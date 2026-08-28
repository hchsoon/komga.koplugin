--[[
Komga/BookInfoDB.lua — SQLite 数据层(缓存 Komga 服务端数据)

三张表与 Komga 三级层级一一对应(命名对照详见 KomgaModel 头注释):
  Komga 官方      表             主键                      本文件返回的对象
  --------------  -----------   -----------------------   -------------------------
  Series          books         (bookShelfId, bookCacheId)  series(旧名 bookinfo)
  Book(分卷)      chapters      (bookCacheId, chapterIndex) volume(旧名 chapter)
  Chapter(书内章) epubchapters  (chapterId, chapterIndex)   epub_chapter(仅 EPUB)

本文件是纯 SQL 层: 不做 Komga 业务逻辑, 只把表行映射成 Lua 对象供上层(Backend/KomgaModel)使用。
表名与列名保持插件历史命名(chapters 表存的是 Komga Book 分卷; chapterIndex 列存分卷序号),
函数名已统一为 Series/Volume 语义(如 getVolumeInfo 返回 chapters 表一行 = Komga Book 分卷)。
]]

local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local dbg = require("dbg")
local Device = require("device")
local util = require("util")
local md5 = require("ffi/sha2").md5
local H = require("Komga/Helper")

if not dbg.log then
    dbg.log = logger.dbg
end

local custom_type_variable = {}
local M = {
    dbPath = nil,
    db_conn = nil,
    isConnected = false,
    dbCreated = false,
    in_transaction = false
}

local function custom_concat(tbl, sep)
    sep = sep or ""
    local result = {}

    for i, v in ipairs(tbl) do
        if v == nil then
            result[i] = "nil"
        elseif type(v) == "table" then

            result[i] = "{" .. custom_concat(v, ",") .. "}"
        else
            result[i] = tostring(v)
        end
    end

    return table.concat(result, sep)
end

local BOOKINFO_DB_VERSION = 20260208

local BOOKINFO_DB_SCHEMA = [[

CREATE TABLE IF NOT EXISTS books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,      
    bookShelfId TEXT NOT NULL,                  
    bookCacheId TEXT NOT NULL,                  
    name TEXT NOT NULL,                         
    author TEXT NOT NULL,                       
    bookUrl TEXT NOT NULL,                      
    origin TEXT NOT NULL,                       
    originName TEXT NOT NULL,                   
    originOrder INTEGER DEFAULT 0,              

    
    durChapterIndex INTEGER DEFAULT 0,          
    durChapterPos INTEGER DEFAULT 0,            
    durChapterTime INTEGER DEFAULT 0,           
    durChapterTitle TEXT DEFAULT '',            

    
    intro TEXT,                                 
    kind TEXT,                                   
    totalChapterNum INTEGER DEFAULT 0,          
    btype INTEGER NOT NULL DEFAULT 0,            
    wordCount TEXT,                              
    coverUrl TEXT,                              

    
    cacheExt TEXT DEFAULT NULL,                              
    sortOrder INTEGER DEFAULT 1,                
    isEnabled INTEGER DEFAULT 1,
    lastUpdated INTEGER DEFAULT (strftime('%s', 'now')),
    UNIQUE (bookShelfId, bookCacheId) 
);


CREATE TABLE IF NOT EXISTS chapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,       
    bookCacheId TEXT NOT NULL,    
    bookId TEXT NOT NULL,                
    chapterIndex INTEGER NOT NULL,    
    title TEXT DEFAULT '',             
    
    isVolume INTEGER DEFAULT 0, 
    pages INTEGER DEFAULT 0,
    mediaType TEXT NOT NULL,
    
    
    isRead INTEGER DEFAULT 0,       
    cacheFilePath TEXT DEFAULT NUll,   
    content TEXT DEFAULT NUll,          
    lastUpdated INTEGER DEFAULT 0, 

    
    UNIQUE (bookCacheId, chapterIndex)
);

CREATE TABLE IF NOT EXISTS epubchapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookCacheId TEXT NOT NULL,
    chapterId TEXT NOT NULL,                
    chapterIndex INTEGER NOT NULL,    
    title TEXT DEFAULT '',          
    chapterUrl TEXT DEFAULT '',   
       
    isRead INTEGER DEFAULT 0,       
    cacheFilePath TEXT DEFAULT NUll,   
    content TEXT DEFAULT NUll,          
    lastUpdated INTEGER DEFAULT 0, 

    UNIQUE (chapterId, chapterIndex)
);

