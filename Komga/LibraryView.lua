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

-- 配置 X-API-Key(请求头), 默认值取自 Config.DEFAULT_API_KEY
-- 缓存管理: 显示可清理缓存占用/上限, 设置上限(MB), 立即执行 LRU 清理。
-- 范围为可再生资源(resources/ 与流式页缓存); 章节缓存与封面不自动清理。
function LibraryView:openCacheManager()
    self:getInstance()
    local ButtonDialog = require("ui/widget/buttondialog")
    local settings = Backend:getSettings()
    local usage = Backend:getCacheUsage()
    local used_mb = math.floor((usage.used_bytes or 0) / 1024 / 1024)
    local max_mb = math.floor((usage.max_bytes or 0) / 1024 / 1024)
    local dialog
    local buttons = {}

    table.insert(buttons, {{
        text = string.format("可清理缓存占用: %d MB / 上限 %d MB", used_mb, max_mb),
        callback = function() end,
    }})
    table.insert(buttons, {{
        text = Icons.FA_FOLDER .. " 设置上限 (MB)",
        callback = function()
            UIManager:close(dialog)
            MessageBox:input(nil, nil, {
                title = "设置缓存上限 (MB)",
                input = tostring(max_mb),
                description = "超过上限时按最久未访问优先清理可再生资源(图片/流式页缓存)。章节缓存与封面不受影响。",
                condensed = true,
                save_callback = function(input_text)
                    local n = tonumber(input_text)
                    if not n or n < 50 or n > 10240 then
                        MessageBox:notice('请输入 50-10240 的数字')
                        return false
                    end
                    settings.cache_max_mb = math.floor(n)
                    return Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice("缓存上限已更新")
                        return true
                    end, function(err_msg)
                        MessageBox:notice('设置失败：' .. tostring(err_msg))
                        return false
                    end)
                end,
                allow_newline = false
            })
        end,
    }})
    table.insert(buttons, {{
        text = Icons.UNICODE_STAR_OUTLINE .. " 立即清理",
        callback = function()
            UIManager:close(dialog)
            local on_done = function(ok, res)
                if ok and H.is_tbl(res) then
                    MessageBox:notice(string.format("清理完成: 删除 %d 个文件, 释放 %.1f MB",
                        res.removed or 0, (res.freed or 0) / 1024 / 1024))
                end
            end
            return Backend:HandleResponse(Backend:runCacheJanitor(on_done), function(data)
                MessageBox:notice("清理已在后台执行, 完成后提示")
            end, function(err_msg)
                MessageBox:notice('清理失败：' .. tostring(err_msg))
            end)
        end,
    }})

    dialog = ButtonDialog:new{
        title = "缓存管理",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- 多服务器配置管理: 列出已存配置(点击切换), 保存当前/删除。
-- 切换即时生效(重建 REST 客户端), 无需重启。
function LibraryView:openServerProfileManager()
    self:getInstance()
    local ButtonDialog = require("ui/widget/buttondialog")
    local profiles = Backend:getServerProfiles()
    local dialog
    local buttons = {}

    for _, profile in ipairs(profiles) do
        local p = profile
        table.insert(buttons, {{
            text = string.format("%s 切换到: %s (%s)", Icons.FA_GLOBE,
                tostring(p.name), tostring(p.server_address)),
            callback = function()
                UIManager:close(dialog)
                Backend:HandleResponse(Backend:switchServerProfile(p.name), function(data)
                    MessageBox:notice(string.format("已切换到 %s, 请刷新书架", tostring(p.name)))
                end, function(err_msg)
                    MessageBox:notice('切换失败：' .. tostring(err_msg))
                end)
            end,
        }})
    end

    table.insert(buttons, {{
        text = Icons.FA_BOOK .. " 保存当前服务器为新配置",
        callback = function()
            UIManager:close(dialog)
            MessageBox:input(nil, nil, {
                title = "保存当前服务器配置",
                input = "",
                description = "为当前生效的 WEB 地址与 API Key 命名(同名覆盖)。切换即时生效, 无需重启。",
                condensed = true,
                save_callback = function(input_text)
                    if not H.is_str(input_text) or util.trim(input_text) == '' then
                        MessageBox:notice('输入为空')
                        return false
                    end
                    local name = util.trim(input_text)
                    return Backend:HandleResponse(Backend:saveServerProfile(name), function(data)
                        MessageBox:notice("配置已保存: " .. name)
                        return true
                    end, function(err_msg)
                        MessageBox:notice('保存失败：' .. tostring(err_msg))
                        return false
                    end)
                end,
                allow_newline = false
            })
        end,
    }})

    if #profiles > 0 then
        table.insert(buttons, {{
            text = Icons.UNICODE_STAR_OUTLINE .. " 删除配置",
            callback = function()
                UIManager:close(dialog)
                local del_dialog
                local del_buttons = {}
                for _, profile in ipairs(Backend:getServerProfiles()) do
                    local p = profile
                    table.insert(del_buttons, {{
                        text = "删除: " .. tostring(p.name),
                        callback = function()
                            UIManager:close(del_dialog)
                            Backend:HandleResponse(Backend:deleteServerProfile(p.name), function(data)
                                MessageBox:notice("已删除: " .. tostring(p.name))
                            end, function(err_msg)
                                MessageBox:notice('删除失败：' .. tostring(err_msg))
                            end)
                        end,
                    }})
                end
                del_dialog = ButtonDialog:new{
                    title = "删除服务器配置",
                    buttons = del_buttons,
                }
                UIManager:show(del_dialog)
            end,
        }})
    else
        table.insert(buttons, 1, {{
            text = "(暂无已存配置, 请先保存当前服务器)",
            callback = function() end,
        }})
    end

    dialog = ButtonDialog:new{
        title = "服务器配置管理",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function LibraryView:openApiKeySetting()
    local setting_data = Backend:getSettings()
    local current_key = H.is_str(setting_data.api_key) and setting_data.api_key or Config.DEFAULT_API_KEY
    local description = [[
X-API-Key 请求头, 用于 Komga 服务器鉴权。
未设置或留空时使用代码内置的默认密钥。
修改后立即持久化生效。]]
    local save_callback = function(input_text)
        if H.is_str(input_text) then
            local new_key = util.trim(input_text)
            if new_key == '' then
                MessageBox:notice('输入为空')
                return false
            end
            return Backend:HandleResponse(Backend:setApiKey(new_key), function(data)
                MessageBox:notice('API Key 已更新')
                return true
            end, function(err_msg)
                MessageBox:notice('设置失败：' .. tostring(err_msg))
                return false
            end)
        end
        MessageBox:notice('输入为空')
        return false
    end
    MessageBox:input(nil, nil, {
        title = "设置 Komga API Key (X-API-Key)",
        input = current_key,
        description = description,
        use_available_height = true,
        fullscreen = true,
        condensed = true,
        save_callback = save_callback,
        allow_newline = false
    })
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

-- Komga 浏览器根目录名: 设置项 browser_dir_name 覆盖默认名(含零宽空格)。
-- 匹配同时接受默认名与自定义名(旧目录下的快捷方式仍可路由); 改名后重启生效。
local DEFAULT_BROWSER_DIR_NAME = "Komga\u{200B}漫画"

local function komga_browser_dir_names()
    local names = {DEFAULT_BROWSER_DIR_NAME}
    local ok, configured = pcall(function()
        return Backend:getSettings().browser_dir_name
    end)
    if ok and H.is_str(configured) and configured ~= "" and configured ~= DEFAULT_BROWSER_DIR_NAME then
        table.insert(names, (configured:gsub("[/\\]", "_")))
    end
    return names
end

-- 路径是否位于 Komga 浏览器目录(默认名或自定义名)之下
local function is_komga_browser_dir_path(file_path)
    if type(file_path) ~= "string" then
        return false
    end
    for _, name in ipairs(komga_browser_dir_names()) do
        if file_path:find("/" .. name .. "/", 1, true) then
            return true
        end
    end
    return false
end

-- 流式双页/翻页方向的设置项显示文案
local stream_dual_mode_label = function(settings)
    local mode = settings.stream_dual_page or "auto"
    if mode == "on" then
        return "[常开]"
    end
    if mode == "off" then
        return "[关闭]"
    end
    return "[自动·横屏]"
end

local stream_rtl_label = function(settings)
    if settings.stream_rtl == nil then
        return "[按书自动]"
    end
    return settings.stream_rtl == true and "[右开本]" or "[左开本]"
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
        text = Icons.FA_PLUG .. " Komga API Key",
        callback = function()
            UIManager:close(dialog)
            self:openApiKeySetting()
        end
    }}, {{
        text = Icons.FA_GLOBE .. " 服务器配置",
        callback = function()
            UIManager:close(dialog)
            self:openServerProfileManager()
        end
    }}, {{
        text = Icons.FA_FOLDER .. " 缓存管理",
        callback = function()
            UIManager:close(dialog)
            self:openCacheManager()
        end
    }}, {{
        text = Icons.FA_MAGNIFYING_GLASS .. " 任务管理",
        callback = function()
            UIManager:close(dialog)
            require("Komga/TaskManagerView").show()
        end
    }}, {{
        text = Icons.FA_PLUG .. " 内存清理",
        callback = function()
            UIManager:close(dialog)
            local res = require("Komga/MemCleaner").sweep()
            MessageBox:notice(string.format("内存清理完成: %.1f MB -> %.1f MB (释放 %.1f MB)",
                res.before / 1024, res.after / 1024, res.freed / 1024))
        end
    }}, {{
        text = string.format("%s 书架排序 [%s]", Icons.FA_BOOK,
            (settings.series_sort_mode == "name" and "名称" or
            settings.series_sort_mode == "updated" and "更新时间" or "最后阅读")),
        callback = function()
            UIManager:close(dialog)
            -- 默认"最后阅读"(刚读完的排最前), 未设置时从此模式起循环
            local order = { last_read = "updated", updated = "name", name = "last_read" }
            settings.series_sort_mode = order[settings.series_sort_mode or "last_read"]
            return Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                if LibraryView.instance and LibraryView.instance.onRefreshLibrary then
                    LibraryView.instance:onRefreshLibrary()
                end
                MessageBox:notice("书架排序：" .. (settings.series_sort_mode == "name" and "名称" or
                    settings.series_sort_mode == "updated" and "更新时间" or "最后阅读"))
                return true
            end, function(err_msg)
                MessageBox:notice('设置失败：' .. tostring(err_msg))
                return false
            end)
        end
    }}, {{
        text_func = function()
            local ok_bm, BookInfoManager = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
            local curr = ok_bm and BookInfoManager.getSetting and BookInfoManager:getSetting("filemanager_display_mode")
            local label = curr == "grid" and "网格" or curr == "list_image_meta" and "列表(元数据)" or "经典列表"
            return Icons.FA_BOOK .. " 视图模式 [" .. label .. "]"
        end,
        callback = function()
            UIManager:close(dialog)
            local ok_plugin, PluginLoader = pcall(require, "pluginloader")
            local cb = ok_plugin and PluginLoader.getPluginInstance and PluginLoader:getPluginInstance("coverbrowser")
            if not (cb and cb.setDisplayMode) then
                MessageBox:notice('未找到 CoverBrowser 插件, 视图切换不可用')
                return
            end
            local ok_bm, BookInfoManager = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
            local curr = ok_bm and BookInfoManager.getSetting and BookInfoManager:getSetting("filemanager_display_mode")
            -- 三态循环: 经典列表 -> 列表(元数据, kokomga 观感: 封面+标题+进度) -> 网格 -> ...
            local cycle = { classic = "list_image_meta", list_image_meta = "grid", grid = "classic" }
            local next_mode = cycle[curr or "classic"] or "list_image_meta"
            pcall(function()
                cb:setDisplayMode(next_mode)
            end)
            local label = next_mode == "grid" and "网格" or next_mode == "list_image_meta" and "列表(元数据)" or "经典列表"
            MessageBox:notice("视图模式：" .. label)
        end
    }}, {{
        text = string.format("%s 整卷原文件模式 %s", Icons.FA_BOOK,
            (settings.whole_file_mode and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "当前: %s \r\n \r\n开启后 EPUB/漫画分卷直接下载原文件(.epub/.cbz)交 KOReader 原生引擎渲染：兼容性最好(原生目录/内链/字体), 但进度定位精度降为整卷比例, 且章节级预载/按需下载失效。关闭则走逐章管线。",
                (settings.whole_file_mode and '[整卷原文件]' or '[逐章管线]')), function(result)
                if result then
                    settings.whole_file_mode = not settings.whole_file_mode and true or nil
                    return Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice("已切换, 下次下载生效")
                        return true
                    end, function(err_msg)
                        MessageBox:notice('设置失败：' .. tostring(err_msg))
                        return false
                    end)
                end
            end)
        end
    }}, {{
        text = string.format("%s 预载数量 [%s]", Icons.FA_BOOK,
            tostring(settings.preload_count or 3)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:input(nil, nil, {
                title = "设置预载数量",
                input = tostring(settings.preload_count or 3),
                description = "阅读时后台预载的后几页(EPUB)或后几卷(漫画), 1-10。",
                condensed = true,
                save_callback = function(input_text)
                    local n = tonumber(input_text)
                    if not n or n < 1 or n > 10 then
                        MessageBox:notice('请输入 1-10 的数字')
                        return false
                    end
                    settings.preload_count = math.floor(n)
                    return Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice("预载数量已更新")
                        return true
                    end, function(err_msg)
                        MessageBox:notice('设置失败：' .. tostring(err_msg))
                        return false
                    end)
                end,
                allow_newline = false
            })
        end
    }}, {{
        text = string.format("%s 调试日志 %s", Icons.FA_PLUG,
            (settings.debug_log and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            settings.debug_log = not settings.debug_log and true or nil
            return Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                require("Komga/Logger").setDebug(settings.debug_log == true)
                MessageBox:notice(string.format("调试日志：%s（写入 komga.log）",
                    settings.debug_log and "开" or "关"))
                return true
            end, function(err_msg)
                MessageBox:notice('设置失败：' .. tostring(err_msg))
                return false
            end)
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
        text = string.format("%s 流式双页模式 %s", Icons.FA_BOOK, stream_dual_mode_label(settings)),
        callback = function()
            UIManager:close(dialog)
            -- 三态循环: 自动(横屏开) -> 常开 -> 关闭
            local order = {"auto", "on", "off"}
            local cur = settings.stream_dual_page or "auto"
            local next_mode = "auto"
            for i, m in ipairs(order) do
                if m == cur and order[i + 1] then
                    next_mode = order[i + 1]
                end
            end
            settings.stream_dual_page = next_mode ~= "auto" and next_mode or nil
            Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                MessageBox:notice("流式双页: " .. stream_dual_mode_label(settings) ..
                    " (重新打开分卷生效)")
            end, function(err_msg)
                MessageBox:error('设置失败:', err_msg)
            end)
        end
    }}, {{
        text = string.format("%s 双页首页为封面 %s", Icons.FA_BOOK,
            (settings.stream_dual_first_cover ~= false and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            -- 开启: 封面独占一屏, 之后 (2,3)(4,5) 配对(漫画书标准拼页); 关闭: (1,2)(3,4)
            settings.stream_dual_first_cover = settings.stream_dual_first_cover == false and true or false
            Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                MessageBox:notice("双页首页为封面: " ..
                    (settings.stream_dual_first_cover ~= false and "开" or "关") ..
                    " (重新打开分卷生效)")
            end, function(err_msg)
                MessageBox:error('设置失败:', err_msg)
            end)
        end
    }}, {{
        text = string.format("%s 流式翻页方向 %s", Icons.FA_BOOK, stream_rtl_label(settings)),
        callback = function()
            UIManager:close(dialog)
            -- 三态循环: 按书自动 -> 右开(RTL) -> 左开(LTR)
            local forced = settings.stream_rtl
            if forced == nil then
                settings.stream_rtl = true
            elseif forced == true then
                settings.stream_rtl = false
            else
                settings.stream_rtl = nil
            end
            Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                MessageBox:notice("流式翻页方向: " .. stream_rtl_label(settings) ..
                    " (重新打开分卷生效)")
            end, function(err_msg)
                MessageBox:error('设置失败:', err_msg)
            end)
        end
    }}, {{
        text = string.format("%s 浏览器目录名 [%s]", Icons.FA_FOLDER,
            settings.browser_dir_name or "默认"),
        callback = function()
            UIManager:close(dialog)
            MessageBox:input(nil, nil, {
                title = "设置 Komga 快捷方式根目录名",
                input = settings.browser_dir_name or DEFAULT_BROWSER_DIR_NAME,
                description = [[书架快捷方式所在的根目录名(位于 KOReader Home 目录下)。
修改后重启 KOReader 生效, 新目录会在下次打开书架时自动创建; 旧目录可自行删除或保留(仍可路由)。]],
                use_available_height = true,
                condensed = true,
                save_callback = function(input_text)
                    if not H.is_str(input_text) then
                        MessageBox:notice('输入为空')
                        return false
                    end
                    local new_name = util.trim(input_text):gsub("[/\\]", "_")
                    if new_name == '' then
                        MessageBox:notice('输入为空')
                        return false
                    end
                    settings.browser_dir_name = new_name ~= DEFAULT_BROWSER_DIR_NAME and new_name or nil
                    return Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice("浏览器目录名已更新, 重启 KOReader 后生效")
                        return true
                    end, function(err_msg)
                        MessageBox:notice('设置失败：' .. tostring(err_msg))
                        return false
                    end)
                end,
                allow_newline = false
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
    local volumes = KomgaModel:new(book_cache_id):getVolumes()
    if not (H.is_tbl(volumes) and #volumes > 0) then
        return
    end
    chunk_size = H.is_num(chunk_size) and chunk_size or 4
    self._bg_volume_sync[book_cache_id] = true
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
            UIManager:scheduleIn(0.03, step)
        else
            self._bg_volume_sync[book_cache_id] = nil
            local fm = FileManager.instance
            if fm and fm.onRefresh then
                pcall(function()
                    fm:onRefresh()
                end)
            end
        end
    end
    UIManager:scheduleIn(0.03, step)
end

-- 章节内进度分数(0..1): 优先 KOReader 写入的 percent_finished, 否则 last_page/doc_pages
function LibraryView:resumeAndOpenVolume(volume)
    local pages = volume.pages
    local is_epub = volume.mediaType == "EPUB"
    local server_frac, server_completed
    local server_target -- EPUB: {number=内部章节, frac=章内比例}
    local local_target  -- EPUB: {number=内部章节, frac=章内比例} 本地断点
    if is_epub then
        -- EPUB: 服务器 locator 自带 href + 章内 progression, 直接映射内部章节定位;
        -- 不依赖 totalProgression 换算页码(各端分页规则不同, 换算会跳错章节)
        -- 未缓存/未浏览过的卷: 数据库可能还没有内部章节清单, 服务器 locator.href 无法反查内部章节,
        -- 续读会退化成从第 1 页打开。这里在 DB 为空时拉取一次 manifest(readingOrder) 入库, 之后 href 反查可用。
        do
            local _, rev = self:epubChapterHrefMap(volume.bookId)
            if not next(rev) then
                local okC, list = pcall(Backend.getAllEpubChapters, Backend, volume)
            end
        end
        local prog = Backend:getBookProgression(volume.bookId)
        local loc = prog and prog.type == "SUCCESS" and prog.body and prog.body.locator
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
            local _, rev = self:epubChapterHrefMap(volume.bookId)
            local s_idx = rev[(href:match("([^/]+)$") or href):lower()]
            if H.is_num(s_idx) then
                server_target = { number = s_idx, frac = math.min(math.max(prog_in_ch, 0), 1) }
            end
        end
        if not server_target and not H.is_num(tp) then
            -- 服务器无 Readium 进度: 回退 readProgress.page/pages(EPUB 页数单位错配, 仅作兜底)
            local resp = Backend:getVolumeReadProgress(volume)
            local rp = resp and resp.body and resp.body.readProgress
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
        local resp = Backend:getVolumeReadProgress(volume)
        local rp = resp and resp.body and resp.body.readProgress
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
        if util.fileExists(fullpath) and name:find("\u{200B}.html", 1, true) then
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
    else
        -- 静默下载: 章节切换不再弹"正在下载正文"对话框(预取命中时本就无需等待;
        -- 未命中时同步下载, 失败仅轻提示, 不打断阅读/关书流程)
        local okdl, dlresp = pcall(Backend.downloadVolume, Backend, chapter)
        if okdl then
            return Backend:HandleResponse(dlresp, function(data)
                if not (H.is_tbl(data) and H.is_str(data.cacheFilePath)) then
                    Backend:show_notice("章节下载失败")
                    return
                end
                data.volume_read = chapter.volume_read
                self:showReaderUI(data)
            end, function(err_msg)
                Backend:show_notice("章节下载失败" .. (H.is_str(err_msg) and (": " .. err_msg) or ""))
            end)
        else
            Backend:show_notice("章节下载失败: " .. H.errorHandler(dlresp))
        end
    end
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
                    cacheExt = bookinfo.cacheExt,
                    origin = bookinfo.origin,
                    originName = bookinfo.originName,
                    originOrder = bookinfo.originOrder
                }, function()
                end, function(chapter)
                    library_view_ref.instance:loadAndRenderChapter(chapter)
                end, true, true)
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
                cacheExt = bookinfo.cacheExt,
                origin = bookinfo.origin,
                originName = bookinfo.originName,
                originOrder = bookinfo.originOrder
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

    table.insert(parent_ref.ui, 3, parent_ref)

    function parent_ref:openFile(file)
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
            local props = custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
            if H.is_tbl(props) and props.number == nil and props.chapters_index ~= nil then
                props.number = props.chapters_index -- 兼容旧版快捷方式(升级前 custom_props 用 chapters_index 存卷号)
            end
            return props
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

            local model = KomgaModel:new(book_cache_id)
            local bookinfo = model and model:getSeries() or nil
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                goto continue
            end

            -- 分卷快捷方式走卷级元数据修复，避免被重写为系列
            local customedata = self:getCustomMateData(fullpath)
            local number = H.is_tbl(customedata) and customedata.number or nil
            if H.is_tbl(customedata) and customedata.type == 'volume' and H.is_num(number) then
                self:refreshVolumeMetadata(nil, fullpath, book_cache_id, number, bookinfo)
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
        local props = custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
        if H.is_tbl(props) and props.number == nil and props.chapters_index ~= nil then
            props.number = props.chapters_index -- 兼容旧版快捷方式(升级前 custom_props 用 chapters_index 存卷号)
        end
        return props
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
            TaskQueue.getChannel("cover", 2):push(function()
                return Backend:download_cover_img(book_cache_id, cover_url)
            end, function(ok, cover_path)
                if ok and H.is_str(cover_path) and util.fileExists(cover_path) then
                    pcall(function()
                        DocSettings:flushCustomCover(book_lnk_path, cover_path)
                    end)
                end
            end, {timeout = 120, tag = "series_cover"})
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

    function book_browser:writeVolLnk(volume, volume_folder, book_cache_id)
        if not (volume_folder and H.is_tbl(volume) and H.is_num(volume.number) and H.is_str(book_cache_id)) then
            logger.err("book_browser.writeVolLnk: parameter error")
            return
        end
        local number = volume.number
        local volume_title = (H.is_str(volume.title) and volume.title ~= "") and volume.title or
            "卷" .. tostring(number)
        -- 卷号补零到 3 位, 避免文件浏览器按文件名排序时 2,10,11... 乱序
        local volume_lnk_name = string.format("%03d-%s\u{200B}.html", number, volume_title)
        volume_lnk_name = util.getSafeFilename(volume_lnk_name)
        if not volume_lnk_name then
            logger.err("book_browser.writeVolLnk: getSafeFilename error")
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

    function book_browser:refreshVolumeMetadata(lnk_name, lnk_path, book_cache_id, number, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_str(book_cache_id) and
            H.is_num(number)) then
            logger.err("browser.refreshVolumeMetadata parameter error")
            return
        end
        local volume = KomgaModel:new(book_cache_id):getVolume(number) -- Komga Book(分卷)
        if not (H.is_tbl(volume) and H.is_num(volume.number)) then
            logger.err("browser.refreshVolumeMetadata no volume data:", book_cache_id, number)
            return
        end
        bookinfo = bookinfo or KomgaModel:new(book_cache_id):getSeries() -- Komga Series
        -- pages 缺失时按 0 处理, 仍写入卷级元数据, 保证点击可打开
        local pages = H.is_num(volume.pages) and volume.pages or 0
        -- pageno: 已读 -> 满进度; 有落盘的服务器空间进度(komga_progress) -> 按它换算(EPUB 与漫画通用);
        -- 缺失时 EPUB 退回累计页数估算, 漫画退回缓存文件 last_page
        local pageno = 0
        if volume.isRead == true then
            pageno = pages
        elseif H.is_num(pages) and pages > 0 then
            local ds = DocSettings:open(lnk_path)
            local komga_prog = ds:readSetting("komga_progress")
            if H.is_num(komga_prog) and komga_prog > 0 and komga_prog <= 1 then
                -- 优先用上传/续读时落盘的服务器空间进度(与服务器显示一致), 避免本地累计/页数模型估算错位
                pageno = math.max(math.min(math.floor(komga_prog * pages + 0.5), pages), 1)
            elseif volume.mediaType == "EPUB" then
                -- EPUB 无服务器空间比例(komga_progress)时:
                -- 1) 主 sidecar 已落盘 percent_finished 表示有真实进度(>第 1 页) -> 保留, 避免被回退成第 1 页 1%
                --    (封面下载完成后 refreshVolumeMetadata 可能被再次触发, 而 komga_progress 尚未落盘, 之前正确显示会被 1% 覆盖)
                -- 2) 否则按累计已读页数估算; 整卷无任何已读痕迹 -> 视为未读(percent=nil, 不显示进度条)
                local existing = ds:readSetting("percent_finished")
                if H.is_num(existing) and existing > (1 / pages) and existing < 1 then
                    pageno = math.max(math.min(math.floor(existing * pages + 0.5), pages), 1)
                else
                    local read_pages = self.parent:calcVolumeLocalRead(book_cache_id, volume.bookId, volume.name)
                    if H.is_num(read_pages) and read_pages > 0 then
                        pageno = math.min(math.max(math.floor(read_pages + 0.5), 1), pages)
                    else
                        pageno = 0 -- 未读: 不显示进度条
                    end
                end
            else
                -- 漫画无落盘比例: 退回缓存文件 last_page
                local cache_chapter = Backend:getCacheVolumeFilePath(volume)
                if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) then
                    local last_page = DocSettings:open(cache_chapter.cacheFilePath):readSetting("last_page")
                    if H.is_num(last_page) and last_page > 0 and last_page <= pages then
                        pageno = last_page
                    end
                end
            end
        end
        -- KOReader 原生显示用进度(0..1): 已读 -> 1; 有进度 -> pageno/pages; 未读 -> nil(FileChooser 显示 "–")
        local percent
        if volume.isRead == true then
            percent = 1
        elseif H.is_num(pages) and pages > 0 and pageno > 0 then
            percent = math.min(pageno / pages, 1)
        end
        local volume_title = (H.is_str(volume.title) and volume.title ~= "") and volume.title or
            (H.is_tbl(bookinfo) and bookinfo.name) or "卷" .. tostring(number)
        -- 无变化则跳过写入，避免每次进入目录都重写并广播事件
        local custom = nil
        local custom_metadata_file = DocSettings:findCustomMetadataFile(lnk_path)
        if custom_metadata_file then
            local custom_settings = DocSettings.openSettingsFile(custom_metadata_file)
            custom = {
                custom_props = custom_settings:readSetting("custom_props"),
                book_cache_id = custom_settings:readSetting("book_cache_id"),
                number = custom_settings:readSetting("number"),
                doc_props = custom_settings:readSetting("doc_props")
            }
        end
        local lnk_ds = DocSettings:open(lnk_path)
        local lnk_percent = lnk_ds:readSetting("percent_finished")
        local lnk_doc_pages = lnk_ds:readSetting("doc_pages")
        local lnk_summary = lnk_ds:readSetting("summary")
        local lnk_status = H.is_tbl(lnk_summary) and lnk_summary.status or nil
        -- 上传/续读落盘的服务器空间进度, 重写 sidecar 时必须保留(data={} 会清空全部设置)
        local lnk_komga_prog = lnk_ds:readSetting("komga_progress")
        local target_status
        if volume.isRead == true then
            target_status = "complete"
        elseif H.is_num(percent) and percent > 0 then
            target_status = "reading"
        end
        if H.is_tbl(custom) and H.is_tbl(custom.custom_props) and custom.custom_props.type == 'volume' and
            custom.custom_props.number == number and
            H.is_tbl(custom.doc_props) and custom.doc_props.pages == pages and custom.doc_props.pageno == pageno and
            custom.book_cache_id == book_cache_id and custom.number == number and
            lnk_percent == percent and lnk_doc_pages == (H.is_num(pages) and pages or nil) and
            lnk_status == target_status and lnk_ds:readSetting("provider") == "komga" then
            return
        end
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            -- bind_provider 写入的 provider 被 data={} 清空, 必须重写:
            -- 否则点击快捷方式时 DocumentRegistry 读不到 komga provider, 会直接用 crengine 打开 html(书籍元信息)
            doc_settings:saveSetting("provider", "komga")
            doc_settings:saveSetting("custom_props", {
                authors = (H.is_tbl(bookinfo) and bookinfo.author) or volume.author,
                title = volume_title,
                description = (H.is_tbl(bookinfo) and bookinfo.intro) or nil,
                -- series/series_index: KOReader 文件管理器/封面浏览器按系列归组显示
                series = (H.is_tbl(bookinfo) and bookinfo.name) or nil,
                series_index = tostring(number),
                type = "volume",
                number = number,
                bookId = volume.bookId
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("number", number)
            doc_settings:saveSetting("doc_props", {
                pages = pages,
                pageno = pageno
            })
            if H.is_num(lnk_komga_prog) then
                -- 保留上传/续读落盘的服务器空间进度, 避免 data={} 清空丢失
                doc_settings:saveSetting("komga_progress", lnk_komga_prog)
            end
            if percent then
                -- 主 sidecar 补写 KOReader 原生进度字段(FileChooser/CoverBrowser/Reading History 读取源)
                doc_settings:saveSetting("percent_finished", percent)
                doc_settings:saveSetting("doc_pages", pages)
                local summary = doc_settings:readSetting("summary") or {}
                summary.status = target_status
                summary.modified = os.date("%Y-%m-%d")
                doc_settings:saveSetting("summary", summary)
            end
            doc_settings:flushCustomMetadata(lnk_path)
            doc_settings:flush()
            self:emitMetadataChanged(lnk_path)
        end
        -- 主 sidecar 也写入 number, 便于 openFile 读取
        local lnk_config = Backend:getLuaConfig(lnk_path)
        if lnk_config and lnk_config.readSetting then
            local old_index = lnk_config:readSetting("number")
            if old_index ~= number then
                lnk_config:saveSetting("number", number):flush()
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
        Backend:runTaskWithRetry(function()
            if DocSettings:findCustomCoverFile(lnk_path) then
                self:emitMetadataChanged(lnk_path)
                return true
            end
        end, 12000, 2000)
        TaskQueue.getChannel("cover", 2):push(function()
            local cover_path_no_ext = Backend:getVolumeCoverCachePath(book_cache_id, chapter.number)
            local cover_path = Backend:download_cover_img(book_cache_id, cover_url, cover_path_no_ext)
            if H.is_str(cover_path) and util.fileExists(cover_path) then
                pcall(function()
                    DocSettings:flushCustomCover(lnk_path, cover_path)
                end)
            end
            return cover_path
        end, nil, {timeout = 120, tag = "volume_cover"})
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
        local volumes = KomgaModel:new(book_cache_id):getVolumes() -- Komga Book 列表(分卷)
        if not (H.is_tbl(volumes) and #volumes > 0) then
            return
        end
        for _, volume in ipairs(volumes) do
            if H.is_num(volume.number) then
                local lnk_path, lnk_name = self:writeVolLnk(volume, volume_folder, book_cache_id)
                if lnk_path and util.fileExists(lnk_path) then
                    self:refreshVolumeMetadata(lnk_name, lnk_path, book_cache_id, volume.number, bookinfo)
                    if not DocSettings:findCustomCoverFile(lnk_path) then
                        self:asyncDownloadVolumeCover(book_cache_id, volume, lnk_path)
                    end
                end
            end
        end
    end


    function book_browser:emitMetadataChanged(path)
        -- CoverBrowser 对每个文件有独立缓存行, 写完 sidecar 后必须删缓存行,
        -- 否则列表/网格一直显示旧元数据(文件名/无进度)
        pcall(function()
            local BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
            if BookInfoManager and BookInfoManager.deleteBookInfo then
                BookInfoManager:deleteBookInfo(path)
            end
        end)
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
            -- bind_provider 写入的 provider 被 data={} 清空, 必须重写, 否则点击快捷方式时 KOReader 不会分发到 komga provider
            doc_settings:saveSetting("provider", "komga")
            doc_settings:saveSetting("custom_props", {
                authors = bookinfo.author,
                title = bookinfo.name,
                description = bookinfo.intro,
                -- series: KOReader 文件管理器/封面浏览器按系列归组显示
                series = bookinfo.name,
                type = "serie"
                --type = bookinfo.type(serie,volume)
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("doc_props", {
                pages = bookinfo.booksCount,
                pageno = bookinfo.durChapterIndex
            })
            -- 系列行进度: 已读卷数/总卷数 -> CoverBrowser 列表进度条
            if H.is_num(bookinfo.booksCount) and bookinfo.booksCount > 0
                and H.is_num(bookinfo.durChapterIndex) and bookinfo.durChapterIndex > 0 then
                doc_settings:saveSetting("percent_finished",
                    math.min(bookinfo.durChapterIndex / bookinfo.booksCount, 1))
                doc_settings:saveSetting("doc_pages", bookinfo.booksCount)
            end
            doc_settings:flushCustomMetadata(lnk_path)
            self:emitMetadataChanged(lnk_path)
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
        if item.continue_read then
            -- 直达上次阅读的那卷(走完整分卷打开/续读流程)
            self.parent_ref:openVolumeShortcut(item.cache_id, item.number, nil)
            return
        end
        local model = KomgaModel:new(item.cache_id)
        local bookinfo = model and model:getSeries() or nil
        self.parent_ref.selected_item = item
        self.parent_ref.onReturnCallback = function()
            self:show_view()
            self:refreshItems(true)
        end
        self.parent_ref.book_toc = ChapterListing:fetchAndShow({
            cache_id = bookinfo.cache_id,
            url = bookinfo.url,
            durChapterIndex = bookinfo.durChapterIndex,
            name = bookinfo.name,
            author = bookinfo.author,
            cacheExt = bookinfo.cacheExt,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder
        }, self.parent_ref.onReturnCallback, function(chapter)
            self.parent_ref.instance:loadAndRenderChapter(chapter)
        end, true)
        UIManager:nextTick(function()
            Backend:autoPinToTop(bookinfo.cache_id, bookinfo.sortOrder)
            self.parent_ref:addBkShortcut(bookinfo)
        end)
        self:onClose()
    end

    function book_menu:onRefreshLibrary()
        -- beforeWifi 模式: 离线时提示联网, 联网后自动补跑(而非静默失败)
        if not NetworkMgr:isConnected() then
            MessageBox:notice("当前离线：连接网络后将自动刷新书架")
            NetworkMgr:runWhenOnline(function()
                pcall(function() self:onRefreshLibrary() end)
            end)
            return
        end
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
                        MessageBox:notice('同步失败', err_msg)
                    end)
                end
            end)
    end

    function book_menu:onMenuHold(item)
        local model = KomgaModel:new(item.cache_id)
        local bookinfo = model and model:getSeries() or nil
        local msginfo = [[
书名： <<%1>>
作者： %2
分类： %3
总卷数：%4
简介：%5
    ]]

        msginfo = T(msginfo, bookinfo.name or '', bookinfo.author or '', bookinfo.kind or '',
            bookinfo.booksCount or '', bookinfo.intro or '')

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
        -- 书架顶部"继续阅读": 最近读过且有进度定位的系列, 直达上次那卷
        for _, b in ipairs(books) do
            if H.is_num(b.durChapterIndex) and b.durChapterIndex > 0
                and H.is_num(b.lastRead) and b.lastRead > 0 then
                item_table[1] = {
                    continue_read = true,
                    cache_id = b.cache_id,
                    number = b.durChapterIndex,
                    text = string.format("%s 继续阅读: %s (卷 %s)", Icons.FA_PLAY,
                        tostring(b.name), tostring(b.durChapterIndex)),
                    mandatory = Icons.FA_PLAY,
                }
                break
            end
        end
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
    -- 根目录名可配置(设置项 browser_dir_name), 缺省用内置名; 不允许路径分隔符
    local browser_dir_name = Backend:getSettings().browser_dir_name
    if not (H.is_str(browser_dir_name) and browser_dir_name ~= "") then
        browser_dir_name = DEFAULT_BROWSER_DIR_NAME
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
