--[[
Komga/ApiClient.lua — Komga REST 单一 HTTP 客户端(取代 Spore + KomgaSpec 双栈)

- 底层复用 Komga/HttpRequest.pGetUrlContent(socket.http), 编解码经 Komga/Json(rapidjson 优先)
- 请求头与旧 KomgaAuth/ForceJSON/FormatEpubJSON 中间件等价:
  X-API-Key / user-agent / Accept(含 Readium 媒体类型, /positions 与
  /progression 端点没有对应 Accept 会 406 Not Acceptable)
- 响应形状与旧 Spore 返回兼容: {status, body<table>, headers}
  204/空体 → {status=204, body={}}; JSON 家族按 content-type 解码;
  非 JSON 体原样返回字符串
- 供 Backend:komgaApi 包装(超时/错误映射/content 摘取语义不变)
]]
local Json = require("Komga/Json")
local ltn12 = require("ltn12")
local socket_url = require("socket.url")

local Paths = require("Komga/Paths")
local USER_AGENT = Paths.USER_AGENT -- (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+"
local ACCEPT = 'application/json,application/webpub+json,' ..
    'application/vnd.readium.position-list+json,application/vnd.readium.progression+json'

local ApiClient = {}
ApiClient.__index = ApiClient

function ApiClient:new(get_server_address, get_api_key)
    local o = {
        get_server_address = get_server_address,
        get_api_key = get_api_key
    }
    return setmetatable(o, self)
end

-- query 参数表 → URL 查询串(值经 socket.url.escape, 键为安全标识符)
function ApiClient:build_query(query)
    if type(query) ~= "table" then
        return nil
    end
    local parts = {}
    for k, v in pairs(query) do
        local vs
        if type(v) == "number" then
            vs = tostring(v)
        elseif type(v) == "string" then
            vs = socket_url.escape(v)
        else
            vs = tostring(v)
        end
        table.insert(parts, tostring(k) .. "=" .. vs)
    end
    if #parts < 1 then
        return nil
    end
    return table.concat(parts, "&")
end

-- method: GET/POST/PATCH/PUT; query: table; payload: table(JSON body); opts: {headers, timeouts}
-- 返回 {status, body, headers} 或 nil, err_msg
function ApiClient:request(method, path, query, payload, opts)
    opts = opts or {}
    local transport = opts.transport or self.transport
    if type(transport) ~= "function" then
        local Http = require("Komga/HttpRequest")
        transport = Http.pGetUrlContent
        self.transport = transport
    end

    local base = self.get_server_address() or ""
    base = base:gsub("/+$", "")
    local url = base .. path
    local qs = self:build_query(query)
    if qs then
        url = url .. "?" .. qs
    end

    local headers = {
        ["user-agent"] = USER_AGENT,
        ["accept"] = ACCEPT,
        ["X-API-Key"] = self.get_api_key()
    }
    if type(opts.headers) == "table" then
        for k, v in pairs(opts.headers) do
            headers[k] = v
        end
    end

    local body
    if payload ~= nil then
        body = Json.encode(payload)
        headers["content-type"] = "application/json"
        headers["content-length"] = tostring(#body)
    end

    local timeouts = opts.timeouts or {8, 12}
    local status, err = transport({
        url = url,
        method = method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        timeout = timeouts[1],
        maxtime = timeouts[2]
    })

    if not status then
        return nil, tostring(err)
    end
    if type(err) ~= "table" then
        return nil, "empty response"
    end

    local data = err.data
    -- 204/空体(如进度上报成功): 服务器确认但无响应体
    if type(data) ~= "string" or data == "" then
        return {status = 204, body = {}, headers = err.headers}
    end

    -- JSON 家族解码(与旧 FormatEpubJSON 中间件的 content-type 判定一致)
    local content_type = (err.headers and err.headers["content-type"]) or ""
    if content_type:find("application/json", 1, true)
        or content_type:find("application/webpub+json", 1, true)
        or content_type:find("application/vnd.readium.position-list+json", 1, true)
        or content_type:find("application/vnd.readium.progression+json", 1, true) then
        local decoded = Json.decode(data)
        if type(decoded) ~= "table" then
            return nil, "JSON decode failed"
        end
        return {status = 200, body = decoded, headers = err.headers}
    end

    -- 非 JSON 体原样返回
    return {status = 200, body = data, headers = err.headers}
end

function ApiClient:get(path, query, opts)
    return self:request("GET", path, query, nil, opts)
end

function ApiClient:post(path, query, payload, opts)
    return self:request("POST", path, query, payload, opts)
end

function ApiClient:put(path, query, payload, opts)
    return self:request("PUT", path, query, payload, opts)
end

function ApiClient:patch(path, query, payload, opts)
    return self:request("PATCH", path, query, payload, opts)
end

return ApiClient
