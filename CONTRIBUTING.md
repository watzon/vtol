# Contributing

## Workflow

1. Keep changes scoped to one subsystem when possible.
2. Run formatting before submitting changes.
3. Run tests before opening a pull request.
4. Add or update docs when module boundaries or public APIs change.

## Commands

```bash
v fmt -w .
v test .
```

## Engineering rules

- Prefer small public APIs and explicit `pub` boundaries.
- Use `!` and `?` consistently instead of sentinel values.
- Favor channels over shared mutable state for update and event pipelines.
- Keep generated TL code out of handwritten modules.
- Treat `internal/` as non-public implementation detail.
