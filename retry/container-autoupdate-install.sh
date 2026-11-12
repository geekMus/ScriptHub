#!/bin/sh
# ============================================================================
# container-autoupdate-install.sh —— DPanel 计划任务用的“带镜像回退”入口
#
# 推荐做法是直接抓官方地址（见 container-autoupdate/README.md）。
# 这个入口多做两件事：换个源再试、内容合格才用。抓不到就沿用上一轮的副本。
#
# 用法（DPanel 计划任务脚本框，按小时跑，超时 600 秒）：
#   把本文件整段粘进去，末尾把 --compose myapp 换成你要更新的目标。
# ============================================================================

G=https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
SRC='https://gh-proxy.com
https://ghfast.top
https://github.com'
T=/tmp/ct-new.sh

okfile() { [ -f "$1" ] || return 1; [ "$(wc -c <"$1")" -gt 1000 ] && sh -n "$1" 2>/dev/null && grep -q container-autoupdate "$1"; }

for u in $SRC; do
    case "$u" in "https://github.com") url=$G ;; *) url="$u/$G" ;; esac
    curl -fsSL --max-time 30 "$url" -o "$T" 2>/dev/null || continue
    okfile "$T" && break
done

if okfile "$T"; then
    mv -f "$T" /tmp/container-autoupdate.sh
else
    echo "WARN 三个源都没拿到可用的脚本，沿用上一轮的副本"
fi

[ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本，也没有上一轮的副本" >&2; exit 1; }

sh /tmp/container-autoupdate.sh "$@"