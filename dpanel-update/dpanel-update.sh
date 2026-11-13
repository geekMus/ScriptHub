#!/bin/sh
# ============================================================
# dpanel-update.sh — 重建 DPanel 容器，保留网络/静态 IP
#
# 用法、选项和退出码见 --help。
# 注意：在宿主机运行，不要在 DPanel 容器内部运行。
# ============================================================

CONTAINER="dpanel"
IMAGE="dpanel/dpanel:lite"
NETWORK="bridge"
STATIC_IP=""
DATA_DIR="/root/dpanel"
CUSTOM_DNS=""
WAIT=5
FORCE=0
PRUNE=1

die() {
    echo "✗ $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
dpanel-update.sh — 重建 DPanel 容器，保留网络/静态 IP

用法:
  sh dpanel-update.sh [选项]

选项:
  --container <名>    容器名（默认 dpanel）
  --image <镜像>     镜像（默认 dpanel/dpanel:lite）
  --network <网络>   Docker 网络（默认 bridge）
  --ip <地址>        静态 IP；仅用户自定义网络可用
  --data-dir <路径>  DPanel 数据目录（默认 /root/dpanel）
  --dns <地址>       自定义 DNS；留空不添加 --dns
  --wait <秒>        启动后等待秒数（默认 5）
  --force            镜像相同也强制重建
  --no-prune         不清理 dangling 镜像
  -h, --help         显示本帮助

说明:
  - 默认使用 bridge 网络且不设置静态 IP；要用 --ip 必须同时指定
    用户自定义网络（bridge/host/none 不支持固定 IP）。
  - 数据目录挂到 /dpanel，另固定挂载 /mnt 和 /var/run/docker.sock。
  - 拉取镜像失败返回 75，可套 retry.sh；其它错误返回 1。
  - 选项按出现顺序解析；同名选项后出现的覆盖前面的，便于外层
    wrapper 用 "$@" 覆盖默认值。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --container|--image|--network|--ip|--data-dir|--dns|--wait)
            [ $# -ge 2 ] || die "$1 缺少值"
            case "$1" in
                --container) CONTAINER=$2 ;;
                --image)     IMAGE=$2 ;;
                --network)   NETWORK=$2 ;;
                --ip)        STATIC_IP=$2 ;;
                --data-dir)  DATA_DIR=$2 ;;
                --dns)       CUSTOM_DNS=$2 ;;
                --wait)      WAIT=$2 ;;
            esac
            shift 2
            ;;
        --force)    FORCE=1; shift ;;
        --no-prune) PRUNE=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

[ -n "$CONTAINER" ] || die "容器名不能为空"
[ -n "$IMAGE" ] || die "镜像不能为空"
[ -n "$NETWORK" ] || die "网络不能为空"
[ -n "$DATA_DIR" ] || die "数据目录不能为空"

case "$WAIT" in
    ''|*[!0-9]*) die "--wait 需要非负整数" ;;
esac

if [ -n "$STATIC_IP" ]; then
    case "$NETWORK" in
        bridge|host|none)
            die "静态 IP 只能用于用户自定义网络，不能与 $NETWORK 网络一起使用"
            ;;
    esac
fi

command -v docker >/dev/null 2>&1 || die "Docker 未安装"
docker info >/dev/null 2>&1 || die "Docker 不可用（守护进程未运行或当前用户无权限）"

# 防止在 DPanel 自己的容器里执行：stop 会把当前进程一起杀掉。
# 部分 OpenWrt 没有 hostname 命令，优先用 uname -n / /proc。
if [ -f /.dockerenv ]; then
    _host=$(uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || true)
    _target_host=$(docker inspect --format '{{.Config.Hostname}}' "$CONTAINER" 2>/dev/null || true)
    if [ -n "$_host" ] && { [ "$_host" = "$CONTAINER" ] || [ "$_host" = "$_target_host" ]; }; then
        die "检测到在 $CONTAINER 容器内部运行；请改从宿主机 cron/计划任务执行"
    fi
fi

_t0=$(date +%s)
el() { echo $(( $(date +%s) - _t0 )); }

# 前置检查只在失败时说话：网络/数据目录不对，下面每一步都做不成，没必要先报一遍「正常」。
docker network inspect "$NETWORK" >/dev/null 2>&1 || die "Docker 网络不存在: $NETWORK"
[ -d "$DATA_DIR" ] || die "数据目录不存在: $DATA_DIR"

# 当前容器（可能不存在）
CONTAINER_EXISTS=0
OLD_IMAGE_ID=""
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    CONTAINER_EXISTS=1
    OLD_IMAGE_ID=$(docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null || true)
fi

# 第一行就说清「在干啥」：哪个容器、哪个镜像、什么网络、要不要强制重建
_desc="$IMAGE · $NETWORK"
[ -n "$STATIC_IP" ] && _desc="$_desc · 静态 IP $STATIC_IP"
[ "$FORCE" -eq 1 ] && _desc="$_desc · 强制重建"
echo "▶ 更新 $CONTAINER（$_desc）"

