--[[ Komga/db/VolumeStore.lua — BookInfoDB 按表拆分
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

function Store:upsertSeries(bookShelfId, komga_data, server_address,isUpdate)
    if not H.is_str(bookShelfId) or not H.is_tbl(komga_data) then
        dbg.log('BookInfoDB:upsertSeries Incorrect input parameters')
        return false
    end

    local seriesData = {}

    for index, series in ipairs(komga_data) do
        -- Komga Series: 书名在 metadata.title, 作者在 booksMetadata.authors(拼接)
        series.name = series.metadata.title
        local authorname = ""
        for index, author in ipairs(series.booksMetadata.authors) do
            if index == 1 then
                authorname = author.name
            else
                authorname = author.name .. "/" .. authorname
            end
        end
        series.author = authorname

        if not H.is_str(series.name) or not H.is_str(series.id) or not H.is_str(series.url) then
            goto continue
        end

        -- 本地主键: bookCacheId = md5(书名[作者])
        series.cache_id = tostring(md5(("%s[%s]"):format(series.name, series.author)))

        table.insert(seriesData, series)
        ::continue::
    end

    local sql_stmt = [[
    INSERT INTO series (
    bookShelfId, bookCacheId, name, author, url, origin, originName, originOrder, 
    durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, wordCount, 
    coverUrl, intro, booksCount, btype, isEnabled, kind
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(bookShelfId, bookCacheId) DO UPDATE SET
    name = CASE WHEN excluded.name != series.name THEN excluded.name ELSE series.name END,
    author = CASE WHEN excluded.author != series.author THEN excluded.author ELSE series.author END,
    url = CASE WHEN excluded.url != series.url THEN excluded.url ELSE series.url END,
    origin = CASE WHEN excluded.origin != series.origin THEN excluded.origin ELSE series.origin END,
    originName = CASE WHEN excluded.originName != series.originName THEN excluded.originName ELSE series.originName END,
    originOrder = CASE WHEN excluded.originOrder != series.originOrder THEN excluded.originOrder ELSE series.originOrder END,
    durChapterIndex = CASE WHEN excluded.durChapterIndex != series.durChapterIndex THEN excluded.durChapterIndex ELSE series.durChapterIndex END,
    durChapterPos = CASE WHEN excluded.durChapterPos != series.durChapterPos THEN excluded.durChapterPos ELSE series.durChapterPos END,
    durChapterTime = CASE WHEN excluded.durChapterTime != series.durChapterTime THEN excluded.durChapterTime ELSE series.durChapterTime END,
    durChapterTitle = CASE WHEN excluded.durChapterTitle != series.durChapterTitle THEN excluded.durChapterTitle ELSE series.durChapterTitle END,
    wordCount = CASE WHEN excluded.wordCount != series.wordCount THEN excluded.wordCount ELSE series.wordCount END,
    coverUrl = CASE WHEN excluded.coverUrl != series.coverUrl THEN excluded.coverUrl ELSE series.coverUrl END,
    intro = CASE WHEN excluded.intro != series.intro THEN excluded.intro ELSE series.intro END,
    booksCount = CASE WHEN excluded.booksCount != series.booksCount THEN excluded.booksCount ELSE series.booksCount END,
    btype = CASE WHEN excluded.btype != series.btype THEN excluded.btype ELSE series.btype END,
    isEnabled = CASE WHEN excluded.isEnabled != series.isEnabled THEN excluded.isEnabled ELSE series.isEnabled END,
    kind = CASE WHEN excluded.kind != series.kind THEN excluded.kind ELSE series.kind END, 
    lastUpdated = CASE WHEN (
    excluded.url != series.url OR
    excluded.wordCount != series.wordCount
) THEN strftime('%s', 'now') ELSE series.lastUpdated END
    ]]

    local batch_data = {}
    for index, series in ipairs(seriesData) do
        -- 封面 URL 带服务器 lastModified 版本号(?v=): download_cover_img 据此判断
        -- 封面是否需要重新下载, Komga 换封面后随书架同步自动刷新
        local cover_version = VolumePath.escapeVersion(H.is_str(series.lastModified) and series.lastModified or "")
        local coverUrl = server_address .. "/api/v1/series/" .. series.id ..
            "/thumbnail" .. (cover_version ~= "" and ("?v=" .. cover_version) or "")
        batch_data[index] = {bookShelfId, series.id, series.metadata.title, series.author, series.url, series.id or "",
            series.metadata.title or "", series.originOrder or 0, series.durChapterIndex or 0,
            series.durChapterPos or 0, series.durChapterTime or 0, series.durChapterTitle or "",
            series.wordCount or "", coverUrl, series.metadata.summary or "", series.booksCount or 0,
            series.type or 0, 1, series.kind or ''}
    end

    if batch_data and #batch_data > 0 then
        if isUpdate ~= true then
            self:getDB():exec("UPDATE series SET isEnabled = 0;")
        end
        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true

end
function Store:upsertVolumes(bookCacheId, volumes)
    if not H.is_str(bookCacheId) or not H.is_tbl(volumes) then
        dbg.log('BookInfoDB:upsertVolumes Incorrect input parameters')
        return false
    end

    local sql_stmt = [[
        INSERT INTO volume (bookCacheId, bookId, number, title, pages, mediaType)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(bookCacheId, number) DO UPDATE SET
    title = CASE WHEN excluded.title != volume.title THEN excluded.title ELSE volume.title END;
    ]]

    local batch_data = {}
    for index, volume in ipairs(volumes) do
        if volume.number ~= nil then
            -- Komga Book(分卷)标题: metadata.title 优先; 缺失时用卷号兜底。
            -- (原代码把兜底写进 chapter.title 却插入 chapter.metadata.title, 兜底从未生效, 已修复)
            local vol_title = volume.metadata.title
            if not (H.is_str(vol_title) and vol_title ~= '') then
                vol_title = string.format('第%s卷', volume.number)
            end
            table.insert(batch_data, {bookCacheId, volume.id, volume.number, vol_title,
                volume.media.pagesCount, volume.media.mediaProfile})
        end
    end

    if #batch_data > 0 then
        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true
end
function Store:getAllVolumes(bookCacheId)
    if bookCacheId == nil then
        return {}
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
    b.booksCount 
FROM volume AS c
INNER JOIN series AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? 
ORDER BY c.number ASC;
    ]]

    local result = self:execute(sql_stmt, bookCacheId)
    local volumes = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            volumes[i] = {
                book_cache_id = bookCacheId,
                number = tonumber(row[1]),
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                url = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = tonumber(row[9]),
                booksCount = tonumber(row[10])

            }
        end
    end

    return volumes
end
function Store:getAllVolumesByUI(bookCacheId, is_desc_sort)
    if bookCacheId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT
    c.number, 
    c.title, 
    c.isRead, 
    c.cacheFilePath,
    b.durChapterIndex,
    c.bookId
FROM volume AS c
INNER JOIN series AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? 
ORDER BY c.number ]]

    if is_desc_sort == true then
        sql_stmt = sql_stmt .. ' DESC;'
    else
        sql_stmt = sql_stmt .. ' ASC;'
    end
    local result = self:execute(sql_stmt, bookCacheId)
    local volumes = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]
            local number = tonumber(row[1])
            volumes[i] = {
                number = number,
                title = row[2],
                isRead = row[3] == 1,
                isDownLoaded = not not row[4],
                durChapterIndex = tonumber(row[5]),
                cacheFilePath = row[4],
                bookId = row[6]
            }
        end
    end

    return volumes
