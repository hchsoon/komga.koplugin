-- ProgressSync 分卷服务器进度批量同步(纯逻辑回归防线)
-- 运行方式: luajit spec/serverprogress_spec.lua
-- 全部重依赖(ui/uimanager、Backend、TaskQueue 等)经 package.preload 桩替换,
-- 只加载真实的 Komga/ProgressSync, 覆盖:
--   extractServerProgressMap(BookDto[] → map) / volumeServerFrac(比例换算)
--   syncAllVolumesServerProgress(离线跳过/同系列去重/数据提取)
--   applyServerProgressToShortcuts(isRead 过滤/分块/无变化零刷新)
--   persistServerProgressToShortcut(无变化零写入/变化写入)
-- 注意: ProgressSync 在 require 时即持有各桩模块的表引用, 测试内只允许
-- 原地修改桩表字段(不可重新绑定变量, 否则被测代码看到的仍是旧表)。

package.path = "./?.lua;" .. package.path

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end
local function eq(a, e, m) if a ~= e then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end
local function ok(v, m) if not v then error(m or "断言失败", 2) end end

-- ===== 依赖桩(全部可变表, 测试内原地改字段) =====
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
package.preload["util"] = function()
    return {fileExists = function() return true end}
end
-- DocSettings 桩: 测试内改写 .open 行为
local DocSettingsStub = {}
package.preload["docsettings"] = function() return DocSettingsStub end
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

local pushed = {} -- TaskQueue 收集的任务 {func, callback, opts}
local rp_response -- Backend.getSeriesVolumesReadProgress 的返回
local rp_series_id -- 最近一次请求的系列 id
package.preload["Komga/Backend"] = function()
    return {
        closeDbManager = function() end,
        getSeriesVolumesReadProgress = function(_, series_id)
            rp_series_id = series_id
            return rp_response
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
    }
end
package.preload["Komga/Paths"] = function()
    return {LNK_SUFFIX = ".html", CACHE_DIR_SEGMENT = "komga.cache"}
end
package.preload["Komga/VolumePath"] = function()
    return {chapterIndex = function() return nil end}
end

local PS = require("Komga/ProgressSync")

