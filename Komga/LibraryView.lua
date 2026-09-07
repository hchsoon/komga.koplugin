local BD = require("ui/bidi")
local Font = require("ui/font")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Menu = require("ui/widget/menu")
local Device = require("device")
local T = ffiUtil.template
local _ = require("gettext")

local ChapterListing = require("Komga/ChapterListing")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Icons = require("Komga/Icons")
local Backend = require("Komga/Backend")
local KomgaModel = require("Komga/KomgaModel")
local MessageBox = require("Komga/MessageBox")
local H = require("Komga/Helper")
local TaskQueue = require("Komga/TaskQueue")
local Config = require("Komga/Config")
local VolumePath = require("Komga/VolumePath")
local Paths = require("Komga/Paths")

local PlgState = require("Komga/PlgState")
local ProgressSync = require("Komga/ProgressSync")
-- 运行时状态字段集中声明于 Komga/PlgState(单一来源); 方法查找经 __index
-- 落到 ProgressSync(进度同步域), 其余方法仍直接定义于本表。
local LibraryView = setmetatable(PlgState.libraryState(), { __index = ProgressSync })

function LibraryView:init()
    if LibraryView.instance then
        return
    end
    self.book_browser_homedir = self:getBrowserHomeDir(true)
    self:backupDbWithPreCheck()
    LibraryView.instance = self
end

function LibraryView:backupDbWithPreCheck()
    local temp_dir = H.getTempDirectory()
    local last_backup_db = H.joinPath(temp_dir, "bookinfo.db.bak")
    local bookinfo_db_path = H.joinPath(temp_dir, "bookinfo.db")

    if not util.fileExists(bookinfo_db_path) then
        logger.warn("komga plugin: source database file does not exist - " .. bookinfo_db_path)
        return false
    end

    local setting_data = Backend:getSettings()
    local last_backup_time = setting_data.last_backup_time or 0
    local has_backup = util.fileExists(last_backup_db)
    local needs_backup = not has_backup or (os.time() - last_backup_time > 86400)

    if not needs_backup then
        return true
    end

    local status, err = pcall(function()
        Backend:getBookShelfCache()
    end)
    if not status then
        logger.err("komga plugin: database pre-check failed - " .. tostring(err))
        return false
    end

    if has_backup then
        util.removeFile(last_backup_db)
    end
    H.copyFileFromTo(bookinfo_db_path, last_backup_db)
    logger.info("komga plugin: backup successful")
    setting_data.last_backup_time = os.time()
    Backend:saveSettings(setting_data)
end

function LibraryView:fetchAndShow()
    local is_first = not LibraryView.instance
    local library_view = LibraryView.instance or self:getInstance()
    local use_browser = not self:isDisableBrowserMode() and is_first and self:browserViewHasLnk()
    local widget = use_browser and self:getBrowserWidget() or self:getMenuWidget()
    if widget then
        widget:show_view()
        widget:refreshItems()
    end
    return self
end

function LibraryView:isDisableBrowserMode()
    local settings = Backend:getSettings()
    return settings and settings.disable_browser == true
end
function LibraryView:browserViewHasLnk()
    local browser_homedir = self:getBrowserHomeDir(true)
    return browser_homedir and util.directoryExists(browser_homedir) and not util.isEmptyDir(browser_homedir)
end

function LibraryView:addBkShortcut(bookinfo, always_add)
    if not always_add and self:isDisableBrowserMode() then
        return
    end
    local browser = self:getBrowserWidget()
    if browser then
        browser:addBookShortcut(bookinfo)
    end
end

function LibraryView:addVolShortcut(bookinfo, seriename, always_add)
    if not always_add and self:isDisableBrowserMode() then
        return
    end
    local browser = self:getBrowserWidget()
    if browser then
        browser:addVolumeShortcut(bookinfo, seriename)
    end
end

function LibraryView:onRefreshLibrary()
    -- 手动刷新书架: 同时清除分卷目录的"已同步"持久标记,
    -- 下次进入分卷目录会重新做一次完整逐卷刷新
    local settings = Backend:getSettings()
    if H.is_tbl(settings.vol_meta_synced) then
        settings.vol_meta_synced = nil
        Backend:saveSettings()
    end
    if self.book_menu then
        self.book_menu:onRefreshLibrary()
    end
end

function LibraryView:closeMenu()
    if self.book_menu then
        self.book_menu:onClose()
    end
end

-- 设置对话框/服务器配置/设置大菜单: 方法体在 Komga/SettingsDialogs
-- (install(LibraryView) 注入, 函数体保持 self 语义, 避免模块环)
require("Komga/SettingsDialogs")(LibraryView)

-- 浏览器目录名/匹配逻辑收敛在 Komga/Paths(常量单一来源)
local function is_komga_browser_dir_path(file_path)
    return Paths.isKomgaBrowserDirPath(file_path, Backend:getSettings().browser_dir_name)
end

-- exit readerUI,  closing the at readerUI、FileManager the same time app will exit
-- readerUI -> ReturnKomgaChapterListing event -> show ChapterListing -> close ->show LibraryView ->close -> ? 
function LibraryView:openKomgaFolder(path, focused_file, selected_files, done_callback)
    UIManager:nextTick(function()
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
            self.readerui_is_showing = false
        end
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        if H.is_str(path) and fc and fc.changeToPath then
            -- 轻量导航: 直接驱动当前 FileChooser 切换到目标目录。
            -- 这与用户点击文件夹走同一条代码路径, 比 FileManager:reinit 重建整个
            -- FileChooser/TitleBar widget 更稳; 部分设备(Android)上 reinit 重建后
            -- 界面不刷新或点击无响应, 换成 changeToPath 可规避。
            fc:changeToPath(path, focused_file)
        elseif fm then
            fm:reinit(path, focused_file, selected_files)
        else
            FileManager:showFiles(path, focused_file, selected_files)
        end
        if fm and H.is_str(path) then
            fm:updateTitleBarPath(path)
        end
        if H.is_func(done_callback) then
            done_callback()
        end
    end)
end

