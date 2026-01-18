-- core/circuit_breaker.lua
-- 熔断器模块：实现完整的熔断策略，保护系统免受级联故障影响
--
-- 状态机: CLOSED -> OPEN -> HALF_OPEN -> CLOSED
--   CLOSED:    正常状态，所有请求通过
--   OPEN:      熔断状态，所有请求快速失败
--   HALF_OPEN: 半开状态，允许部分请求探测服务是否恢复
--
-- 熔断触发条件 (满足任一即触发):
--   1. 连续错误次数 >= consecutive_failures
--   2. 时间窗口内错误率 >= failure_rate_threshold
--   3. 时间窗口内慢调用比例 >= slow_call_rate_threshold

local _M = {}

local health_dict = ngx.shared.health_check

-- ============================================
-- Provider 配置
-- ============================================
local PROVIDERS = {"zerion", "coingecko", "alchemy"}

-- 默认熔断配置
local DEFAULT_CONFIG = {
    -- 熔断触发阈值
    consecutive_failures = 5,        -- 连续失败次数触发熔断
    failure_rate_threshold = 0.5,    -- 错误率阈值 (50%)
    slow_call_rate_threshold = 0.8,  -- 慢调用比例阈值 (80%)
    slow_call_duration_ms = 3000,    -- 慢调用定义 (>3秒)
    
    -- 统计窗口
    window_size_seconds = 60,        -- 统计窗口大小 (60秒)
    min_requests_in_window = 10,     -- 窗口内最小请求数才开始计算
    
    -- 恢复配置
    open_timeout_seconds = 30,       -- 熔断持续时间
    half_open_max_requests = 3,      -- 半开状态允许的最大探测请求数
    half_open_success_threshold = 2, -- 半开状态恢复所需成功次数
}

-- 每个 Provider 可以有独立配置
local PROVIDER_CONFIGS = {
    zerion = {
        consecutive_failures = 5,
        failure_rate_threshold = 0.5,
        slow_call_duration_ms = 5000,  -- Zerion 允许更长响应时间
    },
    coingecko = {
        consecutive_failures = 3,       -- CoinGecko 更敏感
        failure_rate_threshold = 0.4,
    },
    alchemy = {
        consecutive_failures = 5,
        failure_rate_threshold = 0.5,
    }
}

-- ============================================
-- 辅助函数
-- ============================================

-- 获取 Provider 配置
local function get_config(provider)
    local config = {}
    -- 复制默认配置
    for k, v in pairs(DEFAULT_CONFIG) do
        config[k] = v
    end
    -- 覆盖 Provider 特定配置
    local provider_config = PROVIDER_CONFIGS[provider]
    if provider_config then
        for k, v in pairs(provider_config) do
            config[k] = v
        end
    end
    return config
end

-- 生成 key 前缀
local function key(provider, suffix)
    return "cb:" .. provider .. ":" .. suffix
end

-- 安全获取数值
local function safe_get(k, default)
    local val = health_dict:get(k)
    return val or default
end

-- 安全设置数值
local function safe_set(k, v, ttl)
    if ttl then
        health_dict:set(k, v, ttl)
    else
        health_dict:set(k, v)
    end
end

-- 安全递增
local function safe_incr(k, delta)
    local newval, err = health_dict:incr(k, delta or 1)
    if not newval then
        health_dict:set(k, delta or 1)
        return delta or 1
    end
    return newval
end

-- 获取当前时间桶 (用于滑动窗口)
local function get_time_bucket()
    return math.floor(ngx.time() / 10)  -- 10秒一个桶
end

-- ============================================
-- 状态管理
-- ============================================

-- 获取熔断器状态
local function get_state(provider)
    return safe_get(key(provider, "state"), "CLOSED")
end

-- 设置熔断器状态
local function set_state(provider, state)
    local old_state = get_state(provider)
    safe_set(key(provider, "state"), state)
    safe_set(key(provider, "state_changed_at"), ngx.time())
    
    -- 状态变更日志
    if old_state ~= state then
        ngx.log(ngx.WARN, string.format(
            "[CircuitBreaker] Provider '%s' state changed: %s -> %s",
            provider, old_state, state
        ))
        
        -- 记录熔断事件历史
        local events_key = key(provider, "events")
        local events = safe_get(events_key, "")
        local event = string.format("%d:%s->%s", ngx.time(), old_state, state)
        events = event .. ";" .. string.sub(events, 1, 500)  -- 保留最近的事件
        safe_set(events_key, events)
    end
end

-- ============================================
-- 滑动窗口统计
-- ============================================

