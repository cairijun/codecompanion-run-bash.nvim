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
              -- REQUIRED: your sandlock profile path
              profile = vim.fn.stdpath("config") .. "/agent_bash_sandlock.toml",
              -- Rules appended to the profile at runtime
              -- Paths are auto-expanded: `~`, `$VAR`,
              -- and XDG fallbacks (e.g. `$XDG_DATA_HOME` → `~/.local/share`) are resolved
              -- see [sandbox.lua](lua/codecompanion/_extensions/run_bash/sandbox.lua) for default rules
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
              -- extra sandlock CLI args (optional)
              -- useful for older kernels that need degraded protection:
              -- extra_args = { "--allow-degraded", "signal-scope" },
              -- or to disable specific protections:
              -- extra_args = { "--disable", "fs-refer" },
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

Default rules in [`sandbox.lua`](lua/codecompanion/_extensions/run_bash/sandbox.lua) allow common development paths (`.`, cache/tmp locations, etc.) but deliberately exclude paths that MAY include credentials such as `~/.config/gh`, `~/.npmrc`, and `~/.pip`. Add them to `fs_readable` if you are sure they contain no secrets.

## Default Pause List

Built-in rules cover destructive commands such as `rm -rf`, `git reset --hard`, and `git push --force`. See [`checker.lua`](lua/codecompanion/_extensions/run_bash/checker.lua) (`M.defaults`) for the full list.

> `git push --force-with-lease` is **not** pause-listed by default. Override the `git` rule if you need to pause-list it.

## Usage
Just use `@run_bash` instead of `@run_command` in your CodeCompanion chat.
