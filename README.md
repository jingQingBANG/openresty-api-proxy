# OpenResty API Proxy

基于 OpenResty 的高性能 API 代理网关，提供完整的流量治理能力。

## 功能特性

| 功能模块 | 说明 | 文档 |
|---------|------|------|
| **API 路由** | 多 Provider 路由转发 (Zerion, CoinGecko, Alchemy) | [router.lua](lua/core/router.lua) |
| **认证注入** | 自动注入 API Key (Basic Auth, Header, URL) | [auth.lua](lua/core/auth.lua) |
| **Header 过滤** | 请求/响应头安全过滤与注入 | [HEADER_FILTER_TEST_REPORT.md](docs/HEADER_FILTER_TEST_REPORT.md) |
| **限流控制** | 基于令牌桶的请求限流 | [RATE_LIMIT_TEST_REPORT.md](docs/RATE_LIMIT_TEST_REPORT.md) |
| **熔断器** | 三态熔断保护 (CLOSED/HALF_OPEN/OPEN) | [CIRCUIT_BREAKER_TEST_REPORT.md](docs/CIRCUIT_BREAKER_TEST_REPORT.md) |
| **服务降级** | 优雅降级与友好错误提示 | [FALLBACK_TEST_REPORT.md](docs/FALLBACK_TEST_REPORT.md) |
| **Prometheus 监控** | 标准 Prometheus 指标输出 | [METRICS_TEST_REPORT.md](docs/METRICS_TEST_REPORT.md) |
| **结构化日志** | JSON 格式访问日志 | [logger.lua](lua/core/logger.lua) |

## 架构图

```
                                    ┌─────────────────────┐
                                    │   Prometheus        │
                                    │   (Pull /metrics)   │
                                    └──────────┬──────────┘
                                               │
┌──────────────┐                    ┌──────────▼──────────┐                    ┌─────────────────┐
│              │    HTTP Request    │                     │   HTTPS Proxy      │                 │
│   Client     │ ─────────────────► │  OpenResty Proxy    │ ─────────────────► │  Upstream APIs  │
│              │                    │     (Port 8080)     │                    │                 │
└──────────────┘                    └─────────────────────┘                    └─────────────────┘
                                               │
                                    ┌──────────┴──────────┐
                                    │                     │
                          ┌─────────▼─────────┐ ┌─────────▼─────────┐
                          │   Rate Limiter    │ │  Circuit Breaker  │
                          │ (Token Bucket)    │ │  (Three States)   │
                          └───────────────────┘ └───────────────────┘
```

## 快速开始

### 1. 环境要求

- Docker & Docker Compose
- 第三方 API Keys (可选)

### 2. 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env
# 编辑配置 (可选，用于真实 API 访问)
vim .env
```

```env
# .env 文件内容
ZERION_API_KEY=your_zerion_api_key
COINGECKO_API_KEY=your_coingecko_api_key
ALCHEMY_API_KEY=your_alchemy_api_key
```

### 3. 启动服务

```bash
# 构建并启动
grep env -A 3  docker-compose.yml
./start-docker.sh

# 查看日志
docker-compose logs -f

# 停止服务
./stop-docker.sh
```

### 4. 验证服务

```bash
# 健康检查
curl http://localhost:8080/health

# 服务信息
curl http://localhost:8080/

# Prometheus 指标
curl http://localhost:8080/metrics
```

## API 端点

### 管理端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/metrics` | GET | Prometheus 指标 |
| `/metrics/json` | GET | JSON 格式指标 |
| `/status` | GET | Nginx 连接状态 |
| `/circuit-breaker` | GET | 熔断器状态 |
| `/circuit-breaker/{provider}/reset` | POST | 重置熔断器 |
| `/circuit-breaker/{provider}/trip` | POST | 触发熔断 |
| `/fallback/stats` | GET | 降级统计 |
| `/debug/headers` | GET | Header 过滤调试 |

