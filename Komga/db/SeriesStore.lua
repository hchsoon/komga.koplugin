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

function Store:getAllSeries(bookShelfId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, url, origin, originName, 
    originOrder, durChapterIndex, durChapterPos FROM series WHERE isEnabled = 1 AND bookShelfId = ?;
    ]]
    -- 排序模式: updated=更新时间(默认)/name=名称/last_read=最后阅读; 手动置顶恒优先
    local order_by = {
        updated = "lastUpdated DESC",
        name = "name COLLATE NOCASE ASC",
        last_read = "lastRead DESC",
    }
    sql_stmt = sql_stmt .. " ORDER BY (sortOrder = 0) DESC, " ..
        (order_by[sort_mode] or order_by.updated)
    local result = self:execute(sql_stmt, {bookShelfId})
    local series = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            series[i] = {
                book_self_id = bookShelfId,

                cache_id = row[1],

                name = row[2],
                author = row[3],
                url = row[4],
                origin = row[5],
                originName = row[6],
                originOrder = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterPos = row[9]
            }
        end
    end

    return series
end
function Store:getAllSeriesByUI(bookShelfId, sort_mode)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, originName, lastRead, durChapterIndex, durChapterPos FROM series WHERE isEnabled = 1 AND bookShelfId = ?
    ]]
    local result = self:execute(sql_stmt, {bookShelfId})
    local series = {}
    if H.is_tbl(result) and #result > 0 then
        for i = 1, #result, 1 do
            local row = result[i]
            series[i] = {
                cache_id = row[1],
                name = row[2],
                author = row[3],
                originName = row[4],
                lastRead = tonumber(row[5]),
                durChapterIndex = tonumber(row[6]),
                durChapterPos = tonumber(row[7])
            }
        end
    end

    return series
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
    local result = self:execute(sql_stmt, {bookShelfId, bookCacheId})
    local series = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            series[i] = {
                book_self_id = bookShelfId,
                cache_id = row[1],
                name = row[2],
                author = row[3],
                url = row[4],
                origin = row[5],
                originName = row[6],
                originOrder = tonumber(row[7]),
                durChapterIndex = tonumber(row[8]),
                durChapterPos = tonumber(row[9]),
                durChapterTime = tonumber(row[10]),
                durChapterTitle = row[11],
                wordCount = row[12],
                intro = row[13],
                booksCount = tonumber(row[14]),
                kind = row[15],
                sortOrder = tonumber(row[16]),
                cacheExt = row[17],
                coverUrl = row[18]
            }
        end
    end

    if type(series[1]) ~= 'table' then
        return {}
    end

    return series[1]
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
