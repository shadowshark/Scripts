#!/bin/bash

# 源数据库配置
SRC_DB_HOST="IP_ADDR" 
SRC_DB_USER="USER"
SRC_DB_PASS="PWD"
SRC_DB_NAME="DATABASE"

# 目标数据库配置
DEST_DB_HOST="IP_ADDR"
DEST_DB_USER="USER"
DEST_DB_PASS="PWD"
DEST_DB_NAME="DATABASE"

# 其他配置
TIMEOUT=60  # 单个表checksum超时时间（秒）
TABLE_PATTERN=".*"  # 默认匹配所有表

# 获取当前执行目录
CURRENT_DIR=$(pwd)

# 创建安全的目录名（替换非法字符）
safe_dirname() {
    echo "$1" | sed 's/[^a-zA-Z0-9_-]/_/g'
}

SRC_HOST_SAFE=$(safe_dirname "$SRC_DB_HOST")
SRC_DB_SAFE=$(safe_dirname "$SRC_DB_NAME")
DEST_HOST_SAFE=$(safe_dirname "$DEST_DB_HOST")
DEST_DB_SAFE=$(safe_dirname "$DEST_DB_NAME")

# 创建以数据库信息命名的目录
LOG_DIR="${CURRENT_DIR}/checksum_${SRC_HOST_SAFE}_${SRC_DB_SAFE}_vs_${DEST_HOST_SAFE}_${DEST_DB_SAFE}/$(date '+%Y%m%d_%H%M%S')"
REPORT_FILE="${LOG_DIR}/checksum_report.csv"
ERROR_FILE="${LOG_DIR}/error_tables.txt"

# 检查必要的命令是否存在
command -v mysql >/dev/null 2>&1 || { echo "错误: 需要安装 mysql 客户端"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "警告: 未找到 timeout 命令，不会限制查询时间"; }

# 创建日志目录
mkdir -p "${LOG_DIR}" || { echo "错误: 无法创建日志目录: ${LOG_DIR}"; exit 1; }

# 日志函数
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_DIR}/checksum.log"
}

# 错误处理函数
handle_error() {
    log_message "ERROR" "$1"
    exit 1
}

# 源数据库连接函数
src_db_connect() {
    local query=$1
    local result
    
    # 使用命令行参数执行查询
    if command -v timeout >/dev/null 2>&1; then
        result=$(timeout "$TIMEOUT" mysql -h "${SRC_DB_HOST}" -u "${SRC_DB_USER}" -p"${SRC_DB_PASS}" -A -N -D "${SRC_DB_NAME}" -e "$query" 2>&1)
    else
        result=$(mysql -h "${SRC_DB_HOST}" -u "${SRC_DB_USER}" -p"${SRC_DB_PASS}" -A -N -D "${SRC_DB_NAME}" -e "$query" 2>&1)
    fi
    
    # 检查输出是否包含ERROR关键字，即使命令返回状态为0
    if [ $? -ne 0 ] || echo "$result" | grep -q "ERROR"; then
        log_message "ERROR" "源数据库查询失败: $result"
        return 1
    fi
    
    # 过滤掉密码警告信息
    filtered_result=$(echo "$result" | grep -v "Using a password on the command line interface can be insecure")
    
    echo "$filtered_result"
    return 0
}

# 目标数据库连接函数
dest_db_connect() {
    local query=$1
    local result
    
    # 使用命令行参数执行查询
    if command -v timeout >/dev/null 2>&1; then
        result=$(timeout "$TIMEOUT" mysql -h "${DEST_DB_HOST}" -u "${DEST_DB_USER}" -p"${DEST_DB_PASS}" -A -N -D "${DEST_DB_NAME}" -e "$query" 2>&1)
    else
        result=$(mysql -h "${DEST_DB_HOST}" -u "${DEST_DB_USER}" -p"${DEST_DB_PASS}" -A -N -D "${DEST_DB_NAME}" -e "$query" 2>&1)
    fi
    
    # 检查输出是否包含ERROR关键字，即使命令返回状态为0
    if [ $? -ne 0 ] || echo "$result" | grep -q "ERROR"; then
        log_message "ERROR" "目标数据库查询失败: $result"
        return 1
    fi
    
    # 过滤掉密码警告信息
    filtered_result=$(echo "$result" | grep -v "Using a password on the command line interface can be insecure")
    
    echo "$filtered_result"
    return 0
}

# 获取表列表
get_table_list() {
    local tables
    tables=$(src_db_connect "show tables;")
    
    if [ $? -ne 0 ]; then
        handle_error "获取源数据库表列表失败"
    fi
    
    # 如果指定了表模式，过滤表
    if [ "$TABLE_PATTERN" != ".*" ]; then
        echo "$tables" | grep -E "$TABLE_PATTERN"
    else
        echo "$tables"
    fi
}

# 获取表的checksum
get_src_table_checksum() {
    local table=$1
    local result
    
    result=$(src_db_connect "checksum table ${table};")
    if [ $? -ne 0 ]; then
        log_message "ERROR" "获取源表 ${table} 的checksum失败"
        echo "ERROR"
        return 1
    fi
    
    # 提取checksum值
    echo "$result" | awk '{print $2}'
}

get_dest_table_checksum() {
    local table=$1
    local result
    
    result=$(dest_db_connect "checksum table ${table};")
    if [ $? -ne 0 ]; then
        log_message "ERROR" "获取目标表 ${table} 的checksum失败"
        echo "ERROR"
        return 1
    fi
    
    # 提取checksum值
    echo "$result" | awk '{print $2}'
}

