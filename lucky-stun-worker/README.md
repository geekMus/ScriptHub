# lucky-stun-worker

Lucky 的 STUN 穿透打出新端口后，把新端口写进 Cloudflare Worker。

整个目录只有**一个 sh 文件**：它唯一的职责就是“把内嵌的 Worker 代码部署上去”。没有任何配置写死在脚本里——Token、账号、域名、后缀、端口全部通过**命令行参数**传入（也可以用同名环境变量，命令行优先）。

**运行位置**：哪里都行。放在 Lucky 容器里由 Lucky 调用最方便，也可以在宿主机、CI、你自己的机器上手动跑。

## 它解决什么问题

家里宽带是双层 NAT（光猫 + 小米路由），公网 IPv4 端口每次重拨都换。玩法是：

```
浏览器  https://<名字>.mus.pp.ua        ← Cloudflare 上 Worker 的路由
   │
   ├─ Worker 307 → https://<名字>.rt.mus.pp.ua:<当前打洞端口>
   │
   └─ rt.mus.pp.ua 是 DNS only 记录，直接指回公网 IP
```

Worker 里必须存着**当前**的打洞端口；端口一变，Lucky 就调用这段脚本把 Worker 覆盖部署一次。

## 用法

```sh
sh lucky-stun-worker.sh \
  --token   "$CF_WORKER_API_TOKEN" \
  --account "$CF_ACCOUNT_ID" \
  --domain  mus.pp.ua \
  --suffix  rt.mus.pp.ua \
  --port    5267
```

| 参数 | 环境变量 | 说明 |
| --- | --- | --- |
| `--token` | `CF_WORKER_API_TOKEN` | Cloudflare API Token，权限 **Workers Scripts:Edit** |
| `--account` | `CF_ACCOUNT_ID` | Cloudflare 账户 ID |
| `--domain` | `BASE_DOMAIN` | 主域名，例如 `mus.pp.ua` |
| `--suffix` | `V4_SUFFIX` | IPv4 跳转目标后缀，例如 `rt.mus.pp.ua` |
| `--port` | `port` | 本次打洞的公网端口 |
| `--worker` | `WORKER_NAME` | Worker 名称，默认 `stun-redirect` |
| `--v6-suffix` | `V6_SUFFIX` | IPv6 后缀，默认同 `--suffix` |
| `--v6-port` | `V6_PORT` | IPv6 端口，默认 `100` |
| `--dry-run` | — | 只打印解析结果，不部署 |

缺任何一个必填参数都会直接报错退出，不会把空值或 0 部署上去。

- 成功：打印 `✅ Worker 部署成功（<后缀>:<端口>）`，退出码 0
- 失败：打印 `❌ Worker 部署失败` + Cloudflare 的原始响应，退出码 1

单次执行不带重试；需要重试请在**外面**套 [`../retry/retry.sh`](../retry/retry.sh)。

## 在 Lucky 里怎么用

Lucky 的脚本框只能粘一段文本、不能传参数，所以做法是：**先把脚本放进容器，再粘一行调用**。

1. 把 `lucky-stun-worker.sh` 放到宿主机的 `/root/lucky/conf/`（该目录已挂载到容器的 `/app/conf/`）；
2. Lucky → STUN 穿透 → 规则 → 编辑 → 脚本/Webhook，内容写：

```sh
sh /app/conf/lucky-stun-worker.sh \
  --token "你的 Token" --account "你的账户ID" \
  --domain "mus.pp.ua" --suffix "rt.mus.pp.ua" \
  --port "${port}"
```

`${port}` 是 Lucky 的占位符，它会在调用前替换成本次打洞端口。

3. 保存后重启一次 Lucky，日志里应出现 `✅ Worker 部署成功`。

需要重试的话，同一段换成：

```sh
sh /app/conf/retry.sh -n 3 -i 1 -- sh /app/conf/lucky-stun-worker.sh \
  --token "..." --account "..." --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

Lucky 对每轮脚本有 **15 秒硬超时**，超时直接 `SIGKILL`（日志里是 `调用脚本失败：signal: killed`）。本脚本单次请求最长约 5 秒（`--connect-timeout 2 --max-time 5`），所以套重试时用 `-n 2 -i 1`（约 11 秒）才稳；`-n 3 -i 1` 约 17 秒，已经超过窗口。

## Cloudflare 侧要准备的

1. 一个 Worker，名字和 `--worker` 一致（默认 `stun-redirect`）；
2. Worker 路由 / 自定义域名把 `*.<主域名>` 指到它（例如 `*.mus.pp.ua/*`）；
3. DNS 里给 `*.rt.mus.pp.ua` 或具体名字建一条 **DNS only（灰云）** 的 A 记录，指向当前公网 IP——开橙云会把跳转变回 Worker，形成环路。

Worker 代码内嵌在本脚本里，每次部署整份覆盖，不需要 Dashboard 手工同步。

## 故障排查

| 现象 | 原因 | 处置 |
| --- | --- | --- |
| `❌ 缺少参数：token account ...` | 参数没传全 | 检查命令行/环境变量 |
| `调用脚本失败：signal: killed` | 15 秒超时（多半是重拨瞬间链路卡住） | 手动跑一次，或套 `retry.sh` |
| `❌ Worker 部署失败` + `{"success":false,...}` | Token 权限/过期，或出口到 `api.cloudflare.com` 不通 | `curl https://api.cloudflare.com/client/v4/user/tokens/verify -H "Authorization: Bearer <token>"` |
| Worker 端口一直不变 | 端口没变（不触发）或本轮失败 | 看 Lucky 日志里的“公网地址已变化” |
| 端口对、外面还是连不上 | 打洞没成 / 最外层 NAT 又改了一次端口 | `check-host.net/check-tcp` 测公网 IP:端口 |

## 已知限制

- 只在端口变化时触发；失败的那一轮不会自动补，Worker 会停在旧端口直到下次变化（或用 `retry.sh` 兜住这一轮）。
- 双层 NAT 下，光猫可能再改一次端口（本地端口 ≠ 路由器映射端口 ≠ 公网端口）；Worker 里要写的是**公网端口**。
- 如果跳转后缀在 Cloudflare 上没有任何记录，307 的目标根本解析不了——端口再对也没用。