### 代理端点

| 端点 | 目标服务 | 说明 |
|------|---------|------|
| `/zerion/*` | api.zerion.io | Zerion DeFi API |
| `/coingecko/*` | api.coingecko.com | CoinGecko 行情 API |
| `/alchemy/*` | eth-mainnet.g.alchemy.com | Alchemy 区块链 API |

### 测试端点

| 端点 | 说明 |
|------|------|
| `/test/fallback/502` | 模拟 502 错误 |
| `/test/fallback/504` | 模拟 504 超时 |
| `/test/fallback/simulate` | 模拟自定义错误 |

## 配置说明

### nginx.conf 核心配置

```nginx
# 共享字典
lua_shared_dict limit_req_store 10m;    # 限流存储
lua_shared_dict metrics_store 32m;      # Prometheus 指标
lua_shared_dict health_check 5m;        # 熔断器状态

# 初始化
init_by_lua_block {
    require("core.metrics")
    require("core.circuit_breaker").init()
}

init_worker_by_lua_block {
    require("core.metrics").init()
}
```

### 限流配置

```lua
-- lua/config.lua
_M.limit_req = {
    rate = 10,    -- 每秒请求数
    burst = 5     -- 突发容量
}
```

### 熔断器配置

```lua
-- lua/config.lua
_M.circuit_breaker = {
    failure_threshold = 0.5,  -- 50% 错误率触发
    min_requests = 20,        -- 最小请求数阈值
    reset_timeout = 30,       -- 熔断恢复时间(秒)
    max_errors = 5            -- 最大连续错误数
}
```

## 模块说明

### 1. 路由模块 (router.lua)

根据 URI 前缀路由到不同的后端服务：

```lua
-- 路由配置
/zerion/*    -> api.zerion.io
/coingecko/* -> api.coingecko.com
/alchemy/*   -> eth-mainnet.g.alchemy.com
```

### 2. 认证模块 (auth.lua)

支持三种认证方式：
- **Basic Auth**: Zerion (Authorization: Basic base64(apikey:))
- **Header**: CoinGecko (x-cg-pro-api-key: xxx)
- **URL Param**: Alchemy (路径中注入 API Key)

### 3. Header 过滤模块 (access_control.lua)

多层次的请求/响应头安全处理：

**请求头过滤 (sanitize_headers):**
- 移除代理绕过/SSRF 攻击头 (X-Forwarded-Host, X-Original-URL 等)
- 移除 Hop-by-hop Headers (Connection, Keep-Alive, Proxy-* 等)
- 移除敏感信息头 (Cookie, Authorization, Origin, Referer)

**代理转发时清除:**
```nginx
proxy_set_header Connection "";
proxy_set_header Cookie "";
proxy_set_header Origin "";
proxy_set_header Referer "";
```

**响应头注入:**
- `X-OneKey-Request-Id`: 请求追踪 ID
- `X-API-Provider`: API 提供者标识

**调试端点:** `/debug/headers` - 查看 Header 过滤效果

### 4. 限流模块 (rate_limit.lua)

基于令牌桶算法的请求限流：
- 按 IP 地址限流
- 可配置速率和突发容量
- 返回 429 状态码

### 5. 熔断器模块 (circuit_breaker.lua)

三态熔断保护机制：

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

### 6. 降级模块 (fallback.lua)

优雅降级处理：
- 5xx 错误触发降级
- 多语言错误消息 (中/英)
- 按 Provider 定制消息
- 返回 503 + Retry-After

### 7. 监控模块 (metrics.lua)

基于 lua-resty-prometheus 的 Prometheus 指标：

**Counter 指标:**
- `proxy_requests_total{provider,method,status}`
- `proxy_requests_success_total{provider}`
- `proxy_requests_errors_total{provider,error_type}`
- `proxy_rate_limited_total{provider}`
- `proxy_circuit_breaker_rejected_total{provider}`
- `proxy_fallback_triggered_total{provider,original_status}`

