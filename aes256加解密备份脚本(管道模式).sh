#!/bin/bash
ulimit -c 0  # 禁止生成 core dump 文件
set -e
# ============================================================
# 备份与还原脚本 (backup_restore.sh)
# ============================================================
#
# 功能概述:
#   本脚本提供文件备份、加密、分割、上传网盘及还原的完整解决方案，
#   支持本地和远程（123云盘）操作，具备文件头混淆、安全密码输入等特性。
#
# ---- 使用说明 ----
#
# 1. 执行备份（使用默认密码）:
#    ./backup_restore.sh
#    默认备份 /storage/emulated/0/Download 目录
#
# 2. 执行备份（交互式输入密码）:
#    ./backup_restore.sh -pwd
#
# 3. 从备份还原:
#    # 从本地备份还原（完整路径）
#    ./backup_restore.sh -r /backups/backup_20240101_120000/backup_20240101_120000.aes [-to /path/to/restore] [-pwd]
#
#    # 从本地备份还原（目录路径）
#    ./backup_restore.sh -r /backups/backup_20240101_120000 [-to /path/to/restore] [-pwd]
#
#    # 从网盘备份还原
#    ./backup_restore.sh -r backup_20240101_120000 [-to /path/to/restore] [-pwd]
#
#    # 使用序号还原（本地和网盘统一编号）
#    ./backup_restore.sh -r 1 [-to /custom/path] [-pwd]
#
# 4. 显示备份列表（本地+网盘）:
#    ./backup_restore.sh -list
#
# 5. 显示帮助信息:
#    ./backup_restore.sh -h
#
# 6. 手动上传备份到网盘:
#    # 上传最新本地备份
#    ./backup_restore.sh -up
#
#    # 通过序号上传指定备份
#    ./backup_restore.sh -up 1
#
#    # 上传指定目录
#    ./backup_restore.sh -up /path/to/directory [-pwd]
#
# 7. 删除备份:
#    ./backup_restore.sh -del 1
#    （序号从 -list 查看）
#
# 8. 备份指定目录（可选上传）:
#    ./backup_restore.sh -sd /path/to/directory [-pwd] [-up] [-to /output/dir]
#
# ---- 密码说明 ----
#   - 不带 -pwd 参数: 使用脚本内置默认密码（PASSWORD 变量）
#   - 带 -pwd 参数: 触发交互式安全输入（输入时字符不可见，需确认）
#   - 安全特性: 密码绝不会出现在命令行历史、进程列表或环境变量中
#
# ---- 文件头混淆说明 ----
#   - 备份文件的 001 分割文件（或未分割的单文件）的 OpenSSL 头 (Salted__)
#     会被替换为 ZIP 文件头（\x50\x4B\x03\x04...）
#   - 原始 16 字节 OpenSSL 头 + 8 字节偏移量 + 4 字节标记 "OBFS" 
#     共 28 字节嵌入文件末尾
#   - 还原时自动检测尾部 "OBFS" 标记并恢复原始文件头
#   - 混淆状态不影响校验（校验在混淆后生成，还原前校验）
#   - 可通过 OBFUSCATE_HEADER 变量开关此功能 (true/false)
#
# ---- 配置参数说明 ----
#   TARGET_DIR       : 默认备份目录
#   BACKUP_DIR       : 加密备份存储路径
#   RESTORE_DIR      : 默认恢复路径
#   PASSWORD         : 默认密码（不带 -pwd 时使用）
#   RCLONE_REMOTE    : 网盘存储名称（rclone 配置）
#   SPLIT_SIZE       : 加密文件分割大小（如 100M）
#   ZSTD_LEVEL       : ZSTD 压缩等级（1-19，默认 3）
#   KEEP_LATEST      : 保留最新备份份数
#   AUTO_UPLOAD      : 备份后是否自动上传 (true/false)
#   OBFUSCATE_HEADER : 是否混淆文件头 (true/false)
#   BACKUP_PREFIX    : 备份名前缀（默认 "llama.cpp_backup_"）
#
# ---- 依赖要求 ----
#   tar, zstd, pv, rclone, jq, openssl, xxd, coreutils, findutils
#   脚本会自动检测系统环境并安装缺失依赖
#   支持: Termux, Alpine, Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, openSUSE, macOS
#
# ---- 工作流程 ----
#   备份: 压缩(tar+zstd) → 校验 → 加密(AES-256-CBC) → 分割(dd) → 混淆 → 校验和 → 上传(可选)
#   还原: 下载(如需) → 校验 → 还原文件头 → 合并 → 解密 → 解压
#
# ---- 注意事项 ----
#   - 首次使用需配置 rclone 远程存储（脚本会自动引导）
#   - 备份文件命名格式: {BACKUP_PREFIX}YYYYMMDD_HHMMSS
#   - 支持增量下载，避免重复下载已存在的分割文件
#   - 还原前会自动检查路径穿越风险（拒绝含 ../ 的恶意路径）
#   - 临时文件和密码使用后自动安全清除（shred）
#   - Core dump 已禁止生成
#   - 兼容 ash/bash 环境
#
# ============================================================

# 配置参数
TARGET_DIR="/storage/emulated/0/Download" # 默认备份路径
BACKUP_DIR="$HOME/backups"            # 加密备份存储路径
RESTORE_DIR="$HOME/restored"          # 默认恢复路径
TEMP_DIR="$HOME/backups/tmp"          # 临时文件处理路径
PASSWORD="" # 默认密码（不带 -pwd 参数时使用）
RCLONE_REMOTE="123pan" # 网盘存储名称
RCLONE_PATH="/123pan" # 网盘存储路径
KEEP_LATEST="3" # 保留加密文件份数
SPLIT_SIZE="100M" #默认加密文件分割大小
SPLIT_SUFFIX=".zip" #加密文件后缀名
ZSTD_LEVEL="3" # ZSTD压缩等级
COMPRESS_SPEED="250M" # 压缩速度
USER_AGENT="123pan/v2.5.5(Android 13;Xiaomi Mi Max 2)" # 客户端UA伪装
BACKUP_PREFIX="llama.cpp_backup_"  # 备份名前缀配置参数
AUTO_UPLOAD="true"  # 设置为 (true/false) 来设置是否自动上传备份到网盘
OBFUSCATE_HEADER="true" # 是否混淆001文件头 (true/false)
FAKE_FILE_HEADER="\x50\x4B\x03\x04\x14\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00"  #文件头混淆
PBKDF2_ITER="1000000"      # 迭代次数 原次数为10万
CIPHER_ALG="aes-256-cbc"   # 加密模式

# ============================================================
# 安全加密/解密函数（使用文件描述符，密码不落盘）
# ============================================================

# 创建安全密码临时文件
create_password_tempfile() {
    local password="$1"
    local tmpfile
    
    tmpfile=$(mktemp) || {
        echo "错误: 无法创建密码临时文件" >&2
        return 1
    }
    
    # 设置严格权限
    chmod 600 "$tmpfile" || {
        rm -f "$tmpfile"
        echo "错误: 无法设置密码文件权限" >&2
        return 1
    }
    
    # 写入密码
    printf '%s' "$password" > "$tmpfile"
    
    # 返回文件路径
    echo "$tmpfile"
}

# 安全销毁密码临时文件
destroy_password_tempfile() {
    local tmpfile="$1"
    if [ -n "$tmpfile" ] && [ -f "$tmpfile" ]; then
        # 先覆写再删除
        shred -u "$tmpfile" 2>/dev/null || {
            # 如果shred不可用，用随机数据覆写
            dd if=/dev/urandom of="$tmpfile" bs=1 count=$(wc -c < "$tmpfile") conv=notrunc 2>/dev/null
            rm -f "$tmpfile"
        }
    fi
}

# 安全加密函数（使用临时文件描述符）
secure_encrypt() {
    local input="$1"
    local output="$2"
    local password="$3"
    local password_file=""
    local ret=1
    
    # 创建密码临时文件
    password_file=$(create_password_tempfile "$password") || return 1
    
    # 使用 -pass file: 替代 stdin 传递密码
    openssl enc -${CIPHER_ALG} -pbkdf2 -iter ${PBKDF2_ITER} \
        -in "$input" -out "$output" \
        -pass file:"$password_file" 2>/dev/null
    ret=$?
    
    # 立即销毁密码临时文件
    destroy_password_tempfile "$password_file"
    
    if [ $ret -ne 0 ]; then
        echo "错误: 加密失败" >&2
        return 1
    fi
    
    return 0
}

# 安全解密函数（使用临时文件描述符）
secure_decrypt() {
    local input="$1"
    local output="$2"
    local password="$3"
    local password_file=""
    local ret=1
    
    # 创建密码临时文件
    password_file=$(create_password_tempfile "$password") || return 1
    
    # 使用 -pass file: 替代 stdin 传递密码
    openssl enc -d -${CIPHER_ALG} -pbkdf2 -iter ${PBKDF2_ITER} \
        -in "$input" -out "$output" \
        -pass file:"$password_file" 2>/dev/null
    ret=$?
    
    # 立即销毁密码临时文件
    destroy_password_tempfile "$password_file"
    
    if [ $ret -ne 0 ]; then
        echo "错误: 解密失败，请检查密码是否正确" >&2
        return 1
    fi
    
    return 0
}

# ============================================================
# 批量处理辅助函数：使用密码文件执行多个操作
# 适用于需要多次使用同一密码的场景
# ============================================================
run_with_password_file() {
    local password="$1"
    local callback="$2"
    shift 2
    local password_file=""
    local ret=1
    
    # 创建密码临时文件（一次性）
    password_file=$(create_password_tempfile "$password") || return 1
    
    # 将密码文件路径作为第一个参数传给回调函数
    "$callback" "$password_file" "$@"
    ret=$?
    
    # 操作完成后销毁密码文件
    destroy_password_tempfile "$password_file"
    
    return $ret
}

