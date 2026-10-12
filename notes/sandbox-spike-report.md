# TASK-sandbox-spike 结论报告：seatbelt 探针

- 日期：2026-10-12
- 探针：`Scripts/sandbox-spike/probe.swift`（单文件 Swift 脚本，Foundation `Process` 包装 `/usr/bin/sandbox-exec -p <动态 .sbpl>`）
- 运行方式：`swift Scripts/sandbox-spike/probe.swift`（一条命令跑完矩阵，打印逐项 PASS/FAIL 与汇总；全过退出码 0，否则 1）
- 最终实测：**PASS 10/10**，`PROBE_EXIT=0`
- 结论：**通路可行**。`Process` + `/usr/bin/sandbox-exec -p <动态 profile>` 端到端行为符合预期，推荐 base profile 模板见下文，可直接供 TASK-sandbox-core 消费。

## 1. 验证矩阵逐项实测结果

| # | 项目 | 沙箱内命令 | 实测结果 | 证据 |
|---|------|-----------|---------|------|
| 1 | stdout/stderr 透传 | `echo out-spike; echo err-spike >&2` | PASS | exit=0；stdout 原样 `"out-spike\n"`，stderr 原样 `"err-spike\n"` |
| 2 | 环境变量透传 | `printf '%s' "$SPIKE_TOKEN"`（父进程 env 注入 `SPIKE_TOKEN=token-abc-123`） | PASS | exit=0；stdout=`token-abc-123` |
| 3 | 退出码透传 | `exit 42` | PASS | 父进程 `terminationStatus == 42` |
| 4 | stdin 透传 | `IFS= read -r line; echo "got:$line"`（父进程写入 `hello-from-stdin\n`） | PASS | exit=0；stdout=`got:hello-from-stdin\n` |
| 5 | workspace-write 允许 | `echo data > "$PWD/spike-write-ok.txt"`（cwd=可写根） | PASS | exit=0，文件落盘且父进程可见 |
| 6 | workspace-write 拒绝 | `echo nope > "$HOME/sandbox-spike-denied-<pid>.txt"`（cwd 之外） | PASS（被拒绝，符合预期） | exit=1；stderr=`/bin/sh: /Users/boyang/sandbox-spike-denied-<pid>.txt: Operation not permitted`；文件未创建 |
| 7 | 只读路径 | `cat /etc/hosts` | PASS | exit=0，stdout 含 `localhost` |
| 8 | 网络关 | `unset 代理变量; curl --max-time 5 -sS https://example.com -o /dev/null`（profile 无 network allow） | PASS（被拒绝，符合预期） | exit=6；stderr=`curl: (6) Could not resolve host: example.com` |
| 9 | 网络开 | 同上命令，profile 追加 `(allow network*)` | PASS | 实测抓到 exit=0、stderr 为空（DNS 解析 + HTTPS 全通） |
| 10 | sandbox-exec 绝对路径 | 探针内常量 `"/usr/bin/sandbox-exec"` | PASS | 绝对路径、存在且可执行；对齐 Codex `MACOS_PATH_TO_SEATBELT_EXECUTABLE`（防 PATH 注入） |

汇总输出样例（末次运行）：

```
===== SUMMARY =====
#1	PASS	stdout/stderr 透传
#2	PASS	环境变量透传
#3	PASS	退出码透传 (exit 42)
#4	PASS	stdin 透传
#5	PASS	workspace-write 允许 (cwd 下写文件)
#6	PASS	workspace-write 拒绝 ($HOME/cwd 之外)
#7	PASS	只读路径 (/etc/hosts 可读)
#8	PASS	网络关 (无 network allow, curl 被拒)
#9	PASS	网络开 (allow network*, curl 成功)
#10	PASS	sandbox-exec 绝对路径硬编码
PASS 10/10
PROBE_EXIT=0
```

## 2. 沙箱拒绝特征清单（TASK-sandbox-approval 第一手数据）

拒绝表现为**子进程在 syscall 层拿到 EPERM，错误文本由子进程自己（shell/curl）渲染**，`sandbox-exec` 本身不向 stderr 追加任何前缀（`-p` 模式无日志前缀），退出码也是子进程自己的退出码。

### 2.1 文件写拒绝（矩阵 #6）

- 触发：向 profile 未放行的路径写文件（shell 重定向 `>`）
- 退出码：**1**（`/bin/sh` 对重定向失败的通用退出码，非 sandbox 专属）
- stderr 原文（实测）：
  ```
  /bin/sh: /Users/boyang/sandbox-spike-denied-73910.txt: Operation not permitted
  ```
- 稳定特征：stderr 含 **`Operation not permitted`**（EPERM 的 strerror），前缀为子进程名 + 目标路径
- 旁证：目标文件未被创建（探针在父进程侧验证 `fileExists == false`）

### 2.2 网络拒绝（矩阵 #8）

- 触发：profile 不含任何 `(allow network*)`，发起 HTTPS 请求
- 退出码：**6**（curl 的 `CURLE_COULDNT_RESOLVE_HOST`——DNS 解析先撞墙）
- stderr 原文（实测）：
  ```
  curl: (6) Could not resolve host: example.com
  ```
- 稳定特征：**`curl: (6) Could not resolve host`**；DNS（mDNSResponder 的 mach-lookup / 53 端口）在 `(deny default)` 下最先被拒，所以网络拒绝通常以 DNS 失败形态出现，而不是 TCP connect EPERM
- 区分要点：沙箱拒绝 = exit 6 + "Could not resolve host"；宿主机网络抖动 = exit 28（timeout）/ 35（SSL reset）等，不要混为一谈

