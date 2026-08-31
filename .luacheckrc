-- luacheck 配置(参考 comicreader.koplugin / KOReader 上游)
-- 运行: luacheck Komga/ patches/ main.lua
-- 当前仓库存量告警较多, 先以 warning-only 引入, 不阻塞提交;
-- 新增代码请保持 0 error。
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

-- 测试与参考目录不检查
exclude_files = {
    "spec/**",
}
