#!/system/bin/sh
#===============================================================================
# 手机全分区备份脚本 (支持A/B分区) - 兼容版
# # 备份所有分区（包括两个槽位）
# su -c sh ab_backup.sh

# 仅备份当前活动槽位
# su -c sh ab_backup.sh -s

# 备份当前槽位，不包含data
# su -c sh ab_backup.sh -s -d
#===============================================================================

# 颜色定义 - 使用echo -e替代
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置参数
BACKUP_DIR="/sdcard/Full_Backup_$(date +%Y%m%d_%H%M%S)"
INCLUDE_DATA=true
COMPRESS_BACKUP=false
BACKUP_CURRENT_SLOT_ONLY=false

# 系统信息
SLOT_SUFFIX=$(getprop ro.boot.slot_suffix 2>/dev/null)
CURRENT_SLOT=$(getprop ro.boot.slot 2>/dev/null)
IS_AB_DEVICE=false

# SHA256 命令
SHA256_CMD=""

# 打印函数 - 使用printf替代echo -e
print_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

print_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

print_header() {
    printf "${BLUE}========================================${NC}\n"
    printf "${BLUE}%s${NC}\n" "$1"
    printf "${BLUE}========================================${NC}\n"
}

# 检测可用的 sha256 工具
detect_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        SHA256_CMD="sha256sum"
    elif command -v busybox >/dev/null 2>&1 && busybox sha256sum --help >/dev/null 2>&1; then
        SHA256_CMD="busybox sha256sum"
    else
        print_warn "未找到 sha256sum 或 busybox sha256sum，将不生成校验文件"
        SHA256_CMD=""
    fi
}

# 计算并记录 SHA256
record_sha256() {
    local file="$1"
    if [ -n "$SHA256_CMD" ] && [ -f "$file" ]; then
        $SHA256_CMD "$file" >> "$BACKUP_DIR/sha256.txt"
    fi
}

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error "此脚本需要root权限运行！"
        print_info "请使用: su -c sh $0"
        exit 1
    fi
}

# 检查是否应该跳过该分区
should_skip_partition() {
    local partition=$1
    
    # 跳过所有sd开头后跟单个字母的设备（sda, sdb, sdc...）
    if echo "$partition" | grep -q '^sd[a-z]$'; then
        return 0
    fi
    
    # 跳过mmcblk开头的整个磁盘设备（不带p后缀的）
    if echo "$partition" | grep -q '^mmcblk[0-9]$'; then
        return 0
    fi
    
    # 跳过loop设备
    if echo "$partition" | grep -q '^loop[0-9]'; then
        return 0
    fi
    
    # 跳过ram设备
    if echo "$partition" | grep -q '^ram[0-9]'; then
        return 0
    fi
    
    # 跳过zram设备
    if echo "$partition" | grep -q '^zram[0-9]'; then
        return 0
    fi
    
    return 1
}

# 获取分区大小
get_partition_size() {
    local partition=$1
    if [ -e "/dev/block/by-name/$partition" ]; then
        blockdev --getsize64 "/dev/block/by-name/$partition" 2>/dev/null
    else
        echo "0"
    fi
}

# 检测是否为A/B设备
check_ab_device() {
    if [ -n "$SLOT_SUFFIX" ]; then
        IS_AB_DEVICE=true
        print_info "检测到A/B分区设备"
        print_info "当前活动槽位: $CURRENT_SLOT ($SLOT_SUFFIX)"
    elif [ -d "/dev/block/by-name" ]; then
        if ls /dev/block/by-name/ 2>/dev/null | grep -q '_a$' || ls /dev/block/by-name/ 2>/dev/null | grep -q '_b$'; then
            IS_AB_DEVICE=true
            if [ -z "$CURRENT_SLOT" ]; then
                CURRENT_SLOT=$(getprop ro.boot.slot_suffix | sed 's/_//')
            fi
            print_info "检测到A/B分区设备（通过分区名）"
        fi
    fi
    
    if [ "$IS_AB_DEVICE" = false ]; then
        print_info "这是传统单分区设备"
    fi
}

