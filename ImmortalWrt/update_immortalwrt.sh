#!/bin/bash

#===============================
# ImmortalWrt 自动升级脚本
# 从 GitHub tag 获取版本号并与本地比对
#===============================

# 本地版本文件
VERSION_FILE="/etc/immortalwrt_version"

# 本地初始化版本（首次无文件时写入）
INIT_VERSION="x86-64--2025年12月01日12时28分"

# GitHub Releases API （你的仓库）
REPO_API="https://api.github.com/repos/ligusx-build/build-immortalwrt/releases/latest"

# 固件文件名（如 Release 中有变化，请告诉我）
FW_NAME="immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz"

# 固件下载到临时目录
FW_PATH="/tmp/${FW_NAME}"

#------------------------------
# 1. 初始化本地版本文件
#------------------------------
if [ ! -f "$VERSION_FILE" ]; then
    echo "$INIT_VERSION" > "$VERSION_FILE"
fi

LOCAL_VERSION=$(cat "$VERSION_FILE")
echo "本地版本号: $LOCAL_VERSION"

#------------------------------
# 2. 从 GitHub tag 获取最新版本号
#------------------------------
echo "正在获取 GitHub 最新 tag..."

LATEST_VERSION=$(curl -s "$REPO_API" | grep '"tag_name":' | cut -d '"' -f4)

if [ -z "$LATEST_VERSION" ]; then
    echo "❌ 无法获取 GitHub 最新版本号"
    exit 1
fi

echo "远端最新版本号(tag): $LATEST_VERSION"

#------------------------------
# 3. 比对版本号（下载前）
#------------------------------
if [ "$LOCAL_VERSION" = "$LATEST_VERSION" ]; then
    echo "版本一致，无需更新。"
    exit 0
fi

echo "发现新版本，准备下载固件..."

#------------------------------
# 4. 获取固件下载 URL
#------------------------------
DOWNLOAD_URL=$(curl -s "$REPO_API" \
    | grep "browser_download_url" \
    | grep "$FW_NAME" \
    | cut -d '"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ 未在 release 中找到固件文件：$FW_NAME"
    exit 1
fi

echo "固件下载链接: $DOWNLOAD_URL"

#------------------------------
# 5. 下载固件
#------------------------------
echo "正在下载固件..."
curl -L "$DOWNLOAD_URL" -o "$FW_PATH"

if [ $? -ne 0 ]; then
    echo "❌ 固件下载失败"
    exit 1
fi

echo "固件已下载: $FW_PATH"

#------------------------------
# 6. 下载成功 → 更新本地版本号
#------------------------------
echo "$LATEST_VERSION" > "$VERSION_FILE"
echo "版本号已更新到: $LATEST_VERSION"

#------------------------------
# 7. 执行升级（保留配置）
#------------------------------
echo "开始执行 ImmortalWrt 升级（sysupgrade -c）..."
sysupgrade -c "$FW_PATH"

# sysupgrade 执行后自动重启，不会继续往下执行
