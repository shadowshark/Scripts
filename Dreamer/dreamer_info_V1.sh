#!/bin/bash

# 设置保险环境
LANG=C
LC_ALL=C
export LANG LC_ALL

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 恢复默认颜色

# 获取服务器序列号和当前时间
if command -v dmidecode &> /dev/null; then
    SERIAL_NUM=$(dmidecode -s system-serial-number | tr -d ' ')
else
    SERIAL_NUM="UNKNOWN"
fi

CURRENT_TIME=$(date +"%Y%m%d-%H%M%S")
OUTPUT_FILE="/root/${SERIAL_NUM}-${CURRENT_TIME}.txt"

# 定义日志函数，同时输出到屏幕和文件
exec > >(tee "$OUTPUT_FILE") 2>&1

# 定义分隔线函数
print_separator() {
    local length=${1:-150}  # 默认长度为100个字符，可通过参数设置
    local separator=""
    
    for ((i=0; i<length; i++)); do
        separator="${separator}━"
    done
    
    echo -e "${BLUE}${separator}${NC}"
}

# 定义章节标题函数
print_section() {
    print_separator
    echo -e "${GREEN}=== $1 ===${NC}"
}

# 输出键值对的函数
print_info() {
    echo -e "${CYAN}$1:${NC} $2"
}

# 输出内联信息的函数
print_inline_info() {
    echo -e "$1"
}

# 脚本开始
print_section "系统信息收集脚本"
echo -e "${YELLOW}开始时间:${NC} $(date)"
echo -e "${YELLOW}输出文件:${NC} ${OUTPUT_FILE}"
print_separator

# 服务器型号和序列号
print_section "服务器硬件信息"
if command -v dmidecode &> /dev/null; then
    print_info "服务器型号" "$(dmidecode -s system-product-name)"
    print_info "服务器制造商" "$(dmidecode -s system-manufacturer)"
    print_info "服务器序列号" "$(dmidecode -s system-serial-number)"
    print_info "BIOS版本" "$(dmidecode -s bios-version)"
else
    echo -e "${RED}未安装dmidecode工具，无法获取服务器硬件信息${NC}"
    echo -e "${YELLOW}请安装dmidecode: sudo apt-get install dmidecode 或 sudo yum install dmidecode${NC}"
fi

print_separator

# CPU信息
print_section "CPU信息"
cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -n 1 | cut -d ":" -f 2 | sed 's/^[ \t]*//')
cpu_cores=$(nproc)
cpu_sockets=$(lscpu | grep "Socket" | awk -F': ' '{print $2}')
cpu_threads=$(lscpu | grep "Thread" | awk -F': ' '{print $2}')

print_inline_info "${CYAN}CPU型号:${NC} $cpu_model ${CYAN}CPU核心数:${NC} $cpu_cores ${CYAN}CPU物理插槽数:${NC} $cpu_sockets ${CYAN}每核心线程数:${NC} $cpu_threads"

echo -e "\n${YELLOW}CPU完整信息:${NC}"
lscpu
print_separator

# 内存信息
print_section "内存信息"
mem_total=$(free -h | grep "Mem:" | awk '{print $2}')
mem_used=$(free -h | grep "Mem:" | awk '{print $3}')
mem_free=$(free -h | grep "Mem:" | awk '{print $4}')
mem_shared=$(free -h | grep "Mem:" | awk '{print $5}')
mem_buff_cache=$(free -h | grep "Mem:" | awk '{print $6}')
mem_avail=$(free -h | grep "Mem:" | awk '{print $7}')

swap_total=$(free -h | grep "Swap:" | awk '{print $2}')
swap_used=$(free -h | grep "Swap:" | awk '{print $3}')
swap_free=$(free -h | grep "Swap:" | awk '{print $4}')

