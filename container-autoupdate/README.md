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

## 退出码

脚本自己**不做重试**，只把这一轮的结果用退出码说清楚；要不要再跑由外层 `retry.sh` 决定：

| 码 | 含义 | 典型场景 |
| --- | --- | --- |
| `0` | 成功，或本来就没有新版本 | 正常结束 |
| `75` | 临时失败，值得再跑一轮 | 拉取镜像失败（网络/镜像仓库不可达）、连不上 Docker（正在重启）、DPanel 调用超时、拉取或部署被超时打断、本轮预算不够没做完 |
| `1` | 不可重试的失败 | 参数缺失/冲突、Compose 项目目录不存在、compose 文件错、DPanel CLI 不可用、容器升级失败 |

判定原则只有一句：**换成 5 秒后再跑一次有可能成功的，才算 75。**

## 推荐用法：装进 DPanel 计划任务

新建计划任务，把下面整段填进「脚本」框（建议每 2 小时跑一次，超时 600 秒）。重试交给 `retry.sh`，超时按阶段给：拉 `retry.sh` 本身 30 秒、下载目标脚本 20 秒、执行 150 秒。

`retry.sh` 会把执行上限（`-x`）告诉脚本（环境变量 `RETRY_TIMEOUT`），脚本据此把整轮预算压到 135 秒、并留 15 秒自己收尾 —— 它永远在被外部 KILL 之前先写清楚「停在哪、为什么」，而不是留下一句 `Killed`。

```sh
# 两个地址都用完整的文件地址。想换镜像 / 自建 CDN 只改这两行，下面的命令不用动：
# 走镜像时把完整地址接在镜像前缀后面即可（如 https://<镜像>/https://raw.githubusercontent.com/...）。
# retry.sh 本身（引导脚本）
RETRY_URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/retry/retry.sh"
# 本脚本（container-autoupdate.sh）
TARGET_URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/container-autoupdate/container-autoupdate.sh"

R=/tmp/retry.sh
curl -fsSL --http1.1 --max-time 30 "$RETRY_URL" -o "$R" \
  || { echo "ERR 拉取 retry.sh 失败" >&2; exit 1; }
sh "$R" -n 3 -i 2 -d 20 -x 150 -u "$TARGET_URL" -- --compose myapp
```

两个变量里都放**完整地址**，地址本身不拼接、不写相对路径。换镜像 / 自建 CDN 只改这两行，下面的命令不用动；也不要改成 `github.com/.../raw/` 那种形式，会被缓存旧版本。

这条命令的行为：

- **目标脚本只下载一次**，校验语法后反复执行；重试不会重新下载。
- 只有退出码 `75`（以及超时 124/137）才会触发下一次执行；参数错、目录错这类第一轮就结束，不会白等 3 轮。
- 最坏情况（下载 3 次 + 执行 3 次）约 540 秒，压得住 DPanel 的 600 秒。
- 慢网络下每轮只做一半是正常的：拉取成功但剩余预算不够 `up -d` 时会用 `75` 收手，下一轮 pull 已是空操作，时间全给 `up -d`。

## 手动跑

不套 retry 也行，就是「跑一轮就结束」：

```sh
sh container-autoupdate.sh --compose myapp
echo $?   # 0 成功；75 临时失败（可手动再跑）；1 配置/目标问题
```