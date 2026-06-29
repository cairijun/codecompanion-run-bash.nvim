---@brief
---
--- Sandlock backend for the sandbox execution engine.
--- Builds CLI args from resolved rules, spawns sandlock, and kills
--- named sandboxes via `sandlock kill`.

local uv = vim.uv

local M = {}

---Build the sandlock argument array from pre-resolved rules.
---@param opts table Backend-specific config ({ profile, extra_args? })
---@param cmd string Command string for bash -c
---@param sandbox_name string Sandlock sandbox name
---@param resolved_rules table { readable=string[], writable=string[], denied=string[] }
---@return string[] arg_array
function M._build_args(opts, cmd, sandbox_name, resolved_rules)
  local spawn_args = {
    "run",
    "--profile-file",
    opts.profile,
    "--name",
    sandbox_name,
    "--port-remap",
  }

  -- Order: writable, readable, denied
  for _, path in ipairs(resolved_rules.writable) do
    table.insert(spawn_args, "-w")
    table.insert(spawn_args, path)
  end
  for _, path in ipairs(resolved_rules.readable) do
    table.insert(spawn_args, "-r")
    table.insert(spawn_args, path)
  end
  for _, path in ipairs(resolved_rules.denied) do
    table.insert(spawn_args, "--fs-deny")
    table.insert(spawn_args, path)
  end

  -- User-configured extra sandlock args before `--`
  if opts.extra_args then
    vim.list_extend(spawn_args, opts.extra_args)
  end

  vim.list_extend(spawn_args, { "--", "bash", "-c", cmd })
  return spawn_args
end

---Check if sandlock is installed and a profile is configured.
---@param opts table|nil Backend-specific config ({ profile? })
---@return boolean
function M.is_available(opts)
  if vim.fn.executable("sandlock") == 0 then
    return false
  end
  if not opts then
    return false
  end
  local profile = opts.profile
  if not profile or uv.fs_stat(profile) == nil then
    return false
  end
  return true
end

---Validate backend-specific config at setup time.
---@param opts table|nil Backend-specific config ({ profile?, extra_args? })
---@return string|nil err Error message, or nil if valid
function M.validate_opts(opts)
  if opts and opts.profile ~= nil and type(opts.profile) ~= "string" then
    return "run_bash: sandbox.backends.sandlock.profile must be a string or nil"
  end
  if opts and opts.extra_args ~= nil and type(opts.extra_args) ~= "table" then
    return "run_bash: sandbox.backends.sandlock.extra_args must be a table or nil"
  end
  return nil
end

---Return capability flags for this backend.
---@return table
function M.capabilities()
  return {
    named_sandbox = true,
  }
end

---Return a human-readable description for tool schema generation.
---@return string
function M.get_description()
  return "Sandboxed by default (sandlock: Landlock + seccomp)."
end

---Run a command under sandlock.
---@param opts table Backend-specific config ({ profile, extra_args? })
---@param exec_params table { cmd, fd, on_exit, sandbox_name, resolved_rules, deps? }
---@return table|nil handle
---@return integer|string|nil pid_or_error
---@return boolean sandbox_used Always true for this backend
---@return string|nil sandbox_name
function M.run(opts, exec_params)
  local cmd = exec_params.cmd
  local fd = exec_params.fd
  local on_exit = exec_params.on_exit
  local sandbox_name = exec_params.sandbox_name
  local resolved_rules = exec_params.resolved_rules or { readable = {}, writable = {}, denied = {} }

  local deps = exec_params.deps or {}
  local spawn = deps.spawn or uv.spawn
  local unref = deps.unref or uv.unref

  local spawn_args = M._build_args(opts, cmd, sandbox_name, resolved_rules)

  local handle, pid_or_error = spawn("sandlock", {
    args = spawn_args,
    stdio = { nil, fd, fd },
    detached = true,
    hide = true,
  }, on_exit)

  if not handle then
    return nil, pid_or_error, true, sandbox_name
  end

  unref(handle)
  return handle, pid_or_error, true, sandbox_name
end

---Kill a named sandlock sandbox.
---@param opts table|nil Backend-specific config (unused, but part of interface)
---@param sandbox_name string Sandlock sandbox name
---@param pid integer Process ID (unused by sandlock kill)
---@param on_killed function|nil Callback after kill spawn exits
---@param deps? table { spawn, close, unref }
function M.kill(opts, sandbox_name, pid, on_killed, deps)
  deps = deps or {}
  local spawn = deps.spawn or uv.spawn
  local close = deps.close or uv.close
  local unref = deps.unref or uv.unref

  -- Use uv.spawn with args array to prevent shell injection
  local handle
  handle = spawn("sandlock", {
    args = { "kill", sandbox_name },
    hide = true,
  }, function()
    -- Close handle in on_exit to prevent resource leak — do not rely on GC
    if handle then
      close(handle)
    end
    if on_killed then
      on_killed()
    end
  end)
  if handle then
    unref(handle)
  elseif on_killed then
    -- Spawn failed: still notify caller so kill does not hang silently
    on_killed()
  end
end

return M
