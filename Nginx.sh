#!/usr/bin/env bash
# ---------------------------------
# Nginx 反向代理安装/配置脚本
# 支持自动申请 Let’s Encrypt 证书
# 包含主站点和多个推流地址代理
# 支持统一子域名推流请求
# 修复并优化版本
# ---------------------------------

##################################
# 函数: 检测并设置包管理器 & 安装 certbot
# 功能: 根据系统类型安装 certbot 和 python3-certbot-nginx
##################################
install_certbot() {
  if [[ -f /etc/debian_version ]]; then
    # Debian / Ubuntu 系统
    apt-get update
    apt-get install -y certbot python3-certbot-nginx
  elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
    # CentOS / RHEL 系统
    yum install -y epel-release
    yum install -y certbot python3-certbot-nginx
  else
    echo "错误：暂不支持此系统的自动安装 certbot，请手动安装后重试。"
    exit 1
  fi
}

##################################
# 函数: 检查端口是否空闲
# 参数: 端口号
# 返回值: 0 空闲，1 被占用
##################################
check_port() {
  local port=$1
  if ss -tuln | grep -qE ":$port\b"; then
    return 1  # 端口被占用
  else
    return 0  # 端口空闲
  fi
}

##################################
# 函数: 释放端口
# 参数: 端口号
# 功能: 终止占用指定端口的进程
##################################
release_port() {
  local port=$1
  echo "正在尝试释放端口 $port ..."
  if ss -tuln | grep -qE ":$port\b"; then
    # 获取占用端口的进程 PID
    local pid=$(ss -tulnp | grep -E ":$port\b" | awk '{print $6}' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1)
    if [[ -n $pid ]]; then
      echo "端口 $port 被进程 PID $pid 占用，正在终止该进程..."
      kill -9 "$pid"
      if [[ $? -eq 0 ]]; then
        echo "进程已终止，端口 $port 已释放。"
      else
        echo "无法终止进程，请手动检查。"
        exit 1
      fi
    else
      echo "错误：无法获取占用端口的进程信息，请手动检查。"
      exit 1
    fi
  else
    echo "端口 $port 已空闲。"
  fi
}

##################################
# 函数: 验证域名格式
# 参数: 域名
# 返回值: 0 有效，1 无效
##################################
validate_domain() {
  local domain_regex='^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
  [[ "$1" =~ $domain_regex ]] && return 0 || {
    echo "错误：域名格式无效 (示例: example.com)"
    return 1
  }
}

##################################
# 函数: 验证邮箱格式
# 参数: 邮箱
# 返回值: 0 有效，1 无效
##################################
validate_email() {
  local email_regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
  [[ "$1" =~ $email_regex ]] && return 0 || {
    echo "错误：邮箱格式无效 (示例: user@example.com)"
    return 1
  }
}

##################################
# 函数: 验证推流地址格式
# 参数: 推流地址
# 返回值: 0 有效，1 无效
##################################
validate_stream_url() {
  local url_regex='^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$'
  [[ "$1" =~ $url_regex ]] && return 0 || {
    echo "错误：推流地址格式无效 (必须以 http:// 或 https:// 开头)"
    return 1
  }
}

##################################
# 函数: 获取用户输入 (带验证和默认值)
# 参数: 提示信息, 变量名, 验证函数, 默认值
##################################
get_user_input() {
  local prompt=$1
  local var_name=$2
  local validate_func=$3
  local default_value=$4

  while true; do
    read -rp "$prompt" input
    input="${input:-$default_value}"
    if [[ -z "$validate_func" ]] || $validate_func "$input"; then
      declare -g "$var_name"="$input"
      break
    fi
  done
}

##################################
# 函数: 安装 Nginx 依赖项
##################################
install_nginx_dependencies() {
  echo "正在安装 Nginx 依赖项..."

  if [[ -f /etc/debian_version ]]; then
    apt-get update
    apt-get install -y openssl libpcre3 zlib1g libssl-dev
  elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
    yum install -y openssl pcre-devel zlib-devel
  else
    echo "错误：不支持的系统类型"
    exit 1
  fi
}

# -------------------------------
# 主程序开始
# -------------------------------

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "错误：本脚本需要 root 权限执行" >&2
   exit 1
fi

