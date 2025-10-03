#!/bin/bash

# PVE 自动升级脚本（检测到内核更新时自动重启）
# 使用方法：chmod +x pve_auto_upgrade.sh && ./pve_auto_upgrade.sh

# 定义日志文件路径
LOG_DIR="/var/log/pve_auto_upgrade"
LOG_FILE="$LOG_DIR/pve_auto_upgrade.log"
MAX_LOG_DAYS=3

# 创建日志目录
mkdir -p "$LOG_DIR"

# 日志轮转函数
rotate_logs() {
    # 删除超过3天的日志
    find "$LOG_DIR" -name "pve_auto_upgrade.*.log" -mtime +$MAX_LOG_DAYS -exec rm -f {} \;
    
    # 如果当前日志超过1MB则轮转
    if [ -f "$LOG_FILE" ] && [ $(stat -c %s "$LOG_FILE") -gt 1048576 ]; then
        local TIMESTAMP=$(date +%Y%m%d%H%M%S)
        mv "$LOG_FILE" "$LOG_DIR/pve_auto_upgrade.$TIMESTAMP.log"
    fi
}

# 检查是否是root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：此脚本必须以root身份运行" | tee -a "$LOG_FILE"
    exit 1
fi

# 执行日志轮转
rotate_logs

# 记录开始时间
echo "=====================================" >> "$LOG_FILE"
echo "PVE 自动升级开始于: $(date)" | tee -a "$LOG_FILE"

# 获取当前内核版本（正在运行的内核）
CURRENT_KERNEL=$(uname -r)
echo "当前运行内核版本: $CURRENT_KERNEL" | tee -a "$LOG_FILE"

# 获取已安装的 PVE 内核包版本
CURRENT_PVE_KERNEL=$(dpkg-query -W -f='${Package} ${Version}\n' 'pve-kernel-*' | sort -u)
echo "当前已安装的PVE内核版本: $CURRENT_PVE_KERNEL" | tee -a "$LOG_FILE"

#检查软件是否更新
echo "正在读取本地软件包索引" | tee -a "$LOG_FILE"

# 检查是否有可用的升级（特别是内核相关）
UPGRADE_LIST=$(apt list --upgradable 2>/dev/null)
echo -e "可用的升级:\n$UPGRADE_LIST" >> "$LOG_FILE"

# 检查是否有pve内核或相关包需要更新
KERNEL_UPDATE=$(echo "$UPGRADE_LIST" | grep -E 'pve-kernel|linux-image')

if [ -n "$KERNEL_UPDATE" ]; then
    echo "检测到内核更新可用:" | tee -a "$LOG_FILE"
    echo "$KERNEL_UPDATE" | tee -a "$LOG_FILE"
    
    # 执行升级
    echo "正在执行系统升级..." | tee -a "$LOG_FILE"
    apt-get dist-upgrade -y >> "$LOG_FILE" 2>&1
    
# 检查新内核是否已安装
NEW_PVE_KERNEL=$(dpkg-query -W -f='${Package} ${Version}\n' 'pve-kernel-*' | sort -u)
echo "升级后的PVE内核版本: $NEW_PVE_KERNEL" | tee -a "$LOG_FILE"

if [ "$CURRENT_PVE_KERNEL" != "$NEW_PVE_KERNEL" ]; then
    echo "检测到内核已更新，准备重启系统..." | tee -a "$LOG_FILE"
    echo "系统将在30秒后重启..." | tee -a "$LOG_FILE"
    echo "=====================================" >> "$LOG_FILE"
    shutdown -r +0.5 "PVE内核已更新，系统将自动重启"
else
    echo "未检测到实际的内核版本变化，无需重启" | tee -a "$LOG_FILE"
fi

else
    echo "没有检测到内核更新，执行常规升级..." | tee -a "$LOG_FILE"
    apt-get dist-upgrade -y >> "$LOG_FILE" 2>&1
fi

# 清理不需要的包
echo "正在清理..." | tee -a "$LOG_FILE"
apt-get autoremove --purge -y >> "$LOG_FILE" 2>&1

# 记录结束时间
echo "PVE 自动升级完成于: $(date)" | tee -a "$LOG_FILE"
echo "=====================================" >> "$LOG_FILE"

# 去除未订阅弹窗（仅当文件中存在原始内容时才执行替换）
changed=0

if grep -q "data.status === 'Active'" /usr/share/pve-manager/js/pvemanagerlib.js; then
    sed -i_orig "s/data.status === 'Active'/true/g" /usr/share/pve-manager/js/pvemanagerlib.js
    changed=1
fi

if grep -q "if (res === null || res === undefined || !res || res" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; then
    sed -i_orig "s/if (res === null || res === undefined || \!res || res/if(/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    changed=1
fi

if grep -q ".data.status.toLowerCase() !== 'active'" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; then
    sed -i_orig "s/.data.status.toLowerCase() !== 'active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    changed=1
fi

# 仅当有文件被修改时才重启 pveproxy
if [ "$changed" -eq 1 ]; then
    systemctl restart pveproxy
fi

# 再次执行日志轮转确保新日志被正确管理
rotate_logs
