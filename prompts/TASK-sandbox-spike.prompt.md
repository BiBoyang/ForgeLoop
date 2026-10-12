---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-sandbox-spike.md
status: done
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：seatbelt 探针（TASK-sandbox-spike）

## 目标
验证"Swift `Process` 包装 `/usr/bin/sandbox-exec -p <动态生成的 .sbpl>`"端到端通路，产出结论报告与 base profile 模板草稿。
成功标准：探针一条命令跑完验证矩阵并打印 PASS/FAIL 汇总；报告含逐项实测结果与沙箱拒绝特征清单。

## 涉及文件（绝对路径）
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Scripts/sandbox-spike/`（探针代码，可以是 `swift` 脚本或 shell+swift 组合，自选最简形态）
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/notes/sandbox-spike-report.md`

## 验收标准（DoD）
1. 验证矩阵 10 项逐项实测通过并记录（见 TASK 文件"验证矩阵"节，逐项覆盖，不得跳项）
2. 沙箱拒绝场景（矩阵 6/8）必须记录退出码与 stderr 原文特征——下游审批任务要用
3. 报告含推荐 base profile 模板全文（`(deny default)` 起手 + 可写根 subpath 放行）
4. 参考实现（只读，不得修改）：`/Users/boyang/Desktop/Agent 源码解读/codex 源码解读/codex-src/codex-rs/sandboxing/src/seatbelt.rs`
5. 探针代码放 Scripts/sandbox-spike/，不得改动 Sources/、Tests/、Package.swift

## 上游任务产出
无（批次 1，首个任务）

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-sandbox-spike.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
