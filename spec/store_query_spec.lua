-- Store 查询层回归测试(真实 SQLite)
-- 运行: luajit spec/store_query_spec.lua
-- 依赖 KOReader app bundle 的 lua-ljsqlite3/sqlite3(自动探测 /Applications; 其他环境设 KOREADER_ROOT)。
-- 覆盖: SeriesStore/VolumeStore/EpubChapterStore 全部 SELECT 映射 —— 锁定
-- "行→对象"重构前后的字段名/字段数/类型(tonumber/bool01)行为。

local KR = os.getenv("KOREADER_ROOT") or "/Applications/KOReader.app/Contents/koreader"
package.path = "./?.lua;" .. KR .. "/common/?.lua;" .. KR .. "/frontend/?.lua;" .. KR .. "/?.lua;" .. KR .. "/ffi/?.lua;" .. package.path
package.cpath = KR .. "/common/?.so;" .. KR .. "/libs/?.so;" .. KR .. "/?.so;" .. KR .. "/ffi/?.so;" .. package.cpath

local ffi = require("ffi")
ffi.loadlib = ffi.loadlib or function(name, ver)
    local base = KR .. "/libs/lib" .. name .. (ver and ("." .. ver) or "")
    local ok, lib = pcall(ffi.load, base)
    if ok then return lib end
    return ffi.load(base .. ".dylib")
end
package.preload["ffi/utf8proc"] = function() return {lowercase = function(s) return s end} end
package.preload["ffi/utf8proc_h"] = function() end
package.preload["socket.url"] = function()
    return {escape = function(s) return s end, parse = function(s) return {path = s} end,
        unescape = function(s) return s end, absolute = function(b, p) return b .. p end}
end
package.preload["device"] = function()
    return {screen = {getWidth = function() return 1000 end, getHeight = function() return 800 end,
        getSize = function() return {w = 1000, h = 800} end, scaleBySize = function(_, n) return n end},
        isTouchDevice = function() return false end,
        canUseWAL = function() return false end}
end
package.preload["datastorage"] = function()
    return {getDataDir = function() return "/tmp/komga_spec_data" end,
        getFullDataDir = function() return "/tmp/komga_spec_data" end}
end
package.preload["dbg"] = function() return {v = function() end, log = function(...) print("[dbg]", ...) end} end
package.preload["luasettings"] = function()
    return {open = function() return {data = {}, readSetting = function() end} end} end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end, close = function() end, suspend = function() end,
        nextTick = function(_, f) end, scheduleIn = function() end, unschedule = function() end,
    }
end

local checks, failed = 0, 0
local function eq(a, e, m)
    checks = checks + 1
    if a ~= e then
        failed = failed + 1
        error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2)
    end
end
local function is_num(v, m)
    checks = checks + 1
    if type(tonumber(v)) ~= "number" then
        failed = failed + 1
        error((m or "应为数字") .. ": 实际 " .. tostring(v), 2)
    end
end

local BookInfoDB = require("Komga/BookInfoDB")
local H = require("Komga/Helper")
H.initialize("komga", ".")

local db_path = "/tmp/komga_store_spec_" .. (os.time()) .. ".db"
os.remove(db_path)
local db = BookInfoDB:new({dbPath = db_path})

-- 种子数据: 1 系列 + 3 分卷(vol2 未下载) + B1 的 3 内部章节(含一个 No title)
local conn = db:getDB()
conn:exec([[
INSERT INTO series (bookShelfId, bookCacheId, name, author, url, origin, originName,
    durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, wordCount,
    intro, booksCount, btype, isEnabled, kind, cacheExt, coverUrl, sortOrder, lastRead, lastUpdated)
VALUES ('S1', 'C1', '测试系列', '作者X', 'http://s/series/1', 'komga', 'series-1',
    2, 30, 1700000000, '第2卷', '',
    '简介', 3, 0, 1, 'manga', 'xhtml', 'http://s/cover', 5, 1700001000, 1700000000);
]])
conn:exec([[
INSERT INTO volume (bookCacheId, bookId, number, title, pages, mediaType, isRead, cacheFilePath, lastUpdated) VALUES
    ('C1', 'B1', 1, '第1卷', 100, 'Manga', 1, '/cache/v1.cbz', 1700000001),
    ('C1', 'B2', 2, '第2卷', 120, 'Manga', 0, NULL, 1700000002),
    ('C1', 'B3', 3, '第3卷', 140, 'Manga', 0, '/cache/v3.cbz', 1700000003);
]])
conn:exec([[
INSERT INTO epub_chapter (bookCacheId, chapterId, number, title, url, isRead, cacheFilePath, lastUpdated) VALUES
    ('C1', 'B1', 1, '第1章', '/a/1.xhtml', 1, '/cache/b1_1.xhtml', 1700000011),
    ('C1', 'B1', 2, '第2章', '/a/2.xhtml', 0, NULL, 1700000012),
    ('C1', 'B1', 3, 'No title', '/a/3.xhtml', 0, NULL, 1700000013);
]])

