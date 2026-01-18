# OpenResty API Proxy - Lua 模块功能总结

本文档总结了 `lua/core/` 目录下各模块的功能和实现细节。

## 模块概览

| 模块文件 | 功能 | 执行阶段 |
|----------|------|----------|
| `access_control.lua` | 访问控制、Header 过滤、限流、熔断 | access_by_lua |
| `auth.lua` | API Key 认证注入 | rewrite_by_lua |
| `circuit_breaker.lua` | 熔断器状态管理 | access/log |
| `fallback.lua` | 服务降级处理 | content_by_lua |
| `health_check.lua` | 健康检查 | content_by_lua |
| `logger.lua` | 结构化日志 | log_by_lua |
| `metrics.lua` | Prometheus 监控指标 | init_worker/log |
| `rate_limit.lua` | 请求限流 | access_by_lua |
| `router.lua` | 请求路由 | rewrite_by_lua |

---

## 1. 访问控制模块 (access_control.lua)

### 功能概述
统一的访问控制入口，协调请求 ID 生成、Header 过滤、限流和熔断检查。

### 主要函数

#### `handle_request_id()`
生成或透传请求追踪 ID。

```lua
-- 如果客户端传入 X-OneKey-Request-Id 则透传
-- 否则生成 UUID v4 格式的新 ID
local request_id = ngx.var.http_x_onekey_request_id or generate_uuid()
ngx.req.set_header("X-OneKey-Request-Id", request_id)
ngx.ctx.request_id = request_id
```

#### `sanitize_headers()`
**安全过滤：移除不安全的请求 Header**

过滤的 Header 类型：

| 类别 | Headers | 说明 |
|------|---------|------|
| 代理绕过/SSRF | `X-Forwarded-Host`, `X-Original-URL`, `X-Rewrite-URL`, `X-Override-URL`, `X-HTTP-Method-Override`, `X-HTTP-Method`, `X-Method-Override` | 防止请求伪造和 SSRF 攻击 |
| Hop-by-hop (RFC 2616) | `Connection`, `Keep-Alive`, `Proxy-Authorization`, `Proxy-Authenticate`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade` | 不应跨代理转发的连接级头 |
| 敏感信息 | `Cookie`, `Set-Cookie`, `Authorization`, `Origin`, `Referer` | 防止信息泄露 |

```lua
local UNSAFE_HEADERS = {
    -- 代理绕过/SSRF 攻击相关
    "X-Forwarded-Host",
    "X-Original-URL",
    "X-Rewrite-URL",
    -- ... 完整列表见源码
}

function _M.sanitize_headers()
    for _, header in ipairs(UNSAFE_HEADERS) do
        ngx.req.clear_header(header)
    end
end
```

#### `rate_limit()`
调用限流模块进行请求限制。

#### `check_circuit_breaker()`
检查目标服务的熔断状态，如果熔断则直接返回 503。

---

## 2. 响应头过滤 (nginx.conf header_filter_by_lua_block)

### 功能概述
在响应阶段注入自定义响应头，便于客户端追踪和调试。

### 注入的响应头

| Header | 说明 | 示例值 |
|--------|------|--------|
| `X-OneKey-Request-Id` | 请求追踪 ID | `a1b2c3d4-e5f6-4g7h-8i9j-k0l1m2n3o4p5` |
| `X-API-Provider` | API 提供者标识 | `zerion`, `coingecko`, `alchemy` |

### 代码实现

```lua
-- nginx.conf 中的 header_filter_by_lua_block
header_filter_by_lua_block {
    -- 将请求ID添加到响应头，供客户端追踪
    local request_id = ngx.ctx.request_id
    if request_id then
        ngx.header["X-OneKey-Request-Id"] = request_id
    end
    
    -- 添加 Provider 信息
    local target = ngx.ctx.target
    if target then
        ngx.header["X-API-Provider"] = target.provider
    end
}
```

---

## 3. 代理转发时的 Header 处理 (nginx.conf)

### 必须设置的请求头

```nginx
proxy_set_header Host $backend_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

### 清除的 Hop-by-hop Headers (RFC 2616)

```nginx
proxy_set_header Connection "";
proxy_set_header Keep-Alive "";
proxy_set_header Proxy-Authorization "";
proxy_set_header Proxy-Authenticate "";
proxy_set_header TE "";
proxy_set_header Trailer "";
proxy_set_header Transfer-Encoding "";
proxy_set_header Upgrade "";
```

### 清除的敏感信息 Headers

```nginx
proxy_set_header Cookie "";
proxy_set_header Origin "";
proxy_set_header Referer "";
```

---

## 4. Header 过滤调试端点

### 端点：`/debug/headers`

用于验证 Header 过滤效果的调试端点。

### 响应示例