print_inline_info "${CYAN}系统内存:${NC} 总量=${YELLOW}${mem_total}${NC}, 已用=${YELLOW}${mem_used}${NC}, 空闲=${YELLOW}${mem_free}${NC}, 共享=${YELLOW}${mem_shared}${NC}, 缓冲/缓存=${YELLOW}${mem_buff_cache}${NC}, 可用=${YELLOW}${mem_avail}${NC}"
print_inline_info "${CYAN}Swap分区:${NC} 总量=${YELLOW}${swap_total}${NC}, 已用=${YELLOW}${swap_used}${NC}, 空闲=${YELLOW}${swap_free}${NC}"

# 获取swap设备信息
if [ -f "/proc/swaps" ]; then
    echo -e "\n${YELLOW}Swap设备详细信息:${NC}"
    cat /proc/swaps
fi

echo -e "\n${YELLOW}内存完整信息(free -h):${NC}"
free -h


print_separator

# 磁盘信息
print_section "磁盘信息"
echo -e "${YELLOW}文件系统使用情况 (df -Th):${NC}"
df -Th
echo ""
echo -e "${YELLOW}块设备信息 (lsblk):${NC}"
lsblk -a -o NAME,KNAME,MAJ:MIN,FSTYPE,MOUNTPOINT,SIZE,TYPE,UUID,PARTUUID,VENDOR
print_separator

# 防火墙规则
print_section "防火墙规则"
# 检查firewalld
if systemctl is-active --quiet firewalld; then
    print_info "防火墙类型" "firewalld"
    echo -e "${YELLOW}firewalld状态:${NC}"
    firewall-cmd --state
    echo -e "${YELLOW}默认区域:${NC}"
    firewall-cmd --get-default-zone
    echo -e "${YELLOW}活动区域及其接口:${NC}"
    firewall-cmd --get-active-zones
    echo -e "${YELLOW}区域规则:${NC}"
    firewall-cmd --list-all
# 检查iptables
elif command -v iptables &> /dev/null; then
    print_info "防火墙类型" "iptables"
    echo -e "${YELLOW}iptables规则:${NC}"
    iptables -L -n -v
else
    echo -e "${RED}未检测到防火墙服务${NC}"
fi
print_separator

# IP地址信息
print_section "IP地址信息"
echo -e "${YELLOW}网络接口详细信息:${NC}"

# 首先获取所有默认网关信息
all_routes=$(ip route show 2>/dev/null)
default_routes=$(echo "$all_routes" | grep "^default")

# 获取接口列表
interfaces=$(ip -o link show 2>/dev/null | grep -v "lo:" | awk -F': ' '{print $2}')
if [ -z "$interfaces" ]; then
    echo -e "${RED}未找到网络接口${NC}"
    print_separator
    # 继续执行脚本的其他部分
