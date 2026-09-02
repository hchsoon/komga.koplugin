--[[
Komga/ContentProcessor.lua — 章节内容处理管线(纯函数部分, 自 Backend 拆出)

第一批: 文本/HTML 纯函数(无 IO/无 Backend 依赖)。后续批次再把 processLink 与
_processVolumeContent 整体迁入。Backend 通过局部别名保持全部调用点不变。
]]
local socket_url = require("socket.url")
local util = require("util")
local VolumePath = require("Komga/VolumePath")
local ffiUtil = require("ffi/util")

local M = {}
function M.plain_text_replace(text, pattern, replacement, count)
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
M.normalize_rel_href = function(href)
    return VolumePath.basenameKey(href)
end

-- 缓存的章节文件名: <安全书名>-<bookId>-<number>.<xhtml|html>, 与 H.getVolumeCacheFilePath 生成的路径一致
-- (扩展名随源页面 URL, 缺省 xhtml)
M.get_cached_chapter_filename = function(bookId, number, book_name, ext)
    return VolumePath.chapterFileName(util.getSafeFilename(book_name or ""), bookId, number, ext)
end
function M.get_chapter_content_type(txt, first_line)
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
            local is_other_content = M.has_other_content(txt)
            page_type = is_other_content and 3 or 2
        elseif M.has_img_tag(txt) then
            local is_other_content = M.has_other_content(txt)
            page_type = is_other_content and 3 or 2
        else
            page_type = 1
        end
    end
    return page_type
end
function M.has_other_content(text)
    if type(text) ~= "string" then
        return false
    end
    local without_img = text:gsub("<[iI][mM][gG][^>]+>", ""):gsub("\u{3000}", "")
    return without_img:find("%S") ~= nil
end
function M.has_img_tag(text)
    if type(text) ~= "string" then
        return false
    end
    return text:find("<[iI][mM][gG][^>]*>") ~= nil
end
function M.utf8_trim(str)
    if type(str) ~= "string" or str == "" then
        return ""
    end

    local whitespace = {
        [0x00A0] = true, [0x1680] = true,
        [0x2000] = true, [0x2001] = true, [0x2002] = true, [0x2003] = true,
        [0x2004] = true, [0x2005] = true, [0x2006] = true, [0x2007] = true,
        [0x2008] = true, [0x2009] = true, [0x200A] = true, [0x200B] = true,
        [0x202F] = true, [0x205F] = true, [0x3000] = true,
        [0x0009] = true, [0x000A] = true, [0x000B] = true,
        [0x000C] = true, [0x000D] = true, [0x0020] = true,
    }

    -- 字节级 UTF-8 遍历: 首字节定长, 逐字符取码点
    local function each_char(str, from)
        local b = string.byte(str, from)
        if not b then
            return nil
        end
        local len
        if b < 0x80 then len = 1
        elseif b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2
        else len = 1 end -- 孤立续字节按单字节容错
        local char = str:sub(from, from + len - 1)
        return from, ffiUtil.utf8charcode(char), char, from + len
    end

    local start
    local pos = 1
    while pos <= #str do
        local _, cp, _, next_pos = each_char(str, pos)
        if not cp then break end
        if not whitespace[cp] then
            start = pos
            break
        end
        pos = next_pos
    end
    if not start then
        return ""
    end

    local finish
    pos = #str
    while pos >= start do
        -- 从尾部回退到字符首字节
        while pos > 1 and string.byte(str, pos) >= 0x80 and string.byte(str, pos) < 0xC0 do
            pos = pos - 1
        end
        local _, cp, char, next_pos = each_char(str, pos)
        if not cp then break end
        if not whitespace[cp] then
            finish = next_pos - 1
            break
        end
        pos = pos - 1
    end

    return (finish and finish >= start) and str:sub(start, finish) or ""
end

function M.splitParagraphsPreserveBlank(text)
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
        line = M.utf8_trim(line)
        table.insert(lines, line)
    end

    -- 常见标点符号判断
    local isPunctuation = function(char)
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
function M.custom_urlEncode(str)

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
function M.get_url_extension(url)
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
function M.get_img_src(html)
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
return M
