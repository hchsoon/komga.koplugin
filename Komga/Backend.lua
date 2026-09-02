--[[
Komga/Backend.lua — Komga HTTP 层与业务编排

封装 Komga 服务器的 HTTP 请求(经 Komga/ApiClient 单一 REST 客户端, socket.http, 编解码 Komga/Json: rapidjson 优先)
与本地缓存编排, 是插件对外的主要服务入口。

━━━ 名词对照(重要: 插件内部命名与 Komga 官方名词不同)━━━
  Komga 官方         本层/DB 命名       主键                        说明
  ---------------    -----------------  --------------------------  ---------------------------
  Series              series             bookCacheId                书架上的一个"系列"
  Book(单卷)          volume             (bookCacheId, number)  系列内的一个"分卷", 服务器 ID = bookId
  Chapter(书内章)     epub_chapter       (chapterId, number)   EPUB 书内部章节, 仅 EPUB

━━━ 命名约定 ━━━
  * 本文件(与 BookInfoDB / KomgaModel)统一用 series / volume / epub_chapter 描述三级层级。
  * self.api:get/post/put/patch(path, query, payload, opts) 直连 Komga/reader3 HTTP 端点。
  * EPUB 专用函数保留 "Epub/Chapter" 字样(它们处理的确实是 Komga Chapter)。
]]

local logger = require("logger")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local ffiUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5
local dbg = require("dbg")
local LuaSettings = require("luasettings")
local socket_url = require("socket.url")
local util = require("util")
local time = require("ui/time")

local UIManager = require("ui/uimanager")
local H = require("Komga/Helper")
local Config = require("Komga/Config")
local VolumePath = require("Komga/VolumePath")
local ApiClient = require("Komga/ApiClient")
local Async = require("Komga/Async")
local TaskQueue = require("Komga/TaskQueue")
local ContentProcessor = require("Komga/ContentProcessor")
local get_img_src = ContentProcessor.get_img_src
local get_url_extension = ContentProcessor.get_url_extension
local custom_urlEncode = ContentProcessor.custom_urlEncode
local splitParagraphsPreserveBlank = ContentProcessor.splitParagraphsPreserveBlank
local has_img_tag = ContentProcessor.has_img_tag
local has_other_content = ContentProcessor.has_other_content
local get_chapter_content_type = ContentProcessor.get_chapter_content_type
local normalize_rel_href = ContentProcessor.normalize_rel_href
local get_cached_chapter_filename = ContentProcessor.get_cached_chapter_filename
local plain_text_replace = ContentProcessor.plain_text_replace

-- 太旧版本缺少这个函数
if not dbg.log then
    dbg.log = logger.dbg
end

local M = {
    dbManager = {},
    settings_data = nil,
    task_pid_file = nil,
    api = nil,
    httpReq = nil
}

local function wrap_response(data, err_message)
    return data ~= nil and {
        type = 'SUCCESS',
        body = data
    } or {
        type = 'ERROR',
        message = err_message or "Unknown error"
    }
end



-- socket.url.escape util.urlEncode + / ? = @会被编码
-- 处理 reader3 服务器版含书名路径有空格等问题

local function convertToGrayscale(image_data)
    local Png = require("Komga/Png")
    return Png.processImage(Png.toGrayscale, image_data, 1)

end

local function pGetUrlContent(options)
    if not M.httpReq then
        M.httpReq = require("Komga.HttpRequest")
    end
    return M.httpReq.pGetUrlContent(options, true)
end

local function pDownload_CreateCBZ(filePath, img_sources)

    dbg.v('CreateCBZ strat:')

    if not filePath or not H.is_tbl(img_sources) then
        error("Cbz param error:")
    end

    local is_convertToGrayscale = false

    local cbz_path_tmp = filePath .. '.downloading'

    if util.fileExists(cbz_path_tmp) then
        if M:isExtractingInBackground() == true then
            error("Other threads downloading, cancelled")
        else
            util.removeFile(cbz_path_tmp)
        end
    end

    local ZipWriter = require("ffi/zipwriter")

    local cbz = ZipWriter:new{}
    if not cbz:open(cbz_path_tmp) then
        error('CreateCBZ cbz:open err')
    end
    cbz:add("mimetype", "application/vnd.comicbook+zip", true)

    local no_compression = true

    for i, img_src in ipairs(img_sources) do

        dbg.v('Download_Image start', i, img_src)
        local status, err = pGetUrlContent({
                url = img_src,
                timeout = 15,
                maxtime = 60
        })

        if status and H.is_tbl(err) and err['data'] then

            local imgdata = err['data']
            local img_extension = err['ext']
            if not img_extension or img_extension == "" then
                img_extension = get_url_extension(img_src)
            end

            local img_name = string.format("%d.%s", i, img_extension or "")
            if is_convertToGrayscale == true and img_extension == 'png' then
                local success, imgdata_new = convertToGrayscale(imgdata)
                if success ~= true then

                    goto continue
                end
                imgdata = imgdata_new.data
            end

            cbz:add(img_name, imgdata, no_compression)

        else
            dbg.v('Download_Image err', tostring(err))
        end
        ::continue::
    end

    cbz:close()
    dbg.v('CreateCBZ cbz:close')

    if util.fileExists(filePath) ~= true then
        os.rename(cbz_path_tmp, filePath)
    else
        if util.fileExists(cbz_path_tmp) == true then
            util.removeFile(cbz_path_tmp)
        end
        error('exist target file, cancelled')
    end

    return filePath
end

function M:HandleResponse(response, on_success, on_error)
    if not response then
        return on_error and on_error("Response is nil")
    end

    local rtype = response.type
    if rtype == "SUCCESS" then
        return on_success and on_success(response.body)
    elseif rtype == "ERROR" then
        return on_error and on_error(response.message or "")
    end
    return on_error and on_error("Unknown response type: " .. tostring(rtype))
end

-- 构建 REST 客户端(单一 HTTP 栈, 取代 Spore+KomgaSpec 双栈):
-- 服务器地址/API Key 由设置驱动, 请求经 Komga/ApiClient 走 socket.http
function M:loadApiClient()
    self.api = ApiClient:new(function()
        return self.settings_data.data.server_address or Config.DEFAULT_SERVER_ADDRESS
    end, function()
        return self:getApiKey()
    end)
end

-- 一次性设置迁移(幂等: 以字段缺失为触发条件, 已迁移自然跳过)。
-- 新增迁移只需往表里加 {name, check, run}, 不要在 initialize 里散落 if 分支。
local ONE_TIME_MIGRATIONS = {
    {
        name = "<1.038 setting_url 继承 komga_server",
        check = function(d)
            return d.setting_url == nil and d.reader3_un == nil and H.is_str(d.komga_server)
        end,
        run = function(d)
            d.setting_url = d.komga_server
        end
    },
    {
        name = "<1.049 server_address 继承 komga_server",
        check = function(d)
            return d.server_address == nil and H.is_str(d.komga_server)
        end,
        run = function(d)
            d.server_address = d.komga_server
            d.komga_server = nil
        end
    },
    {
        name = "api_key 缺省补默认值",
        check = function(d)
            return not H.is_str(d.api_key)
        end,
        run = function(d)
            d.api_key = Config.DEFAULT_API_KEY
        end
    }
}

function M:runOneTimeMigrations()
    local dirty = false
    for _, migration in ipairs(ONE_TIME_MIGRATIONS) do
        if migration.check(self.settings_data.data) then
            migration.run(self.settings_data.data)
            dirty = true
            dbg.v('settings migration applied:', migration.name)
        end
    end
    if dirty then
        self.settings_data:flush()
    end
end

function M:initialize()
    self.task_pid_file = H.getTempDirectory() .. '/task.pid.lua'
    self.settings_data = self:getLuaConfig(H.getUserSettingsPath())
    -- 上个进程异常退出可能遗留 pid 文件(通道状态在内存, 重启即复位), 清理防误判
    pcall(function()
        util.removeFile(self.task_pid_file)
    end)

    -- 旧版本设置迁移(集中管理, 见 ONE_TIME_MIGRATIONS)
    self:runOneTimeMigrations()

    if self.settings_data and not self.settings_data.data['server_address'] then
        self.settings_data.data = {
            chapter_sorting_mode = "chapter_ascending",
            server_address = Config.DEFAULT_SERVER_ADDRESS,
            server_address_md5 = 'f528764d624db129b32c21fbca0cb8d6',
            setting_url = Config.DEFAULT_SERVER_ADDRESS,
            servers_history = {},
            api_key = Config.DEFAULT_API_KEY,
            stream_image_view = nil,
            disable_browser = nil
        }
        self.settings_data:flush()
    end

    self:loadApiClient()

    local BookInfoDB = require("Komga/BookInfoDB")
    self.dbManager = BookInfoDB:new({
        dbPath = H.getTempDirectory() .. "/bookinfo.db"
    })

end

function M:installPatches()
    local patches_file_path = H.joinPath(H.getUserPatchesDirectory(), '2-komga_plugin_func.lua')
    local source_patches = H.joinPath(H.getPluginDirectory(), 'patches/2-komga_plugin_func.lua')
    local disabled_patches = patches_file_path .. '.disabled'
    for _, file in ipairs({patches_file_path, disabled_patches}) do
        if util.fileExists(file) then
            util.removeFile(file)
        end
    end
    H.copyFileFromTo(source_patches, patches_file_path)
    UIManager:restartKOReader()
end

function M:show_notice(msg, timeout)
    local Notification = require("ui/widget/notification")
    Notification:notify(msg or '', Notification.SOURCE_ALWAYS_SHOW)
end
function M:launchProcess(job)
    if H.is_func(job) then
        return ffiUtil.runInSubProcess(job, nil ,true)
    end
end
function M:getLuaConfig(path)
    return LuaSettings:open(path)
end
function M:backgroundCacheConfig()
    return self:getLuaConfig(H.getTempDirectory() .. '/cache.lua')
end

function print_table(t, indent)
    indent = indent or 0
    local spaces = string.rep("  ", indent)
    
    for k, v in pairs(t) do
        if type(v) == "table" then
            print(spaces .. tostring(k) .. ":")
            print_table(v, indent + 1)
        else
            print(spaces .. tostring(k) .. ": " .. tostring(v))
        end
    end
end

-- 统一请求包装(原 komgaSporeApi): 错误映射 / 204 摘取 / content 摘取语义保持不变,
-- 传输层由 Spore 换成 self.api(Komga/ApiClient, 直接 socket.http)。
-- requestFunc 返回 {status, body, headers}(ApiClient 约定)或 nil, err_msg。
function M:komgaApi(requestFunc, callback, logName)
    logName = logName or 'komgaApi'

    local status, res, rerr = pcall(requestFunc)

    if not status then
        local err_msg = H.errorHandler(res)
        if err_msg == "wantread" then
            err_msg = '连接超时'
        end
        logger.err(logName, 'requestFunc err:', tostring(res))
        return wrap_response(nil, 'requestFunc: ' .. err_msg)
    end

    -- ApiClient 失败约定: nil, err_msg
    if not H.is_tbl(res) then
        local err_msg = H.errorHandler(rerr)
        if err_msg == "wantread" then
            err_msg = '连接超时'
        end
        logger.err(logName, 'request err:', tostring(rerr))
        return wrap_response(nil, 'requestFunc: ' .. err_msg)
    end

    -- 204 No Content（如进度上报）: 服务器确认成功但无响应体，视为成功
    if res.status == 204 then
        return wrap_response({})
    end

    if not H.is_tbl(res.body) then
        local err_msg = H.errorHandler(res)
        if err_msg == "wantread" then
            err_msg = '连接超时'
        end
        logger.err(logName, 'requestFunc err:', tostring(res))
        return wrap_response(nil, 'requestFunc: ' .. err_msg)
    end


    if res.body.content then
        if H.is_func(callback) then
            return callback(res.body)
        else
            return wrap_response(res.body.content)
        end
    elseif H.is_tbl(res.body) then --and res.body.readProgress then
        return wrap_response(res.body)
    else
        return wrap_response(nil, (res.body and res.body.errorMsg) and res.body.errorMsg or '出错1')
    end
