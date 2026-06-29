# run_bash — CodeCompanion Extension

Run Bash commands in CodeCompanion chats with **sandbox isolation** and a **pause list approval** mechanism.

## Why

This is a CodeCompanion extension — it provides a `run_bash` tool which replaces the built-in `run_command` tool with a safer and more capable Bash execution environment.

**Security.** The agent runs many commands. Approving every one causes fatigue — users rubber-stamp or disable review entirely. Two layers solve this:

1. **Sandbox** ([sandlock](https://github.com/multikernel/sandlock)) — the real security boundary. Landlock + seccomp restrict filesystem access and syscalls. Safe commands run with zero friction.
2. **Pause list** — not a security measure, but a human checkpoint for destructive ops (`rm -rf`, `git reset --hard`) that can run inside the sandbox but warrant a second look.

**Background processes.** The built-in `run_command` hangs on backgrounded commands like `./run_server.py &` — `vim.system()` waits for the pipe to close, which never happens while the process is alive. This extension provides a dedicated background mode: the command runs detached, returns an ID with partial output, and the agent can kill it later when its work is done.

```
  Command
     │
     ▼
┌──────────────────┐    no sandbox    ┌────────────┐
│ sandlock sandbox │─────────────────►│ Always ask │
│ Landlock+seccomp │                  └────────────┘
└────────┬─────────┘
         │
   Pause-listed?
    ┌────┴────┐
   Yes       No
    │         │
    ▼         ▼
  Ask user  Auto-run (Happy path)
```

## Requirements

- **Linux only.**
- Neovim 0.13+
- CodeCompanion v19+
- `bash` treesitter parser
- `sandlock` (optional but recommended) — provides sandbox isolation. Install from [sandlock](https://github.com/multikernel/sandlock). Requires kernel 5.13+ (see sandlock's documentation).

> Without sandlock, all commands fall back to non-sandbox mode and require manual approval.

## Installation

### lazy.nvim

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "cairijun/codecompanion-run-bash.nvim",
  },
  config = function()
    require("codecompanion").setup({
      extensions = {
        run_bash = {
          opts = {
            sandbox = {
              -- Sandbox backend: "sandlock" (default) or "bubblewrap".
              -- Set `backend = false` to disable the sandbox entirely.
              backend = "sandlock",
              -- Rules appended to the profile at runtime
              -- Paths are auto-expanded: `~`, `$VAR`,
              -- and XDG fallbacks (e.g. `$XDG_DATA_HOME` → `~/.local/share`) are resolved
              -- see [sandbox/init.lua](lua/codecompanion/_extensions/run_bash/sandbox/init.lua) for default rules
              rules = {
                -- Extra paths allowed reading at runtime.
                -- Table = replaces defaults.
                fs_readable = {
                  "~/.local/bin",
                  "$XDG_DATA_HOME",
                  "~/.gitconfig",
                  "$XDG_CONFIG_HOME/git",
                },
                -- Extra paths allowed writing at runtime.
                -- Function = receives defaults, returns new list.
                fs_writable = function(defaults)
                  return vim.list_extend({ "/var/log" }, defaults)
                end,
                -- Paths explicitly denied
                fs_denied = {
                  "$XDG_DATA_HOME/kwalletd",
                  "$XDG_DATA_HOME/keyrings",
                  "~/.ssh",
                  "~/.gnupg",
                },
              },
              backends = {
                -- Sandlock backend: REQUIRED profile path.
                -- `extra_args` are passed to `sandlock` before `--`.
                sandlock = {
                  profile = vim.fn.stdpath("config") .. "/agent_bash_sandlock.toml",
                  -- useful for older kernels that need degraded protection:
                  -- extra_args = { "--allow-degraded", "signal-scope" },
                },
                -- Bubblewrap backend (optional alternative). Needs a working
                -- unprivileged user namespace (`/proc/self/uid_map` valid).
                -- NOTE: fs_denied supports only existing DIRECTORIES (via --tmpfs).
                -- Files and non-existent paths are silently skipped — bwrap has
                -- no clean file-deny primitive. Use sandlock for full coverage.
                -- bubblewrap = { extra_args = { "--unshare-net" } },
              },
            },
            -- uncomment to override built-in pause list:
            -- pauselist = {
            --   cargo = true,                -- true = always block (adds a new rule)
            --   rm = false,                  -- false = disable a built-in rule
            --   git = function(args)         -- function(args) -> boolean = custom check
            --     return args[1] == "reset" and args[2] == "--hard"
            --   end,
            -- },
          },
        },
      },
    })
  end,
}
```

## Rules

### Sandlock Profile

You need to prepare your own sandlock profile. Below is a strict sample that covers typical development needs:

```toml
[limits]
processes = 4096

[filesystem]
read = [
    "/usr", "/lib", "/lib64", "/bin", "/etc", "/opt", "/proc", "/var",
    "/dev/zero", "/dev/urandom", "/dev/random",
]
write = [
    "/tmp", "/var/tmp",
    "/dev/null", "/dev/shm", "/dev/ptmx", "/dev/pts", "/dev/tty",
]
deny = ["/root", "/sys", "/proc/sys", "/etc/shadow", "/etc/sudoers", "/etc/sudoers.d"]

[network]
allow = [
    # Localhost — all ports (local dev servers, IPC)
    "tcp://127.0.0.1", "tcp://::1",
    "udp://127.0.0.1", "udp://::1",

    # Git hosting
    "tcp://github.com:443",
    "tcp://api.github.com:443",
    "tcp://raw.githubusercontent.com:443",
    "tcp://objects.githubusercontent.com:443",
    "tcp://gitlab.com:443",

    # Rust / Cargo
    "tcp://crates.io:443",
    "tcp://static.crates.io:443",

    # Node / npm
    "tcp://registry.npmjs.org:443",

    # Python / pip
    "tcp://pypi.org:443",
    "tcp://files.pythonhosted.org:443",

    # Go modules
    "tcp://proxy.golang.org:443",
    "tcp://sum.golang.org:443",
]
```

### Dynamic Rules

The sandlock profile does not expand paths dynamically — `~`, `$PWD`. Use the `sandbox.rules` option to add paths that depend on the user's environment. See the [Installation](#installation) section for an example.

Default rules in [`sandbox/init.lua`](lua/codecompanion/_extensions/run_bash/sandbox/init.lua) allow common development paths (`.`, cache/tmp locations, etc.) but deliberately exclude paths that MAY include credentials such as `~/.config/gh`, `~/.npmrc`, and `~/.pip`. Add them to `fs_readable` if you are sure they contain no secrets.

### Bubblewrap Backend (Alternative)

The `bubblewrap` backend provides sandbox isolation via user namespaces and bind mounts. Enable with `sandbox.backend = "bubblewrap"` and (optionally) configure `sandbox.backends.bubblewrap.extra_args`.

Bubblewrap has a more limited `fs_denied` model than sandlock:
- Existing **directories** → masked with `--tmpfs PATH`
- **Files** → silently skipped (no clean denial primitive)
- **Non-existent paths** → silently skipped, with a one-time `vim.notify_once` warning

For most cases, sandlock (`backend = "sandlock"`) is the recommended option — it covers files and non-existent deny targets. Continue to set `backends.sandlock.profile` with a [sandlock profile](https://github.com/multikernel/sandlock) for full denial coverage.

## Default Pause List

Built-in rules cover destructive commands such as `rm -rf`, `git reset --hard`, and `git push --force`. See [`checker.lua`](lua/codecompanion/_extensions/run_bash/checker.lua) (`M.defaults`) for the full list.

> `git push --force-with-lease` is **not** pause-listed by default. Override the `git` rule if you need to pause-list it.

## Usage
Just use `@run_bash` instead of `@run_command` in your CodeCompanion chat.
