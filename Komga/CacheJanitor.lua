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

-- 收集可清理文件: {path=, size=, atime=}
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
                            atime = attr.access or attr.modification or 0,
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

-- 按 atime 从旧到新删除, 直到总占用 <= limit_bytes。
-- 返回 {removed=, freed=, total=(清理后)}
function M.enforceLimit(root, limit_bytes)
    local util = require("util")
    local files = M.collectEvictable(root)
    local total = 0
    for _, f in ipairs(files) do
        total = total + f.size
    end
    table.sort(files, function(a, b)
        return a.atime < b.atime
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
    return {removed = removed, freed = freed, total = total}
end

return M
