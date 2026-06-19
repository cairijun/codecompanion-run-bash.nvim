--[[
Test: tool.lua — Tool Definition and Handler

Intent: Verify tool handler behavior via spy-based unit tests, focusing on
resource cleanup, temp file security, and concurrency safety.

]]

local uv = vim.uv
local T = MiniTest.new_set()

-- ── Foreground spawn failure: timer leak ────────────────────

T["tool: foreground spawn failure closes all timers"] = function()
  -- Intent: Verify that when sandbox.run() returns nil (spawn failure)
  -- in foreground mode, both timer and kill_timer handles are closed.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  -- Track created timers
  local created_timers = {}
  local orig_new_timer = uv.new_timer
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
  local orig_run = sandbox_mod.run
  sandbox_mod.run = function()
    return nil, "mock spawn error", false
  end

  -- Mock uv.fs_open and uv.fs_close
  local orig_fs_open = uv.fs_open
  local orig_fs_close = uv.fs_close
  uv.fs_open = function()
    return 999
  end
  uv.fs_close = function() end

  local orig_os_remove = os.remove
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

  -- Restore mocks
  uv.new_timer = orig_new_timer
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  sandbox_mod.run = orig_run
  os.remove = orig_os_remove

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
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local captured_path = nil
  local captured_mode = nil

  local orig_fs_open = uv.fs_open
  uv.fs_open = function(path, mode, permissions)
    captured_path = path
    captured_mode = permissions
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_new_timer = uv.new_timer
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

  local orig_run = sandbox_mod.run
  sandbox_mod.run = function()
    return nil, "mock error", false
  end

  local orig_os_remove = os.remove
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

  -- Restore mocks
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.new_timer = orig_new_timer
  sandbox_mod.run = orig_run
  os.remove = orig_os_remove

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
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local orig_run = sandbox_mod.run
  sandbox_mod.run = function()
    return { close = function() end }, 12345, true
  end

  local orig_fs_open = uv.fs_open
  uv.fs_open = function()
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_new_timer = uv.new_timer
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

  local orig_os_remove = os.remove
  os.remove = function()
    return true
  end

  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local tools_obj = { tool = { opts = { sandbox = { enabled = false } } } }
  handler(tools_obj, { cmd = "echo test" }, {
    output_cb = function() end,
  })

  -- Restore mocks
  sandbox_mod.run = orig_run
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.new_timer = orig_new_timer
  os.remove = orig_os_remove

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
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local session_ids = {}
  local orig_run = sandbox_mod.run
  sandbox_mod.run = function(sandbox_opts, exec_params)
    local name = exec_params.sandbox_name
    if name and name:match("^cc%-bash%-(.+)$") then
      table.insert(session_ids, name:match("^cc%-bash%-(.+)$"))
    end
    return nil, "mock error", true
  end

  local orig_is_available = sandbox_mod.is_available
  sandbox_mod.is_available = function()
    return true
  end

  local orig_fs_open = uv.fs_open
  uv.fs_open = function()
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_new_timer = uv.new_timer
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

  local orig_os_remove = os.remove
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

  -- Restore mocks
  sandbox_mod.run = orig_run
  sandbox_mod.is_available = orig_is_available
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.new_timer = orig_new_timer
  os.remove = orig_os_remove

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
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local io_open_called = false
  local orig_io_open = io.open
  io.open = function()
    io_open_called = true
    return nil
  end

  local captured_on_exit = nil
  local orig_run = sandbox_mod.run
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, false
  end

  local orig_kill = sandbox_mod.kill
  sandbox_mod.kill = function() end

  local orig_fs_open = uv.fs_open
  uv.fs_open = function()
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_fs_fstat = uv.fs_fstat
  uv.fs_fstat = function()
    return { size = 5 }
  end

  local orig_fs_read = uv.fs_read
  uv.fs_read = function()
    return "hello"
  end

  local orig_new_timer = uv.new_timer
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

  local orig_os_remove = os.remove
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

  -- Restore mocks
  io.open = orig_io_open
  sandbox_mod.run = orig_run
  sandbox_mod.kill = orig_kill
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.fs_fstat = orig_fs_fstat
  uv.fs_read = orig_fs_read
  uv.new_timer = orig_new_timer
  os.remove = orig_os_remove

  MiniTest.expect.equality(true, not io_open_called, "io.open should NOT be called in on_exit")
end

-- ── Conditional sandbox.kill on clean exit ─────────────────

T["tool: sandbox.kill not called on clean exit"] = function()
  -- Intent: Verify that sandbox.kill() is NOT called when a foreground
  -- process exits cleanly (code 0, signal 0).
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local kill_called = false
  local orig_kill = sandbox_mod.kill
  sandbox_mod.kill = function()
    kill_called = true
  end

  local captured_on_exit = nil
  local orig_run = sandbox_mod.run
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, false
  end

  local orig_fs_open = uv.fs_open
  uv.fs_open = function()
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_fs_fstat = uv.fs_fstat
  uv.fs_fstat = function()
    return { size = 0 }
  end

  local orig_fs_read = uv.fs_read
  uv.fs_read = function()
    return ""
  end

  local orig_new_timer = uv.new_timer
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

  local orig_os_remove = os.remove
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

  -- Restore mocks
  sandbox_mod.kill = orig_kill
  sandbox_mod.run = orig_run
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.fs_fstat = orig_fs_fstat
  uv.fs_read = orig_fs_read
  uv.new_timer = orig_new_timer
  os.remove = orig_os_remove

  MiniTest.expect.equality(true, not kill_called, "sandbox.kill should NOT be called on clean exit")
