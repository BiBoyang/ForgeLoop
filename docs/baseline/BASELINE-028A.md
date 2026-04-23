# STEP-028A 改造前性能基线

## 采集信息

| 项目 | 值 |
|------|-----|
| 采集日期 | 2026-04-23 |
| 采集环境 | macOS 26.5 (25F5042g), arm64e, 10 cores |
| Swift 版本 | 6.0 |
| 业务代码版本 | STEP-022 完成后主干（146/146 测试通过） |

## 采样配置

| 参数 | 值 |
|------|-----|
| 渲染迭代次数 | 500 |
| 输入延迟迭代次数 | 100 |
| 长输出更新次数 | 50 次 update x 20 字符 = 1000 字符 |
| 大帧行数 | 120 行（STEP-023 目标场景） |

## 1. 渲染耗时

测量 `TUI.requestRender()` 与 `TranscriptRenderer.apply()` 的耗时。

### 1.1 TUI.requestRender 基线

| 指标 | 均值 | p95 | 迭代 | 采样条件 |
|------|------|-----|------|---------|
| render-small-first | 0.001 ms | 0.001 ms | 500 | 7 行首帧（header + model + cwd + content + status） |
| render-small-nochange | 0.001 ms | 0.001 ms | 500 | 相同帧重复渲染（diff 短路返回） |
| render-small-partial | 0.001 ms | 0.001 ms | 500 | 小帧部分行变更 |
| render-medium-first | 0.002 ms | 0.002 ms | 500 | ~25 行首帧（20 行 transcript） |
| render-medium-append | 0.002 ms | 0.002 ms | 500 | 中帧追加一行增量 |
| render-large-first | 0.011 ms | 0.011 ms | 500 | 124 行首帧（120 行 transcript） |
| render-large-stream-append | 0.009 ms | 0.009 ms | 500 | 大帧追加 streaming 行 |

### 1.2 TranscriptRenderer.apply 独立耗时

| 指标 | 均值 | p95 | 迭代 | 采样条件 |
|------|------|-----|------|---------|
| transcript-apply | 0.004 ms | 0.004 ms | 500 | 纯 `apply()` 调用（messageStart + messageUpdate + messageEnd），不含 TUI 输出 |

## 2. 输入延迟

测量从 `PromptController.submit()` 到可观测状态变化的延迟。

| 指标 | 均值 | p95 | 迭代 | 采样条件 |
|------|------|-----|------|---------|
| input-latency-idle-prompt | 138.103 ms | 143.242 ms | 100 | idle 态 → `prompt()` 完整生命周期（faux provider，含 AgentLoop.run） |
| input-latency-streaming-steer | 0.002 ms | 0.003 ms | 100 | streaming 态 → `steer()` 入队（仅 enqueue，不等待执行） |

## 3. 长输出吞吐

测量大量 messageUpdate 累积处理的速度。

| 指标 | 吞吐率 | 单次更新耗时 | 采样条件 |
|------|--------|-------------|---------|
| throughput-renderer | 3,787,290 chars/sec | 0.005 ms | 50 次 update x 20 字符，仅 TranscriptRenderer |
| throughput-full-pipeline | 1,512,669 chars/sec | 0.013 ms | 50 次 update x 20 字符，Renderer + TUI.requestRender 完整链路 |

## 最小回归命令集

以下命令用于 STEP-023~027 改造前后的对照验证：

```bash
# 1. 性能基线回归
swift test --filter PerformanceBaselineTests

# 2. CLI 全量回归
swift test --filter ForgeLoopCliTests

# 3. Agent 核心回归
swift test --filter Agent

# 4. AI 层回归
swift test --filter AI

# 5. 全量回归（最终门禁）
swift test
```

## 阈值约定

- 相比本基线，关键指标回退 **> 10%** 触发告警。
- 告警连续稳定后再升级为 CI 阻断阈值。
- 先 non-blocking 记录趋势（STEP-028B 收口）。

## 复现说明

同命令、同环境可再次得到同量级结果。性能测试使用 `DispatchTime.now().uptimeNanoseconds`，不依赖外部服务。

idle-prompt 延迟（~138ms）包含 faux provider 的完整 AgentLoop.run 生命周期，属于端到端交互延迟基线。
