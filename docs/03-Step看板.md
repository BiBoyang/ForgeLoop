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

## Phase 3（已完成：TUI 内核升级与产品化闭环）

| Step ID | 标题 | 状态 | 负责人 | 备注 |
|---|---|---|---|---|
| STEP-023 | TUI 渲染内核升级（inline retained-mode） | Done | 你 | `023A/023B` 已通过：inline anchor、shrink/resize/cursor、non-TTY、legacy 回滚 |
| STEP-024 | 输入链路重构（raw stdin + keybinding） | Done | 你 | `024A/024B` 已通过：raw stdin、ESC flush、上下键、bracketed paste、扩展映射 |
| STEP-025 | 组件化布局落地（Header/Transcript/Status/Queue/Input） | Done | 你 | 五段布局已通过：Header/Transcript/Queue/Status/Input |
| STEP-026 | Transcript 语义增强 | Done | 你 | thinking 区分渲染、toolCall 去重、通知折叠、tool result 多行索引修复 |
| STEP-027 | 登录与鉴权闭环（可商用门槛） | Done | 你 | `forgeloop login` + CredentialStore + 环境变量回退 + 诊断错误闭环 |
| STEP-028 | 测试与性能门禁 | Done | 你 | `028A` 基线 + `028B` 门禁收口（non-blocking 阶段） |

## Post-v0.1.1（TUI 深度优化）

| Step ID | 标题 | 状态 | 负责人 | 备注 |
|---|---|---|---|---|
| PB-001 | inline 脏尾段重绘 + applyCore 性能链路清理 | Done | AI | `inlineAnchor` 同帧 no-op、变更尾段重绘；`Performance*Tests` 移除 deprecated `apply` 调用 |
| PB-002 | MarkdownEngine 流式增量 + 表格渲染最小闭环 | Done | AI | 新增 `StreamingMarkdownEngine`（stable boundary + 未闭合降级），接入 `TranscriptRenderer` 并补测试 |
| PB-003 | TUI 测试 warning 清零（deprecated/actor-isolation） | Done | AI | 重写 `CoreRenderEventAdapterTests` 为 Agent→Core 对照；清理 LayoutRendererTests actor 告警；`ForgeLoopCliTests` warning clean |
| PB-004 | TranscriptRenderer* 测试迁移到纯 `applyCore` 路径 | Done | AI | `TranscriptRendererTests` + `TranscriptRendererToolResultTests` 移除 legacy `apply(_:)` 依赖；保持语义断言不变并通过 warning 扫描 |
| PB-005 | TUI 稳定性修复（Esc 语义 + 合帧默认 + Markdown 兜底） | Done | AI | Esc: streaming abort/idle+bg killAll；RenderLoop 默认开启（`FORGELOOP_TUI_RENDER_LOOP=0` 可关闭）；代码块/转义管道/超宽表格稳定渲染 |
| PB-006 | TUI 行首对齐修复（TTY 统一 CRLF） | Done | AI | TTY 渲染统一使用 `\\r\\n`，修复 raw 模式首屏/多行“整体右移”；non-TTY 仍保持 `\\n` |
| PB-007 | TUI 小终端溢出安全重绘 + 多行逻辑行规范化 | Done | AI | 超过视口高度时 `inlineAnchor` 自动降级全帧重绘；用户消息/输入按逻辑行拆分，避免 `\\n` 破坏行模型 |
| PB-008 | TUI streaming 自然追加输出 + stdout EAGAIN 加固 | Done | AI | TTY streaming 改为直接追加完整 frame，避免擦除 scrollback；默认 stdout writer 改为 POSIX `write` 循环处理 `EAGAIN/EINTR` |
| PB-009 | TUI streaming transcript 增量输出降噪 | Done | AI | 不再整帧重复输出 transcript/header/prompt；TTY streaming 只追加 transcript 稳定增量，idle footer 单独渲染 |
| PB-010 | Streaming planner 上移到 `ForgeLoopTUI` | Done | AI | `StreamingTranscriptAppendState` 从 `ForgeLoopCli` 迁移到 `ForgeLoopTUI` target，并同步独立仓库 |
| PB-011 | `ForgeLoopCliTests` 性能门禁重校准 | Done | AI | 更新 `render-small-first` / `render-medium-first` 基线，`ForgeLoopCliTests` 208/208 全绿 |
| PB-012 | ForgeLoop 接入可配置宽表策略 | Done | AI | `CodingTUI` 显式传入 app-level `MarkdownRenderOptions`；宽表默认 compact/truncate，应用层可继续调整 |
| PB-013 | ForgeLoop 主仓接入 `TextInputState` 与 `/model` picker | Done | AI | `CodingTUI` 改用 `TextInputState` + 真光标偏移；`/model` 空参数打开 `ListPickerState/ListPickerRenderer`；`ForgeLoopCliTests` 215/215 全绿 |
| PB-014 | ForgeLoop 状态栏升级 | Done | AI | 状态栏升级为 phase + badges：`ready/generating/aborting/selecting model/background tasks`，并显示 tools/bg/queued 信息；`ForgeLoopCliTests` 221/221 全绿 |
| PB-015 | Slash registry 与命令反馈可见性收口 | Done | AI | `PromptController` 改接 `SlashCommandRegistry`；`/help` 等反馈改走 footer notice；补齐 DeepSeek picker 与 cursor-anchor hotfix；`ForgeLoopCliTests` 227/227 全绿 |
| PB-016 | `/queue` 最小命令闭环 | Done | AI | `/queue` 可见性与 streaming 并存语义落地，队列消费后空态可观测 |
| PB-017 | auto-compact 最小事件闭环 | Done | AI | `context_compacted` 事件与 CLI footer notice 打通，Agent 稳定性测试补齐 |
| PB-018 | AttachmentStore 接入 CLI | Done | AI | 附件存储、注入与状态 badge 联通，不下沉到 `ForgeLoopTUI` |
| PB-019 | 空输入 + 附件提交规则 | Done | AI | 保留模式下支持“空输入仅附件提交”，补齐 `PromptController` 语义测试 |
| PB-020 | 附件 slash 命令首版 | Done | AI | `/attach` `/attachments` `/detach` + `/help` 覆盖通过 |
| PB-021 | Queue/Attachment/Notice 收口 | Done | AI | 统一 status/footer/transcript 边界，`FooterNotice` 优先级与覆盖规则落地 |
| PB-022 | Attachment 体验增强 | Done | AI | preview 单行归一化、`/attachments clear` 别名、文案与清空行为一致化 |
| PB-023 | `/queue` 二期能力 | Done | AI | 预览归一化 + 50 字截断 + top-5 + `... and N more` + `/queue clear` |
| PB-024 | auto-compact 二期 | Done | AI | `keepCount/minGap` 可配置，compact badge 可见且随输入清除 |
| PB-025A | 工具防分页器卡住 | Done | AI | `ProcessRunner` 注入 `PAGER/GIT_PAGER/MANPAGER/SYSTEMD_PAGER=cat` + `stdin=/dev/null`，`bash/bg` 路径验证通过 |