end
function Store:getVolumeCount(bookCacheId)
    local sql_stmt = "SELECT count(*) as total_num FROM volume WHERE  bookCacheId = '%s';"
    sql_stmt = string.format(sql_stmt, bookCacheId)
    local booksCount = self:getDB():rowexec(sql_stmt)
    return tonumber(booksCount)
end
function Store:getLastReadVolumeIndex(bookCacheId)
    if not H.is_str(bookCacheId) then
        return 0
    end
    local sql_stmt = [[
            SELECT  COALESCE(number, 0) AS number 
FROM volume
WHERE lastUpdated IS NOT NULL AND bookCacheId = '%s'
ORDER BY lastUpdated DESC
LIMIT 1;
    ]]
    sql_stmt = string.format(sql_stmt, bookCacheId)
    local lastUpdated = self:getDB():rowexec(sql_stmt)
    return tonumber(lastUpdated) or 0
end
function Store:getVolumeByBookId(bookCacheId, bookId)
    if not (H.is_str(bookCacheId) and H.is_str(bookId)) then
        dbg.log('getVolumeByBookId Incorrect input parameters')
        return nil
    end
    local sql_stmt = [[
    SELECT
    c.number,
    c.title,
    c.mediaType,
    c.pages,
    c.cacheFilePath
FROM volume AS c
WHERE c.bookCacheId = ? AND c.bookId = ? LIMIT 1;
    ]]
    local result = self:execute(sql_stmt, {bookCacheId, bookId})
    if result and #result > 0 then
        local row = result[1]
        return {
            book_cache_id = bookCacheId,
            bookId = bookId,
            number = tonumber(row[1]),
            title = row[2],
            mediaType = row[3],
            pages = tonumber(row[4]),
            cacheFilePath = row[5]
        }
    end
    return nil
