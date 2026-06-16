# ForgeLoop Performance Regression Policy

> Scope: how to detect, classify, and act on performance regressions in `ForgeLoop` + `ForgeLoopTUI`.  
> Audience: maintainers, CI operators, and release managers.

---

## 1. Core Metrics

| Metric | Role | Usage |
|--------|------|-------|
| **p50 (median)** | Primary | Cross-run comparison, regression判定 |
| **p95** | Secondary | Tail stability, jitter detection |
| **avg** | Tertiary | Throughput-only (chars/sec, per-update ms) |

Baseline 与 Gate 均使用 **p50** 作为核心指标。avg 不再用于回归判定。

---

## 2. Regression Thresholds

### 2.1 Delta-based verdict (primary rule)

| Verdict | p50 Delta Range | Required Action |
|---------|-----------------|-----------------|
| **pass** | `<= 5%` | None; proceed |
| **warn** | `> 5%` and `<= 10%` | Must explain in PR or snapshot `note`; re-run 3 times to confirm; proceed with caution if stable |
| **fail** | `> 10%` | Block merge; must fix or roll back before proceeding |

> The delta is computed against the **current accepted baseline** recorded in `docs/perf-baseline-snapshots.md`.  
> This three-tier scale replaces the previous Minor/Moderate/Severe severity bands and is compatible with the existing `PerformanceGateTests` threshold logic.

### 2.2 Absolute sanity checks (hard ceilings)

These absolute limits are independent of delta; exceeding any is an automatic `fail` regardless of baseline change:
- render-small-first p50 < 5 ms
- render-medium-first p50 < 10 ms
- render-large-first p50 < 50 ms
- transcript-apply p50 < 100 μs
- steer-enqueue p50 < 500 μs (baseline; gate threshold = baseline × thresholdFactor)
- input-latency-idle-prompt p50 < 200 ms (loose sanity check; faux-provider lifecycle varies)

---

## 3. Flaky Handling Flow

```
Test fails
  └── Re-run 3 times on same machine
        ├── 0/3 fail → transient noise, ignore
        ├── 1/3 fail → monitor, do not block
        ├── 2/3 fail → minor regression, annotate PR
        └── 3/3 fail → confirmed regression, follow severity table
```

**Forbidden**: skipping (`XCTSkip`) or deleting a test as the final resolution.  
**Required**: if a test is flaky, open an issue and link it in the test comment.

---

## 4. Exception Handling

A one-time controlled exception to the `> 10%` fail rule is permitted **only if** all of the following are satisfied:

1. **Documented** — a linked issue or PR comment explains why the regression is expected and acceptable.
2. **Time-boxed** — the exception has an expiration (e.g. next milestone or specific date).
3. **Rollback plan** — a concrete rollback commit/PR is identified before merge; if the follow-up fix misses the deadline, the rollback is executed automatically.
4. **Approved** — at least one maintainer approves the exception in writing (issue comment or PR review).

**Forbidden**: repeated exceptions for the same metric without a fix; this degrades the baseline and voids comparability.

---

## 5. Baseline Update Rules

### Allowed

1. Verified performance optimization/退化 with before/after data
2. Measurement model change (iterations, warm-up, sampling strategy)

### Not Allowed

1. "It usually passes on my machine"
2. CI vs local environment difference (use `thresholdFactor` or environment guard instead)
3. Single-run outlier

### Required Evidence

- At least 3 independent runs on the same machine
- p50 values for all 3 runs
- Current `thresholdFactor` pass/fail ratio
- Environment info (OS version, CPU, Swift version)
- `baseline_delta(%)` and `verdict` per the standard snapshot template in `docs/perf-baseline-snapshots.md`

---

## 6. Environment Noise Guard

| Source | Mitigation |
|--------|------------|
| CPU throttling | Close heavy apps; run on AC power |
| Background tasks | Avoid indexing/backup during measurement |
| Debug vs Release | Policy applies to debug builds; release baselines are separate |
| Simulator | Do not use iOS simulator for macOS TUI baselines |

---

## 7. Related Documents

- `docs/perf-baseline-snapshots.md` — current and historical snapshots
- `Tests/ForgeLoopCliTests/PerformanceBaselineTests.swift` — snapshot collection
- `Tests/ForgeLoopCliTests/PerformanceGateTests.swift` — PR gate with warm-up + p50
- `docs/tui-maturity-scorecards.md` — scorecard dimension 5/7 evidence
