--[[
Komga/CacheJanitor.lua — 缓存占用上限 + LRU 清理(参考 koobone download.lru_cleanup)

范围(安全子集): 各系列缓存目录下 resources/ 内的可再生文件
(md5 命名的 EPUB 资源、stream/ 流式页缓存)。这些文件缺失时管线会按需重新下载,
不涉及 DB 状态。**章节缓存文件(.xhtml/.html/.cbz/.txt)与封面不动**——
它们与 volume 表/快捷方式联动, 自动删除风险高, 仍走手动清理入口。
]]
local M = {}

local KEEP_PATTERNS = { "^cover%.jpg$", "^book_defaults%.lua$", "^cover_v%d+%.%w+$" }

local function is_kept(name)
    for _, pat in ipairs(KEEP_PATTERNS) do
        if name:match(pat) then
            return true
        end
    end
    return false
end

local function lfs_mod()
    return require("libs/libkoreader-lfs")
end

-- 收集可清理文件: {path=, size=, last_use=}
-- last_use 取 modification 优先: 缓存文件写后不变, mtime 即首次落盘时间;
-- atime 在 noatime/relatime 挂载下不更新, 作 LRU 依据会退化为创建序
function M.collectEvictable(root)
    local lfs = lfs_mod()
    local out = {}
    if not root then
        return out
    end
    local function walk(dir)
        local ok, iter = pcall(lfs.dir, dir)
        if not ok or not iter then
            return
        end
        for name in iter do
            if name ~= "." and name ~= ".." then
                local full = dir .. "/" .. name
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        walk(full)
                    elseif attr.mode == "file" and not is_kept(name) then
                        out[#out + 1] = {
                            path = full,
                            size = attr.size or 0,
                            last_use = attr.modification or attr.access or 0,
                        }
                    end
                end
            end
        end
    end
    walk(root)
    return out
end

function M.totalBytes(root)
    local total = 0
    for _, f in ipairs(M.collectEvictable(root)) do
        total = total + f.size
    end
    return total
end

-- 按 last_use 从旧到新删除, 直到总占用 <= limit_bytes; 结束后自深至浅删除空目录
-- (删空文件后残留的 resources/stream 等骨架目录)。
-- 返回 {removed=, freed=, total=(清理后), pruned=}
function M.enforceLimit(root, limit_bytes)
    local util = require("util")
    local files = M.collectEvictable(root)
    local total = 0
    for _, f in ipairs(files) do
        total = total + f.size
    end
    table.sort(files, function(a, b)
        return a.last_use < b.last_use
    end)
    local removed, freed = 0, 0
    for _, f in ipairs(files) do
        if total <= limit_bytes then
            break
        end
        if pcall(function()
            util.removeFile(f.path)
        end) then
            total = total - f.size
            freed = freed + f.size
            removed = removed + 1
        end
    end
    return {removed = removed, freed = freed, total = total, pruned = M.pruneEmptyDirs(root)}
end

-- 自深至浅删除空目录(root 本身保留); 非空目录 rmdir 失败即忽略
function M.pruneEmptyDirs(root)
    local lfs = lfs_mod()
    if not root then
        return 0
    end
    local dirs = {}
    local function walk(dir)
        local ok, iter = pcall(lfs.dir, dir)
        if not ok or not iter then
            return
        end
        dirs[#dirs + 1] = dir
        for name in iter do
            if name ~= "." and name ~= ".." then
                local full = dir .. "/" .. name
                local attr = lfs.attributes(full)
                if attr and attr.mode == "directory" then
                    walk(full)
                end
            end
        end
    end
    walk(root)
    local removed = 0
    for i = #dirs, 2, -1 do
        local ok = pcall(function()
            lfs.rmdir(dirs[i])
        end)
        if ok then
            removed = removed + 1
        end
    end
    return removed
end

return M
