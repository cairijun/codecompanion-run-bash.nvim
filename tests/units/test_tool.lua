--[[
Test: tool.lua — Tool Definition and Handler

Intent: Verify tool handler behavior via spy-based unit tests, focusing on
resource cleanup, temp file security, and concurrency safety.

]]

local uv = vim.uv
local Helpers = require("tests.helpers")
local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

-- Saved originals for mock restoration after each test
local orig_new_timer, orig_fs_open, orig_fs_close, orig_fs_fstat, orig_fs_read
local orig_os_remove, orig_vim_schedule, orig_io_open
local orig_sandbox_run, orig_sandbox_kill, orig_sandbox_is_available

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      orig_new_timer = uv.new_timer
      orig_fs_open = uv.fs_open
      orig_fs_close = uv.fs_close
      orig_fs_fstat = uv.fs_fstat
      orig_fs_read = uv.fs_read
      orig_os_remove = os.remove
      orig_vim_schedule = vim.schedule
      orig_io_open = io.open
      orig_sandbox_run = sandbox_mod.run
      orig_sandbox_kill = sandbox_mod.kill
      orig_sandbox_is_available = sandbox_mod.is_available
    end,
    post = function()
      uv.new_timer = orig_new_timer
      uv.fs_open = orig_fs_open
      uv.fs_close = orig_fs_close
      uv.fs_fstat = orig_fs_fstat
      uv.fs_read = orig_fs_read
      os.remove = orig_os_remove
      vim.schedule = orig_vim_schedule
      io.open = orig_io_open
      sandbox_mod.run = orig_sandbox_run
      sandbox_mod.kill = orig_sandbox_kill
      sandbox_mod.is_available = orig_sandbox_is_available
    end,
  },
})

