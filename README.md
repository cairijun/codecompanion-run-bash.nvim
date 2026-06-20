# run_bash — CodeCompanion Extension

Run Bash commands in CodeCompanion chats with **sandbox isolation** and a **blocklist approval** mechanism.

## Why

This is a CodeCompanion extension — it provides a `run_bash` tool which replaces the built-in `run_command` tool with a safer and more capable Bash execution environment.

**Security.** The agent runs many commands. Approving every one causes fatigue — users rubber-stamp or disable review entirely. Two layers solve this:

1. **Sandbox** ([sandlock](https://github.com/multikernel/sandlock)) — the real security boundary. Landlock + seccomp restrict filesystem access and syscalls. Safe commands run with zero friction.
2. **Blocklist** — not a security measure, but a human checkpoint for destructive ops (`rm -rf`, `git reset --hard`) that can run inside the sandbox but warrant a second look.

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
   Blocklisted?
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
            -- Below is the default configuration (except `profile`).
            sandbox = {
              -- REQUIRED: your sandlock profile path
              profile = vim.fn.stdpath("config") .. "/agent_bash_sandlock.toml",
              enabled = true, -- sandbox on by default
              rules = {
                -- extra readable paths passed to sandlock at runtime
                readable = function()
                  return { vim.fn.expand("~") }
                end,
                -- extra writable paths passed to sandlock at runtime
                writable = function()
                  return { vim.fn.getcwd(), vim.fn.expand("~/.cache") }
                end,
              },
            },
            -- uncomment to override built-in rules:
            -- blocklist = {
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

## Sandlock Profile

You need to prepare your own sandlock profile. Below is a strict sample that covers typical development needs:

```toml
[filesystem]
read = [
    "/usr", "/lib", "/lib64", "/bin", "/etc", "/opt", "/proc", "/var",
    "/dev/zero", "/dev/urandom", "/dev/random", "/dev/tty", "/dev/pts",
]
write = [
    "/tmp", "/var/tmp",
    "/dev/null",
]
deny = ["/root", "/sys", "/proc/sys", "/etc/shadow", "/etc/sudoers", "/etc/sudoers.d"]

[network]
allow = ["tcp://*:*", "udp://*:53", "icmp://*"]
```

The `rules.writable` and `rules.readable` in your CodeCompanion config are passed to sandlock at runtime, granting additional access on top of the profile.

## Default Blocklist

Built-in rules cover destructive commands such as `rm -rf`, `git reset --hard`, and `git push --force`. See [`checker.lua`](lua/codecompanion/_extensions/run_bash/checker.lua) (`M.defaults`) for the full list.

> `git push --force-with-lease` is **not** blocked by default. Override the `git` rule if you need to block it.

## Usage
Just use `@run_bash` instead of `@run_command` in your CodeCompanion chat.
