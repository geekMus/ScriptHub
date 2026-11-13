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
    echo "[错误] $*" >&2
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
if [ -f /.dockerenv ]; then
    _host=$(hostname 2>/dev/null || true)
    if [ "$_host" = "$CONTAINER" ]; then
        die "检测到在 $CONTAINER 容器内部运行；请改从宿主机 cron/计划任务执行"
    fi
fi

echo "================================="
echo "   DPanel 更新脚本"
echo "================================="
echo ""

if [ "$FORCE" -eq 1 ]; then
    echo "[模式] 强制重建模式"
else
    echo "[模式] 普通更新模式"
fi
echo ""

# 检查网络
echo "[1/9] 检查 Docker 网络..."
docker network inspect "$NETWORK" >/dev/null 2>&1 || die "Docker 网络不存在: $NETWORK"
echo "网络正常"
echo ""

# 检查数据目录
echo "[2/9] 检查数据目录..."
[ -d "$DATA_DIR" ] || die "数据目录不存在: $DATA_DIR"
echo "数据目录正常"
echo ""

# 获取当前容器信息（可能不存在）
echo "[3/9] 获取当前容器信息..."
CONTAINER_EXISTS=0
OLD_IMAGE_ID=""

if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    CONTAINER_EXISTS=1
    OLD_IMAGE_ID=$(docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null || true)
    echo "检测到已有容器: $CONTAINER"
    if [ -n "$OLD_IMAGE_ID" ]; then
        echo "当前镜像ID:"
        echo "$OLD_IMAGE_ID"
    fi
else
    echo "[提示] 未检测到容器: $CONTAINER"
    echo "将直接创建新容器"
fi
echo ""

# 拉取最新镜像
echo "[4/9] 拉取最新镜像..."
if ! docker pull "$IMAGE"; then
    echo "[错误] 镜像拉取失败"
    exit 75
fi

NEW_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null) || die "获取最新镜像失败"
[ -n "$NEW_IMAGE_ID" ] || die "获取最新镜像失败"

echo ""
echo "最新镜像ID:"
echo "$NEW_IMAGE_ID"
echo ""

# 普通模式：容器存在且镜像一致时直接结束
if [ "$FORCE" -eq 0 ] && [ "$CONTAINER_EXISTS" -eq 1 ] && [ -n "$OLD_IMAGE_ID" ] \
    && [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
    echo "[提示] 当前已经是最新版本"
    exit 0
fi

if [ "$CONTAINER_EXISTS" -eq 1 ] && [ "$NETWORK" = "bridge" ] && [ -z "$STATIC_IP" ]; then
    echo "[提示] 按默认 bridge + 动态 IP 重建；原容器若用了自定义网络/固定 IP，请显式传 --network/--ip"
    echo ""
fi

# 停止 / 删除旧容器（仅在存在时执行）
if [ "$CONTAINER_EXISTS" -eq 1 ]; then
    echo "[5/9] 停止旧容器..."
    docker stop "$CONTAINER" >/dev/null 2>&1 || die "停止旧容器失败"
    echo "旧容器已停止"
    echo ""

    echo "[6/9] 删除旧容器..."
    docker rm "$CONTAINER" >/dev/null 2>&1 || die "删除旧容器失败"
    echo "旧容器已删除"
    echo ""
else
    echo "[5/9] 无旧容器，跳过停止"
    echo ""
    echo "[6/9] 无旧容器，跳过删除"
    echo ""
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
    echo ""
    echo "正在尝试回滚到旧镜像..."

    if [ "$CONTAINER_EXISTS" -eq 1 ] && [ -n "$OLD_IMAGE_ID" ]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        if run_container "$OLD_IMAGE_ID"; then
            echo ""
            echo "[回滚成功] 已恢复旧版本"
        else
            echo ""
            echo "[严重错误] 回滚失败"
        fi
    else
        echo "无旧版本可回滚，请检查上面的错误信息"
    fi
}

# 创建新容器
echo "[7/9] 创建新容器..."
if ! run_container "$IMAGE"; then
    echo ""
    echo "[错误] 新容器启动失败"
    rollback
    exit 1
fi

# 等待启动
echo ""
echo "[8/9] 等待容器启动..."
sleep "$WAIT"

_RUNNING=$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
if [ "$_RUNNING" != "true" ]; then
    echo "[错误] 容器未成功运行"
    rollback
    exit 1
fi

echo "容器运行正常"
echo ""

# 清理无用镜像
if [ "$PRUNE" -eq 1 ]; then
    echo "[9/9] 清理无用镜像..."
    docker image prune -f >/dev/null 2>&1 || true
else
    echo "[9/9] 跳过清理无用镜像"
fi

echo ""
echo "================================="
echo " DPanel 更新完成"
echo "================================="
echo ""

docker ps | grep "$CONTAINER"

echo ""
echo "DPanel 地址:"
if [ -n "$STATIC_IP" ]; then
    echo "http://$STATIC_IP:8080"
else
    _ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null || true)
    if [ -n "$_ip" ]; then
        echo "http://$_ip:8080"
    else
        echo "http://<容器IP>:8080"
    fi
fi
echo ""
