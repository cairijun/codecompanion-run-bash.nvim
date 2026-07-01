local sandbox = require("codecompanion._extensions.run_bash.sandbox")
local uv = vim.uv

local M = {}

---Common filesystem rules used by the parameterized backend matrix.
M.common_rules = {
  fs_writable = { vim.fn.getcwd(), "/tmp" },
  fs_readable = { vim.fn.getcwd(), "/usr", "/bin", "/lib", "/lib64" },
  fs_denied = {},
}

---Build full sandbox_opts for a backend driver, merging common rules and optional overrides.
---For the `none` driver, rule overrides are ignored because direct bash does not use them.
---@param driver table { name = string, sandbox_opts = table }
---@param rule_overrides? table { fs_readable?, fs_writable?, fs_denied? }
---@return table
function M.build_sandbox_opts(driver, rule_overrides)
  local opts = vim.tbl_deep_extend("force", {}, driver.sandbox_opts or {})
  if driver.name == "none" then
    return opts
  end

  opts.backend = driver.name
  opts.rules = vim.tbl_deep_extend("force", {}, M.common_rules)
  if rule_overrides then
    opts.rules = vim.tbl_deep_extend("force", opts.rules, rule_overrides)
  end
  return opts
end

---Read the contents of a temp output file. Caller owns cleanup.
---@param file_path string
---@return string
function M.read_output(file_path)
  local f = io.open(file_path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

---Spawn a command under a driver without waiting.
---Creates a temp output file with mode 0600, opens it, calls `sandbox.run`, and returns a mutable result table that the caller can poll or kill.
---@param driver table
---@param cmd string
---@param rule_overrides? table
---@return table result { completed: boolean, error?, handle?, pid?, sandbox_used, sandbox_name, fd, file_path, exit_code? }
function M.spawn(driver, cmd, rule_overrides)
  local file_path = vim.fn.tempname() .. ".out"
  local fd = uv.fs_open(file_path, "w", 384)
  if not fd then
    return { completed = false, error = "fd: could not open " .. file_path }
  end

  local opts = M.build_sandbox_opts(driver, rule_overrides)
  local use_sandbox = driver.name ~= "none"

  local result = {
    completed = false,
    sandbox_used = use_sandbox,
    sandbox_name = nil,
    fd = fd,
    file_path = file_path,
  }

  local handle, pid, sandbox_used, sandbox_name = sandbox.run(opts, {
    cmd = cmd,
    fd = fd,
    use_sandbox = use_sandbox,
    on_exit = function(code)
      result.exit_code = code
      result.completed = true
    end,
  })

  if not handle then
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)
    return {
      completed = false,
      error = "spawn: " .. tostring(pid),
      file_path = file_path,
    }
  end

  uv.unref(handle)
  result.handle = handle
  result.pid = pid
  result.sandbox_used = sandbox_used
  result.sandbox_name = sandbox_name
  return result
end

---Run a command under a driver and wait for completion.
---Uses `fast_only = true` for `vim.wait` so the default headless reporter's
---`cquit` in `reporter.finish` is not processed during the wait.
---@param driver table
---@param cmd string
---@param rule_overrides? table
---@return table result { completed: boolean, error?, handle?, pid?, sandbox_used, sandbox_name, exit_code, content }
function M.run_and_wait(driver, cmd, rule_overrides)
  local result = M.spawn(driver, cmd, rule_overrides)
  if result.completed == false and result.error ~= nil then
    return result
  end

  local ok = vim.wait(5000, function()
    return result.completed
  end, 50, true)

  local content = ""
  if result.fd then
    pcall(uv.fs_close, result.fd)
  end
  if result.file_path then
    content = M.read_output(result.file_path)
    pcall(os.remove, result.file_path)
  end

  if not ok then
    result.completed = false
    result.error = "wait: timeout"
    return result
  end

  result.content = content
  return result
end

---Kill a process/sandbox and wait for the kill callback.
---Uses `fast_only = true` for `vim.wait` so the default headless reporter's
---`cquit` in `reporter.finish` is not processed during the wait.
---@param driver table
---@param pid integer
---@param sandbox_name string|nil
---@param on_killed? function Optional caller callback forwarded to `sandbox.kill`.
---@param result? table Optional spawn result containing fd/file_path to clean up after kill.
function M.kill_and_wait(driver, pid, sandbox_name, on_killed, result)
  local opts = M.build_sandbox_opts(driver)
  local done = false

  local function wrapped()
    if on_killed then
      on_killed()
    end
    done = true
  end

  sandbox.kill(opts, sandbox_name, pid, wrapped)

  local ok = vim.wait(5000, function()
    return done and (result == nil or result.completed)
  end, 50, true)

  if result then
    if result.fd then
      pcall(uv.fs_close, result.fd)
    end
    if result.file_path then
      pcall(os.remove, result.file_path)
    end
  end

  if not ok then
    error("kill_and_wait timed out")
  end
end

return M
