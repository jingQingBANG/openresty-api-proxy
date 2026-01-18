# Header 过滤功能测试报告

> 测试日期: 2026-01-18  
> 测试环境: OpenResty API Proxy v1.0.0

## 1. 概述

本报告测试 OpenResty API Proxy 的 Header 过滤功能，确保敏感和危险的 HTTP Headers 不会被转发给上游第三方服务。

## 2. 过滤机制设计

### 2.1 两层过滤架构

```
客户端请求
    │
    ▼
┌─────────────────────────────────┐
│  第一层: Lua sanitize_headers() │
│  access_control.lua             │
│  移除攻击相关 Headers           │
└─────────────────┬───────────────┘
                  │
                  ▼
┌─────────────────────────────────┐
│  第二层: proxy_set_header ""    │
│  nginx.conf                     │
│  清空 Hop-by-hop Headers        │
└─────────────────┬───────────────┘
                  │
                  ▼
              上游服务
```

### 2.2 过滤的 Header 分类

| 分类 | Headers | 过滤原因 |
|------|---------|----------|
| **代理绕过/SSRF 攻击** | X-Forwarded-Host, X-Original-URL, X-Rewrite-URL, X-Override-URL, X-HTTP-Method-Override | 可被用于绕过代理或发起 SSRF 攻击 |
| **Hop-by-hop (RFC 2616)** | Connection, Keep-Alive, TE, Trailer, Transfer-Encoding, Upgrade | 不应跨代理转发 |
| **代理认证** | Proxy-Authorization, Proxy-Authenticate | 代理层认证信息，不应泄露给上游 |
| **敏感信息** | Cookie, Authorization, Origin, Referer | 防止用户隐私泄露给第三方 |

## 3. 测试环境

### 3.1 测试端点

| 端点 | 用途 |
|------|------|
| `/debug/headers` | 显示 Header 过滤效果对比 |
| `/coingecko/api/v3/ping` | 测试实际代理请求 |
| `/health` | 健康检查（不经过代理过滤） |

### 3.2 测试命令

```bash
curl -s http://localhost:8080/debug/headers \
  -H "Connection: keep-alive" \
  -H "Cookie: session=secret123" \
  -H "Proxy-Authorization: Basic abc123" \
  -H "X-Forwarded-Host: evil.com" \
  -H "X-Original-URL: /admin" \
  -H "X-Rewrite-URL: /secret" \
  -H "Authorization: Bearer token123" \
  -H "Origin: https://attacker.com" \
  -H "Referer: https://attacker.com/page" \
  -H "X-Custom-Safe: allowed" \
  -H "X-OneKey-Request-Id: test-123"
```

## 4. 测试结果

### 4.1 原始请求 Headers (客户端发送)

```json
{
    "user-agent": "curl/8.7.1",
    "accept": "*/*",
    "x-rewrite-url": "/secret",
    "connection": "keep-alive",
    "origin": "https://attacker.com",
    "cookie": "session=secret123",
    "referer": "https://attacker.com/page",
    "proxy-authorization": "Basic abc123",
    "x-onekey-request-id": "test-123",
    "x-forwarded-host": "evil.com",
    "x-original-url": "/admin",
    "authorization": "Bearer token123",
    "host": "localhost:8080",
    "x-custom-safe": "allowed"
}
```

### 4.2 Lua 过滤后 Headers

```json
{
    "user-agent": "curl/8.7.1",
    "x-onekey-request-id": "test-123",
    "accept": "*/*",
    "host": "localhost:8080",
    "x-custom-safe": "allowed"
}
```

### 4.3 过滤效果对比

| Header | 原始值 | 过滤后 | 状态 |
|--------|--------|--------|------|
| `Connection` | keep-alive | - | ❌ 已移除 |
| `Cookie` | session=secret123 | - | ❌ 已移除 |
| `Proxy-Authorization` | Basic abc123 | - | ❌ 已移除 |
| `X-Forwarded-Host` | evil.com | - | ❌ 已移除 |
| `X-Original-URL` | /admin | - | ❌ 已移除 |
| `X-Rewrite-URL` | /secret | - | ❌ 已移除 |
| `Authorization` | Bearer token123 | - | ❌ 已移除 |
| `Origin` | https://attacker.com | - | ❌ 已移除 |
| `Referer` | https://attacker.com/page | - | ❌ 已移除 |
| `User-Agent` | curl/8.7.1 | curl/8.7.1 | ✅ 保留 |
| `Accept` | */* | */* | ✅ 保留 |
| `X-Custom-Safe` | allowed | allowed | ✅ 保留 |
| `X-OneKey-Request-Id` | test-123 | test-123 | ✅ 保留 |

### 4.4 响应头验证

代理请求后的响应头包含追踪信息：

```
< HTTP/1.1 200 OK
< Server: openresty/1.27.1.2
< X-OneKey-Request-Id: cb9c1a5b-6910-4fb2-b457-a9c72a392d90
< X-API-Provider: coingecko
```

## 5. 代码实现

### 5.1 Lua 层过滤 (access_control.lua)

