--[[
Komga/BookInfoDB.lua — SQLite 数据层(缓存 Komga 服务端数据)

三张表与 Komga 三级层级一一对应(命名对照详见 KomgaModel 头注释):
  Komga 官方      表             主键                       本文件返回的对象
  --------------  -----------   -----------------------   -------------------------
  Series          series        (bookShelfId, bookCacheId)  series
  Book(分卷)      volume        (bookCacheId, number)       volume
  Chapter(书内章) epub_chapter  (chapterId, number)         epub_chapter(仅 EPUB)

本文件是纯 SQL 层: 不做 Komga 业务逻辑, 只把表行映射成 Lua 对象供上层(Backend/KomgaModel)使用。
表名/列名已与 Komga 实体对齐(series/volume/epub_chapter; 卷序号列 = number),
函数名统一为 Series/Volume 语义(如 getVolumeInfo 返回 volume 表一行 = Komga Book 分卷)。
]]

local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local dbg = require("dbg")
local Device = require("device")
local util = require("util")
local VolumePath = require("Komga/VolumePath")
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

local BOOKINFO_DB_VERSION = 20260829

local BOOKINFO_DB_SCHEMA = [[

CREATE TABLE IF NOT EXISTS series (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookShelfId TEXT NOT NULL,
    bookCacheId TEXT NOT NULL,
    name TEXT NOT NULL,
    author TEXT NOT NULL,
    url TEXT NOT NULL,
    origin TEXT NOT NULL,
    originName TEXT NOT NULL,
    originOrder INTEGER DEFAULT 0,

    -- 阅读定位(上次读到哪个分卷)
    durChapterIndex INTEGER DEFAULT 0,
    durChapterPos INTEGER DEFAULT 0,
    durChapterTime INTEGER DEFAULT 0,
    durChapterTitle TEXT DEFAULT '',

    -- 系列信息
    intro TEXT,
    kind TEXT,
    booksCount INTEGER DEFAULT 0,
    btype INTEGER NOT NULL DEFAULT 0,
    wordCount TEXT,
    coverUrl TEXT,

    -- 本地缓存
    cacheExt TEXT DEFAULT NULL,
    sortOrder INTEGER DEFAULT 1,
    isEnabled INTEGER DEFAULT 1,
    lastUpdated INTEGER DEFAULT (strftime('%s', 'now')),
    UNIQUE (bookShelfId, bookCacheId)
);


CREATE TABLE IF NOT EXISTS volume (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookCacheId TEXT NOT NULL,
    bookId TEXT NOT NULL,
    number INTEGER NOT NULL,
    title TEXT DEFAULT '',
    pages INTEGER DEFAULT 0,
    mediaType TEXT NOT NULL,

    -- 本地缓存
    isRead INTEGER DEFAULT 0,
    cacheFilePath TEXT DEFAULT NUll,
    content TEXT DEFAULT NUll,
    lastUpdated INTEGER DEFAULT 0,

    UNIQUE (bookCacheId, number)
);

CREATE TABLE IF NOT EXISTS epub_chapter (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookCacheId TEXT NOT NULL,
    chapterId TEXT NOT NULL,
    number INTEGER NOT NULL,
    title TEXT DEFAULT '',
    url TEXT DEFAULT '',

    isRead INTEGER DEFAULT 0,
    cacheFilePath TEXT DEFAULT NUll,
    content TEXT DEFAULT NUll,
    lastUpdated INTEGER DEFAULT 0,

    UNIQUE (chapterId, number)
);

CREATE INDEX IF NOT EXISTS idx_series_main ON series (bookShelfId, bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_series_bookcacheid ON series (bookCacheId);
CREATE INDEX IF NOT EXISTS idx_series_bookCacheId_isenabled ON series (bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_volume_basic ON volume (bookCacheId, number);
CREATE INDEX IF NOT EXISTS idx_volume_book_cacheid_number ON volume (bookCacheId, number);
CREATE INDEX IF NOT EXISTS idx_series_sortorder_lastread ON series ( sortOrder );
CREATE INDEX IF NOT EXISTS idx_volume_number ON volume (number);
CREATE INDEX IF NOT EXISTS idx_volume_cachefilepath ON volume (cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_volume_content_cache ON volume(content, cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_lastread_volume ON volume (lastUpdated);

CREATE INDEX IF NOT EXISTS idx_epub_chapter_book_cacheid_number ON epub_chapter (bookCacheId, number);
CREATE INDEX IF NOT EXISTS idx_epub_chapter_number ON epub_chapter (number);
CREATE INDEX IF NOT EXISTS idx_epub_chapter_cachefilepath ON epub_chapter (cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_epub_chapter_content_cache ON epub_chapter(content, cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_lastread_epub_chapter ON epub_chapter (lastUpdated);

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

    -- 增量列迁移: 每次连接都尝试(幂等), 保证任何查询前列已存在;
    -- 此前只在 _initDB 做一次且失败被吞, 会出现列缺失后全部查询报 no such column
    local ok_col, err_col = pcall(function()
        self.db:exec("ALTER TABLE series ADD COLUMN lastRead INTEGER DEFAULT 0;")
    end)
    if not ok_col then
        if not tostring(err_col):find("duplicate column", 1, false) then
            dbg.log("ensure lastRead column failed:", tostring(err_col))
        end
    end

    return self.db
end

function M:_initDB(is_repair)
    local db
    local success, rc = pcall(function()
        db = self:_openDB()
        -- 版本比对:旧版库(表结构不同)直接清库重建,重新从服务器同步
        local cur = db:rowexec("PRAGMA user_version;")
        local cur_version = cur
        if type(cur) == "table" then
            cur_version = cur.user_version or 0
        end
        if cur_version ~= BOOKINFO_DB_VERSION then
            -- 旧版库表名是 books/chapters/epubchapters, 清掉避免新旧共存
            db:exec("DROP TABLE IF EXISTS books; DROP TABLE IF EXISTS chapters; DROP TABLE IF EXISTS epubchapters;")
        end
        db:exec(string.format("PRAGMA user_version=%d;", BOOKINFO_DB_VERSION))
        -- 增量列迁移(幂等): 列已存在时 ALTER 报错, pcall 吞掉即可
        pcall(function()
            db:exec("ALTER TABLE series ADD COLUMN lastRead INTEGER DEFAULT 0;")
        end)
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

-- 通用"行→对象"映射(收敛各 Store 的 row[1]/row[2]... 位置式手工取列)。
-- cols 与 SELECT 列序一一对应, 每项 {字段名[, 转换]}:
--   转换 = "number"  -> tonumber(v)
--   转换 = "bool01"  -> v == 1
--   转换 = 函数      -> fn(v, row)  (自定义/派生字段, 派生条目须放在 cols 末尾,
--                                      否则其占用的槽位会让后续字段整体错位)
-- fixed: 可选表, 并入每个对象(如 { book_cache_id = ... }); 列映射的同名字段可覆盖它。
function M:queryObjects(sql, params, cols, fixed)
    local result = self:execute(sql, params)
    local objects = {}
    if H.is_tbl(result) then
        for i = 1, #result do
            local row = result[i]
            local obj = {}
            if fixed then
                for fname, fval in pairs(fixed) do
                    obj[fname] = fval
                end
            end
            for j = 1, #cols do
                local col = cols[j]
                local v = row[j]
                local conv = col[2]
                if conv == "number" then
                    obj[col[1]] = tonumber(v)
                elseif conv == "bool01" then
                    obj[col[1]] = v == 1
                elseif type(conv) == "function" then
                    obj[col[1]] = conv(v, row)
                else
                    obj[col[1]] = v
                end
            end
            objects[i] = obj
        end
    end
    return objects
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



-- 打点系列"最后阅读"时间(打开分卷/流式阅读时调用), 供书架按最后阅读排序

-- 按表拆分: series/volume/epub_chapter 三域方法分别在 Komga/db/*Store,
-- 经元表 __index 混入(M 上查不到的方法落到对应 Store, self 仍为实例)。
local SeriesStore = require("Komga/db/SeriesStore")
local VolumeStore = require("Komga/db/VolumeStore")
local EpubChapterStore = require("Komga/db/EpubChapterStore")
setmetatable(M, {
    __index = function(_, k)
        return VolumeStore[k] or SeriesStore[k] or EpubChapterStore[k]
    end,
})
return M
