# dpanel-update

在宿主机上重建 **DPanel 容器**：拉取最新镜像、保留自定义网络和静态 IP、启动失败自动回滚旧镜像。单文件、每次执行只跑一次、用退出码说话。

> 只适用于用 `docker run` 启动的 DPanel。如果 DPanel 是 Compose 起的，用 [container-autoupdate](../container-autoupdate/) 的 `--compose` 分支。
>
> **不要从 DPanel 自己的计划任务里运行本脚本**：脚本会先 `docker stop dpanel`，把运行中的 DPanel 连同任务一起停掉。请放到宿主机的 cron / OpenWrt 计划任务里。

## 用法

只有两个变量：脚本地址（远程或本地都行）和一段参数。

```sh
# 地址：远程脚本地址；本地已有文件就写路径
URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/dpanel-update/dpanel-update.sh"
# 参数：全部写在一个变量里；不传就用默认值（dpanel / dpanel:lite / bridge）
ARGS="--network DockerBridge --ip 172.20.0.15"

# 远程地址：下载一次再执行；$@ 透传调用方额外参数
curl -fsSL "$URL" -o /tmp/dpanel-update.sh \
  || { echo "ERR 拉取脚本失败" >&2; exit 1; }
sh /tmp/dpanel-update.sh $ARGS "$@"

# 本地路径：直接执行
sh "$URL" $ARGS "$@"
```

`ARGS` 是固定参数，末尾的 `"$@"` 把调用本脚本时收到的额外参数原样透传给核心脚本。同名选项以后出现的为准，所以 `sh update-dpanel.sh --force` 可以覆盖 `ARGS` 里的默认值；直接放进 DPanel / OpenWrt 计划任务、不传额外参数时，`"$@"` 为空，行为不变。

文章里的环境是自定义网络 `DockerBridge` + 固定 IP `172.20.0.15`；这两个默认**没有**写死，默认网络是 `bridge`、静态 IP 为空。需要和文章一致时，像上面那样显式传 `--network DockerBridge --ip 172.20.0.15`。

> 升级已有 DPanel 时，如果原容器用了自定义网络或固定 IP，**必须显式传** `--network` / `--ip`。不传会按默认 bridge + 动态 IP 重建，容器地址可能变化。

## 参数

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `--container <名>` | `dpanel` | 容器名 |
| `--image <镜像>` | `dpanel/dpanel:lite` | DPanel 镜像 |
| `--network <网络>` | `bridge` | Docker 网络；自定义网络需显式传 |
| `--ip <地址>` | 空 | 静态 IP；必须配用户自定义网络，不能和 bridge/host/none 一起用 |
| `--data-dir <路径>` | `/root/dpanel` | DPanel 数据目录，挂到容器 `/dpanel` |
| `--dns <地址>` | 空 | 自定义 DNS；留空不添加 `--dns` |
| `--wait <秒>` | `5` | 启动后等待时间 |
| `--force` | 关 | 镜像相同也强制重建 |
| `--no-prune` | 关 | 不执行 `docker image prune -f` |
| `-h, --help` | — | 显示帮助 |

另外固定挂载 `/mnt:/mnt` 和 `/var/run/docker.sock:/var/run/docker.sock`，与文章脚本一致。

## 行为

1. 检查 docker、网络、数据目录，记录旧容器和旧镜像 ID。
2. `docker pull` 拉最新镜像；容器已是最新且没给 `--force` 时直接退出 0。
3. 停掉并删除旧容器，用同样的网络/IP/DNS/挂载创建新容器。
4. 新容器启动失败或等待后没有运行，自动用旧镜像 ID 重建，尽量恢复服务。
5. 成功后清理 dangling 镜像；只有无标签、无容器引用的镜像会被清掉。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 成功，或本来就已经是最新镜像 |
| `75` | 拉取镜像失败（网络/仓库临时不可用），可套 [retry](../retry/) |
| `1` | 参数错误、Docker/网络/数据目录不可用、停止/删除/启动失败、回滚失败 |

`75` 只用于拉镜像失败；参数错、镜像名错、容器启动失败都直接 `1`，不会让 retry 白试。