CREATE INDEX IF NOT EXISTS idx_book_main ON books (bookShelfId, bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_books_bookcacheid ON books (bookCacheId);
CREATE INDEX IF NOT EXISTS idx_books_bookCacheId_isenabled ON books (bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_chapter_basic ON chapters (bookCacheId, chapterIndex);
CREATE INDEX IF NOT EXISTS idx_chapters_book_cacheid_chapterindex ON chapters (bookCacheId, chapterIndex);
CREATE INDEX IF NOT EXISTS idx_book_sortorder_Lastread ON books ( sortOrder );
CREATE INDEX IF NOT EXISTS idx_chapters_chapterindex ON chapters (chapterIndex);
CREATE INDEX IF NOT EXISTS idx_chapters_cachefilepath ON chapters (cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_chapters_content_cache ON chapters(content, cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_Lastread_chapters ON chapters (lastUpdated);

CREATE INDEX IF NOT EXISTS idx_epubchapters_book_cacheid_chapterindex ON epubchapters (bookCacheId, chapterIndex);
CREATE INDEX IF NOT EXISTS idx_epubchapters_chapterindex ON epubchapters (chapterIndex);
CREATE INDEX IF NOT EXISTS idx_epubchapters_cachefilepath ON epubchapters (cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_epubchapters_content_cache ON epubchapters(content, cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_Lastread_epubchapters ON epubchapters (lastUpdated);

]]

function M:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o.init then
        o:init()
    end
    return o
end

function M:init()
    self:_initDB()
end

function M:nil_object()
    return setmetatable({
        __type_ext = 'nil',
        [1] = 'nil'

    }, {
        __tostring = function()
            return "nil"
        end
    })
end

function M:blob_object(byte_array, size)
    return setmetatable({
        __type_ext = 'blob',
        __ext_size = size,
        [1] = byte_array
    }, {
        __tostring = function()
            return "blob"
        end
    })
end

function M:_setJournalMode()
    local mode = Device:canUseWAL() and "WAL" or "TRUNCATE"
    local success, err = pcall(function()
        self.db:exec("PRAGMA journal_mode=" .. mode .. ";")
    end)
    if success then
        dbg.v("Database journal mode set to: " .. mode)
    else
        dbg.log("Failed to set journal mode. Error: " .. tostring(err))
    end

end

function M:_openDB()
    if self.isConnected and self.db then

        return self.db
    end
    if not self.dbPath then
        error('Variable not set db path!')
    end
    local success, db = pcall(function()
        return SQ3.open(self.dbPath)
    end)
    if not success or not db then
        dbg.log("Failed to open database at: " .. self.dbPath)
        error("Failed to open database at: " .. self.dbPath)
        return nil
    end

    self.db = db
    self.isConnected = true
    self.in_transaction = false

    self.db:set_busy_timeout(5000)

    dbg.v("Database opened successfully at: " .. self.dbPath)

    self:_setJournalMode()

    return self.db
end

function M:_initDB(is_repair)
    local db
    local success, rc = pcall(function()
        db = self:_openDB()
        db:exec(string.format("PRAGMA user_version=%d;", BOOKINFO_DB_VERSION))
        return db:exec(BOOKINFO_DB_SCHEMA)
    end)
    if success and rc == SQ3.OK then
        dbg.v("Database schema initialized successfully.")
        self.dbCreated = true
        self:closeDB()
    else
        dbg.log("Failed to initialize database schema. Return code: " .. tostring(rc))
        local last_backup_db = self.dbPath .. ".bak"
        local has_backup = util.fileExists(last_backup_db)
        if has_backup then
            H.copyFileFromTo(last_backup_db, self.dbPath)
            util.removeFile(last_backup_db)
            dbg.log("The backup database has been restored")
        else
            if util.fileExists(self.dbPath) then
                util.removeFile(self.dbPath)
                dbg.log("Removed corrupt database file")
            end
        end
        if not is_repair then
            self:closeDB()
            self:_initDB(true)
        end
    end
end

function M:closeDB()
    if not self.isConnected or not self.db then
        return
    end

    local success, err = pcall(function()
        return self.db:close()
    end)
    if not success then
        dbg.log("closing database: " .. H.errorHandler(err))
    end
    self.db = nil
    self.isConnected = nil
end

function M:getDB()

    if not util.fileExists(self.dbPath) then
        self:_initDB()
    end
    if not self.isConnected or not self.db then
        return self:_openDB()
    end
    return self.db
end

function M:transaction(write_func, opts)
    return function(...)
        local conn = self:getDB()
        opts = opts or {}
        local savepoint_name
        local use_savepoint = opts.enable_savepoint and self.in_transaction

        if use_savepoint then
            savepoint_name = string.format("sp_%08x", math.random(0x7fffffff))
            local savepoint_sql = string.format("SAVEPOINT %s", savepoint_name)
            conn:exec(savepoint_sql)
        else

            local txn_type = opts.transaction_type or "IMMEDIATE"
            conn:exec(string.format("BEGIN %s TRANSACTION", txn_type))
            self.in_transaction = true
        end

        local ok, result = xpcall(function(...)
            return write_func(...)
        end, function(err)

            return debug.traceback(tostring(err), 2)
        end, ...)

        if use_savepoint then
            if ok then
                local release_sql = string.format("RELEASE %s", savepoint_name)
                conn:exec(release_sql)
            else
                local rollback_sql = string.format("ROLLBACK TO %s", savepoint_name)
                pcall(conn.exec, conn, rollback_sql)

            end
        else
            if ok then
                pcall(conn.exec, conn, "COMMIT")

            else
                pcall(conn.exec, conn, "ROLLBACK")

            end
            self.in_transaction = false
        end

        if not ok then
            error(result, 0)

        end
        return result
    end
end

local function bool_to_number(bool_value)

    return bool_value and 1 or 0
end

local function validate_data_list(data_list)
    if type(data_list) ~= "table" or #data_list == 0 then
        error("The data list must be a non-empty array")
    end
end

local function adapt_value(v)
    if type(v) == "boolean" then
        return bool_to_number(v)
    elseif type(v) == "table" and v.__type_ext == 'blob' then
        return SQ3.blob(v[1], v.__ext_size)
    elseif type(v) == "table" and v.__type_ext == 'nil' then
        return nil
    end
    return v
end

local function validate_param_type(v, pos)
    local t = type(v)
    if not (t == "nil" or t == "number" or t == "string" or t == 'boolean' or (t == "table" and v.__type_ext)) then
        error(string.format("Illegal parameter type %s (position %d)", t, pos))
    end
end

function M:batch_insert(sql_template, data_list, batch_size)
    batch_size = batch_size or 500
    validate_data_list(data_list)

    local function process_batch(batch_data)
        return self:transaction(function()
            local stmt = self:getDB():prepare(sql_template)

            local param_count = select(2, sql_template:gsub("%?", "%?"))

            for _, params in ipairs(batch_data) do
                if #params ~= param_count then
                    error(string.format(
                        "The number of parameters does not match (requires %d, actual %d, parameter %s)", param_count,
                        #params, custom_concat(params, ", ")))
                end

                for i, v in ipairs(params) do
                    validate_param_type(v, i)

                    stmt:bind1(i, adapt_value(v))

                end

                local step_ok, step_err = pcall(stmt.step, stmt)
                if not step_ok then
                    error(string.format("Step execution failed:%s\n Parameters:%s", step_err,
                        custom_concat(params, ", ")))
                end
                stmt:reset()
            end

            stmt:clearbind():close()
        end, {
            enable_savepoint = false
        })()
    end

    if batch_size <= 0 or #data_list <= batch_size then
        return process_batch(data_list)
    end

    local total = #data_list
    for i = 1, total, batch_size do
        local batch = {}
        for j = i, math.min(i + batch_size - 1, total) do
            table.insert(batch, data_list[j])
        end
        process_batch(batch)
    end
end

local _write_ops = {
    INSERT = true,
    UPDATE = true,
    DELETE = true,
    REPLACE = true,
    ALTER = true,
    DROP = true
}

function M:execute(sql, params, options)

    params = params or {}
    options = options or {}
    if type(params) ~= "table" then
        params = {params}
    end

    local op = sql:match("^%s*(%w+)") or "UNKNOWN"

    op = op:upper()
    local is_write = _write_ops[op]

    local placeholder_count = select(2, sql:gsub("%?", "%?"))
    if placeholder_count ~= #params then
        error(string.format(
            "The number of parameters does not match (SQL has %d placeholders, %d parameters are passed in, parameter %s)",
            placeholder_count, #params, custom_concat(params, ", ")))
    end

    local conn = self:getDB()

    if not conn then
        error("Database not connected")
    end

    local stmt, err = conn:prepare(sql)
    if not stmt then
        error("SQL预处理失败: " .. tostring(err))
    end

    for i, v in ipairs(params) do
        validate_param_type(v, i)

        stmt:bind1(i, adapt_value(v))

    end

    if options.return_stmt then
        return stmt
    end

    local ok, ret = pcall(function()
        if is_write then
            stmt:step()

            return {
                last_insert_rowid = conn:rowexec("SELECT last_insert_rowid() AS id") or 0,
                changes = conn:rowexec("SELECT changes() AS count") or 0
            }
        else

            local result = {}
            local row = {}

            local i = 1
            for row in stmt:rows() do

                if row == nil then
                    break
                end

                result[i] = row
                i = i + 1

            end

            return result
        end
    end)

    stmt:clearbind():reset()

    if not ok then
        error(string.format("SQL Execution failed\nStatement: %s\nError: %s", sql, ret))
    else

        return ret
    end
end

function M:safe_rows(sql, params, fetch_size)
    fetch_size = fetch_size or 100
    local stmt = self:execute(sql, params, {
        return_stmt = true
    })

    return function()
        local batch = {}
        for _ = 1, fetch_size do
            local row = stmt:step()
            if not row then
                break
            end
            table.insert(batch, row)
        end

        if #batch == 0 then
            stmt:clearbind():reset()
            return nil
        end
        stmt:clearbind():reset()
        return batch
    end
end

function M:upsertSeries(bookShelfId, komga_data, server_address,isUpdate)
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
    INSERT INTO books (
    bookShelfId, bookCacheId, name, author, bookUrl, origin, originName, originOrder, 
    durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, wordCount, 
    coverUrl, intro, totalChapterNum, btype, isEnabled, kind
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(bookShelfId, bookCacheId) DO UPDATE SET
    name = CASE WHEN excluded.name != books.name THEN excluded.name ELSE books.name END,
    author = CASE WHEN excluded.author != books.author THEN excluded.author ELSE books.author END,
    bookUrl = CASE WHEN excluded.bookUrl != books.bookUrl THEN excluded.bookUrl ELSE books.bookUrl END,
    origin = CASE WHEN excluded.origin != books.origin THEN excluded.origin ELSE books.origin END,
    originName = CASE WHEN excluded.originName != books.originName THEN excluded.originName ELSE books.originName END,
    originOrder = CASE WHEN excluded.originOrder != books.originOrder THEN excluded.originOrder ELSE books.originOrder END,
    durChapterIndex = CASE WHEN excluded.durChapterIndex != books.durChapterIndex THEN excluded.durChapterIndex ELSE books.durChapterIndex END,
    durChapterPos = CASE WHEN excluded.durChapterPos != books.durChapterPos THEN excluded.durChapterPos ELSE books.durChapterPos END,
    durChapterTime = CASE WHEN excluded.durChapterTime != books.durChapterTime THEN excluded.durChapterTime ELSE books.durChapterTime END,
    durChapterTitle = CASE WHEN excluded.durChapterTitle != books.durChapterTitle THEN excluded.durChapterTitle ELSE books.durChapterTitle END,
    wordCount = CASE WHEN excluded.wordCount != books.wordCount THEN excluded.wordCount ELSE books.wordCount END,
    coverUrl = CASE WHEN excluded.coverUrl != books.coverUrl THEN excluded.coverUrl ELSE books.coverUrl END,
    intro = CASE WHEN excluded.intro != books.intro THEN excluded.intro ELSE books.intro END,
    totalChapterNum = CASE WHEN excluded.totalChapterNum != books.totalChapterNum THEN excluded.totalChapterNum ELSE books.totalChapterNum END,
    btype = CASE WHEN excluded.btype != books.btype THEN excluded.btype ELSE books.btype END,
    isEnabled = CASE WHEN excluded.isEnabled != books.isEnabled THEN excluded.isEnabled ELSE books.isEnabled END,
    kind = CASE WHEN excluded.kind != books.kind THEN excluded.kind ELSE books.kind END, 
    lastUpdated = CASE WHEN (
    excluded.bookUrl != books.bookUrl OR
    excluded.wordCount != books.wordCount
) THEN strftime('%s', 'now') ELSE books.lastUpdated END
    ]]

    local batch_data = {}
    for index, series in ipairs(seriesData) do
        local coverUrl = server_address .. "/api/v1/series/" .. series.id .. "/thumbnail"
        batch_data[index] = {bookShelfId, series.id, series.metadata.title, series.author, series.url, series.id or "",
            series.metadata.title or "", series.originOrder or 0, series.durChapterIndex or 0,
            series.durChapterPos or 0, series.durChapterTime or 0, series.durChapterTitle or "",
            series.wordCount or "", coverUrl, series.metadata.summary or "", series.booksCount or 0,
            series.type or 0, 1, series.kind or ''}
    end

    if batch_data and #batch_data > 0 then
        if isUpdate ~= true then
            self:getDB():exec("UPDATE books SET isEnabled = 0;")
        end
        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true

end

function M:getAllSeries(bookShelfId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, bookUrl, origin, originName, 
    originOrder, durChapterIndex, durChapterPos FROM books WHERE isEnabled = 1 AND bookShelfId = ?;
    ]]
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
                bookUrl = row[4],
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

function M:getAllSeriesByUI(bookShelfId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, originName FROM books WHERE isEnabled = 1 AND bookShelfId = ? ORDER BY sortOrder = 0 DESC, sortOrder DESC;
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
                originName = row[4]
            }
        end
    end

    return series
end

function M:getSeriesInfo(bookShelfId, bookCacheId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, bookUrl, origin, originName, 
    originOrder, durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, 
    wordCount, intro, totalChapterNum, kind, sortOrder, cacheExt, coverUrl FROM books WHERE isEnabled = 1 AND bookShelfId = ? AND bookCacheId =? ;
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
                bookUrl = row[4],
                origin = row[5],
                originName = row[6],
                originOrder = tonumber(row[7]),
                durChapterIndex = tonumber(row[8]),
                durChapterPos = tonumber(row[9]),
                durChapterTime = tonumber(row[10]),
                durChapterTitle = row[11],
                wordCount = row[12],
                intro = row[13],
                totalChapterNum = tonumber(row[14]),
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

function M:upsertVolumes(bookCacheId, volumes)
    if not H.is_str(bookCacheId) or not H.is_tbl(volumes) then
        dbg.log('BookInfoDB:upsertVolumes Incorrect input parameters')
        return false
    end

    local sql_stmt = [[
        INSERT INTO chapters (bookCacheId, bookId ,chapterIndex, title, isVolume, pages, mediaType)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(bookCacheId, chapterIndex) DO UPDATE SET
    title = CASE WHEN excluded.title != chapters.title THEN excluded.title ELSE chapters.title END,
    isVolume = CASE WHEN excluded.isVolume != chapters.isVolume THEN excluded.isVolume ELSE chapters.isVolume END;
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
            table.insert(batch_data, {bookCacheId, volume.id, volume.number, vol_title, true,
                volume.media.pagesCount, volume.media.mediaProfile})
        end
    end

    if #batch_data > 0 then
        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true
end

function M:upsertEpubChapters(bookCacheId, chapters)
    if not H.is_str(bookCacheId) or not H.is_tbl(chapters) then
        dbg.log('BookInfoDB:upsertEpubChapters Incorrect input parameters')
        return false
    end

    local sql_stmt = [[
        INSERT INTO epubchapters (bookCacheId, chapterId ,chapterIndex, title, chapterUrl)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(chapterId, chapterIndex) DO UPDATE SET
    title = CASE WHEN excluded.title != epubchapters.title THEN excluded.title ELSE epubchapters.title END,
    chapterUrl = CASE WHEN excluded.chapterUrl IS NOT NULL AND excluded.chapterUrl != '' THEN excluded.chapterUrl ELSE epubchapters.chapterUrl END;
    ]]

    -- TODO: 章节与xhtml不是一一对应的，有些不在内的xhtml未被入库

    local batch_data = {}
    for index, chapter in ipairs(chapters.readingOrder) do
        -- if chapter.title ~= nil then
        -- if not H.is_str(chapter.title) or chapter.title == '' then
        --     chapter.title = string.format('No title', chapter.index)
        -- end
        -- print(bookCacheId, chapters.bookId ,index, chapter.title, chapter.href)

        table.insert(batch_data, {bookCacheId, chapters.bookId ,index, 'No title', chapter.href})
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

    for _, chapter in ipairs(flatten_toc(chapters.toc)) do
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

function M:getAllVolumes(bookCacheId)
    if bookCacheId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT 
    c.chapterIndex, 
    c.title, 
    c.isRead,
    c.cacheFilePath,
    b.name,
    b.author,
    b.bookUrl,
    b.durChapterIndex,
    b.durChapterTime,
    b.totalChapterNum 
FROM chapters AS c
INNER JOIN books AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? 
ORDER BY c.chapterIndex ASC;
    ]]

    local result = self:execute(sql_stmt, bookCacheId)
    local volumes = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            volumes[i] = {
                book_cache_id = bookCacheId,
                chapters_index = tonumber(row[1]),
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                bookUrl = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = tonumber(row[9]),
                totalChapterNum = tonumber(row[10])

            }
        end
    end

    return volumes
end

function M:getAllVolumesByUI(bookCacheId, is_desc_sort)
    if bookCacheId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT
    c.chapterIndex, 
    c.title, 
    c.isRead, 
    c.cacheFilePath,
    b.durChapterIndex,
    c.bookId
FROM chapters AS c
INNER JOIN books AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? 
ORDER BY c.chapterIndex ]]

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
            local chapterIndex = tonumber(row[1])
            volumes[i] = {
                chapters_index = chapterIndex,
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

function M:getVolumeCount(bookCacheId)
    local sql_stmt = "SELECT count(*) as total_num FROM chapters WHERE  bookCacheId = '%s';"
    sql_stmt = string.format(sql_stmt, bookCacheId)
    local totalChapterNum = self:getDB():rowexec(sql_stmt)
    return tonumber(totalChapterNum)
end

function M:getLastReadVolumeIndex(bookCacheId)
    if not H.is_str(bookCacheId) then
        return 0
    end
    local sql_stmt = [[
            SELECT  COALESCE(chapterIndex, 0) AS chapterIndex 
FROM chapters
WHERE lastUpdated IS NOT NULL AND bookCacheId = '%s'
ORDER BY lastUpdated DESC
LIMIT 1;
    ]]
    sql_stmt = string.format(sql_stmt, bookCacheId)
    local lastUpdated = self:getDB():rowexec(sql_stmt)
    return tonumber(lastUpdated) or 0
end

function M:getSeriesLastUpdateTime(bookCacheId)
    local sql_stmt = string.format(
        "SELECT lastUpdated FROM books WHERE isEnabled = 1 AND bookCacheId = '%s';", bookCacheId)

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

function M:getVolumeInfo(bookCacheId, chapterIndex)
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        dbg.log('getVolumeInfo Incorrect input parameters')
        return {}
    end

    local sql_stmt = [[
    SELECT 
    c.chapterIndex, 
    c.title, 
    c.isRead, 
    c.cacheFilePath,
    b.name,
    b.author,
    b.bookUrl,
    b.durChapterIndex,
    b.durChapterTime,
    b.totalChapterNum,
    b.cacheExt,
    c.bookId,
    c.pages,
    c.mediaType
FROM chapters AS c
INNER JOIN books AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? AND c.chapterIndex = ?;
    ]]

    local result = self:execute(sql_stmt, {bookCacheId, chapterIndex})
    local volume = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local chapterIndex = tonumber(row[1])
            volume[i] = {
                book_cache_id = bookCacheId,
                chapters_index = chapterIndex,
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                bookUrl = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = tonumber(row[9]),
                totalChapterNum = tonumber(row[10]),
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

function M:getEpubChapterCount(chapterId)
    local sql_stmt = "SELECT count(*) as total_num FROM epubchapters WHERE chapterId = '%s';"
    sql_stmt = string.format(sql_stmt, chapterId)
    -- print("Sql_fmt is...", sql_stmt)
    local totalChapterNum = self:getDB():rowexec(sql_stmt)
    return tonumber(totalChapterNum)
end

function M:getAllEpubChapters(chapterId)
    if chapterId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT 
    c.chapterIndex, 
    c.title, 
    c.chapterUrl,
    c.isRead,
    c.cacheFilePath,
    v.title as VolumeTitle
FROM epubchapters AS c
INNER JOIN chapters AS v
    ON c.chapterId = v.bookId 
WHERE 
    c.chapterId = ? AND c.title <> 'No title'
ORDER BY c.chapterIndex ASC;
    ]]

    local result = self:execute(sql_stmt, chapterId)
    local chapters = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            chapters[i] = {
                chapterId = chapterId,
                chapters_index = tonumber(row[1]),
                title = row[2],
                chapterUrl = row[3],
                isRead = row[4] == 1,
                cacheFilePath = row[5],
                volumename = row[6]
            }
        end
    end

    return chapters
end


-- 返回某个 epub 的全部内部章节 URL(含 'No title' 子章节), 供缓存 xhtml 内部链接映射用
function M:getAllEpubChapterUrls(chapterId)
    if chapterId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT c.chapterIndex, c.chapterUrl
FROM epubchapters AS c
WHERE c.chapterId = ?
ORDER BY c.chapterIndex ASC;
    ]]

    local result = self:execute(sql_stmt, chapterId)
    local items = {}
    if result and #result > 0 then
        for i = 1, #result, 1 do
            local row = result[i]
            items[i] = {
                chapters_index = tonumber(row[1]),
                chapterUrl = row[2]
            }
        end
    end

    return items
end

function M:getEpubChapterInfo(chapterId, epubChapterIndex)
    if not H.is_str(chapterId) or not H.is_num(epubChapterIndex) then
        dbg.log('getEpubChapterInfo Incorrect input parameters')
        return {}
    end

    local sql_stmt = [[
    SELECT 
    c.chapterIndex, 
    c.title, 
    c.chapterUrl,
    c.isRead,
    c.cacheFilePath,
    v.title as VolumeTitle
FROM epubchapters AS c
INNER JOIN chapters AS v
    ON c.chapterId = v.bookId 
WHERE 
    c.chapterId = ? AND c.chapterIndex = ?;
    ]]

    local result = self:execute(sql_stmt, {chapterId, epubChapterIndex})
    local chapter = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local chapterIndex = tonumber(row[1])
            chapter[i] = {
                chapterId = chapterId,
                chapters_index = tonumber(row[1]),
                title = row[2],
                chapterUrl = row[3],
                isRead = row[4] == 1,
                cacheFilePath = row[5],
                volumename = row[6]
            }
        end
    end

    if not H.is_tbl(chapter[1]) then
        return {}
    end

    return chapter[1]
end

function M:getReadAheadVolumeCount(current_volume)

    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.chapters_index == nil then
        dbg.log('getReadAheadVolumeCount:', current_volume)
        return 0
    end

    local bookCacheId = current_volume.book_cache_id
    local current_volume_index = current_volume.chapters_index
    local call_event_type = current_volume.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = ''
    if call_event_type == 'next' then
        sql_stmt = [[
SELECT COUNT(*) AS continuous_count
FROM chapters AS c
WHERE 
  c.chapterIndex > %d        
  AND c.cacheFilePath IS NOT NULL 
  AND c.bookCacheId = '%s'   
  AND c.chapterIndex < COALESCE(
      (SELECT MIN(chapterIndex) 
       FROM chapters 
       WHERE chapterIndex > %d  
         AND cacheFilePath IS NULL 
         AND bookCacheId = '%s'   
      ),
      (SELECT MAX(chapterIndex) + 1 
       FROM chapters 
       WHERE bookCacheId = '%s'  
      )
  )
  AND EXISTS (
      SELECT 1 FROM books AS b 
      WHERE b.bookCacheId = c.bookCacheId 
        AND b.isEnabled = 1
  );
  ]]

        sql_stmt = string.format(sql_stmt, current_volume_index, bookCacheId, current_volume_index, bookCacheId,
            bookCacheId)
    else

        sql_stmt = [[
                    SELECT COUNT(*) AS continuous_count
FROM chapters AS c
WHERE 
  c.chapterIndex < %d       
  AND c.cacheFilePath IS NOT NULL 
  AND c.bookCacheId = '%s'   
  AND c.chapterIndex > COALESCE(
      (SELECT MAX(chapterIndex) 
       FROM chapters 
       WHERE chapterIndex < %d 
         AND cacheFilePath IS NULL 
         AND bookCacheId = '%s'
      ),
      (SELECT MIN(chapterIndex) - 1 
       FROM chapters 
       WHERE bookCacheId = '%s'
      )
  )
  AND EXISTS (
      SELECT 1 FROM books AS b 
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

function M:findVolumesNotDownloaded(current_volume, count)
    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.chapters_index == nil then
        dbg.log('findVolumesNotDownloaded:', current_volume)
        return {}
    end

    if not H.is_num(count) or count < 1 then
        count = 1
    end

    local bookCacheId = current_volume.book_cache_id
    local current_volume_index = current_volume.chapters_index
    local call_event_type = current_volume.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = [[
        SELECT 
        c.chapterIndex, 
        c.title, 
        b.bookUrl,
        b.name,
        c.bookId
    FROM chapters AS c
    INNER JOIN books AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
         c.bookCacheId = ? AND b.isEnabled = 1 AND c.isRead = 0 AND c.cacheFilePath IS NULL
         ]]

    local suffix = "  AND c.chapterIndex > ?  ORDER BY c.chapterIndex ASC LIMIT "

    if call_event_type ~= 'next' then
        suffix = "  AND c.chapterIndex < ? ORDER BY c.chapterIndex DESC LIMIT "
    end

    sql_stmt = table.concat({sql_stmt, suffix, count, ';'})

    local result = self:execute(sql_stmt, {bookCacheId, current_volume_index})

    local volumes = {}
    if result and #result > 0 then
        for i = 1, #result, 1 do
            local row = result[i]
            local chapterIndex = tonumber(row[1])
            volumes[i] = {
                book_cache_id = bookCacheId,
                title = row[2],
                bookUrl = row[3],
                chapters_index = chapterIndex,
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

function M:findNextVolumeInfo(current_volume, is_downloaded)
    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.chapters_index == nil then
        dbg.log('findNextVolumeInfo:', current_volume)
        return {}
    end

    local bookCacheId = current_volume.book_cache_id
    local current_volume_index = current_volume.chapters_index
    local call_event_type = current_volume.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = [[
        SELECT 
        c.chapterIndex, 
        c.title, 
        c.isRead, 
        c.cacheFilePath,
        b.name,
        b.author,
        b.bookUrl,
        b.durChapterIndex,
        b.durChapterTime,
        b.totalChapterNum,
        b.cacheExt
    FROM chapters AS c
    INNER JOIN books AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
         c.bookCacheId = ? AND b.isEnabled = 1 ]]

    if is_downloaded == false then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NULL '
    elseif is_downloaded == true then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NOT NULL '
    end

    local suffix = "  AND c.chapterIndex > ?  ORDER BY c.chapterIndex ASC LIMIT 1;"
    if call_event_type ~= 'next' then

        suffix = "  AND c.chapterIndex < ? ORDER BY c.chapterIndex DESC LIMIT 1;"
    end

    sql_stmt = sql_stmt .. suffix

    local result = self:execute(sql_stmt, {bookCacheId, current_volume_index})

    local volume = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local chapterIndex = tonumber(row[1])
            volume[i] = {
                book_cache_id = bookCacheId,
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                bookUrl = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = tonumber(row[9]), -- type cdata?
                totalChapterNum = tonumber(row[10]),
                chapters_index = chapterIndex,
                cacheExt = row[11]
            }
        end
    end

    if not H.is_tbl(volume[1]) then
        return {}
    end

    return volume[1]
end

function M:findNextEpubChapterInfo(current_chapter, is_downloaded)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log('findNextEpubChapterInfo:', current_chapter)
        return {}
    end
    -- print("Next Epub Chapter Info book is ...", current_chapter.bookId)
    local bookCacheId = current_chapter.book_cache_id
    local bookId = current_chapter.bookId
    local current_chapters_index = current_chapter.chapters_index
    local call_event_type = current_chapter.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = [[
        SELECT 
        c.chapterIndex, 
        c.title, 
        c.isRead, 
        c.cacheFilePath,
        b.name,
        b.author,
        b.bookUrl,
        b.durChapterIndex,
        b.durChapterTime,
        b.totalChapterNum,
        b.cacheExt
    FROM epubchapters AS c
    INNER JOIN books AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
        c.bookCacheId = ? AND c.chapterId = ? AND b.isEnabled = 1 ]]

    if is_downloaded == false then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NULL '
    elseif is_downloaded == true then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NOT NULL '
    end

    local suffix = "  AND c.chapterIndex > ?  ORDER BY c.chapterIndex ASC LIMIT 1;"
    if call_event_type ~= 'next' then

        suffix = "  AND c.chapterIndex < ? ORDER BY c.chapterIndex DESC LIMIT 1;"
    end

    sql_stmt = sql_stmt .. suffix

    local result = self:execute(sql_stmt, {bookCacheId, bookId ,current_chapters_index})

    local chapter = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local chapterIndex = tonumber(row[1])
            chapter[i] = {
                book_cache_id = bookCacheId,
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                bookUrl = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = tonumber(row[9]), -- type cdata?
                totalChapterNum = tonumber(row[10]),
                chapters_index = chapterIndex,
                cacheExt = row[11]
            }
        end
    end

    if not H.is_tbl(chapter[1]) then
        return {}
    end

    return chapter[1]
end


function M:updateVolumeIsRead(volume, chapter_page ,isRead, is_update_timestamp)
    local bookCacheId = volume.book_cache_id
    local chapterIndex = volume.chapters_index
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
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

function M:updateVolumeDownloadState(volume, is_downloaded)
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

function M:updateVolumeCacheFilePath(volume, cacheFilePath)

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

function M:isVolumeDownloaded(bookCacheId, chapterIndex)
    local sql_stmt = [[
        SELECT 1 
        FROM chapters
        WHERE bookCacheId = '%s'
          AND chapterIndex = %d AND cacheFilePath IS NOT NULL;
    ]]

    sql_stmt = string.format(sql_stmt, bookCacheId, chapterIndex)

    local ok, ret = pcall(function()
        self:getDB():rowexec(sql_stmt)
    end)
    local is_downed = ret == 1
    if not ok then
        is_downed = false
    end
    return is_downed
end

function M:cleanVolumeDownloading()
    local sql_stmt = [[
    UPDATE chapters 
SET content = NULL 
WHERE 
  content = 'downloading_' AND
  cacheFilePath IS NULL;
    ]]
    return self:getDB():exec(sql_stmt)
end

function M:isVolumeDownloading(bookCacheId, bookId, chapterIndex)
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        dbg.log('Db isVolumeDownloading Error parameters')
        return true
    end

    local sql_stmt = [[
        SELECT  1
        FROM chapters
        WHERE bookCacheId = '%s'
          AND bookId = '%s'
          AND chapterIndex = %d AND content = 'downloading_';
    ]]

    sql_stmt = string.format(sql_stmt, bookCacheId, bookId, chapterIndex)
    local ok, ret = pcall(function()
        return self:getDB():rowexec(sql_stmt)
    end)
    local is_downing = ret == 1

    if not ok then
        is_downing = true
    end
    return is_downing
end

function M:clearAllSeries(bookShelfId)
    if not H.is_str(bookShelfId) then
        dbg.log('DB clearAllSeries error')
        return false
    end

    self:dynamicUpdate('books', {
        isEnabled = 0
    }, {
        bookShelfId = bookShelfId
    })
    return true
end

function M:clearSeries(bookShelfId, book_cache_id)

    if not H.is_str(bookShelfId) or not H.is_str(book_cache_id) then
        dbg.log('DB clearSeries error')
        return false
    end

    self:dynamicUpdate('books', {
        isEnabled = 0
    }, {
        bookShelfId = bookShelfId,
        bookCacheId = book_cache_id
    })

    self:dynamicUpdate('chapters', {
        cacheFilePath = self.nil_object(),
        content = self.nil_object(),
        isRead = 0
    }, {
        bookCacheId = book_cache_id
    })

    -- 同时清空 epubchapters 内部章节缓存。否则清除缓存后内部目录仍是旧的
    -- (如子章节因只遍历顶层 toc 而保持 'No title' 被过滤), 无法触发 manifest 重新拉取。
    self:execute("DELETE FROM epubchapters WHERE bookCacheId = ? OR chapterId = ?;",
        {book_cache_id, book_cache_id})

    return true
end

function M:dynamicUpdateVolume(volume, updateData)
    if not H.is_tbl(updateData) or not H.is_tbl(volume) then
        dbg.log('dynamicUpdateVolume Required parameter error')
        return
    end

    local bookCacheId = volume.book_cache_id
    local chapterIndex = volume.chapters_index
    -- local bookId = volume.bookId

    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        dbg.log('dynamicUpdateVolume Required parameter error')
        error('dynamicUpdateVolume Required parameter error')
        return
    end

    return self:dynamicUpdate('chapters', updateData, {
        bookCacheId = bookCacheId,
        chapterIndex = chapterIndex
    })

end

function M:dynamicUpdateSeries(series, updateData)
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

    return self:dynamicUpdate('books', updateData, {
        bookCacheId = bookCacheId,
        bookShelfId = bookShelfId
    })
end

function M:dynamicUpdate(tableName, updateData, conditions)
    if not H.is_tbl(updateData) or not H.is_str(tableName) then
        error('Error entering necessary parameters')
        return
    end

    local set_clause = {}
    local params = {}
    local param_count = 0

    for key, value in pairs(updateData) do
        if value == '_NULL' then
            table.insert(set_clause, string.format("%s = ?", key))
            table.insert(params, self.nil_object())
        elseif H.is_tbl(value) and H.is_str(value._set) then
            table.insert(set_clause, table.concat({key, ' ', value._set}))
        else
            table.insert(set_clause, string.format("%s = ?", key))
            table.insert(params, value)
        end
        param_count = param_count + 1
    end

    if param_count < 1 then
        return
    end

    local where_clause = ""
    if H.is_tbl(conditions) then
        local where_parts = {}
        for field, value in pairs(conditions) do
            if value == '_NULL' then
                table.insert(where_parts, string.format("%s IS NULL", field))
            elseif H.is_tbl(value) and H.is_str(value._where) then
                table.insert(where_parts, table.concat({field, ' ', value._where}))
            else
                table.insert(where_parts, string.format("%s = ?", field))
                table.insert(params, value)
            end
        end

        if #where_parts > 0 then
            where_clause = " WHERE " .. table.concat(where_parts, " AND ")
        else
            return
        end

    end

    local sql_stmt = table.concat({"UPDATE ", tableName, " SET ", table.concat(set_clause, ", "), where_clause})

    -- logger.info(sql_stmt)
    return self:execute(sql_stmt, params)
end

function M:getVolumesDownloadProgress(bookCacheId, target_indexes)

    local sql_template =
        "SELECT COUNT(*) AS total_count FROM chapters WHERE content = 'downloaded' AND chapterIndex IN (%s) AND bookCacheId='%s';"

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

function M:setSeriesTopStatus(bookShelfId, book_cache_id, isPinnedManually, isPinnedByTime)
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
        SELECT bookCacheId FROM books 
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

    return self:dynamicUpdate('books', {
        sortOrder = set_sortorder
    }, {
        bookCacheId = book_cache_id,
        bookShelfId = bookShelfId,
        sortOrder = where_sortorder
    })
end

return M
