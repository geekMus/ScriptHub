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
| `-u` / `--url` | 空 | 远程脚本地址；给了就走“下载后执行” |

只看退出码：0 算成功，非 0 就重试。最终退出码 = 最后一次的结果；参数写错返回 2。

**不管超时。** 下载和执行都不设超时，多久算超时交给外层：Lucky 对每轮脚本 15 秒，DPanel 计划任务用它自己的超时（我们设的是 600 秒），你也可以自己套 `timeout`。

## 在 Lucky 里

把 `retry.sh` 和基础脚本一起放进容器，脚本框粘：

```sh
sh /app/conf/retry.sh -n 2 -i 1 -- sh /app/conf/lucky-stun-worker.sh \
  --token "..." --account "..." --domain mus.pp.ua --suffix rt.mus.pp.ua --port "${port}"
```

Lucky 对每轮脚本只有 **15 秒**，单次请求最坏约 5 秒，所以 `-n 2 -i 1` 是上限。

## 在 DPanel 计划任务里

超时交给 DPanel（我们设 600 秒），脚本里只写重试：

```sh
R=/tmp/retry.sh
curl -fsSL --http1.1 \
  "https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/ScriptHub/main/retry/retry.sh" \
  -o "$R" || { echo "ERR 拉取 retry.sh 失败" >&2; exit 1; }
sh "$R" -n 3 -i 2 \
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