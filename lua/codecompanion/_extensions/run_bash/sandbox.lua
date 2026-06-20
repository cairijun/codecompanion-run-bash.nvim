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
    readable = function()
      return { vim.fn.expand("~") }
    end,
    writable = function()
      return { vim.fn.getcwd(), vim.fn.expand("~/.cache") }
    end,
  },
}

---Expand a dynamic rule to flag + path pairs
---@param rule function|table|nil
---@param flag string
---@return string[]
local function expand_rule(rule, flag)
  local result = {}
  local evaluated = type(rule) == "function" and rule() or rule
  local paths = (type(evaluated) == "table" and evaluated) or {}
  for _, path in ipairs(paths) do
    table.insert(result, flag)
    table.insert(result, path)
  end
  return result
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
---@param exec_params table { cmd, fd, file_path, use_sandbox, sandbox_name?, on_exit }
---@return table|nil handle
---@return integer|string|nil pid_or_error
---@return boolean sandbox_used
function M.run(sandbox_opts, exec_params)
  local cmd = exec_params.cmd
  local fd = exec_params.fd
  local file_path = exec_params.file_path
  local use_sandbox = exec_params.use_sandbox
  local sandbox_name = exec_params.sandbox_name
  local on_exit = exec_params.on_exit

  local executable, spawn_args

  if use_sandbox then
    local rules = sandbox_opts and sandbox_opts.rules or {}
    executable = "sandlock"
    spawn_args =
      { "run", "--profile-file", sandbox_opts.profile, "--name", sandbox_name, "--port-remap" }
    vim.list_extend(spawn_args, expand_rule(rules.writable, "-w"))
    vim.list_extend(spawn_args, expand_rule(rules.readable, "-r"))
    -- Insert user-configured extra sandlock args before `--`
    if sandbox_opts.extra_args then
      vim.list_extend(spawn_args, sandbox_opts.extra_args)
    end
    vim.list_extend(spawn_args, { "--", "bash", "-c", cmd })
  else
    executable = "bash"
    spawn_args = { "-c", cmd }
  end

  local handle, pid_or_error = uv.spawn(executable, {
    args = spawn_args,
    stdio = { nil, fd, fd },
    detached = true,
    hide = true,
  }, on_exit)

  if not handle then
    return nil, pid_or_error, use_sandbox
  end

  uv.unref(handle)
  return handle, pid_or_error, use_sandbox
end

---Kill a process group
---@param sandbox_name string|nil Non-nil → sandlock kill; nil → uv.kill(-pid)
---@param pid integer
function M.kill(sandbox_name, pid)
  if sandbox_name then
    -- Use uv.spawn with args array to prevent shell injection
    -- and avoid blocking the event loop with os.execute
    local handle
    handle = uv.spawn("sandlock", {
      args = { "kill", sandbox_name },
      hide = true,
    }, function()
      -- Close handle in on_exit to prevent resource leak — do not rely on GC
      if handle then
        uv.close(handle)
      end
    end)
    if handle then
      -- Unref so fire-and-forget kill doesn't keep the event loop alive
      uv.unref(handle)
    end
  else
    pcall(uv.kill, -pid, "sigkill")
  end
end

return M
