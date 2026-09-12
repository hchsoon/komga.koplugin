--[[
Komga/ProgressSync.lua — 阅读进度同步域(自 LibraryView 拆出, legado 式分层)

经 setmetatable(LibraryView, {__index = ProgressSync}) 混入:
调用方仍写 self:uploadCurrentProgress()(self = LibraryView 表),
状态继续存取 LibraryView 运行时字段(默认值声明于 Komga/PlgState)。
]]
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local util = require("util")
local DocSettings = require("docsettings")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local KomgaModel = require("Komga/KomgaModel")
local Backend = require("Komga/Backend")
local TaskQueue = require("Komga/TaskQueue")
local H = require("Komga/Helper")
local Paths = require("Komga/Paths")
local VolumePath = require("Komga/VolumePath")

local ProgressSync = {}

-- 章内/整卷比例统一钳到 0..1(调用方保证 x 为数字)
local function clamp01(x)
    return math.min(math.max(x, 0), 1)
end

-- 取路径/URL 的基名并小写(href_map 反查键与 positions 表 href 对齐用)
local function basename_key(s)
    return (s:match("([^/]+)$") or s):lower()
end

-- 防回退冲刷: 本次位置几乎在卷首(整卷比例 < 2%)而服务器已知进度领先(>5%)时,
-- 视为续读失败落在第 1 页而非用户主动回开, 上层应跳过本次上传,
-- 避免把服务器进度和本地 komga_progress 一并冲刷成 ~0。
function ProgressSync:resumeFlushGuard(bookId, frac)
    if H.is_num(frac) and frac < 0.02 then
        local last_server = self._last_epub_server_frac
        if H.is_tbl(last_server) and last_server.bookId == bookId
            and H.is_num(last_server.frac) and last_server.frac > 0.05 then
            return true
        end
    end
    return false
end

function ProgressSync:getChapterFraction(doc_settings)
    if not (doc_settings and doc_settings.readSetting) then
        return 0
    end
    local pct = doc_settings:readSetting("percent_finished")
    if H.is_num(pct) and pct >= 0 and pct <= 1 then
        return pct
    end
    local last_page = tonumber(doc_settings:readSetting("last_page")) or 0
    local doc_pages = tonumber(doc_settings:readSetting("doc_pages")) or 0
    if last_page >= 99999 or (doc_pages > 0 and last_page >= doc_pages) then
        return 1.0
    end
    if doc_pages > 0 then
        return clamp01(last_page / doc_pages)
    end
    return 0
end

