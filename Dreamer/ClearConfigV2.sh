#!/bin/bash

# 设置错误时立即退出
set -e

# 日志函数
log() {
    local level="$1"
    local message="$2"
    echo "$(date +%Y-%m-%d\ %H:%M:%S) [${level}] - ${message}"
}

# 错误处理函数
error_handler() {
    local line_no=$1
    local error_code=$2
    log "ERROR" "错误发生在第 ${line_no} 行，错误代码: ${error_code}"
    exit ${error_code}
}
trap 'error_handler ${LINENO} $?' ERR

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
}

# 检查系统版本
check_os_version() {
    if [ -f /etc/redhat-release ]; then
        local version=$(cat /etc/redhat-release | grep -oP '\d+' | head -1)
        if [ "$version" -lt 7 ]; then
            log "ERROR" "此脚本仅支持CentOS/RHEL 7及以上版本"
            exit 1
        fi
    else
        log "ERROR" "不支持的操作系统"
        exit 1
    fi
}

# 检查必要命令
check_commands() {
    local commands=("systemctl" "hmadm" "sed" "cp")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR" "未找到必要命令: $cmd"
            exit 1
        fi
    done
}

# 备份配置文件
backup_config() {
    local backup_dir="/var/backups/osnstreamer_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    local files_to_backup=(
        "/etc/osnstreamer/osmcd.conf"
        "/boot/hmdevs.reg"
        "/usr/local/osnhm/conf/hmdev.conf"
        "/etc/infocore/imlitesource/drserverinfo.xml"
        "/etc/infocore/imlitesource/drclientinfo.xml"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [ -f "$file" ]; then
            cp -p "$file" "$backup_dir/" 2>/dev/null || log "WARN" "无法备份文件: $file"
        fi
    done
    
    log "INFO" "配置文件已备份到: $backup_dir"
}

# 确认执行函数
confirm() {
    read -p "本脚本支持7系以上系统使用，是否确认强制删除配置? (yes/no): " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$response" =~ ^(yes)$ ]]; then
        log "INFO" "用户取消操作"
        exit 1
    fi
}

# 停止服务
stop_services() {
    local services=("osmcli" "imlitesource")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log "INFO" "正在停止服务: $service"
            systemctl stop "$service" || log "ERROR" "停止服务 $service 失败"
        else
            log "INFO" "服务 $service 未运行"
        fi
    done
}

# 清理配置文件
cleanup_config() {
    local file="/etc/osnstreamer/osmcd.conf"
    if [ -f "$file" ]; then
        log "INFO" "正在清理文件: $file"
        sed -i '/<Manager>/,/<\/DiskGroupList>/d' "$file" || log "ERROR" "清理文件 $file 失败"
    else
        log "WARN" "文件不存在: $file"
    fi

    # 清除 hmdevs.reg 和 hmdev.conf
    local files_to_clear=(
        "/boot/hmdevs.reg"
        "/usr/local/osnhm/conf/hmdev.conf"
    )
    for file in "${files_to_clear[@]}"; do
        if [ -f "$file" ]; then
            log "INFO" "正在清空文件: $file"
            echo -n > "$file" || log "ERROR" "清空文件 $file 失败"
        fi
    done

    # 删除指定文件
    local files_to_remove=(
        "/etc/infocore/imlitesource/drserverinfo.xml"
        "/etc/infocore/imlitesource/drclientinfo.xml"
        "/etc/infocore/imlitesource/serveruuid"
    )
    for file in "${files_to_remove[@]}"; do
        if [ -f "$file" ]; then
            log "INFO" "正在删除文件: $file"
            rm -f "$file" || log "ERROR" "删除文件 $file 失败"
        fi
    done

    # 清理目录
    local dir_to_clean="/etc/infocore/imlitesource/diskdrrel"
    if [ -d "$dir_to_clean" ]; then
        log "INFO" "正在清理目录: $dir_to_clean"
        rm -rf "$dir_to_clean"/* || log "ERROR" "清理目录 $dir_to_clean 失败"
    fi
}

# 取消磁盘保护
unprotect_disks() {
    log "INFO" "正在取消磁盘保护..."
    hmadm disk statall | while IFS= read -r line; do
        if [[ $line =~ "Name:" ]]; then
            device=$(echo "$line" | awk '{print $2}')
            if [[ "$device" != "/dev/sd??" ]]; then
                log "INFO" "取消保护: $device"
                hmadm disk unprotect "$device" || log "ERROR" "取消保护 $device 失败"
            fi
        fi
    done
}

# 替换启动镜像
replace_boot_images() {
    for ifnimg in /boot/initramfs-*.ifn.img; do
        if [ -f "$ifnimg" ]; then
            log "INFO" "找到启动镜像: $ifnimg"
            ifcimg=$(echo "$ifnimg" | sed -e "s/ifn/ifc/g")
            if [ -f "$ifcimg" ]; then
                log "INFO" "找到目标镜像: $ifcimg"
                cp -f "$ifnimg" "$ifcimg" || log "ERROR" "替换镜像失败: $ifnimg -> $ifcimg"
                log "INFO" "替换镜像成功: $ifnimg -> $ifcimg"
            else
                log "WARN" "目标镜像不存在: $ifcimg"
            fi
        fi
    done
}

# 重启服务
restart_services() {
    local services=("osnhm" "osmcli" "imlitesource")
    for service in "${services[@]}"; do
        log "INFO" "正在重启服务: $service"
        systemctl restart "$service" || log "ERROR" "重启服务 $service 失败"
    done
}

# 检查服务状态
check_services() {
    local services=("osnhm" "osmcli" "imlitesource")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log "INFO" "服务 $service 运行正常"
        else
            log "ERROR" "服务 $service 未运行"
            systemctl status "$service" | cat
        fi
    done
}

# 主函数
main() {
    log "INFO" "开始执行配置清理脚本"
    
    # 执行检查
    check_root
    check_os_version
    check_commands
    
    # 获取用户确认
    confirm
    
    # 备份配置
    backup_config
    
    # 执行清理操作
    stop_services
    cleanup_config
    unprotect_disks
    replace_boot_images
    restart_services
    check_services
    
    log "INFO" "配置清理完成"
}

# 执行主函数
main