if [ "$CONTAINER_EXISTS" -eq 1 ] && [ "$NETWORK" = "bridge" ] && [ -z "$STATIC_IP" ]; then
    echo "WARN 按 bridge + 动态 IP 重建；原容器若用自定义网络/固定 IP，请显式传 --network/--ip"
fi

# 拉取：docker pull 的进度是每层一行，成功时全吞掉，失败时才把最后几行给出来
_p0=$(el)
_pull=$(docker pull "$IMAGE" 2>&1)
_prc=$?
_pd=$(( $(el) - _p0 ))
if [ "$_prc" -ne 0 ]; then
    echo "✗ 拉取镜像失败（${_pd}s）：$IMAGE" >&2
    printf '%s\n' "$_pull" | tr '\r' '\n' | awk 'NF' | tail -n3 | while IFS= read -r _nl; do echo "    $_nl" >&2; done
    exit 75
fi
echo "   拉取 ✓ ${_pd}s"

NEW_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null) || die "读不出刚拉取镜像的 ID"
[ -n "$NEW_IMAGE_ID" ] || die "读不出刚拉取镜像的 ID"

# 普通模式：容器存在且镜像一致时直接结束
if [ "$FORCE" -eq 0 ] && [ "$CONTAINER_EXISTS" -eq 1 ] && [ -n "$OLD_IMAGE_ID" ] \
    && [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
    echo "✓ 完成 $(el)s · 已是最新（镜像没变；--force 可强制重建）"
    exit 0
fi

# 停 / 删旧容器（没有旧容器就跳过，不专门报一句「跳过」）
if [ "$CONTAINER_EXISTS" -eq 1 ]; then
    docker stop "$CONTAINER" >/dev/null 2>&1 || die "停止旧容器失败"
    docker rm "$CONTAINER" >/dev/null 2>&1 || die "删除旧容器失败"
fi

# 用当前配置启动指定镜像
run_container() {
    _image=$1
    set -- -d \
        --name="$CONTAINER" \
        --hostname="$CONTAINER" \
        --restart=unless-stopped \
        --network="$NETWORK"

    if [ -n "$STATIC_IP" ]; then
        set -- "$@" --ip="$STATIC_IP"
    fi

    if [ -n "$CUSTOM_DNS" ]; then
        set -- "$@" --dns="$CUSTOM_DNS"
    fi

    set -- "$@" \
        -v "$DATA_DIR:/dpanel" \
        -v /mnt:/mnt \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "$_image"

    docker run "$@"
}

rollback() {
    if [ "$CONTAINER_EXISTS" -eq 1 ] && [ -n "$OLD_IMAGE_ID" ]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        if run_container "$OLD_IMAGE_ID" >/dev/null 2>&1; then
            echo "   已回滚到旧镜像，$CONTAINER 仍可用" >&2
        else
            echo "   回滚也失败：$CONTAINER 现在没有运行，只能手动 docker run 起一份" >&2
        fi
    else
        echo "   原本没有旧容器，无需回滚" >&2
    fi
}

# 创建新容器（docker run 成功时不打一句话；失败时把它骂的原话给出来）
_r0=$(el)
_run_out=$(run_container "$IMAGE" 2>&1)
_rrc=$?
if [ "$_rrc" -ne 0 ]; then
    echo "✗ 新容器启动失败（docker run rc=$_rrc）" >&2
    printf '%s\n' "$_run_out" | awk 'NF' | tail -n3 | while IFS= read -r _nl; do echo "    $_nl" >&2; done
    rollback
    exit 1
fi

sleep "$WAIT"
_RUNNING=$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
if [ "$_RUNNING" != "true" ]; then
    echo "✗ 容器没跑起来（等了 ${WAIT}s，State.Running=${_RUNNING:-空}）" >&2
    rollback
    exit 1
fi
_rd=$(( $(el) - _r0 ))
echo "   重建 ✓ ${_rd}s"

[ "$PRUNE" -eq 1 ] && docker image prune -f >/dev/null 2>&1

# 收尾一行给结果：做了什么 + 从哪访问（原来还要 docker ps | grep 一遍，那是给自己看的噪音）
if [ -n "$STATIC_IP" ]; then
    _url="http://$STATIC_IP:8080"
else
    _ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null || true)
    # 容器没在运行时 docker 用 "invalid IP" 当占位符，别把它当地址印出来
    case "$_ip" in "invalid IP") _ip="" ;; esac
    if [ -n "$_ip" ]; then _url="http://$_ip:8080"; else _url="http://<容器IP>:8080"; fi
fi

# 收尾前再看一眼还在不在跑：ENTRYPOINT 一跑就结束的镜像，上面那次检查可能刚好撞在
# 「还活着」的一瞬间，这时候报「完成」就是骗人。
_st=$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
if [ "$_st" != "true" ]; then
    echo "✗ 容器起来又退了（$(el)s，State.Running=${_st:-空}）· $_url" >&2
    exit 1
fi

if [ "$CONTAINER_EXISTS" -eq 1 ]; then _act="已重建"; else _act="已新建"; fi
echo "✓ 完成 $(el)s · $_act · $_url"
