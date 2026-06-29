---@brief
---
--- Bubblewrap backend for sandbox execution.
--- Uses bwrap (user namespace + bind mounts) for filesystem isolation.
--- No named sandbox support — kill uses two-stage SIGTERM → SIGKILL.
--- fs_denied only supports directories (via --tmpfs); files and nonexistent
--- paths are silently skipped because bwrap lacks a clean file-deny primitive.

local uv = vim.uv
local sandbox = require("codecompanion._extensions.run_bash.sandbox")

local M = {}

---Read /proc/self/uid_map and check for a valid user namespace mapping.
---`0 0 0` (or absent file) means the namespace is not configured for unprivileged use.
---@return boolean
local function uid_map_valid()
  local lines = vim.fn.readfile("/proc/self/uid_map")
  if not lines or #lines == 0 then
    return false
  end
  for _, line in ipairs(lines) do
    if line:match("%S") and line ~= "0 0 0" then
      return true
    end
  end
  return false
end

---Build the bwrap argument array from pre-resolved rules.
---@param opts table Backend-specific config ({ extra_args? })
---@param cmd string Command string for bash -c
---@param resolved_rules table { readable=string[], writable=string[], denied=string[] }
---@param deps? table { fs_stat? }
---@return string[] arg_array
function M._build_args(opts, cmd, resolved_rules, deps)
  deps = deps or {}
  local fs_stat = deps.fs_stat or uv.fs_stat

  local spawn_args = {}

  for _, path in ipairs(resolved_rules.writable or {}) do
    table.insert(spawn_args, "--bind")
    table.insert(spawn_args, path)
    table.insert(spawn_args, path)
  end

  for _, path in ipairs(resolved_rules.readable or {}) do
    table.insert(spawn_args, "--ro-bind")
    table.insert(spawn_args, path)
    table.insert(spawn_args, path)
  end

  -- fs_denied: bwrap can only deny existing directories via --tmpfs. Files and
  -- non-existent paths are skipped (no clean primitive for them). The first
  -- time a non-existent path is skipped in a single call, emit a warning so
  -- users understand the coverage gap.
  local warned_nonexistent = false
  for _, path in ipairs(resolved_rules.denied or {}) do
    local stat = fs_stat(path)
    if stat ~= nil and stat.type == "directory" then
      table.insert(spawn_args, "--tmpfs")
      table.insert(spawn_args, path)
    elseif stat == nil then
      if not warned_nonexistent then
        vim.notify_once(
          "run_bash: bubblewrap backend cannot deny non-existent paths; "
            .. "consider using sandlock for full fs_denied coverage",
          vim.log.levels.WARN
        )
        warned_nonexistent = true
      end
    end
    -- files and other types: silently skipped (no primitive)
  end

  if opts.extra_args then
    vim.list_extend(spawn_args, opts.extra_args)
  end

  vim.list_extend(spawn_args, { "--", "bash", "-c", cmd })
  return spawn_args
end

---Check if bwrap is installed and a valid user namespace mapping exists.
---@param opts table|nil Backend-specific config (unused, kept for contract compliance)
---@return boolean
function M.is_available(opts)
  if vim.fn.executable("bwrap") == 0 then
    return false
  end
  return uid_map_valid()
end

---Validate backend-specific config at setup time.
---@param opts table|nil Backend-specific config ({ extra_args? })
---@return string|nil err Error message, or nil if valid
function M.validate_opts(opts)
  if opts and opts.extra_args ~= nil and type(opts.extra_args) ~= "table" then
    return "run_bash: sandbox.backends.bubblewrap.extra_args must be a table or nil"
  end
  return nil
end

---Return capability flags for this backend.
---@return table
function M.capabilities()
  return {
    named_sandbox = false,
  }
end

---Return a human-readable description for tool schema generation.
---@return string
function M.get_description()
  return "Sandboxed by default (bubblewrap: user namespace + bind mounts)."
end

---Run a command under bubblewrap.
---@param opts table Backend-specific config ({ extra_args? })
---@param exec_params table { cmd, fd, on_exit, sandbox_name (ignored), resolved_rules, deps? }
---@return table|nil handle
---@return integer|string|nil pid_or_error
---@return boolean sandbox_used Always true for this backend
---@return nil sandbox_name bubblewrap does not support named sandboxes
function M.run(opts, exec_params)
  local cmd = exec_params.cmd
  local fd = exec_params.fd
  local on_exit = exec_params.on_exit
  local resolved_rules = exec_params.resolved_rules or { readable = {}, writable = {}, denied = {} }

  local deps = exec_params.deps or {}
  local spawn = deps.spawn or uv.spawn
  local unref = deps.unref or uv.unref

  local spawn_args = M._build_args(opts, cmd, resolved_rules)

  local handle, pid_or_error = spawn("bwrap", {
    args = spawn_args,
    stdio = { nil, fd, fd },
    detached = true,
    hide = true,
  }, on_exit)

  if not handle then
    return nil, pid_or_error, true, nil
  end

  unref(handle)
  return handle, pid_or_error, true, nil
end

---Kill a bubblewrap process group via two-stage SIGTERM → SIGKILL.
---sandbox_name is ignored: bwrap has no named-sandbox CLI kill primitive.
---@param opts table|nil Backend-specific config (unused)
---@param sandbox_name string|nil Ignored by bubblewrap
---@param pid integer Process ID
---@param on_killed function|nil Callback after kill sequence completes
---@param deps? table { kill, new_timer, unref }
function M.kill(opts, sandbox_name, pid, on_killed, deps)
  -- sandbox_name is ignored: bwrap has no named-sandbox CLI kill primitive.
  -- Reuse the shared two-stage kill sequence so both bubblewrap and the
  -- non-sandbox facade path behave identically.
  sandbox._internal.two_stage_kill(pid, on_killed, deps)
end

return M
