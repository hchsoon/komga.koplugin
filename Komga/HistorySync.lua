--[[ Komga/HistorySync.lua — 从 Komga 同步"在读"历史到 KOReader 本地(手动触发)

流程: POST /books/list 按 readProgress.lastModified 倒序拉全库 → 过滤在读
(completed 跳过) → 按 bookId 定位书架已有系列的卷 → 快捷方式 sidecar 进度落盘
(复用 persistServerProgressToShortcut) → 以服务器 lastModified 为时间戳合并进
KOReader 阅读历史。

安全合并(只向前不后退): ReadHistory:addItem(file, ts) 会把已有条目移动到 ts
位置 —— 本机比服务器新时(本地读完又读过)回写旧时间戳会把"继续阅读"置顶条目
降级, 故本地条目时间 >= 服务器时间时跳过。

系列不在书架的卷一期跳过(书架刷新纳入后下次同步即可补上)。
]]
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local H = require("Komga/Helper")
local Backend = require("Komga/Backend")
local TaskQueue = require("Komga/TaskQueue")
local KomgaModel = require("Komga/KomgaModel")
local MessageBox = require("Komga/MessageBox")

local HistorySync = {}

-- 默认同步条数(komga.lua 设置 history_sync_limit 可覆盖, 设置菜单可改)
local DEFAULT_LIMIT = 20

