local logger = require("logger")
local H = require("Komga/Helper")
local Config = require("Komga/Config")
local LuaSettings = require("luasettings")

--- Common timeout values
-- Large content 块超时 总超时
local LARGE_BLOCK_TIMEOUT = 10
local LARGE_TOTAL_TIMEOUT = 30
-- File downloads
local FILE_BLOCK_TIMEOUT = 15
local FILE_TOTAL_TIMEOUT = 60
-- Upstream defaults
local DEFAULT_BLOCK_TIMEOUT = 60
local DEFAULT_TOTAL_TIMEOUT = -1   

local Paths = require("Komga/Paths")
local USER_AGENT = Paths.USER_AGENT -- (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+"

-- 从设置文件读取当前 X-API-Key(与 Backend.getApiKey 同源; 此处直接读文件避免循环依赖),
-- 未设置/为空时回落 Config 预设值
local function get_api_key()
    local ok, settings = pcall(function()
        return LuaSettings:open(H.getUserSettingsPath())
    end)
    local key = ok and settings and settings.data and settings.data.api_key
    if type(key) == "string" and key ~= "" then
        return key
    end
    return Config.DEFAULT_API_KEY
end

-- 默认请求头: 调用方未显式传 headers 时使用, X-API-Key 取当前配置
local function get_default_headers()
    return {
        ["user-agent"] = USER_AGENT,
        ["X-API-Key"] = get_api_key()
    }
end

local EXT_BY_MIME = {
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/bmp"] = "bmp",
    ["image/webp"] = "webp",
    ["image/tiff"] = "tiff",
    ["image/svg+xml"] = "svg",
    ["application/xhtml+xml"] = "html",
    ["text/javascript"] = "js",
    ["text/css"] = "css",
    ["application/opentype"] = "otf",
    ["application/truetype"] = "ttf",
    ["application/font-woff"] = "woff",
    ["application/epub+zip"] = "epub"
}

local function get_extension_from_mimetype(content_type)
    return EXT_BY_MIME[content_type]
end

local function get_image_format_head8(image_data)
    if type(image_data) ~= "string" then
        return "bin"
    end
    local header = image_data:sub(1, 8)

    if header:sub(1, 3) == "\xFF\xD8\xFF" then
        return "jpg"
    elseif header:sub(1, 8) == "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A" then
        return "png"
    elseif header:sub(1, 4) == "\x47\x49\x46\x38" then
        return "gif"
    elseif header:sub(1, 2) == "\x42\x4D" then
        return "bmp"
    elseif header:sub(1, 4) == "\x52\x49\x46\x46" then
        return "webp"
    else
        return "bin"
    end
end

-- 按 URL scheme 选择传输(socket.http / ssl.https, 接口同构)
local function pick_http(url)
    if url:find("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then
            return https
        end
        return nil, "https unavailable"
    end
    return require("socket.http")
end
-- 非 2xx 的分类描述: 用户侧可区分密钥错误/资源不存在/限流/服务器错误
local function describe_http_error(code, status)
    if code == 401 or code == 403 then
        return "HTTP " .. code .. ": 鉴权失败, 请检查 API Key 设置"
    elseif code == 404 then
        return "HTTP 404: 资源不存在"
    elseif code == 429 then
        return "HTTP 429: 请求过于频繁"
    elseif type(code) == "number" and code >= 500 then
        return "HTTP " .. code .. ": 服务器错误"
    elseif type(code) == "number" then
        -- luasocket 的 status 已形如 "HTTP/1.1 400 Bad Request", 直接展示避免重复
        if status and status ~= "" then
            return status
        end
        return "HTTP " .. code .. ": 请求失败"
    end
    return "Remote server error or unavailable"
end

-- 重定向地址解析: Location 为相对路径时基于当前 URL 补全
local function resolve_redirect(base_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    if location:find("^https?://") then
        return location
    end
    local socket_url = require("socket.url")
    return socket_url.absolute(base_url, location)
end

local function pGetUrlContent(options)
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local url = options.url
    local method = options.method or "GET"
    local headers = options.headers or get_default_headers()
    local timeout = options.timeout or 10
    local maxtime = options.maxtime or options.timeout + 20

    -- 301/302/307/308 跟随(GET 限 2 跳); 非 GET 请求重定向按错误返回
    local hops = 0
    while true do
        local http, http_err = pick_http(url)
        if not http then
            return false, http_err
        end
        local parsed = socket_url.parse(url)
        if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
            return false, "Unsupported protocol"
        end

        local sink = {}
        local request = {
            url = url,
            method = method,
            headers = headers,
            sink = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
            source = options.source,
            create = socketutil.tcp,
        }

        socketutil:set_timeout(timeout, maxtime)
        local code, resp_headers, status = socket.skip(1, http.request(request))
        socketutil:reset_timeout()

        if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
            logger.err("request interrupted:", code)
            return false, "request interrupted:" .. tostring(code)
        end

        if resp_headers == nil then
            logger.warn("No HTTP headers:", status or code or "network unreachable")
            return false, "Network or remote server unavailable"
        end

        local is_redirect = type(code) == "number" and code >= 300 and code < 400
        if is_redirect and (method ~= "GET" or options.source) then
            return false, describe_http_error(code, status) .. " (非 GET 请求不跟随重定向)"
        elseif is_redirect then
            local next_url = resolve_redirect(url, resp_headers["location"])
            if not next_url then
                return false, describe_http_error(code, status)
            end
            if hops >= 2 then
                return false, describe_http_error(code, status) .. " (重定向次数过多)"
            end
            hops = hops + 1
            logger.dbg("following redirect:", code, "->", next_url)
            url = next_url
        elseif type(code) ~= 'number' or code < 200 or code > 299 then
            logger.warn("HTTP status not okay:", status or code or "network unreachable")
            return false, describe_http_error(code, status)
        else
            local content = table.concat(sink)
            local content_length = tonumber(resp_headers["content-length"] or "")
            if content_length and #content ~= content_length then
                return false, "Incomplete content received"
            end

            local extension
            local contentType = resp_headers["content-type"]
            if contentType then
                extension = get_extension_from_mimetype(contentType)
                if not extension and contentType:match("^image/") then
                    extension = get_image_format_head8(content)
                end
            end

            return true, {
                data = content,
                ext = extension,
                headers = resp_headers
            }
        end
    end
end

--[[ 流式下载到文件(参考 koobone http_downloader 设计):
- 边下边写盘, 不整载内存; 已有 .part 时发 Range 头断点续传
- on_progress(downloaded, total) 每 256KB 回调(total 未知为 nil)
- should_cancel() 返回 true 时中止并保留 .part 供下次续传
- 成功后 .part → rename 原子落位; 服务器无视 Range(200 回全量)时自动重下
options: { url, dest, headers, timeout, maxtime, on_progress, should_cancel, resume }
返回 true, {bytes, resumed} 或 false, err ]]
local function pStreamToFile(options)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local url = options.url
    local http, http_err = pick_http(url)
    if not http then
        return false, http_err
    end
    local dest = options.dest
    if type(url) ~= "string" or type(dest) ~= "string" or dest == "" then
        return false, "bad params"
    end
    local parsed = socket_url.parse(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return false, "Unsupported protocol"
    end

    local tmp = dest .. ".part"
    local timeout = options.timeout or 15
    local maxtime = options.maxtime or 120
    local on_progress = options.on_progress
    local should_cancel = options.should_cancel

    -- 单次尝试(含 Range); 服务器忽略 Range 回 200 时由调用侧重试一次。
    -- current_url/hops 支持重定向跟随(3xx 时未写入任何字节, 整次重试)。
    local function attempt(from_scratch, current_url, hops)
        local url = current_url
        local start_offset = 0
        local mode = "wb"
        if not from_scratch and options.resume ~= false then
            local probe = io.open(tmp, "rb")
            if probe then
                start_offset = probe:seek("end")
                probe:close()
                if start_offset > 0 then
                    mode = "ab"
                end
            end
        end
        local f = io.open(tmp, mode)
        if not f then
            return false, "cannot open part file"
        end

        local headers = {}
        for k, v in pairs(options.headers or get_default_headers()) do
            headers[k] = v
        end
        if start_offset > 0 then
            headers["Range"] = "bytes=" .. start_offset .. "-"
        end

        local downloaded = start_offset
        local last_cb = start_offset
        local total = nil
        local cancelled = false

        local function notify()
            if on_progress then
                pcall(on_progress, downloaded, total)
            end
        end

        local sink_obj = setmetatable({}, {
            __call = function(_, chunk, sink_err)
                if chunk == nil then
                    -- ltn12 结束标记: sink_err 非 nil 表示出错
                    if sink_err then
                        return nil, tostring(sink_err)
                    end
                    return true
                end
                if chunk ~= "" then
                    if not f:write(chunk) then
                        return nil, "disk write failed"
                    end
                    downloaded = downloaded + #chunk
                    if downloaded - last_cb >= 256 * 1024 then
                        last_cb = downloaded
                        notify()
                    end
                    if should_cancel and should_cancel() then
                        cancelled = true
                        return nil, "cancelled"
                    end
                end
                return true
            end
        })

        local request = {
            url = url,
            method = "GET",
            headers = headers,
            sink = sink_obj,
            create = socketutil.tcp
        }

        socketutil:set_timeout(timeout, maxtime)
        -- skip(1) 丢弃首值(=1): 依次返回 code(number), headers(table), status(string)
        -- 注意首个返回值就是状态码——此前误命名为 res 导致 code 拿到 headers 表
        local code, resp_headers = socket.skip(1, http.request(request))
        socketutil:reset_timeout()
        f:close()

        if cancelled then
            return false, "cancelled"
        end

        -- 3xx 重定向: 此时未写入任何字节, 换目标 URL 重新走一次完整尝试
        if type(code) == "number" and code >= 300 and code < 400 then
            local next_url = resolve_redirect(url, resp_headers and resp_headers["location"])
            if next_url and hops < 2 then
                logger.dbg("following redirect:", code, "->", next_url)
                local ok2, res2 = attempt(from_scratch, next_url, hops + 1)
                -- 失败原因统一为字符串(底层可能抛出非字符串错误值, 不规范化会让日志无法定位)
                if not ok2 and type(res2) ~= "string" then
                    res2 = tostring(res2)
                end
                return ok2, res2
            end
            return false, describe_http_error(code) .. (next_url and " (重定向次数过多)" or "")
        end

        if type(code) == "number" and code >= 200 and code < 300 then
            -- Range 被忽略(回 200 全量)但本地已有半段: 清掉重下
            if start_offset > 0 and code == 200 then
                return nil, "restart"
            end
            if code == 206 then
                -- Content-Range: bytes s-e/total; 无头时退回 content-length(剩余量)
                local cr = resp_headers and resp_headers["content-range"]
                local t = cr and tonumber(cr:match("/(%d+)%s*$"))
                if not t then
                    local cl = resp_headers and tonumber(resp_headers["content-length"])
                    t = cl and (start_offset + cl) or nil
                end
                total = t
            else
                total = resp_headers and tonumber(resp_headers["content-length"]) or nil
            end
            if total and downloaded < total then
                notify()
                return false, "incomplete"
            end
            notify()
            os.remove(dest)
            if not os.rename(tmp, dest) then
                return false, "rename failed"
            end
            -- 扩展名由 Content-Type 推导(调用方命名用; 无则 nil)
            local ctype = resp_headers and resp_headers["content-type"]
            ctype = ctype and ctype:gsub("%s*;.*$", "") or nil
            local ext = ctype and get_extension_from_mimetype(ctype) or nil
            return true, {bytes = downloaded, resumed = start_offset > 0, ext = ext,
                headers = resp_headers}
        end

        return false, describe_http_error(code)
    end

    local ok, res = attempt(false, url, 0)
    if ok then
        return true, res
    end
    if res == "restart" then
        -- 本地有半段但服务器不支持 Range: 清空重下
        os.remove(tmp)
        return attempt(true, url, 0)
    end
    -- 失败原因统一为字符串
    if type(res) ~= "string" then
        res = tostring(res)
    end
    return false, res
end

-- 表导出: pGetUrlContent(整载内存) / pStreamToFile(流式落盘+断点续传) /
-- get_default_headers(批量下载方应取一次后随每页传入, 避免逐页读设置文件)
-- (注意不能给函数值挂字段——Lua 函数不可索引, 此前因此炸过模块加载)
return {
    pGetUrlContent = pGetUrlContent,
    pStreamToFile = pStreamToFile,
    get_default_headers = get_default_headers,
}
