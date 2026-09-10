-- BrowserViews 分卷目录行自愈(repairVolumeShortcutRows)回归防线
-- 运行方式: luajit spec/volumerowrepair_spec.lua
-- BrowserViews 的全部模块依赖经 package.preload 桩替换, 只加载真实模块,
-- 覆盖: 中毒行(has_meta 空)精确删行 / 健康行与缺失行零触碰 /
--       CoverBrowser 不可用静默跳过 / 快捷方式文件缺失跳过 /
--       只在确实删了行时整目录刷新一次

package.path = "./?.lua;" .. package.path

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end
local function eq(a, e, m) if a ~= e then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end
local function ok(v, m) if not v then error(m or "断言失败", 2) end end

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
package.preload["docsettings"] = function() return {} end
package.preload["Komga/Icons"] = function() return {} end
package.preload["Komga/Backend"] = function()
    return {getLuaConfig = function()
        return {saveSetting = function(self) return self end, flush = function() end}
    end}
end
package.preload["Komga/MessageBox"] = function() return {} end
package.preload["Komga/TaskQueue"] = function() return {} end
package.preload["Komga/ChapterListing"] = function() return {} end
package.preload["apps/filemanager/filemanager"] = function()
    return {instance = nil}
end
package.preload["Komga/Helper"] = function()
    return {
        is_str = function(s) return "string" == type(s) end,
        is_num = function(s) return "number" == type(s) end,
        is_tbl = function(t) return "table" == type(t) end,
        joinPath = function(a, b) return a .. "/" .. b end,
    }
end
package.preload["Komga/Paths"] = function()
    return {LNK_SUFFIX = ".html", ZWSP = "\u{200B}", DEFAULT_BROWSER_DIR_NAME = "komga"}
end
package.preload["Komga/VolumePath"] = function() return {} end

local volumes_reply = {}
package.preload["Komga/KomgaModel"] = function()
    return {new = function(_, _)
        return {getVolumes = function() return volumes_reply end}
    end}
end

-- CoverBrowser bookinfomanager 桩: cb_enabled=false 时 require 必然失败(模拟未启用)
local cb_enabled = true
local cb_rows = {}      -- { [lnk_path] = row 表或 nil }
local cb_gets, cb_deletes = {}, {}
package.preload["plugins/coverbrowser.koplugin/bookinfomanager"] = function()
    if not cb_enabled then
        return nil
    end
    return {
        getBookInfo = function(_, filepath, _)
            cb_gets[#cb_gets + 1] = filepath
            return cb_rows[filepath]
        end,
        deleteBookInfo = function(_, filepath)
            cb_deletes[#cb_deletes + 1] = filepath
            cb_rows[filepath] = nil
        end,
    }
end

-- util 桩: fileExists/getSafeFilename 可按路径配置
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

-- require 返回工厂 function(LibraryView); 工厂返回两个构造函数, 取 book_browser 的
local init_book_browser = require("Komga/BrowserViews")({})
local browser = init_book_browser({})

local VOLUME_FOLDER = "/home/堀与宫村-作者-vol.sdr"

local function lnk(number)
    return VOLUME_FOLDER .. "/" .. string.format("%03d-卷 %d.html", number, number)
end

local function mkvolumes(count)
    local volumes = {}
    for i = 1, count do
        volumes[#volumes + 1] = {number = i, title = "卷 " .. i, bookId = "b" .. i}
    end
    return volumes
end

-- ===== 用例 =====
T("健康行(has_meta=Y)零触碰, 不触发刷新", function()
    volumes_reply = mkvolumes(2)
    cb_enabled = true
    cb_rows = {
        [lnk(1)] = {has_meta = "Y", in_progress = 0},
        [lnk(2)] = {has_meta = "Y", in_progress = 0, unsupported = nil},
    }
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    require("apps/filemanager/filemanager").instance = {onRefresh = function() refreshes = refreshes + 1 end}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_deletes, 0, "健康行不应被删")
    eq(#cb_gets, 2, "每卷应查一次行状态")
    eq(refreshes, 0, "无修复不应刷新目录")
end)

T("中毒行(终审 too many / 卡在 in_progress)被精确删除, 健康行与缺失行不碰, 刷新一次", function()
    volumes_reply = mkvolumes(4)
    cb_rows = {
        [lnk(1)] = {has_meta = "Y"},                                        -- 健康
        [lnk(2)] = {in_progress = 0, unsupported = "too many interruptions or crashes"}, -- 终审中毒
        [lnk(3)] = {in_progress = 2},                                       -- 中断卡死
        -- lnk(4) 无行: 从未提取, CoverBrowser 自然会处理, 不碰
    }
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    require("apps/filemanager/filemanager").instance = {onRefresh = function() refreshes = refreshes + 1 end}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_deletes, 2, "应恰好删 2 行")
    ok(cb_deletes[1] == lnk(2) and cb_deletes[2] == lnk(3), "删的是卷 2/3")
    eq(refreshes, 1, "有修复应整目录只刷新一次")
end)

T("CoverBrowser 不可用时静默跳过", function()
    volumes_reply = mkvolumes(2)
    -- 清掉模块缓存: cb_enabled=false 时 preload 返回 nil, require 报"找不到模块",
    -- 模拟 CoverBrowser 未启用(否则 require 命中缓存桩, 测不到降级路径)
    cb_enabled = false
    package.loaded["plugins/coverbrowser.koplugin/bookinfomanager"] = nil
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    require("apps/filemanager/filemanager").instance = {onRefresh = function() refreshes = refreshes + 1 end}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_deletes, 0)
    eq(#cb_gets, 0)
    eq(refreshes, 0)
    cb_enabled = true
    package.loaded["plugins/coverbrowser.koplugin/bookinfomanager"] = nil
end)

T("卷数据为空时不触碰 bookinfomanager", function()
    volumes_reply = {}
    cb_gets, cb_deletes = {}, {}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_gets, 0)
    eq(#cb_deletes, 0)
end)

T("快捷方式文件缺失的卷被跳过", function()
    volumes_reply = mkvolumes(2)
    cb_rows = {[lnk(1)] = {in_progress = 1}, [lnk(2)] = {in_progress = 1}}
    exists_by_path = {[lnk(1)] = true, [lnk(2)] = false} -- 卷 2 的快捷方式文件不存在
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    require("apps/filemanager/filemanager").instance = {onRefresh = function() refreshes = refreshes + 1 end}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_gets, 1, "文件缺失的卷不应查行")
    eq(cb_gets[1], lnk(1))
    eq(#cb_deletes, 1)
    eq(cb_deletes[1], lnk(1))
    exists_by_path = nil
end)

T("无 provider 哑对象(_no_provider)不据此删行", function()
    volumes_reply = mkvolumes(1)
    cb_rows = {[lnk(1)] = {_no_provider = true, ignore_meta = "Y"}} -- 未查 DB 的哑对象
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    require("apps/filemanager/filemanager").instance = {onRefresh = function() refreshes = refreshes + 1 end}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_deletes, 0, "哑对象不是真实行状态, 不能删")
    eq(refreshes, 0)
end)

T("参数缺失时静默返回", function()
    volumes_reply = mkvolumes(1)
    cb_gets, cb_deletes = {}, {}
    browser:repairVolumeShortcutRows(nil, {name = "x"}, VOLUME_FOLDER)
    browser:repairVolumeShortcutRows("bc", {name = "x"}, nil)
    eq(#cb_gets, 0)
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
