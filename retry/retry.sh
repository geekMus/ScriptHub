#!/bin/sh
# ============================================================================
# retry.sh —— 通用重试：失败（非 0 退出码）就再跑一次
#
# 它自己不干活，只负责“把你给的命令多跑几次”。要跑什么、参数是什么，全部由
# 命令行传进来；基础脚本保持单次执行、干净退出码，需要重试就在外面套这一层。
#
# 用法：
#   retry.sh [-n 次数] [-i 间隔秒] [-q] -- <命令> [参数...]
#   retry.sh [-n 次数] [-i 间隔秒] [-q] -u <URL> [--] [参数...]
#
#   -n  最多尝试几次（默认 3）
#   -i  两次之间等几秒（默认 2）
#   -q  安静模式，不打印进度
#   -u  远程脚本地址：每轮先下载到临时文件、校验非空且语法正确，再用 sh 执行，
#       后面的参数原样传给该脚本（下载失败也算这一轮失败）
#
#   下载和执**都不设超时**：多久算超时由外层决定（Lucky 对每轮脚本 15 秒，
#   DPanel 计划任务的 600 秒，或者你自己套 timeout）。
#
# 例子：
#   sh retry.sh -n 3 -- sh ./lucky-stun-worker.sh --token "$TOKEN" --port 5267
#   sh retry.sh -n 3 -u https://raw.githubusercontent.com/geekMus/ScriptHub/main/lucky-stun-worker/lucky-stun-worker.sh \
#      -- --token "$TOKEN" --account "$ACCOUNT" --domain mus.pp.ua --suffix rt.mus.pp.ua --port 5267
#
# 退出码：最后一次执行（或下载）的退出码；成功即 0，参数错误 2。
# ============================================================================

N=3
I=2
QUIET=0
URL=""

while [ $# -gt 0 ]; do
    case "$1" in
        -n) [ $# -ge 2 ] || { echo "retry.sh: -n 缺少值" >&2; exit 2; }
            N="$2"; shift 2 ;;
        -i) [ $# -ge 2 ] || { echo "retry.sh: -i 缺少值" >&2; exit 2; }
            I="$2"; shift 2 ;;
        -q) QUIET=1; shift ;;
        -u|--url) [ $# -ge 2 ] || { echo "retry.sh: -u 缺少 URL" >&2; exit 2; }
            URL="$2"; shift 2; break ;;
        --) shift; break ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) break ;;
    esac
done

case "${N}" in ''|*[!0-9]*) echo "retry.sh: -n 需要正整数" >&2; exit 2 ;; esac
[ "${N}" -ge 1 ] || { echo "retry.sh: -n 至少为 1" >&2; exit 2; }

case "${I}" in ''|*[!0-9]*) echo "retry.sh: -i 需要非负整数" >&2; exit 2 ;; esac

# -u 之后允许再写一个 -- 作为“以下是给目标脚本的参数”的分隔符，剥掉它
if [ -n "${URL}" ] && [ "${1:-}" = "--" ]; then
    shift
fi

if [ -z "${URL}" ] && [ $# -eq 0 ]; then
    echo "用法: retry.sh [-n 次数] [-i 间隔] [-q] -- <命令> [参数...]" >&2
    echo "      retry.sh [-n 次数] [-i 间隔] [-q] -u <URL> [--] [参数...]" >&2
    exit 2
fi

say() { [ "${QUIET}" -eq 1 ] || echo "$*" >&2; }

T=1
while :; do
    if [ -n "${URL}" ]; then
        say "▶ 第 ${T}/${N} 次: 下载 ${URL}"
        TMP=$(mktemp 2>/dev/null || echo "/tmp/retry.$$")
        RC=1
        if curl -fsSL --http1.1 "${URL}" -o "${TMP}" 2>/dev/null && [ -s "${TMP}" ]; then
            if sh -n "${TMP}" 2>/dev/null; then
                RC=0
            else
                say "✖ 下载到的脚本语法有误"
                RC=1
            fi
        else
            say "✖ 下载失败"
            RC=1
        fi

        if [ "${RC}" -eq 0 ]; then
            say "▶ 执行: sh ${TMP} $*"
            sh "${TMP}" "$@"
            RC=$?
        fi
        rm -f "${TMP}" 2>/dev/null
    else
        say "▶ 第 ${T}/${N} 次: $*"
        "$@"
        RC=$?
    fi

    [ "${RC}" -eq 0 ] && exit 0
    [ "${T}" -ge "${N}" ] && break
    say "✖ 退出码 ${RC}，${I} 秒后重试"
    sleep "${I}"
    T=$((T + 1))
done

echo "✖ 已试 ${N} 次，最后一次退出码 ${RC}" >&2
exit "${RC}"