# 备份单个分区
backup_partition() {
    local partition=$1
    local output_file="$BACKUP_DIR/${partition}.img"
    local size
    
    if [ ! -e "/dev/block/by-name/$partition" ]; then
        print_warn "分区 $partition 不存在，跳过"
        return 1
    fi
    
    size=$(get_partition_size "$partition")
    if [ "$size" = "0" ]; then
        print_warn "无法获取分区 $partition 大小，跳过"
        return 1
    fi
    
    print_info "正在备份 $partition ($((size/1024/1024))MB)..."
    
    if dd if="/dev/block/by-name/$partition" of="$output_file" bs=4M 2>/dev/null; then
        local backup_size
        backup_size=$(stat -c%s "$output_file" 2>/dev/null)
        if [ "$backup_size" = "$size" ]; then
            print_info "$partition 备份完成"
            echo "$partition:$size:$output_file" >> "$BACKUP_DIR/backup_manifest.txt"
            # 记录 SHA256
            record_sha256 "$output_file"
            return 0
        else
            print_error "$partition 备份验证失败"
            rm -f "$output_file"
            return 1
        fi
    else
        print_error "$partition 备份失败"
        rm -f "$output_file"
        return 1
    fi
}

# 获取所有分区
get_all_partitions() {
    if [ -d "/dev/block/by-name" ]; then
        if [ "$BACKUP_CURRENT_SLOT_ONLY" = true ] && [ "$IS_AB_DEVICE" = true ]; then
            print_info "仅备份当前槽位 ($SLOT_SUFFIX) 分区"
            ls /dev/block/by-name/ 2>/dev/null | while read -r part; do
                case "$part" in
                    *_a|*_b)
                        if echo "$part" | grep -q "${SLOT_SUFFIX}$"; then
                            echo "$part"
                        fi
                        ;;
                    *)
                        echo "$part"
                        ;;
                esac
            done
        else
            ls /dev/block/by-name/ 2>/dev/null
        fi
    fi
}

# 显示A/B分区状态
show_ab_status() {
    print_header "A/B分区状态"
    
    if [ "$IS_AB_DEVICE" = true ]; then
        print_info "当前活动槽位: $SLOT_SUFFIX"
        
        for base in boot system vendor product; do
            local info=""
            if [ -e "/dev/block/by-name/${base}_a" ]; then
                local size_a
                size_a=$(get_partition_size "${base}_a")
                info="  A槽: $((size_a/1024/1024))MB"
            fi
            if [ -e "/dev/block/by-name/${base}_b" ]; then
                local size_b
                size_b=$(get_partition_size "${base}_b")
                info="$info  B槽: $((size_b/1024/1024))MB"
            fi
            if [ -n "$info" ]; then
                local status=""
                if [ -e "/dev/block/by-name/${base}${SLOT_SUFFIX}" ]; then
                    status=" [活动]"
                fi
                print_info "${base}:$info$status"
            fi
        done
        
        if [ "$CURRENT_SLOT" = "a" ] || [ "$SLOT_SUFFIX" = "_a" ]; then
            print_warn "非活动槽位: _b (备份后可保留备用)"
        else
            print_warn "非活动槽位: _a (备份后可保留备用)"
        fi
    else
        print_info "非A/B设备"
    fi
}

# 备份data分区（使用tar方式）
backup_data_tar() {
    print_info "正在使用tar方式备份data重要数据..."
    local output_file="$BACKUP_DIR/data_backup.tar.gz"
    
    local backup_dirs="/data/app /data/data /data/system /data/misc"
    local dirs_to_backup=""
    for dir in $backup_dirs; do
        if [ -d "$dir" ]; then
            dirs_to_backup="$dirs_to_backup $dir"
        fi
    done
    
    if [ -z "$dirs_to_backup" ]; then
        print_warn "没有找到可备份的data目录"
        return 1
    fi
    
    if tar -czf "$output_file" $dirs_to_backup 2>/dev/null; then
        local backup_size
        backup_size=$(stat -c%s "$output_file" 2>/dev/null)
        print_info "Data tar备份完成 ($((backup_size/1024/1024))MB)"
        echo "data_tar:$backup_size:$output_file" >> "$BACKUP_DIR/backup_manifest.txt"
        # 记录 SHA256
        record_sha256 "$output_file"
        return 0
    else
        print_error "Data tar备份失败"
        return 1
    fi
}

