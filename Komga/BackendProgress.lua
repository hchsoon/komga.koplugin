--[[ Komga/BackendProgress.lua — Komga 进度 API(自 Backend 拆出)

Readium Progression(EPUB) + read-progress(漫画页码) + 跨卷续读 /books/:id/next。
install(M) 把方法装回 Backend 表; wrap_response 经 M 字段做 local 别名, 函数体零改动。
]]
local H = require("Komga/Helper")
local NetworkMgr = require("ui/network/manager")

return function(M)
local wrap_response = M.wrap_response
function M:getVolumeReadProgress(volume)

    if not (H.is_str(volume.name) and H.is_str(volume.url)) then
        return wrap_response(nil, '参数错误')
    end

    return self:komgaApi(function()
        -- GET /api/v1/books/:id(BookDto, 含 readProgress/media/metadata)
        return self.api:get("/api/v1/books/" .. volume.bookId, nil, {timeouts = {3, 5}})
    end, nil, 'getVolumeReadProgress')

end

-- 分卷目录初始化用: 一次拉取全部分卷的 BookDto(BookDto 自带该用户的 readProgress)。
-- 与 refreshVolumesCache 同端点同条件(POST /api/v1/books/list, seriesId is), 但不做任何 DB 写入;
-- 分页拉齐为单一 content 数组(komgaApi 缺省回调时自动摘取)。
function M:getSeriesVolumesReadProgress(series_id)
    if not H.is_str(series_id) then
        return wrap_response(nil, '参数错误')
    end

    return self:komgaApi(function()
        return self:fetchAllPages("/api/v1/books/list",
            function(page)
                return {size = 1000, page = page}
            end, {
                condition = {
                    allOf = {
                        {
                            seriesId = {
                                operator = "is",
                                value = series_id
                            }
                        }
                    }
                }
            }, {5, 8})
    end, nil, 'getSeriesVolumesReadProgress')

end

-- 阅读历史同步: 全库 BookDto[] 按 readProgress.lastModified 倒序(sort 走 Spring
-- pageable 查询参数), body=合并后的 content 数组。在读/已读过滤由调用方做。
function M:getRecentReadingBooks()
    return self:komgaApi(function()
        return self:fetchAllPages("/api/v1/books/list",
            function(page)
                return {size = 1000, page = page, sort = "readProgress.lastModified,desc"}
            end, {fullTextSearch = ""}, {5, 8})
    end, nil, 'getRecentReadingBooks')
end

function M:saveVolumeProgress(volume)

    if not (H.is_str(volume.name) and H.is_str(volume.url)) then
        return wrap_response(nil, '参数错误')
    end
    -- 图片列表加载失败等场景 current_page 为 nil: 缺页码上传必被服务器 400 拒绝, 直接跳过
    if not H.is_num(volume.current_page) then
        return wrap_response(nil, '无有效页码进度, 跳过上传')
    end

    local number = volume.number
    local finish = (volume.current_page == volume.pages)
    if finish then
        -- 读完直接标已读。旧实现先 volume.isRead = finish 再经 toggleVolumeRead
        -- 翻转, 会把刚置的 true 翻回 false 写库(服务器 completed 会在下次同步纠偏)
        self.dbManager:updateVolumeIsRead(volume, true)
    else
        -- 打点"最后阅读卷"(目录 pin/继续阅读按 volume.lastUpdated 排序)
        self.dbManager:touchVolumeLastRead(volume.book_cache_id, number)
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
    -- 读完(整卷比例 >= 99.9%): 本地标记已读, 服务器读满(totalProgression=1)会自动标 completed;
    -- 未读完也要打点"最后阅读卷"(目录 pin/继续阅读按 volume.lastUpdated 排序)
    if H.is_num(upload.frac) and upload.frac >= 0.999 then
        self.dbManager:updateVolumeIsRead(upload, true)
    else
        self.dbManager:touchVolumeLastRead(upload.book_cache_id, upload.number)
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

end