-- 系列快捷方式点击: 进入该系列的分卷目录（数据缺失时先同步分卷）
function LibraryView:openSeriesVolumesFolder(book_cache_id, serie_file)
    self:getInstance()
    self:getBrowserWidget()
    if not H.is_str(book_cache_id) then
        MessageBox:notice("openSeriesVolumesFolder parameter error")
        return
    end
    local model = KomgaModel:new(book_cache_id)
    local bookinfo = model:getSeries() -- Komga Series
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name)) then
        MessageBox:notice("书籍不存在于书架,请刷新同步")
        return
    end
    local chapters = model:getVolumes() -- Komga Book 列表(分卷)
    if H.is_tbl(chapters) and #chapters > 0 then
        self:doOpenSeriesVolumesFolder(book_cache_id, bookinfo)
        return
    end
    -- 分卷未同步, 先刷新目录
    if not NetworkMgr:isConnected() then
        MessageBox:notice("分卷数据未同步且当前无网络连接")
        return
    end
    -- 本进程内同步分卷目录。不使用 MessageBox:loading + fork 子进程:
    -- fork 后的子进程内网络请求在部分设备(Android/macOS)上会挂起,
    -- 而 MessageBox:loading 的对话框 dismissable=false 无法点击取消,
    -- 导致模态对话框永久显示、后续点击全部失效("重新点击没有反应")。
    -- refreshVolumesCache 内部 socketutil 有 10s/12s 超时, 本进程内可靠返回。
    self:syncChaptersInProcess(book_cache_id, bookinfo)
end

-- 记录同步错误/痕迹到日志文件, 便于排查
function LibraryView:logSyncError(err_str)
    pcall(function()
        local f = io.open(H.getTempDirectory() .. "/sync_err.log", "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(err_str) .. "\n")
            f:close()
        end
    end)
end

-- 本进程内直接同步分卷(不走 MessageBox:loading 的子进程 fork)。
-- 在 macOS 上 fork 后的子进程内网络/数据库状态可能异常, 导致回调拿到 nil;
-- 本进程内同步已验证可用。
function LibraryView:syncChaptersInProcess(book_cache_id, bookinfo)
    local dialog = MessageBox:custom({
        text = "正在同步分卷目录...",
        icon = "notice-info"
    })
    local ok, err_or_res = pcall(function()
        return Backend:refreshVolumesCache({
            url = bookinfo.url,
            cache_id = book_cache_id,
            name = bookinfo.name,
            author = bookinfo.author,
            cacheExt = bookinfo.cacheExt
        })
    end)
    UIManager:close(dialog)
    if not ok then
        self:logSyncError(tostring(err_or_res))
        MessageBox:error('同步分卷失败: 同步异常: ' .. tostring(err_or_res))
        return
    end
    Backend:HandleResponse(err_or_res, function(data)
        self:doOpenSeriesVolumesFolder(book_cache_id, bookinfo)
    end, function(err_msg)
        MessageBox:error('同步分卷失败: ' .. tostring(err_msg))
    end)
end

function LibraryView:doOpenSeriesVolumesFolder(book_cache_id, bookinfo)
    self:getInstance()
    self:getBrowserWidget()
    if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo)) then
        return
    end
    local volume_folder = self.book_browser:ensureVolumeFolder(book_cache_id, bookinfo)
    if not volume_folder then
        MessageBox:notice("创建分卷目录失败")
        return
    end
    -- 点击系列后目录秒开(异步优化):
    -- 1) 先把全部快捷方式落盘(轻量写, 不做元数据加工), 目录内容立即可见
    local volumes = KomgaModel:new(book_cache_id):getVolumes()
    if H.is_tbl(volumes) then
        for _, volume in ipairs(volumes) do
            if H.is_num(volume.number) then
                pcall(function()
                    self.book_browser:writeVolLnk(volume, volume_folder, book_cache_id)
                end)
            end
        end
    end
    -- 2) 立即打开目录(此前要等全部卷的元数据同步完才打开, 大系列卡顿数秒到数十秒)
    self:openKomgaFolder(volume_folder)
    -- 3) 元数据/封面在后台分块补齐(块间让出 UI, 不 fork——本工作纯磁盘/DB,
    --    且本项目已验证 fork+网络/嵌套在部分平台不可靠)
    self:syncSeriesVolumesInBackground(book_cache_id, bookinfo, volume_folder)
end

