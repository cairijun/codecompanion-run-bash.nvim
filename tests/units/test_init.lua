--[[
Test: run_bash — Unit Tests for init.lua

Intent: Verify init.setup() registration and config merging in isolation.
These tests call init.setup() directly and verify config merging — they don't need Chat.
]]

local Helpers = require("tests.helpers")

-- Save/restore tools_config.run_bash across tests to prevent cross-file contamination
local saved_run_bash_config = nil

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      local tools_config = require("codecompanion.config").interactions.chat.tools
      saved_run_bash_config = tools_config.run_bash
    end,
    post_once = function()
      local tools_config = require("codecompanion.config").interactions.chat.tools
      tools_config.run_bash = saved_run_bash_config
    end,
  },
})

-- ── Extension registration ───────────────────────────────────────

T["init: setup registers run_bash in tools_config"] = function()
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  -- Ensure not already registered
  tools_config.run_bash = nil

  run_bash.setup({ sandbox = { enabled = false } })

  MiniTest.expect.equality(true, tools_config.run_bash ~= nil)
  MiniTest.expect.equality(true, tools_config.run_bash.opts.require_cmd_approval)
  MiniTest.expect.equality(false, tools_config.run_bash.opts.allowed_in_yolo_mode)
  MiniTest.expect.equality("function", type(tools_config.run_bash.opts.require_approval_before))
  MiniTest.expect.equality("function", type(tools_config.run_bash.callback))
end

-- ── Config merging tests ──────────────────────────────────────────

T["init: default sandbox config applied when no opts"] = function()
  -- Intent: Verify that when no sandbox options are provided,
  -- default configuration is applied with enabled=true and default fs_* rules.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  -- Reset and setup with no sandbox opts
  tools_config.run_bash = nil
  run_bash.setup({})

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts ~= nil, "sandbox opts should exist")
  MiniTest.expect.equality(true, s_opts.enabled, "sandbox should be enabled by default")
  MiniTest.expect.equality(
    "table",
    type(s_opts.rules.fs_readable),
    "rules.fs_readable should be a table"
  )
  MiniTest.expect.equality(
    "table",
    type(s_opts.rules.fs_writable),
    "rules.fs_writable should be a table"
  )
  MiniTest.expect.equality(
    "table",
    type(s_opts.rules.fs_denied),
    "rules.fs_denied should be a table"
  )
end

T["init: partial sandbox opts merge with defaults"] = function()
  -- Intent: Verify that partial sandbox options merge with defaults
  -- rather than replacing them entirely.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = false } })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(false, s_opts.enabled, "user override should be preserved")
  MiniTest.expect.equality(true, s_opts.rules ~= nil, "default rules should still be present")
end

T["init: enabled=false disables sandbox"] = function()
  -- Intent: Verify that user can explicitly disable sandbox by setting
  -- enabled = false, overriding the default true.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = false } })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(false, s_opts.enabled, "enabled should be false when user overrides")
  -- Rules from defaults should still be merged in
  MiniTest.expect.equality(
    "table",
    type(s_opts.rules.fs_readable),
    "default fs_readable rule should be preserved"
  )
  MiniTest.expect.equality(
    "table",
    type(s_opts.rules.fs_writable),
    "default fs_writable rule should be preserved"
  )
end

T["init: partial rules override preserves unset defaults"] = function()
  -- Intent: Verify that overriding only rules.fs_writable still preserves
  -- the default rules.fs_readable and fs_denied from defaults.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = { profile = "/some/profile.toml", rules = { fs_writable = { "/custom/path" } } },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts.enabled, "default enabled should be true")
  MiniTest.expect.equality(
    true,
    s_opts.profile == "/some/profile.toml",
    "user profile should be set"
  )
  MiniTest.expect.equality(
    "table",
    type(s_opts.rules.fs_readable),
    "default fs_readable rule should be preserved"
  )
  MiniTest.expect.equality(
    "table",
    type(s_opts.rules.fs_denied),
    "default fs_denied rule should be preserved"
  )
  MiniTest.expect.equality(
    { "/custom/path" },
    s_opts.rules.fs_writable,
    "user fs_writable override should be used"
  )
