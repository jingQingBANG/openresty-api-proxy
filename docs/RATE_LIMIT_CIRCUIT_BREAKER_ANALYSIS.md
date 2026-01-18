# 限流与熔断机制分析报告

> 测试日期: 2026-01-18  
> 测试环境: OpenResty API Proxy v1.0.0

## 1. 概述

本报告分析了 OpenResty API Proxy 中限流（Rate Limiting）和熔断（Circuit Breaker）两种保护机制的执行顺序、触发条件及相互关系。

## 2. 当前执行顺序

### 2.1 代码实现

```nginx
# conf/nginx.conf - access_by_lua_block
access_by_lua_block {
    local access_control = require("core.access_control")
    
    -- 5.1 生成或透传请求ID (用于链路追踪)
    access_control.handle_request_id()
    
    -- 5.2 安全过滤：移除不安全的Header
    access_control.sanitize_headers()
    
    -- 5.3 多维度限流 (IP, API Key, 路径)
    access_control.rate_limit()           -- ← 先执行
    
    -- 5.4 熔断检查 (如果服务熔断，则直接拒绝)
    access_control.check_circuit_breaker()  -- ← 后执行
}
```

### 2.2 执行流程图

```
┌─────────────────────────────────────────────────────────────┐
│                        请求流量                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │   handle_request_id()   │  生成追踪ID
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │   sanitize_headers()    │  安全过滤
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │    rate_limit()         │  ← 第一道防线
                    │  超过阈值返回 429       │     保护本地资源
                    └────────┬────────┘
                             │ 通过
                             ▼
                    ┌─────────────────┐
                    │ check_circuit_breaker() │  ← 第二道防线
                    │  熔断打开返回 503       │     保护上游服务
                    └────────┬────────┘
                             │ 通过
                             ▼
                    ┌─────────────────┐
                    │   代理到上游服务        │
                    └─────────────────┘
```

## 3. 配置参数

### 3.1 限流配置 (lua/config.lua)

```lua
_M.limit_req = {
    rate = 10,        -- 10 requests per second (每秒10个请求)
    burst = 5         -- 允许突发5个请求
}
```

**触发条件**: 当请求速率超过 10 QPS + 5 burst = 15 个/秒时，返回 429

### 3.2 熔断器配置 (lua/config.lua)

```lua
_M.circuit_breaker = {
    failure_threshold = 0.5,  -- 50% 错误率触发熔断
    min_requests = 20,        -- 最小请求数阈值
    reset_timeout = 30,       -- 熔断后等待重试时间(秒)
    max_errors = 5            -- 最大连续错误次数
}
```

**触发条件**: 当连续错误达到 5 次，或错误率超过 50%（且请求数 ≥ 20）时，熔断器打开

## 4. 测试分析

### 4.1 测试场景对比

| 测试方式 | 实际 QPS | 限流触发 | 熔断触发 | 原因 |
|----------|----------|----------|----------|------|
| 串行请求 | ~0.5 | 极少 | 大量 | QPS 远低于限流阈值，但上游错误累计触发熔断 |
| 并发请求 | >>10 | 大量 | 少量 | QPS 超过限流阈值，大部分请求被限流拦截 |

### 4.2 串行请求测试

```bash
# 串行发送 30 个请求（每个请求等待上一个完成）
for i in $(seq 1 30); do
    curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
        "http://localhost:8080/coingecko/api/v3/ping"
done
```

**结果**:
```
200 (成功):      4-5 次
429 (限流):      1-3 次
503 (熔断/降级): 22-25 次
```

**时间线分析**:
```
Request #1:  rate_limit(OK) → circuit_breaker(CLOSED) → 代理 → 上游超时 → 记录失败(1)
Request #2:  rate_limit(OK) → circuit_breaker(CLOSED) → 代理 → 上游超时 → 记录失败(2)
Request #3:  rate_limit(OK) → circuit_breaker(CLOSED) → 代理 → 上游超时 → 记录失败(3)
Request #4:  rate_limit(OK) → circuit_breaker(CLOSED) → 代理 → 上游超时 → 记录失败(4)
Request #5:  rate_limit(OK) → circuit_breaker(CLOSED) → 代理 → 上游超时 → 记录失败(5) ← 熔断打开!
                                                                                          
Request #6:  rate_limit(OK) → circuit_breaker(OPEN!) → 返回 503
Request #7+: rate_limit(OK) → circuit_breaker(OPEN!) → 返回 503
             ↑
             因为是串行请求，实际 QPS ≈ 0.5，远低于限流阈值 10
```

### 4.3 并发请求测试

```bash
# 并发发送 30 个请求
for i in $(seq 1 30); do
    curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 \
        "http://localhost:8080/coingecko/api/v3/ping" &
done
wait
```

**结果**:
```
429 (限流):      24 次  ← 大量请求被限流拦截
503 (熔断/降级): 4 次
200 (成功):      2 次
```

**Prometheus 指标**:
```
proxy_requests_errors_total{provider="coingecko",error_type="rate_limited"} 23
proxy_requests_errors_total{provider="coingecko",error_type="circuit_breaker"} 306
proxy_circuit_breaker_rejected_total{provider="coingecko"} 306
```

