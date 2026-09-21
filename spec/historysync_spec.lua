-- HistorySync 纯函数回归防线(候选过滤/时间戳解析/安全合并决策)
-- 运行方式: luajit spec/historysync_spec.lua
-- Komga/Helper 顶层依赖经桩替换(同 helper_dedup_spec), 不触 KOReader 其余栈

package.path = "./?.lua;" .. package.path

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end
local function eq(a, e, m) if a ~= e then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end

package.preload["libs/libkoreader-lfs"] = function() return {dir = function() return nil end} end
package.preload["util"] = function()
    return {getSafeFilename = function(s) return s end}
end
package.preload["ffi/util"] = function()
    return {template = function() return "" end}
end
package.preload["datastorage"] = function()
    return {getDataDir = function() return "/tmp" end}
end
-- HistorySync 顶层依赖(UI/网络/后端域)与本 spec 无关, 一律桩掉
package.preload["ui/uimanager"] = function() return {} end
package.preload["ui/network/manager"] = function() return {isConnected = function() return true end} end
package.preload["Komga/Backend"] = function() return {} end
package.preload["Komga/TaskQueue"] = function()
    return {getChannel = function() return {push = function() end} end} end
package.preload["Komga/KomgaModel"] = function() return {} end
package.preload["Komga/MessageBox"] = function() return {} end

local HistorySync = require("Komga/HistorySync")

T("filterReadingBooks: 过滤无 readProgress / completed / 缺 id 的条目, 保持服务器排序", function()
    local books = {
        { id = "a", readProgress = { completed = true,  lastModified = "2026-09-21T10:00:00Z" } }, -- 已读: 剔
        { id = "b", readProgress = { completed = false, lastModified = "2026-09-20T10:00:00Z" } }, -- 在读: 留
        { id = "c" },                                                                              -- 无进度: 剔
        { id = "d", readProgress = { completed = false, lastModified = "2026-09-19T10:00:00Z" } }, -- 在读: 留
        { id = "e", readProgress = { completed = false } },                                        -- 无时间: 剔
    }
    local out = HistorySync.filterReadingBooks(books, 10)
    eq(#out, 2, "候选数")
    eq(out[1].id, "b", "保序")
    eq(out[2].id, "d", "保序")
end)

T("filterReadingBooks: limit 截断", function()
    local books = {}
    for i = 1, 30 do
        books[i] = { id = "b" .. i, readProgress = { completed = false,
            lastModified = "2026-09-01T00:00:00Z" } }
    end
    eq(#HistorySync.filterReadingBooks(books, 5), 5, "limit=5")
    eq(#HistorySync.filterReadingBooks(books, 100), 30, "limit=100")
    eq(#HistorySync.filterReadingBooks(books, nil), 30, "无 limit")
end)

T("isoToEpoch: Z 后缀(UTC)换算为本地 epoch", function()
    -- 2026-01-01T00:00:00Z 的本地 epoch = UTC epoch + 时区差, 与 os.time(os.date("!*t")) 一致性校验
    local ts = HistorySync.isoToEpoch("2026-01-01T00:00:00Z")
    local expect = os.time({ year = 2026, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
        + (os.time() - os.time(os.date("!*t")))
    eq(ts, expect)
end)

T("isoToEpoch: 显式 +08:00 后缀", function()
    -- 同一时刻两种写法必须得到同一 epoch
    local tz8 = HistorySync.isoToEpoch("2026-01-01T08:00:00+08:00")
    local tz0 = HistorySync.isoToEpoch("2026-01-01T00:00:00+00:00")
    eq(tz8, tz0)
end)

T("isoToEpoch: 容忍毫秒与小数秒, 非法输入返回 nil", function()
    eq(HistorySync.isoToEpoch("2026-01-01T00:00:00.123Z"),
       HistorySync.isoToEpoch("2026-01-01T00:00:00Z"), "毫秒忽略")
    eq(HistorySync.isoToEpoch("not-a-date"), nil)
    eq(HistorySync.isoToEpoch(nil), nil)
    eq(HistorySync.isoToEpoch(123), nil)
end)

T("shouldBackfill: 无本地条目 → 写; 本地较新 → 跳; 服务器较新 → 写", function()
    eq(HistorySync.shouldBackfill(nil, 1000), true)
    eq(HistorySync.shouldBackfill(2000, 1000), false)
    eq(HistorySync.shouldBackfill(1000, 2000), true)
    eq(HistorySync.shouldBackfill(1000, 1000), false, "相等视为已同步")
    eq(HistorySync.shouldBackfill(1000, nil), false, "无服务器时间不写")
end)

local pass = 0
for _, c in ipairs(checks) do
    local ok, err = pcall(c.fn)
    if ok then
        pass = pass + 1
        print("[通过]", c.name)
    else
        print("[失败]", c.name, err)
    end
end
print(string.format("%d/%d 通过", pass, #checks))
if pass < #checks then
    os.exit(1)
end
