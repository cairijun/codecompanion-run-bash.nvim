---@brief
---
--- Sandbox execution engine for run_bash extension.
--- Encapsulates command execution via sandlock (sandbox) or direct bash.
--- Manages uv.spawn, file fd lifecycle, and process group kill.
---
--- Interface:
---   sandbox.is_available(sandbox_opts) -> boolean
---   sandbox.run(sandbox_opts, exec_params) -> handle, pid, sandbox_used
---   sandbox.kill(sandbox_name, pid) -> nil

local uv = vim.uv

local M = {}

---Built-in default sandbox configuration
M.defaults = {
  enabled = true,
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
}

-- XDG environment variable fallback paths. Keys are full variable names
-- with $ prefix (e.g. "$XDG_DATA_HOME") for O(1) hash lookup.
-- $XDG_RUNTIME_DIR has no fallback — the spec requires it to be set.
local XDG_FALLBACKS = {
  ["$XDG_DATA_HOME"] = "~/.local/share",
  ["$XDG_CONFIG_HOME"] = "~/.config",
  ["$XDG_CACHE_HOME"] = "~/.cache",
  ["$XDG_STATE_HOME"] = "~/.local/state",
}

---Expand a single path: normalize → XDG fallback → (optional) existence check
---@param path string  Raw path (may contain ~ and $VAR)
---@param check_existence boolean  Whether to check path existence (false for fs_denied)
---@param fs_stat? function  Optional fs_stat override (defaults to vim.uv.fs_stat)
---@return string|nil  Expanded normalized absolute path, nil if unresolvable
local function resolve_path(path, check_existence, fs_stat)
  fs_stat = fs_stat or uv.fs_stat

  -- Reject non-string types early (fail-fast)
  if type(path) ~= "string" then
    error("run_bash: rule path must be a string, got " .. type(path))
  end

  -- Step 1: vim.fs.normalize handles ~, $VAR, ., .., trailing slash
  local normalized = vim.fs.normalize(path)

  -- Step 2: if result still starts with $ (env var unset), try XDG fallback
  if vim.startswith(normalized, "$") then
    -- Extract first path component (the variable name): from $ to next / or end
    local slash_pos = normalized:find("/", 2)
    local var_name = slash_pos and normalized:sub(1, slash_pos - 1) or normalized
    local fallback = XDG_FALLBACKS[var_name]
    if fallback then
      local suffix = normalized:sub(#var_name + 1) -- sub-path after var name (incl. / or empty)
      normalized = vim.fs.normalize(fallback .. suffix)
    else
      return nil -- Not in fallback table, cannot resolve
    end
  end

  -- Step 3: existence check (only for fs_readable/fs_writable;
  -- fs_denied skips this — sandlock --fs-deny allows non-existent paths)
  if check_existence then
    if normalized == "" or not fs_stat(normalized) then
      return nil
    end
  end

  return normalized
end

---Expand a rule table into sandlock CLI flag + path pairs.
---Non-existent paths silently skipped for -r/-w; --fs-deny always included.
---@param rule table|nil  List of path strings
---@param flag string       Sandlock CLI flag ("-r", "-w", "--fs-deny")
---@param fs_stat? function Optional fs_stat override
---@return string[]         {flag, path, flag, path, ...}
local function expand_rule(rule, flag, fs_stat)
  local result = {}
  local paths = (type(rule) == "table" and rule) or {}
  -- fs_denied does not check existence (sandlock --fs-deny allows non-existent paths)
  local check_existence = flag ~= "--fs-deny"
  for _, path in ipairs(paths) do
    local resolved = resolve_path(path, check_existence, fs_stat)
    if resolved then
      table.insert(result, flag)
      table.insert(result, resolved)
    end
  end
  return result
end

---Build the sandlock argument array for a sandboxed command.
---@param sandbox_opts table Sandbox config ({ profile, rules, extra_args? })
---@param cmd string Command string to pass to bash -c
---@param sandbox_name string Sandlock sandbox name
---@param deps? table Optional dependency overrides { fs_stat? }
---@return string[] arg_array
function M.build_sandlock_args(sandbox_opts, cmd, sandbox_name, deps)
  local rules = sandbox_opts and sandbox_opts.rules or {}
  local fs_stat = deps and deps.fs_stat or uv.fs_stat
  local spawn_args = {
    "run",
    "--profile-file",
    sandbox_opts.profile,
    "--name",
    sandbox_name,
    "--port-remap",
  }

  vim.list_extend(spawn_args, expand_rule(rules.fs_writable, "-w", fs_stat))
  vim.list_extend(spawn_args, expand_rule(rules.fs_readable, "-r", fs_stat))
  vim.list_extend(spawn_args, expand_rule(rules.fs_denied, "--fs-deny", fs_stat))

  -- Insert user-configured extra sandlock args before `--`
  if sandbox_opts.extra_args then
    vim.list_extend(spawn_args, sandbox_opts.extra_args)
  end

  vim.list_extend(spawn_args, { "--", "bash", "-c", cmd })

  return spawn_args
end

---Check if sandbox mode is available
---@param sandbox_opts table|nil Sandbox config subtable ({ enabled, profile, rules })
---@return boolean
function M.is_available(sandbox_opts)
  if vim.fn.executable("sandlock") == 0 then
    return false
  end
  if not sandbox_opts or sandbox_opts.enabled == false then
    return false
  end
  local profile = sandbox_opts.profile
  if not profile or uv.fs_stat(profile) == nil then
    return false
  end
  return true
end

---Determine whether sandbox mode should be used for a given request,
---based on skip_sandbox flag and sandbox availability.
---@param args table Tool args (may contain skip_sandbox)
---@param sandbox_opts table|nil Sandbox config subtable
---@return boolean
function M.should_use(args, sandbox_opts)
  return args.skip_sandbox ~= true and M.is_available(sandbox_opts)
end

---Run a command.
---Returns handle and pid on success, handle=nil and error on failure.
---@param sandbox_opts table|nil Sandbox config subtable (used when use_sandbox=true)
---@param exec_params table { cmd, fd, file_path, use_sandbox, sandbox_name?, on_exit, deps? }
---@return table|nil handle
---@return integer|string|nil pid_or_error
---@return boolean sandbox_used
function M.run(sandbox_opts, exec_params)
  local cmd = exec_params.cmd
  local fd = exec_params.fd
  local use_sandbox = exec_params.use_sandbox
  local sandbox_name = exec_params.sandbox_name
  local on_exit = exec_params.on_exit

  local deps = exec_params.deps or {}
  local spawn = deps.spawn or uv.spawn
  local unref = deps.unref or uv.unref
  local fs_stat = deps.fs_stat or uv.fs_stat

  local executable, spawn_args

  if use_sandbox then
    executable = "sandlock"
    spawn_args = M.build_sandlock_args(sandbox_opts, cmd, sandbox_name, deps)
  else
    executable = "bash"
    spawn_args = { "-c", cmd }
  end

  local handle, pid_or_error = spawn(executable, {
    args = spawn_args,
    stdio = { nil, fd, fd },
    detached = true,
    hide = true,
  }, on_exit)

  if not handle then
    return nil, pid_or_error, use_sandbox
  end

  unref(handle)
  return handle, pid_or_error, use_sandbox
end

---Kill a process group
---@param sandbox_name string|nil Non-nil → sandlock kill; nil → uv.kill(-pid)
---@param pid integer
---@param on_killed function|nil Callback after kill sequence completes.
---  Sandbox: fires when sandlock spawn exits.
---  Non-sandbox: fires after SIGTERM grace period + SIGKILL.
---@param deps? table Optional dependency overrides { spawn, close, unref, kill, new_timer }
function M.kill(sandbox_name, pid, on_killed, deps)
  deps = deps or {}
  local spawn = deps.spawn or uv.spawn
  local close = deps.close or uv.close
  local unref = deps.unref or uv.unref
  local kill = deps.kill or uv.kill
  local new_timer = deps.new_timer or uv.new_timer

  if sandbox_name then
    -- Use uv.spawn with args array to prevent shell injection
    -- and avoid blocking the event loop with os.execute
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
      -- Unref so fire-and-forget kill doesn't keep the event loop alive
      unref(handle)
    elseif on_killed then
      -- Spawn failed (e.g. sandlock removed between availability check and kill);
      -- still notify the caller so the kill does not hang silently.
      on_killed()
    end
  else
    -- Non-sandbox: two-stage SIGTERM → SIGKILL.
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
    -- Unref so fire-and-forget kill doesn't keep the event loop alive
    unref(kill_timer)
  end
end

return M