end

-- ── ANSI color code stripping ─────────────────────────────

T["tool: foreground output strips ANSI color codes"] = function()
  -- Intent: Verify ANSI escape sequences are stripped from foreground
  -- command output before being sent to output_cb.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local ansi_content = "\27[31mred text\27[0m"
  local expected = "red text"

  local captured_on_exit
  local orig_run = sandbox_mod.run
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, false
  end

  local orig_kill = sandbox_mod.kill
  sandbox_mod.kill = function() end

  local orig_fs_open = uv.fs_open
  uv.fs_open = function()
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_fs_fstat = uv.fs_fstat
  uv.fs_fstat = function()
    return { size = #ansi_content }
  end

  local orig_fs_read = uv.fs_read
  uv.fs_read = function()
    return ansi_content
  end

  local orig_new_timer = uv.new_timer
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

  local orig_os_remove = os.remove
  os.remove = function()
    return true
  end

  local orig_vim_schedule = vim.schedule
  vim.schedule = function(fn)
    fn()
  end

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

  -- Restore mocks
  sandbox_mod.run = orig_run
  sandbox_mod.kill = orig_kill
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.fs_fstat = orig_fs_fstat
  uv.fs_read = orig_fs_read
  uv.new_timer = orig_new_timer
  os.remove = orig_os_remove
  vim.schedule = orig_vim_schedule

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

T["tool: background bg_running output strips ANSI color codes"] = function()
  -- Intent: Verify ANSI escape sequences are stripped from background
  -- partial output (bg_running branch) before being sent to output_cb.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local ansi_content = "\27[1;32mgreen bold\27[0m"
  local expected = "green bold"

  local orig_run = sandbox_mod.run
  sandbox_mod.run = function()
    return { close = function() end }, 12345, true
  end

  local orig_is_available = sandbox_mod.is_available
  sandbox_mod.is_available = function()
    return true
  end

  local orig_fs_open = uv.fs_open
  uv.fs_open = function()
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_fs_fstat = uv.fs_fstat
  uv.fs_fstat = function()
    return { size = #ansi_content }
  end

  local orig_fs_read = uv.fs_read
  uv.fs_read = function()
    return ansi_content
  end

  local captured_timer_cb
  local orig_new_timer = uv.new_timer
  uv.new_timer = function()
    return {
      start = function(self, ms, repeat_ms, cb)
        captured_timer_cb = cb
      end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end

  local orig_os_remove = os.remove
  os.remove = function()
    return true
  end

  local orig_vim_schedule = vim.schedule
  vim.schedule = function(fn)
    fn()
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
  if captured_timer_cb then
    captured_timer_cb()
  end

  -- Restore mocks
  sandbox_mod.run = orig_run
  sandbox_mod.is_available = orig_is_available
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.fs_fstat = orig_fs_fstat
  uv.fs_read = orig_fs_read
  uv.new_timer = orig_new_timer
  os.remove = orig_os_remove
  vim.schedule = orig_vim_schedule

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

T["tool: background bg_exited output strips ANSI color codes"] = function()
  -- Intent: Verify ANSI escape sequences are stripped from background
  -- full output (bg_exited branch) before being sent to output_cb.
  local tool_mod = require("codecompanion._extensions.run_bash.tool")
  local sandbox_mod = require("codecompanion._extensions.run_bash.sandbox")

  local ansi_content = "\27[33myellow\27[0m\n\27[34mblue\27[0m"
  local expected = "yellow\nblue"

  local captured_on_exit
  local orig_run = sandbox_mod.run
  sandbox_mod.run = function(sandbox_opts, exec_params)
    captured_on_exit = exec_params.on_exit
    return { close = function() end }, 12345, true
  end

  local orig_is_available = sandbox_mod.is_available
  sandbox_mod.is_available = function()
    return true
  end

  local orig_kill = sandbox_mod.kill
  sandbox_mod.kill = function() end

  local orig_fs_open = uv.fs_open
  uv.fs_open = function()
    return 999
  end

  local orig_fs_close = uv.fs_close
  uv.fs_close = function() end

  local orig_fs_fstat = uv.fs_fstat
  uv.fs_fstat = function()
    return { size = #ansi_content }
  end

  local orig_fs_read = uv.fs_read
  uv.fs_read = function()
    return ansi_content
  end

  local captured_timer_cb
  local orig_new_timer = uv.new_timer
  uv.new_timer = function()
    return {
      start = function(self, ms, repeat_ms, cb)
        captured_timer_cb = cb
      end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return true
      end,
    }
  end

  local orig_os_remove = os.remove
  os.remove = function()
    return true
  end

  local orig_vim_schedule = vim.schedule
  vim.schedule = function(fn)
    fn()
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

  -- Simulate process exit before timer fires
  if captured_on_exit then
    captured_on_exit(0, 0)
  end
  -- Simulate timer fire (process already exited → bg_exited branch)
  if captured_timer_cb then
    captured_timer_cb()
  end

  -- Restore mocks
  sandbox_mod.run = orig_run
  sandbox_mod.is_available = orig_is_available
  sandbox_mod.kill = orig_kill
  uv.fs_open = orig_fs_open
  uv.fs_close = orig_fs_close
  uv.fs_fstat = orig_fs_fstat
  uv.fs_read = orig_fs_read
  uv.new_timer = orig_new_timer
  os.remove = orig_os_remove
  vim.schedule = orig_vim_schedule

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

return T
