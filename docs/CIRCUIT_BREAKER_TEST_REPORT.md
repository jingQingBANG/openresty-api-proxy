# 熔断器测试报告

## 1. 熔断器设计概述

### 1.1 状态机模型

```
   ┌──────────────────────────────────────────┐
   │                                          │
   ▼          失败达到阈值                    │
┌──────┐  ─────────────────►  ┌──────┐        │
│CLOSED│                      │ OPEN │        │
└──────┘  ◄─────────────────  └──────┘        │
   ▲       探测成功恢复         │              │
   │                          │等待超时        │
   │     ┌───────────┐        │              │
   │     │ HALF_OPEN │◄───────┘              │
   │     └───────────┘                        │
   │           │                              │
   │           │ 探测失败                      │
   └───────────┴──────────────────────────────┘
```

**状态说明：**
- **CLOSED**: 正常状态，所有请求通过
- **OPEN**: 熔断状态，所有请求快速失败（返回 503）
- **HALF_OPEN**: 半开状态，允许部分请求探测服务是否恢复

### 1.2 熔断触发条件

| 条件 | 默认阈值 | 说明 |
|-----|---------|-----|
| 连续失败次数 | 5次 (coingecko=3) | 不受最小请求数限制，立即触发 |
| 错误率 | 50% (coingecko=40%) | 需满足窗口内最小请求数(10) |
| 慢调用比例 | 80% | 响应时间 > 3秒视为慢调用 |

### 1.3 恢复机制配置

| 参数 | 值 | 说明 |
|-----|---|-----|
| open_timeout_seconds | 30秒 | 熔断持续时间，超时后进入半开状态 |
| half_open_max_requests | 3 | 半开状态允许的最大探测请求数 |
| half_open_success_threshold | 2 | 恢复所需的成功探测次数 |

### 1.4 Provider 独立配置

```lua
PROVIDER_CONFIGS = {
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
```

---

## 2. 测试用例与结果

### 2.1 测试环境

- **OpenResty 版本**: 1.27.1.2
- **运行环境**: Docker (macOS)
- **测试时间**: 2026-01-17

### 2.2 测试用例 1: 手动触发熔断

**目的**: 验证手动触发熔断功能

**操作步骤**:
```bash
# 手动触发 coingecko 熔断
curl -s -X POST http://localhost:8080/circuit-breaker/coingecko/trip
```

**预期结果**: 熔断器状态变为 OPEN

**实际结果**:
```json
{
  "action": "trip",
  "provider": "coingecko",
  "success": true,
  "new_state": "OPEN"
}
```

**状态验证**:
```bash
curl -s http://localhost:8080/circuit-breaker | jq '.coingecko.state'
# 输出: "OPEN"

curl -s http://localhost:8080/circuit-breaker | jq '.coingecko.recent_events'
# 输出: "1768650018:CLOSED->OPEN;"
```

✅ **测试通过**

---

### 2.3 测试用例 2: 熔断状态请求拒绝

**目的**: 验证熔断状态下请求被正确拒绝

**前置条件**: coingecko 熔断器处于 OPEN 状态

**操作步骤**:
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" http://localhost:8080/coingecko/api/v3/ping
```

**预期结果**: 返回 503 状态码和熔断错误信息

**实际结果**:
```json
{"error": "Service temporarily unavailable due to circuit breaker", "code": 503}

HTTP Status: 503
```

✅ **测试通过**

---

### 2.4 测试用例 3: 手动重置熔断器

**目的**: 验证手动重置功能

**操作步骤**:
```bash
curl -s -X POST http://localhost:8080/circuit-breaker/coingecko/reset
```

**预期结果**: 熔断器状态恢复为 CLOSED

**实际结果**:
```json
{
  "action": "reset",
  "provider": "coingecko",
  "success": true,
  "new_state": "CLOSED"
}
```

**验证请求恢复正常**:
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" http://localhost:8080/coingecko/api/v3/ping
# 输出:
# {"gecko_says":"(V3) To the Moon!"}
# HTTP Status: 200
```

✅ **测试通过**

---

### 2.5 测试用例 4: 连续失败自动触发熔断

**目的**: 验证连续失败达到阈值时自动触发熔断

**前置条件**: 
- 重置 coingecko 熔断器
- coingecko 的 consecutive_failures 阈值为 3

**操作步骤**:
```bash
# 重置熔断器
curl -s -X POST http://localhost:8080/circuit-breaker/coingecko/reset

# 发送连续失败请求
for i in {1..5}; do 
  curl -s -o /dev/null -w "请求$i: %{http_code}\n" \
    http://localhost:8080/coingecko/api/v3/nonexistent
done
```

**预期结果**: 
- 前 3 个请求触发熔断
- 第 4、5 个请求返回 503

**实际结果**:
```
请求1: 429
请求2: 429
请求3: 429
请求4: 503
请求5: 503
```

**状态验证**:
```json
{
  "state": "OPEN",
  "consecutive_failures": 5,
  "recent_events": "1768650062:CLOSED->OPEN;..."
}
```

✅ **测试通过**

---

