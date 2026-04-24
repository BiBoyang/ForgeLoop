# TUI 深度优化 RFC（独立化 + 性能 + Markdown）

状态：Draft  
日期：2026-04-23  
范围：仅规划，不含代码改动

## 1. 背景与目标

本轮只做 TUI 深度优化，目标固定为：

1) `ForgeLoopTUI` 可独立开源复用（不绑定 ForgeLoop 业务语义）；  
2) 超长文本与高频流式更新下仍保持流畅；  
3) 特殊 Markdown（尤其表格）在流式场景下可稳定渲染。

## 2. 现状评估（基于当前代码）

### 2.1 已有优势

- `ForgeLoopTUI` 已是独立 target，可单独编译：`Package.swift`。  
- 已具备 inline retained-mode、非全屏清屏、物理行预算等关键能力。  
- 已有性能基线与门禁测试：`PerformanceBaselineTests`、`PerformanceGateTests`。

### 2.2 当前阻碍点

- `RenderEvent/RenderMessage` 仍偏 chat 语义，限制通用场景复用。  
- 渲染触发点分散（输入、事件、后台轮询），缺少统一调度器（coalescing + throttle）。  
- Markdown 渲染仍以“文本行”思路为主，缺少“流式增量解析 + 稳定边界缓存”机制。  
- 表格等块级结构在“未闭合”流式阶段缺少明确降级与收敛策略。

## 3. 总体方案（唯一主线）

先做 **边界解耦**，再做 **性能收敛**，最后做 **Markdown 增量化**。  
不并行开多个重构主题，按阶段推进并保留回滚开关。

### 3.1 模块边界（Core / Adapter）

将 `ForgeLoopTUI` 逻辑概念上拆为两层（第一阶段可先在同一 target 内分目录）：

- `TUICore`（开源核心，通用）
  - `RenderLoop`（帧调度/节流/合帧）
  - `ScreenBuffer`（可见区状态）
  - `DiffEngine`（按物理行 diff）
  - `TerminalWriter`（ANSI/non-TTY 输出）
  - `MarkdownEngine` 协议（可插拔）
- `TUIChatAdapter`（业务适配）
  - `AgentEvent -> CoreRenderEvent` 映射
  - chat 样式（user/assistant/tool）约定

原则：Core 不依赖 `ForgeLoopAI` / `ForgeLoopAgent` / `ForgeLoopCli`。

### 3.2 流式数据与渲染节流

采用单渲染队列 + 合帧模型：

- 输入层可 1~5ms 收到 delta；  
- 渲染层默认 16ms tick（≈60fps）统一消费；  
- 在 `messageEnd`、用户回车、错误终止等关键事件上 **立即 flush**；  
- 同一 tick 内保留“最新状态帧”，丢弃中间过期帧（coalescing）。

### 3.3 Diff 更新策略

- 以“物理行”为单位计算最小更新区域（考虑 CJK 与折行）；  
- 保持当前 inline anchor 机制，避免全帧清除；  
- 引入 `dirtyTop/dirtyBottom` 区间输出，减少长输出重绘成本。

### 3.4 Markdown 增量解析（含表格）

实现 `StreamingMarkdownEngine` 的“稳定前缀 / 不稳定尾部”策略：

- 维护 `stableBoundary`（单调递增）；  
- 新增文本只解析尾部；  
- 找到最后一个“完整块”后推进边界；  
- 稳定块缓存 AST/渲染结果，不重复解析。

对表格（GFM table）采用显式状态机：

- 识别 `header | ...` + `|---|---|` 的候选起点；  
- 未闭合前按“纯文本块”渲染（可读优先）；  
- 一旦表格块完整，替换为结构化表格渲染；  
- `messageEnd` 触发最终收敛，保证最终态正确。

## 4. 分阶段计划（可回滚）

## Phase A：边界解耦（先做）

目标：定义并落地 Core/Adapter 接口，不改用户可见行为。

步骤：

1. 抽象 `CoreRenderEvent`（去 chat 语义）；  
2. 将现有 `AgentEvent -> RenderEvent` 逻辑迁移为 `TUIChatAdapter`；  
3. 保持旧 API 兼容层（deprecated 包装）；  
4. 补充“Core 不依赖业务模块”的编译门禁测试。

回滚：保留旧入口，切回 legacy adapter。

## Phase B：性能收敛（单主题）

目标：高频流式下 `p95` 帧时间稳定在预算内。

步骤：

1. 引入 `RenderLoop`（16ms 默认 + 关键事件即时 flush）；  
2. 引入帧合并（latest-frame-wins）；  
3. 引入物理行 dirty range diff；  
4. 用现有基线测试扩展出“长文本 + 高频 delta”场景。

回滚：`FORGELOOP_TUI_STRATEGY=legacy` + `RenderLoop` feature flag。

## Phase C：Markdown 增量化（单主题）

目标：表格/代码块/列表在流式阶段与最终态都可正确渲染。

步骤：

1. 定义 `MarkdownEngine` 协议与默认实现；  
2. 增量边界缓存与块完成度检测；  
3. 表格块状态机与未闭合降级策略；  
4. Snapshot + streaming 回归测试。

回滚：保留纯文本 renderer 作为 fallback。

## 5. 验收标准（按目标）

### 目标1：可独立开源

- `ForgeLoopTUI` 可在无 `AI/Agent/CLI` 依赖下单独编译与测试；  
- 提供最小示例：仅 Core API 即可完成流式渲染；  
- Chat 语义通过 adapter 注入，不进入 Core 公共接口。

### 目标2：超长文本流畅

- 高频 delta（1~5ms）输入下无卡顿性抖动；  
- 60fps 预算下帧调度稳定（渲染节流可观测）；  
- 长文本场景不出现全量重绘退化。

### 目标3：Markdown 表格稳定

- 未闭合表格：可读降级，不破坏布局；  
- 闭合后：可结构化渲染且不重复闪烁；  
- `messageEnd` 后最终渲染与离线完整解析一致。

## 6. 最小测试命令（规划阶段约定）

```bash
# 1) TUI 核心回归
swift test --filter ForgeLoopCliTests/TUI

# 2) 渲染与布局回归
swift test --filter ForgeLoopCliTests/Layout

# 3) 性能基线与门禁
swift test --filter PerformanceBaselineTests
swift test --filter PerformanceGateTests
```

## 7. 与旧版独立库的关系

你提供的旧仓库 `../ForgeLoopTUI` 可作为“最小独立库”参考实现：  
其优点是边界简洁；不足是全屏清屏与非增量 Markdown。  
本 RFC 的方向是：保留其“独立性”，引入当前 ForgeLoop 主干已验证的 inline/diff/perf 能力。

## 8. 本轮唯一最优下一步

先执行 **Phase A（边界解耦）设计评审**，只产出接口草案与迁移清单，不改渲染行为。  
通过后再进入 Phase B（性能专项），避免范围漂移。

