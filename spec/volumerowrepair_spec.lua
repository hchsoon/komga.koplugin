-- BrowserViews 分卷目录行自愈(repairVolumeShortcutRows)与封面落盘行刷新
-- (invalidateShortcutRow)回归防线
-- 运行方式: luajit spec/volumerowrepair_spec.lua
-- BrowserViews 的全部模块依赖经 package.preload 桩替换, 只加载真实模块, 覆盖:
--   卡死行两类: 提取未完成(has_meta 空) / 封面卡死(has_cover 空+磁盘已有封面) 精确删行
--   健康行与缺失行零触碰 / CoverBrowser 不可用静默跳过 / 快捷方式文件缺失跳过
--   invalidateShortcutRow: 删行+清缓存+重绘节流
-- 注意: ProgressSync 在 require 时即持有各桩模块的表引用, 测试内只允许
-- 原地修改桩表字段(不可重新绑定变量, 否则被测代码看到的仍是旧表)。

package.path = "./?.lua;" .. package.path

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end
local function eq(a, e, m) if a ~= e then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end
local function ok(v, m) if not v then error(m or "断言失败", 2) end end

-- ===== 依赖桩 =====
local scheduled = {} -- UIManager:scheduleIn 收集的定时任务 {delay, fn}
package.preload["ui/uimanager"] = function()
    return {scheduleIn = function(_, delay, fn) table.insert(scheduled, {delay = delay, fn = fn}) end}
end

local network_online = true
package.preload["ui/network/manager"] = function()
    return {isConnected = function() return network_online end}
end
package.preload["logger"] = function()
    return {info = function() end, warn = function() end, err = function() end, dbg = function() end}
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
package.preload["device"] = function()
    return {screen = {getWidth = function() return 600 end, getHeight = function() return 800 end},
        hasKeys = function() return false end, hasDPad = function() return false end}
end

local exists_by_path -- nil = 全部存在
local cover_files = {} -- [lnk_path] = true(磁盘已有封面 sidecar 文件)
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
-- DocSettings 桩: 自愈路径只用 findCustomCoverFile
package.preload["docsettings"] = function()
    return {findCustomCoverFile = function(_, path)
        return cover_files[path] and (path .. ".cover.jpg") or nil
    end}
end
package.preload["apps/reader/readerui"] = function()
    return {instance = nil}
end
-- FileManager 桩: 测试内改写 .instance
local FileManagerStub = {instance = nil}
package.preload["apps/filemanager/filemanager"] = function() return FileManagerStub end

local volumes_reply = {}
package.preload["Komga/KomgaModel"] = function()
    return {new = function(_, _)
        return {getVolumes = function() return volumes_reply end}
    end}
end

package.preload["Komga/Icons"] = function() return {} end
package.preload["Komga/MessageBox"] = function() return {} end
package.preload["Komga/ChapterListing"] = function() return {} end

local pushed = {} -- TaskQueue 收集的任务
package.preload["Komga/Backend"] = function()
    return {
        closeDbManager = function() end,
        getSeriesVolumesReadProgress = function() return {type = "SUCCESS", body = {}} end,
        getLuaConfig = function()
            return {saveSetting = function(self) return self end, flush = function() end}
        end,
    }
