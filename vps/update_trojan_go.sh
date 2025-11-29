#!/bin/bash

set -e

INSTALL_DIR="/root/trojan-go"
SERVICE_NAME="trojan-go.service"
REPO="Potterli20/trojan-go-fork"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
TMP_DIR="/tmp/trojan-go-update"
VERSION_FILE="$INSTALL_DIR/version.txt"

echo "=== Trojan-Go 自动更新脚本 ==="

# 检测架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) PLATFORM="linux-amd64-v2" ;;
  aarch64) PLATFORM="linux-arm64-v2" ;;
  armv7l) PLATFORM="linux-armv7-v2" ;;
  i386|i686) PLATFORM="linux-386-v2" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

echo "系统架构: $PLATFORM"

# 获取最新版本
LATEST_VERSION=$(curl -s $API_URL | grep '"tag_name":' | cut -d '"' -f 4)
if [ -z "$LATEST_VERSION" ]; then
    echo "获取 GitHub 最新版本失败"; exit 1
fi

echo "GitHub 最新版本: $LATEST_VERSION"

# 读取本地版本号
if [ -f "$VERSION_FILE" ]; then
    LOCAL_VERSION=$(cat "$VERSION_FILE")
else
    LOCAL_VERSION="none"
fi

echo "本地记录版本: $LOCAL_VERSION"

# 对比版本号
if [ "$LOCAL_VERSION" = "$LATEST_VERSION" ]; then
    echo "版本一致，无需更新。"
    exit 0
fi

echo "--- 发现新版本，准备更新 ---"

# 下载文件（注意：必须是正确文件名）
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_VERSION}/trojan-go-fork-${PLATFORM}.zip"

echo "下载地址: $DOWNLOAD_URL"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
mkdir -p "$INSTALL_DIR"

curl -L -o "$TMP_DIR/trojan.zip" "$DOWNLOAD_URL"

# 检查文件是否真的是 zip
if ! file "$TMP_DIR/trojan.zip" | grep -q "Zip archive"; then
    echo "下载的文件不是 ZIP，可能下载失败或 GitHub 限制，请检查网络或 URL"
    exit 1
fi

echo "解压文件..."
unzip -o "$TMP_DIR/trojan.zip" -d "$TMP_DIR"

# 如果安装目录存在 server.json，则备份
if [ -f "$INSTALL_DIR/server.json" ]; then
    echo "备份旧 server.json"
    cp "$INSTALL_DIR/server.json" "$TMP_DIR/server.json.keep"
fi

echo "停止服务: $SERVICE_NAME"
systemctl stop $SERVICE_NAME

echo "覆盖更新文件..."
cp -rf "$TMP_DIR/trojan-go-fork" "$INSTALL_DIR/trojan-go"
cp -rf "$TMP_DIR/geoip-only-cn-private.dat" "$INSTALL_DIR/"
cp -rf "$TMP_DIR/geoip.dat" "$INSTALL_DIR/"
cp -rf "$TMP_DIR/geosite.dat" "$INSTALL_DIR/"

# 恢复旧 server.json
if [ -f "$TMP_DIR/server.json.keep" ]; then
    echo "恢复原 server.json"
    mv -f "$TMP_DIR/server.json.keep" "$INSTALL_DIR/server.json"
fi

chmod +x "$INSTALL_DIR/trojan-go"

echo "启动服务: $SERVICE_NAME"
systemctl start $SERVICE_NAME

# 记录新版本号
echo "$LATEST_VERSION" > "$VERSION_FILE"

rm -rf "$TMP_DIR"