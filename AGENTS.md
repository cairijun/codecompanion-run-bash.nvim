# AGENTS.md

Coding agent guide for codecompanion-run-bash.nvim.

## What

CodeCompanion extension. Replaces built-in `run_command` tool. Execute bash in chat. Two goals:

1. **Security** — sandlock sandbox (real boundary) + pause list approval (human checkpoint). Minimize approval friction, keep safety.
2. **Background processes** — built-in `run_command` hangs on `cmd &` (vim.system waits for pipe close, never returns while process alive). This extension: dedicated background mode. Command detached, returns session_id + partial output. Agent kills later via `{"action": "kill", "session_id": "..."}`.

## Design Principles

- **Sandbox = real security boundary.** Landlock + seccomp isolate fs + syscalls. Pause list NOT security — just human checkpoint for risky-but-sandboxable ops.
- **Minimize approval fatigue.** Frequent approval → user rubber-stamp or disable review → worse than no review. Safe commands = zero friction. Only pause-listed commands pause.
- **Agent use sandbox by default.** Skip sandbox = rare, needs human approval every time.

## Architecture

Major files in `lua/codecompanion/_extensions/run_bash/`:

| File | Role |
|------|------|
| `init.lua` | Entry point. Config merge, tool registration, approval callback wiring, cleanup on VimLeavePre. |
| `checker.lua` | Pause list engine. Treesitter parse bash, resolve proxy commands, match against rules. |
| `sandbox.lua` | Execution engine. Sandlock or direct bash. uv.spawn, fd lifecycle, process kill. |
| `tool.lua` | Tool definition. Schema, system prompt, output handlers. Session registry for foreground/background processes. |

Flow: `init.setup()` registers tool → agent calls tool → handler validates args → `sandbox` decide + spawn → on_exit → output → chat.

## Approval Logic

1. `action=kill` → auto-approve.
2. Non-sandbox → always require approval.
3. Sandbox → check pause list. Parse failure → conservative: require approval.

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

- **Unit — checker** (`tests/units/test_checker.lua`): Pause list logic, config override, edge cases. Pure logic, no I/O.
- **Unit — sandbox** (`tests/units/test_sandbox.lua`): Sandbox/non-sandbox exec, kill, output interleave, spy on uv.spawn args. Tests `sandbox.lua` in isolation.
- **Unit — tool** (`tests/units/test_tool.lua`): Resource cleanup, temp file security, concurrency safety, async I/O, ANSI stripping. Tests `tool.lua` with mocked `sandbox.run`.
- **Unit — init** (`tests/units/test_init.lua`): Config merge, registration, default application. Tests `init.setup()` in isolation.
- **Integration** (`tests/test_integration.lua`): Full `Chat → run_bash → sandbox → command` pipeline. Only the LLM Adapter is mocked. Tests the contract between run_bash and CodeCompanion — tool registration, approval flow, execution, output formatting — all through the Chat interface, not direct handler calls.

### Testing guidelines

- Prefer real implementations over mocks.
- Extract pure functions and test them without mocks.
- Use dependency injection or local stubs instead of global replacements.
- If a global mock is unavoidable, wrap it with `Helpers.with_mocks` so restoration is guaranteed even on failure.
- Reserve global mocks for external boundaries that cannot be injected (e.g., LLM adapter in integration tests).

**Boundary:** If a test can pass by calling `tool.create()`, `handler()`, or `require_approval_before()` directly, it belongs in a unit test. Integration tests MUST exercise the Chat interface.

Sandbox tests force-run by default. sandlock missing → fail. `SKIP_SANDBOX_TESTS=1 make test` to skip.

### Agent test caveat

When using `run_bash` to run tests: `run_bash` sandbox enabled by default — sandlock can't nest. Two ways:

- `"skip_sandbox": true` — test outside of sandbox (no nesting conflict).
- `SKIP_SANDBOX_TESTS=1` — skip sandbox tests entirely, test non-sandbox code only.
