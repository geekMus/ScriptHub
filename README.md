# ScriptHub

自用运维脚本，一个目录一件事。脚本都是**单文件、无配置、无版本号、无缓存、纯命令行参数**，可以单独拿走用；每次用都从仓库拿最新的一份。

| 目录 | 干什么 | 一句话 |
| --- | --- | --- |
| [container-autoupdate](./container-autoupdate/) | 容器 / Compose 自动更新（给 DPanel 计划任务） | `sh container-autoupdate.sh --compose myapp` |
| [lucky-stun-worker](./lucky-stun-worker/) | Lucky 打洞后，把新端口部署进 Cloudflare Worker | `sh lucky-stun-worker.sh --token <TOKEN> --account <ID> --domain example.com --suffix rt.example.com --port 5267` |
| [retry](./retry/) | 只重试临时失败（退出码 75），其它立即结束 | `sh retry.sh -n 3 -- <命令>` |

基础脚本只跑一次、用退出码说话；要重试就在外面套 `retry.sh`，它只认 `75`（临时失败）和超时码 `124/137`，配置错、鉴权失败不会白试。

## 许可

MIT，见 [LICENSE](./LICENSE)。