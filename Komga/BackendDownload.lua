--[[ Komga/BackendDownload.lua — 下载/预载/封面/后台任务域(自 Backend 拆出)

逐章下载管线(pDownloadVolume/pDownload_Image)、整卷原文件下载、预载
(preLoadVolumes/preLoadEpubChapters)、封面下载与缓存、后台任务控制
(重试/看门狗/任务清单)。install(M) 把方法装回 Backend 表; wrap_response/
pGetUrlContent 经 M 字段做 local 别名, 函数体零改动。
]]
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local dbg = require("dbg")
local socket_url = require("socket.url")
local UIManager = require("ui/uimanager")
local Device = require("device")
local TaskQueue = require("Komga/TaskQueue")
local KLog = require("Komga/Logger")
local Paths = require("Komga/Paths")
local CacheJanitor = require("Komga/CacheJanitor")
local ContentProcessor = require("Komga/ContentProcessor")
local get_img_src = ContentProcessor.get_img_src
local custom_urlEncode = ContentProcessor.custom_urlEncode
local H = require("Komga/Helper")

return function(M)
local wrap_response = M.wrap_response
local pGetUrlContent = M.pGetUrlContent
function M:pDownloadVolume(volume)

    local series_url = volume.url
    local book_cache_id = volume.book_cache_id
    local down_number = volume.number
    if volume.bookId == nil then
        volume.bookId = volume.book_cache_id
    end

    if series_url == nil or not book_cache_id then
        error('pDownloadVolume input parameters err' .. tostring(series_url) .. tostring(book_cache_id))
    end

    local cache_chapter = self:getCacheVolumeFilePath(volume)
    if cache_chapter and cache_chapter.cacheFilePath then
        return cache_chapter
    end

    local url
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
                                ["user-agent"] = Paths.USER_AGENT,
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
            return self:_processVolumeContent(volume, data)
        else
            logger.err("download volume error: ", url, err)
        end
    end

    return nil
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

function M:findNextVolume(current_volume)

    if not H.is_tbl(current_volume) or current_volume.book_cache_id == nil or current_volume.number == nil then
        dbg.log("findNextVolume: bad params", current_volume)
        return
    end

    if current_volume.call_event == nil then
        current_volume.call_event = 'next'
    end

    local next_volume = self.dbManager:findNextEpubChapterInfo(current_volume)

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
                        ["user-agent"] = Paths.USER_AGENT,
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

    -- pages 缺失(部分书的 media.pagesCount 未入库)时无法构造页 URL;
    -- 先从服务器补拉一次并回写 DB, 此前直接 for 迭代 nil 会抛
    -- "'for' limit must be a number" 并杀死整个下载子任务
    local pages = tonumber(volume.pages)
    if not pages or pages < 1 then
        local resp = self:getVolumeReadProgress(volume)
        local media = resp and resp.body and resp.body.media
        pages = tonumber(media and media.pagesCount)
        if pages and pages > 0 then
            volume.pages = pages
            pcall(function()
                self.dbManager:dynamicUpdateVolume({
                    book_cache_id = volume.book_cache_id,
                    bookId = volume.bookId,
                    number = number,
                }, { pages = pages })
            end)
        end
    end

    if not pages or pages < 1 then
        return imgs
    end

    for j = 1, pages do
        table.insert(imgs, server_address .. "/api/v1/books/" .. volume.bookId .. "/pages/" .. j)
    end

    return imgs
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

    local volume_down_tasks

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

    -- 先把任务卷标记为 downloading_ 再 fork: 若在子进程启动后才写,
    -- 先完成的卷会被父进程的 downloading_ 覆盖(表现为已下载卷状态回退)
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
            function(volumes, ok_list)

                for i = 1, #volumes do
                    local nextVolume = volumes[i]
                    if H.is_tbl(nextVolume) and nextVolume.number ~= nil and nextVolume.book_cache_id ~= nil and nextVolume.bookId ~= nil then

                        local number = tonumber(nextVolume.number)
                        local book_cache_id = nextVolume.book_cache_id
                        local volume_book_id = nextVolume.bookId

                        if ok_list['ok_' .. number] == nil then

                            local ok, cerr = pcall(function()
                                self.dbManager:updateVolumeDownloadState({
                                    number = number,
                                    book_cache_id = book_cache_id,
                                    bookId = volume_book_id
                                }, false)
                            end)

                            if not ok then
                                dbg.log("Error cleaning download task for database write:", H.errorHandler(cerr))
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

                -- 注意: pcall 第二返回值在这里是下载结果(cacheFilePath 所在), 不是错误信息
                local ok, dl = pcall(function()
                    -- 与 downloadVolume 同策略: 漫画卷(非 EPUB)必须走整卷下载
                    return self:downloadVolumeAuto(nextVolume)
                end)

                if not ok then
                    logger.err("Chapter download failed: ", tostring(dl))
                else

                    if H.is_tbl(dl) and dl.cacheFilePath then

                        local cache_file_path = dl.cacheFilePath
                        local number = tonumber(nextVolume.number)
                        local book_cache_id = nextVolume.book_cache_id

                        task_return_ok_list['ok_' .. number] = true

                        dbg.v('Download volume successfully:', book_cache_id, number, cache_file_path)

                        local db_ok, dberr = pcall(function()
                            return task_return_db_add(book_cache_id, number, cache_file_path)
                        end)
                        if not db_ok then
                            logger.err('Error saving download to database:', tostring(dberr))
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
        local cleanup_ok, cleanup_err = pcall(function()
            return task_return_db_clear(volume_down_tasks, task_return_ok_list)
        end)
        if not cleanup_ok and cleanup_err then
            dbg.v("Incomplete volume cleanup after load", tostring(cleanup_err))
        end

        self:closeDbManager()

        pcall(function()
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

    -- downloading_ 标记已在 fork 前写入(见上), 这里直接返回任务清单
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
    end, function()
        -- 子进程可能已补写 epub_chapter 行, 失效 ProgressSync 的 href 映射缓存
        pcall(function()
            require("Komga/ProgressSync").invalidateEpubHrefMap(book_cache_id)
        end)
    end, {timeout = PAGES_WATCHDOG_TIMEOUT, tag = "epub_pages"})
    return true