end

function M:refreshVolumesCache(series, last_refresh_time)

    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshVolumesCache')
        return wrap_response(nil, '处理中')
    end
    if not (H.is_tbl(series) and H.is_str(series.url) and H.is_str(series.cache_id)) then
        return wrap_response(nil, "获取目录参数错误")
    end

    local book_cache_id = series.cache_id
    return self:komgaApi(function()
        -- POST /api/v1/books/list(按系列条件查询分卷)。
        -- 注意: Komga 分页参数 size 只认 query string, 放 body 会被忽略(默认页大小 20 截断)
        return self.api:post("/api/v1/books/list", {size = 1000}, {
            condition = {
                allOf = {
                    {
                        seriesId = {
                            operator = "is",
                            value = series.cache_id
                        }
                    }
                }
            }
        }, {timeouts = {10, 12}})
    end, function(response)

        local status, err = pcall(function()
            return self.dbManager:upsertVolumes(book_cache_id, response.content)
        end)

        if not status then
            dbg.log('refreshVolumesCache数据写入', tostring(err))
            return wrap_response(nil, '数据写入出错，请重试')
        end
        return wrap_response(true)
    end, 'refreshVolumesCache')
end

function M:refreshLibraryCache(last_refresh_time)

    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshVolumesCache')
        return wrap_response(nil, '处理中')
    end

    return self:komgaApi(function()
        -- data=bookinfos
        dbg.v('Start refreshing library')
        logger.warn('Start refreshing library')
        -- POST /api/v1/series/list(全量书架)。
        -- 注意: 分页参数 size 只认 query string, 放 body 会被忽略(默认页大小 20 截断)
        return self.api:post("/api/v1/series/list", {size = 1000}, {
            fullTextSearch = ""
        }, {timeouts = {8, 12}})
    end, function(response)
        local bookShelfId = self:getServerPathCode()
        local status, err = pcall(function()
            local server_address = self.settings_data.data['server_address']
            return self.dbManager:upsertSeries(bookShelfId, response.content, server_address)
        end)

        if not status then
            dbg.log('refreshLibraryCache数据写入', H.errorHandler(err))
            return wrap_response(nil, '写入数据出错，请重试')
        end

        return wrap_response(true)
    end, 'refreshLibraryCache')
end

function M:pGetEpubManifest(volume)
    local bookId = volume.bookId

    if not H.is_str(bookId) then
        return wrap_response(nil, 'GetChapterContent参数错误')
    end

    return self:komgaApi(function()
        -- GET /api/v1/books/:id/manifest/epub(webpub+json, 含 readingOrder/toc)
        return self.api:get("/api/v1/books/" .. bookId .. "/manifest/epub", nil, {
            headers = {
                ["X-Accept"] = "application/webpub+json"
            },
            timeouts = {18, 25}
        })
    end, nil, 'getEpubManifest')
end

function M:getVolumeReadProgress(volume)

    if not (H.is_str(volume.name) and H.is_str(volume.url)) then
        return wrap_response(nil, '参数错误')
    end

    return self:komgaApi(function()
        -- GET /api/v1/books/:id(BookDto, 含 readProgress/media/metadata)
        return self.api:get("/api/v1/books/" .. volume.bookId, nil, {timeouts = {3, 5}})
    end, nil, 'getVolumeReadProgress')

end

function M:saveVolumeProgress(volume)

    if not (H.is_str(volume.name) and H.is_str(volume.url)) then
        return wrap_response(nil, '参数错误')
    end

    local number = volume.number
    local finish = (volume.current_page == volume.pages)
    -- print(finish)
    if finish then
        volume.isRead = finish
        -- print("Mark volume read...", volume.number)
        self:toggleVolumeRead(volume)
    end
    return self:komgaApi(function()
        -- PATCH /api/v1/books/:id/read-progress(漫画分卷页码进度)
        return self.api:patch("/api/v1/books/" .. volume.bookId .. "/read-progress", nil, {
            page = volume.current_page,
            completed = finish
        }, {timeouts = {3, 5}})
    end, nil, 'saveVolumeProgress')

end

-- EPUB(非 Divina)进度走 Readium Progression API: GET /progression 返回 R2Progression
-- {modified, device, locator{locations{progression, position, totalProgression}}}
function M:getBookProgression(bookId)
    if not H.is_str(bookId) then
        return wrap_response(nil, '参数错误')
    end
    local r = self:komgaApi(function()
        -- GET /api/v1/books/:id/progression(R2Progression)
        return self.api:get("/api/v1/books/" .. bookId .. "/progression", nil, {timeouts = {3, 5}})
    end, nil, 'getBookProgression')
    local loc = r and r.body and r.body.locator
    return r
end

-- EPUB 进度上传: PUT /progression, payload 为 R2Progression(服务器按 locator 重算 totalProgression,
-- 并换算 readProgress.page; totalProgression 到 1 时自动标 completed)
-- upload 需含 {bookId, name, url, number, book_cache_id, locator, frac, current_page, pages}
function M:saveBookProgression(upload)
    if not (H.is_str(upload.bookId) and H.is_tbl(upload.locator)
        and H.is_str(upload.name) and H.is_str(upload.url)) then
        return wrap_response(nil, '参数错误')
    end
    -- 读完(整卷比例 >= 99.9%): 本地标记已读, 服务器读满(totalProgression=1)会自动标 completed
    if H.is_num(upload.frac) and upload.frac >= 0.999 then
        self.dbManager:updateVolumeIsRead(upload, upload.current_page, true)
    end
    -- modified 必须严格递增, 否则服务器 409 Conflict; 同秒内多次上传时间戳加 1 秒
    local ts = os.time()
    if ts <= (self._last_prog_modified_ts or 0) then
        ts = (self._last_prog_modified_ts or 0) + 1
    end
    self._last_prog_modified_ts = ts
    local r = self:komgaApi(function()
        -- PUT /api/v1/books/:id/progression
        return self.api:put("/api/v1/books/" .. upload.bookId .. "/progression", nil, {
            modified = os.date("!%Y-%m-%dT%H:%M:%SZ", ts),
            device = {id = "koreader", name = "KOReader"},
            locator = upload.locator
        }, {timeouts = {3, 5}})
    end, nil, 'saveBookProgression')
    return r
end

-- EPUB: 全书位置查找表(totalProgression 单调递增), 供 frac→locator 映射
function M:getBookPositions(bookId)
    if not H.is_str(bookId) then
        return wrap_response(nil, '参数错误')
    end
    local r = self:komgaApi(function()
        -- GET /api/v1/books/:id/positions(readium position-list)
        return self.api:get("/api/v1/books/" .. bookId .. "/positions", nil, {timeouts = {3, 5}})
    end, nil, 'getBookPositions')
    return r
end

function M:getBookSourcesList()
    return self:komgaApi(function()
        -- GET /getBookSources(书源列表, reader3 服务)
        return self.api:get("/getBookSources", {simple = 1, v = os.time()}, {timeouts = {15, 20}})
    end, nil, 'getBookSourcesList')
end

function M:refreshVolumeContent(volume)

    local url = volume.url
    local number = volume.number
    local down_number = volume.number

    if not H.is_str(url) or not H.is_num(down_number) then
        return wrap_response(nil, '刷新章节出错')
    end


    self:komgaApi(function()
        -- GET /api/v1/books/:id/pages/:n 的历史调用形态(url/index 参数), 保留原语义
        return self.api:get("/api/v1/books/-/pages/" .. tostring(down_number), {
            url = url,
            index = down_number,
            refresh = 1,
            v = os.time()
        }, {timeouts = {10, 20}})
    end, nil, 'GetChapterContent')
end

function M:searchBookSource(url, lastIndex, searchSize)
    if not H.is_str(url) then
        return wrap_response(nil, '获取更多书源参数错误')
    end
    if not H.is_num(lastIndex) then
        lastIndex = -1
    end
    if not H.is_num(searchSize) then
        searchSize = 5
    end
    return self:komgaApi(function()
        -- data.list data.lastindex
        return self.api:get("/searchBookSource", {
            url = url,
            bookSourceGroup = '',
            lastIndex = lastIndex,
            searchSize = searchSize,
            v = os.time()
        }, {timeouts = {70, 80}})
    end, nil, 'searchBook')

end

function M:searchBook(search_text, bookSourceUrl, concurrentCount)
    if not (H.is_str(search_text) and search_text ~= '' and H.is_str(bookSourceUrl)) then
        return wrap_response(nil, "输入参数错误")
    end
    concurrentCount = concurrentCount or 32
    return self:komgaApi(function()
        -- data = bookinfolist
        return self.api:get("/searchBook", {
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            bookSourceUrl = bookSourceUrl,
            lastIndex = -1,
            page = 1,
            v = os.time()
        }, {timeouts = {20, 30}})
    end, nil, 'searchBook')
end

function M:searchBookMulti(search_text, lastIndex, searchSize, concurrentCount)

    if not H.is_str(search_text) or search_text == '' then
        return wrap_response(nil, "输入参数错误")
    end

    lastIndex = lastIndex or -1
    searchSize = searchSize or 20
    concurrentCount = concurrentCount or 32
    return self:komgaApi(function()
        -- data.list data.lastindex
        return self.api:get("/searchBookMulti", {
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            lastIndex = lastIndex,
            searchSize = searchSize,
            v = os.time()
        }, {timeouts = {60, 80}})
    end, nil, 'searchBook')
end

function M:deleteBook(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.url)) then
        return wrap_response(nil, "输入参数错误")
    end

    return self:komgaApi(function()
        -- {"isSuccess":true,"errorMsg":"","data":"删除书籍成功"}
        return self.api:post("/deleteBook", nil, {
            v = os.time(),
            name = bookinfo.name,
            author = bookinfo.author,
            url = bookinfo.url,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder or 0,
            durChapterIndex = bookinfo.durChapterIndex or 0,
            durChapterPos = bookinfo.durChapterPos or 0,
            durChapterTime = bookinfo.durChapterTime or 0,
            durChapterTitle = bookinfo.durChapterTitle or '',
            wordCount = bookinfo.wordCount or '',
            intro = bookinfo.intro or '',
            booksCount = bookinfo.booksCount or 0,
            kind = bookinfo.kind or '',
            type = bookinfo.type or 0
        }, {timeouts = {6, 8}})
    end, nil, 'deleteBook')
end

local ffi = require("ffi")
local libutf8proc

