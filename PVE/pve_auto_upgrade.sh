#!/bin/bash

# PVE 自动升级脚本（包含旧内核清理功能）
# 使用方法：chmod +x pve_auto_upgrade.sh && ./pve_auto_upgrade.sh

# 定义日志文件路径
LOG_DIR="/var/log/pve_auto_upgrade"
LOG_FILE="$LOG_DIR/pve_auto_upgrade.log"
MAX_LOG_DAYS=3
KERNEL_KEEP_COUNT=3  # 保留最近的内核数量

# 创建日志目录
mkdir -p "$LOG_DIR"

# 日志轮转函数
rotate_logs() {
    find "$LOG_DIR" -name "pve_auto_upgrade.*.log" -mtime +$MAX_LOG_DAYS -exec rm -f {} \;
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

# 获取当前运行的内核版本
CURRENT_KERNEL=$(uname -r)
echo "当前运行内核版本: $CURRENT_KERNEL" | tee -a "$LOG_FILE"

# 更新软件包列表
echo "正在更新软件包索引..." | tee -a "$LOG_FILE"
apt update >> "$LOG_FILE" 2>&1

# 检查是否有可用的升级
UPGRADE_LIST=$(apt list --upgradable 2>/dev/null)
echo -e "可用的升级:\n$UPGRADE_LIST" >> "$LOG_FILE"

# 统计可升级的包数量（不包括内核）
TOTAL_UPGRADES=$(echo "$UPGRADE_LIST" | grep -v "Listing..." | wc -l)
echo "总共有 $TOTAL_UPGRADES 个软件包可以升级" | tee -a "$LOG_FILE"

# 检查是否有内核相关更新
KERNEL_UPDATE=$(echo "$UPGRADE_LIST" | grep -E 'pve-kernel|proxmox-kernel|linux-image')

NEED_REBOOT=0
KERNEL_CHANGED=0
UPGRADE_EXECUTED=0

# ========== 执行系统升级 ==========
if [ -n "$KERNEL_UPDATE" ]; then
    echo "检测到内核更新可用:" | tee -a "$LOG_FILE"
    echo "$KERNEL_UPDATE" | tee -a "$LOG_FILE"
    KERNEL_CHANGED=1
    UPGRADE_EXECUTED=1
else
    if [ $TOTAL_UPGRADES -gt 0 ]; then
        echo "检测到 $TOTAL_UPGRADES 个软件包可以升级（无内核更新）" | tee -a "$LOG_FILE"
    else
        echo "没有检测到任何软件包更新" | tee -a "$LOG_FILE"
    fi
fi

# 执行系统升级（如果有任何包需要更新）
if [ $TOTAL_UPGRADES -gt 0 ]; then
    echo "正在执行系统升级..." | tee -a "$LOG_FILE"
    apt-get dist-upgrade -y >> "$LOG_FILE" 2>&1
    UPGRADE_EXECUTED=1
else
    echo "没有软件包需要升级，跳过" | tee -a "$LOG_FILE"
fi

# ========== 清理旧内核 ==========
echo "开始清理旧内核..." | tee -a "$LOG_FILE"

# 清理旧的元数据包
echo "清理旧的元数据包..." | tee -a "$LOG_FILE"
OLD_META_PACKAGES=$(dpkg -l | grep -E "pve-kernel-[0-9]+\.[0-9]+" | grep -v "pve-kernel-[0-9]\+\.[0-9]\+.[0-9]\+" | awk '{print $2}')
if [ -n "$OLD_META_PACKAGES" ]; then
    echo "发现旧的元数据包: $OLD_META_PACKAGES" | tee -a "$LOG_FILE"
    apt-get remove --purge -y $OLD_META_PACKAGES >> "$LOG_FILE" 2>&1
    KERNEL_CHANGED=1
else
    echo "没有发现旧的元数据包" | tee -a "$LOG_FILE"
fi

# 获取所有已安装的完整内核包
ALL_KERNELS=$(dpkg -l | grep "proxmox-kernel-[0-9]\+\.[0-9]\+.[0-9]\+-[0-9]\+-pve" | grep -v "signed" | grep -v "helper" | awk '{print $2}' | sed 's/proxmox-kernel-//' | sort -V)

# 获取当前运行的内核版本号
CURRENT_KERNEL_VERSION=$(echo "$CURRENT_KERNEL" | sed 's/-pve//')

# 获取所有内核版本列表（排除当前运行的内核）
KERNEL_VERSIONS=$(echo "$ALL_KERNELS" | grep -v "^$CURRENT_KERNEL_VERSION$" | sort -V)

# 清理旧内核
REMOVED_KERNELS=0
if [ -n "$KERNEL_VERSIONS" ]; then
    TOTAL_KERNELS=$(echo "$KERNEL_VERSIONS" | wc -l)
    echo "找到 $TOTAL_KERNELS 个旧内核版本" | tee -a "$LOG_FILE"
    
    if [ $TOTAL_KERNELS -gt $KERNEL_KEEP_COUNT ]; then
        KEEP_COUNT=$KERNEL_KEEP_COUNT
    else
        KEEP_COUNT=$TOTAL_KERNELS
    fi
    
    REMOVE_KERNELS=$(echo "$KERNEL_VERSIONS" | head -n -$KEEP_COUNT)
    
    if [ -n "$REMOVE_KERNELS" ]; then
        echo "清理旧内核（保留最近 $KEEP_COUNT 个版本）..." | tee -a "$LOG_FILE"
        echo "要删除的内核版本: $REMOVE_KERNELS" | tee -a "$LOG_FILE"
        
        for KERNEL_VERSION in $REMOVE_KERNELS; do
            echo "删除内核: proxmox-kernel-${KERNEL_VERSION}-pve" | tee -a "$LOG_FILE"
            apt-get remove --purge -y "proxmox-kernel-${KERNEL_VERSION}-pve" "proxmox-kernel-${KERNEL_VERSION}-pve-signed" >> "$LOG_FILE" 2>&1
            REMOVED_KERNELS=$((REMOVED_KERNELS + 1))
        done
        KERNEL_CHANGED=1
    else
        echo "没有需要清理的旧内核" | tee -a "$LOG_FILE"
    fi
else
    echo "没有找到其他内核版本" | tee -a "$LOG_FILE"
fi

# 清理孤儿包和依赖
echo "清理未使用的包..." | tee -a "$LOG_FILE"
apt-get autoremove --purge -y >> "$LOG_FILE" 2>&1

# 修复可能的依赖问题
echo "修复依赖关系..." | tee -a "$LOG_FILE"
apt-get install -f -y >> "$LOG_FILE" 2>&1

# 只有在内核发生变化时才更新GRUB
if [ $KERNEL_CHANGED -eq 1 ]; then
    echo "检测到内核变化，更新GRUB引导配置..." | tee -a "$LOG_FILE"
    update-grub >> "$LOG_FILE" 2>&1
else
    echo "未检测到内核变化，跳过GRUB更新" | tee -a "$LOG_FILE"
fi

# 检查是否需要重启
if [ $KERNEL_CHANGED -eq 1 ]; then
    # 获取最新安装的完整内核版本
    LATEST_INSTALLED_KERNEL=$(dpkg -l | grep "proxmox-kernel-[0-9]\+\.[0-9]\+.[0-9]\+-[0-9]\+-pve" | grep -v "signed" | grep -v "helper" | awk '{print $2}' | sed 's/proxmox-kernel-//' | sort -V | tail -n1)
    
    if [ -n "$LATEST_INSTALLED_KERNEL" ] && [ "$CURRENT_KERNEL" != "${LATEST_INSTALLED_KERNEL}-pve" ]; then
        echo "检测到已安装的内核比当前运行的内核更新" | tee -a "$LOG_FILE"
        echo "当前运行: $CURRENT_KERNEL" | tee -a "$LOG_FILE"
        echo "最新安装: ${LATEST_INSTALLED_KERNEL}-pve" | tee -a "$LOG_FILE"
        NEED_REBOOT=1
    else
        echo "当前运行的是最新安装的内核" | tee -a "$LOG_FILE"
    fi
fi

# 如果需要重启
if [ $NEED_REBOOT -eq 1 ]; then
    echo "系统将在30秒后重启..." | tee -a "$LOG_FILE"
    echo "=====================================" >> "$LOG_FILE"
    shutdown -r +1 "PVE内核已更新或清理，系统将自动重启"
else
    if [ $UPGRADE_EXECUTED -eq 1 ]; then
        echo "软件包已升级完成，无需重启" | tee -a "$LOG_FILE"
    else
        echo "没有软件包需要升级" | tee -a "$LOG_FILE"
    fi
fi

# 记录结束时间
echo "PVE 自动升级完成于: $(date)" | tee -a "$LOG_FILE"
echo "=====================================" >> "$LOG_FILE"

# ========== 去除未订阅弹窗 ==========
changed=0

if grep -q "data.status === 'Active'" /usr/share/pve-manager/js/pvemanagerlib.js 2>/dev/null; then
    sed -i_orig "s/data.status === 'Active'/true/g" /usr/share/pve-manager/js/pvemanagerlib.js
    changed=1
fi

if grep -q "if (res === null || res === undefined || !res || res" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js 2>/dev/null; then
    sed -i_orig "s/if (res === null || res === undefined || \!res || res/if(/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    changed=1
fi

if grep -q ".data.status.toLowerCase() !== 'active'" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js 2>/dev/null; then
    sed -i_orig "s/.data.status.toLowerCase() !== 'active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    changed=1
fi

if [ "$changed" -eq 1 ]; then
    systemctl restart pveproxy
fi

# 再次执行日志轮转
rotate_logs

echo "脚本执行完成，详细日志请查看: $LOG_FILE"
