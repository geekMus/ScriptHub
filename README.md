# ScriptHub

自用运维脚本集合，一个功能一个目录。每个目录都是**可以单独拿走用**的单文件脚本 + 说明。

| 目录 | 干什么 | 跑在哪 |
| --- | --- | --- |
| [container-autoupdate](./container-autoupdate/) | 给 DPanel 计划任务用的容器 / Compose 自动更新脚本 | DPanel 容器内 |
| [lucky-stun-worker](./lucky-stun-worker/) | Lucky STUN 打洞端口变化时，把新端口写进 Cloudflare Worker | Lucky 容器内（由 Lucky 调用） |

## 关于这两个脚本

两个脚本来自同一条实际的排障链：家里的宽带是**双层 NAT**（光猫 + 小米路由），公网 IPv4 端口每次重拨都会变，于是用 Lucky 的 STUN 打洞把内网服务暴露出去，再用一个 Cloudflare Worker 把 `<名字>.域名` 307 跳到 `<名字>.打洞后缀:<当前端口>`。

问题出在“**端口变了，Worker 没跟上**”：

- Worker 部署由 Lucky 在端口变化时调用自定义脚本完成，脚本里有 15 秒硬超时；
- 运营商重拨的那几秒，容器到 `api.cloudflare.com` 的连接会被拖住，脚本被杀，Worker 停在旧端口；
- 于是加了三处改进：**入口做选择性代理**（只让需要出海的流量走 OpenClash，STUN 直连）、**脚本内置重试**（最坏 11 秒，留 4 秒余量）、**彻底去掉外挂守护**（全权交给 Lucky）。

细节写在各自目录的 README 里。

## 使用

每个目录都是独立的，进目录看 README。两个脚本都只依赖 `sh` + `curl` + `grep`（`container-autoupdate` 额外用 `timeout`/`sed`/`awk`，Compose 模式还要 `docker` + Compose v2 插件）。

## 许可

MIT，见 [LICENSE](./LICENSE)。