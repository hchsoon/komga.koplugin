local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local H = require("Komga/Helper") -- need to load first 
local Backend = require("Komga/Backend") -- two
local LibraryView = require("Komga/LibraryView")
local verify_patched = require("patches.core").verifyPatched

local Komga = WidgetContainer:extend({
    name = "Komga漫画库",
    library_view = nil,
    patches_ok = nil
})

function Komga:init()
    -- on open FileManager or ReaderUI
    self.patches_ok = verify_patched()
    if not H.plugin_path then
        H.initialize("komga", self.path)
    end
    if not Backend.settings_data then
        Backend:initialize()
    end
    if self.ui then
        LibraryView:initializeRegisterEvent(self)
        if self.ui.menu then
            self.ui.menu:registerToMainMenu(self)
        end
    end
    self:registerDocumentRegistryAuxProvider()
    self:onDispatcherRegisterActions()
end

function Komga:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_komga_libraryview", {
        category = "none",
        event = "ShowKomgaLibraryView",
        title = _("Komga 漫画库"),
        filemanager = true
    })
    Dispatcher:registerAction("return_komga_chapterlisting", {
        category = "none",
        event = "ShowKomgaToc",
        title = _("返回 Komga 目录"),
        reader = true
    })
    Dispatcher:registerAction("show_komga_search", {
        category = "none",
        event = "ShowKomgaSearch",
        title = _("以书籍信息搜索 Komga 漫画源"),
        reader = true
    })
end

function Komga:isFileTypeSupported(file)
    return true
end

function Komga:registerDocumentRegistryAuxProvider()
    DocumentRegistry:addAuxProvider({
        provider_name = "Komga漫画阅读",
        provider = "komga",
        order = 50, -- order in OpenWith dialog
        disable_file = true,
        disable_type = false,
    })
end

local is_low_version
function Komga:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        if is_low_version == nil then
            local ko_version = require("version"):getNormalizedCurrentVersion()
            is_low_version = (ko_version and ko_version < 202411000000)
        end
        menu_items.Komga = {
            text = "Komga 漫画库",
            sorting_hint = "search",
            help_text = "连接 Komga 漫画库" .. (is_low_version and "，Koreader 版本低，建议升级" or ""),
            callback = function()
                self:openLibraryView()
            end
        }
    else

        if not self.patches_ok and self.ui and self.ui.name == "readerUI" and LibraryView.instance and
            LibraryView.instance.readerui_is_showing == true then
            menu_items.go_back_to_komga = {
                text = "返回 Komga...",
                sorting_hint = "main",
                help_text = "点击返回 Komga 漫画库",
                callback = function()
                    self.ui:handleEvent(Event:new("ShowKomgaToc"))
                end
            }
        end
    end
end

function Komga:openLibraryView()
    self.library_view = LibraryView:fetchAndShow()
    UIManager:nextTick(function()
        if not self.patches_ok then
            Backend:installPatches()
        end
        -- Backend:checkOta()
    end)
end
return Komga