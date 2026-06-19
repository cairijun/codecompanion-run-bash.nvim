--[[
Test: run_bash — Integration Tests (in-process)

Intent: Verify registration, approval decisions, and command execution
without child Neovim. For execution, test the tool handler directly
rather than via mock HTTP.

]]

local uv = vim.uv
local Helpers = require("tests.helpers")
local T = MiniTest.new_set()

-- ── Extension registration ───────────────────────────────────────

T["registration: setup registers run_bash in tools_config"] = function()
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

-- ── Approval decisions (non-sandbox mode) ────────────────────────

T["approval: run cmd requires approval in non-sandbox"] = function()
  local run_bash = require("codecompanion._extensions.run_bash")
  local tools_config = require("codecompanion.config").interactions.chat.tools

  -- Ensure setup was called
  if not tools_config.run_bash then
    run_bash.setup({ sandbox = { enabled = false } })
  end

  local approval_fn = tools_config.run_bash.opts.require_approval_before
  local tool = {
    args = { cmd = "echo hello", action = "run" },
    opts = { sandbox = { enabled = false } },
  }
  MiniTest.expect.equality(true, approval_fn(tool, {}))
end

T["approval: kill action is auto-approved"] = function()
  local tools_config = require("codecompanion.config").interactions.chat.tools
  local approval_fn = tools_config.run_bash.opts.require_approval_before

  local tool = {
    args = { action = "kill", session_id = "test-123" },
    opts = { sandbox = { enabled = false } },
  }
  MiniTest.expect.equality(false, approval_fn(tool, {}))
end

T["approval: default action (run) requires approval"] = function()
  local tools_config = require("codecompanion.config").interactions.chat.tools
  local approval_fn = tools_config.run_bash.opts.require_approval_before

  local tool = {
    args = { cmd = "ls" },
    opts = { sandbox = { enabled = false } },
  }
  MiniTest.expect.equality(true, approval_fn(tool, {}))
end

-- ── Tool definition and callback ─────────────────────────────────

T["tool: create returns valid tool definition"] = function()
  local tool = require("codecompanion._extensions.run_bash.tool")
  local def = tool.create({ enabled = false })

  MiniTest.expect.equality("run_bash", def.name)
  MiniTest.expect.equality(true, def.schema ~= nil)
  MiniTest.expect.equality(true, #def.cmds == 1)
  MiniTest.expect.equality(true, def.output ~= nil)
  MiniTest.expect.equality(true, def.system_prompt ~= nil)

  -- Schema has expected fields
  local props = def.schema["function"].parameters.properties
  MiniTest.expect.equality(true, props.cmd ~= nil)
  MiniTest.expect.equality(true, props.action ~= nil)
  MiniTest.expect.equality(true, props.timeout ~= nil)
  -- No skip_sandbox since sandbox not available
  MiniTest.expect.equality(true, props.skip_sandbox == nil)
end

T["tool: schema includes skip_sandbox when sandbox available"] = function()
  local sandbox = require("codecompanion._extensions.run_bash.sandbox")

  Helpers.require_sandbox()

  local tool = require("codecompanion._extensions.run_bash.tool")
  local path = Helpers.sandbox_profile_path()

  local def = tool.create({
    enabled = true,
    profile = path,
    rules = {},
  })

  local props = def.schema["function"].parameters.properties
  MiniTest.expect.equality(
    true,
    props.skip_sandbox ~= nil,
    "should have skip_sandbox when sandbox available"
  )
end

-- ── Command execution (tool handler test) ────────────────────────

T["execution: echo hello produces output via handler"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  -- Execute the handler
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "echo hello" }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  -- Wait for async execution to complete
  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)

  MiniTest.expect.equality(true, ok, "handler should complete within 5s")
  MiniTest.expect.equality(true, output_data ~= nil)

  if output_data then
    local d = Helpers.unwrap_cb_data(output_data)
    local output_text = d.output or ""
    Helpers.expect_contains("hello", output_text)
  end
end

T["execution: false (exit 1) reports failure"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "false" }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)

  MiniTest.expect.equality(true, ok)
  MiniTest.expect.equality(true, output_data ~= nil)

  if output_data then
    MiniTest.expect.equality("error", output_data.status)
  end
end

T["execution: kill nonexistent session returns error"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    action = "kill",
    session_id = "nonexistent-999",
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil, "should respond immediately")
  if output_data then
    local error_msg = (output_data.data and output_data.data.error) or ""
    Helpers.expect_contains("session not found", error_msg)
  end