-- 记录请求到滑动窗口
local function record_to_window(provider, is_success, is_slow)
    local bucket = get_time_bucket()
    local config = get_config(provider)
    local window_buckets = math.ceil(config.window_size_seconds / 10)
    
    -- 请求计数
    local req_key = key(provider, "window:" .. bucket .. ":req")
    safe_incr(req_key, 1)
    health_dict:expire(req_key, config.window_size_seconds + 10)
    
    -- 失败计数
    if not is_success then
        local fail_key = key(provider, "window:" .. bucket .. ":fail")
        safe_incr(fail_key, 1)
        health_dict:expire(fail_key, config.window_size_seconds + 10)
    end
    
    -- 慢调用计数
    if is_slow then
        local slow_key = key(provider, "window:" .. bucket .. ":slow")
        safe_incr(slow_key, 1)
        health_dict:expire(slow_key, config.window_size_seconds + 10)
    end
end

-- 计算滑动窗口内的统计数据
local function get_window_stats(provider)
    local config = get_config(provider)
    local current_bucket = get_time_bucket()
    local window_buckets = math.ceil(config.window_size_seconds / 10)
    
    local total_requests = 0
    local total_failures = 0
    local total_slow = 0
    
    for i = 0, window_buckets - 1 do
        local bucket = current_bucket - i
        total_requests = total_requests + safe_get(key(provider, "window:" .. bucket .. ":req"), 0)
        total_failures = total_failures + safe_get(key(provider, "window:" .. bucket .. ":fail"), 0)
        total_slow = total_slow + safe_get(key(provider, "window:" .. bucket .. ":slow"), 0)
    end
    
    return {
        requests = total_requests,
        failures = total_failures,
        slow_calls = total_slow,
        failure_rate = total_requests > 0 and (total_failures / total_requests) or 0,
        slow_call_rate = total_requests > 0 and (total_slow / total_requests) or 0
    }
end

-- ============================================
-- 熔断判断逻辑
-- ============================================

-- 检查是否应该触发熔断
local function should_trip(provider)
    local config = get_config(provider)
    local stats = get_window_stats(provider)
    
    -- 1. 连续失败次数检查 (不受最小请求数限制)
    local consecutive = safe_get(key(provider, "consecutive_failures"), 0)
    if consecutive >= config.consecutive_failures then
        return true, "consecutive_failures"
    end
    
    -- 以下检查需要满足最小请求数
    if stats.requests < config.min_requests_in_window then
        return false, "insufficient_requests"
    end
    
    -- 2. 检查错误率
    if stats.failure_rate >= config.failure_rate_threshold then
        return true, "failure_rate"
    end
    
    -- 3. 检查慢调用比例
    if stats.slow_call_rate >= config.slow_call_rate_threshold then
        return true, "slow_call_rate"
    end
    
    return false, nil
end

-- ============================================
-- 公开 API
-- ============================================

-- 初始化熔断器
function _M.init()
    for _, provider in ipairs(PROVIDERS) do
        -- 初始化状态（如果不存在）
        if not health_dict:get(key(provider, "state")) then
            safe_set(key(provider, "state"), "CLOSED")
            safe_set(key(provider, "consecutive_failures"), 0)
            safe_set(key(provider, "half_open_requests"), 0)
            safe_set(key(provider, "half_open_successes"), 0)
        end
    end
    ngx.log(ngx.INFO, "[CircuitBreaker] Initialized for providers: ", table.concat(PROVIDERS, ", "))
end

-- 检查请求是否允许通过
function _M.check(provider)
    local state = get_state(provider)
    local config = get_config(provider)
    
    if state == "CLOSED" then
        -- 正常状态，允许通过
        return true
    
    elseif state == "OPEN" then
        -- 熔断状态，检查是否到了恢复时间
        local changed_at = safe_get(key(provider, "state_changed_at"), 0)
        local elapsed = ngx.time() - changed_at
        
        if elapsed >= config.open_timeout_seconds then
            -- 进入半开状态
            set_state(provider, "HALF_OPEN")
            safe_set(key(provider, "half_open_requests"), 0)
            safe_set(key(provider, "half_open_successes"), 0)
            return true  -- 允许第一个探测请求
        end
        
        -- 仍在熔断期间
        return false
    
    elseif state == "HALF_OPEN" then
        -- 半开状态，允许有限的探测请求
        local half_open_requests = safe_get(key(provider, "half_open_requests"), 0)
        
        if half_open_requests < config.half_open_max_requests then
            safe_incr(key(provider, "half_open_requests"), 1)
            return true
        end
        
        -- 已达到最大探测请求数，等待结果
        return false
    end
    
    return true
