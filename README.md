# ScriptHub

自用运维脚本，一个目录一件事。脚本都是**单文件、无配置、无版本号、无缓存、纯命令行参数**，可以单独拿走用；每次用都从仓库拿最新的一份。

| 目录 | 干什么 | 一句话 |
| --- | --- | --- |
| [container-autoupdate](./container-autoupdate/) | 容器 / Compose 自动更新（给 DPanel 计划任务） | `sh container-autoupdate.sh --compose myapp` |
| [lucky-stun-worker](./lucky-stun-worker/) | Lucky 只写端口文件，宿主机盯到变化再部署 Worker | `sh watch.sh` + `sh lucky-stun-worker.sh --port 5267` |
| [retry](./retry/) | 失败了自动再试几次 | `sh retry.sh -n 3 -- <命令>` |

基础脚本只跑一次、用退出码说话；要重试就在外面套 `retry.sh`。

## 依赖

三个脚本都只要 `sh` + `curl`；`container-autoupdate` 另外要 `timeout`、`docker`（Compose 模式要 Compose v2）。

## 背景

家里宽带是双层 NAT（光猫 + 小米路由），公网端口每次重拨都变。做法是 Lucky 用 STUN 打洞，再用 Cloudflare Worker 把 `<名字>.域名` 307 跳到 `<名字>.rt.域名:<当前端口>`。麻烦在“端口变了、Worker 没跟上”——Lucky 对脚本有 15 秒硬超时，所以现在把部署挪到宿主机：Lucky 只写一行端口文件，`watch.sh` 看到变化再部署，重试次数和间隔都由宿主机决定。

## 许可

MIT，见 [LICENSE](./LICENSE)。