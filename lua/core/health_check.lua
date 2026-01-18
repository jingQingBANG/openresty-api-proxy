-- core/health_check.lua
-- 健康检查模块

local _M = {}

local dict = ngx.shared.health_check

-- 配置常量
local ERROR_THRESHOLD = 5      -- 错误次数阈值
local RESET_TIMEOUT = 30       -- 重置超时时间(秒)

local function get_key(host)
    return "health_" .. host
end

local function get_error_count(host)
    return dict:get(get_key(host) .. "_errors") or 0
end

local function set_error_count(host, count)
    dict:set(get_key(host) .. "_errors", count, RESET_TIMEOUT)
end

local function get_last_failure_time(host)
    return dict:get(get_key(host) .. "_last_fail")
end

function _M.is_healthy(host)
    local errors = get_error_count(host)
    if errors >= ERROR_THRESHOLD then
        -- 检查是否过了重置时间
        local last_fail = get_last_failure_time(host)
        if last_fail and (ngx.time() - last_fail) < RESET_TIMEOUT then
            return false -- 熔断开启
        else
            -- 重置计数器，尝试恢复
            set_error_count(host, 0)
            return true
        end
    end
    return true
end

function _M.mark_down(host)
    local count = get_error_count(host) + 1
    set_error_count(host, count)
    dict:set(get_key(host) .. "_last_fail", ngx.time(), RESET_TIMEOUT)
end

function _M.mark_up(host)
    set_error_count(host, 0)
end

function _M.get_status()
    local keys = dict:get_keys(100)
    local status = {}
    
    for _, key in ipairs(keys) do
        status[key] = dict:get(key)
    end
    
    return status
end

return _M