# 获取当前时间
get_current_time() {
    date '+%Y/%m/%d %H:%M'
}

# 初始化报告文件
init_report() {
    echo "数据对比时间,源库ip,目标库ip,数据库,表,源表checksum,目标checksum,检验值" > "${REPORT_FILE}"
}

# 添加报告记录
add_report_record() {
    local table=$1
    local src_checksum=$2
    local dest_checksum=$3
    local check_result=$4
    local current_time=$(get_current_time)
    
    echo "${current_time},${SRC_DB_HOST},${DEST_DB_HOST},${SRC_DB_NAME},${table},${src_checksum},${dest_checksum},${check_result}" >> "${REPORT_FILE}"
}

# 主程序
main() {
    log_message "INFO" "开始执行checksum检查"
    log_message "INFO" "源数据库: ${SRC_DB_HOST}:${SRC_DB_NAME}"
    log_message "INFO" "目标数据库: ${DEST_DB_HOST}:${DEST_DB_NAME}"
    init_report
    
    # 检查数据库连接
    log_message "INFO" "检查数据库连接..."
    if ! src_db_connect "SELECT 1"; then
        handle_error "无法连接到源数据库，请检查连接信息"
    fi
    
    if ! dest_db_connect "SELECT 1"; then
        handle_error "无法连接到目标数据库，请检查连接信息"
    fi
    
    # 获取表列表
    log_message "INFO" "获取数据库表列表..."
    src_table_list=$(get_table_list)
    if [ -z "$src_table_list" ]; then
        log_message "WARN" "没有找到匹配的表"
        exit 0
    fi
    
    # 统计表的数量
    src_table_list_count=$(echo "$src_table_list" | wc -l)
    log_message "INFO" "找到 ${src_table_list_count} 个表需要检查"
    
    # 创建计数器
    local total_tables=0
    local matched_tables=0
    local mismatched_tables=0
    local error_tables=0
    
    # 遍历表进行checksum检查
    for table in ${src_table_list}; do
        ((total_tables++))
        log_message "INFO" "检查表 [${total_tables}/${src_table_list_count}]: ${table}"
        
        # 检查目标数据库是否有此表
        dest_table_exists=$(dest_db_connect "show tables like '${table}';")
        if [ -z "$dest_table_exists" ]; then
            log_message "ERROR" "目标数据库中不存在表: ${table}"
            add_report_record "${table}" "N/A" "N/A" "2"  # 2表示表不存在
            echo "${table}:TABLE_NOT_EXIST_IN_DEST" >> "${ERROR_FILE}"
            ((error_tables++))
            continue
        fi
        
        # 获取checksum
        src_checksum=$(get_src_table_checksum "${table}")
        if [ "$src_checksum" = "ERROR" ]; then
            add_report_record "${table}" "ERROR" "N/A" "3"  # 3表示获取checksum出错
            echo "${table}:ERROR_GETTING_SRC_CHECKSUM" >> "${ERROR_FILE}"
            ((error_tables++))
            continue
        fi
        
        dest_checksum=$(get_dest_table_checksum "${table}")
        if [ "$dest_checksum" = "ERROR" ]; then
            add_report_record "${table}" "$src_checksum" "ERROR" "3"  # 3表示获取checksum出错
            echo "${table}:ERROR_GETTING_DEST_CHECKSUM" >> "${ERROR_FILE}"
            ((error_tables++))
            continue
        fi
        
        # 比对checksum
        if [ "${src_checksum}" = "${dest_checksum}" ]; then
            log_message "INFO" "表 ${table} 检查通过"
            add_report_record "${table}" "${src_checksum}" "${dest_checksum}" "0"
            ((matched_tables++))
        else
            log_message "ERROR" "表 ${table} checksum不匹配"
            add_report_record "${table}" "${src_checksum}" "${dest_checksum}" "1"
            echo "${table}:${src_checksum}:${dest_checksum}" >> "${ERROR_FILE}"
            ((mismatched_tables++))
        fi
    done
    
    # 输出统计信息
    log_message "INFO" "checksum检查完成"
    log_message "INFO" "总表数: ${total_tables}, 匹配: ${matched_tables}, 不匹配: ${mismatched_tables}, 错误: ${error_tables}"
    log_message "INFO" "报告已生成：${REPORT_FILE}"
    
    # 生成摘要文件
    {
        echo "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "源数据库: ${SRC_DB_HOST}:${SRC_DB_NAME}"
        echo "目标数据库: ${DEST_DB_HOST}:${DEST_DB_NAME}"
        echo "总表数: ${total_tables}"
        echo "匹配表数: ${matched_tables}"
        echo "不匹配表数: ${mismatched_tables}"
        echo "错误表数: ${error_tables}"
        echo "检查结果: $([[ $mismatched_tables -eq 0 && $error_tables -eq 0 ]] && echo "通过" || echo "失败")"
    } > "${LOG_DIR}/summary.txt"
}

# 执行主程序
main

# 检查是否有错误发生
if [ -f "${ERROR_FILE}" ] && [ -s "${ERROR_FILE}" ]; then
    log_message "WARN" "存在检查失败的表，请查看 ${ERROR_FILE} 文件"
    exit 1
else
    log_message "INFO" "所有表检查通过"
    exit 0
fi 