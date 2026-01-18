-- core/rate_limit.lua
-- 限流模块：基于令牌桶算法的多维度限流

local limit_req = require "resty.limit.req"
local config = require "config"

local _M = {}

-- 从配置文件读取限流参数
local RATE = config.limit_req and config.limit_req.rate or 10
local BURST = config.limit_req and config.limit_req.burst or 5

-- 限流检查 (provider 用于指标统计)
function _M.limit(provider)
    -- 创建限流器实例
    local lim, err = limit_req.new("limit_req_store", RATE, BURST)
    if not lim then
        ngx.log(ngx.ERR, "Failed to instantiate limiter: ", err)
        return false
    end

    -- 基于 IP 限流
    local key = ngx.var.binary_remote_addr
    local delay, err = lim:incoming(key, true)
    
    if not delay then
        if err == "rejected" then
            -- 在 exit 之前记录限流指标 (ngx.exit 会终止执行)
            local metrics = require("core.metrics")
            metrics.record_rate_limit(provider or "unknown")
            
            ngx.status = 429 -- Too Many Requests
            ngx.header["Content-Type"] = "application/json"
            ngx.header["Retry-After"] = "1"
            ngx.say('{"error": "Rate limit exceeded", "code": 429}')
            ngx.exit(429)
            return true -- 这行不会执行，但保留以明确语义
        end
        ngx.log(ngx.ERR, "Rate limit error: ", err)
    end
    
    -- 如果需要延迟（软限流），可以选择 sleep
    if delay and delay > 0 then
        ngx.sleep(delay)
    end
    
    return false -- 返回 false 表示未被限流
end

-- 获取当前限流配置（供调试使用）
function _M.get_config()
    return {
        rate = RATE,
        burst = BURST
    }
end

return _M
