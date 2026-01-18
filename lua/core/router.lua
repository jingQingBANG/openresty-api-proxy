-- core/router.lua
-- 路由模块：根据 URI 前缀路由到不同的后端服务

local _M = {}

-- Provider 配置
local providers = {
    ["/zerion"] = {
        provider = "zerion",
        upstream = "api.zerion.io",
        prefix_len = 7,  -- strlen("/zerion")
        auth_type = "basic"
    },
    ["/coingecko"] = {
        provider = "coingecko",
        upstream = "api.coingecko.com",
        prefix_len = 10, -- strlen("/coingecko")
        auth_type = "header"
    },
    ["/alchemy"] = {
        provider = "alchemy",
        upstream = "eth-mainnet.g.alchemy.com",
        prefix_len = 8,  -- strlen("/alchemy")
        auth_type = "url_param"
    }
}

function _M.route(uri)
    for prefix, config in pairs(providers) do
        if string.sub(uri, 1, #prefix) == prefix then
            -- 截取前缀后的路径部分
            local backend_path = string.sub(uri, config.prefix_len + 1)
            -- 如果路径为空，默认为 /
            if backend_path == "" then
                backend_path = "/"
            end
            
            return {
                provider = config.provider,
                upstream_host = config.upstream,
                backend_path = backend_path
            }
        end
    end
    return nil
end

-- 获取所有 Provider 列表
function _M.get_providers()
    local list = {}
    for prefix, config in pairs(providers) do
        table.insert(list, {
            prefix = prefix,
            provider = config.provider,
            upstream = config.upstream
        })
    end
    return list
end

return _M