-- EPUB 全书位置查找表(按 bookId 缓存): 服务器 /positions 的 totalProgression 单调递增, 用于 frac→locator 映射
function ProgressSync:getEpubPositions(bookId)
    if not H.is_str(bookId) then
        return nil
    end
    if self._positions_cache and self._positions_cache[bookId] then
        return self._positions_cache[bookId]
    end
    local resp = Backend:getBookPositions(bookId)
    if not (H.is_tbl(resp) and resp.type == "SUCCESS" and H.is_tbl(resp.body)
        and H.is_tbl(resp.body.positions) and #resp.body.positions > 0) then
        return nil
    end
    self._positions_cache = self._positions_cache or {}
    self._positions_cache[bookId] = resp.body
    return resp.body
end

-- EPUB: 整卷比例(0..1) → Komga Readium locator
-- 服务器按 locator 的 href + progression 线性插值重算 totalProgression, 故用 positions 查找表选最近位置并插值,
-- 使服务器重算的 totalProgression ≈ 目标比例。progression 必须 < 1(服务器对 1.0 返回 400 "Invalid progression")
function ProgressSync:epubFractionToLocator(bookId, frac)
    if not (H.is_str(bookId) and H.is_num(frac)) then
        return nil
    end
    local positions = self:getEpubPositions(bookId)
    local list = positions and positions.positions
    if not (H.is_tbl(list) and #list > 0) then
        return nil
    end
    frac = clamp01(frac)
    -- 二分找第一个 totalProgression >= frac 的位置
    local lo, hi = 1, #list
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local tp = list[mid].locations and list[mid].locations.totalProgression
        if H.is_num(tp) and tp < frac then
            lo = mid + 1
        else
            hi = mid
        end
    end
    local idx = math.min(math.max(lo, 1), #list)
    local cur = list[idx]
    local cur_tp = cur.locations and cur.locations.totalProgression
    if not H.is_num(cur_tp) then
        return nil
    end
    -- 同一资源内线性插值; 跨资源时取当前位置起点
    local progression = cur.locations.progression or 0
    local prev = idx > 1 and list[idx - 1] or nil
    local prev_tp = prev and prev.locations and prev.locations.totalProgression or nil
    if prev and prev.href == cur.href and H.is_num(prev_tp) and cur_tp > prev_tp then
        local prev_p = prev.locations.progression or 0
        local cur_p = cur.locations.progression or 0
        progression = prev_p + (frac - prev_tp) / (cur_tp - prev_tp) * (cur_p - prev_p)
    end
    progression = math.min(math.max(progression, 0), 0.999)
    return {
        href = cur.href,
        type = cur.type or "application/xhtml+xml",
        locations = {
            progression = progression,
            position = cur.locations.position,
            totalProgression = frac,
        }
    }
end

-- EPUB: 内部章节 index ↔ 相对 href 双向映射(以 basename 为键, 卷内唯一)
-- 上传用 idx→href 构造 locator; 续读用服务器 locator.href→idx 定位内部章节。
-- 按 bookId 缓存(epub_chapter 行仅在 manifest 补写/预载后变化, 两处 upsert
-- 均已失效缓存), 一次进度上传内的多次取图(定位+插值)只查一次库。
local href_map_cache = {}

function ProgressSync:invalidateEpubHrefMap(book_cache_id)
    if book_cache_id then
        href_map_cache[book_cache_id] = nil
    else
        href_map_cache = {}
    end
end

function ProgressSync:epubChapterHrefMap(bookId)
    local map, rev = {}, {}
    if not H.is_str(bookId) then
        return map, rev
    end
    local cached = href_map_cache[bookId]
    if cached then
        return cached.map, cached.rev
    end
    local all = Backend.dbManager and Backend.dbManager:getAllEpubChapterUrls(bookId)
    if H.is_tbl(all) then
        for _, item in ipairs(all) do
            local idx = item and item.number
            local url = item and item.url
            if H.is_num(idx) and H.is_str(url) then
                -- url 形如 .../resource/OEBPS/Text/Section000.xhtml, 取其相对路径
                local rel = url:match("resource/([^?#]+)") or url
                rel = rel:gsub("^%./", "")
                local key = basename_key(rel)
                map[idx] = rel
                rev[key] = idx
            end
        end
    end
    href_map_cache[bookId] = {map = map, rev = rev}
    return map, rev
end

-- EPUB: 内部章节 + 章内比例 → 服务器整卷比例(0..1)
-- 用 positions 表中同一资源(href)的条目插值, 得到该位置的服务器总进度, 用于构造 locator。
-- 与上传方向一致: 服务器按 locator 重算的 totalProgression ≈ 该比例, 续读再按 href 反查回同一章节。
function ProgressSync:epubChapterFracToServerFrac(bookId, number, frac, map)
    if not (H.is_str(bookId) and H.is_num(number) and H.is_num(frac)) then
        return nil
    end
    map = map or self:epubChapterHrefMap(bookId)
    local href = map[number]
    if not href then
        return nil
    end
    local positions = self:getEpubPositions(bookId)
    local list = positions and positions.positions
    if not (H.is_tbl(list) and #list > 0) then
        return nil
    end
    frac = clamp01(frac)
    local hkey = basename_key(href)
    local prev_tp, prev_p
    for _, pos in ipairs(list) do
        local ph = pos.href and basename_key(pos.href)
        if ph == hkey then
            local ptp = pos.locations and pos.locations.totalProgression
            local pp = pos.locations and pos.locations.progression
            if H.is_num(ptp) and H.is_num(pp) then
                if pp >= frac then
                    if prev_tp and prev_p and prev_p < pp and frac > prev_p then
                        return prev_tp + (frac - prev_p) / (pp - prev_p) * (ptp - prev_tp)
                    end
                    return ptp
                end
                prev_tp, prev_p = ptp, pp
            end
        end
    end
    return prev_tp
end

-- 按 bookId 从卷列表取卷总页数(服务器口径)。
-- KOReader 与 Komga 分页规则不同且 manifest 无每章页数, 页级精确不可行, 只能按章节数比例换算。
-- 数据逻辑在 KomgaModel:getVolumePages; 这里只做参数校验后转发(翻章后 chapter.pages 可能丢失)。
function ProgressSync:getVolumePages(book_cache_id, bookId)
    if not (H.is_str(book_cache_id) and H.is_str(bookId)) then
        return nil
    end
    return KomgaModel:new(book_cache_id):getVolumePages(bookId)
end

-- 按 bookId 反查卷号: EPUB 翻章后 number 是内部章节 index, 上传/刷新必须用卷号。
-- 数据逻辑在 KomgaModel:getVolumeIndexByBookId。
function ProgressSync:getVolumeIndexByBookId(book_cache_id, bookId)
    if not (H.is_str(book_cache_id) and H.is_str(bookId)) then
        return nil
    end
    return KomgaModel:new(book_cache_id):getVolumeIndexByBookId(bookId)
end

-- EPUB: 扫描卷内全部内部章节的已缓存文件, 返回 (order, data)
-- order = 按章节序的 idx 数组; data[idx] = {cp=KOReader页数, frac=已读比例}
-- 每章独立缓存为 <safe书名>-<bookId>-<内部章节idx>.xhtml, 侧车记录该章页数与进度。
-- current_override={number=当前章, frac=实时比例} 时, 当前章用实时比例, 其余读侧车。
function ProgressSync:scanEpubVolumeChapters(book_cache_id, bookId, book_name, current_override)
    local order, data = {}, {}
    if not (H.is_str(book_cache_id) and H.is_str(bookId)) then
        return order, data
    end
    local cur_idx = current_override and current_override.number
    local cur_frac = current_override and current_override.frac
    local all = Backend.dbManager and Backend.dbManager:getAllEpubChapterUrls(bookId)
    if H.is_tbl(all) then
        for _, item in ipairs(all) do
            local idx = item and item.number
            if H.is_num(idx) then
                local cp = 1
                local frac = 0
                -- 内部章节缓存扩展名随源页面 URL(.xhtml 或 .html), 探测实际存在的文件
                local base = H.getVolumeCacheFilePath(book_cache_id, bookId, idx, book_name or "")
                local path = util.fileExists(base .. ".xhtml") and (base .. ".xhtml")
                    or (util.fileExists(base .. ".html") and (base .. ".html")) or nil
                if path then
                    local ds = DocSettings:open(path)
                    if ds and ds.readSetting then
                        local p = tonumber(ds:readSetting("doc_pages")) or 0
                        if p > 0 then
                            cp = p
                        end
                    end
                    if H.is_num(cur_idx) and idx == cur_idx and H.is_num(cur_frac) then
                        frac = cur_frac
                    else
                        frac = self:getChapterFraction(ds)
                    end
                elseif H.is_num(cur_idx) and idx == cur_idx and H.is_num(cur_frac) then
                    frac = cur_frac
                end
                data[idx] = { cp = cp, frac = clamp01(frac) }
                table.insert(order, idx)
            end
        end
    end
    return order, data
end

-- EPUB: 累计该卷已读页数(跨内部章节), 每章已读 = floor(frac*cp+0.5)
-- 上传方向与本地断点共用, 避免把单章比例当成整卷比例(整卷是多个内部章节 xhtml)
function ProgressSync:calcVolumeLocalRead(book_cache_id, bookId, book_name, current_override)
    local order, data = self:scanEpubVolumeChapters(book_cache_id, bookId, book_name, current_override)
    local total = 0
    for _, idx in ipairs(order) do
        local d = data[idx]
        total = total + math.floor(d.frac * d.cp + 0.5)
    end
    return total
end

-- EPUB: 累计该卷已读页数换算为全局页码(显示用近似), 第2返回值当前内部章节
function ProgressSync:calcVolumeGlobalPage(book_cache_id, chapter, pages)
    if not (H.is_str(book_cache_id) and H.is_tbl(chapter) and H.is_str(chapter.bookId)
        and H.is_num(pages) and pages > 0) then
        return 0
    end
    local read_pages = self:calcVolumeLocalRead(book_cache_id, chapter.bookId, chapter.name)
    local p = math.max(math.floor(read_pages + 0.5), 1)
    if p > pages then
        p = pages
    end
    if p > 0 then
        return p, chapter.number
    end
    return 0, nil
end

-- 上传当前阅读进度到服务器(关闭/翻章时调用, 锁+延迟, 失败静默不影响本地)
function ProgressSync:uploadCurrentProgress()
    if not NetworkMgr:isConnected() then
        return
    end
    local chapter = self.displayed_chapter
    local reader = ReaderUI.instance
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookId) and reader and reader.document) then
        return
    end
    local file = reader.document.file
    if not (H.is_str(file) and file:find(Paths.CACHE_DIR_SEGMENT, 1, true)) then
        return
    end
    -- 翻章后内部章节可能丢失 name/url, 从卷数据兜底补回(saveVolumeProgress 强依赖这两项)
    if not (H.is_str(chapter.name) and H.is_str(chapter.url)) then
        local vol_idx = self.volume_reading_index or chapter.number
        local vol = KomgaModel:new(chapter.book_cache_id):getVolume(vol_idx) -- Komga Book(分卷)
        if H.is_tbl(vol) then
            chapter.name = chapter.name or vol.name
            chapter.url = chapter.url or vol.url
        end
    end
    if not (H.is_str(chapter.name) and H.is_str(chapter.url)) then
        return
    end
    local doc_settings = DocSettings:open(file)
    local is_epub = chapter.mediaType == "EPUB" or file:match("%.x?html$") ~= nil
    local current_page, pages, epub_frac, epub_locator
    -- 实时进度优先取 ReaderFooter(翻页即时更新), sidecar 的 percent_finished 只在 onSaveSettings 落盘会滞后
    local footer = reader.view and reader.view.footer
    local live_pageno = footer and footer.pageno
    local live_frac = footer and footer.percent_finished
    if is_epub then
        pages = self.volume_pages or self:getVolumePages(chapter.book_cache_id, chapter.bookId)
        if not (H.is_num(pages) and pages > 0) then
            return
        end
        local frac
        if H.is_num(live_frac) and live_frac >= 0 and live_frac <= 1 then
            frac = live_frac
        else
            frac = self:getChapterFraction(doc_settings)
        end
        -- EPUB 整卷是多个内部章节 xhtml, 每章 footer 比例只代表该章(章内比例)。
        -- 位置定位按"当前内部章节 href + 章内比例"为准, 不能用"累计已读页数/卷页数"
        -- (累计≠位置, 各章页数差异大会跳错章节)。
        -- 1) 首选: 章内比例经 positions 插值为服务器整卷比例, 再用 positions 反查构造 locator
        --    (progression<1 必须, 服务器对 1.0 返回 400 "Invalid progression");
        -- 2) 兜底: 直接构造最小 locator(仅 href + 章内 progression);
        -- 3) 最后: 无法确定章节时按累计页数换算整卷比例走 positions
        -- 内部章节缓存扩展名随源页面 URL(.xhtml 或 .html), 统一经 VolumePath 解析;
        -- 解析失败会导致 locator 恒为"第 1 章 0%", 服务器进度冻结在卷首
        local cur_idx = VolumePath.chapterIndex(file)
        -- 整卷原文件模式(.epub): 文件名无内部章节号, 实时比例即整卷比例;
        -- 逐章模式: 章内比例经 positions 插值为服务器整卷比例(与整卷模式同源)
        local href_map = self:epubChapterHrefMap(chapter.bookId)
        local vol_frac
        if cur_idx == nil and H.is_num(frac) then
            vol_frac = clamp01(frac)
        else
            vol_frac = cur_idx and self:epubChapterFracToServerFrac(chapter.bookId, cur_idx, frac, href_map)
        end
        local href = cur_idx and href_map[cur_idx]
        local loc
        if self:resumeFlushGuard(chapter.bookId, vol_frac) then
            return
        end
        if H.is_num(vol_frac) then
            loc = self:epubFractionToLocator(chapter.bookId, vol_frac)
        elseif href then
            loc = {
                href = href,
                type = "application/xhtml+xml",
                locations = {
                    progression = math.min(math.max(frac, 0.001), 0.999),
                },
            }
        else
            local read_pages = self:calcVolumeLocalRead(chapter.book_cache_id, chapter.bookId, chapter.name,
                { number = cur_idx, frac = frac })
            loc = self:epubFractionToLocator(chapter.bookId, clamp01(read_pages / pages))
        end
        if H.is_tbl(loc) then
            epub_locator = loc
            -- 记录服务器空间整卷比例(totalProgression), 供快捷方式 sidecar 显示正确的整卷百分比
            local tp = loc.locations and loc.locations.totalProgression
            if H.is_num(tp) then
                self._last_epub_server_frac = { bookId = chapter.bookId, frac = clamp01(tp) }
            end
        end
        -- 记录本地断点: 关闭/翻章后按内部章节 + 章内比例直接定位(与上传同源)
        if cur_idx then
            self._last_epub_pos = { bookId = chapter.bookId, number = cur_idx, frac = frac }
        end
        current_page = math.max(math.min(math.ceil(frac * pages), pages), 1)
        -- EPUB 进度必须走 /progression: 服务器对 EPUB 拒绝 page 格式 read-progress(400 "not Divina compatible")
        -- locator 已构造好, scheduleProgressUpload 直接使用
        -- 整卷比例(服务器空间)取 locator 的 totalProgression, 不能用章内比例(frac):
        -- 单章读完 != 整卷读完, 否则 saveBookProgression 的 frac>=0.999 会把卷误标已读(显示 100%)
        epub_frac = (loc and loc.locations and loc.locations.totalProgression) or nil
        -- 把最近一次服务器空间进度落盘到当前卷快捷方式 sidecar, 修正文件夹/Reading History 显示的整卷百分比
        self:persistKomgaProgressToShortcut()
    else
        pages = chapter.pages
        if not (H.is_num(pages) and pages > 0) then
            return
        end
        if H.is_num(live_pageno) and live_pageno > 0 then
            current_page = math.min(live_pageno, pages)
        else
            local last_page = tonumber(doc_settings:readSetting("last_page")) or 0
            current_page = math.min(math.max(last_page, 1), pages)
        end
        -- 与 EPUB 一致: 记录服务器空间整卷比例并落盘到快捷方式 sidecar(供文件夹显示正确百分比)
        local comic_frac = current_page / pages
        if self:resumeFlushGuard(chapter.bookId, comic_frac) then
            return
        end
        self._last_epub_server_frac = { bookId = chapter.bookId, frac = comic_frac }
        self:persistKomgaProgressToShortcut()
    end
    -- 用卷号而非内部 index, 否则 saveVolumeProgress 内 toggleVolumeRead 会把错误的卷标已读。
    -- 优先按 bookId 反查(翻章后 number 是内部 index 且 volume_reading_index 可能未设置)
    local vol_index = self:getVolumeIndexByBookId(chapter.book_cache_id, chapter.bookId)
    if not (H.is_num(vol_index) and vol_index > 0) then
        vol_index = self.volume_reading_index or chapter.number
    end
    self:scheduleProgressUpload({
        name = chapter.name,
        url = chapter.url,
        bookId = chapter.bookId,
        pages = pages,
        current_page = current_page,
        number = vol_index,
        book_cache_id = chapter.book_cache_id,
        epub = is_epub,
        frac = epub_frac,
        locator = epub_locator,
    })
