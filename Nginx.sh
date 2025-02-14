#!/usr/bin/env bash
# ---------------------------------
# Nginx 反向代理安装/配置脚本示例
# 支持自动申请 Let’s Encrypt 证书
# 包含主站点和多个推流地址代理
# ---------------------------------

##################################
# 函数: 检测并设置包管理器 & 安装 certbot
##################################
install_certbot() {
  if [[ -f /etc/debian_version ]]; then
    # Debian / Ubuntu
    apt-get update
    apt-get install -y certbot python3-certbot-nginx
  elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
    # CentOS / RHEL / Rocky / Alma 等
    yum install -y epel-release
    yum install -y certbot python3-certbot-nginx
  else
    echo "暂不支持此系统的自动安装 certbot，请手动安装后重试。"
    exit 1
  fi
}

# 1. 检查是否为 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "本脚本需要 root 权限，请使用 sudo 或切换为 root 后再执行。"
   exit 1
fi

# 2. 交互式获取必要参数
read -rp "请输入您的域名 (例如: p.example.com): " DOMAIN
read -rp "请输入Emby主站地址 (例如: https://emby.example.com): " EMBY_URL
read -rp "请输入推流地址数量 (例如: 4): " STREAM_COUNT
declare -A STREAMS
for ((i=1; i<=STREAM_COUNT; i++)); do
  read -rp "请输入第 $i 个推流地址 (例如: https://stream$i.example.com): " STREAMS[$i]
done

# 2.1 是否自动申请 Let’s Encrypt 证书
read -rp "是否自动申请/更新 Let’s Encrypt 证书？[y/n] (默认 n): " AUTO_SSL
AUTO_SSL="${AUTO_SSL:-n}"

SSL_CERT=""
SSL_KEY=""

if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  # 2.2 若自动申请，则获取 Email
  read -rp "请输入您的邮箱 (用于 Let’s Encrypt 注册): " EMAIL
  echo "请确保本机 80 端口空闲，并且域名 $DOMAIN 已解析到本机公网 IP。"
else
  # 2.3 若不自动申请，则让用户手动填写证书路径
  read -rp "请输入 SSL 证书文件绝对路径 (例如: /root/cert/example.com.cer): " SSL_CERT
  read -rp "请输入 SSL 私钥文件绝对路径 (例如: /root/cert/example.com.key): " SSL_KEY
fi

# 显示配置信息，供用户确认
echo "===================== 配置确认 ====================="
echo "代理域名 (Domain)          : $DOMAIN"
echo "Emby主站地址 (Emby URL)    : $EMBY_URL"
echo "推流地址数量               : $STREAM_COUNT"
for ((i=1; i<=STREAM_COUNT; i++)); do
  echo "推流地址 $i                : ${STREAMS[$i]}"
done
echo "自动申请证书 (AUTO_SSL)    : $AUTO_SSL"
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo "邮箱 (Email)               : $EMAIL"
  echo "证书路径将保存在 Let’s Encrypt 默认目录: /etc/letsencrypt/live/$DOMAIN"
else
  echo "SSL 证书 (SSL_CERT)        : $SSL_CERT"
  echo "SSL 私钥 (SSL_KEY)         : $SSL_KEY"
fi
echo "===================================================="

# 是否确认
read -rp "以上信息是否正确？(y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "用户取消操作，脚本退出。"
  exit 1
fi

# 3. 安装 Nginx
echo "正在安装 Nginx..."
if [[ -f /etc/debian_version ]]; then
  apt-get update
  apt-get install -y nginx
elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
  yum install -y nginx
else
  echo "暂不支持此系统的自动安装 Nginx，请手动安装后重试。"
  exit 1
fi

# 4. 如果选择自动申请证书，尝试安装并使用 certbot
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  install_certbot

  echo "使用 certbot 为 $DOMAIN 申请/更新证书..."
  systemctl stop nginx 2>/dev/null || true

  certbot certonly --nginx \
    --agree-tos --no-eff-email \
    -m "$EMAIL" \
    -d "$DOMAIN"

  if [[ $? -ne 0 ]]; then
    echo "Let’s Encrypt 证书申请失败，请检查错误信息。脚本退出。"
    exit 1
  fi

  SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi

# 5. 生成 Nginx 配置文件
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/$DOMAIN"

echo "正在生成 Nginx 配置文件..."
cat > "$NGINX_CONF" <<EOF
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

    client_max_body_size 20M;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    location / {
        proxy_pass $EMBY_URL;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$proxy_host;
        proxy_set_header Referer "$EMBY_URL/web/index.html";
        proxy_ssl_server_name on;
EOF

# 添加推流地址重定向规则
for ((i=1; i<=STREAM_COUNT; i++)); do
  cat >> "$NGINX_CONF" <<EOF
        proxy_redirect ${STREAMS[$i]} https://$DOMAIN/s$i/;
EOF
done

cat >> "$NGINX_CONF" <<EOF
    }
EOF

# 添加推流地址 location 配置
for ((i=1; i<=STREAM_COUNT; i++)); do
  cat >> "$NGINX_CONF" <<EOF
    location /s$i {
        rewrite ^/s$i(/.*)\$ \$1 break;
        proxy_pass ${STREAMS[$i]};
        proxy_set_header Referer "$EMBY_URL/web/index.html";
        proxy_set_header Host \$proxy_host;
        proxy_ssl_server_name on;
        proxy_buffering off;
    }
EOF
done

cat >> "$NGINX_CONF" <<EOF
}
EOF

# 创建符号链接到 sites-enabled
ln -sf "$NGINX_CONF" "$NGINX_CONF_ENABLED"

# 测试 Nginx 配置
echo "正在测试 Nginx 配置..."
nginx -t

if [[ $? -ne 0 ]]; then
  echo "Nginx 配置测试失败，请检查配置文件。"
  exit 1
fi

# 6. 重启 Nginx
echo "正在重启 Nginx..."
systemctl restart nginx

# 7. 检查 Certbot 续签任务是否已配置
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo "正在检查 Certbot 续签任务..."
  CRON_JOB=$(crontab -l 2>/dev/null | grep "certbot renew")
  if [ -z "$CRON_JOB" ]; then
    echo "未找到 Certbot 续签任务，正在配置..."
    (crontab -l 2>/dev/null; echo "0 0 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    echo "Certbot 续签任务已配置。"
  else
    echo "Certbot 续签任务已存在，无需配置。"
  fi
fi

# 最终提示
echo "===================================================="
echo "Nginx 反向代理配置完成！"
echo
echo "代理域名:      $DOMAIN"
echo "Emby主站地址:  $EMBY_URL"
echo "推流地址配置:"
for ((i=1; i<=STREAM_COUNT; i++)); do
  echo "  /s$i -> ${STREAMS[$i]}"
done
echo "Nginx 配置文件: $NGINX_CONF"
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo
  echo "SSL 证书位于:  /etc/letsencrypt/live/$DOMAIN/"
  echo "Let’s Encrypt 证书有效期为 90 天，Certbot 会定期自动续期。"
fi
echo
echo "查看 Nginx 日志请使用：journalctl -u nginx -f"
echo "===================================================="
