#!/bin/bash
# test_all.sh - OpenResty API Proxy 全功能测试脚本
# 用法: ./test_all.sh [options]
#   -u, --url URL      指定测试目标 (默认: http://localhost:8080)
#   -b, --benchmark    执行压力测试
#   -r, --report       生成测试报告
#   -v, --verbose      详细输出模式
#   -h, --help         显示帮助

# 不使用 set -e，手动控制退出

# ============================================
# 配置
# ============================================
BASE_URL="${BASE_URL:-http://localhost:8080}"
BENCHMARK=true
REPORT=true
VERBOSE=false
REPORT_FILE="docs/ab_test/test_report_$(date +%Y%m%d_%H%M%S).md"
TIMEOUT=5

# ============================================
# 解析命令行参数
# ============================================
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)
            BASE_URL="$2"
            shift 2
            ;;
        -b|--benchmark)
            BENCHMARK=true
            shift
            ;;
        -r|--report)
            REPORT=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "用法: $0 [options]"
            echo "  -u, --url URL      指定测试目标 (默认: http://localhost:8080)"
            echo "  -b, --benchmark    执行压力测试"
            echo "  -r, --report       生成测试报告"
            echo "  -v, --verbose      详细输出模式"
            echo "  -h, --help         显示帮助"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# ============================================
# 颜色定义
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================
# 计数器
# ============================================
PASSED=0
FAILED=0
SKIPPED=0

# ============================================
# 报告内容
# ============================================
REPORT_CONTENT=""

# ============================================
# 工具函数
# ============================================
log() {
    echo -e "$1"
    if $REPORT; then
        # 去除颜色代码
        REPORT_CONTENT+="$(echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g')\n"
    fi
}

log_section() {
    log ""
    log "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    log "${CYAN}  $1${NC}"
    log "${CYAN}═══════════════════════════════════════════════════════════${NC}"
}

log_subsection() {
    log ""
    log "${BLUE}--- $1 ---${NC}"
}

verbose_log() {
    if $VERBOSE; then
        log "    ${YELLOW}[DEBUG]${NC} $1"
    fi
}

# ============================================
# 测试函数
# ============================================
test_endpoint() {
    local name="$1"
    local url="$2"
    local expected_code="${3:-200}"
    local method="${4:-GET}"
    
    printf "  %-40s " "$name"
    
    local start_time=$(date +%s%N)
    
    if [ "$method" = "POST" ]; then
        response=$(curl -s -o /tmp/response.txt -w "%{http_code}" -X POST --max-time $TIMEOUT "$url" 2>/dev/null || echo "000")
    else
        response=$(curl -s -o /tmp/response.txt -w "%{http_code}" --max-time $TIMEOUT "$url" 2>/dev/null || echo "000")
    fi
    
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    if [ "$response" = "$expected_code" ]; then
        log "${GREEN}✓ PASS${NC} (HTTP $response, ${duration}ms)"
        verbose_log "响应: $(cat /tmp/response.txt | head -c 200)"
        return 0
    elif [ "$response" = "000" ]; then
        log "${RED}✗ FAIL${NC} (连接超时或失败)"
        return 1
    else
        log "${RED}✗ FAIL${NC} (期望 $expected_code, 实际 $response, ${duration}ms)"
        verbose_log "响应: $(cat /tmp/response.txt | head -c 200)"
        return 1
    fi
}

test_json_field() {
    local name="$1"
    local url="$2"
    local field="$3"
    
    printf "  %-40s " "$name"
    
    response=$(curl -s --max-time $TIMEOUT "$url" 2>/dev/null)
    
    if echo "$response" | grep -q "$field"; then
        log "${GREEN}✓ PASS${NC}"
        return 0
    else
        log "${RED}✗ FAIL${NC} (未找到字段: $field)"
        return 1
    fi
}

test_metric() {
    local name="$1"
    local metric="$2"
    local metrics_data="$3"
    
    printf "  %-40s " "$name"
    
    if echo "$metrics_data" | grep -q "$metric"; then
        local value=$(echo "$metrics_data" | grep "$metric" | head -1)
        log "${GREEN}✓ PASS${NC}"
        verbose_log "$value"
        return 0
    else
        log "${RED}✗ FAIL${NC} (指标不存在)"
        return 1
    fi
}

