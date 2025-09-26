#!/usr/bin/env bash
set -euo pipefail

# 基本配置（可通过环境变量覆盖）
port=${port:-3306}
threads=${THREADS:-8}
chunk_mb=${CHUNK_FILESIZE_MB:-128}
long_query_ms=${LONG_QUERY_MS:-7200000}
rows=${ROWS:-50000}

# 命令行参数：-h host -P port -u user -p password -D days -K keep -T threads -F chunk_mb -L long_query_ms [--rows rows] -H help
usage() {
  echo "Usage: $0 -h <host> [OPTIONS]"
  echo ""
  echo "必选:"
  echo "  -h <host>                 主机名或地址"
  echo "  -u <user>                 用户名"
  echo "  -p <password>             密码（建议用 env 传入）"
  echo ""
  echo "可选:"
  echo "  -P <port>                 端口，默认 ${port}"
  echo "  -T <threads>              并发线程数，默认 ${threads}"
  echo "  -F <chunk_mb>             按文件大小切块（MB），默认 ${chunk_mb}"
  echo "  --rows <rows>             按行数切块（与 -F 可并行），默认 ${rows}"
  echo "  -L <long_query_ms>        mydumper -l（毫秒），默认 ${long_query_ms}"
  echo "  -D <retention_days>       留存天数（>0 生效），默认 ${RETENTION_DAYS:-2}"
  echo "  -K <retention_keep>       留存最近 N 份（>0 生效），默认 ${RETENTION_KEEP:-0}"
  echo "  -H                         显示帮助"
  echo ""
  echo "提示: --rows 与 -F 可同时使用；将任一值设为 0 可禁用对应选项"
}

while getopts ":h:P:u:p:D:K:T:F:L:H" opt; do
  case "$opt" in
    h) host="$OPTARG" ;;
    P) port="$OPTARG" ;;
    u) user="$OPTARG" ;;
    p) passwd="$OPTARG" ;;
    D) RETENTION_DAYS="$OPTARG" ;;
    K) RETENTION_KEEP="$OPTARG" ;;
    T) threads="$OPTARG" ;;
    F) chunk_mb="$OPTARG" ;;
    L) long_query_ms="$OPTARG" ;;
    H) usage; exit 0 ;;
    :) echo "Option -$OPTARG requires an argument."; usage; exit 1 ;;
    \?) echo "Invalid option: -$OPTARG"; usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# 处理长参数（仅当前剩余位置参数中解析 --rows/--row）
while [ $# -gt 0 ]; do
  case "$1" in
    --rows|--row)
      if [ -n "${2:-}" ]; then
        rows="$2"
        shift 2
        continue
      else
        echo "Option $1 requires an argument."; usage; exit 1
      fi
      ;;
    --)
      shift; break ;;
    *)
      break ;;
  esac
done

# 小工具函数
is_positive_int() { [[ -n "${1:-}" ]] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; }

print_effective_config() {
  echo "配置:"
  echo "  host=${host} port=${port} user=${user}"
  echo "  threads=${threads} long_query_ms=${long_query_ms}"
  echo "  chunk_mb=${chunk_mb} rows=${rows}"
  echo "  retention_days=${RETENTION_DAYS:-2} retention_keep=${RETENTION_KEEP:-0}"
  echo "  output_dir=${bakdir}"
}

# 必填参数校验：host/user/passwd 必须提供（命令行或环境变量）
if [ -z "${host:-}" ] || [ -z "${user:-}" ] || [ -z "${passwd:-}" ]; then
  echo "ERROR: 必须指定 -h <host> -u <user> -p <password>（或以环境变量 host/user/passwd 提供）"
  usage
  exit 1
fi

# 留存策略
RETENTION_DAYS=${RETENTION_DAYS:-2}                             # 保留天数（>0 启用）
RETENTION_KEEP=${RETENTION_KEEP:-0}                             # 或者保留最近 N 份（>0 启用）

# 备份目录：带时间戳，避免同日覆盖；日志写入同目录
bakdir="/rds-backup/${host}/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${bakdir}"
log_file="/rds-backup/${host}/backup_$(date +%Y%m%d_%H%M%S).log"

# 将 stdout/stderr 同时写入日志
exec > >(tee -a "${log_file}") 2>&1

echo "==> mydumper 备份开始: $(date -Is)"
print_effective_config

# 依赖检查
command -v mydumper >/dev/null 2>&1 || { echo "FATAL: 未找到 mydumper"; exit 127; }
command -v mysql >/dev/null 2>&1 || { echo "FATAL: 未找到 mysql 客户端"; exit 127; }


# 使用 MYSQL_PWD 避免明文密码出现在进程参数中
if [ -n "${passwd}" ]; then
  export MYSQL_PWD="${passwd}"
fi



# mydumper 参数：不加表锁，降低锁强度；一致性基于 InnoDB 快照
cmd=(
  mydumper
  -h "${host}"
  -u "${user}"
  -P "${port}"
  -G -R -E 
  -x '^(?!(mysql|INFORMATION_SCHEMA|PERFORMANCE_SCHEMA|METRICS_SCHEMA))'
  -t "${threads}"
)

# 分片/切块参数：两者可并行使用
if is_positive_int "${rows}"; then
  cmd+=( --rows "${rows}" )
fi
if is_positive_int "${chunk_mb}"; then
  cmd+=( -F "${chunk_mb}" )
fi

cmd+=(
  -l "${long_query_ms}"
  -v 3
  --compress
  --trx-tables
  -o "${bakdir}"
)

echo "执行命令: ${cmd[*]}"
start_ts=$(date +%s)
if "${cmd[@]}"; then
  touch "${bakdir}/SUCCESS"
  status=0
  echo "==> 备份成功"
else
  touch "${bakdir}/FAILED"
  status=$?
  echo "==> 备份失败，退出码: ${status}"
fi
end_ts=$(date +%s)
echo "用时: $((end_ts - start_ts))s"
echo "日志: ${log_file}"

# 留存策略：优先按天，其次按份数
cleanup_retention() {
  base_dir="/rds-backup"
  echo "执行保留策略..."
  if [ "${RETENTION_DAYS}" -gt 0 ]; then
    find "${base_dir}" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" -print -exec rm -rf {} \; | cat || true
  elif [ "${RETENTION_KEEP}" -gt 0 ]; then
    mapfile -t all_dirs < <(ls -1dt "${base_dir}"/* 2>/dev/null || true)
    if [ ${#all_dirs[@]} -gt ${RETENTION_KEEP} ]; then
      to_del=("${all_dirs[@]:${RETENTION_KEEP}}")
      printf '将删除旧备份:\n'; printf '%s\n' "${to_del[@]}"
      rm -rf "${to_del[@]}"
    fi
  fi
}
if [ "${status}" -eq 0 ]; then
  cleanup_retention || echo "WARN: 清理过程出现问题"
else
  echo "跳过保留策略清理：因本次备份失败"
fi

echo "结束时间: $(date -Is)"
exit ${status}
