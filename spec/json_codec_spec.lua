-- Komga/Json 编解码测试(rapidjson 优先, dkjson 回退)
-- 运行方式: luajit spec/json_codec_spec.lua

package.path = "./?.lua;" .. (os.getenv("KOREADER_ROOT") or "/Applications/KOReader.app/Contents/koreader") .. "/common/?.lua;" .. package.path
package.cpath = (os.getenv("KOREADER_ROOT") or "/Applications/KOReader.app/Contents/koreader") .. "/common/?.so;" .. package.cpath
package.preload["socket.url"] = function() return {escape = function(s) return s end} end

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end

local Json = require("Komga/Json")

T("后端可用(rapidjson 或 dkjson)", function()
    if Json.backend == "none" then error("无可用 JSON 后端") end
end)
T("往返: 布尔/数值/嵌套/数组", function()
    local v = Json.decode(Json.encode({ok = true, n = 0.42, loc = {progression = 0.37}, arr = {1, 2, 3}}))
    if v.ok ~= true or v.n ~= 0.42 or v.loc.progression ~= 0.37 or v.arr[3] ~= 3 then error("往返不一致") end
end)
T("rapidjson null 归零(历史回归: readProgress 哨兵崩溃)", function()
    if Json.backend ~= "rapidjson" then return end -- dkjson 本就返回 nil
    local v = Json.decode('{"readProgress":null,"loc":{"p":null},"arr":[1,null,{"x":null}]}')
    if v.readProgress ~= nil then error("readProgress 应为 nil") end
    if v.loc.p ~= nil or v.arr[2] ~= nil or v.arr[3].x ~= nil then error("嵌套/数组内 null 应为 nil") end
end)
T("decode 失败返回 nil", function()
    if Json.decode('{broken') ~= nil then error("应返回 nil") end
end)
T("encode: nil 字段跳过", function()
    if Json.encode({a = nil, b = 2}) ~= '{"b":2}' then error("nil 字段应跳过") end
end)
T("encode: 序列编码为数组(allOf 回归)", function()
    local cond = Json.encode({condition = {allOf = {{seriesId = {operator = "is", value = "X"}}}}})
    if not cond:find('"allOf":%[') then error("allOf 应为数组") end
end)
T("UTF-8 无损", function()
    if Json.decode(Json.encode({s = "中文测试"})).s ~= "中文测试" then error("中文不一致") end
end)
local failed = 0
for _, c in ipairs(checks) do
    local ok, err = pcall(c.fn)
    if ok then
        print(string.format("ok   %s", c.name))
    else
        failed = failed + 1
        print(string.format("FAIL %s\n     %s", c.name, tostring(err)))
    end
end
if failed > 0 then
    print(string.format("\n%d/%d 用例失败", failed, #checks))
    os.exit(1)
end
print(string.format("\n全部通过 (%d 用例)", #checks))