-- 后台分块执行每卷 refreshVolumeMetadata/封面下载(每块 chunk_size 卷, 块间让出主循环)。
-- 完成后一次性 onRefresh 上屏最终元数据(中间不逐卷重绘, 避免 e-ink 闪烁)。
-- 同一系列去重: 上一次分块未跑完时跳过重复触发。
function LibraryView:syncSeriesVolumesInBackground(book_cache_id, bookinfo, volume_folder, chunk_size)
    if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo) and H.is_str(volume_folder)) then
        return
    end
    self._bg_volume_sync = self._bg_volume_sync or {}
    if self._bg_volume_sync[book_cache_id] then
        return
    end
    -- 已同步标记持久化在 komga.lua 设置里(跨重启有效):
    -- 每个系列只在首次进入分卷目录时做一次完整同步, 之后进入仅补缺失封面,
    -- 不再逐卷刷新元数据/广播(这是目录"加载很久"+"反复刷新"的主因)。
    -- 需要重刷时走手动"同步书架"(onRefreshLibrary 会清除标记)。
    local settings = Backend:getSettings()
    settings.vol_meta_synced = H.is_tbl(settings.vol_meta_synced) and settings.vol_meta_synced or {}

    self._bg_volume_sync = self._bg_volume_sync or {}
    if self._bg_volume_sync[book_cache_id] then
        return
    end

    local volumes = KomgaModel:new(book_cache_id):getVolumes()
    if not (H.is_tbl(volumes) and #volumes > 0) then
        return
    end

    -- 轻量补封面: 只检查各卷缺失的封面并入队下载(无元数据写入/无广播)。
    -- 已同步状态下每次进入分卷目录都会跑一遍, 保证漏下的封面能自行补齐。
    local function fill_missing_covers()
        for _, volume in ipairs(volumes) do
            if H.is_num(volume.number) then
                local lnk_path = self.book_browser:writeVolLnk(volume, volume_folder, book_cache_id)
                if lnk_path and util.fileExists(lnk_path)
                    and not DocSettings:findCustomCoverFile(lnk_path) then
                    self.book_browser:asyncDownloadVolumeCover(book_cache_id, volume, lnk_path)
                end
            end
        end
    end

    -- 已完整同步过: 仅补缺失封面, 不再逐卷刷新元数据
    if settings.vol_meta_synced[book_cache_id] then
        self._bg_volume_sync[book_cache_id] = nil
        fill_missing_covers()
        return
    end

    -- 首次进入: 标记已同步(持久化), 后台分块做完整刷新
    settings.vol_meta_synced[book_cache_id] = true
    self._bg_volume_sync[book_cache_id] = true
    -- 批量期间挂起单卷元数据广播, 结束后统一失效+整目录一次刷新
    self._bulk_meta_sync = true
    self._pending_meta_paths = {}
    -- 每块 1 卷 + 0.1s 间隔: 每卷含 DB 查询/多次 sidecar 写/封面任务 fork,
    -- 单卷即需数百毫秒; 块太大时翻页事件在块间隙得不到处理(实测首次加载期翻页无响应)
    chunk_size = H.is_num(chunk_size) and chunk_size or 1
    local total = #volumes
    local idx = 1
    local function step()
        local last = math.min(idx + chunk_size - 1, total)
        while idx <= last do
            local volume = volumes[idx]
            idx = idx + 1
            if H.is_num(volume.number) then
                pcall(function()
                    local lnk_path, lnk_name = self.book_browser:writeVolLnk(volume, volume_folder, book_cache_id)
                    if lnk_path and util.fileExists(lnk_path) then
                        self.book_browser:refreshVolumeMetadata(lnk_name, lnk_path, book_cache_id,
                            volume.number, bookinfo)
                        if not DocSettings:findCustomCoverFile(lnk_path) then
                            self.book_browser:asyncDownloadVolumeCover(book_cache_id, volume, lnk_path)
                        end
                    end
                end)
            end
        end
        if idx <= total then
            UIManager:scheduleIn(0.1, step)
        else
            self._bg_volume_sync[book_cache_id] = nil
            self._bulk_meta_sync = nil
            -- 批量结束: 统一失效期间变更的 CoverBrowser 缓存行, 整目录只刷新这一次
            local pending = self._pending_meta_paths
            self._pending_meta_paths = nil
            if pending then
                for path in pairs(pending) do
                    pcall(function()
                        self.book_browser:emitMetadataChanged(path)
                    end)
                end
            end
            local fm = FileManager.instance
            if fm and fm.onRefresh then
                pcall(function()
                    fm:onRefresh()
                end)
            end
            -- 持久化"已同步"标记(连同期间写入的设置), 跨重启不再重刷
            pcall(function()
                Backend:saveSettings()
            end)
        end
    end
    UIManager:scheduleIn(0.03, step)
end

-- 章节内进度分数(0..1): 优先 KOReader 写入的 percent_finished, 否则 last_page/doc_pages

-- 子进程执行: 拉取续读定位所需的服务器数据(纯数据经管道回传, 决策/落盘仍在主线程)。
-- 原 resumeAndOpenVolume 在 UI 线程同步发 2-3 个 GET, 慢网下点开快捷方式即冻结。
local function fetch_resume_server_data(volume, is_epub)
    local raw = { is_epub = is_epub }
    if not is_epub then
        local resp = Backend:getVolumeReadProgress(volume)
        raw.rp = (resp and resp.body and resp.body.readProgress) or nil
        return raw
    end
    local _, rev = LibraryView:epubChapterHrefMap(volume.bookId)
    if not next(rev) then
        -- DB 无内部章节清单: 拉 manifest 入库, 之后 href 反查可用(与旧逻辑一致)
        pcall(Backend.getAllEpubChapters, Backend, volume)
        _, rev = LibraryView:epubChapterHrefMap(volume.bookId)
    end
    raw.rev = rev
    local prog = Backend:getBookProgression(volume.bookId)
    raw.prog_body = (prog and prog.type == "SUCCESS" and prog.body) or nil
    -- 与主线程决策同源的兜底条件: locator 无法映射内部章节且无整卷比例时才补页码进度
    local loc = raw.prog_body and raw.prog_body.locator
    local tp = loc and loc.locations and loc.locations.totalProgression
    local prog_in_ch = loc and loc.locations and loc.locations.progression
    local href = loc and loc.href
    local s_idx
    if H.is_str(href) and H.is_num(prog_in_ch) then
        s_idx = rev and rev[(href:match("([^/]+)$") or href):lower()]
    end
    if not H.is_num(s_idx) and not H.is_num(tp) then
        local resp = Backend:getVolumeReadProgress(volume)
        raw.rp = (resp and resp.body and resp.body.readProgress) or nil
    end
    return raw
end

function LibraryView:resumeAndOpenVolume(volume, server_data)
    local pages = volume.pages
    local is_epub = volume.mediaType == "EPUB"
    local server_frac, server_completed
    local server_target -- EPUB: {number=内部章节, frac=章内比例}
    local local_target  -- EPUB: {number=内部章节, frac=章内比例} 本地断点
    if not server_data then
        -- 先在子进程拉服务器进度: 拉取期间界面保持响应, 完成后带数据重入本函数;
        -- 拉取失败也重入(空数据退化为本地断点续读)。fork 不可用时同步降级(行为同旧版)。
        -- fork 前关库: 子进程经 getDB 用自有连接读库/写 manifest, 主线程按需懒重开
        Backend:closeDbManager()
        TaskQueue.getChannel("sync", 1):push(function()
            return fetch_resume_server_data(volume, is_epub)
        end, function(ok, raw, err)
            self:resumeAndOpenVolume(volume, ok and raw or {})
        end, {timeout = 45, tag = "resume_progress"})
        return
    end
    if is_epub then
        -- EPUB: 服务器 locator 自带 href + 章内 progression, 直接映射内部章节定位;
        -- 不依赖 totalProgression 换算页码(各端分页规则不同, 换算会跳错章节)
        local loc = server_data.prog_body and server_data.prog_body.locator
        local tp = loc and loc.locations and loc.locations.totalProgression
        local prog_in_ch = loc and loc.locations and loc.locations.progression
        local href = loc and loc.href
        if H.is_num(tp) then
            server_frac = math.min(math.max(tp, 0), 1)
            server_completed = tp >= 0.999
            -- 打开即把服务器整卷进度落盘到快捷方式 sidecar, 修正文件夹显示的整卷百分比
            self._last_epub_server_frac = { bookId = volume.bookId, frac = server_frac }
            self:persistKomgaProgressToShortcut()
        end
        -- 服务器 locator.href → 内部章节 + 章内比例(href 与 url 同源, 用 basename 反查)
        if H.is_str(href) and H.is_num(prog_in_ch) then
            local rev = server_data.rev or select(2, self:epubChapterHrefMap(volume.bookId))
            local s_idx = rev[(href:match("([^/]+)$") or href):lower()]
            if H.is_num(s_idx) then
                server_target = { number = s_idx, frac = math.min(math.max(prog_in_ch, 0), 1) }
            end
        end
        if not server_target and not H.is_num(tp) then
            -- 服务器无 Readium 进度: 回退 readProgress.page/pages(EPUB 页数单位错配, 仅作兜底)
            local rp = server_data.rp
            if H.is_tbl(rp) and H.is_num(pages) and pages > 0 then
                server_frac = math.min(math.max((tonumber(rp.page) or 1) / pages, 0), 1)
                server_completed = rp.completed == true
            end
        end
        -- 本地断点: 关闭时记录的内部章节 + 章内比例(与上传同源)
        local last = self._last_epub_pos
        if H.is_tbl(last) and last.bookId == volume.bookId
            and H.is_num(last.number) and H.is_num(last.frac) then
            local_target = { number = last.number, frac = last.frac }
        end
    else
        local rp = server_data.rp
        if H.is_tbl(rp) and H.is_num(pages) and pages > 0 then
            server_frac = math.min(math.max((tonumber(rp.page) or 1) / pages, 0), 1)
            server_completed = rp.completed == true
        end
    end

    if is_epub then
        -- EPUB 目标: 服务器更靠后 → 服务器位置; 否则本地断点
        local target
        if server_completed == true then
            -- 已读完: 打开最后一章末尾并翻下卷
            local _, rev = self:epubChapterHrefMap(volume.bookId)
            local last_idx
            for _, v in pairs(rev) do
                if not last_idx or v > last_idx then
                    last_idx = v
                end
            end
            if last_idx then
                target = { number = last_idx, frac = 1 }
                self.chapter_call_event = "next"
            end
        elseif server_target then
            if local_target then
                if server_target.number > local_target.number then
                    target = server_target
                elseif server_target.number < local_target.number then
                    target = local_target
                else
                    target = (server_target.frac >= local_target.frac) and server_target or local_target
                end
            else
                target = server_target
            end
            self.chapter_call_event = nil
        else
            target = local_target
            self.chapter_call_event = nil
        end
        if target and H.is_num(target.number) then
            volume.number = target.number
            if H.is_num(target.frac) and target.frac > 0 and target.frac < 1 then
                self.resume_goto_frac = target.frac
            else
                self.resume_goto_frac = nil
            end
        end
    else
        -- 漫画: 卷级缓存文件比例即整卷进度(单文件整卷, 与 EPUB 不同)
        if not (H.is_num(pages) and pages > 0) then
            self:loadAndRenderChapter(volume)
            return
        end
        local local_global = self:calcVolumeGlobalPage(volume.book_cache_id, volume, pages)
        local local_frac = math.min(math.max(local_global / pages, 0), 1)
        local target_frac
        if server_completed == true then
            target_frac = 1.0
            self.chapter_call_event = "next"
        elseif H.is_num(server_frac) and server_frac > local_frac + (1 / pages) then
            -- 服务器进度领先: 跳到服务器位置(领先至少一页)
            target_frac = server_frac
            self.chapter_call_event = "next"
        else
            -- 服务器进度不领先: 回到本地断点
            target_frac = local_frac
            self.chapter_call_event = nil
        end
        -- 与 EPUB 一致: 把服务器整卷进度落盘到快捷方式 sidecar, 修正文件夹显示的整卷百分比
        if H.is_num(server_frac) and server_frac > 0 then
            self._last_epub_server_frac = { bookId = volume.bookId, frac = server_frac }
            self:persistKomgaProgressToShortcut()
        end
        if target_frac and target_frac > 0 then
            self.resume_goto_frac = target_frac
        end
    end
    self:loadAndRenderChapter(volume)
end

-- 分卷快捷方式点击: 镜像 ChapterListing:onMenuChoice 的流式/缓存分流
function LibraryView:openVolumeShortcut(book_cache_id, number, lnk_path)
    self:getInstance()
    self:getBrowserWidget()
    if not (H.is_str(book_cache_id) and H.is_num(number)) then
        MessageBox:notice("openVolumeShortcut parameter error")
        return
    end
    local volume = KomgaModel:new(book_cache_id):getVolume(number) -- Komga Book(分卷)
    if not (H.is_tbl(volume) and H.is_num(volume.number)) then
        MessageBox:notice("分卷数据不存在,请返回书架刷新同步")
        return
    end
    -- 记住当前卷快捷方式路径: 上传/续读进度时把服务器空间整卷比例落盘到该 sidecar, 供文件夹显示正确百分比
    if H.is_str(lnk_path) then
        self.volume_lnk_path = lnk_path
    end
    -- 分卷快捷方式进入的 EPUB 阅读: 标记为分卷阅读, 目录按钮显示 EPUB 原生目录而非系列目录
    if volume.mediaType == "EPUB" then
        volume.volume_read = true
        self.volume_reading_index = number
        self.volume_pages = volume.pages
        self.volume_bookId = volume.bookId
        -- 自动续读: 服务器进度更新时跳到服务器位置(章节级近似); 离线或设置关闭时不查
        if NetworkMgr:isConnected() and Backend:getSettings().auto_resume_volume ~= false then
            return self:resumeAndOpenVolume(volume)
        end
    else
        -- 漫画(单文件整卷): 与 EPUB 一致, 打开前读取服务器进度并落盘到快捷方式 sidecar, 供文件夹显示正确百分比;
        -- 缓存漫画: 服务器进度领先时跳到服务器位置(复用 resumeAndOpenVolume 的漫画分支);
        -- 流式漫画: 只落盘显示用进度, 阅读位置由 StreamImageView 按 readProgress 处理
        self.volume_reading_index = number
        self.volume_pages = volume.pages
        self.volume_bookId = volume.bookId
        local is_stream = Backend:getSettings().stream_image_view == true
        if NetworkMgr:isConnected() and Backend:getSettings().auto_resume_volume ~= false then
            if is_stream then
                self:persistComicServerProgress(volume)
            else
                return self:resumeAndOpenVolume(volume)
            end
        end
    end
    -- 刷新该卷快捷方式的进度显示
    if H.is_str(lnk_path) and util.fileExists(lnk_path) then
        self:refreshVolumeShortcutProgress(book_cache_id, number, lnk_path)
    end

    if Backend:getSettings().stream_image_view == true and volume.mediaType ~= "EPUB" then
        local bookinfo = KomgaModel:new(book_cache_id):getSeries() -- Komga Series
        if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
            MessageBox:notice("书籍数据缺失")
            return
        end
        -- 流式阅读不经过 showReaderUI, 手动记录当前卷, 供关闭时写入阅读记录(History)
        self.displayed_chapter = volume
        local volume_dir = H.is_str(lnk_path) and select(1, util.splitFilePathName(lnk_path)) or nil
        NetworkMgr:runWhenOnline(function()
            UIManager:nextTick(function()
                local StreamImageView = require("Komga/StreamImageView")
                StreamImageView:fetchAndShow({
                    bookinfo = bookinfo,
                    chapter = volume,
                    on_return_callback = function()
                        if H.is_str(volume_dir) then
                            self:openKomgaFolder(volume_dir)
                        end
                    end
                })
            end)
        end)
        Backend:show_notice("流式漫画开启")
    else
        self:loadAndRenderChapter(volume)
    end
end

-- 读完返回文件浏览器时, 刷新当前分卷快捷方式的进度显示
function LibraryView:refreshReadVolumeShortcut(book_cache_id, number)
    self:getBrowserWidget()
    if not (H.is_str(book_cache_id) and H.is_num(number)) then
        return
    end
    -- 已跟踪本次阅读的快捷方式且侧车匹配时直用, 免去全目录扫描(关书路径的热点);
    -- 跨卷后路径可能指向旧卷, 校验 book_cache_id + number 不匹配则走扫描兜底
    local known = self.volume_lnk_path
    if H.is_str(known) and util.fileExists(known) then
        local ok_ds, ds = pcall(function()
            return DocSettings:open(known)
        end)
        local props = ok_ds and ds and ds:readSetting("custom_props")
        if H.is_tbl(props) and props.type == "volume" and props.number == number
            and ds:readSetting("book_cache_id") == book_cache_id then
            self:persistKomgaProgressToShortcut()
            self.book_browser:refreshVolumeMetadata(nil, known, book_cache_id, number)
            return
        end
    end
    local file_manager = FileManager.instance
    local dir = file_manager and file_manager.file_chooser and file_manager.file_chooser.path
    if not (H.is_str(dir) and is_komga_browser_dir_path(dir)) then
        return
    end
    local found
    util.findFiles(dir, function(fullpath, name)
        if found then
            return
        end
        if util.fileExists(fullpath) and name:find(Paths.LNK_SUFFIX, 1, true) then
            local customedata = self.book_browser:getCustomMateData(fullpath)
            if H.is_tbl(customedata) and customedata.type == 'volume' and
                customedata.number == number then
                local doc_settings = DocSettings:open(fullpath)
                if doc_settings:readSetting("book_cache_id") == book_cache_id then
                    found = fullpath
                end
            end
        end
    end, false)
    if found then
        self.volume_lnk_path = found
        -- 关闭返回时把服务器空间进度写入该快捷方式(覆盖目录打开等无快捷方式路径的场景)
        self:persistKomgaProgressToShortcut()
        self.book_browser:refreshVolumeMetadata(nil, found, book_cache_id, number)
    end
end

-- 把最近一次服务器空间整卷比例(_last_epub_server_frac)写入分卷快捷方式 sidecar(komga_progress),
-- 供 refreshVolumeMetadata 显示正确的整卷百分比; 无快捷方式/无可用比例时静默跳过。
-- 注意: 不覆盖 custom_props, 因此需校验当前快捷方式确实属于该 bookId, 避免串卷写入。
function LibraryView:refreshVolumeShortcutProgress(book_cache_id, number, lnk_path)
    self:getBrowserWidget()
    if not (H.is_str(book_cache_id) and H.is_num(number) and H.is_str(lnk_path) and
        util.fileExists(lnk_path)) then
        return
    end
    self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, number)