-- 浏览器桩: 记录 writeVolLnk/refreshVolumeMetadata 调用
local function new_browser(lnk_exists)
    -- 先声明再赋值: 表构造器里的闭包要引用 br, local br = {...} 语句完成前 br 尚不在作用域内
    local br
    br = {
        calls = {}, writes = {},
        writeVolLnk = function(_, volume, volume_folder, book_cache_id)
            br.calls[#br.calls + 1] = {"writeVolLnk", volume.number}
            return lnk_exists and ("/vol/" .. tostring(volume.number) .. ".html") or nil
        end,
        refreshVolumeMetadata = function(_, _, lnk_path, book_cache_id, number, _)
            br.calls[#br.calls + 1] = {"refresh", number}
            br.writes[number] = (br.writes[number] or 0) + 1
        end,
    }
    return br
end

local function new_libview(br)
    -- 生产环境 LibraryView 经 setmetatable(state, {__index = ProgressSync}) 混入方法,
    -- 桩保持同一解析路径, 被测代码里的 self:xxx() 调用才能走通
    return setmetatable({book_browser = br, server_rp_busy = nil}, {__index = PS})
end

-- 把 scheduleIn 排进的任务全部跑完(含执行中新增的)
local function drain_scheduled()
    while #scheduled > 0 do
        local job = table.remove(scheduled)
        job.fn()
    end
end

-- ===== extractServerProgressMap =====
T("extractServerProgressMap: 提取 id/readProgress/pagesCount, 跳过无 readProgress/无 id 的书", function()
    local books = {
        {id = "b1", readProgress = {page = 12, completed = false}, media = {pagesCount = 200}},
        {id = "b2", readProgress = {page = 200, completed = true}, media = {pagesCount = 200}},
        {id = "b3", media = {pagesCount = 100}}, -- 无 readProgress
        {readProgress = {page = 1}},             -- 无 id
        "junk",                                  -- 非表
    }
    local map = PS.extractServerProgressMap(books)
    eq(map.b1.page, 12)
    eq(map.b1.pages, 200)
    eq(map.b1.completed, false)
    eq(map.b2.completed, true)
    ok(map.b3 == nil, "无 readProgress 的书不应入 map")
    ok(map.junk == nil, "非表条目不应入 map")
end)

T("extractServerProgressMap: 非表输入返回空表", function()
    ok(next(PS.extractServerProgressMap(nil)) == nil)
    ok(next(PS.extractServerProgressMap("x")) == nil)
end)

-- ===== volumeServerFrac =====
T("volumeServerFrac: completed → 1; page/pages 换算; 越界与缺参钳制", function()
    eq(PS.volumeServerFrac({completed = true, page = 0, pages = 100}), 1)
    local frac = PS.volumeServerFrac({page = 50, pages = 200})
    ok(math.abs(frac - 0.25) < 1e-9, "比例换算")
    eq(PS.volumeServerFrac({page = 999, pages = 100}), 1)
    eq(PS.volumeServerFrac({page = 0, pages = 100}), nil)
    eq(PS.volumeServerFrac({page = 10}), nil) -- 无 pages
    eq(PS.volumeServerFrac({}), nil)
    eq(PS.volumeServerFrac(nil), nil)
end)

-- ===== syncAllVolumesServerProgress =====
T("syncAllVolumes: 离线/参数缺失静默跳过(不发请求)", function()
    network_online = false
    local lv = new_libview(new_browser(true))
    PS.syncAllVolumesServerProgress(lv, "bc1", {name = "x"}, "/vol")
    eq(#pushed, 0)
    network_online = true
    PS.syncAllVolumesServerProgress(lv, nil, {name = "x"}, "/vol")
    PS.syncAllVolumesServerProgress(lv, "bc1", nil, "/vol")
    PS.syncAllVolumesServerProgress(lv, "bc1", {name = "x"}, nil)
    eq(#pushed, 0)
end)

T("syncAllVolumes: 任务进 sync 通道, 子进程取数提取 map, 回调后清除去重标记", function()
    local lv = new_libview(new_browser(true))
    rp_response = {type = "SUCCESS", body = {
        {id = "b1", readProgress = {page = 30, completed = false}, media = {pagesCount = 300}},
    }}
    PS.syncAllVolumesServerProgress(lv, "bc1", {name = "x"}, "/vol")
    eq(#pushed, 1)
    eq(pushed[1].opts.tag, "series_read_progress")
    eq(rp_series_id, nil, "驱动任务前不应发请求")
    local map = pushed[1].func() -- 模拟子进程执行
    eq(rp_series_id, "bc1")
    eq(map.b1.page, 30)
    lv.book_browser = new_browser(true)
    pushed[1].callback(true, map) -- 模拟主线程回调
    ok(lv.server_rp_busy == nil or lv.server_rp_busy.bc1 == nil, "回调后必须清除去重标记")
    drain_scheduled()
end)

T("syncAllVolumes: 失败响应回传空表, 不落盘", function()
    local lv = new_libview(new_browser(true))
    pushed = {}
    rp_response = {type = "ERROR", message = "boom"}
    PS.syncAllVolumesServerProgress(lv, "bc2", {name = "x"}, "/vol")
    local map = pushed[1].func()
    ok(next(map) == nil, "失败应回传空表")
    pushed[1].callback(true, map)
    drain_scheduled()
end)

T("syncAllVolumes: 同系列在途去重, 不同系列不受影响", function()
    local lv = new_libview(new_browser(true))
    pushed = {}
    rp_response = {type = "SUCCESS", body = {}}
    PS.syncAllVolumesServerProgress(lv, "bc3", {name = "x"}, "/vol")
    PS.syncAllVolumesServerProgress(lv, "bc3", {name = "x"}, "/vol")
    eq(#pushed, 1)
    PS.syncAllVolumesServerProgress(lv, "bc4", {name = "x"}, "/vol")
    eq(#pushed, 2)
end)

-- ===== applyServerProgressToShortcuts =====
T("applyVolumes: 无服务器进度卷与 isRead 卷被过滤, 空目标不安排分块任务", function()
    volumes_reply = {
        {number = 1, bookId = "b1", isRead = true},
        {number = 2, bookId = "b2"}, -- 无服务器进度
    }
    local br = new_browser(true)
    local lv = new_libview(br)
    scheduled = {}
    PS.applyServerProgressToShortcuts(lv, "bc", {name = "x"}, "/vol", {
        b1 = {page = 10, pages = 100, completed = false},
    })
    eq(#scheduled, 0, "目标为空不应安排分块任务")
end)

T("applyVolumes: 有变化卷落盘并刷新元数据, 无变化/isRead 卷零写入", function()
    volumes_reply = {
        {number = 1, bookId = "b1"},               -- sidecar 现值与服务器相同 → 零写入
        {number = 2, bookId = "b2"},               -- 有变化 → 写入
        {number = 3, bookId = "b3"},               -- 无现值 → 写入
        {number = 4, bookId = "b4", isRead = true}, -- isRead → 过滤
    }
    -- sidecar 现值: 卷 1 = 0.5, 其余无
    DocSettingsStub.open = function(_, path)
        return {
            readSetting = function(_, k)
                if k == "komga_progress" and path == "/vol/1.html" then
                    return 0.5
                end
            end,
            saveSetting = function(self, _, _) return self end,
            flush = function() end,
        }
    end
    local br = new_browser(true)
    local lv = new_libview(br)
    scheduled = {}
    PS.applyServerProgressToShortcuts(lv, "bc", {name = "x"}, "/vol", {
        b1 = {page = 50, pages = 100, completed = false},
        b2 = {page = 20, pages = 100, completed = false},
        b3 = {completed = true},
        b4 = {page = 90, pages = 100},
    })
    drain_scheduled()
    local refreshed = {}
    for _, call in ipairs(br.calls) do
        if call[1] == "refresh" then
            refreshed[#refreshed + 1] = call[2]
        end
    end
    eq(#refreshed, 2, "只应有卷 2/3 触发元数据刷新")
    ok(refreshed[1] == 2 and refreshed[2] == 3, "处理顺序按卷号")
    ok(br.writes[4] == nil, "isRead 卷不应被处理")
end)

-- ===== persistServerProgressToShortcut =====
T("persistSingle: 无变化零写入; 有变化写 komga_progress + 刷新元数据", function()
    local stored = {["/vol/1.html"] = 0.5}
    local saved = {}
    DocSettingsStub.open = function(_, path)
        return {
            readSetting = function(_, k)
                if k == "komga_progress" then
                    return stored[path]
                end
            end,
            saveSetting = function(self, _, v) saved[path] = v return self end,
            flush = function() end,
        }
    end
    local br = new_browser(true)
    local lv = new_libview(br)
    local wrote = PS.persistServerProgressToShortcut(lv, "bc1", "/vol",
        {number = 1, bookId = "b1"}, 0.5, {name = "x"})
    eq(wrote, false, "现值 0.5 与新值 0.5 相同, 不应写入")
    ok(saved["/vol/1.html"] == nil)

    wrote = PS.persistServerProgressToShortcut(lv, "bc1", "/vol",
        {number = 1, bookId = "b1"}, 0.75, {name = "x"})
    eq(wrote, true)
    ok(math.abs(saved["/vol/1.html"] - 0.75) < 1e-9, "应写入新比例")
    eq(br.writes[1] or 0, 1, "应触发一次卷元数据刷新")
end)

T("persistSingle: 快捷方式缺失/参数非法返回 false", function()
    local lv = new_libview(new_browser(false)) -- writeVolLnk 返回 nil
    eq(PS.persistServerProgressToShortcut(lv, "bc1", "/vol",
        {number = 2, bookId = "b2"}, 0.9, {name = "x"}), false)
    lv = new_libview(new_browser(true))
    eq(PS.persistServerProgressToShortcut(lv, "bc1", "/vol", {number = 1}, 0, {name = "x"}), false)
    eq(PS.persistServerProgressToShortcut(lv, "bc1", "/vol", {number = 1}, nil, {name = "x"}), false)
    eq(PS.persistServerProgressToShortcut(lv, "bc1", "/vol", nil, 0.5, {name = "x"}), false)
    eq(PS.persistServerProgressToShortcut(lv, "bc1", "/vol", {number = "x"}, 0.5, {name = "x"}), false)
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
