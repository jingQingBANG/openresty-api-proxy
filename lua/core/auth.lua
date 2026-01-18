-- core/auth.lua
-- 认证模块：为不同 Provider 注入认证信息

local config = require("config")
local base64 = require("ngx.base64")

local _M = {}

function _M.inject(provider)
    local provider_config = config.providers[provider]
    if not provider_config then
        ngx.log(ngx.WARN, "Unknown provider: ", provider)
        return
    end
    
    local api_key = provider_config.api_key
    if not api_key or api_key == "" then
        ngx.log(ngx.WARN, "No API key configured for provider: ", provider)
        return
    end
    
    local auth_type = provider_config.auth_type
    
    if auth_type == "basic" then
        -- Basic Auth (如 Zerion)
        local cred = "Basic " .. base64.encode(api_key .. ":")
        ngx.req.set_header("Authorization", cred)
    elseif auth_type == "header" then
        -- Header Auth (如 CoinGecko)
        ngx.req.set_header("X-CG-Pro-API-Key", api_key)
    elseif auth_type == "url" then
        -- URL 参数 (如 Alchemy)
        -- 通过设置变量，在 proxy_pass 中使用
        ngx.var.add_api_key = api_key
    else
        ngx.log(ngx.WARN, "Unknown auth type: ", auth_type, " for provider: ", provider)
    end
end

return _M