```json
{
  "note": "此端点显示 Header 过滤效果",
  "original_headers": {
    "host": "localhost:8080",
    "cookie": "session=abc123",
    "x-forwarded-host": "evil.com"
  },
  "after_lua_filter": {
    "host": "localhost:8080"
  },
  "proxy_will_clear": [
    "Connection", "Keep-Alive", "Proxy-Authorization",
    "Cookie", "Origin", "Referer"
  ],
  "description": {
    "original_headers": "客户端发送的原始 Headers",
    "after_lua_filter": "经过 Lua sanitize_headers() 过滤后的 Headers",
    "proxy_will_clear": "proxy_pass 时会被 nginx 清空的 Headers"
  }
}
```

### 测试命令

```bash
# 测试 Header 过滤
curl -H "Cookie: session=test" \
     -H "X-Forwarded-Host: evil.com" \
     -H "Origin: http://malicious.com" \
     http://localhost:8080/debug/headers | jq .
```

---

## 5. 认证模块 (auth.lua)

### 支持的认证方式

| Provider | 认证方式 | Header/参数 |
|----------|---------|-------------|
| Zerion | Basic Auth | `Authorization: Basic base64(apikey:)` |
| CoinGecko | Header | `x-cg-pro-api-key: xxx` |
| Alchemy | URL Path | `/v2/{api_key}/...` |

---

## 6. 路由模块 (router.lua)

### 路由配置

| URI 前缀 | 目标服务 | 后端路径转换 |
|----------|---------|-------------|
| `/zerion/*` | `api.zerion.io` | 移除 `/zerion` 前缀 |
| `/coingecko/*` | `api.coingecko.com` | 移除 `/coingecko` 前缀 |
| `/alchemy/*` | `eth-mainnet.g.alchemy.com` | 移除 `/alchemy` 前缀 |

---

## 7. 限流模块 (rate_limit.lua)

### 算法
令牌桶算法 (Token Bucket)

### 配置项
```lua
_M.limit_req = {
    rate = 10,    -- 每秒请求数
    burst = 5     -- 突发容量
}
```

### 限流键
基于客户端 IP 地址：`ngx.var.remote_addr`

---

## 8. 熔断器模块 (circuit_breaker.lua)

### 状态机

```
        失败率 > 阈值
    ┌─────────────────┐
    │                 ▼
┌───┴───┐  超时后  ┌───────┐  请求成功  ┌──────────┐
│CLOSED │◄────────│ OPEN  │───────────►│HALF_OPEN │
└───────┘         └───────┘            └────┬─────┘
    ▲                                       │
    └───────────────────────────────────────┘
                  测试请求成功
```

### 配置项
```lua
_M.circuit_breaker = {
    failure_threshold = 0.5,  -- 50% 错误率触发
    min_requests = 20,        -- 最小请求数阈值
    reset_timeout = 30,       -- 熔断恢复时间(秒)
    max_errors = 5            -- 最大连续错误数
}
```

---

## 9. 降级模块 (fallback.lua)

### 触发条件
上游服务返回 500/502/503/504 错误

### 降级响应
```json
{
  "success": false,
  "code": 503,
  "message": "服务繁忙，请稍后再试",
  "error": {
    "type": "service_unavailable",
    "provider": "coingecko",
    "recoverable": true
  },
  "fallback": true,
  "retry_after": 30
}
```

---

## 10. 监控模块 (metrics.lua)

### 指标类型

**Counter:**
- `proxy_requests_total`
- `proxy_requests_success_total`
- `proxy_requests_errors_total`
- `proxy_rate_limited_total`
- `proxy_circuit_breaker_rejected_total`

**Histogram:**
- `proxy_request_duration_seconds`
- `proxy_upstream_duration_seconds`

**Gauge:**
- `proxy_connections`
- `proxy_circuit_breaker_state`

---

## 11. 日志模块 (logger.lua)

### 日志格式
结构化 JSON 日志，包含：
- 请求 ID
- 时间戳
- 客户端 IP
- 请求方法/路径
- 响应状态码
- 延迟

### 敏感信息处理
- 大 Body 截断
- 敏感字段脱敏

---

## 请求处理流程

```
请求到达
    │
    ▼
┌─────────────────────────────────────────┐
│ access_by_lua_block                     │
│  1. handle_request_id()  生成追踪ID    │
│  2. sanitize_headers()   过滤不安全头   │
│  3. rate_limit()         限流检查       │
│  4. check_circuit_breaker() 熔断检查   │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ rewrite_by_lua_block                    │
│  1. router.route()       路由解析       │
│  2. auth.inject()        认证注入       │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ proxy_pass                              │
│  - 转发请求到上游                        │
│  - proxy_set_header 清除敏感头          │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ header_filter_by_lua_block              │
│  - 注入 X-OneKey-Request-Id            │
│  - 注入 X-API-Provider                 │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ log_by_lua_block                        │
│  1. metrics.collect()    收集指标       │
│  2. logger.process()     记录日志       │
│  3. circuit_breaker.record_*() 更新熔断│
└─────────────────────────────────────────┘
    │
    ▼
响应返回客户端
```
