-- BrowserViews 系列总阅读进度(refreshSeriesTotalProgress)回归防线
-- 运行方式: luajit spec/seriessummary_spec.lua
-- 全部模块依赖经 package.preload 桩替换, 只加载真实模块, 覆盖:
--   页数加权汇总正确性 / 全读完 complete / 无变化跳过写入 /
--   系列快捷方式缺失跳过 / 全未读不写 0% / 缺 pages 卷不计入

package.path = "./?.lua;" .. package.path

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end
local function eq(a, e, m) if a ~= e then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end
local function ok(v, m) if not v then error(m or "断言失败", 2) end end
local function near(a, e, m) if not (math.abs(a - e) < 1e-6) then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end

-- ===== 依赖桩 =====
package.preload["ui/uimanager"] = function()
    return {scheduleIn = function() end}
end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/bidi"] = function() return {flipDirectionIfMirroredUILayout = function(d) return d end} end
package.preload["ui/font"] = function() return {getFace = function() return {} end} end
package.preload["ffi/util"] = function() return {template = function(s) return s end} end
package.preload["gettext"] = function()
    return setmetatable({}, {__call = function(_, s) return s end})
end
package.preload["ui/event"] = function()
    return {new = function() return {} end}
end
package.preload["logger"] = function()
    return {info = function() end, warn = function() end, err = function() end, dbg = function() end}
end
package.preload["device"] = function()
    return {screen = {getWidth = function() return 600 end, getHeight = function() return 800 end},
        hasKeys = function() return false end, hasDPad = function() return false end}
end
package.preload["ui/network/manager"] = function()
    return {isConnected = function() return true end}
end
package.preload["Komga/Icons"] = function() return {} end
package.preload["Komga/Backend"] = function()
    return {getLuaConfig = function()
        return {saveSetting = function(self) return self end, flush = function() end}
    end}
end
package.preload["Komga/MessageBox"] = function() return {} end
package.preload["Komga/TaskQueue"] = function() return {} end
package.preload["Komga/ChapterListing"] = function() return {} end

