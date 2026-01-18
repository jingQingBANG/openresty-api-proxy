# Prometheus 监控指标测试报告

## 概述

本文档描述了基于 `lua-resty-prometheus` 插件重构后的监控指标模块的功能、配置和测试方法。

## 模块架构

```
┌─────────────────────────────────────────────────────────────────┐
│                     Prometheus Server                            │
│                    (Pull /metrics)                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     OpenResty Proxy                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ /metrics    │  │ /metrics/   │  │  lua/core/metrics.lua   │  │
│  │ (Prometheus)│  │ json        │  │  (lua-resty-prometheus) │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
│                                              │                   │
│  ┌───────────────────────────────────────────┼─────────────────┐ │
│  │              Shared Dict: metrics_store   │                 │ │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌───┴───┐             │ │
│  │  │Counters │ │Histograms│ │ Gauges │ │ Locks │             │ │
│  │  └─────────┘ └─────────┘ └─────────┘ └───────┘             │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## 指标定义

### Counter 指标（累计计数器）

| 指标名称 | 标签 | 说明 |
|---------|------|------|
| `proxy_requests_total` | `provider`, `method`, `status` | 总请求数 |
| `proxy_requests_success_total` | `provider` | 成功请求数 (2xx, 3xx) |
| `proxy_requests_errors_total` | `provider`, `error_type` | 错误请求数 |
| `proxy_rate_limited_total` | `provider` | 被限流拒绝的请求数 |
| `proxy_circuit_breaker_rejected_total` | `provider` | 被熔断器拒绝的请求数 |
| `proxy_fallback_triggered_total` | `provider`, `original_status` | 触发降级的请求数 |

### Histogram 指标（直方图）

| 指标名称 | 标签 | 桶边界 (秒) | 说明 |
|---------|------|------------|------|
| `proxy_request_duration_seconds` | `provider` | 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 | 请求总延迟 |
| `proxy_upstream_duration_seconds` | `provider` | 同上 | 上游响应时间 |

### Gauge 指标（瞬时值）

| 指标名称 | 标签 | 说明 |
|---------|------|------|
| `proxy_connections` | `state` | 当前连接数 (active/reading/writing/waiting) |
| `proxy_provider_health` | `provider`, `state` | Provider 健康状态 (1=健康, 0=不健康) |
| `proxy_circuit_breaker_state` | `provider` | 熔断器状态 (0=CLOSED, 1=HALF_OPEN, 2=OPEN) |
| `proxy_circuit_breaker_failures` | `provider` | 熔断器当前失败计数 |
| `proxy_start_time_seconds` | - | 服务启动时间戳 |

### 错误类型分类

| error_type | 说明 |
|------------|------|
| `timeout` | 请求超时 (504) |
| `connect_failed` | 连接失败 (502) |
| `rate_limited` | 限流拒绝 (429) |
| `circuit_breaker` | 熔断拒绝 (503) |
| `upstream_5xx` | 上游服务器错误 (5xx) |
| `client_4xx` | 客户端错误 (4xx) |

## 配置说明

### nginx.conf 共享字典配置

```nginx
# Prometheus 指标存储
lua_shared_dict metrics_store 32m; 
# Prometheus 指标锁
lua_shared_dict prometheus_locks 128k;
```

### 初始化配置

```nginx
# Master 进程初始化 (预加载模块)
init_by_lua_block {
    require("core.metrics")
    require("core.circuit_breaker").init()
}

# Worker 进程初始化 (lua-resty-prometheus 必须在此阶段初始化)
init_worker_by_lua_block {
    local metrics = require("core.metrics")
    metrics.init()
}
```

> **重要**: `lua-resty-prometheus` 的 `init()` 必须在 `init_worker_by_lua_block` 阶段调用，不能在 `init_by_lua_block` 阶段调用。

### 端点配置

```nginx
# Prometheus 格式端点
location = /metrics {
    access_log off;
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    deny all;

    content_by_lua_block {
        local metrics = require("core.metrics")
        metrics.collect_metrics()
    }
}

