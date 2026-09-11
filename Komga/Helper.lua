local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ffiUtil = require("ffi/util")
local DataStorage = require("datastorage")

local M = {
    plugin_path = nil,
    plugin_name = nil
}

M.initialize = function(name, path)
    M.plugin_name = name
    -- fix Android path
    if type(path) == "string" then
        path = path:gsub("/+", "/")
    end
    M.plugin_path = path
end



M.is_str = function(s)
    return "string" == type(s)
end
M.is_num = function(s)
    return "number" == type(s)
end

M.is_func = function(s)
    return "function" == type(s)
end

M.is_tbl = function(t)
    return "table" == type(t)
end



-- pay attention to infinite recursion
M.deep_equal = function(a, b)
    return util.tableEquals(a, b, true)
end

M.errorHandler = function(err)
    err = tostring(err)
    -- remove stacktrace
    local detail = err:match("%.lua:%d+:%s*(.*)")
    if not detail then
        detail = err:match(".*%.lua:%d+:%s*(.*)")
    end
    return detail or err
end

M.isFileOlderThan = function(filepath, seconds)

    local attributes = lfs.attributes(filepath)
    if not attributes then
        return nil, "File not found or unable to access file."
    end

    local file_time = attributes.creation or attributes.modification
    if not file_time then
        return nil, "No valid file time found."
    end

    local time_difference = os.time() - file_time

    return time_difference > seconds, time_difference
end

M.copyFileFromTo = function(from, to)
    ffiUtil.copyFile(from, to)
    return true
end
M.joinPath = function(path1, path2)
    if string.sub(path2, 1, 1) == "/" then
        return path2
    end
    if string.sub(path1, -1, -1) ~= "/" then
        path1 = path1 .. "/"
    end
    return path1 .. path2
end

M.checkAndCreateFolder = function(d_path)
    if not util.directoryExists(d_path) then
        util.makePath(d_path)
        if not util.directoryExists(d_path) then
            os.execute(string.format('"mkdir -p "%s"', d_path))
        end
    end
    return d_path
end

M.getUserSettingsPath = function()
    return M.joinPath(DataStorage:getSettingsDir(), M.plugin_name .. '.lua')
end
M.getUserPatchesDirectory = function()
    local patches_dir = M.joinPath(DataStorage:getDataDir(), 'patches')
    return M.checkAndCreateFolder(patches_dir)
end
M.getTempDirectory = function()
    local plugin_cache_dir = M.plugin_name .. '.cache'
    local plugin_cache_path = M.joinPath(DataStorage:getDataDir(), 'cache/' .. plugin_cache_dir)
    return M.checkAndCreateFolder(plugin_cache_path)
end
M.getPluginDirectory = function()
    local plugin_path_bak = table.concat({DataStorage:getDataDir(), "/plugins/", M.plugin_name, '.koplugin'})
    return M.plugin_path or plugin_path_bak
end
M.getBookCachePath = function(book_cache_id)
    assert(type(book_cache_id) == "string", "Error: The variable is not a string.")
    local plugin_cache_path = M.getTempDirectory()
    local book_cache_path = M.joinPath(plugin_cache_path, book_cache_id .. '.sdr')
    M.checkAndCreateFolder(book_cache_path)
    M.checkAndCreateFolder(M.joinPath(book_cache_path, "resources"))
    return book_cache_path
end
M.getCoverCacheFilePath = function(book_cache_id)
    local book_cache_path = M.getBookCachePath(book_cache_id)
    return M.joinPath(book_cache_path, 'cover')
end
M.getVolumeCacheFilePath = function(book_cache_id, book_id, number, book_name)
    book_name = util.getSafeFilename(book_name)
    local book_cache_path = M.getBookCachePath(book_cache_id)
    local volume_cache_name = string.format("%s-%s-%s", book_name or "", book_id, number)
    return M.joinPath(book_cache_path, volume_cache_name)
end
M.getHomeDir = function()
    return G_reader_settings and G_reader_settings:readSetting("home_dir") or
               require("apps/filemanager/filemanagerutil").getDefaultDir()
end
-- 临时诊断: 关键链路直接落盘日志(append, 不依赖 logger/调试开关), 排查完可删
M.diagLog = function(msg)
    local ok, err = pcall(function()
        local f = io.open(M.getTempDirectory() .. "/komga_diag.log", "a")
        if f then
            f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n")
            f:close()
        end
    end)
    return ok, err
end
return M