else    
    for iface in $interfaces; do
        if [ -n "$iface" ]; then
            # 基础信息
            ip_addr=$(ip addr show dev $iface 2>/dev/null | grep "inet " | head -n 1 | awk '{print $2}' | cut -d'/' -f1)
            [ -z "$ip_addr" ] && ip_addr="${RED}未分配${NC}"
            
            subnet_mask=$(ip addr show dev $iface 2>/dev/null | grep "inet " | head -n 1 | awk '{print $2}' | cut -d'/' -f2)
            if [ -n "$subnet_mask" ]; then
                subnet_long=$(ipcalc -m $ip_addr/$subnet_mask 2>/dev/null | grep "Netmask" | awk '{print $2}')
                [ -z "$subnet_long" ] && subnet_long="未知"
            else
                subnet_long="${RED}未分配${NC}"
            fi
            
            mac_addr=$(ip link show dev $iface 2>/dev/null | grep "link/ether" | awk '{print $2}')
            [ -z "$mac_addr" ] && mac_addr="${RED}未知${NC}"
            
            status="未知"
            if ip link show dev $iface 2>/dev/null | grep -q "state UP"; then
                status="${GREEN}已启用${NC}"
            else
                status="${RED}已禁用${NC}"
            fi
            
            mtu=$(ip link show dev $iface 2>/dev/null | grep -o "mtu [0-9]*" | awk '{print $2}')
            [ -z "$mtu" ] && mtu="${RED}未知${NC}"
            
            speed="未知"
            speed_file="/sys/class/net/$iface/speed"
            if [ -f "$speed_file" ]; then
                speed_val=$(cat $speed_file 2>/dev/null)
                if [ -n "$speed_val" ] && [ "$speed_val" != "-1" ]; then
                    speed="${speed_val}Mbps"
                fi
            fi
            
            # 确定接口类型
            type="物理接口"
            if [ -d "/sys/class/net/$iface/bonding" ]; then
                type="${YELLOW}Bond接口${NC}"
                # 获取Bond详情
                bond_mode=$(cat /sys/class/net/$iface/bonding/mode 2>/dev/null || echo '未知')
                bond_mode=$(echo "$bond_mode" | sed 's/^[0-9]\+\s\+//') # 移除前缀数字
                bond_slaves=$(cat /sys/class/net/$iface/bonding/slaves 2>/dev/null || echo '未知')
            elif [ -f "/proc/net/vlan/$iface" ] || echo "$iface" | grep -q "\.[0-9]\+$"; then
                type="${PURPLE}VLAN接口${NC}"
                # 获取VLAN详情
                vlan_id=$(echo "$iface" | grep -o "\.[0-9]\+$" | tr -d '.')
                parent_iface=$(echo "$iface" | sed "s/\.[0-9]\+$//")
            fi
            
            # 输出基本表格行
            # 使用简单的echo，每个字段单独一行
            echo -e "│ 接口名称: $iface"
            echo -e "│ IP地址: $ip_addr"
            echo -e "│ 子网掩码: $subnet_long"
            echo -e "│ MAC地址: $mac_addr"
            echo -e "│ 状态: $status"
            echo -e "│ 速率: $speed"
            echo -e "│ MTU: $mtu"
            echo -e "│ 类型: $type"
            
            # 如果有多个IP，显示额外的IP
            extra_ips=$(ip addr show dev $iface 2>/dev/null | grep "inet " | tail -n +2 | awk '{print $2}' | cut -d'/' -f1)
            if [ -n "$extra_ips" ]; then
                echo -e "│ ${YELLOW}└─ 额外IP地址:${NC} $extra_ips"
            fi
            
            # 显示Bond或VLAN的特殊信息
            if [ -d "/sys/class/net/$iface/bonding" ]; then
                echo -e "│ ${YELLOW}└─ Bond模式:${NC} $bond_mode, ${YELLOW}成员:${NC} $bond_slaves"
            elif [ -f "/proc/net/vlan/$iface" ] || echo "$iface" | grep -q "\.[0-9]\+$"; then
                echo -e "│ ${YELLOW}└─ VLAN ID:${NC} $vlan_id, ${YELLOW}父接口:${NC} $parent_iface"
            fi
            
            # 获取并显示网关
            gateway=$(echo "$all_routes" | grep "default.*dev $iface" | head -n 1 | awk '{print $3}')
            if [ -n "$gateway" ]; then
                echo -e "│ ${YELLOW}└─ 默认网关:${NC} $gateway"
            fi
            
            echo -e "├$(for i in $(seq 1 120); do echo -n "─"; done)┤"
        fi
    done
    echo -e "└$(for i in $(seq 1 120); do echo -n "─"; done)┘"
    
    # 显示额外的网络信息
    echo -e "\n${YELLOW}网络路由表:${NC}"
    ip route show | column -t
    
    print_separator
fi

# 存储系统信息
print_section "存储系统信息"