```lua
-- 不安全的 Header 列表 (需要移除)
local UNSAFE_HEADERS = {
    -- 代理绕过/SSRF 攻击相关
    "X-Forwarded-Host",
    "X-Original-URL",
    "X-Rewrite-URL",
    "X-Override-URL",
    "X-HTTP-Method-Override",
    "X-HTTP-Method",
    "X-Method-Override",
    
    -- Hop-by-hop Headers (RFC 2616)
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
    "Authorization",
    "Origin",
    "Referer"
}

function _M.sanitize_headers()
    for _, header in ipairs(UNSAFE_HEADERS) do
        ngx.req.clear_header(header)
    end
end
```

### 5.2 Nginx 层过滤 (nginx.conf)

```nginx
# 7.4.2 清除不应转发的 Hop-by-hop Headers (RFC 2616)
proxy_set_header Connection "";
proxy_set_header Keep-Alive "";
proxy_set_header Proxy-Authorization "";
proxy_set_header Proxy-Authenticate "";
proxy_set_header TE "";
proxy_set_header Trailer "";
proxy_set_header Transfer-Encoding "";
proxy_set_header Upgrade "";

# 7.4.3 清除可能泄露信息的 Headers
proxy_set_header Cookie "";
proxy_set_header Origin "";
proxy_set_header Referer "";
```

## 6. 安全防护说明

### 6.1 SSRF 攻击防护

**X-Forwarded-Host 攻击示例：**
```
攻击者: curl -H "X-Forwarded-Host: internal-service.local" proxy.com/api
预期: 代理将请求发送到 internal-service.local 而非真实上游
```

**防护效果：** Header 被移除，代理使用配置的真实上游地址。

### 6.2 代理绕过攻击防护

**X-Original-URL 攻击示例：**
```
攻击者: curl -H "X-Original-URL: /admin" proxy.com/public
预期: 绕过权限检查访问管理端点
```

**防护效果：** Header 被移除，请求路径不被篡改。

### 6.3 敏感信息保护

**Cookie 泄露风险：**
```
用户 Cookie 可能被发送到第三方 API (coingecko, zerion 等)
```

**防护效果：** Cookie、Authorization 等 Header 被移除，用户隐私得到保护。

## 7. 测试验证脚本

```bash
#!/bin/bash
# header_filter_test.sh

echo "=== Header 过滤功能测试 ==="

# 测试 1: 基础过滤
echo "测试 1: 基础 Header 过滤"
result=$(curl -s http://localhost:8080/debug/headers \
  -H "Cookie: secret=123" \
  -H "X-Forwarded-Host: evil.com")

if echo "$result" | grep -q '"cookie"'; then
  echo "❌ FAIL: Cookie 未被过滤"
else
  echo "✓ PASS: Cookie 已被过滤"
fi

if echo "$result" | grep -q '"x-forwarded-host"'; then
  echo "❌ FAIL: X-Forwarded-Host 未被过滤"
else
  echo "✓ PASS: X-Forwarded-Host 已被过滤"
fi

# 测试 2: 安全 Header 保留
echo ""
echo "测试 2: 安全 Header 保留"
if echo "$result" | grep -q '"user-agent"'; then
  echo "✓ PASS: User-Agent 已保留"
else
  echo "❌ FAIL: User-Agent 被错误移除"
fi

# 测试 3: 响应头添加
echo ""
echo "测试 3: 响应头追踪 ID"
response=$(curl -s -I http://localhost:8080/coingecko/api/v3/ping)
if echo "$response" | grep -q "X-OneKey-Request-Id"; then
  echo "✓ PASS: X-OneKey-Request-Id 已添加"
else
  echo "❌ FAIL: X-OneKey-Request-Id 未添加"
fi

echo ""
echo "=== 测试完成 ==="
```

## 8. 测试结论

### 8.1 测试结果汇总

| 测试项 | 结果 |
|--------|------|
| SSRF 攻击 Headers 过滤 | ✅ PASS |
| Hop-by-hop Headers 过滤 | ✅ PASS |
| 敏感信息 Headers 过滤 | ✅ PASS |
| 安全 Headers 保留 | ✅ PASS |
| 响应头追踪 ID 添加 | ✅ PASS |

### 8.2 安全性评估

- ✅ **SSRF 防护**: X-Forwarded-Host, X-Original-URL 等攻击向量已屏蔽
- ✅ **隐私保护**: Cookie, Authorization 等敏感信息不会泄露给第三方
- ✅ **协议合规**: Hop-by-hop Headers 按 RFC 2616 规范处理
- ✅ **可追踪性**: 每个请求都有唯一的 Request-Id 用于链路追踪

### 8.3 建议

1. **定期审查**: 定期审查需要过滤的 Header 列表，关注新的攻击向量
2. **日志监控**: 监控被过滤的 Header 数量，发现异常攻击行为
3. **白名单机制**: 考虑实现 Header 白名单，只允许特定 Headers 通过

---

*报告生成时间: 2026-01-18*  
*测试工具: curl, OpenResty*  
*测试端点: /debug/headers*
