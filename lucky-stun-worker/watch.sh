#!/bin/sh
# ============================================================================
# watch.sh —— 宿主机侧：盯着 Lucky 的通知文件，端口变了就调用部署脚本
#
# 分工：
#   Lucky   只做通知，往挂载目录写一个端口文件，瞬间返回（不碰它的 15 秒超时）
#   宿主机  本脚本轮询这个文件，发现端口变化就调用 lucky-stun-worker.sh 部署，
#           失败按 5→10→20→40→80→160→300 秒退避重试（上限 300 秒），直到成功
#
# Lucky 脚本框里只粘这一行：
#   echo "${port}" > /app/conf/.stun-port.new && mv /app/conf/.stun-port.new /app/conf/stun-port
#
# 用法：
#   watch.sh [-c 配置文件] [-f 端口文件] [-s 部署脚本] [-p 轮询秒] [-n 最多尝试次数] [--once]
#
#   -c  配置文件（默认 /etc/stun-worker.conf），内容是 shell 片段：
#        TOKEN=... ACCOUNT=... DOMAIN=... SUFFIX=... [WORKER=...]
#   -f  端口文件（默认 /root/lucky/conf/stun-port，容器内即 /app/conf/stun-port）
#   -s  部署脚本（默认 /usr/bin/lucky-stun-worker.sh）
#   -p  轮询间隔秒（默认 3）
#   -n  每个端口最多试几次；0 = 一直重试（默认 0）
#   --once  只处理当前端口一次（调试用），成功/失败都退出
# ============================================================================

CONF=/etc/stun-worker.conf
PORTFILE=/root/lucky/conf/stun-port
DEPLOY=/usr/bin/lucky-stun-worker.sh
POLL=3
MAX_TRY=0
ONCE=0
STATE=""
LOG=/tmp/stun-worker-watch.log

while [ $# -gt 0 ]; do
    case "$1" in
        -c) CONF="$2"; shift 2 ;;
        -f) PORTFILE="$2"; shift 2 ;;
        -s) DEPLOY="$2"; shift 2 ;;
        -p) POLL="$2"; shift 2 ;;
        -n) MAX_TRY="$2"; shift 2 ;;
        -t) STATE="$2"; shift 2 ;;
        --once) ONCE=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

# 状态文件默认跟着端口文件放（同一目录），方便跟容器共用挂载目录
[ -n "$STATE" ] || STATE="${PORTFILE%/*}/.stun-port.last"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# 日志别无限长
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 200000 ]; then
    : >"$LOG"
fi

if [ ! -f "$CONF" ]; then
    log "配置不存在：$CONF"
    echo "配置不存在：$CONF" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

if [ -z "${TOKEN:-}" ] || [ -z "${ACCOUNT:-}" ] || [ -z "${DOMAIN:-}" ] || [ -z "${SUFFIX:-}" ]; then
    log "配置不完整：需要 TOKEN / ACCOUNT / DOMAIN / SUFFIX"
    echo "配置不完整：$CONF 里需要 TOKEN / ACCOUNT / DOMAIN / SUFFIX" >&2
    exit 1
fi

deploy_once() {
    _port="$1"
    if [ -n "${WORKER:-}" ]; then
        sh "$DEPLOY" --token "$TOKEN" --account "$ACCOUNT" \
            --domain "$DOMAIN" --suffix "$SUFFIX" --worker "$WORKER" --port "$_port"
    else
        sh "$DEPLOY" --token "$TOKEN" --account "$ACCOUNT" \
            --domain "$DOMAIN" --suffix "$SUFFIX" --port "$_port"
    fi
}

handle() { # $1 = 端口
    _p="$1"
    _try=0
    _delay=5
    while :; do
        _try=$((_try + 1))
        log "部署 ${_p}，第 ${_try} 次"
        if deploy_once "$_p"; then
            echo "$_p" >"$STATE"
            log "成功：端口 ${_p}（第 ${_try} 次）"
            return 0
        fi
        if [ "$MAX_TRY" -gt 0 ] && [ "$_try" -ge "$MAX_TRY" ]; then
            log "放弃：端口 ${_p} 试了 ${_try} 次仍失败"
            return 1
        fi
        log "失败，${_delay} 秒后重试"
        sleep "$_delay"
        _delay=$((_delay * 2))
        [ "$_delay" -gt 300 ] && _delay=300
    done
}

if [ "$ONCE" -eq 1 ]; then
    _p=$(tr -cd '0-9' <"$PORTFILE" 2>/dev/null)
    [ -n "$_p" ] || { echo "端口文件为空或不存在：$PORTFILE" >&2; exit 1; }
    handle "$_p" && exit 0 || exit 1
fi

log "watch 启动：file=$PORTFILE script=$DEPLOY poll=${POLL}s max=${MAX_TRY}"
while :; do
    _p=$(tr -cd '0-9' <"$PORTFILE" 2>/dev/null)
    _last=$(cat "$STATE" 2>/dev/null)
    if [ -n "$_p" ] && [ "$_p" != "$_last" ]; then
        handle "$_p"
    fi
    sleep "$POLL"
done