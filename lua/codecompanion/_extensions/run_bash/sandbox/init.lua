---@brief
---
--- Sandbox execution facade.
--- Dispatches to pluggable backends (sandlock, bubblewrap) based on opts.backend.
--- Generates sandbox_name as an additional run() return value for backends
--- that support named sandboxes.
---
--- Backend interface contract (each backend module must implement):
---   is_available(opts)        -> boolean
---   validate_opts(opts)       -> string|nil   (error msg or nil)
---   capabilities()            -> table  { named_sandbox }
---   get_description()         -> string
---   run(opts, exec_params)     -> handle|nil, pid|string|nil, sandbox_used:bool
---   kill(opts, name, pid, cb, deps) -> nil

local uv = vim.uv
local resolver = require("codecompanion._extensions.run_bash.sandbox.resolver")

local M = {}

-- Internal helpers exposed for reuse by backends/tests. These are not part
-- of the public facade API; backends may depend on them only for shared
-- utility behavior that does not belong to a specific backend.
M._internal = {}

---Kill a process group via two-stage SIGTERM → SIGKILL.
---@param pid integer Process ID (negative value kills the process group)
---@param on_killed function|nil Callback after SIGKILL is sent
---@param deps? table { kill, new_timer, unref }
function M._internal.two_stage_kill(pid, on_killed, deps)
  deps = deps or {}
  local kill = deps.kill or uv.kill
  local unref = deps.unref or uv.unref
  local new_timer = deps.new_timer or uv.new_timer

  -- SIGTERM allows processes (e.g., docker CLI) to forward the signal to
  -- children and clean up before receiving the final SIGKILL.
  pcall(kill, -pid, "sigterm")
  local kill_timer = new_timer()
  kill_timer:start(2000, 0, function()
    kill_timer:close()
    pcall(kill, -pid, "sigkill")
    if on_killed then
      on_killed()
    end
  end)
  unref(kill_timer)
end

---Known backend names. load_backend errors for anything not in this list.
local KNOWN_BACKENDS = { "sandlock", "bubblewrap" }

---Module-level counter for unique sandbox names within a session.
local sandbox_counter = 0

---Generate a unique sandbox name for backends that support naming.
---@return string
local function gen_sandbox_name()
  sandbox_counter = sandbox_counter + 1
  return string.format("cc-bash-%d-%d", os.time(), sandbox_counter)
end

---Load a backend module by name. Errors for unknown backends.
---@param name string Backend name (e.g. "sandlock")
---@return table backend module
local function load_backend(name)
  if not vim.tbl_contains(KNOWN_BACKENDS, name) then
    error("run_bash: unknown backend: " .. tostring(name))
  end
  return require("codecompanion._extensions.run_bash.sandbox.backends." .. name)
end

---Extract the backend-specific opts subtable from full sandbox_opts.
---@param opts table Full sandbox_opts ({ backend, rules, backends })
---@return table backend-specific config (e.g. { profile, extra_args })
local function backend_opts(opts)
  return (opts.backends and opts.backends[opts.backend]) or {}
end

---Built-in default sandbox configuration.
M.defaults = {
  backend = "sandlock",
  rules = {
    fs_readable = {
      "~/.local/bin",
      "$XDG_DATA_HOME",
      "~/.gitconfig",
      "$XDG_CONFIG_HOME/git",
    },
    fs_writable = {
      ".",
      "$XDG_CACHE_HOME",
      "$XDG_STATE_HOME",
      "$XDG_RUNTIME_DIR",
      "~/.cargo",
      "~/.rustup",
      "~/go",
      "~/.nvm",
      "~/.fnm",
      "~/.volta",
      "~/.asdf",
      "~/.npm",
    },
    fs_denied = {
      "$XDG_DATA_HOME/kwalletd",
      "$XDG_DATA_HOME/keyrings",
      "~/.ssh",
      "~/.gnupg",
    },
  },
  backends = {
    sandlock = {
      profile = nil,
      extra_args = nil,
    },
    bubblewrap = {
      extra_args = nil,
    },
  },
}

