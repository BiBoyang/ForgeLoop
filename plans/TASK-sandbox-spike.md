# TASK-sandbox-spike：seatbelt 探针

- 状态：done
- 依赖：无（批次 1）
- 下游：TASK-sandbox-core（消费本任务的 profile 模板与结论）

## 目标
验证"Swift `Process` 包装 `/usr/bin/sandbox-exec -p <动态生成的 .sbpl>`"这条端到端通路行为符合预期，产出可直接用于 TASK-sandbox-core 的 base profile 模板与结论报告。探不通则整个沙箱方案回炉。

## 涉及文件（绝对路径）
- 新建目录 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Scripts/sandbox-spike/`（探针代码全部放这里，不进 Sources/）
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/notes/sandbox-spike-report.md`（结论报告）

## 验证矩阵（探针必须逐项实测并记录）
1. stdout/stderr 透传：沙箱内 `echo`/`>&2 echo` 输出原样回到父进程
2. 环境变量透传：父进程注入的 env 在沙箱内可见
3. 退出码透传：沙箱内 `exit 42` → 父进程拿到 42
4. stdin 透传：父进程写 stdin，沙箱内 `read` 能收到
5. workspace-write 允许：向 cwd 下写文件成功
6. workspace-write 拒绝：向 `$HOME` 下、cwd 之外的路径写入被拒（记录拒绝时的退出码与 stderr 特征——这是 TASK-sandbox-approval 拒绝检测的第一手数据）
7. 只读路径：读 `/etc/hosts` 成功
8. 网络关：profile 不含 network allow 时，`curl --max-time 5 https://example.com` 被拒（记录 stderr 特征）
9. 网络开：profile 含 `(allow network*)` 时同上命令成功
10. 路径硬编码：使用 `/usr/bin/sandbox-exec` 绝对路径（防 PATH 注入，对齐 Codex）

## DoD
- 探针可用一条命令跑完全部矩阵并打印 PASS/FAIL 汇总
- 报告含：矩阵逐项结果、沙箱拒绝时的退出码/stderr 特征清单、推荐 base profile 模板全文、踩坑记录
- 参考材料（只读）：`/Users/boyang/Desktop/Agent 源码解读/codex 源码解读/codex-src/codex-rs/sandboxing/src/seatbelt.rs` 与 `core/assets/seatbelt_base_policy.sbpl`（若存在，以实际文件为准）

## 验证命令
- 探针自带汇总输出；报告中逐条附命令与实测输出