# ============================================================
# 文件头混淆相关函数（偏移量存储方案）
# ============================================================

# 函数: 将原始文件头附加到文件末尾并替换为指定伪装头
obfuscate_001_header() {
    local target_file="$1"
    
    if [ ! -f "$target_file" ]; then
        echo "错误: 目标文件不存在: $target_file"
        return 1
    fi
    
    echo "[混淆] 正在处理: $(basename "$target_file")"
    
    # 用 head 读取原始前16字节，速度远快于 dd
    local original_header=$(head -c 16 "$target_file" | xxd -p | tr -d '\n')
    if [ ${#original_header} -ne 32 ]; then
        echo "错误: 无法读取原始文件头 (读取到 ${#original_header} 字符)"
        return 1
    fi
    
    # 检查是否已经被混淆过
    local first_two=$(echo "$original_header" | cut -c1-4)
    if [ "$first_two" = "504b" ]; then
        echo "[混淆] 文件已是指定伪装文件头，跳过混淆"
        return 0
    fi
    
    # 记录当前文件大小
    local orig_size=$(wc -c < "$target_file")
    
    # 写入伪装头（16字节）
    printf "$FAKE_FILE_HEADER" | \
    dd of="$target_file" bs=16 count=1 conv=notrunc 2>/dev/null || {
        echo "错误: 写入伪装文件头失败"
        return 1
    }
    
    # 在文件末尾追加：原始头(16字节) + 偏移量(8字节小端) + OBFS(4字节)
    local offset_le=$(printf '%016x' "$orig_size" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\8\7\6\5\4\3\2\1/')
    printf '%b' "$(echo "$original_header" | sed 's/\(..\)/\\x\1/g')" >> "$target_file"
    printf '%b' "$(echo "$offset_le" | sed 's/\(..\)/\\x\1/g')" >> "$target_file"
    printf 'OBFS' >> "$target_file"
    
    echo "[混淆] 完成: 原始头+偏移量已嵌入文件末尾 (28字节尾部数据)"
    return 0
}

# 函数: 从文件末尾提取原始头并还原
restore_001_header() {
    local target_file="$1"
    
    if [ ! -f "$target_file" ]; then
        echo "错误: 目标文件不存在: $target_file"
        return 1
    fi
    
    # 用 tail 读取末尾4字节魔术标记，速度极快
    local magic=$(tail -c 4 "$target_file")
    if [ "$magic" != "OBFS" ]; then
        echo "[还原] 未找到混淆标记，文件可能未混淆或已还原"
        return 0
    fi
    
    echo "[还原] 检测到混淆标记，正在还原: $(basename "$target_file")"
    
    # 用 tail 一次性读取末尾28字节
    local tail_data=$(tail -c 28 "$target_file" | xxd -p | tr -d '\n')
    
    if [ ${#tail_data} -ne 56 ]; then
        echo "错误: 无法读取尾部数据 (读取到 ${#tail_data} 字符)"
        return 1
    fi
    
    # 提取原始头（前32字符 = 16字节）
    local original_header=$(echo "$tail_data" | cut -c1-32)
    
    # 提取偏移量（接下来16字符 = 8字节，小端序）
    local offset_le=$(echo "$tail_data" | cut -c33-48)
    # 小端转大端：逐字节反转
    local orig_size=0
    local i
    for i in 14 12 10 8 6 4 2 0; do
        local byte=$(echo "$offset_le" | cut -c$((i+1))-$((i+2)))
        orig_size=$((orig_size * 256 + 16#$byte))
    done
    
    # 验证偏移量合理性
    local file_size=$(wc -c < "$target_file")
    if [ "$orig_size" -lt 16 ] || [ "$orig_size" -gt "$file_size" ]; then
        echo "错误: 偏移量异常 ($orig_size)，文件可能已损坏"
        return 1
    fi
    
    # 写入原始头（一次性16字节）
    printf '%b' "$(echo "$original_header" | sed 's/\(..\)/\\x\1/g')" | \
    dd of="$target_file" bs=16 count=1 conv=notrunc 2>/dev/null || {
        echo "错误: 还原文件头失败"
        return 1
    }
    
    # 截断文件，去掉末尾28字节（用 head 比 dd 截断快得多）
    local new_size=$((file_size - 28))
    head -c "$new_size" "$target_file" > "${target_file}.tmp" && \
    mv "${target_file}.tmp" "$target_file" || {
        echo "错误: 截断文件失败"
        return 1
    }
    
    echo "[还原] 完成: 原始头已恢复，尾部数据已移除"
    return 0
}

# 函数: 检查文件是否已被混淆
is_obfuscated() {
    local target_file="$1"
    [ ! -f "$target_file" ] && return 1
    [ $(wc -c < "$target_file") -lt 44 ] && return 1
    [ "$(tail -c 4 "$target_file")" = "OBFS" ]
}

# 函数: 以安全交互方式输入密码（返回密码而非设置全局变量）
get_password_interactively() {
    local password1 password2
    
    echo -n "请输入密码: " >&2
    stty -echo 2>/dev/null || true
    read -r password1
    stty echo 2>/dev/null || true
    echo >&2
    
    if [ -z "$password1" ]; then
        echo "错误: 密码不能为空" >&2
        exit 1
    fi
    
    echo -n "请再次输入密码以确认: " >&2
    stty -echo 2>/dev/null || true
    read -r password2
    stty echo 2>/dev/null || true
    echo >&2
    
    if [ "$password1" != "$password2" ]; then
        echo "错误: 两次输入的密码不一致" >&2
        exit 1
    fi
    
    # 提示信息输出到 stderr，不干扰密码的返回值
    echo "[*] 密码已安全设置。" >&2
    
    # 只将密码输出到 stdout（返回值）
    printf '%s' "$password1"
}

# 函数: 安全地临时使用密码执行操作
run_with_password() {
    local callback="$1"
    shift
    
    # 创建受限权限的临时文件存储密码（仅在需要时）
    local password_file
    password_file=$(mktemp) && chmod 600 "$password_file" || {
        echo "错误: 无法创建安全临时文件"
        exit 1
    }
    
    # 获取密码并立即写入临时文件
    get_password_interactively > "$password_file"
    
    # 执行回调函数，将密码文件路径作为最后一个参数传递
    "$callback" "$@" "$password_file"
    local ret=$?
    
    # 立即安全删除密码文件
    shred -u "$password_file" 2>/dev/null || rm -f "$password_file"
    
    return $ret
}

# ============================================================
# 安全临时文件创建函数
# ============================================================
create_secure_tempfile() {
    local tempfile
    tempfile=$(mktemp) || { echo "错误: 无法创建临时文件"; exit 1; }
    chmod 600 "$tempfile" || { 
        rm -f "$tempfile"
        echo "错误: 无法设置临时文件权限" 
        exit 1
    }
    printf '%s' "$tempfile"
}

# 清理临时文件函数（更安全的实现）
cleanup() {
    local exit_code=$?
    
    # 清理已知的临时文件
    if [ -n "${args_file:-}" ] && [ -f "$args_file" ]; then
        shred -u "$args_file" 2>/dev/null || rm -f "$args_file"
    fi
    if [ -n "${local_backups_file:-}" ] && [ -f "$local_backups_file" ]; then
        shred -u "$local_backups_file" 2>/dev/null || rm -f "$local_backups_file"
    fi
    if [ -n "${yun_backups_file:-}" ] && [ -f "$yun_backups_file" ]; then
        shred -u "$yun_backups_file" 2>/dev/null || rm -f "$yun_backups_file"
    fi
    
    # 清理还原过程中产生的临时文件
    # 更安全的做法：删除脚本自己创建的特定目录
    if [ -n "${TEMP_DIR_FOR_SCRIPT:-}" ] && [ -d "$TEMP_DIR_FOR_SCRIPT" ]; then
        rm -rf "${TEMP_DIR_FOR_SCRIPT:?}" 2>/dev/null
    fi
    if [ -d "$TEMP_DIR" ]; then
        # 只删除与本次备份相关的临时目录，避免影响其他进程
        find "$TEMP_DIR" -maxdepth 1 -name "${backup_name:-__nonexistent__}*" -delete 2>/dev/null
    fi
    
    # 安全清除密码（尽力而为，bash层面效果有限）
    if [ -n "${PASSWORD:-}" ]; then
        # 覆写变量内容
        PASSWORD=$(head -c "${#PASSWORD}" /dev/urandom 2>/dev/null | tr -dc '[:print:]')
        PASSWORD=""
        unset PASSWORD
    fi
    
    return $exit_code
}
trap cleanup EXIT INT TERM HUP

# 检查网盘是否可用
check_rclone_available() {
    if rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
        return 0
    else
        return 1
    fi
}

# 函数: 显示示例命令
show_examples() {
    echo "示例命令:"
    echo "1. 执行备份（使用默认密码）:"
    echo "   $0"
    echo ""
    echo "2. 执行备份（交互式输入密码）:"
    echo "   $0 -pwd"
    echo ""
    echo "3. 从本地备份还原:"
    echo "   $0 -r $BACKUP_DIR/${BACKUP_PREFIX}20240101_120000/${BACKUP_PREFIX}20240101_120000.aes [-to /custom/restore/path] [-pwd]"
    echo "   或使用序号: $0 -r 1 [-to /custom/restore/path]"
    echo ""
    echo "4. 从网盘备份还原:"
    echo "   $0 -r ${BACKUP_PREFIX}20240101_120000 [-to /custom/restore/path] [-pwd]"
    echo "   或使用序号: $0 -r 5 [-to /custom/restore/path]"
    echo ""
    echo "5. 显示备份列表:"
    echo "   $0 -list"
    echo ""
    echo "6. 删除备份:"
    echo "   $0 -del 1 (删除序号1的备份)"
    echo ""
    echo "7. 手动上传指定目录:"
    echo "   $0 -up /path/to/directory [-pwd]"
    echo ""
    echo "8. 备份指定目录:"
    echo "   $0 -sd /path/to/directory [-pwd] [-up]"
    echo ""
    echo "9. 显示帮助:"
    echo "   $0 -h"
    echo ""
    echo "密码说明:"
    echo "  - 不带 -pwd 参数: 使用脚本内置默认密码"
    echo "  - 带 -pwd 参数: 触发交互式安全输入（输入不可见）"
    echo "  - 密码绝不会出现在命令行历史或进程列表中"
    echo ""
    echo "文件头混淆说明:"
    echo "  - 001文件(或单文件)的OpenSSL头(Salted__)会被替换为JPEG头"
    echo "  - 原始16字节头+偏移量嵌在文件末尾(28字节尾部)"
    echo "  - 还原时自动检测并恢复原始头"
    echo "  - 可通过 OBFUSCATE_HEADER 变量开关此功能"
    exit 0
}

# 函数: 显示用法
show_usage() {
    echo "用法:"
    echo "  $0 [-h] [-list] [-r 备份路径/序号] [-to 恢复路径] [-up 目录] [-del 序号] [-sd 目录] [-pwd]"
    show_examples
    exit 1
}

# 函数: 处理密码参数
handle_password_option() {
    local use_interactive=false
    
    while [ $# -gt 0 ]; do
        case "$1" in
            -pwd)
                use_interactive=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if [ "$use_interactive" = true ]; then
        # 直接调用交互式输入函数，该函数自己会显示提示信息
        PASSWORD=$(get_password_interactively)
    else
        echo "[*] 使用默认密码"
    fi
}

get_backup_list() {
    # 使用临时文件存储备份列表
    local_backups_file=$(create_secure_tempfile)
    yun_backups_file=$(create_secure_tempfile)
    
    # 本地备份（显示所有目录）
    if [ -d "$BACKUP_DIR" ]; then
        find "$BACKUP_DIR" -maxdepth 1 -type d | grep -v "/backups$" | grep -v "$TEMP_DIR" | sort -r | while IFS= read -r dir; do
            dirname=$(basename "$dir")
            size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            mtime=$(stat -c "%y" "$dir" 2>/dev/null | cut -d'.' -f1)
            printf "%s (大小: %s, 修改时间: %s)\n" "$dirname" "${size:-未知}" "${mtime:-未知}" >> "$local_backups_file"
        done
    fi
    
    # 网盘备份（仅在配置可用时显示）
    if check_rclone_available; then
        rclone lsf "$RCLONE_REMOTE:$RCLONE_PATH" --dirs-only --max-depth 1 2>/dev/null | sort -r | while IFS= read -r dir; do
            info=$(rclone size "$RCLONE_REMOTE:${RCLONE_PATH%/}/${dir}" --json 2>/dev/null)
            size=$(echo "$info" | jq -r '.bytes' 2>/dev/null | awk '{if($1>=1024^3) printf "%.2f GB", $1/1024/1024/1024; else if($1>=1024^2) printf "%.2f MB", $1/1024/1024; else if($1>=1024) printf "%.2f KB", $1/1024; else printf "%d bytes", $1}')
            mtime=$(rclone lsf "$RCLONE_REMOTE:${RCLONE_PATH%/}/${dir}" --format "t" --files-only --max-depth 1 2>/dev/null | head -1 | cut -d';' -f2)
            printf "%s (大小: %s, 修改时间: %s)\n" "$dir" "${size:-未知}" "${mtime:-未知}" >> "$yun_backups_file"
        done
    fi
    
    # 读取到变量
    local_backups=$(cat "$local_backups_file" 2>/dev/null)
    yun_backups=$(cat "$yun_backups_file" 2>/dev/null)
}

# 函数: 显示备份列表（本地和网盘）- 自动重新排序
show_backup_list() {
    get_backup_list
    
    # 合并本地和网盘备份列表并统一编号
    local all_backups=""
    local counter=1
    
    # 先处理本地备份
    if [ -n "$local_backups" ]; then
        all_backups="${all_backups}LOCAL_START\n${local_backups}\nLOCAL_END\n"
    else
        all_backups="${all_backups}LOCAL_START\nLOCAL_END\n"
    fi
    
    # 再处理网盘备份
    if [ -n "$yun_backups" ]; then
        all_backups="${all_backups}YUN_START\n${yun_backups}\nYUN_END\n"
    else
        all_backups="${all_backups}YUN_START\nYUN_END\n"
    fi
    
    # 显示本地备份
    echo "本地备份列表 (${BACKUP_DIR}):"
    echo "----------------------------------------"
    local local_section=false
    local has_local=false
    
    while IFS= read -r line; do
        case "$line" in
            "LOCAL_START")
                local_section=true
                continue
                ;;
            "LOCAL_END")
                local_section=false
                if [ "$has_local" = false ]; then
                    echo "没有找到本地备份"
                fi
                continue
                ;;
            "YUN_START")
                continue
                ;;
            "YUN_END")
                continue
                ;;
        esac
        
        if [ "$local_section" = true ] && [ -n "$line" ]; then
            printf "%2d. %s\n" "$counter" "$line"
            counter=$((counter+1))
            has_local=true
        fi
    done <<EOF
$(printf '%b' "$all_backups")
EOF
    
    echo "----------------------------------------"
    echo "使用示例: $0 -r /root/backups/llama.cpp_backup_20240101_120000/llama.cpp_backup_20240101_120000.aes [-to /custom/path]"
    local local_example=$counter
    echo "或使用序号: $0 -r 1 [-to /custom/path]"
    echo

    # 显示网盘备份
    echo "网盘备份列表 (${RCLONE_REMOTE}:${RCLONE_PATH}):"
    echo "----------------------------------------"
    if check_rclone_available; then
        local yun_section=false
        local has_yun=false
        
        while IFS= read -r line; do
            case "$line" in
                "LOCAL_START"|"LOCAL_END")
                    continue
                    ;;
                "YUN_START")
                    yun_section=true
                    continue
                    ;;
                "YUN_END")
                    yun_section=false
                    if [ "$has_yun" = false ]; then
                        echo "没有找到网盘备份"
                    fi
                    continue
                    ;;
            esac
            
            if [ "$yun_section" = true ] && [ -n "$line" ]; then
                printf "%2d. %s\n" "$counter" "$line"
                counter=$((counter+1))
                has_yun=true
            fi
        done <<EOF
$(printf '%b' "$all_backups")
EOF
    else
        echo "网盘未配置，请先运行 'rclone config' 配置远程存储"
    fi
    echo "----------------------------------------"
    echo "使用示例: $0 -r llama.cpp_backup_20240101_120000 [-to /custom/path]"
    echo "或使用序号: $0 -r $local_example [-to /custom/path]"
}

