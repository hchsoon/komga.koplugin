--[[ Komga/BackendProfiles.lua — 设置持久化/一次性迁移/多服务器配置(自 Backend 拆出)

install(M) 把方法装回 Backend 表; wrap_response 经 M 字段做 local 别名, 函数体零改动。
]]
local dbg = require("dbg")
local LuaSettings = require("luasettings")
local socket_url = require("socket.url")
local util = require("util")
local md5 = require("ffi/sha2").md5
local Config = require("Komga/Config")
local H = require("Komga/Helper")

return function(M)
local wrap_response = M.wrap_response
-- 新增迁移只需往表里加 {name, check, run}, 不要在 initialize 里散落 if 分支。
local ONE_TIME_MIGRATIONS = {
    {
        name = "<1.038 setting_url 继承 komga_server",
        check = function(d)
            return d.setting_url == nil and d.reader3_un == nil and H.is_str(d.komga_server)
        end,
        run = function(d)
            d.setting_url = d.komga_server
        end
    },
    {
        name = "<1.049 server_address 继承 komga_server",
        check = function(d)
            return d.server_address == nil and H.is_str(d.komga_server)
        end,
        run = function(d)
            d.server_address = d.komga_server
            d.komga_server = nil
        end
    },
    {
        name = "api_key 缺省补默认值",
        check = function(d)
            return not H.is_str(d.api_key)
        end,
        run = function(d)
            d.api_key = Config.DEFAULT_API_KEY
        end
    }
}

function M:runOneTimeMigrations()
    local dirty = false
    for _, migration in ipairs(ONE_TIME_MIGRATIONS) do
        if migration.check(self.settings_data.data) then
            migration.run(self.settings_data.data)
            dirty = true
            dbg.v('settings migration applied:', migration.name)
        end
    end
    if dirty then
        self.settings_data:flush()
    end
end

function M:getServerPathCode()
    if self.settings_data.data['server_address_md5'] == nil then
        local server_address_md5 = socket_url.parse(self.settings_data.data['server_address']).host
        self.settings_data.data['server_address_md5'] = md5(server_address_md5)
        self:saveSettings()
    end
    return tostring(self.settings_data.data['server_address_md5'])
end

function M:getSettings()
    return self.settings_data.data
end

-- 当前生效的 X-API-Key: 设置项 api_key, 未设置/为空时回落代码预设值
function M:getApiKey()
    local key = self.settings_data and self.settings_data.data and self.settings_data.data.api_key
    if H.is_str(key) and key ~= '' then
        return key
    end
    return Config.DEFAULT_API_KEY
end

-- 设置 X-API-Key(立即持久化生效)
function M:setApiKey(new_api_key)
    if not H.is_str(new_api_key) or new_api_key == '' then
        return wrap_response(nil, 'API Key 不能为空')
    end
    if not self.settings_data or not self.settings_data.data then
        return wrap_response(nil, '设置未初始化')
    end
    self.settings_data.data.api_key = new_api_key
    self.settings_data:flush()
    return wrap_response(self.settings_data.data)
end

-- ---------------------------------------------------------------------------
-- 多服务器配置(场景: 家里局域网地址 ↔ 外网域名 一键切换)
-- 配置存于设置项 server_profiles = { {name, server_address, api_key}, ... };
-- 当前生效值仍为 server_address/api_key 两个字段(向后兼容)。
-- ---------------------------------------------------------------------------
function M:getServerProfiles()
    if not self.settings_data then
        return {}
    end
    local profiles = self.settings_data.data.server_profiles
    if not H.is_tbl(profiles) then
        return {}
    end
    return profiles
end

-- 保存当前生效的服务器为一份具名配置(同名覆盖)
function M:saveServerProfile(name)
    if not (H.is_str(name) and name ~= "") then
        return wrap_response(nil, '配置名不能为空')
    end
    local data = self.settings_data and self.settings_data.data
    if not (H.is_tbl(data) and H.is_str(data.server_address)) then
        return wrap_response(nil, '设置未初始化')
    end
    local profiles = H.is_tbl(data.server_profiles) and data.server_profiles or {}
    local entry = {
        name = name,
        server_address = data.server_address,
        api_key = H.is_str(data.api_key) and data.api_key or "",
    }
    local replaced = false
    for i, p in ipairs(profiles) do
        if p.name == name then
            profiles[i] = entry
            replaced = true
            break
        end
    end
    if not replaced then
        table.insert(profiles, entry)
    end
    data.server_profiles = profiles
    self.settings_data:flush()
    return wrap_response(profiles)