# 检查Ceph
if command -v ceph &> /dev/null; then
    echo -e "${YELLOW}=== Ceph信息 ===${NC}"
    echo -e "${YELLOW}Ceph状态:${NC}"
    ceph_status=$(ceph status 2>/dev/null)
    echo "$ceph_status"
    
    # 检查是否包含特定的epoch和fsid信息
    if echo "$ceph_status" | grep -q "127.0.0.1"; then
        echo -e "${YELLOW}检测到特定Ceph配置，跳过后续Ceph信息收集${NC}"
    else
        echo -e "${YELLOW}Ceph OSD树:${NC}"
        ceph osd tree
        echo -e "${YELLOW}Ceph DB 分区:${NC}"
        osdctl show

        # 获取系统中的OSD数量
        echo -e "${YELLOW}Ceph OSD实例:${NC}"
        osd_list=$(ls /var/lib/ceph/osd/ 2>/dev/null | grep -o "[0-9]*" | sort -n)
        if [ -z "$osd_list" ]; then
            # 尝试其他方法获取OSD列表
            osd_list=$(ceph osd ls 2>/dev/null | sort -n)
        fi
        
        if [ -n "$osd_list" ]; then
            echo -e "系统中发现以下OSD实例: ${GREEN}$osd_list${NC}"
            
            echo -e "\n${YELLOW}Ceph OSD内存限制 (systemctl):${NC}"
            echo -e "ID\t内存限制"
            echo -e "----\t--------"
            
            for osd_id in $osd_list; do
                service_name="ceph-osd@$osd_id"
                if systemctl status $service_name &>/dev/null; then
                    # 获取内存限制
                    mem_limit=$(systemctl show $service_name -p MemoryLimit | awk -F= '{print $2}')
                    # 如果内存限制为无限制或者未设置，则显示"无限制"
                    if [ "$mem_limit" = "18446744073709551615" -o -z "$mem_limit" ]; then
                        mem_limit_human="无限制"
                    else
                        # 将字节转换为GB，保留2位小数
                        mem_limit_human=$(echo "scale=2; $mem_limit/1024/1024/1024" | bc 2>/dev/null)
                        mem_limit_human="${mem_limit_human}GB"
                    fi
                    
                    echo -e "$osd_id\t$mem_limit_human"
                else
                    echo -e "$osd_id\t${RED}服务未找到${NC}"
                fi
            done
            
        else
            echo -e "${RED}未找到任何OSD实例${NC}"
        fi
    fi
else
    echo -e "${RED}未检测到Ceph${NC}"
fi

# 检查LVM
if command -v pvs &> /dev/null; then
    echo -e "\n${YELLOW}=== LVM信息 ===${NC}"
    
    echo -e "${YELLOW}物理卷(PV)信息:${NC}"
    pvs_output=$(pvs 2>/dev/null)
    if [ -z "$pvs_output" ]; then
        echo -e "${RED}无物理卷${NC}"
    else
        echo "$pvs_output"
        echo -e "\n${YELLOW}物理卷详情:${NC}"
        pvdisplay
    fi
    
    echo -e "\n${YELLOW}卷组(VG)信息:${NC}"
    vgs_output=$(vgs 2>/dev/null)
    if [ -z "$vgs_output" ]; then
        echo -e "${RED}无卷组${NC}"
    else
        echo "$vgs_output"
        echo -e "\n${YELLOW}卷组详情:${NC}"
        vgdisplay
    fi
    
    echo -e "\n${YELLOW}逻辑卷(LV)信息:${NC}"
    lvs_output=$(lvs 2>/dev/null)
    if [ -z "$lvs_output" ]; then
        echo -e "${RED}无逻辑卷${NC}"
    else
        echo "$lvs_output"
        echo -e "\n${YELLOW}逻辑卷详情:${NC}"
        lvdisplay
    fi
else
    echo -e "${RED}未检测到LVM${NC}"
fi
print_separator

# 文件系统信息
echo -e "\n${YELLOW}=== Dreamer 相关信息 ===${NC}"
echo -e "${YELLOW} svctl 服务状态:${NC}"
svctl show
echo -e "${YELLOW} dmctl 节点信息:${NC}"
dmctl node list
echo -e "${YELLOW} dmctl 存储信息:${NC}"
dmctl storage list
echo -e "${YELLOW} dmctl 主机备份信息:${NC}"
dmctl hostbackup list
echo -e "${YELLOW} dmctl 无代理备份信息:${NC}"
dmctl vm list
print_separator
echo -e "${YELLOW}结束时间:${NC} $(date)" 
echo -e "${YELLOW}信息已保存至:${NC} ${OUTPUT_FILE}"
print_separator 