---Set up common mock configuration for ANSI and I/O tests.
---Returns a table with captured callbacks that tests can use for simulation.
---@param content string File content to return from uv.fs_read
---@return table captured { timer_cb: function|nil }
local function setup_common_mocks(content)
  local captured = {}

  uv.fs_open = function()
    return 999
  end
  uv.fs_close = function() end
  uv.fs_fstat = function()
    return { size = #content }
  end
  uv.fs_read = function()
    return content
  end
  os.remove = function()
    return true
  end
  vim.schedule = function(fn)
    fn()
  end
  uv.new_timer = function()
    return {
      start = function(self, ms, repeat_ms, cb)
        captured.timer_cb = cb
      end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end

  return captured
end

-- ── Foreground spawn failure: timer leak ────────────────────

T["tool: foreground spawn failure closes all timers"] = function()
  -- Intent: Verify that when sandbox.run() returns nil (spawn failure)
  -- in foreground mode, both timer and kill_timer handles are closed.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  -- Track created timers
  local created_timers = {}
  uv.new_timer = function()
    local t = {
      _closed = false,
      start = function() end,
      stop = function(self) end,
      close = function(self)
        self._closed = true
      end,
      is_closing = function(self)
        return self._closed
      end,
    }
    table.insert(created_timers, t)
    return t
  end

  -- Mock sandbox.run to return nil (spawn failure)
  sandbox_mod.run = function()
    return nil, "mock spawn error", false
  end

  uv.fs_open = function()
    return 999
  end
  uv.fs_close = function() end
  os.remove = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo test",
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  -- Verify error was reported
  MiniTest.expect.equality(true, output_data ~= nil, "should report error")
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
  end

  -- Verify all created timers were closed
  MiniTest.expect.equality(true, #created_timers > 0, "should have created timers")
  for i, t in ipairs(created_timers) do
    MiniTest.expect.equality(true, t._closed, "timer " .. i .. " should be closed")
  end
end

-- ── Temp file security ────────────────────────────────────

T["tool: temp file uses secure path and mode"] = function()
  -- Intent: Verify that temp output files use vim.fn.tempname() (random, secure path)
  -- and mode 0600 (384), not hardcoded /tmp/cc-bash-*.out with mode 0644.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local captured_path = nil
  local captured_mode = nil

  uv.fs_open = function(path, mode, permissions)
    captured_path = path
    captured_mode = permissions
    return 999
  end
  uv.fs_close = function() end
  uv.new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end
  sandbox_mod.run = function()
    return nil, "mock error", false
  end
  os.remove = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo test",
  }, {
    output_cb = function() end,
  })

  MiniTest.expect.equality(true, captured_path ~= nil, "fs_open should be called")
  if captured_path then
    MiniTest.expect.equality(
      true,
      captured_path:match("^/tmp/cc%-bash%-") == nil,
      "should not use /tmp/cc-bash-* pattern"
    )
    MiniTest.expect.equality(384, captured_mode, "should use mode 0600 (384 decimal)")
  end
end

-- ── _sandbox_active concurrency race ──────────────────────

T["tool: handler does not set shared _sandbox_active"] = function()
  -- Intent: Verify that sandbox_active is NOT set as shared mutable state
  -- on the tools object, preventing race conditions between concurrent calls.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  sandbox_mod.run = function()
    return { close = function() end }, 12345, true
  end
  uv.fs_open = function()
    return 999
  end
  uv.fs_close = function() end
  uv.new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end
  os.remove = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local tools_obj = { tool = { opts = { sandbox = { enabled = false } } } }
  handler(tools_obj, { cmd = "echo test" }, {
    output_cb = function() end,
  })

  -- _sandbox_active should NOT be set on the shared tools object
  MiniTest.expect.equality(
    true,
    tools_obj.tool._sandbox_active == nil,
    "should not set shared _sandbox_active"
  )
end

-- ── Session ID uniqueness ──────────────────────────────────

T["tool: session IDs are unique across rapid calls"] = function()
  -- Intent: Verify that generating many session IDs rapidly produces
  -- all unique values, preventing collisions that cause output file conflicts.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local session_ids = {}
  sandbox_mod.run = function(sandbox_opts, exec_params)
    local name = exec_params.sandbox_name
    if name and name:match("^cc%-bash%-(.+)$") then
      table.insert(session_ids, name:match("^cc%-bash%-(.+)$"))
    end
    return nil, "mock error", true
  end
  sandbox_mod.is_available = function()
    return true
  end
  uv.fs_open = function()
    return 999
  end
  uv.fs_close = function() end
  uv.new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end
  os.remove = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  -- Call handler 500 times rapidly
  for i = 1, 500 do
    handler({ tool = { opts = { sandbox = { enabled = true } } } }, { cmd = "echo " .. i }, {
      output_cb = function() end,
    })
  end

  -- Count unique session IDs
  local seen = {}
  local unique = 0
  for _, id in ipairs(session_ids) do
    if not seen[id] then
      seen[id] = true
      unique = unique + 1
    end
  end

  MiniTest.expect.equality(true, #session_ids == 500, "should have captured 500 session IDs")
  MiniTest.expect.equality(
    true,
    unique == 500,
    "all 500 session IDs should be unique, got " .. unique
  )
end

-- ── No blocking io.open in async callbacks ────────────────

T["tool: on_exit does not use blocking io.open"] = function()
  -- Intent: Verify that file reading in async callbacks uses uv.fs_*
  -- functions, not synchronous io.open/f:read.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local io_open_called = false
  io.open = function()
    io_open_called = true
    return nil
  end

  local captured_on_exit = nil
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, false
  end
  sandbox_mod.kill = function() end
  uv.fs_open = function()
    return 999
  end
  uv.fs_close = function() end
  uv.fs_fstat = function()
    return { size = 5 }
  end
  uv.fs_read = function()
    return "hello"
  end
  uv.new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end
  os.remove = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "echo test" }, {
    output_cb = function() end,
  })

  -- Simulate process exit
  if captured_on_exit then
    captured_on_exit(0, 0)
  end

  MiniTest.expect.equality(true, not io_open_called, "io.open should NOT be called in on_exit")
end

-- ── Conditional sandbox.kill on clean exit ─────────────────

T["tool: sandbox.kill not called on clean exit"] = function()
  -- Intent: Verify that sandbox.kill() is NOT called when a foreground
  -- process exits cleanly (code 0, signal 0).
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local kill_called = false
  sandbox_mod.kill = function()
    kill_called = true
  end

  local captured_on_exit = nil
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, false
  end
  uv.fs_open = function()
    return 999
  end
  uv.fs_close = function() end
  uv.fs_fstat = function()
    return { size = 0 }
  end
  uv.fs_read = function()
    return ""
  end
  uv.new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end
  os.remove = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "echo test" }, {
    output_cb = function() end,
  })

  -- Simulate clean exit (code=0, signal=0)
  if captured_on_exit then
    captured_on_exit(0, 0)
  end

  MiniTest.expect.equality(true, not kill_called, "sandbox.kill should NOT be called on clean exit")