## Phase 4（Tool Call 解析与结构化协议）

| Step ID | 标题 | 状态 | 负责人 | 备注 |
|---|---|---|---|---|
| STEP-029 | ChatCompletions 入站 tool_call 解析 | Done | AI | 支持 choices[].delta.tool_calls[] / function_call，PendingToolCall 聚合，text+tool 混合 |
| STEP-030 | Responses 入站 tool_call 解析 | Done | AI | 支持 response.output_item.added / function_call_arguments.delta / output_item.done，参数分片聚合 |
| STEP-031 | Provider 统一终止语义 | Done | AI | toolCall → .toolUse，无 toolCall → .endTurn，取消/错误不双终止 |
| STEP-032 | FauxProvider 支持 tool_call 模拟 | Done | AI | 新增 text/toolCall/textThenToolCall/multipleToolCalls 四种模式，默认行为不变 |
| STEP-033 | AI 层测试补齐（tool_call 专项） | Done | AI | arguments 分片、多 toolCall 顺序、text+tool 混合、.toolUse 判定、取消不双终止 |
| STEP-034 | Agent 端到端验证（FauxProvider 闭环） | Done | AI | assistant(tool_call) → toolExecutionStart/End → tool_result → 第二轮，事件顺序断言 |
| STEP-035 | Phase B 出站结构化工具协议 | Done | AI | StreamOptions 扩展 tools/toolChoice；请求体支持 tools/tool_choice；assistant tool_call 与 tool_result 结构化回灌（不再文本化降级） |

## Harness Engineer 阶段（HB-001~HB-005：参数校验层固化）

| Step ID | 标题 | 状态 | 负责人 | 备注 |
|---|---|---|---|---|
| HB-001 | Tool 参数校验核心（schema/validator/taxonomy） | Done | AI | 二审通过：CFTypeID 精确区分 Bool/Number，34/34 测试绿 |
| HB-002 | ls/find/grep 迁移到 typed args | Done | AI | 二审通过：严格 unknown_field，26/26 测试绿 |
| HB-003 | EditTool diff 摘要输出 | Done | AI | 二审通过：可读 diff + 截断标记，9/9 测试绿 |
| HB-004 | bash/bg/bg_status 接入 typed args + background 模式 | Done | AI | 二审通过：BashTool 共享 manager，background 路径打通，16+24 测试绿 |
| HB-005 | 回归固化与文档同步 | Done | AI | 全量 459/459 绿，看板/评审日志/架构文档同步完成 |

## Phase 3 建议执行顺序（V2）

1. `STEP-028A`：建立改造前基线（性能 + 回归快照）
2. `STEP-023A`：最小 inline retained-mode 渲染闭环
3. `STEP-024A`：最小输入闭环（Enter/Esc/Ctrl-C + ESC flush）
4. `STEP-025`：薄布局落地（Transcript/Status/Input）
5. `STEP-023B`：渲染补强（shrink/resize/cursor marker）
6. `STEP-024B`：输入补强（上下键/bracketed paste/扩展 keybinding）
7. `STEP-026`：Transcript 语义增强
8. `STEP-027`：登录与鉴权闭环
9. `STEP-028B`：CI 门禁与性能阈值收口

## 使用方式
- 你开始一个 step 前先发：`开始 STEP-0XX`
- 批量执行可发：`开始 BATCH-001`（一次做 `STEP-007~009`）
- 批量执行可发：`开始 BATCH-002`（一次做 `STEP-011~013`）
- 批量执行可发：`开始 BATCH-003`（一次做 `STEP-017~019`）
- 批量执行可发：`开始 BATCH-004`（一次做 `STEP-023~025`）
- 你开发完后发：`完成 STEP-0XX，求 review`
- 批量开发完后发：`完成 BATCH-001，求 review`
- 批量开发完后发：`完成 BATCH-002，求 review`
- 批量开发完后发：`完成 BATCH-003，求 review`
- 批量开发完后发：`完成 BATCH-004，求 review`
- 我评审通过后将状态改为 `Done`，并释放下一个 `Ready`
