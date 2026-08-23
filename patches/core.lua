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
    local ReaderStatus = require("apps/reader/modules/readerstatus")
    local addToMainMenu_readerstatus_orig = ReaderStatus.addToMainMenu
    function ReaderStatus:addToMainMenu(menu_items)
        if not is_komga_path(nil, self.ui) then
            addToMainMenu_readerstatus_orig(self, menu_items)
        end
    end
    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
    local addToMainMenu_filemanagerbookinfo_orig = FileManagerBookInfo.addToMainMenu
    function FileManagerBookInfo:addToMainMenu(menu_items)
        if not is_komga_path(nil, self.ui) then
            addToMainMenu_filemanagerbookinfo_orig(self, menu_items)
        end
    end
    local ReadHistory = require("readhistory")
    local original_addItem = ReadHistory.addItem
    function ReadHistory:addItem(file, ts, no_flush)
        if is_komga_path(file) or is_komga_browser_path(file) then
            return
        end
        return original_addItem(self, file, ts, no_flush)
    end
    local original_updateLastBookTime = ReadHistory.updateLastBookTime
    function ReadHistory:updateLastBookTime(no_flush)
        if self.hist and self.hist[1] ~= nil then
            original_updateLastBookTime(self, no_flush)
        end
    end
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
        -- 兜底: 缓存为单页 xhtml 的即为 EPUB 内部章节(mediaType 可能因翻页/换章节丢失)
        if chapter and type(chapter.cacheFilePath) == 'string' then
            local ext = chapter.cacheFilePath:lower():match("%.([^.]+)$")
            if ext == "xhtml" then
                return true
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
    local FileManager = require("apps/filemanager/filemanager")
    local original_showOpenWithDialog = FileManager.showOpenWithDialog
    function FileManager:showOpenWithDialog(file)
        if file and is_komga_browser_path(file) then
            self:handleEvent(Event:new("ShowKomgaLibraryView"))
        else
            original_showOpenWithDialog(self, file)
        end
    end
    local original_showFiles = FileManager.showFiles
    function FileManager:showFiles(path, focused_file, selected_files)
        if is_komga_path(path) then
            local home_dir = G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
            if home_dir then
                local komga_homedir = home_dir .. "/Komga\u{200B}漫画"
                local util = require("util")
                if util and util.fileExists(komga_homedir) then
                    path = komga_homedir
                else
                    path = home_dir
                end
            end
        end
        original_showFiles(self, path, focused_file, selected_files)
    end
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
    -- fix koreader .cbz next chapter crash
    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local original_getBookProgress = ReaderFooter.getBookProgress
    function ReaderFooter:getBookProgress()
        if self.ui and self.ui.document then
            return original_getBookProgress(self)
        else
            print("progress ", self.pageno, "//", self.pages)
            return self.pageno / self.pages
        end
    end
    local original_updateFooterPage = ReaderFooter.updateFooterPage
    function ReaderFooter:updateFooterPage(force_repaint, full_repaint)
        if self.ui and self.ui.document then
            return original_updateFooterPage(self, force_repaint, full_repaint)
        end
        return
    end
    -- 临时调试: 记录所有 Reader 打开调用, 判断"正在打开/opening"来源 (诊断完成后删除)
    local ReaderUI = require("apps/reader/readerui")
    local dbg_file = "/Users/hchsoon/Library/Application Support/koreader/komga_ui_debug.log"
    local function dbg_log(...)
        local ok, f = pcall(io.open, dbg_file, "a")
        if ok and f then
            f:write(os.date("[%H:%M:%S] ") .. table.concat({...}, " ") .. "\n")
            f:close()
        end
    end
    local showReader_orig = ReaderUI.showReader
    function ReaderUI:showReader(file, provider, seamless, ...)
        dbg_log("READERUI.showReader file:", tostring(file), "seamless:", tostring(seamless),
            "provider:", tostring(provider and provider.provider))
        return showReader_orig(self, file, provider, seamless, ...)
    end
    local switchDocument_orig = ReaderUI.switchDocument
    function ReaderUI:switchDocument(new_file, ...)
        dbg_log("READERUI.switchDocument file:", tostring(new_file))
        return switchDocument_orig(self, new_file, ...)
    end
end

return M
