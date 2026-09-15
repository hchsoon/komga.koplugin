--[[
Komga/TaskQueue.lua — 具名任务通道(设计参考 legado.koplugin task/Queue, 适配本插件体量)

- 每个通道(getChannel(name, max_workers))独立队列与并发上限;
  本插件的后台域约定: "pages"/"stream"/"volume" 均为 1 worker, "cover" 为 2
- 任务经 Komga/Async.run 在子进程执行: 超时/终止/回收由 Async 托管,
  fork 不可用时 Async 自动同步降级(此时任务在主进程串行执行)
- 失败即终局并回调 (false, nil, err); 支持按 id 取消与清空队列
]]
local logger = require("logger")

-- Async 延迟绑定(避免模块加载顺序问题, 且便于测试桩替换)
local Async_run_guarded = function(func, callback, opts)
    local Async = require("Komga/Async")
    return Async.run(func, callback, opts)
end

local TaskQueue = {
    channels = {},
}

local Channel = {}
Channel.__index = Channel

function TaskQueue.getChannel(name, max_workers)
    local ch = TaskQueue.channels[name]
    if not ch then
        ch = setmetatable({
            name = name,
            max_workers = math.max(1, max_workers or 1),
            active = 0,
            queue = {},
            seq = 0,
            tasks = {}, -- id -> task(queued/running + handle)
        }, Channel)
        TaskQueue.channels[name] = ch
    end
    return ch
end

function TaskQueue.listAll()
    local out = {}
    for name, ch in pairs(TaskQueue.channels) do
        for _, t in ipairs(ch:list()) do
            out[#out + 1] = t
        end
    end
    table.sort(out, function(a, b)
        if a.channel ~= b.channel then
            return a.channel < b.channel
        end
        return a.id < b.id
    end)
    return out
end

-- 更新运行中/排队任务的标签(下载进度实时回显到后台任务管理)
function TaskQueue.setTaskTag(channel_name, id, tag)
    local ch = TaskQueue.channels[channel_name]
    local t = ch and ch.tasks[id]
    if t then
        t.tag = tag
    end
end

function TaskQueue.cancel(channel_name, id)
    local ch = TaskQueue.channels[channel_name]
    if not ch then
        return false
    end
    return ch:cancelTask(id)
end

function Channel:hasTasks()
    return self.active > 0 or #self.queue > 0
end

-- push(func, callback, opts)
--   func:      无参函数, 在子进程执行, 返回值经管道回传
--   callback:  function(ok, result, err), 仅在最终成败时调用一次
--   opts:      { timeout, tag }
function Channel:push(func, callback, opts)
    if type(func) ~= "function" then
        return nil
    end
    opts = opts or {}
    self.seq = self.seq + 1
    local task = {
        id = self.seq,
        tag = opts.tag,
        func = func,
        callback = callback,
        opts = opts,
        status = "queued",
        channel = self.name,
    }
    self.tasks[task.id] = task
    table.insert(self.queue, task)
    self:_pump()
    return task.id
end

function Channel:_pump()
    while self.active < self.max_workers and #self.queue > 0 do
        local task = table.remove(self.queue, 1)
        self.active = self.active + 1
        self:_run(task)
    end
end

function Channel:_run(task)
    task.status = "running"
    task.handle = Async_run_guarded(task.func, function(ok, result, err)
        self.active = self.active - 1
        -- 任务终结(完成/失败/取消/超时)即离册
        self.tasks[task.id] = nil
        if not ok and task.opts.tag then
            logger.warn(string.format("[task:%s] #%d(%s) 最终失败: %s",
                self.name, task.id, tostring(task.tag), tostring(err)))
        end
        if task.callback then
            pcall(task.callback, ok, result, err)
        end
        self:_pump()
    end, {timeout = task.opts.timeout or 300})
end

-- 清空待处理队列(已启动的子进程任务不受影响, 由其超时/完成自行收敛)
function Channel:list()
    local out = {}
    for _, task in pairs(self.tasks) do
        out[#out + 1] = {
            id = task.id,
            tag = task.tag,
            status = task.status,
            channel = self.name,
        }
    end
    table.sort(out, function(a, b)
        if a.status ~= b.status then
            return a.status == "running"
        end
        return a.id < b.id
    end)
    return out
end

function Channel:cancelTask(id)
    for i, task in ipairs(self.queue) do
        if task.id == id then
            table.remove(self.queue, i)
            self.tasks[id] = nil
            return true
        end
    end
    local task = self.tasks[id]
    if task and task.status == "running" and task.handle and task.handle.cancel then
        task.handle.cancel()
        self.tasks[id] = nil
        -- Async 取消不回调 on_done(见 Async.lua 头注), worker 名额必须在此归还:
        -- 否则单 worker 通道永久卡死(isExtractingInBackground 恒真,
        -- 下载/缓存清理全部被拒直到重启), 且要立即 _pump 唤醒排队任务
        if self.active > 0 then
            self.active = self.active - 1
        end
        self:_pump()
        return true
    end
    return false
end

function Channel:clear()
    for _, task in ipairs(self.queue) do
        self.tasks[task.id] = nil
    end
    self.queue = {}
end

return TaskQueue
