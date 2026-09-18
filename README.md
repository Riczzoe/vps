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
- Google/Youtube 送中检测
  ```bash
  # Google
  jar=$(mktemp)
  curl -4 --noproxy '*' -sS -L \
    -A "$UA" \
    -H 'Accept-Language: en-US,en;q=0.9' \
    -c "$jar" -b "$jar" \
    -o /dev/null \
    -w '最终 URL: %{url_effective}\n' \
    https://www.google.com/
  rm -f "$jar"

  # Youtube
  html=$(curl -4 -sSL --max-time 10 -H 'Accept-Language: en' -b 'YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai; _gcl_au=1.1.1809531354.1646633279' 'https://www.youtube.com/premium' 2>&1); if [[ "$html" == curl:* ]] || [[ -z "$html" ]]; then echo '连接失败'; elif grep -q 'www\.google\.cn' <<< "$html"; then echo '中国 [CN]'; elif grep -q 'Premium is not available in your country' <<< "$html"; then echo '禁会员'; elif grep -q 'ad-free' <<< "$html"; then region=$(grep -oE '"contentRegion":"[^"]+"' <<< "$html" | head -n1 | cut -d'"' -f4); echo "Premium 可用，地区：[${region:-未知}]"; else echo '无法识别'; fi
  ```