end

-- 进度上传: 延迟到翻页/关闭事件之后执行, 非重入锁 + 合并最新一条, 失败静默
function ProgressSync:scheduleProgressUpload(upload_chapter)
    if self.progress_sync_busy then
        self.progress_sync_pending = upload_chapter
        return
    end
    self.progress_sync_busy = true
    UIManager:nextTick(function()
        -- EPUB 走 /progression(Readium locator), 漫画走 read-progress(page)
        if upload_chapter.epub then
            -- 优先用上传时按当前内部章节构造的 locator; 兜底再按整卷比例走 positions
            local loc = upload_chapter.locator
            if not loc and H.is_num(upload_chapter.frac) then
                loc = self:epubFractionToLocator(upload_chapter.bookId, upload_chapter.frac)
            end
            if loc then
                upload_chapter.locator = loc
                local ok_save, save_resp = pcall(Backend.saveBookProgression, Backend, upload_chapter)
                if not ok_save then
                    logger.warn("[KomgaProgress] progression 上传异常:", H.errorHandler(save_resp))
                end
            else
                -- positions 获取失败: 跳过本次上传(失败静默, 下次翻章/关闭再传)
            end
        else
            local ok_save, save_resp = pcall(Backend.saveVolumeProgress, Backend, upload_chapter)
            if not ok_save then
                logger.warn("[KomgaProgress] read-progress 上传异常:", H.errorHandler(save_resp))
            end
        end
        self.progress_sync_busy = false
        local pending = self.progress_sync_pending
        self.progress_sync_pending = nil
        if pending then
            self:scheduleProgressUpload(pending)
        end
    end)