# 生成恢复脚本
generate_restore_script() {
    cat > "$BACKUP_DIR/restore.sh" << 'RESTORE_SCRIPT'
#!/system/bin/sh
# 自动生成的恢复脚本

echo "==========================================="
echo "  分区恢复脚本"
echo "==========================================="

CURRENT_SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
if [ -n "$CURRENT_SLOT" ]; then
    echo "当前活动槽位: $CURRENT_SLOT"
    echo ""
    echo "恢复选项："
    echo "  1) 恢复到当前槽位"
    echo "  2) 恢复所有分区"
    echo "  0) 取消"
    echo ""
    read -p "请选择 [1/2]: " choice
    
    case $choice in
        1)
            echo "恢复到当前槽位 $CURRENT_SLOT..."
            SLOT_FILTER="$CURRENT_SLOT"
            ;;
        2)
            echo "恢复所有分区..."
            SLOT_FILTER=""
            ;;
        *)
            echo "恢复取消"
            exit 0
            ;;
    esac
fi

echo "警告: 此操作将覆盖分区数据！"
read -p "输入 YES 确认: " confirm
if [ "$confirm" != "YES" ]; then
    echo "恢复取消"
    exit 0
fi

BACKUP_DIR="$(dirname $0)"

while IFS=':' read -r partition size file; do
    if echo "$partition" | grep -q '^#'; then
        continue
    fi
    if echo "$partition" | grep -q '_tar$'; then
        continue
    fi
    if [ -n "$SLOT_FILTER" ]; then
        if echo "$partition" | grep -qE '_(a|b)$'; then
            if ! echo "$partition" | grep -q "${SLOT_FILTER}$"; then
                echo "跳过 $partition (不在目标槽位)"
                continue
            fi
        fi
    fi
    
    echo "恢复 $partition..."
    dd if="$file" of="/dev/block/by-name/$partition" bs=4M
    
    if [ $? -eq 0 ]; then
        echo "  ✓ $partition 恢复完成"
    else
        echo "  ✗ $partition 恢复失败!"
    fi
done < "$BACKUP_DIR/backup_manifest.txt"

echo "恢复完成！建议重启设备。"
RESTORE_SCRIPT
    
    chmod +x "$BACKUP_DIR/restore.sh"
}

# 显示使用说明
show_usage() {
    print_header "手机全分区备份脚本 (A/B设备支持)"
    echo "用法: sh $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -d, --no-data        不备份data分区"
    echo "  -s, --current-slot   仅备份当前活动槽位"
    echo "  -t, --tar-data       使用tar方式备份data"
    echo "  -o, --output DIR     指定备份目录"
    echo "  -l, --list           列出所有分区及槽位信息"
    echo "  -h, --help           显示此帮助"
    echo ""
    echo "示例:"
    echo "  sh $0               # 备份所有分区(包含data，跳过sda等)"
    echo "  sh $0 -d            # 不备份data分区"
    echo "  sh $0 -s -d         # 仅备份当前槽位系统分区"
    echo "  sh $0 -l            # 查看分区信息"
}

