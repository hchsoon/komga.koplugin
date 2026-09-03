--[[
Komga/MemCleaner.lua — 内存清理(rakuyomi fork 的 "cleaner to free up memory" 思路)

- sweep(): 双轮 collectgarbage, 返回清理前后 Lua 内存(KB)
- 大对象引用的释放由各持有方在自身关闭路径完成(如流式页缓存),
  这里只负责把可回收对象真正交给分配器
]]
local M = {}

function M.usedKB()
    return math.floor(collectgarbage("count"))
end

-- 返回 {before, after, freed}; freed 为 KB
function M.sweep()
    local before = M.usedKB()
    collectgarbage("collect")
    collectgarbage("collect")
    local after = M.usedKB()
    return {
        before = before,
        after = after,
        freed = math.max(before - after, 0),
    }
end

return M
