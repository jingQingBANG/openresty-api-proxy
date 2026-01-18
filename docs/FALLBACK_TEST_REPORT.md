# 服务降级测试报告

## 1. 功能概述

服务降级是一种容错机制，当第三方上游服务出现异常（如超时、连接失败、服务不可用等）时，系统不会直接返回错误，而是返回一个友好的降级响应，提示用户"服务繁忙，请稍后再试"。

### 1.1 设计目标

- **用户体验优化**：避免暴露内部错误细节，返回友好的提示信息
- **多语言支持**：根据 `Accept-Language` 头自动选择中文或英文响应
- **可追溯性**：响应中包含原始错误类型和 Provider 信息
- **监控支持**：记录降级事件，支持统计分析

### 1.2 触发条件

当上游服务返回以下 HTTP 状态码时，触发服务降级：

| 状态码 | 错误类型 | 说明 |
|--------|----------|------|
| 500 | `service_unavailable` | 服务器内部错误 |
| 502 | `connection_failed` | 网关错误/连接失败 |
| 503 | `service_unavailable` | 服务暂时不可用 |
| 504 | `timeout` | 网关超时 |

## 2. 实现架构

### 2.1 核心模块

```
lua/core/fallback.lua  -- 降级处理模块
conf/nginx.conf        -- Nginx 配置（error_page 指令）
```

### 2.2 配置方式

在 `nginx.conf` 中通过以下配置启用服务降级：

```nginx
# API 代理端点
location ~ ^/(zerion|coingecko|alchemy)/ {
    # ... 其他配置 ...

    # 服务降级配置 - 拦截上游错误
    proxy_intercept_errors on;
    error_page 500 502 503 504 = @fallback;

    proxy_pass $proxy_url$is_args$args;
}

# 降级处理 location
location @fallback {
    internal;
    content_by_lua_block {
        -- 降级逻辑处理
    }
}
```

### 2.3 降级响应格式

```json
{
  "success": false,
  "code": 503,
  "message": "服务繁忙，请稍后再试",
  "error": {
    "type": "connection_failed",
    "provider": "coingecko",
    "recoverable": true,
    "original_status": 502
  },
  "fallback": true,
  "retry_after": 30,
  "timestamp": 1768662194
}
```

### 2.4 响应头

| 响应头 | 说明 |
|--------|------|
| `Retry-After: 30` | 建议客户端 30 秒后重试 |
| `X-Fallback: true` | 标识这是降级响应 |
| `X-Fallback-Provider` | 发生降级的 Provider 名称 |
| `X-Original-Status` | 原始上游错误状态码 |

## 3. 测试用例与结果

### 3.1 测试 502 错误（连接失败）

**请求：**
```bash
curl -s http://localhost:8080/test/fallback/502 | jq .
```

**响应：**
```json
{
  "code": 503,
  "message": "服务繁忙，请稍后再试",
  "fallback": true,
  "timestamp": 1768662194,
  "retry_after": 30,
  "error": {
    "original_status": 502,
    "type": "connection_failed",
    "recoverable": true,
    "provider": "test"
  },
  "success": false
}
```

**验证：** ✅ 通过 - 正确返回连接失败的降级响应

---

### 3.2 测试 CoinGecko 服务降级（中文）

**请求：**
```bash
curl -s "http://localhost:8080/test/fallback/simulate?provider=coingecko&code=503" | jq .
```

**响应：**
```json
{
  "code": 503,
  "message": "CoinGecko 行情服务繁忙，请稍后再试",
  "fallback": true,
  "timestamp": 1768662194,
  "retry_after": 30,
  "error": {
    "original_status": 503,
    "type": "service_unavailable",
    "recoverable": true,
    "provider": "coingecko"
  },
  "success": false
}
```

**验证：** ✅ 通过 - 返回 CoinGecko 专属的中文降级消息

---

### 3.3 测试 Zerion 服务降级（英文 + 超时错误）

**请求：**
```bash
curl -s -H "Accept-Language: en-US" \
  "http://localhost:8080/test/fallback/simulate?provider=zerion&code=504" | jq .
```

**响应：**
```json
{
  "code": 503,
  "message": "Zerion service is temporarily unavailable",
  "fallback": true,
  "timestamp": 1768662194,
  "retry_after": 30,
  "error": {
    "original_status": 504,
    "type": "timeout",
    "recoverable": true,
    "provider": "zerion"
  },
  "success": false
}
```

**验证：** ✅ 通过 - 正确识别英文语言偏好，返回英文消息和超时错误类型

---

### 3.4 测试 Alchemy 服务降级

**请求：**
```bash
curl -s "http://localhost:8080/test/fallback/simulate?provider=alchemy&code=502" | jq .
```

**响应：**
```json
{
  "code": 503,
  "message": "Alchemy 区块链服务繁忙，请稍后再试",
  "fallback": true,
  "timestamp": 1768662194,
  "retry_after": 30,
  "error": {
    "original_status": 502,
    "type": "connection_failed",
    "recoverable": true,
    "provider": "alchemy"
  },
  "success": false
}
```

