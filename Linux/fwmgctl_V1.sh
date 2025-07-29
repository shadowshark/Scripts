#!/bin/bash

# 防火墙管理脚本
# 用于管理firewalld的富规则、IP地址和端口

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要root权限，请使用sudo运行"
    exit 1
fi

# 检查firewalld是否安装和运行
check_firewalld() {
    if ! command -v firewall-cmd &> /dev/null; then
        echo "firewalld未安装，请先安装firewalld"
        exit 1
    fi
    
    if ! systemctl is-active --quiet firewalld; then
        echo "firewalld服务未运行，正在启动..."
        systemctl start firewalld
    fi
}

# 添加IP地址到白名单
add_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        echo "请提供IP地址"
        return 1
    fi
    
    # 检查IP地址是否已包含CIDR前缀
    if [[ ! "$ip" =~ / ]]; then
        # 没有CIDR前缀，作为单个IP添加/32
        ip="${ip}/32"
    else
        # 已有CIDR前缀，提取IP部分和前缀
        local ip_part=$(echo "$ip" | cut -d'/' -f1)
        local cidr=$(echo "$ip" | cut -d'/' -f2)
        
        # 验证IP部分格式
        if ! [[ $ip_part =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "IP地址格式不正确"
            return 1
        fi
        
        # 验证CIDR前缀范围
        if ! [[ $cidr =~ ^[0-9]+$ ]] || [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
            echo "子网掩码位数不正确（应在0-32之间）"
            return 1
        fi
    fi
    
    echo "正在添加IP: $ip"
    firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$ip\" accept" && \
    echo "IP $ip 添加成功" || echo "添加失败"
    
    # 重新加载防火墙配置
    firewall-cmd --reload
}

# 移除白名单IP
remove_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        echo "请提供要移除的IP地址"
        return 1
    fi
    
    # 检查IP地址是否已包含CIDR前缀
    if [[ ! "$ip" =~ / ]]; then
        # 没有CIDR前缀，添加/32作为单个IP
        ip="${ip}/32"
    fi
    
    echo "正在移除IP: $ip"
    # 尝试删除带注释和不带注释的规则
    firewall-cmd --permanent --remove-rich-rule="rule family=\"ipv4\" source address=\"$ip\" accept" || \
    firewall-cmd --list-rich-rules | grep "$ip" | while read -r rule; do
        firewall-cmd --permanent --remove-rich-rule="$rule"
    done
    
    echo "IP $ip 移除成功"
    
    # 重新加载防火墙配置
    firewall-cmd --reload
}

# 整合显示端口和允许的IP地址
list() {
    echo "============================================================="
    echo "                 端口和IP地址列表                           "
    echo "============================================================="
    echo "| 端口号        | 协议   | 开放的IP                         |"
    echo "|--------------|--------|----------------------------------|"
    
    # 获取开放的端口列表
    local ports=$(firewall-cmd --list-ports)
    local all_ports=""
    
    # 获取服务列表及其端口
    local services=$(firewall-cmd --list-services)
    
    # 获取富规则列表
    local rich_rules=$(firewall-cmd --list-rich-rules)
    
    # 处理直接开放的端口（对所有IP开放）
    if [ -n "$ports" ]; then
        for port in $ports; do
            local port_num=$(echo $port | cut -d'/' -f1)
            local proto=$(echo $port | cut -d'/' -f2)
            printf "| %-12s | %-6s | %-32s |\n" "$port_num" "$proto" "ALL"
            all_ports="$all_ports $port"
        done
    fi
    
    # 处理服务中开放的端口（对所有IP开放）
    if [ -n "$services" ]; then
        for service in $services; do
            local service_ports=$(firewall-cmd --service=$service --get-ports 2>/dev/null)
            if [ -n "$service_ports" ]; then
                for sport in $service_ports; do
                    # 检查这个端口是否已经在之前的列表中
                    if ! echo "$all_ports" | grep -q "$sport"; then
                        local sport_num=$(echo $sport | cut -d'/' -f1)
                        local sport_proto=$(echo $sport | cut -d'/' -f2)
                        printf "| %-12s | %-6s | %-32s |\n" "$sport_num" "$sport_proto" "ALL"
                        all_ports="$all_ports $sport"
                    fi
                done
            fi
        done
    fi
    
    # 处理富规则（针对特定IP的规则）
    # 首先提取所有针对特定端口的规则
    local port_rules=$(echo "$rich_rules" | grep "port=" || echo "")
    if [ -n "$port_rules" ]; then
        echo "$port_rules" | while read -r rule; do
            local ip="ALL"
            local port_info=""
            local proto=""
            
            # 提取IP地址（如果有）
            if echo "$rule" | grep -q "source address"; then
                ip=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')
                
                # 检查IP地址是否已包含CIDR前缀
                if [[ ! "$ip" =~ / ]]; then
                    # 如果没有CIDR前缀，添加/32
                    ip="${ip}/32"
                fi
            fi
            
            # 提取端口信息
            port_info=$(echo "$rule" | sed -n 's/.*port port="\([^"]*\)" protocol="\([^"]*\)".*/\1 \2/p')
            if [ -n "$port_info" ]; then
                local port_num=$(echo "$port_info" | cut -d' ' -f1)
                proto=$(echo "$port_info" | cut -d' ' -f2)
                printf "| %-12s | %-6s | %-32s |\n" "$port_num" "$proto" "$ip"
            fi
        done
    fi
    
    # 处理富规则中仅针对IP但不指定端口的规则
    local ip_rules=$(echo "$rich_rules" | grep "source address" | grep -v "port=" || echo "")
    if [ -n "$ip_rules" ]; then
        echo "$ip_rules" | while read -r rule; do
            local ip=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')
            
            # 检查IP地址是否已包含CIDR前缀
            if [[ ! "$ip" =~ / ]]; then
                # 如果没有CIDR前缀，添加/32
                ip="${ip}/32"
            fi
            
            printf "| %-12s | %-6s | %-32s |\n" "ALL" "ALL" "$ip"
        done
    fi
    
    # 如果没有任何端口或规则
    if [ -z "$ports" ] && [ -z "$services" ] && [ -z "$rich_rules" ]; then
        echo "| 未找到已开放的端口和IP规则                               |"
    fi
    
    echo "|--------------|--------|----------------------------------|"
    echo ""
}

# 打开端口
open_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    if [[ -z "$port" ]]; then
        echo "请提供端口号"
        return 1
    fi
    
    echo "正在开放端口: $port/$protocol"
    firewall-cmd --permanent --add-port="$port/$protocol" && \
    echo "端口 $port/$protocol 开放成功" || echo "开放端口失败"
    
    # 重新加载防火墙配置
    firewall-cmd --reload
}