end

-- 自动续读: 服务器进度更新时打开对应内部章节(章节级近似), 否则保留本地断点
function ProgressSync:persistKomgaProgressToShortcut()
    local s = self._last_epub_server_frac
    local lnk_path = self.volume_lnk_path
    if not (H.is_tbl(s) and H.is_str(s.bookId) and H.is_num(s.frac) and s.frac > 0 and s.frac <= 1) then
        return
    end
    if not (H.is_str(lnk_path) and util.fileExists(lnk_path)) then
        return
    end
    local ds = DocSettings:open(lnk_path)
    -- 快捷方式侧边已有 bookId 且与当前书不一致 -> 不是这本书的快捷方式, 跳过
    local custom = ds:readSetting("custom_props")
    if H.is_tbl(custom) and H.is_str(custom.bookId) and custom.bookId ~= s.bookId then
        return
    end
    -- 快捷方式缺少 bookId 时, 用 self.volume_bookId 二次校验
    if not (H.is_tbl(custom) and H.is_str(custom.bookId))
        and H.is_str(self.volume_bookId) and self.volume_bookId ~= s.bookId then
        return
    end
    local old = ds:readSetting("komga_progress")
    if old ~= s.frac then
        ds:saveSetting("komga_progress", s.frac):flush()
    end
