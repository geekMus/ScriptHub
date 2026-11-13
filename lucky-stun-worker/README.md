# lucky-stun-worker

Lucky 的 STUN 每打出一个新端口，就把它写进 Cloudflare Worker。

这里有两个角色：

| 谁 | 干什么 | 跑在哪 |
| --- | --- | --- |
| Lucky | **只通知**：把新端口写进一个文件，立刻返回 | 容器里 |
| `watch.sh` | 看到端口变了就调用部署脚本，失败按 5→10→20→40→80→160→300 秒退避重试，直到成功 | 宿主机 |

为什么这样分工：Lucky 对规则脚本有 **15 秒硬超时**（超了就是 `调用脚本失败：signal: killed`），重拨的瞬间链路正卡，脚本很容易被杀掉，Worker 就停在旧端口。把“部署 + 重试”挪到宿主机，超时和重试次数都由宿主机决定，Lucky 那边只写一行文件，永远不会超时。

## 文件

| 文件 | 用途 |
| --- | --- |
| `lucky-stun-worker.sh` | 部署脚本：拿端口调 CF API，单次执行，用退出码说话 |
| `watch.sh` | 宿主机侧：盯端口文件，变了就调用部署脚本（带退避重试） |

## 装到宿主机

1. 放脚本：

```sh
install -m 0755 lucky-stun-worker.sh /usr/bin/lucky-stun-worker.sh
install -m 0755 watch.sh             /usr/bin/lucky-stun-watch.sh
```

2. 写配置 `/etc/stun-worker.conf`（`chmod 600`，里面是 Token，别外传）：

```sh
TOKEN="你的 Cloudflare API Token"      # 权限：Workers Scripts:Edit
ACCOUNT="你的账户 ID"
DOMAIN="mus.pp.ua"
SUFFIX="rt.mus.pp.ua"
# WORKER="stun-redirect"               # 可选，默认就是它
```

3. 起 procd 服务 `/etc/init.d/stun-worker-watch`：

```sh
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/lucky-stun-watch.sh
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
```

```sh
chmod +x /etc/init.d/stun-worker-watch
/etc/init.d/stun-worker-watch enable
/etc/init.d/stun-worker-watch start
```

4. Lucky 里：STUN 穿透 → 规则 → 编辑 → 脚本，只粘这一行：

```sh
[ -n "${port}" ] && echo "${port}" > /app/conf/.stun-port.new && mv /app/conf/.stun-port.new /app/conf/stun-port
```

`${port}` 由 Lucky 替换成本次打洞端口；先写临时文件再 `mv` 是原子的，宿主机不会读到写了一半的文件。

日志在 `/tmp/stun-worker-watch.log`：

```text
2026-11-13 12:16:30 watch 启动：file=/root/lucky/conf/stun-port script=/usr/bin/lucky-stun-worker.sh poll=3s max=0
2026-11-13 12:16:33 部署 6001，第 1 次
2026-11-13 12:16:33 成功：端口 6001（第 1 次）
```

## watch.sh 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-c` | `/etc/stun-worker.conf` | 配置文件（shell 片段） |
| `-f` | `/root/lucky/conf/stun-port` | 端口文件（容器内 `/app/conf/stun-port`） |
| `-s` | `/usr/bin/lucky-stun-worker.sh` | 部署脚本 |
| `-p` | `3` | 轮询间隔秒 |
| `-n` | `0` | 每个端口最多试几次；`0` = 一直重试 |
| `-t` | 同端口文件目录下的 `.stun-port.last` | 已部署端口的记录文件 |
| `--once` | — | 只处理当前端口一次，调试用 |

端口没变不会重复部署；上次成功部署的端口记在状态文件里，所以重启宿主机或服务后也能接着用。

## 直接调部署脚本（不经 watch.sh）

```sh
sh lucky-stun-worker.sh \
  --token   "$TOKEN" \
  --account "$ACCOUNT" \
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

## Cloudflare 侧要有

1. 一个叫 `stun-redirect` 的 Worker（或你在 `--worker` 里指定的名字）
2. 路由把 `*.mus.pp.ua/*` 指过去
3. DNS 给 `*.rt.mus.pp.ua` 建 **DNS only（灰云）** 的 A 记录，指向当前公网 IP（开橙云会形成跳转环路）

## 出问题看这里

| 现象 | 原因 / 处置 |
| --- | --- |
| 日志一直不动 | 端口文件没写进来：`docker exec lucky cat /app/conf/stun-port` 看看 |
| `❌ Worker 部署失败` + `success:false` | Token 权限/过期，或宿主机到 `api.cloudflare.com` 不通 |
| 端口对、外面还是连不上 | 用 `check-host.net/check-tcp` 测“公网 IP:端口”，确认打洞本身通 |
| 一直重试同一次 | 看日志里的 CF 响应；`-n 3` 可以限制次数 |

## 已知限制

- 双层 NAT 下光猫可能再改一次端口，Worker 要写的是**公网端口**，不是本地端口。
- 跳转后缀在 CF 上没有 DNS 记录的话，307 跳过去也解析不了。
- 端口文件和状态文件放在挂载目录里，容器删了重建也还在。