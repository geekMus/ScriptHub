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

DPanel 里新建计划任务，脚本框整段填下面这段（按小时跑，执行超时 600 秒）：

```sh
G=https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
SRC='https://gh-proxy.com
https://ghfast.top
https://github.com'
T=/tmp/ct-new.sh
okfile() { [ -f "$1" ] || return 1; [ "$(wc -c <"$1")" -gt 1000 ] && sh -n "$1" 2>/dev/null && grep -q container-autoupdate "$1"; }
for u in $SRC; do
  case "$u" in "https://github.com") url=$G ;; *) url="$u/$G" ;; esac
  curl -fsSL --max-time 30 "$url" -o "$T" 2>/dev/null || continue
  okfile "$T" && break
done
if okfile "$T"; then
  mv -f "$T" /tmp/container-autoupdate.sh
else
  echo "WARN 三个源都没拿到可用的脚本，沿用上一轮的副本"
fi
[ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本，也没有上一轮的副本" >&2; exit 1; }
sh /tmp/container-autoupdate.sh --compose myapp
```

`SRC` 一行一个源，按顺序试，**内容合格才算成功**（`okfile` 会挡掉返回 HTML 的镜像站）。

## 退出码

- `0` 更新成功或本来就没有新版本
- 非 `0` 失败，原因同时写到 stderr（计划任务失败时只收 stderr）