local function utf8_chars(str, reverse)
    if libutf8proc == nil then
        -- 兼容旧版
        if ffi.loadlib then
            libutf8proc = ffi.loadlib("utf8proc", "3")
        else
            if ffi.os == "Windows" then
                libutf8proc = ffi.load("libs/libutf8proc.dll")
            elseif ffi.os == "OSX" then
                libutf8proc = ffi.load("libs/libutf8proc.dylib")
            else
                libutf8proc = ffi.load("libs/libutf8proc.so.2")
            end
        end

        ffi.cdef [[
typedef int32_t utf8proc_int32_t;
typedef uint8_t utf8proc_uint8_t;
typedef ssize_t utf8proc_ssize_t;
utf8proc_ssize_t utf8proc_iterate(const utf8proc_uint8_t *, utf8proc_ssize_t, utf8proc_int32_t *);
]]
    end
    local str_len = #str
    local pos = reverse and (str_len + 1) or 0
    local str_p = ffi.cast("const utf8proc_uint8_t*", str)
    local codepoint = ffi.new("utf8proc_int32_t[1]")

    return function()
        while true do
            pos = reverse and (pos - 1) or (pos + 1)
            if (reverse and pos < 1) or (not reverse and pos > str_len) then
                return nil
            end

            local remaining = reverse and pos or (str_len - pos + 1)
            -- 指针偏移调整为 str_p + pos - 1
            local bytes = libutf8proc.utf8proc_iterate(str_p + pos - 1, remaining, codepoint)

            if bytes > 0 then
                -- 计算起始指针，转换为Lua字符串
                local char = ffi.string(str_p + pos - 1, bytes)
                local ret_pos = tonumber(pos)
                -- [修复] 修正了反向遍历成功时的指针更新逻辑
                -- 它应该回退到当前字符之前的位置，以便下一次循环可以正确地处理前一个字节
                pos = reverse and (pos - bytes + 1) or (pos + bytes - 1)
                return ret_pos, tonumber(codepoint[0]), char
            elseif bytes < 0 then
                -- [修复] 解码失败时（bytes < 0），不做任何操作
                -- 循环会自动将指针移动到前一个/后一个字节继续尝试，避免跳字节
            end
        end
    end
end

function M:utf8_trim(str)
    if type(str) ~= "string" or str == "" then
        return ""
    end

    local utf8_whitespace_codepoints = {
        [0x00A0] = true,
        [0x1680] = true,
        [0x2000] = true,
        [0x2001] = true,
        [0x2002] = true,
        [0x2003] = true,
        [0x2004] = true,
        [0x2005] = true,
        [0x2006] = true,
        [0x2007] = true,
        [0x2008] = true,
        [0x2009] = true,
        [0x200A] = true,
        [0x200B] = true,
        [0x202F] = true,
        [0x205F] = true,
        [0x3000] = true,
        [0x0009] = true,
        [0x000A] = true,
        [0x000B] = true,
        [0x000C] = true,
        [0x000D] = true,
        [0x0020] = true
    }

    local start
    for pos, cp, char in utf8_chars(str) do
        if not utf8_whitespace_codepoints[cp] then
            start = pos
            break
        end
    end
    if not start then
        return ""
    end

    local finish
    for pos, cp, char in utf8_chars(str, true) do
        if not utf8_whitespace_codepoints[cp] then
            finish = pos + #char - 1
            break
        end
    end

    return (start and finish and start <= finish) and str:sub(start, finish) or ""
end

---去除多余换行、统一段落缩进、根据部分排版规则将不合理的换行合并成一个
---仅假设源文本格式混入了错误或多余换行和不标准的段落缩进
---@param text any




local book_chapter_resources = function(book_cache_id, filename, res_data, overwrite)

    if not book_cache_id then
        return
    end

    local catalogue, relpath, filepath

    catalogue = string.format("%s/resources", H.getBookCachePath(book_cache_id))
    if H.is_str(filename) then
        relpath = string.format("resources/%s", filename)
        filepath = string.format("%s/%s", catalogue, filename)
    end

    if res_data and (overwrite or not util.fileExists(filepath or "")) then
        H.checkAndCreateFolder(catalogue)
        -- 原子写: 先写 .part 再 rename, 避免进程被杀/断电留下半写文件
        -- 被存在性检查误判为有效缓存
        local tmp_path = filepath .. '.part'
        if util.writeToFile(res_data, tmp_path, true) then
            os.rename(tmp_path, filepath)
        end
    end

    return relpath, filepath, catalogue
end

local volume_writeToFile = function(volume, filePath, resources)
    if util.fileExists(filePath) then
        if volume.is_pre_loading == true then
            error('存在目标任务，本次任务取消')
        else
            volume.cacheFilePath = filePath
            return volume
        end
    end

    -- 原子写: 先写 .part 再 rename, 半写文件不会被存在性检查误判为有效缓存
    local tmp_path = filePath .. '.part'
    if util.writeToFile(resources, tmp_path, true) and os.rename(tmp_path, filePath) then

        if volume.is_pre_loading == true then
            dbg.v('Cache task completed volume.title', volume.title or '')
        end

        volume.cacheFilePath = filePath
        return volume
    else
        error('下载 content 写入失败')
    end
end

-- 生成章节链接匹配关键字(实现收敛在 VolumePath.basenameKey, 有单测)

local replace_css_urls = function(css_text, replace_fn)
    css_text = tostring(css_text or "")
    return (css_text:gsub("url%s*%((%s*['\"]?)(.-)(['\"]?%s*)%)", function(prefix, old_path, suffix)
        if type(old_path) ~= "string" or old_path == "" or old_path:lower():find("^data:") then
            return
        end
        local ok, new_path = pcall(replace_fn, old_path)
        if not ok or type(new_path) ~= "string" or new_path == "" then
            return "url(" .. prefix .. old_path .. suffix .. ")"
        end
        return
    end))
end

local processLink
processLink = function(book_cache_id, resources_src, base_url, is_porxy, callback)
    if not (H.is_str(book_cache_id) and H.is_str(resources_src) and resources_src ~= "") then
        logger.dbg("invalid params in processLink", book_cache_id, resources_src)
        return nil
    end

    local processed_src
    if is_porxy == true then
        local url = base_url
        processed_src = M:getProxyImageUrl(url, resources_src)
    else
        processed_src = util.trim(resources_src)

        local lower_src = processed_src:lower()
        if lower_src:find("^data:") then
            logger.dbg("skipping data URI", processed_src)
            return nil
        elseif lower_src:find("^res:") then
            logger.dbg("fonts css URI", processed_src)
            return nil
        elseif lower_src:sub(1, 1) == "#" then
            return nil
        elseif lower_src:sub(1, 2) == "//" then
            processed_src = "https:" .. processed_src
        elseif lower_src:sub(1, 1) == "/" then
            processed_src = socket_url.absolute(base_url, processed_src)
        elseif not lower_src:find("^http") then
            processed_src = socket_url.absolute(base_url, processed_src)
        end
    end

    local ext = get_url_extension(processed_src)
    if ext == "" then
        local clean_url = resources_src:gsub("[#?].*", "")
        ext = get_url_extension(clean_url)
        if ext == "" then
            -- komga app 图片后带数据 v07ew.jpg,{'headers':{'referer':'https://m.weibo.cn'}}"
            clean_url = resources_src:match("^(.-),") or resources_src
            ext = get_url_extension(clean_url)
        end
    end

    -- logger.info("src_ext", ext, "resources_src", resources_src)
    local resources_id = md5(processed_src)
    local resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id

    local resources_relpath, resources_filepath, resources_catalogue =
        book_chapter_resources(book_cache_id, resources_filename)
    -- logger.info(resources_relpath, resources_filepath, resources_catalogue)

    -- 已有缓存
    if ext ~= "" and resources_filepath and util.fileExists(resources_filepath) then
        return resources_relpath
    end

    -- 流式落盘快速路径: 扩展名已知且无需内容加工(非 css 级联)的资源直接下载到文件,
    -- 不整载内存(大图内存峰值显著降低), 中断可 Range 续传; 失败回退下方内存路径
    if ext ~= "" and resources_filepath and not callback then
        local ok_dl = pcall(function()
            if not M.httpReq then
                M.httpReq = require("Komga.HttpRequest")
            end
            H.checkAndCreateFolder(resources_catalogue)
            local ok, res = M.httpReq.pStreamToFile({
                url = processed_src,
                dest = resources_filepath,
                timeout = 15,
                maxtime = 60
            })
            return ok == true
        end)
        if ok_dl then
            return resources_relpath
        end
        logger.dbg("processLink stream fallback to memory:", processed_src)
    end

    local status, err = pGetUrlContent({
                url = processed_src,
                timeout = 15,
                maxtime = 60
        })
    if status and H.is_tbl(err) and err["data"] then
        if not ext or ext == "" then
            ext = err["ext"] or ""
            resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id
        end

        -- 尝试处理css里面的级联
        if ext == "css_disable" and not callback then
            err["data"] = replace_css_urls(err["data"], function(url)
                -- 防止循环引用
                if url == resources_src then
                    return url
                end
                return processLink(book_cache_id, url, processed_src, nil, true)
            end)

        end

        return book_chapter_resources(book_cache_id, resources_filename, err["data"])
    end

end


local txt2html = function(book_cache_id, content, title)
    local dropcaps
    local lines = {}
    content = content or ""
    title = title or ""

    for line in util.gsplit(content, "\n", false, true) do
        line = M:utf8_trim(line)
        local el_tags

        if dropcaps ~= true and line ~= "" and not string.find(line, "<img", 1, true) then
            -- 尝试清理重复标题 >9 避免单字误判
            if #title > 9 and string.find(line, title, 1, true) == 1 then
                line = plain_text_replace(line, title, "", 1)
                line = M:utf8_trim(line)
                if line == "" then
                    -- 抛弃仅重复标题行
                    goto continue
                end
            end
            
            local rep_text = line:match(util.UTF8_CHAR_PATTERN)
            
            -- [修复] 增加对 rep_text 的有效性检查
            if rep_text and rep_text ~= "" then
                -- 只有在成功获取到首字符时，才进行替换和格式化
                line = plain_text_replace(line, rep_text, "", 1)
                el_tags = string.format('<p style="text-indent: 0em;"><span class="duokan-dropcaps-two">%s</span>%s</p>',
                    rep_text, line)
                dropcaps = true
            else
                -- 如果没有有效的首字符（例如，行是空的或只包含不可见字符），则作为普通段落处理
                el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
            end
        else
            el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
        end
        table.insert(lines, el_tags)
        ::continue::
    end

    if #lines > 0 then
        content = table.concat(lines)
    end

    local epub = require("Komga/EpubHelper")
    epub.addCssRes(book_cache_id)
    return epub.addchapterT(title, content)
end

