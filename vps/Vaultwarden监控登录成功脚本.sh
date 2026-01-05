#!/bin/bash

# Vaultwarden日志监控脚本
# 监控登录日志，发现非授权IP登录成功时发送邮件告警

# ========== 配置区域 ==========
# 日志文件配置
LOG_FILE="/www/wwwlogs/vaultwarden.log"  # 请修改为实际的日志文件路径

# 授权IP列表（支持多个IP，用空格分隔）
AUTHORIZED_IPS=("127.0.0.1" "112.37.125.80" "74.48.136.189")

# 邮件告警配置
MAIL_TO="986989222@qq.com"                    # 接收告警的邮箱
MAIL_FROM="ligus520@126.com"                  # 发件人邮箱
MAIL_SUBJECT="[Vaultwarden告警] 检测到非授权IP登录"

# SMTP服务器配置（使用126邮箱）
SMTP_SERVER="smtp.126.com"     # SMTP服务器地址
SMTP_PORT="465"                # SMTP端口：465(SSL)
SMTP_USER="ligus520@126.com"   # SMTP用户名（完整邮箱地址）
SMTP_PASSWORD="XRddD645ArdrzqDL" # SMTP密码

# 脚本运行配置
LOCK_FILE="/tmp/vaultwarden_monitor.lock"   # 锁文件，防止重复运行
ALERT_HISTORY_FILE="/tmp/vaultwarden_alert_history.log"  # 告警历史记录文件
ALERT_COOLDOWN_SECONDS=3600                  # 冷却时间（秒）：1小时内相同用户和IP不重复告警
DEBUG_MODE="no"                           # 调试模式：yes/no（显示详细过程）
CHECK_LINES=100                             # 每次检查的日志行数

# ========== 函数定义 ==========

