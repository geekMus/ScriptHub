# lucky-stun-worker

Lucky 的 STUN 打出新端口后，把端口写进 Cloudflare Worker。一个文件，参数全从命令行来。

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
| `--token` | `CF_WORKER_API_TOKEN` | CF API Token，权限 **Workers Scripts:Edit** |
| `--account` | `CF_ACCOUNT_ID` | CF 账户 ID |
| `--domain` | `BASE_DOMAIN` | 主域名，如 `mus.pp.ua` |
| `--suffix` | `V4_SUFFIX` | IPv4 跳转后缀，如 `rt.mus.pp.ua` |
| `--port` | `port` | 本次打洞的公网端口 |
| `--worker` | `WORKER_NAME` | Worker 名，默认 `stun-redirect` |
| `--v6-suffix` | `V6_SUFFIX` | 默认同 `--suffix` |
| `--v6-port` | `V6_PORT` | 默认 `100` |
| `--dry-run` | — | 只打印结果，不部署 |

- 成功：`✅ Worker 部署成功（rt.mus.pp.ua:5267）`，退出码 0
- 失败：打印 CF 原始响应，退出码 1
- 缺参数 / 端口非法：直接报错退出，不会把空值部署上去

只跑一次，不重试。

## 在 Lucky 里用

把脚本放进宿主机 `/root/lucky/conf/`（已挂载到容器 `/app/conf/`），Lucky → STUN 穿透 → 规则 → 编辑 → 脚本，粘一行：

```sh
sh /app/conf/lucky-stun-worker.sh \
  --token "你的Token" --account "你的账户ID" \
  --domain "mus.pp.ua" --suffix "rt.mus.pp.ua" \
  --port "${port}"
```

`${port}` 由 Lucky 替换成本次端口。需要重试就套一层：

```sh
sh /app/conf/retry.sh -n 2 -i 1 -- sh /app/conf/lucky-stun-worker.sh \
  --token "..." --account "..." --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

Lucky 每轮脚本 **15 秒**超时（超了是 `调用脚本失败：signal: killed`）。本脚本单次最长约 5 秒，所以最多 `-n 2 -i 1`（≈11 秒）；`-n 3` 会超时。

## Cloudflare 侧要有

1. 一个叫 `stun-redirect` 的 Worker（或你在 `--worker` 里指定的名字）
2. 路由把 `*.mus.pp.ua/*` 指过去
3. DNS 给 `*.rt.mus.pp.ua` 建 **DNS only（灰云）** 的 A 记录，指向当前公网 IP（开橙云会形成跳转环路）

## 出问题看这里

| 现象 | 原因 / 处置 |
| --- | --- |
| `❌ 缺少参数：...` | 参数没给全 |
| `调用脚本失败：signal: killed` | 撞上 15 秒超时，多半是重拨瞬间链路卡住；手动跑一次 |
| `❌ Worker 部署失败` + `success:false` | Token 权限/过期，或容器到 `api.cloudflare.com` 不通 |
| 端口对、外面还是连不上 | 用 `check-host.net/check-tcp` 测“公网 IP:端口”，确认打洞本身通 |

## 已知限制

- 只在端口变化时触发；失败那一轮不会自动补，Worker 停在旧值直到下次变化（套 `retry.sh` 可以兜住这一轮）。
- 双层 NAT 下光猫可能再改一次端口，Worker 要写的是**公网端口**，不是本地端口。
- 跳转后缀在 CF 上没有 DNS 记录的话，307 跳过去也解析不了。