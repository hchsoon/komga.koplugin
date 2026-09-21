local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local _ = require("gettext")
local H = require("Komga/Helper") -- need to load first 
local Backend = require("Komga/Backend") -- two
local LibraryView = require("Komga/LibraryView")
local verify_patched = require("patches.core").verifyPatched

local Komga = WidgetContainer:extend({
    name = "Komga漫画库",
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
end

function Komga:isFileTypeSupported(file)
    -- OpenWith 只认领 komga 缓存章节与快捷方式(.html), 不再无条件认领所有文件
    if type(file) ~= "string" then
        return false
    end
    local Paths = require("Komga/Paths")
    if file:find(Paths.CACHE_DIR_SEGMENT, 1, true) then
        return true
    end
    return file:find(Paths.LNK_SUFFIX, 1, true) ~= nil
end

function Komga:registerDocumentRegistryAuxProvider()
    -- 快捷方式 .html 的轻量"文档"类: 不打开真实引擎(无头), 元数据/进度
    -- 直接读 sidecar —— 供 CoverBrowser 的提取子进程使用。
    -- 没有它时: 提取子进程 openDocument 调 provider.new(不存在)必然失败,
    -- 每次目录渲染/失效广播都会重试, 3 次后 CoverBrowser 永久放弃该文件
    -- ("too many, ignoring it"), 封面与信息显示随之冻结。
    local DocSettings = require("docsettings")
    local ShortcutDocument = {}
    ShortcutDocument.__index = ShortcutDocument
    function ShortcutDocument.new(provider, file_tbl)
        return setmetatable({ file = file_tbl.file }, ShortcutDocument)
    end
    function ShortcutDocument:getProps()
        local props = {}
        local ok, ds = pcall(function()
            return DocSettings:open(self.file)
        end)
        if ok and ds then
            local custom = ds:readSetting("custom_props") or {}
            props.title = custom.title
            if custom.authors then
                props.authors = { custom.authors }
            end
            props.series = custom.series
            props.series_index = custom.number
            props.description = custom.description
            local pages = tonumber(ds:readSetting("doc_pages"))
            if pages then
                props.pages = pages
            end
            local percent = tonumber(ds:readSetting("percent_finished"))
            if percent then
                props.percent_finished = percent
            end
        end
        return props
    end
    function ShortcutDocument:getPageCount()
        return 1
    end
    function ShortcutDocument:close() end

    DocumentRegistry:addAuxProvider({
        provider_name = "KOReader 漫画插件",
        provider = "komga",
        document_class = ShortcutDocument,
        order = 50, -- order in OpenWith dialog
        disable_file = true,
        disable_type = false,
        -- Reader 内(阅读器历史/最近阅读)打开 komga 快捷方式时:
        -- filemanagerutil.openFile 对带 order 的 aux provider 会调 provider.callback,
        -- 无 callback 则回退 ui[provider]:openFile —— ReaderUI 上从未赋值 komga 字段,
        -- 必然报错闪退。这里显式路由到插件打开流程(与文件管理器点快捷方式同一路径)
        callback = function(file)
            local okLV, LibraryViewModule = pcall(require, "Komga/LibraryView")
            local handler = okLV and LibraryViewModule and LibraryViewModule.openFileHandler
            if handler and handler.openFile then
                handler:openFile(file)
            end
        end,
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
    LibraryView:fetchAndShow()
    UIManager:nextTick(function()
        if not self.patches_ok then
            Backend:installPatches()
        end
    end)
end
return Komga