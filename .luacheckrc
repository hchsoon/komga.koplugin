-- luacheck 配置(参考 comicreader.koplugin / KOReader 上游)
-- 运行: luacheck Komga/ patches/ main.lua
-- 全局变量告警(111/112/113)必须保持开启: 曾有多处"nil 全局"笔误静默弄死功能
-- (StreamPageCache 预取/书架排序打点/跳章上限等), 靠的就是这组告警。
-- 其余风格类告警(遮蔽/空白行/超长行)warning-only, 不阻塞提交。
std = "lua51+luajit"

-- KOReader 运行时注入的全局
globals = {
    "G_reader_settings",
    "G_defaults",
    "G_compilation",
}

-- KOReader 惯例: 方法形参 self / 事件回调的冗余参数大量存在
self = false
unused_args = false
max_line_length = 160

-- 存量代码暂不修复的类别: 未用局部变量/变量遮蔽(渐进清理)
ignore = {
    "211", -- unused local
    "411", -- redefined local
    "212", -- unused argument
    "542", -- empty if branch
}

-- 测试与参考目录不检查; main.css.lua 是纯 CSS 资源, 非 Lua
exclude_files = {
    "spec/**",
    "Komga/main.css.lua",
}