# 2. 检查端口占用
PORTS=(80 443)
for port in "${PORTS[@]}"; do
  check_port "$port" || {
    read -rp "端口 $port 被占用，是否强制释放？[y/N] " -n1 answer
    [[ "$answer" != "y" && "$answer" != "Y" ]] && exit 1
    release_port "$port"
  }
done

# 3. 收集配置信息
declare DOMAIN EMBY_URL EMAIL SSL_CERT SSL_KEY STREAM_COUNT UNIFY_SUBDOMAINS
get_user_input "请输入主域名 (示例: example.com): " DOMAIN validate_domain
get_user_input "请输入 Emby 主站地址 (示例: https://emby.example.com): " EMBY_URL validate_stream_url

read -rp "是否统一处理所有子域名请求？[y/N] " UNIFY_SUBDOMAINS
UNIFY_SUBDOMAINS=${UNIFY_SUBDOMAINS:-n}

if [[ "$UNIFY_SUBDOMAINS" =~ ^[nN] ]]; then
  read -rp "请输入推流地址数量 (0 表示不配置): " STREAM_COUNT
  STREAM_COUNT=${STREAM_COUNT:-0}

  declare -A STREAMS
  for ((i=1; i<=STREAM_COUNT; i++)); do
    get_user_input "推流地址 #$i (示例: https://stream$i.example.com): " "STREAMS[$i]" validate_stream_url
  done
fi

# 4. SSL 证书配置
read -rp "是否自动申请 Let's Encrypt 证书？[Y/n] " AUTO_SSL
AUTO_SSL=${AUTO_SSL:-y}

if [[ "$AUTO_SSL" =~ ^[yY] ]]; then
  get_user_input "请输入管理员邮箱: " EMAIL validate_email
else
  while true; do
    get_user_input "SSL 证书路径: " SSL_CERT ""
    get_user_input "SSL 私钥路径: " SSL_KEY ""
    [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]] && break
    echo "错误：证书文件不存在，请重新输入"
  done
fi

# 5. 安装依赖
install_nginx_dependencies

# 6. 安装 Nginx
if ! command -v nginx &>/dev/null; then
  echo "正在安装 Nginx..."
  if [[ -f /etc/debian_version ]]; then
    apt-get install -y nginx
  else
    yum install -y nginx
  fi
  systemctl enable nginx
fi

# 7. 证书申请
if [[ "$AUTO_SSL" =~ ^[yY] ]]; then
  install_certbot
  systemctl stop nginx
  certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN"
  SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi

# 8. 生成 Nginx 配置
CONF_DIR="/etc/nginx/conf.d"
mkdir -p "$CONF_DIR"
CONF_FILE="$CONF_DIR/${DOMAIN}.conf"

cat > "$CONF_FILE" <<EOF
# 主服务器配置
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate "$SSL_CERT";
    ssl_certificate_key "$SSL_KEY";
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 20M;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass $EMBY_URL;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
EOF

# 推流地址配置
if [[ "$UNIFY_SUBDOMAINS" =~ ^[nN] && $STREAM_COUNT -gt 0 ]]; then
  for ((i=1; i<=STREAM_COUNT; i++)); do
    cat >> "$CONF_FILE" <<EOF

    # 推流地址 $i
    location /s$i {
        rewrite ^/s$i(/.*)\$ \$1 break;
        proxy_pass ${STREAMS[$i]};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
EOF
  done
fi

# 子域名通配配置
if [[ "$UNIFY_SUBDOMAINS" =~ ^[yY] ]]; then
  cat >> "$CONF_FILE" <<EOF

# 子域名通配配置
server {
    listen 443 ssl http2;
    server_name ~^(?<subdomain>.+)\.$DOMAIN\$;

    ssl_certificate "$SSL_CERT";
    ssl_certificate_key "$SSL_KEY";
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass $EMBY_URL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
fi

echo "}" >> "$CONF_FILE"  # 闭合主 server 块

# 9. 配置验证
nginx -t || {
  echo "错误：Nginx 配置验证失败"
  exit 1
}

systemctl restart nginx
echo "Nginx 服务已重启"

# 10. 配置证书续订
if [[ "$AUTO_SSL" =~ ^[yY] ]]; then
  (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
  echo "证书自动续订任务已配置"
fi

echo "安装完成！访问地址：https://$DOMAIN"