end

-- 共同核心: 记录最近服务器空间整卷比例并落盘到快捷方式 sidecar(比例 <= 0 不动)
function ProgressSync:stampServerFracAndPersist(bookId, frac)
    if H.is_num(frac) and frac > 0 then
        self._last_epub_server_frac = { bookId = bookId, frac = clamp01(frac) }
        self:persistKomgaProgressToShortcut()
    end
end

-- 漫画打开前: 读取服务器 readProgress.page/pages 落盘到快捷方式 sidecar(供文件夹显示正确百分比)。
-- 只做显示, 不改变阅读位置; 服务器无进度或离线时静默跳过。
function ProgressSync:persistComicServerProgress(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookId) and H.is_num(chapter.pages) and chapter.pages > 0) then
        return
    end
    local ok, resp = pcall(Backend.getVolumeReadProgress, Backend, chapter)
    local rp = ok and resp and resp.body and resp.body.readProgress
    local page = rp and tonumber(rp.page)
    if H.is_num(page) and page > 0 then
        self:stampServerFracAndPersist(chapter.bookId, page / chapter.pages)
    end
end

-- StreamImageView(流式漫画)关闭时: 把流式阅读的整卷比例落盘到快捷方式 sidecar 并刷新文件夹显示。
-- 与 ReaderUI 关闭路径(onCloseDocument -> uploadCurrentProgress)对齐, 否则流式阅读不会写 komga_progress。
function ProgressSync:persistStreamComicProgress(chapter, page)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookId) and H.is_num(page)) then
        return
    end
    local pages = H.is_num(chapter.pages) and chapter.pages or 0
    if not (pages > 0) then
        return
    end
    self:stampServerFracAndPersist(chapter.bookId, page / pages)
    if H.is_num(chapter.number) then
        self:refreshReadVolumeShortcut(chapter.book_cache_id, chapter.number)
    end
