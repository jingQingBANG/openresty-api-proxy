#!/bin/bash

# OpenResty API 代理服务 Docker 停止脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 检查是否使用 docker-compose
USE_COMPOSE=false
if [ -f docker-compose.yml ]; then
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        USE_COMPOSE=true
    fi
fi

if [ "$USE_COMPOSE" = true ]; then
    echo "使用 docker-compose 停止服务..."
    if docker compose version &> /dev/null; then
        docker compose down
    else
        docker-compose down
    fi
    echo "服务已停止"
else
    echo "停止 Docker 容器..."
    docker stop openresty-api-proxy 2>/dev/null
    docker rm openresty-api-proxy 2>/dev/null
    echo "服务已停止"
fi
