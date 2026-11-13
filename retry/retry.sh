#!/bin/sh
# ============================================================================
# retry.sh —— 本项目专用：只重试「值得重试」的失败
#
# 它自己不干活，只决定「要不要再来一次」。判定标准只有一个——退出码：
#
#   75   临时失败（网络不通、超时、Cloudflare 5xx/429 等），可以再试
#   124  被 -x 的 timeout 杀掉（执行超时），可以再试
#   137  同 124（timeout -s KILL 的结果），可以再试
#   其它 配置错、参数缺、鉴权失败……再试一万次也是一样的结果，立即结束
#
# 为什么不再「非 0 就重试」：把「Token 写错了」重试三次，除了烧掉计划任务的
# 时间预算、把真正的错误埋进第三遍日志，没有任何收益。脚本自己要区分这两类
# 失败（见 container-autoupdate.sh / lucky-stun-worker.sh 的退出码说明）。
#
# 用法：
#   retry.sh [-n 次数] [-i 间隔秒] [-q] [-r 可重试码] [-d 下载超时] [-x 执行超时]
#            -- <命令> [参数...]
#   retry.sh [-n 次数] [-i 间隔秒] [-q] [-r 可重试码] [-d 下载超时] [-x 执行超时]
#            -u <URL> [--] [参数...]
#
#   -n  最多执行几次（默认 3）
#   -i  两次之间等几秒（默认 2）
#   -q  安静模式：不打印每次尝试的进度，只留最终结果
#   -r  可重试退出码，逗号分隔（默认 75）；124/137 始终算可重试
#   -d  下载阶段超时秒数（默认 0 = 不限）；只作用于第一次下载
#   -x  执行阶段超时秒数（默认 0 = 不限）
#   -u  远程脚本地址：**只下载一次**，校验语法后反复执行；重试不再重新下载
#
#   -u 模式下，下载失败（连不上、超时、语法不对）本身可按 -n 重试；一旦下载
#   成功，之后的执行重试就只用本地这份文件，不会再产生下载流量。
#
# 退出码：0 成功；不可重试的失败 → 立即返回该退出码；重试耗尽 → 最后一次的
# 退出码；参数写错 2。
# ============================================================================

N=3
I=2
QUIET=0
D=0
X=0
URL=""
RETRY="75"

usage() {
    echo "用法: retry.sh [-n 次数] [-i 间隔] [-q] [-r 可重试码] [-d 下载超时] [-x 执行超时] -- <命令> [参数...]" >&2
    echo "      retry.sh [-n 次数] [-i 间隔] [-q] [-r 可重试码] [-d 下载超时] [-x 执行超时] -u <URL> [--] [参数...]" >&2
}

say() { [ "${QUIET}" -eq 1 ] || echo "$*" >&2; }

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
        -r) [ $# -ge 2 ] || { echo "retry.sh: -r 缺少值" >&2; exit 2; }
            RETRY="$2"; shift 2 ;;
        -q) QUIET=1; shift ;;
        -u|--url) [ $# -ge 2 ] || { echo "retry.sh: -u 缺少 URL" >&2; exit 2; }
            URL="$2"; shift 2; break ;;
        --) shift; break ;;
        -h|--help) sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

if [ -n "${URL}" ] && ! command -v curl >/dev/null 2>&1; then
    echo "retry.sh: -u 模式需要 curl" >&2
    exit 2
fi

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

# 退出码是否属于「再试一次有意义」的那一类
retryable() {
    case "$1" in
        124|137) return 0 ;;
    esac
    _codes=$(printf '%s' "${RETRY}" | tr ',' ' ')
    for _c in ${_codes}; do
        [ "$1" = "${_c}" ] && return 0
    done
    return 1
}

# 只跑一次（带 -x 超时）
run_once() {
    if [ "${X}" -gt 0 ]; then
        timeout -s KILL "${X}" "$@"
    else
        "$@"
    fi
}

TMP=""
if [ -n "${URL}" ]; then
    # ---- 阶段一：下载（只在这一阶段会重复下载）----
    T=1
    while :; do
        say "▶ 第 ${T}/${N} 次: 下载 ${URL}${CT:+（超时 ${D}s）}"
        TMP=$(mktemp 2>/dev/null || echo "/tmp/retry.$$")
        DL_OK=0
        if curl -fsSL --http1.1 ${CT} "${URL}" -o "${TMP}" 2>/dev/null && [ -s "${TMP}" ]; then
            if sh -n "${TMP}" 2>/dev/null; then
                DL_OK=1
            else
                say "✖ 下载到的脚本语法有误"
            fi
        else
            if [ "${D}" -gt 0 ]; then
                say "✖ 下载失败或超过 ${D}s"
            else
                say "✖ 下载失败"
            fi
        fi
        [ "${DL_OK}" -eq 1 ] && break
        rm -f "${TMP}" 2>/dev/null
        TMP=""
        if [ "${T}" -ge "${N}" ]; then
            echo "✖ 下载失败，已试 ${N} 次" >&2
            exit 75
        fi
        say "✖ ${I} 秒后重新下载"
        sleep "${I}"
        T=$((T + 1))
    done
    say "✔ 已下载并通过语法校验（后面重试只用这份，不再重新下载）"
fi

# ---- 阶段二：执行（不重复下载）----
T=1
while :; do
    if [ -n "${URL}" ]; then
        say "▶ 第 ${T}/${N} 次执行: sh ${TMP} $*"
        run_once sh "${TMP}" "$@"
    else
        say "▶ 第 ${T}/${N} 次执行: $*"
        run_once "$@"
    fi
    RC=$?

    if [ "${RC}" -eq 0 ]; then
        [ -n "${TMP}" ] && rm -f "${TMP}" 2>/dev/null
        exit 0
    fi

    if ! retryable "${RC}"; then
        [ -n "${TMP}" ] && rm -f "${TMP}" 2>/dev/null
        echo "✖ 退出码 ${RC}：不是可重试失败（可重试码：${RETRY},124,137），不再重试" >&2
        exit "${RC}"
    fi

    if [ "${T}" -ge "${N}" ]; then
        [ -n "${TMP}" ] && rm -f "${TMP}" 2>/dev/null
        break
    fi
    say "✖ 可重试失败（退出码 ${RC}），${I} 秒后重试（第 $((T + 1))/${N} 次）"
    sleep "${I}"
    T=$((T + 1))
done

echo "✖ 已试 ${N} 次，最后一次退出码 ${RC}" >&2
exit "${RC}"