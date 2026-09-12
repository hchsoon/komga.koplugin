--[[ Komga/db/EpubChapterStore.lua — BookInfoDB 按表拆分
经 BookInfoDB 元表 __index 混入: 实例方法 self:xxx(...) 的 self 仍为
BookInfoDB 实例(dbPath/db_conn/execute/transaction 等基础设施在 M)。
]]

local dbg = require("dbg")
local H = require("Komga/Helper")

local Store = {}

-- 列描述(queryObjects 用, 顺序与各 SELECT 列序一致)。
local EPUB_CHAPTER_COLS = {
    { "number", "number" }, { "title" }, { "url" }, { "isRead", "bool01" },
    { "cacheFilePath" }, { "volumename" },
}
local EPUB_URL_COLS = {
    { "number", "number" }, { "url" },
}
-- findNextEpubChapterInfo: join series 的 11 列; isDownLoaded 派生自第 4 列, 放 cols 末尾
local EPUB_NEXT_COLS = {
    { "number", "number" }, { "title" }, { "isRead", "bool01" }, { "cacheFilePath" },
    { "name" }, { "author" }, { "url" }, { "durChapterIndex", "number" },
    { "durChapterTime", "number" }, { "booksCount", "number" }, { "cacheExt" },
    { "isDownLoaded", function(_, row) return not not row[4] end },
}

function Store:upsertEpubChapters(bookCacheId, epub_data)
    if not H.is_str(bookCacheId) or not H.is_tbl(epub_data) then
        dbg.log('BookInfoDB:upsertEpubChapters Incorrect input parameters')
        return false
    end

    local sql_stmt = [[
        INSERT INTO epub_chapter (bookCacheId, chapterId, number, title, url)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(chapterId, number) DO UPDATE SET
    title = CASE WHEN excluded.title != epub_chapter.title THEN excluded.title ELSE epub_chapter.title END,
    url = CASE WHEN excluded.url IS NOT NULL AND excluded.url != '' THEN excluded.url ELSE epub_chapter.url END;
    ]]

    -- TODO: 章节与xhtml不是一一对应的，有些不在内的xhtml未被入库

    local batch_data = {}
    for index, chapter in ipairs(epub_data.readingOrder) do
        -- if chapter.title ~= nil then
        -- if not H.is_str(chapter.title) or chapter.title == '' then
        --     chapter.title = string.format('No title', chapter.index)
        -- end
        -- print(bookCacheId, epub_data.bookId ,index, chapter.title, chapter.href)

        table.insert(batch_data, {bookCacheId, epub_data.bookId ,index, 'No title', chapter.href})
    end

    -- webpub+json 的 toc 是嵌套结构(卷->章->节)。只遍历顶层会漏掉子章节,
    -- 其 title 保持 'No title' 而被目录过滤, 导致第一章下的子章节获取不到。
    -- 这里先展平 toc, 再按 href 匹配 readingOrder, 把子章节标题写回库。
    local function flatten_toc(toc)
        local flat = {}
        local function walk(items)
            for _, item in ipairs(items or {}) do
                table.insert(flat, item)
                if H.is_tbl(item.children) and #item.children > 0 then
                    walk(item.children)
                end
            end
        end
        walk(toc)
        return flat
    end

    for _, chapter in ipairs(flatten_toc(epub_data.toc)) do
        for _, batch_entry in ipairs(batch_data) do
            if batch_entry[5] == chapter.href then
                batch_entry[4] = chapter.title
            end
        end
    end

    if #batch_data > 0 then

        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true
end
function Store:getEpubChapterCount(chapterId)
    local sql_stmt = "SELECT count(*) as total_num FROM epub_chapter WHERE chapterId = '%s';"
    sql_stmt = string.format(sql_stmt, chapterId)
    -- print("Sql_fmt is...", sql_stmt)
    local booksCount = self:getDB():rowexec(sql_stmt)
    return tonumber(booksCount)
end
function Store:getAllEpubChapters(chapterId)
    if chapterId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT 
    c.number, 
    c.title, 
    c.url,
    c.isRead,
    c.cacheFilePath,
    v.title as VolumeTitle