## 5. 设计原理

### 5.1 为什么先限流后熔断？

| 执行顺序 | 原因 |
|----------|------|
| **限流在前** | 保护本地资源（CPU/内存），快速拒绝过多请求，不消耗网络带宽 |
| **熔断在后** | 保护上游服务，只有通过限流的请求才需要检查熔断状态 |

### 5.2 两种机制的协同工作

```
                    正常流量
                       │
           ┌───────────▼───────────┐
           │       限流检查         │
           │   (保护本地资源)       │
           └───────────┬───────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
    通过限流      超过阈值       软限流
         │         (429)        (delay)
         ▼                          │
   ┌─────────────┐                  │
   │  熔断检查   │                  │
   │(保护上游)   │◄─────────────────┘
   └──────┬──────┘
          │
    ┌─────┼─────┐
    │           │
 熔断关闭    熔断打开
    │        (503)
    ▼
  代理请求
    │
    ▼
┌─────────┐
│ 上游服务 │
└─────────┘
    │
    ▼
记录结果到熔断器
```

### 5.3 保护层级

| 层级 | 机制 | 响应码 | 保护目标 | 触发成本 |
|------|------|--------|----------|----------|
| 第一层 | 限流 | 429 | 本地资源 | 极低（仅检查令牌桶） |
| 第二层 | 熔断 | 503 | 上游服务 | 低（仅检查状态） |
| 第三层 | 降级 | 503 | 用户体验 | 高（需要代理请求失败） |

## 6. 状态码说明

| 状态码 | 含义 | 触发条件 | Header |
|--------|------|----------|--------|
| **200** | 成功 | 请求正常完成 | - |
| **429** | 限流 | 请求速率超过阈值 | `Retry-After: 1` |
| **503** | 服务不可用 | 熔断打开或上游故障 | `Retry-After: 30` |
| **504** | 网关超时 | 上游响应超时 | - |

## 7. 测试验证脚本

### 7.1 串行请求测试

```bash
#!/bin/bash
# 测试串行请求下的限流与熔断行为

# 重置熔断器
curl -s -X POST http://localhost:8080/circuit-breaker/coingecko/reset > /dev/null
sleep 1

count_200=0
count_429=0
count_503=0
count_other=0

for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
        "http://localhost:8080/coingecko/api/v3/ping" 2>/dev/null || echo "000")
    case $code in
        200) count_200=$((count_200+1)); echo -n "." ;;
        429) count_429=$((count_429+1)); echo -n "L" ;;
        503) count_503=$((count_503+1)); echo -n "B" ;;
        *) count_other=$((count_other+1)); echo -n "?" ;;
    esac
done

echo ""
echo "结果: 200=$count_200, 429(限流)=$count_429, 503(熔断)=$count_503, 其他=$count_other"
```

### 7.2 并发请求测试

```bash
#!/bin/bash
# 测试并发请求下的限流与熔断行为

# 重置熔断器
curl -s -X POST http://localhost:8080/circuit-breaker/coingecko/reset > /dev/null
sleep 1

echo "发送 30 个并发请求..."
for i in $(seq 1 30); do
    curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 \
        "http://localhost:8080/coingecko/api/v3/ping" &
done
wait

echo ""
echo "检查 Prometheus 指标:"
curl -s http://localhost:8080/metrics | grep -E "rate_limited|circuit_breaker"
```

## 8. 优化建议

### 8.1 当前配置评估

| 参数 | 当前值 | 建议 |
|------|--------|------|
| rate | 10 QPS | 根据实际流量调整 |
| burst | 5 | 适合小突发流量 |
| max_errors | 5 | 可适当增加到 10 |
| reset_timeout | 30s | 合理 |

### 8.2 监控建议

建议在 Grafana 中设置以下告警：

```yaml
# 限流告警
- alert: HighRateLimitRate
  expr: rate(proxy_rate_limited_total[5m]) > 10
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "High rate limit rate detected"

# 熔断告警
- alert: CircuitBreakerOpen
  expr: proxy_circuit_breaker_state > 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Circuit breaker is open"
```

## 9. 结论

### 9.1 设计验证

✅ **执行顺序正确**: 先限流 → 后熔断  
✅ **保护层级合理**: 本地资源 → 上游服务 → 用户体验  
✅ **响应码清晰**: 429 限流, 503 熔断/降级  

### 9.2 测试结论

| 场景 | 结论 |
|------|------|
| 串行请求 | 熔断先"生效"是因为 QPS 低于限流阈值 |
| 并发请求 | 限流大量触发，有效保护系统 |
| 混合场景 | 两种机制协同工作，提供多层保护 |

### 9.3 核心要点

1. **限流和熔断是互补的保护机制**，不是竞争关系
2. **先限流后熔断**是正确的设计，符合防御深度原则
3. **测试方式影响结果**：串行测试难以触发限流，应使用并发测试验证限流效果
4. **两者触发条件不同**：
   - 限流：基于请求速率（瞬时）
   - 熔断：基于错误累计（历史）

---

*报告生成时间: 2026-01-18*  
*测试工具: curl, bash*  
*监控系统: Prometheus + lua-resty-prometheus*