local booklist_resets = {}
package.preload["ui/widget/booklist"] = function()
    -- 与真实 BookList.resetBookInfoCache(file) 同为点调用
    return {resetBookInfoCache = function(file) booklist_resets[#booklist_resets + 1] = file end}
end
package.preload["apps/filemanager/filemanager"] = function()
    return {instance = nil}
end
package.preload["Komga/Paths"] = function()
    return {LNK_SUFFIX = ".html", ZWSP = "\u{200B}", DEFAULT_BROWSER_DIR_NAME = "komga"}
end
package.preload["Komga/VolumePath"] = function() return {} end

local volumes_reply, volume_full = {}, {}
package.preload["Komga/KomgaModel"] = function()
    return {new = function(_, _)
        return {
            getVolumes = function() return volumes_reply end,
            getVolume = function(_, number) return volume_full[number] end,
        }
    end}
end

-- DocSettings 桩: 每个路径一个设置表, saveSetting(nil) 即删除
local ds_store = {}
local function ds_reset() ds_store = {} end
package.preload["docsettings"] = function()
    return {open = function(_, path)
        local t = ds_store[path]
        if not t then
            t = {}
            ds_store[path] = t
        end
        return {
            readSetting = function(_, k) return t[k] end,
            saveSetting = function(_, k, v) t[k] = v end,
            flush = function() end,
        }
    end}
end

local exists_by_path -- nil = 全部存在
package.preload["util"] = function()
    return {
        fileExists = function(path)
            if exists_by_path then
                return exists_by_path[path] and true or false
            end
            return true
        end,
        getSafeFilename = function(s) return s end,
        splitFilePathName = function(p)
            local dir, name = p:match("^(.*/)([^/]+)$")
            return dir or "", name or p
        end,
        directoryExists = function() return true end,
    }
end
package.preload["Komga/Helper"] = function()
    return {
        is_str = function(s) return "string" == type(s) end,
        is_num = function(s) return "number" == type(s) end,
        is_tbl = function(t) return "table" == type(t) end,
        joinPath = function(a, b) return a .. "/" .. b end,
        diagLog = function() end,
    }
end

local init_book_browser = require("Komga/BrowserViews")({})
local browser = init_book_browser({
    getBrowserHomeDir = function() return "/home" end,
})

local HOME = "/home"
local SERIES_LNK = "/home/堀与宫村-HERO.html"
local VOL_FOLDER = "/home/堀与宫村-HERO-vol.sdr"
local BOOKINFO = {name = "堀与宫村", author = "HERO", cache_id = "bc1", booksCount = 16,
    coverUrl = "http://x/thumbnail"}

local function vol_lnk(number)
    -- 与 writeVolLnk 的兜底卷标题一致: "卷N"(无空格), DB 无 title 时生成
    return VOL_FOLDER .. "/" .. string.format("%03d-卷%d.html", number, number)
end

-- 卷列表(卷号/isRead) + 各卷 DB pages + 各卷 sidecar percent_finished
local function setup(volumes, pages_by_number, percent_by_number)
    ds_reset()
    booklist_resets = {}
    volumes_reply = {}
    volume_full = {}
    for _, v in ipairs(volumes) do
        volumes_reply[#volumes_reply + 1] = v
        local number = v.number
        volume_full[number] = {number = number, pages = pages_by_number[number]}
        if percent_by_number[number] then
            ds_store[vol_lnk(number)] = {percent_finished = percent_by_number[number]}
        end
    end
end

-- ===== 用例 =====
T("加权汇总: 已读卷 100% + sidecar 比例 + 未读卷, 按页数加权", function()
    setup({
        {number = 1, isRead = true},
        {number = 2},
        {number = 3},
    }, {[1] = 100, [2] = 200, [3] = 100}, {[2] = 0.5})
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO)
    local t = ds_store[SERIES_LNK]
    near(t.percent_finished, 0.5, "总进度=(100*1+200*0.5+100*0)/400")
    eq(t.doc_pages, 16)
    eq(t.summary.status, "reading")
    eq(booklist_resets[1], SERIES_LNK, "应清系列行的 BookList 缓存")
end)

T("全部已读 → percent 1 + complete", function()
    setup({
        {number = 1, isRead = true},
        {number = 2, isRead = true},
    }, {[1] = 150, [2] = 250}, {})
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO)
    local t = ds_store[SERIES_LNK]
    near(t.percent_finished, 1)
    eq(t.summary.status, "complete")
end)

T("无变化跳过写入(不清缓存)", function()
    setup({{number = 1}}, {[1] = 100}, {[1] = 0.25})
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO) -- 先写一次
    local resets = #booklist_resets
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO) -- 值相同
    eq(#booklist_resets, resets, "无变化不应再清缓存/写 sidecar")
    eq(resets, 1)
end)

T("系列快捷方式不存在(已删/未上架)时跳过, 不代建", function()
    setup({{number = 1}}, {[1] = 100}, {[1] = 0.5})
    exists_by_path = {[SERIES_LNK] = false}
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO)
    ok(ds_store[SERIES_LNK] == nil or ds_store[SERIES_LNK].percent_finished == nil,
        "不应写入不存在的快捷方式")
    exists_by_path = nil
end)

T("全未读(比例 0)不写 0% 进度", function()
    setup({{number = 1}, {number = 2}}, {[1] = 100, [2] = 100}, {})
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO)
    local t = ds_store[SERIES_LNK]
    -- DS 桩的 open 会创建空表, 断言字段而非表本身
    ok(t == nil or (t.percent_finished == nil and (t.summary == nil or t.summary.status == nil)),
        "无进度不应落 percent/status")
end)

T("缺 pages 的卷不计入汇总; 卷数据为空时不写", function()
    setup({{number = 1}, {number = 2, isRead = true}}, {[2] = 100}, {[1] = 0.8})
    -- 卷 1 无 DB pages → 排除(其 0.8 不计入); 卷 2 isRead → 1
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO)
    near(ds_store[SERIES_LNK].percent_finished, 1, "只有卷 2 计入, isRead → 100%")

    volumes_reply = {}
    ds_reset()
    booklist_resets = {}
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO)
    ok(ds_store[SERIES_LNK] == nil, "无卷数据不应写")
end)

T("原有过期进度被刷新; 进度归零时清除并回退状态", function()
    setup({{number = 1}}, {[1] = 100}, {})
    ds_store[SERIES_LNK] = {percent_finished = 0.9, doc_pages = 16,
        summary = {status = "reading"}}
    browser:refreshSeriesTotalProgress("bc1", BOOKINFO) -- 现在真实进度 0
    local t = ds_store[SERIES_LNK]
    ok(t.percent_finished == nil, "进度归零应清除 percent_finished")
    eq(t.summary.status, nil, "进度归零应清除状态")
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
