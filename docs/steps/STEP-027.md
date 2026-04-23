# STEP-027：登录与鉴权闭环（可商用门槛）

## 目标
- 补齐 `login + AuthResolver` 的端到端闭环，移除脚手架态登录路径。
- 使首次使用与重启复用流程可直接落地。
- 作为后置步骤推进，避免与 TUI 主链改造互相干扰。

## 实现范围
- 涉及模块：`ForgeLoopCli`、`ForgeLoopAI`
- 涉及文件（建议）：
  - `Sources/ForgeLoopCli/ForgeLoop.swift`
  - `Sources/ForgeLoopCli/AuthResolver.swift`
  - `Sources/forgeloop/main.swift`
  - 认证相关新增文件（按实现需要）

## 实现要求
- `forgeloop login` 可执行完整流程并持久化凭证。
- 启动时可按优先级解析凭证并给出可诊断错误。
- 保持与现有 ModelStore/模型切换行为兼容。
- 与主链并行时，需确保不阻塞 `STEP-023~026` 回归节奏。

## 验证方式
- 命令：
  - `swift test --filter AuthAndLabelTests`
  - `swift test --filter ModelStoreTests`
  - `swift test --filter ForgeLoopCliTests`
- 预期结果：
  - 登录成功后可直接进入会话；
  - 重启可复用；
  - 缺失凭证时报错清晰。

## 风险与回滚
- 风险：
  - 鉴权分支增多后，模型与 provider 路由易出现错配。
- 回滚点：
  - 保留当前默认 fallback，逐步切换真实登录路径。
