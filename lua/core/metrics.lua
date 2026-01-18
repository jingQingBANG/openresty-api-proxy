-- core/metrics.lua
-- 基于 lua-resty-prometheus 的监控指标模块
-- 提供标准 Prometheus 格式的指标输出

local _M = {}

-- Prometheus 实例 (在 init_worker 阶段初始化)
local prometheus

-- 指标定义
local metrics = {}

-- 初始化标志
local initialized = false

-- 配置常量
local PROVIDERS = {"zerion", "coingecko", "alchemy"}

-- 延迟直方图桶边界 (秒)
local LATENCY_BUCKETS = {0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

-- 共享字典引用
local health_dict = ngx.shared.health_check
local metrics_dict = ngx.shared.metrics_store

-- ============================================
-- 初始化函数 (必须在 init_worker_by_lua 阶段调用)
-- ============================================
function _M.init()
    if initialized then
        return
    end
    
    -- 创建 Prometheus 实例，使用共享字典存储指标
    prometheus = require("prometheus").init("metrics_store")
    
    -- ========== Counter 指标 ==========
    
    -- 总请求计数器 (按 provider, method, status 分组)
    metrics.requests_total = prometheus:counter(
        "proxy_requests_total",
        "Total number of HTTP requests",
        {"provider", "method", "status"}
    )
    
    -- 成功请求计数器
    metrics.requests_success = prometheus:counter(
        "proxy_requests_success_total",
        "Total number of successful requests",
        {"provider"}
    )
    
    -- 错误请求计数器 (按错误类型分组)
    metrics.requests_errors = prometheus:counter(
        "proxy_requests_errors_total",
        "Total number of failed requests",
        {"provider", "error_type"}
    )
    
    -- 限流拒绝计数器
    metrics.rate_limited = prometheus:counter(
        "proxy_rate_limited_total",
        "Total number of rate limited requests",
        {"provider"}
    )
    
    -- 熔断拒绝计数器
    metrics.circuit_breaker_rejected = prometheus:counter(
        "proxy_circuit_breaker_rejected_total",
        "Total number of requests rejected by circuit breaker",
        {"provider"}
    )
    
    -- 降级触发计数器
    metrics.fallback_triggered = prometheus:counter(
        "proxy_fallback_triggered_total",
        "Total number of fallback responses",
        {"provider", "original_status"}
    )
    
    -- ========== Histogram 指标 ==========
    
    -- 请求延迟直方图 (按 provider 分组)
    metrics.request_duration = prometheus:histogram(
        "proxy_request_duration_seconds",
        "Request duration in seconds",
        {"provider"},
        LATENCY_BUCKETS
    )
    
    -- 上游响应时间直方图
    metrics.upstream_duration = prometheus:histogram(
        "proxy_upstream_duration_seconds",
        "Upstream response time in seconds",
        {"provider"},
        LATENCY_BUCKETS
    )
    
    -- ========== Gauge 指标 ==========
    
    -- 当前连接数
    metrics.connections = prometheus:gauge(
        "proxy_connections",
        "Current number of connections",
        {"state"}
    )
    
    -- Provider 健康状态 (1=healthy/closed, 0=unhealthy/open)
    metrics.provider_health = prometheus:gauge(
        "proxy_provider_health",
        "Provider health status (1=healthy, 0=unhealthy)",
        {"provider", "state"}
    )
    
    -- 熔断器状态
    metrics.circuit_breaker_state = prometheus:gauge(
        "proxy_circuit_breaker_state",
        "Circuit breaker state (0=CLOSED, 1=HALF_OPEN, 2=OPEN)",
        {"provider"}
    )
    
    -- 熔断器失败计数
    metrics.circuit_breaker_failures = prometheus:gauge(
        "proxy_circuit_breaker_failures",
        "Current failure count in circuit breaker",
        {"provider"}
    )
    
    -- 服务启动时间
    metrics.start_time = prometheus:gauge(
        "proxy_start_time_seconds",
        "Unix timestamp of service start time"
    )
    
    -- 记录启动时间到共享字典和 gauge
    local start_time = ngx.now()
    metrics_dict:safe_set("start_time", start_time)
    metrics.start_time:set(start_time)
    
    -- 预初始化所有 Provider 的指标 (确保零值也显示)
    for _, provider in ipairs(PROVIDERS) do
        -- 初始化 success counter (零值)
        metrics.requests_success:inc(0, {provider})
        
        -- 初始化 error counters (零值)
        metrics.requests_errors:inc(0, {provider, "timeout"})
        metrics.requests_errors:inc(0, {provider, "connect_failed"})
        metrics.requests_errors:inc(0, {provider, "rate_limited"})
        metrics.requests_errors:inc(0, {provider, "circuit_breaker"})
        metrics.requests_errors:inc(0, {provider, "upstream_5xx"})
        metrics.requests_errors:inc(0, {provider, "client_4xx"})
        
        -- 初始化其他 counters
        metrics.rate_limited:inc(0, {provider})
        metrics.circuit_breaker_rejected:inc(0, {provider})
        
        -- 初始化 gauges
        metrics.provider_health:set(1, {provider, "CLOSED"})
        metrics.circuit_breaker_state:set(0, {provider})
        metrics.circuit_breaker_failures:set(0, {provider})
    end
    
    -- 初始化连接 gauges
    metrics.connections:set(0, {"active"})
    metrics.connections:set(0, {"reading"})
    metrics.connections:set(0, {"writing"})
    metrics.connections:set(0, {"waiting"})
    
    -- 存储到模块级变量
    _M.prometheus = prometheus
    _M.metrics = metrics
    
    initialized = true
    
    ngx.log(ngx.INFO, "[metrics] Prometheus metrics initialized successfully")
end

-- ============================================
-- 核心指标收集函数 (在 log_by_lua 阶段调用)
-- ============================================
function _M.collect()
    if not initialized or not metrics.requests_total then
        return
    end
    
    local status = ngx.status
    local request_time = tonumber(ngx.var.request_time) or 0
    local upstream_time = tonumber(ngx.var.upstream_response_time) or 0
    local method = ngx.req.get_method()
    
    -- 获取 Provider 信息
    local target = ngx.ctx.target
    local provider = target and target.provider or "unknown"
    
    -- 1. 记录总请求数
    metrics.requests_total:inc(1, {provider, method, tostring(status)})
    
    -- 同步更新共享字典 (用于 JSON 报告)
    local key_total = "stats:" .. provider .. ":total"
    metrics_dict:incr(key_total, 1, 0)
    
    -- 2. 记录请求延迟
    metrics.request_duration:observe(request_time, {provider})
    
    -- 3. 记录上游响应时间
    if upstream_time > 0 then
        metrics.upstream_duration:observe(upstream_time, {provider})
    end
    
    -- 4. 成功/错误统计
    local is_success = status >= 200 and status < 400
    if is_success then
        metrics.requests_success:inc(1, {provider})
        -- 同步更新共享字典
        local key_success = "stats:" .. provider .. ":success"
        metrics_dict:incr(key_success, 1, 0)
    else
        -- 检测错误类型
        local error_type = _M.detect_error_type(status)
        metrics.requests_errors:inc(1, {provider, error_type})
        -- 同步更新共享字典
        local key_errors = "stats:" .. provider .. ":errors"
        metrics_dict:incr(key_errors, 1, 0)
        local key_error_type = "stats:" .. provider .. ":error:" .. error_type
        metrics_dict:incr(key_error_type, 1, 0)
    end
end

-- ============================================
-- 错误类型检测
-- ============================================
function _M.detect_error_type(status)
    if status == 504 then
        return "timeout"
    elseif status == 502 then
        return "connect_failed"
    elseif status == 429 then
        return "rate_limited"
    elseif status == 503 then
        return "circuit_breaker"
    elseif status >= 500 then
        return "upstream_5xx"
    elseif status >= 400 then
        return "client_4xx"
    end
    return "unknown"
end

-- ============================================
-- 特定事件记录函数
-- ============================================

-- 记录限流事件
function _M.record_rate_limit(provider)
    provider = provider or "unknown"
    if initialized and metrics.rate_limited then
        metrics.rate_limited:inc(1, {provider})
    end
    -- 同步更新共享字典
    local key = "stats:" .. provider .. ":rate_limited"
    metrics_dict:incr(key, 1, 0)
end

-- 记录熔断拒绝事件
function _M.record_circuit_breaker(provider)
    provider = provider or "unknown"
    if initialized and metrics.circuit_breaker_rejected then
        metrics.circuit_breaker_rejected:inc(1, {provider})
    end
    -- 同步更新共享字典
    local key = "stats:" .. provider .. ":circuit_breaker"
    metrics_dict:incr(key, 1, 0)
end

-- 记录降级事件
function _M.record_fallback(provider, original_status)
    provider = provider or "unknown"
    original_status = tostring(original_status or "503")
    if initialized and metrics.fallback_triggered then
        metrics.fallback_triggered:inc(1, {provider, original_status})
    end
    -- 同步更新共享字典
    local key = "stats:" .. provider .. ":fallback"
    metrics_dict:incr(key, 1, 0)
end

-- ============================================
-- 更新 Gauge 指标 (可在任意阶段调用)
-- ============================================

-- 更新连接统计
function _M.update_connections()
    if not initialized or not metrics.connections then
        return
    end
    
    metrics.connections:set(tonumber(ngx.var.connections_active) or 0, {"active"})
    metrics.connections:set(tonumber(ngx.var.connections_reading) or 0, {"reading"})
    metrics.connections:set(tonumber(ngx.var.connections_writing) or 0, {"writing"})
    metrics.connections:set(tonumber(ngx.var.connections_waiting) or 0, {"waiting"})
end

-- 更新 Provider 健康状态
function _M.update_provider_health()
    if not initialized or not metrics.provider_health then
        return
    end
    
    for _, provider in ipairs(PROVIDERS) do
        local state = health_dict:get(provider .. "_state") or "CLOSED"
        local failure_count = health_dict:get(provider .. "_failure_count") or 0
        
        -- 健康值: CLOSED=1, HALF_OPEN=1, OPEN=0
        local health_value = (state == "CLOSED" or state == "HALF_OPEN") and 1 or 0
        metrics.provider_health:set(health_value, {provider, state})
        
        -- 熔断器状态值: CLOSED=0, HALF_OPEN=1, OPEN=2
        local state_value = 0
        if state == "HALF_OPEN" then
            state_value = 1
        elseif state == "OPEN" then
            state_value = 2
        end
        metrics.circuit_breaker_state:set(state_value, {provider})
        metrics.circuit_breaker_failures:set(failure_count, {provider})
    end
end

-- ============================================
-- Prometheus 指标输出
-- ============================================
function _M.collect_metrics()
    if not initialized or not prometheus then
        ngx.status = 500
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("# ERROR: Prometheus not initialized")
        ngx.say("# Please ensure init_worker_by_lua_block calls metrics.init()")
        return
    end
    
    -- 更新 Gauge 指标
    _M.update_connections()
    _M.update_provider_health()
    
    -- 输出 Prometheus 格式
    ngx.header["Content-Type"] = "text/plain; charset=utf-8"
    prometheus:collect()
end

-- ============================================
-- JSON 格式报告 (兼容旧接口)
-- ============================================
function _M.get_report()
    -- 从共享字典获取启动时间
    local start_time = metrics_dict:get("start_time") or ngx.now()
    
    -- 计算全局统计
    local total_requests = 0
    local total_success = 0
    local total_errors = 0
    local total_rate_limited = 0
    local total_circuit_breaker = 0
    local total_fallback = 0
    
    -- Provider 统计
    local providers_stats = {}
    
    for _, provider in ipairs(PROVIDERS) do
        local p_total = metrics_dict:get("stats:" .. provider .. ":total") or 0
        local p_success = metrics_dict:get("stats:" .. provider .. ":success") or 0
        local p_errors = metrics_dict:get("stats:" .. provider .. ":errors") or 0
        local p_rate_limited = metrics_dict:get("stats:" .. provider .. ":rate_limited") or 0
        local p_circuit_breaker = metrics_dict:get("stats:" .. provider .. ":circuit_breaker") or 0
        local p_fallback = metrics_dict:get("stats:" .. provider .. ":fallback") or 0
        
        -- 获取健康状态
        local state = health_dict:get(provider .. "_state") or "CLOSED"
        local failure_count = health_dict:get(provider .. "_failure_count") or 0
        
        providers_stats[provider] = {
            requests = {
                total = p_total,
                success = p_success,
                errors = p_errors
            },
            protection = {
                rate_limited = p_rate_limited,
                circuit_breaker = p_circuit_breaker,
                fallback = p_fallback
            },
            health = {
                state = state,
                failure_count = failure_count,
                healthy = (state == "CLOSED" or state == "HALF_OPEN")
            }
        }
        
        -- 累加全局统计
        total_requests = total_requests + p_total
        total_success = total_success + p_success
        total_errors = total_errors + p_errors
        total_rate_limited = total_rate_limited + p_rate_limited
        total_circuit_breaker = total_circuit_breaker + p_circuit_breaker
        total_fallback = total_fallback + p_fallback
    end
    
    local report = {
        timestamp = ngx.time(),
        uptime_seconds = ngx.now() - start_time,
        
        -- 全局统计
        global = {
            requests = {
                total = total_requests,
                success = total_success,
                errors = total_errors,
                success_rate = total_requests > 0 and 
                    string.format("%.2f%%", total_success * 100 / total_requests) or "N/A"
            },
            protection = {
                rate_limited = total_rate_limited,
                circuit_breaker = total_circuit_breaker,
                fallback = total_fallback
            }
        },
        
        -- Provider 详细统计
        providers = providers_stats,
        
        -- 连接统计
        connections = {
            active = tonumber(ngx.var.connections_active) or 0,
            reading = tonumber(ngx.var.connections_reading) or 0,
            writing = tonumber(ngx.var.connections_writing) or 0,
            waiting = tonumber(ngx.var.connections_waiting) or 0
        }
    }
    
    return report
end

-- ============================================
-- 辅助函数
-- ============================================

-- 记录启动时间 (兼容旧接口，现在在init中自动调用)
function _M.record_start_time()
    -- 启动时间已在 init() 中记录
end

-- 获取 Prometheus 实例 (供外部模块使用)
function _M.get_prometheus()
    return prometheus
end

-- 获取指标对象 (供外部模块使用)
function _M.get_metrics()
    return metrics
end

-- 检查是否已初始化
function _M.is_initialized()
    return initialized
end

return _M