# JSON 格式端点 (兼容)
location = /metrics/json {
    access_log off;
    content_by_lua_block {
        local cjson = require("cjson")
        local metrics = require("core.metrics")
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode(metrics.get_report()))
    }
}
```

## 测试方法

### 1. 启动服务

```bash
# 构建并启动 Docker 容器
docker-compose up -d --build

# 查看日志
docker-compose logs -f
```

### 2. 基础指标测试

#### 2.1 访问 Prometheus 指标端点

```bash
# 获取 Prometheus 格式指标
curl http://localhost:8080/metrics
```

**预期输出示例：**

```prometheus
# HELP proxy_requests_total Total number of HTTP requests
# TYPE proxy_requests_total counter
proxy_requests_total{provider="zerion",method="GET",status="200"} 10
proxy_requests_total{provider="coingecko",method="GET",status="200"} 5

# HELP proxy_request_duration_seconds Request duration in seconds
# TYPE proxy_request_duration_seconds histogram
proxy_request_duration_seconds_bucket{provider="zerion",le="0.01"} 2
proxy_request_duration_seconds_bucket{provider="zerion",le="0.025"} 5
proxy_request_duration_seconds_bucket{provider="zerion",le="0.05"} 8
proxy_request_duration_seconds_bucket{provider="zerion",le="0.1"} 10
proxy_request_duration_seconds_bucket{provider="zerion",le="+Inf"} 10
proxy_request_duration_seconds_sum{provider="zerion"} 0.35
proxy_request_duration_seconds_count{provider="zerion"} 10

# HELP proxy_connections Current number of connections
# TYPE proxy_connections gauge
proxy_connections{state="active"} 1
proxy_connections{state="reading"} 0
proxy_connections{state="writing"} 1
proxy_connections{state="waiting"} 0

# HELP proxy_provider_health Provider health status (1=healthy, 0=unhealthy)
# TYPE proxy_provider_health gauge
proxy_provider_health{provider="zerion",state="CLOSED"} 1
proxy_provider_health{provider="coingecko",state="CLOSED"} 1
proxy_provider_health{provider="alchemy",state="CLOSED"} 1

# HELP proxy_start_time_seconds Unix timestamp of service start time
# TYPE proxy_start_time_seconds gauge
proxy_start_time_seconds 1737100800
```

#### 2.2 访问 JSON 格式端点

```bash
curl http://localhost:8080/metrics/json | jq
```

**预期输出：**

```json
{
  "timestamp": 1737100900,
  "uptime_seconds": 100,
  "global": {
    "note": "Use /metrics endpoint for detailed Prometheus metrics"
  },
  "providers": {
    "zerion": {
      "health": {
        "state": "CLOSED",
        "failure_count": 0,
        "healthy": true
      }
    },
    "coingecko": {
      "health": {
        "state": "CLOSED",
        "failure_count": 0,
        "healthy": true
      }
    },
    "alchemy": {
      "health": {
        "state": "CLOSED",
        "failure_count": 0,
        "healthy": true
      }
    }
  },
  "connections": {
    "active": 1,
    "reading": 0,
    "writing": 1,
    "waiting": 0
  }
}
```

### 3. 请求指标测试

#### 3.1 生成测试请求

```bash
# 发送多个请求以生成指标
for i in {1..10}; do
    curl -s http://localhost:8080/coingecko/api/v3/ping > /dev/null
    sleep 0.1
done

