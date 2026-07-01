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
| `init.lua` | Entry point. Config merge (incl. legacy→new migration), tool registration, approval callback wiring, cleanup on VimLeavePre. |
| `checker.lua` | Pause list engine. Treesitter parse bash, resolve proxy commands, match against rules. |
| `sandbox/init.lua` | Facade. Backend name validation, `sandbox_name` generation, `run`/`kill`/`is_available`/`should_use`/`get_description` dispatch by `opts.backend`. |
| `sandbox/resolver.lua` | Generic path resolution: `resolve_path`, `resolve_fs_rules`, XDG fallback. |
| `sandbox/backends/sandlock.lua` | sandlock backend: CLI arg construction, availability (`sandlock` exec + profile), validate_opts, named-sandbox run/kill. |
| `sandbox/backends/bubblewrap.lua` | bubblewrap backend: maps `fs_*` rules to bwrap CLI (`--bind`, `--ro-bind`, `--tmpfs` for dirs only), uid_map availability check, two-stage SIGTERM/SIGKILL kill. |
| `tool.lua` | Tool definition. Schema, dynamic description (from `sandbox.get_description`), output handlers. Session registry stores `sandbox_opts` + `sandbox_name`; kill passes them through the facade. |

Flow: `init.setup()` registers tool → agent calls tool → handler validates args → `sandbox` facade decides + dispatches to backend → on_exit → output → chat.

Backend interface contract (each backend must implement):

- `is_available(opts) -> boolean`
- `validate_opts(opts) -> string|nil` (error message or nil)
- `capabilities() -> { named_sandbox }`
- `get_description() -> string`
- `run(opts, exec_params) -> handle|nil, pid|string|nil, sandbox_used:boolean`
- `kill(opts, sandbox_name, pid, on_killed, deps) -> nil`

The facade returns a 4-tuple `handle, pid, sandbox_used, sandbox_name` from `run()` where `sandbox_name` is non-nil only for backends with `named_sandbox = true`.

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
- **Unit — resolver** (`tests/units/test_resolver.lua`): Path resolution, XDG fallbacks, `resolve_fs_rules` grouping/dedup/existence checks. Tests `sandbox/resolver.lua` in isolation.
- **Unit — sandlock backend** (`tests/units/test_backend_sandlock.lua`): CLI args, availability, validate_opts, run/kill spies. Tests `sandbox/backends/sandlock.lua` in isolation.
- **Unit — bubblewrap backend** (`tests/units/test_backend_bubblewrap.lua`): Bind/connect args mapping, fs_denied dir-vs-file-skip, uid_map availability, two-stage kill. Tests `sandbox/backends/bubblewrap.lua` in isolation.
- **Unit — sandbox facade** (`tests/units/test_sandbox.lua`): Facade dispatch by `opts.backend`, unknown backend error, `run()` return shape, defaults, and non-sandbox two-stage kill. Tests `sandbox/init.lua` without real backends.
- **Unit — sandbox backends matrix** (`tests/units/test_sandbox_backends.lua`): Common backend contract (execution, capture, exit codes, isolation, kill) against `sandlock`, `bubblewrap`, and the non-sandbox `none` driver.
- **Unit — tool** (`tests/units/test_tool.lua`): Resource cleanup, registry persistence of `sandbox_opts`/`sandbox_name`, kill opts dispatch, cleanup_all per-entry, dynamic description, temp file security, concurrency safety, async I/O, ANSI stripping. Tests `tool.lua` with mocked `sandbox` facade.
- **Unit — init** (`tests/units/test_init.lua`): Config merge, default `backend="sandlock"`, legacy→new migration, `validate_backend_opts`, requirement of approval flow. Tests `init.setup()` in isolation.
- **Integration** (`tests/test_integration.lua`): Full `Chat → run_bash → sandbox → command` pipeline. Only the LLM Adapter is mocked. Tests the contract between run_bash and CodeCompanion — tool registration, approval flow, execution, output formatting — all through the Chat interface, not direct handler calls.

### Testing guidelines

- Prefer real implementations over mocks.
- Extract pure functions and test them without mocks.
- Use dependency injection or local stubs instead of global replacements.
- If a global mock is unavoidable, wrap it with `Helpers.with_mocks` so restoration is guaranteed even on failure.
- Reserve global mocks for external boundaries that cannot be injected (e.g., LLM adapter in integration tests).

**Boundary:** If a test can pass by calling `tool.create()`, `handler()`, or `require_approval_before()` directly, it belongs in a unit test. Integration tests MUST exercise the Chat interface.

### Agent test caveat

When using `run_bash` to run tests: `run_bash` sandbox enabled by default — sandlock can't nest. Two ways:

- `"skip_sandbox": true` — test outside of sandbox (no nesting conflict).
- `TEST_CC_RUN_BASH_SANDBOX_BACKENDS=""` — skip all backend-gated tests (the `none` baseline is also skipped). Use when running tests inside a nested sandbox or when backends are missing. DON'T when full backend coverage is needed.
- `TEST_CC_RUN_BASH_SANDBOX_BACKENDS="sandlock"` — run only the sandlock row of the backend matrix.
