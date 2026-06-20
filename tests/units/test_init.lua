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
  -- default configuration is applied with enabled=true and default rules.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  -- Reset and setup with no sandbox opts
  tools_config.run_bash = nil
  run_bash.setup({})

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts ~= nil, "sandbox opts should exist")
  MiniTest.expect.equality(true, s_opts.enabled, "sandbox should be enabled by default")
  MiniTest.expect.equality(
    "function",
    type(s_opts.rules.readable),
    "rules.readable should be a function"
  )
  MiniTest.expect.equality(
    "function",
    type(s_opts.rules.writable),
    "rules.writable should be a function"
  )
  MiniTest.expect.equality(
    true,
    type(s_opts.rules.readable()) == "table",
    "readable should return table"
  )
  MiniTest.expect.equality(
    true,
    type(s_opts.rules.writable()) == "table",
    "writable should return table"
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
    "function",
    type(s_opts.rules.readable),
    "default readable rule should be preserved"
  )
  MiniTest.expect.equality(
    "function",
    type(s_opts.rules.writable),
    "default writable rule should be preserved"
  )
end

T["init: partial rules override merges with defaults"] = function()
  -- Intent: Verify that overriding only rules.writable still preserves
  -- the default rules.readable from defaults.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  local custom_writable = function()
    return { "/custom/path" }
  end

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = { profile = "/some/profile.toml", rules = { writable = custom_writable } },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts.enabled, "default enabled should be true")
  MiniTest.expect.equality(
    true,
    s_opts.profile == "/some/profile.toml",
    "user profile should be set"
  )
  MiniTest.expect.equality(
    "function",
    type(s_opts.rules.readable),
    "default readable rule should be preserved"
  )
  MiniTest.expect.equality(
    custom_writable,
    s_opts.rules.writable,
    "user writable override should be used"
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

return T
