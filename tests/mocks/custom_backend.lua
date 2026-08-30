-- Mock custom backend for testing facade loading
local M = {}

function M.is_available(opts)
  return true
end

function M.validate_opts(opts)
  return nil
end

function M.capabilities()
  return {
    kill_by_name = true,
    fs_deny_files = true,
    fs_deny_dirs = "block",
  }
end

function M.get_description()
  return "custom mock backend"
end

function M.run(opts, exec_params)
  -- Not implemented for mock
end

function M.kill(opts, sandbox_name, pid, on_killed, deps)
  -- Not implemented for mock
end

return M
