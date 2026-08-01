#!/bin/bash

wifiname="配置WiFi"
wifipasswd="12345678"
bridge='/etc/NetworkManager/system-connections/bridge.nmconnection'

function menu()
{
cat <<eof
    *************************************
                    菜单                 

                1.切换运行模式

                2.修改wifi热点名称&密码
            
                0.退出


    *************************************
eof
}
function num()
{
    read -p "请输入您需要操作的项目: " number
    case $number in
        1)
            swichmodel
            ;;
        2)
            change
            ;;
        0)
            exit 0
            ;;

    esac
}

function change()
{
read -p "请输入要修改的WIFI名称:" wifiname
read -p "请输入要修改的WIFI密码:" wifipasswd

if [ -f "$bridge" ];then
    echo "当前是随身WIFI模式，正在修改中，稍后会自动重启设备......"
    wifimodel
elif [ -f "/etc/NetworkManager/system-connections/upstream.nmconnection" ];then
    echo "当前是WiFi中继模式，正在修改中，稍后会自动重启设备......"
    repeatermodel
else
    echo "当前模式未知，默认切换到随身WIFI模式......"
    wifimodel
fi
}

function swichmodel()
{
cat <<eof
    *************************************
                请选择运行模式                 

            1.随身WIFI模式(开启WIFI热点和USB共享，不启动遥控车程序)
            
            2.WiFi中继模式(连接上游WiFi并广播新热点)
            
            0.退出


    *************************************
eof
read -p "请输入您需要操作的项目: " number
    case $number in
        1)
            wifimodel
            ;;
        2)
            repeatermodel
            ;;
        0)
            exit 0
            ;;
    esac
}


