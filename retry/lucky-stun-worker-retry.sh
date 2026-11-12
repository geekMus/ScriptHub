#!/bin/sh
# ============================================================================
# lucky-stun-worker-retry.sh —— Lucky 用的“带重试”入口脚本
#
# 它不是基础脚本。基础脚本（lucky-stun-worker.sh）只做一次部署、干净退出；
# 这个入口负责把基础脚本多跑几次。Lucky 的脚本框只能粘一段文本，所以这里的
# 做法是：把基础脚本放进容器里，入口只负责调用它。
#
# 用法：
#   1) 把 lucky-stun-worker.sh 放到宿主机的 /root/lucky/conf/
#      （该目录已挂载到容器的 /app/conf/，容器内路径即 /app/conf/lucky-stun-worker.sh）
#   2) Lucky → STUN 穿透 → 规则 → 编辑 → 脚本/Webhook，粘**本文件**的整段
#   3) 基础脚本里的四个配置照常填；本文件的 ${port} 由 Lucky 替换
#
# 时长：基础脚本单次最长 3 秒（--connect-timeout 2 --max-time 3），
#       3 次 + 2 秒间隔 = 最坏 11 秒，Lucky 的硬超时是 15 秒。
# ============================================================================

BASE="${LUCKY_WORKER_SCRIPT:-/app/conf/lucky-stun-worker.sh}"
TRIES=3
GAP=1

# Lucky 在调用前把 ${port} 替换成本次打洞端口
export port="${port}"

if [ ! -f "${BASE}" ]; then
    echo "❌ 找不到基础脚本：${BASE}"
    echo "   把 lucky-stun-worker.sh 放到宿主机 /root/lucky/conf/ 再试"
    exit 1
fi

T=1
while [ "${T}" -le "${TRIES}" ]; do
    sh "${BASE}"
    RC=$?
    [ "${RC}" -eq 0 ] && exit 0
    if [ "${T}" -lt "${TRIES}" ]; then
        echo "⚠️ 第 ${T} 次失败（退出码 ${RC}），${GAP} 秒后重试"
        sleep "${GAP}"
    fi
    T=$((T + 1))
done

echo "❌ 已尝试 ${TRIES} 次，Worker 仍是旧端口"
exit 1