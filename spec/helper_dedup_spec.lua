-- Helper.dedupeAuthors 作者串去重回归防线
-- 运行方式: luajit spec/helper_dedup_spec.lua
-- Helper 顶层依赖(libs/libkoreader-lfs、util、ffi/util、datastorage)经桩替换

package.path = "./?.lua;" .. package.path

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end
local function eq(a, e, m) if a ~= e then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end

package.preload["libs/libkoreader-lfs"] = function() return {dir = function() return nil end} end
package.preload["util"] = function()
    return {getSafeFilename = function(s) return s end}
end
package.preload["ffi/util"] = function()
    return {template = function(s) return s end}
end
package.preload["datastorage"] = function()
    return {getDataDir = function() return "/tmp" end}
end

local H = require("Komga/Helper")

T("重复作者去重: 岸本斉史/岸本斉史 → 岸本斉史", function()
    eq(H.dedupeAuthors("岸本斉史/岸本斉史"), "岸本斉史")
end)

T("多作者保序去重: A/B/A/C → A/B/C", function()
    eq(H.dedupeAuthors("A/B/A/C"), "A/B/C")
end)

T("无重复时不改变原串", function()
    eq(H.dedupeAuthors("萩原ダイスケ/HERO"), "萩原ダイスケ/HERO")
    eq(H.dedupeAuthors("岸本斉史"), "岸本斉史")
end)

T("首尾空白先去除再比较", function()
    eq(H.dedupeAuthors("岸本斉史 / 岸本斉史"), "岸本斉史")
end)

T("空段被忽略: A//B → A/B", function()
    eq(H.dedupeAuthors("A//B"), "A/B")
end)

T("非字符串/空串原样返回", function()
    eq(H.dedupeAuthors(nil), nil)
    eq(H.dedupeAuthors(""), "")
end)

T("全部为空段时原样返回(不产出空串)", function()
    eq(H.dedupeAuthors("//"), "//")
end)

-- ===== 运行 =====
local failed = 0
for _, check in ipairs(checks) do
    local run_ok, err = pcall(check.fn)
    if run_ok then
        print("[通过] " .. check.name)
    else
        failed = failed + 1
        print("[失败] " .. check.name .. "\n        " .. tostring(err))
    end
end
print(string.format("\n%d/%d 通过", #checks - failed, #checks))
os.exit(failed > 0 and 1 or 0)
