#!/bin/sh
# ============================================================================
# retry.sh —— 通用重试入口：失败（非 0 退出码）就再跑一次
#
# 它自己不干活，只负责“把你的脚本多跑几次”。基础脚本保持单次执行、干净退出码，
# 需要重试的场景在外面套这一层。
#
# 用法：
#   sh retry.sh [-n 次数] [-i 间隔秒] [-q] -- 命令 [参数...]
#
# 例子：
#   sh retry.sh -n 3 -i 2 -- sh ../container-autoupdate/container-autoupdate.sh --compose myapp
#   sh retry.sh -n 3 -- sh /opt/scripts/backup.sh
#
# 退出码：最后一次命令的退出码（成功即 0）。
# ============================================================================

N=3
I=2
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -n) N="$2"; shift 2 ;;
        -i) I="$2"; shift 2 ;;
        -q) QUIET=1; shift ;;
        --) shift; break ;;
        *)  break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "用法: sh retry.sh [-n 次数] [-i 间隔秒] [-q] -- 命令 [参数...]" >&2
    exit 2
fi

case "${N}" in ''|*[!0-9]*) echo "retry.sh: -n 需要正整数" >&2; exit 2 ;; esac
[ "${N}" -ge 1 ] || { echo "retry.sh: -n 至少为 1" >&2; exit 2; }

T=1
while :; do
    [ "${QUIET}" -eq 1 ] || echo "▶ 第 ${T}/${N} 次: $*" >&2
    "$@"
    RC=$?
    [ "${RC}" -eq 0 ] && exit 0
    [ "${T}" -ge "${N}" ] && break
    [ "${QUIET}" -eq 1 ] || echo "✖ 退出码 ${RC}，${I} 秒后重试" >&2
    sleep "${I}"
    T=$((T + 1))
done

echo "✖ 已试 ${N} 次，最后一次退出码 ${RC}" >&2
exit "${RC}"