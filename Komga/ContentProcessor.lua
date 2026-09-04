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

-- 常量集合提升到模块级: 原先在 utf8_trim / isPunctuation 内每次调用重建
-- (utf8_trim 逐行调用, isPunctuation 逐字符调用)
local WHITESPACE_CP = {
    [0x00A0] = true, [0x1680] = true,
    [0x2000] = true, [0x2001] = true, [0x2002] = true, [0x2003] = true,
    [0x2004] = true, [0x2005] = true, [0x2006] = true, [0x2007] = true,
    [0x2008] = true, [0x2009] = true, [0x200A] = true, [0x200B] = true,
    [0x202F] = true, [0x205F] = true, [0x3000] = true,
    [0x0009] = true, [0x000A] = true, [0x000B] = true,
    [0x000C] = true, [0x000D] = true, [0x0020] = true,
}

local PUNCTUATION_CHARS = {
    ["\u{0021}"] = true, -- !
    ["\u{002C}"] = true, -- ,
    ["\u{002E}"] = true, -- .
    ["\u{003A}"] = true, -- :
    ["\u{003B}"] = true, -- ;
    ["\u{003F}"] = true, -- ?
    ["\u{3001}"] = true, -- 、
    ["\u{3002}"] = true, -- 。
    ["\u{FF0C}"] = true, -- ，
    ["\u{FF0E}"] = true, -- ．
    ["\u{FF1A}"] = true, -- ：
    ["\u{FF1B}"] = true, -- ；
    ["\u{FF1F}"] = true, -- ？
    ["\u{2026}"] = true, -- …
    ["\u{00B7}"] = true, -- ·
    ["\u{2022}"] = true, -- •
    ["\u{FF5E}"] = true, -- ～
}