end


function M:toggleVolumeRead(volume)
    volume.isRead = not volume.isRead
    self.dbManager:updateVolumeIsRead(volume, volume.isRead)
    return wrap_response(true)
end

-- 直接置已读状态(不经 toggle 翻转): 进度同步完成等"确定目标状态"的场景用
function M:markVolumeRead(volume, isRead)
    self.dbManager:updateVolumeIsRead(volume, isRead)
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
                            ["user-agent"] = Paths.USER_AGENT,
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

function M:downloadVolumeWholeFile(volume)
    local bookId = volume.bookId
    if not (H.is_str(bookId) and H.is_str(volume.url)) then
        return nil
    end
    local ext = volume.url:match("%.([%w]+)$")
    ext = ext and ext:lower() or nil
    if ext == "zip" then
        ext = "cbz"
    end
    if ext ~= "epub" and ext ~= "cbz" and ext ~= "pdf" then
        -- 服务器文件路径常无扩展名(series.url 即文件路径): 按媒体类型兜底。
        -- 漫画(DIVINA)整卷文件是 cbz 系图片包; EPUB 卷识别不了时回退逐章管线
        if volume.mediaType == "EPUB" then
            return nil
        end
        ext = "cbz"
    end
    local base = H.getVolumeCacheFilePath(volume.book_cache_id, bookId, volume.number, volume.name)
    local dest = base .. "." .. ext
    if util.fileExists(dest) then
        volume.cacheFilePath = dest
        return volume
    end
    local dir = util.splitFilePathName(dest)
    if H.is_str(dir) then
        H.checkAndCreateFolder(dir)
    end
    local url = (self.settings_data.data.server_address or "") .. "/api/v1/books/" .. bookId .. "/file"
    if not self.httpReq then
        self.httpReq = require("Komga.HttpRequest")
    end
    local ok, res = self.httpReq.pStreamToFile({
        url = url,
        dest = dest,
        headers = {
            ["X-API-Key"] = self:getApiKey(),
            ["user-agent"] = Paths.USER_AGENT,
        },
        timeout = 30,
        maxtime = 600,
    })
    if not ok then
        KLog.warn("whole-file download failed:", tostring(res))
        return nil
    end
    volume.cacheFilePath = dest
    pcall(function()
        self.dbManager:transaction(function()
            return self.dbManager:dynamicUpdateVolume({
                book_cache_id = volume.book_cache_id,
                bookId = bookId,
                number = volume.number,
            }, {
                content = "downloaded",
                cacheFilePath = dest,
            })
        end)()
    end)
    return volume