end

-- 阅读记录(History): 把当前正在阅读的分卷映射到其分卷快捷方式(.html)。
-- 供 patches/core.lua 在 ReadHistory:addItem 时调用: komga 阅读打开的是缓存文件
-- (EPUB 是内部章节 xhtml / 漫画是 cbz), 直接写进历史点开会丢失 komga 上下文,
-- 所以统一映射为分卷快捷方式, 历史条目点击后走 komga:openFile -> openVolumeShortcut 恢复阅读。
-- 返回快捷方式路径; 数据缺失返回 nil(此时不写入阅读记录)。
function LibraryView:ensureVolumeShortcutForReading()
    self:getInstance()
    self:getBrowserWidget()
    local chapter = self.displayed_chapter
    if not (H.is_tbl(chapter) and H.is_str(chapter.book_cache_id) and H.is_str(chapter.bookId)) then
        return nil
    end
    local book_cache_id = chapter.book_cache_id
    -- 分卷索引: 漫画 number 即卷号; EPUB 的 displayed_chapter.number 可能是内部章节 index, 用卷号反查
    local vol_index = chapter.number
    if chapter.mediaType == "EPUB" then
        vol_index = self.volume_reading_index
            or self:getVolumeIndexByBookId(book_cache_id, chapter.bookId)
            or chapter.number
    end
    if not (H.is_num(vol_index) and vol_index > 0) then
        return nil
    end
    local model = KomgaModel:new(book_cache_id)
    local bookinfo = model:getSeries() -- Komga Series
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name)) then
        return nil
    end
    local volume_folder = self.book_browser:ensureVolumeFolder(book_cache_id, bookinfo)
    if not volume_folder then
        return nil
    end
    -- 用与 syncSeriesVolumes 同源的卷数据构造快捷方式, 保证文件名一致(已存在则复用, 不会重复创建)
    local vol = model:getVolume(vol_index) -- Komga Book(分卷)
    if not (H.is_tbl(vol) and H.is_num(vol.number)) then
        return nil
    end
    local lnk_path = self.book_browser:writeVolLnk(vol, volume_folder, book_cache_id)
    if H.is_str(lnk_path) and util.fileExists(lnk_path) then
        -- 补写 DocSettings sidecar(provider="komga" / custom_props.type="volume" / book_cache_id / number):
        -- writeVolLnk 只把 book_cache_id 写进 .html 内联 config, 不写 sidecar;
        -- 而 LibraryView:openFile 点开分卷快捷方式时依赖 customedata.type=='volume' 路由到 openVolumeShortcut,
        -- 缺了它历史条目点击会退化到 series 的 openLastReadChapter 而非该卷续读。
        pcall(function()
            self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, vol_index)
        end)
        return lnk_path
    end
    return nil