# 主函数
main() {
    print_header "手机全分区备份工具 (A/B支持)"
    
    check_root
    check_ab_device
    detect_sha256   # 检测 sha256 工具
    
    # 解析参数
    while [ $# -gt 0 ]; do
        case $1 in
            -d|--no-data)
                INCLUDE_DATA=false
                shift
                ;;
            -s|--current-slot)
                BACKUP_CURRENT_SLOT_ONLY=true
                shift
                ;;
            -t|--tar-data)
                USE_TAR_DATA=true
                shift
                ;;
            -o|--output)
                BACKUP_DIR="$2"
                shift 2
                ;;
            -l|--list)
                show_ab_status
                print_header "所有分区列表"
                get_all_partitions | while read -r part; do
                    if should_skip_partition "$part"; then
                        echo "  [跳过] $part"
                    else
                        echo "  $part"
                    fi
                done
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    show_ab_status
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "无法创建备份目录: $BACKUP_DIR"
        exit 1
    fi
    
    # 初始化 SHA256 文件头部
    if [ -n "$SHA256_CMD" ]; then
        echo "# SHA256 checksums of backup files" > "$BACKUP_DIR/sha256.txt"
        echo "# Generated on $(date)" >> "$BACKUP_DIR/sha256.txt"
    fi
    
    # 记录设备信息
    echo "设备型号: $(getprop ro.product.model)" > "$BACKUP_DIR/device_info.txt"
    echo "Android版本: $(getprop ro.build.version.release)" >> "$BACKUP_DIR/device_info.txt"
    echo "编译版本: $(getprop ro.build.display.id)" >> "$BACKUP_DIR/device_info.txt"
    echo "A/B设备: $IS_AB_DEVICE" >> "$BACKUP_DIR/device_info.txt"
    echo "当前槽位: $CURRENT_SLOT ($SLOT_SUFFIX)" >> "$BACKUP_DIR/device_info.txt"
    echo "备份时间: $(date)" >> "$BACKUP_DIR/device_info.txt"
    
    # 初始化清单文件
    echo "# 分区备份清单" > "$BACKUP_DIR/backup_manifest.txt"
    echo "# 格式: 分区名:大小(字节):文件路径" >> "$BACKUP_DIR/backup_manifest.txt"
    
    # 获取所有分区
    print_info "正在获取分区列表..."
    local partitions=$(get_all_partitions)
    local total_partitions=$(echo "$partitions" | wc -l)
    
    print_info "发现 $total_partitions 个分区"
    
    local current=0
    local success=0
    local failed=0
    local skipped=0
    
    for partition in $partitions; do
        current=$((current + 1))
        
        if should_skip_partition "$partition"; then
            print_info "[$current/$total_partitions] 跳过 $partition (在跳过列表中)"
            skipped=$((skipped + 1))
            continue
        fi
        
        if [ "$partition" = "userdata" ] || [ "$partition" = "data" ]; then
            if [ "$INCLUDE_DATA" = false ]; then
                print_info "[$current/$total_partitions] 跳过data分区"
                skipped=$((skipped + 1))
                continue
            fi
            
            if [ "$USE_TAR_DATA" = true ]; then
                print_info "[$current/$total_partitions] 使用tar备份data"
                if backup_data_tar; then
                    success=$((success + 1))
                else
                    failed=$((failed + 1))
                fi
                continue
            fi
        fi
        
        print_info "[$current/$total_partitions] 备份 $partition"
        if backup_partition "$partition"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    generate_restore_script
    
    # 打印摘要
    print_header "备份完成"
    print_info "备份目录: $BACKUP_DIR"
    print_info "备份大小: $(du -sh $BACKUP_DIR | cut -f1)"
    print_info "成功: $success 个分区"
    print_info "失败: $failed 个分区"
    print_info "跳过: $skipped 个分区"
    if [ -n "$SHA256_CMD" ]; then
        print_info "校验文件: $BACKUP_DIR/sha256.txt"
    else
        print_warn "未生成校验文件（缺少 sha256sum）"
    fi
    print_info "设备信息: $BACKUP_DIR/device_info.txt"
    print_info "恢复脚本: $BACKUP_DIR/restore.sh"
    
    if [ "$IS_AB_DEVICE" = true ]; then
        print_warn "A/B设备注意事项："
        echo "  1. 恢复时请确认目标槽位"
        echo "  2. 跨槽位恢复可能导致系统无法启动"
        echo "  3. 建议保留非活动槽位的备份"
    fi
}

main "$@"