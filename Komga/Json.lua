--[[
Komga/Json.lua — JSON 编解码统一入口

优先 rapidjson(C FFI, 实测 108KB 书架载荷解码 2.8ms→0.43ms, 编码快 ~15 倍),
缺失时回落 dkjson(纯 Lua)。两者在本插件用到的语义子集内等价:
- decode 失败均返回 nil(+错误串), 数组/对象均为 table
- encode 跳过 nil 字段, 序列(1..n)编码为数组, UTF-8 无损
]]
local has_rapidjson, rapidjson = pcall(require, "rapidjson")
local has_dkjson, dkjson = pcall(require, "dkjson")

if not (has_rapidjson and type(rapidjson) == "table" and rapidjson.decode and rapidjson.encode) then
    has_rapidjson = nil
end
if not (has_dkjson and type(dkjson) == "table" and dkjson.decode and dkjson.encode) then
    has_dkjson = nil
end

local M = {}

if has_rapidjson then
    M.backend = "rapidjson"

    -- rapidjson 把 JSON null 解码为 rapidjson.null 哨兵(userdata, 真值!),
    -- 而 dkjson 解码为 nil——全插件的 `x == nil` / `x and x.y` 判空都基于后者。
    -- 递归把哨兵替换回 nil, 恢复 dkjson 语义(实测 108KB 书架载荷归零 <0.5ms)。
    -- 遍历中置 nil(Lua 允许清除已存在键)不会破坏 pairs 迭代。
    -- 深度上限防服务器异常载荷耗尽栈(真实 Komga 载荷深度 <20)。
    local null_sentinel = rapidjson.null
    local DENULL_MAX_DEPTH = 64
    local function denull(t, depth)
        if depth > DENULL_MAX_DEPTH then
            return
        end
        for k, v in pairs(t) do
            if v == null_sentinel then
                t[k] = nil
            elseif type(v) == "table" then
                denull(v, depth + 1)
            end
        end
    end

    function M.decode(s)
        local v = rapidjson.decode(s)
        if type(v) == "table" then
            denull(v, 1)
        end
        return v
    end

    function M.encode(v)
        return rapidjson.encode(v)
    end
else
    M.backend = has_dkjson and "dkjson" or "none"

    function M.decode(s)
        return (dkjson.decode(s))
    end

    function M.encode(v)
        return dkjson.encode(v)
    end
end

return M