end

-- ── ANSI color code stripping ─────────────────────────────

T["tool: foreground output strips ANSI color codes"] = function()
  -- Intent: Verify ANSI escape sequences are stripped from foreground
  -- command output before being sent to output_cb.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local ansi_content = "\27[31mred text\27[0m"
  local expected = "red text"

  setup_common_mocks(ansi_content)

  local captured_on_exit
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, false
  end
  sandbox_mod.kill = function() end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "echo test" }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  if captured_on_exit then
    captured_on_exit(0, 0)
  end

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

T["tool: background bg_running output strips ANSI color codes"] = function()
  -- Intent: Verify ANSI escape sequences are stripped from background
  -- partial output (bg_running branch) before being sent to output_cb.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local ansi_content = "\27[1;32mgreen bold\27[0m"
  local expected = "green bold"

  local captured = setup_common_mocks(ansi_content)

  sandbox_mod.run = function()
    return { close = function() end }, 12345, true
  end
  sandbox_mod.is_available = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data
  handler({ tool = { opts = { sandbox = { enabled = true } } } }, {
    cmd = "echo test",
    bg_after = 1,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  -- Simulate timer fire (process still running → bg_running branch)
  if captured.timer_cb then
    captured.timer_cb()
  end

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

T["tool: background bg_exited output strips ANSI color codes"] = function()
  -- Intent: Verify ANSI escape sequences are stripped from background
  -- full output (bg_exited branch) before being sent to output_cb.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local ansi_content = "\27[33myellow\27[0m\n\27[34mblue\27[0m"
  local expected = "yellow\nblue"

  local captured = setup_common_mocks(ansi_content)

  local captured_on_exit
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, true
  end
  sandbox_mod.is_available = function()
    return true
  end
  sandbox_mod.kill = function() end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data
  handler({ tool = { opts = { sandbox = { enabled = true } } } }, {
    cmd = "echo test",
    bg_after = 1,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  -- Simulate process exit before timer fires
  if captured_on_exit then
    captured_on_exit(0, 0)
  end
  -- Simulate timer fire (process already exited → bg_exited branch)
  if captured.timer_cb then
    captured.timer_cb()
  end

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

-- ── Background session cleanup after natural exit (#7) ─────

T["tool: background session cleaned up after natural exit"] = function()
  -- Intent: Verify that after a background process exits naturally,
  -- the bg_exited timer branch removes the session from the registry,
  -- does NOT delete the temp output file, and a subsequent kill returns
  -- "session not found."
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local captured = setup_common_mocks("done")

  -- Track os.remove calls to verify temp file cleanup
  local remove_call_count = 0
  os.remove = function(path)
    remove_call_count = remove_call_count + 1
    return true
  end

  local captured_on_exit
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, true
  end
  sandbox_mod.is_available = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  -- Start background command
  local output_data
  handler({ tool = { opts = { sandbox = { enabled = true } } } }, {
    cmd = "echo test",
    bg_after = 1,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  -- Fire on_exit first (clean exit) so status becomes EXITED before timer
  MiniTest.expect.equality(true, captured_on_exit ~= nil, "on_exit callback should be captured")
  if captured_on_exit then
    captured_on_exit(0, 0)
  end

  -- Fire timer: sees EXITED status → bg_exited branch → outputs session_id,
  -- then removes session from registry AND calls os.remove on temp file
  MiniTest.expect.equality(true, captured.timer_cb ~= nil, "timer callback should be captured")
  MiniTest.expect.equality(0, remove_call_count, "os.remove should NOT be called before timer")
  if captured.timer_cb then
    captured.timer_cb()
  end
  MiniTest.expect.equality(
    0,
    remove_call_count,
    "os.remove should still NOT be called after bg_exited cleanup"
  )

  MiniTest.expect.equality(true, output_data ~= nil, "should have bg_exited output")
  local session_id = output_data and output_data.data and output_data.data.session_id
  MiniTest.expect.equality(true, session_id ~= nil, "should have session_id")

  -- After cleanup, kill should report "session not found"
  local kill_output
  handler({ tool = { opts = { sandbox = { enabled = true } } } }, {
    action = "kill",
    session_id = session_id,
  }, {
    output_cb = function(data)
      kill_output = data
    end,
  })

  MiniTest.expect.equality(true, kill_output ~= nil, "should have kill response")
  if kill_output then
    local error_msg = kill_output.data and kill_output.data.error or ""
    Helpers.expect_contains("session not found", error_msg)
  end
end

-- ── Background output file preservation ─────────────────────

T["tool: background output file is preserved after natural exit"] = function()
  -- Intent: Verify that the background output file is never deleted when a
  -- background process exits, whether the exit happens before or after the
  -- bg_after timer fires.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local function run_scenario(name, seq_fn)
    local captured = setup_common_mocks("done")
    local removed_paths = {}
    os.remove = function(path)
      table.insert(removed_paths, path)
      return true
    end

    local captured_on_exit
    sandbox_mod.run = function(sandbox_opts, exec_params)
      captured_on_exit = exec_params.on_exit
      return { close = function() end }, 12345, true
    end
    sandbox_mod.is_available = function()
      return true
    end
    sandbox_mod.kill = function() end

    local def = tool_mod.create({ enabled = false })
    local handler = def.cmds[1]
    local tools = { tool = { opts = { sandbox = { enabled = true } } } }

    local output_data
    handler(tools, { cmd = "echo test", bg_after = 1 }, {
      output_cb = function(data)
        output_data = data
      end,
    })

    MiniTest.expect.equality(true, captured_on_exit ~= nil, name .. ": on_exit should be captured")
    MiniTest.expect.equality(true, captured.timer_cb ~= nil, name .. ": timer should be captured")

    seq_fn(captured_on_exit, captured.timer_cb)

    MiniTest.expect.equality(true, output_data ~= nil, name .. ": should have output")
    local file_path = output_data and output_data.data and output_data.data.file_path
    local session_id = output_data and output_data.data and output_data.data.session_id
    MiniTest.expect.equality(true, file_path ~= nil, name .. ": should have file_path")

    for _, removed_path in ipairs(removed_paths) do
      MiniTest.expect.equality(
        false,
        removed_path == file_path,
        name .. ": os.remove should not delete the background output file"
      )
    end

    -- After both callbacks, the session should be gone
    local kill_output
    handler(tools, { action = "kill", session_id = session_id }, {
      output_cb = function(data)
        kill_output = data
      end,
    })
    MiniTest.expect.equality(true, kill_output ~= nil, name .. ": should have kill response")
    if kill_output then
      local error_msg = kill_output.data and kill_output.data.error or ""
      Helpers.expect_contains("session not found", error_msg)
    end
  end

  run_scenario("exit before timer", function(on_exit, timer_cb)
    on_exit(0, 0)
    timer_cb()
  end)

  run_scenario("timer before exit", function(on_exit, timer_cb)
    timer_cb()
    on_exit(0, 0)
  end)

  run_scenario("non-zero early exit", function(on_exit, timer_cb)
    on_exit(1, 0)
    timer_cb()
  end)
end

T["tool: background output file is preserved on kill"] = function()
  -- Intent: Verify that action=kill terminates the background session but
  -- keeps the output file, returning the preserved path in the response.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local captured = setup_common_mocks("partial output")

  local removed_paths = {}
  os.remove = function(path)
    table.insert(removed_paths, path)
    return true
  end

  local captured_on_exit
  local captured_session_id
  local captured_file_path
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    captured_file_path = exec_params.file_path
    local name = exec_params.sandbox_name
    if name then
      captured_session_id = name:match("^cc%-bash%-(.+)$")
    end
    return { close = function() end }, 12345, true
  end
  sandbox_mod.is_available = function()
    return true
  end
  sandbox_mod.kill = function() end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]
  local tools = { tool = { opts = { sandbox = { enabled = true } } } }

  -- Scenario: kill a running session
  handler(tools, { cmd = "echo test", bg_after = 1 }, {
    output_cb = function() end,
  })
  MiniTest.expect.equality(
    true,
    captured_session_id ~= nil,
    "running session should have session_id"
  )
  MiniTest.expect.equality(true, captured_file_path ~= nil, "running session should have file_path")

  local kill_output
  handler(tools, { action = "kill", session_id = captured_session_id }, {
    output_cb = function(data)
      kill_output = data
    end,
  })
  MiniTest.expect.equality("success", kill_output.status)
  MiniTest.expect.equality("killed", kill_output.data.kill_info)
  MiniTest.expect.equality(
    captured_file_path,
    kill_output.data.file_path,
    "kill should return preserved file_path"
  )

  for _, removed_path in ipairs(removed_paths) do
    MiniTest.expect.equality(
      false,
      removed_path == captured_file_path,
      "os.remove should not delete the running session's output file"
    )
  end

  -- Scenario: kill an already-exited session
  captured_session_id = nil
  captured_file_path = nil
  handler(tools, { cmd = "echo test", bg_after = 1 }, {
    output_cb = function() end,
  })
  MiniTest.expect.equality(
    true,
    captured_session_id ~= nil,
    "exited session should have session_id"
  )
  MiniTest.expect.equality(true, captured_file_path ~= nil, "exited session should have file_path")

  -- Process exits before the timer fires, leaving the session in EXITED state
  captured_on_exit(0, 0)

  local kill_exited_output
  handler(tools, { action = "kill", session_id = captured_session_id }, {
    output_cb = function(data)
      kill_exited_output = data
    end,
  })
  MiniTest.expect.equality("success", kill_exited_output.status)
  MiniTest.expect.equality("already exited", kill_exited_output.data.kill_info)
  MiniTest.expect.equality(
    captured_file_path,
    kill_exited_output.data.file_path,
    "kill of exited session should return preserved file_path"
  )

  for _, removed_path in ipairs(removed_paths) do
    MiniTest.expect.equality(
      false,
      removed_path == captured_file_path,
      "os.remove should not delete the exited session's output file"
    )
  end
end

T["tool: background output file is preserved on spawn failure"] = function()
  -- Intent: Verify that a failed sandbox.run spawn in background mode does
  -- not delete the already-created output file.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")

  local captured_path
  uv.fs_open = function(path, mode, permissions)
    captured_path = path
    return 999
  end
  uv.fs_close = function() end
  uv.new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end

  local removed_paths = {}
  os.remove = function(path)
    table.insert(removed_paths, path)
    return true
  end

  sandbox_mod.run = function()
    return nil, "mock error", false
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo test",
    bg_after = 1,
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality("error", output_data.status)
  MiniTest.expect.equality(
    true,
    captured_path ~= nil,
    "fs_open should capture the output file path"
  )

  for _, removed_path in ipairs(removed_paths) do
    MiniTest.expect.equality(
      false,
      removed_path == captured_path,
      "os.remove should not delete the output file on spawn failure"
    )
  end
end

-- ── Migrated handler arg validation tests ──────────────────────

T["tool: bg_after > 60 returns error"] = function()
  -- Intent: Handler rejects bg_after > 60
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
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

T["tool: timeout > 3600 returns error"] = function()
  -- Intent: Handler rejects timeout > 3600
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
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

T["tool: empty cmd returns error"] = function()
  -- Intent: Handler rejects empty cmd
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
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

T["tool: run without cmd returns error"] = function()
  -- Intent: Handler rejects missing cmd for action=run
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

T["tool: no action defaults to run, requires cmd"] = function()
  -- Intent: Missing action defaults to run, still needs cmd
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

T["tool: kill without session_id returns error"] = function()
  -- Intent: Handler rejects missing session_id for action=kill
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

T["tool: kill nonexistent session returns error"] = function()
  -- Intent: Handler returns error for unknown session_id
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data = nil
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

-- ── Tool definition tests ──────────────────────────────────────

T["tool: create returns valid tool definition"] = function()
  -- Intent: tool.create() produces correct structure with expected fields.
  -- skip_sandbox presence depends on sandlock availability (tested separately).
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local def = tool_mod.create({ enabled = false })

  MiniTest.expect.equality("run_bash", def.name)
  MiniTest.expect.equality(true, def.schema ~= nil)
  MiniTest.expect.equality(true, #def.cmds == 1)
  MiniTest.expect.equality(true, def.output ~= nil)

  -- Schema has expected fields; skip_sandbox presence depends on sandlock (tested in next test)
  local props = def.schema["function"].parameters.properties
  MiniTest.expect.equality(true, props.cmd ~= nil)
  MiniTest.expect.equality(true, props.action ~= nil)
  MiniTest.expect.equality(true, props.timeout ~= nil)
end

T["tool: schema includes skip_sandbox"] = function()
  -- Intent: Schema includes skip_sandbox field only when sandbox available
  Helpers.require_sandbox()

  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local path = Helpers.sandbox_profile_path()

  local def = tool_mod.create({
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

return T
