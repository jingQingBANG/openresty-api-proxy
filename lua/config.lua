-- lua/config.lua
-- 配置文件：从环境变量加载敏感信息

local _M = {}

-- 辅助函数：从环境变量读取值，若不存在则返回默认值
local function get_env(key, default)
    local value = os.getenv(key)
    if not value or value == "" then
        return default
    end
    return value
end

-- 第三方服务配置
_M.providers = {
    zerion = {
        host = "api.zerion.io",
        upstream = "https://api.zerion.io",
        auth_type = "basic",
        api_key = get_env("ZERION_API_KEY", "")
    },
    coingecko = {
        host = "api.coingecko.com",
        upstream = "https://api.coingecko.com",
        auth_type = "header",
        api_key = get_env("COINGECKO_API_KEY", "")
    },
    alchemy = {
        host = "eth-mainnet.g.alchemy.com",
        upstream = "https://eth-mainnet.g.alchemy.com",
        auth_type = "url",
        api_key = get_env("ALCHEMY_API_KEY", "")
    }
}

-- 超时配置
_M.timeout = {
    connect = 2000,   -- 连接超时 (ms)
    send = 10000,     -- 发送超时 (ms)
    read = 15000      -- 读取超时 (ms)
}

-- 限流配置
_M.limit_req = {
    rate = 100,        -- 10 requests per second
    burst = 5
}

-- 熔断器配置
_M.circuit_breaker = {
    failure_threshold = 0.5,  -- 50% 错误率触发熔断
    min_requests = 20,        -- 最小请求数阈值
    reset_timeout = 30,       -- 熔断后等待重试时间(秒)
    max_errors = 5            -- 最大连续错误次数
}

return _M
