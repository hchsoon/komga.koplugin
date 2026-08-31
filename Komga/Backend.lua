--[[
Komga/Backend.lua — Komga HTTP 层与业务编排

封装 Komga 服务器的 HTTP 请求(apiClient 由 KomgaSpec 的 Spore 定义生成)与本地缓存编排,
是插件对外的主要服务入口。

━━━ 名词对照(重要: 插件内部命名与 Komga 官方名词不同)━━━
  Komga 官方         本层/DB 命名       主键                        说明
  ---------------    -----------------  --------------------------  ---------------------------
  Series              series             bookCacheId                书架上的一个"系列"
  Book(单卷)          volume             (bookCacheId, number)  系列内的一个"分卷", 服务器 ID = bookId
  Chapter(书内章)     epub_chapter       (chapterId, number)   EPUB 书内部章节, 仅 EPUB

━━━ 命名约定 ━━━
  * 本文件(与 BookInfoDB / KomgaModel)统一用 series / volume / epub_chapter 描述三级层级。
  * self.apiClient:* 与 KomgaSpec.lua 的方法名是 Komga HTTP 端点, 与 Komga 官方命名一致,
    不参与上述改名(如 apiClient:getChapterInfo = GET /books/{id}/progress, apiClient:saveBookProgress = PUT)。
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

-- 太旧版本缺少这个函数
if not dbg.log then
    dbg.log = logger.dbg
end

local M = {
    dbManager = {},
    settings_data = nil,
    task_pid_file = nil,
    apiClient = nil,
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

local function get_img_src(html)
    if type(html) ~= "string" then
        return {}
    end

    local img_sources = {}
    -- local img_pattern = "<img[^>]*src%s*=%s*([\"']?)([^%s\"'>]+)%1[^>]*>"
    local img_pattern = '<img[^>]-src%s*=%s*["\']?([^"\'>%s]+)["\']?[^>]*>'

    for src in html:gmatch(img_pattern) do
        if src and src ~= "" then
            table.insert(img_sources, src)
        end
    end

    return img_sources
end

local function get_url_extension(url)
    if type(url) ~= "string" or url == "" then
        return ""
    end
    local parsed = socket_url.parse(url)
    local path = parsed and parsed.path
    if not path or path == "" then
        return ""
    end
    path = socket_url.unescape(path):gsub("/+$", "")

    local filename = path:match("([^/]+)$") or ""
    local ext = filename:match("%.([%w]+)$")
    -- logger.info(path, filename, ext)
    return ext and ext:lower() or "", filename
end

-- socket.url.escape util.urlEncode + / ? = @会被编码
-- 处理 reader3 服务器版含书名路径有空格等问题
local function custom_urlEncode(str)

    if str == nil then
        return ""
    end
    local segment_chars = {
        ['-'] = true,
        ['.'] = true,
        ['_'] = true,
        ['~'] = true,
        [','] = true,
        ['!'] = true,
        ['*'] = true,
        ['\''] = true,
        ['('] = true,
        [')'] = true,
        ['/'] = true,
        ['?'] = true,
        ['&'] = true,
        ['='] = true,
        [':'] = true,
        ['@'] = true
    }

    return string.gsub(str, "([^A-Za-z0-9_])", function(c)
        if segment_chars[c] then
            return c
        else
            return string.format("%%%02X", string.byte(c))
        end
    end)
    --[[
    -- socket_url.build_path(socket_url.parse_path(str))
    return str:gsub("([^%w%-%.%_%~%!%$%&%'%(%)%*%+%,%;%=%:%@%/%?])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    ]]
end

local function convertToGrayscale(image_data)
    local Png = require("Komga/Png")
    return Png.processImage(Png.toGrayscale, image_data, 1)

end

local function pGetUrlContent(options)
    if not M.httpReq then 
        M.httpReq = require("Komga.HttpRequest")
    end
    return M.httpReq(options, true)
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

function M:loadSpore()
    local Spore = require("Spore")
    local komgaSpec = require("Komga/KomgaSpec")
    self.apiClient = Spore.new_from_lua(komgaSpec, {
        base_url = (self.settings_data.data.server_address or Config.DEFAULT_SERVER_ADDRESS) .. '/'
    })

    package.loaded["Spore.Middleware.FormatEpubJSON"] = {}

    require("Spore.Middleware.FormatEpubJSON").call = function(_args,req)
        local decode = require'dkjson'.decode
        local encode = require'dkjson'.encode
        local type = type
        local find = string.find
        local raises = require'Spore'.raises
        local spore = req.env.spore
        local payload = spore.payload
        -- 含 Readium 媒体类型: Komga 的 /positions 与 /progression 只产生
        -- application/vnd.readium.position-list+json / application/vnd.readium.progression+json,
        -- Accept 里没有会返回 406 Not Acceptable(EPUB 进度同步的读取/上报都会用到)
        local contenttype = 'application/json,application/webpub+json,' ..
            'application/vnd.readium.position-list+json,application/vnd.readium.progression+json'
        if payload and type(payload) == 'table' then
            spore.payload = encode(payload)
            req.headers['content-type'] = "application/json"
        end
        req.headers['accept'] = contenttype

        return  function (res)
                    local header = res.headers and res.headers['content-type']
                    local body = res.body
                    if header and (find(header, 'application/json', 1, true) or find(header, 'application/webpub+json', 1, true)
                        or find(header, 'application/vnd.readium.position-list+json', 1, true)
                        or find(header, 'application/vnd.readium.progression+json', 1, true)) and type(body) == 'string' and body ~= '' then
                        local r, _, msg = decode(body)
                        if r then
                            res.body = r
                        else
                            if spore.errors then
                                spore.errors:write(msg, "\n")
                                spore.errors:write(body, "\n")
                            end
                            if res.status == 200 then
                                raises(res, msg)
                            end
                        end
                    end
                    return res
                end
    end

    package.loaded["Spore.Middleware.ForceJSON"] = {}
    require("Spore.Middleware.ForceJSON").call = function(args, req)
        -- req.env.HTTP_USER_AGENT = ""
        req.headers = req.headers or {}
        -- req.headers["X-API-Key"] = self:getApiKey()
        req.headers["user-agent"] =
            "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+"
        return function(res)
            res.headers = res.headers or {}
            res.headers["content-type"] = 'application/json'
            return res
        end
    end
    package.loaded["Spore.Middleware.KomgaAuth"] = {}
    require("Spore.Middleware.KomgaAuth").call = function(args, req)
        local spore = req.env.spore

        -- X-API-Key 来自设置(api_key), 未设置时回落到 Config 预设值
        req.headers["X-API-Key"] = self:getApiKey()
        req.headers["user-agent"] = "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+"

        return function(res)
            return res
        end
    end
end

function M:initialize()
    self.task_pid_file = H.getTempDirectory() .. '/task.pid.lua'
    -- 阅读中"后几页"预下载(EPUB 内部章节)的独立 pid 文件, 与整卷预下载互不阻塞
    self.pages_pid_file = H.getTempDirectory() .. '/pages.pid.lua'
    -- 流式漫画页预取的 pid 文件
    self.stream_pages_pid_file = H.getTempDirectory() .. '/stream_pages.pid.lua'
    self.settings_data = self:getLuaConfig(H.getUserSettingsPath())

    -- 兼容历史版本 <1.038
    if not self.settings_data.data.setting_url and not self.settings_data.data.reader3_un and
        H.is_str(self.settings_data.data.komga_server) then
        self.settings_data.data.setting_url = self.settings_data.data.komga_server
    end
    -- <1.049
    if not self.settings_data.data.server_address and H.is_str(self.settings_data.data.komga_server) then
        self.settings_data.data.server_address = self.settings_data.data.komga_server
        self.settings_data.data.komga_server = nil
        self.settings_data:flush()
    end

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
    -- 兼容旧设置文件: 没有 api_key 键时补默认值
    if not H.is_str(self.settings_data.data.api_key) then
        self.settings_data.data.api_key = Config.DEFAULT_API_KEY
        self.settings_data:flush()
    end

    self:loadSpore()

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

function M:komgaSporeApi(requestFunc, callback, opts, logName)
    local socketutil = require("socketutil")

    local server_address = self.settings_data.data['server_address']
    logName = logName or 'komgaSporeApi'
    opts = opts or {}

    local isServerOnly = opts.isServerOnly
    local timeouts = opts.timeouts
    if not H.is_tbl(timeouts) or not H.is_num(timeouts[1]) or not H.is_num(timeouts[2]) then
        timeouts = {8, 12}
    end

    self.apiClient:reset_middlewares()
    self.apiClient:enable("KomgaAuth")
    -- self.apiClient:enable("Format.JSON")
    self.apiClient:enable("FormatEpubJSON")
    self.apiClient:enable("ForceJSON")
    -- 单次轮询 timeout,总 timeout
    socketutil:set_timeout(timeouts[1], timeouts[2])
    local status, res = pcall(requestFunc)
    socketutil:reset_timeout()

    if not status then
        local err_msg = H.errorHandler(res)
        if err_msg == "wantread" then
            err_msg = '连接超时'
        end
        logger.err(logName, 'requestFunc err:', tostring(res))
        return wrap_response(nil, 'requestFunc: ' .. err_msg)
    end

    -- 204 No Content（如 saveVolumeProgress）: 服务器确认成功但无响应体，视为成功
    if H.is_tbl(res) and res.status == 204 then
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

    
    if H.is_tbl(res.body) and res.body.content then
        if H.is_func(callback) then
            return callback(res.body)
        else
            return wrap_response(res.body.content)
        end
    elseif H.is_tbl(res.body) then --and res.body.readProgress then
        -- print("Res.body is ...",res.body)
        return wrap_response(res.body)
    else
        -- print_table(res.body.content,"  ")
        -- print(H.is_tbl(res.body))
        -- print(res.body.isSuccess)
        -- print(res.body.content)
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
    return self:komgaSporeApi(function()
        return self.apiClient:getChapterList({
            condition =  {
                allOf = {
                  {
                    seriesId = {
                        operator = "is",
                        value = series.cache_id
                    }
                  }
                }
            },
            size = 1000
        })
    end, function(response)

        local status, err = pcall(function()
            return self.dbManager:upsertVolumes(book_cache_id, response.content)
        end)

        if not status then
            dbg.log('refreshVolumesCache数据写入', tostring(err))
            return wrap_response(nil, '数据写入出错，请重试')
        end
        return wrap_response(true)
    end, {
        timeouts = {10, 12}
    }, 'refreshVolumesCache')
end

function M:refreshLibraryCache(last_refresh_time)

    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshVolumesCache')
        return wrap_response(nil, '处理中')
    end

    return self:komgaSporeApi(function()
        -- data=bookinfos
        dbg.v('Start refreshing library')
        logger.warn('Start refreshing library')
        local response =  self.apiClient:getBookShelf({
            fullTextSearch = "",
            size=1000
        })
        return response
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
    end, {
        timeouts = {8, 12}
    }, 'refreshLibraryCache')
end

function M:pGetEpubManifest(volume)
    local bookId = volume.bookId

    if not H.is_str(bookId) then
        return wrap_response(nil, 'GetChapterContent参数错误')
    end

    return self:komgaSporeApi(function()
        -- data=string
        -- return self.apiClient:getBookContent({
        --     bookId = bookId,
        --     pageNumber = 1,
        -- })
        return self.apiClient:getEpubManifest({
            bookId = bookId,
            -- pageNumber = 0,
        },{headers = {
                ["X-Accept"] = "application/webpub+json"
            }})
    end, nil, {
        timeouts = {18, 25}
    }, 'getEpubManifest')
end

function M:getVolumeReadProgress(volume)

    if not (H.is_str(volume.name) and H.is_str(volume.url)) then
        return wrap_response(nil, '参数错误')
    end

    return self:komgaSporeApi(function()
        return self.apiClient:getChapterInfo({
            bookId = volume.bookId
            -- name = volume.name,
            -- author = volume.author or '',
            -- durChapterPos = 0,
            -- durChapterIndex = number,
            -- durChapterTime = time.to_ms(time.now()),
            -- durChapterTitle = volume.title or '',
            -- index = number,
            -- url = volume.url,
            -- v = os.time()
        })
    end, nil, {
        timeouts = {3, 5}
    }, 'getVolumeReadProgress')

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
    return self:komgaSporeApi(function()
        return self.apiClient:saveBookProgress({
            bookId = volume.bookId,
            page = volume.current_page,
            completed = finish
            -- name = volume.name,
            -- author = volume.author or '',
            -- durChapterPos = 0,
            -- durChapterIndex = number,
            -- durChapterTime = time.to_ms(time.now()),
            -- durChapterTitle = volume.title or '',
            -- index = number,
            -- url = volume.url,
            -- v = os.time()
        })
    end, nil, {
        timeouts = {3, 5}
    }, 'saveVolumeProgress')

end

-- EPUB(非 Divina)进度走 Readium Progression API: GET /progression 返回 R2Progression
-- {modified, device, locator{locations{progression, position, totalProgression}}}
function M:getBookProgression(bookId)
    if not H.is_str(bookId) then
        return wrap_response(nil, '参数错误')
    end
    local r = self:komgaSporeApi(function()
        return self.apiClient:getBookProgression({
            bookId = bookId
        })
    end, nil, {
        timeouts = {3, 5}
    }, 'getBookProgression')
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
    local r = self:komgaSporeApi(function()
        return self.apiClient:updateBookProgression({
            bookId = upload.bookId,
            modified = os.date("!%Y-%m-%dT%H:%M:%SZ", ts),
            device = { id = "koreader", name = "KOReader" },
            locator = upload.locator,
        })
    end, nil, {
        timeouts = {3, 5}
    }, 'saveBookProgression')
    return r
end

-- EPUB: 全书位置查找表(totalProgression 单调递增), 供 frac→locator 映射
function M:getBookPositions(bookId)
    if not H.is_str(bookId) then
        return wrap_response(nil, '参数错误')
    end
    local r = self:komgaSporeApi(function()
        return self.apiClient:getBookPositions({
            bookId = bookId
        })
    end, nil, {
        timeouts = {3, 5}
    }, 'getBookPositions')
    return r
end

function M:getBookSourcesList()
    return self:komgaSporeApi(function()
        return self.apiClient:getBookSources({
            simple = 1,
            v = os.time()
        })
    end, nil, {
        timeouts = {15, 20},
        isServerOnly = true
    }, 'getBookSourcesList')
end

function M:refreshVolumeContent(volume)

    local url = volume.url
    local number = volume.number
    local down_number = volume.number

    if not H.is_str(url) or not H.is_num(down_number) then
        return wrap_response(nil, '刷新章节出错')
    end


    self:komgaSporeApi(function()
        return self.apiClient:getBookContent({
            url = url,
            index = down_number,
            refresh = 1,
            v = os.time()
        })
    end, nil, {
        timeouts = {10, 20}
    }, 'GetChapterContent')
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
    return self:komgaSporeApi(function()
        -- data.list data.lastindex
        return self.apiClient:searchBookSource({
            url = url,
            bookSourceGroup = '',
            lastIndex = lastIndex,
            searchSize = searchSize,
            v = os.time()
        })

    end, nil, {
        timeouts = {70, 80},
        isServerOnly = true
    }, 'searchBook')

end

function M:searchBook(search_text, bookSourceUrl, concurrentCount)
    if not (H.is_str(search_text) and search_text ~= '' and H.is_str(bookSourceUrl)) then
        return wrap_response(nil, "输入参数错误")
    end
    concurrentCount = concurrentCount or 32
    return self:komgaSporeApi(function()
        -- data = bookinfolist
        return self.apiClient:searchBook({
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            bookSourceUrl = bookSourceUrl,
            lastIndex = -1,
            page = 1,
            v = os.time()
        })
    end, nil, {
        timeouts = {20, 30},
        isServerOnly = true
    }, 'searchBook')
end

function M:searchBookMulti(search_text, lastIndex, searchSize, concurrentCount)

    if not H.is_str(search_text) or search_text == '' then
        return wrap_response(nil, "输入参数错误")
    end

    lastIndex = lastIndex or -1
    searchSize = searchSize or 20
    concurrentCount = concurrentCount or 32
    return self:komgaSporeApi(function()
        -- data.list data.lastindex
        return self.apiClient:searchBookMulti({
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            lastIndex = lastIndex,
            searchSize = searchSize,
            v = os.time()
        })
    end, nil, {
        timeouts = {60, 80},
        isServerOnly = true
    }, 'searchBook')
end

function M:deleteBook(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.url)) then
        return wrap_response(nil, "输入参数错误")
    end

    return self:komgaSporeApi(function()
        -- {"isSuccess":true,"errorMsg":"","data":"删除书籍成功"}
        return self.apiClient:deleteBook({

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
        })
    end, nil, {
        timeouts = {6, 8}
    }, 'deleteBook')
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
local function splitParagraphsPreserveBlank(text)
    if not text or text == "" then
        return {}
    end

    text = text:gsub("\r\n?", "\n"):gsub("\n+", function(s)
        return (#s >= 2) and "\n\n" or s
    end)

    -- 兼容: 2半角+1全角,Koreader .txt auto add a indentEnglish
    local indentChinese = "\u{0020}\u{0020}\u{3000}"
    local indentEnglish = "\u{0020}\u{0020}"
    local paragraphs = {}
    local allow_split = true
    local buffer = ""
    local prefix = nil
    local lines = {}

    -- 保留空行，清理前后空白
    for line in util.gsplit(text, "\n", false, true) do
        line = M:utf8_trim(line)
        table.insert(lines, line)
    end

    -- 常见标点符号判断
    local function isPunctuation(char)
        if not char then
            return false
        end

        local punctuationSet = {
            ["\u{0021}"] = true,
            ["\u{002C}"] = true,
            ["\u{002E}"] = true,
            ["\u{003A}"] = true,
            ["\u{003B}"] = true,
            ["\u{003F}"] = true,
            ["\u{3001}"] = true,
            ["\u{3002}"] = true,
            ["\u{FF0C}"] = true,
            ["\u{FF0E}"] = true,
            ["\u{FF1A}"] = true,
            ["\u{FF1B}"] = true,
            ["\u{FF1F}"] = true,
            ["\u{2026}"] = true,
            ["\u{00B7}"] = true,
            ["\u{2022}"] = true,
            ["\u{FF5E}"] = true
        }

        if punctuationSet[char] then
            return true
        end

        local code = ffiUtil.utf8charcode(char)
        if not code then
            return false
        end

        return (code >= 0x2000 and code <= 0x206F) or (code >= 0x3000 and code <= 0x303F) or
                   (code >= 0xFF00 and code <= 0xFFEF)
    end

    for i, line in ipairs(lines) do

        if buffer and buffer ~= "" then
            line = table.concat({buffer, line or ""})
            buffer = ""
        end

        if line == "" then
            table.insert(paragraphs, line)
        else
            if not prefix then
                prefix = util.hasCJKChar(line:sub(1, 9)) and indentChinese or indentEnglish
                -- logger.dbg('isChinese:', prefix == indentChinese)
            end

            local line_len = #line
            local word_end = line:match(util.UTF8_CHAR_PATTERN .. "$")
            local next_word_start = (lines[i + 1] or ""):match(util.UTF8_CHAR_PATTERN)
            local word_end_isPunctuation = isPunctuation(word_end)

            -- 中文段末没有标点不允许换行, 避免触发koreader的章节标题渲染规则
            if prefix == indentChinese and (not word_end_isPunctuation or line_len < 7) then
                allow_split = false
            else
                allow_split = util.isSplittable and util.isSplittable(word_end, next_word_start, word_end) or true
            end

            -- logger.dbg(i,line_len,word_end,next_word_start, word_end_isPunctuation, allow_split)

            if not allow_split and i < #lines then

                if prefix == indentEnglish and not word_end_isPunctuation and not isPunctuation(next_word_start) then
                    -- 非CJK两个单词间补充个空格
                    line = line .. "\u{0020}"
                end
                buffer = table.concat({buffer, line})
            else
                table.insert(paragraphs, prefix .. line)
            end
        end
    end

    lines = nil

    return paragraphs
end

local function has_img_tag(text)
    if type(text) ~= "string" then
        return false
    end
    return text:find("<[iI][mM][gG][^>]*>") ~= nil
end

local function has_other_content(text)
    if type(text) ~= "string" then
        return false
    end
    local without_img = text:gsub("<[iI][mM][gG][^>]+>", ""):gsub("\u{3000}", "")
    return without_img:find("%S") ~= nil
end

local function get_chapter_content_type(txt, first_line)
    if type(txt) ~= "string" then
        return 1
    end
    local page_type

    if not first_line or type(first_line) ~= 'string' then
        first_line = (string.match(txt, "([^\n]*)\n?") or txt):lower()
    else
        first_line = first_line:lower()
    end

    -- logger.info("优先检查 XHTML 特征",get_url_extension("/test.epub/index/OPS/Text/Chapter79.xhtml"))
    if string.match(first_line, "%.x?html$") then
        page_type = 4
    else

        local has_img_in_first_line = string.find(first_line, "<img", 1, true)
        if has_img_in_first_line then
            local is_other_content = has_other_content(txt)
            page_type = is_other_content and 3 or 2
        elseif has_img_tag(txt) then
            local is_other_content = has_other_content(txt)
            page_type = is_other_content and 3 or 2
        else
            page_type = 1
        end
    end
    return page_type
end

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

-- 生成章节链接匹配关键字: 取文件基名(去扩展名, 小写)。
-- epub 内部章节文件通常唯一命名(如 Section0031.xhtml), 而 DB 里 url 是
-- 完整资源 URL、xhtml 内部 href 是相对路径, 只有基名是两边一致的, 故按基名匹配。
local normalize_rel_href = function(href)
    if type(href) ~= "string" or href == "" then
        return nil
    end
    -- 全 URL(如 Komga /resource/ 资源地址)只取路径部分
    local u = href:gsub("^%a[%w+.-]*://[^/]+/", "")
    u = u:gsub("[?#].*", "")
    local name = u:match("([^/]+)$")
    if not name then
        return nil
    end
    name = name:gsub("%.x?html?$", "")
    if name == "" then
        return nil
    end
    return name:lower()
end

-- 缓存的章节文件名: <安全书名>-<bookId>-<number>.<xhtml|html>, 与 H.getVolumeCacheFilePath 生成的路径一致
-- (扩展名随源页面 URL, 缺省 xhtml)
local get_cached_chapter_filename = function(bookId, number, book_name, ext)
    book_name = util.getSafeFilename(book_name or "")
    ext = ext or "xhtml"
    return string.format("%s-%s-%s.%s", book_name, bookId, number, ext)
end

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

local function plain_text_replace(text, pattern, replacement, count)
    text = tostring(text or "")
    pattern = tostring(pattern or "")
    replacement = tostring(replacement or "")

    if pattern == "" then
        return text
    end
    -- 转义 Lua 模式特殊字符
    local escaped_pattern = pattern:gsub("([%%().%+-*?[%]^$])", "%%%1")
    -- 转义替换字符串中的 %
    local safe_replacement = replacement:gsub("%%", "%%%%")
    return text:gsub(escaped_pattern, safe_replacement, count)
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

-- 后台任务看门狗参数(须声明在使用点之前)
local TASK_WATCHDOG_INTERVAL = 30 -- 轮询间隔(秒)
local TASK_WATCHDOG_TIMEOUT = 600 -- 整卷预下载硬超时(秒)
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

    local task_pid, err = self:launchProcess(function()

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
        dbg.log("Multithreaded task creation failed:" .. tostring(err))
        pcall(function()
            Device:enableCPUCores(1)
            UIManager:allowStandby()
        end)
        return false, "Background download task failed" .. tostring(err)
    else

        dbg.v("Task started. PID:" .. tostring(task_pid))

        self:startTaskWatchdog(task_pid, self.task_pid_file, TASK_WATCHDOG_TIMEOUT)

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

end

-- ---------------------------------------------------------------------------
-- 后台子进程看门狗
-- 子进程卡死(网络挂起等)时 pid 文件会残留, isExtractingInBackground 持续为真,
-- 后续预下载被"Background tasks incomplete"拒绝、用户下载被"后台下载中"拦截。
-- 看门狗在父进程周期检查: 进程已退出但 pid 文件未清理 → 复位状态;
-- 超时 → 删 pid 文件(子进程在任务边界自行退出)并强制回收, 恢复 standby。
-- ---------------------------------------------------------------------------
function M:startTaskWatchdog(pid, pid_file, timeout_seconds)
    if not (pid and pid_file) then
        return
    end
    self._task_watchdogs = self._task_watchdogs or {}
    self._task_watchdogs[pid_file] = {
        pid = pid,
        start = os.time(),
        timeout = timeout_seconds or TASK_WATCHDOG_TIMEOUT
    }
    if self._task_watchdog_scheduled ~= true then
        self._task_watchdog_scheduled = true
        UIManager:scheduleIn(TASK_WATCHDOG_INTERVAL, function()
            self:checkTaskWatchdogs()
        end)
    end
end

function M:checkTaskWatchdogs()
    self._task_watchdog_scheduled = false
    local watchdogs = self._task_watchdogs
    if H.is_tbl(watchdogs) then
        for pid_file, w in pairs(watchdogs) do
            local file_exists = util.fileExists(pid_file)
            -- ffiUtil.isSubProcessDone/terminateSubProcess 在旧版 KOReader 可能缺失, 先探测
            local done = (H.is_func(ffiUtil.isSubProcessDone) and ffiUtil.isSubProcessDone(w.pid)) or false
            if not file_exists then
                -- 正常结束: pid 文件已清理; 进程若仍活着(收尾中)不再等待, 直接回收
                watchdogs[pid_file] = nil
                if not done and H.is_func(ffiUtil.terminateSubProcess) then
                    pcall(function()
                        ffiUtil.terminateSubProcess(w.pid)
                    end)
                end
            elseif done then
                -- 进程已退出但 pid 文件未清理(异常终止): 复位状态, 恢复 standby
                pcall(function()
                    util.removeFile(pid_file)
                end)
                watchdogs[pid_file] = nil
                pcall(function()
                    Device:enableCPUCores(1)
                    UIManager:allowStandby()
                end)
            elseif (os.time() - w.start) > w.timeout then
                dbg.log('background task timeout, terminate pid:', tostring(w.pid))
                pcall(function()
                    util.removeFile(pid_file)
                end)
                if H.is_func(ffiUtil.terminateSubProcess) then
                    pcall(function()
                        ffiUtil.terminateSubProcess(w.pid)
                    end)
                end
                watchdogs[pid_file] = nil
                pcall(function()
                    Device:enableCPUCores(1)
                    UIManager:allowStandby()
                end)
            end
        end
    end
    if H.is_tbl(self._task_watchdogs) and next(self._task_watchdogs) then
        self._task_watchdog_scheduled = true
        UIManager:scheduleIn(TASK_WATCHDOG_INTERVAL, function()
            self:checkTaskWatchdogs()
        end)
    end
end

-- 翻页预下载(EPUB 后几页/内部章节)是否进行中
function M:isPagesPreloading()
    return self.pages_pid_file ~= nil and util.fileExists(self.pages_pid_file)
end

-- 阅读中后台预下载当前 EPUB 卷的后几页(内部章节), 翻到时即开。
-- 与 preLoadVolumes 不同: 内部章节缓存不写 volume 表下载状态,
-- 全程静默——失败只记日志, 不弹窗、不打断阅读。
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

    local task_pid = self:launchProcess(function()
        pcall(function()
            util.writeToFile('', self.pages_pid_file, true)
        end)
        for i = 1, #tasks do
            if not util.fileExists(self.pages_pid_file) then
                break -- 收到停止信号
            end
            local status, err = pcall(function()
                return self:pDownloadVolume(tasks[i])
            end)
            if not status then
                logger.err('preload epub chapter failed:', tostring(err))
            end
        end
        pcall(function()
            util.removeFile(self.pages_pid_file)
        end)
        self:closeDbManager()
        pcall(function()
            Device:enableCPUCores(1)
            UIManager:allowStandby()
        end)
        return true
    end)

    if not task_pid then
        pcall(function()
            Device:enableCPUCores(1)
            UIManager:allowStandby()
        end)
        return false
    end

    self:startTaskWatchdog(task_pid, self.pages_pid_file, PAGES_WATCHDOG_TIMEOUT)
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
    return self.stream_pages_pid_file ~= nil and util.fileExists(self.stream_pages_pid_file)
end

-- 后台预取流式漫画页(子进程顺序下载落盘)。
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
    local task_pid = self:launchProcess(function()
        pcall(function()
            util.writeToFile('', self.stream_pages_pid_file, true)
        end)
        for i = 1, #tasks do
            if not util.fileExists(self.stream_pages_pid_file) then
                break -- 收到停止信号
            end
            local ok, res = pcall(function()
                return self:pDownload_Image(tasks[i], 30)
            end)
            if ok and H.is_tbl(res) and res.type == 'SUCCESS' and H.is_tbl(res.body)
                and H.is_str(res.body.data) and #res.body.data > 0 then
                pcall(function()
                    local dir = self:getStreamPageCacheDir(cache_id)
                    H.checkAndCreateFolder(dir)
                    -- 原子写 + 按 md5(url) 命名
                    local base = H.joinPath(dir,
                        md5(tasks[i]) .. '.' .. (H.is_str(res.body.ext) and res.body.ext or "jpg"))
                    local tmp = base .. '.part'
                    if util.writeToFile(res.body.data, tmp, true) then
                        os.rename(tmp, base)
                    end
                end)
            else
                logger.err('preload stream page failed:', tostring(tasks[i]))
            end
        end
        pcall(function()
            util.removeFile(self.stream_pages_pid_file)
        end)
        return true
    end)

    if not task_pid then
        return false
    end
    self:startTaskWatchdog(task_pid, self.stream_pages_pid_file, PAGES_WATCHDOG_TIMEOUT)
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
    local response = self:komgaSporeApi(function()
        return self.apiClient:getNextBook({bookId = bookId})
    end, nil, {timeouts = {4, 6}}, 'getNextBook')
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

    -- 封面版本缓存: cover_url 带 ?v=<服务器 lastModified>(见 upsertSeries)时,
    -- 版本未变且本地已有封面文件则直接复用; Komga 换封面后随书架同步自动刷新
    local cover_version = cover_url:match("[?&]v=([^&]*)") or nil
    if cover_version and cover_version ~= "" then
        local marker_path = cover_path_no_ext .. '.v'
        local marker = nil
        local f = io.open(marker_path, "rb")
        if f then
            marker = f:read("*a")
            f:close()
        end
        if marker == cover_version then
            local cached = findCachedCoverFile(cover_path_no_ext)
            if cached then
                local _, image_filename = util.splitFilePathName(cached)
                return cached, image_filename
            end
        end
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
            if cover_version and cover_version ~= "" then
                pcall(function()
                    util.writeToFile(cover_version, path_no_ext .. '.v', true)
                end)
            end
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
    -- ffiUtil.isSubProcessDone(task_pid)
    local pid_file = self.task_pid_file
    if not util.fileExists(pid_file) then
        return false
    end
    if H.isFileOlderThan(pid_file, 24 * 60 * 60) then
        util.removeFile(pid_file)
        return false
    end

    return true
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

    self:loadSpore()

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