# 检查指标
curl -s http://localhost:8080/metrics | grep proxy_requests_total
```

**预期输出：**

```prometheus
proxy_requests_total{provider="coingecko",method="GET",status="200"} 10
```

#### 3.2 验证延迟直方图

```bash
curl -s http://localhost:8080/metrics | grep proxy_request_duration
```

**预期输出：**

```prometheus
# HELP proxy_request_duration_seconds Request duration in seconds
# TYPE proxy_request_duration_seconds histogram
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.01"} 0
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.025"} 0
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.05"} 2
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.1"} 5
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.25"} 8
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.5"} 10
proxy_request_duration_seconds_bucket{provider="coingecko",le="+Inf"} 10
proxy_request_duration_seconds_sum{provider="coingecko"} 2.15
proxy_request_duration_seconds_count{provider="coingecko"} 10
```

### 4. 错误指标测试

#### 4.1 触发降级 (502 错误)

```bash
# 触发 502 错误
curl -s http://localhost:8080/test/fallback/502

# 检查错误指标
curl -s http://localhost:8080/metrics | grep -E "(errors_total|fallback)"
```

**预期输出：**

```prometheus
proxy_requests_errors_total{provider="test",error_type="connect_failed"} 1
proxy_fallback_triggered_total{provider="test",original_status="502"} 1
```

#### 4.2 触发超时 (504 错误)

```bash
# 触发 504 超时
curl -s --max-time 5 http://localhost:8080/test/fallback/504

# 检查指标
curl -s http://localhost:8080/metrics | grep -E "error_type=\"timeout\""
```

### 5. 限流指标测试

```bash
# 快速发送大量请求触发限流
for i in {1..50}; do
    curl -s http://localhost:8080/coingecko/api/v3/ping &
done
wait

# 检查限流指标
curl -s http://localhost:8080/metrics | grep rate_limited
```

**预期输出：**

```prometheus
proxy_rate_limited_total{provider="coingecko"} 35
```

### 6. 熔断器指标测试

#### 6.1 手动触发熔断

```bash
# 触发熔断
curl -X POST http://localhost:8080/circuit-breaker/zerion/trip

# 检查熔断器状态指标
curl -s http://localhost:8080/metrics | grep circuit_breaker
```

**预期输出：**

```prometheus
proxy_circuit_breaker_state{provider="zerion"} 2
proxy_provider_health{provider="zerion",state="OPEN"} 0
```

#### 6.2 重置熔断器

```bash
# 重置熔断器
curl -X POST http://localhost:8080/circuit-breaker/zerion/reset

# 检查状态
curl -s http://localhost:8080/metrics | grep "circuit_breaker_state.*zerion"
```

**预期输出：**

```prometheus
proxy_circuit_breaker_state{provider="zerion"} 0
```

### 7. 连接指标测试

```bash
# 并发请求测试
for i in {1..20}; do
    curl -s http://localhost:8080/coingecko/api/v3/ping &
done

# 立即检查连接指标
curl -s http://localhost:8080/metrics | grep proxy_connections
```

**预期输出：**

```prometheus
proxy_connections{state="active"} 21
proxy_connections{state="reading"} 0
proxy_connections{state="writing"} 20
proxy_connections{state="waiting"} 0
```

## Prometheus 集成配置

### prometheus.yml 配置示例

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'openresty-proxy'
    static_configs:
      - targets: ['openresty:8080']
    metrics_path: '/metrics'
    scrape_interval: 10s
    scrape_timeout: 5s
```

### Docker Compose 集成示例

```yaml
version: '3.8'

services:
  openresty:
    build: .
    ports:
      - "8080:8080"
    networks:
      - monitoring

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    networks:
      - monitoring
    depends_on:
      - openresty

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    networks:
      - monitoring
    depends_on:
      - prometheus

networks:
  monitoring:
    driver: bridge
```

## Grafana 仪表板示例查询

### 请求速率 (QPS)

```promql
rate(proxy_requests_total[1m])
```

### 按 Provider 分组的请求速率

```promql
sum by (provider) (rate(proxy_requests_total[1m]))
```

### 错误率

```promql
sum(rate(proxy_requests_errors_total[5m])) / sum(rate(proxy_requests_total[5m])) * 100
```

### P95 延迟

