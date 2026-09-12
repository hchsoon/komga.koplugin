local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")

local _ = require("gettext")

local function custom_concat(tbl, sep)
    sep = sep or ""
    local result = {}

    for i, v in ipairs(tbl) do
        if v == nil then
            result[i] = "nil"
        elseif type(v) == "table" then

            result[i] = "{" .. custom_concat(v, ",") .. "}"
        else
            result[i] = tostring(v)
        end
    end

    return table.concat(result, sep)
end

local M = {}

function M:custom(options)
    local defaultOptions = {
        text = '',
        icon = "notice-info",

        timeout = nil,

        alignment = "left",
        modal = true,

        _timeout_func = nil
    }
    if options then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end
    local dialog = InfoMessage:new(defaultOptions)
    UIManager:show(dialog)
    return dialog
end

local function pick_timeout(args)
    if #args > 0 and type(args[1]) == "number" then
        return table.remove(args, 1)
    end
    return nil
end

local function join_args(message, args)
    if #args > 0 then
        return message .. " " .. custom_concat(args, " ")
    end
    return message
end

-- error/success 两态同构: 仅图标与是否过 gettext 不同
local function notify_dialog(message, icon, timeout, wrap_gettext)
    return M:custom({
        text = wrap_gettext and _(message) or message,
        icon = icon,
        timeout = timeout
    })
end

function M:error(message, ...)
    local args = {...}
    local timeout = pick_timeout(args)
    return notify_dialog(join_args(message, args), "notice-warning", timeout)
end

function M:success(message, ...)
    local args = {...}
    local timeout = pick_timeout(args)
    return notify_dialog(join_args(message, args), "check", timeout, true)
end

function M:confirm(message, callback, options)

    local dialog
    local defaultOptions = {
        text = message,

        timeout = nil

    }

    if options then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end

    if callback then
        defaultOptions.ok_callback = function()
            callback(true)
            UIManager:close(dialog)
        end
        defaultOptions.cancel_callback = function()
            callback(false)
            UIManager:close(dialog)
        end
    end

    dialog = ConfirmBox:new(defaultOptions)
    UIManager:show(dialog)

    if defaultOptions.timeout then
        UIManager:scheduleIn(defaultOptions.timeout, function()
            UIManager:close(dialog)
        end)
    end
    return dialog
end

function M:input(message, callback, options)
    local dialog = {}

    local defaultOptions = {
        title = "",

        input_hint = "",

        description = _(message),

        buttons = {{{
            text = _("Cancel"),

            callback = function()
                if callback then
                    callback(nil)
                end
                UIManager:close(dialog)
            end
        }, {
            text = _("OK"),

            is_enter_default = true,

            callback = function()
                local input_text = dialog:getInputText()
                if callback then
                    callback(input_text)
                end
                UIManager:close(dialog)
            end
        }}},
        timeout = nil

    }

    if not callback then
        defaultOptions.buttons = nil
    end

    if options then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end

    dialog = InputDialog:new(defaultOptions)
    UIManager:show(dialog)
    dialog:onShowKeyboard()

    if defaultOptions.timeout then
        UIManager:scheduleIn(defaultOptions.timeout, function()
            UIManager:close(dialog)
        end)
    end
    return dialog
end

function M:loading(message, runnable, callback, options)
    local defaultOptions = {
        text = "\u{231B}  " .. message .. " ...",
        dismissable = false
    }

    if type(options) == 'table' then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end

    -- 单控件: 创建一次、显示一次。旧实现每 0.2s new 一个 InfoMessage 且从不
    -- close 旧的, 30 秒操作会在 UIManager 窗口栈堆 ~150 个全屏控件, 每次 show
    -- 还触发一次全屏刷屏(墨水屏闪屏)。转圈动画本就以高频全刷为代价, 改为静态
    -- "请稍候"(KOReader 自家 Trapper:info 同款形态); dismiss_callback 由
    -- Trapper:dismissableRunInSubprocess 挂在本控件上, 取消语义不变。
    local message_dialog = InfoMessage:new(defaultOptions)
    UIManager:show(message_dialog)

    Trapper:wrap(function()
        local completed, return_values = Trapper:dismissableRunInSubprocess(runnable, message_dialog)

        UIManager:close(message_dialog)

        if type(callback) == 'function' then
            if not completed then
                callback(false, "Task was cancelled or failed to complete")
            else
                callback(true, return_values)
            end
        end
    end)
end

function M:notice(msg, timeout)
    if timeout then
        -- 指定展示时长: 直接构造(Notice:notify 的第三参是 refresh_after, 不是时长)
        UIManager:show(Notification:new{ text = msg or '', timeout = timeout })
    else
        Notification:notify(msg or '', Notification.SOURCE_ALWAYS_SHOW)
    end
end

return M
