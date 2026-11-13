#!/bin/sh
# ============================================================================
# retry.sh —— 通用重试入口：下载、执行、失败再来
#
# 它自己不干活，只负责“把你给的命令多跑几次”。要跑什么、参数是什么，全部由
# 命令行传进来；基础脚本保持单次执行、干净退出码，需要重试就在外面套这一层。
#
# 用法：
#   retry.sh [-n 次数] [-i 间隔秒] [-q] [-d 下载超时秒] [-x 执行超时秒]
#            -- <命令> [参数...]
#   retry.sh [-n 次数] [-i 间隔秒] [-q] [-d 下载超时秒] [-x 执行超时秒]
#            -u <URL> [--] [参数...]
#
#   -n  最多尝试几次（默认 3）
#   -i  两次之间等几秒（默认 2）
#   -q  安静模式，不打印进度
#   -d  下载阶段超时秒数（默认 0 = 不限）；大于 0 时给 curl 加 --max-time
#   -x  执行阶段超时秒数（默认 0 = 不限）；大于 0 时用 timeout 包住执行
#   -u  远程脚本地址：每轮先下载到临时文件、校验非空且语法正确，再用 sh 执行，
#       后面的参数原样传给该脚本（下载失败也算这一轮失败）
#
#   超时和失败一样，都算这一轮失败，按 -n/-i 继续重试；全部失败退出码为 124
#   （超时）或最后一次的退出码。系统里没有 timeout 命令时，-x 会被忽略并告警。
#
# 例子：
#   sh retry.sh -n 3 -- sh ./lucky-stun-worker.sh --token "$TOKEN" --port 5267
#   sh retry.sh -n 3 -d 20 -x 150 -u https://example.com/task.sh -- --arg 1
# ============================================================================

N=3
I=2
QUIET=0
D=0
X=0
URL=""

usage() {
    echo "用法: retry.sh [-n 次数] [-i 间隔] [-q] [-d 下载超时] [-x 执行超时] -- <命令> [参数...]" >&2
    echo "      retry.sh [-n 次数] [-i 间隔] [-q] [-d 下载超时] [-x 执行超时] -u <URL> [--] [参数...]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n) [ $# -ge 2 ] || { echo "retry.sh: -n 缺少值" >&2; exit 2; }
            N="$2"; shift 2 ;;
        -i) [ $# -ge 2 ] || { echo "retry.sh: -i 缺少值" >&2; exit 2; }
            I="$2"; shift 2 ;;
        -d) [ $# -ge 2 ] || { echo "retry.sh: -d 缺少值" >&2; exit 2; }
            D="$2"; shift 2 ;;
        -x) [ $# -ge 2 ] || { echo "retry.sh: -x 缺少值" >&2; exit 2; }
            X="$2"; shift 2 ;;
        -q) QUIET=1; shift ;;
        -u|--url) [ $# -ge 2 ] || { echo "retry.sh: -u 缺少 URL" >&2; exit 2; }
            URL="$2"; shift 2; break ;;
        --) shift; break ;;
        -h|--help) sed -n '3,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) break ;;
    esac
done

num() {
    # num 名称 值 是否允许 0
    case "$2" in ''|*[!0-9]*) echo "retry.sh: $1 需要非负整数" >&2; exit 2 ;; esac
    if [ "$3" = "pos" ] && [ "$2" -lt 1 ]; then
        echo "retry.sh: $1 至少为 1" >&2; exit 2
    fi
}

num -n "${N}" pos
num -i "${I}" zero
num -d "${D}" zero
num -x "${X}" zero

# -u 之后允许再写一个 -- 作为“以下是给目标脚本的参数”的分隔符，剥掉它
if [ -n "${URL}" ] && [ "${1:-}" = "--" ]; then
    shift
fi

if [ -z "${URL}" ] && [ $# -eq 0 ]; then
    usage
    exit 2
fi

say() { [ "${QUIET}" -eq 1 ] || echo "$*" >&2; }

# 执行阶段超时需要 timeout 命令；没有就退化成“不限制”
HAVE_TIMEOUT=0
if command -v timeout >/dev/null 2>&1; then
    HAVE_TIMEOUT=1
fi
if [ "${X}" -gt 0 ] && [ "${HAVE_TIMEOUT}" -eq 0 ]; then
    say "⚠ 系统里没有 timeout 命令，-x ${X} 被忽略"
    X=0
fi

CT=""
if [ "${D}" -gt 0 ]; then
    CT="--max-time ${D}"
fi

T=1
while :; do
    if [ -n "${URL}" ]; then
        say "▶ 第 ${T}/${N} 次: 下载 ${URL}${CT:+（超时 ${D}s）}"
        TMP=$(mktemp 2>/dev/null || echo "/tmp/retry.$$")
        RC=1
        if curl -fsSL --http1.1 ${CT} "${URL}" -o "${TMP}" 2>/dev/null && [ -s "${TMP}" ]; then
            if sh -n "${TMP}" 2>/dev/null; then
                RC=0
            else
                say "✖ 下载到的脚本语法有误"
                RC=1
            fi
        else
            if [ "${D}" -gt 0 ]; then
                say "✖ 下载失败或超过 ${D}s"
                RC=124
            else
                say "✖ 下载失败"
                RC=1
            fi
        fi

        if [ "${RC}" -eq 0 ]; then
            if [ "${X}" -gt 0 ]; then
                say "▶ 执行（超时 ${X}s）: sh ${TMP} $*"
                timeout -s KILL "${X}" sh "${TMP}" "$@"
            else
                say "▶ 执行: sh ${TMP} $*"
                sh "${TMP}" "$@"
            fi
            RC=$?
        fi
        rm -f "${TMP}" 2>/dev/null
    else
        if [ "${X}" -gt 0 ]; then
            say "▶ 第 ${T}/${N} 次（超时 ${X}s）: $*"
            timeout -s KILL "${X}" "$@"
        else
            say "▶ 第 ${T}/${N} 次: $*"
            "$@"
        fi
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