end

-- 分卷快捷方式右键菜单
function LibraryView:openVolumeBrowserMenu(file, customedata)
    self:getInstance()
    self:getBrowserWidget()
    local lnk_path = file
    if not H.is_str(lnk_path) then
        return
    end
    local book_cache_id = customedata and customedata.book_cache_id
    if not H.is_str(book_cache_id) then
        book_cache_id = DocSettings:open(lnk_path):readSetting("book_cache_id")
    end
    local number = customedata and customedata.number
    if not H.is_num(number) then
        number = DocSettings:open(lnk_path):readSetting("number") or
            DocSettings:open(lnk_path):readSetting("chapters_index") -- 兼容旧版 sidecar key
    end
    if not (H.is_str(book_cache_id) and H.is_num(number)) then
        MessageBox:notice("分卷快捷方式数据不完整")
        return
    end
    local volume = KomgaModel:new(book_cache_id):getVolume(number) -- Komga Book(分卷)
    local is_read = H.is_tbl(volume) and volume.isRead == true
    local isDownLoaded = H.is_tbl(volume) and volume.isDownLoaded == true
    local dialog
    local buttons = {{{
        text = table.concat({Icons.FA_CHECK_CIRCLE, (is_read and ' 取消' or ' 标记'), "已读"}),
        callback = function()
            UIManager:close(dialog)
            Backend:HandleResponse(Backend:toggleVolumeRead({
                number = number,
                chapter_page = 0,
                isRead = is_read,
                book_cache_id = book_cache_id
            }), function(data)
                self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, number)
                self.book_browser:refreshItems()
            end, function(err_msg)
                MessageBox:error('标记失败 ', err_msg)
            end)
        end
    }}, {{
        text = table.concat({Icons.FA_DOWNLOAD, (isDownLoaded and ' 刷新' or ' 下载'), '分卷'}),
        callback = function()
            UIManager:close(dialog)
            Backend:HandleResponse(Backend:changeVolumeCache({
                number = number,
                cacheFilePath = volume.cacheFilePath,
                book_cache_id = book_cache_id,
                isDownLoaded = isDownLoaded,
                url = volume.url,
                title = volume
            }), function(data)
                self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, number)
                self.book_browser:refreshItems()
                if isDownLoaded == true then
                    Backend:show_notice('删除成功')
                else
                    MessageBox:success('后台下载分卷任务已添加，请稍后下拉刷新')
                end
            end, function(err_msg)
                MessageBox:error('失败:', err_msg)
            end)
        end
    }}, {{
        text = table.concat({Icons.FA_THUMB_TACK, " 上传进度"}),
        callback = function()
            UIManager:close(dialog)
            self:syncVolumeProgressShow(book_cache_id, number)
        end
    }}, {{
        text = "删除快捷方式",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("确定删除该分卷快捷方式? (不影响已缓存的分卷)", function(result)
                if result then
                    self:deleteFile(lnk_path, true)
                end
            end, {
                ok_text = "删除",
                cancel_text = "取消"
            })
        end
    }}}

    dialog = require("ui/widget/buttondialog"):new{
        title = "分卷快捷方式",
        title_align = "center",
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }
    UIManager:show(dialog)
