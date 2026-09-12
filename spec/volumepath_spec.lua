-- VolumePath 单元测试
-- 运行方式:
--   busted spec/                      (有 busted 时)
--   luajit spec/volumepath_spec.lua   (无 busted, 内置迷你断言直接跑)
-- 覆盖历史回归点: EPUB 内部章节缓存可能为 .xhtml 或 .html(随源页面 URL),
-- 任何新增调用点请走 VolumePath, 不要在业务代码里重写模式。

package.path = "./?.lua;" .. package.path

local VP = require("Komga/VolumePath")

local checks = {}
local function T(name, fn)
    table.insert(checks, {name = name, fn = fn})
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: 期望 %q, 实际 %q", msg or "不等", tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then
        error(tostring(msg or "应为真"), 2)
    end
end

-- ===== chapterIndex: 内部章节号解析(历史回归: .html 文件解析不出导致进度冻结) =====
T("chapterIndex 解析 .html 缓存文件", function()
    eq(VP.chapterIndex("/path/女校之星-0RF8YN5NVADW9-2.html"), 2)
    eq(VP.chapterIndex("女校之星-0RF8YN5NVADW8-1.html"), 1)
end)

T("chapterIndex 解析 .xhtml 缓存文件", function()
    eq(VP.chapterIndex("/path/无职转生-0RE05D8BZD1VG-14.xhtml"), 14)
    eq(VP.chapterIndex("x-0RE05D8BZD1VG-8.xhtml"), 8)
end)

T("chapterIndex 非 x/html 扩展名返回 nil", function()
    eq(VP.chapterIndex("x-0RF8YN5NVADW8-1.css"), nil)
    eq(VP.chapterIndex("x-0RF8YN5NVADW8-1.jpg"), nil)
    eq(VP.chapterIndex(nil), nil)
end)

-- ===== chapterFileName =====
T("chapterFileName 生成文件名(默认/显式扩展)", function()
    eq(VP.chapterFileName("书名", "B1", 3), "书名-B1-3.xhtml")
    eq(VP.chapterFileName("书名", "B1", 3, "html"), "书名-B1-3.html")
    eq(VP.chapterFileName(nil, "B1", 3), "-B1-3.xhtml")
end)

-- ===== basenameKey: 链接基名匹配 =====
T("basenameKey 相对路径/全 URL/查询串", function()
    eq(VP.basenameKey("../Text/Section007.xhtml"), "section007")
    eq(VP.basenameKey("http://h/api/v1/books/B/resource/OEBPS/Text/page-1.html"), "page-1")
    eq(VP.basenameKey("cover.jpg.html?v=1"), "cover.jpg")
    eq(VP.basenameKey(""), nil)
    eq(VP.basenameKey(nil), nil)
end)

-- ===== escapeVersion =====
T("escapeVersion URL 转义", function()
    local lm = "2026-08-30T14:45:28.123Z"
    local escaped = VP.escapeVersion(lm)
    eq(escaped, "2026%2D08%2D30T14%3A45%3A28%2E123Z")
    eq(VP.escapeVersion(""), "")
    eq(VP.escapeVersion(nil), "")
end)

-- ===== 双页配对(移植自 comicreader) =====
T("dualBaseFromPage 首页为封面: 封面独占, 之后偶数基页", function()
    eq(VP.dualBaseFromPage(1, true), 1)
    eq(VP.dualBaseFromPage(2, true), 2)
    eq(VP.dualBaseFromPage(3, true), 2)
    eq(VP.dualBaseFromPage(4, true), 4)
    eq(VP.dualBaseFromPage(5, true), 4)
end)

T("dualBaseFromPage 无封面特判: 奇数基页", function()
    eq(VP.dualBaseFromPage(1, false), 1)
    eq(VP.dualBaseFromPage(2, false), 1)
    eq(VP.dualBaseFromPage(3, false), 3)
    eq(VP.dualBaseFromPage(4, false), 3)
end)

T("dualBaseFromPage 非法页码回退第 1 页", function()
    eq(VP.dualBaseFromPage(nil, true), 1)
    eq(VP.dualBaseFromPage(0, true), 1)
    eq(VP.dualBaseFromPage(-3, false), 1)
end)

T("dualPairFromBase 封面独占 + 尾单页截断", function()
    local p1 = VP.dualPairFromBase(1, 10, true, false)
    eq(#p1, 1); eq(p1[1], 1)
    local p2 = VP.dualPairFromBase(2, 10, true, false)
    eq(#p2, 2); eq(p2[1], 2); eq(p2[2], 3)
    local plast = VP.dualPairFromBase(10, 11, true, false) -- 总页 11: (10,11)
    eq(#plast, 2); eq(plast[2], 11)
    local ptail = VP.dualPairFromBase(11, 11, true, false) -- 11 落回 10
    eq(ptail[1], 10)
end)

T("dualPairFromBase LTR/RTL 顺序", function()
    local ltr = VP.dualPairFromBase(4, 10, true, false)
    eq(ltr[1], 4); eq(ltr[2], 5)
    local rtl = VP.dualPairFromBase(4, 10, true, true)
    eq(rtl[1], 5); eq(rtl[2], 4) -- 右开本: 基页在右侧(显示顺序右→左)
end)

T("dualPairFromBase 无 total 时不截断", function()
    local p = VP.dualPairFromBase(4, nil, true, false)
    eq(#p, 2); eq(p[2], 5)
end)

-- ===== 双模式执行入口 =====
if type(describe) == "function" and type(it) == "function" then
    describe("Komga/VolumePath", function()
        for _, c in ipairs(checks) do
            it(c.name, c.fn)
        end
    end)
else
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
    truthy(#checks >= 12, "用例数量异常")
    if failed > 0 then
        print(string.format("\n%d/%d 用例失败", failed, #checks))
        os.exit(1)
    end
    print(string.format("\n全部通过 (%d 用例)", #checks))
end
