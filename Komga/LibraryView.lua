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
local MessageBox = require("Komga/MessageBox")
local H = require("Komga/Helper")

-- 临时调试: 记录点击打开流程 (诊断完成后删除)
local function debug_log(...)
    local ok, file = pcall(io.open, "/Users/hchsoon/Library/Application Support/koreader/komga_ui_debug.log", "a")
    if ok and file then
        file:write(os.date("[%H:%M:%S] ") .. table.concat({...}, " ") .. "\n")
        file:close()
    end
end

local LibraryView = {
    disk_available = nil,
    -- record the current reading items
    selected_item = nil,
    book_toc = nil,
    ui_refresh_time = os.time(),
    displayed_chapter = nil,
    readerui_is_showing = nil,
    volume_reading = nil, -- 当前阅读是否为分卷快捷方式进入的 EPUB（用于 TOC 决策）
    chapter_call_event = nil,
    -- menu mode
    book_menu = nil,
    -- file browser mode
    book_browser = nil,
    book_browser_homedir = nil
}

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
    if self.book_menu then
        self.book_menu:onRefreshLibrary()
    end
end

function LibraryView:closeMenu()
    if self.book_menu then
        self.book_menu:onClose()
    end
end

function LibraryView:openInstalledReadSource()

    local setting_data = Backend:getSettings()
    local history_lines = setting_data.servers_history or {}
    local setting_url = tostring(setting_data.setting_url)
    if not history_lines[1] then
        history_lines = {}
    end

    local description = [[
        (书架与接口地址关联，设置格式符合 RFC3986，认证信息如有特殊字符需要 URL 编码)  示例:
        → 服务器版    http://192.168.1.18:10102/reader3
    ]]

    local dialog
    local reset_callback
    local history_cur = 0
    local history_lines_len = #history_lines
    if history_lines_len > 0 then
        -- only display the last 3 lines
        local servers_history_str = table.concat(history_lines, '\n', math.max(1, #history_lines - 2))
        description = description .. string.format("\n历史记录(%s)：\n%s", history_lines_len, servers_history_str)

        reset_callback = function()
            history_cur = history_cur + 1
            if history_cur > #history_lines then
                history_cur = 1
            end
            dialog.button_table:getButtonById("reset"):enable()
            dialog:refreshButtons()
            return history_lines[history_cur]
        end
    end

    local save_callback = function(input_text)
        if H.is_str(input_text) then
            local new_setting_url = util.trim(input_text)
            return Backend:HandleResponse(Backend:setEndpointUrl(new_setting_url), function(data)
                if not self.book_menu then
                    return true
                end
                self.book_menu.item_table = self.book_menu:generateEmptyViewItemTable()
                self.book_menu.multilines_show_more_text = true
                self.book_menu.items_per_page = 1
                self.book_menu:updateItems()
                self.book_menu:onRefreshLibrary()
                return true
            end, function(err_msg)
                MessageBox:notice('设置失败：' .. tostring(err_msg))
                return false
            end)
        end
        MessageBox:notice('输入为空')
        return false
    end

    dialog = MessageBox:input(nil, nil, {
        title = "设置阅读 API 接口地址",
        input = setting_url,
        description = description,
        use_available_height = true,
        fullscreen = true,
        condensed = true,
        save_callback = save_callback,
        allow_newline = false,
        reset_button_text = '填入历史',
        reset_callback = reset_callback
    })

    if H.is_func(reset_callback) then
        dialog.button_table:getButtonById("reset"):enable()
        dialog:refreshButtons()
    end
end

function LibraryView:openBrowserMenu(file)
    self:getInstance()
    self:getBrowserWidget()
    -- 分卷快捷方式分流到卷级菜单（此入口仅对 /Komga漫画/ 下的文件触发）
    if H.is_str(file) and file:find("\u{200B}.html", 1, true) then
        local customedata = self.book_browser:getCustomMateData(file)
        if H.is_tbl(customedata) and customedata.type == 'volume' then
            self:openVolumeBrowserMenu(file, customedata)
            return
        end
    end
    local dialog
    local buttons = {{{
        text = "清空书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("是否清除所有书籍快捷方式?", function(result)
                if result then
                    local browser_homedir = self:getBrowserHomeDir(true)
                    if self:deleteFile(browser_homedir) then
                        MessageBox:notice("已清除")
                    end
                end
            end, {
                ok_text = "清除",
                cancel_text = "取消"
            })
        end
    }}, {{
        text = "修复书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            self.book_browser:verifyBooksMetadata()
        end
    }}, {{
        text = "更换书籍封面",
        callback = function()
            local ui = FileManager.instance or ReaderUI.instance
            if file and ui and ui.bookinfo then
                UIManager:close(dialog)
                local custom_book_cover = DocSettings:findCustomCoverFile(file)
                if custom_book_cover and util.fileExists(custom_book_cover) then
                    util.removeFile(custom_book_cover)
                end

                local DocumentRegistry = require("document/documentregistry")
                local PathChooser = require("ui/widget/pathchooser")
                local path_chooser = PathChooser:new{
                    select_directory = false,
                    path = H.getHomeDir(),
                    file_filter = function(filename)
                        return DocumentRegistry:isImageFile(filename)
                    end,
                    onConfirm = function(image_file)
                        if DocSettings:flushCustomCover(file, image_file) then
                            self.book_browser:emitMetadataChanged(file)
                        end
                    end
                }
                UIManager:show(path_chooser)
            else
                MessageBox:notice("操作失败: 仅能在文件浏览器下操作")
            end
        end
    }}, {{
        text = "更多设置",
        callback = function()
            UIManager:close(dialog)
            self:openMenu()
        end
    }}}

    dialog = require("ui/widget/buttondialog"):new{
        title = "Komga 设置",
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }

    UIManager:show(dialog)
end

function LibraryView:openMenu()
    local dialog
    self:getInstance()
    local settings = Backend:getSettings()
    local buttons = {{{
        text = Icons.FA_GLOBE .. " Komga WEB地址",
        callback = function()
            UIManager:close(dialog)
            self:openInstalledReadSource()
        end
    }}, {{
        text = string.format("%s 流式漫画模式 %s", Icons.FA_BOOK,
            (settings.stream_image_view and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "当前模式: %s \r\n \r\n缓存模式: 边看边下载。\n缺点：占空间。\n优点：预加载后相对流畅。\r\n \r\n流式：不下载到磁盘。\n缺点：对网络要求较高且画质缺少优化，需要下载任一章节后才能开启（建议服务端开启图片代理）。\n优点：不占空间。",
                (settings.stream_image_view and '[流式]' or '[缓存]')), function(result)
                if result then
                    settings.stream_image_view = not settings.stream_image_view or nil
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice("设置成功")
                        self:closeMenu()
                    end, function(err_msg)
                        MessageBox:error('设置失败:', err_msg)
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end
    }}, {{
        text = string.format("%s 自动生成快捷方式 %s", Icons.FA_FOLDER,
            (settings.disable_browser and Icons.UNICODE_STAR_OUTLINE or Icons.UNICODE_STAR)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "自动生成快捷方式：%s \r\n \r\n 打开书籍目录时自动在文件浏览器 Home 目录中生成对应书籍快捷方式，支持封面显示, 关闭后可在书架菜单手动生成",
                (settings.disable_browser and '[关闭]' or '[开启]')), function(result)
                if result then
                    local ok_msg = "设置已开启"
                    settings.disable_browser = not settings.disable_browser or nil
                    if settings.disable_browser then
                        ok_msg = "设置已关闭，请手动删除目录"
                    end
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice(ok_msg)
                    end, function(err_msg)
                        MessageBox:error('设置失败:', err_msg)
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end
    }}, {{
        text = string.format("%s Clear all caches", Icons.FA_TIMES),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(
                "是否清空本地书架所有已缓存章节与阅读记录？\r\n（刷新会重新下载）",
                function(result)
                    if result then
                        Backend:closeDbManager()
                        MessageBox:loading("清除中", function()
                            return Backend:cleanAllBookCaches()
                        end, function(state, response)
                            if state == true then
                                Backend:HandleResponse(response, function(data)
                                    settings.servers_history = {}
                                    Backend:saveSettings(settings)
                                    MessageBox:notice("已清除")
                                    self:closeMenu()
                                end, function(err_msg)
                                    MessageBox:error('操作失败：', tostring(err_msg))
                                end)
                            end
                        end)
                    end
                end, {
                    ok_text = "清空",
                    cancel_text = "取消"
                })
        end
    }}, {{
        text = Icons.FA_QUESTION_CIRCLE .. ' ' .. "关于/更新",
        callback = function()
            UIManager:close(dialog)
            local about_txt = [[
-- 清风不识字，何故乱翻书 --

简介：
一个在 KOReader 中阅读 Komga 漫画库的插件，适配阅读 3.0，支持手机 APP 和服务器版本。初衷是 Kindle 的浏览器体验不佳，目的是部分替代受限设备的浏览器，实现流畅的网文阅读，提升老设备体验。

操作：
列表支持下拉或 Home 键刷新，右键列表菜单 / Menu 键左上角菜单，阅读界面下拉菜单有返回选项，书架和目录可绑定手势使用。

章节页面图标说明:
%1 可下载  %2 已阅读  %3 阅读进度

帮助改进：
请到 Github：hchsoon/komga.koplugin 反馈 issues

版本: ver_%4]]
            local curren_version = "1.0.0"
            about_txt = T(about_txt, Icons.FA_DOWNLOAD, Icons.FA_CHECK_CIRCLE, Icons.FA_THUMB_TACK, curren_version)
            MessageBox:custom({
                text = about_txt,
                alignment = "left"
            })
        end
    }}}

    if not Device:isTouchDevice() then
        table.insert(buttons, 4, {{
            text = Icons.FA_EXCLAMATION_CIRCLE .. ' ' .. " 同步书架",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshLibrary()
            end
        }})
    end

    if not self.disk_available then
        local cache_dir = H.getTempDirectory()
        local disk_use = util.diskUsage(cache_dir)
        if disk_use and disk_use.available then
            self.disk_available = disk_use.available / 1073741824
        end
    end

    dialog = require("ui/widget/buttondialog"):new{
        title = string.format(Icons.FA_DATABASE .. " 剩余空间: %.1f G", self.disk_available or -1),
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }

    UIManager:show(dialog)
end

-- exit readerUI,  closing the at readerUI、FileManager the same time app will exit
-- readerUI -> ReturnKomgaChapterListing event -> show ChapterListing -> close ->show LibraryView ->close -> ? 
function LibraryView:openKomgaFolder(path, focused_file, selected_files, done_callback)
    debug_log("OPENKOMGAFOLDER entry path:", tostring(path))
    UIManager:nextTick(function()
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
            self.readerui_is_showing = false
        end
        debug_log("OPENKOMGAFOLDER before reinit t=", os.time())
        if FileManager.instance then
            FileManager.instance:reinit(path, focused_file, selected_files)
        else
            FileManager:showFiles(path, focused_file, selected_files)
        end
        debug_log("OPENKOMGAFOLDER after reinit t=", os.time())
        if FileManager.instance and path then
            FileManager.instance:updateTitleBarPath(path)
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
    local bookinfo = Backend:getBookInfoCache(book_cache_id)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name)) then
        MessageBox:notice("书籍不存在于书架,请刷新同步")
        return
    end
    local chapters = Backend:getBookChapterCache(book_cache_id)
    debug_log("OPENSERIE chapters:", tostring(H.is_tbl(chapters) and #chapters or 0))
    if H.is_tbl(chapters) and #chapters > 0 then
        debug_log("OPENSERIE direct->doOpenSeriesVolumesFolder")
        self:doOpenSeriesVolumesFolder(book_cache_id, bookinfo)
        return
    end
    debug_log("OPENSERIE -> sync 分卷目录")
    -- 分卷未同步, 先刷新目录
    if not NetworkMgr:isConnected() then
        MessageBox:notice("分卷数据未同步且当前无网络连接")
        return
    end
    Backend:closeDbManager()
    MessageBox:loading("正在同步分卷目录", function()
        -- 子进程内任务必须返回可序列化的值, 否则 Trapper 反序列化失败回调会拿到 nil(显示"Response is nil")
        local ok, err_or_res = pcall(function()
            return Backend:refreshChaptersCache({
                bookUrl = bookinfo.bookUrl,
                cache_id = book_cache_id,
                name = bookinfo.name,
                author = bookinfo.author,
                cacheExt = bookinfo.cacheExt
            })
        end)
        if not ok then
            -- 记录真实错误到日志文件, 便于排查
            self:logSyncError(tostring(err_or_res))
            return { type = 'ERROR', message = '同步异常: ' .. tostring(err_or_res) }
        end
        return err_or_res
    end, function(state, response)
        if state ~= true then
            return
        end
        if response == nil then
            -- 子进程 fork 后无输出(在 macOS 上 fork 后的子进程网络/数据库状态可能异常):
            -- 记录痕迹并回退到本进程内同步, 保证能完成
            self:logSyncError("<nil response: subprocess produced no output, falling back to in-process sync>")
            self:syncChaptersInProcess(book_cache_id, bookinfo)
            return
        end
        Backend:HandleResponse(response, function(data)
            self:doOpenSeriesVolumesFolder(book_cache_id, bookinfo)
        end, function(err_msg)
            MessageBox:error('同步分卷失败: ' .. tostring(err_msg))
        end)
    end)
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
        return Backend:refreshChaptersCache({
            bookUrl = bookinfo.bookUrl,
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
    self.book_browser:syncSeriesVolumes(book_cache_id, bookinfo, volume_folder)
    debug_log("DOOPENSERIE volume_folder:", tostring(volume_folder))
    self:openKomgaFolder(volume_folder)
end

-- 分卷快捷方式点击: 镜像 ChapterListing:onMenuChoice 的流式/缓存分流
function LibraryView:openVolumeShortcut(book_cache_id, chapters_index, lnk_path)
    self:getInstance()
    self:getBrowserWidget()
    if not (H.is_str(book_cache_id) and H.is_num(chapters_index)) then
        MessageBox:notice("openVolumeShortcut parameter error")
        return
    end
    local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
    debug_log("OPENVOLUME idx:", tostring(chapters_index), "mediaType:", tostring(chapter and chapter.mediaType),
        "cacheFilePath:", tostring(chapter and chapter.cacheFilePath))
    if not (H.is_tbl(chapter) and H.is_num(chapter.chapters_index)) then
        MessageBox:notice("分卷数据不存在,请返回书架刷新同步")
        return
    end
    -- 分卷快捷方式进入的 EPUB 阅读: 标记为分卷阅读, 目录按钮显示 EPUB 原生目录而非系列目录
    if chapter.mediaType == "EPUB" then
        chapter.volume_read = true
    end
    -- 刷新该卷快捷方式的进度显示
    if H.is_str(lnk_path) and util.fileExists(lnk_path) then
        self:refreshVolumeShortcutProgress(book_cache_id, chapters_index, lnk_path)
    end

    if Backend:getSettings().stream_image_view == true and chapter.mediaType ~= "EPUB" then
        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
            MessageBox:notice("书籍数据缺失")
            return
        end
        local volume_dir = H.is_str(lnk_path) and select(1, util.splitFilePathName(lnk_path)) or nil
        NetworkMgr:runWhenOnline(function()
            UIManager:nextTick(function()
                local StreamImageView = require("Komga/StreamImageView")
                StreamImageView:fetchAndShow({
                    bookinfo = bookinfo,
                    chapter = chapter,
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
        self:loadAndRenderChapter(chapter)
    end
end

-- 读完返回文件浏览器时, 刷新当前分卷快捷方式的进度显示
function LibraryView:refreshReadVolumeShortcut(book_cache_id, chapters_index)
    self:getBrowserWidget()
    if not (H.is_str(book_cache_id) and H.is_num(chapters_index)) then
        return
    end
    local file_manager = FileManager.instance
    local dir = file_manager and file_manager.file_chooser and file_manager.file_chooser.path
    if not (H.is_str(dir) and dir:find("/Komga\u{200B}漫画/", 1, true)) then
        return
    end
    local found
    util.findFiles(dir, function(fullpath, name)
        if found then
            return
        end
        if util.fileExists(fullpath) and name:find("\u{200B}.html", 1, true) then
            local customedata = self.book_browser:getCustomMateData(fullpath)
            if H.is_tbl(customedata) and customedata.type == 'volume' and
                customedata.chapters_index == chapters_index then
                local doc_settings = DocSettings:open(fullpath)
                if doc_settings:readSetting("book_cache_id") == book_cache_id then
                    found = fullpath
                end
            end
        end
    end, false)
    if found then
        self.book_browser:refreshVolumeMetadata(nil, found, book_cache_id, chapters_index)
    end
end

-- 轻量刷新分卷快捷方式进度（doc_props）
function LibraryView:refreshVolumeShortcutProgress(book_cache_id, chapters_index, lnk_path)
    self:getBrowserWidget()
    if not (H.is_str(book_cache_id) and H.is_num(chapters_index) and H.is_str(lnk_path) and
        util.fileExists(lnk_path)) then
        return
    end
    self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, chapters_index)
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
    local chapters_index = customedata and customedata.chapters_index
    if not H.is_num(chapters_index) then
        chapters_index = DocSettings:open(lnk_path):readSetting("chapters_index")
    end
    if not (H.is_str(book_cache_id) and H.is_num(chapters_index)) then
        MessageBox:notice("分卷快捷方式数据不完整")
        return
    end
    local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
    local is_read = H.is_tbl(chapter) and chapter.isRead == true
    local isDownLoaded = H.is_tbl(chapter) and chapter.isDownLoaded == true
    local dialog
    local buttons = {{{
        text = table.concat({Icons.FA_CHECK_CIRCLE, (is_read and ' 取消' or ' 标记'), "已读"}),
        callback = function()
            UIManager:close(dialog)
            Backend:HandleResponse(Backend:MarkReadChapter({
                chapters_index = chapters_index,
                chapter_page = 0,
                isRead = is_read,
                book_cache_id = book_cache_id
            }), function(data)
                self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, chapters_index)
                self.book_browser:refreshItems()
            end, function(err_msg)
                MessageBox:error('标记失败 ', err_msg)
            end)
        end
    }}, {{
        text = table.concat({Icons.FA_DOWNLOAD, (isDownLoaded and ' 刷新' or ' 下载'), '分卷'}),
        callback = function()
            UIManager:close(dialog)
            Backend:HandleResponse(Backend:ChangeChapterCache({
                chapters_index = chapters_index,
                cacheFilePath = chapter.cacheFilePath,
                book_cache_id = book_cache_id,
                isDownLoaded = isDownLoaded,
                bookUrl = chapter.bookUrl,
                title = chapter
            }), function(data)
                self.book_browser:refreshVolumeMetadata(nil, lnk_path, book_cache_id, chapters_index)
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
            self:syncVolumeProgressShow(book_cache_id, chapters_index)
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
function LibraryView:syncVolumeProgressShow(book_cache_id, chapters_index)
    self:getBrowserWidget()
    local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
    if not (H.is_tbl(chapter) and H.is_num(chapter.pages)) then
        MessageBox:notice("分卷数据不存在")
        return
    end
    local cache_chapter = Backend:getCacheChapterFilePath(chapter)
    chapter.current_page = 0
    if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) then
        local cache_doc_settings = DocSettings:open(cache_chapter.cacheFilePath)
        chapter.current_page = tonumber(cache_doc_settings:readSetting("last_page")) or 0
    end
    Backend:closeDbManager()
    MessageBox:loading("同步中 ", function()
        local response = Backend:saveBookProgress(chapter)
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

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)

    print("Index is ...", chapter.chapters_index)
    print("Cache chapter is ...", cache_chapter.cacheFilePath)
    print("LOADRENDER cachehit:", tostring(cache_chapter.cacheFilePath))
    debug_log("LOADRENDER idx:", tostring(chapter.chapters_index), "bookId:", tostring(chapter.bookId),
        "cachehit:", tostring(cache_chapter and cache_chapter.cacheFilePath))
    if (H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath)) then
        -- 缓存命中分支也要传递分卷阅读标记, 否则目录按钮会退回系列目录而非 EPUB 原生目录
        cache_chapter.volume_read = chapter.volume_read
        self:showReaderUI(cache_chapter)
    else
        -- Backend:closeDbManager()
        -- dismissable=true: 下载中可取消, 避免慢下载/挂起时卡住界面无法点击其他分卷
        return MessageBox:loading("正在下载正文", function()
            return Backend:downloadChapter(chapter)
        end, function(state, response)
            if state == false then
                Backend:show_notice("已取消下载")
                return
            end
            if state == true then
                Backend:HandleResponse(response, function(data)
                    if not H.is_tbl(data) or not H.is_str(data.cacheFilePath) then
                        MessageBox:error('下载失败')
                        return
                    end
                    data.volume_read = chapter.volume_read
                    self:showReaderUI(data)
                end, function(err_msg)
                    Backend:show_notice("请检查并刷新书架")
                    MessageBox:error(err_msg or '错误')
                end)
            end

        end, {dismissable = true})
    end
end

function LibraryView:ReaderUIEventCallback(chapter_call_event)
    if not (H.is_str(chapter_call_event) and H.is_tbl(self.displayed_chapter)) then
        return
    end
    local chapter = self.displayed_chapter
    self.chapter_call_event = chapter_call_event
    chapter.call_event = chapter_call_event

    local nextChapter = Backend:findNextChapter({
        chapters_index = chapter.chapters_index,
        call_event = chapter.call_event,
        book_cache_id = chapter.book_cache_id,
        bookId = chapter.bookId,
        totalChapterNum = chapter.totalChapterNum
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
        nextChapter.totalChapterNum = chapter.totalChapterNum
        self:loadAndRenderChapter(nextChapter)
    else
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
    chapter.totalChapterNum = Backend:getEpubChapterCount(chapter.bookId)
    -- 兜底: 分卷类型可能因翻页/换章节而丢失, 由缓存文件扩展名推断 EPUB
    if chapter.mediaType == nil and H.is_str(chapter.cacheFilePath) then
        local _, ext = util.splitFileNameSuffix(chapter.cacheFilePath)
        if ext and ext:lower() == "xhtml" then
            chapter.mediaType = "EPUB"
        end
    end
    self.displayed_chapter = chapter
    -- 记录当前阅读是否为分卷快捷方式进入（TOC 决策依据）
    self.volume_reading = chapter.volume_read == true
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    print("SHOWREADER path:", book_path, "ReaderUI.instance:", tostring(ReaderUI.instance))
    debug_log("SHOWREADER path:", tostring(book_path), "ReaderUI.instance:", tostring(ReaderUI.instance))
    if self.book_toc then
        UIManager:close(self.book_toc)
    end
    if ReaderUI.instance then
        debug_log("SHOWREADER -> switchDocument")
        ReaderUI.instance:switchDocument(book_path, true)
    else
        debug_log("SHOWREADER -> ReaderUI:showReader")
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(book_path, nil, true)
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
            chapters_index = epub_chapter.chapters_index,
            text = epub_chapter.title or string.format('章节 %d', epub_chapter.chapters_index),
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
        if item.chapters_index then
            print("TOCJUMP tap index:", item.chapters_index)
            print("TOCJUMP chapter fields:", chapter.book_cache_id, chapter.bookId,
                tostring(chapter.name), "cur_cache:", tostring(chapter.cacheFilePath))
            volume_toc_menu:onClose()
            chapter.chapters_index = item.chapters_index
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

function LibraryView:initializeRegisterEvent(parent_ref)
    local DocSettings = require("docsettings")
    local FileManager = require("apps/filemanager/filemanager")
    local util = require("util")
    local logger = require("logger")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local ChapterListing = require("Komga/ChapterListing")
    local Backend = require("Komga/Backend")
    local H = require("Komga/Helper")

    local library_view_ref = self

    local is_komga_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find('/cache/komga.cache/', 1, true) or false
    end
    local is_komga_browser_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:find("/Komga\u{200B}漫画/", 1, true) or false
    end
    local get_chapter_event = function()
        if library_view_ref.instance then
            return library_view_ref.instance.chapter_call_event
        end
    end

    function parent_ref:onShowKomgaLibraryView()
        -- FileManager menu only
        if not (self.ui and self.ui.document) then
            self:openLibraryView()
        end
        return true
    end

    function parent_ref:openLastReadChapter(book_cache_id)
        library_view_ref:getInstance()
        if not library_view_ref.instance then
            logger.warn("openLastReadChapter LibraryView instance not loaded")
            return
        end
        if not H.is_str(book_cache_id) then
            MessageBox:notice("openLastReadChapter parameter error")
            return
        end
        local last_read_chapter = Backend:getLastReadChapter(book_cache_id)
        if H.is_num(last_read_chapter) then
            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
                -- no sync
                self:onShowKomgaLibraryView()
                MessageBox:notice("书籍不存在于书架,请刷新同步")
                return
            end

            local book_toc_instance = library_view_ref.instance.book_toc
            if not (book_toc_instance and H.is_tbl(book_toc_instance.bookinfo) and book_toc_instance.bookinfo.cache_id ==
                book_cache_id) then
                library_view_ref.instance.book_toc = ChapterListing:fetchAndShow({
                    cache_id = bookinfo.cache_id,
                    bookUrl = bookinfo.bookUrl,
                    durChapterIndex = bookinfo.durChapterIndex,
                    name = bookinfo.name,
                    author = bookinfo.author,
                    cacheExt = bookinfo.cacheExt,
                    origin = bookinfo.origin,
                    originName = bookinfo.originName,
                    originOrder = bookinfo.originOrder
                }, function()
                end, function(chapter)
                    print("Predownload 4.")
                    library_view_ref.instance:loadAndRenderChapter(chapter)
                end, true, true)
            end

            local chapters_index = last_read_chapter - 1
            if chapters_index < 0 then
                chapters_index = 0
            end
            local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
            if H.is_tbl(chapter) and chapter.chapters_index then
                -- jump to the reading position
                chapter.call_event = "next"
                print("Predownload 1.")
                library_view_ref.instance:loadAndRenderChapter(chapter)
            else
                -- chapter does not exist, request refresh
                if library_view_ref.instance.book_toc then
                    UIManager:show(library_view_ref.instance.book_toc)
                end
                MessageBox:notice('请同步刷新目录数据')
            end
            return true
        end

        local dir = library_view_ref.instance:getBrowserHomeDir()
        self:onShowKomgaToc(book_cache_id, function()
            -- Sometimes LibraryView instance may not start
            library_view_ref:openKomgaFolder(dir)
        end)
    end

    function parent_ref:onShowKomgaToc(book_cache_id, onReturnCallBack)
        library_view_ref:getInstance()
        if not library_view_ref.instance then
            logger.warn("ShowKomgaToc LibraryView instance not loaded")
            return true
        end
        if not book_cache_id then
            if library_view_ref.instance.displayed_chapter then
                book_cache_id = library_view_ref.instance.displayed_chapter.book_cache_id
            elseif library_view_ref.instance.selected_item then
                book_cache_id = library_view_ref.instance.selected_item.cache_id
            end
        end
        if not book_cache_id then
            logger.warn("ShowKomgaToc book_cache_id not obtained")
            return true
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            MessageBox:error('书籍不存在于当前 Komga 漫画库或已被删除, 请检查并同步漫画库')
            return
        end

        if not H.is_func(onReturnCallBack) then
            onReturnCallBack = function()
                self:openLibraryView()
            end
        end

        local fetch_show_chapter = function()
            library_view_ref.instance.book_toc = ChapterListing:fetchAndShow({
                cache_id = bookinfo.cache_id,
                bookUrl = bookinfo.bookUrl,
                durChapterIndex = bookinfo.durChapterIndex,
                name = bookinfo.name,
                author = bookinfo.author,
                cacheExt = bookinfo.cacheExt,
                origin = bookinfo.origin,
                originName = bookinfo.originName,
                originOrder = bookinfo.originOrder
            }, onReturnCallBack, function(chapter)
                -- chapter.chapters_index = 1
                -- chapter.durChapterIndex = 1
                print("Predownload 2.")
                library_view_ref.instance:loadAndRenderChapter(chapter)
            end, true)
        end

        -- If under ReaderUI, exit it first.
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI and ReaderUI.instance then
            library_view_ref:openKomgaFolder(nil, nil, nil, fetch_show_chapter)
        else
            fetch_show_chapter()
        end
        return true
    end

    -- 阅读 EPUB 分卷时, 目录按钮显示分卷自身的内部目录(epubchapters)
    function parent_ref:onShowKomgaVolumeToc()
        library_view_ref:getInstance()
        if not library_view_ref.instance then
            logger.warn("ShowKomgaVolumeToc LibraryView instance not loaded")
            return true
        end
        local chapter = library_view_ref.instance.displayed_chapter
        if not (H.is_tbl(chapter) and H.is_str(chapter.bookId)) then
            logger.warn("ShowKomgaVolumeToc displayed_chapter not available")
            return true
        end
        library_view_ref.instance:showVolumeEpubToc(chapter)
        return true
    end

    local calculate_goto_page = function(chapter_call_event, page_count)
        if chapter_call_event == "next" then
            return 1
        elseif page_count and chapter_call_event == "pre" then
            return page_count
        end
    end
    function parent_ref:onDocSettingsLoad(doc_settings, document)
        if not (doc_settings and doc_settings.data and document) then
            return
        end
        if is_komga_path(document.file) then

            local directory, file_name = util.splitFilePathName(document.file)
            local _, extension = util.splitFileNameSuffix(file_name or "")
            if not (directory and file_name and directory ~= "" and file_name ~= "") then
                return
            end

            local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
            -- document.is_new = nil ? at readerui
            local document_is_new = (document.is_new == true) or doc_settings:readSetting("doc_props") == nil
            if document_is_new then
                doc_settings:saveSetting("komga_doc_is_new", true)
            end

            if util.fileExists(book_defaults_path) then
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                if book_defaults and H.is_tbl(book_defaults.data) then
                    local summary = doc_settings.data.summary -- keep status
                    local book_defaults_data = util.tableDeepCopy(book_defaults.data)
                    for k, v in pairs(book_defaults_data) do
                        doc_settings.data[k] = v
                    end
                    doc_settings.data.doc_path = document.file
                    doc_settings.data.summary = doc_settings.data.summary or summary
                end
            end

            if extension == 'txt' then
                doc_settings.data.txt_preformatted = 0
                doc_settings.data.style_tweaks = doc_settings.data.style_tweaks or {}
                doc_settings.data.style_tweaks.paragraph_whitespace_half = true
                doc_settings.data.style_tweaks.paragraphs_indent = true
                doc_settings.data.css = "./data/fb2.css"
            end

            -- statistics.koplugin
            if document then
                document.is_pic = true
            end
            -- Does it affect the future ？
            --[=[
                    if document_is_new then  
                        local bookinfo = library_view_ref.instance.book_toc.bookinfo
                        doc_settings.data.doc_props = doc_settings.data.doc_props or {}
                        doc_settings.data.doc_props.title = bookinfo.name or "N/A"
                        doc_settings.data.doc_props.authors = bookinfo.author or "N/A"
                    end
                ]=]

            -- current_page == nil
            -- self.ui.document:getPageCount() unreliable, sometimes equal to 0
            local chapter_call_event = get_chapter_event()
            local page_count = doc_settings:readSetting("doc_pages") or 99999
            -- koreader some cases is goto last_page
            local page_number = calculate_goto_page(chapter_call_event, page_count)
            if H.is_num(page_number) then
                doc_settings.data.last_page = page_number
            end

        elseif is_komga_browser_path(document.file) and doc_settings.data then
            doc_settings.data.provider = "komga"
        end
    end
    -- or UIManager:flushSettings() --onFlushSettings
    function parent_ref:onSaveSettings()
        if not (self.ui and self.ui.doc_settings) then
            return
        end
        local filepath = self.ui.document and self.ui.document.file or self.ui.doc_settings:readSetting("doc_path")
        if is_komga_path(filepath) then

            local directory, file_name = util.splitFilePathName(filepath)
            if not is_komga_path(directory) then
                return
            end
            -- logger.dbg("Komga: Saving reader settings...")
            if self.ui.doc_settings and type(self.ui.doc_settings.data) == 'table' then
                local persisted_settings_keys = require("Komga/BookMetaData")
                local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                local doc_settings_data = util.tableDeepCopy(self.ui.doc_settings.data)
                local is_updated

                for k, v in pairs(doc_settings_data) do
                    if persisted_settings_keys[k] and not H.deep_equal(book_defaults.data[k], v) then
                        book_defaults.data[k] = v
                        is_updated = true
                        -- logger.info("onSaveSettings save k v", k, v)
                    end
                end
                if is_updated == true then
                    book_defaults:flush()
                end
            end
        elseif is_komga_browser_path(nil, self.ui) and self.ui.doc_settings then
            self.ui.doc_settings.data.provider = "komga"
        end
    end

    -- .cbz call twice ?
    function parent_ref:onReaderReady(doc_settings)
        -- logger.dbg("document.is_pic",self.ui.document.is_pic)
        -- logger.dbg(doc_settings.data.summary.status)
        if not (doc_settings and doc_settings.data and self.ui) then
            return
        end

        if not is_komga_path(nil, self.ui) then
            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = false
            end
            return
        elseif self.ui.link and self.ui.document then

            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = true
            end

            local chapter_call_event = get_chapter_event()
            if not chapter_call_event then
                return
            end

            local document_is_new =
                (self.ui.document.is_new == true) or doc_settings:readSetting("komga_doc_is_new") == true
            doc_settings:delSetting("komga_doc_is_new")
            if document_is_new and chapter_call_event == "next" then
                return
            end

            local function make_pages_continuous(chapter_event)
                local current_page = self.ui:getCurrentPage()
                if not current_page or current_page == 0 then
                    -- fallback to another method if current_page is unavailable
                    -- self.ui.document.info.has_pages == self.ui.paging
                    if self.ui.paging or (self.ui.document.info and self.ui.document.info.has_pages) then
                        current_page = self.view.state.page
                    else
                        current_page = self.ui.document:getXPointer()
                        current_page = self.ui.document:getPageFromXPointer(current_page)
                    end
                end

                local page_count = self.ui.document:getPageCount()
                if not (H.is_num(page_count) and page_count > 0) then
                    page_count = doc_settings:readSetting("doc_pages")
                end

                local page_number = calculate_goto_page(chapter_event, page_count)

                if H.is_num(page_number) and current_page ~= page_number then
                    self.ui.link:addCurrentLocationToStack()
                    self.ui:handleEvent(Event:new("GotoPage", page_number))
                end
            end
            make_pages_continuous(chapter_call_event)
        end
    end

    function parent_ref:onCloseDocument()
        if is_komga_path(nil, self.ui) then
            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = false
                -- 读完返回时刷新该分卷快捷方式的进度显示
                local displayed_chapter = library_view_ref.instance.displayed_chapter
                if H.is_tbl(displayed_chapter) and H.is_str(displayed_chapter.book_cache_id) and
                    H.is_num(displayed_chapter.chapters_index) then
                    library_view_ref.instance:refreshReadVolumeShortcut(
                        displayed_chapter.book_cache_id, displayed_chapter.chapters_index)
                end
            end
            if not self.patches_ok then
                require("readhistory"):removeItemByPath(self.document.file)
            end
        end
    end

    function parent_ref:onEndOfBook()
        if is_komga_path(nil, self.ui) then
            library_view_ref:getInstance()
            if library_view_ref.instance then
                local chapter_call_event = "next"
                library_view_ref.instance:ReaderUIEventCallback(chapter_call_event)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onStartOfBook()
        if is_komga_path(nil, self.ui) then
            library_view_ref:getInstance()
            if library_view_ref.instance then
                local chapter_call_event = "pre"
                library_view_ref.instance:ReaderUIEventCallback(chapter_call_event)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onShowKomgaBrowserOption(file)
        -- logger.info("Received ShowKomgaBrowserOption event", file)
        library_view_ref:getInstance()
        if FileManager.instance and library_view_ref.instance then
            library_view_ref.instance:openBrowserMenu(file)
        end
    end

    function parent_ref:onSuspend()
        Backend:closeDbManager()
    end

    table.insert(parent_ref.ui, 3, parent_ref)

    function parent_ref:openFile(file)
        debug_log("OPENFILE file:", tostring(file))
        if not H.is_str(file) then
            return
        end
        local function open_regular_file(file)
            local ReaderUI = require("apps/reader/readerui")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(file, nil, true)
        end

        local function getCustomMetaData(filepath)
            local custom_metadata_file = DocSettings:findCustomMetadataFile(filepath)
            return custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
        end
        if not (is_komga_browser_path(file) and file:find("\u{200B}.html", 1, true)) then
            open_regular_file(file)
            return
        end
        -- prioritize using custom matedata book_cache_id
        local doc_settings = DocSettings:open(file)
        local book_cache_id = doc_settings:readSetting("book_cache_id")
        local customedata = getCustomMetaData(file)
        local booktype = customedata and customedata.type
        debug_log("OPENFILE book_cache_id:", tostring(book_cache_id), "booktype:", tostring(booktype))

        if not book_cache_id then
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_config then
                book_cache_id = lnk_config:readSetting("book_cache_id")
            end
        end

        -- 分卷快捷方式: 点击后直接打开该分卷阅读（必须在通用分支之前）
        if booktype == 'volume' and book_cache_id then
            local chapters_index = (customedata and customedata.chapters_index) or
                doc_settings:readSetting("chapters_index")
            debug_log("OPENFILE branch=volume chapters_index:", tostring(chapters_index))
            if H.is_num(chapters_index) then
                library_view_ref:openVolumeShortcut(book_cache_id, chapters_index, file)
                return true
            end
        end

        -- 系列快捷方式: 点击后进入该系列的分卷目录
        if booktype == 'serie' and book_cache_id then
            debug_log("OPENFILE branch=serie -> openSeriesVolumesFolder")
            library_view_ref:openSeriesVolumesFolder(book_cache_id, file)
            return true
        end

        if book_cache_id then
            debug_log("OPENFILE branch=fallback openLastReadChapter")
            local ok, err = pcall(function()
                return self:openLastReadChapter(book_cache_id)
            end)
            if not ok then
                logger.err("fail to open file:", err)
            end
            return true
        else
            debug_log("OPENFILE branch=open_regular_file")
            open_regular_file(file)
        end
    end
end

local function init_book_browser(parent)
    if parent.book_browser then
        return parent.book_browser
    end

    local book_browser = {
        parent = parent
    }

    function book_browser:show_view(focused_file, selected_files)
        local homedir = self.parent:getBrowserHomeDir()
        if not homedir then
            return
        end
        local current_dir = self.parent:getBrowserCurrentDir()
        if current_dir and current_dir == homedir then
            if not self.parent.book_menu then
                self.parent.book_menu = self.parent:getMenuWidget()
            end
            self.parent.book_menu:show_view()
            self.parent.book_menu:refreshItems(true)
            return
        end
        self.parent:openKomgaFolder(homedir, focused_file, selected_files)
    end

    function book_browser:goHome()
        if FileManager.instance then
            FileManager.instance:goHome()
        end
    end

    function book_browser:refreshItems()
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end

    function book_browser:deleteFile(file, is_file)
        self.parent:deleteFile(file, is_file)
    end
    function book_browser:verifyBooksMetadata()
        -- possible cover name change
        local browser_homedir = self.parent:getBrowserHomeDir()
        if not util.directoryExists(browser_homedir) then
            return
        end

        local function is_valid_book_file(fullpath, name)
            return util.fileExists(fullpath) and H.is_str(name) and name:find("\u{200B}.html", 1, true)
        end

        local function get_book_id(fullpath)
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, fullpath)
            if ok and H.is_tbl(lnk_config) and lnk_config.readSetting then
                return lnk_config:readSetting("book_cache_id")
            end
            local doc_settings = DocSettings:open(fullpath)
            return doc_settings:readSetting("book_cache_id")
        end

        util.findFiles(browser_homedir, function(fullpath, name)
            if not is_valid_book_file(fullpath, name) then
                goto continue
            end

            local book_cache_id = get_book_id(fullpath)
            if not book_cache_id then
                self:deleteFile(fullpath, true)
                goto continue
            end

            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                goto continue
            end

            -- 分卷快捷方式走卷级元数据修复，避免被重写为系列
            local customedata = self:getCustomMateData(fullpath)
            local chapters_index = H.is_tbl(customedata) and customedata.chapters_index or nil
            if H.is_tbl(customedata) and customedata.type == 'volume' and H.is_num(chapters_index) then
                self:refreshVolumeMetadata(nil, fullpath, book_cache_id, chapters_index, bookinfo)
            else
                self:refreshBookMetadata(nil, fullpath, bookinfo)
            end
            ::continue::
        end, true)
    end

    function book_browser:wirteLnk(bookinfo, home_dir)
        -- local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("book_browser.wirteLnk: parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local book_name = bookinfo.name
        local book_author = bookinfo.author or "未知作者"

        local book_lnk_name = string.format("%s-%s\u{200B}.html", book_name, book_author)
        book_lnk_name = util.getSafeFilename(book_lnk_name)
        if not book_lnk_name then
            logger.err("book_browser.wirteLnk: getSafeFilename error")
            return
        end
        local book_lnk_path = H.joinPath(home_dir, book_lnk_name)
        if book_lnk_path and util.fileExists(book_lnk_path) then
            return book_lnk_path, book_lnk_name
        end

        local book_lnk_config = Backend:getLuaConfig(book_lnk_path)
        book_lnk_config:saveSetting("book_cache_id", book_cache_id):flush()

        return book_lnk_path, book_lnk_name
    end

    function book_browser:getCustomMateData(filepath)
        local custom_metadata_file = DocSettings:findCustomMetadataFile(filepath)
        return custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
    end

    function book_browser:addBookShortcut(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id and bookinfo.coverUrl) then
            logger.err("addBookShortcut: parameter error")
            return
        end

        local book_lnk_path, book_lnk_name = self:wirteLnk(bookinfo, home_dir)
        if not (book_lnk_path and util.fileExists(book_lnk_path)) then
            logger.err("addBookShortcut: failed to create lnk")
            return
        end

        if not self:getCustomMateData(book_lnk_path) then
            self:refreshBookMetadata(book_lnk_name, book_lnk_path, bookinfo)
        else
            self:bind_provider(book_lnk_path)
        end

        if DocSettings:findCustomCoverFile(book_lnk_path) then
            return
        end

        if not NetworkMgr:isConnected() then
            return
        end
        local book_cache_id = bookinfo.cache_id
        local cover_url =  bookinfo.coverUrl
        if cover_url then
            Backend:runTaskWithRetry(function()
                if DocSettings:findCustomCoverFile(book_lnk_path) then
                    self:emitMetadataChanged(book_lnk_path)
                    return true
                end
            end, 12000, 2000)
            Backend:launchProcess(function()
                local cover_path, cover_name = Backend:download_cover_img(book_cache_id, cover_url)
                if cover_path and util.fileExists(cover_path) then
                    DocSettings:flushCustomCover(book_lnk_path, cover_path)
                end
            end)
        end
    end

    function book_browser:addVolumeShortcut(bookinfo, seriename)
        -- 生成该系列分卷目录并同步各分卷快捷方式（不再写入 .sdr 隐藏目录）
        if not (H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("addVolumeShortcut: parameter error")
            return
        end
        local volume_folder = self:ensureVolumeFolder(bookinfo.cache_id, bookinfo)
        if volume_folder then
            self:syncSeriesVolumes(bookinfo.cache_id, bookinfo, volume_folder)
        end
    end

    function book_browser:wirteVolLnk(chapter, volume_folder, book_cache_id)
        if not (volume_folder and H.is_tbl(chapter) and H.is_num(chapter.chapters_index) and H.is_str(book_cache_id)) then
            logger.err("book_browser.wirteVolLnk: parameter error")
            return
        end
        local chapters_index = chapter.chapters_index
        local chapter_title = (H.is_str(chapter.title) and chapter.title ~= "") and chapter.title or
            "卷" .. tostring(chapters_index)
        -- 卷号补零到 3 位, 避免文件浏览器按文件名排序时 2,10,11... 乱序
        local volume_lnk_name = string.format("%03d-%s\u{200B}.html", chapters_index, chapter_title)
        volume_lnk_name = util.getSafeFilename(volume_lnk_name)
        if not volume_lnk_name then
            logger.err("book_browser.wirteVolLnk: getSafeFilename error")
            return
        end
        local volume_lnk_path = H.joinPath(volume_folder, volume_lnk_name)
        if util.fileExists(volume_lnk_path) then
            return volume_lnk_path, volume_lnk_name
        end
        local volume_lnk_config = Backend:getLuaConfig(volume_lnk_path)
        volume_lnk_config:saveSetting("book_cache_id", book_cache_id):flush()
        return volume_lnk_path, volume_lnk_name
    end

    function book_browser:refreshVolumeMetadata(lnk_name, lnk_path, book_cache_id, chapters_index, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_str(book_cache_id) and
            H.is_num(chapters_index)) then
            logger.err("browser.refreshVolumeMetadata parameter error")
            return
        end
        local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
        if not (H.is_tbl(chapter) and H.is_num(chapter.chapters_index)) then
            logger.err("browser.refreshVolumeMetadata no chapter data:", book_cache_id, chapters_index)
            return
        end
        debug_log("REFRESHVOL idx:", tostring(chapters_index), "t=", os.time())
        bookinfo = bookinfo or Backend:getBookInfoCache(book_cache_id)
        -- pages 缺失时按 0 处理, 仍写入卷级元数据, 保证点击可打开
        local pages = H.is_num(chapter.pages) and chapter.pages or 0
        -- pageno: 已读 -> 满进度; 未读 -> 尽力读缓存文件 last_page
        local pageno = 0
        if chapter.isRead == true then
            pageno = pages
        else
            local cache_chapter = Backend:getCacheChapterFilePath(chapter)
            if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) then
                local last_page = DocSettings:open(cache_chapter.cacheFilePath):readSetting("last_page")
                if H.is_num(last_page) and last_page > 0 and last_page <= pages then
                    pageno = last_page
                end
            end
        end
        local volume_title = (H.is_str(chapter.title) and chapter.title ~= "") and chapter.title or
            (H.is_tbl(bookinfo) and bookinfo.name) or "卷" .. tostring(chapters_index)
        -- 无变化则跳过写入，避免每次进入目录都重写并广播事件
        local custom = nil
        local custom_metadata_file = DocSettings:findCustomMetadataFile(lnk_path)
        if custom_metadata_file then
            local custom_settings = DocSettings.openSettingsFile(custom_metadata_file)
            custom = {
                custom_props = custom_settings:readSetting("custom_props"),
                book_cache_id = custom_settings:readSetting("book_cache_id"),
                chapters_index = custom_settings:readSetting("chapters_index"),
                doc_props = custom_settings:readSetting("doc_props")
            }
        end
        if H.is_tbl(custom) and H.is_tbl(custom.custom_props) and custom.custom_props.type == 'volume' and
            custom.custom_props.chapters_index == chapters_index and
            H.is_tbl(custom.doc_props) and custom.doc_props.pages == pages and custom.doc_props.pageno == pageno and
            custom.book_cache_id == book_cache_id and custom.chapters_index == chapters_index then
            return
        end
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            doc_settings:saveSetting("custom_props", {
                authors = (H.is_tbl(bookinfo) and bookinfo.author) or chapter.author,
                title = volume_title,
                description = (H.is_tbl(bookinfo) and bookinfo.intro) or nil,
                type = "volume",
                chapters_index = chapters_index,
                bookId = chapter.bookId
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("chapters_index", chapters_index)
            doc_settings:saveSetting("doc_props", {
                pages = pages,
                pageno = pageno
            }):flushCustomMetadata(lnk_path)
        end
        -- 主 sidecar 也写入 chapters_index, 便于 openFile 读取
        local lnk_config = Backend:getLuaConfig(lnk_path)
        if lnk_config and lnk_config.readSetting then
            local old_index = lnk_config:readSetting("chapters_index")
            if old_index ~= chapters_index then
                lnk_config:saveSetting("chapters_index", chapters_index):flush()
            end
        end
        self:emitMetadataChanged(lnk_path)
    end

    function book_browser:asyncDownloadVolumeCover(book_cache_id, chapter, lnk_path)
        if not (H.is_str(book_cache_id) and H.is_tbl(chapter) and H.is_str(lnk_path)) then
            return
        end
        if DocSettings:findCustomCoverFile(lnk_path) then
            return
        end
        if not NetworkMgr:isConnected() then
            return
        end
        local cover_url = Backend:getVolumeCoverUrl(chapter.bookId)
        if not cover_url then
            return
        end
        debug_log("ASYNCCOVER start idx:", tostring(chapter.chapters_index), "t=", os.time())
        Backend:runTaskWithRetry(function()
            if DocSettings:findCustomCoverFile(lnk_path) then
                self:emitMetadataChanged(lnk_path)
                return true
            end
        end, 12000, 2000)
        debug_log("ASYNCCOVER before launchProcess idx:", tostring(chapter.chapters_index), "t=", os.time())
        Backend:launchProcess(function()
            local cover_path_no_ext = Backend:getVolumeCoverCachePath(book_cache_id, chapter.chapters_index)
            local cover_path, cover_name = Backend:download_cover_img(book_cache_id, cover_url, cover_path_no_ext)
            if cover_path and util.fileExists(cover_path) then
                DocSettings:flushCustomCover(lnk_path, cover_path)
            end
        end)
        debug_log("ASYNCCOVER after launchProcess idx:", tostring(chapter.chapters_index), "t=", os.time())
    end

    function book_browser:ensureVolumeFolder(book_cache_id, bookinfo)
        if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo) and H.is_str(bookinfo.name)) then
            return nil
        end
        local home_dir = self.parent:getBrowserHomeDir()
        if not home_dir then
            return nil
        end
        local author = (H.is_str(bookinfo.author) and bookinfo.author ~= "") and bookinfo.author or "未知作者"
        -- 目录以 .sdr 结尾, 文件浏览器会将其隐藏, 避免与系列快捷方式(.html)同时显示造成重复。
        -- 注意: 不能直接用 <系列名>-<作者>\u{200B}.sdr, 那是系列快捷方式的封面 sidecar 目录。
        local folder_name = string.format("%s-%s-vol.sdr", bookinfo.name, author)
        folder_name = util.getSafeFilename(folder_name)
        if not folder_name then
            logger.err("ensureVolumeFolder: getSafeFilename error")
            return nil
        end
        local volume_folder = H.joinPath(home_dir, folder_name)
        -- 旧版目录名(<系列名>-<作者>\u{200B}, 无 -vol.sdr 后缀)在浏览器中可见, 迁移到新隐藏命名
        local legacy_folder = H.joinPath(home_dir, util.getSafeFilename(string.format("%s-%s\u{200B}", bookinfo.name, author)))
        if not util.directoryExists(volume_folder) and util.directoryExists(legacy_folder) then
            local ok, err = pcall(os.rename, legacy_folder, volume_folder)
            if not ok then
                logger.err("ensureVolumeFolder: failed to rename legacy folder - " .. tostring(err or "unknown error"))
                return nil
            end
        end
        if not util.directoryExists(volume_folder) then
            local ok, err = pcall(H.checkAndCreateFolder, volume_folder)
            if not (ok and util.directoryExists(volume_folder)) then
                logger.err("ensureVolumeFolder: failed to create folder - " .. tostring(err or "unknown error"))
                return nil
            end
        end
        return volume_folder
    end

    function book_browser:syncSeriesVolumes(book_cache_id, bookinfo, volume_folder)
        if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo) and H.is_str(volume_folder)) then
            logger.err("syncSeriesVolumes parameter error")
            return
        end
        local chapters = Backend:getBookChapterCache(book_cache_id)
        if not (H.is_tbl(chapters) and #chapters > 0) then
            return
        end
        debug_log("SYNCSERIES start chapters:", tostring(#chapters), "t=", os.time())
        for _, chapter in ipairs(chapters) do
            if H.is_num(chapter.chapters_index) then
                local lnk_path, lnk_name = self:wirteVolLnk(chapter, volume_folder, book_cache_id)
                if lnk_path and util.fileExists(lnk_path) then
                    self:refreshVolumeMetadata(lnk_name, lnk_path, book_cache_id, chapter.chapters_index, bookinfo)
                    if not DocSettings:findCustomCoverFile(lnk_path) then
                        self:asyncDownloadVolumeCover(book_cache_id, chapter, lnk_path)
                    end
                end
            end
        end
        debug_log("SYNCSERIES end t=", os.time())
    end


    function book_browser:emitMetadataChanged(path)
        --[[
        local prop_updated = {
            filepath = file,
            doc_props = book_props,
            metadata_key_updated = prop_updated,
            metadata_value_old = prop_value_old,
        }
        ]]
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end

    function book_browser:bind_provider(file)
        local doc_settings = DocSettings:open(file)
        local provider = doc_settings:readSetting("provider")
        if provider ~= "komga" then
            doc_settings:saveSetting("provider", "komga"):flush()
        end
        return doc_settings
    end

    function book_browser:refreshBookMetadata(lnk_name, lnk_path, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_tbl(bookinfo) and bookinfo.cache_id and
            bookinfo.name) then
            logger.err("browser.refreshBookMetadata parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            doc_settings:saveSetting("custom_props", {
                authors = bookinfo.author,
                title = bookinfo.name,
                description = bookinfo.intro,
                type = "serie"
                --type = bookinfo.type(serie,volume)
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("doc_props", {
                pages = bookinfo.totalChapterNum,
                pageno = bookinfo.durChapterIndex
            }):flushCustomMetadata(lnk_path)
        end

        self:emitMetadataChanged(lnk_path)
    end

    parent.book_browser = book_browser
    return book_browser
end

local function init_book_menu(parent)
    if parent.book_menu then
        return parent.book_menu
    end
    local book_menu = Menu:new{
        name = "library_view",
        is_enable_shortcut = false,
        is_popout = false,
        title = "书架",
        with_context_menu = true,
        align_baselines = true,
        covers_fullscreen = true,
        title_bar_left_icon = "appbar.menu",
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        onLeftButtonTap = function()
            parent:openMenu()
        end,
        close_callback = function()
            Backend:closeDbManager()
        end,
        show_search_item = nil,
        parent_ref = parent
    }

    if Device:hasKeys({"Home"}) or Device:hasDPad() then
        book_menu.key_events.Close = {{Device.input.group.Back}}
        book_menu.key_events.RefreshLibrary = {{"Home"}}
        book_menu.key_events.FocusRight = {{"Right"}}
    end

    function book_menu:onFocusRight()
        local focused_widget = Menu.getFocusItem(self)
        if focused_widget then

            local point = focused_widget.dimen:copy()
            point.x = point.x + point.w
            point.y = point.y + point.h / 2
            point.w = 0
            point.h = 0
            UIManager:sendEvent(Event:new("Gesture", {
                ges = "tap",
                pos = point
            }))
            return true
        end
    end
    function book_menu:onSwipe(arg, ges_ev)
        local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
        if direction == "south" then
            NetworkMgr:runWhenOnline(function()
                self:onRefreshLibrary()
            end)
            return
        end
        Menu.onSwipe(self, arg, ges_ev)
    end

    function book_menu:refreshItems(no_recalculate_dimen)
        local books_cache_data = Backend:getBookShelfCache()
        if H.is_tbl(books_cache_data) and #books_cache_data > 0 then
            self.item_table = self:generateItemTableFromMangas(books_cache_data)
            self.multilines_show_more_text = false
            self.items_per_page = nil
        else
            self.item_table = self:generateEmptyViewItemTable()
            self.multilines_show_more_text = true
            self.items_per_page = 1
        end
        self:updateItems(nil, no_recalculate_dimen)
    end

    function book_menu:onPrimaryMenuChoice(item)
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        self.parent_ref.selected_item = item
        self.parent_ref.onReturnCallback = function()
            self:show_view()
            self:refreshItems(true)
        end
        self.parent_ref.book_toc = ChapterListing:fetchAndShow({
            cache_id = bookinfo.cache_id,
            bookUrl = bookinfo.bookUrl,
            durChapterIndex = bookinfo.durChapterIndex,
            name = bookinfo.name,
            author = bookinfo.author,
            cacheExt = bookinfo.cacheExt,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder
        }, self.parent_ref.onReturnCallback, function(chapter)
            print("Predownload 3.")
            self.parent_ref.instance:loadAndRenderChapter(chapter)
        end, true)
        UIManager:nextTick(function()
            Backend:autoPinToTop(bookinfo.cache_id, bookinfo.sortOrder)
            self.parent_ref:addBkShortcut(bookinfo)
        end)
        self:onClose()
    end

    function book_menu:onRefreshLibrary()
            Backend:closeDbManager()
            MessageBox:loading("Refreshing Library", function()
                return Backend:refreshLibraryCache(parent.ui_refresh_time)
            end, function(state, response)
                if state == true then
                    Backend:HandleResponse(response, function(data)
                        MessageBox:notice('同步成功')
                        self.show_search_item = true
                        self:refreshItems()
                        self.parent_ref.ui_refresh_time = os.time()
                    end, function(err_msg)
                        print('同步失败', err_msg)
                        MessageBox:notice('同步失败', err_msg)
                    end)
                end
            end)
    end

    function book_menu:onMenuHold(item) 
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        local msginfo = [[
书名： <<%1>>
作者： %2
分类： %3
总卷数：%4
简介：%5
    ]]

        msginfo = T(msginfo, bookinfo.name or '', bookinfo.author or '', bookinfo.kind or '',
            bookinfo.totalChapterNum or '', bookinfo.intro or '')

        MessageBox:confirm(msginfo, nil, {
            icon = "notice-info",
            no_ok_button = true,
            other_buttons_first = true,
            other_buttons = {{{
                text = (bookinfo.sortOrder > 0) and '置顶书籍' or '取消置顶',
                callback = function()
                    Backend:manuallyPinToTop(item.cache_id, bookinfo.sortOrder)
                    self:refreshItems(true)
                end
            }}, {{
                text = "快捷方式",
                callback = function()
                    UIManager:nextTick(function()
                        self.parent_ref:addBkShortcut(bookinfo, true)
                    end)
                    MessageBox:notice("已调用生成，请到 Home 目录查看")
                end
            }}, {{
                text = '删除',
                callback = function()
                    MessageBox:confirm(string.format(
                        "是否删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复",
                        bookinfo.name), function(result)
                        if result then
                            Backend:closeDbManager()
                            MessageBox:loading("删除中...", function()
                                Backend:deleteBook(bookinfo)
                                return Backend:refreshLibraryCache()
                            end, function(state, response)
                                if state == true then
                                    Backend:HandleResponse(response, function(data)
                                        MessageBox:notice("删除成功")
                                        self:refreshItems(true)
                                    end, function(err_msg)
                                        MessageBox:error('删除失败：', err_msg)
                                    end)
                                end
                            end)
                        end
                    end, {
                        ok_text = "删除",
                        cancel_text = "取消"
                    })

                end
            }}}
        })

    end

    function book_menu:onMenuSelect(entry, pos)
        if entry.select_enabled == false then
            return true
        end
        local selected_context_menu = pos ~= nil and pos.x > 0.8
        if selected_context_menu then
            self:onMenuHold(entry, pos)
        else
            self:onPrimaryMenuChoice(entry, pos)
        end
    end

    function book_menu:generateEmptyViewItemTable()
        return {{
            text = string.format("No books found in library. Try%s swiping down to refresh.",
                (Device:hasKeys({"Home"}) and ' Press the home button or ' or '')),
            dim = true,
            select_enabled = false
        }}
    end

    function book_menu:generateItemTableFromMangas(books)
        local item_table = {}
        if self.show_search_item == true then
            item_table[1] = {
                text = string.format('%s Search...', Icons.FA_MAGNIFYING_GLASS),
                mandatory = "[Go]"
            }
            self.show_search_item = nil
        end

        for _, bookinfo in ipairs(books) do

            local show_book_title = ("%s (%s)[%s]"):format(bookinfo.name or "未命名书籍",
                bookinfo.author or "未知作者", bookinfo.originName)

            table.insert(item_table, {
                cache_id = bookinfo.cache_id,
                text = show_book_title,
                mandatory = Icons.FA_ELLIPSIS_VERTICAL
            })
        end

        return item_table
    end

    function book_menu:show_view()
        UIManager:show(self)
    end

    parent.book_menu = book_menu
    return book_menu
end

function LibraryView:getBrowserHomeDir(skip_check)
    local home_dir = H.getHomeDir()
    if not H.is_str(home_dir) then
        logger.err("LibraryView.getBrowserHomeDir: home_dir is nil")
        return nil
    end
    local browser_dir_name = "Komga\u{200B}漫画"
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
