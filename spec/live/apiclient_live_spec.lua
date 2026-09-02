-- ApiClient 真机集成测试(需要可达的 Komga 服务器)
-- 运行方式: KOMGA_TEST_SERVER=http://host:port KOMGA_TEST_KEY=xxx luajit spec/live/apiclient_live_spec.lua
-- 未设置环境变量时跳过(退出码 0)。

local server = os.getenv("KOMGA_TEST_SERVER")
local api_key = os.getenv("KOMGA_TEST_KEY")
if not server or not api_key then
    print("SKIP: 未设置 KOMGA_TEST_SERVER/KOMGA_TEST_KEY, 跳过真机用例")
    return
end

package.path = "./?.lua;" .. (os.getenv("KOREADER_ROOT") or "/Applications/KOReader.app/Contents/koreader") .. "/common/?.lua;" .. package.path
package.cpath = (os.getenv("KOREADER_ROOT") or "/Applications/KOReader.app/Contents/koreader") .. "/common/?.so;" .. package.cpath
package.preload["socket.url"] = function()
    return {escape = function(s) return (s:gsub("[^%w%-_%.!~%*%'%(%)%$%,%;]", function(c)
        return string.format("%%%02X", string.byte(c)) end)) end}
end

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end

local ApiClient = require("Komga/ApiClient")
local client = ApiClient:new(function() return server end, function() return api_key end)

local function curl_transport(options)
    local out = os.tmpname()
    local head = os.tmpname()
    local cmd = string.format("curl -s -m 20 -X %s", options.method or "GET")
    for k, v in pairs(options.headers or {}) do
        cmd = cmd .. string.format(" -H %q", k .. ": " .. v)
    end
    if options.source then
        local body = options.source()
        local bf = io.open(out .. ".body", "wb")
        bf:write(body or "")
        bf:close()
        cmd = cmd .. " --data-binary @" .. out .. ".body"
    end
    cmd = cmd .. string.format(" -D %s -o %s %q", head, out, options.url)
    os.execute(cmd)
    local headers = {}
    for line in io.lines(head) do
        local k, v = line:match("^([%w%-]+):%s*(.-)\r?$")
        if k then headers[k:lower()] = v end
    end
    local f = io.open(out, "rb")
    local data = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(out)
    os.remove(head)
    if options.source then os.remove(out .. ".body") end
    return true, {data = data, headers = headers}
end

T("GET /api/v1/libraries", function()
    local r = client:get("/api/v1/libraries", nil, {transport = curl_transport})
    if type(r) ~= "table" or type(r.body) ~= "table" then error("响应形状错误") end
end)
T("POST /series/list: size 必须在 query(分页回归)", function()
    local r = client:post("/api/v1/series/list", {size = 1000}, {fullTextSearch = ""}, {transport = curl_transport})
    local content = r and r.body and r.body.content
    if type(content) ~= "table" or #content == 0 then error("无 content") end
    local total = r.body.totalElements or #content
    if #content ~= total then error(string.format("分页截断: content=%d totalElements=%s", #content, tostring(total))) end
end)
T("GET 不存在资源: 非 JSON 404 体不误判成功", function()
    local r = client:get("/api/v1/books/NOPE123/books/next", nil, {transport = curl_transport})
    if type(r) == "table" and type(r.body) == "table" and r.body.id then error("404 不应解析出 id") end
end)

local failed = 0
for _, c in ipairs(checks) do
    local ok, err = pcall(c.fn)
    if ok then print("ok   " .. c.name)
    else failed = failed + 1 print("FAIL " .. c.name .. "  " .. tostring(err)) end
end
if failed > 0 then os.exit(1) end
print("\n真机用例全部通过 (" .. #checks .. ")")
