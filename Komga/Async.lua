--[[
Komga/Async.lua — runInSubProcess 异步执行封装(设计参考 koobone.koplugin/async.lua)

- work 在子进程执行, 结果经管道以 JSON 回传 {ok, result|err}
- 父进程定时轮询: 超时终止、手动取消句柄、结束后回收子进程
- 子进程不可用(不支持 fork 的平台)或 fork 失败时同步降级执行
- on_done(ok, result, err) 保证恰好调用一次(取消时不调用)
]]
local ffiUtil = require("ffi/util")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Json = require("Komga/Json")

local M = {}

function M.is_available()
    return type(ffiUtil.runInSubProcess) == "function"
        and type(ffiUtil.writeToFD) == "function"
        and type(ffiUtil.readAllFromFD) == "function"
        and type(ffiUtil.getNonBlockingReadSize) == "function"
        and type(ffiUtil.isSubProcessDone) == "function"
end

local function sanitize_err(err)
    local s = tostring(err or "unknown error")
    s = s:gsub("[%c]", " ")
    if #s > 1000 then
        s = s:sub(1, 1000) .. "..."
    end
    return s
end

-- 同步降级: 直接在当前进程执行并回调(失败功能可用, 只是阻塞 UI)
local function run_sync(work_func, on_done)
    local ok, result = pcall(work_func)
    if on_done then
        if ok then
            on_done(true, result, nil)
        else
            on_done(false, nil, sanitize_err(result))
        end
    end
    return nil
end

-- opts: { timeout = 300, poll_interval = 0.25 }
-- 返回 handle: { pid, done, cancelled, cancel() }
function M.run(work_func, on_done, opts)
    opts = opts or {}
    local poll_interval = opts.poll_interval or 0.25
    local timeout = opts.timeout or 300

    if not M.is_available() then
        logger.warn("[komga-async] 子进程不可用, 降级同步执行")
        return run_sync(work_func, on_done)
    end

    local function child_entry(pid, child_write_fd)
        local ok, result = pcall(work_func)
        local payload = ok
            and Json.encode({ok = true, result = (result ~= nil) and result or true})
            or Json.encode({ok = false, err = sanitize_err(result)})
        if not payload then
            -- 编码兜底(Json.backend == "none" 的极端环境): 至少回传成败标记
            payload = ok and '{"ok":true}' or '{"ok":false}'
        end
        pcall(ffiUtil.writeToFD, child_write_fd, payload, true)
    end

    local pid, parent_read_fd = ffiUtil.runInSubProcess(child_entry, true)
    if not pid then
        logger.warn("[komga-async] fork 失败, 降级同步执行")
        return run_sync(work_func, on_done)
    end

    local handle = {pid = pid, fd = parent_read_fd, done = false, cancelled = false}

    local function cleanup()
        if handle.fd then
            pcall(ffiUtil.readAllFromFD, handle.fd)
            handle.fd = nil
        end
        if not ffiUtil.isSubProcessDone(pid) then
            pcall(ffiUtil.terminateSubProcess, pid)
        end
    end

    local function finish(ok, result, err)
        handle.done = true
        if on_done and not handle.cancelled then
            on_done(ok, result, err)
        end
    end

    function handle.cancel()
        if handle.done then
            return
        end
        handle.cancelled = true
        handle.done = true
        cleanup()
    end

    local started = os.time()

    local function poll()
        if handle.done then
            return
        end

        if os.time() - started > timeout then
            logger.warn("[komga-async] 子进程超时", timeout, "s, 终止")
            cleanup()
            finish(false, nil, "async timeout")
            return
        end

        local sub_done = ffiUtil.isSubProcessDone(pid)
        local has_data = handle.fd ~= nil and ffiUtil.getNonBlockingReadSize(handle.fd) ~= 0

        if sub_done or has_data then
            local ok, val, err
            if has_data then
                local raw = ffiUtil.readAllFromFD(handle.fd)
                handle.fd = nil
                local decoded = raw and Json.decode(raw)
                if type(decoded) == "table" then
                    if decoded.ok then
                        ok, val = true, decoded.result
                    else
                        ok, err = false, decoded.err or "unknown error"
                    end
                elseif sub_done then
                    ok, val = true, nil
                else
                    ok, err = false, "malformed subprocess output"
                end
            else
                if handle.fd then
                    pcall(ffiUtil.readAllFromFD, handle.fd)
                    handle.fd = nil
                end
                ok, err = false, "subprocess exited without output"
            end

            -- 子进程尚未退出(管道先就绪): 按秒回收, 不阻塞
            if not sub_done then
                local collect_pid = pid
                local collect
                collect = function()
                    if not ffiUtil.isSubProcessDone(collect_pid) then
                        UIManager:scheduleIn(1, collect)
                    end
                end
                UIManager:scheduleIn(1, collect)
            end

            finish(ok, val, err)
        else
            UIManager:scheduleIn(poll_interval, poll)
        end
    end

    UIManager:scheduleIn(poll_interval, poll)
    return handle
end

return M