end

-- ===== 分卷目录初始化: 批量同步全部分卷的服务器阅读进度 =====

-- BookDto[] → { [bookId] = {page, completed, pages} }(纯函数, 仅保留带 readProgress 的书)。
-- pages 用服务器自己的 media.pagesCount, 换算比例时与服务器网页端同口径。
function ProgressSync.extractServerProgressMap(books)
    local out = {}
    if not H.is_tbl(books) then
        return out
    end
    for _, book in ipairs(books) do
        if H.is_tbl(book) and H.is_str(book.id) and H.is_tbl(book.readProgress) then
            local media = H.is_tbl(book.media) and book.media or {}
            out[book.id] = {
                page = tonumber(book.readProgress.page),
                completed = book.readProgress.completed == true,
                pages = tonumber(media.pagesCount),
            }
        end
    end
    return out
end

-- readProgress 条目 → 服务器空间整卷比例(0..1], 无有效进度返回 nil(不打扰本地显示状态)。
-- completed 直接视为读完; 比例 = 服务器 page/pagesCount(与 Komga 网页端显示一致)。
function ProgressSync.volumeServerFrac(entry)
    if not H.is_tbl(entry) then
        return nil
    end
    if entry.completed == true then
        return 1
    end
    local page = tonumber(entry.page)
    local pages = tonumber(entry.pages)
    if not (H.is_num(page) and page > 0 and H.is_num(pages) and pages > 0) then
        return nil
    end
    return clamp01(page / pages)
