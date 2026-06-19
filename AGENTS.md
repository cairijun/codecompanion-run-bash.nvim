# AGENTS.md

Coding agent guide for codecompanion-run-bash.nvim.

## What

CodeCompanion extension. Replaces built-in `run_command` tool. Execute bash in chat. Two goals:

1. **Security** — sandlock sandbox (real boundary) + blocklist approval (human checkpoint). Minimize approval friction, keep safety.
2. **Background processes** — built-in `run_command` hangs on `cmd &` (vim.system waits for pipe close, never returns while process alive). This extension: dedicated background mode. Command detached, returns session_id + partial output. Agent kills later via `{"action": "kill", "session_id": "..."}`.

## Design Principles

- **Sandbox = real security boundary.** Landlock + seccomp isolate fs + syscalls. Blocklist NOT security — just human checkpoint for risky-but-sandboxable ops.
- **Minimize approval fatigue.** Frequent approval → user rubber-stamp or disable review → worse than no review. Safe commands = zero friction. Only blocklisted commands pause.
- **Agent use sandbox by default.** Skip sandbox = rare, needs human approval every time.

## Architecture

Major files in `lua/codecompanion/_extensions/run_bash/`:

| File | Role |
|------|------|
| `init.lua` | Entry point. Config merge, tool registration, approval callback wiring, cleanup on VimLeavePre. |
| `checker.lua` | Blocklist engine. Treesitter parse bash, resolve proxy commands, match against rules. |
| `sandbox.lua` | Execution engine. Sandlock or direct bash. uv.spawn, fd lifecycle, process kill. |
| `tool.lua` | Tool definition. Schema, system prompt, output handlers. Session registry for foreground/background processes. |

Flow: `init.setup()` registers tool → agent calls tool → handler validates args → `sandbox` decide + spawn → on_exit → output → chat.

## Approval Logic

1. `action=kill` → auto-approve.
2. Non-sandbox → always require approval.
3. Sandbox → check blocklist. Parse failure → conservative: require approval.

## Conventions

- Lua, stylua formatted. `make format`.
- Comments explain current code intent/constraints — not task steps or change rationale.
- Temp files mode 0600, removed on exit.
- uv.spawn handles `unref`'d — don't block event loop.

## Dev

```bash
make deps      # install test deps
make test      # all tests
make test_file FILE=tests/units/test_checker.lua  # single file
make format    # stylua
make clean     # remove deps
```

Test layers:

- Unit checker: blocklist logic, config override, edge cases.
- Unit sandbox: sandbox/non-sandbox exec, kill, output interleave, spy.
- Unit tool: resource cleanup, temp file safety, concurrency, async I/O.
- Integration: extension register, approval, exec, timeout, bg mode, arg validation.

Sandbox tests force-run by default. sandlock missing → fail. `SKIP_SANDBOX_TESTS=1 make test` to skip.