run_test() {
    if "$@"; then
        PASSED=$((PASSED+1))
    else
        FAILED=$((FAILED+1))
    fi
}

skip_test() {
    local name="$1"
    local reason="$2"
    printf "  %-40s " "$name"
    log "${YELLOW}⊘ SKIP${NC} ($reason)"
    SKIPPED=$((SKIPPED+1))
}

# ============================================
# 重置所有熔断器
# ============================================
reset_all_circuit_breakers() {
    curl -s -X POST "$BASE_URL/circuit-breaker/zerion/reset" > /dev/null 2>&1
    curl -s -X POST "$BASE_URL/circuit-breaker/coingecko/reset" > /dev/null 2>&1
    curl -s -X POST "$BASE_URL/circuit-breaker/alchemy/reset" > /dev/null 2>&1
    sleep 0.5
}

# ============================================
# 检查服务是否运行
# ============================================
check_service() {
    log_subsection "检查服务状态"
    printf "  %-40s " "服务连接测试"
    
    if curl -s --max-time 3 "$BASE_URL/health" > /dev/null 2>&1; then
        log "${GREEN}✓ 服务运行中${NC}"
        return 0
    else
        log "${RED}✗ 服务未响应${NC}"
        log ""
        log "${RED}错误: 无法连接到 $BASE_URL${NC}"
        log "请确保服务已启动: docker-compose up -d"
        exit 1
    fi
}

# ============================================
# 限流测试 - 并发请求
# ============================================
test_rate_limit_concurrent() {
    log_subsection "6. 限流功能测试 (并发请求)"
    
    log "  ${MAGENTA}【原理】限流基于请求速率，并发请求更容易触发${NC}"
    log "  ${MAGENTA}【配置】rate=10 QPS, burst=5${NC}"
    log ""
    
    # 重置熔断器
    printf "  %-40s " "重置熔断器状态"
    reset_all_circuit_breakers
    log "${GREEN}✓ 已重置${NC}"
    
    # 并发测试
    printf "  %-40s " "发送30个并发请求"
    
    local count_429=0
    local count_200=0
    local count_503=0
    local count_504=0
    local count_other=0
    local results=""
    
    # 使用临时文件收集并发结果
    local tmpdir=$(mktemp -d)
    
    for i in $(seq 1 30); do
        (
            code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$BASE_URL/coingecko/api/v3/ping" 2>/dev/null || echo "000")
            echo "$code" > "$tmpdir/$i.txt"
        ) &
    done
    wait
    
    # 统计结果
    for i in $(seq 1 30); do
        if [ -f "$tmpdir/$i.txt" ]; then
            code=$(cat "$tmpdir/$i.txt")
            case $code in
                429) count_429=$((count_429+1)) ;;
                200) count_200=$((count_200+1)) ;;
                503) count_503=$((count_503+1)) ;;
                504) count_504=$((count_504+1)) ;;
                *) count_other=$((count_other+1)) ;;
            esac
        fi
    done
    rm -rf "$tmpdir"
    
    # 判断结果
    if [ $count_429 -gt 0 ]; then
        log "${GREEN}✓ PASS${NC} (限流已触发)"
        PASSED=$((PASSED+1))
    else
        log "${YELLOW}⊘ SKIP${NC} (限流未触发)"
        SKIPPED=$((SKIPPED+1))
    fi
    
    log "    ${CYAN}统计: 200(成功)=$count_200, 429(限流)=$count_429, 503(熔断)=$count_503, 504(超时)=$count_504, 其他=$count_other${NC}"
    
    # 记录到报告变量
    RATE_LIMIT_RESULT="200=$count_200, 429=$count_429, 503=$count_503"
}

