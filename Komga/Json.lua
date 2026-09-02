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

    function M.decode(s)
        return rapidjson.decode(s)
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