-- 全角空格(U+3000): 与 %s(仅 ASCII 空白)一并视作空白
local IDEOGRAPHIC_SPACE = "\u{3000}"
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
    -- 零复制: 原实现两次全文 gsub(img 标签剥离 + 全角空格)拷贝整串只为一次判空。
    -- 现按位置扫 img 标签(与原剥离同款 [^>]+ 模式, 保持逐输入行为一致),
    -- 只在标签间隙里找"非空白字符"(半角空白与 U+3000 之外)。
    local from = 1
    while true do
        local s, e = text:find("<[iI][mM][gG][^>]+>", from)
        local limit = (s or (#text + 1)) - 1
        local p = from
        while true do
            local q = text:find("%S", p)
            if not q or q > limit then
                break
            end
            if text:sub(q, q + #IDEOGRAPHIC_SPACE - 1) ~= IDEOGRAPHIC_SPACE then
                return true
            end
            p = q + #IDEOGRAPHIC_SPACE
        end
        if not s then
            return false
        end
        from = e + 1
    end
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

    local whitespace = WHITESPACE_CP

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

        if PUNCTUATION_CHARS[char] then
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

-- chapter content pipeline (tranche 2, moved from Backend)
-- ctx = Backend instance (settings/api/dbManager)

local md5 = require("ffi/sha2").md5
local logger = require("logger")
local dbg = require("dbg")
local H = require("Komga/Helper")

local HttpRequest
local function pGetUrlContent(options)
    HttpRequest = HttpRequest or require("Komga/HttpRequest")
    return HttpRequest.pGetUrlContent(options, true)
end

local get_url_extension = M.get_url_extension
local plain_text_replace = M.plain_text_replace
local splitParagraphsPreserveBlank = M.splitParagraphsPreserveBlank
local get_chapter_content_type = M.get_chapter_content_type
local normalize_rel_href = M.normalize_rel_href
local get_cached_chapter_filename = M.get_cached_chapter_filename

local processLink

local pDownload_CreateCBZ = function(ctx, filePath, img_sources)

    dbg.v('CreateCBZ strat:')

    if not filePath or not H.is_tbl(img_sources) then
        error("Cbz param error:")
    end


    local cbz_path_tmp = filePath .. '.downloading'

    if util.fileExists(cbz_path_tmp) then
        if ctx:isExtractingInBackground() == true then
            error("Other threads downloading, cancelled")
        else
            util.removeFile(cbz_path_tmp)
        end
    end

    local ZipWriter = require("ffi/zipwriter")

    local cbz = ZipWriter:new{}
    if not cbz:open(cbz_path_tmp) then
        error('CreateCBZ cbz:open err')
    end
    cbz:add("mimetype", "application/vnd.comicbook+zip", true)

    local no_compression = true

    for i, img_src in ipairs(img_sources) do

        dbg.v('Download_Image start', i, img_src)
        local status, err = pGetUrlContent({
                url = img_src,
                timeout = 15,
                maxtime = 60
        })

        if status and H.is_tbl(err) and err['data'] then

            local imgdata = err['data']
            local img_extension = err['ext']
            if not img_extension or img_extension == "" then
                img_extension = M.get_url_extension(img_src)
            end

            local img_name = string.format("%d.%s", i, img_extension or "")

            cbz:add(img_name, imgdata, no_compression)

        else
            dbg.v('Download_Image err', tostring(err))
        end
    end

    cbz:close()
    dbg.v('CreateCBZ cbz:close')

    if util.fileExists(filePath) ~= true then
        os.rename(cbz_path_tmp, filePath)
    else
        if util.fileExists(cbz_path_tmp) == true then
            util.removeFile(cbz_path_tmp)
        end
        error('exist target file, cancelled')
    end

    return filePath
end
local book_chapter_resources = function(book_cache_id, filename, res_data, overwrite)

    if not book_cache_id then
        return
    end

    local catalogue, relpath, filepath

    catalogue = string.format("%s/resources", H.getBookCachePath(book_cache_id))
    if H.is_str(filename) then
        relpath = string.format("resources/%s", filename)
        filepath = string.format("%s/%s", catalogue, filename)
    end

    if res_data and (overwrite or not util.fileExists(filepath or "")) then
        H.checkAndCreateFolder(catalogue)
        -- 原子写: 先写 .part 再 rename, 避免进程被杀/断电留下半写文件
        -- 被存在性检查误判为有效缓存
        local tmp_path = filepath .. '.part'
        if util.writeToFile(res_data, tmp_path, true) then
            os.rename(tmp_path, filepath)
        end
    end

    return relpath, filepath, catalogue
end
local volume_writeToFile = function(volume, filePath, resources)
    if util.fileExists(filePath) then
        if volume.is_pre_loading == true then
            error('存在目标任务，本次任务取消')
        else
            volume.cacheFilePath = filePath
            return volume
        end
    end

    -- 原子写: 先写 .part 再 rename, 半写文件不会被存在性检查误判为有效缓存
    local tmp_path = filePath .. '.part'
    if util.writeToFile(resources, tmp_path, true) and os.rename(tmp_path, filePath) then

        if volume.is_pre_loading == true then
            dbg.v('Cache task completed volume.title', volume.title or '')
        end

        volume.cacheFilePath = filePath
        return volume
    else
        error('下载 content 写入失败')
    end
end
local replace_css_urls = function(css_text, replace_fn)
    css_text = tostring(css_text or "")
    return (css_text:gsub("url%s*%((%s*['\"]?)(.-)(['\"]?%s*)%)", function(prefix, old_path, suffix)
        if type(old_path) ~= "string" or old_path == "" or old_path:lower():find("^data:") then
            return
        end
        local ok, new_path = pcall(replace_fn, old_path)
        if not ok or type(new_path) ~= "string" or new_path == "" then
            return "url(" .. prefix .. old_path .. suffix .. ")"
        end
        return
    end))
end
local processLink
processLink = function(ctx, book_cache_id, resources_src, base_url, is_porxy, callback)
    if not (H.is_str(book_cache_id) and H.is_str(resources_src) and resources_src ~= "") then
        logger.dbg("invalid params in processLink", book_cache_id, resources_src)
        return nil
    end

    local processed_src
    if is_porxy == true then
        local url = base_url
        processed_src = ctx:getProxyImageUrl(url, resources_src)
    else
        processed_src = util.trim(resources_src)

        local lower_src = processed_src:lower()
        if lower_src:find("^data:") then
            logger.dbg("skipping data URI", processed_src)
            return nil
        elseif lower_src:find("^res:") then
            logger.dbg("fonts css URI", processed_src)
            return nil
        elseif lower_src:sub(1, 1) == "#" then
            return nil
        elseif lower_src:sub(1, 2) == "//" then
            processed_src = "https:" .. processed_src
        elseif lower_src:sub(1, 1) == "/" then
            processed_src = socket_url.absolute(base_url, processed_src)
        elseif not lower_src:find("^http") then
            processed_src = socket_url.absolute(base_url, processed_src)
        end
    end

    local ext = M.get_url_extension(processed_src)
    if ext == "" then
        local clean_url = resources_src:gsub("[#?].*", "")
        ext = M.get_url_extension(clean_url)
        if ext == "" then
            -- komga app 图片后带数据 v07ew.jpg,{'headers':{'referer':'https://m.weibo.cn'}}"
            clean_url = resources_src:match("^(.-),") or resources_src
            ext = M.get_url_extension(clean_url)
        end
    end

    -- logger.info("src_ext", ext, "resources_src", resources_src)
    local resources_id = md5(processed_src)
    local resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id

    local resources_relpath, resources_filepath, resources_catalogue =
        book_chapter_resources(book_cache_id, resources_filename)
    -- logger.info(resources_relpath, resources_filepath, resources_catalogue)

    -- 已有缓存
    if ext ~= "" and resources_filepath and util.fileExists(resources_filepath) then
        return resources_relpath
    end

    -- 流式落盘快速路径: 扩展名已知且无需内容加工(非 css 级联)的资源直接下载到文件,
    -- 不整载内存(大图内存峰值显著降低), 中断可 Range 续传; 失败回退下方内存路径
    if ext ~= "" and resources_filepath and not callback then
        local ok_dl = pcall(function()
            if not M.httpReq then
                M.httpReq = require("Komga.HttpRequest")
            end
            H.checkAndCreateFolder(resources_catalogue)
            local ok, res = M.httpReq.pStreamToFile({
                url = processed_src,
                dest = resources_filepath,
                timeout = 15,
                maxtime = 60
            })
            return ok == true
        end)
        if ok_dl then
            return resources_relpath
        end
        logger.dbg("processLink stream fallback to memory:", processed_src)
    end

    local status, err = pGetUrlContent({
                url = processed_src,
                timeout = 15,
                maxtime = 60
        })
    if status and H.is_tbl(err) and err["data"] then
        if not ext or ext == "" then
            ext = err["ext"] or ""
            resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id
        end

        -- 尝试处理css里面的级联
        if ext == "css_disable" and not callback then
            err["data"] = replace_css_urls(err["data"], function(url)
                -- 防止循环引用
                if url == resources_src then
                    return url
                end
                return processLink(ctx, book_cache_id, url, processed_src, nil, true)
            end)

        end

        return book_chapter_resources(book_cache_id, resources_filename, err["data"])
    end

end
local txt2html = function(book_cache_id, content, title)
    local dropcaps
    local lines = {}
    content = content or ""
    title = title or ""

    for line in util.gsplit(content, "\n", false, true) do
        line = M.utf8_trim(line)
        local el_tags

        if dropcaps ~= true and line ~= "" and not string.find(line, "<img", 1, true) then
            -- 尝试清理重复标题 >9 避免单字误判
            if #title > 9 and string.find(line, title, 1, true) == 1 then
                line = M.plain_text_replace(line, title, "", 1)
                line = M.utf8_trim(line)
                if line == "" then
                    -- 抛弃仅重复标题行
                    goto continue
                end
            end
            
            local rep_text = line:match(util.UTF8_CHAR_PATTERN)
            
            -- [修复] 增加对 rep_text 的有效性检查
            if rep_text and rep_text ~= "" then
                -- 只有在成功获取到首字符时，才进行替换和格式化
                line = M.plain_text_replace(line, rep_text, "", 1)
                el_tags = string.format('<p style="text-indent: 0em;"><span class="duokan-dropcaps-two">%s</span>%s</p>',
                    rep_text, line)
                dropcaps = true
            else
                -- 如果没有有效的首字符（例如，行是空的或只包含不可见字符），则作为普通段落处理
                el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
            end
        else
            el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
        end
        table.insert(lines, el_tags)
        ::continue::
    end

    if #lines > 0 then
        content = table.concat(lines)
    end

    local epub = require("Komga/EpubHelper")
    epub.addCssRes(book_cache_id)
    return epub.addchapterT(title, content)
end
local htmlparser
function M.process_volume_content(ctx, volume, content)

    local url = volume.url
    local book_cache_id = volume.book_cache_id
    local number = volume.number
    local chapter_title = volume.title or ''
    local down_number = volume.number

    if type(content) ~= "string" then
        content = tostring(content)
    end

    local filePath = H.getVolumeCacheFilePath(book_cache_id, volume.bookId, number, volume.name)

    local first_line = string.match(content, "([^\n]*)\n?") or content
    local PAGE_TYPES = {
        TEXT = 1, -- 纯文本
        IMAGE = 2, -- 纯图片
        MIXED = 3, -- 图文混合
        XHTML = 4, -- XHTML/EPUB
        MEDIA = 5 -- 音频/视频（??）
    }

    local page_type = M.get_chapter_content_type(content, first_line)
    -- logger.dbg("get_chapter_content_type:",page_type)
    -- print("page_type is..." , page_type);
    if page_type == PAGE_TYPES['IMAGE'] then
        local img_sources = ctx:getPorxyPicUrls(url, content)
        if H.is_tbl(img_sources) and #img_sources > 0 then

            -- 一张图片就不打包cbz了
            if #img_sources == 1 then
                local res_url = img_sources[1]
                local status, err = pGetUrlContent({
                        url = res_url,
                        timeout = 15,
                        maxtime = 60
                })
                if not status then
                    error('请求错误，' .. H.errorHandler(err))
                end
                if not (H.is_tbl(err) and err["data"]) then
                    error('下载失败，数据为空')
                end

                local ext = M.get_url_extension(res_url)
                if (not ext or ext == "") and not not err.ext then
                    ext = err['ext']
                end

                filePath = string.format("%s.%s", filePath, ext or "")
                return volume_writeToFile(volume, filePath, err['data'])
            else
                filePath = filePath .. '.cbz'
                local status, err = pcall(pDownload_CreateCBZ, filePath, img_sources)

                if not status then
                    error('CreateCBZ err:' .. H.errorHandler(err))
                end

                if volume.is_pre_loading == true then
                    dbg.v('Cache task completed volume.title:', chapter_title)
                end
            end
            volume.cacheFilePath = filePath
            return volume
        else
            error('生成图片列表失败')
        end

    elseif page_type == PAGE_TYPES['XHTML'] then

        local html_url = ctx:getProxyEpubUrl(url, first_line)
        -- logger.info("bookurl",url)
        -- logger.info("first_line",first_line)
        -- logger.info("html_url",html_url)
        if html_url == nil or html_url == '' then
            error('转换失败')
        end
        local status, err = pGetUrlContent({
                        url = html_url,
                        timeout = 15,
                        maxtime = 60
                })
        if not status then
            error('请求错误，' .. H.errorHandler(err))
        end
        if not (H.is_tbl(err) and err["data"]) then
            error('下载失败，数据为空')
        end
        -- TODO 写入原始文件名，用于导出
        local ext, original_name = M.get_url_extension(first_line)
        if (not ext or ext == "") and not not err.ext then
            ext = err['ext']
        end

        content = err['data'] or '下载失败'
        filePath = string.format("%s.%s", filePath, ext or "")

        if not htmlparser then
            htmlparser = require("htmlparser")
        end
        local success, root = pcall(htmlparser.parse, content, 5000)
        if success and root then

            local body = root("body")
            if body[1] then
                local img_pattern = "(<[Ii][Mm][Gg].-[Ss][Rr][Cc]%s*=%s*)(['\"])(.-)%2([^>]*>)"
                local image_xlink_pattern = '(<image.-href%s*=%s*)(["\'])(.-)%2([^>]*>)'
                local link_pattern = '(<link.-href%s*=%s*)(["\'])(.-)%2([^>]*>)'
                -- 单遍 gsub 统一改写(script 剥离 + link/svg-xlink/img 重定向)。
                -- 原先在此之上还有四段 htmlparser 元素循环(script 内容剔除/head link/
                -- body img/svg image), 逐元素 plain_text_replace 对全文做扫描替换
                -- (N 张图 = N 次全串拷贝, 二次方开销), 且与这遍 gsub 完全重复
                -- (下方 ^resources/ 跳过检查本就是为那批先行改写设计的), 故删。
                -- XHTML 属性中 URL 的 & 会转义成 &amp;, processLink 需要原始 URL, 先还原。
                local function decode_attr_url(path)
                    if type(path) == "string" and path:find("&", 1, true) then
                        return (path:gsub("&amp;", "&"))
                    end
                    return path
                end

                content = content:gsub("<script[^>]*>(.-\n?)</script>", ""):gsub("<script[^>]*>[\x00-\xFF]-</script>",
                    ""):gsub(link_pattern, function(r1, r2, r3, r4)
                    local open, path, close = r1, r3, r4
                    if not (open and open ~= "" and path and path ~= "" and string.find(path, "^resources/") == nil) then
                        return
                    end
                    local relpath = processLink(ctx, book_cache_id, decode_attr_url(path), html_url)
                    if H.is_str(relpath) then
                        r2 = r2 or ""
                        close = close or ""
                        return table.concat({open .. r2, relpath, r2 .. close})
                    end
                    return
                end):gsub(image_xlink_pattern, function(r1, r2, r3, r4)
                    local open, path, close = r1, r3, r4
                    if open and open ~= "" and path and string.find(path, "^resources/") == nil then
                        local relpath = processLink(ctx, book_cache_id, decode_attr_url(path), html_url)
                        if H.is_str(relpath) then
                            r2 = r2 or ""
                            close = close or ""
                            return table.concat({open .. r2, relpath, r2 .. close})
                        end
                    end
                    return
                end):gsub(img_pattern, function(r1, r2, r3, r4)
                    if r1 == "" or not r3 or string.find(r3, "^resources/") ~= nil then
                        return
                    end
                    local path = r3
                    local relpath = processLink(ctx, book_cache_id, decode_attr_url(path), html_url)
                    if H.is_str(relpath) then
                        return table.concat({r1, r2, relpath, r2, r4})
                    end
                    return
                end)

                -- === FIX: 重写内部章节链接与剩余相对路径 ===
                -- KOReader 用 document_dir 解析相对 href, 原 epub 的 ../Text/xx.xhtml
                -- 在扁平缓存目录下解析不到目标, 点击链接无反应。这里把指向其他章节的
                -- <a href> 改写成实际缓存文件名(<安全书名>-<bookId>-<index>.xhtml),
                -- 使其能通过 ReaderLink:openFileFromLink 打开并跳转。
                do
                    local href_map = {}
                    local href_ext = {} -- key → 缓存扩展名(xhtml/html, 随源页面 URL)
                    -- 优先用 manifest readingOrder(含全部章节 href→序号 映射)。
                    -- 注意: Lua pattern 里 '|' 是字面字符, 不能当"或"用, 故用 %.x?html$
                    if H.is_tbl(volume.readingOrder) then
                        for ro_idx, ro_item in ipairs(volume.readingOrder) do
                            if H.is_tbl(ro_item) and H.is_str(ro_item.href) and
                                ro_item.href:lower():match("%.x?html$") then
                                local key = M.normalize_rel_href(ro_item.href)
                                if key then
                                    href_map[key] = ro_idx
                                    href_ext[key] = ro_item.href:lower():match("%.(x?html)$")
                                end
                            end
                        end
                    end
                    -- 再用 DB 全量行补充(含 'No title' 子章节), 已有 key 不覆盖,
                    -- 这样即使 readingOrder 缺失/为空/过期也能构建出完整映射
                    local all_chs = ctx.dbManager:getAllEpubChapterUrls(volume.bookId)
                    if H.is_tbl(all_chs) then
                        for _, ch in ipairs(all_chs) do
                            if H.is_num(ch.number) and H.is_str(ch.url) then
                                local key = M.normalize_rel_href(ch.url)
                                if key and not href_map[key] then
                                    href_map[key] = ch.number
                                    href_ext[key] = ch.url:lower():match("%.(x?html)$")
                                end
                            end
                        end
                    end

                    if next(href_map) then
                        local cached_name = util.getSafeFilename(volume.name or "")
                        local bookId = volume.bookId
                        content = content:gsub('(<[Aa][^>]-href%s*=%s*)([\'"])(.-)%2',
                            function(open, quote, href)
                                if not H.is_str(href) or href == "" or href:sub(1, 1) == "#" then
                                    return open .. quote .. href .. quote
                                end
                                local key = M.normalize_rel_href(href)
                                local target_index = key and href_map[key]
                                if H.is_num(target_index) then
                                    return open .. quote ..
                                        M.get_cached_chapter_filename(bookId, target_index, cached_name,
                                            href_ext[key]) .. quote
                                end
                                return open .. quote .. href .. quote
                            end)
                    end

                    -- 内联 <style>/style 中的 url() 相对路径重写到 resources/(如 css 里引用的图片/字体)
                    content = content:gsub('url%s*%(%s*([\'"])?(.-)%1%s*%)', function(q, u)
                        if not H.is_str(u) or u == "" or u:sub(1, 1) == "#" or u:lower():find("^data:") then
                            return nil
                        end
                        local relpath = processLink(ctx, book_cache_id, u, html_url)
                        if H.is_str(relpath) then
                            return string.format("url(%s%s%s)", q or "", relpath, q or "")
                        end
                        return nil
                    end)
                end
            end
        end

        return volume_writeToFile(volume, filePath, content)

    elseif page_type == PAGE_TYPES['MIXED'] then
        -- 混合 img 标签和文本
        filePath = filePath .. '.html'
        local img_pattern = "(<[Ii][Mm][Gg].-[Ss][Rr][Cc]%s*=%s*)(['\"])(.-)%2([^>]*>)"
        if M.has_img_tag(content) then

            content = content:gsub(img_pattern, function(r1, r2, r3, r4)
                if not (r1 and r1 ~= "" and r3 and r3 ~= "") then
                    return
                end
                local path = r3
                local relpath = processLink(ctx, book_cache_id, path, url, true)
                if H.is_str(relpath) then
                    -- 随文图
                    return string.format('<div class="duokan-image-single">%s</div>',
                        table.concat({r1, r2, relpath, r2, ' class="picture-80" alt="" ', r4}))
                end
                return
            end)
        end

        content = txt2html(book_cache_id, content, chapter_title)
        return volume_writeToFile(volume, filePath, content)
    else
        -- TEXT
        if ctx.settings_data.data.istxt == true then
            filePath = filePath .. '.txt'
            local paragraphs = M.splitParagraphsPreserveBlank(content)
            if #paragraphs == 0 then
                volume.content_is_nil = true
            end
            first_line = paragraphs[1] or ""
            content = table.concat(paragraphs, "\n")
            paragraphs = nil

            if not string.find(first_line, chapter_title, 1, true) then
                content = table.concat({"\t\t", tostring(chapter_title), "\n\n", content})
            end
        else
            filePath = filePath .. '.html'
            content = txt2html(book_cache_id, content, chapter_title)
        end

        return volume_writeToFile(volume, filePath, content)
    end

end

M.process_link = processLink

return M