local htmlparser
function M:_processVolumeContent(volume, content)

    local url = volume.url
    local book_cache_id = volume.book_cache_id
    local number = volume.number
    local chapter_title = volume.title or ''
    local down_number = volume.number

    if type(content) ~= "string" then
        content = tostring(content)
    end

    local filePath = H.getVolumeCacheFilePath(book_cache_id, volume.bookId, number, volume.name)

    local first_line = string.match(content, "([^\n]*)\n?") or content
    local PAGE_TYPES = {
        TEXT = 1, -- 纯文本
        IMAGE = 2, -- 纯图片
        MIXED = 3, -- 图文混合
        XHTML = 4, -- XHTML/EPUB
        MEDIA = 5 -- 音频/视频（??）
    }

    local page_type = get_chapter_content_type(content, first_line)
    -- logger.dbg("get_chapter_content_type:",page_type)
    -- print("page_type is..." , page_type);
    if page_type == PAGE_TYPES['IMAGE'] then
        local img_sources = self:getPorxyPicUrls(url, content)
        if H.is_tbl(img_sources) and #img_sources > 0 then

            -- 一张图片就不打包cbz了
            if #img_sources == 1 then
                local res_url = img_sources[1]
                local status, err = pGetUrlContent({
                        url = res_url,
                        timeout = 15,
                        maxtime = 60
                })
                if not status then
                    error('请求错误，' .. H.errorHandler(err))
                end
                if not (H.is_tbl(err) and err["data"]) then
                    error('下载失败，数据为空')
                end

                local ext = get_url_extension(res_url)
                if (not ext or ext == "") and not not err.ext then
                    ext = err['ext']
                end

                filePath = string.format("%s.%s", filePath, ext or "")
                return volume_writeToFile(volume, filePath, err['data'])
            else
                filePath = filePath .. '.cbz'
                local status, err = pcall(pDownload_CreateCBZ, filePath, img_sources)

                if not status then
                    error('CreateCBZ err:' .. H.errorHandler(err))
                end

                if volume.is_pre_loading == true then
                    dbg.v('Cache task completed volume.title:', chapter_title)
                end
            end
            volume.cacheFilePath = filePath
            return volume
        else
            error('生成图片列表失败')
        end

    elseif page_type == PAGE_TYPES['XHTML'] then

        local html_url = self:getProxyEpubUrl(url, first_line)
        -- logger.info("bookurl",url)
        -- logger.info("first_line",first_line)
        -- logger.info("html_url",html_url)
        if html_url == nil or html_url == '' then
            error('转换失败')
        end
        local status, err = pGetUrlContent({
                        url = html_url,
                        timeout = 15,
                        maxtime = 60
                })
        if not status then
            error('请求错误，' .. H.errorHandler(err))
        end
        if not (H.is_tbl(err) and err["data"]) then
            error('下载失败，数据为空')
        end
        -- TODO 写入原始文件名，用于导出
        local ext, original_name = get_url_extension(first_line)
        if (not ext or ext == "") and not not err.ext then
            ext = err['ext']
        end

        content = err['data'] or '下载失败'
        filePath = string.format("%s.%s", filePath, ext or "")

        if not htmlparser then
            htmlparser = require("htmlparser")
        end
        local success, root = pcall(htmlparser.parse, content, 5000)
        if success and root then

            local body = root("body")
            if body[1] then
                local img_pattern = "(<[Ii][Mm][Gg].-[Ss][Rr][Cc]%s*=%s*)(['\"])(.-)%2([^>]*>)"
                local image_xlink_pattern = '(<image.-href%s*=%s*)(["\'])(.-)%2([^>]*>)'
                local link_pattern = '(<link.-href%s*=%s*)(["\'])(.-)%2([^>]*>)'
                for _, el in ipairs(root("script")) do
                    if el then
                        local el_text = el:gettext()
                        if el_text then
                            content = plain_text_replace(content, el_text, "")
                        end
                    end
                end
                for _, el in ipairs(root("head > link[href]")) do
                    if el and el.attributes and el.attributes["href"] then
                        local relpath = processLink(book_cache_id, el.attributes["href"], html_url)
                        local el_text = el:gettext()
                        if H.is_str(relpath) and el_text then
                            local replace_text = plain_text_replace(el_text, el.attributes["href"], relpath)
                            content = plain_text_replace(content, el_text, replace_text)
                        end
                    end
                end
                for _, el in ipairs(body[1]:select("img[src]")) do
                    if el and el.attributes and el.attributes["src"] then
                        local relpath = processLink(book_cache_id, el.attributes["src"], html_url)
                        local el_text = el:gettext()
                        if relpath and el_text then
                            local replace_text = plain_text_replace(el_text, el.attributes["src"], relpath)
                            content = plain_text_replace(content, el_text, replace_text)
                        end
                    end
                end
                for _, el in ipairs(body[1]:select("svg")) do
                    if el then
                        local el_text = el:gettext()
                        for r1, r2, r3, r4 in el_text:gmatch(image_xlink_pattern) do
                            local open, path, close = r1, r3, r4
                            if not open or open == "" then
                                return
                            end
                            open = open .. r2 or ""
                            local relpath = processLink(book_cache_id, path, html_url)
                            if H.is_str(relpath) then
                                local replace_text = plain_text_replace(el_text, open .. path, open .. relpath)
                                content = plain_text_replace(content, el_text, replace_text)
                            end
                        end
                    end
                end

                -- 补充处理
                content = content:gsub("<script[^>]*>(.-\n?)</script>", ""):gsub("<script[^>]*>[\x00-\xFF]-</script>",
                    ""):gsub(link_pattern, function(r1, r2, r3, r4)
                    local open, path, close = r1, r3, r4
                    if not (open and open ~= "" and path and path ~= "" and string.find(path, "^resources/") == nil) then
                        return
                    end
                    local relpath = processLink(book_cache_id, path, html_url)
                    if H.is_str(relpath) then
                        r2 = r2 or ""
                        close = close or ""
                        return table.concat({open .. r2, relpath, r2 .. close})
                    end
                    return
                end):gsub(image_xlink_pattern, function(r1, r2, r3, r4)
                    local open, path, close = r1, r3, r4
                    -- 前面处理过了这里就跳过
                    if open and open ~= "" and path and string.find(path, "^resources/") == nil then
                        local relpath = processLink(book_cache_id, path, html_url)
                        if H.is_str(relpath) then
                            r2 = r2 or ""
                            close = close or ""
                            return table.concat({open .. r2, relpath, r2 .. close})
                        end
                    end
                    return
                end):gsub(img_pattern, function(r1, r2, r3, r4)
                    if r1 == "" or not r3 or string.find(r3, "^resources/") ~= nil then
                        return
                    end
                    local path = r3
                    local relpath = processLink(book_cache_id, path, html_url)
                    if H.is_str(relpath) then
                        return table.concat({r1, r2, relpath, r2, r4})
                    end
                    return
                end)

                -- === FIX: 重写内部章节链接与剩余相对路径 ===
                -- KOReader 用 document_dir 解析相对 href, 原 epub 的 ../Text/xx.xhtml
                -- 在扁平缓存目录下解析不到目标, 点击链接无反应。这里把指向其他章节的
                -- <a href> 改写成实际缓存文件名(<安全书名>-<bookId>-<index>.xhtml),
                -- 使其能通过 ReaderLink:openFileFromLink 打开并跳转。
                do
                    local href_map = {}
                    local href_ext = {} -- key → 缓存扩展名(xhtml/html, 随源页面 URL)
                    -- 优先用 manifest readingOrder(含全部章节 href→序号 映射)。
                    -- 注意: Lua pattern 里 '|' 是字面字符, 不能当"或"用, 故用 %.x?html$
                    if H.is_tbl(volume.readingOrder) then
                        for ro_idx, ro_item in ipairs(volume.readingOrder) do
                            if H.is_tbl(ro_item) and H.is_str(ro_item.href) and
                                ro_item.href:lower():match("%.x?html$") then
                                local key = normalize_rel_href(ro_item.href)
                                if key then
                                    href_map[key] = ro_idx
                                    href_ext[key] = ro_item.href:lower():match("%.(x?html)$")
                                end
                            end
                        end
                    end
                    -- 再用 DB 全量行补充(含 'No title' 子章节), 已有 key 不覆盖,
                    -- 这样即使 readingOrder 缺失/为空/过期也能构建出完整映射
                    local all_chs = self.dbManager:getAllEpubChapterUrls(volume.bookId)
                    if H.is_tbl(all_chs) then
                        for _, ch in ipairs(all_chs) do
                            if H.is_num(ch.number) and H.is_str(ch.url) then
                                local key = normalize_rel_href(ch.url)
                                if key and not href_map[key] then
                                    href_map[key] = ch.number
                                    href_ext[key] = ch.url:lower():match("%.(x?html)$")
                                end
                            end
                        end
                    end

                    if next(href_map) then
                        local cached_name = util.getSafeFilename(volume.name or "")
                        local bookId = volume.bookId
                        content = content:gsub('(<[Aa][^>]-href%s*=%s*)([\'"])(.-)%2',
                            function(open, quote, href)
                                if not H.is_str(href) or href == "" or href:sub(1, 1) == "#" then
                                    return open .. quote .. href .. quote
                                end
                                local key = normalize_rel_href(href)
                                local target_index = key and href_map[key]
                                if H.is_num(target_index) then
                                    return open .. quote ..
                                        get_cached_chapter_filename(bookId, target_index, cached_name,
                                            href_ext[key]) .. quote
                                end
                                return open .. quote .. href .. quote
                            end)
                    end

                    -- 内联 <style>/style 中的 url() 相对路径重写到 resources/(如 css 里引用的图片/字体)
                    content = content:gsub('url%s*%(%s*([\'"])?(.-)%1%s*%)', function(q, u)
                        if not H.is_str(u) or u == "" or u:sub(1, 1) == "#" or u:lower():find("^data:") then
                            return nil
                        end
                        local relpath = processLink(book_cache_id, u, html_url)
                        if H.is_str(relpath) then
                            return string.format("url(%s%s%s)", q or "", relpath, q or "")
                        end
                        return nil
                    end)
                end
            end
        end

        return volume_writeToFile(volume, filePath, content)

    elseif page_type == PAGE_TYPES['MIXED'] then
        -- 混合 img 标签和文本
        filePath = filePath .. '.html'
        local img_pattern = "(<[Ii][Mm][Gg].-[Ss][Rr][Cc]%s*=%s*)(['\"])(.-)%2([^>]*>)"
        if has_img_tag(content) then

            content = content:gsub(img_pattern, function(r1, r2, r3, r4)
                if not (r1 and r1 ~= "" and r3 and r3 ~= "") then
                    return
                end
                local path = r3
                local relpath = processLink(book_cache_id, path, url, true)
                if H.is_str(relpath) then
                    -- 随文图
                    return string.format('<div class="duokan-image-single">%s</div>',
                        table.concat({r1, r2, relpath, r2, ' class="picture-80" alt="" ', r4}))
                end
                return
            end)
        end

        content = txt2html(book_cache_id, content, chapter_title)
        return volume_writeToFile(volume, filePath, content)
    else
        -- TEXT
        if self.settings_data.data.istxt == true then
            filePath = filePath .. '.txt'
            local paragraphs = splitParagraphsPreserveBlank(content)
            if #paragraphs == 0 then
                volume.content_is_nil = true
            end
            first_line = paragraphs[1] or ""
            content = table.concat(paragraphs, "\n")
            paragraphs = nil

            if not string.find(first_line, chapter_title, 1, true) then
                content = table.concat({"\t\t", tostring(chapter_title), "\n\n", content})
            end
        else
            filePath = filePath .. '.html'
            content = txt2html(book_cache_id, content, chapter_title)
        end

        return volume_writeToFile(volume, filePath, content)
    end

end