# 函数: 根据序号获取备份名称（基于当前实际备份列表）
get_backup_by_index() {
    local index="$1"
    get_backup_list
    
    # 构建统一的备份列表数组
    local all_backups_array=()
    
    # 添加本地备份
    if [ -n "$local_backups" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && all_backups_array+=("$line")
        done <<EOF
$local_backups
EOF
    fi
    
    # 添加网盘备份
    if [ -n "$yun_backups" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && all_backups_array+=("$line")
        done <<EOF
$yun_backups
EOF
    fi
    
    local total_count=${#all_backups_array[@]}
    
    if [ "$index" -gt 0 ] && [ "$index" -le "$total_count" ]; then
        # 获取对应的备份项
        local backup_item="${all_backups_array[$((index-1))]}"
        # 提取备份名称（第一列）
        local result=$(echo "$backup_item" | awk '{print $1}')
        # 去除尾部的斜杠
        echo "${result%/}"
        return 0
    else
        echo ""
        return 1
    fi
}

# 函数: 自动判断备份位置
determine_backup_location() {
    local backup_arg="$1"
    
    # 如果是数字序号
    if echo "$backup_arg" | grep -q '^[0-9]\+$'; then
        backup_name=$(get_backup_by_index "$backup_arg")
        [ -z "$backup_name" ] && { echo "无效的序号: $backup_arg"; exit 1; }
        
        # 去除尾部的斜杠
        backup_name=$(echo "$backup_name" | sed 's:/$::')

        # 检查是本地还是网盘
        if [ -d "${BACKUP_DIR}/${backup_name}" ]; then
            echo "local"
        else
            echo "yun"
        fi
    else
        # 如果是完整路径
        if echo "$backup_arg" | grep -q "^${BACKUP_DIR}"; then
            echo "local"
        elif [ -f "$backup_arg" ] || [ -d "$backup_arg" ]; then
            echo "local"
        else
            # 检查是否是网盘备份
            if check_rclone_available && rclone lsf "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_arg}" >/dev/null 2>&1; then
                echo "yun"
            else
                echo "无法确定备份位置: $backup_arg"
                exit 1
            fi
        fi
    fi
}

# 函数: 检查并安装依赖
check_dependencies() {
    local dependencies="tar zstd pv rclone jq openssl xxd"
    local missing=""
    
    for dep in $dependencies; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing="$missing $dep"
        fi
    done
    
    # 额外检查 coreutils 中的常用命令
    for cmd in md5sum sha256sum dd stat; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    
    # 额外检查 findutils 中的 find 命令
    if ! command -v "find" >/dev/null 2>&1; then
        missing="$missing find"
    fi
    
    if [ -n "$missing" ]; then
        echo "缺少依赖: $missing"
        
        # ============================================================
        # Termux 检测（必须在其他系统检测之前）
        # ============================================================
        if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ] || [ -f "/data/data/com.termux/files/usr/bin/apt" ]; then
            echo "检测到 Termux 环境，使用 pkg 安装"
            pkg update -y && pkg upgrade -y pkg install zstd -y || {
                echo "警告: pkg update 失败，尝试继续安装..."
            }
            
            # Termux 特有的包名映射
            local termux_missing=""
            for dep in $missing; do
                case "$dep" in
                    tar)
                        termux_missing="$termux_missing tar" ;;
                    zstd)
                        termux_missing="$termux_missing zstd" ;;
                    pv)
                        termux_missing="$termux_missing pv" ;;
                    rclone)
                        termux_missing="$termux_missing rclone" ;;
                    jq)
                        termux_missing="$termux_missing jq" ;;
                    openssl)
                        termux_missing="$termux_missing openssl-tool" ;;  # Termux 中包名不同
                    xxd)
                        termux_missing="$termux_missing vim" ;;  # xxd 包含在 vim 包中
                    md5sum|sha256sum)
                        termux_missing="$termux_missing coreutils" ;;
                    dd)
                        termux_missing="$termux_missing coreutils" ;;
                    stat)
                        termux_missing="$termux_missing coreutils" ;;
                    find)
                        termux_missing="$termux_missing findutils" ;;
                    *)
                        termux_missing="$termux_missing $dep" ;;
                esac
            done
            
            # 去重
            termux_missing=$(echo "$termux_missing" | tr ' ' '\n' | sort -u | tr '\n' ' ')
            
            echo "安装 Termux 包: $termux_missing"
            pkg install -y $termux_missing || {
                echo "Termux 依赖安装失败! 请手动执行:"
                echo "  pkg install -y $termux_missing"
                exit 1
            }
            echo "Termux 依赖安装完成"
            #授予存储空间访问权限
            termux-setup-storage
            return 0
        
        # ============================================================
        # Alpine Linux
        # ============================================================
        elif [ -f /etc/alpine-release ]; then
            echo "检测到 Alpine 系统，使用 apk 安装"
            
            # Alpine 包名映射（某些包名可能不同）
            local alpine_missing=""
            for dep in $missing; do
                case "$dep" in
                    md5sum|sha256sum)
                        alpine_missing="$alpine_missing coreutils" ;;
                    xxd)
                        alpine_missing="$alpine_missing vim" ;;
                    *)
                        alpine_missing="$alpine_missing $dep" ;;
                esac
            done
            
            apk add --no-cache $alpine_missing || { 
                echo "依赖安装失败!"; 
                echo "请手动安装: apk add $alpine_missing"
                exit 1; 
            }
        
        # ============================================================
        # Debian/Ubuntu
        # ============================================================
        elif [ -f /etc/debian_version ]; then
            echo "检测到 Debian/Ubuntu 系统，使用 apt 安装"
            apt-get update -y
            
            # Debian/Ubuntu 包名映射
            local debian_missing=""
            for dep in $missing; do
                case "$dep" in
                    xxd)
                        debian_missing="$debian_missing xxd" ;;
                    md5sum|sha256sum|dd|stat)
                        debian_missing="$debian_missing coreutils" ;;
                    find)
                        debian_missing="$debian_missing findutils" ;;
                    *)
                        debian_missing="$debian_missing $dep" ;;
                esac
            done
            
            apt-get install -y $debian_missing 2>/dev/null || {
                apt-get install -y $missing coreutils findutils || { 
                    echo "依赖安装失败!"; 
                    exit 1; 
                }
            }
        
        # ============================================================
        # RHEL/CentOS/Fedora
        # ============================================================
        elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || [ -f /etc/fedora-release ]; then
            # Fedora 包名映射
            local rhel_missing=""
            for dep in $missing; do
                case "$dep" in
                    xxd)
                        rhel_missing="$rhel_missing vim-common" ;;
                    md5sum|sha256sum|dd|stat)
                        rhel_missing="$rhel_missing coreutils" ;;
                    find)
                        rhel_missing="$rhel_missing findutils" ;;
                    *)
                        rhel_missing="$rhel_missing $dep" ;;
                esac
            done
            
            if command -v dnf >/dev/null 2>&1; then
                echo "检测到 RHEL/CentOS/Fedora 系统，使用 dnf 安装"
                dnf install -y $rhel_missing || { 
                    echo "依赖安装失败!"; 
                    exit 1; 
                }
            else
                echo "检测到 RHEL/CentOS 系统，使用 yum 安装"
                yum install -y $rhel_missing || { 
                    echo "依赖安装失败!"; 
                    exit 1; 
                }
            fi
        
        # ============================================================
        # Arch Linux
        # ============================================================
        elif [ -f /etc/arch-release ]; then
            echo "检测到 Arch Linux 系统，使用 pacman 安装"
            
            # Arch 包名映射
            local arch_missing=""
            for dep in $missing; do
                case "$dep" in
                    xxd)
                        arch_missing="$arch_missing vim" ;;
                    md5sum|sha256sum|dd|stat)
                        arch_missing="$arch_missing coreutils" ;;
                    find)
                        arch_missing="$arch_missing findutils" ;;
                    *)
                        arch_missing="$arch_missing $dep" ;;
                esac
            done
            
            pacman -Sy --noconfirm $arch_missing || { 
                echo "依赖安装失败!"; 
                exit 1; 
            }
        
        # ============================================================
        # openSUSE
        # ============================================================
        elif [ -f /etc/SuSE-release ] || [ -f /etc/openSUSE-release ]; then
            echo "检测到 openSUSE 系统，使用 zypper 安装"
            
            local suse_missing=""
            for dep in $missing; do
                case "$dep" in
                    xxd)
                        suse_missing="$suse_missing vim" ;;
                    md5sum|sha256sum|dd|stat)
                        suse_missing="$suse_missing coreutils" ;;
                    find)
                        suse_missing="$suse_missing findutils" ;;
                    *)
                        suse_missing="$suse_missing $dep" ;;
                esac
            done
            
            zypper install -y $suse_missing || { 
                echo "依赖安装失败!"; 
                exit 1; 
            }
        
        # ============================================================
        # macOS (Homebrew)
        # ============================================================
        elif [ "$(uname)" = "Darwin" ]; then
            echo "检测到 macOS 系统"
            
            if command -v brew >/dev/null 2>&1; then
                echo "使用 Homebrew 安装依赖"
                brew install $missing || { 
                    echo "依赖安装失败!"; 
                    exit 1; 
                }
            else
                echo "未检测到 Homebrew，请先安装 Homebrew:"
                echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                echo "然后安装依赖:"
                echo "  brew install $missing"
                exit 1
            fi
        
        else
            echo "未知系统，请手动安装以下依赖: $missing"
            echo ""
            echo "常见系统的安装命令:"
            echo "  Termux:     pkg install $missing"
            echo "  Debian/Ubuntu: sudo apt install $missing"
            echo "  CentOS/RHEL:  sudo yum install $missing"
            echo "  Fedora:       sudo dnf install $missing"
            echo "  Arch:         sudo pacman -S $missing"
            echo "  Alpine:       sudo apk add $missing"
            echo "  macOS:        brew install $missing"
            exit 1
        fi
    fi
}

