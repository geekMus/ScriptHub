# ScriptHub

自用运维脚本，一个目录一件事。脚本都是**单文件、无配置、无版本号、无缓存、纯命令行参数**，可以单独拿走用；每次用都从仓库拿最新的一份。

| 目录 | 干什么 | 一句话 |
| --- | --- | --- |
| [container-autoupdate](./container-autoupdate/) | 容器 / Compose 自动更新（给 DPanel 计划任务） | `sh container-autoupdate.sh --compose myapp` |
| [lucky-stun-worker](./lucky-stun-worker/) | Lucky 打洞后，把新端口部署进 Cloudflare Worker | `sh lucky-stun-worker.sh --port 5267` |
| [retry](./retry/) | 只重试临时失败（退出码 75），其它立即结束 | `sh retry.sh -n 3 -- <命令>` |

基础脚本只跑一次、用退出码说话；要重试就在外面套 `retry.sh`，它只认 `75`（临时失败）和超时码 `124/137`，配置错、鉴权失败不会白试。

## 依赖

三个脚本都只要 `sh` + `curl`；`container-autoupdate` 另外要 `timeout`、`docker`（Compose 模式要 Compose v2）。

## 背景

家里宽带是双层 NAT（光猫 + 小米路由），公网端口每次重拨都变。做法是 Lucky 用 STUN 打洞，再用 Cloudflare Worker 把 `<名字>.域名` 307 跳到 `<名字>.rt.域名:<当前端口>`。麻烦在“端口变了、Worker 没跟上”——Lucky 对脚本有 15 秒硬超时，所以部署脚本必须又快又短：Lucky 判定端口变化 → 直接调 `lucky-stun-worker.sh` → 成功或失败都立刻返回。网络抖动时可以在 15 秒里套一层 `retry.sh` 再试一次；不做宿主机守护，也就不存在“守着一个旧端口反复重试”的循环。

## 许可

MIT，见 [LICENSE](./LICENSE)。