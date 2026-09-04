--[[ Komga/db/SeriesStore.lua — BookInfoDB 按表拆分
经 BookInfoDB 元表 __index 混入: 实例方法 self:xxx(...) 的 self 仍为
BookInfoDB 实例(dbPath/db_conn/execute/transaction 等基础设施在 M)。
]]

local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local dbg = require("dbg")
local Device = require("device")
local util = require("util")
local VolumePath = require("Komga/VolumePath")
local md5 = require("ffi/sha2").md5
local H = require("Komga/Helper")

local Store = {}

-- 列描述(queryObjects 用, 顺序与各 SELECT 列序一致)
local SERIES_UI_COLS = {
    { "cache_id" }, { "name" }, { "author" }, { "originName" },
    { "lastRead", "number" }, { "durChapterIndex", "number" }, { "durChapterPos", "number" },
}
local SERIES_INFO_COLS = {
    { "cache_id" }, { "name" }, { "author" }, { "url" }, { "origin" }, { "originName" },
    { "originOrder", "number" }, { "durChapterIndex", "number" }, { "durChapterPos", "number" },
    { "durChapterTime", "number" }, { "durChapterTitle" }, { "wordCount" }, { "intro" },
    { "booksCount", "number" }, { "kind" }, { "sortOrder", "number" }, { "cacheExt" }, { "coverUrl" },
}

-- 排序模式: last_read=最后阅读(默认, 刚读完的排最前)/updated=更新时间/name=名称;
-- 手动置顶恒优先。lastRead 为 NULL(从未打开)排在最后: SQLite 中 NULL 在 DESC 时恒小于任何值
local ORDER_BY = {
    last_read = "lastRead DESC",
    updated = "lastUpdated DESC",
    name = "name COLLATE NOCASE ASC",
}

function Store:getAllSeriesByUI(bookShelfId, sort_mode)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, originName, lastRead, durChapterIndex, durChapterPos FROM series WHERE isEnabled = 1 AND bookShelfId = ?
    ]]
    sql_stmt = sql_stmt .. " ORDER BY (sortOrder = 0) DESC, " ..
        (ORDER_BY[sort_mode] or ORDER_BY.last_read)
    return self:queryObjects(sql_stmt, {bookShelfId}, SERIES_UI_COLS)
end
function Store:getSeriesInfo(bookShelfId, bookCacheId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, url, origin, originName, 
    originOrder, durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, 
    wordCount, intro, booksCount, kind, sortOrder, cacheExt, coverUrl FROM series WHERE isEnabled = 1 AND bookShelfId = ? AND bookCacheId =? ;
    ]]
    local list = self:queryObjects(sql_stmt, {bookShelfId, bookCacheId}, SERIES_INFO_COLS,
        { book_self_id = bookShelfId })

    if type(list[1]) ~= 'table' then
        return {}
    end

    return list[1]
end
function Store:getSeriesLastUpdateTime(bookCacheId)
    local sql_stmt = string.format(
        "SELECT lastUpdated FROM series WHERE isEnabled = 1 AND bookCacheId = '%s';", bookCacheId)

    -- 查询失败(表未就绪等)用当前时间兜底。原代码在失败分支引用未 require 的
    -- time 全局, pcall 兜底反而会报错; os.time() 为 Lua 标准库, 始终可用
    local ok, ret = pcall(function()
        return self:getDB():rowexec(sql_stmt)
    end)
    if not ok then
        ret = os.time()
    end
    return tonumber(ret)
end
function Store:clearAllSeries(bookShelfId)
    if not H.is_str(bookShelfId) then
        dbg.log('DB clearAllSeries error')
        return false
    end

    self:dynamicUpdate('series', {
        isEnabled = 0
    }, {
        bookShelfId = bookShelfId
    })
    return true
end
function Store:dynamicUpdateSeries(series, updateData)
    if not H.is_tbl(updateData) or not H.is_tbl(series) then
        dbg.log('dynamicUpdateSeries An error occurred when calling the parameter')
        return
    end

    local bookCacheId = series.book_cache_id
    local bookShelfId = series.bookShelfId

    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        dbg.log('dynamicUpdateSeries Error parameters')
        error('dynamicUpdateSeries Error parameters')
        return
    end

    return self:dynamicUpdate('series', updateData, {
        bookCacheId = bookCacheId,
        bookShelfId = bookShelfId
    })
end
function Store:setSeriesTopStatus(bookShelfId, book_cache_id, isPinnedManually, isPinnedByTime)
    if not (H.is_str(bookShelfId) and H.is_str(book_cache_id)) then
        dbg.log('DB setSeriesTopStatus error')
        return false
    end

    local set_sortorder = 0
    local where_sortorder = {
        _where = ' > 0'
    }
    if 0 == isPinnedByTime then
        local sql_stmt = [[
        SELECT bookCacheId FROM series 
        WHERE isEnabled = 1 AND bookShelfId = '%s' AND sortOrder != 0 
        ORDER BY sortOrder DESC LIMIT 1;
    ]]
        sql_stmt = string.format(sql_stmt, bookShelfId)
        local ok, firstBookCacheId = pcall(function()
            return self:getDB():rowexec(sql_stmt)
        end)
        if ok and firstBookCacheId and firstBookCacheId == book_cache_id then
            -- logger.info(book_cache_id, "it's the first, don't update it anymore")
            return true
        end

        set_sortorder = {
            _set = "= strftime('%s', 'now')"
        }
        where_sortorder = {
            _where = ' > 0'
        }
    elseif 0 == isPinnedManually then 
        set_sortorder = {
            _set = "= strftime('%s', 'now')"
        }
        where_sortorder = 0
    end

    return self:dynamicUpdate('series', {
        sortOrder = set_sortorder
    }, {
        bookCacheId = book_cache_id,
        bookShelfId = bookShelfId,
        sortOrder = where_sortorder
    })
end
function Store:touchSeriesLastRead(bookCacheId)
    if not H.is_str(bookCacheId) then
        return false
    end
    local ok = pcall(function()
        self:execute(
            "UPDATE series SET lastRead = strftime('%s', 'now') WHERE bookCacheId = ?;",
            {bookCacheId})
    end)
    return ok
end

return Store