end
function Store:getVolumeInfo(bookCacheId, number)
    if not H.is_str(bookCacheId) or not H.is_num(number) then
        dbg.log('getVolumeInfo Incorrect input parameters')
        return {}
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
    b.cacheExt,
    c.bookId,
    c.pages,
    c.mediaType
FROM volume AS c
INNER JOIN series AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? AND c.number = ?;
    ]]

    local result = self:execute(sql_stmt, {bookCacheId, number})
    local volume = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local number = tonumber(row[1])
            volume[i] = {
                book_cache_id = bookCacheId,
                number = number,
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                url = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = tonumber(row[9]),
                booksCount = tonumber(row[10]),
                cacheExt = row[11],
                bookId = row[12],
                pages = tonumber(row[13]),
                mediaType = row[14]
            }
        end
    end

    if not H.is_tbl(volume[1]) then
        return {}
    end

    return volume[1]
end
function Store:getReadAheadVolumeCount(current_volume)

    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.number == nil then
        dbg.log('getReadAheadVolumeCount:', current_volume)
        return 0
    end

    local bookCacheId = current_volume.book_cache_id
    local current_volume_index = current_volume.number
    local call_event_type = current_volume.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = ''
    if call_event_type == 'next' then
        sql_stmt = [[
SELECT COUNT(*) AS continuous_count
FROM volume AS c
WHERE 
  c.number > %d        
  AND c.cacheFilePath IS NOT NULL 
  AND c.bookCacheId = '%s'   
  AND c.number < COALESCE(
      (SELECT MIN(number) 
       FROM volume 
       WHERE number > %d  
         AND cacheFilePath IS NULL 
         AND bookCacheId = '%s'   
      ),
      (SELECT MAX(number) + 1 
       FROM volume 
       WHERE bookCacheId = '%s'  
      )
  )
  AND EXISTS (
      SELECT 1 FROM series AS b 
      WHERE b.bookCacheId = c.bookCacheId 
        AND b.isEnabled = 1
  );
  ]]

        sql_stmt = string.format(sql_stmt, current_volume_index, bookCacheId, current_volume_index, bookCacheId,
            bookCacheId)
    else

        sql_stmt = [[
                    SELECT COUNT(*) AS continuous_count
FROM volume AS c
WHERE 
  c.number < %d       
  AND c.cacheFilePath IS NOT NULL 
  AND c.bookCacheId = '%s'   
  AND c.number > COALESCE(
      (SELECT MAX(number) 
       FROM volume 
       WHERE number < %d 
         AND cacheFilePath IS NULL 
         AND bookCacheId = '%s'
      ),
      (SELECT MIN(number) - 1 
       FROM volume 
       WHERE bookCacheId = '%s'
      )
  )
  AND EXISTS (
      SELECT 1 FROM series AS b 
      WHERE b.bookCacheId = c.bookCacheId 
        AND b.isEnabled = 1
  );

    ]]
        sql_stmt = string.format(sql_stmt, current_volume_index, bookCacheId, current_volume_index, bookCacheId,
            bookCacheId)
    end
    local continuous_count = self:getDB():rowexec(sql_stmt)
    return tonumber(continuous_count)

end
function Store:findVolumesNotDownloaded(current_volume, count)
    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.number == nil then
        dbg.log('findVolumesNotDownloaded:', current_volume)
        return {}
    end

    if not H.is_num(count) or count < 1 then
        count = 1
    end

    local bookCacheId = current_volume.book_cache_id
    local current_volume_index = current_volume.number
    local call_event_type = current_volume.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = [[
        SELECT 
        c.number, 
        c.title, 
        b.url,
        b.name,
        c.bookId
    FROM volume AS c
    INNER JOIN series AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
         c.bookCacheId = ? AND b.isEnabled = 1 AND c.isRead = 0 AND c.cacheFilePath IS NULL
         ]]

    local suffix = "  AND c.number > ?  ORDER BY c.number ASC LIMIT "

    if call_event_type ~= 'next' then
        suffix = "  AND c.number < ? ORDER BY c.number DESC LIMIT "
    end

    sql_stmt = table.concat({sql_stmt, suffix, count, ';'})

    local result = self:execute(sql_stmt, {bookCacheId, current_volume_index})

    local volumes = {}
    if result and #result > 0 then
        for i = 1, #result, 1 do
            local row = result[i]
            local number = tonumber(row[1])
            volumes[i] = {
                book_cache_id = bookCacheId,
                title = row[2],
                url = row[3],
                number = number,
                name = row[4],
                bookId = row[5]
            }
        end
    end

    if not H.is_tbl(volumes[1]) then
        return {}
    end

    return volumes

