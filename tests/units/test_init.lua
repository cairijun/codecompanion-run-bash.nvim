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
  MiniTest.expect.equality("sandlock", s_opts.backend, "sandbox should default to sandlock backend")
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

T["init: legacy enabled=false migrates to backend=false"] = function()
  -- Intent: Legacy { sandbox = { enabled = false } } must keep sandbox disabled.
  -- setup() should migrate the legacy flag to backend = false.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = false } })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    false,
    s_opts.backend,
    "legacy enabled=false should migrate to backend=false"
  )
  MiniTest.expect.equality(false, s_opts.enabled, "legacy enabled=false should be preserved")
end

T["init: legacy enabled=true does not override default backend"] = function()
  -- Intent: Legacy enabled=true alone should not disable the sandbox.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = true } })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    "sandlock",
    s_opts.backend,
    "enabled=true should not change default backend"
  )
end

T["init: backend=false disables sandbox"] = function()
  -- Intent: Verify that user can explicitly disable sandbox by setting
  -- backend = false, overriding the default "sandlock".
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { backend = false } })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    false,
    s_opts.backend,
    "backend should be false (sandbox disabled by user)"
  )
  -- Rules from defaults should still be merged in even when sandbox is disabled
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

  -- Legacy format (profile + no backend) should auto-migrate to the new structure:
  -- { backend="sandlock", backends={ sandlock={ profile=... } } }
  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    "sandlock",
    s_opts.backend,
    "migrated config should use sandlock backend"
  )
  MiniTest.expect.equality(
    "/some/profile.toml",
    s_opts.backends.sandlock.profile,
    "user profile should be migrated to backends.sandlock.profile"
  )
  MiniTest.expect.equality(
    true,
    s_opts.profile == nil,
    "top-level profile should NOT be preserved after migration"
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
      backend = "sandlock",
      rules = {},
      backends = {
        sandlock = { extra_args = { "--allow-degraded", "signal-scope" } },
      },
    },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts ~= nil, "sandbox opts should exist")
  MiniTest.expect.equality("sandlock", s_opts.backend, "backend should be sandlock")
  MiniTest.expect.equality(
    true,
    s_opts.backends.sandlock.extra_args ~= nil,
    "backends.sandlock.extra_args should be present"
  )
  MiniTest.expect.equality(
    2,
    #s_opts.backends.sandlock.extra_args,
    "extra_args should have 2 elements"
  )
  MiniTest.expect.equality("--allow-degraded", s_opts.backends.sandlock.extra_args[1])
  MiniTest.expect.equality("signal-scope", s_opts.backends.sandlock.extra_args[2])
end

T["init: extra_args empty when not configured"] = function()
  -- Intent: Verify that when extra_args is not configured, it remains nil.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = {
      backend = "sandlock",
      rules = {},
    },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(true, s_opts ~= nil, "sandbox opts should exist")
  MiniTest.expect.equality(
    nil,
    s_opts.backends.sandlock.extra_args,
    "backends.sandlock.extra_args should be nil when not configured"
  )
end

local function with_should_use_stub(sandbox_mod, return_value, fn)
  -- Intent: Mock sandbox.should_use and guarantee restoration even if fn errors.
  local orig = sandbox_mod.should_use
  sandbox_mod.should_use = function()
    return return_value
  end
  local ok, err = pcall(fn)
  sandbox_mod.should_use = orig
  if not ok then
    error(err, 0)
  end
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
  -- Intent: Verify that non-sandbox mode (backend=false) always requires
  -- approval — should_use returns false when backend=false.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { backend = false } })

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "echo hello" },
    opts = { sandbox = { backend = false } },
  }
  MiniTest.expect.equality(true, fn(tool_obj, {}))
end

T["init: legacy enabled=false requires approval through full pipeline"] = function()
  -- Intent: Verify that the legacy enabled=false migration still results in
  -- a non-sandbox config that requires approval in require_approval_before.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = false } })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    false,
    s_opts.backend,
    "legacy enabled=false should migrate to backend=false"
  )

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "echo hello" },
    opts = { sandbox = s_opts },
  }
  MiniTest.expect.equality(true, fn(tool_obj, {}))
end

