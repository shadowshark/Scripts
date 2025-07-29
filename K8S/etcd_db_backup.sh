#!/bin/bash

# etcdctl Backup Script

# 退出时清理临时文件
cleanup() {
    rm -f "${TEMP_BACKUP_FILE}" 2>/dev/null
}
trap cleanup EXIT

# 检查命令是否存在
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "错误: 未找到命令 $1" >&2
        exit 1
    fi
}

# 检查必要的命令
check_command etcdctl
check_command gzip

# 配置变量
ETCD_HOST="${ETCD_HOST:-127.0.0.1}"                   # etcd 主机 IP 地址
ETCD_PORT="${ETCD_PORT:-2379}"                        # etcd 端口
ETCDCTL_ENDPOINTS="https://${ETCD_HOST}:${ETCD_PORT}" # etcdctl 连接的 endpoints

# 证书路径
ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"         # CA 证书路径
ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"       # etcd 服务器证书路径
ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"        # etcd 服务器密钥路径

BACKUP_DIR="/var/backups/etcd"                        # 备份文件存储目录
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/etcd_backup_${TIMESTAMP}.db"
TEMP_BACKUP_FILE="${BACKUP_FILE}.tmp"

LOG_DIR="${BACKUP_DIR}/logs"                          # 日志文件目录
LOG_FILE="${LOG_DIR}/etcd_backup_${TIMESTAMP}.log"

# 保留天数配置
RETAIN_DAYS=7                                         # 保留最近 7 天的备份和日志文件

# 检查必要文件和目录
for cert_file in "${ETCD_CACERT}" "${ETCD_CERT}" "${ETCD_KEY}"; do
    if [ ! -r "${cert_file}" ]; then
        echo "错误: 证书文件 ${cert_file} 不存在或无法读取" >&2
        exit 1
    fi
done

# 创建必要的目录
for dir in "${BACKUP_DIR}" "${LOG_DIR}"; do
    if ! mkdir -p "${dir}"; then
        echo "错误: 无法创建目录 ${dir}" >&2
        exit 1
    fi
done

log() {
    local level="$1"
    local message="$2"
    echo "$(date +%Y-%m-%d\ %H:%M:%S) [${level}] - ${message}" | tee -a "${LOG_FILE}"
    
    # 如果是错误消息，可以在这里添加告警通知
    if [ "${level}" = "ERROR" ]; then
        # 这里可以添加告警通知的代码，比如发送邮件或企业微信通知
        :
    fi
}

verify_backup() {
    local backup_file="$1"
    log "INFO" "验证备份文件: ${backup_file}"
    if ! /usr/local/bin/etcdctl snapshot status "${backup_file}" &>> "${LOG_FILE}"; then
        log "ERROR" "备份文件验证失败！"
        return 1
    fi
    return 0
}

# 开始备份
log "INFO" "开始备份 etcd 数据到临时文件：${TEMP_BACKUP_FILE}"

if ! /usr/local/bin/etcdctl --endpoints="${ETCDCTL_ENDPOINTS}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" \
        snapshot save "${TEMP_BACKUP_FILE}" &>> "${LOG_FILE}"; then
    log "ERROR" "etcd 备份失败，请检查日志和配置！"
    exit 1
fi

# 验证备份
if ! verify_backup "${TEMP_BACKUP_FILE}"; then
    log "ERROR" "备份验证失败，中止操作！"
    exit 1
fi

# 压缩备份文件
log "INFO" "压缩备份文件..."
if ! gzip -c "${TEMP_BACKUP_FILE}" > "${BACKUP_FILE}.gz"; then
    log "ERROR" "备份文件压缩失败！"
    exit 1
fi

# 生成校验和
if ! sha256sum "${BACKUP_FILE}.gz" > "${BACKUP_FILE}.gz.sha256"; then
    log "ERROR" "生成校验和失败！"
    exit 1
fi

# 删除临时文件
rm -f "${TEMP_BACKUP_FILE}"

log "INFO" "etcd 备份成功！文件保存至：${BACKUP_FILE}.gz"

# 清理旧文件
log "INFO" "开始清理超过 ${RETAIN_DAYS} 天的旧文件..."

for pattern in "etcd_backup_*.db.gz" "etcd_backup_*.db.gz.sha256" "etcd_backup_*.log"; do
    if ! find "${BACKUP_DIR}" -type f -name "${pattern}" -mtime "+${RETAIN_DAYS}" -delete &>> "${LOG_FILE}"; then
        log "ERROR" "清理旧${pattern}文件失败！"
        exit 1
    fi
done

log "INFO" "etcd 备份与清理任务完成。"
