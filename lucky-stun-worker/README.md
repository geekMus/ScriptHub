# lucky-stun-worker

把 Lucky STUN 打洞得到的公网端口写进 Cloudflare Worker。单文件、每次执行只部署一次、用退出码说话。

## 用法

只有两个变量：脚本地址（远程或本地都行）和一段参数。Lucky 的 STUN 规则每次端口变化只调一次，把整段填进规则的「脚本」栏。

```sh
# 地址：远程脚本地址；本地已有文件就写路径
URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/lucky-stun-worker/lucky-stun-worker.sh"
# 参数：全部写在一个变量里
ARGS="--token $CF_WORKER_API_TOKEN --account $CF_ACCOUNT_ID --domain example.com --suffix rt.example.com --port ${port} --worker stun-redirect"

# 远程地址：下载一次再执行
curl -fsSL --http1.1 --max-time 3 "$URL" -o /tmp/lucky-stun-worker.sh \
  || { echo "✗ 拉取脚本失败" >&2; exit 1; }
sh /tmp/lucky-stun-worker.sh $ARGS

# 本地路径：直接执行
sh "$URL" $ARGS
```

部署成功的最后一行是 `✓ 部署成功 *.rt.example.com:12345（2s）`。那个 `*` 表示「任意子域名」：访问 `a.example.com` 会被 307 到 `a.rt.example.com:12345`，访问 `xyz.example.com` 就到 `xyz.rt.example.com:12345`，只有访问裸域名 `example.com` 才直接跳 `rt.example.com:12345`。所以 CF 上要解析的是 `*.rt.example.com`（或具体那个子域），不是 `rt.example.com` 本身。

`ARGS` 里的 `${port}` 是 Lucky 的占位符，运行前会替换成实际端口；`example.com` / `rt.example.com` 换成自己的域名。Lucky 每轮只有 **15 秒**：拉脚本与部署一般合计 2–6 秒，够用。

## 参数

| 参数 | 环境变量 | 说明 |
| --- | --- | --- |
| `--token` | `CF_WORKER_API_TOKEN` | CF API Token，权限 **Workers Scripts:Edit** |
| `--account` | `CF_ACCOUNT_ID` | CF 账户 ID |
| `--domain` | `BASE_DOMAIN` | 主域名，如 `example.com`（**必填**） |
| `--suffix` | `V4_SUFFIX` | IPv4 跳转后缀，如 `rt.example.com`（**必填**） |
| `--port` | `port` | 本次打洞的公网端口（Lucky 自动替换） |
| `--worker` | `WORKER_NAME` | Worker 名，默认 `stun-redirect` |
| `--v6-suffix` | `V6_SUFFIX` | 默认同 `--suffix` |
| `--v6-port` | `V6_PORT` | 默认 `100` |
| `--dry-run` | — | 只打印解析结果，不部署 |

`--token`、`--account`、`--domain`、`--suffix`、`--port` 都没有默认值：少传一个就打印 `✗ 缺少参数：…` 并以 `1` 退出，不会把示例域名部署上去。命令行参数优先于环境变量。

## 退出码

| 码 | 含义 | 外层怎么办 |
| --- | --- | --- |
| `0` | 部署成功 | 结束 |
| `75` | 临时失败：连不上 `api.cloudflare.com`、请求超时、CF 返回 5xx/429 | 可以再试 |
| `1` | 参数缺失、端口非法、Token/账户错误、CF 明确拒绝（4xx） | 重试没有意义 |

脚本自己不做重试，只如实报告这一次的结果。

## 出问题看这里

| 现象 | 原因 / 处置 |
| --- | --- |
| `调用脚本失败：signal: killed` | Lucky 15 秒超时；通常是拉脚本或 CF 请求被网络拖住 |
| `✗ Worker 部署失败（HTTP 4xx）` | Token 权限/过期，或账户 ID 不对；重试无用 |
| `✗ 连不上 Cloudflare（curl …）` | 容器到 CF 不通；确认 `api.cloudflare.com` 的分流 |
| 端口对、外面连不上 | 用 check-host.net 测「公网 IP:端口」，确认打洞本身通 |
| Worker 里是旧端口 | 那次部署失败了；看 Lucky 日志那行，按退出码判断是 `75` 还是 `1` |

## 已知限制

- 双层 NAT 下光猫可能再改一次端口；Worker 要写的是**公网端口**，不是本地端口。
- 跳转后缀在 CF 上没有 DNS 记录时，307 跳过去也解析不了。
- 部署失败不会自动补偿：Lucky 只在端口变化时调用，失败就等下一次变化（刻意不要守护进程）。