T["init: require_approval_before auto-approves safe sandbox command"] = function()
  -- Intent: Verify that a safe command (not in pause list) in sandbox mode
  -- is auto-approved. Mock should_use to bypass sandlock availability check.
  local run_bash = require("codecompanion._extensions.run_bash")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = true } })

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "echo hello" },
    opts = { sandbox = { enabled = true } },
  }

  with_should_use_stub(sandbox_mod, true, function()
    MiniTest.expect.equality(false, fn(tool_obj, {}))
  end)
end

T["init: require_approval_before requires approval for pause-listed command in sandbox"] = function()
  -- Intent: Verify that a pause-listed command (rm -rf) in sandbox mode
  -- requires approval. Mock should_use to bypass sandlock availability check.
  local run_bash = require("codecompanion._extensions.run_bash")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({ sandbox = { enabled = true } })

  local fn = tools_config.run_bash.opts.require_approval_before
  local tool_obj = {
    args = { cmd = "rm -rf /tmp/test" },
    opts = { sandbox = { enabled = true } },
  }

  with_should_use_stub(sandbox_mod, true, function()
    MiniTest.expect.equality(true, fn(tool_obj, {}))
  end)
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

-- ── New format / migration tests ─────────────────────────────────────

T["init: new format fully preserves backend, rules, and backends structure"] = function()
  -- Intent: Verify that the new-format config passes through init.setup()
  -- unchanged in structure: backend, rules, and backends.<name> are all kept.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  local user_rules = {
    fs_readable = { "/opt" },
    fs_writable = { "/var/log" },
    fs_denied = { "/etc/shadow" },
  }
  run_bash.setup({
    sandbox = {
      backend = "sandlock",
      rules = user_rules,
      backends = {
        sandlock = { profile = "/tmp/test.toml", extra_args = { "--flag1" } },
      },
    },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality("sandlock", s_opts.backend)
  MiniTest.expect.equality(user_rules.fs_readable, s_opts.rules.fs_readable)
  MiniTest.expect.equality(user_rules.fs_writable, s_opts.rules.fs_writable)
  MiniTest.expect.equality(user_rules.fs_denied, s_opts.rules.fs_denied)
  MiniTest.expect.equality("/tmp/test.toml", s_opts.backends.sandlock.profile)
  MiniTest.expect.equality({ "--flag1" }, s_opts.backends.sandlock.extra_args)
end

T["init: legacy format migration wraps into backends.sandlock"] = function()
  -- Intent: Verify that an old-format config (profile + extra_args without
  -- backend) auto-migrates to backend="sandlock" with profile/extra_args
  -- moved into backends.sandlock, and top-level extra_args is NOT preserved.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  run_bash.setup({
    sandbox = {
      profile = "/tmp/legacy-profile.toml",
      extra_args = { "-x" },
      rules = {},
    },
  })

  local s_opts = tools_config.run_bash.opts.sandbox
  MiniTest.expect.equality(
    "sandlock",
    s_opts.backend,
    "legacy config should migrate to sandlock backend"
  )
  MiniTest.expect.equality("/tmp/legacy-profile.toml", s_opts.backends.sandlock.profile)
  MiniTest.expect.equality(
    { "-x" },
    s_opts.backends.sandlock.extra_args,
    "extra_args should migrate to backends.sandlock"
  )
  MiniTest.expect.equality(
    true,
    s_opts.extra_args == nil,
    "top-level extra_args should NOT be preserved after migration"
  )
end

T["init: validate_opts error propagates as setup() failure"] = function()
  -- Intent: Verify that an invalid backend-specific config causes setup()
  -- to raise an error (via sandbox.validate_backend_opts) so misconfiguration
  -- is caught at startup rather than at tool invocation time.
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  tools_config.run_bash = nil
  local ok, err = pcall(run_bash.setup, {
    sandbox = {
      backend = "sandlock",
      backends = {
        -- extra_args must be a table or nil, not a string
        sandlock = { extra_args = "invalid-string-value" },
      },
    },
  })

  MiniTest.expect.equality(false, ok, "setup should throw when backend opts are invalid")
  MiniTest.expect.equality(true, type(err) == "string", "error message should be a string")
end

return T