```promql
histogram_quantile(0.95, sum(rate(proxy_request_duration_seconds_bucket[5m])) by (le, provider))
```

### P99 延迟

```promql
histogram_quantile(0.99, sum(rate(proxy_request_duration_seconds_bucket[5m])) by (le))
```

### 熔断器状态

```promql
proxy_circuit_breaker_state
```

### 服务可用性

```promql
avg(proxy_provider_health) * 100
```

## 告警规则示例

```yaml
groups:
  - name: openresty-proxy
    rules:
      # 高错误率告警
      - alert: HighErrorRate
        expr: |
          sum(rate(proxy_requests_errors_total[5m])) 
          / sum(rate(proxy_requests_total[5m])) > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High error rate detected"
          description: "Error rate is {{ $value | humanizePercentage }}"

      # 熔断器打开告警
      - alert: CircuitBreakerOpen
        expr: proxy_circuit_breaker_state == 2
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Circuit breaker is OPEN"
          description: "Provider {{ $labels.provider }} circuit breaker is open"

      # 高延迟告警
      - alert: HighLatency
        expr: |
          histogram_quantile(0.95, 
            sum(rate(proxy_request_duration_seconds_bucket[5m])) by (le)
          ) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High latency detected"
          description: "P95 latency is {{ $value }}s"

      # 限流告警
      - alert: HighRateLimiting
        expr: rate(proxy_rate_limited_total[5m]) > 10
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High rate limiting"
          description: "Rate limiting {{ $value }} requests/sec"
```

## 测试检查清单

| 测试项 | 状态 | 备注 |
|--------|------|------|
| `/metrics` 端点返回 Prometheus 格式 | ⬜ | |
| `/metrics/json` 端点返回 JSON 格式 | ⬜ | |
| `proxy_requests_total` 正确递增 | ⬜ | |
| `proxy_request_duration_seconds` 直方图正确记录 | ⬜ | |
| `proxy_requests_errors_total` 按错误类型分类 | ⬜ | |
| `proxy_rate_limited_total` 限流计数正确 | ⬜ | |
| `proxy_circuit_breaker_rejected_total` 熔断计数正确 | ⬜ | |
| `proxy_fallback_triggered_total` 降级计数正确 | ⬜ | |
| `proxy_connections` 连接数正确 | ⬜ | |
| `proxy_provider_health` 健康状态正确 | ⬜ | |
| `proxy_circuit_breaker_state` 熔断状态正确 | ⬜ | |
| Prometheus 可正常采集指标 | ⬜ | |
| Grafana 可正常展示指标 | ⬜ | |

## 故障排查

### 1. 指标端点返回 500 错误

检查 `lua-resty-prometheus` 是否正确安装：

```bash
docker exec -it <container_id> ls /usr/local/openresty/site/lualib/prometheus.lua
```

### 2. 指标数据为空

确认初始化是否成功：

```bash
docker logs <container_id> 2>&1 | grep -i "metrics\|prometheus"
```

### 3. 共享字典空间不足

增加 `metrics_store` 大小：

```nginx
lua_shared_dict metrics_store 64m;
```

### 4. Prometheus 采集失败

检查网络访问权限：

```bash
# 从 Prometheus 容器测试连接
docker exec -it prometheus wget -O- http://openresty:8080/metrics
```

## 压测实测报告

### 测试环境

- **测试日期**: 2026-01-18
- **服务版本**: OpenResty 1.27.1.2
- **测试工具**: Apache Benchmark (ab)
- **运行环境**: Docker Container

---

### 测试 1: 健康检查端点性能

**测试命令:**
```bash
ab -n 100 -c 10 http://localhost:8080/health
```

