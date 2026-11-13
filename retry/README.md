# retry

通用重试入口。整个目录只有**一个文件**，它自己不干任何业务：要跑什么、参数是什么，全部从命令行传进来。

基础脚本保持“跑一次、用退出码说话”，需要重试就在外面套这一层——这样重试策略（跑几次、隔多久、静不静默）随时能换，不用改业务代码。

## 两种用法

### 1. 重试一条本地命令

```sh
sh retry.sh -n 3 -i 2 -- sh ../container-autoupdate/container-autoupdate.sh --compose myapp
sh retry.sh -n 5 -- sh /opt/scripts/backup.sh /data
```

### 2. 重试一个远程脚本（每轮重新下载）

```sh
sh retry.sh -n 3 -u https://raw.githubusercontent.com/geekMus/ScriptHub/main/lucky-stun-worker/lucky-stun-worker.sh \
  -- --token "$CF_WORKER_API_TOKEN" --account "$CF_ACCOUNT_ID" \
     --domain mus.pp.ua --suffix rt.mus.pp.ua --port 5267
```

`-u` 后面的参数会原样传给被下载的脚本；每轮都会重新下载（下载失败也算这一轮失败），下载后先做“非空 + `sh -n` 语法检查”再执行。

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-n` | 3 | 最多尝试几次 |
| `-i` | 2 | 两次之间等几秒 |
| `-q` | 关 | 安静模式：不打印每轮进度；全部失败时仍会在 stderr 写一行结果（计划任务只留 stderr，这行不能丢） |
| `-u` / `--url` | 空 | 远程脚本地址；给了它就走“下载后执行”模式 |

判定只看**退出码**：0 即成功，非 0 才重试。最终退出码 = 最后一次执行（或下载/校验）的退出码；参数错误返回 2。

## 在 Lucky 里用

Lucky 的脚本框只能粘一段文本，所以把 `retry.sh` 和基础脚本一起放进容器（宿主机 `/root/lucky/conf/` → 容器 `/app/conf/`），然后粘一行：

```sh
sh /app/conf/retry.sh -n 3 -i 1 -- sh /app/conf/lucky-stun-worker.sh \
  --token "..." --account "..." --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

Lucky 对每轮脚本有 **15 秒硬超时**，所以次数和间隔要留余量：基础脚本单次最长约 5 秒，3 次 + 1 秒间隔 ≈ 17 秒——超了就把 `-n` 降到 2，或把 `-i` 设成 0。

## 退出码速查

| 场景 | 退出码 |
| --- | --- |
| 成功 | 0 |
| 全部尝试都失败 | 最后一次的退出码 |
| 参数写错 / 没给命令 | 2 |