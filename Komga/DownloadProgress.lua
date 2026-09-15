--[[
Komga/DownloadProgress.lua — 整卷下载进度(参考 komix 的 DownloadDialog + 轮询架构)

- 整卷文件(.epub/.cbz)下载在子进程执行, 父进程无法直接读取子进程内存,
  因此子进程把 (已下载字节, 总字节) 写进状态文件, 父进程每秒轮询该文件
  并刷新进度对话框与后台任务管理的任务标签(卷名 + 百分比)。
- 取消: 经 TaskQueue 取消子进程, .part 文件保留 —— 断网/取消后的重试
  会从 .part 断点续传(Range 请求), 不整卷重来。
- 隐藏: 仅关闭对话框, 下载继续; 进度仍可在后台任务管理中查看。
- 单下载通道("download" workers=1), 同时只有一个整卷下载, 故作业为单例。
]]
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Blitbuffer = require("blitbuffer")
local Size = require("ui/size")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local ButtonTable = require("ui/widget/buttontable")
local TaskQueue = require("Komga/TaskQueue")
local H = require("Komga/Helper")

local M = {}

local job = nil -- 单例: { key, title, state_path, channel, task_id, got, total, dialog, hidden, on_cancelled }

local function formatSize(bytes)
    if not (type(bytes) == "number" and bytes > 0) then
        return "0 KB"
    end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / 1024 / 1024)
    end
    return string.format("%d KB", math.floor(bytes / 1024))
end

-- 读取子进程落盘的状态: "got total"(total 可能为 0 = 未知)
local function readState(state_path)
    local f = io.open(state_path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    local got, total = content:match("^(%d+)%s+(%d+)")
    return tonumber(got), tonumber(total)
end

local function buildDialog(j)
    local content_width = Screen:getWidth() - 96
    local group = VerticalGroup:new{
        separators = {},
    }
    table.insert(group, TextBoxWidget:new{
        text = j.title,
        face = Font:getFace("smallinfofontbold"),
        width = content_width,
    })
    table.insert(group, VerticalSpan:new{ width = Size.padding.default })
    if j.total and j.total > 0 then
        j.progress_bar = ProgressWidget:new{
            width = content_width,
            height = Screen:scaleBySize(9),
            percentage = 0,
        }
        table.insert(group, j.progress_bar)
    end
    j.status_text = TextBoxWidget:new{
        text = "准备下载…",
        face = Font:getFace("smallinfofont"),
        width = content_width,
    }
    table.insert(group, VerticalSpan:new{ width = Size.padding.default })
    table.insert(group, j.status_text)
    local button_table = ButtonTable:new{
        width = content_width,
        buttons = {
            {
                {
                    text = "隐藏",
                    callback = function()
                        M.hide()
                    end,
                },
                {
                    text = "取消下载",
                    callback = function()
                        M.cancel()
                    end,
                },
            },
        },
    }
    table.insert(group, VerticalSpan:new{ width = Size.padding.default })
    table.insert(group, button_table)

    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:getWidth() - 96, h = group:getSize().h },
            group,
        },
    }
end

local function updateDialog(j)
    if j.hidden or not j.dialog then
        return
    end
    local pct_text = ""
    if j.total and j.total > 0 then
        local pct = math.min(j.got / j.total, 1)
        if j.progress_bar then
            j.progress_bar:setPercentage(pct)
        end
        pct_text = string.format("%d%%  ", math.floor(pct * 100 + 0.5))
    end
    j.status_text:setText(pct_text .. formatSize(j.got) ..
        (j.total and j.total > 0 and (" / " .. formatSize(j.total)) or ""))
end

-- 同步任务标签到后台任务管理(卷名 + 百分比)
local function updateTaskTag(j)
    if not (j.channel and j.task_id) then
        return
    end
    local tag
    if j.total and j.total > 0 then
        local pct = math.floor(math.min(j.got / j.total, 1) * 100 + 0.5)
        tag = string.format("下载分卷: %s — %d%% (%s)", j.title, pct, formatSize(j.got))
    else
        tag = string.format("下载分卷: %s — %s", j.title, formatSize(j.got))
    end
    pcall(function()
        TaskQueue.setTaskTag(j.channel, j.task_id, tag)
    end)
end

local function poll()
    if not job then
        return
    end
    local got, total = readState(job.state_path)
    if got and got > (job.got or 0) then
        job.got = got
    end
    if total and total > 0 then
        job.total = total
    end
    updateDialog(job)
    updateTaskTag(job)
    UIManager:scheduleIn(1, poll)
end

-- 开始一个整卷下载作业
-- opts: { key, title, state_path, channel, task_id, on_cancelled }
function M.start(opts)
    if not (H.is_tbl(opts) and H.is_str(opts.key) and H.is_str(opts.state_path)) then
        return
    end
    M.finish() -- 单下载通道, 保险起见先清理旧作业
    job = {
        key = opts.key,
        title = opts.title or "分卷",
        state_path = opts.state_path,
        channel = opts.channel,
        task_id = opts.task_id,
        got = 0,
        total = nil,
        hidden = false,
        on_cancelled = opts.on_cancelled,
    }
    local frame = buildDialog(job)
    job.dialog = frame
    UIManager:show(frame)
    updateTaskTag(job)
    poll()
end

-- 作业结束(成功/失败/取消): 关对话框, 清理状态文件与注册
function M.finish()
    if not job then
        return
    end
    if job.dialog then
        pcall(function()
            UIManager:close(job.dialog)
        end)
    end
    pcall(function()
        local f = io.open(job.state_path, "w")
        if f then
            f:close()
        end
    end)
    job = nil
end

-- 隐藏对话框(下载继续, 后台任务管理仍可见)
function M.hide()
    if job and job.dialog then
        pcall(function()
            UIManager:close(job.dialog)
        end)
        job.hidden = true
    end
end

-- 取消下载: 经 TaskQueue 终止子进程, .part 保留供断点续传
function M.cancel()
    if not job then
        return
    end
    local j = job
    job = nil
    if j.dialog then
        pcall(function()
            UIManager:close(j.dialog)
        end)
    end
    if j.channel and j.task_id then
        pcall(function()
            TaskQueue.cancel(j.channel, j.task_id)
        end)
    end
    if H.is_func(j.on_cancelled) then
        pcall(j.on_cancelled)
    end
    if H.diagLog then
        pcall(H.diagLog, "download cancelled: " .. tostring(j.title))
    end
end

-- 供后台任务管理读取进度摘要(nil = 无整卷下载作业)
function M.currentSummary()
    if not job then
        return nil
    end
    if job.total and job.total > 0 then
        local pct = math.floor(math.min(job.got / job.total, 1) * 100 + 0.5)
        return string.format("%d%% (%s)", pct, formatSize(job.got))
    end
    return formatSize(job.got)
end

return M
