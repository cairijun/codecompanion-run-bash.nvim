--[[
Test: resolver.lua — Generic Path Resolver

Intent: Verify resolve_path correctly expands ~, $VAR, XDG fallbacks,
fails fast on non-string input, and strips trailing slashes.
Verify resolve_fs_rules groups paths into readable/writable/denied
arrays, deduplicates, and applies existence checks per group
(skip for fs_denied).
]]

local resolver = require("codecompanion._extensions.run_bash.sandbox.resolver")

local T = MiniTest.new_set()

-- ── resolve_path tests ───────────────────────────────────────────

T["resolve_path: ~ expands to home directory"] = function()
  local result = resolver.resolve_path("~/test", false)
  MiniTest.expect.equality(vim.fn.expand("~") .. "/test", result)
end

T["resolve_path: $HOME expands"] = function()
  local result = resolver.resolve_path("$HOME/test", false)
  MiniTest.expect.equality(vim.fn.expand("$HOME") .. "/test", result)
end

T["resolve_path: XDG_DATA_HOME fallback when unset"] = function()
  local saved = vim.env.XDG_DATA_HOME
  vim.env.XDG_DATA_HOME = nil
  local result = resolver.resolve_path("$XDG_DATA_HOME/a", false)
  vim.env.XDG_DATA_HOME = saved
  MiniTest.expect.equality(vim.fn.expand("~") .. "/.local/share/a", result)
end

T["resolve_path: XDG_DATA_HOME set to custom path"] = function()
  local saved = vim.env.XDG_DATA_HOME
  vim.env.XDG_DATA_HOME = "/tmp/xdg-custom"
  local result = resolver.resolve_path("$XDG_DATA_HOME/a", false)
  vim.env.XDG_DATA_HOME = saved
  MiniTest.expect.equality("/tmp/xdg-custom/a", result)
end

T["resolve_path: XDG_RUNTIME_DIR unset has no fallback"] = function()
  local saved = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = nil
  local result = resolver.resolve_path("$XDG_RUNTIME_DIR/a", false)
  vim.env.XDG_RUNTIME_DIR = saved
  MiniTest.expect.equality(nil, result)
end

T["resolve_path: existence check passes for existing path"] = function()
  -- /usr exists on virtually all Linux systems
  local result = resolver.resolve_path("/usr", true)
  MiniTest.expect.equality("/usr", result)
end

T["resolve_path: existence check fails for nonexistent path"] = function()
  local result = resolver.resolve_path("/nonexistent-xyz", true)
  MiniTest.expect.equality(nil, result)
end

T["resolve_path: fs_denied path not existence-checked"] = function()
  local result = resolver.resolve_path("/nonexistent-deny", false)
  MiniTest.expect.equality("/nonexistent-deny", result)
end

T["resolve_path: non-string path raises error"] = function()
  local ok, err = pcall(resolver.resolve_path, 123, false)
  MiniTest.expect.equality(false, ok)
  MiniTest.expect.equality(
    true,
    type(err) == "string" and err:find("rule path must be a string") ~= nil
  )
end

T["resolve_path: trailing slash removed"] = function()
  local result = resolver.resolve_path("/usr/", false)
  MiniTest.expect.equality("/usr", result)
end

-- ── resolve_fs_rules tests ───────────────────────────────────────

local function truthy_fs()
  return {}
end

local function mk_fs(exists_set)
  return function(path)
    return exists_set[path] and {}
  end
end

T["resolve_fs_rules: groups into readable/writable/denied"] = function()
  local result = resolver.resolve_fs_rules({
    fs_readable = { "/a" },
    fs_writable = { "/b" },
    fs_denied = { "/c" },
  }, truthy_fs)
  MiniTest.expect.equality({ "/a" }, result.readable)
  MiniTest.expect.equality({ "/b" }, result.writable)
  MiniTest.expect.equality({ "/c" }, result.denied)
end

T["resolve_fs_rules: deduplicates paths within group"] = function()
  local result = resolver.resolve_fs_rules({
    fs_readable = { "/a", "/a" },
  }, truthy_fs)
  MiniTest.expect.equality({ "/a" }, result.readable)
  MiniTest.expect.equality({}, result.writable)
  MiniTest.expect.equality({}, result.denied)
end

T["resolve_fs_rules: readable skips nonexistent, denied keeps all"] = function()
  local result = resolver.resolve_fs_rules({
    fs_readable = { "/usr", "/missing" },
    fs_denied = { "/deny" },
  }, mk_fs({ ["/usr"] = true }))
  MiniTest.expect.equality({ "/usr" }, result.readable)
  MiniTest.expect.equality({ "/deny" }, result.denied)
  MiniTest.expect.equality({}, result.writable)
end

return T
