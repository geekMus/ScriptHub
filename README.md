# ScriptHub

自用运维脚本集合，一个功能一个目录：每个目录都是**可以单独拿走用**的单文件脚本 + 说明。

## 速查

| 我想…… | 用这个 | 一句话 |
| --- | --- | --- |
| 让容器 / Compose 项目自动更新 | [container-autoupdate/](./container-autoupdate/) | `sh container-autoupdate.sh --compose myapp` |
| 把自动更新装进 DPanel 计划任务 | [container-autoupdate/](./container-autoupdate/) | 粘 README 里“安装”那段 |
| Lucky 打洞换端口后自动改 Worker | [lucky-stun-worker/](./lucky-stun-worker/) | `sh lucky-stun-worker.sh --token ... --port 5267` |
| 上面这些失败了想自动再试几次 | [retry/](./retry/) | `sh retry.sh -n 3 -- <命令>` |
| 要重试的脚本还在网上 | [retry/](./retry/) | `sh retry.sh -n 3 -u <URL> -- <参数...>` |

## 目录

| 目录 | 干什么 | 跑在哪 |
| --- | --- | --- |
| [container-autoupdate](./container-autoupdate/) | 给 DPanel 计划任务用的容器 / Compose 自动更新脚本 | DPanel 容器内 |
| [lucky-stun-worker](./lucky-stun-worker/) | 把打洞端口部署进 Cloudflare Worker（纯参数化，无配置） | 哪儿都行，常用在 Lucky 容器内 |
| [retry](./retry/) | 通用重试入口：重跑命令，或下载远程脚本再重跑 | 哪儿都行 |

## 为什么重试单独放

基础脚本只做一件事：跑一次，用**退出码**说明成败。推荐用法就是直接跑它——逻辑短、看得懂、出错时错误信息就是原始错误。

“失败了再试几次”是另一件事，和业务无关。与其在每个脚本里各写一份重试循环，不如放到 [retry/](./retry/) 里，用统一的入口去调用：`retry.sh -n 3 -- sh 基础脚本`，或者 `retry.sh -u <URL> -- <参数...>` 直接重试一个网上的脚本。这样基础脚本永远保持干净，重试策略可以随时换（次数、间隔、是否静默），也不用改业务代码。

Lucky 的脚本框只能粘一段文本、传不了参数，所以 [lucky-stun-worker](./lucky-stun-worker/) 的做法是：脚本本身纯参数化，Lucky 里只粘**一行调用**（端口用 Lucky 的 `${port}` 占位符）。

## 背景

这几个脚本来自同一条排障链：家里宽带是**双层 NAT**（光猫 + 小米路由），公网 IPv4 端口每次重拨都变。于是用 Lucky 的 STUN 打洞把内网服务暴露出去，再用一个 Cloudflare Worker 把 `<名字>.域名` 307 跳到 `<名字>.打洞后缀:<当前端口>`。

麻烦在“**端口变了，Worker 没跟上**”：Worker 由 Lucky 在端口变化时调用自定义脚本部署，而 Lucky 对脚本有 15 秒硬超时；重拨那几秒容器到 `api.cloudflare.com` 的连接会被拖住，脚本被杀，Worker 停在旧端口。细节在各目录 README。

## 依赖

两个脚本都只依赖 `sh` + `curl` + `grep`；`container-autoupdate` 额外用 `timeout` / `sed` / `awk`，Compose 模式还要 `docker` + Compose v2 插件。

## 许可

MIT，见 [LICENSE](./LICENSE)。