end

T["execution: bg_after > 60 returns error"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo hello",
    bg_after = 61,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil)
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
    local error_msg = (output_data.data and output_data.data.error) or ""
    Helpers.expect_contains("bg_after", error_msg)
  end
end

T["execution: timeout > 3600 returns error"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo hello",
    timeout = 3601,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil)
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
    local error_msg = (output_data.data and output_data.data.error) or ""
    Helpers.expect_contains("Timeout", error_msg)
  end
end

T["execution: empty cmd returns error"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "",
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil)
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
  end
end

-- ── Blocklist approval via require_approval_before (sandbox mode) ─

T["blocklist: rm -rf blocked in sandbox mode"] = function()
  local tools_config = require("codecompanion.config").interactions.chat.tools
  local approval_fn = tools_config.run_bash.opts.require_approval_before

  -- Only test if sandlock and profile are available
  local profile = Helpers.sandbox_profile_path()
  Helpers.require_sandbox()

  local tool = {
    args = { cmd = "rm -rf /tmp/test", skip_sandbox = false },
    opts = {
      sandbox = { enabled = true, profile = profile },
    },
  }
  MiniTest.expect.equality(true, approval_fn(tool, {}))
end

T["blocklist: git status safe in sandbox mode"] = function()
  local tools_config = require("codecompanion.config").interactions.chat.tools
  local approval_fn = tools_config.run_bash.opts.require_approval_before

  local profile = Helpers.sandbox_profile_path()
  Helpers.require_sandbox()

  local tool = {
    args = { cmd = "git status", skip_sandbox = false },
    opts = {
      sandbox = { enabled = true, profile = profile },
    },
  }
  MiniTest.expect.equality(false, approval_fn(tool, {}))
end

-- ── Timeout and background execution ──────────────────────────────

T["execution: timeout kills long-running command"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "sleep 10",
    timeout = 1,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)

  MiniTest.expect.equality(true, ok, "should complete within 5s (timeout=1s + cleanup)")
  MiniTest.expect.equality(true, output_data ~= nil)

  if output_data then
    MiniTest.expect.equality("error", output_data.status)
    local d = Helpers.unwrap_cb_data(output_data)
    MiniTest.expect.equality(true, d.timed_out == true, "should be marked as timed out")
  end
end

T["execution: background mode returns session_id"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo STARTING; sleep 3",
    bg_after = 1,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)

  MiniTest.expect.equality(true, ok, "should return within 5s (bg_after=1s)")
  MiniTest.expect.equality(true, output_data ~= nil)

  if output_data then
    local d = Helpers.unwrap_cb_data(output_data)
    MiniTest.expect.equality(true, d.bg_running == true, "should be bg_running")
    MiniTest.expect.equality(true, d.session_id ~= nil, "should have session_id")
    MiniTest.expect.equality(true, d.file_path ~= nil, "should have file_path")
    Helpers.expect_contains("STARTING", d.output)

    -- Clean up: kill the background session
    handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
      action = "kill",
      session_id = d.session_id,
    }, {
      output_cb = function() end,
    })
  end
end

T["execution: bg quick exit returns full output"] = function()
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo done",
    bg_after = 2,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)

  MiniTest.expect.equality(true, ok, "should return within 5s (bg_after=2s)")
  MiniTest.expect.equality(true, output_data ~= nil)

  if output_data then
    local d = Helpers.unwrap_cb_data(output_data)
    MiniTest.expect.equality(true, d.bg_exited == true, "should be bg_exited")
    MiniTest.expect.equality(0, d.exit_code, "should have exit code 0")
    Helpers.expect_contains("done", d.output)
  end
end

