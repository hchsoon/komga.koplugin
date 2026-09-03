--[[
Komga/TaskQueue.lua — 具名任务通道(设计参考 legado.koplugin task/Queue, 适配本插件体量)

- 每个通道(getChannel(name, max_workers))独立队列与并发上限;
  本插件的后台域约定: "pages"/"stream"/"volume" 均为 1 worker, "cover" 为 2
- 任务经 Komga/Async.run 在子进程执行: 超时/终止/回收由 Async 托管,
  fork 不可用时 Async 自动同步降级(此时任务在主进程串行执行)
- 支持重试(max_retries)、插队(insert_at_head)、暂停/恢复、清空队列
- 失败重试不回调原 callback; 重试耗尽后才回调 (false, nil, err)
]]
local logger = require("logger")

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
            paused = false,
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

function TaskQueue.cancel(channel_name, id)
    local ch = TaskQueue.channels[channel_name]
    if not ch then
        return false
    end
    return ch:cancelTask(id)
end

function TaskQueue.hasAnyTasks()
    for _, ch in pairs(TaskQueue.channels) do
        if ch:hasTasks() then
            return true
        end
    end
    return false
end

function TaskQueue.getEngineStatus()
    local status = {}
    for name, ch in pairs(TaskQueue.channels) do
        status[name] = ch:getStatus()
    end
    return status
end

function Channel:hasTasks()
    return self.active > 0 or #self.queue > 0
end

function Channel:getStatus()
    return {
        queued = #self.queue,
        active = self.active,
        paused = self.paused,
        max_workers = self.max_workers,
    }
end

-- push(func, callback, opts)
--   func:      无参函数, 在子进程执行, 返回值经管道回传
--   callback:  function(ok, result, err), 仅在最终成败时调用一次(重试期间不调用)
--   opts:      { timeout, max_retries, insert_at_head, tag }
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
        retries = 0,
        status = "queued",
        channel = self.name,
    }
    self.tasks[task.id] = task
    if opts.insert_at_head then
        table.insert(self.queue, 1, task)
    else
        table.insert(self.queue, task)
    end
    self:_pump()
    return task.id
end

function Channel:_pump()
    if self.paused then
        return
    end
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
        -- 任务终结(完成/失败/取消/超时)即离册; 重试的重新入册由下方 queue 插入时补回
        if not (not ok and task.retries < (task.opts.max_retries or 0)) then
            self.tasks[task.id] = nil
        end
        local max_retries = task.opts.max_retries or 0
        if not ok and task.retries < max_retries then
            task.retries = task.retries + 1
            logger.warn(string.format("[task:%s] #%d(%s) 失败, 重试 %d/%d: %s",
                self.name, task.id, tostring(task.tag), task.retries, max_retries, tostring(err)))
            task.status = "queued"
            self.tasks[task.id] = task
            table.insert(self.queue, task)
        else
            if not ok and task.opts.tag then
                logger.warn(string.format("[task:%s] #%d(%s) 最终失败: %s",
                    self.name, task.id, tostring(task.tag), tostring(err)))
            end
            if task.callback then
                pcall(task.callback, ok, result, err)
            end
        end
        self:_pump()
    end, {timeout = task.opts.timeout or 300})
end

-- Async 延迟绑定(避免模块加载顺序问题, 且便于测试桩替换)
function Async_run_guarded(func, callback, opts)
    local Async = require("Komga/Async")
    return Async.run(func, callback, opts)
end

function Channel:pause()
    self.paused = true
end

function Channel:resume()
    self.paused = false
    self:_pump()
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
