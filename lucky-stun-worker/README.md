# lucky-stun-worker

把 Lucky STUN 打洞得到的公网端口写进 Cloudflare Worker。单文件、单次执行、用退出码说话。

## 谁在调用它

**Lucky 自己。** STUN 穿透规则里那一栏「脚本」，只写一行调用，端口用 Lucky 的 `${port}` 占位符：

```sh
sh /app/conf/lucky-stun-worker.sh \
  --token "$CF_WORKER_API_TOKEN" --account "$CF_ACCOUNT_ID" \
  --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

为什么不再放一个宿主机守护：Lucky 每次打洞成功只会通知一次，守护等于把同一件事重做一遍；而且它是「不行就再来」的逻辑，一旦端口没变、Worker 又落后，就会一直重试同一个旧端口。现在只保留一条链路——**Lucky 判断端口变了 → 调脚本 → 部署成功或失败**。失败时 Lucky 的界面日志会写清楚原因，下一次端口变化会自然重来。

> 历史：仓库里曾经有 `watch.sh`（宿主机轮询端口文件 + 退避重试），已在 2026-11 移除。需要时可以翻 git 历史，但不建议再用。

## 装进 Lucky 容器

脚本放在宿主 `/root/lucky/conf/`（容器里是 `/app/conf/`，这个目录本来就挂载着）：

```sh
install -m 0755 lucky-stun-worker.sh /root/lucky/conf/lucky-stun-worker.sh
```

Lucky 的规则脚本里再引用 `/app/conf/lucky-stun-worker.sh` 即可。不需要改容器启动参数、不需要额外服务。

## 参数

| 参数 | 环境变量 | 说明 |
| --- | --- | --- |
| `--token` | `CF_WORKER_API_TOKEN` | CF API Token，权限 **Workers Scripts:Edit** |
| `--account` | `CF_ACCOUNT_ID` | CF 账户 ID |
| `--domain` | `BASE_DOMAIN` | 主域名，如 `mus.pp.ua` |
| `--suffix` | `V4_SUFFIX` | IPv4 跳转后缀，如 `rt.mus.pp.ua` |
| `--port` | `port` | 本次打洞的公网端口（Lucky 自动替换） |
| `--worker` | `WORKER_NAME` | Worker 名，默认 `stun-redirect` |
| `--v6-suffix` | `V6_SUFFIX` | 默认同 `--suffix` |
| `--v6-port` | `V6_PORT` | 默认 `100` |
| `--dry-run` | — | 只打印解析结果，不部署 |

命令行参数优先于环境变量；什么参数都没给时，`${port}` 会原样留在脚本里——那样的值部署上去等于把 Worker 写坏，所以参数校验会直接拦下。

## 退出码（给 retry.sh 用）

| 码 | 含义 | 外层怎么办 |
| --- | --- | --- |
| `0` | 部署成功 | 结束 |
| `75` | 临时失败：连不上 `api.cloudflare.com`、请求超时、CF 返回 5xx/429 | 可以再试 |
| `1` | 参数缺失、端口非法、Token/账户错误、CF 明确拒绝（4xx） | 重试没意义，立即结束 |

脚本自己**不做重试**：它只负责把这一次的结果如实报告出来。要重试就套 `retry.sh`，而且只有 75 会被重试。

## 推荐用法：在 Lucky 里套一层 retry

Lucky 对每轮脚本只有 **15 秒**硬超时（超了就是 `调用脚本失败：signal: killed`）。单次部署最多约 5 秒，两轮加 1 秒间隔约 11 秒，塞得进去：

```sh
sh /app/conf/retry.sh -n 2 -i 1 -x 3 -- \
  sh /app/conf/lucky-stun-worker.sh \
     --token "$CF_WORKER_API_TOKEN" --account "$CF_ACCOUNT_ID" \
     --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

这样只有「网络抖了一下」这种 75 才会再跑一轮；Token 写错、端口非法会在第一轮直接结束，Lucky 的界面日志里立刻能看到真正的原因。

如果容器里没有 `retry.sh`，就退回上面那条单行调用——它同样能工作，只是少一次重试。

## Cloudflare 侧要有

1. 一个叫 `stun-redirect` 的 Worker（或 `--worker` 指定的名字）
2. 路由把 `*.mus.pp.ua/*` 指过去
3. DNS 给 `*.rt.mus.pp.ua` 建 **DNS only（灰云）** 的 A 记录，指向当前公网 IP（开橙云会形成跳转环路）

## 出问题看这里

| 现象 | 原因 / 处置 |
| --- | --- |
| Lucky 日志里 `调用脚本失败：signal: killed` | 15 秒超时。看当时是不是正赶上重拨；脚本本身单次最多 5 秒，通常是被网络拖住 |
| `❌ Worker 部署失败（HTTP 4xx）` | Token 权限/过期，或账户 ID 不对；重试无用 |
| `❌ 请求失败（curl 退出码 …）` | 容器到 CF 不通。容器走 OpenClash 出网，确认 `api.cloudflare.com` 命中 DIRECT 之外的分流也没问题 |
| 端口对、外面还是连不上 | 用 `check-host.net/check-tcp` 测“公网 IP:端口”，确认打洞本身通 |
| Worker 里是旧端口 | Lucky 那次部署失败了。看 Lucky 界面日志那一行，按退出码判断是 75（网络）还是 1（配置） |

## 已知限制

- 双层 NAT 下光猫可能再改一次端口，Worker 要写的是**公网端口**，不是本地端口。
- 跳转后缀在 CF 上没有 DNS 记录的话，307 跳过去也解析不了。
- 部署失败不会被自动补偿：Lucky 只在端口变化时调用脚本，失败了就等下一次变化。这是刻意的取舍——不要守护进程。