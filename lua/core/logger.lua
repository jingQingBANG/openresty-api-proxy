-- core/logger.lua
local cjson = require "cjson"
local _M = {}

-- 定义需要脱敏的 Header 和 Body 关键字
local SENSITIVE_HEADERS = {["Authorization"] = true, ["Proxy-Authorization"] = true}
local SENSITIVE_BODY_KEYWORDS = {"apiKey", "secret", "password", "privateKey"}

function _M.process()
    local headers = ngx.req.get_headers()
    local safe_headers = {}
    
    -- 3.1 Header 脱敏
    for k, v in pairs(headers) do
        if SENSITIVE_HEADERS[k] then
            safe_headers[k] = "REDACTED_" .. string.sub(v, 1, 4) .. "..."
        else
            safe_headers[k] = v
        end
    end

    -- 3.2 Body 处理 (仅记录前100字符，避免膨胀)
    local req_body = ngx.req.get_body_data()
    if req_body and #req_body > 100 then
        req_body = string.sub(req_body, 1, 100) .. "...[TRUNCATED]"
    end

    -- 3.3 上游错误日志
    if ngx.status >= 500 then
        local err_msg = string.format("UPSTREAM_ERROR: %s -> %s", ngx.var.uri, ngx.status)
        ngx.log(ngx.ERR, err_msg)
    end
end

return _M
