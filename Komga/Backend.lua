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
local NetworkMgr = require("ui/network/manager")
local ffiUtil = require("ffi/util")
local dbg = require("dbg")
local LuaSettings = require("luasettings")
local util = require("util")

local UIManager = require("ui/uimanager")
local H = require("Komga/Helper")
local Config = require("Komga/Config")
local ApiClient = require("Komga/ApiClient")
local TaskQueue = require("Komga/TaskQueue")
local KLog = require("Komga/Logger")
local StreamPageCache = require("Komga/StreamPageCache")
local CacheJanitor = require("Komga/CacheJanitor")
local ContentProcessor = require("Komga/ContentProcessor")

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


local function pGetUrlContent(options)
    if not M.httpReq then
        M.httpReq = require("Komga.HttpRequest")
    end
    return M.httpReq.pGetUrlContent(options, true)
end

-- 拆分模块(BackendProfiles/BackendProgress/BackendDownload)经 install(M) 内 local 别名复用这两个助手
M.wrap_response = wrap_response
M.pGetUrlContent = pGetUrlContent


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
-- 一次性设置迁移(ONE_TIME_MIGRATIONS/runOneTimeMigrations)在 Komga/BackendProfiles
function M:initialize()
    self.task_pid_file = H.getTempDirectory() .. '/task.pid.lua'
    self.settings_data = self:getLuaConfig(H.getUserSettingsPath())
    -- 上个进程异常退出可能遗留 pid 文件(通道状态在内存, 重启即复位), 清理防误判
    pcall(function()
        util.removeFile(self.task_pid_file)
    end)

    KLog.init(H.getTempDirectory() .. "/komga.log", self.settings_data.data.debug_log == true)

    -- 缓存上限 LRU(启动 8s 后在 janitor 通道后台执行, 全程静默)
    UIManager:scheduleIn(8, function()
        pcall(function()
            local max_bytes = (tonumber(self.settings_data.data.cache_max_mb) or 1024) * 1024 * 1024
            local root = H.joinPath(H.getTempDirectory(), "cache/komga.cache")
            TaskQueue.getChannel("janitor", 1):push(function()
                return CacheJanitor.enforceLimit(root, max_bytes)
            end, function(ok, res)
                if ok and H.is_tbl(res) and (res.removed or 0) > 0 then
                    KLog.info("cache janitor removed", res.removed, "files, freed", res.freed)
                end
            end, {timeout = 300, tag = "lru"})
        end)
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

    -- 已安装且内容一致时跳过重装与重启: 此前无条件覆盖+重启,
    -- 导致每次启动第一次打开 Komga 都被踢回主页, 第二次才能进入
    if util.fileExists(patches_file_path) and M.isFileContentEqual(source_patches, patches_file_path) then
        return
    end

    local disabled_patches = patches_file_path .. '.disabled'
    for _, file in ipairs({patches_file_path, disabled_patches}) do
        if util.fileExists(file) then
            util.removeFile(file)
        end
    end
    H.copyFileFromTo(source_patches, patches_file_path)
    UIManager:restartKOReader()
end

-- 逐块比较两个文件内容是否一致(任一不存在返回 false)
function M.isFileContentEqual(path_a, path_b)
    local fa = io.open(path_a, "rb")
    if not fa then
        return false
    end
    local fb = io.open(path_b, "rb")
    if not fb then
        fa:close()
        return false
    end
    while true do
        local ca = fa:read(8192)
        local cb = fb:read(8192)
        if ca ~= cb then
            fa:close()
            fb:close()
            return false
        end
        if not ca then
            fa:close()
            fb:close()
            return true
        end
    end
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

-- Komga 分页拉取统一骨架: 分页参数 size 只认 query string(放 body 会被忽略,
-- 默认页大小 20 截断), 逐页拉齐后合并为单一响应(替换 first.body.content 为
-- 全量数组), 调用方回调无感知。
-- build_body(page) 返回每页请求 body(通常 {size = 1000, page = page})。
function M:fetchAllPages(path, build_body, json_body, timeouts)
    local all_content, total_pages, page = {}, 1, 0
    local first
    while page < total_pages do
        local r = self.api:post(path, build_body(page), json_body, {timeouts = timeouts})
        if not H.is_tbl(r) then
            return r
        end
        if not first then
            first = r
        end
        local content = r.body and r.body.content
        if H.is_tbl(content) then
            for _, item in ipairs(content) do
                all_content[#all_content + 1] = item
            end
        end
        total_pages = tonumber(r.body and r.body.totalPages) or 1
        page = page + 1
    end
    if first then
        first.body.content = all_content
    end
    return first
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
        -- POST /api/v1/books/list(按系列条件查询分卷)
        return self:fetchAllPages("/api/v1/books/list",
            function(page)
                return {size = 1000, page = page}
            end, {
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
            }, {10, 12})
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
        -- POST /api/v1/series/list(全量书架), 分页循环拉齐后交回调(上游无感知)
        return self:fetchAllPages("/api/v1/series/list",
            function(page)
                return {size = 1000, page = page}
            end, {fullTextSearch = ""}, {8, 12})
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

-- 关闭阅读器等路径的后台全库刷新: fork 前关库(子进程经 getDB 用自有连接, 主线程按需懒重开)。
-- 原 UI 线程同步分页拉取在慢网下冻结界面数秒; 失败静默, 结果经回调带回(多数调用方不关心)。
function M:refreshLibraryCacheAsync(on_done)
    self:closeDbManager()
    TaskQueue.getChannel("sync", 1):push(function()
        return M.refreshLibraryCache(M)
    end, function(ok, resp, err)
        if on_done then
            on_done(ok and resp or wrap_response(nil, err))
        end
    end, {timeout = 600, tag = "library_refresh"})
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

-- 方法体在 Komga/BackendProgress(install(M) 注入, 避免模块环)
require("Komga/BackendProgress")(M)

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

-- 流式页预取缓存已迁至 Komga/StreamPageCache(薄委托保持 StreamImageView 调用面不变)
function M:getStreamPageCacheDir(bookCacheId)
    return StreamPageCache.getStreamPageCacheDir(bookCacheId)
end
function M:lookupStreamPageCache(bookCacheId, img_src)
    return StreamPageCache.lookupStreamPageCache(bookCacheId, img_src)
end
function M:removeStreamPageCache(bookCacheId, img_src)
    StreamPageCache.removeStreamPageCache(bookCacheId, img_src)
end
function M:clearStreamPageCache(bookCacheId)
    StreamPageCache.clearStreamPageCache(bookCacheId)
end
function M:preLoadStreamPages(bookCacheId, img_srcs)
    return StreamPageCache.preLoadStreamPages(bookCacheId, img_srcs)
end

-- chapter content pipeline moved to Komga/ContentProcessor; thin delegates here
function M:_processVolumeContent(volume, content)
    return ContentProcessor.process_volume_content(self, volume, content)
end

-- 下载/预载/封面/后台任务域: 方法体在 Komga/BackendDownload(install(M) 注入)
require("Komga/BackendDownload")(M)

function M:getVolumeInfoCache(bookCacheId, number)
    local volume_data = self.dbManager:getVolumeInfo(bookCacheId, number)
    return volume_data
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
    return self.dbManager:getAllSeriesByUI(bookShelfId, self:getSettings().series_sort_mode)
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
            -- epub_chapter 行已补写, 失效 ProgressSync 的 href 映射缓存
            pcall(function()
                require("Komga/ProgressSync").invalidateEpubHrefMap(volume.book_cache_id)
            end)
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

function M:after_reader_chapter_show(volume)
    local book_cache_id = volume.book_cache_id
    -- 书架"按最后阅读"排序打点
    self:touchSeriesLastRead(book_cache_id)

    local number = volume.number
    local cache_file_path = volume.cacheFilePath
    -- 打开不标记已读(EPUB 与漫画一致): isRead 在 refreshVolumeMetadata 被当作
    -- "整卷满进度 100%", 打开即标已读会让"没读完的卷"一直显示 100%。
    -- 已读统一由进度同步按真实完成状态写入:
    --   EPUB: saveBookProgression(整卷比例 totalProgression >= 99.9%)
    --   漫画: saveVolumeProgress(读到最后一页, current_page == pages)
    local is_epub = volume.mediaType == "EPUB"
        or (H.is_str(volume.cacheFilePath) and volume.cacheFilePath:match("%.x?html$") ~= nil)

    local status, err = pcall(function()

        local update_state = {}

        if volume.isDownLoaded ~= true then
            update_state.content = 'downloaded'
            update_state.cacheFilePath = cache_file_path
        end

        -- update_state 可能为空(已下载过), 空更新直接跳过
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
            local ext_ok, ext_err = pcall(function()

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

            if not ext_ok then
                dbg.log('updating cache ext err:', tostring(ext_err))
            end
        end
    end

    if volume.isRead ~= true and NetworkMgr:isConnected() then
        if is_epub then
            -- EPUB: 预下载当前卷的后几页(内部章节), 翻到时即开; 全程静默
            self:preLoadEpubChapters(volume, tonumber(self:getSettings().preload_count) or 3)
        else
            -- 漫画: 预下载后续整卷(cbz 单文件较大, 只预下载 1 卷)
            local complete_count = self:getReadAheadVolumeCount(volume)
            if complete_count < 40 then
                local preDownloadNum = tonumber(self:getSettings().preload_count) or 3
                if volume.cacheExt and volume.cacheExt == 'cbz' then
                    preDownloadNum = 1
                end
                self:preLoadVolumes(volume, preDownloadNum)
            end
        end
    end

    volume.isDownLoaded = true
end

-- P3-9 双轨渲染: 整卷原文件模式 —— 直接下载 /api/v1/books/:id/file,
-- 交 KOReader 原生引擎渲染(EPUB=CRE, zip/cbz=图片文档)。成功返回 volume
-- (cacheFilePath 指向整卷文件), 失败返回 nil(调用方回退逐章管线)。
require("Komga/BackendProfiles")(M)

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