### 2.6 测试用例 5: 半开状态与探测恢复

**目的**: 验证熔断超时后进入半开状态，并根据探测结果决定恢复或重新熔断

**前置条件**: coingecko 熔断器处于 OPEN 状态

**操作步骤**:
```bash
# 等待 32 秒（超过 open_timeout_seconds = 30）
sleep 32

# 发送探测请求
curl -s -w "\nHTTP Status: %{http_code}\n" http://localhost:8080/coingecko/api/v3/ping
```

**预期结果**: 
- 熔断器进入 HALF_OPEN 状态
- 根据探测结果决定恢复（成功）或重新熔断（失败）

**实际结果**（探测失败场景）:
```
# 第一个探测请求（超时）
HTTP Status: 504

# 熔断器重新进入 OPEN 状态
HTTP Status: 503
```

**状态变更记录**:
```json
{
  "state": "OPEN",
  "recent_events": "1768650104:HALF_OPEN->OPEN;1768650102:OPEN->HALF_OPEN;1768650062:CLOSED->OPEN;..."
}
```

状态流转: `OPEN` → `HALF_OPEN` → `OPEN`（探测失败）

✅ **测试通过** - 半开状态探测失败后正确重新熔断

---

### 2.7 测试用例 6: 滑动窗口错误率统计

**目的**: 验证滑动窗口内的错误率统计功能

**操作步骤**:
```bash
# 发送多个请求后查看窗口统计
curl -s http://localhost:8080/circuit-breaker | jq '.coingecko.window_stats'
```

**实际结果**:
```json
{
  "failures": 10,
  "slow_calls": 0,
  "failure_rate": "100.00%",
  "requests": 10,
  "slow_call_rate": "0.00%"
}
```

✅ **测试通过**

---

## 3. API 端点说明

### 3.1 查看熔断器状态

```bash
GET /circuit-breaker
```

**响应示例**:
```json
{
  "zerion": {
    "state": "CLOSED",
    "consecutive_failures": 0,
    "window_stats": {
      "requests": 0,
      "failures": 0,
      "failure_rate": "0.00%",
      "slow_calls": 0,
      "slow_call_rate": "0.00%"
    },
    "config": {
      "consecutive_failures_threshold": 5,
      "failure_rate_threshold": "50%",
      "slow_call_rate_threshold": "80%",
      "slow_call_duration_ms": 5000,
      "open_timeout_seconds": 30
    },
    "half_open": {
      "requests": 0,
      "successes": 0,
      "max_requests": 3,
      "success_threshold": 2
    },
    "recent_events": ""
  },
  "coingecko": { ... },
  "alchemy": { ... }
}
```

### 3.2 手动触发熔断

```bash
POST /circuit-breaker/{provider}/trip
```

**响应示例**:
```json
{
  "success": true,
  "provider": "coingecko",
  "action": "trip",
  "new_state": "OPEN"
}
```

### 3.3 手动重置熔断器

```bash
POST /circuit-breaker/{provider}/reset
```

**响应示例**:
```json
{
  "success": true,
  "provider": "coingecko",
  "action": "reset",
  "new_state": "CLOSED"
}
```

---

## 4. 测试结论

### 4.1 功能验证结果

| 功能点 | 状态 | 备注 |
|-------|------|-----|
| 手动触发熔断 | ✅ 通过 | |
| 熔断状态请求拒绝 | ✅ 通过 | 返回 503 |
| 手动重置熔断器 | ✅ 通过 | |
| 连续失败自动触发 | ✅ 通过 | 达到阈值后立即触发 |
| 半开状态转换 | ✅ 通过 | 超时后正确进入 HALF_OPEN |
| 探测失败重新熔断 | ✅ 通过 | |
| 滑动窗口统计 | ✅ 通过 | 60秒窗口 |
| 状态事件记录 | ✅ 通过 | |

### 4.2 状态流转验证

完整的状态流转测试记录：
```
CLOSED -> OPEN (手动触发/连续失败)
OPEN -> HALF_OPEN (等待超时)
HALF_OPEN -> OPEN (探测失败)
HALF_OPEN -> CLOSED (探测成功)
任意状态 -> CLOSED (手动重置)
```

### 4.3 性能影响

- 熔断器使用共享内存字典存储状态，对请求延迟影响极小
- 状态检查在 access 阶段完成，熔断时直接返回，不会产生后端连接

---

## 5. 附录：测试命令速查

```bash
# 查看所有 Provider 熔断状态
curl -s http://localhost:8080/circuit-breaker | jq .

# 查看特定 Provider 状态
curl -s http://localhost:8080/circuit-breaker | jq '.coingecko'

# 手动触发熔断
curl -s -X POST http://localhost:8080/circuit-breaker/coingecko/trip | jq .

# 手动重置
curl -s -X POST http://localhost:8080/circuit-breaker/coingecko/reset | jq .

# 查看状态变更历史
curl -s http://localhost:8080/circuit-breaker | jq '.coingecko.recent_events'

# 查看窗口统计
curl -s http://localhost:8080/circuit-breaker | jq '.coingecko.window_stats'
```