---Check if sandbox mode is available for the configured backend.
---@param opts table|nil Full sandbox_opts ({ backend, backends })
---@return boolean
function M.is_available(opts)
  if not opts or not opts.backend then
    return false
  end
  local backend = load_backend(opts.backend)
  return backend.is_available(backend_opts(opts))
end

---Determine whether sandbox mode should be used for a given request.
---@param args table Tool args (may contain skip_sandbox)
---@param opts table|nil Full sandbox_opts
---@return boolean
function M.should_use(args, opts)
  return args.skip_sandbox ~= true and M.is_available(opts)
end

---Run a command, sandboxed or direct depending on use_sandbox.
---Returns 4 values: handle, pid_or_error, sandbox_used, sandbox_name.
---sandbox_name is non-nil only for backends with named_sandbox capability.
---@param opts table|nil Full sandbox_opts (used when use_sandbox=true)
---@param exec_params table { cmd, fd, use_sandbox, on_exit, deps? }
---@return table|nil handle
---@return integer|string|nil pid_or_error
---@return boolean sandbox_used
---@return string|nil sandbox_name
function M.run(opts, exec_params)
  local cmd = exec_params.cmd
  local fd = exec_params.fd
  local use_sandbox = exec_params.use_sandbox
  local on_exit = exec_params.on_exit

  local deps = exec_params.deps or {}
  local spawn = deps.spawn or uv.spawn
  local unref = deps.unref or uv.unref

  if not use_sandbox then
    -- Direct bash spawn, no sandbox
    local handle, pid_or_error = spawn("bash", {
      args = { "-c", cmd },
      stdio = { nil, fd, fd },
      detached = true,
      hide = true,
    }, on_exit)
    if not handle then
      return nil, pid_or_error, false, nil
    end
    unref(handle)
    return handle, pid_or_error, false, nil
  end

  -- Sandboxed execution: load backend, resolve rules, generate name
  local backend = load_backend(opts.backend)
  local b_opts = backend_opts(opts)
  local resolved_rules = resolver.resolve_fs_rules(opts.rules)

  local sandbox_name = nil
  if backend.capabilities().named_sandbox then
    sandbox_name = gen_sandbox_name()
  end

  local handle, pid_or_error = backend.run(b_opts, {
    cmd = cmd,
    fd = fd,
    on_exit = on_exit,
    sandbox_name = sandbox_name,
    resolved_rules = resolved_rules,
    deps = deps,
  })

  return handle, pid_or_error, true, sandbox_name
end

---Kill a process or named sandbox.
---For non-sandbox (backend nil/false): two-stage SIGTERM → 2s → SIGKILL.
---For sandboxed backends: delegates to backend.kill.
---@param opts table|nil Full sandbox_opts
---@param sandbox_name string|nil Sandlock sandbox name (nil for non-sandbox)
---@param pid integer Process ID
---@param on_killed function|nil Callback after kill completes
---@param deps? table { spawn, close, unref, kill, new_timer }
function M.kill(opts, sandbox_name, pid, on_killed, deps)
  deps = deps or {}

  if not opts or not opts.backend then
    -- Non-sandbox: two-stage SIGTERM → SIGKILL.
    M._internal.two_stage_kill(pid, on_killed, deps)
    return
  end

  local backend = load_backend(opts.backend)
  backend.kill(backend_opts(opts), sandbox_name, pid, on_killed, deps)
end

---Get a human-readable description for tool schema generation.
---@param opts table|nil Full sandbox_opts
---@return string
function M.get_description(opts)
  if not opts or not opts.backend then
    return "Requires user approval for all commands."
  end
  local backend = load_backend(opts.backend)
  return backend.get_description()
end

---Validate backend-specific opts at setup time.
---@param opts table|nil Full sandbox_opts
---@return string|nil err Error message, or nil if valid
function M.validate_backend_opts(opts)
  if not opts or not opts.backend then
    return nil
  end
  local backend = load_backend(opts.backend)
  return backend.validate_opts(backend_opts(opts))
end

return M