# 调试输出函数
debug_echo() {
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo "[DEBUG][$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

# 检查是否需要发送告警（基于时间戳和冷却时间）
should_send_alert() {
    local username="$1"
    local ip="$2"
    local current_timestamp="$3"
    
    # 如果历史文件不存在，直接返回可以发送
    if [ ! -f "$ALERT_HISTORY_FILE" ]; then
        debug_echo "告警历史文件不存在，允许发送告警"
        return 0
    fi
    
    # 获取当前时间戳（秒）
    local current_seconds
    if [ -n "$current_timestamp" ]; then
        current_seconds=$(date -d "$current_timestamp" +%s 2>/dev/null)
    fi
    
    # 如果无法解析时间戳，使用当前时间
    if [ -z "$current_seconds" ]; then
        current_seconds=$(date +%s)
    fi
    
    debug_echo "检查告警冷却时间: 用户=$username, IP=$ip, 时间=$current_timestamp ($current_seconds)"
    
    # 查找最近相同用户和IP的告警记录
    local last_alert_line
    last_alert_line=$(grep -E "^${username}@${ip}:" "$ALERT_HISTORY_FILE" | tail -1)
    
    if [ -z "$last_alert_line" ]; then
        debug_echo "未找到相同用户和IP的历史告警记录，允许发送"
        return 0
    fi
    
    # 提取时间戳
    local last_timestamp_seconds
    last_timestamp_seconds=$(echo "$last_alert_line" | cut -d: -f2-)
    
    if [ -z "$last_timestamp_seconds" ] || [ "$last_timestamp_seconds" -eq 0 ]; then
        debug_echo "历史记录时间戳无效，允许发送"
        return 0
    fi
    
    # 计算时间差
    local time_diff=$((current_seconds - last_timestamp_seconds))
    
    debug_echo "上次告警时间: $last_timestamp_seconds, 时间差: ${time_diff}秒, 冷却时间: ${ALERT_COOLDOWN_SECONDS}秒"
    
    # 如果时间差大于冷却时间，允许发送
    if [ "$time_diff" -gt "$ALERT_COOLDOWN_SECONDS" ]; then
        debug_echo "距离上次告警已超过${ALERT_COOLDOWN_SECONDS}秒，允许发送"
        return 0
    else
        debug_echo "距离上次告警仅${time_diff}秒，仍在冷却期内，跳过发送"
        return 1
    fi
}

# 更新告警历史记录
update_alert_history() {
    local username="$1"
    local ip="$2"
    local timestamp="$3"
    
    # 转换为时间戳（秒）
    local timestamp_seconds
    timestamp_seconds=$(date -d "$timestamp" +%s 2>/dev/null)
    
    # 如果无法解析时间戳，使用当前时间
    if [ -z "$timestamp_seconds" ]; then
        timestamp_seconds=$(date +%s)
    fi
    
    # 创建或更新历史文件
    local history_entry="${username}@${ip}:${timestamp_seconds}"
    
    # 删除旧的相同用户和IP的记录
    if [ -f "$ALERT_HISTORY_FILE" ]; then
        grep -v "^${username}@${ip}:" "$ALERT_HISTORY_FILE" > "${ALERT_HISTORY_FILE}.tmp"
        mv "${ALERT_HISTORY_FILE}.tmp" "$ALERT_HISTORY_FILE"
    fi
    
    # 添加新记录
    echo "$history_entry" >> "$ALERT_HISTORY_FILE"
    
    debug_echo "更新告警历史记录: $history_entry"
    
    # 清理过期的历史记录（保留最近100条）
    if [ -f "$ALERT_HISTORY_FILE" ] && [ $(wc -l < "$ALERT_HISTORY_FILE") -gt 100 ]; then
        tail -100 "$ALERT_HISTORY_FILE" > "${ALERT_HISTORY_FILE}.tmp"
        mv "${ALERT_HISTORY_FILE}.tmp" "$ALERT_HISTORY_FILE"
        debug_echo "清理告警历史记录，保留最近100条"
    fi
}

# 清理旧的告警历史记录
cleanup_old_alerts() {
    local current_seconds=$(date +%s)
    local cutoff_seconds=$((current_seconds - ALERT_COOLDOWN_SECONDS * 24))  # 保留24倍冷却时间的记录
    
    if [ -f "$ALERT_HISTORY_FILE" ]; then
        local temp_file="${ALERT_HISTORY_FILE}.cleanup"
        
        while IFS=: read -r key timestamp; do
            if [ -n "$timestamp" ] && [ "$timestamp" -gt "$cutoff_seconds" ]; then
                echo "${key}:${timestamp}" >> "$temp_file"
            fi
        done < "$ALERT_HISTORY_FILE"
        
        if [ -f "$temp_file" ]; then
            mv "$temp_file" "$ALERT_HISTORY_FILE"
            debug_echo "清理了过期的告警历史记录"
        fi
    fi
}

# 使用curl发送邮件函数（集成你验证可用的方法）
send_email_curl() {
    local to="$1"
    local subject="$2"
    local body="$3"
    
    # 构建邮件内容
    local mail_content
    mail_content=$(cat << EOF
From: Vaultwarden 成功登录提醒 <$MAIL_FROM>
To: $to
Subject: $subject
Date: $(date -R)
Content-Type: text/plain; charset=utf-8

$body
EOF
)
    
    debug_echo "使用curl发送邮件到: $to"
    debug_echo "SMTP服务器: $SMTP_SERVER:$SMTP_PORT"
    
    # 使用curl发送邮件
    curl_output=$(curl -v \
      --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
      --ssl-reqd \
      --mail-from "$MAIL_FROM" \
      --mail-rcpt "$to" \
      --user "$SMTP_USER:$SMTP_PASSWORD" \
      --upload-file - <<< "$mail_content" 2>&1)
    
    local curl_result=$?
    
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo "=== curl发送邮件输出 ==="
        echo "$curl_output"
        echo "=== curl发送结束 ==="
    fi
    
    # 检查是否发送成功
    if echo "$curl_output" | grep -q "250 OK" || [ $curl_result -eq 0 ]; then
        debug_echo "邮件发送成功"
        return 0
    else
        debug_echo "邮件发送失败，curl退出码: $curl_result"
        return 1
    fi
}

# 备用邮件发送函数（使用openssl）
send_email_openssl() {
    local to="$1"
    local subject="$2"
    local body="$3"
    
    # 构建邮件内容
    local mail_content
    mail_content=$(cat << EOF
From: Vaultwarden Monitor <$MAIL_FROM>
To: $to
Subject: $subject
Date: $(date -R)
Content-Type: text/plain; charset=utf-8

$body
EOF
)
    
    debug_echo "尝试使用openssl发送邮件"
    
    # 准备SMTP命令序列
    local smtp_commands
    smtp_commands=$(cat << EOF
EHLO $(hostname)
AUTH LOGIN
$(echo -n "$SMTP_USER" | base64)
$(echo -n "$SMTP_PASSWORD" | base64)
MAIL FROM:<$MAIL_FROM>
RCPT TO:<$to>
DATA
$mail_content
.
QUIT
EOF
)
    
    # 发送邮件
    if echo "$smtp_commands" | openssl s_client -quiet -connect "$SMTP_SERVER:$SMTP_PORT" -starttls smtp 2>/dev/null | grep -q "250 OK"; then
        debug_echo "openssl邮件发送成功"
        return 0
    else
        debug_echo "openssl邮件发送失败"
        return 1
    fi
}

# 邮件告警发送函数
send_alert() {
    local ip="$1"
    local user="$2"
    local timestamp="$3"
    
    # 首先检查是否应该发送（基于冷却时间）
    if ! should_send_alert "$user" "$ip" "$timestamp"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏸️ 跳过发送告警（仍在冷却期内）: $user@$ip"
        return 0
    fi
    
    # 构造邮件正文
    local mail_body
    mail_body=$(cat << EOF
Vaultwarden登录安全告警

检测到非授权IP登录成功！
========================================

🔴 安全事件详情:
    • 发生时间: $timestamp
    • 用户名: $user
    • IP地址: $ip
    • 事件类型: 登录成功
    • 服务器: $(hostname)
    • 检测时间: $(date '+%Y-%m-%d %H:%M:%S')
    • 冷却时间: ${ALERT_COOLDOWN_SECONDS}秒内相同用户和IP不会重复告警

⚠️ 安全风险:
    此IP地址不在授权列表中，可能是未授权的访问尝试。
    建议立即检查相关账户的安全状态。

✅ 授权IP列表:
    ${AUTHORIZED_IPS[@]}

🔧 需要检查的内容:
    1. 确认是否为合法用户从新位置登录
    2. 检查账户是否有异常活动
    3. 如有必要，立即重置密码
    4. 检查服务器安全日志

📋 操作步骤:
    1. 登录服务器查看详细日志
    2. 检查Vaultwarden管理界面
    3. 如需阻止此IP，可添加到防火墙规则
    4. 通知相关用户检查账户安全

📁 日志文件路径: $LOG_FILE
🌐 服务器地址: $(hostname -I 2>/dev/null || hostname)

----------------------------------------
此邮件由Vaultwarden安全监控脚本自动发送
请勿直接回复此邮件
EOF
)
    
    debug_echo "正在发送告警邮件到: $MAIL_TO"
    debug_echo "邮件主题: $MAIL_SUBJECT"
    
    # 首先尝试使用curl发送（你验证过可用的方法）
    if send_email_curl "$MAIL_TO" "$MAIL_SUBJECT" "$mail_body"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 邮件告警已发送: $user@$ip"
        
        # 更新告警历史记录
        update_alert_history "$user" "$ip" "$timestamp"
        return 0
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ curl发送失败，尝试openssl方法: $user@$ip"
        
        # 如果curl失败，尝试openssl方法
        if send_email_openssl "$MAIL_TO" "$MAIL_SUBJECT" "$mail_body"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 使用openssl发送邮件成功: $user@$ip"
            
            # 更新告警历史记录
            update_alert_history "$user" "$ip" "$timestamp"
            return 0
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ 错误: 所有邮件发送方法都失败" >&2
            
            # 尝试使用系统mail命令作为最后备选方案
            if command -v mail &> /dev/null; then
                debug_echo "尝试使用系统mail命令发送"
                echo -e "$mail_body" | mail -s "$MAIL_SUBJECT" "$MAIL_TO"
                if [ $? -eq 0 ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 使用系统mail命令发送成功"
                    
                    # 更新告警历史记录
                    update_alert_history "$user" "$ip" "$timestamp"
                    return 0
                fi
            fi
            
            # 如果所有邮件发送都失败，记录到系统日志
            logger -t vaultwarden-monitor "ALERT: Unauthorized login $user@$ip but email notification failed"
            return 1
        fi
    fi
}

# 检查IP是否在授权列表中
check_ip_authorized() {
    local check_ip="$1"
    
    # 如果授权IP列表为空，则拒绝所有IP
    if [ ${#AUTHORIZED_IPS[@]} -eq 0 ]; then
        debug_echo "授权IP列表为空，拒绝所有IP"
        return 1
    fi
    
    # 检查IP是否在授权列表中
    for authorized_ip in "${AUTHORIZED_IPS[@]}"; do
        if [ "$check_ip" = "$authorized_ip" ]; then
            debug_echo "IP $check_ip 在授权列表中"
            return 0
        fi
    done
    
    debug_echo "IP $check_ip 不在授权列表中"
    return 1
}

# 初始化检查
initialize_check() {
    # 检查必要工具
    local required_tools=("curl" "grep" "awk" "sed" "tail" "stat" "date")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo "⚠️ 警告: 需要工具 $tool 但未安装，尝试安装..." >&2
            
            # 尝试安装
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y "$tool"
                if [ $? -ne 0 ]; then
                    echo "❌ 错误: 无法安装 $tool，请手动安装" >&2
                    exit 1
                fi
            elif command -v yum &> /dev/null; then
                yum install -y "$tool"
                if [ $? -ne 0 ]; then
                    echo "❌ 错误: 无法安装 $tool，请手动安装" >&2
                    exit 1
                fi
            else
                echo "❌ 错误: 无法安装 $tool，请手动安装" >&2
                exit 1
            fi
        fi
    done
    
    # 检查openssl（可选但推荐）
    if ! command -v openssl &> /dev/null; then
        debug_echo "警告: openssl未安装，备用邮件发送方法不可用"
    fi
    
    # 检查日志文件
    if [ ! -f "$LOG_FILE" ]; then
        echo "⚠️ 警告: 日志文件不存在: $LOG_FILE" >&2
        echo "请检查配置或创建日志文件" >&2
        
        # 尝试创建目录
        local log_dir=$(dirname "$LOG_FILE")
        if [ ! -d "$log_dir" ]; then
            mkdir -p "$log_dir"
            debug_echo "创建日志目录: $log_dir"
        fi
        
        # 创建空日志文件
        touch "$LOG_FILE"
        echo "已创建空日志文件: $LOG_FILE" >&2
    fi
    
    # 检查SMTP配置
    if [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ]; then
        echo "❌ 错误: SMTP用户名或密码未配置" >&2
        exit 1
    fi
    
    # 创建告警历史文件（如果不存在）
    if [ ! -f "$ALERT_HISTORY_FILE" ]; then
        touch "$ALERT_HISTORY_FILE"
        debug_echo "创建告警历史文件: $ALERT_HISTORY_FILE"
    fi
    
    # 清理旧的告警历史记录
    cleanup_old_alerts
    
    debug_echo "初始化检查完成"
    debug_echo "告警冷却时间: ${ALERT_COOLDOWN_SECONDS}秒"
    debug_echo "告警历史文件: $ALERT_HISTORY_FILE"
}

# 测试邮件发送功能
test_email_function() {
    echo "测试邮件发送功能..."
    
    local test_body="这是Vaultwarden监控脚本的测试邮件。\n\n如果收到此邮件，说明邮件发送功能正常。\n\n时间: $(date '+%Y-%m-%d %H:%M:%S')\n服务器: $(hostname)\n告警冷却时间: ${ALERT_COOLDOWN_SECONDS}秒"
    
    echo "正在发送测试邮件到: $MAIL_TO"
    
    if send_email_curl "$MAIL_TO" "Vaultwarden监控脚本测试邮件" "$test_body"; then
        echo "✅ 测试邮件发送成功！请检查邮箱是否收到测试邮件。"
        return 0
    else
        echo "❌ 测试邮件发送失败。"
        echo "正在尝试备用方法..."
        
        if send_email_openssl "$MAIL_TO" "Vaultwarden监控脚本测试邮件" "$test_body"; then
            echo "✅ 备用方法测试邮件发送成功！"
            return 0
        else
            echo "❌ 所有邮件发送方法都失败，请检查配置。"
            return 1
        fi
    fi
}

# 显示告警历史
show_alert_history() {
    echo "告警历史记录:"
    echo "========================================"
    
    if [ ! -f "$ALERT_HISTORY_FILE" ] || [ ! -s "$ALERT_HISTORY_FILE" ]; then
        echo "暂无告警历史记录"
        return
    fi
    
    local current_seconds=$(date +%s)
    
    while IFS=: read -r key timestamp; do
        local user_ip="$key"
        local timestamp_str=$(date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知时间")
        local time_diff=$((current_seconds - timestamp))
        
        # 计算剩余冷却时间（如果是正数）
        local remaining_cooldown=$((ALERT_COOLDOWN_SECONDS - time_diff))
        
        if [ "$remaining_cooldown" -gt 0 ]; then
            local hours=$((remaining_cooldown / 3600))
            local minutes=$(( (remaining_cooldown % 3600) / 60 ))
            local seconds=$((remaining_cooldown % 60))
            echo "  $user_ip - $timestamp_str (冷却中: ${hours}h${minutes}m${seconds}s)"
        else
            echo "  $user_ip - $timestamp_str (可告警)"
        fi
    done < "$ALERT_HISTORY_FILE"
    
    echo "========================================"
    echo "总计记录数: $(wc -l < "$ALERT_HISTORY_FILE")"
}

# 主监控函数
monitor_logs() {
    # 检查是否已在运行
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            debug_echo "脚本已在运行中 (PID: $pid)，退出..."
            exit 1
        else
            debug_echo "发现旧的锁文件，清理..."
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 创建锁文件
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
    
    # 检查日志文件是否存在
    if [ ! -f "$LOG_FILE" ]; then
        echo "❌ 错误: 日志文件不存在: $LOG_FILE" >&2
        exit 1
    fi
    
    # 获取日志文件大小
    local file_size=$(stat -c %s "$LOG_FILE" 2>/dev/null)
    if [ -z "$file_size" ]; then
        echo "❌ 错误: 无法获取日志文件大小" >&2
        exit 1
    fi
    
    debug_echo "日志文件: $LOG_FILE (大小: ${file_size}字节)"
    debug_echo "检查最近 $CHECK_LINES 行日志"
    
    # 读取最近50行日志并处理
    local found_events=0
    
    # 使用tail读取最近50行
    tail -n $CHECK_LINES "$LOG_FILE" | while IFS= read -r line; do
        # 检查登录成功的日志
        if echo "$line" | grep -q 'logged in successfully. IP:'; then
            # 提取时间戳、用户名和IP
            local timestamp user ip
            
            # 提取时间戳（假设日志格式为 [YYYY-MM-DD HH:MM:SS]）
            timestamp=$(echo "$line" | grep -o '\[[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\]' | head -1 | tr -d '[]')
            
            # 提取用户名
            user=$(echo "$line" | grep -o 'User [^ ]*' | awk '{print $2}')
            
            # 提取IP地址
            ip=$(echo "$line" | grep -o 'IP: [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | awk '{print $2}')
            
            if [ -n "$timestamp" ] && [ -n "$user" ] && [ -n "$ip" ]; then
                found_events=$((found_events + 1))
                debug_echo "发现登录事件: $user@$ip ($timestamp)"
                
                # 检查IP授权
                if ! check_ip_authorized "$ip"; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ 发现非授权IP登录: $user@$ip"
                    send_alert "$ip" "$user" "$timestamp"
                else
                    debug_echo "授权IP登录: $user@$ip"
                fi
            fi
        fi
    done
    
    if [ "$found_events" -gt 0 ]; then
        debug_echo "处理了 $found_events 个登录事件"
    else
        debug_echo "在最近 $CHECK_LINES 行日志中未发现登录事件"
    fi
}

# ========== 主程序 ==========

# 显示启动信息
echo "========================================"
echo "Vaultwarden登录监控脚本启动"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "主机: $(hostname)"
echo "日志文件: $LOG_FILE"
echo "检查行数: $CHECK_LINES 行"
echo "邮件收件人: $MAIL_TO"
echo "告警冷却时间: ${ALERT_COOLDOWN_SECONDS}秒"
echo "========================================"

# 检查命令行参数
case "$1" in
    "test")
        # 测试模式
        initialize_check
        test_email_function
        exit 0
        ;;
    "reset")
        # 重置模式，清除检查点
        rm -f "$LOCK_FILE" "$ALERT_HISTORY_FILE"
        echo "已重置锁文件和告警历史记录"
        exit 0
        ;;
    "status")
        # 状态模式
        initialize_check
        if [ -f "$LOG_FILE" ]; then
            local total_lines=$(wc -l < "$LOG_FILE" 2>/dev/null)
            local file_size=$(stat -c %s "$LOG_FILE" 2>/dev/null)
            echo "日志文件: $LOG_FILE"
            echo "总行数: $total_lines"
            echo "文件大小: ${file_size}字节"
            echo "检查行数: $CHECK_LINES 行"
            echo ""
            
            # 显示最近几条登录记录
            echo "最近登录记录:"
            grep 'logged in successfully. IP:' "$LOG_FILE" | tail -5 | sed 's/^/  /'
            echo ""
            
            # 显示告警历史
            show_alert_history
        else
            echo "日志文件不存在: $LOG_FILE"
        fi
        exit 0
        ;;
    "history")
        # 显示告警历史
        show_alert_history
        exit 0
        ;;
    "clean")
        # 清理旧的历史记录
        cleanup_old_alerts
        echo "已清理过期的告警历史记录"
        exit 0
        ;;
    "")
        # 正常监控模式
        ;;
    *)
        echo "用法: $0 [command]"
        echo ""
        echo "命令:"
        echo "  (无)     正常监控模式"
        echo "  test     测试邮件发送功能"
        echo "  reset    重置锁文件和告警历史记录"
        echo "  status   显示脚本状态和最近登录记录"
        echo "  history  显示告警历史记录"
        echo "  clean    清理过期的告警历史记录"
        echo ""
        echo "配置参数:"
        echo "  冷却时间: ${ALERT_COOLDOWN_SECONDS}秒"
        echo "  告警历史: $ALERT_HISTORY_FILE"
        echo "  授权IP: ${AUTHORIZED_IPS[@]}"
        exit 1
        ;;
esac

# 正常监控模式
initialize_check

# 执行监控
monitor_logs

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 监控检查完成"
