#!/bin/bash

# OpenResty API 代理服务 Docker 启动脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 创建必要的目录
mkdir -p logs

# 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
    echo "错误: 未找到 docker 命令"
    echo "请先安装 Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

# 检查 docker-compose 是否安装（可选）
USE_COMPOSE=false
if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
    USE_COMPOSE=true
fi

echo "使用 Docker 启动 OpenResty 服务..."

if [ "$USE_COMPOSE" = true ]; then
    echo "使用 docker-compose 启动..."
    
    # 加载环境变量（如果存在 .env 文件）
    if [ -f .env ]; then
        # 安全地加载环境变量，忽略空行和注释
        set -a
        source .env 2>/dev/null || true
        set +a
        echo "已加载 .env 文件中的环境变量"
    else
        echo "提示: .env 文件不存在，使用默认配置或环境变量"
    fi
    
    # 使用 docker-compose
    if docker compose version &> /dev/null; then
        docker compose up -d --build
    else
        docker-compose up -d --build
    fi
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "服务启动成功！"
        echo "访问地址: http://localhost:8080"
        echo "健康检查: http://localhost:8080/health"
        echo "Metrics: http://localhost:8080/metrics"
        echo ""
        echo "查看日志: docker compose logs -f"
        echo "停止服务: docker compose down"
    else
        echo "服务启动失败"
        exit 1
    fi
else
    echo "使用 docker build 和 run 启动..."
    
    # 构建镜像
    echo "构建 Docker 镜像..."
    docker build -t openresty-api-proxy:latest .
    
    if [ $? -ne 0 ]; then
        echo "镜像构建失败"
        exit 1
    fi
    
    # 停止并删除旧容器（如果存在）
    docker stop openresty-api-proxy 2>/dev/null
    docker rm openresty-api-proxy 2>/dev/null
    
    # 运行容器
    echo "启动容器..."
    docker run -d \
        --name openresty-api-proxy \
        -p 8080:8080 \
        -v "$SCRIPT_DIR/conf/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro" \
        -v "$SCRIPT_DIR/lua:/usr/local/openresty/nginx/lua:ro" \
        -v "$SCRIPT_DIR/logs:/usr/local/openresty/nginx/logs" \
        --restart unless-stopped \
        openresty-api-proxy:latest
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "服务启动成功！"
        echo "访问地址: http://localhost:8080"
        echo "健康检查: http://localhost:8080/health"
        echo "Metrics: http://localhost:8080/metrics"
        echo ""
        echo "查看日志: docker logs -f openresty-api-proxy"
        echo "停止服务: docker stop openresty-api-proxy"
    else
        echo "服务启动失败"
        exit 1
    fi
fi
