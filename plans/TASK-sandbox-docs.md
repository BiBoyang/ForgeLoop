# TASK-sandbox-docs：文档同步与移植笔记

- 状态：pending
- 依赖：TASK-sandbox-approval
- 下游：无（收尾）

## 目标
同步项目文档，并把 Codex → ForgeLoop 的沙箱映射沉淀为学习笔记。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/docs/architecture/ARCHITECTURE.md`（新增 ForgeLoopSandbox 层与审批链路的单一事实源描述）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/README.md`（用户可见行为变化：沙箱默认档、审批交互、auditor 移除）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/docs/reviews/REVIEW-LOG.md`
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/notes/codex-sandbox-porting-notes.md`：Codex 概念 → ForgeLoop 实现的映射表、裁剪点（Guardian/proxy 为何缓做）、踩坑与拒绝特征数据出处

## DoD
- 架构文档与实现一致（AGENTS.md §2：不改文档迁就代码，也不留过时描述）
- 移植笔记含映射表 + 每项决策的一句话理由
