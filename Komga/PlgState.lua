--[[
Komga/PlgState.lua — LibraryView 运行时状态单一来源

字段默认值集中声明于此; libraryState() 返回带默认值的新状态表。
状态仍挂在 LibraryView 表上(历史调用面 self.xxx 不变)。
]]

local M = {}

local FIELDS = {
    disk_available = nil,
    -- record the current reading items
    selected_item = nil,
    book_toc = nil,
    ui_refresh_time = os.time(),
    displayed_chapter = nil,
    readerui_is_showing = nil,
    volume_reading = nil, -- 当前阅读是否为分卷快捷方式进入的 EPUB（用于 TOC 决策）
    chapter_call_event = nil,
    volume_reading_index = nil, -- 当前正读的分卷卷号（openVolumeShortcut 记录, 翻章后仍指向卷）
    volume_pages = nil,         -- 当前卷总页数快照（showReaderUI 记录）
    volume_bookId = nil,        -- 当前卷 bookId（翻章后 displayed_chapter 可能丢失）
    progress_sync_busy = nil,   -- 进度上传锁
    progress_sync_pending = nil,-- 待上传的合并进度（仅保留最新一条）
    resume_goto_frac = nil,     -- 自动续读目标(漫画:整卷比例 0..1; EPUB:目标章内比例 0..1), 打开后跳转
    _last_epub_pos = nil,       -- 最近一次 EPUB 阅读位置 {bookId, number=内部章节, frac=章内比例}(本地断点)
    volume_lnk_path = nil,      -- 当前卷快捷方式路径(openVolumeShortcut 记录; 上传/续读时把服务器进度落盘到其 sidecar)
    _last_epub_server_frac = nil, -- 最近一次服务器空间整卷比例 {bookId, frac 0..1}(供快捷方式显示正确百分比)
    -- menu mode
    book_menu = nil,
    -- file browser mode
    book_browser = nil,
    book_browser_homedir = nil
}

function M.libraryState()
    local t = {}
    for k, v in pairs(FIELDS) do
        t[k] = v
    end
    return t
end

-- 重置可变阅读状态(保留菜单/浏览器等 UI 字段)
function M.resetReading(t)
    t.displayed_chapter = nil
    t.readerui_is_showing = nil
    t.volume_reading = nil
    t.chapter_call_event = nil
    t.volume_reading_index = nil
    t.volume_pages = nil
    t.volume_bookId = nil
    t.progress_sync_busy = nil
    t.progress_sync_pending = nil
    t.resume_goto_frac = nil
    t._last_epub_pos = nil
    t.volume_lnk_path = nil
    t._last_epub_server_frac = nil
end

return M