local T = function(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        print("FAIL", name, err)
    else
        print("ok  ", name)
    end
end

-- SeriesStore
T("getAllSeriesByUI: last_read 排序 + 字段映射", function()
    local list = db:getAllSeriesByUI("S1", "last_read")
    eq(#list, 1)
    local s = list[1]
    eq(s.cache_id, "C1")
    eq(s.name, "测试系列")
    eq(s.author, "作者X")
    eq(s.originName, "series-1")
    is_num(s.lastRead, "lastRead")
    eq(s.durChapterIndex, 2)
    is_num(s.durChapterPos, "durChapterPos")
end)

T("getSeriesInfo: 18 字段映射", function()
    local s = db:getSeriesInfo("S1", "C1")
    eq(s.cache_id, "C1")
    eq(s.name, "测试系列")
    eq(s.author, "作者X")
    eq(s.url, "http://s/series/1")
    eq(s.originName, "series-1")
    eq(s.originOrder, 0)
    eq(s.durChapterIndex, 2)
    is_num(s.durChapterTime, "durChapterTime")
    eq(s.booksCount, 3)
    eq(s.kind, "manga")
    is_num(s.sortOrder, "sortOrder")
    eq(s.cacheExt, "xhtml")
    eq(s.coverUrl, "http://s/cover")
end)

-- VolumeStore
T("getAllVolumes: join 字段 + isDownLoaded 派生", function()
    local vols = db:getAllVolumes("C1")
    eq(#vols, 3)
    local v1 = vols[1]
    eq(v1.book_cache_id, "C1")
    eq(v1.number, 1)
    eq(v1.title, "第1卷")
    eq(v1.isRead, true)
    eq(v1.cacheFilePath, "/cache/v1.cbz")
    eq(v1.isDownLoaded, true)
    eq(v1.name, "测试系列")
    eq(v1.author, "作者X")
    eq(v1.url, "http://s/series/1")
    eq(v1.durChapterIndex, 2)
    is_num(v1.durChapterTime, "durChapterTime")
    eq(v1.booksCount, 3)
    eq(vols[2].isDownLoaded, false)
    eq(vols[2].isRead, false)
end)

T("getAllVolumesByUI: 降序 + 映射", function()
    local vols = db:getAllVolumesByUI("C1", true)
    eq(#vols, 3)
    eq(vols[1].number, 3)
    eq(vols[1].bookId, "B3")
    eq(vols[1].isDownLoaded, true)
    eq(vols[1].cacheFilePath, "/cache/v3.cbz")
    eq(vols[2].number, 2)
    eq(vols[2].isDownLoaded, false)
    eq(vols[2].durChapterIndex, 2)
    eq(vols[3].number, 1)
end)

T("getVolumeByBookId: 单对象 + 类型转换", function()
    local v = db:getVolumeByBookId("C1", "B2")
    eq(v.number, 2)
    eq(v.title, "第2卷")
    eq(v.mediaType, "Manga")
    eq(v.pages, 120)
    eq(v.cacheFilePath, nil)
    eq(v.book_cache_id, "C1")
    eq(db:getVolumeByBookId("C1", "NOPE"), nil)
end)

T("getVolumeInfo: 14 字段映射", function()
    local v = db:getVolumeInfo("C1", 3)
    eq(v.book_cache_id, "C1")
    eq(v.number, 3)
    eq(v.title, "第3卷")
    eq(v.isRead, false)
    eq(v.cacheFilePath, "/cache/v3.cbz")
    eq(v.isDownLoaded, true)
    eq(v.name, "测试系列")
    eq(v.booksCount, 3)
    eq(v.cacheExt, "xhtml")
    eq(v.bookId, "B3")
    eq(v.pages, 140)
    eq(v.mediaType, "Manga")
    local empty = db:getVolumeInfo("C1", 99)
    eq(type(empty), "table")
end)

T("findNextVolumeInfo: next/prev/已下载过滤", function()
    local nxt = db:findNextVolumeInfo({book_cache_id = "C1", number = 1, call_event = "next"})
    eq(nxt.number, 2)
    eq(nxt.title, "第2卷")
    eq(nxt.book_cache_id, "C1")
    eq(nxt.isDownLoaded, false)
    local nxt_dl = db:findNextVolumeInfo({book_cache_id = "C1", number = 1, call_event = "next"}, true)
    eq(nxt_dl.number, 3)
    local prev = db:findNextVolumeInfo({book_cache_id = "C1", number = 2, call_event = "prev"})
    eq(prev.number, 1)
    local none = db:findNextVolumeInfo({book_cache_id = "C1", number = 3, call_event = "next"})
    eq(next(none), nil)
end)

-- EpubChapterStore
local EpubChapterStore_ok, EpubChapterStore = pcall(require, "Komga/db/EpubChapterStore")
if not EpubChapterStore_ok then
    -- BookInfoDB 的 __index 混入路径下直接经实例调用
end

T("getAllEpubChapters: 过滤 No title + join 卷名", function()
    local list = db:getAllEpubChapters("B1")
    eq(#list, 2)
    eq(list[1].number, 1)
    eq(list[1].title, "第1章")
    eq(list[1].isRead, true)
    eq(list[1].cacheFilePath, "/cache/b1_1.xhtml")
    eq(list[1].volumename, "第1卷")
    eq(list[1].chapterId, "B1")
    eq(list[2].url, "/a/2.xhtml")
end)

T("getAllEpubChapterUrls: number/url 对", function()
    local list = db:getAllEpubChapterUrls("B1")
    eq(#list, 3)
    eq(list[1].number, 1)
    eq(list[1].url, "/a/1.xhtml")
    eq(list[3].url, "/a/3.xhtml")
end)

T("getEpubChapterInfo: 单章映射", function()
    local c = db:getEpubChapterInfo("B1", 2)
    eq(c.number, 2)
    eq(c.title, "第2章")
    eq(c.isRead, false)
    eq(c.volumename, "第1卷")
    eq(c.chapterId, "B1")
end)

os.remove(db_path)
if failed > 0 then
    print(("\n失败 %d 处 (%d 断言)"):format(failed, checks))
    os.exit(1)
end
print(("\n全部通过 (%d 断言)"):format(checks))