end

-- ── Extra args tests ─────────────────────────────────────────────

T["init: extra_args merged correctly"] = function()
  -- Intent: Verify that extra_args from user config is correctly merged
  -- into sandbox_opts via vim.tbl_deep_extend.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = {
      enabled = true,
      extra_args = { "--allow-degraded", "signal-scope" },
    },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts ~= nil, "sandbox opts should exist")
  MiniTest.expect.equality(true, s_opts.enabled ~= nil, "enabled should be present")
  MiniTest.expect.equality(true, s_opts.extra_args ~= nil, "extra_args should be present")
  MiniTest.expect.equality(2, #s_opts.extra_args, "extra_args should have 2 elements")
  MiniTest.expect.equality("--allow-degraded", s_opts.extra_args[1])
  MiniTest.expect.equality("signal-scope", s_opts.extra_args[2])
end

T["init: extra_args empty when not configured"] = function()
  -- Intent: Verify that when extra_args is not configured, it remains nil.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = {
      enabled = true,
    },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts ~= nil, "sandbox opts should exist")
  MiniTest.expect.equality(nil, s_opts.extra_args, "extra_args should be nil when not configured")
end

-- ── require_approval_before tests ───────────────────────────────

T["init: require_approval_before auto-approves kill action"] = function()
  -- Intent: Verify that kill action always returns false (auto-approved)
  -- regardless of sandbox config — kill short-circuits before should_use.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = true } })

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { action = "kill", session_id = "test" },
    opts = { sandbox = { enabled = true } },
  }
  MiniTest.expect.equality(false, fn(tool_obj, {}))
end

T["init: require_approval_before requires approval for non-sandbox mode"] = function()
  -- Intent: Verify that non-sandbox mode (enabled=false) always requires
  -- approval — should_use returns false when enabled=false.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = false } })

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "echo hello" },
    opts = { sandbox = { enabled = false } },
  }
  MiniTest.expect.equality(true, fn(tool_obj, {}))
end

T["init: require_approval_before auto-approves safe sandbox command"] = function()
  -- Intent: Verify that a safe command (not in blocklist) in sandbox mode
  -- is auto-approved. Mock should_use to bypass sandlock availability check.
  local run_bash = require("codecompanion._extensions.run_bash")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = true } })

  local orig_should_use = sandbox_mod.should_use
  sandbox_mod.should_use = function()
    return true
  end

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "echo hello" },
    opts = { sandbox = { enabled = true } },
  }
  local result = fn(tool_obj, {})

  sandbox_mod.should_use = orig_should_use

  MiniTest.expect.equality(false, result)
end

T["init: require_approval_before requires approval for blocklisted command in sandbox"] = function()
  -- Intent: Verify that a blocklisted command (rm -rf) in sandbox mode
  -- requires approval. Mock should_use to bypass sandlock availability check.
  local run_bash = require("codecompanion._extensions.run_bash")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = true } })

  local orig_should_use = sandbox_mod.should_use
  sandbox_mod.should_use = function()
    return true
  end

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "rm -rf /tmp/test" },
    opts = { sandbox = { enabled = true } },
  }
  local result = fn(tool_obj, {})

  sandbox_mod.should_use = orig_should_use

  MiniTest.expect.equality(true, result)
end

T["init: require_approval_before requires approval when skip_sandbox=true"] = function()
  -- Intent: Verify that skip_sandbox=true forces the non-sandbox branch,
  -- requiring approval even when sandbox is enabled.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = true } })

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "echo hello", skip_sandbox = true },
    opts = { sandbox = { enabled = true } },
  }
  MiniTest.expect.equality(true, fn(tool_obj, {}))
end

-- ── resolve_rules tests ──────────────────────────────────────────

