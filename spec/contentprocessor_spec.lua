-- ContentProcessor 运行时测试(管线回归防线)
-- 运行方式: luajit spec/contentprocessor_spec.lua
-- 依赖 KOReader app bundle 的 util/ffi 栈(自动探测 /Applications; 其他环境设 KOREADER_ROOT)。
-- 覆盖: 内容分类矩阵 / utf8_trim / 段落切分 / VolumePath 委托 / TEXT-MIXED 全链路。

local KR = os.getenv("KOREADER_ROOT") or "/Applications/KOReader.app/Contents/koreader"
package.path = "./?.lua;" .. KR .. "/common/?.lua;" .. KR .. "/frontend/?.lua;" .. KR .. "/?.lua;" .. KR .. "/ffi/?.lua;" .. package.path
package.cpath = KR .. "/common/?.so;" .. KR .. "/libs/?.so;" .. KR .. "/?.so;" .. KR .. "/ffi/?.so;" .. package.cpath

local ffi = require("ffi")
ffi.loadlib = ffi.loadlib or function(name, ver)
    return ffi.load(KR .. "/libs/lib" .. name .. (ver and ("." .. ver) or ""))
end
package.preload["ffi/utf8proc"] = function()
    return {lowercase = function(s) return s end}
end
package.preload["ffi/utf8proc_h"] = function() end
package.preload["socket.url"] = function()
    return {escape = function(s) return s end, parse = function(s) return {path = s} end,
        unescape = function(s) return s end, absolute = function(b, p) return b .. p end}
end
package.preload["device"] = function()
    return {screen = {getWidth = function() return 1000 end, getHeight = function() return 800 end,
        getSize = function() return {w = 1000, h = 800} end, scaleBySize = function(_, n) return n end},
        isTouchDevice = function() return false end}
end
package.preload["datastorage"] = function()
    return {getDataDir = function() return "/tmp/komga_spec_data" end,
        getFullDataDir = function() return "/tmp/komga_spec_data" end}
end
package.preload["dbg"] = function() return {v = function() end, log = function() end} end
package.preload["luasettings"] = function()
    return {open = function() return {data = {}, readSetting = function() end} end} end

local checks = {}
local function T(name, fn) table.insert(checks, {name = name, fn = fn}) end
local function eq(a, e, m) if a ~= e then error((m or "不等") .. ": 期望 " .. tostring(e) .. " 实际 " .. tostring(a), 2) end end

local CP = require("Komga/ContentProcessor")
local H = require("Komga/Helper")
if H.initialize then pcall(H.initialize, "komga", "/tmp/komga_spec_data") end

-- 分类矩阵(历史回归: 内部互调用裸名在抽取后变全局查找)
T("分类: 纯图=2", function() eq(CP.get_chapter_content_type('<img src="a.jpg"/>', nil), 2) end)
T("分类: 图文=3", function() eq(CP.get_chapter_content_type('<img/>文字', nil), 3) end)
T("分类: html 包裹=MIXED(原语义)", function() eq(CP.get_chapter_content_type('<html><img src="a.jpg"/></html>', nil), 3) end)
T("分类: xhtml 首行=4", function() eq(CP.get_chapter_content_type("<html>", "OEBPS/Text/S1.xhtml"), 4) end)
T("分类: 纯文本=1", function() eq(CP.get_chapter_content_type("正文", nil), 1) end)

T("utf8_trim 全角空格", function() eq(CP.utf8_trim("\u{3000}你好\u{0020}\u{0020}"), "你好") end)

T("段落切分: 内容完整(冒号调用回归)", function()
    local paras = CP.splitParagraphsPreserveBlank("第一段落内容。\r\n第二段落,内容更长一些。\r\n\r\n第三段。")
    if #paras < 2 then error("段落数不足") end
    local joined = table.concat(paras)
    if not joined:find("第一段落内容", 1, true) then error("段首内容被吞") end
end)

T("VolumePath 委托: basenameKey", function() eq(CP.normalize_rel_href("/a/b/Page1.html"), "page1") end)
T("plain_text_replace", function() eq(CP.plain_text_replace("a.b.c", ".", "-"), "a-b-c") end)

-- TEXT 分支全链路(无网络)
T("TEXT 分支: 分类->切分->落盘", function()
    local ctx = {settings_data = {data = {istxt = true}},
        getApiKey = function() return "k" end,
        isExtractingInBackground = function() return false end,
        getProxyImageUrl = function(_, url, src) return src end,
        getProxyEpubUrl = function(_, url, h) return h end}
    local volume = {book_cache_id = "SPECTEST", bookId = "BKSPEC", number = 3,
        name = "测试书名", title = "卷三"}
    local out = CP.process_volume_content(ctx, volume, "第一行正文内容。\r\n第二行更长的正文。")
    if not (type(out) == "table" and type(out.cacheFilePath) == "string") then error("无 cacheFilePath") end
    if not out.cacheFilePath:find("%.txt$") then error("istxt 应产出 .txt") end
    local f = io.open(out.cacheFilePath, "rb")
    local data = f and f:read("*a") or ""
    if f then f:close() end
    if not data:find("第一行正文内容", 1, true) then error("正文未落盘") end
    os.remove(out.cacheFilePath)
end)
local failed = 0
for _, c in ipairs(checks) do
    local ok, err = pcall(c.fn)
    if ok then
        print(string.format("ok   %s", c.name))
    else
        failed = failed + 1
        print(string.format("FAIL %s\n     %s", c.name, tostring(err)))
    end
end
if failed > 0 then
    print(string.format("\n%d/%d 用例失败", failed, #checks))
    os.exit(1)
end
print(string.format("\n全部通过 (%d 用例)", #checks))
