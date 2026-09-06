-- ---------------------------------------------------------------------------
-- 流式漫画页预取(磁盘缓存 + 通道后台下载), 自 Backend 迁入
-- ---------------------------------------------------------------------------
local H = require("Komga/Helper")
local util = require("util")
local md5 = require("ffi/sha2").md5
local logger = require("logger")
local TaskQueue = require("Komga/TaskQueue")

local PAGES_WATCHDOG_TIMEOUT = 300

local M = {}

local HttpRequestRef = nil
local function httpReq()
    HttpRequestRef = HttpRequestRef or require("Komga/HttpRequest")
    return HttpRequestRef
end

-- ---------------------------------------------------------------------------
-- 流式漫画页预取(磁盘缓存 + 子进程后台下载)
-- StreamImageView 每翻一页原本要同步下载一图; 预取把"后几页"提前落盘,
-- 翻页时直接读本地。缓存按 img_src 的 md5 命名, 阅读中滑动窗口清理,
-- 关卷时整目录清理, 不占用长期磁盘。
-- ---------------------------------------------------------------------------
local STREAM_PAGE_EXTS = {"jpg", "jpeg", "png", "webp", "gif"}

-- 流式页缓存目录: <系列缓存>/resources/stream
function M.getStreamPageCacheDir(bookCacheId)
    if not H.is_str(bookCacheId) then
        return nil
    end
    return H.joinPath(H.joinPath(H.getBookCachePath(bookCacheId), 'resources'), 'stream')
end

-- 查流式页缓存: 命中返回图片数据(string), 未命中返回 nil
function M.lookupStreamPageCache(bookCacheId, img_src)
    if not (H.is_str(bookCacheId) and H.is_str(img_src)) then
        return nil
    end
    local dir = M.getStreamPageCacheDir(bookCacheId)
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
M.removeStreamPageCache = function(bookCacheId, img_src)
    local dir = M.getStreamPageCacheDir(bookCacheId)
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

-- 清空流式页缓存目录(关卷时调用)。预取子进程以"目录是否存在"为取消依据
-- (标志位跨 fork 不可见, 目录删除跨进程可见), 在飞的页会中止、剩余页跳过。
function M.clearStreamPageCache(bookCacheId)
    local dir = M.getStreamPageCacheDir(bookCacheId)
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
function M.isStreamPagesPreloading()
    return TaskQueue.getChannel("stream", 1):hasTasks()
end

-- 后台预取流式漫画页(Async 子进程 + 流式落盘 + Range 断点续传)。
-- 已有预取任务运行时跳过(翻得快时退回同步下载, 与现状一致); 全程静默失败。
function M.preLoadStreamPages(bookCacheId, img_srcs)
    if not (H.is_str(bookCacheId) and H.is_tbl(img_srcs) and #img_srcs > 0) then
        return false
    end
    if M.isStreamPagesPreloading() then
        return false
    end
    -- 过滤已缓存的页
    local tasks = {}
    for _, src in ipairs(img_srcs) do
        if H.is_str(src) and src ~= "" and M.lookupStreamPageCache(bookCacheId, src) == nil then
            table.insert(tasks, src)
        end
    end
    if #tasks < 1 then
        return false
    end

    local cache_id = bookCacheId
    local dir = M.getStreamPageCacheDir(cache_id)
    H.checkAndCreateFolder(dir)

    local Http = httpReq()
    local batch_headers = Http.get_default_headers()
    TaskQueue.getChannel("stream", 1):push(function()
        local pStreamToFile = Http.pStreamToFile
        for i = 1, #tasks do
            local src = tasks[i]
            local base_no_ext = H.joinPath(dir, md5(src))
            -- 先流式落位到 .dl(扩展名下载后由 Content-Type 得知), 再改名为最终文件;
            -- 中断留下的 .part/.dl 下次按 Range 续传。
            -- should_cancel: 缓存目录被删(关卷清理)时中止剩余预取。
            -- 注意: pcall 会包住 pStreamToFile 的两个返回值(成功标志, 结果/原因),
            -- 必须解开两层, 否则结果表落在第三个值里被丢弃(表现为 res=true 的"失败")
            local pok, ok, res = pcall(pStreamToFile, {
                url = src,
                dest = base_no_ext .. ".dl",
                headers = batch_headers,
                timeout = 30,
                maxtime = 90,
                should_cancel = function() return not util.fileExists(dir) end,
            })
            if not pok then
                ok, res = false, tostring(ok)
            end
            if ok and H.is_tbl(res) then
                local ext = (H.is_str(res.ext) and res.ext ~= "") and res.ext or "jpg"
                local final = base_no_ext .. "." .. ext
                os.remove(final)
                os.rename(base_no_ext .. ".dl", final)
                -- 成功日志: 用于确认预取生效(预取失败会在下方 error 级别单独记录)
                logger.info('preload stream page cached:', tostring(final),
                    'bytes=', tostring(res.bytes))
            else
                logger.err('preload stream page failed:', tostring(src),
                    'ok=', tostring(ok), 'res=', tostring(res))
            end
        end
        return true
    end, nil, {timeout = PAGES_WATCHDOG_TIMEOUT, tag = "stream_pages"})
    return true
end

return M