# 关闭端口
close_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    if [[ -z "$port" ]]; then
        echo "请提供端口号"
        return 1
    fi
    
    echo "正在关闭端口: $port/$protocol"
    firewall-cmd --permanent --remove-port="$port/$protocol" && \
    echo "端口 $port/$protocol 关闭成功" || echo "关闭端口失败"
    
    # 重新加载防火墙配置
    firewall-cmd --reload
}

# 显示所有防火墙配置（包含格式化输出）
show_all() {
    echo "===================================================="
    echo "                  防火墙状态信息                     "
    echo "===================================================="
    echo -n "防火墙状态: "
    
    if firewall-cmd --state &>/dev/null; then
        echo "运行中 ✓"
    else
        echo "未运行 ✗"
    fi
    
    echo "默认区域: $(firewall-cmd --get-default-zone)"
    echo "活动区域: $(firewall-cmd --get-active-zones | head -n1)"
    echo ""
    
    # 调用整合的端口和IP列表函数
    list
    
    echo ""
    echo "===================================================="
    echo "                完整富规则列表                       "
    echo "===================================================="
    
    local rich_rules=$(firewall-cmd --list-rich-rules)
    if [ -z "$rich_rules" ]; then
        echo "无富规则配置"
    else
        echo "$rich_rules" | sed 's/^/  /'
    fi
}

