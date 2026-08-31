--[[
Komga/VolumePath.lua — 缓存文件名/URL 模式解析与双页配对(纯函数, 无 KOReader 依赖)

集中管理散落各处的字符串模式。EPUB 内部章节缓存扩展名随源页面 URL,
可能是 .xhtml 或 .html——历史上两次回归(渲染成源码/进度冻结)都是
某处硬编码 %.xhtml$ 漏掉 .html 造成的, 统一到此模块并配单元测试
(spec/volumepath_spec.lua, 可用 busted 或 luajit 直接运行)。
]]
local VolumePath = {}

-- ===== 内部章节缓存文件名: <安全书名>-<bookId>-<number>.<xhtml|html> =====

-- 从缓存文件全路径解析内部章节号(解析失败返回 nil)
function VolumePath.chapterIndex(file)
    if type(file) ~= "string" then
        return nil
    end
    return tonumber(file:match("%-(%d+)%.x?html$"))
end

-- 缓存文件扩展名: "xhtml" / "html" / nil(其他类型)
function VolumePath.fileExt(file)
    if type(file) ~= "string" then
        return nil
    end
    return file:match("%.(x?html)$")
end

-- 从缓存文件全路径解析 bookId
function VolumePath.bookIdOf(file)
    if type(file) ~= "string" then
        return nil
    end
    return file:match("-([%u%d]+)-%d+%.x?html$")
end

-- 缓存文件名前缀(到 <书名>-<bookId>- 为止, 不含章节号与扩展名)
function VolumePath.pathPrefix(file)
    if type(file) ~= "string" then
        return nil
    end
    return file:match("^(.*)-%d+%.x?html$")
end

-- 生成缓存章节文件名(book_name 需调用方先经 util.getSafeFilename 处理)
function VolumePath.chapterFileName(book_name, bookId, number, ext)
    return string.format("%s-%s-%s.%s", book_name or "", bookId, number, ext or "xhtml")
end

-- 章节链接匹配关键字: 取文件基名(去扩展名, 小写)。
-- epub 内部章节文件通常唯一命名(如 Section0031.xhtml), 而 DB 里 url 是
-- 完整资源 URL、xhtml 内部 href 是相对路径, 只有基名两边一致。
function VolumePath.basenameKey(href)
    if type(href) ~= "string" or href == "" then
        return nil
    end
    -- 全 URL(如 Komga /resource/ 资源地址)只取路径部分
    local u = href:gsub("^%a[%w+.-]*://[^/]+/", "")
    u = u:gsub("[?#].*", "")
    local name = u:match("([^/]+)$")
    if not name then
        return nil
    end
    name = name:gsub("%.x?html?$", "")
    if name == "" then
        return nil
    end
    return name:lower()
end

-- ===== 封面版本参数(?v=<服务器 lastModified>) =====

-- 封面 URL 的 ?v= 版本参数(无则 nil)
function VolumePath.coverVersion(url)
    if type(url) ~= "string" then
        return nil
    end
    return url:match("[?&]v=([^&]*)")
end

-- 版本串 URL 转义(lastModified 中的非字母数字 → %XX)
function VolumePath.escapeVersion(v)
    if type(v) ~= "string" or v == "" then
        return ""
    end
    return (v:gsub("[^%w]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- ===== 双页(对页)配对 — 移植自 comicreader.koplugin =====

-- 页码 → 双页模式基页(页对的起始页):
--   first_is_cover = true : 封面(第1页)独占, 之后 (2,3)(4,5)...(漫画书标准拼页)
--   first_is_cover = false: (1,2)(3,4)...
function VolumePath.dualBaseFromPage(page, first_is_cover)
    if type(page) ~= "number" or page == 0 then
        page = 1
    end
    if page < 1 then
        page = 1
    end
    if first_is_cover and page == 1 then
        return 1
    end
    if first_is_cover then
        return (page % 2 == 0) and page or (page - 1)
    end
    return (page % 2 == 1) and page or (page - 1)
end

-- 基页 → 页对数组(总页数 total 内截断)。
-- rtl = true 时返回显示顺序为右→左(右开本: 基页显示在右侧)。
function VolumePath.dualPairFromBase(base, total, first_is_cover, rtl)
    local pair_base = VolumePath.dualBaseFromPage(base, first_is_cover)
    if first_is_cover and pair_base == 1 then
        return {1}
    end
    local pair = {pair_base}
    if not total or (pair_base + 1) <= total then
        table.insert(pair, pair_base + 1)
    end
    if rtl then
        local n = #pair
        for i = 1, math.floor(n / 2) do
            pair[i], pair[n - i + 1] = pair[n - i + 1], pair[i]
        end
    end
    return pair
end

return VolumePath
