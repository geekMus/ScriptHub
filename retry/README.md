# retry

本项目专用的一层包装：**只重试「再跑一次有可能成功」的失败**。它不判断业务，只看退出码。

约定只有一个数字：

| 退出码 | 含义 | retry 怎么办 |
| --- | --- | --- |
| `0` | 成功 | 结束 |
| `75` | 临时失败（网络不通、超时、镜像仓库/CF 暂时不可用） | 再试，最多 `-n` 次 |
| `124` / `137` | 被 `-x` 的超时杀掉（目标脚本自己收尾时也可能直接给 `75`） | 再试，最多 `-n` 次 |
| 其它 | 配置错、参数缺、鉴权失败…… | **立即结束**，不重试 |

为什么要这样：把「Token 写错了」重试三次，只会把真错误埋进第三遍日志，还把计划任务的时间预算烧光。写脚本的人最清楚哪类失败是「过一会儿就好」，由脚本自己用退出码说出来。

## 用法

```sh
# 跑本地命令
sh retry.sh -n 3 -i 2 -- sh /opt/backup.sh /data

# 跑远程脚本：只下载一次，然后反复执行（重试不再重新下载）
sh retry.sh -n 3 -i 2 -d 20 -x 150 \
  -u https://raw.githubusercontent.com/geekMus/ScriptHub/main/container-autoupdate/container-autoupdate.sh \
  -- --compose magpie_gateway
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-n` | 3 | 最多执行几次（下载失败也算次数） |
| `-i` | 2 | 两次之间等几秒 |
| `-q` | 关 | 不打印每次尝试的进度，只留最终结果 |
| `-r` | `75` | 可重试退出码，逗号分隔；`124`/`137` 永远算可重试 |
| `-d` | 0 | 下载超时秒数（0 = 不限）；>0 时给 `curl` 加 `--max-time` |
| `-x` | 0 | 执行超时秒数（0 = 不限）；>0 时整个执行过程跑在独立进程组里，到点先 TERM 整组、2 秒后 KILL |
| `-u` / `--url` | 空 | 远程脚本地址：**下载一次**，校验语法后反复执行 |

**下载只做一次**：`-u` 模式下第一次下载成功后就固定用这份临时文件，后面每次重试都是「重新执行」，不会再产生下载流量，也不会出现「同一个地址两次下到不同内容」。

下载阶段本身失败（连不上、超时、语法不对）可按 `-n` 重试；全部失败返回 `75`。

**超时怎么算**：`-d` 管下载、`-x` 管执行，默认 0（不限）。被 `-x` 杀掉返回 `124`/`137`，属于可重试。

`-x` 的实现是「独立进程组 + watchdog」，不是 `timeout`：目标脚本用 `setsid` 放进自己的会话，到点先给**整组**发 TERM（脚本有机会自己打印原因、自己选退出码，比如退 `75`），2 秒后再 KILL 整组。这样脚本里用 `$(docker compose pull ...)` 这类写法派生出来的孙进程不会变成孤儿继续跑（busybox 的 `timeout` 只杀直接子进程，N1 上实测过：脚本 30 秒就结束，计划任务却等满 425 秒，日志里多一行来路不明的 `Killed`）。

同时把 `RETRY_TIMEOUT=<秒>` 放进环境变量。认识它的脚本（本仓库的 `container-autoupdate.sh`）会据此把内部预算压到上限以内、在被杀之前自己收手；不认识的脚本不受影响。系统里没有 `setsid` 也没有 `timeout` 时 `-x` 被忽略并打一行告警。

## 在 Lucky 里

Lucky 对每轮脚本只有 **15 秒**。单次部署约 5 秒，两轮加间隔约 11 秒，能塞进去：

```sh
sh /app/conf/retry.sh -n 2 -i 1 -d 2 -x 3 -u \
  "https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/ScriptHub/main/lucky-stun-worker/lucky-stun-worker.sh" \
  -- --token "..." --account "..." --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

`lucky-stun-worker.sh` 在连不上 CF、超时、CF 返回 5xx/429 时退出 `75`，所以这里只会为「真的可能好」的失败再跑一轮；参数写错时第一轮就结束。

## 在 DPanel 计划任务里

超时按阶段给：拉 `retry.sh` 本身 30 秒、下载目标脚本 20 秒、执行 150 秒。最坏情况（下载重试 3 次 + 执行重试 3 次）约 540 秒，压得住 DPanel 的 600 秒：

```sh
R=/tmp/retry.sh
curl -fsSL --http1.1 --max-time 30 \
  "https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/ScriptHub/main/retry/retry.sh" \
  -o "$R" || { echo "ERR 拉取 retry.sh 失败" >&2; exit 1; }
sh "$R" -n 3 -i 2 -d 20 -x 150 \
  -u "https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/ScriptHub/main/container-autoupdate/container-autoupdate.sh" \
  -- --compose magpie_gateway
```

两个地址都是完整的文件地址，不拼变量、不写相对路径。只走 `github.mus.pp.ua` 一个加速站（后面接完整的 `https://raw.githubusercontent.com/...`；不要用 `github.com/.../raw/`，那个形式会被缓存旧版本）。

`container-autoupdate.sh` 自己会用退出码区分：拉取镜像失败、Docker 暂时连不上 → `75`（值得再跑一轮）；compose 文件错、目标不存在、目录不存在 → `1`（停下来）。所以 DPanel 里的 3 次重试只会在真正有用的时候发生。

它还会读 `RETRY_TIMEOUT`：发现执行上限是 150 秒，就把整轮预算压到 135 秒（留 15 秒收尾）。预算不够时不是硬着头皮往上冲，而是「拉完了但没时间部署」这种状态用 `75` 收手 —— 镜像层已经在本地，下一轮 pull 是空操作，时间全留给 `up -d`，正好落在 150 秒里。所以慢网络下看到的是「每轮做一半、下一轮接着做」，而不是「每轮都被 KILL、日志里什么都没有」。

## 退出码

| 场景 | 码 |
| --- | --- |
| 成功 | 0 |
| 不可重试的失败 | 立即返回该脚本的退出码 |
| 重试耗尽 | 最后一次的退出码 |
| 执行被 `-x` 到点打断 | 124（目标脚本自己收尾时可能给 75） |
| 下载全部失败 | 75 |
| 参数写错 / 没给命令 | 2 |