**验证：** ✅ 通过 - 返回 Alchemy 专属的中文降级消息

---

### 3.5 验证响应头

**请求：**
```bash
curl -sI "http://localhost:8080/test/fallback/simulate?provider=coingecko"
```

**响应头：**
```
HTTP/1.1 503 Service Temporarily Unavailable
Content-Type: application/json; charset=utf-8
Retry-After: 30
X-Fallback: true
X-Fallback-Provider: coingecko
X-Simulated-Error: 503
```

**验证：** ✅ 通过 - 所有降级相关响应头都正确设置

---

### 3.6 降级统计

**请求：**
```bash
curl -s http://localhost:8080/fallback/stats | jq .
```

**响应：**
```json
{
  "timestamp": 1768662200,
  "fallback_stats": {
    "by_provider": {
      "zerion": 1,
      "coingecko": 2,
      "alchemy": 1
    },
    "total": 5
  }
}
```

**验证：** ✅ 通过 - 正确记录各 Provider 的降级次数

## 4. 降级消息配置

### 4.1 中文消息

| Provider | 消息 |
|----------|------|
| 默认 | 服务繁忙，请稍后再试 |
| zerion | Zerion 服务暂时不可用，请稍后再试 |
| coingecko | CoinGecko 行情服务繁忙，请稍后再试 |
| alchemy | Alchemy 区块链服务繁忙，请稍后再试 |

### 4.2 英文消息

| Provider | 消息 |
|----------|------|
| 默认 | Service is busy, please try again later |
| zerion | Zerion service is temporarily unavailable, please try again later |
| coingecko | CoinGecko market service is busy, please try again later |
| alchemy | Alchemy blockchain service is busy, please try again later |

## 5. API 端点

### 5.1 降级统计端点

```
GET /fallback/stats
```

返回降级事件的统计信息。

### 5.2 测试端点

| 端点 | 说明 |
|------|------|
| `GET /test/fallback/502` | 模拟 502 连接失败 |
| `GET /test/fallback/504` | 模拟 504 超时（需等待） |
| `GET /test/fallback/simulate?provider={provider}&code={code}` | 模拟任意 Provider 的降级响应 |

## 6. 与其他模块的协作

### 6.1 与熔断器的关系

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│   请求到达   │ ──▶ │  熔断器检查   │ ──▶ │  上游服务调用  │
└─────────────┘     └──────────────┘     └──────────────┘
                          │                     │
                          │ 熔断开启             │ 5xx 错误
                          ▼                     ▼
                    ┌──────────────┐     ┌──────────────┐
                    │ 返回熔断响应  │     │  服务降级响应  │
                    │  (快速失败)   │     │  (友好提示)   │
                    └──────────────┘     └──────────────┘
```

- **熔断器**：在连续失败达到阈值后，直接拒绝请求，不发送到上游
- **服务降级**：当请求已发送到上游但收到错误响应时，返回友好提示

### 6.2 与监控的关系

降级事件会被记录到 `metrics_store` 共享字典中，可通过以下方式查询：

- `/fallback/stats` - 专用降级统计端点
- `/metrics` - 在全局监控报告中包含降级信息

## 7. 测试总结

| 测试项 | 状态 |
|--------|------|
| 502 错误降级 | ✅ 通过 |
| 503 错误降级 | ✅ 通过 |
| 504 超时降级 | ✅ 通过 |
| 中文消息响应 | ✅ 通过 |
| 英文消息响应 | ✅ 通过 |
| Provider 专属消息 | ✅ 通过 |
| 响应头设置 | ✅ 通过 |
| 降级统计记录 | ✅ 通过 |
| Retry-After 头 | ✅ 通过 |

## 8. 使用建议

### 8.1 客户端处理

客户端在收到降级响应时应：

1. 检查 `X-Fallback: true` 头确认是降级响应
2. 根据 `Retry-After` 头设置重试延迟
3. 向用户展示 `message` 字段的友好提示
4. 可根据 `error.recoverable` 决定是否显示重试按钮

### 8.2 监控告警

建议对以下指标设置告警：

- 降级总次数突增
- 某个 Provider 降级率超过阈值
- 连续多次降级

```bash
# 监控降级率
watch -n 5 'curl -s http://localhost:8080/fallback/stats | jq .'
```

## 9. 附录

### 9.1 完整测试命令

```bash
# 测试所有降级场景
echo "=== 服务降级测试 ===" && \
curl -s http://localhost:8080/test/fallback/502 | jq . && \
curl -s "http://localhost:8080/test/fallback/simulate?provider=coingecko&code=503" | jq . && \
curl -s -H "Accept-Language: en-US" "http://localhost:8080/test/fallback/simulate?provider=zerion&code=504" | jq . && \
curl -s "http://localhost:8080/test/fallback/simulate?provider=alchemy&code=502" | jq . && \
curl -s http://localhost:8080/fallback/stats | jq .
```

### 9.2 相关文件

- `lua/core/fallback.lua` - 降级处理模块
- `conf/nginx.conf` - Nginx 配置（@fallback location）
- `docs/FALLBACK_TEST_REPORT.md` - 本测试报告
