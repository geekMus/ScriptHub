# container-autoupdate

给 **DPanel 计划任务**用的容器 / Compose 自动更新脚本。单文件、没有版本号、不做缓存：每次触发都取仓库里最新的一份来跑。

| 目标 | 怎么更新 | 回滚点 |
| --- | --- | --- |
| 容器（`--container`） | DPanel `container:upgrade`，确认有新版本才升级 | DPanel 自动留 `<名字>-bak-<时间戳>` |
| Compose（`--compose`） | `docker compose pull` + `up -d` 就地重建 | 不留；回退要把 compose 里的 tag 钉回旧版本 |

Compose 分支在部署成功后会回收本项目淘汰下来的旧镜像（已无标签、无容器引用）；容器分支不动镜像。同一目标只挂一个计划任务（脚本内部不加锁）。

## 用法

只有两个变量：脚本地址（远程或本地都行）和一段参数。把整段填进 DPanel 计划任务的「脚本」框（建议计划任务超时 600 秒）。

```sh
# 地址：远程脚本地址；本地已有文件就写路径
URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/container-autoupdate/container-autoupdate.sh"
# 参数：全部写在一个变量里，写目标（--compose 或 --container）
ARGS="--compose myapp"

# 远程地址：下载一次再执行
curl -fsSL "$URL" -o /tmp/container-autoupdate.sh \
  || { echo "✗ 拉取脚本失败" >&2; exit 1; }
sh /tmp/container-autoupdate.sh $ARGS

# 本地路径：直接执行
sh "$URL" $ARGS
```

- `ARGS` 里必须且只能给一个目标：`--compose <项目名>` 或 `--container <容器名>`。
- 脚本整轮上限默认 540 秒，计划任务超时设 600 秒即可；外面再套 [retry](../retry/) 时，它的 `-x` 就是这里的硬上限（`T_HARD = -x - 15`），经验值是 `-x 180`。
- 剩余预算不足 30 秒时脚本不再动手，直接退 `75` 让下一轮接着做（镜像层已在本地，下一轮很快）——所以别把 `-x` 压到刚好只够拉取。
- 脚本内部每次调 `docker` / DPanel CLI 也带超时，并按整组收尾，不会留下孤儿进程。

## 参数

| 选项 | 环境变量 | 说明 |
| --- | --- | --- |
| `--compose <名>` | `UPD_COMPOSE` | Compose 项目名；项目目录/文件从容器标签自动反查 |
| `--container <名>` | `UPD_CONTAINER` | 容器名 |
| `--compose-dir <路径>` | `COMPOSE_DIR` | 指定 Compose 项目目录；在容器内跑时填容器内路径（如 DPanel 的 `/dpanel/compose/<项目>`） |
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
