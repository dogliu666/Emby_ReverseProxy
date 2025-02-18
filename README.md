一键emby反代

# 下载运行
1. 下载脚本
```bash
wget https://raw.githubusercontent.com/dogliu666/Emby_ReverseProxy/refs/heads/beta/Proxy_Louis.sh
```
> 注意：可能存在重复下载文件，需要手动删除文件

2. 运行脚本
```
bash Proxy_Louis.sh
```

# 若需要修改反代地址，参考以下步骤
```bash
nano /etc/nginx/proxy_louis.conf
```

此时修改内部的`EMBY_URL` `STREAM_COUNT`等配置即可
