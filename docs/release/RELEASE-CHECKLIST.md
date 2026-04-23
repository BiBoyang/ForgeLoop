# Release Checklist

本清单用于每次发布前自检，确保版本、测试、文档同步、tag 规范一致。

---

## 版本策略

| 类型 | 触发条件 | 示例 |
|---|---|---|
| **patch** (默认) | bug fix、内部重构、文档更新 | v0.1.0 → v0.1.1 |
| **minor** | 新增功能、CLI 新 flag、新 slash 命令 | v0.1.1 → v0.2.0 |
| **major** | 破坏性 API 变更、协议级不兼容 | v0.2.0 → v1.0.0 |

当前项目处于早期阶段，默认 patch；minor 需记录 CHANGELOG；major 需提前沟通。

---

## 必跑命令

```bash
# 1) 全量回归
swift test

# 2) 快速预检（核心模块）
swift test --filter Agent
swift test --filter AI
swift test --filter Cli

# 3) Build 验证
swift build

# 4) STEP-028B: 自动门禁脚本（non-blocking 阶段）
./Scripts/release-check.sh
```

期望：全部通过，0 failures。

## STEP-028B 性能门禁

- 性能基线：`Tests/ForgeLoopCliTests/PerformanceBaselineTests.swift`（仅记录，不阻断）
- 性能门禁：`Tests/ForgeLoopCliTests/PerformanceGateTests.swift`（阈值检查，non-blocking）
- 阈值策略：
  - 当前 `thresholdFactor = 2.0`（允许 200% 偏差，non-blocking）
  - 基线稳定后逐步收紧至 `1.1`（10% 回退告警，blocking）
- 关键指标：
  - 小帧首帧渲染 < 20 μs
  - 中帧首帧渲染 < 100 μs
  - 大帧首帧渲染 < 20 ms
  - TranscriptRenderer.apply < 20 μs
  - steer 入队 < 1 ms

---

## 文档同步项

发布前逐项确认：

- [ ] `docs/03-Step看板.md` — 当前 step 状态更新为 Done，下一个 step 置为 Ready
- [ ] `docs/reviews/REVIEW-LOG.md` — 新增本次评审条目，写明结论与验证结果
- [ ] `sessions/SESSION-YYYY-MM-DD.md` — 如有新 session，按日期归档
- [ ] 本 checklist — 如有流程变更，同步更新

---

## Commit Message 模板

```
<type>: <subject>

<body (optional)>
```

| type | 用途 |
|---|---|
| `feat` | 新功能 |
| `fix` | bug 修复 |
| `test` | 测试补全/修复 |
| `docs` | 文档更新 |
| `chore` | 构建/工具/无关代码的杂项 |
| `refactor` | 重构（无行为变更） |

示例：
```
feat: add /help slash command

test: cover streaming + slash command interleaving

docs: update release checklist for v0.1.2
```

---

## Tag 规范

- 格式：`v<major>.<minor>.<patch>`
- 示例：`v0.1.0`, `v0.1.1`, `v0.2.0`
- tag 应指向 clean commit（无 uncommitted changes）
- tag message 使用对应 commit message 的 subject

---

## 发布顺序

```
1. 校验
   └── 执行 Scripts/release-check.sh（或手动 checklist）
   └── swift test（全量回归）

2. 文档
   └── 更新 docs/03-Step看板.md
   └── 更新 docs/reviews/REVIEW-LOG.md
   └── 更新 sessions/（如有）

3. 提交
   └── git add <改动文件>
   └── git commit -m "chore: release vX.Y.Z"

4. Tag
   └── git tag -a vX.Y.Z -m "Release vX.Y.Z"
   └── git push origin vX.Y.Z
```

---

## 历史记录

| 版本 | 日期 | 备注 |
|---|---|---|
| v0.1.0 | 2026-04-22 | 首次发布，STEP-001 ~ STEP-022 全部完成，146 tests green |