function M:pDownloadVolume(volume, message_dialog, is_recursive)

    local series_url = volume.url
    local book_cache_id = volume.book_cache_id
    local number = volume.number
    local chapter_title = volume.title or ''
    local down_number = volume.number
    if volume.bookId == nil then
        volume.bookId = volume.book_cache_id
    end

    -- logger.info('pDownloadVolume called',volume)

    -- print(series_url, book_cache_id, volume.bookId ,number, chapter_title, down_number)
    local function message_show(msg)
        if message_dialog then
            message_dialog.text = msg
            UIManager:setDirty(message_dialog, "ui")
            UIManager:forceRePaint()
        end
    end

    if series_url == nil or not book_cache_id then
        error('pDownloadVolume input parameters err' .. tostring(series_url) .. tostring(book_cache_id))
    end

    local cache_chapter = self:getCacheVolumeFilePath(volume)
    if cache_chapter and cache_chapter.cacheFilePath then
        return cache_chapter
    end

    local url = nil
    -- 分卷(volume 表)没有 url 列, 以前每下载一个未缓存章节都会先调
    -- pGetEpubManifest 拉取整个 manifest(getEpubManifest, 超时 18-25s), 导致下载卡住数秒到数十秒。
    -- 内部章节 URL(epub_chapter.url)通常已在库中, 直接使用即可跳过该慢请求。
    -- === FIX: 确保 url 始终来自数据库(或 manifest 兜底), 子章节 URL 缺失时也能下载/跳转 ===
    -- (卷对象上的 url 字段是系列 URL, 与内部章节 URL 语义不同, 不能用作回退)
    local epubchapter = self.dbManager:getEpubChapterInfo(volume.bookId, down_number)
    if H.is_tbl(epubchapter) and H.is_str(epubchapter.url) and epubchapter.url ~= "" then
        url = epubchapter.url
    end

    -- 兜底: 数据库没有该章节 URL 时, 强制刷新 manifest 并把内部章节回写数据库, 再取 URL。
    -- (子章节可能因早期只遍历顶层 toc 而未入库, 这里能补上)
    if not H.is_str(url) or url == "" then
        local inforesponse = self:pGetEpubManifest(volume)
        if H.is_tbl(inforesponse) and H.is_tbl(inforesponse.body) and H.is_tbl(inforesponse.body.toc) then
            volume.toc = inforesponse.body.toc
            volume.readingOrder = inforesponse.body.readingOrder
            self.dbManager:upsertEpubChapters(book_cache_id, volume)
        end
        epubchapter = self.dbManager:getEpubChapterInfo(volume.bookId, down_number)
        if H.is_tbl(epubchapter) and H.is_str(epubchapter.url) and epubchapter.url ~= "" then
            url = epubchapter.url
        end
    end
    
    if url ~= nil then
        -- print("Downloading Url is ...",url)
        local status, err = pGetUrlContent({
                            url = url,
                            timeout = 120,
                            maxtime = 120,
                            headers = {
                                ["user-agent"] = "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+",
                                ["X-API-Key"] = self:getApiKey()
                            }
                    })

        if status and err and err['data'] then
            local data = err['data']
            -- EPUB 页面资源可能是 .xhtml 或 .html(取决于书内文件名), 两者都需
            -- 拼接 url 供 get_chapter_content_type 判定为 XHTML; 否则页面源码会被
            -- 当 MIXED 转义成可见源码(女校之星/无职转生部分卷缓存成源码的根因)。
            -- 与 get_chapter_content_type 的 %.x?html$ 判定保持一致。
            if url:lower():match("%.x?html$") then
                data = url .. "\n" .. data
            end
            -- print(data)
            return self:_processVolumeContent(volume, data)
        else
            logger.err("download volume error: ", url, err)
        end
    end
    -- if not H.is_tbl(response) or response.type ~= 'SUCCESS' then
    --     error(response.message or '章节下载失败')
    -- end

    return nil --
end

function M:getCacheVolumeFilePath(volume)

    if not H.is_tbl(volume) or volume.book_cache_id == nil or volume.number == nil then
        dbg.log('getCacheVolumeFilePath parameters err:', volume)
        return volume
    end

    local book_cache_id = volume.book_cache_id
    local number = volume.number
    local book_name = volume.name or ""
    local cache_file_path = volume.cacheFilePath
    local cacheExt = volume.cacheExt
    local filePath = H.getVolumeCacheFilePath(book_cache_id, volume.bookId, number, book_name)

    if H.is_str(cache_file_path) then
        if util.fileExists(cache_file_path) and filePath == cache_file_path then
            volume.cacheFilePath = cache_file_path
            return volume
        else
            dbg.v('Files are deleted, clear database record flag', cache_file_path)
            pcall(function()
                self.dbManager:updateVolumeCacheFilePath(volume, false)
            end)
            volume.cacheFilePath = nil
        end
    end

    local extensions = {'html', 'cbz', 'xhtml', 'txt', 'png', 'jpg'}

    if H.is_str(cacheExt) then

        table.insert(extensions, 1, volume.cacheExt)
    end

    for _, ext in ipairs(extensions) do
        local fullPath = filePath .. '.' .. ext
        if util.fileExists(fullPath) then
            volume.cacheFilePath = fullPath
            return volume
        end
    end

    return volume
end

function M:findVolumesNotDownloaded(current_volume, count)
    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.number == nil then
        dbg.log('findVolumesNotDownloaded: bad params', current_volume)
        return {}
    end

    if current_volume.call_event == nil then
        current_volume.call_event = 'next'
    end

    local next_volumes = self.dbManager:findVolumesNotDownloaded(current_volume, count)

    if not H.is_tbl(next_volumes[1]) or next_volumes[1].number == nil then
        dbg.log('not found', current_volume.number)
        return {}
    end

    return next_volumes
end

function M:findNextVolume(current_volume, is_downloaded)

    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.number == nil then
        dbg.log("findNextVolume: bad params", current_volume)
        return
    end

    local book_cache_id = current_volume.book_cache_id
    local bookId = current_volume.bookId
    local current_volume_index = current_volume.number

    if current_volume.call_event == nil then
        current_volume.call_event = 'next'
    end

    local next_volume = self.dbManager:findNextEpubChapterInfo(current_volume, is_downloaded)

    if not H.is_tbl(next_volume) or next_volume.number == nil then
        dbg.log('not found', current_volume.number)
        return
    end

    next_volume.call_event = current_volume.call_event
    next_volume.is_pre_loading = current_volume.is_pre_loading

    return next_volume

end

function M:getProxyEpubUrl(url, htmlUrl)
    if not H.is_str(htmlUrl) then
        return htmlUrl
    end
    local server_address = self.settings_data.data['server_address']
    if server_address:match("/reader3$") and htmlUrl:match("%.x?html$") then
        local api_root_url = server_address:gsub("/reader3$", "")
        -- 可能有空格 "data": "/book-assets/guest/紫川_老猪/紫川 作者：老猪.epub/index/OEBPS/Text/chapter_0.html"
        htmlUrl = custom_urlEncode(htmlUrl)
        -- logger.info("custom_urlEncode:",htmlUrl)
        -- logger.info("util.urlEncode",util.urlEncode(htmlUrl))
        -- logger.info("url.escape",socket_url.escape(htmlUrl))
        return socket_url.absolute(api_root_url, htmlUrl)

    else
        return htmlUrl
    end
end

function M:getProxyImageUrl(url, img_src)
    local res_img_src = img_src
    local width = Device.screen:getWidth() or 800
    local server_address = self.settings_data.data.server_address
    
    local api_root_url = server_address
    -- <img src='__API_ROOT__/book-assets/guest/剑来_/剑来.cbz/index/1.png' />
    res_img_src = custom_urlEncode(img_src):gsub("^__API_ROOT__", "")
    res_img_src = socket_url.absolute(api_root_url, res_img_src)

    return res_img_src
end

function M:getPorxyPicUrls(url, content)
    local picUrls = get_img_src(content)
    if not H.is_tbl(picUrls) or #picUrls < 1 then
        return {}
    end

    local new_porxy_picurls = {}
    for i, img_src in ipairs(picUrls) do
        local new_url = self:getProxyImageUrl(url, img_src)
        table.insert(new_porxy_picurls, new_url)
    end
    return new_porxy_picurls
end

function M:pDownload_Image(img_src, timeout)
    local status, err = pGetUrlContent({
                    url = img_src,
                    timeout = timeout or 15,
                    maxtime = 60,
                    headers = {
                        ["user-agent"] = "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+",
                        ["X-API-Key"] = self:getApiKey()
                    }
                })
    if status and H.is_tbl(err) and err['data'] then
        return wrap_response(err)
    else
        return wrap_response(nil, H.errorHandler(err))
    end
end

function M:getVolumePageUrls(volume)
    local number = volume.number
    local server_address = self.settings_data.data['server_address']

    local imgs = {}

    for j = 1,volume.pages do
        table.insert(imgs,server_address .. "/api/v1/books/" .. volume.bookId .. "/pages/" ..j)
    end

    return imgs
end