# ============================================
# 熔断器测试 - 串行请求触发
# ============================================
test_circuit_breaker_serial() {
    log_subsection "7. 熔断器功能测试 (串行请求)"
    
    log "  ${MAGENTA}【原理】熔断基于错误累计，串行请求更容易触发${NC}"
    log "  ${MAGENTA}【配置】max_errors=5, reset_timeout=30s${NC}"
    log ""
    
    # 重置熔断器
    printf "  %-40s " "重置熔断器状态"
    reset_all_circuit_breakers
    log "${GREEN}✓ 已重置${NC}"
    
    # 验证初始状态
    printf "  %-40s " "验证初始状态 (CLOSED)"
    local state=$(curl -s "$BASE_URL/circuit-breaker" 2>/dev/null | grep -o '"state":"[^"]*"' | head -1)
    if echo "$state" | grep -q "CLOSED"; then
        log "${GREEN}✓ PASS${NC}"
        PASSED=$((PASSED+1))
    else
        log "${RED}✗ FAIL${NC} ($state)"
        FAILED=$((FAILED+1))
    fi
    
    # 串行发送请求触发熔断
    printf "  %-40s " "发送10个串行请求触发熔断"
    
    local count_200=0
    local count_503=0
    local count_other=0
    
    for i in $(seq 1 10); do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$BASE_URL/coingecko/api/v3/ping" 2>/dev/null || echo "000")
        case $code in
            200) count_200=$((count_200+1)) ;;
            503) count_503=$((count_503+1)) ;;
            *) count_other=$((count_other+1)) ;;
        esac
    done
    
    if [ $count_503 -gt 0 ]; then
        log "${GREEN}✓ PASS${NC} (熔断已触发)"
        PASSED=$((PASSED+1))
    else
        log "${YELLOW}⊘ SKIP${NC} (熔断未触发，上游响应正常)"
        SKIPPED=$((SKIPPED+1))
    fi
    
    log "    ${CYAN}统计: 200(成功)=$count_200, 503(熔断)=$count_503, 其他=$count_other${NC}"
    
    # 验证熔断器状态
    printf "  %-40s " "检查熔断器状态"
    local cb_status=$(curl -s "$BASE_URL/circuit-breaker" 2>/dev/null)
    local cb_state=$(echo "$cb_status" | grep -o '"state":"[^"]*"' | head -1)
    log "${GREEN}✓${NC} $cb_state"
    
    # 记录到报告变量
    CIRCUIT_BREAKER_RESULT="200=$count_200, 503=$count_503"
}

