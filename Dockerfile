FROM openresty/openresty:alpine-fat

# 设置工作目录
WORKDIR /usr/local/openresty

# 创建必要的目录
RUN mkdir -p /usr/local/openresty/nginx/logs

# 安装 lua-resty-prometheus 库
# 方式1: 使用 luarocks 安装 (推荐)
RUN luarocks install nginx-lua-prometheus

# 复制配置文件
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# 复制 Lua 脚本
COPY lua/ /usr/local/openresty/nginx/lua/

# 暴露端口
EXPOSE 8080

# 启动 OpenResty（前台运行，使用 -p 指定前缀路径）
CMD ["/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx", "-c", "conf/nginx.conf", "-g", "daemon off;"]