end

-- 分卷目录初始化时批量同步服务器阅读进度: 一次 books/list 请求拿到全部分卷 readProgress,
-- 把有变化的服务器空间比例落盘到各卷快捷方式 sidecar(komga_progress)。
-- 覆盖"曾在其他设备/端读到第 N 卷, 本地无任何进度痕迹, 目录首屏却显示未读"的场景
-- (逐卷点开时的 persistComicServerProgress/续读只覆盖当前那一卷)。
-- 每次进入分卷目录都执行, 离线静默跳过; 无变化零写入, 有变化整目录只刷新一次。
function ProgressSync:syncAllVolumesServerProgress(book_cache_id, bookinfo, volume_folder)
    if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo) and H.is_str(volume_folder)) then
        return
    end
    if not NetworkMgr:isConnected() then
        return
    end
    -- 同系列去重: 上一次请求未回来时不重复发
    self.server_rp_busy = self.server_rp_busy or {}
    if self.server_rp_busy[book_cache_id] then
        return
    end
    self.server_rp_busy[book_cache_id] = true
    -- fork 前关库: 子进程只做 HTTP+JSON, 不持有 sqlite 连接
    Backend:closeDbManager()
    TaskQueue.getChannel("sync", 1):push(function()
        local ok, resp = pcall(Backend.getSeriesVolumesReadProgress, Backend, book_cache_id)
        if not (ok and H.is_tbl(resp) and resp.type == "SUCCESS" and H.is_tbl(resp.body)) then
            return {}
        end
        return ProgressSync.extractServerProgressMap(resp.body)
    end, function(ok, progress_map)
        self.server_rp_busy[book_cache_id] = nil
        if ok and H.is_tbl(progress_map) then
            self:applyServerProgressToShortcuts(book_cache_id, bookinfo, volume_folder, progress_map)
        end
    end, {timeout = 45, tag = "series_read_progress"})
end

