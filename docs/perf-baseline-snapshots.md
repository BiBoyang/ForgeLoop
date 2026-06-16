# ForgeLoop Performance Baseline Snapshots

> Scope: reproducible performance snapshots for `ForgeLoop` CLI + TUI pipeline.  
> Audience: maintainers running regression checks before merge or release.

---

## Measurement Environment

| Field | Value |
|-------|-------|
| OS | macOS 14.x (arm64e) |
| CPU | Apple Silicon, 10 cores |
| Swift | 6.0 |
| Date | 2026-05-11 |
| Commit anchor | `main` HEAD (post A1–E2) |

---

## Sampling Parameters

| Parameter | Value |
|-----------|-------|
| Warm-up iterations | 10 (Gate only) |
| Render iterations | 500 (Baseline) / 100 (Gate) |
| Input latency iterations | 100 |
| Throughput updates | 50 × 20 chars |
| Core metric | **p50 (median)** |
| Tail reference | p95 |
| Single-point throughput | avg (chars/sec, per-update ms) |

---

## Snapshot Table

### Rendering

| Scenario | p50 | avg | p95 | Iterations | Unit |
|----------|-----|-----|-----|------------|------|
| render-small-first | 0.049 | 0.050 | 0.052 | 500 | ms |
| render-small-nochange | 0.049 | 0.049 | 0.049 | 500 | ms |
| render-small-partial | 0.052 | 0.052 | 0.054 | 500 | ms |
| render-medium-first | 0.350 | 0.355 | 0.370 | 500 | ms |
| render-medium-append | 0.358 | 0.361 | 0.378 | 500 | ms |
| render-medium-rapid-refresh | 0.345 | 0.348 | 0.358 | 500 | ms |
| render-large-first | 1.854 | 1.867 | 1.917 | 500 | ms |
| render-large-stream-append | 1.888 | 1.888 | 1.981 | 500 | ms |

### Transcript

| Scenario | p50 | avg | p95 | Iterations | Unit |
|----------|-----|-----|-----|------------|------|
| transcript-apply | 0.010 | 0.010 | 0.011 | 500 | ms |
| transcript-apply (block cycle) | 0.016 | 0.016 | 0.017 | 500 | ms |

### Input Latency

| Scenario | p50 | avg | p95 | Iterations | Unit |
|----------|-----|-----|-----|------------|------|
| input-latency-idle-prompt | 137.2 | 137.2 | 140.1 | 100 | ms (faux lifecycle) |
| input-latency-streaming-steer | 0.001 | 0.001 | 0.001 | 100 | μs (enqueue) |

> Note: input-latency values are environment-sensitive due to faux-provider async lifecycle; p50 is still the core metric, but absolute values vary across runs. Use relative change (>10%) for regression detection. The idle-prompt threshold is a loose sanity check (200 ms); steer-enqueue is a tight gate (500 μs baseline × thresholdFactor).

### Throughput

| Scenario | Total chars | Updates | Elapsed | Chars/sec | Per-update avg |
|----------|-------------|---------|---------|-----------|----------------|
| throughput-renderer | 1,000 | 50 | ~0.3 ms | ~3.3M | ~0.006 ms |
| throughput-full-pipeline | 1,000 | 50 | ~20 ms | ~50K | ~0.4 ms |

---

## How to Reproduce

```bash
cd /Users/boyang/Desktop/WebKit_build/ForgeLoop
swift test --filter PerformanceBaselineTests
```

Capture the markdown table from the `testBaseline_ReportAllMetrics` output and paste into a new snapshot section above, updating the date and commit anchor.

---

## Single Snapshot Standard Template

Every new performance snapshot MUST be recorded with the following fields so that snapshots are directly comparable across runs.

| Field | Required | Description |
|-------|----------|-------------|
| `date` | Yes | ISO-8601 date of the run (`YYYY-MM-DD`) |
| `git_sha` | Yes | Full or short (≥8 chars) commit SHA of the tested revision |
| `machine` | Yes | Machine identifier (e.g. hostname or CI runner label) |
| `os` | Yes | macOS version and architecture (e.g. `macOS 14.x (arm64e)`) |
| `swift_version` | Yes | Swift compiler version (e.g. `6.0`) |
| `test_filter` | Yes | Test filter string used (e.g. `PerformanceBaselineTests` or `PerformanceGateTests`) |
| `sample_count` | Yes | Number of iterations per scenario (e.g. `500`) |
| `p50` | Yes | Median value for the primary metric, per scenario |
| `p95` | Yes | 95th percentile for tail stability reference |
| `baseline_delta(%)` | Yes | Percentage change vs. the previous accepted baseline (`+3.2%`, `-1.5%`) |
| `verdict` | Yes | `pass` / `warn` / `fail` per `docs/perf-regression-policy.md` thresholds |
| `note` | No | Free-text context: known noise, expected change, linked issue, etc. |

### Verdict mapping (quick reference)

- `pass` — delta `<= 5%`
- `warn` — delta `> 5%` and `<= 10%`; requires explanation in `note`
- `fail` — delta `> 10%`; requires fix or rollback before merge, or a one-time controlled exception approved per `docs/perf-regression-policy.md` §4

> These thresholds are enforced by the existing gate logic (`PerformanceGateTests`); the template ensures human-readable records align with automated results.

### Example row (markdown table style)

| date | git_sha | machine | os | swift_version | test_filter | sample_count | p50 | p95 | baseline_delta(%) | verdict | note |
|------|---------|---------|----|---------------|-------------|--------------|-----|-----|-------------------|---------|------|
| 2026-05-11 | `a1b2c3d4` | local-mbp | macOS 14.x (arm64e) | 6.0 | PerformanceBaselineTests | 500 | 0.049 ms | 0.052 ms | +0.0% | pass | initial baseline |

---

## Update Rules

1. **New snapshot** after every milestone (M6/M7) or significant perf change.
2. **Must include**: date, commit SHA, environment, sampling parameters.
3. **Must keep**: at least the previous snapshot for comparison.
4. **Do not overwrite**: append new sections; old snapshots are historical evidence.
5. **Must use** the "Single Snapshot Standard Template" fields above when recording results; ad-hoc tables are discouraged.