FROM epub_chapter AS c
INNER JOIN volume AS v
    ON c.chapterId = v.bookId 
WHERE 
    c.chapterId = ? AND c.title <> 'No title'
ORDER BY c.number ASC;
    ]]

    local result = self:queryObjects(sql_stmt, chapterId, EPUB_CHAPTER_COLS, { chapterId = chapterId })
    return result
end
function Store:getAllEpubChapterUrls(chapterId)
    if chapterId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT c.number, c.url
FROM epub_chapter AS c
WHERE c.chapterId = ?
ORDER BY c.number ASC;
    ]]

    return self:queryObjects(sql_stmt, chapterId, EPUB_URL_COLS)
end
function Store:getEpubChapterInfo(chapterId, epubChapterIndex)
    if not H.is_str(chapterId) or not H.is_num(epubChapterIndex) then
        dbg.log('getEpubChapterInfo Incorrect input parameters')
        return {}
    end

    local sql_stmt = [[
    SELECT 
    c.number, 
    c.title, 
    c.url,
    c.isRead,
    c.cacheFilePath,
    v.title as VolumeTitle
FROM epub_chapter AS c
INNER JOIN volume AS v
    ON c.chapterId = v.bookId 
WHERE 
    c.chapterId = ? AND c.number = ?;
    ]]

    local result = self:queryObjects(sql_stmt, {chapterId, epubChapterIndex}, EPUB_CHAPTER_COLS,
        { chapterId = chapterId })

    if not H.is_tbl(result[1]) then
        return {}
    end

    return result[1]
end
function Store:findNextEpubChapterInfo(current_chapter, is_downloaded)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.number == nil then
        dbg.log('findNextEpubChapterInfo:', current_chapter)
        return {}
    end
    -- print("Next Epub Chapter Info book is ...", current_chapter.bookId)
    local bookCacheId = current_chapter.book_cache_id
    local bookId = current_chapter.bookId
    local current_number = current_chapter.number
    local call_event_type = current_chapter.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = [[
        SELECT 
        c.number, 
        c.title, 
        c.isRead, 
        c.cacheFilePath,
        b.name,
        b.author,
        b.url,
        b.durChapterIndex,
        b.durChapterTime,
        b.booksCount,
        b.cacheExt
    FROM epub_chapter AS c
    INNER JOIN series AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
        c.bookCacheId = ? AND c.chapterId = ? AND b.isEnabled = 1 ]]

    if is_downloaded == false then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NULL '
    elseif is_downloaded == true then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NOT NULL '
    end

    local suffix = "  AND c.number > ?  ORDER BY c.number ASC LIMIT 1;"
    if call_event_type ~= 'next' then

        suffix = "  AND c.number < ? ORDER BY c.number DESC LIMIT 1;"
    end

    sql_stmt = sql_stmt .. suffix

    local result = self:queryObjects(sql_stmt, {bookCacheId, bookId, current_number}, EPUB_NEXT_COLS,
        { book_cache_id = bookCacheId })

    if not H.is_tbl(result[1]) then
        return {}
    end

    return result[1]
end
function Store:clearSeries(bookShelfId, book_cache_id)

    if not H.is_str(bookShelfId) or not H.is_str(book_cache_id) then
        dbg.log('DB clearSeries error')
        return false
    end

    self:dynamicUpdate('series', {
        isEnabled = 0
    }, {
        bookShelfId = bookShelfId,
        bookCacheId = book_cache_id
    })

    self:dynamicUpdate('volume', {
        cacheFilePath = self.nil_object(),
        content = self.nil_object(),
        isRead = 0
    }, {
        bookCacheId = book_cache_id
    })

    -- 同时清空 epub_chapter 内部章节缓存。否则清除缓存后内部目录仍是旧的
    -- (如子章节因只遍历顶层 toc 而保持 'No title' 被过滤), 无法触发 manifest 重新拉取。
    self:execute("DELETE FROM epub_chapter WHERE bookCacheId = ? OR chapterId = ?;",
        {book_cache_id, book_cache_id})

    return true
end

return Store