# 函数: 检查 rclone 是否已配置远程
check_rclone_config() {
    local config_file=""
    
    # 检查可能的配置文件位置
    if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
        config_file="$HOME/.config/rclone/rclone.conf"
    elif [ -f "/root/.config/rclone/rclone.conf" ]; then
        config_file="/root/.config/rclone/rclone.conf"
    fi
    
    if [ -z "$config_file" ]; then
        # 配置文件不存在，提示用户配置
        echo "[!] rclone 配置文件不存在"
        echo ">>> 10 秒内按 Enter 进入 rclone 配置向导，否则自动跳过并继续 <<<"

        if read -t 10 -p "" user_input; then
            echo "[*] 启动 rclone 配置向导..."
            rclone config
            echo "[+] rclone 配置完成"
            
            # 检查配置是否成功
            if check_rclone_available; then
                echo "[+] 网盘配置成功，网盘功能可用"
            else
                echo "[!] 警告: 网盘配置可能不完整，网盘功能不可用"
            fi
        else
            echo "[!] 超时未选择，跳过 rclone 配置，网盘功能不可用"
        fi
    else
        # 配置文件存在，检查是否有远程配置
        if check_rclone_available; then
            echo "[+] 已检测到 rclone 配置: ${RCLONE_REMOTE}"
        else
            echo "[!] 警告: rclone 配置文件存在但未配置远程 ${RCLONE_REMOTE}，网盘功能不可用"
        fi
    fi
}

