# container-autoupdate

给 **DPanel 计划任务**用的容器 / Compose 自动更新脚本。单文件，跑一次检查一轮就结束，频率交给 DPanel。

脚本没有版本号、不做缓存：每次触发都从本仓库拉最新的一份来跑，拉不到就报错退出，不拿旧副本凑合。

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

新建计划任务，把下面整段填进「脚本」框（建议每 2 小时跑一次，超时 600 秒）：

```sh
G=https://github.mus.pp.ua/https://github.com/geekMus/ScriptHub/raw/refs/heads/main/container-autoupdate/container-autoupdate.sh
T=/tmp/ct-new.sh
curl -fsSL --max-time 30 "$G" -o "$T" || { echo "ERR 拉取失败，本轮不更新" >&2; exit 1; }
{ [ "$(wc -c <"$T")" -gt 1000 ] && sh -n "$T" 2>/dev/null && grep -q container-autoupdate "$T"; } \
  || { echo "ERR 拉到的不是可用的 container-autoupdate 脚本，本轮不更新" >&2; exit 1; }
sh "$T" --compose myapp
```

只走 `github.mus.pp.ua` 这一个加速站（地址要把 `https://github.com/...` 整个拼在它后面），不备其他镜像；拉不到就退出、这一轮不更新，也不会留下半截文件。

## 退出码

`0` 更新成功或本来就没有新版本；非 `0` 失败，原因同时写 stderr（计划任务失败时只收 stderr）。

要重试就套一层：`sh retry.sh -n 3 -- sh container-autoupdate.sh --compose myapp`。