end

-- 上传分卷阅读进度到服务器（尽力读取本地缓存文件进度）
function LibraryView:syncVolumeProgressShow(book_cache_id, number)
    self:getBrowserWidget()
    local volume = KomgaModel:new(book_cache_id):getVolume(number) -- Komga Book(分卷)
    if not (H.is_tbl(volume) and H.is_num(volume.pages)) then
        MessageBox:notice("分卷数据不存在")
        return
    end
    local cache_chapter = Backend:getCacheVolumeFilePath(volume)
    volume.current_page = 0
    if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) then
        local cache_doc_settings = DocSettings:open(cache_chapter.cacheFilePath)
        volume.current_page = tonumber(cache_doc_settings:readSetting("last_page")) or 0
    end
    Backend:closeDbManager()
    MessageBox:loading("同步中 ", function()
        local response = Backend:saveVolumeProgress(volume)
        if not (type(response) == 'table' and response.type == 'SUCCESS') then
            local message = (type(response) == 'table' and response.message) or
                "进度上传失败，请稍后重试"
            return {
                type = 'ERROR',
                message = message
            }
        end
        return Backend:refreshLibraryCache()
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                self.book_browser:refreshItems()
                Backend:show_notice('同步完成')
            end, function(err_msg)
                MessageBox:error('同步失败：' .. tostring(err_msg))
            end)
        end
    end)
end

