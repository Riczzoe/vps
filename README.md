## VPS 安全 (SSH) 脚本
只需要以 root 的身份执行 `security.sh` 脚本。

```bash
chmod +x ./security.sh
# 如果是 root 用户, 则执行
./security.sh
# 如果是非 root 用户, 则执行
sudo ./security.sh
```

## Vless + reality 脚本
打开`vless.sh`文件，将你vps的公网地址填入第23行就好，之后只需要以 root 的身份执行 `vless.sh` 脚本。

```bash
chmod +x ./vless.sh
# 如果是 root 用户, 则执行
./vless.sh
# 如果是非 root 用户, 则执行
sudo ./vless.sh
```
执行成功后，终端会打印 url 格式或者 mihomo 支持的格式的 vless 节点，按需复制导入对应的软件即可。
##  常用的检测脚本

- 最优sni域名
  ```bash
  bash -c "$(curl -sSL https://raw.githubusercontent.com/harenaNow/SNI-TLS-test/main/sni_tls_test.sh)"
  ```

- NodeQuality 测试脚本
  ```bash
  bash <(curl -sL https://run.NodeQuality.com)
  ```
  
- 网络质量体检脚本
  ```bash
  bash <(curl -sL Net.Check.Place)
  
  # 只检测 IPv4
  bash <(curl -Ls https://Net.Check.Place) -4
  ```
  
- IP质量体检脚本
  ```bash
  bash <(curl -Ls https://Check.Place) -I
  
  # 只检测 IPv4
  bash <(curl -Ls https://IP.Check.Place) -4
  ```

- TCPQuality 脚本
  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
  
  # 只检测 IPv4 
  bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -v4
  ```