T["execution: bg session cleaned up after natural exit"] = function()
  -- Intent: Verify that after a background command exits naturally,
  -- the session entry is cleaned up and the temp file is removed.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  local output_data = nil
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo done",
    bg_after = 1,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  -- Wait for timer to fire (bg_after=1s) and report output
  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)
  MiniTest.expect.equality(true, ok, "should return within 5s")

  if not output_data then
    return
  end

  local d = Helpers.unwrap_cb_data(output_data)
  MiniTest.expect.equality(true, d.bg_exited == true, "should be bg_exited")
  local file_path = d.file_path
  local session_id = d.session_id
  MiniTest.expect.equality(true, file_path ~= nil, "exited output should include file_path")
  MiniTest.expect.equality(true, session_id ~= nil, "exited output should include session_id")

  -- Session should be cleaned up: kill attempt returns "session not found"
  local kill_output = nil
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    action = "kill",
    session_id = session_id,
  }, {
    output_cb = function(data)
      kill_output = data
    end,
  })

  if kill_output then
    local error_msg = (kill_output.data and kill_output.data.error) or ""
    Helpers.expect_contains("session not found", error_msg)
  end

  -- Temp file should be removed
  if file_path then
    MiniTest.expect.equality(true, vim.uv.fs_stat(file_path) == nil, "temp file should be removed")
  end
end

-- ── Sandbox execution integration tests ──────────────

T["execution: sandbox mode executes command"] = function()
  -- Intent: Verify that when sandlock is available, the handler correctly
  -- executes commands under sandbox with sandbox_active=true.
  local profile = Helpers.sandbox_profile_path()
  Helpers.require_sandbox()

  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = true, profile = profile, rules = {} })
  local handler = def.cmds[1]

  local output_data = nil
  handler({ tool = { opts = { sandbox = { enabled = true, profile = profile, rules = {} } } } }, {
    cmd = "echo sandboxed",
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)
  MiniTest.expect.equality(true, ok, "should complete within 5s")

  if output_data then
    local d = Helpers.unwrap_cb_data(output_data)
    Helpers.expect_contains("sandboxed", d.output)
    MiniTest.expect.equality(true, d.sandbox_active == true, "sandbox should be active")
  end
end

T["execution: skip_sandbox bypasses sandbox"] = function()
  -- Intent: Verify that skip_sandbox=true bypasses the sandbox even when
  -- sandbox is available.
  local profile = Helpers.sandbox_profile_path()
  Helpers.require_sandbox()

  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = true, profile = profile, rules = {} })
  local handler = def.cmds[1]

  local output_data = nil
  handler({ tool = { opts = { sandbox = { enabled = true, profile = profile, rules = {} } } } }, {
    cmd = "echo no-sandbox",
    skip_sandbox = true,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)
  MiniTest.expect.equality(true, ok, "should complete within 5s")

  if output_data then
    local d = Helpers.unwrap_cb_data(output_data)
    Helpers.expect_contains("no-sandbox", d.output)
    MiniTest.expect.equality(true, d.sandbox_active == false, "sandbox should NOT be active")
  end
end

-- ── Missing required-parameter error tests ────────────────

T["execution: kill without session_id returns error"] = function()
  -- Intent: Verify handler returns proper error when session_id is missing
  -- for action='kill'.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    action = "kill",
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil)
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
    local error_msg = (output_data.data and output_data.data.error) or ""
    Helpers.expect_contains("session not found", error_msg)
  end
end

T["execution: run without cmd returns error"] = function()
  -- Intent: Verify handler returns proper error when cmd is missing
  -- for action='run'.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    action = "run",
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil)
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
    local error_msg = (output_data.data and output_data.data.error) or ""
    Helpers.expect_contains("cmd is required", error_msg)
  end
end

T["execution: no action defaults to run and requires cmd"] = function()
  -- Intent: Verify handler defaults to action='run' and returns error when
  -- cmd is missing.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {}, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil)
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
    local error_msg = (output_data.data and output_data.data.error) or ""
    Helpers.expect_contains("cmd is required", error_msg)
  end
end

-- ── Invalid sandbox profile error path ────────────────────

T["execution: invalid sandbox profile falls back to non-sandbox"] = function()
  -- Intent: Verify that when a non-existent sandbox profile is configured,
  -- execution gracefully falls back to non-sandbox mode.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = true, profile = "/nonexistent/profile.toml", rules = {} })
  local handler = def.cmds[1]

  local output_data = nil
  handler({
    tool = {
      opts = { sandbox = { enabled = true, profile = "/nonexistent/profile.toml", rules = {} } },
    },
  }, { cmd = "echo fallback" }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(5000, function()
    return output_data ~= nil
  end, 50)
  MiniTest.expect.equality(true, ok, "should complete within 5s")

  if output_data then
    local d = Helpers.unwrap_cb_data(output_data)
    Helpers.expect_contains("fallback", d.output)
    MiniTest.expect.equality(true, d.sandbox_active == false, "should fall back to non-sandbox")
  end
end

return T
