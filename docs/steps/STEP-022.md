# STEP-022：发布收尾与版本流程准备

## 目标
- 为“收尾并发布”流程准备最小可执行基线。
- 明确版本、文档、回归、tag 的执行顺序。

## 实现范围
- 涉及模块：全仓库（文档与流程）
- 涉及文件（建议）：
  - `README.md`
  - `docs/reviews/REVIEW-LOG.md`
  - `docs/03-Step看板.md`
  - `sessions/SESSION-YYYY-MM-DD.md`（按需创建）
  - 可选 `Scripts/release-check.sh`（新增）

## 实现要求
- 输出一份发布清单（checklist）：
  - 版本号策略（默认 patch）；
  - 必跑测试命令；
  - 文档同步项；
  - commit message 模板；
  - tag 命名规范。
- 若提供脚本，仅做只读检查与提示，不直接 destructive 操作。

## 验证方式
- 命令：
  - `swift test`
  - 发布清单逐项人工确认
- 预期结果：
  - 发布流程步骤清晰、可重复；
  - 无遗漏关键检查项。

## 风险与回滚
- 风险：
  - 发布脚本与实际流程偏差。
- 回滚点：
  - 先以文档 checklist 为准，脚本仅辅助提示。