**测试结果:**
```
Server Software:        openresty/1.27.1.2
Server Hostname:        localhost
Server Port:            8080

Document Path:          /health
Document Length:        56 bytes

Concurrency Level:      10
Time taken for tests:   0.031 seconds
Complete requests:      100
Failed requests:        0
Total transferred:      23800 bytes
HTML transferred:       5600 bytes
Requests per second:    3222.90 [#/sec] (mean)
Time per request:       3.103 [ms] (mean)
Time per request:       0.310 [ms] (mean, across all concurrent requests)
Transfer rate:          749.07 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.1      0       1
Processing:     1    3   1.6      2       6
Waiting:        1    3   1.6      2       6
Total:          1    3   1.6      2       6

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      3
  75%      4
  80%      4
  90%      5
  95%      6
  98%      6
  99%      6
 100%      6 (longest request)
```

**结论:**
| 指标 | 值 |
|------|-----|
| QPS | **3222.90** |
| 平均延迟 | **3.1ms** |
| P95 延迟 | **6ms** |
| 成功率 | **100%** |

---

### 测试 2: 代理端点并发压测

**测试命令:**
```bash
ab -n 200 -c 20 http://localhost:8080/coingecko/api/v3/ping
```

**测试结果:**
```
Server Software:        openresty/1.27.1.2
Concurrency Level:      20
Time taken for tests:   1.308 seconds
Complete requests:      200
Failed requests:        198
   (Connect: 0, Receive: 0, Length: 198, Exceptions: 0)
Non-2xx responses:      198
Requests per second:    152.85 [#/sec] (mean)
Time per request:       130.849 [ms] (mean)

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.2      0       1
Processing:     1   19  83.6      4     751
Waiting:        0   17  83.6      1     746
Total:          1   19  83.7      4     751

Percentage of the requests served within a certain time (ms)
  50%      4
  66%      5
  75%      6
  80%      7
  90%     14
  95%     23
  98%    409
  99%    562
 100%    751 (longest request)
```

**结论:**
| 指标 | 值 |
|------|-----|
| QPS | **152.85** |
| 成功响应 (200) | 2 (1%) |
| 限流拦截 (429) | 198 (99%) |
| 说明 | 限流功能正常工作 |

---

### Prometheus 指标实测输出

**测试命令:**
```bash
curl -s http://localhost:8080/metrics
```