function wifimodel(){
    # 完全停止NetworkManager服务，避免连接缓存问题
    echo "正在停止网络服务..."
    systemctl stop NetworkManager
    sleep 3
    
    #1.切换usb模式
    sed -i '6c #echo host > /sys/kernel/debug/usb/ci_hdrc.0/role' /usr/sbin/mobian-usb-gadget
   
    #2. 彻底清理所有网络连接配置和状态
    echo "清理旧配置..."
    rm -rf /etc/NetworkManager/system-connections/*.nmconnection
    rm -rf /var/lib/NetworkManager/*.state
    rm -rf /var/run/NetworkManager/*.pid
    
    bridge=$(cat <<- EOF
[connection]
id=bridge
uuid=0332def0-cc09-4509-9929-97c92d4f4b7b
type=bridge
interface-name=nm-bridge
permissions=
autoconnect=yes

[bridge]

[ipv4]
address1=192.168.68.1/24
dns-search=
method=manual

[ipv6]
addr-gen-mode=stable-privacy
dns-search=
method=auto

[proxy]
EOF
)

    wifi=$(cat <<- EOF
[connection]
id=wifi
uuid=46e2a2e7-2e43-4f61-9269-cf740351f557
type=wifi
interface-name=wlan0
master=0332def0-cc09-4509-9929-97c92d4f4b7b
permissions=
slave-type=bridge
autoconnect=yes

[wifi]
band=bg
channel=8
mac-address-blacklist=
mode=ap
ssid=${wifiname}

[wifi-security]
key-mgmt=wpa-psk
psk=${wifipasswd}

[bridge-port]
EOF
)

    usb=$(cat <<- EOF
[connection]
id=usb
uuid=fa0ad694-a11a-46bd-9417-0b66ea105cbc
type=ethernet
interface-name=usb0
master=0332def0-cc09-4509-9929-97c92d4f4b7b
permissions=
slave-type=bridge
autoconnect=yes

[ethernet]
mac-address-blacklist=

[bridge-port]
EOF
)

    start=$(cat <<- 'EOF'
#!/bin/sh -e
# 等待系统完全启动
sleep 5

# 解除WiFi软屏蔽
rfkill unblock wifi
sleep 2

# 重启NetworkManager以确保clean状态
systemctl restart NetworkManager
sleep 5

# 连接USB网络
nmcli connection up USB
sleep 5
nmcli connection down USB
exit 0
EOF
)

    # 写入配置文件
    echo "${bridge}" > /etc/NetworkManager/system-connections/bridge.nmconnection
    echo "${wifi}" > /etc/NetworkManager/system-connections/wifi.nmconnection
    echo "${usb}" > /etc/NetworkManager/system-connections/usb.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/bridge.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/wifi.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/usb.nmconnection
    
    # 清理可能的wifi缓存
    rm -rf /var/lib/NetworkManager/wifi*
    
    echo "${start}" > /etc/rc.local
    chmod +x /etc/rc.local
    
    echo "修改完成，WIFI热点名称：${wifiname}，密码：${wifipasswd}"
    echo "设备重启中......"
    
    # 同步文件系统，确保配置写入磁盘
    sync
    reboot
}

function repeatermodel(){
    
    upstream_ssid="L" # 上游WiFi名称（需要中继的目标网络）
    upstream_passwd="1a2b3c4d"  # 如果上游WiFi有密码请填写
    
    # 完全停止NetworkManager服务
    echo "正在停止网络服务..."
    systemctl stop NetworkManager
    sleep 3
    
    #1.切换usb模式
    sed -i '6c echo host > /sys/kernel/debug/usb/ci_hdrc.0/role' /usr/sbin/mobian-usb-gadget
    
    #2. 彻底清理所有网络连接配置和状态
    echo "清理旧配置..."
    rm -rf /etc/NetworkManager/system-connections/*.nmconnection
    rm -rf /var/lib/NetworkManager/*.state
    rm -rf /var/run/NetworkManager/*.pid
    
    # 清理wifi相关的临时文件和扫描结果
    rm -rf /var/lib/NetworkManager/wifi*
    rm -rf /var/lib/NetworkManager/seen-bssids*
    rm -rf /var/lib/NetworkManager/timestamps*
    
    # 上游客户端连接配置（连接上游路由器）
    upstream=$(cat <<- EOF
[connection]
id=upstream
uuid=a1b2c3d4-5678-9012-3456-789abcdef012
type=wifi
interface-name=wlan0
permissions=
autoconnect=yes
autoconnect-priority=10

[wifi]
mode=infrastructure
ssid=${upstream_ssid}
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=${upstream_passwd}

[ipv4]
method=auto
route-metric=100

[ipv6]
method=auto
route-metric=100
EOF
)

    # AP热点配置（下游手机/设备连接）
    ap=$(cat <<- EOF
[connection]
id=wifi-ap
uuid=d4e61c73-514a-44ee-b395-99fcbbce8218
type=wifi
interface-name=wlan0
permissions=
autoconnect=yes
autoconnect-priority=5

[wifi]
mac-address-blacklist=
mode=ap
ssid=${wifiname}
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=${wifipasswd}

[ipv4]
address1=192.168.68.1/24
method=manual

[ipv6]
addr-gen-mode=stable-privacy
method=auto

[proxy]
EOF
)

    # 开机启动脚本，包含多次重试和完整回退机制
    start=$(cat <<- 'EOF'
#!/bin/sh -e

# 日志函数
log_file="/dev/null"
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $log_file
}

log_msg "系统启动，开始中继模式检测"

# 等待系统完全启动
sleep 5

# 关闭红色系统灯
echo none > /sys/class/leds/red:os/trigger
echo 0 > /sys/class/leds/red:os/brightness

# 解除WiFi软屏蔽
rfkill unblock wifi
sleep 3

# 开启IP转发
echo 1 > /proc/sys/net/ipv4/ip_forward

# 重启NetworkManager以确保clean状态
systemctl restart NetworkManager
sleep 10

log_msg "开始连接上游WiFi"
# 先连接上游WiFi
nmcli connection up upstream
sleep 15

# 检查上游连接状态
max_retries=3
retry_count=1
connected=false

while [ $retry_count -le $max_retries ]; do
    log_msg "检查上游连接 (尝试 $retry_count/$max_retries)"
    
    # 多种方式检查连接状态
    conn_state=$(nmcli -t -f GENERAL.STATE connection show upstream 2>/dev/null)
    if [ "$conn_state" = "activated" ]; then
        # 尝试获取网关
        sleep 5
        gateway=$(ip route | grep default | grep wlan0 | awk '{print $3}')
        if [ -n "$gateway" ] && ping -c 3 -W 3 $gateway >/dev/null 2>&1; then
            log_msg "上游WiFi连接成功，网关: $gateway"
            connected=true
            break
        fi
    fi
    
    log_msg "上游WiFi连接失败 (尝试 $retry_count/$max_retries)"
    
    if [ $retry_count -lt $max_retries ]; then
        log_msg "重新尝试连接上游WiFi..."
        # 完全重置连接
        nmcli connection down upstream 2>/dev/null
        nmcli device disconnect wlan0 2>/dev/null
        sleep 3
        nmcli device wifi rescan
        sleep 3
        nmcli connection up upstream
        sleep 15
    fi
    
    retry_count=$((retry_count+1))
done

if [ "$connected" = true ]; then
    log_msg "中继模式启动成功，启动AP热点"
    # 再启动AP热点
    nmcli connection up wifi-ap
    sleep 5
    
    # 设置NAT转发规则
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
    iptables -F FORWARD
    iptables -A FORWARD -i wlan0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i wlan0 -o wlan0 -j ACCEPT
    
    sleep 2
    cd /app/
    nohup java -jar CameraPusher.jar > run.log 2>&1 &
    log_msg "中继模式完全启动"
else
    log_msg "上游WiFi连接失败3次，切换到随身WIFI模式"
    
    # 停止NetworkManager
    systemctl stop NetworkManager
    sleep 3
    
    # 清理中继模式的所有配置和状态
    rm -rf /etc/NetworkManager/system-connections/upstream.nmconnection
    rm -rf /etc/NetworkManager/system-connections/wifi-ap.nmconnection
    rm -rf /var/lib/NetworkManager/*.state
    rm -rf /var/lib/NetworkManager/wifi*
    
    # 创建随身WiFi模式配置
    cat > /etc/NetworkManager/system-connections/bridge.nmconnection << 'BRIDGEEOF'
[connection]
id=bridge
uuid=0332def0-cc09-4509-9929-97c92d4f4b7b
type=bridge
interface-name=nm-bridge
permissions=
autoconnect=yes

[bridge]

[ipv4]
address1=192.168.68.1/24
dns-search=
method=manual

[ipv6]
addr-gen-mode=stable-privacy
dns-search=
method=auto

[proxy]
BRIDGEEOF

    cat > /etc/NetworkManager/system-connections/wifi.nmconnection << WIFIEOF
[connection]
id=wifi
uuid=46e2a2e7-2e43-4f61-9269-cf740351f557
type=wifi
interface-name=wlan0
master=0332def0-cc09-4509-9929-97c92d4f4b7b
permissions=
slave-type=bridge
autoconnect=yes

[wifi]
band=bg
channel=8
mac-address-blacklist=
mode=ap
ssid=${wifiname}

[wifi-security]
key-mgmt=wpa-psk
psk=${wifipasswd}

[bridge-port]
WIFIEOF

    cat > /etc/NetworkManager/system-connections/usb.nmconnection << USBEOF
[connection]
id=usb
uuid=fa0ad694-a11a-46bd-9417-0b66ea105cbc
type=ethernet
interface-name=usb0
master=0332def0-cc09-4509-9929-97c92d4f4b7b
permissions=
slave-type=bridge
autoconnect=yes

[ethernet]
mac-address-blacklist=

[bridge-port]
USBEOF

    chmod 600 /etc/NetworkManager/system-connections/bridge.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/wifi.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/usb.nmconnection
    
    log_msg "随身WiFi模式配置完成，重启网络"
    
    # 启动NetworkManager
    systemctl start NetworkManager
    sleep 5
    
    # 重启网络连接
    nmcli connection reload
    sleep 3
    nmcli connection up USB
    sleep 5
    nmcli connection down USB
    
    log_msg "随身WiFi模式启动完成"
fi

exit 0
EOF
)

    # 写入配置文件
    echo "${upstream}" > /etc/NetworkManager/system-connections/upstream.nmconnection
    echo "${ap}" > /etc/NetworkManager/system-connections/wifi-ap.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/upstream.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/wifi-ap.nmconnection
    
    # 永久开启内核转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p 2>/dev/null

    echo "${start}" > /etc/rc.local
    chmod +x /etc/rc.local
    
    echo "中继模式配置完成！"
    echo "上游连接：${upstream_ssid}"
    echo "广播热点：${wifiname}，密码：${wifipasswd}"
    echo "网关地址：192.168.68.1"
    echo "注意：如果上游连接失败3次，将自动切换到随身WIFI模式"
    echo "设备重启中......"
    
    # 同步文件系统，确保配置写入磁盘
    sync
    reboot
}

function  main()
{
    while true
    do
        menu
        num
    done
}
main
