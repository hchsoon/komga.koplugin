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
-- 分页参数只认 query string(size=1000 逐页拉齐, 汇总为单一 content 数组, komgaApi 缺省回调时自动摘取)。
function M:getSeriesVolumesReadProgress(series_id)
    if not H.is_str(series_id) then
        return wrap_response(nil, '参数错误')
    end

    return self:komgaApi(function()
        local all_content, total_pages, page = {}, 1, 0
        local first
        while page < total_pages do
            local r = self.api:post("/api/v1/books/list",
                {size = 1000, page = page}, {
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
                }, {timeouts = {5, 8}})
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
    end, nil, 'getSeriesVolumesReadProgress')

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
