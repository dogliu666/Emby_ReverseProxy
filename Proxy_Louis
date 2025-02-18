#!/usr/bin/env bash
# --------------------------------
# Emby反向代理一键配置脚本
# 版本：2.0
# 新增功能：
# 1. 动态流路径代理配置
# 2. 增强SSL/TLS设置
# 3. 自动修正响应头
# --------------------------------

##################################
# 标准化颜色输出函数
##################################
RED='\033[31m'    GREEN='\033[32m'
YELLOW='\033[33m' BLUE='\033[34m'
RESET='\033[0m'
info() { echo -e "${BLUE}[信息] $*${RESET}"; }
success() { echo -e "${GREEN}[成功] $*${RESET}"; }
warning() { echo -e "${YELLOW}[警告] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; exit 1; }

##################################
# 系统初始化检查
##################################
init_check() {
  [[ $EUID -ne 0 ]] && error "必须使用 root 权限运行"
  info "执行系统环境检查..."
  command -v nginx >/dev/null || {
    warning "未检测到Nginx，将尝试自动安装"
    if command -v apt-get >/dev/null; then
      apt-get update && apt-get install -y nginx
    else
      yum install -y nginx
    fi
    systemctl enable nginx --now
  }
}

##################################
# 端口冲突处理
##################################
port_check() {
  local port=$1
  if ss -tuln | grep -q ":$port "; then
    read -rp "端口 $port 被占用，是否强制释放？[y/N]: " choice
    if [[ $choice =~ [yY] ]]; then
      local pid=$(ss -tulnp | awk -v p=":$port$" '$5 ~ p {split($7,a,/=/); print a[2]}' | head -1)
      [ -z "$pid" ] && error "获取进程失败"
      kill -9 "$pid" && success "已释放端口 $port"
    else
      error "操作已取消"
    fi
  fi
}

##################################
# 增强型输入验证
##################################
validate_input() {
  local prompt=$1 var_name=$2 regex=$3 default=$4 err_msg=$5
  while :; do
    read -rp "$prompt" input
    input=${input:-$default}
    if [[ $input =~ $regex ]]; then
      declare -g "$var_name"="$input"
      return 0
    else
      warning "${err_msg:-"输入格式错误，请重新输入"}"
    fi
  done
}

##################################
# 证书管理模块
##################################
cert_manager() {
  case "$SSL_MODE" in
    auto)
      if ! command -v certbot >/dev/null; then
        info "正在安装Certbot..."
        if command -v apt-get >/dev/null; then
          apt-get install -y certbot python3-certbot-nginx
        else
          yum install -y certbot
        fi
      fi
      systemctl stop nginx
      local domains="-d $DOMAIN"
      [ "$WILDCARD_CERT" = "y" ] && domains+=" -d *.$DOMAIN"
      certbot certonly --standalone --non-interactive --agree-tos \
        -m "$EMAIL" $domains || error "证书申请失败"
      SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
      SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
      ;;
    manual)
      [ -f "$SSL_CERT" ] || error "证书文件不存在: $SSL_CERT"
      [ -f "$SSL_KEY" ] || error "私钥文件不存在: $SSL_KEY"
      # 检查证书权限
      if [ "$(stat -c %U "$SSL_CERT")" != "root" ]; then
        chmod 600 "$SSL_CERT" "$SSL_KEY"
        chown root:root "$SSL_CERT" "$SSL_KEY"
      fi
      ;;
  esac
}

##################################
# 生成Nginx配置文件（关键模块）
##################################
generate_config() {
  local config_path="/etc/nginx/sites-available/$DOMAIN"
  info "生成Nginx配置文件: $config_path"

  # 构建基础配置
  cat > "$config_path" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    client_max_body_size 20M;
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    # 主代理配置
    location / {
        proxy_pass $EMBY_URL;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
EOF

  # 添加流路径重定向
  if [ "$STREAM_COUNT" -gt 0 ]; then
    cat >> "$config_path" <<EOF
        # 流路径重定向
        proxy_redirect default;
EOF
    for ((i=1; i<=STREAM_COUNT; i++)); do
      cat >> "$config_path" <<EOF
        proxy_redirect ${STREAMS[$i]} https://$DOMAIN/s${i}/;
EOF
    done
  fi

  # 添加路径代理规则
  for ((i=1; i<=STREAM_COUNT; i++)); do
    cat >> "$config_path" <<EOF
    location /s${i} {
        rewrite ^/s${i}(/.*)\$ \$1 break;
        proxy_pass ${STREAMS[$i]};
        proxy_http_version 1.1;
        proxy_set_header Host \$proxy_host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_ssl_server_name on;
        proxy_buffering off;
    }
EOF
  done

  cat >> "$config_path" <<EOF
    }
}
EOF

  # 启用配置
  ln -sf "$config_path" "/etc/nginx/sites-enabled/" || error "配置链接失败"
}

##################################
# 主流程控制
##################################
main() {
  init_check
  port_check 80
  port_check 443

  # 收集配置信息
  validate_input "请输入您的域名 (示例: emby.example.com): " \
    DOMAIN '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' "" "域名格式不正确"

  validate_input "输入Emby服务器地址 (示例: https://192.168.1.100:8096): " \
    EMBY_URL '^https?://[a-zA-Z0-9.-]+(:[0-9]+)?/?$' "" "请输入有效的URL"

  # 流代理配置
  declare -a STREAMS
  validate_input "需要配置几个流路径代理？[0-9]: " \
    STREAM_COUNT '^[0-9]+$' 0 "请输入数字"
  if [ "$STREAM_COUNT" -gt 0 ]; then
    for ((i=1; i<=STREAM_COUNT; i++)); do
      validate_input "输入流地址 $i (示例: https://stream$i.example.com): " \
        input '^https?://.+$' "" "必须以http/https开头"
      STREAMS[$i]=$input
    done
  fi

  # SSL配置选择
  PS3="请选择SSL证书模式: "
  select SSL_MODE in "自动申请" "手动配置"; do
    case $SSL_MODE in
      自动申请)
        SSL_MODE="auto"
        validate_input "输入证书通知邮箱: " \
          EMAIL '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' \
          "" "邮箱格式不正确"
        read -p "是否需要通配符证书？[y/N]: " WILDCARD_CERT
        ;;
      手动配置)
        SSL_MODE="manual"
        validate_input "输入SSL证书路径 (示例: /path/to/cert.pem): " \
          SSL_CERT '^/.*\.pem$' "" "必须是有效的PEM文件路径"
        validate_input "输入私钥路径 (示例: /path/to/key.pem): " \
          SSL_KEY '^/.*\.pem$' "" "必须是有效的私钥文件路径"
        ;;
      *) continue ;;
    esac
    break
  done

  # 证书处理
  cert_manager

  # 生成配置
  generate_config

  # 最终检查
  if nginx -t; then
    systemctl restart nginx
    success "部署完成！访问地址: https://$DOMAIN"
    [ "$STREAM_COUNT" -gt 0 ] && info "流路径代理: /s1 到 /s$STREAM_COUNT"
  else
    error "Nginx配置验证失败，请检查日志"
  fi
}

# 执行入口
main "$@"