T["init: resolve_rules table replaces defaults"] = function()
  -- Intent: Verify that a table rule completely replaces the default,
  -- and unset keys retain their default values.
  local run_bash = require("codecompanion._extensions.run_bash")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = { rules = { fs_readable = { "/custom" } } },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    { "/custom" },
    s_opts.rules.fs_readable,
    "fs_readable should be user table"
  )
  MiniTest.expect.equality(
    sandbox_mod.defaults.rules.fs_writable,
    s_opts.rules.fs_writable,
    "fs_writable should be default table"
  )
  MiniTest.expect.equality(
    sandbox_mod.defaults.rules.fs_denied,
    s_opts.rules.fs_denied,
    "fs_denied should be default table"
  )
end

T["init: resolve_rules function transforms defaults"] = function()
  -- Intent: Verify that a function rule receives the default table and
  -- can append to it without affecting the original defaults.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = {
      rules = {
        fs_writable = function(defaults)
          local copy = vim.deepcopy(defaults)
          table.insert(copy, "/extra")
          return copy
        end,
      },
    },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality("table", type(s_opts.rules.fs_writable), "fs_writable should be a table")
  MiniTest.expect.equality(true, #s_opts.rules.fs_writable > 0, "fs_writable should have entries")
  -- Last entry should be /extra
  MiniTest.expect.equality(
    "/extra",
    s_opts.rules.fs_writable[#s_opts.rules.fs_writable],
    "last entry should be /extra"
  )
end

T["init: resolve_rules function receives deepcopy"] = function()
  -- Intent: Verify that the function receives a deepcopy of defaults,
  -- preventing in-place mutation of sandbox.defaults.rules.
  local run_bash = require("codecompanion._extensions.run_bash")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = {
      rules = {
        fs_writable = function(defaults)
          table.insert(defaults, "/mutated")
          return defaults
        end,
      },
    },
  })

  -- The original defaults must NOT contain /mutated
  MiniTest.expect.equality(
    false,
    vim.tbl_contains(sandbox_mod.defaults.rules.fs_writable, "/mutated"),
    "defaults.fs_writable should NOT contain /mutated"
  )
end

T["init: resolve_rules nil uses defaults"] = function()
  -- Intent: Verify that when no sandbox rules are configured, all three
  -- fs_* keys come from sandbox.defaults.rules.
  local run_bash = require("codecompanion._extensions.run_bash")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({})

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    sandbox_mod.defaults.rules.fs_readable,
    s_opts.rules.fs_readable,
    "fs_readable should be default"
  )
  MiniTest.expect.equality(
    sandbox_mod.defaults.rules.fs_writable,
    s_opts.rules.fs_writable,
    "fs_writable should be default"
  )
  MiniTest.expect.equality(
    sandbox_mod.defaults.rules.fs_denied,
    s_opts.rules.fs_denied,
    "fs_denied should be default"
  )
end

T["init: resolve_rules invalid type throws error"] = function()
  -- Intent: Verify that a non-table, non-function rule value raises
  -- an error message containing "must be a table or function".
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  local ok, err = pcall(run_bash.setup, {
    sandbox = { rules = { fs_readable = 123 } },
  })

  MiniTest.expect.equality(false, ok, "should throw error")
  MiniTest.expect.equality(
    true,
    type(err) == "string" and err:find("must be a table or function") ~= nil,
    "error should mention 'must be a table or function': " .. tostring(err)
  )
end

T["init: resolve_rules function returning non-table throws error"] = function()
  -- Intent: Verify that a function rule returning a non-table raises
  -- an error message containing "must return a table".
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  local ok, err = pcall(run_bash.setup, {
    sandbox = {
      rules = {
        fs_readable = function()
          return "string"
        end,
      },
    },
  })

  MiniTest.expect.equality(false, ok, "should throw error")
  MiniTest.expect.equality(
    true,
    type(err) == "string" and err:find("must return a table") ~= nil,
    "error should mention 'must return a table': " .. tostring(err)
  )
end

T["init: resolve_rules function that throws propagates error"] = function()
  -- Intent: Verify that a function rule that raises an error propagates
  -- the error (pcall returns false).
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  local ok, err = pcall(run_bash.setup, {
    sandbox = {
      rules = {
        fs_readable = function()
          error("boom")
        end,
      },
    },
  })

  MiniTest.expect.equality(false, ok, "should throw error")
end

return T