**Histogram 指标:**
- `proxy_request_duration_seconds{provider}`
- `proxy_upstream_duration_seconds{provider}`

**Gauge 指标:**
- `proxy_connections{state}`
- `proxy_provider_health{provider,state}`
- `proxy_circuit_breaker_state{provider}`
- `proxy_start_time_seconds`

## 测试指南

### 功能测试

```bash
# 1. 基础代理测试
curl http://localhost:8080/coingecko/api/v3/ping

# 2. 限流测试 (快速发送请求)
for i in {1..20}; do curl -s http://localhost:8080/coingecko/api/v3/ping & done

# 3. 熔断器测试
# 触发熔断
curl -X POST http://localhost:8080/circuit-breaker/zerion/trip
# 检查状态
curl http://localhost:8080/circuit-breaker
# 重置
curl -X POST http://localhost:8080/circuit-breaker/zerion/reset

# 4. 降级测试
curl http://localhost:8080/test/fallback/502
curl http://localhost:8080/test/fallback/simulate?provider=coingecko&code=503

# 5. 监控测试
curl http://localhost:8080/metrics
curl http://localhost:8080/metrics/json
```

### 压力测试

```bash
# 使用 wrk 进行压力测试
wrk -t4 -c100 -d30s http://localhost:8080/coingecko/api/v3/ping

# 使用 ab 进行压力测试
ab -n 1000 -c 50 http://localhost:8080/coingecko/api/v3/ping
```

## Prometheus 集成

### prometheus.yml

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'openresty-proxy'
    static_configs:
      - targets: ['openresty:8080']
    metrics_path: '/metrics'
```

### 常用 PromQL 查询

```promql
# QPS
rate(proxy_requests_total[1m])

# 错误率
sum(rate(proxy_requests_errors_total[5m])) / sum(rate(proxy_requests_total[5m]))

# P95 延迟
histogram_quantile(0.95, sum(rate(proxy_request_duration_seconds_bucket[5m])) by (le))

# 熔断器状态
proxy_circuit_breaker_state
```

## 目录结构

```
openresty-api-proxy-v3/
├── conf/
│   └── nginx.conf              # Nginx 主配置
├── lua/
│   ├── config.lua              # 全局配置
│   └── core/
│       ├── access_control.lua  # 访问控制
│       ├── auth.lua            # 认证注入
│       ├── circuit_breaker.lua # 熔断器
│       ├── fallback.lua        # 服务降级
│       ├── health_check.lua    # 健康检查
│       ├── logger.lua          # 日志处理
│       ├── metrics.lua         # Prometheus 监控
│       ├── rate_limit.lua      # 限流
│       └── router.lua          # 路由
├── docs/
│   ├── CIRCUIT_BREAKER_TEST_REPORT.md
│   ├── FALLBACK_TEST_REPORT.md
│   ├── METRICS_TEST_REPORT.md
│   └── RATE_LIMIT_TEST_REPORT.md
├── logs/                       # 日志目录
├── docker-compose.yml
├── Dockerfile
└── README.md
```

## 文档索引

- [Lua 模块功能总结](docs/FEATURE_SUMMARY.md)
- [限流测试报告](docs/RATE_LIMIT_TEST_REPORT.md)
- [熔断器测试报告](docs/CIRCUIT_BREAKER_TEST_REPORT.md)
- [降级测试报告](docs/FALLBACK_TEST_REPORT.md)
- [监控指标测试报告](docs/METRICS_TEST_REPORT.md)
- [Header 过滤测试报告](docs/HEADER_FILTER_TEST_REPORT.md)

## 依赖

- **OpenResty**: 1.21.4+
- **lua-resty-prometheus**: nginx-lua-prometheus (via luarocks)
- **Docker**: 20.10+
- **Docker Compose**: 2.0+

## License

MIT License