function LibraryView:loadAndRenderChapter(chapter)

    local cache_chapter = Backend:getCacheVolumeFilePath(chapter)

    if (H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath)) then
        -- 缓存命中分支也要传递分卷阅读标记, 否则目录按钮会退回系列目录而非 EPUB 原生目录
        cache_chapter.volume_read = chapter.volume_read
        self:showReaderUI(cache_chapter)
        return
    end
    -- 静默后台下载: 未命中预取缓存时在子进程下载+内容处理, 完成后回主线程打开。
    -- 旧版在 UI 线程同步下载, 大章节/慢网下翻章即冻结; fork 不可用时同步降级(行为同旧版)。
    -- 全程无提示(仅失败轻提示), 不打断阅读。
    self._downloading_chapters = self._downloading_chapters or {}
    local dl_key = tostring(chapter.bookId or chapter.number)
    if self._downloading_chapters[dl_key] then
        return
    end
    self._downloading_chapters[dl_key] = true
    -- fork 前关库: 子进程经 getDB 用自有连接写库, 主线程按需懒重开
    Backend:closeDbManager()
    TaskQueue.getChannel("download", 1):push(function()
        return Backend:downloadVolume(chapter)
    end, function(ok, resp, err)
        self._downloading_chapters[dl_key] = nil
        -- 子进程可能已补写 epub_chapter 行, 失效 ProgressSync 的 href 映射缓存
        pcall(function()
            require("Komga/ProgressSync").invalidateEpubHrefMap(chapter.book_cache_id)
        end)
        if not ok then
            Backend:show_notice("章节下载失败" .. (H.is_str(err) and (": " .. err) or ""))
            return
        end
        Backend:HandleResponse(resp, function(data)
            if not (H.is_tbl(data) and H.is_str(data.cacheFilePath)) then
                Backend:show_notice("章节下载失败")
                return
            end
            data.volume_read = chapter.volume_read
            self:showReaderUI(data)
        end, function(err_msg)
            Backend:show_notice("章节下载失败" .. (H.is_str(err_msg) and (": " .. err_msg) or ""))
        end)
    end, {timeout = 900, tag = "chapter_download"})
end

-- 跨卷续读: 当前卷翻到末尾时问服务器"同系列下一本书"(Komga /books/:id/next),
-- 本地库有该卷记录则用分卷打开流程接着读(EPUB 走服务器进度续读, 漫画走流式/缓存)。
-- 新卷尚未同步到本地库时回退目录(刷新书架后可读); 全程静默, 失败不弹窗。
function LibraryView:openNextVolumeOnServer(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookId) and H.is_str(chapter.book_cache_id)) then
        return false
    end
    local ok, next_book = pcall(Backend.getNextBookOnServer, Backend, chapter.bookId)
    if not ok or not H.is_tbl(next_book) then
        return false
    end
    local next_volume = Backend:getVolumeByBookId(chapter.book_cache_id, next_book.id)
    if not (H.is_tbl(next_volume) and H.is_num(next_volume.number)) then
        return false
    end
    Backend:show_notice(string.format("接续下一卷: %s", tostring(next_volume.title or next_book.id)))
    self:openVolumeShortcut(chapter.book_cache_id, next_volume.number, nil)
    return true
end

function LibraryView:ReaderUIEventCallback(chapter_call_event)
    if not (H.is_str(chapter_call_event) and H.is_tbl(self.displayed_chapter)) then
        return
    end
    local chapter = self.displayed_chapter
    self.chapter_call_event = chapter_call_event
    chapter.call_event = chapter_call_event

    local nextChapter = Backend:findNextVolume({
        number = chapter.number,
        call_event = chapter.call_event,
        book_cache_id = chapter.book_cache_id,
        bookId = chapter.bookId,
        booksCount = chapter.booksCount
    })

    if H.is_tbl(nextChapter) then
        -- 翻页/跨章节时 findNextEpubChapterInfo 返回的内部章节缺少 bookId/mediaType/volume_read
        -- 等字段, 必须从当前章节补齐, 否则缓存路径解析失败(TOC 按钮也会退回系列目录)
        nextChapter.bookId = chapter.bookId
        nextChapter.call_event = chapter.call_event
        nextChapter.mediaType = chapter.mediaType
        nextChapter.volume_read = chapter.volume_read
        nextChapter.book_cache_id = chapter.book_cache_id
        nextChapter.name = chapter.name
        nextChapter.author = chapter.author
        nextChapter.cacheExt = chapter.cacheExt
        nextChapter.booksCount = chapter.booksCount
        self:loadAndRenderChapter(nextChapter)
    else
        -- 当前卷翻到末尾: 在线时先尝试跨卷续读(Komga /books/:id/next),
        -- 离线/无下一卷/本地库无记录时静默回退目录
        if chapter_call_event == 'next' and NetworkMgr:isConnected() then
            local ok_next, opened = pcall(self.openNextVolumeOnServer, self, chapter)
            if ok_next and opened == true then
                return
            end
        end
        -- print("No more pages")
        self:openKomgaFolder(nil, nil, nil, function()
            if self.book_toc then
                UIManager:show(self.book_toc)
            end
        end)
    end
end

