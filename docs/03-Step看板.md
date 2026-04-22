# Step 看板

状态说明：`Todo` / `Ready` / `In Progress` / `Review` / `Done`

## Phase 1（已完成）

| Step ID | 标题 | 状态 | 负责人 | 备注 |
|---|---|---|---|---|
| STEP-001 | Agent `continue()` 与队列雏形 | Done | 你 | 已通过二审（并发不丢队列） |
| STEP-002 | AgentLoop 工具调用事件骨架 | Done | 你 | 二审通过：tool 事件骨架 + 位置约束 |
| STEP-003 | TranscriptRenderer 覆盖更新增强 | Done | 你 | 二审通过：stream 覆盖稳定 + tool 占位替换 |
| STEP-004 | TUI 输入态与 streaming 态行为分流 | Done | 你 | 二审通过：Prompt/Steer 分流 + 全量回归绿 |
| STEP-005 | FauxProvider 流式中止一致性 | Done | 你 | 二审通过：取消语义一致 + 全量回归绿 |

## Phase 2（进行中：真实 Provider + 工具闭环）

| Step ID | 标题 | 状态 | 负责人 | 备注 |
|---|---|---|---|---|
| STEP-006 | OpenAI Responses Provider 最小接入 | Done | 你 | 二审通过：真实 SSE text 流 + 取消语义闭环 |
| STEP-007 | AgentLoop 接入真实工具执行闭环 | Done | 你 | 二审通过：tool_result 闭环 + continue 路径对齐 |
| STEP-008 | Read/Write 工具落地与基础安全约束 | Done | 你 | 二审通过：cwd 约束 + 越界拒绝 |
| STEP-009 | Bash 工具最小可用（前台） | Done | 你 | 二审通过：timeout/cancel + 负值超时防护 |
| STEP-010 | TUI 工具结果渲染与状态一致性回归 | Done | 你 | 二审通过：done/failed 摘要渲染 + 混排稳定 |
| STEP-011 | AgentEvent 增强：tool 结果摘要透传 | Done | 你 | 二审通过：summary 透传 + 事件签名对齐 |
| STEP-012 | Edit 工具最小落地（补丁写入） | Done | 你 | 二审通过：首个命中替换 + 1MB 限制 |
| STEP-013 | Find/Grep/Ls 工具最小落地 | Done | 你 | 二审通过：检索闭环 + 限流截断 |
| STEP-014 | 后台任务与 bg_status 最小闭环 | Done | 你 | 二审通过：任务跟踪 + 完成注入 |
| STEP-015 | Slash Commands（/model /compact）最小实现 | Done | 你 | 二审通过：命令路由 + streaming 行为一致 |
| STEP-016 | 发布前稳定性收尾（并发/取消/回归） | Done | 你 | bg/streaming 竞争 + slash/队列 交错测试补齐，全量 129/129 绿 |
| STEP-017 | 后台任务可取消与进程回收完善 | Done | 你 | 二审通过：真实取消 + 状态稳定 |
| STEP-018 | Tool 参数校验与错误模型统一 | Done | 你 | 二审通过：错误模型统一 + 参数校验收敛 |
| STEP-019 | 工具执行并发策略最小切换 | Done | 你 | 三审通过：mode 透传闭环 + 并行验收补齐 |
| STEP-020 | TUI 交互增强（/help/截断/状态栏） | Done | 你 | /help 命令 + 渲染端截断 + 底部状态栏，全量 140/140 绿 |
| STEP-021 | 模型管理与配置持久化（最小） | Done | 你 | ModelStore JSON 持久化 + 启动优先级 + 坏配置容错，全量 140/140 绿 |
| STEP-022 | 发布收尾与版本流程准备 | Done | 你 | checklist + release-check.sh 已落地，146/146 绿 |

## 使用方式
- 你开始一个 step 前先发：`开始 STEP-0XX`
- 批量执行可发：`开始 BATCH-001`（一次做 `STEP-007~009`）
- 批量执行可发：`开始 BATCH-002`（一次做 `STEP-011~013`）
- 批量执行可发：`开始 BATCH-003`（一次做 `STEP-017~019`）
- 你开发完后发：`完成 STEP-0XX，求 review`
- 批量开发完后发：`完成 BATCH-001，求 review`
- 批量开发完后发：`完成 BATCH-002，求 review`
- 批量开发完后发：`完成 BATCH-003，求 review`
- 我评审通过后将状态改为 `Done`，并释放下一个 `Ready`
