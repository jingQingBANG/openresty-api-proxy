-- core/fallback.lua
-- 服务降级模块：当第三方服务异常时提供友好的降级响应

local cjson = require("cjson")

local _M = {}

-- 降级响应消息配置
local FALLBACK_MESSAGES = {
    -- 默认消息
    default = {
        zh = "服务繁忙，请稍后再试",
        en = "Service is busy, please try again later"
    },
    -- 按 Provider 定制消息
    zerion = {
        zh = "Zerion 服务暂时不可用，请稍后再试",
        en = "Zerion service is temporarily unavailable, please try again later"
    },
    coingecko = {
        zh = "CoinGecko 行情服务繁忙，请稍后再试",
        en = "CoinGecko market service is busy, please try again later"
    },
    alchemy = {
        zh = "Alchemy 区块链服务繁忙，请稍后再试",
        en = "Alchemy blockchain service is busy, please try again later"
    }
}

-- 降级响应模板
local FALLBACK_RESPONSE = {
    success = false,
    code = 503,
    message = "",
    data = nil,
    fallback = true,
    retry_after = 30,
    timestamp = 0
}

-- 获取降级消息
local function get_fallback_message(provider, lang)
    lang = lang or "zh"
    local messages = FALLBACK_MESSAGES[provider] or FALLBACK_MESSAGES.default
    return messages[lang] or messages.zh
end

-- 检测客户端语言偏好
local function detect_language()
    local accept_lang = ngx.req.get_headers()["Accept-Language"]
    if accept_lang and string.match(accept_lang, "^en") then
        return "en"
    end
    return "zh"
end

-- 生成降级响应
function _M.generate_response(provider, error_type)
    local lang = detect_language()
    local message = get_fallback_message(provider, lang)
    
    local response = {
        success = false,
        code = 503,
        message = message,
        error = {
            type = error_type or "service_unavailable",
            provider = provider or "unknown",
            recoverable = true
        },
        fallback = true,
        retry_after = 30,
        timestamp = ngx.time()
    }
    
    return response
end

-- 处理降级响应
function _M.handle()
    local provider = ngx.var.fallback_provider or "unknown"
    local error_type = ngx.var.fallback_error_type or "unknown"
    local original_status = tonumber(ngx.var.fallback_status) or 503
    
    -- 根据原始错误类型确定降级类型
    local fallback_type = "service_unavailable"
    if original_status == 504 then
        fallback_type = "timeout"
    elseif original_status == 502 then
        fallback_type = "connection_failed"
    elseif original_status == 503 then
        fallback_type = "service_unavailable"
    end
    
    local response = _M.generate_response(provider, fallback_type)
    
    -- 设置响应头
    ngx.status = 503
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Retry-After"] = "30"
    ngx.header["X-Fallback"] = "true"
    ngx.header["X-Fallback-Provider"] = provider
    ngx.header["X-Original-Status"] = tostring(original_status)
    
    -- 记录降级事件
    ngx.log(ngx.WARN, string.format(
        "[Fallback] Provider: %s, Original Status: %d, Error Type: %s",
        provider, original_status, fallback_type
    ))
    
    ngx.say(cjson.encode(response))
end

-- 检查是否需要降级（在 header_filter 阶段调用）
function _M.should_fallback(status)
    -- 5xx 错误触发降级
    if status >= 500 and status < 600 then
        return true
    end
    return false
end

-- 记录降级指标
function _M.record_fallback(provider, original_status)
    -- 使用 Prometheus 指标记录
    local ok, metrics = pcall(require, "core.metrics")
    if ok and metrics.record_fallback then
        metrics.record_fallback(provider, original_status)
    end
    
    -- 同时保留共享字典记录（兼容旧接口）
    local metrics_dict = ngx.shared.metrics_store
    if metrics_dict then
        local key = "fallback:" .. (provider or "unknown")
        local newval, err = metrics_dict:incr(key, 1)
        if not newval then
            metrics_dict:set(key, 1)
        end
        
        -- 记录总降级次数
        local total_key = "fallback:total"
        newval, err = metrics_dict:incr(total_key, 1)
        if not newval then
            metrics_dict:set(total_key, 1)
        end
    end
end

-- 获取降级统计
function _M.get_stats()
    local metrics_dict = ngx.shared.metrics_store
    if not metrics_dict then
        return {}
    end
    
    local stats = {
        total = metrics_dict:get("fallback:total") or 0,
        by_provider = {
            zerion = metrics_dict:get("fallback:zerion") or 0,
            coingecko = metrics_dict:get("fallback:coingecko") or 0,
            alchemy = metrics_dict:get("fallback:alchemy") or 0
        }
    }
    
    return stats
end

return _M
