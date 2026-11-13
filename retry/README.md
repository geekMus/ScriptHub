# retry

一个文件，只干一件事：命令失败就再跑几次。要跑什么全靠参数，自己不含任何业务。

## 用法

```sh
# 跑本地命令
sh retry.sh -n 3 -i 2 -- sh /opt/backup.sh /data

# 跑远程脚本：每轮重新下载 + 校验语法 + 执行，参数原样传过去
sh retry.sh -n 2 -i 1 -u https://raw.githubusercontent.com/geekMus/ScriptHub/main/lucky-stun-worker/lucky-stun-worker.sh \
  -- --token "$CF_WORKER_API_TOKEN" --account "$CF_ACCOUNT_ID" \
     --domain mus.pp.ua --suffix rt.mus.pp.ua --port 5267
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-n` | 3 | 最多试几次 |
| `-i` | 2 | 两次之间等几秒 |
| `-q` | 关 | 不打印进度（全部失败时仍会在 stderr 写一行结果） |
| `-d` | 0 | 下载阶段超时秒数（0 = 不限）；>0 时给 `curl` 加 `--max-time` |
| `-x` | 0 | 执行阶段超时秒数（0 = 不限）；>0 时用 `timeout -s KILL` 包住执行 |
| `-u` / `--url` | 空 | 远程脚本地址；给了就走“下载后执行” |

只看退出码：0 算成功，非 0 就重试。最终退出码 = 最后一次的结果；参数写错返回 2。

**每阶段超时**：`-d` 管下载、`-x` 管执行，默认 0（不限）。超时和失败一样处理——算这一轮失败，按 `-n`/`-i` 继续重试，全部失败时退出码是 124（下载超时）或 137（执行被 KILL）。系统里没有 `timeout` 命令时 `-x` 会被忽略并打一行告警。注意 `timeout` 只杀直接子进程，若目标脚本自己派生后台进程，需要由它自己收尾。

## 在 Lucky 里

把 `retry.sh` 和基础脚本一起放进容器，脚本框粘：

```sh
sh /app/conf/retry.sh -n 2 -i 1 -d 2 -x 3 -- sh /app/conf/lucky-stun-worker.sh \
  --token "..." --account "..." --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

Lucky 对每轮脚本只有 **15 秒**：单次请求约 5 秒，加超时后一轮最多 2+3 秒，两轮加间隔约 11 秒，塞得进去。再长就得靠 Lucky 自己的 15 秒兜底。

## 在 DPanel 计划任务里

超时按阶段给：拉 `retry.sh` 本身 30 秒、下载目标脚本 20 秒、执行 150 秒，三层叠加的上限（3 轮）约 514 秒，压得住 DPanel 的 600 秒：

```sh
R=/tmp/retry.sh
curl -fsSL --http1.1 --max-time 30 \
  "https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/ScriptHub/main/retry/retry.sh" \
  -o "$R" || { echo "ERR 拉取 retry.sh 失败" >&2; exit 1; }
sh "$R" -n 3 -i 2 -d 20 -x 150 \
  -u "https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/ScriptHub/main/container-autoupdate/container-autoupdate.sh" \
  -- --compose myapp
```

两个地址都是完整的文件地址，不用仓库基址再拼相对路径。

## 退出码

| 场景 | 码 |
| --- | --- |
| 成功 | 0 |
| 全部失败 | 最后一次的退出码 |
| 参数写错 / 没给命令 | 2 |