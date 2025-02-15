# 7. 生成 Nginx 配置文件
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
    }
EOF

# 如果用户选择统一子域名推流请求，则添加通配符子域名匹配规则
if [[ "$UNIFY_SUBDOMAINS" == "y" || "$UNIFY_SUBDOMAINS" == "Y" ]]; then
  cat >> "$NGINX_CONF" <<EOF

server {
    listen 443 ssl http2;
    server_name ~^(.*)\.$DOMAIN$;

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
    }
}
EOF
else
  # 如果用户选择不统一子域名推流请求，则根据推流地址数量生成配置
  if [[ "$STREAM_COUNT" -gt 0 ]]; then
    cat >> "$NGINX_CONF" <<EOF

    # 推流地址配置
EOF
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
  fi
  # 主 server 块闭合
  cat >> "$NGINX_CONF" <<EOF
}
EOF
fi