function M:downloadAllVolumes(volumes)
    local begin_volume = volumes[1]

    begin_volume.call_event = 'next'

    local status, err = self:preLoadVolumes(begin_volume, #volumes)
    if not status then
        return wrap_response(nil, tostring(err))
    else
        return wrap_response(err)
    end
end

-- 后台任务超时(通道任务经 Async 托管超时与回收)
local PAGES_WATCHDOG_TIMEOUT = 300 -- 翻页预下载硬超时(秒)

function M:preLoadVolumes(volume, download_volume_count)

    if not H.is_tbl(volume) then
        return false, 'preLoadVolumesIncorrect call parameters'
    end

    if self:isExtractingInBackground() == true then
        dbg.log('"Background tasks incomplete. Cannot create new tasks:"')
        return false, "Background tasks incomplete. Cannot create new tasks:"
    end

    if not H.is_num(download_volume_count) or download_volume_count < 1 then
        download_volume_count = 1
    end

    local volume_down_tasks = {}

    if volume[1] and volume[1].number ~= nil and volume[1].book_cache_id ~= nil and volume[1].bookId ~= nil then

        volume_down_tasks = volume
    else

        volume_down_tasks = self:findVolumesNotDownloaded(volume, download_volume_count)
    end

    if not H.is_tbl(volume_down_tasks) or #volume_down_tasks < 1 then
        return false, 'No volume to be downloaded'
    end

    pcall(function()
        Device:enableCPUCores(2)
        UIManager:preventStandby()
    end)

    self:closeDbManager()

    -- 经 TaskQueue "volume" 通道执行(1 worker, 串行; 超时/回收由通道+Async 托管)。
    -- 任务体内仍读写 task.pid.lua: 供 quit_the_background_download_job 协作式停止
    local task_pid = TaskQueue.getChannel("volume", 1):push(function()

        pcall(function()

            util.writeToFile('', self.task_pid_file, true)
        end)

        local task_return_db_add = self.dbManager:transaction(
            function(book_cache_id, number, cache_file_path)
                return self.dbManager:dynamicUpdateVolume({
                    number = number,
                    book_cache_id = book_cache_id
                }, {
                    content = 'downloaded',
                    cacheFilePath = cache_file_path
                })
            end)

        local task_return_db_clear = self.dbManager:transaction(
            function(volume_down_tasks, task_return_ok_list)

                for i = 1, #volume_down_tasks do
                    local nextVolume = volume_down_tasks[i]
                    if H.is_tbl(nextVolume) and nextVolume.number ~= nil and nextVolume.book_cache_id ~= nil and nextVolume.bookId ~= nil then

                        local number = tonumber(nextVolume.number)
                        local book_cache_id = nextVolume.book_cache_id
                        local volume_book_id = nextVolume.bookId

                        if task_return_ok_list['ok_' .. number] == nil then

                            local status, err = pcall(function()
                                self.dbManager:updateVolumeDownloadState({
                                    number = number,
                                    book_cache_id = book_cache_id,
                                    bookId = volume_book_id
                                }, false)
                            end)

                            if not status then
                                dbg.log("Error cleaning download task for database write:", H.errorHandler(err))
                            end
                        end
                    end
                end
            end)

        local task_return_ok_list = {}

        ffiUtil.usleep(50)

        for i = 1, #volume_down_tasks do

            ffiUtil.usleep(50)

            local nextVolume = volume_down_tasks[i]

            if H.is_tbl(nextVolume) and nextVolume.number ~= nil and nextVolume.book_cache_id ~= nil and nextVolume.bookId ~= nil then

                nextVolume.is_pre_loading = true
                dbg.v('Threaded tasks running:runInSubProcess_start_title:', nextVolume.title)

                local status, err = pcall(function()
                    -- print("Download 2.", nextVolume.book_cache_id, " ", nextVolume.bookId)
                    return self:pDownloadVolume(nextVolume)
                end)

                if not status then
                    logger.err("Chapter download failed: ", tostring(err))
                else

                    if H.is_tbl(err) and err.cacheFilePath then

                        local cache_file_path = err.cacheFilePath
                        local number = tonumber(nextVolume.number)
                        local book_cache_id = nextVolume.book_cache_id

                        task_return_ok_list['ok_' .. number] = true

                        dbg.v('Download volume successfully:', book_cache_id, number, cache_file_path)

                        status, err = pcall(function()
                            return task_return_db_add(book_cache_id, number, cache_file_path)
                        end)
                        if not status then
                            logger.err('Error saving download to database:', tostring(err))
                        end
                    end

                end
            else
                dbg.log("Cache error: next volume data source")

            end

            if not util.fileExists(self.task_pid_file) then
                dbg.v("Downloader received stop signal")
                break
            end

        end

        dbg.v("Clean up unfinished downloads")
        local status, err = pcall(function()
            return task_return_db_clear(volume_down_tasks, task_return_ok_list)
        end)
        if not status and err then
            dbg.v("Incomplete volume cleanup after load", tostring(err))
        end

        self:closeDbManager()

        volume_down_tasks = nil
        task_return_ok_list = nil

        status, err = pcall(function()
            util.removeFile(self.task_pid_file)
            ffiUtil.usleep(50)
            util.removeFile(self.task_pid_file)
        end)

        status, err = pcall(function()

            Device:enableCPUCores(1)

            UIManager:allowStandby()
        end)
        if not status and err then
            dbg.v('allowStandby err', tostring(err))
        end

        return true

    end)

    if not task_pid then
        pcall(function()
            Device:enableCPUCores(1)
            UIManager:allowStandby()
        end)
        return false, "Background download task failed"
    end

    dbg.v("Task queued on volume channel")

    local task_return_db_func = self.dbManager:transaction(
        function(task_return_volume, content)

            self.dbManager:cleanVolumeDownloading()

            for i = 1, #task_return_volume do
                local task_volume = task_return_volume[i]
                if H.is_tbl(task_volume) and task_volume.number ~= nil and task_volume.book_cache_id ~=
                    nil then
                    self.dbManager:updateVolumeDownloadState(task_volume, content)
                end
            end
        end)

    local status, err = pcall(function()

        task_return_db_func(volume_down_tasks, 'downloading_')
    end)
    if not status and err then
        dbg.v("Download flag write error:", tostring(err))
    end

    return true, volume_down_tasks

end

-- 翻页预下载(EPUB 后几页/内部章节)是否进行中
function M:isPagesPreloading()
    return TaskQueue.getChannel("pages", 1):hasTasks()
end

-- 阅读中后台预下载当前 EPUB 卷的后几页(内部章节), 翻到时即开。
-- 与 preLoadVolumes 不同: 内部章节缓存不写 volume 表下载状态,
-- 全程静默——失败只记日志, 不弹窗、不打断阅读。
-- 经 Komga/Async 子进程执行(超时/回收由 Async 托管; fork 不可用时同步降级)。
function M:preLoadEpubChapters(volume, count)
    if not (H.is_tbl(volume) and H.is_str(volume.book_cache_id) and H.is_str(volume.bookId) and
        H.is_num(volume.number)) then
        return false
    end
    if self:isExtractingInBackground() == true or self:isPagesPreloading() == true then
        return false
    end
    count = H.is_num(count) and count or 3

    local book_cache_id = volume.book_cache_id
    local bookId = volume.bookId
    local book_name = volume.name or ""
    local cur_number = tonumber(volume.number) or 0

    -- 组装后 count 个内部章节任务, 已缓存的(DB 有 url 且文件存在)跳过
    local tasks = {}
    for i = 1, count do
        local num = cur_number + i
        local ok_ch, chapter = pcall(function()
            return self.dbManager:getEpubChapterInfo(bookId, num)
        end)
        if ok_ch and H.is_tbl(chapter) and H.is_str(chapter.url) and chapter.url ~= "" then
            local base = H.getVolumeCacheFilePath(book_cache_id, bookId, num, book_name)
            if not (util.fileExists(base .. ".xhtml") or util.fileExists(base .. ".html")) then
                table.insert(tasks, {
                    book_cache_id = book_cache_id,
                    bookId = bookId,
                    number = num,
                    name = book_name,
                    title = chapter.title or '',
                    is_pre_loading = true
                })
            end
        end
    end
    if #tasks < 1 then
        return false
    end

    pcall(function()
        Device:enableCPUCores(2)
        UIManager:preventStandby()
    end)

    self:closeDbManager()

    TaskQueue.getChannel("pages", 1):push(function()
        for i = 1, #tasks do
            local status, err = pcall(function()
                return self:pDownloadVolume(tasks[i])
            end)
            if not status then
                logger.err('preload epub chapter failed:', tostring(err))
            end
        end
        self:closeDbManager()
        return true
    end, nil, {timeout = PAGES_WATCHDOG_TIMEOUT, tag = "epub_pages"})
    return true
end

-- ---------------------------------------------------------------------------
-- 流式漫画页预取(磁盘缓存 + 子进程后台下载)
-- StreamImageView 每翻一页原本要同步下载一图; 预取把"后几页"提前落盘,
-- 翻页时直接读本地。缓存按 img_src 的 md5 命名, 阅读中滑动窗口清理,
-- 关卷时整目录清理, 不占用长期磁盘。
-- ---------------------------------------------------------------------------
local STREAM_PAGE_EXTS = {"jpg", "jpeg", "png", "webp", "gif"}

-- 流式页缓存目录: <系列缓存>/resources/stream
function M:getStreamPageCacheDir(bookCacheId)
    if not H.is_str(bookCacheId) then
        return nil
    end
    return H.joinPath(H.joinPath(H.getBookCachePath(bookCacheId), 'resources'), 'stream')
end

-- 查流式页缓存: 命中返回图片数据(string), 未命中返回 nil
function M:lookupStreamPageCache(bookCacheId, img_src)
    if not (H.is_str(bookCacheId) and H.is_str(img_src)) then
        return nil
    end
    local dir = self:getStreamPageCacheDir(bookCacheId)
    if not dir then
        return nil
    end
    local base = H.joinPath(dir, md5(img_src))
    for _, ext in ipairs(STREAM_PAGE_EXTS) do
        local p = base .. '.' .. ext
        if util.fileExists(p) then
            local f = io.open(p, "rb")
            if f then
                local data = f:read("*a")
                f:close()
                if data and #data > 0 then
                    return data
                end
            end
            return nil
        end
    end
    return nil
end

-- 删除单页缓存(滑动窗口淘汰用)
function M:removeStreamPageCache(bookCacheId, img_src)
    local dir = self:getStreamPageCacheDir(bookCacheId)
    if not (dir and H.is_str(img_src)) then
        return
    end
    local base = H.joinPath(dir, md5(img_src))
    for _, ext in ipairs(STREAM_PAGE_EXTS) do
        pcall(function()
            util.removeFile(base .. '.' .. ext)
        end)
    end
end

-- 清空流式页缓存目录(关卷时调用)
function M:clearStreamPageCache(bookCacheId)
    local dir = self:getStreamPageCacheDir(bookCacheId)
    if not dir then
        return
    end
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                util.removeFile(H.joinPath(dir, name))
            end
        end
        lfs.rmdir(dir)
    end)
end

-- 流式页预取是否进行中
function M:isStreamPagesPreloading()
    return TaskQueue.getChannel("stream", 1):hasTasks()
end

