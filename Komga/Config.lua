--[[
Komga/Config.lua — 插件预设默认值(唯一来源)

host(服务器地址)与 X-API-Key 在旧版中是散落在代码里的写死字面量。
现在统一收敛到此模块: 运行时值由设置项(server_address / api_key)驱动,
设置缺失时回落到这里定义的代码预设值。
]]

return {
    -- 服务器地址预设值(实际值由设置项 server_address 覆盖)
    DEFAULT_SERVER_ADDRESS = "http://192.168.1.18:10102",
    -- API Key 预设值(实际值由设置项 api_key 覆盖)
    DEFAULT_API_KEY = "451e132996b44937b1576242447d9cd2",
}
