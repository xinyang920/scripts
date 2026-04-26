#!/bin/bash
# nbw-xray-reality-install.sh
# 一键部署 Xray Reality 节点，仅生成本地离线导入信息
# 系统要求：Linux 发行版
# Ubuntu: 20.04, 22.04, 24.04 及更高版本（推荐）
# Debian: 12 及更高版本
# by 南波丸 @nbw_one (modified)

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 权限运行此脚本${NC}"
    exit 1
fi

# 生成随机端口
PORT=$(shuf -i 10000-65000 -n 1)
# 生成UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   南波丸 Xray Reality 一键安装脚本${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${GREEN}[1/5] 安装依赖...${NC}"
apt update -y
apt install -y curl openssl bc qrencode

echo -e "${GREEN}[2/5] 安装 Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo -e "${GREEN}[3/5] 生成 Reality 密钥对 & 选择最佳 SNI...${NC}"

# 选择最佳 SNI
SNI_LIST=("www.microsoft.com" "www.apple.com" "www.yahoo.com" "www.samsung.com" "www.amazon.com" "www.amd.com" "www.nvidia.com" "www.intel.com" "www.python.org")
BEST_SNI="www.microsoft.com"
MIN_LATENCY=9999

echo "正在从以下域名中选择最佳 SNI..."
for sni in "${SNI_LIST[@]}"; do
    LATENCY=$(curl -o /dev/null -s -w "%{time_connect}\n" "https://$sni" || echo 999)
    echo "  - $sni: ${LATENCY}s"
    if (( $(echo "$LATENCY < $MIN_LATENCY" | bc -l) )); then
        MIN_LATENCY=$LATENCY
        BEST_SNI=$sni
    fi
done
echo -e "${YELLOW}已选择最佳 SNI: ${BEST_SNI} (延迟: ${MIN_LATENCY}s)${NC}"

# 生成密钥
KEYS=$(/usr/local/bin/xray x25519)
echo "x25519 原始输出:"
echo "$KEYS"
echo "---"

# 提取密钥
PRIVATE_KEY=$(printf '%s\n' "$KEYS" | awk -F': ' '/^PrivateKey:|^Private key:/ {print $2; exit}')
PUBLIC_KEY=$(printf '%s\n' "$KEYS" | awk -F': ' '/^Password \(PublicKey\):|^PublicKey:|^Public key:/ {print $2; exit}')

# 兼容旧格式
if [[ -z "$PRIVATE_KEY" ]]; then
    PRIVATE_KEY=$(echo "$KEYS" | sed -n 's/.*Private key: *\([^ ]*\).*/\1/p' | head -1)
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(echo "$KEYS" | sed -n 's/.*Public key: *\([^ ]*\).*/\1/p' | head -1)
fi

SHORT_ID=$(openssl rand -hex 8)

# 验证密钥
if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}错误: 密钥提取失败。原始输出如下:${NC}"
    echo "$KEYS"
    exit 1
fi

echo -e "${GREEN}[4/5] 写入 Xray 配置...${NC}"
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${BEST_SNI}:443",
          "serverNames": ["${BEST_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

echo -e "${GREEN}[5/5] 启动 Xray 服务...${NC}"
systemctl restart xray
systemctl enable xray

# 获取服务器IP
SERVER_IP=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || curl -s ifconfig.me)

# 生成 VLESS 链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${BEST_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${SERVER_IP}"

# 生成本地 Clash Meta 配置文件（离线手动导入）
cat > /root/clash-meta-reality.yaml << EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - 8.8.8.8
    - 1.1.1.1

proxies:
  - name: Reality-${SERVER_IP}
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${BEST_SNI}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome

proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies:
      - Reality-${SERVER_IP}
      - DIRECT

  - name: 🎯 全球直连
    type: select
    proxies:
      - DIRECT
      - 🚀 节点选择

rules:
  - DOMAIN-SUFFIX,cn,🎯 全球直连
  - DOMAIN-KEYWORD,baidu,🎯 全球直连
  - DOMAIN-KEYWORD,taobao,🎯 全球直连
  - DOMAIN-KEYWORD,aliyun,🎯 全球直连
  - GEOIP,CN,🎯 全球直连
  - MATCH,🚀 节点选择
EOF

# 生成本地二维码图片（仅本机保存，不对外提供）
qrencode -o /root/vless-reality.png "${VLESS_LINK}"

# 开放防火墙端口
if command -v ufw &> /dev/null; then
    ufw allow ${PORT}/tcp
fi

# 输出信息
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}           部署完成！${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${YELLOW}【节点信息】${NC}"
echo "服务器IP:    ${SERVER_IP}"
echo "端口:        ${PORT}"
echo "UUID:        ${UUID}"
echo "Public Key:  ${PUBLIC_KEY}"
echo "Short ID:    ${SHORT_ID}"
echo "SNI:         ${BEST_SNI}"
echo "Fingerprint: chrome"
echo "Flow:        xtls-rprx-vision"
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${YELLOW}【VLESS 链接】${NC} (复制到 v2rayN / v2rayNG / Shadowrocket)"
echo -e "${GREEN}============================================${NC}"
echo "${VLESS_LINK}"
echo ""
echo -e "${YELLOW}扫描下方二维码直接导入 VLESS (仅本地离线使用):${NC}"
qrencode -t ansiutf8 "${VLESS_LINK}"
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${YELLOW}【本地离线文件】${NC}"
echo -e "${GREEN}============================================${NC}"
echo "节点信息文件: /root/xray-info.txt"
echo "Clash Meta 配置: /root/clash-meta-reality.yaml"
echo "VLESS 二维码图片: /root/vless-reality.png"
echo ""
echo -e "${YELLOW}电报 Telegram 交流群:${NC}"
echo "TG: @nbw_club"
echo ""
echo -e "${GREEN}============================================${NC}"

# 保存信息到文件
cat > /root/xray-info.txt << EOF
============================================
Xray Reality 节点信息
============================================

【节点信息】
服务器IP:    ${SERVER_IP}
端口:        ${PORT}
UUID:        ${UUID}
Public Key:  ${PUBLIC_KEY}
Short ID:    ${SHORT_ID}
SNI:         ${BEST_SNI}
Fingerprint: chrome
Flow:        xtls-rprx-vision

【VLESS 链接】
${VLESS_LINK}

【本地离线文件】
Clash Meta 配置: /root/clash-meta-reality.yaml
VLESS 二维码图片: /root/vless-reality.png

【作者联系方式】
TG: @nbw_club

============================================
EOF

echo -e "${GREEN}所有信息已保存到 /root/xray-info.txt${NC}"
echo ""