end

-- 记录成功请求
function _M.record_success(provider, latency_ms)
    local config = get_config(provider)
    local state = get_state(provider)
    local is_slow = latency_ms and latency_ms > config.slow_call_duration_ms
    
    -- 重置连续失败计数
    safe_set(key(provider, "consecutive_failures"), 0)
    
    -- 记录到滑动窗口
    record_to_window(provider, true, is_slow)
    
    -- 半开状态的处理
    if state == "HALF_OPEN" then
        local successes = safe_incr(key(provider, "half_open_successes"), 1)
        
        if successes >= config.half_open_success_threshold then
            -- 恢复到关闭状态
            set_state(provider, "CLOSED")
            ngx.log(ngx.INFO, string.format(
                "[CircuitBreaker] Provider '%s' recovered after %d successful probes",
                provider, successes
            ))
        end
    end
end

-- 记录失败请求
function _M.record_failure(provider, latency_ms, error_type)
    local config = get_config(provider)
    local state = get_state(provider)
    local is_slow = latency_ms and latency_ms > config.slow_call_duration_ms
    
    -- 增加连续失败计数
    local consecutive = safe_incr(key(provider, "consecutive_failures"), 1)
    
    -- 记录到滑动窗口
    record_to_window(provider, false, is_slow)
    
    -- 记录错误类型统计
    if error_type then
        safe_incr(key(provider, "error:" .. error_type), 1)
    end
    
    if state == "CLOSED" then
        -- 检查是否需要触发熔断
        local should_open, reason = should_trip(provider)
        if should_open then
            set_state(provider, "OPEN")
            ngx.log(ngx.WARN, string.format(
                "[CircuitBreaker] Provider '%s' circuit OPENED, reason: %s",
                provider, reason
            ))
        end
    
    elseif state == "HALF_OPEN" then
        -- 半开状态失败，重新进入熔断
        set_state(provider, "OPEN")
        ngx.log(ngx.WARN, string.format(
            "[CircuitBreaker] Provider '%s' probe failed, re-opening circuit",
            provider
        ))
    end
end

-- 获取熔断器状态报告
function _M.get_status(provider)
    if provider then
        local config = get_config(provider)
        local stats = get_window_stats(provider)
        
        return {
            provider = provider,
            state = get_state(provider),
            state_changed_at = safe_get(key(provider, "state_changed_at"), 0),
            consecutive_failures = safe_get(key(provider, "consecutive_failures"), 0),
            window_stats = {
                requests = stats.requests,
                failures = stats.failures,
                slow_calls = stats.slow_calls,
                failure_rate = string.format("%.2f%%", stats.failure_rate * 100),
                slow_call_rate = string.format("%.2f%%", stats.slow_call_rate * 100)
            },
            config = {
                consecutive_failures_threshold = config.consecutive_failures,
                failure_rate_threshold = string.format("%.0f%%", config.failure_rate_threshold * 100),
                slow_call_rate_threshold = string.format("%.0f%%", config.slow_call_rate_threshold * 100),
                slow_call_duration_ms = config.slow_call_duration_ms,
                open_timeout_seconds = config.open_timeout_seconds
            },
            half_open = {
                requests = safe_get(key(provider, "half_open_requests"), 0),
                successes = safe_get(key(provider, "half_open_successes"), 0),
                max_requests = config.half_open_max_requests,
                success_threshold = config.half_open_success_threshold
            },
            recent_events = safe_get(key(provider, "events"), "")
        }
    else
        -- 返回所有 Provider 的状态
        local all_status = {}
        for _, p in ipairs(PROVIDERS) do
            all_status[p] = _M.get_status(p)
        end
        return all_status
    end
end

-- 手动重置熔断器（用于管理操作）
function _M.reset(provider)
    if provider then
        set_state(provider, "CLOSED")
        safe_set(key(provider, "consecutive_failures"), 0)
        safe_set(key(provider, "half_open_requests"), 0)
        safe_set(key(provider, "half_open_successes"), 0)
        ngx.log(ngx.INFO, string.format(
            "[CircuitBreaker] Provider '%s' manually reset",
            provider
        ))
        return true
    end
    return false
end

-- 手动触发熔断（用于管理操作）
function _M.trip(provider)
    if provider then
        set_state(provider, "OPEN")
        ngx.log(ngx.WARN, string.format(
            "[CircuitBreaker] Provider '%s' manually tripped",
            provider
        ))
        return true
    end
    return false
end

-- 获取所有 Provider 列表
function _M.get_providers()
    return PROVIDERS
end

return _M