end
function Store:findNextVolumeInfo(current_volume, is_downloaded)
    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.number == nil then
        dbg.log('findNextVolumeInfo:', current_volume)
        return {}
    end

    local bookCacheId = current_volume.book_cache_id
    local current_volume_index = current_volume.number
    local call_event_type = current_volume.call_event
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
    FROM volume AS c
    INNER JOIN series AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
         c.bookCacheId = ? AND b.isEnabled = 1 ]]

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

    local result = self:execute(sql_stmt, {bookCacheId, current_volume_index})

    local volume = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local number = tonumber(row[1])
            volume[i] = {
                book_cache_id = bookCacheId,
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                url = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = tonumber(row[9]), -- type cdata?
                booksCount = tonumber(row[10]),
                number = number,
                cacheExt = row[11]
            }
        end
    end

    if not H.is_tbl(volume[1]) then
        return {}
    end

    return volume[1]
end
function Store:updateVolumeIsRead(volume, chapter_page ,isRead, is_update_timestamp)
    local bookCacheId = volume.book_cache_id
    local number = volume.number
    if not H.is_str(bookCacheId) or not H.is_num(number) then
        return
    end
    volume.isRead = isRead
    local update_state = {}
    update_state.isRead = isRead
    if is_update_timestamp == true then
        update_state.lastUpdated = {
            _set = "= strftime('%s', 'now')"
        }
    end
    return self:dynamicUpdateVolume(volume, update_state)
end
function Store:updateVolumeDownloadState(volume, is_downloaded)
    local content = ''
    if is_downloaded == true then
        content = 'downloaded'
    elseif is_downloaded == nil or is_downloaded == false then
        content = self.nil_object()
    else
        content = is_downloaded
    end

    return self:dynamicUpdateVolume(volume, {
        content = content
    })
end
function Store:updateVolumeCacheFilePath(volume, cacheFilePath)

    local cacheFilePath_add = ''
    if type(cacheFilePath) == 'string' then
        cacheFilePath_add = cacheFilePath
    else
        cacheFilePath_add = self.nil_object()
    end

    return self:dynamicUpdateVolume(volume, {
        cacheFilePath = cacheFilePath_add
    })
end
function Store:isVolumeDownloaded(bookCacheId, number)
    local sql_stmt = [[
        SELECT 1 
        FROM volume
        WHERE bookCacheId = '%s'
          AND number = %d AND cacheFilePath IS NOT NULL;
    ]]

    sql_stmt = string.format(sql_stmt, bookCacheId, number)

    local ok, ret = pcall(function()
        self:getDB():rowexec(sql_stmt)
    end)
    local is_downed = ret == 1
    if not ok then
        is_downed = false
    end
    return is_downed
end
function Store:cleanVolumeDownloading()
    local sql_stmt = [[
    UPDATE volume 
SET content = NULL 
WHERE 
  content = 'downloading_' AND
  cacheFilePath IS NULL;
    ]]
    return self:getDB():exec(sql_stmt)
end
function Store:isVolumeDownloading(bookCacheId, bookId, number)
    if not H.is_str(bookCacheId) or not H.is_num(number) then
        dbg.log('Db isVolumeDownloading Error parameters')
        return true
    end

    local sql_stmt = [[
        SELECT  1
        FROM volume
        WHERE bookCacheId = '%s'
          AND bookId = '%s'
          AND number = %d AND content = 'downloading_';
    ]]

    sql_stmt = string.format(sql_stmt, bookCacheId, bookId, number)
    local ok, ret = pcall(function()
        return self:getDB():rowexec(sql_stmt)
    end)
    local is_downing = ret == 1

    if not ok then
        is_downing = true
    end
    return is_downing
end
function Store:dynamicUpdateVolume(volume, updateData)
    if not H.is_tbl(updateData) or not H.is_tbl(volume) then
        dbg.log('dynamicUpdateVolume Required parameter error')
        return
    end

    local bookCacheId = volume.book_cache_id
    local number = volume.number
    -- local bookId = volume.bookId

    if not H.is_str(bookCacheId) or not H.is_num(number) then
        dbg.log('dynamicUpdateVolume Required parameter error')
        error('dynamicUpdateVolume Required parameter error')
        return
    end

    return self:dynamicUpdate('volume', updateData, {
        bookCacheId = bookCacheId,
        number = number
    })

end
function Store:getVolumesDownloadProgress(bookCacheId, target_indexes)

    local sql_template =
        "SELECT COUNT(*) AS total_count FROM volume WHERE content = 'downloaded' AND number IN (%s) AND bookCacheId='%s';"

    local function generate_placeholders(arr)
        local validated = {}
        for _, v in ipairs(arr) do
            table.insert(validated, tostring(v))
        end
        return table.concat(validated, ",")
    end

    local query = string.format(sql_template, generate_placeholders(target_indexes), bookCacheId)

    local ret = self:getDB():rowexec(query)
    ret = tonumber(ret)

    return ret
end

return Store
