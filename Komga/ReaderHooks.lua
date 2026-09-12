--[[ Komga/ReaderHooks.lua — ReaderUI 事件胶水(自 LibraryView 拆出)

注册阅读期事件(onDocSettingsLoad/onSaveSettings/onReaderReady/onCloseDocument 等),
install(LibraryView) 注入方法; LibraryView.openFileHandler 供 patches/core.lua
路由补丁直接调用。
]]
local KomgaModel = require("Komga/KomgaModel")
local Paths = require("Komga/Paths")
local Backend = require("Komga/Backend")
local MessageBox = require("Komga/MessageBox")

-- 与 LibraryView 同款浏览器目录判断(常量来源 Komga/Paths)
local function is_komga_browser_dir_path(file_path)
    return Paths.isKomgaBrowserDirPath(file_path, Backend:getSettings().browser_dir_name)
end

-- book_defaults.lua 仅由本插件读写: 按路径缓存解析结果, 免去每次保存事件的
-- 磁盘重读+重解析(对象为原地修改 + 条件 flush, 缓存即活值)
local book_defaults_cache = {}
local function get_book_defaults(book_defaults_path)
    local cached = book_defaults_cache[book_defaults_path]
    if cached then
        return cached
    end
    local config = Backend:getLuaConfig(book_defaults_path)
    if config then
        book_defaults_cache[book_defaults_path] = config
    end
    return config
end

return function(LibraryView)
function LibraryView:initializeRegisterEvent(parent_ref)
    local DocSettings = require("docsettings")
    local FileManager = require("apps/filemanager/filemanager")
    local util = require("util")
    local logger = require("logger")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local ChapterListing = require("Komga/ChapterListing")
    local H = require("Komga/Helper")

    local library_view_ref = self

    local is_komga_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find(Paths.CACHE_DIR_SEGMENT, 1, true) or false
    end
    local is_komga_browser_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return is_komga_browser_dir_path(file_path)
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
        local last_read_chapter = Backend:getLastReadVolumeIndex(book_cache_id)
        if H.is_num(last_read_chapter) then
            local bookinfo = KomgaModel:new(book_cache_id):getSeries()
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
                    url = bookinfo.url,
                    durChapterIndex = bookinfo.durChapterIndex,
                    name = bookinfo.name,
                    author = bookinfo.author,
                    cacheExt = bookinfo.cacheExt
                }, function()
                end, function(chapter)
                    library_view_ref.instance:loadAndRenderChapter(chapter)
                end, true)
            end

            local number = last_read_chapter - 1
            if number < 0 then
                number = 0
            end
            local chapter = KomgaModel:new(book_cache_id):getVolume(number)
            if H.is_tbl(chapter) and chapter.number then
                -- jump to the reading position
                chapter.call_event = "next"
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

        local model = KomgaModel:new(book_cache_id)
        local bookinfo = model and model:getSeries() or nil
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
                url = bookinfo.url,
                durChapterIndex = bookinfo.durChapterIndex,
                name = bookinfo.name,
                author = bookinfo.author,
                cacheExt = bookinfo.cacheExt
            }, onReturnCallBack, function(chapter)
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
                local book_defaults = get_book_defaults(book_defaults_path)
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
            document.is_pic = true

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
                local book_defaults = get_book_defaults(book_defaults_path)
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
                local instance = library_view_ref.instance
                instance.readerui_is_showing = false
                local displayed_chapter = instance.displayed_chapter
                if H.is_tbl(displayed_chapter) and H.is_str(displayed_chapter.book_cache_id) then
                    -- 1) 自动上传进度到服务器（同步取数 + 延迟发送, 不阻塞关书）
                    instance:uploadCurrentProgress()
                    -- 2) 读完返回时刷新该分卷快捷方式的进度显示
                    -- 用卷号而非 displayed_chapter.number（翻章后它是内部章节 index）
                    local vol_idx = instance:getVolumeIndexByBookId(
                        displayed_chapter.book_cache_id, displayed_chapter.bookId)
                    if not (H.is_num(vol_idx) and vol_idx > 0) then
                        vol_idx = instance.volume_reading_index or displayed_chapter.number
                    end
                    if H.is_num(vol_idx) then
                        instance:refreshReadVolumeShortcut(displayed_chapter.book_cache_id, vol_idx)
                    end
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
                -- 翻章前先上传当前章进度（末页/完成状态）
                library_view_ref.instance:uploadCurrentProgress()
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
                -- 回章前先上传当前章进度
                library_view_ref.instance:uploadCurrentProgress()
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

    -- 挂入 UI 事件链。注意: 必须保留无条件插入(不能因"已挂入"跳过)——
    -- 事件经 WidgetContainer 逆序分发, 插件在索引 3 的早期挂载位置是
    -- onEndOfBook/onSuspend 等处理器可靠触发的既有时序(2026-09 实测:
    -- 改为幂等跳过后 EPUB/漫画实体翻页键失联)。
    table.insert(parent_ref.ui, 3, parent_ref)

    function parent_ref:openFile(file)
        if not H.is_str(file) then
            return
        end
        local function open_regular_file(path)
            local ReaderUI = require("apps/reader/readerui")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(path, nil, true)
        end

        if not (is_komga_browser_path(file) and file:find(Paths.LNK_SUFFIX, 1, true)) then
            open_regular_file(file)
            return
        end
        -- prioritize using custom matedata book_cache_id
        local doc_settings = DocSettings:open(file)
        local book_cache_id = doc_settings:readSetting("book_cache_id")
        local customedata = H.getCustomProps(file)
        local booktype = customedata and customedata.type

        if not book_cache_id then
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_config then
                book_cache_id = lnk_config:readSetting("book_cache_id")
            end
        end

        -- 分卷快捷方式: 点击后直接打开该分卷阅读（必须在通用分支之前）
        if booktype == 'volume' and book_cache_id then
            local number = (customedata and customedata.number) or
                doc_settings:readSetting("number") or
                doc_settings:readSetting("chapters_index") -- 兼容旧版 sidecar key
            if H.is_num(number) then
                library_view_ref:openVolumeShortcut(book_cache_id, number, file)
                return true
            end
        end

        -- 系列快捷方式: 点击后进入该系列的分卷目录
        if booktype == 'serie' and book_cache_id then
            library_view_ref:openSeriesVolumesFolder(book_cache_id, file)
            return true
        end

        if book_cache_id then
            local ok, err = pcall(function()
                return self:openLastReadChapter(book_cache_id)
            end)
            if not ok then
                logger.err("fail to open file:", err)
            end
            return true
        else
            open_regular_file(file)
        end
    end

    -- FileManager.openFile 补丁(patches/core.lua)的路由目标: openFile 是定义在本插件实例(parent_ref)
    -- 上的方法, 不是 LibraryView.instance 上的。挂一个静态引用供补丁直接调用, 避免依赖从未赋值的 self.komga。
    LibraryView.openFileHandler = parent_ref
end
end