# 添加组合规则（IP+端口）
add_rule() {
    local ip="$1"
    local port="$2"
    local protocol="${3:-tcp}"
    
    # 如果没有提供IP和端口，则显示帮助
    if [[ -z "$ip" && -z "$port" ]]; then
        echo "请至少提供IP地址或端口"
        echo "用法: $0 add-rule [IP地址[/掩码位]] [端口] [协议]"
        echo "示例: $0 add-rule 192.168.1.0/24 80 tcp  # 允许特定IP访问特定端口"
        echo "      $0 add-rule 192.168.1.100         # 允许特定IP访问所有端口"
        echo "      $0 add-rule '' 8080               # 允许所有IP访问特定端口"
        return 1
    fi
    
    # 规则类型
    local rule_type=""
    local rule_cmd=""
    
    # 处理IP地址
    if [[ -n "$ip" ]]; then
        # 检查IP地址是否已包含CIDR前缀
        if [[ ! "$ip" =~ / ]]; then
            # 没有CIDR前缀，作为单个IP添加/32
            ip="${ip}/32"
        else
            # 已有CIDR前缀，提取IP部分和前缀
            local ip_part=$(echo "$ip" | cut -d'/' -f1)
            local cidr=$(echo "$ip" | cut -d'/' -f2)
            
            # 验证IP部分格式
            if ! [[ $ip_part =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "IP地址格式不正确"
                return 1
            fi
            
            # 验证CIDR前缀范围
            if ! [[ $cidr =~ ^[0-9]+$ ]] || [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
                echo "子网掩码位数不正确（应在0-32之间）"
                return 1
            fi
        fi
    fi
    
    # 处理端口
    if [[ -n "$port" ]]; then
        # 验证端口格式
        if ! [[ $port =~ ^[0-9]+-?[0-9]*$ ]]; then
            echo "端口格式不正确（应为数字或数字范围，如：80或8080-8090）"
            return 1
        fi
    fi
    
    # 构造命令
    if [[ -n "$ip" && -n "$port" ]]; then
        # IP和端口都指定
        echo "正在添加规则: IP $ip 访问 $port/$protocol 端口"
        rule_cmd="rule family=\"ipv4\" source address=\"$ip\" port port=\"$port\" protocol=\"$protocol\" accept"
    elif [[ -n "$ip" ]]; then
        # 仅指定IP
        echo "正在添加规则: IP $ip 访问所有端口"
        rule_cmd="rule family=\"ipv4\" source address=\"$ip\" accept"
    elif [[ -n "$port" ]]; then
        # 仅指定端口
        echo "正在添加规则: 所有IP访问 $port/$protocol 端口"
        rule_cmd="--add-port=$port/$protocol"
        firewall-cmd --permanent $rule_cmd && \
        echo "规则添加成功" || echo "规则添加失败"
        
        # 重新加载防火墙配置
        firewall-cmd --reload
        return 0
    fi
    
    # 执行添加富规则命令
    firewall-cmd --permanent --add-rich-rule="$rule_cmd" && \
    echo "规则添加成功" || echo "规则添加失败"
    
    # 重新加载防火墙配置
    firewall-cmd --reload
}

# 删除组合规则（IP+端口）
remove_rule() {
    local ip="$1"
    local port="$2"
    local protocol="${3:-tcp}"
    
    # 如果没有提供IP和端口，则显示帮助
    if [[ -z "$ip" && -z "$port" ]]; then
        echo "请至少提供IP地址或端口"
        echo "用法: $0 remove-rule [IP地址[/掩码位]] [端口] [协议]"
        echo "示例: $0 remove-rule 192.168.1.0/24 80 tcp  # 删除特定IP访问特定端口的规则"
        echo "      $0 remove-rule 192.168.1.100         # 删除特定IP访问所有端口的规则"
        echo "      $0 remove-rule '' 8080               # 删除所有IP访问特定端口的规则"
        return 1
    fi
    
    # 处理IP地址
    if [[ -n "$ip" && ! "$ip" =~ / ]]; then
        # 没有CIDR前缀，作为单个IP添加/32
        ip="${ip}/32"
    fi
    
    # 构造命令
    if [[ -n "$ip" && -n "$port" ]]; then
        # IP和端口都指定
        echo "正在删除规则: IP $ip 访问 $port/$protocol 端口"
        firewall-cmd --permanent --remove-rich-rule="rule family=\"ipv4\" source address=\"$ip\" port port=\"$port\" protocol=\"$protocol\" accept"
    elif [[ -n "$ip" ]]; then
        # 仅指定IP
        echo "正在删除规则: IP $ip 访问所有端口"
        firewall-cmd --permanent --remove-rich-rule="rule family=\"ipv4\" source address=\"$ip\" accept"
    elif [[ -n "$port" ]]; then
        # 仅指定端口
        echo "正在删除规则: 所有IP访问 $port/$protocol 端口"
        firewall-cmd --permanent --remove-port="$port/$protocol"
    fi
    
    echo "规则删除成功"
    
    # 重新加载防火墙配置
    firewall-cmd --reload
}

# 执行防火墙命令
exec_cmd() {
    # 清空前保存允许IP访问所有端口的规则
    echo "正在收集允许IP访问所有端口的规则..."
    local ip_whitelist_rules=$(firewall-cmd --list-rich-rules | grep "source address" | grep -v "port=" || echo "")
    local saved_ip_rules=()
    
    if [ -n "$ip_whitelist_rules" ]; then
        echo "找到以下IP白名单规则将被保留:"
        echo "$ip_whitelist_rules" | while read -r rule; do
            echo "  - $rule"
            saved_ip_rules+=("$rule")
        done
    else
        echo "未找到IP白名单规则"
    fi
    
    # 清空所有现有规则
    echo "正在清空防火墙规则..."
    
    # 获取当前默认区域
    local default_zone=$(firewall-cmd --get-default-zone)
    
    # 清空所有端口和富规则 - 不使用范围移除，因为可能会报错
    echo "正在移除所有端口规则..."
    local all_ports=$(firewall-cmd --list-ports)
    if [ -n "$all_ports" ]; then
        for port in $all_ports; do
            firewall-cmd --permanent --remove-port=$port &>/dev/null
        done
    fi
    
    # 获取并移除所有富规则（先全部移除，稍后恢复IP白名单）
    local rich_rules=$(firewall-cmd --list-rich-rules)
    if [ -n "$rich_rules" ]; then
        echo "正在移除富规则..."
        echo "$rich_rules" | while read -r rule; do
            firewall-cmd --permanent --remove-rich-rule="$rule" &>/dev/null
        done
    fi
    
    # 移除所有服务
    local services=$(firewall-cmd --list-services)
    for service in $services; do
        firewall-cmd --permanent --remove-service=$service &>/dev/null
    done
    
    echo "所有规则已清空，现在添加新规则..."
    
    # 恢复IP白名单规则
    if [ -n "$ip_whitelist_rules" ]; then
        echo "正在恢复IP白名单规则..."
        echo "$ip_whitelist_rules" | while read -r rule; do
            firewall-cmd --permanent --add-rich-rule="$rule"
        done
    fi
    
    # 定义需要开放的端口列表
    local tcp_ports=("3260" "9101-9104" "9990-9994" "9997-9999")
    
    # 开放指定端口的TCP访问
    echo "正在开放TCP端口: ${tcp_ports[*]}"
    for port in "${tcp_ports[@]}"; do
        firewall-cmd --permanent --add-port=${port}/tcp
    done
    
    local udp_ports=("3260" "9101-9104" "9990-9994" "9997-9999")

    # 开放指定端口的UDP访问
    echo "正在开放UDP端口: ${udp_ports[*]}"
    for port in "${udp_ports[@]}"; do
        firewall-cmd --permanent --add-port=${port}/udp
    done
    
    # 重新加载防火墙配置
    echo "正在应用新规则..."
    firewall-cmd --reload
    
    echo "防火墙规则已重置，保留了IP白名单并开放了指定端口"
    echo "现在的防火墙规则如下:"
    list
}

# 显示帮助信息
show_help() {
    echo "防火墙管理脚本使用方法:"
    echo "  $0 add-ip <IP地址[/掩码位]>        - 添加IP地址到白名单（单个IP自动添加/32）"
    echo "  $0 remove-ip <IP地址[/掩码位]>     - 从白名单中删除IP地址（单个IP自动添加/32）"
    echo "  $0 list                           - 整合显示端口和IP规则信息"
    echo "  $0 open-port <端口> [协议]         - 开放端口(默认TCP)"
    echo "  $0 close-port <端口> [协议]        - 关闭端口(默认TCP)"
    echo "  $0 show-all                       - 显示所有防火墙配置"
    echo "  $0 add-rule <IP地址[/掩码位]> [端口] [协议] - 添加组合规则"
    echo "  $0 remove-rule <IP地址[/掩码位]> [端口] [协议] - 删除组合规则"
    echo "  $0 exec                           - 清空所有规则保留白名单并开放指定端口(3260,9101-9104,9990-9994,9997-9999)"
    echo "  $0 help                           - 显示此帮助信息"
    echo ""
    echo "例子:"
    echo "  $0 add-ip 192.168.1.100           - 添加单个IP (自动变为192.168.1.100/32)"
    echo "  $0 add-ip 192.168.1.0/24          - 添加整个子网"
    echo "  $0 open-port 22                   - 开放22端口"
    echo "  $0 open-port 53 udp               - 开放53/udp端口"
    echo "  $0 add-rule 192.168.1.100 80      - 允许192.168.1.100访问80端口"
    echo "  $0 add-rule 10.0.0.0/8 443 tcp    - 允许10.0.0.0/8网段访问443端口"
    echo "  $0 add-rule 172.16.0.0/16         - 允许172.16.0.0/16网段访问所有端口"
    echo "  $0 add-rule '' 8080               - 允许所有IP访问8080端口"
}

# 主函数
main() {
    # 检查firewalld
    check_firewalld
    
    # 处理命令行参数
    case "$1" in
        add-ip)
            add_ip "$2"
            ;;
        remove-ip)
            remove_ip "$2"
            ;;
        list)
            list
            ;;
        open-port)
            open_port "$2" "$3"
            ;;
        close-port)
            close_port "$2" "$3"
            ;;
        show-all)
            show_all
            ;;
        add-rule)
            add_rule "$2" "$3" "$4"
            ;;
        remove-rule)
            remove_rule "$2" "$3" "$4"
            ;;
        exec)
            exec_cmd
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"