### 2.3 下游检测建议

- 程序化判定不要只看退出码（1 太泛）；建议组合：**stderr 匹配 `Operation not permitted`（文件类）或 `curl: (6) Could not resolve host`（网络类）+ 非零退出码**。
- 若未来需要更强的归因，可在 profile 里给关键子系统加 `(deny ...(with report))` 或读取 unified log 的 sandbox 违规记录（本次未实测，留给 TASK-sandbox-core 评估）。

## 3. 推荐 base profile 模板（供 TASK-sandbox-core 直接消费）

设计原则：`(deny default)` 起手（对齐 codex-rs `seatbelt_base_policy.sbpl`），只放行进程/exec/信号/sysctl/mach/tty 等基础能力；**全局只读**（`file-read*`），写权限仅放行系统临时目录与**可写根 subpath**；网络默认不放行，需要时追加 `(allow network*)`。

```sbpl
(version 1)
(deny default)

; ---- 进程基础能力（对齐 codex-rs seatbelt_base_policy.sbpl）----
(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))
(allow process-info* (target same-sandbox))
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm-read-data ipc-posix-shm-write-data)
(allow pseudo-tty)

; ---- 文件系统：默认全局只读 ----
(allow file-read*)

; ---- 系统临时目录可写（编译器/解释器刚需）----
(allow file-read* file-test-existence file-write*
    (subpath "/tmp")
    (subpath "/private/tmp")
    (subpath "/var/tmp")
    (subpath "/private/var/tmp"))

; ---- 可写根：动态拼接，路径必须先过 realpath(3)（见踩坑 1）----
(allow file-read* file-write* (subpath "<WORKSPACE_REALPATH>"))

; ---- /dev/null 可写 ----
(allow file-write-data
  (require-all
    (path "/dev/null")
    (vnode-type CHARACTER-DEVICE)))

; ---- 网络开关：默认注释掉；需要联网时追加 ----
; (allow network*)
```

使用方式（探针实测形态）：

```swift
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")  // 硬编码绝对路径
proc.arguments = ["-p", profileString, "/bin/sh", "-c", command]
// stdout/stderr/stdin 走 Pipe；terminationStatus 原样透传子进程退出码
```

完整可运行实现见 `Scripts/sandbox-spike/probe.swift`；每次运行会把实际 profile 落盘到工作目录下的 `profile-netoff.sbpl` / `profile-neton.sbpl` 供复核。

## 4. 踩坑记录

1. **`/var` firmlink：writable root 必须先 `realpath(3)`。**
   `NSTemporaryDirectory()` 返回 `/var/folders/...`，但 seatbelt 按真实路径匹配，实际 inode 在 `/private/var/folders/...`。`URL.resolvingSymlinksInPath()` **不会**解析 `/var` firmlink（实测无效），必须用 `realpath(3)`（要求路径已存在）或等价 canonicalize。这正是 Codex `normalize_writable_root_for_sandbox` 拒绝 symlink writable root 的原因。不处理的话，workspace-write 放行会落空（#5 首轮 FAIL 即此因）。
2. **父进程代理环境变量会透传进沙箱，污染网络测试。**
   本机 shell 带 `https_proxy=127.0.0.1:1082`，curl 在沙箱里走代理导致 #8/#9 首轮判定失真（exit 7 / timeout）。网络矩阵必须显式 `unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY` 后再测。下游实现若要做网络开关语义测试，同样要先清代理。
3. **Pipe 必须并发读，否则管道缓冲打满死锁。**
   `Process` 的 stdout/stderr 各起一个异步读（`DispatchGroup` + `readDataToEndOfFile`），`waitUntilExit` 后再 join；stdin 写完立刻 `closeFile()`，否则沙箱内 `read` 永远等不到 EOF。
4. **example.com 直连在宿主机网络上本身抖动（超时/SSL reset）。**
   #9 的判据不能只看 `exit==0`：沙箱拒绝的确定性特征是 exit 6 + `Could not resolve host`（DNS EPERM），而 exit 28/35 是宿主机网络问题。探针采用「exit==0 直接过；否则失败特征非沙箱拒绝也算放行生效（最多重试 3 次）」，末次运行实测抓到 exit=0。
5. **拒绝信号来自子进程自身，sandbox-exec 不加前缀。**
   `-p` 模式下 sandbox-exec 不写任何拒绝日志到 stderr，退出码也是子进程的。审批检测要面向子进程 stderr 文本特征（见 §2），不要期待统一的 sandbox 错误格式。

## 5. 参考实现对照

- `codex-rs/sandboxing/src/seatbelt.rs`：`MACOS_PATH_TO_SEATBELT_EXECUTABLE = "/usr/bin/sandbox-exec"`（本探针 #10 对齐）；writable root 走 canonicalize + 拒绝 symlink（本探针踩坑 1 对齐）；profile 组成为 base + network + preferences + 动态 READABLE/WRITABLE_ROOT param 拼接（本探针用直接字符串插值，下游可升级为 `-D` param 形式）。
- `codex-rs/sandboxing/src/seatbelt_base_policy.sbpl`：本模板取其 `(deny default)` + process/sysctl/mach/tty 基础放行骨架，按需精简（未搬 Java sysctl-write、KMP shm 名 regex 等按需项）。