-- 把拉回的服务器进度逐卷落盘(分块让出 UI, 纯磁盘/DB 工作不 fork):
-- 只处理有服务器进度且与 sidecar 现值不同的卷; 结束后整目录只 onRefresh 这一次
-- (行失效由 persistServerProgressToShortcut -> refreshVolumeMetadata -> emitMetadataChanged 按路径完成)。
function ProgressSync:applyServerProgressToShortcuts(book_cache_id, bookinfo, volume_folder, progress_map)
    if not next(progress_map) then
        return
    end
    local volumes = KomgaModel:new(book_cache_id):getVolumes()
    if not (H.is_tbl(volumes) and #volumes > 0) then
        return
    end
    local targets = {}
    for _, volume in ipairs(volumes) do
        if H.is_tbl(volume) and H.is_num(volume.number) then
            local frac = ProgressSync.volumeServerFrac(progress_map[volume.bookId])
            -- 本地已读(isRead)显示恒为满进度, 服务器进度无显示意义, 跳过
            if H.is_num(frac) and volume.isRead ~= true then
                targets[#targets + 1] = { volume = volume, frac = frac }
            end
        end
    end
    if #targets == 0 then
        return
    end
    local total = #targets
    local idx = 1
    local changed = 0
    -- 每块 3 卷: 单卷 = sidecar 读 + (有变化时)写 + 卷元数据重算
    local function step()
        local last = math.min(idx + 2, total)
        while idx <= last do
            local target = targets[idx]
            idx = idx + 1
            if self:persistServerProgressToShortcut(book_cache_id, volume_folder,
                target.volume, target.frac, bookinfo) then
                changed = changed + 1
            end
        end
        if idx <= total then
            UIManager:scheduleIn(0.05, step)
        else
            -- 汇总系列总进度到书架的系列快捷方式行(与本次是否有新进度无关——
            -- 也兜住上次阅读会话写下的各卷进度); 内部无变化自动跳过
            if H.is_tbl(self.book_browser) and self.book_browser.refreshSeriesTotalProgress then
                pcall(function()
                    self.book_browser:refreshSeriesTotalProgress(book_cache_id, bookinfo)
                end)
            end
            if changed > 0 then
                local fm = FileManager.instance
                if fm and fm.onRefresh then
                    pcall(function()
                        fm:onRefresh()
                    end)
                end
            end
        end
    end
    UIManager:scheduleIn(0.03, step)
end

-- 单卷: 服务器进度与 sidecar 现值(komga_progress)不同时写入, 并按既有层级重算显示元数据。
-- 返回是否实际写入; 快捷方式缺失/无变化时零写入(避免无谓的行失效与目录刷新)。
function ProgressSync:persistServerProgressToShortcut(book_cache_id, volume_folder, volume, frac, bookinfo)
    if not (H.is_tbl(self.book_browser) and H.is_tbl(volume) and H.is_num(volume.number)
        and H.is_num(frac) and frac > 0) then
        return false
    end
    local lnk_path = self.book_browser:writeVolLnk(volume, volume_folder, book_cache_id)
    if not (H.is_str(lnk_path) and util.fileExists(lnk_path)) then
        return false
    end
    local ds = DocSettings:open(lnk_path)
    -- LuaJIT 的 tonumber(nil) 直接报错, 先做类型判断再换算(兼容数字/数字字符串两种落盘形态)
    local raw_old = ds:readSetting("komga_progress")
    local old
    if H.is_num(raw_old) or H.is_str(raw_old) then
        old = tonumber(raw_old)
    end
    if H.is_num(old) and math.abs(old - frac) < 0.0001 then
        return false
    end
    ds:saveSetting("komga_progress", frac):flush()
    -- komga_progress 是 refreshVolumeMetadata 的第二优先级进度源, 调它统一换算
    -- pageno/percent_finished/summary(内部对无变化有跳过保护, 不会盲目重写)
    self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, volume.number, bookinfo)
    -- 就地让目录行显示新进度(不发失效广播/不触发重提取, 避免逐卷广播带来的
    -- 反复重提取与目录重排): 列表行的 percent_finished/status 由 BookList 从
    -- sidecar 直读并缓存在内存表, 清掉该条目后下一次绘制(本流程结尾的一次
    -- onRefresh)即重读 sidecar; CoverBrowser 的 DB 行不承载进度, 无需动它。
    pcall(function()
        local BookList = require("ui/widget/booklist")
        if BookList and BookList.resetBookInfoCache then
            BookList.resetBookInfoCache(lnk_path)
        end
    end)
    return true
end

-- 轻量刷新分卷快捷方式进度（doc_props）

return ProgressSync
