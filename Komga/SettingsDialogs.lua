--[[ Komga/SettingsDialogs.lua — 设置对话框/服务器配置/设置大菜单(自 LibraryView 拆出)

install(LibraryView) 把这些方法装回 LibraryView 表: 函数体保持原样(self 仍指向
LibraryView 实例), LibraryView 以参数注入, 避免模块环。
]]
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local T = require("ffi/util").template
local _ = require("gettext")
local util = require("util")
local Device = require("device")
local DocSettings = require("docsettings")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Icons = require("Komga/Icons")
local Backend = require("Komga/Backend")
local MessageBox = require("Komga/MessageBox")
local Config = require("Komga/Config")
local H = require("Komga/Helper")
local Paths = require("Komga/Paths")

return function(LibraryView)
-- 保存设置并统一提示: 成功走 on_ok(自定义成功提示), 失败弹统一错误提示;
-- 收编 openMenu 各设置项重复的 HandleResponse+saveSettings 样板
local function saveSettingsAndNotify(settings, on_ok)
    return Backend:HandleResponse(Backend:saveSettings(settings), function(data)
        if on_ok then
            on_ok(data)
        end
        return true
    end, function(err_msg)
        MessageBox:notice('设置失败：' .. tostring(err_msg))
        return false
    end)
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
        → IPv6 地址   http://[fd00::1]:25600
        (IPv6 字面量必须带方括号, 否则端口无法正确解析)
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
    local max_mb = math.floor((usage.max_bytes or 0) / 1024 / 1024)
    -- 占用由 refreshCacheUsageAsync 后台统计并缓存; 未统计时点"重新统计"获取
    local used_label
    if H.is_num(usage.used_bytes) then
        used_label = string.format("可清理缓存占用: %d MB / 上限 %d MB",
            math.floor(usage.used_bytes / 1048576), max_mb)
    else
        used_label = string.format("可清理缓存占用: 尚未统计 / 上限 %d MB", max_mb)
    end
    local dialog
    local buttons = {}

    table.insert(buttons, {{
        text = used_label,
        callback = function() end,
    }})
    table.insert(buttons, {{
        text = Icons.FA_REFRESH .. " 重新统计占用",
        callback = function()
            UIManager:close(dialog)
            Backend:refreshCacheUsageAsync(function()
                self:openCacheManager()
            end)
        end,
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
                    return saveSettingsAndNotify(settings, function(data)
                        MessageBox:notice("缓存上限已更新")
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

-- 账号密码自动获取 API Key(参考 kokomga): Basic 鉴权调 Komga 的
-- POST /api/v2/users/me/api-keys(Komga >= 1.11)。两步输入用户名/密码,
-- 密码仅本次使用不保存; 成功后自动写入 api_key 并持久化。
function LibraryView:openApiKeyLogin()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local setting_data = Backend:getSettings()
    local dialog
    dialog = MultiInputDialog:new{
        title = "账号密码获取 API Key(需要 Komga 1.11+)",
        fields = {
            {
                text = H.is_str(setting_data.login_username) and setting_data.login_username or "",
                hint = "用户名(默认保存)",
            },
            {
                hint = "密码(仅本次使用, 不保存)",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "登录并生成",
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local username = util.trim(fields[1] or "")
                        local password = fields[2] or ""
                        if username == "" or password == "" then
                            MessageBox:notice("用户名和密码不能为空")
                            return
                        end
                        -- 默认保存用户名(不保存密码)
                        local sd = Backend:getSettings()
                        sd.login_username = username
                        Backend:saveSettings()
                        UIManager:close(dialog)
                        Backend:closeDbManager()
                        MessageBox:loading("正在登录并生成 API Key", function()
                            return Backend:generateApiKeyWithCredentials(username, password)
                        end, function(state, response)
                            if state ~= true then
                                MessageBox:error("登录失败：任务被取消")
                                return
                            end
                            Backend:HandleResponse(response, function(new_key)
                                local r = Backend:setApiKey(new_key)
                                if H.is_tbl(r) and r.type == "SUCCESS" then
                                    -- 同步更新匹配地址的服务器档案, 避免切换档案时把新 key 冲掉
                                    local sd = Backend:getSettings()
                                    if H.is_tbl(sd.server_profiles) then
                                        local changed = false
                                        for _, profile in ipairs(sd.server_profiles) do
                                            if profile.server_address == sd.server_address
                                                and profile.api_key ~= new_key then
                                                profile.api_key = new_key
                                                changed = true
                                            end
                                        end
                                        if changed then
                                            Backend:saveSettings()
                                        end
                                    end
                                    MessageBox:notice("API Key 获取成功, 已自动填入")
                                else
                                    MessageBox:error("保存失败: " .. tostring(r and r.message))
                                end
                            end, function(err_msg)
                                MessageBox:error("获取失败: " .. tostring(err_msg))
                            end)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibraryView:openBrowserMenu(file)
    self:getInstance()
    self:getBrowserWidget()
    -- 分卷快捷方式分流到卷级菜单（此入口仅对 /Komga漫画/ 下的文件触发）
    if H.is_str(file) and file:find(Paths.LNK_SUFFIX, 1, true) then
        local customedata = H.getCustomProps(file)
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
    -- 多级菜单: 子菜单复用主菜单对话框样式; dialog 为所有按钮闭包共享的 upvalue,
    -- 各按钮内原有的 UIManager:close(dialog) 关闭的是当前所在层
    local function showSubmenu(title, btns)
        dialog = require("ui/widget/buttondialog"):new{
            title = title,
            title_align = "center",
            title_face = Font:getFace("x_smalltfont"),
            info_face = Font:getFace("tfont"),
            buttons = btns,
        }
        UIManager:show(dialog)
    end

    local function backRow()
        return {{
            text = Icons.UNICODE_ARROW_LEFT .. " 返回主菜单",
            callback = function()
                UIManager:close(dialog)
                self:openMenu()
            end
        }}
    end

    -- 服务器
    local function serverButtons()
        local rows = {
            {
                {
        text = Icons.FA_GLOBE .. " Komga WEB地址",
        callback = function()
            UIManager:close(dialog)
            self:openInstalledReadSource()
        end
                }
            },
            {
                {
        text = Icons.FA_PLUG .. " Komga API Key",
        callback = function()
            UIManager:close(dialog)
            self:openApiKeySetting()
        end
                }
            },
            {
                {
        text = Icons.FA_PLUG .. " 账号密码获取 API Key",
        callback = function()
            UIManager:close(dialog)
            self:openApiKeyLogin()
        end
                }
            },
            {
                {
        text = Icons.FA_GLOBE .. " 服务器配置",
        callback = function()
            UIManager:close(dialog)
            self:openServerProfileManager()
        end
                }
            },
        }
        table.insert(rows, backRow())
        return rows
    end

    -- 阅读偏好
    local function readingButtons()
        local rows = {
            {
                {
        text = string.format("%s 阅读模式 %s", Icons.FA_BOOK,
            (settings.reading_mode == "stream" and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            local new_mode = (settings.reading_mode == "stream") and "whole" or "stream"
            MessageBox:confirm(string.format(
                "当前: %s \r\n \r\n切换到: %s\r\n \r\n[流式] 漫画边看边下载, 不占空间, 对网络要求较高。\r\n[整卷] 漫画/EPUB 分卷下载原文件(.epub/.cbz)交 KOReader 原生引擎渲染：兼容性最好(原生目录/内链/字体), 占用缓存空间。",
                (settings.reading_mode == "stream" and '[流式]' or '[整卷]'),
                (new_mode == "stream" and '[流式]' or '[整卷]')), function(result)
                if result then
                    settings.reading_mode = new_mode
                    -- 同步旧键, 降级回旧版插件时行为一致
                    settings.stream_image_view = (new_mode == "stream") and true or nil
                    settings.whole_file_mode = (new_mode == "whole") and true or nil
                    return saveSettingsAndNotify(settings, function(data)
                        MessageBox:notice("已切换, 对新打开的分卷生效")
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end
                }
            },
            {
                {
        text = string.format("%s 智能旋转(流式横页自动转屏) %s", Icons.FA_BOOK,
            ((G_reader_settings and G_reader_settings:isTrue("imageviewer_rotate_auto_for_best_fit")) and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            local cur = G_reader_settings and G_reader_settings:isTrue("imageviewer_rotate_auto_for_best_fit")
            G_reader_settings:saveSetting("imageviewer_rotate_auto_for_best_fit", not cur)
            G_reader_settings:flush()
            MessageBox:notice(cur and "已关闭, 下次打开流式分卷生效" or "已开启, 横版页面将自动旋转铺满屏幕")
        end
                }
            },
            {
                {
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
                    return saveSettingsAndNotify(settings, function(data)
                        MessageBox:notice("预载数量已更新")
                    end)
                end,
                allow_newline = false
            })
        end
                }
            },
            {
                {
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
            saveSettingsAndNotify(settings, function(data)
                MessageBox:notice("流式双页: " .. stream_dual_mode_label(settings) ..
                    " (重新打开分卷生效)")
            end)
        end
                }
            },
            {
                {
        text = string.format("%s 双页首页为封面 %s", Icons.FA_BOOK,
            (settings.stream_dual_first_cover ~= false and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            -- 开启: 封面独占一屏, 之后 (2,3)(4,5) 配对(漫画书标准拼页); 关闭: (1,2)(3,4)
            settings.stream_dual_first_cover = settings.stream_dual_first_cover == false and true or false
            saveSettingsAndNotify(settings, function(data)
                MessageBox:notice("双页首页为封面: " ..
                    (settings.stream_dual_first_cover ~= false and "开" or "关") ..
                    " (重新打开分卷生效)")
            end)
        end
                }
            },
            {
                {
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
            saveSettingsAndNotify(settings, function(data)
                MessageBox:notice("流式翻页方向: " .. stream_rtl_label(settings) ..
                    " (重新打开分卷生效)")
            end)
        end
                }
            },
        }
        table.insert(rows, backRow())
        return rows
    end

    -- 书架
    local function shelfButtons()
        local rows = {
            {
                {
        text = string.format("%s 书架排序 [%s]", Icons.FA_BOOK,
            (settings.series_sort_mode == "name" and "名称" or
            settings.series_sort_mode == "updated" and "更新时间" or "最后阅读")),
        callback = function()
            UIManager:close(dialog)
            -- 默认"最后阅读"(刚读完的排最前), 未设置时从此模式起循环
            local order = { last_read = "updated", updated = "name", name = "last_read" }
            settings.series_sort_mode = order[settings.series_sort_mode or "last_read"]
            return saveSettingsAndNotify(settings, function(data)
                if LibraryView.instance and LibraryView.instance.onRefreshLibrary then
                    LibraryView.instance:onRefreshLibrary()
                end
                MessageBox:notice("书架排序：" .. (settings.series_sort_mode == "name" and "名称" or
                    settings.series_sort_mode == "updated" and "更新时间" or "最后阅读"))
            end)
        end
                }
            },
            {
                {
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
                }
            },
        }
    -- 非触屏设备无下拉刷新, 书架子菜单提供显式同步入口
    if not Device:isTouchDevice() then
        table.insert(rows, {{
            text = Icons.FA_EXCLAMATION_CIRCLE .. ' ' .. " 同步书架",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshLibrary()
            end
        }})
    end

        table.insert(rows, backRow())
        return rows
    end

    -- 快捷方式
    local function browserButtons()
        local rows = {
            {
                {
        text = string.format("%s 浏览器目录名 [%s]", Icons.FA_FOLDER,
            settings.browser_dir_name or "默认"),
        callback = function()
            UIManager:close(dialog)
            MessageBox:input(nil, nil, {
                title = "设置 Komga 快捷方式根目录名",
                input = settings.browser_dir_name or Paths.DEFAULT_BROWSER_DIR_NAME,
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
                    settings.browser_dir_name = new_name ~= Paths.DEFAULT_BROWSER_DIR_NAME and new_name or nil
                    return saveSettingsAndNotify(settings, function(data)
                        MessageBox:notice("浏览器目录名已更新, 重启 KOReader 后生效")
                    end)
                end,
                allow_newline = false
            })
        end
                }
            },
            {
                {
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
                    saveSettingsAndNotify(settings, function(data)
                        MessageBox:notice(ok_msg)
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end
                }
            },
        }
        table.insert(rows, backRow())
        return rows
    end

    -- 缓存与维护
    local function maintenanceButtons()
        local rows = {
            {
                {
        text = Icons.FA_HISTORY .. " 从 Komga 同步阅读历史",
        callback = function()
            UIManager:close(dialog)
            require("Komga/HistorySync").sync(self)
        end
                }
            },
            {
                {
        text = string.format("%s 书架刷新后自动同步历史 %s", Icons.FA_HISTORY,
            (settings.history_sync_auto and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            settings.history_sync_auto = not settings.history_sync_auto and true or nil
            return saveSettingsAndNotify(settings, function(data)
                MessageBox:notice("书架刷新后自动同步历史: " ..
                    (settings.history_sync_auto and "开" or "关"))
            end)
        end
                }
            },
            {
                {
        text = string.format("%s 历史同步条数 [%s]", Icons.FA_HISTORY,
            tostring(settings.history_sync_limit or 20)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:input(nil, nil, {
                title = "设置历史同步条数",
                input = tostring(settings.history_sync_limit or 20),
                description = "从 Komga 同步\"在读\"历史到本地的最大条数, 5-100。",
                condensed = true,
                save_callback = function(input_text)
                    local n = tonumber(input_text)
                    if not n or n < 5 or n > 100 then
                        MessageBox:notice('请输入 5-100 的数字')
                        return false
                    end
                    settings.history_sync_limit = math.floor(n)
                    return saveSettingsAndNotify(settings, function(data)
                        MessageBox:notice("历史同步条数已更新")
                    end)
                end,
                allow_newline = false
            })
        end
                }
            },
            {
                {
        text = Icons.FA_FOLDER .. " 缓存管理",
        callback = function()
            UIManager:close(dialog)
            self:openCacheManager()
        end
                }
            },
            {
                {
        text = Icons.FA_MAGNIFYING_GLASS .. " 任务管理",
        callback = function()
            UIManager:close(dialog)
            require("Komga/TaskManagerView").show()
        end
                }
            },
            {
                {
        text = Icons.FA_PLUG .. " 内存清理",
        callback = function()
            UIManager:close(dialog)
            local res = require("Komga/MemCleaner").sweep()
            MessageBox:notice(string.format("内存清理完成: %.1f MB -> %.1f MB (释放 %.1f MB)",
                res.before / 1024, res.after / 1024, res.freed / 1024))
        end
                }
            },
            {
                {
        text = string.format("%s 调试日志 %s", Icons.FA_PLUG,
            (settings.debug_log and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            settings.debug_log = not settings.debug_log and true or nil
            return saveSettingsAndNotify(settings, function(data)
                require("Komga/Logger").setDebug(settings.debug_log == true)
                MessageBox:notice(string.format("调试日志：%s（写入 komga.log）",
                    settings.debug_log and "开" or "关"))
            end)
        end
                }
            },
            {
                {
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
                }
            },
        }
        table.insert(rows, backRow())
        return rows
    end

    local buttons = {
        {
            {
                text = Icons.FA_GLOBE .. "服务器",
                callback = function()
                    UIManager:close(dialog)
                    showSubmenu("Komga 设置 · 服务器", serverButtons())
                end
            },
            {
                text = Icons.FA_BOOK .. "阅读偏好",
                callback = function()
                    UIManager:close(dialog)
                    showSubmenu("Komga 设置 · 阅读偏好", readingButtons())
                end
            },
        },
        {
            {
                text = Icons.FA_BOOK .. "书架",
                callback = function()
                    UIManager:close(dialog)
                    showSubmenu("Komga 设置 · 书架", shelfButtons())
                end
            },
            {
                text = Icons.FA_FOLDER .. "快捷方式",
                callback = function()
                    UIManager:close(dialog)
                    showSubmenu("Komga 设置 · 快捷方式", browserButtons())
                end
            },
        },
        {
            {
                text = Icons.FA_DATABASE .. "缓存与维护",
                callback = function()
                    UIManager:close(dialog)
                    showSubmenu("Komga 设置 · 缓存与维护", maintenanceButtons())
                end
            },
            {
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
            -- 版本号以 _meta.lua 为单一来源(此前 About 面板写死 1.0.0, 与 _meta 的 1.0.3 漂移)
            local ok_meta, meta = pcall(require, "_meta")
            local curren_version = (ok_meta and H.is_str(meta.version)) and meta.version or "unknown"
            about_txt = T(about_txt, Icons.FA_DOWNLOAD, Icons.FA_CHECK_CIRCLE, Icons.FA_THUMB_TACK, curren_version)
            MessageBox:custom({
                text = about_txt,
                alignment = "left"
            })
        end
            },
        }
    }

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

end
