# lucky-stun-worker

Lucky 的 STUN 穿透打出新端口后，把新端口写进 Cloudflare Worker 的脚本。

**运行位置**：Lucky 容器内部，由 Lucky 自己调用（STUN 规则 → 编辑 → 脚本/Webhook）。不依赖宿主机、不依赖任何外挂守护进程。

## 为什么需要它

家里的宽带是双层 NAT（光猫 + 小米路由），公网 IPv4 端口每次重拨都换。玩法是：

```
浏览器  https://<名字>.mus.pp.ua        ← Cloudflare 上的 Worker 路由
   │
   ├─ Worker 307 → https://<名字>.rt.mus.pp.ua:<当前打洞端口>
   │
   └─ rt.mus.pp.ua 是 DNS only 记录，直接指回公网 IP
```

所以 Worker 里必须存着**当前**的打洞端口。Lucky 只要端口变了就会调用这段脚本。

## 为什么内置重试

Lucky 对每轮脚本有 **15 秒硬超时**，超时就 `SIGKILL`，日志里是：

```
调用脚本失败：signal: killed
```

而运营商重拨的那几秒，容器到 `api.cloudflare.com` 的连接会被拖住（实测直接超时 15 秒）。Lucky 不会重试，Worker 就停在旧端口——外网表现为“端口能 ping 通但访问不了”。

脚本因此把部署改成最多 3 次，每次 `--connect-timeout 2 --max-time 3`、间隔 1 秒：最坏 **3+1+3+1+3 = 11 秒**，留 4 秒余量。

## 配置

脚本顶部四个值必须填：

| 变量 | 说明 |
| --- | --- |
| `CF_WORKER_API_TOKEN` | Cloudflare API Token，权限 **Workers Scripts:Edit**，建议只授权这一个账号 |
| `CF_ACCOUNT_ID` | Cloudflare 账户 ID |
| `BASE_DOMAIN` | 主域名，例如 `mus.pp.ua` |
| `V4_SUFFIX` | 跳转目标的后缀，例如 `rt.mus.pp.ua` |

其余两项一般不用改：`WORKER_NAME`（Worker 脚本名，默认 `stun-redirect`）、`V6_SUFFIX` / `V6_PORT`（IPv6 侧，端口固定 100）。

**`V4_PORT` 不要手填**：写的是 `V4_PORT="${port}"`，Lucky 在调用脚本前会把 `${port}` 替换成本次打洞端口。手动测试时留空会直接报错退出，避免把 0 部署上去。

## Cloudflare 侧要准备的

1. 一个 Worker，名字和 `WORKER_NAME` 一致；
2. Worker 路由 / 自定义域名把 `*.<主域名>` 指到它（例如 `*.mus.pp.ua/*`）；
3. DNS 里给 `*.rt.mus.pp.ua` 或具体名字建一条 **DNS only（灰云）** 的 A 记录，指向当前公网 IP —— 注意 Cloudflare 代理会把跳转变成环路，别开橙云。

`worker.js` 是线上 Worker 的一份快照，方便直接读/在 Dashboard 里手工部署；**真正生效的是脚本里内嵌的那份**（每次部署整份覆盖），两边同步修改。

## 用法

1. Cloudflare 上建好 Worker（可以先拿 `worker.js` 手工部署一次）；
2. Lucky → STUN 穿透 → 规则 → 编辑 → 脚本/Webhook，把 `lucky-stun-worker.sh` 整段粘进去，填好四个配置；
3. 保存后重启一次 Lucky，确认日志出现 `✅ Worker 部署成功（<端口>）`；
4. 用外部探测（例如 check-host.net 的 TCP 检测）验证 `公网IP:<端口>` 能连上。

## 故障排查

| 现象 | 原因 | 处置 |
| --- | --- | --- |
| `调用脚本失败：signal: killed` | 15 秒超时 | 看是不是刚重拨；重试补丁已内置，仍失败就手动跑一次 |
| `❌ Worker 部署失败` + `{"success":false,...}` | Token 权限/过期，或容器出不了网 | 容器里 `curl https://api.cloudflare.com/client/v4/user/tokens/verify` 看返回 |
| Worker 端口一直不变 | 脚本没被触发（端口没变）或脚本失败 | 看 Lucky 日志里的“公网地址已变化”与脚本输出 |
| 端口对、外面还是连不上 | 打洞没成 / 最外层 NAT 又改了一次端口 | `check-host.net/check-tcp` 测；再看路由器 UPnP 表里的外部端口 |

## 已知限制

- 只在端口变化时触发；失败的这一轮不会补，Worker 会停在旧端口直到下次变化。
- 双层 NAT 下，光猫那层可能再改一次端口（本地端口 ≠ 路由器映射端口 ≠ 公网端口），Worker 里要写的是**公网端口**。
- 如果 `rt.mus.pp.ua` 在 Cloudflare 上没有任何记录，Worker 的 307 目标根本解析不了——端口再对也不行。