# 新增：支持管道的分割函数（从stdin读取）
split_from_stdin() {
    local output_prefix="$1"
    local chunk_size="$2"
    local suffix="$3"
    
    local clean_prefix="${output_prefix%.aes}"
    
    # 清除可能存在的旧分割文件
    rm -f "${clean_prefix}."[0-9][0-9][0-9]"${suffix}"
    rm -f "${clean_prefix}${suffix}"
    
    # 使用 split 命令从 stdin 读取数据
    # 创建临时目录用于 --filter 输出
    local split_tmp_dir="${TEMP_DIR}/split_$$"
    mkdir -p "$split_tmp_dir"
    
    # split 从 stdin 读取，--filter 为每个分块执行命令
    # $FILE 是 split 内置变量，代表当前分块的文件名（不含后缀）
    split -b "$chunk_size" -d -a 3 --numeric-suffixes=1 \
        --filter="cat > ${split_tmp_dir}/\${FILE}${suffix}" \
        - "${clean_prefix##*/}."
    
    # 移动文件到目标位置
    local file_count=0
    for f in "${split_tmp_dir}/"*"${suffix}"; do
        [ -f "$f" ] || continue
        local base_name=$(basename "$f")
        mv "$f" "$(dirname "$clean_prefix")/${base_name}"
        file_count=$((file_count + 1))
    done
    rmdir "$split_tmp_dir" 2>/dev/null
    
    # 如果只有一个文件，重命名为单文件格式
    if [ "$file_count" -eq 1 ]; then
        local single_file=$(ls -1 "$(dirname "$clean_prefix")"/*"${suffix}" 2>/dev/null | head -1)
        # 已经是正确的命名格式，无需重命名
    fi
    
    echo "已分割为 ${file_count} 个文件"
    return 0
}


# 函数: 校验分割文件（带详细输出）
verify_split_files() {
    local backup_dir="$1"
    local backup_name="$2"
    
    echo "正在校验分割文件..."
    
    # 检查校验文件是否存在
    if [ ! -f "$backup_dir/checksums.md5" ]; then
        echo "警告: 找不到MD5校验文件，跳过MD5校验"
    else
        echo "正在进行MD5校验:"
        local md5_result_file=$(create_secure_tempfile)
        (cd "$backup_dir" && md5sum -c checksums.md5 2>/dev/null > "$md5_result_file")
        
        grep -E "(${SPLIT_SUFFIX})" "$md5_result_file" | \
        sort -V | \
        while read -r line; do
            local file=$(echo "$line" | awk -F: '{print $1}' | sed 's|^\./||;s|^\./\./||')
            local status=$(echo "$line" | cut -d: -f2-)
            printf "  %-40s %s\n" "$file" "$status"
        done
        
        if grep -q "FAILED" "$md5_result_file"; then
            rm -f "$md5_result_file"
            echo "错误: MD5校验失败"
            return 1
        fi
        rm -f "$md5_result_file"
    fi
    
    # SHA256校验
    if [ ! -f "$backup_dir/checksums.sha256" ]; then
        echo "警告: 找不到SHA256校验文件，跳过SHA256校验"
    else
        echo "正在进行SHA256校验:"
        local sha_result_file=$(create_secure_tempfile)
        (cd "$backup_dir" && sha256sum -c checksums.sha256 2>/dev/null > "$sha_result_file")
        
        grep -E "(${SPLIT_SUFFIX})" "$sha_result_file" | \
        sort -V | \
        while read -r line; do
            local file=$(echo "$line" | awk -F: '{print $1}' | sed 's|^\./||;s|^\./\./||')
            local status=$(echo "$line" | cut -d: -f2-)
            printf "  %-40s %s\n" "$file" "$status"
        done
        
        if grep -q "FAILED" "$sha_result_file"; then
            rm -f "$sha_result_file"
            echo "错误: SHA256校验失败"
            return 1
        fi
        rm -f "$sha_result_file"
    fi
    
    echo "所有分割文件校验通过"
    return 0
}

# 函数: 比较本地和远程文件差异
compare_and_download() {
    local remote_dir="$1"
    local local_dir="$2"
    
    # 获取远程文件列表
    remote_files=$(rclone lsf "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${remote_dir}" --files-only --format "p" 2>/dev/null)
    
    # 检查本地文件
    missing_files=""
    for file in $remote_files; do
        if [ ! -f "${local_dir}/${file}" ]; then
            missing_files="${missing_files} ${file}"
        fi
    done
    
    # 如果有缺失文件，只下载缺失的文件
    if [ -n "$missing_files" ]; then
        echo "发现 $(echo "$missing_files" | wc -w) 个文件需要下载..."
        for file in $missing_files; do
            echo "正在下载缺失文件: $file"
            rclone copy "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${remote_dir}/${file}" "$local_dir" \
            --user-agent "$USER_AGENT" 2>/dev/null || { echo "下载失败: $file"; return 1; }
        done
    else
        echo "所有文件已存在本地，无需下载"
    fi
    
    return 0
}

# ============================================================
# 函数: 备份流程（管道优化版 - 零中间文件，密码安全处理）
# ============================================================
perform_backup() {
    local target_dir="$1"
    local backup_name="${2:-${BACKUP_PREFIX}$(date +"%Y%m%d_%H%M%S")}"
    local upload_after_backup="${3:-false}"
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始备份流程 (密码: 已设置)"
    
    backup_folder="${BACKUP_DIR}/${backup_name}"
    mkdir -p "$backup_folder"
    
    # ============================================================
    # 管道模式：压缩 -> 加密 -> 分割（零中间文件）
    # 数据流: tar -> pv(可选) -> zstd -> openssl -> split -> 分片文件
    # 密码通过临时文件描述符传递，绝不进入管道数据流
    # ============================================================
    echo "正在执行 压缩 -> 加密 -> 分割..."
    echo "  目标: $target_dir"
    echo "  输出: $backup_folder"
    
    # 构建加密文件的基础名（用于分割函数的输出前缀）
    local enc_file_base="${backup_folder}/${backup_name}"
    local enc_file="${enc_file_base}.aes"
    
    # 使用增强的安全密码文件创建（优先使用 /dev/shm 内存文件系统）
    local password_file=""
    if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
        password_file=$(mktemp -p /dev/shm .backup_pass_XXXXXXXXXX) || {
            echo "错误: 无法在 /dev/shm 创建密码临时文件"
            return 1
        }
    else
        password_file=$(mktemp) || {
            echo "错误: 无法创建密码临时文件"
            return 1
        }
    fi
    
    # 原子化写入密码并设置严格权限
    (umask 077 && printf '%s' "$PASSWORD" > "$password_file") || {
        rm -f "$password_file"
        echo "错误: 写入密码文件失败"
        return 1
    }
    
    # 一条管道完成所有操作
    # 步骤1: tar 打包
    tar -cf - -C "$(dirname "$target_dir")" "$(basename "$target_dir")" \
        2>/dev/null | \
    # 步骤2: 可选的限速（pv）
    { command -v pv >/dev/null 2>&1 && pv -q -L "$COMPRESS_SPEED" 2>/dev/null || cat; } | \
    # 步骤3: zstd 压缩
    zstd -"$ZSTD_LEVEL" -q -c | \
    # 步骤4: openssl 加密（密码通过文件描述符传递，不进入数据流）
    openssl enc -${CIPHER_ALG} -pbkdf2 -iter ${PBKDF2_ITER} \
        -pass file:"$password_file" -e 2>/dev/null | \
    # 步骤5: 分割为分片文件
    split_from_stdin "$enc_file" "$SPLIT_SIZE" "$SPLIT_SUFFIX"
    
    # 检查管道执行状态（使用 PIPESTATUS 数组）
    local pipe_status=("${PIPESTATUS[@]}")
    
    # 立即安全销毁密码文件（多重覆写 + 删除）
    if [ -n "$password_file" ] && [ -f "$password_file" ]; then
        local pass_size=$(wc -c < "$password_file" 2>/dev/null || echo 256)
        # 用随机数据覆写
        dd if=/dev/urandom of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
        # 用零覆写
        dd if=/dev/zero of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
        # 强制同步（仅在非 tmpfs 时有效）
        [ "${password_file#/dev/shm}" = "$password_file" ] && sync 2>/dev/null
        rm -f "$password_file"
    fi
    
    # 检查各个阶段的退出码
    if [ "${pipe_status[0]}" -ne 0 ]; then
        echo "错误: tar 打包失败!"
        return 1
    fi
    
    if [ "${pipe_status[2]}" -ne 0 ]; then
        echo "错误: zstd 压缩失败!"
        return 1
    fi
    
    if [ "${pipe_status[3]}" -ne 0 ]; then
        echo "错误: openssl 加密失败!"
        return 1
    fi
    
    echo "备份流程完成"
    
    # ============================================================
    # 001文件头混淆（偏移量存储方案）
    # ============================================================
    if [ "$OBFUSCATE_HEADER" = "true" ]; then
        # 确定分片文件的前缀
        local clean_prefix="${enc_file%.aes}"
        local file_001="${clean_prefix}.001${SPLIT_SUFFIX}"
        
        if [ -f "$file_001" ]; then
            # 有分片，混淆001
            echo "[混淆] 检测到分片文件，正在混淆 001 文件头..."
            obfuscate_001_header "$file_001" || {
                echo "错误: 001文件头混淆失败!"
                return 1
            }
        else
            # 没有分片（文件小于分割大小），检查单文件
            local single_file="${clean_prefix}${SPLIT_SUFFIX}"
            if [ -f "$single_file" ]; then
                echo "[混淆] 文件未分割，直接混淆单文件头..."
                obfuscate_001_header "$single_file" || {
                    echo "错误: 单文件头混淆失败!"
                    return 1
                }
            else
                echo "警告: 未找到可混淆的文件"
            fi
        fi
        echo "[混淆] 文件头混淆处理完成"
    else
        echo "[混淆] 文件头混淆已禁用 (OBFUSCATE_HEADER=false)"
    fi
    
    # ============================================================
    # 校验文件（针对混淆后的文件生成校验和）
    # ============================================================
    echo "正在创建校验文件..."
    ( cd "$backup_folder" && \
      rm -f checksums.md5 checksums.sha256 && \
      for f in *; do
          [ "$f" != "checksums.md5" ] && [ "$f" != "checksums.sha256" ] && \
          md5sum "$f" >> checksums.md5 2>/dev/null
      done && \
      sha256sum * 2>/dev/null | grep -v checksums > checksums.sha256 ) || \
      { echo "创建校验文件失败!"; return 1; }
    
    echo "校验文件创建完成"
    
    # ============================================================
    # 复制脚本自身到备份目录
    # ============================================================
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    if [ -f "$script_path" ]; then
        cp "$script_path" "$backup_folder/" 2>/dev/null && \
            echo "[*] 已将备份脚本复制到备份目录" || \
            echo "[!] 复制备份脚本到备份目录失败"
    fi
    # ============================================================
	
    # ============================================================
    # 如果指定了上传，则上传到网盘
    # ============================================================
    if [ "$upload_after_backup" = "true" ]; then
        if check_rclone_available; then
            echo "正在上传到网盘..."
            rclone mkdir "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" 2>/dev/null && \
            rclone copy "$backup_folder" "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" \
                --user-agent "$USER_AGENT" 2>/dev/null || {
                echo "上传失败!"; return 1
            }
            echo "上传完成"
        else
            echo "[!] 跳过上传：网盘未配置"
        fi
    fi
    
    # ============================================================
    # 清理旧备份（仅清理带配置前缀的）
    # ============================================================
    echo "清理旧备份（保留最新${KEEP_LATEST}份，仅处理${BACKUP_PREFIX}前缀）..."
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "${BACKUP_PREFIX}*" | \
    grep -v "${backup_name}" | grep -v "$TEMP_DIR" | sort -r | \
    awk -v keep="$KEEP_LATEST" 'NR > keep {print $0}' | \
    while read -r dir; do rm -rf "$dir"; done

    # 网盘清理（仅在配置可用时）
    if check_rclone_available; then
        echo "清理网盘旧备份..."
        rclone lsd "${RCLONE_REMOTE}:${RCLONE_PATH}" 2>/dev/null | \
        awk '{print $5}' | grep "^${BACKUP_PREFIX}" | \
        grep -v "${backup_name}" | sort -r | \
        awk -v keep="$KEEP_LATEST" 'NR > keep {print $0}' | \
        while read -r dir; do 
            rclone purge "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${dir}" 2>/dev/null
        done
    fi
	
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 备份完成: ${backup_name}"
    echo "备份位置: ${backup_folder}"
    
    return 0
}

# 函数: 手动上传指定目录
manual_upload() {
    local dir_to_backup="$1"
    [ ! -d "$dir_to_backup" ] && { echo "目录不存在: $dir_to_backup"; exit 1; }
    
    # 检查网盘配置
    if ! check_rclone_available; then
        echo "错误: 网盘未配置，无法上传"
        echo "请先运行 'rclone config' 配置远程存储"
        exit 1
    fi
    
    echo "开始手动上传目录: $dir_to_backup (密码: 已设置)"
    
    # 使用目录名作为备份名
    local dir_name=$(basename "$dir_to_backup")
    timestamp=$(date +"%Y%m%d_%H%M%S")
    backup_name="${dir_name}_${timestamp}"
    
    echo "正在执行备份: $backup_name"
    perform_backup "$dir_to_backup" "$backup_name" "true" || exit 1
    echo "手动上传完成"
}

# 函数: 备份指定目录
backup_specific_directory() {
    local dir_to_backup="$1"
    local upload_after_backup="$2"
    [ ! -d "$dir_to_backup" ] && { echo "目录不存在: $dir_to_backup"; exit 1; }
    
    # 如果要求上传，检查网盘配置
    if [ "$upload_after_backup" = "true" ]; then
        if ! check_rclone_available; then
            echo "错误: 网盘未配置，无法上传"
            echo "请先运行 'rclone config' 配置远程存储"
            exit 1
        fi
    fi
    
    echo "开始备份指定目录: $dir_to_backup (密码: 已设置)"
    
    # 使用目录名作为备份名
    local dir_name=$(basename "$dir_to_backup")
    timestamp=$(date +"%Y%m%d_%H%M%S")
    backup_name="${dir_name}_${timestamp}"
    
    echo "正在执行备份: $backup_name"
    perform_backup "$dir_to_backup" "$backup_name" "$upload_after_backup" || exit 1
    echo "指定目录备份完成"
}

# 函数: 删除备份（支持序号和路径，带安全保护）
delete_backup() {
    local arg="$1"
    
    # 安全检查：防止路径穿越和空变量
    if [ -z "$arg" ] || \
       [[ "$arg" == *".."* ]]; then
        echo "错误: 参数包含不安全的字符: $arg"
        exit 1
    fi
    
    # ============================================================
    # 判断是数字序号还是路径
    # ============================================================
    if echo "$arg" | grep -q '^[0-9]\+$'; then
        # ---- 数字序号：走原有逻辑 ----
        backup_name=$(get_backup_by_index "$arg")
        [ -z "$backup_name" ] && { echo "无效的序号: $arg"; exit 1; }
        echo "通过序号 $arg 定位备份: $backup_name"
        
        if [ -d "${BACKUP_DIR}/${backup_name}" ]; then
            echo "正在删除本地备份: $backup_name"
            rm -rf "${BACKUP_DIR:?}/${backup_name}" || { echo "删除失败"; exit 1; }
            echo "本地备份删除成功"
        elif check_rclone_available; then
            echo "本地未找到，尝试删除网盘备份: $backup_name"
            rclone purge "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" 2>/dev/null || {
                echo "删除失败: 网盘中未找到 $backup_name"
                exit 1
            }
            echo "网盘备份删除成功"
        else
            echo "错误: 备份不存在且网盘未配置"
            exit 1
        fi
        
    elif [ -d "$arg" ]; then
        # ---- 目录路径：加多重安全检查 ----
        
        # 1. 禁止删除危险目录
        local dangerous_dirs="/ /root /home /etc /bin /sbin /usr /var /tmp /dev /proc /sys /storage /storage/emulated /storage/emulated/0 /data"
        for dangerous in $dangerous_dirs; do
            if [ "$(realpath "$arg" 2>/dev/null || echo "$arg")" = "$dangerous" ]; then
                echo "错误: 禁止删除系统关键目录: $arg"
                exit 1
            fi
        done
        
        # 2. 判断目录名是否符合备份格式
        local dir_name=$(basename "$arg")
        local is_backup_format=false
        if echo "$dir_name" | grep -qE "^(${BACKUP_PREFIX})?.*[0-9]{8}_[0-9]{6}"; then
            is_backup_format=true
        fi
        
        # 3. 非备份格式需要手动确认
        if [ "$is_backup_format" = false ]; then
            echo "========================================"
            echo "警告: 该目录不是标准备份格式"
            echo "  $arg"
            echo "========================================"
            echo -n "确认删除？请输入 yes 继续: "
            read -r confirm
            if [ "$confirm" != "yes" ]; then
                echo "已取消删除"
                exit 0
            fi
        fi
        
        # 执行删除
        echo "正在删除目录: $arg"
        rm -rf "${arg:?}" || { echo "删除失败"; exit 1; }
        echo "目录删除成功"
        
        # 如果网盘也有同名备份，询问是否一并删除
        if check_rclone_available; then
            if rclone lsf "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${dir_name}" >/dev/null 2>&1; then
                echo ""
                echo "网盘中存在同名备份: $dir_name"
                echo -n "是否一并删除网盘备份？(y/N): "
                read -r answer
                if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                    rclone purge "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${dir_name}" 2>/dev/null
                    echo "网盘备份已删除"
                else
                    echo "跳过网盘删除"
                fi
            fi
        fi
    else
        echo "错误: 无效的参数（需要数字序号或存在的目录路径）: $arg"
        exit 1
    fi
}

# ============================================================
# 函数: 还原流程（管道优化版 - 零中间文件，密码安全处理）
# ============================================================
perform_restore() {
    local backup_arg="$1"
    local restore_to="${2:-$RESTORE_DIR}"
    local _saved_password="${PASSWORD}"  # 立即保存密码，防止被意外清空
    
    # 自动判断备份位置
    local mode=$(determine_backup_location "$backup_arg")
    
    # 检查是否是数字序号
    if echo "$backup_arg" | grep -q '^[0-9]\+$'; then
        backup_name=$(get_backup_by_index "$backup_arg")
        [ -z "$backup_name" ] && { echo "无效的序号: $backup_arg"; exit 1; }
        echo "使用序号 $backup_arg 对应的备份: $backup_name"
    else
        backup_name="$backup_arg"
    fi
    
    # 创建恢复目录
    mkdir -p "$restore_to" || { echo "无法创建恢复目录: $restore_to"; exit 1; }
    
    if [ "$mode" = "yun" ]; then
        # 检查网盘配置
        if ! check_rclone_available; then
            echo "错误: 网盘未配置，无法从网盘还原"
            exit 1
        fi
        # 去除backup_name尾部的斜杠
        backup_name=$(echo "$backup_name" | sed 's:/$::')

        # 网盘还原模式
        backup_dir="${TEMP_DIR}/${backup_name}"
        backup_prefix="${backup_dir}/${backup_name}"
        
        echo "从网盘下载备份文件: ${backup_name} (密码: 已设置)"
        mkdir -p "$backup_dir"
        
        # 先检查本地是否已有部分文件
        if [ -d "$backup_dir" ] && [ "$(ls -1 "$backup_dir" 2>/dev/null | wc -l)" -gt 0 ]; then
            echo "发现本地已有部分文件，开始对比并下载缺失文件..."
            compare_and_download "$backup_name" "$backup_dir" || { echo "差异下载失败!"; exit 1; }
        else
            echo "正在从网盘下载备份文件..."
            rclone copy "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" "$backup_dir" \
            --user-agent "$USER_AGENT" 2>/dev/null || { echo "下载失败!"; exit 1; }
        fi
        
        # 检查分割文件
        if ! ls "${backup_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 && \
           [ ! -f "${backup_prefix}${SPLIT_SUFFIX}" ]; then
            backup_prefix="${backup_dir}/${backup_name}.aes"
            if ! ls "${backup_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 && \
               [ ! -f "${backup_prefix}${SPLIT_SUFFIX}" ]; then
                echo "找不到备份文件"; exit 1
            fi
            echo "检测到旧格式备份文件（含.aes）"
        fi
    else
        # 本地还原模式
        if echo "$backup_arg" | grep -q '^[0-9]\+$'; then
            backup_dir="${BACKUP_DIR}/${backup_name}"
            backup_prefix="${backup_dir}/${backup_name}"
            
        # 如果指定的是单文件备份，直接处理
        elif [ -f "$backup_arg" ] && echo "$backup_arg" | grep -q "${SPLIT_SUFFIX}$"; then
            local full_path="$(realpath "$backup_arg")"
            backup_dir="$(dirname "$full_path")"
            local filename="$(basename "$full_path")"
            
            # 检查是否是分片文件（如 .001.zip, .002.zip）
            if echo "$filename" | grep -qE '\.[0-9]{3}\.zip$'; then
                # 是分片文件，去掉 .xxx.zip 得到前缀
                backup_prefix="${full_path%.*.*}"
                backup_name="$(basename "$backup_prefix")"
                echo "检测到分片备份文件: $backup_name (从 $filename)"
            else
                # 是单文件（如 backup.zip），去掉 .zip 得到前缀
                backup_prefix="${full_path%${SPLIT_SUFFIX}}"
                backup_name="$(basename "$backup_prefix")"
                echo "检测到单文件备份: $backup_name"
            fi
        
        # 如果指定的是目录，自动查找目录内的备份前缀
        elif [ -d "$backup_arg" ]; then
            backup_dir="$backup_arg"
            # 查找目录内第一个 .001.zip 文件来确定前缀
            local first_part=$(ls -1 "$backup_dir"/*.001${SPLIT_SUFFIX} 2>/dev/null | head -1)
            if [ -n "$first_part" ]; then
                # 去掉 .001.zip 后缀得到前缀
                backup_prefix="${first_part%.001${SPLIT_SUFFIX}}"
                backup_name=$(basename "$backup_prefix")
                echo "检测到目录输入，自动定位备份前缀: $backup_name"
            else
                # 没有分片，检查单文件
                local single=$(ls -1 "$backup_dir"/*${SPLIT_SUFFIX} 2>/dev/null | head -1)
                if [ -n "$single" ]; then
                    backup_prefix="${single%${SPLIT_SUFFIX}}"
                    backup_name=$(basename "$backup_prefix")
                    echo "检测到目录输入，使用单文件备份: $backup_name"
                else
                    echo "错误: 目录内找不到备份文件 (${SPLIT_SUFFIX})"; exit 1
                fi
            fi
        else
            backup_prefix="$backup_arg"
            backup_dir=$(dirname "$backup_prefix")
            backup_name=$(basename "$backup_prefix" .aes)
            if [ "$backup_name" = "$(basename "$backup_prefix")" ]; then
                backup_name=$(basename "$backup_prefix")
            fi
        fi
        
        # 检查分割文件
        if ! ls "${backup_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 && \
           [ ! -f "${backup_prefix}${SPLIT_SUFFIX}" ]; then
            if [ "$backup_prefix" != "${backup_prefix}.aes" ]; then
                old_prefix="${backup_prefix}.aes"
                if ls "${old_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 || \
                   [ -f "${old_prefix}${SPLIT_SUFFIX}" ]; then
                    echo "检测到旧格式备份文件（含.aes），兼容处理中..."
                    backup_prefix="$old_prefix"
                else
                    echo "找不到备份文件"; exit 1
                fi
            else
                echo "找不到备份文件"; exit 1
            fi
        fi
    fi

    # ============================================================
    # 检查是否需要还原001文件头（决定是否跳过校验）
    # ============================================================
    local backup_prefix_noext="${backup_prefix%.aes}"
    
    local file_001=""
    [ -f "${backup_prefix_noext}.001${SPLIT_SUFFIX}" ] && file_001="${backup_prefix_noext}.001${SPLIT_SUFFIX}"
    [ -z "$file_001" ] && [ -f "${backup_prefix}.001${SPLIT_SUFFIX}" ] && file_001="${backup_prefix}.001${SPLIT_SUFFIX}"
    
    local need_restore=false
    if [ -n "$file_001" ] && [ -f "$file_001" ]; then
        if is_obfuscated "$file_001"; then
            need_restore=true
        fi
    else
        # 检查单文件情况
        local single_file=""
        [ -f "${backup_prefix_noext}${SPLIT_SUFFIX}" ] && single_file="${backup_prefix_noext}${SPLIT_SUFFIX}"
        [ -z "$single_file" ] && [ -f "${backup_prefix}${SPLIT_SUFFIX}" ] && single_file="${backup_prefix}${SPLIT_SUFFIX}"
        
        if [ -n "$single_file" ] && [ -f "$single_file" ] && is_obfuscated "$single_file"; then
            need_restore=true
        fi
    fi

    # ============================================================
    # 仅首次还原时校验（001仍是混淆状态，与生成校验和时一致）
    # ============================================================
    if [ "$need_restore" = true ]; then
        echo "[校验] 检测到001文件仍为混淆状态，执行完整性校验..."
        verify_split_files "$backup_dir" "$backup_name" || { echo "文件校验失败，无法继续还原"; exit 1; }
    else
        echo "[校验] 001文件已还原或无混淆，跳过校验"
    fi

    # ============================================================
    # 还原001文件头（仅在需要时）
    # ============================================================
    if [ "$need_restore" = true ] && [ -n "$file_001" ] && [ -f "$file_001" ]; then
        echo "[还原] 校验通过，正在还原001文件头..."
        restore_001_header "$file_001" || {
            echo "错误: 还原001文件头失败!"
            exit 1
        }
        echo "[还原] 001文件头还原完成"
    elif [ "$need_restore" = true ] && [ -n "$single_file" ] && [ -f "$single_file" ]; then
        echo "[还原] 校验通过，正在还原单文件头..."
        restore_001_header "$single_file" || {
            echo "错误: 还原文件头失败!"
            exit 1
        }
        echo "[还原] 单文件头还原完成"
    fi

    # ============================================================
    # 管道模式：合并 -> 解密 -> 解压（零中间文件）
    # 数据流: cat(分片) -> openssl(解密) -> zstd(解压) -> tar(提取)
    # 密码通过临时文件描述符传递，绝不进入管道数据流
    # ============================================================
    echo "正在执行 合并 -> 解密 -> 解压..."
    
    # 确定合并源（分片文件或单文件）
    local merge_prefix="$backup_prefix"
    [ ! -f "${merge_prefix}.001${SPLIT_SUFFIX}" ] && merge_prefix="$backup_prefix_noext"
    
    # 使用增强的安全密码文件创建（优先使用 /dev/shm 内存文件系统）
    local password_file=""
    if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
        password_file=$(mktemp -p /dev/shm .restore_pass_XXXXXXXXXX) || {
            echo "错误: 无法在 /dev/shm 创建密码临时文件"
            _saved_password=""
            exit 1
        }
    else
        password_file=$(mktemp) || {
            echo "错误: 无法创建密码临时文件"
            _saved_password=""
            exit 1
        }
    fi
    
    # 原子化写入密码并设置严格权限
    (umask 077 && printf '%s' "$_saved_password" > "$password_file") || {
        rm -f "$password_file"
        echo "错误: 写入密码文件失败"
        _saved_password=""
        exit 1
    }
    
    # 一条管道完成所有操作
    if ls "${merge_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1; then
        # 分片文件：先 cat 合并，再管道传递
        # 数据流: cat(分片) -> openssl(解密) -> zstd(解压) -> tar(提取)
        cat "${merge_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" | \
        openssl enc -d -${CIPHER_ALG} -pbkdf2 -iter ${PBKDF2_ITER} \
            -pass file:"$password_file" 2>/dev/null | \
        zstd -d -q -c | \
        tar -x --warning=no-timestamp -C "$restore_to" 2>/dev/null
        
        # 检查管道执行状态
        local pipe_status=("${PIPESTATUS[@]}")
        
        # 立即安全销毁密码文件（多重覆写 + 删除）
        if [ -n "$password_file" ] && [ -f "$password_file" ]; then
            local pass_size=$(wc -c < "$password_file" 2>/dev/null || echo 256)
            # 用随机数据覆写
            dd if=/dev/urandom of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
            # 用零覆写
            dd if=/dev/zero of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
            # 强制同步（仅在非 tmpfs 时有效）
            [ "${password_file#/dev/shm}" = "$password_file" ] && sync 2>/dev/null
            rm -f "$password_file"
        fi
        
        # cat 的退出码
        if [ "${pipe_status[0]}" -ne 0 ]; then
            echo "错误: 文件合并失败!"
            _saved_password=""
            exit 1
        fi
        # openssl 的退出码
        if [ "${pipe_status[1]}" -ne 0 ]; then
            echo "错误: 解密失败! 请检查密码是否正确。"
            _saved_password=""
            exit 1
        fi
        # zstd 的退出码
        if [ "${pipe_status[2]}" -ne 0 ]; then
            echo "错误: zstd 解压失败!"
            _saved_password=""
            exit 1
        fi
        # tar 的退出码
        if [ "${pipe_status[3]}" -ne 0 ]; then
            echo "错误: tar 解包失败!"
            _saved_password=""
            exit 1
        fi
        
    elif [ -f "${merge_prefix}${SPLIT_SUFFIX}" ]; then
        # 单文件：直接解密（使用已创建的 password_file）
        # 数据流: openssl(解密单文件) -> zstd(解压) -> tar(提取)
        openssl enc -d -${CIPHER_ALG} -pbkdf2 -iter ${PBKDF2_ITER} \
            -in "${merge_prefix}${SPLIT_SUFFIX}" -pass file:"$password_file" 2>/dev/null | \
        zstd -d -q -c | \
        tar -x --warning=no-timestamp -C "$restore_to" 2>/dev/null
        
        # 检查管道执行状态
        local pipe_status=("${PIPESTATUS[@]}")
        
        # 立即安全销毁密码文件（多重覆写 + 删除）
        if [ -n "$password_file" ] && [ -f "$password_file" ]; then
            local pass_size=$(wc -c < "$password_file" 2>/dev/null || echo 256)
            # 用随机数据覆写
            dd if=/dev/urandom of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
            # 用零覆写
            dd if=/dev/zero of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
            # 强制同步（仅在非 tmpfs 时有效）
            [ "${password_file#/dev/shm}" = "$password_file" ] && sync 2>/dev/null
            rm -f "$password_file"
        fi
        
        # openssl 的退出码
        if [ "${pipe_status[0]}" -ne 0 ]; then
            echo "错误: 解密失败! 请检查密码是否正确。"
            _saved_password=""
            exit 1
        fi
        # zstd 的退出码
        if [ "${pipe_status[1]}" -ne 0 ]; then
            echo "错误: zstd 解压失败!"
            _saved_password=""
            exit 1
        fi
        # tar 的退出码
        if [ "${pipe_status[2]}" -ne 0 ]; then
            echo "错误: tar 解包失败!"
            _saved_password=""
            exit 1
        fi
        
    else
        # 找不到备份文件，清理密码文件后退出
        if [ -n "$password_file" ] && [ -f "$password_file" ]; then
            local pass_size=$(wc -c < "$password_file" 2>/dev/null || echo 256)
            dd if=/dev/urandom of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
            dd if=/dev/zero of="$password_file" bs=1 count="$pass_size" conv=notrunc 2>/dev/null
            [ "${password_file#/dev/shm}" = "$password_file" ] && sync 2>/dev/null
            rm -f "$password_file"
        fi
        echo "找不到备份文件"
        _saved_password=""
        exit 1
    fi
    
    echo "还原流程完成，未产生中间文件"

    # 清理临时下载目录（仅网盘模式）
    [ "$mode" = "yun" ] && rm -rf "$backup_dir"

    # 安全清除局部密码副本（多重覆写）
    local pass_len=${#_saved_password}
    _saved_password=$(dd if=/dev/urandom bs=1 count="$pass_len" 2>/dev/null | base64 | tr -d '\n' | head -c "$pass_len")
    _saved_password=""
    unset _saved_password

    echo "还原成功! 文件已恢复到: $restore_to"
    
    return 0
}

# ============================================================
# 主程序
# ============================================================

# 首先处理密码参数
handle_password_option "$@"

# 使用临时文件处理参数
args_file=$(create_secure_tempfile)
while [ $# -gt 0 ]; do
    case "$1" in
        -pwd)
            shift
            ;;
        *)
            echo "$1" >> "$args_file"
            shift
            ;;
    esac
done
set -- $(cat "$args_file")
rm -f "$args_file"

check_dependencies
check_rclone_config

# 解析参数
while [ $# -gt 0 ]; do
    case "$1" in
        "")
            perform_backup "$TARGET_DIR" "" "$AUTO_UPLOAD"
            exit 0
            ;;
        -r)
            shift
            restore_arg=""
            restore_to="$RESTORE_DIR"
            
            [ $# -eq 0 ] && { echo "必须指定备份路径或序号"; show_usage; }
            restore_arg="$1"
            shift
            
            # 处理 -to 参数
            if [ "$1" = "-to" ]; then
                shift
                [ $# -eq 0 ] && { echo "必须指定恢复路径"; show_usage; }
                restore_to="$1"
                shift
            fi
            
            perform_restore "$restore_arg" "$restore_to"
            exit 0
            ;;
        -list)
            show_backup_list
            exit 0
            ;;
        -h|--help)
            show_examples
            exit 0
            ;;
        -up)
            shift
            if ! check_rclone_available; then
                echo "错误: 网盘未配置，无法上传"
                echo "请先运行 'rclone config' 配置远程存储"
                exit 1
            fi
            
            # ============================================================
            # 支持通过数字序号选择备份
            # ============================================================
            if [ $# -gt 0 ] && echo "$1" | grep -q '^[0-9]\+$'; then
                # 参数是数字，使用序号查找备份
                index="$1"
                shift
                
                echo "通过序号 $index 查找备份..."
                
                # 获取备份名称
                backup_name=$(get_backup_by_index "$index")
                if [ -z "$backup_name" ]; then
                    echo "错误: 无效的序号: $index"
                    echo "使用 -list 查看可用备份列表"
                    exit 1
                fi
                
                # 判断是本地还是网盘备份
                if [ -d "${BACKUP_DIR}/${backup_name}" ]; then
                    dir_to_upload="${BACKUP_DIR}/${backup_name}"
                    echo "找到本地备份: $dir_to_upload"
                else
                    echo "错误: 序号 $index 对应的是网盘备份 ($backup_name)，已在网盘中，无需上传"
                    echo "本地备份路径: ${BACKUP_DIR}/${backup_name} (不存在)"
                    exit 1
                fi
            elif [ $# -gt 0 ] && [ -d "$1" ]; then
                # 参数是有效的目录路径
                dir_to_upload="$1"
                shift
                echo "使用指定目录: $dir_to_upload"
            else
                # 没有指定或无效，自动查找最新备份
                if [ $# -gt 0 ]; then
                    echo "警告: '$1' 不是有效的目录或数字序号"
                    shift
                fi
                echo "未指定有效参数，自动查找最新本地备份..."
                
                latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "${BACKUP_PREFIX}*" | grep -v "$TEMP_DIR" | sort -r | head -n 1)
                
                if [ -z "$latest_backup" ]; then
                    echo "错误: 找不到可用的备份目录"
                    echo ""
                    echo "用法:"
                    echo "  $0 -up [序号]        通过序号选择备份上传"
                    echo "  $0 -up [目录路径]    通过路径指定备份上传"
                    echo "  $0 -up              自动上传最新备份"
                    echo ""
                    echo "示例:"
                    echo "  $0 -up 1             上传序号1的本地备份"
                    echo "  $0 -up /backups/特殊图片和视频_20260503_131314"
                    echo "  $0 -list             查看所有备份及序号"
                    exit 1
                fi
                dir_to_upload="$latest_backup"
                echo "找到最新备份: $dir_to_upload"
            fi
            
            # ============================================================
            # 验证并上传
            # ============================================================
            if [ ! -d "$dir_to_upload" ]; then
                echo "错误: 备份目录不存在: $dir_to_upload"
                exit 1
            fi
            
            backup_name=$(basename "$dir_to_upload")
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始上传备份: $backup_name"
            
            # 检查目录是否为空
            if [ -z "$(ls -A "$dir_to_upload" 2>/dev/null)" ]; then
                echo "错误: 备份目录为空: $dir_to_upload"
                exit 1
            fi
            
            # 显示目录内容概览
            echo "目录内容:"
            ls -lh "$dir_to_upload" | head -10
            if [ "$(ls -1 "$dir_to_upload" | wc -l)" -gt 10 ]; then
                echo "... 还有 $(($(ls -1 "$dir_to_upload" | wc -l) - 10)) 个文件"
            fi
            
            # 上传到网盘
            echo "正在上传到网盘..."
            if rclone mkdir "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" 2>/dev/null; then
                echo "创建远程目录成功"
            fi
            
            if rclone copy "$dir_to_upload" "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" \
                --progress \
                --user-agent "$USER_AGENT" 2>/dev/null; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 上传完成: ${backup_name}"
            else
                echo "上传失败!"
                exit 1
            fi
            exit 0
            ;;
        -del)
            shift
            [ $# -eq 0 ] && { echo "必须指定序号或路径"; show_usage; }
            delete_backup "$1"
            exit 0
            ;;
        -sd)
            shift
            [ $# -eq 0 ] && { echo "必须指定目录路径"; show_usage; }
            dir_to_backup="$1"
            shift
            
            upload_after_backup="false"
            custom_backup_dir=""
            
            # 处理 -to 和 -up 参数
            while [ $# -gt 0 ]; do
                case "$1" in
                    -to)
                        shift
                        [ $# -eq 0 ] && { echo "必须指定备份输出目录"; show_usage; }
                        custom_backup_dir="$1"
                        shift
                        ;;
                    -up)
                        upload_after_backup="true"
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            # 如果指定了输出目录，临时覆盖 BACKUP_DIR
            if [ -n "$custom_backup_dir" ]; then
                ORIG_BACKUP_DIR="$BACKUP_DIR"
                BACKUP_DIR="$custom_backup_dir"
                backup_specific_directory "$dir_to_backup" "$upload_after_backup"
                BACKUP_DIR="$ORIG_BACKUP_DIR"
            else
                backup_specific_directory "$dir_to_backup" "$upload_after_backup"
            fi
            exit 0
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
done

# 默认执行备份
perform_backup "$TARGET_DIR" "" "$AUTO_UPLOAD"