end

-- 删除具名配置
function M:deleteServerProfile(name)
    if not H.is_str(name) then
        return wrap_response(nil, '参数错误')
    end
    local data = self.settings_data and self.settings_data.data
    local profiles = H.is_tbl(data and data.server_profiles) and data.server_profiles or {}
    local kept = {}
    for _, p in ipairs(profiles) do
        if p.name ~= name then
            table.insert(kept, p)
        end
    end
    data.server_profiles = kept
    self.settings_data:flush()
    return wrap_response(kept)
end

-- 切换到具名配置(立即生效: 重建 REST 客户端, 无需重启)
function M:switchServerProfile(name)
    if not H.is_str(name) then
        return wrap_response(nil, '参数错误')
    end
    local data = self.settings_data and self.settings_data.data
    if not H.is_tbl(data) then
        return wrap_response(nil, '设置未初始化')
    end
    local target
    for _, p in ipairs(self:getServerProfiles()) do
        if p.name == name then
            target = p
            break
        end
    end
    if not H.is_tbl(target) then
        return wrap_response(nil, '配置不存在: ' .. name)
    end
    -- 地址无变化时仅同步 key, 避免无谓的客户端重建
    local address_changed = (data.server_address ~= target.server_address)
    data.server_address = target.server_address
    if H.is_str(target.api_key) and target.api_key ~= "" then
        data.api_key = target.api_key
    end
    -- 书架分组键按主机 md5 派生, 换服务器必须失效重算
    data.server_address_md5 = nil
    self.settings_data:flush()
    if address_changed then
        self:loadApiClient()
    end
    return wrap_response(self.settings_data.data)
end

function M:saveSettings(settings)
    if H.is_tbl(settings) and H.is_str(self.settings_data.data.server_address) then
        if not H.is_str(settings.server_address) or not H.is_str(settings.chapter_sorting_mode) then
            return wrap_response(nil, '参数校检错误，保存失败')
        end
        self.settings_data.data = settings
    end
    self.settings_data:flush()
    self.settings_data = LuaSettings:open(H.getUserSettingsPath())
    return wrap_response(true)
end

function M:setEndpointUrl(new_setting_url)

    if not H.is_str(new_setting_url) or new_setting_url == '' then
        return wrap_response(nil, '参数校检错误，保存失败')
    end

    local parsed = socket_url.parse(new_setting_url)
    if not parsed then
        return wrap_response(nil, '地址不合规则，请检查')
    end

    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return wrap_response(nil, '不支持的协议，请检查')
    end

    if not parsed.host or parsed.host == "" then
        return wrap_response(nil, "没有主机名")
    end

    if parsed.port then
        local port_num = tonumber(parsed.port)
        if not port_num or port_num < 1 or port_num > 65535 then
            return wrap_response(nil, "端口号不正确")
        end
    end

    local settings = self.settings_data.data
    if parsed.user and parsed.user ~= "" then
        self.settings_data.data.reader3_un = util.urlDecode(parsed.user)
        self.settings_data.data.reader3_pwd = util.urlDecode(parsed.password)
    end

    local clean_url = socket_url.build(parsed)
    local old_setting_url = self.settings_data.data.setting_url
    -- dbg.log("server_address:", clean_url)
    self.settings_data.data.server_address = clean_url
    self.settings_data.data.setting_url = new_setting_url
    self.settings_data.data.server_address_md5 = md5(parsed.host)
    if not H.is_tbl(self.settings_data.data.servers_history) or not self.settings_data.data.servers_history[1] then
        self.settings_data.data.servers_history = {}
    end

    local function updateHistoryItem(history_table, item, max_size)
        local removed_old = false
        for i = #history_table, 1, -1 do
            if history_table[i] == item then
                table.remove(history_table, i)
                removed_old = true
                break
            end
        end
        table.insert(history_table, item)
        if max_size and max_size > 0 then
            while #history_table > max_size do
                table.remove(history_table, 1)
            end
        end
    end
    
    --添加历史记录
    updateHistoryItem(self.settings_data.data.servers_history, old_setting_url, 10)

    self:saveSettings()

    -- 服务器地址已变更, 重建 REST 客户端
    self:loadApiClient()

    return wrap_response(self.settings_data.data)
end

end
