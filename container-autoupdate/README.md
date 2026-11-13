# container-autoupdate

给 **DPanel 计划任务**用的容器 / Compose 自动更新脚本。单文件，跑一次检查一轮就结束，频率交给 DPanel。

> 这里是核心脚本的快照（v5.0.1）。完整文档和发布包在上游：<https://github.com/geekMus/container-autoupdate>

## 用法

```sh
sh container-autoupdate.sh --container myapp          # 更新一个容器
sh container-autoupdate.sh --compose myapp            # 更新一个 Compose 项目
sh container-autoupdate.sh --compose myapp --dry-run  # 只看不动手
sh container-autoupdate.sh --help                     # 全部选项
```

目标也可以写在脚本顶部或环境变量（`UPD_COMPOSE` / `UPD_CONTAINER`），优先级：命令行 > 环境变量 > 配置区。

| 目标 | 谁动手 | 回滚点 |
| --- | --- | --- |
| 容器 | DPanel `container:upgrade`（有新版本才升级） | DPanel 自动留 `<名字>-bak-<时间戳>` |
| Compose | `docker compose pull` + `up -d` | 不留；回退要把 compose 里的 tag 钉回旧版本 |

Compose 分支更新成功后会回收“本项目、已无标签、无引用”的旧镜像；容器分支不碰 Docker。

## 装进 DPanel 计划任务

新建计划任务，脚本框填两行（建议按小时跑，超时 600 秒）：

```sh
G=https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
curl -fsSL --max-time 30 "$G" -o /tmp/container-autoupdate.sh && sh /tmp/container-autoupdate.sh --compose myapp
```

官方地址抓不到（网络不稳、镜像站返回 HTML）时，把上一轮成功下载的副本放在 `/tmp/container-autoupdate.sh` 继续用，或在 [retry](../retry/) 外面套重试。

## 退出码

`0` 更新成功或本来就没有新版本；非 `0` 失败，原因同时写 stderr（计划任务失败时只收 stderr）。

要重试就套一层：`sh retry.sh -n 3 -- sh container-autoupdate.sh --compose myapp`。