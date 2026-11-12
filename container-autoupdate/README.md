# container-autoupdate

给 **DPanel 计划任务**用的容器 / Compose 自动更新脚本。单文件，只用 `sh`；跑一次检查一轮就结束，频率和超时全交给 DPanel 的计划任务。

> 这个目录是核心脚本的**快照**（v5.0.1）。完整文档、发布包和历史都在上游仓库：
> <https://github.com/geekMus/container-autoupdate>

## 两条路各用各的长处

| 目标 | 谁动手 | 回滚点 |
| --- | --- | --- |
| **容器** | DPanel `container:upgrade`（先查有没有新版，有才升级） | DPanel 自己留 `<容器名>-bak-<时间戳>` 备份容器 |
| **Compose 项目** | 脚本调 `docker compose pull` + `up -d` 就地重建 | 不留（要回退就把 compose 文件里的 tag 钉回旧版本） |

Compose 分支在部署成功后会顺手回收“本项目淘汰下来的、已无标签、无容器引用的旧镜像”，整批删掉；容器分支不碰 Docker。

项目目录从容器标签自动反查，认不到再用 `--compose-dir` 指定。

## 用法

```sh
sh container-autoupdate.sh --container myapp            # 更新一个普通容器
sh container-autoupdate.sh --compose myapp              # 更新一个 Compose 项目
sh container-autoupdate.sh --compose myapp --dry-run    # 只看不动手
sh container-autoupdate.sh --help                       # 全部选项
```

目标也可以写在脚本顶部配置区（`COMPOSE_NAME` / `CONTAINER_NAME`）或用环境变量 `UPD_COMPOSE` / `UPD_CONTAINER` 指定，优先级：命令行 > 环境变量 > 配置区。

## 安装（DPanel 计划任务）

DPanel 里新建计划任务，脚本框填两行（按小时跑，执行超时 600 秒），把 `--compose myapp` 换成你的目标：

```sh
G=https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
curl -fsSL --max-time 30 "$G" -o /tmp/container-autoupdate.sh && sh /tmp/container-autoupdate.sh --compose myapp
```

抓不到官方地址（网络不稳、镜像站返回 HTML）时，改用 [`../retry/container-autoupdate-install.sh`](../retry/container-autoupdate-install.sh)：它轮流试几个源，内容合格才用，全失败就沿用上一轮副本。

## 退出码

- `0` 更新成功或本来就没有新版本
- 非 `0` 失败，原因同时写到 stderr（计划任务失败时只收 stderr）

需要“失败了再试几次”的场景，用 [`../retry/retry.sh`](../retry/retry.sh) 包一层：`sh retry.sh -n 3 -- sh container-autoupdate.sh --compose myapp`。

## Compose 分支的旧镜像回收

`docker compose pull` 会把 `<仓库>:<标签>` 搬到新镜像上，旧镜像丢掉最后一个标签但层还留在磁盘；`up -d` 重建容器后，旧镜像连最后的引用也没了。脚本在更新成功后做一次回收，只删**本项目、已无标签、无容器引用**的镜像，避免每更新一次就永久沉淀一个镜像。

代价是不保留回滚点：Compose 模式回退只能把 compose 文件里的 tag 改回旧版本再 `up -d`。容器模式的回滚点由 DPanel 负责。