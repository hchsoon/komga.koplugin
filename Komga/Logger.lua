--[[
Komga/Logger.lua — 分级日志(参考 koobone logger, 极简版)

- 级别: debug < info < warn < error; 低于当前级别的只进 KOReader logger, 不落盘
- 设置项 debug_log = true 时级别提到 debug(诊断日志如 [komga-layout] 收编于此)
- 文件: <临时目录>/komga.log, 自 init 起追加
- 无 KOReader 依赖(纯 io), 可在任何加载阶段使用
]]
local M = {
    _level = 2, -- info
    _path = nil,
}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local TAGS = { [1] = "DEBUG", [2] = "INFO ", [3] = "WARN ", [4] = "ERROR" }

function M.init(path, debug_on)
    M._path = path
    if debug_on then
        M._level = LEVELS.debug
    end
end

function M.setDebug(on)
    M._level = on and LEVELS.debug or LEVELS.info
end

local function write(level, msg)
    local ko_logger = require("logger")
    if level == 1 then
        ko_logger.dbg(msg)
    elseif level == 3 then
        ko_logger.warn(msg)
    elseif level == 4 then
        ko_logger.err(msg)
    else
        ko_logger.info(msg)
    end
    if M._path and level >= M._level then
        pcall(function()
            local f = io.open(M._path, "a")
            if f then
                f:write(os.date("%m-%d %H:%M:%S "), TAGS[level], " ", msg, "\n")
                f:close()
            end
        end)
    end
end

local function fmt(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, " ")
end

function M.info(...)
    write(LEVELS.info, fmt(...))
end

function M.warn(...)
    write(LEVELS.warn, fmt(...))
end

return M
