--[[ Komga/Paths.lua — 快捷方式/缓存路径约定(纯常量与纯函数)

收敛散落各处的魔法串: 浏览器目录名(含零宽空格)、.html 快捷方式标记、
章节缓存目录片段、统一 User-Agent。无状态, 不依赖 Backend(设置值经参数
传入)避免模块环。patches/core.lua 因补丁运行环境不保证插件包可加载,
保留同名常量的本地副本, 改动这里时需同步。
]]

local M = {}

-- 零宽空格: 快捷方式文件名/目录名的标记字符, 用于与真实文档区分
M.ZWSP = "\u{200B}"

-- 快捷方式文件名后缀标记: <名称>\u{200B}.html
M.LNK_SUFFIX = M.ZWSP .. ".html"

-- Komga 浏览器根目录默认名(含零宽空格)
M.DEFAULT_BROWSER_DIR_NAME = "Komga" .. M.ZWSP .. "漫画"

-- 接受的浏览器目录名: 默认名 + 设置的自定义名(旧目录下的快捷方式仍可路由)
function M.browserDirNames(configured)
    local names = {M.DEFAULT_BROWSER_DIR_NAME}
    if type(configured) == "string" and configured ~= ""
        and configured ~= M.DEFAULT_BROWSER_DIR_NAME then
        names[#names + 1] = (configured:gsub("[/\\]", "_"))
    end
    return names
end

-- 路径是否位于 Komga 浏览器目录(默认名或自定义名)之下
function M.isKomgaBrowserDirPath(file_path, configured)
    if type(file_path) ~= "string" then
        return false
    end
    for _, name in ipairs(M.browserDirNames(configured)) do
        if file_path:find("/" .. name .. "/", 1, true) then
            return true
        end
    end
    return false
end

-- 本插件章节缓存目录片段(缓存文件路径识别用)
M.CACHE_DIR_SEGMENT = "/cache/komga.cache/"

-- 统一 User-Agent(此前 6 处相同字面量散落各模块)
M.USER_AGENT = "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) " ..
    "AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+"

return M