end

function M:downloadVolume(volume)

    local bookCacheId = volume.book_cache_id
    local number = volume.number
    local volume_book_id = volume.bookId

    if self.dbManager:isVolumeDownloading(bookCacheId, volume_book_id, number) == true and self:isExtractingInBackground() == true then
        return wrap_response(nil, "此章节后台下载中, 请等待...")
    end

    local status, err = pcall(function()
        -- P3-9 双轨: 非 EPUB 卷(漫画)必须走整卷下载
        -- (逐章管线对漫画必 400);
        -- EPUB 卷按 whole_file_mode 选择整卷/逐章, 整卷失败回退逐章
        return self:downloadVolumeAuto(volume)
    end)
    if not status then
        logger.err('下载章节失败：', err)
        return wrap_response(nil, "下载章节失败：" .. H.errorHandler(err))
    end
    return wrap_response(err)

end

-- 下载策略选择: 非 EPUB 卷(漫画 DIVINA 等)没有内部章节, 逐章管线是 EPUB 专用
-- (对漫画调 manifest/epub 端点必然 400), 因此无论设置如何都先走整卷原文件下载;
-- EPUB 卷按 whole_file_mode 选择整卷/逐章, 整卷失败回退逐章。
function M:downloadVolumeAuto(volume)
    if self:getSettings().whole_file_mode == true or volume.mediaType ~= "EPUB" then
        local wf = self:downloadVolumeWholeFile(volume)
        if wf then
            return wf
        end
    end
    return self:pDownloadVolume(volume)
end

-- 打点系列"最后阅读"时间(静默, 失败不影响阅读)
function M:touchSeriesLastRead(book_cache_id)
    pcall(function()
        self.dbManager:touchSeriesLastRead(book_cache_id)
    end)
end

-- 缓存占用上限, 供设置菜单展示。占用(used_bytes)由 refreshCacheUsageAsync
-- 在 janitor 子进程里统计后缓存 —— 此前每次打开菜单都同步全树递归 lfs 遍历, 卡顿明显
function M:getCacheUsage()
    local root = H.joinPath(H.getTempDirectory(), "cache/komga.cache")
    local max_mb = tonumber(self.settings_data.data.cache_max_mb) or 1024
    return {
        used_bytes = self._cache_used_bytes,
        used_at = self._cache_used_at,
        max_bytes = max_mb * 1024 * 1024,
        root = root,
    }
end

-- 后台统计缓存占用(janitor 通道子进程执行 collectEvictable), 完成后回调 total
function M:refreshCacheUsageAsync(on_done)
    local root = H.joinPath(H.getTempDirectory(), "cache/komga.cache")
    TaskQueue.getChannel("janitor", 1):push(function()
        return CacheJanitor.totalBytes(root)
    end, function(ok, total)
        if ok and H.is_num(total) then
            self._cache_used_bytes = total
            self._cache_used_at = os.time()
        end
        if H.is_func(on_done) then
            pcall(on_done, ok and total or nil)
        end
    end, {timeout = 300, tag = "cache_usage"})
end

-- 手动触发 LRU 清理(janitor 通道后台), on_done(ok, res) 可选回调。
-- 清理结果里的 total 顺带刷新占用缓存, 下次打开菜单即为新值。
function M:runCacheJanitor(on_done)
    local usage = self:getCacheUsage()
    TaskQueue.getChannel("janitor", 1):push(function()
        return CacheJanitor.enforceLimit(usage.root, usage.max_bytes)
    end, function(ok, res)
        if ok and H.is_tbl(res) and H.is_num(res.total) then
            self._cache_used_bytes = res.total
            self._cache_used_at = os.time()
        end
        if H.is_func(on_done) then
            pcall(on_done, ok, res)
        end
    end, {timeout = 300, tag = "manual_janitor"})
    return wrap_response(true)
end

-- 方法体在 Komga/BackendProfiles(install(M) 注入, 避免模块环)
end