end
package.preload["Komga/TaskQueue"] = function()
    return {getChannel = function(_, _, _)
        return {push = function(_, func, callback, opts)
            pushed[#pushed + 1] = {func = func, callback = callback, opts = opts}
        end}
    end}
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
package.preload["Komga/Paths"] = function()
    return {LNK_SUFFIX = ".html", CACHE_DIR_SEGMENT = "komga.cache"}
end
package.preload["Komga/VolumePath"] = function()
    return {chapterIndex = function() return nil end}
end

local booklist_resets = {}
package.preload["ui/widget/booklist"] = function()
    -- 与真实 BookList.resetBookInfoCache(file) 同为点调用
    return {resetBookInfoCache = function(file) booklist_resets[#booklist_resets + 1] = file end}
end

-- CoverBrowser bookinfomanager 桩: 裸名与点分全名都注册(与被测代码的
-- 双名加载策略对应)。cb_enabled=false 时 require 返回 true(模拟 LuaJIT 对
-- "加载器无返回值"的真实行为: require 结果为布尔), 行自愈须静默跳过
local cb_enabled = true
local cb_rows = {} -- { [lnk_path] = row 表或 nil }
local cb_gets, cb_deletes = {}, {}
local function make_cb_stub()
    if not cb_enabled then
        return true
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
package.preload["bookinfomanager"] = make_cb_stub
package.preload["plugins/coverbrowser.koplugin/bookinfomanager"] = make_cb_stub

local PS = require("Komga/ProgressSync")
local init_book_browser = require("Komga/BrowserViews")({})
local browser = init_book_browser({})

local VOLUME_FOLDER = "/vol"

-- 与真实 writeVolLnk 生成的路径一致: 兜底卷标题"卷N"(无空格)
local function lnk(number)
    return VOLUME_FOLDER .. "/" .. string.format("%03d-卷%d.html", number, number)
end

local function new_libview(br)
    -- 生产环境 LibraryView 经 setmetatable(state, {__index = ProgressSync}) 混入方法
    return setmetatable({book_browser = br, server_rp_busy = nil}, {__index = PS})
end

local function new_browser(lnk_exists)
    -- 先声明再赋值: 表构造器里的闭包要引用 br, local br = {...} 语句完成前 br 尚不在作用域内
    local br
    br = {
        calls = {}, writes = {},
        writeVolLnk = function(_, volume, volume_folder, book_cache_id)
            br.calls[#br.calls + 1] = {"writeVolLnk", volume.number}
            return lnk_exists and (volume_folder .. "/" .. tostring(volume.number) .. ".html") or nil
        end,
        refreshVolumeMetadata = function(_, _, lnk_path, book_cache_id, number, _)
            br.calls[#br.calls + 1] = {"refresh", number}
            br.writes[number] = (br.writes[number] or 0) + 1
        end,
    }
    return br
end

local function drain_scheduled()
    while #scheduled > 0 do
        local job = table.remove(scheduled)
        job.fn()
    end
end

-- ===== 行自愈: 卡死行删行 =====
T("repairRows: 提取未完成行(has_meta 空)删除, 健康行与缺失行零触碰", function()
    volumes_reply = {
        {number = 1},
        {number = 2},
        {number = 3},
        {number = 4},
    }
    cb_rows = {
        [lnk(1)] = {has_meta = "Y", has_cover = "Y", cover_fetched = "Y"}, -- 健康
        [lnk(2)] = {in_progress = 0, unsupported = "too many interruptions or crashes"}, -- 终审中毒
        [lnk(3)] = {in_progress = 2}, -- 中断卡死
        -- 卷 4 无行: 从未提取, CoverBrowser 自然会处理, 不碰
    }
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    FileManagerStub.instance = {onRefresh = function() refreshes = refreshes + 1 end}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_deletes, 2, "应恰好删 2 行")
    ok(cb_deletes[1] == lnk(2) and cb_deletes[2] == lnk(3), "删的是卷 2/3")
    eq(refreshes, 1, "有修复应整目录只刷新一次")
end)

T("repairRows: 封面卡死行(has_cover 空但磁盘已有封面)删除; 封面真缺失则不删", function()
    volumes_reply = {
        {number = 1},
        {number = 2},
        {number = 3},
    }
    cb_rows = {
        -- 封面卡死: 已提取(有 meta), 封面试过没拿到, 但磁盘上封面已落盘
        [lnk(1)] = {has_meta = "Y", cover_fetched = "Y"},
        -- 封面真缺失: 磁盘无封面文件(下载未完成/失败), 不该删
        [lnk(2)] = {has_meta = "Y", cover_fetched = "Y"},
        -- 从未试过封面(旧行), 不该删
        [lnk(3)] = {has_meta = "Y"},
    }
    cover_files = {[lnk(1)] = true}
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    FileManagerStub.instance = {onRefresh = function() refreshes = refreshes + 1 end}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_deletes, 1, "只删封面卡死的卷 1")
    eq(cb_deletes[1], lnk(1))
    eq(refreshes, 1)
    cover_files = {}
end)

T("repairRows: 无 provider 哑对象(_no_provider)不据此删行", function()
    volumes_reply = {{number = 1}}
    cb_rows = {[lnk(1)] = {_no_provider = true, ignore_meta = "Y"}}
    cb_gets, cb_deletes = {}, {}
    FileManagerStub.instance = nil
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_deletes, 0, "哑对象不是真实行状态, 不能删")
end)

T("repairRows: CoverBrowser 不可用/卷数据为空/快捷方式缺失时静默跳过", function()
    cb_enabled = false
    package.loaded["bookinfomanager"] = nil
    package.loaded["plugins/coverbrowser.koplugin/bookinfomanager"] = nil
    volumes_reply = {{number = 1}}
    cb_gets, cb_deletes = {}, {}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_gets, 0, "不可用不应查行")
    cb_enabled = true
    package.loaded["bookinfomanager"] = nil
    package.loaded["plugins/coverbrowser.koplugin/bookinfomanager"] = nil

    volumes_reply = {}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_gets, 0)

    volumes_reply = {{number = 1}}
    exists_by_path = {[lnk(1)] = false}
    browser:repairVolumeShortcutRows("bc", {name = "x"}, VOLUME_FOLDER)
    eq(#cb_gets, 0, "快捷方式文件缺失不应查行")
    exists_by_path = nil
end)

-- ===== invalidateShortcutRow: 封面落盘后的定向行刷新 =====
T("invalidateRow: 删行+清缓存, 1.5s 窗口内重绘节流为一次, 窗口后重新调度", function()
    cb_enabled = true
    package.loaded["bookinfomanager"] = nil
    package.loaded["plugins/coverbrowser.koplugin/bookinfomanager"] = nil
    cb_gets, cb_deletes = {}, {}
    local refreshes = 0
    FileManagerStub.instance = {onRefresh = function() refreshes = refreshes + 1 end}
    local resets_before = #booklist_resets

    browser:invalidateShortcutRow("/v/1.html")
    browser:invalidateShortcutRow("/v/2.html")
    eq(#cb_deletes, 2, "两个封面落盘各删一行")
    eq(#booklist_resets - resets_before, 2, "各清一次 BookList 缓存")
    eq(#scheduled, 1, "重绘应节流为一次")

    drain_scheduled()
    eq(refreshes, 1, "节流窗口结束只刷一次目录")

    browser:invalidateShortcutRow("/v/3.html")
    eq(#scheduled, 1, "窗口结束后再次落盘应重新调度重绘")
    drain_scheduled()
    eq(refreshes, 2)
end)

T("invalidateRow: 非法路径静默返回", function()
    cb_deletes = {}
    browser:invalidateShortcutRow(nil)
    browser:invalidateShortcutRow(123)
    eq(#cb_deletes, 0)
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
