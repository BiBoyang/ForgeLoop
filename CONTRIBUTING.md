# Contributing to ForgeLoop

Thanks for your interest in contributing.

## Development setup

- Swift 6.0+
- macOS 14+

Run baseline checks before opening a PR:

```bash
swift test
swift test --filter Agent
swift test --filter AI
swift test --filter Cli
swift build
```

## Scope and architecture

Please keep changes aligned with the repository layering:

- `ForgeLoopAI`: provider/stream/message models
- `ForgeLoopAgent`: lifecycle/loop/tools/cancellation
- `ForgeLoopCli`: input/render/event consumption

Avoid cross-layer coupling changes unless the PR explicitly proposes a design update.

## PR expectations

- Keep patches focused and reviewable.
- Include tests for behavior changes.
- Update docs when user-visible behavior changes:
  - `docs/03-Step看板.md`
  - `docs/reviews/REVIEW-LOG.md`
  - `README.md` when applicable

## Commit style

Recommended prefixes:

- `feat`: new behavior
- `fix`: bug fix
- `test`: tests only
- `docs`: documentation
- `refactor`: no behavior change
- `chore`: maintenance

## Security issues

Please do not open public issues for vulnerabilities.
See `SECURITY.md` for private reporting instructions.