-- 后台预取流式漫画页(Async 子进程 + 流式落盘 + Range 断点续传)。
-- 已有预取任务运行时跳过(翻得快时退回同步下载, 与现状一致); 全程静默失败。
function M:preLoadStreamPages(bookCacheId, img_srcs)
    if not (H.is_str(bookCacheId) and H.is_tbl(img_srcs) and #img_srcs > 0) then
        return false
    end
    if self:isStreamPagesPreloading() == true then
        return false
    end
    -- 过滤已缓存的页
    local tasks = {}
    for _, src in ipairs(img_srcs) do
        if H.is_str(src) and src ~= "" and self:lookupStreamPageCache(bookCacheId, src) == nil then
            table.insert(tasks, src)
        end
    end
    if #tasks < 1 then
        return false
    end

    local cache_id = bookCacheId
    local dir = self:getStreamPageCacheDir(cache_id)
    H.checkAndCreateFolder(dir)

    TaskQueue.getChannel("stream", 1):push(function()
        if not self.httpReq then
            self.httpReq = require("Komga.HttpRequest")
        end
        local pStreamToFile = self.httpReq.pStreamToFile
        for i = 1, #tasks do
            local src = tasks[i]
            local base_no_ext = H.joinPath(dir, md5(src))
            -- 先流式落位到 .dl(扩展名下载后由 Content-Type 得知), 再改名为最终文件;
            -- 中断留下的 .part/.dl 下次按 Range 续传
            local ok, res = pcall(pStreamToFile, {
                url = src,
                dest = base_no_ext .. ".dl",
                timeout = 30,
                maxtime = 90
            })
            if ok and H.is_tbl(res) then
                local ext = (H.is_str(res.ext) and res.ext ~= "") and res.ext or "jpg"
                local final = base_no_ext .. "." .. ext
                os.remove(final)
                os.rename(base_no_ext .. ".dl", final)
            else
                logger.err('preload stream page failed:', tostring(src), tostring(res))
            end
        end
        return true
    end, nil, {timeout = PAGES_WATCHDOG_TIMEOUT, tag = "stream_pages"})
    return true
end

function M:getVolumeInfoCache(bookCacheId, number)
    local volume_data = self.dbManager:getVolumeInfo(bookCacheId, number)
    return volume_data
end

function M:getEpubChapterInfoCache(chapterId, number)
    local chapter_data = self.dbManager:getEpubChapterInfo(chapterId, number)
    return chapter_data
end

function M:getVolumeCount(bookCacheId)
    return self.dbManager:getVolumeCount(bookCacheId)
end

function M:getEpubChapterCount(chapterId)
    return self.dbManager:getEpubChapterCount(chapterId)
end

-- 按 bookId 取卷记录(跨卷续读: 把服务器"下一本书"映射回本地卷号/类型)
function M:getVolumeByBookId(bookCacheId, bookId)
    if not (H.is_str(bookCacheId) and H.is_str(bookId)) then
        return nil
    end
    return self.dbManager:getVolumeByBookId(bookCacheId, bookId)
end

-- Komga 原生"同系列下一本书"(/books/:id/next, 404=无下一本)。
-- 在线跨卷续读用; 任何失败(离线/超时/无下一本)返回 nil, 调用方静默回退
function M:getNextBookOnServer(bookId)
    if not (H.is_str(bookId) and NetworkMgr:isConnected()) then
        return nil
    end
    local response = self:komgaApi(function()
        -- GET /api/v1/books/:id/next(404 = 无下一本)
        return self.api:get("/api/v1/books/" .. bookId .. "/next", nil, {timeouts = {4, 6}})
    end, nil, 'getNextBook')
    if H.is_tbl(response) and response.type == 'SUCCESS' and H.is_tbl(response.body)
        and H.is_str(response.body.id) then
        return response.body
    end
    return nil
end

function M:getSeriesInfoCache(bookCacheId)
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:getSeriesInfo(bookShelfId, bookCacheId)
end

function M:getReadAheadVolumeCount(current_volume)
    return self.dbManager:getReadAheadVolumeCount(current_volume)
end

function M:manuallyPinToTop(bookCacheId, sortOrder)
    local bookShelfId = self:getServerPathCode()
    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        return wrap_response(nil, '参数错误')
    end
    self.dbManager:transaction(function()
        return self.dbManager:setSeriesTopStatus(bookShelfId, bookCacheId, sortOrder)
    end)()
    return wrap_response(true)
end

function M:getBookShelfCache()
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:getAllSeriesByUI(bookShelfId)
end

function M:getAllEpubChapters(volume)
    -- print("Get all chapters...",volume.bookId)
    if not H.is_str(volume.bookId) then
        return {}
    end
    
    -- 先从数据库获取 epub 章节信息
    local epub_chapters = self.dbManager:getAllEpubChapters(volume.bookId)
    
    -- 如果数据库中没有数据，尝试从 Komga 服务器获取
    if not H.is_tbl(epub_chapters) or #epub_chapters == 0 then
        local inforesponse = self:pGetEpubManifest(volume)
        
        if inforesponse.body ~= nil and inforesponse.body.toc ~= nil then
            volume.toc = inforesponse.body.toc
            volume.readingOrder = inforesponse.body.readingOrder
            self.dbManager:upsertEpubChapters(volume.book_cache_id,volume)
            epub_chapters = self.dbManager:getAllEpubChapters(volume.bookId)
        end
    end
    
    return epub_chapters
end

function M:autoPinToTop(bookCacheId, sortOrder)
    if 0 == sortOrder then
        -- If it is manually placed on top
        return wrap_response(true)
    end
    local bookShelfId = self:getServerPathCode()
    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        return wrap_response(nil, '参数错误')
    end
    self.dbManager:setSeriesTopStatus(bookShelfId, bookCacheId, nil, 0)
    return wrap_response(true)
end

function M:getLastReadVolumeIndex(bookCacheId)
    return self.dbManager:getLastReadVolumeIndex(bookCacheId)
end

function M:getSeriesLastUpdateTime(bookCacheId)
    return self.dbManager:getSeriesLastUpdateTime(bookCacheId)
end

function M:getVolumesCache(bookCacheId)
    local bookShelfId = self:getServerPathCode()

    local is_desc_sort = true
    if self.settings_data.data['chapter_sorting_mode'] == 'chapter_ascending' then
        is_desc_sort = false
    end
    local volume_data = self.dbManager:getAllVolumesByUI(bookCacheId, is_desc_sort)
    return volume_data
end

function M:getVolumesPlusCache(bookCacheId)
    local bookShelfId = self:getServerPathCode()
    local volume_data = self.dbManager:getAllVolumes(bookCacheId)
    return volume_data
end

function M:closeDbManager()
    self.dbManager:closeDB()
end

function M:cleanBookCache(book_cache_id)
    if self:isExtractingInBackground() == true then
        return wrap_response(nil, '有后台任务进行中，请等待结束或者重启 KOReader')
    end
    local bookShelfId = self:getServerPathCode()

    self.dbManager:clearSeries(bookShelfId, book_cache_id)

    local book_cache_path = H.getBookCachePath(book_cache_id)
    if book_cache_path and util.pathExists(book_cache_path) then

        ffiUtil.purgeDir(book_cache_path)

        return wrap_response(true)
    else
        return wrap_response(nil, '没有缓存')
    end
end

function M:cleanAllBookCaches()
    if self:isExtractingInBackground() == true then
        return wrap_response(nil, '有后台任务进行中，请等待结束或者重启 KOReader')
    end

    local bookShelfId = self:getServerPathCode()
    self.dbManager:clearAllSeries(bookShelfId)
    self:closeDbManager()
    local books_cache_dir = H.getTempDirectory()
    ffiUtil.purgeDir(books_cache_dir)
    H.getTempDirectory()
    self.settings_data.data.servers_history = {}
    self:saveSettings()
    return wrap_response(true)
end

function M:toggleVolumeRead(volume, volume_page, is_update_timestamp)
    local number = volume.number
    volume.isRead = not volume.isRead
    self.dbManager:updateVolumeIsRead(volume, volume_page ,volume.isRead, is_update_timestamp)
    return wrap_response(true)
end

function M:changeVolumeCache(volume)
    local number = volume.number
    local cacheFilePath = volume.cacheFilePath
    local book_cache_id = volume.book_cache_id
    local isDownLoaded = volume.isDownLoaded

    if isDownLoaded ~= true then

        local status, err = self:preLoadVolumes({volume}, 1)
        if status == true then
            return wrap_response(true)
        else
            return wrap_response(nil, '下载任务添加失败：' .. H.errorHandler(err))
        end
    else

        if util.fileExists(cacheFilePath) then
            pcall(function()
                require("docsettings"):open(cacheFilePath):purge()
            end)
            util.removeFile(cacheFilePath)
        end

        self.dbManager:transaction(function()
            self.dbManager:dynamicUpdateVolume(volume, {
                content = '_NULL',
                cacheFilePath = '_NULL'
            })
        end)()
        self:launchProcess(function()
            self:refreshVolumeContent(volume)
        end)
        return wrap_response(true)
    end
end

function M:runTaskWithRetry(taskFunc, timeoutMs, intervalMs)

    if not H.is_func(taskFunc) then
        dbg.log("taskFunc must be a function")
        return
    end

    if not H.is_num(timeoutMs) or timeoutMs <= 10 then
        dbg.log("timeoutMs must be > 10")
        return
    end

    if not H.is_num(intervalMs) or intervalMs <= 10 then
        dbg.log("intervalMs must be > 0")
        return
    end

    local startTime = os.time()

    local isTaskCompleted = false

    dbg.v("Task started at: %d", startTime)

    local function checkTask()

        local currentTime = os.time()
        if currentTime - startTime >= timeoutMs / 1000 then
            dbg.log("Task timed out!")
            return
        end

        if isTaskCompleted then
            dbg.v("Task completed!")
            return
        end

        local status, result = pcall(taskFunc)
        if not status then

            dbg.log("Task function error:", result)
            isTaskCompleted = false
        else

            isTaskCompleted = result
        end

        if isTaskCompleted then

            dbg.v("Task completed!")
        else

            dbg.v("Retrying in %d ms...", currentTime)

            UIManager:scheduleIn(intervalMs / 1000, checkTask)
        end
    end

    checkTask()
end

-- 分卷封面 URL（Komga: GET /api/v1/books/:bookId/thumbnail）
function M:getVolumeCoverUrl(bookId)
    local server_address = self.settings_data and self.settings_data.data and self.settings_data.data['server_address']
    if not (H.is_str(server_address) and H.is_str(bookId)) then
        return nil
    end
    return string.format("%s/api/v1/books/%s/thumbnail", server_address, bookId)
end

-- 分卷封面本地缓存路径（无扩展名，download_cover_img 会自动附加扩展名）
function M:getVolumeCoverCachePath(book_cache_id, number)
    if not (H.is_str(book_cache_id) and H.is_num(number)) then
        return nil
    end
    local resources_path = H.joinPath(H.getBookCachePath(book_cache_id), 'resources')
    return H.joinPath(resources_path, 'cover_v' .. tostring(number))
end

-- 探测已缓存的封面文件(扩展名由下载时的 Content-Type 决定)
local function findCachedCoverFile(path_no_ext)
    for _, ext in ipairs({"jpg", "jpeg", "png", "webp", "gif"}) do
        local p = string.format("%s.%s", path_no_ext, ext)
        if util.fileExists(p) then
            return p
        end
    end
    return nil
end

function M:download_cover_img(book_cache_id, cover_url, cover_path_no_ext)
    if not (H.is_str(book_cache_id) and H.is_str(cover_url)) then
        logger.err("download_cover_img parameter error")
        return
    end

    cover_path_no_ext = cover_path_no_ext or H.getCoverCacheFilePath(book_cache_id)

    -- 本地已有封面文件直接复用, 仅缺失时联网下载。
    -- 此前的 ?v=<lastModified> 版本比对: 服务器侧 lastModified 随书籍活动(进度/扫描)
    -- 变化会导致标记失配、图片未变也反复重下, 与"已有缓存不刷新"相悖, 故移除。
    -- (?v= 仍由 upsertSeries 附加在 URL 上, 仅作缓存未命中时的请求参数, 无害。)
    local cached = findCachedCoverFile(cover_path_no_ext)
    if cached then
        local _, image_filename = util.splitFilePathName(cached)
        return cached, image_filename
    end

    local img_src = cover_url
    local status, err = pGetUrlContent({
                        url = img_src,
                        timeout = 120,
                        maxtime = 120,
                        headers = {
                            ["user-agent"] = "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+",
                            ["X-API-Key"] = self:getApiKey()
                        }
                })
    if status and err and err['data'] then
        local cover_img_data = err['data']
        local path_no_ext = cover_path_no_ext or H.getCoverCacheFilePath(book_cache_id)

        local cover_img_path = string.format("%s.%s", path_no_ext, err['ext'] or "jpg")
        local dir, image_filename = util.splitFilePathName(cover_img_path)
        if not (dir and image_filename) then
            logger.err("download_cover_img name error: ",dir, image_filename)
            return
        end

        H.checkAndCreateFolder(dir)

        local cover_file_name = util.getSafeFilename(image_filename)
        if not cover_file_name then
            logger.err("download_cover_img getSafeFilename error")
            return
        end
        local safe_cover_img_path = H.joinPath(dir, image_filename)
        -- 原子写: 半写封面文件会被当作有效缓存
        local tmp_cover_path = safe_cover_img_path .. '.part'
        if util.writeToFile(cover_img_data, tmp_cover_path, true) then
            os.rename(tmp_cover_path, safe_cover_img_path)
        end

        return cover_img_path, image_filename
    else
        logger.err("download_cover_img error: ", cover_url, err)
    end
end

function M:quit_the_background_download_job()

    if util.fileExists(self.task_pid_file) then
        util.removeFile(self.task_pid_file)
    end
    TaskQueue.getChannel("volume", 1):clear()
    return true
end

function M:check_the_background_download_job(volume_down_tasks)

    if not H.is_tbl(volume_down_tasks) or #volume_down_tasks == 0 then
        return wrap_response(true)
    end

    if not self:isExtractingInBackground() then
        dbg.v("Inspector stopping...")
        if #volume_down_tasks ~= 1 then
            return wrap_response(true)
        else
            return {
                type = 'SUCCESS',
                body = {
                    message = '下载任务已经切换到后台'
                }
            }
        end
    end

    local total_num = #volume_down_tasks
    local downloaded_num = 0

    local target_ages = {}
    local book_cache_id = volume_down_tasks[1].book_cache_id

    for i = 1, total_num do
        local task_volume = volume_down_tasks[i]
        if task_volume and task_volume.number ~= nil then
            table.insert(target_ages, task_volume.number)
        end
    end

    local status, err = pcall(function()
        return self.dbManager:getVolumesDownloadProgress(book_cache_id, target_ages)
    end)

    if status then
        downloaded_num = tonumber(err)
    end

    dbg.v('Download progress num:', downloaded_num)
    if downloaded_num == 0 then

        return {
            type = 'PENDING',
            body = {
                type = 'INITIALIZING',
                total = total_num,
                downloaded = downloaded_num
            }
        }
    elseif downloaded_num < total_num then
        return {
            type = 'PENDING',
            body = {
                total = total_num,
                downloaded = downloaded_num
            }
        }
    else

        return wrap_response(true)
    end

end

function M:isExtractingInBackground(task_pid)
    -- 以 volume 通道状态为准(通道任务自带超时, 不会永久卡住);
    -- pid 文件仅作为上个版本崩溃遗留的兜底: 超过 24h 视为孤儿并清理
    if TaskQueue.getChannel("volume", 1):hasTasks() then
        return true
    end
    local pid_file = self.task_pid_file
    if util.fileExists(pid_file) then
        if H.isFileOlderThan(pid_file, 24 * 60 * 60) then
            util.removeFile(pid_file)
        else
            return true
        end
    end
    return false
end

function M:after_reader_chapter_show(volume)

    local number = volume.number
    local cache_file_path = volume.cacheFilePath
    local book_cache_id = volume.book_cache_id
    -- EPUB 分卷打开不标记已读: isRead 在 refreshVolumeMetadata 被当作"整卷满进度 100%"。
    -- 打开即标已读会把"没读完的卷"显示成 100%(用户反馈)。EPUB 整卷读完才标记,
    -- 由 saveBookProgression 按服务器空间整卷比例(totalProgression)>=99.9% 统一处理。
    -- 漫画单文件卷保持原"打开即已读"行为。
    local is_epub = volume.mediaType == "EPUB"
        or (H.is_str(volume.cacheFilePath) and volume.cacheFilePath:match("%.x?html$") ~= nil)

    local status, err = pcall(function()

        local update_state = {}

        if volume.isDownLoaded ~= true then
            update_state.content = 'downloaded'
            update_state.cacheFilePath = cache_file_path
        end

        if not is_epub and volume.isRead ~= true then
            update_state.isRead = true
            update_state.lastUpdated = {
                _set = "= strftime('%s', 'now')"
            }
        end

        -- update_state 可能为空(EPUB 且已下载), 空更新直接跳过
        if next(update_state) then
            self.dbManager:transaction(function()
                self.dbManager:dynamicUpdateVolume(volume, update_state)
            end)()
        end

    end)

    if not status then
        dbg.log('updating the read download flag err:', tostring(err))
    end

    if cache_file_path ~= nil then

        local cache_name = select(2, util.splitFilePathName(cache_file_path)) or ''
        local _, extension = util.splitFileNameSuffix(cache_name)

        if extension and volume.cacheExt ~= extension then
            local status, err = pcall(function()

                local bookShelfId = self:getServerPathCode()
                self.dbManager:transaction(function()
                    return self.dbManager:dynamicUpdateSeries({
                        book_cache_id = book_cache_id,
                        bookShelfId = bookShelfId,
                    }, {
                        cacheExt = extension
                    })
                end)()
            end)

            if not status then
                dbg.log('updating cache ext err:', tostring(err))
            end
        end
    end

    if volume.isRead ~= true and NetworkMgr:isConnected() then
        if is_epub then
            -- EPUB: 预下载当前卷的后几页(内部章节), 翻到时即开; 全程静默
            self:preLoadEpubChapters(volume, 3)
        else
            -- 漫画: 预下载后续整卷(cbz 单文件较大, 只预下载 1 卷)
            local complete_count = self:getReadAheadVolumeCount(volume)
            if complete_count < 40 then
                local preDownloadNum = 3
                if volume.cacheExt and volume.cacheExt == 'cbz' then
                    preDownloadNum = 1
                end
                self:preLoadVolumes(volume, preDownloadNum)
            end
        end
    end

    if not is_epub then
        volume.isRead = true
    end
    volume.isDownLoaded = true
end

function M:downloadVolume(volume, message_dialog)

    local bookCacheId = volume.book_cache_id
    local number = volume.number
    local volume_book_id = volume.bookId
    -- print(bookCacheId, number, volume_book_id)

    if self.dbManager:isVolumeDownloading(bookCacheId, volume_book_id, number) == true and self:isExtractingInBackground() == true then
        return wrap_response(nil, "此章节后台下载中, 请等待...")
    end

    local status, err = pcall(function()
        -- print("Download 1.")
        return self:pDownloadVolume(volume, message_dialog)
    end)
    if not status then
        logger.err('下载章节失败：', err)
        return wrap_response(nil, "下载章节失败：" .. H.errorHandler(err))
    end
    return wrap_response(err)

end

function M:getServerPathCode()
    if self.settings_data.data['server_address_md5'] == nil then
        local server_address_md5 = socket_url.parse(self.settings_data.data['server_address']).host
        self.settings_data.data['server_address_md5'] = md5(server_address_md5)
        self:saveSettings()
    end
    return tostring(self.settings_data.data['server_address_md5'])
end

function M:getSettings()
    return self.settings_data.data
end

-- 当前生效的 X-API-Key: 设置项 api_key, 未设置/为空时回落代码预设值
function M:getApiKey()
    local key = self.settings_data and self.settings_data.data and self.settings_data.data.api_key
    if H.is_str(key) and key ~= '' then
        return key
    end
    return Config.DEFAULT_API_KEY
end

-- 设置 X-API-Key(立即持久化生效)
function M:setApiKey(new_api_key)
    if not H.is_str(new_api_key) or new_api_key == '' then
        return wrap_response(nil, 'API Key 不能为空')
    end
    if not self.settings_data or not self.settings_data.data then
        return wrap_response(nil, '设置未初始化')
    end
    self.settings_data.data.api_key = new_api_key
    self.settings_data:flush()
    return wrap_response(self.settings_data.data)
end

-- ---------------------------------------------------------------------------
-- 多服务器配置(场景: 家里局域网地址 ↔ 外网域名 一键切换)
-- 配置存于设置项 server_profiles = { {name, server_address, api_key}, ... };
-- 当前生效值仍为 server_address/api_key 两个字段(向后兼容)。
-- ---------------------------------------------------------------------------
function M:getServerProfiles()
    if not self.settings_data then
        return {}
    end
    local profiles = self.settings_data.data.server_profiles
    if not H.is_tbl(profiles) then
        return {}
    end
    return profiles
end

-- 保存当前生效的服务器为一份具名配置(同名覆盖)
function M:saveServerProfile(name)
    if not (H.is_str(name) and name ~= "") then
        return wrap_response(nil, '配置名不能为空')
    end
    local data = self.settings_data and self.settings_data.data
    if not (H.is_tbl(data) and H.is_str(data.server_address)) then
        return wrap_response(nil, '设置未初始化')
    end
    local profiles = H.is_tbl(data.server_profiles) and data.server_profiles or {}
    local entry = {
        name = name,
        server_address = data.server_address,
        api_key = H.is_str(data.api_key) and data.api_key or "",
    }
    local replaced = false
    for i, p in ipairs(profiles) do
        if p.name == name then
            profiles[i] = entry
            replaced = true
            break
        end
    end
    if not replaced then
        table.insert(profiles, entry)
    end
    data.server_profiles = profiles
    self.settings_data:flush()
    return wrap_response(profiles)
end

-- 删除具名配置
function M:deleteServerProfile(name)
    if not H.is_str(name) then
        return wrap_response(nil, '参数错误')
    end
    local data = self.settings_data and self.settings_data.data
    local profiles = H.is_tbl(data and data.server_profiles) and data.server_profiles or {}
    local kept = {}
    for _, p in ipairs(profiles) do
        if p.name ~= name then
            table.insert(kept, p)
        end
    end
    data.server_profiles = kept
    self.settings_data:flush()
    return wrap_response(kept)
end

-- 切换到具名配置(立即生效: 重建 REST 客户端, 无需重启)
function M:switchServerProfile(name)
    if not H.is_str(name) then
        return wrap_response(nil, '参数错误')
    end
    local data = self.settings_data and self.settings_data.data
    if not H.is_tbl(data) then
        return wrap_response(nil, '设置未初始化')
    end
    local target
    for _, p in ipairs(self:getServerProfiles()) do
        if p.name == name then
            target = p
            break
        end
    end
    if not H.is_tbl(target) then
        return wrap_response(nil, '配置不存在: ' .. name)
    end
    -- 地址无变化时仅同步 key, 避免无谓的客户端重建
    local address_changed = (data.server_address ~= target.server_address)
    data.server_address = target.server_address
    if H.is_str(target.api_key) and target.api_key ~= "" then
        data.api_key = target.api_key
    end
    -- 书架分组键按主机 md5 派生, 换服务器必须失效重算
    data.server_address_md5 = nil
    self.settings_data:flush()
    if address_changed then
        self:loadApiClient()
    end
    return wrap_response(self.settings_data.data)
end

function M:saveSettings(settings)
    if H.is_tbl(settings) and H.is_str(self.settings_data.data.server_address) then
        if not H.is_str(settings.server_address) or not H.is_str(settings.chapter_sorting_mode) then
            return wrap_response(nil, '参数校检错误，保存失败')
        end
        self.settings_data.data = settings
    end
    self.settings_data:flush()
    self.settings_data = LuaSettings:open(H.getUserSettingsPath())
    return wrap_response(true)
end

function M:setEndpointUrl(new_setting_url)

    if not H.is_str(new_setting_url) or new_setting_url == '' then
        return wrap_response(nil, '参数校检错误，保存失败')
    end

    local parsed = socket_url.parse(new_setting_url)
    if not parsed then
        return wrap_response(nil, '地址不合规则，请检查')
    end

    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return wrap_response(nil, '不支持的协议，请检查')
    end

    if not parsed.host or parsed.host == "" then
        return wrap_response(nil, "没有主机名")
    end

    if parsed.port then
        local port_num = tonumber(parsed.port)
        if not port_num or port_num < 1 or port_num > 65535 then
            return wrap_response(nil, "端口号不正确")
        end
    end

    local settings = self.settings_data.data
    if parsed.user and parsed.user ~= "" then
        self.settings_data.data.reader3_un = util.urlDecode(parsed.user)
        self.settings_data.data.reader3_pwd = util.urlDecode(parsed.password)
    end

    local clean_url = socket_url.build(parsed)
    local old_setting_url = self.settings_data.data.setting_url
    -- dbg.log("server_address:", clean_url)
    self.settings_data.data.server_address = clean_url
    self.settings_data.data.setting_url = new_setting_url
    self.settings_data.data.server_address_md5 = md5(parsed.host)
    if not H.is_tbl(self.settings_data.data.servers_history) or not self.settings_data.data.servers_history[1] then
        self.settings_data.data.servers_history = {}
    end

    local function updateHistoryItem(history_table, item, max_size)
        local removed_old = false
        for i = #history_table, 1, -1 do
            if history_table[i] == item then
                table.remove(history_table, i)
                removed_old = true
                break
            end
        end
        table.insert(history_table, item)
        if max_size and max_size > 0 then
            while #history_table > max_size do
                table.remove(history_table, 1)
            end
        end
    end
    
    --添加历史记录
    updateHistoryItem(self.settings_data.data.servers_history, old_setting_url, 10)

    self:saveSettings()

    -- 服务器地址已变更, 重建 REST 客户端
    self:loadApiClient()

    return wrap_response(self.settings_data.data)
end

function M:onExitClean()
    dbg.v('Backend call onExitClean')

    if util.fileExists(self.task_pid_file) then
        util.removeFile(self.task_pid_file)
    end

    self:closeDbManager()
    collectgarbage()
    collectgarbage()
    return true
end

require("ffi/__gc")(M, {
    __gc = function(t)
        M:onExitClean()
    end
})

return M