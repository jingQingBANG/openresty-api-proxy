-- core/access_control.lua
-- 访问控制模块：请求ID处理、Header过滤、限流、熔断检查

local rate_limit = require("core.rate_limit")
local circuit_breaker = require("core.circuit_breaker")
local router = require("core.router")
local metrics = require("core.metrics")

local _M = {}

-- 不安全的 Header 列表 (需要移除)
-- 包括：代理绕过攻击头、Hop-by-hop 头、敏感信息头
local UNSAFE_HEADERS = {
    -- 代理绕过/SSRF 攻击相关
    "X-Forwarded-Host",
    "X-Original-URL",
    "X-Rewrite-URL",
    "X-Override-URL",
    "X-HTTP-Method-Override",
    "X-HTTP-Method",
    "X-Method-Override",
    
    -- Hop-by-hop Headers (RFC 2616) - 不应跨代理转发
    "Connection",
    "Keep-Alive",
    "Proxy-Authorization",
    "Proxy-Authenticate",
    "TE",
    "Trailer",
    "Transfer-Encoding",
    "Upgrade",
    
    -- 可能泄露敏感信息的 Headers
    "Cookie",
    "Set-Cookie",
    "Authorization",  -- 原始认证，会被新的认证覆盖
    "Origin",
    "Referer"
}

-- 生成 UUID v4
local function generate_uuid()
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

-- 5.1 生成或透传请求ID (用于链路追踪)
function _M.handle_request_id()
    local request_id = ngx.var.http_x_onekey_request_id
    
    if not request_id or request_id == "" then
        -- 生成新的请求ID
        request_id = generate_uuid()
    end
    
    -- 设置请求头，供后续使用
    ngx.req.set_header("X-OneKey-Request-Id", request_id)
    -- 保存到 ngx.ctx 供日志使用
    ngx.ctx.request_id = request_id
end

-- 5.2 安全过滤：移除不安全的Header
function _M.sanitize_headers()
    for _, header in ipairs(UNSAFE_HEADERS) do
        ngx.req.clear_header(header)
    end
end

-- 5.3 多维度限流 (IP, API Key, 路径)
function _M.rate_limit()
    -- 获取 provider 信息
    local uri = ngx.var.uri
    local target = router.route(uri)
    local provider = target and target.provider or "unknown"
    
    -- 传递 provider 给限流模块，用于指标统计
    -- (ngx.exit 会在限流时直接终止，所以指标在 rate_limit.limit 内部记录)
    rate_limit.limit(provider)
end

-- 5.4 熔断检查 (如果服务熔断，则直接拒绝)
function _M.check_circuit_breaker()
    local uri = ngx.var.uri
    local target = router.route(uri)
    
    if target then
        local provider = target.provider
        local is_allowed = circuit_breaker.check(provider)
        
        if not is_allowed then
            -- 记录熔断事件
            metrics.record_circuit_breaker(provider)
            
            ngx.status = 503
            ngx.header["Content-Type"] = "application/json"
            ngx.header["Retry-After"] = "30"
            ngx.say('{"error": "Service temporarily unavailable due to circuit breaker", "code": 503}')
            ngx.exit(503)
        end
    end
end

return _M
