--[[
Komga/TaskManagerView.lua — 后台任务管理器(rakuyomi TaskManagerView 的轻量对应物)

- 列出 TaskQueue 全部通道的排队/运行中任务(通道、标签、状态)
- 点击任务 → 确认取消(排队: 移除; 运行中: 终止子进程)
- 打开期间每 2s 自动刷新并保持聚焦; 关闭停止刷新
]]
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")

local TaskQueue = require("Komga/TaskQueue")

local M = {}

local STATUS_TEXT = { running = "运行中", queued = "排队中" }

local view = nil
local active = false

local function onCancelTask(channel, id)
    UIManager:show(ConfirmBox:new{
        text = string.format("取消任务 [%s] #%d?", tostring(channel), tonumber(id) or -1),
        ok_text = "取消任务",
        cancel_text = "返回",
        ok_callback = function()
            TaskQueue.cancel(channel, id)
        end,
    })
end

local function buildItems()
    local items = {}
    local tasks = TaskQueue.listAll()
    if #tasks == 0 then
        items[1] = {
            text = "当前没有后台任务",
            dim = true,
            select_enabled = false,
        }
        return items
    end
    for _, t in ipairs(tasks) do
        local channel, id = t.channel, t.id
        items[#items + 1] = {
            task_id = id,
            text = string.format("[%s] #%d %s — %s",
                tostring(channel), t.id, tostring(t.tag or "未命名"),
                STATUS_TEXT[t.status] or tostring(t.status)),
            mandatory = "取消",
            callback = function()
                onCancelTask(channel, id)
            end,
        }
    end
    return items
end

local function refreshKeepingFocus()
    if not (active and view) then
        return
    end
    local focused = view.item_table and view.item_table[view.selected_item or 1]
    local keep_id = focused and focused.task_id
    view:switchItemTable(buildItems())
    if keep_id then
        for i, it in ipairs(view.item_table) do
            if it.task_id == keep_id then
                view.selected_item = i
                break
            end
        end
    end
    UIManager:scheduleIn(2, refreshKeepingFocus)
end

function M.show()
    if view then
        active = false
        pcall(function()
            UIManager:close(view)
        end)
        view = nil
    end
    active = true
    view = Menu:new{
        title = "后台任务管理",
        item_table = buildItems(),
        is_borderless = true,
        is_popout = false,
        fullscreen = true,
        covers_fullscreen = true,
        close_callback = function()
            active = false
            view = nil
        end,
    }
    UIManager:show(view)
    refreshKeepingFocus()
    return view
end

return M