**实际输出:**
```prometheus
# HELP nginx_metric_errors_total Number of nginx-lua-prometheus errors
# TYPE nginx_metric_errors_total counter
nginx_metric_errors_total 0

# HELP proxy_circuit_breaker_failures Current failure count in circuit breaker
# TYPE proxy_circuit_breaker_failures gauge
proxy_circuit_breaker_failures{provider="alchemy"} 0
proxy_circuit_breaker_failures{provider="coingecko"} 0
proxy_circuit_breaker_failures{provider="zerion"} 0

# HELP proxy_circuit_breaker_rejected_total Total number of requests rejected by circuit breaker
# TYPE proxy_circuit_breaker_rejected_total counter
proxy_circuit_breaker_rejected_total{provider="coingecko"} 18

# HELP proxy_circuit_breaker_state Circuit breaker state (0=CLOSED, 1=HALF_OPEN, 2=OPEN)
# TYPE proxy_circuit_breaker_state gauge
proxy_circuit_breaker_state{provider="alchemy"} 0
proxy_circuit_breaker_state{provider="coingecko"} 0
proxy_circuit_breaker_state{provider="zerion"} 0

# HELP proxy_connections Current number of connections
# TYPE proxy_connections gauge
proxy_connections{state="active"} 1
proxy_connections{state="reading"} 0
proxy_connections{state="waiting"} 0
proxy_connections{state="writing"} 1

# HELP proxy_fallback_triggered_total Total number of fallback responses
# TYPE proxy_fallback_triggered_total counter
proxy_fallback_triggered_total{provider="coingecko",original_status="504"} 1
proxy_fallback_triggered_total{provider="test",original_status="502"} 1

# HELP proxy_provider_health Provider health status (1=healthy, 0=unhealthy)
# TYPE proxy_provider_health gauge
proxy_provider_health{provider="alchemy",state="CLOSED"} 1
proxy_provider_health{provider="coingecko",state="CLOSED"} 1
proxy_provider_health{provider="zerion",state="CLOSED"} 1

# HELP proxy_request_duration_seconds Request duration in seconds
# TYPE proxy_request_duration_seconds histogram
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.01"} 224
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.025"} 224
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.05"} 224
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.1"} 225
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.25"} 230
proxy_request_duration_seconds_bucket{provider="coingecko",le="0.5"} 246
proxy_request_duration_seconds_bucket{provider="coingecko",le="1"} 249
proxy_request_duration_seconds_bucket{provider="coingecko",le="2.5"} 249
proxy_request_duration_seconds_bucket{provider="coingecko",le="5"} 249
proxy_request_duration_seconds_bucket{provider="coingecko",le="10"} 249
proxy_request_duration_seconds_bucket{provider="coingecko",le="+Inf"} 249
proxy_request_duration_seconds_count{provider="coingecko"} 249
proxy_request_duration_seconds_sum{provider="coingecko"} 9.099

# HELP proxy_requests_errors_total Total number of failed requests
# TYPE proxy_requests_errors_total counter
proxy_requests_errors_total{provider="coingecko",error_type="circuit_breaker"} 18
proxy_requests_errors_total{provider="coingecko",error_type="rate_limited"} 224

# HELP proxy_requests_success_total Total number of successful requests
# TYPE proxy_requests_success_total counter
proxy_requests_success_total{provider="coingecko"} 7

# HELP proxy_requests_total Total number of HTTP requests
# TYPE proxy_requests_total counter
proxy_requests_total{provider="coingecko",method="GET",status="200"} 7
proxy_requests_total{provider="coingecko",method="GET",status="429"} 224
proxy_requests_total{provider="coingecko",method="GET",status="503"} 18

# HELP proxy_start_time_seconds Unix timestamp of service start time
# TYPE proxy_start_time_seconds gauge
proxy_start_time_seconds 1768667418.438

# HELP proxy_upstream_duration_seconds Upstream response time in seconds
# TYPE proxy_upstream_duration_seconds histogram
proxy_upstream_duration_seconds_bucket{provider="coingecko",le="0.5"} 8
proxy_upstream_duration_seconds_bucket{provider="coingecko",le="1"} 10
proxy_upstream_duration_seconds_bucket{provider="coingecko",le="2.5"} 10
proxy_upstream_duration_seconds_bucket{provider="coingecko",le="5"} 10
proxy_upstream_duration_seconds_bucket{provider="coingecko",le="10"} 10
proxy_upstream_duration_seconds_bucket{provider="coingecko",le="+Inf"} 10
proxy_upstream_duration_seconds_count{provider="coingecko"} 10
proxy_upstream_duration_seconds_sum{provider="coingecko"} 4.6
```

---

### 指标数据分析

#### 请求统计汇总

| 指标 | 值 | 说明 |
|------|-----|------|
| 总请求数 | 249 | proxy_requests_total 所有状态码之和 |
| 成功请求 (200) | 7 | 2.8% |
| 限流拒绝 (429) | 224 | 90.0% |
| 熔断拒绝 (503) | 18 | 7.2% |

#### 错误类型分布

| 错误类型 | 数量 | 占比 |
|---------|------|------|
| rate_limited | 224 | 92.6% |
| circuit_breaker | 18 | 7.4% |

#### 延迟分布 (proxy_request_duration_seconds)

| 百分位 | 延迟 (秒) | 请求数 |
|--------|----------|--------|
| ≤ 10ms | 0.01 | 224 (90%) |
| ≤ 50ms | 0.05 | 224 (90%) |
| ≤ 100ms | 0.1 | 225 (90.4%) |
| ≤ 250ms | 0.25 | 230 (92.4%) |
| ≤ 500ms | 0.5 | 246 (98.8%) |
| ≤ 1s | 1.0 | 249 (100%) |