-- 纯函数: BookDto[] → 在读候选(有 readProgress 且未 completed), 保持服务器排序截前 limit 条
function HistorySync.filterReadingBooks(books, limit)
    local out = {}
    if not H.is_tbl(books) then
        return out
    end
    for _, book in ipairs(books) do
        if H.is_tbl(book) and H.is_str(book.id) and H.is_tbl(book.readProgress)
            and book.readProgress.completed ~= true
            and H.is_str(book.readProgress.lastModified) then
            out[#out + 1] = book
            if H.is_num(limit) and #out >= limit then
                break
            end
        end
    end
    return out
end

-- 纯函数: ISO8601 → 本地时区 epoch。容忍毫秒与小数秒; 时区取 Z(缺省, UTC)或
-- ±hh:mm 后缀; 解析失败返回 nil
function HistorySync.isoToEpoch(s)
    if not H.is_str(s) then
        return nil
    end
    local y, mo, d, h, mi, sec = s:match("(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then
        return nil
    end
    local epoch = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
    local offset = 0
    local sign, oh, om = s:match("([+-])(%d%d):(%d%d)$")
    if sign then
        offset = (tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60
        if sign == "-" then
            offset = -offset
        end
    end
    -- os.time 按本地时区解释字段: UTC 字段值 + (本地-UTC) 差值即得正确 epoch,
    -- 再减去串内显式时差(无后缀按 UTC)
    local utc_now = os.time(os.date("!*t"))
    local local_now = os.time()
    return epoch - offset + (local_now - utc_now)
end

-- 纯函数: 合并决策 —— 服务器条目是否应写入本地历史(只向前不后退)
function HistorySync.shouldBackfill(existing_time, server_ts)
    if not H.is_num(server_ts) then
        return false
    end
    if not H.is_num(existing_time) then
        return true
    end
    return server_ts > existing_time
end

-- 系列行是否存在(全库书架同步会建齐; 服务器新加的系列可能还没有)
function HistorySync.seriesRowExists(series_id)
    local db = Backend.dbManager
    if not (db and H.is_str(series_id)) then
        return false
    end
    local ok, info = pcall(function()
        return db:getSeriesInfo(Backend:getServerPathCode(), series_id)
    end)
    return ok and H.is_tbl(info) and H.is_str(info.name) or false
end

-- 卷行按需落地: volume 表只在"进过该系列分卷目录"后才有行(书架全量同步不建卷),
-- 没卷行时用 BookDto 自带字段直接 upsert 单行, 免整系列卷清单拉取; 系列行也缺失
-- (书架同步后服务器新加)时拉单条 SeriesDto 建行。
-- upsertSeries 的 isUpdate 必须传 true: 缺省语义是"先停用全部旧系列"的全量刷新。
function HistorySync.materializeVolume(book)
    local db = Backend.dbManager
    if not (db and H.is_tbl(book) and H.is_str(book.id) and H.is_str(book.seriesId)) then
        return false
    end
    if not HistorySync.seriesRowExists(book.seriesId) then
        local ok, resp = pcall(Backend.getSeriesById, Backend, book.seriesId)
        local dto = ok and H.is_tbl(resp) and resp.type == "SUCCESS"
            and H.is_tbl(resp.body) and resp.body or nil
        if not dto then
            return false
        end
        local ok_series = pcall(function()
            db:upsertSeries(Backend:getServerPathCode(), {dto},
                Backend.settings_data.data.server_address, true)
        end)
        if not ok_series then
            return false
        end
    end
    local ok_volume = pcall(function()
        db:upsertVolumes(book.seriesId, {book})
    end)
    return ok_volume
end

-- 单条: 定位卷(缺卷行按需落地) → 本地已读纠偏(服务器在读证据) → sidecar 进度
-- 落盘 → 系列快捷方式补建 → 返回卷快捷方式路径。无法落地返回 nil
function HistorySync.applyOne(lv, book)
    local owner = Backend.dbManager and Backend.dbManager:findVolumeOwnerByBookId(book.id)
    if not (H.is_tbl(owner) and H.is_str(owner.book_cache_id) and H.is_num(owner.number)) then
        if not HistorySync.materializeVolume(book) then
            return nil
        end
        owner = Backend.dbManager:findVolumeOwnerByBookId(book.id)
        if not (H.is_tbl(owner) and H.is_str(owner.book_cache_id) and H.is_num(owner.number)) then
            return nil
        end
    end
    local book_cache_id, number = owner.book_cache_id, owner.number
    local model = KomgaModel:new(book_cache_id)
    local volume = model:getVolume(number)
    local bookinfo = model:getSeries()
    if not (H.is_tbl(volume) and H.is_num(volume.number)
        and H.is_tbl(bookinfo) and H.is_str(bookinfo.name)) then
        return nil
    end
    local volume_folder = lv.book_browser:ensureVolumeFolder(book_cache_id, bookinfo)
    if not volume_folder then
        return nil
    end
    local rp = book.readProgress
    -- 服务器"在读"证据: 本地误标已读的卷纠正回来(与 applyServerProgressToShortcuts 同规则)
    if volume.isRead == true then
        volume.book_cache_id = book_cache_id
        volume.isRead = false
        pcall(Backend.markVolumeRead, Backend, volume, false)
    end
    local pages = H.is_num(volume.pages) and volume.pages or tonumber(rp.pagesCount)
    local page = tonumber(rp.page)
    if H.is_num(pages) and pages > 0 and H.is_num(page) and page > 0 then
        pcall(function()
            lv:persistServerProgressToShortcut(book_cache_id, volume_folder, volume,
                math.min(page / pages, 1), bookinfo)
        end)
    end
    -- 系列快捷方式补建: 该系列从未打开过时书架首页没有它的 .html(系列快捷方式
    -- 只在书架菜单点开时创建), 历史同步顺带补上(addBookShortcut 幂等, 已存在零写入)
    pcall(function()
        lv.book_browser:addBookShortcut(bookinfo)
    end)
    local lnk_path = lv.book_browser:writeVolLnk(volume, volume_folder, book_cache_id)
    if not (H.is_str(lnk_path) and util.fileExists(lnk_path)) then
        return nil
    end
    return lnk_path
end

-- 历史合并: 只前进不后退; no_flush 批量写, 由调用方在收尾统一 reduce+flush
function HistorySync.mergeEntry(ReadHistory, lnk_path, ts)
    local existing_time
    if ReadHistory.getIndexByFile then
        local index = ReadHistory:getIndexByFile(lnk_path)
        local item = index and ReadHistory.hist and ReadHistory.hist[index]
        existing_time = item and item.time or nil
    end
    if not HistorySync.shouldBackfill(existing_time, ts) then
        return false
    end
    if not ReadHistory.addItem then
        return false
    end
    ReadHistory:addItem(lnk_path, ts, true)
    return true
end

-- 主流程: 子进程拉取 → UI 线程分块落地(每块 3 条让出主循环) → 历史合并 →
-- 统一落盘 + 单次目录重绘 + 汇总通知
function HistorySync.sync(lv)
    if not (H.is_tbl(lv) and H.is_tbl(lv.book_browser)) then
        MessageBox:notice("书架未初始化, 请先打开书架")
        return
    end
    if not NetworkMgr:isConnected() then
        MessageBox:notice("当前离线, 同步阅读历史需要联网")
        return
    end
    local settings = Backend:getSettings()
    local limit = H.is_num(settings.history_sync_limit) and settings.history_sync_limit or DEFAULT_LIMIT
    local added, skipped_local, skipped_missing = 0, 0, 0
    -- fork 前关库: 子进程只做 HTTP+JSON(与 syncAllVolumesServerProgress 同款)
    Backend:closeDbManager()
    TaskQueue.getChannel("sync", 1):push(function()
        local ok, resp = pcall(Backend.getRecentReadingBooks, Backend)
        if not (ok and H.is_tbl(resp) and resp.type == "SUCCESS") then
            return nil
        end
        return resp.body
    end, function(ok, books)
        if not ok or books == nil then
            MessageBox:notice("同步失败: 无法获取服务器阅读进度")
            return
        end
        local candidates = HistorySync.filterReadingBooks(books, limit)
        if #candidates == 0 then
            MessageBox:notice("服务器没有在读书目可同步")
            return
        end
        local idx = 1
        local function step()
            local last = math.min(idx + 2, #candidates)
            while idx <= last do
                local book = candidates[idx]
                idx = idx + 1
                local lnk_path = HistorySync.applyOne(lv, book)
                if lnk_path then
                    local ReadHistory = require("readhistory")
                    if HistorySync.mergeEntry(ReadHistory, lnk_path,
                        HistorySync.isoToEpoch(book.readProgress.lastModified)) then
                        added = added + 1
                    else
                        skipped_local = skipped_local + 1
                    end
                else
                    skipped_missing = skipped_missing + 1
                end
            end
            if idx <= #candidates then
                UIManager:scheduleIn(0.05, step)
                return
            end
            -- 收尾: 历史落盘(_reduce 裁剪超限旧条目)+ 目录行刷新
            pcall(function()
                local ReadHistory = require("readhistory")
                if ReadHistory._reduce and ReadHistory._flush then
                    ReadHistory:_reduce()
                    ReadHistory:_flush()
                end
            end)
            if H.is_tbl(lv.book_browser) then
                lv.book_browser:scheduleCoalescedRefresh()
            end
            local parts = { string.format("历史同步完成: 新增 %d 条", added) }
            if skipped_local > 0 then
                parts[#parts + 1] = string.format("本地已较新 %d 条", skipped_local)
            end
            if skipped_missing > 0 then
                parts[#parts + 1] = string.format("不在书架 %d 条", skipped_missing)
            end
            MessageBox:notice(table.concat(parts, ", "))
        end
        step()
    end, {timeout = 60, tag = "history_sync"})
end

return HistorySync
