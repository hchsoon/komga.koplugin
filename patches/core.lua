local M = {
    _mark = "_c8eeb679e"
}

M._setMark = function(instance)
    instance[M._mark] = true
end

M.verifyPatched = function(instance)
    if not instance then
        instance = require("apps/reader/modules/readerrolling")
    end
    return instance[M._mark] == true
end

M.install = function()
    local Event = require("ui/event")

    -- If the plugin is disabled, no functional patch is applied
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["komga"] == true then
            return
        end
    end

    -- 幂等: 重复调用 install()(如重启流程残留)会把补丁包两层
    if M._installed then
        return
    end
    M._installed = true

    -- 每个补丁独立 pcall: 单个失败(如 KOReader 升级改了模块接口)
    -- 不再拖垮后续补丁。
    -- 注意: 各补丁正文保持原有缩进未重排(Lua 不依赖缩进), 减少无谓 diff。
    local logger = require("logger")
    local function apply(name, patch_fn)
        local ok, err = pcall(patch_fn)
        if ok then
            logger.dbg("komga patch applied:", name)
        else
            logger.warn("komga patch FAILED:", name, err)
        end
    end
    local is_komga_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find('/cache/komga.cache/', 1, true) or false
    end
    -- 浏览器根目录名可配置(插件设置项 browser_dir_name, 默认含零宽空格)。
    -- 直接读插件设置文件(与 HttpRequest.get_api_key 同法, 不依赖 Backend 初始化),
    -- 进程内缓存, 改名后重启生效; 匹配同时接受默认名与自定义名, 旧目录快捷方式仍可路由。
    local DEFAULT_BROWSER_DIR_NAME = "Komga\u{200B}漫画"
    local browser_dir_names_cache = nil
    local function get_komga_browser_dir_names()
        if browser_dir_names_cache then
            return browser_dir_names_cache
        end
        local names = {DEFAULT_BROWSER_DIR_NAME}
        local ok, configured = pcall(function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/komga.lua")
            local v = settings and settings.data and settings.data.browser_dir_name
            if type(v) == "string" and v ~= "" and v ~= DEFAULT_BROWSER_DIR_NAME then
                return (v:gsub("[/\\]", "_"))
            end
            return nil
        end)
        if ok and configured then
            table.insert(names, configured)
        end
        browser_dir_names_cache = names
        return names
    end
    local is_komga_browser_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        if type(file_path) ~= 'string' then
            return false
        end
        for _, name in ipairs(get_komga_browser_dir_names()) do
            if file_path:find("/" .. name .. "/", 1, true) then
                return true
            end
        end
        return false
    end
    apply("ReaderRolling.onGotoViewRel", function()
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    local onGotoViewRel_original = ReaderRolling.onGotoViewRel
    ReaderRolling.onGotoViewRel = function(self, diff)
        local scroll_mode = self.view.view_mode == "scroll"
        local old_pos = scroll_mode and self.current_pos or self.current_page
        onGotoViewRel_original(self, diff)
        local new_pos = scroll_mode and self.current_pos or self.current_page
        -- local beginning_page = self.ui.document:getNextPage(0)
        -- old_pos cannot be equal to 1, otherwise it won't work in scroll mode.
        if diff < 0 and old_pos == new_pos and is_komga_path(nil, self.ui) then
            self.ui:handleEvent(Event:new("StartOfBook"))
        end
        return true
    end
    M._setMark(ReaderRolling)
    end)

    apply("ReaderPaging.onGotoViewRel", function()
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    local onGotoViewRel_orig = ReaderPaging.onGotoViewRel
    -- In scroll mode, one screen may have multiple pages
    function ReaderPaging:onGotoViewRel(diff)
        local scroll_mode = self.view.view_mode == "scroll"
        local old_pos = self:getTopPage()
        onGotoViewRel_orig(self, diff)
        local new_pos = self:getTopPage()
        -- require("logger").info("ReaderPaging:onGotoViewRel scroll_mode old_pos new_pos diff ",scroll_mode,old_pos,new_pos,diff)
        if diff < 0 and old_pos == 1 and old_pos == new_pos and is_komga_path(nil, self.ui) then
            self.ui:handleEvent(Event:new("StartOfBook"))
        end
        return true
    end
    end)

    apply("ReaderStatus.addToMainMenu", function()
    local ReaderStatus = require("apps/reader/modules/readerstatus")
    local addToMainMenu_readerstatus_orig = ReaderStatus.addToMainMenu
    function ReaderStatus:addToMainMenu(menu_items)
        if not is_komga_path(nil, self.ui) then
            addToMainMenu_readerstatus_orig(self, menu_items)
        end
    end
    end)

    apply("FileManagerBookInfo.addToMainMenu", function()
    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
    local addToMainMenu_filemanagerbookinfo_orig = FileManagerBookInfo.addToMainMenu
    function FileManagerBookInfo:addToMainMenu(menu_items)
        if not is_komga_path(nil, self.ui) then
            addToMainMenu_filemanagerbookinfo_orig(self, menu_items)
        end
    end
    end)

    -- lfs 是 ReadHistory/ReaderLink 两个补丁共用的 upvalue, 提到 install 作用域
    local lfs = require("libs/libkoreader-lfs")

    apply("Suppress Closing book prompt during komga chapter switch", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        -- EPUB 章节切换经 switchDocument 关闭旧文档, 核心层会弹 "Closing book"
        -- (翻译为"正在关闭书籍")提示, 每次翻章都闪一次。切换窗口期
        -- (M.switching_chapter, 由 LibraryView 置位/定时清除)过滤该提示,
        -- 手动关书的提示不受影响。
        UIManager.show = function(self, widget, ...)
            if M.switching_chapter and widget and type(widget.text) == "string"
                and (widget.text:find("Closing book", 1, true)
                    or widget.text:find("关闭书籍", 1, true)) then
                return
            end
            return original_show(self, widget, ...)
        end
    end)

    apply("ReadHistory.addItem/updateLastBookTime", function()
    local ReadHistory = require("readhistory")
    local original_addItem = ReadHistory.addItem
    function ReadHistory:addItem(file, ts, no_flush)
        -- Komga 阅读打开的是缓存文件(EPUB 内部章节 xhtml / 漫画 cbz), 直接写进历史点开会丢失
        -- komga 上下文(无法上传进度/续读), 所以映射为对应的分卷快捷方式(.html)再写入:
        -- 历史条目点击后经 komga:openFile -> openVolumeShortcut 恢复阅读, 与文件夹点开分卷一致。
        if is_komga_path(file) then
            local ok, shortcut = pcall(function()
                local okLV, LibraryView = pcall(require, "Komga/LibraryView")
                local inst = okLV and LibraryView and LibraryView.instance
                if inst and inst.ensureVolumeShortcutForReading then
                    return inst:ensureVolumeShortcutForReading()
                end
                return nil
            end)
            if ok and type(shortcut) == "string" and lfs.attributes(shortcut, "mode") == "file" then
                return original_addItem(self, shortcut, ts, no_flush)
            end
            return -- 找不到对应分卷快捷方式: 不写入阅读记录
        end
        return original_addItem(self, file, ts, no_flush)
    end
    local original_updateLastBookTime = ReadHistory.updateLastBookTime
    function ReadHistory:updateLastBookTime(no_flush)
        if self.hist and self.hist[1] ~= nil then
            original_updateLastBookTime(self, no_flush)
        end
    end
    end)

    apply("ReaderToc.onShowToc", function()
    local ReaderToc = require("apps/reader/modules/readertoc")
    local original_onShowToc = ReaderToc.onShowToc
    -- Komga 阅读时目录按钮的决策:
    --   EPUB 分卷(缓存为单页 xhtml, KOReader 无原生 TOC) -> 显示分卷内部目录 ShowKomgaVolumeToc
    --   漫画/其他                                       -> 显示系列目录 ShowKomgaToc
    --   非 Komga 文件                                   -> KOReader 原生目录
    local function get_komga_displayed_chapter()
        local ok, LibraryView = pcall(require, "Komga/LibraryView")
        local inst = ok and LibraryView and LibraryView.instance
        return inst and inst.displayed_chapter
    end
    local function is_komga_epub_reading()
        local chapter = get_komga_displayed_chapter()
        if chapter and chapter.mediaType == "EPUB" then
            return true
        end
        -- 兜底(mediaType 可能因翻页/换章节丢失): EPUB 内部章节按 DB 清单判定。
        -- .xhtml 缓存只有 EPUB 在用, 直接认定; .html 可能是书源文本章, 须查 DB
        if chapter and type(chapter.cacheFilePath) == 'string' then
            local ext = chapter.cacheFilePath:lower():match("%.([^.]+)$")
            if ext == "xhtml" then
                return true
            elseif ext == "html" then
                local bookId = chapter.cacheFilePath:match("-([%u%d]+)-%d+%.html$")
                if bookId then
                    local okB, Backend = pcall(require, "Komga/Backend")
                    if okB and Backend and Backend.dbManager then
                        local okQ, all = pcall(Backend.dbManager.getAllEpubChapterUrls,
                            Backend.dbManager, bookId)
                        if okQ and type(all) == "table" and #all > 0 then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end
    function ReaderToc:onShowToc()
        if is_komga_path(nil, self.ui) then
            if is_komga_epub_reading() then
                self.ui:handleEvent(Event:new("ShowKomgaVolumeToc"))
            else
                self.ui:handleEvent(Event:new("ShowKomgaToc"))
            end
            return true
        else
            return original_onShowToc(self)
        end
    end
    end)

    -- FileManager 被 showOpenWithDialog/showFiles/openFile 三个补丁共用, 提到 install 作用域
    local FileManager = require("apps/filemanager/filemanager")

    apply("FileManager.showOpenWithDialog", function()
    local original_showOpenWithDialog = FileManager.showOpenWithDialog
    function FileManager:showOpenWithDialog(file)
        if file and is_komga_browser_path(file) then
            self:handleEvent(Event:new("ShowKomgaLibraryView"))
        else
            original_showOpenWithDialog(self, file)
        end
    end
    end)

    apply("FileManager.showFiles", function()
    local original_showFiles = FileManager.showFiles
    function FileManager:showFiles(path, focused_file, selected_files)
        if is_komga_path(path) then
            local home_dir = G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
            if home_dir then
                -- 重定向到浏览器根目录: 优先自定义名, 其次默认名, 都不存在回 Home
                local redirected
                for _, name in ipairs(get_komga_browser_dir_names()) do
                    local d = home_dir .. "/" .. name
                    if lfs.attributes(d, "mode") == "directory" then
                        redirected = d
                        break
                    end
                end
                path = redirected or home_dir
            end
        end
        original_showFiles(self, path, focused_file, selected_files)
    end
    end)

    -- 兜底: Komga 快捷方式(.html 存书籍元信息)必须路由到 Komga 插件, 即使 sidecar 的 provider 字段缺失
    -- (DocumentRegistry:getProvider 会退回 document provider, 用 crengine 直接打开 html 显示元信息)
    apply("FileManager.openFile", function()
    local original_openFile = FileManager.openFile
    function FileManager:openFile(file, provider, doc_caller_callback, aux_caller_callback, after_open_callback)
        if not provider and file and is_komga_browser_path(file) and file:find("\u{200B}.html", 1, true) then
            -- openFile 是定义在 komga 插件实例(parent_ref)上的方法, 不是 LibraryView.instance 的;
            -- initializeRegisterEvent 时已把实例挂到 LibraryView.openFileHandler。
            -- 历史条目(阅读记录)/文件浏览器点开分卷快捷方式都要路由到这里, 否则 crengine 会直接渲染 .html 元信息。
            local ok, LibraryView = pcall(require, "Komga/LibraryView")
            local handler = ok and LibraryView and LibraryView.openFileHandler
            if not handler then
                handler = self.komga -- 兜底(历史遗留字段)
            end
            if handler and handler.openFile then
                return handler:openFile(file)
            end
        end
        return original_openFile(self, file, provider, doc_caller_callback, aux_caller_callback, after_open_callback)
    end
    end)

    -- 兜底拦截: 任何走到 ReaderUI:showReader 的 komga 快捷方式都必须路由回插件,
    -- 否则 crengine 会直接渲染 .html 元信息。这覆盖 FileManager:openFile 补丁之外
    -- 的所有入口(如返回流程/阅读记录里直接调 showReader 的路径)。
    apply("ReaderUI.showReader", function()
    local ReaderUI = require("apps/reader/readerui")
    local original_showReader = ReaderUI.showReader
    function ReaderUI:showReader(file, provider, seamless, is_provider_forced, after_open_callback)
        if file and is_komga_browser_path(file) and file:find("\u{200B}.html", 1, true) then
            local ok, LibraryView = pcall(require, "Komga/LibraryView")
            local handler = ok and LibraryView and LibraryView.openFileHandler
            if handler and handler.openFile then
                return handler:openFile(file)
            end
        end
        return original_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
    end
    end)

    apply("filemanagerutil.genBookCoverButton", function()
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local original_genBookCoverButton = filemanagerutil.genBookCoverButton
    function filemanagerutil.genBookCoverButton(file, book_props, caller_callback, button_disabled)
        if file and is_komga_browser_path(file) then
            return {
                text = "komga 漫画",
                enabled = true,
                callback = function()
                    caller_callback()
                    local ui = require("apps/filemanager/filemanager").instance or require("apps/reader/readerui").instance
                    if ui then
                        ui:handleEvent(Event:new("ShowKomgaBrowserOption", file))
                    end
                end
            }
        else
            return original_genBookCoverButton(file, book_props, caller_callback, button_disabled)
        end
    end
    end)

    -- fix koreader .cbz next chapter crash
    apply("ReaderFooter.getBookProgress", function()
    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local original_getBookProgress = ReaderFooter.getBookProgress
    function ReaderFooter:getBookProgress()
        if self.ui and self.ui.document then
            return original_getBookProgress(self)
        else
            return self.pageno / self.pages
        end
    end
    end)
    -- 分卷 EPUB 内链(目录页 <a href> / 正文互链)跳转到缓存章节。
    -- 1) 链接已在下载时重写成缓存文件名 <safe-name>-<bookId>-<index>.xhtml:
    --    目标文件已缓存则直接打开(跳过原生"是否打开本地文档"确认框);
    --    未缓存则按需下载后打开, 避免 "Invalid or external link" 提示。
    -- 2) 兼容旧缓存中未重写的相对路径(../Text/Sectionxxx.xhtml):
    --    以当前文档同卷章节为基准, 用数据库 url 的基名映射到缓存文件名。
    -- 3) 调试日志已关闭(dbg 为空操作), 不再写 <datadir>/komga_link_debug.log。
    --    若需重新定位链接跳转问题, 把下方 dbg 恢复为写文件实现即可。
    apply("ReaderLink.openFileFromLink", function()
    local ReaderLink = require("apps/reader/modules/readerlink")
    local original_openFileFromLink = ReaderLink.openFileFromLink
    local function dbg(_msg)
        -- 空操作: 关闭链接调试日志
    end
    local normalize_href_basename = function(href)
        if type(href) ~= "string" or href == "" then
            return nil
        end
        local u = href:gsub("^%a[%w+.-]*://[^/]+/", "")
        u = u:gsub("[?#].*", "")
        local name = u:match("([^/]+)$")
        if not name then
            return nil
        end
        name = name:gsub("%.x?html?$", "")
        if name == "" then
            return nil
        end
        return name:lower()
    end
    function ReaderLink:openFileFromLink(link_url)
        if not (is_komga_path(nil, self.ui) and type(link_url) == "string" and link_url ~= "") then
            return original_openFileFromLink(self, link_url)
        end
        dbg("click: " .. tostring(link_url))
        local ok, res = pcall(function()
            local ffiUtil = require("ffi/util")
            local link_clean = link_url:gsub("[?#].*", ""):gsub("^file:", "")
            if link_clean == "" then
                return original_openFileFromLink(self, link_url)
            end
            local cur_file = self.ui.document and self.ui.document.file
            -- 内部章节缓存扩展名随源页面 URL(.xhtml 或 .html), 统一 %.x?html$ 解析;
            -- 重建目标文件名沿用当前文件扩展名
            local cur_ext = cur_file and cur_file:match("%.(x?html)$")
            local cur_bookId = cur_file and cur_file:match("-([%u%d]+)-%d+%.x?html$")
            -- 前缀取到 <safe-name>-<bookId>-(不含章节号), 目标文件 = 前缀-index-<ext>
            local cur_prefix = cur_file and cur_file:match("^(.*)-%d+%.x?html$")
            local bookId, target_idx, target_file
            -- Case 1: 缓存文件名 <safe-name>-<bookId>-<index>.xhtml
            -- (必须同时解析出 bookId 才视为缓存文件名; 否则可能是旧缓存的相对路径,
            -- 其末尾的数字会被误当成章节索引, 需要落到 Case 2 用数据库基名映射)
            if link_clean:match("%.x?html$") then
                local idx = link_clean:match("(%d+)%.xhtml$") or link_clean:match("(%d+)%.html$")
                if idx then
                    local bId = link_clean:match("-([%u%d]+)-%d+%.x?html$")
                    if bId then
                        bookId = bId
                        target_idx = tonumber(idx)
                        local joined = ffiUtil.joinPath(self.document_dir, link_clean)
                        -- realpath 对不存在的文件返回 nil, 用它本身做"文件是否存在"判断
                        joined = ffiUtil.realpath(joined)
                        if joined then
                            target_file = joined
                        elseif cur_bookId == bookId and cur_prefix then
                            -- 链接可能被 URL 编码(中文/空格变 %xx), 磁盘文件名与 href 字节
                            -- 不一致; 用当前文档同卷前缀重建目标路径再试
                            local rebuilt = cur_prefix .. "-" .. target_idx .. "." .. (cur_ext or "xhtml")
                            if lfs.attributes(rebuilt, "mode") == "file" then
                                target_file = rebuilt
                            end
                        end
                    end
                end
            end
            -- Case 2: 旧缓存未重写的相对路径 ../Text/Section007.xhtml(与当前文档同卷)
            if not target_idx then
                if cur_bookId and cur_prefix then
                    local key = normalize_href_basename(link_clean)
                    local okB, Backend = pcall(require, "Komga/Backend")
                    if okB and Backend and Backend.dbManager and key then
                        local all = Backend.dbManager:getAllEpubChapterUrls(cur_bookId)
                        if type(all) == "table" then
                            for _, ch in ipairs(all) do
                                if type(ch) == "table" and type(ch.number) == "number" and
                                    normalize_href_basename(ch.url) == key then
                                    target_idx = ch.number
                                    bookId = cur_bookId
                                    target_file = cur_prefix .. "-" .. target_idx .. "." .. (cur_ext or "xhtml")
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if not (type(target_idx) == "number" and type(bookId) == "string") then
                dbg("  no target -> original")
                return original_openFileFromLink(self, link_url)
            end
            dbg("  bookId=" .. tostring(bookId) .. " idx=" .. tostring(target_idx))
            -- 已缓存: 直接打开; 未缓存: 按需下载后打开。
            local okB, Backend = pcall(require, "Komga/Backend")
            local okMsg, MessageBox = pcall(require, "Komga/MessageBox")
            local okLV, LibraryView = pcall(require, "Komga/LibraryView")
            -- document_dir 来自 splitFilePathName, 含尾部斜杠(.../x.sdr/), 匹配需容忍
            local document_dir_name = self.document_dir and self.document_dir:match("([^/\\]+)%.sdr[/\\]*$")
            dbg(string.format("  deps Backend=%s sdata=%s MsgBox=%s LibraryView=%s inst=%s dirname=%s",
                tostring(okB and Backend ~= nil),
                tostring(Backend and Backend.settings_data and Backend.settings_data.data ~= nil),
                tostring(okMsg and MessageBox ~= nil),
                tostring(okLV and LibraryView ~= nil),
                tostring(LibraryView and LibraryView.instance ~= nil),
                tostring(document_dir_name)))
            if not (okB and Backend and document_dir_name) then
                dbg("  essential deps missing -> original")
                return original_openFileFromLink(self, link_url)
            end
            local cur_chapter = (LibraryView and LibraryView.instance) and LibraryView.instance.displayed_chapter
            local server_addr = (Backend.settings_data and Backend.settings_data.data and Backend.settings_data.data.server_address)
                or (type(cur_chapter) == "table" and cur_chapter.url)
            -- 补全分卷阅读所需字段(与 ReaderUIEventCallback 相同),
            -- 避免 TOC 按钮退回系列目录/进度上传缺字段
            local function patch_fields(data)
                if type(cur_chapter) == "table" then
                    for _, k in ipairs({"call_event", "mediaType", "volume_read", "name",
                        "author", "cacheExt", "booksCount", "book_cache_id", "url"}) do
                        if data[k] == nil and cur_chapter[k] ~= nil then
                            data[k] = cur_chapter[k]
                        end
                    end
                end
                return data
            end
            local function make_chapter(cache_file)
                return patch_fields({
                    book_cache_id = document_dir_name,
                    bookId = bookId,
                    number = target_idx,
                    cacheFilePath = cache_file,
                    url = server_addr,
                })
            end
            -- 打开目标章节: 优先 LibraryView.showReaderUI(正确更新 displayed_chapter);
            -- LibraryView.instance 缺失时(直接打开缓存文件等场景)退化为 self.ui:switchDocument
            local function open_chapter(chapter)
                if LibraryView and LibraryView.instance and LibraryView.instance.showReaderUI then
                    LibraryView.instance:showReaderUI(chapter)
                else
                    if LibraryView and LibraryView.instance then
                        LibraryView.instance.displayed_chapter = chapter
                    end
                    self.ui:switchDocument(chapter.cacheFilePath, true)
                end
            end
            if target_file and lfs.attributes(target_file, "mode") == "file" then
                -- 已缓存: 直接打开(不弹"是否打开本地文档"确认框)
                dbg("  cached, open: " .. tostring(target_file))
                open_chapter(make_chapter(target_file))
                return true
            end
            if not server_addr then
                dbg("  no url -> original")
                return original_openFileFromLink(self, link_url)
            end
            -- 未缓存: 按需下载后打开。
            -- 构造 chapter 时就补全 name 等字段(而非下载后再补), 否则 pDownloadVolume
            -- 会用空书名命名缓存文件(-<bookId>-<index>.xhtml), 与正常命名不一致造成重复缓存
            local chapter = patch_fields({
                book_cache_id = document_dir_name,
                bookId = bookId,
                number = target_idx,
                url = server_addr,
            })
            dbg("  download bookId=" .. tostring(bookId) .. " idx=" .. tostring(target_idx))
            local function download_cb(state, response)
                if state ~= true then
                    dbg("  download state=" .. tostring(state) .. " resp=" .. tostring(response))
                    return
                end
                Backend:HandleResponse(response, function(data)
                    dbg("  download ok cacheFilePath=" .. tostring(data and data.cacheFilePath))
                    if not (type(data) == "table" and type(data.cacheFilePath) == "string") then
                        if Backend.show_notice then Backend:show_notice("章节下载失败") end
                        return
                    end
                    open_chapter(patch_fields(data))
                end, function(err_msg)
                    dbg("  download err: " .. tostring(err_msg))
                    if Backend.show_notice then Backend:show_notice("章节下载失败" .. tostring(err_msg or "")) end
                end)
            end
            -- 静默下载: 不弹"正在下载章节"对话框(与章节切换路径一致, 失败仅轻提示)
            local okdl, dlresp = pcall(Backend.downloadVolume, Backend, chapter)
            if okdl then
                download_cb(true, dlresp)
            else
                download_cb(false, "下载失败: " .. tostring(dlresp))
            end
            return true
        end)
        if not ok then
            dbg("  patch error: " .. tostring(res))
            return original_openFileFromLink(self, link_url)
        end
        return res
    end
    dbg("install() patched ReaderLink:openFileFromLink")
    end)
end

return M