function LibraryView:showReaderUI(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then
        return
    end
    -- print("Cache file path...", chapter.cacheFilePath)
    chapter.booksCount = Backend:getEpubChapterCount(chapter.bookId)
    -- 兜底: 分卷类型可能因翻页/换章节而丢失, 按 DB 是否有内部章节清单推断 EPUB。
    -- 不能按扩展名推断: EPUB 内部章节缓存可能是 .xhtml 或 .html, 而书源文本章节也缓存为 .html
    -- (booksCount 即上方 getEpubChapterCount 结果, 仅 EPUB 分卷 > 0)
    if chapter.mediaType == nil and H.is_num(chapter.booksCount) and chapter.booksCount > 0 then
        chapter.mediaType = "EPUB"
    end
    self.displayed_chapter = chapter
    -- 记录当前阅读是否为分卷快捷方式进入（TOC 决策依据）
    self.volume_reading = chapter.volume_read == true
    -- 快照卷数据: 翻章后内部章节对象可能丢失 pages/bookId, 上传与续读依赖
    if H.is_num(chapter.pages) and chapter.pages > 0 then
        self.volume_pages = chapter.pages
    end
    if H.is_str(chapter.bookId) then
        self.volume_bookId = chapter.bookId
    end
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    if self.book_toc then
        UIManager:close(self.book_toc)
    end
    -- 自动续读: reader 打开后按 resume_goto_frac 跳转。
    -- EPUB 的 resume_goto_frac 是目标内部章节的章内比例(目标章节已通过 number 打开)
    local goto_resume_target = function()
        local target = self.resume_goto_frac
        self.resume_goto_frac = nil
        if H.is_num(target) and target > 0 then
            local ui = ReaderUI.instance
            if ui and ui.document then
                local pct = target * 100
                if pct > 100 then
                    pct = 100
                end
                ui:handleEvent(Event:new("GotoPercent", pct))
            end
        end
    end
    if ReaderUI.instance then
        -- 章节切换窗口期过滤核心层 "Closing book" 提示(补丁层实现, 3 秒后自动清除)
        local patches_core = require("patches.core")
        patches_core.switching_chapter = true
        UIManager:scheduleIn(3, function()
            patches_core.switching_chapter = nil
        end)
        ReaderUI.instance:switchDocument(book_path, true, goto_resume_target)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(book_path, nil, true, nil, goto_resume_target)
    end
    Backend:after_reader_chapter_show(chapter)
end

-- 分卷内部目录: 阅读 EPUB 分卷时, 目录按钮展示该分卷自身的章节列表(epubchapters)
-- 分卷在缓存中是单页 xhtml, KOReader 无原生 TOC, 因此用数据库里的内部章节构建目录
function LibraryView:showVolumeEpubToc(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookId)) then
        MessageBox:notice("分卷信息缺失")
        return
    end
    local epub_chapters = Backend:getAllEpubChapters(chapter)
    if not (H.is_tbl(epub_chapters) and #epub_chapters > 0) then
        MessageBox:error('无法获取 epub 内部目录')
        return
    end
    local item_table = {}
    for _, epub_chapter in ipairs(epub_chapters) do
        table.insert(item_table, {
            number = epub_chapter.number,
            text = epub_chapter.title or string.format('章节 %d', epub_chapter.number),
            mandatory = "  "
        })
    end
    local items_per_page = G_reader_settings:readSetting("toc_items_per_page") or 14
    local items_font_size = G_reader_settings:readSetting("toc_items_font_size") or
        Menu.getItemFontSize(items_per_page)
    local volume_title = (H.is_str(chapter.title) and chapter.title ~= "") and chapter.title or
        (H.is_str(chapter.volumename) and chapter.volumename) or "分卷"
    local volume_toc_menu = Menu:new{
        title = volume_title .. " - 内部目录",
        subtitle = "epub 章节导航",
        is_popout = false,
        item_table = item_table,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        single_line = true,
        with_dots = true,
        items_per_page = items_per_page,
        items_font_size = items_font_size,
        close_callback = function()
            Backend:closeDbManager()
        end,
    }
    volume_toc_menu.onMenuChoice = function(_, item)
        if item.number then
            volume_toc_menu:onClose()
            chapter.number = item.number
            self:loadAndRenderChapter(chapter)
        end
    end
    volume_toc_menu.paths = {{
        callback = function()
            UIManager:close(volume_toc_menu)
        end
    }}
    UIManager:show(volume_toc_menu)
end

-- ReaderUI 事件胶水: 方法体在 Komga/ReaderHooks(install 注入)
require("Komga/ReaderHooks")(LibraryView)

-- 浏览器快捷方式引擎与书架菜单: 构造函数在 Komga/BrowserViews
-- (install(LibraryView) 返回构造函数, 保持原 local 调用点不变)
local init_book_browser, init_book_menu = require("Komga/BrowserViews")(LibraryView)

function LibraryView:getBrowserHomeDir(skip_check)
    local home_dir = H.getHomeDir()
    if not H.is_str(home_dir) then
        logger.err("LibraryView.getBrowserHomeDir: home_dir is nil")
        return nil
    end
    -- 根目录名可配置(设置项 browser_dir_name), 缺省用内置名; 不允许路径分隔符
    local browser_dir_name = Backend:getSettings().browser_dir_name
    if not (H.is_str(browser_dir_name) and browser_dir_name ~= "") then
        browser_dir_name = Paths.DEFAULT_BROWSER_DIR_NAME
    end
    browser_dir_name = browser_dir_name:gsub("[/\\]", "_")
    local expected_path = H.joinPath(home_dir, browser_dir_name)
    -- nil or home_dir changed
    if not H.is_str(self.book_browser_homedir) or self.book_browser_homedir ~= expected_path then
        -- 特殊情况：设置以 browser_dir_name 为主目录
        local clean_home_dir = home_dir:gsub("/+$", "")
        local last_folder = clean_home_dir:match("([^/]+)$")
        if last_folder and last_folder == browser_dir_name then
            self.book_browser_homedir = home_dir
        else
            self.book_browser_homedir = expected_path
        end
    end

    if not skip_check then
        local success, err = pcall(H.checkAndCreateFolder, self.book_browser_homedir)
        if not (success and util.directoryExists(self.book_browser_homedir)) then
            logger.err("LibraryView.getBrowserHomeDir: failed to create directory - " ..
                           tostring(err or "unknown error"))
            return nil
        end
    end
    return self.book_browser_homedir
end

function LibraryView:deleteFile(file, is_file)
    local exists = is_file and util.fileExists(file) or util.directoryExists(file)
    if not exists then
        return false
    end

    if FileManager.instance then
        FileManager.instance:goHome()
        FileManager.instance:deleteFile(file, is_file)
        FileManager.instance:onRefresh()
        return true
    end
    if is_file then
        return util.removeFile(file)
    else
        return pcall(ffiUtil.purgeDir, file)
    end
end

function LibraryView:getBrowserCurrentDir()
    local file_manager = FileManager.instance
    if file_manager and file_manager.file_chooser then
        return file_manager.file_chooser.path
    end
    local readerui = ReaderUI.instance
    if readerui then
        return readerui:getLastDirFile()
    end
end

function LibraryView:getInstance()
    if not LibraryView.instance then
        self:init()
    end
    return self
end

function LibraryView:getBrowserWidget()
    return init_book_browser(self)
end

function LibraryView:getMenuWidget()
    return init_book_menu(self)
end

return LibraryView
