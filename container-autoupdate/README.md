# container-autoupdate

给 **DPanel 计划任务**用的容器 / Compose 自动更新脚本。单文件、没有版本号、不做缓存：每次触发都取仓库里最新的一份来跑。

| 目标 | 怎么更新 | 回滚点 |
| --- | --- | --- |
| 容器（`--container`） | DPanel `container:upgrade`，确认有新版本才升级 | DPanel 自动留 `<名字>-bak-<时间戳>` |
| Compose（`--compose`） | `docker compose pull` + `up -d` 就地重建 | 不留；回退要把 compose 里的 tag 钉回旧版本 |

Compose 分支在部署成功后会回收本项目淘汰下来的旧镜像（已无标签、无容器引用）；容器分支不动镜像。同一目标只挂一个计划任务（脚本内部不加锁）。

## 用法

把下面整段填进 DPanel 计划任务的「脚本」框（建议每 2 小时一次、超时 600 秒）。只有四个变量要改：

```sh
# 1) 重试脚本地址
RETRY_URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/retry/retry.sh"
# 2) 目标：远程地址（只下载一次）或本地脚本路径，二选一
TARGET="https://raw.githubusercontent.com/geekMus/ScriptHub/main/container-autoupdate/container-autoupdate.sh"
# 本地已有一份时改成：TARGET="/opt/scripts/container-autoupdate.sh"
# 3) 重试脚本自己的参数
RETRY_ARGS="-n 3 -i 2 -d 20 -x 150"
# 4) 目标脚本的参数：--compose <项目名> 或 --container <容器名>
TARGET_ARGS="--compose myapp"

curl -fsSL --http1.1 --max-time 30 "$RETRY_URL" -o /tmp/retry.sh \
  || { echo "ERR 拉取 retry.sh 失败" >&2; exit 1; }
sh /tmp/retry.sh $RETRY_ARGS -t "$TARGET" -- $TARGET_ARGS
```

- 目标写远程地址时只下载一次、校验语法后反复执行；写本地路径时 retry 直接执行本地文件，不下载。只有 `75`（和 124/137）才重试，参数错/目录错第一轮就结束。
- `retry.sh` 用 `RETRY_TIMEOUT` 告诉脚本执行上限，脚本据此把整轮预算压到 135 秒并留 15 秒收尾，不会在拉镜像途中被外部 KILL。
- 最坏不到 480 秒（下载最多重试两次 + 三次执行各 135 秒），压得住 DPanel 的 600 秒；慢网络下「拉完但没时间 up -d」会用 `75` 收手，下一轮 pull 是空操作。
- 脚本内部每次调 `docker` / DPanel CLI 也带超时，并且和 `retry.sh` 一样按整组收尾：compose 插件这类孙进程不会变成孤儿把任务吊住。

## 参数

| 选项 | 环境变量 | 说明 |
| --- | --- | --- |
| `--compose <名>` | `UPD_COMPOSE` | Compose 项目名；项目目录/文件从容器标签自动反查 |
| `--container <名>` | `UPD_CONTAINER` | 容器名 |
| `--compose-dir <路径>` | `COMPOSE_DIR` | 指定 Compose 项目目录；一般不用填 |
| `--docker-sock <路径>` | `DOCKER_SOCK` / `DOCKER_HOST` | docker CLI 端点 |
| `--dpanel-container <名>` | `DPANEL_NAME` | DPanel 容器名（默认 `dpanel`） |
| `--dpanel-bin <路径>` | `DPANEL_BIN` | 容器内 DPanel CLI 路径（默认 `/app/server/dpanel`） |
| `--dpanel-docker-env <名>` | `DPANEL_DOCKER_ENV` | DPanel 里的 docker 环境名（默认 `local`） |
| `--dry-run` | `DRY_RUN=1` | 只检查、不动手 |
| `-h, --help` | — | 全部选项与超时变量 |

`--compose` 与 `--container` 必须且只能给一个；优先级：命令行 > 环境变量 > 文件顶部配置区。

时间变量（整轮上限 `T_HARD`、各阶段超时 `DP_T_CHECK` / `DP_T_PULL` / `DP_T_UP`、起步门槛 `DP_MIN_UPGRADE` 等）见 `--help`。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 成功，或本来就没有新版本 |
| `75` | 临时失败（可重试）：网络/镜像仓库暂时不可达、连不上 Docker（正在重启）、拉取或部署被超时打断、本轮预算不够没做完 |
| `1` | 不可重试：参数缺失/冲突、Compose 目录不存在、compose 文件错、DPanel CLI 不可用、容器升级失败 |

判定原则：**换成 5 秒后再跑一次有可能成功的，才算 `75`。**

被 TERM/INT/HUP 打断时，脚本会先打印「收到 SIGxxx，提前结束」再按 `75` 退出。