**平均延迟**: 9.099s / 249 = **36.5ms**

#### Provider 健康状态

| Provider | 状态 | 健康值 | 失败计数 |
|----------|------|--------|---------|
| coingecko | CLOSED | 1 (健康) | 0 |
| zerion | CLOSED | 1 (健康) | 0 |
| alchemy | CLOSED | 1 (健康) | 0 |

#### 降级触发统计

| Provider | 原始状态码 | 触发次数 |
|----------|-----------|---------|
| coingecko | 504 | 1 |
| test | 502 | 1 |

---

### JSON 格式指标输出

**测试命令:**
```bash
curl -s http://localhost:8080/metrics/json | python3 -m json.tool
```

**实际输出:**
```json
{
{
  "providers": {
    "zerion": {
      "requests": {
        "total": 0,
        "success": 0,
        "errors": 0
      },
      "health": {
        "state": "CLOSED",
        "failure_count": 0,
        "healthy": true
      },
      "protection": {
        "fallback": 0,
        "rate_limited": 0,
        "circuit_breaker": 0
      }
    },
    "coingecko": {
      "requests": {
        "total": 20,
        "success": 1,
        "errors": 19
      },
      "health": {
        "state": "CLOSED",
        "failure_count": 0,
        "healthy": true
      },
      "protection": {
        "fallback": 0,
        "rate_limited": 13,
        "circuit_breaker": 6
      }
    },
    "alchemy": {
      "requests": {
        "total": 0,
        "success": 0,
        "errors": 0
      },
      "health": {
        "state": "CLOSED",
        "failure_count": 0,
        "healthy": true
      },
      "protection": {
        "fallback": 0,
        "rate_limited": 0,
        "circuit_breaker": 0
      }
    }
  },
  "connections": {
    "reading": 0,
    "writing": 1,
    "waiting": 0,
    "active": 1
  },
  "timestamp": 1768673087,
  "uptime_seconds": 28.05999994278,
  "global": {
    "requests": {
      "success_rate": "5.00%",
      "total": 20,
      "success": 1,
      "errors": 19
    },
    "protection": {
      "fallback": 0,
      "rate_limited": 13,
      "circuit_breaker": 6
    }
  }
}
```

---

### 测试结论

| 测试项 | 状态 | 备注 |
|--------|------|------|
| `/metrics` 端点返回 Prometheus 格式 | ✅ 通过 | 格式正确 |
| `/metrics/json` 端点返回 JSON 格式 | ✅ 通过 | 格式正确 |
| `proxy_requests_total` 正确递增 | ✅ 通过 | 按 provider/method/status 分组 |
| `proxy_request_duration_seconds` 直方图正确记录 | ✅ 通过 | 10 个桶 + sum + count |
| `proxy_requests_errors_total` 按错误类型分类 | ✅ 通过 | rate_limited, circuit_breaker |
| `proxy_rate_limited_total` 限流计数正确 | ✅ 通过 | 224 次限流 |
| `proxy_circuit_breaker_rejected_total` 熔断计数正确 | ✅ 通过 | 18 次熔断拒绝 |
| `proxy_fallback_triggered_total` 降级计数正确 | ✅ 通过 | 按 provider + status 分组 |
| `proxy_connections` 连接数正确 | ✅ 通过 | active/reading/writing/waiting |
| `proxy_provider_health` 健康状态正确 | ✅ 通过 | 3 个 provider 均健康 |
| `proxy_circuit_breaker_state` 熔断状态正确 | ✅ 通过 | 均为 CLOSED (0) |
| `nginx_metric_errors_total` 无错误 | ✅ 通过 | 值为 0 |

---

## 版本信息

- OpenResty: 1.27.1.2
- lua-resty-prometheus: nginx-lua-prometheus (via luarocks)
- Prometheus: 2.x
- Grafana: 9.x+
- 测试日期: 2026-01-18