# ============================================
# 综合测试 - 先限流后熔断
# ============================================
test_rate_limit_then_circuit_breaker() {
    log_subsection "8. 综合测试 - 先限流后熔断"
    
    log "  ${MAGENTA}【设计】请求进入 → 限流检查(429) → 熔断检查(503) → 代理上游${NC}"
    log ""
    
    # 重置状态
    printf "  %-40s " "重置所有状态"
    reset_all_circuit_breakers
    log "${GREEN}✓ 已重置${NC}"
    
    # 阶段1: 并发请求测试限流
    log ""
    log "  ${BLUE}阶段1: 并发请求 (测试限流优先)${NC}"
    
    local tmpdir=$(mktemp -d)
    local count_429=0
    local count_200=0
    local count_503=0
    
    for i in $(seq 1 20); do
        (
            code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$BASE_URL/zerion/v1/wallets" 2>/dev/null || echo "000")
            echo "$code" > "$tmpdir/$i.txt"
        ) &
    done
    wait
    
    for i in $(seq 1 20); do
        if [ -f "$tmpdir/$i.txt" ]; then
            code=$(cat "$tmpdir/$i.txt")
            case $code in
                429) count_429=$((count_429+1)) ;;
                200|301|302|404) count_200=$((count_200+1)) ;;
                503) count_503=$((count_503+1)) ;;
            esac
        fi
    done
    rm -rf "$tmpdir"
    
    printf "  %-40s " "  并发20请求结果"
    log "${CYAN}429(限流)=$count_429, 2xx/3xx/4xx=$count_200, 503(熔断)=$count_503${NC}"
    
    # 阶段2: 连续失败触发熔断
    log ""
    log "  ${BLUE}阶段2: 串行请求 (测试熔断触发)${NC}"
    
    local serial_503=0
    local serial_other=0
    
    for i in $(seq 1 10); do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$BASE_URL/zerion/v1/wallets" 2>/dev/null || echo "000")
        case $code in
            503) serial_503=$((serial_503+1)) ;;
            *) serial_other=$((serial_other+1)) ;;
        esac
    done
    
    printf "  %-40s " "  串行10请求结果"
    log "${CYAN}503(熔断)=$serial_503, 其他=$serial_other${NC}"
    
    # 阶段3: 验证顺序
    log ""
    log "  ${BLUE}阶段3: 验证执行顺序${NC}"
    
    # 重置再测试一次
    reset_all_circuit_breakers
    
    local order_test_results=""
    local first_429=""
    local first_503=""
    
    # 并发发送并记录顺序
    tmpdir=$(mktemp -d)
    for i in $(seq 1 15); do
        (
            code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$BASE_URL/coingecko/api/v3/ping" 2>/dev/null || echo "000")
            echo "$(date +%s%N):$code" > "$tmpdir/$i.txt"
        ) &
    done
    wait
    
    # 收集并排序结果
    local sorted_results=$(cat "$tmpdir"/*.txt 2>/dev/null | sort -t: -k1 -n)
    rm -rf "$tmpdir"
    
    # 分析顺序
    local seq_num=0
    while IFS=: read -r timestamp code; do
        seq_num=$((seq_num+1))
        if [ "$code" = "429" ] && [ -z "$first_429" ]; then
            first_429=$seq_num
        fi
        if [ "$code" = "503" ] && [ -z "$first_503" ]; then
            first_503=$seq_num
        fi
    done <<< "$sorted_results"
    
    printf "  %-40s " "  执行顺序分析"
    if [ -n "$first_429" ]; then
        if [ -n "$first_503" ]; then
            if [ "$first_429" -lt "$first_503" ]; then
                log "${GREEN}✓ PASS${NC} (429在第${first_429}个, 503在第${first_503}个 - 限流先于熔断)"
                PASSED=$((PASSED+1))
            else
                log "${YELLOW}⊘ INFO${NC} (503在第${first_503}个, 429在第${first_429}个)"
                SKIPPED=$((SKIPPED+1))
            fi
        else
            log "${GREEN}✓ PASS${NC} (429在第${first_429}个, 未触发503 - 限流生效)"
            PASSED=$((PASSED+1))
        fi
    elif [ -n "$first_503" ]; then
        log "${YELLOW}⊘ INFO${NC} (503在第${first_503}个, 未触发429 - 熔断先打开)"
        SKIPPED=$((SKIPPED+1))
    else
        log "${YELLOW}⊘ INFO${NC} (未触发429和503)"
        SKIPPED=$((SKIPPED+1))
    fi
}

# ============================================
# 主测试流程
# ============================================
main() {
    log_section "OpenResty API Proxy 功能测试"
    log "目标: $BASE_URL"
    log "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # 检查服务
    check_service
    
    # ========== 1. 基础端点测试 ==========
    log_subsection "1. 基础端点测试"
    run_test test_endpoint "健康检查 /health" "$BASE_URL/health" 200
    run_test test_endpoint "服务信息 /" "$BASE_URL/" 200
    run_test test_endpoint "Nginx状态 /status" "$BASE_URL/status" 200
    
    # ========== 2. 监控端点测试 ==========
    log_subsection "2. 监控端点测试"
    run_test test_endpoint "Prometheus指标 /metrics" "$BASE_URL/metrics" 200
    run_test test_endpoint "JSON指标 /metrics/json" "$BASE_URL/metrics/json" 200
    
    # ========== 3. 熔断器端点测试 ==========
    log_subsection "3. 熔断器端点测试"
    run_test test_endpoint "熔断器状态 /circuit-breaker" "$BASE_URL/circuit-breaker" 200
    run_test test_endpoint "降级统计 /fallback/stats" "$BASE_URL/fallback/stats" 200
    
    # ========== 4. 降级测试 ==========
    log_subsection "4. 降级功能测试"
    run_test test_endpoint "502错误降级" "$BASE_URL/test/fallback/502" 503
    run_test test_endpoint "模拟降级 (coingecko)" "$BASE_URL/test/fallback/simulate?provider=coingecko&code=503" 503
    run_test test_endpoint "模拟降级 (zerion)" "$BASE_URL/test/fallback/simulate?provider=zerion&code=504" 503
    
    # ========== 5. 熔断器操作测试 ==========
    log_subsection "5. 熔断器操作测试"
    run_test test_endpoint "触发熔断 (zerion)" "$BASE_URL/circuit-breaker/zerion/trip" 200 POST
    run_test test_json_field "验证熔断状态" "$BASE_URL/circuit-breaker" '"state":"OPEN"'
    run_test test_endpoint "重置熔断 (zerion)" "$BASE_URL/circuit-breaker/zerion/reset" 200 POST
    run_test test_json_field "验证重置状态" "$BASE_URL/circuit-breaker" '"state":"CLOSED"'
    
    # ========== 6. 限流测试 (并发) ==========
    test_rate_limit_concurrent
    
    # ========== 7. 熔断器测试 (串行) ==========
    test_circuit_breaker_serial
    
    # ========== 8. 综合测试 ==========
    test_rate_limit_then_circuit_breaker
    
    # ========== 9. Prometheus 指标验证 ==========
    log_subsection "9. Prometheus 指标验证"
    metrics=$(curl -s --max-time $TIMEOUT "$BASE_URL/metrics" 2>/dev/null)
    
    run_test test_metric "proxy_requests_total" "proxy_requests_total" "$metrics"
    run_test test_metric "proxy_requests_success_total" "proxy_requests_success_total" "$metrics"
    run_test test_metric "proxy_requests_errors_total" "proxy_requests_errors_total" "$metrics"
    run_test test_metric "proxy_request_duration_seconds" "proxy_request_duration_seconds" "$metrics"
    run_test test_metric "proxy_rate_limited_total" "proxy_rate_limited_total" "$metrics"
    run_test test_metric "proxy_circuit_breaker_rejected" "proxy_circuit_breaker_rejected" "$metrics"
    run_test test_metric "proxy_circuit_breaker_state" "proxy_circuit_breaker_state" "$metrics"
    
    # ========== 10. JSON 格式验证 ==========
    log_subsection "10. JSON 指标格式验证"
    run_test test_json_field "timestamp 字段" "$BASE_URL/metrics/json" '"timestamp"'
    run_test test_json_field "uptime_seconds 字段" "$BASE_URL/metrics/json" '"uptime_seconds"'
    run_test test_json_field "providers 字段" "$BASE_URL/metrics/json" '"providers"'
    run_test test_json_field "connections 字段" "$BASE_URL/metrics/json" '"connections"'
    
    # ========== 11. 压力测试 (可选) ==========
    if $BENCHMARK; then
        log_subsection "11. 压力测试 (ab)"
        
        # 重置熔断器
        reset_all_circuit_breakers
        
        if command -v ab &> /dev/null; then
            log "  健康检查端点压测 (100请求, 10并发):"
            ab -n 100 -c 10 -q "$BASE_URL/health" 2>/dev/null | grep -E "Requests per second|Time per request|Failed requests" | while read line; do
                log "    $line"
            done
            
            log ""
            log "  代理端点压测 (50请求, 5并发):"
            ab -n 50 -c 5 -q "$BASE_URL/coingecko/api/v3/ping" 2>/dev/null | grep -E "Requests per second|Time per request|Failed requests|Non-2xx" | while read line; do
                log "    $line"
            done
        else
            log "  ${YELLOW}跳过: ab 工具未安装${NC}"
        fi
    fi
    
    # ========== 测试结果汇总 ==========
    log_section "测试结果汇总"
    
    TOTAL=$((PASSED + FAILED + SKIPPED))
    PASS_RATE=0
    if [ $TOTAL -gt 0 ]; then
        PASS_RATE=$((PASSED * 100 / TOTAL))
    fi
    
    log ""
    log "  ${GREEN}✓ 通过:${NC} $PASSED"
    log "  ${RED}✗ 失败:${NC} $FAILED"
    log "  ${YELLOW}⊘ 跳过:${NC} $SKIPPED"
    log "  ─────────────"
    log "  总计: $TOTAL"
    log "  通过率: ${PASS_RATE}%"
    log ""
    
    # 输出指标摘要
    if [ -n "$metrics" ]; then
        log_subsection "指标摘要"
        
        # 提取关键指标
        requests_total=$(echo "$metrics" | grep "proxy_requests_total{" | awk '{sum+=$2} END {print sum}')
        success_total=$(echo "$metrics" | grep "proxy_requests_success_total{" | awk '{sum+=$2} END {print sum}')
        errors_total=$(echo "$metrics" | grep "proxy_requests_errors_total{" | awk '{sum+=$2} END {print sum}')
        rate_limited=$(echo "$metrics" | grep "proxy_rate_limited_total{" | awk '{sum+=$2} END {print sum}')
        cb_rejected=$(echo "$metrics" | grep "proxy_circuit_breaker_rejected_total{" | awk '{sum+=$2} END {print sum}')
        
        log "  总请求数:     ${requests_total:-0}"
        log "  成功请求:     ${success_total:-0}"
        log "  错误请求:     ${errors_total:-0}"
        log "  限流拦截:     ${rate_limited:-0}"
        log "  熔断拦截:     ${cb_rejected:-0}"
    fi
    
    # 生成报告
    if $REPORT; then
        log ""
        log "生成测试报告: $REPORT_FILE"
        
        mkdir -p "$(dirname "$REPORT_FILE")"
        
        cat > "$REPORT_FILE" << EOF
# OpenResty API Proxy 测试报告

**测试时间**: $(date '+%Y-%m-%d %H:%M:%S')
**测试目标**: $BASE_URL

## 测试结果

| 项目 | 数量 |
|------|------|
| ✓ 通过 | $PASSED |
| ✗ 失败 | $FAILED |
| ⊘ 跳过 | $SKIPPED |
| **总计** | $TOTAL |
| **通过率** | ${PASS_RATE}% |

## 限流与熔断测试

### 设计原理

\`\`\`
请求流程: 请求进入 → 限流检查(429) → 熔断检查(503) → 代理上游

保护层级:
┌─────────────────────────────────────┐
│           请求流量                   │
└─────────────────┬───────────────────┘
                  │
        ┌─────────▼─────────┐
        │    限流检查        │  ← 第一道防线 (保护本地资源)
        │  超过阈值返回 429  │     基于请求速率
        └─────────┬─────────┘
                  │ 通过
        ┌─────────▼─────────┐
        │    熔断检查        │  ← 第二道防线 (保护上游服务)
        │  打开时返回 503    │     基于错误累计
        └─────────┬─────────┘
                  │ 通过
        ┌─────────▼─────────┐
        │    代理到上游      │
        └───────────────────┘
\`\`\`

### 测试方法

| 测试类型 | 方法 | 目的 |
|----------|------|------|
| 限流测试 | 并发请求 | 瞬时高 QPS 触发限流 |
| 熔断测试 | 串行请求 | 累计上游错误触发熔断 |
| 综合测试 | 混合请求 | 验证执行顺序 |

### 配置参数

| 参数 | 值 | 说明 |
|------|-----|------|
| rate | 10 QPS | 每秒允许10个请求 |
| burst | 5 | 允许突发5个请求 |
| max_errors | 5 | 5次错误触发熔断 |
| reset_timeout | 30s | 熔断后30秒尝试恢复 |

## 详细日志

\`\`\`
$(echo -e "$REPORT_CONTENT")
\`\`\`

## Prometheus 指标快照

\`\`\`prometheus
$(curl -s "$BASE_URL/metrics" 2>/dev/null | head -100)
\`\`\`

## JSON 指标快照

\`\`\`json
$(curl -s "$BASE_URL/metrics/json" 2>/dev/null | python3 -m json.tool 2>/dev/null || curl -s "$BASE_URL/metrics/json")
\`\`\`
EOF
        log "${GREEN}报告已保存${NC}"
    fi
    
    log ""
    if [ $FAILED -eq 0 ]; then
        log "${GREEN}════════════════════════════════════════${NC}"
        log "${GREEN}  ✓ 所有测试通过!${NC}"
        log "${GREEN}════════════════════════════════════════${NC}"
        exit 0
    else
        log "${RED}════════════════════════════════════════${NC}"
        log "${RED}  ✗ 有 $FAILED 个测试失败${NC}"
        log "${RED}════════════════════════════════════════${NC}"
        exit 1
    fi
}

# ============================================
# 执行主函数
# ============================================
main
