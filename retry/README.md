# retry

带重试 / 带回退的**入口脚本**。这里不放业务逻辑，只负责把 `../` 里的基础脚本多跑几次。

基础脚本本身保持“跑一次、干净退出码”，推荐用法就是直接跑它；只有确实需要重试时，才用这里的入口去**调用**它。

| 入口 | 给谁用 | 调用谁 |
| --- | --- | --- |
| `retry.sh` | 任何脚本（cron、DPanel 计划任务、手动） | 任意命令，失败重试 |
| `lucky-stun-worker-retry.sh` | Lucky 的“脚本/Webhook”框 | `/app/conf/lucky-stun-worker.sh` |
| `container-autoupdate-install.sh` | DPanel 计划任务（网络不稳） | 下载后运行 `container-autoupdate.sh` |

## retry.sh —— 通用

```sh
sh retry.sh -n 3 -i 2 -- sh ../container-autoupdate/container-autoupdate.sh --compose myapp
```

- `-n` 最多几次（默认 3），`-i` 间隔秒数（默认 2），`-q` 少打印
- 判定标准只看**退出码**：0 就算成功，非 0 才重试
- 退出码 = 最后一次的退出码

## lucky-stun-worker-retry.sh —— Lucky 专用

Lucky 的脚本框只能粘一段文本，没法引用外部文件，所以这里的入口是：先让基础脚本待在容器里，入口再去调它。

1. 把 [`../lucky-stun-worker/lucky-stun-worker.sh`](../lucky-stun-worker/lucky-stun-worker.sh) 放到宿主机的 `/root/lucky/conf/`（该目录已挂载到容器 `/app/conf/`）；
2. 基础脚本里的四个配置照常填；
3. Lucky → STUN 穿透 → 规则 → 编辑 → 脚本/Webhook，粘**本入口**的整段。

时长要卡在 Lucky 的 15 秒硬超时以内：基础脚本单次最长 3 秒，3 次 + 2 秒间隔 = 最坏 11 秒。

## container-autoupdate-install.sh —— DPanel 计划任务

推荐的安装方式是从官方地址直接抓（见 [`../container-autoupdate/README.md`](../container-autoupdate/README.md)）。这个入口多做一层镜像回退：三个源轮流试，`sh -n` + 体积 + 内容关键字都合格才用，全失败就沿用上一轮副本。

计划任务里整段粘进去，末尾把 `--compose myapp` 换成你的目标。