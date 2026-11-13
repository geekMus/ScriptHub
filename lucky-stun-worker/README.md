# lucky-stun-worker

把 Lucky STUN 打洞得到的公网端口写进 Cloudflare Worker。单文件、每次执行只部署一次、用退出码说话。

## 用法（推荐：远程脚本）

Lucky 每次端口变化只会调一次脚本，所以在 STUN 穿透规则的「脚本」栏里直接拉最新版来跑：

```sh
# 脚本地址（换镜像只改这一行；要写 raw.githubusercontent.com 的完整地址）
WORKER_URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/lucky-stun-worker/lucky-stun-worker.sh"

R=/tmp/lucky-stun-worker.sh
curl -fsSL --http1.1 --max-time 3 "$WORKER_URL" -o "$R" \
  || { echo "ERR 拉取脚本失败" >&2; exit 75; }
sh "$R" --token "$CF_WORKER_API_TOKEN" --account "$CF_ACCOUNT_ID" \
  --domain example.com --suffix rt.example.com --port "${port}"
```

`${port}` 是 Lucky 的占位符；`example.com` / `rt.example.com` 换成自己的域名。Lucky 每轮只有 **15 秒**：拉脚本与部署一般合计 2–6 秒，够用。

想多一次重试，就把 `sh "$R" ...` 换成 `retry.sh -n 2 -i 1 -x 3 -- sh "$R" ...`（Lucky 容器里要先有 `retry.sh`；只有 `75` 会重试）。

### 或者先下载、本地运行

把脚本放进 Lucky 容器（宿主 `/root/lucky/conf/` 就是容器里的 `/app/conf/`，本来就挂载着），之后调本地路径，不必每次联网取脚本：

```sh
# 地址（换镜像只改这一行）
WORKER_URL="https://raw.githubusercontent.com/geekMus/ScriptHub/main/lucky-stun-worker/lucky-stun-worker.sh"
curl -fsSL --http1.1 --max-time 30 "$WORKER_URL" -o lucky-stun-worker.sh
install -m 0755 lucky-stun-worker.sh /root/lucky/conf/lucky-stun-worker.sh

# STUN 规则脚本栏：
sh /app/conf/lucky-stun-worker.sh --token "..." --account "..." \
  --domain example.com --suffix rt.example.com --port "${port}"
```

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

`--token`、`--account`、`--domain`、`--suffix`、`--port` 都没有默认值：少传一个就打印 `❌ 缺少参数：…` 并以 `1` 退出，不会把示例域名部署上去。命令行参数优先于环境变量。

## 退出码

| 码 | 含义 | 外层怎么办 |
| --- | --- | --- |
| `0` | 部署成功 | 结束 |
| `75` | 临时失败：连不上 `api.cloudflare.com`、请求超时、CF 返回 5xx/429 | 可以再试 |
| `1` | 参数缺失、端口非法、Token/账户错误、CF 明确拒绝（4xx） | 重试没有意义 |

脚本自己不做重试，只如实报告这一次的结果。

## Cloudflare 侧要有

1. 一个叫 `stun-redirect` 的 Worker（或 `--worker` 指定的名字）。
2. 路由把 `*.example.com/*` 指过去（`example.com` 换成自己的域名）。
3. DNS 给 `*.rt.example.com` 建 **DNS only（灰云）** 的 A 记录，指向当前公网 IP；开橙云会形成跳转环路。

## 出问题看这里

| 现象 | 原因 / 处置 |
| --- | --- |
| `调用脚本失败：signal: killed` | Lucky 15 秒超时；通常是拉脚本或 CF 请求被网络拖住 |
| `❌ Worker 部署失败（HTTP 4xx）` | Token 权限/过期，或账户 ID 不对；重试无用 |
| `❌ 请求失败（curl 退出码 …）` | 容器到 CF 不通；确认 `api.cloudflare.com` 的分流 |
| 端口对、外面连不上 | 用 check-host.net 测「公网 IP:端口」，确认打洞本身通 |
| Worker 里是旧端口 | 那次部署失败了；看 Lucky 日志那行，按退出码判断是 `75` 还是 `1` |

## 已知限制

- 双层 NAT 下光猫可能再改一次端口；Worker 要写的是**公网端口**，不是本地端口。
- 跳转后缀在 CF 上没有 DNS 记录时，307 跳过去也解析不了。
- 部署失败不会自动补偿：Lucky 只在端口变化时调用，失败就等下一次变化（刻意不要守护进程）。
