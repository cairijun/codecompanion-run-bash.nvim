--[[
Test: tool.lua — Tool Definition and Handler

Intent: Verify tool handler behavior via dependency-injected unit tests,
focusing on resource cleanup, temp file security, and concurrency safety.
All behavior tests construct isolated registries and injected stubs; no
global mocks are mutated.
]]

local Helpers = require("tests.helpers")
local tool_mod = require("codecompanion._extensions.run_bash.tool")

local T = MiniTest.new_set()

-- ── Pure strip_ansi tests ─────────────────────────────────────────────

T["strip_ansi: empty string"] = function()
  MiniTest.expect.equality("", tool_mod._internal.strip_ansi(""))
end

T["strip_ansi: string without codes unchanged"] = function()
  MiniTest.expect.equality("hello world", tool_mod._internal.strip_ansi("hello world"))
end

T["strip_ansi: simple CSI code"] = function()
  MiniTest.expect.equality("red text", tool_mod._internal.strip_ansi("\27[31mred text\27[0m"))
end

T["strip_ansi: combined CSI codes"] = function()
  MiniTest.expect.equality(
    "bold red and blue",
    tool_mod._internal.strip_ansi("\27[1;31mbold red\27[0m and \27[34mblue\27[0m")
  )
end

-- ── Pure SessionRegistry tests ────────────────────────────────────────

T["SessionRegistry: gen_session_id produces unique ids"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local seen = {}
  for _ = 1, 500 do
    local id = registry:gen_session_id()
    MiniTest.expect.equality(nil, seen[id], "session ID collision: " .. tostring(id))
    seen[id] = true
  end
end

-- ── Foreground spawn failure: timer leak ──────────────────────────────

T["tool: foreground spawn failure closes all timers"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local created_timers = {}
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      local t = {
        _closed = false,
        start = function() end,
        stop = function() end,
        close = function(self)
          self._closed = true
        end,
        is_closing = function(self)
          return self._closed
        end,
      }
      table.insert(created_timers, t)
      return t
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function()
      return nil, "mock spawn error", false, nil
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]

  local output_data = nil
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, {
    cmd = "echo test",
  }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  MiniTest.expect.equality(true, output_data ~= nil, "should report error")
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
  end

  MiniTest.expect.equality(true, #created_timers > 0, "should have created timers")
  for i, t in ipairs(created_timers) do
    MiniTest.expect.equality(true, t._closed, "timer " .. i .. " should be closed")
  end
end

-- ── Temp file security ────────────────────────────────────────────────

T["tool: temp file uses secure path and mode"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local captured_path = nil
  local captured_mode = nil
  local uv_stub = {
    fs_open = function(path, mode, permissions)
      captured_path = path
      captured_mode = permissions
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function()
      return nil, "mock error", false, nil
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
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

-- ── _sandbox_active concurrency race ──────────────────────────────────

T["tool: handler does not set shared _sandbox_active"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function()
      return { close = function() end }, 12345, true, "cc-bash-stub"
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]

  local tools_obj = { tool = { opts = { sandbox = { enabled = false } } } }
  handler(tools_obj, { cmd = "echo test" }, {
    output_cb = function() end,
  })

  MiniTest.expect.equality(
    nil,
    tools_obj.tool._sandbox_active,
    "should not set shared _sandbox_active"
  )
end

-- ── No blocking io.open in async callbacks ────────────────────────────

T["tool: on_exit does not use blocking io.open"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local captured_on_exit = nil
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 5 }
    end,
    fs_read = function()
      return "hello"
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function(_, exec_params)
      captured_on_exit = exec_params.on_exit
      return { close = function() end }, 12345, false, nil
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]

  local io_open_called = false
  Helpers.with_mocks({
    ["io.open"] = function()
      io_open_called = true
      return nil
    end,
  }, function()
    handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "echo test" }, {
      output_cb = function() end,
    })
    if captured_on_exit then
      captured_on_exit(0, 0)
    end
  end)

  MiniTest.expect.equality(false, io_open_called, "io.open should NOT be called in on_exit")
end

-- ── Conditional sandbox.kill on clean exit ────────────────────────────

T["tool: sandbox.kill not called on clean exit"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local kill_called = false
  local captured_on_exit = nil
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function(_, exec_params)
      captured_on_exit = exec_params.on_exit
      return { close = function() end }, 12345, false, nil
    end,
    kill = function()
      kill_called = true
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "echo test" }, {
    output_cb = function() end,
  })

  if captured_on_exit then
    captured_on_exit(0, 0)
  end

  MiniTest.expect.equality(false, kill_called, "sandbox.kill should NOT be called on clean exit")
end

-- ── ANSI color code stripping ─────────────────────────────────────────

T["tool: foreground output strips ANSI color codes"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local ansi_content = "\27[31mred text\27[0m"
  local expected = "red text"
  local captured_on_exit
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = #ansi_content }
    end,
    fs_read = function()
      return ansi_content
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function(_, exec_params)
      captured_on_exit = exec_params.on_exit
      return { close = function() end }, 12345, false, nil
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
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
  local registry = tool_mod._internal.SessionRegistry.new()
  local ansi_content = "\27[1;32mgreen bold\27[0m"
  local expected = "green bold"
  local captured = {}
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = #ansi_content }
    end,
    fs_read = function()
      return ansi_content
    end,
    new_timer = function()
      return {
        start = function(_, _, _, cb)
          captured.timer_cb = cb
        end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    get_description = function()
      return "Sandboxed (test stub)."
    end,
    should_use = function()
      return true
    end,
    run = function()
      return { close = function() end }, 12345, true, "cc-bash-stub"
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
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

  if captured.timer_cb then
    captured.timer_cb()
  end

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

T["tool: background bg_exited output strips ANSI color codes"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local ansi_content = "\27[33myellow\27[0m\n\27[34mblue\27[0m"
  local expected = "yellow\nblue"
  local captured = {}
  local captured_on_exit
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = #ansi_content }
    end,
    fs_read = function()
      return ansi_content
    end,
    new_timer = function()
      return {
        start = function(_, _, _, cb)
          captured.timer_cb = cb
        end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    get_description = function()
      return "Sandboxed (test stub)."
    end,
    should_use = function()
      return true
    end,
    run = function(_, exec_params)
      captured_on_exit = exec_params.on_exit
      return { close = function() end }, 12345, true, "cc-bash-stub"
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
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

  if captured_on_exit then
    captured_on_exit(0, 0)
  end
  if captured.timer_cb then
    captured.timer_cb()
  end

  MiniTest.expect.equality(true, output_data ~= nil, "should have output")
  if output_data then
    MiniTest.expect.equality(expected, output_data.data.output, "ANSI codes should be stripped")
  end
end

-- ── Background session cleanup after natural exit ─────────────────────

T["tool: background session cleaned up after natural exit"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local content = "done"
  local captured = {}
  local remove_call_count = 0
  local captured_on_exit
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = #content }
    end,
    fs_read = function()
      return content
    end,
    new_timer = function()
      return {
        start = function(_, _, _, cb)
          captured.timer_cb = cb
        end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    get_description = function()
      return "Sandboxed (test stub)."
    end,
    should_use = function()
      return true
    end,
    run = function(_, exec_params)
      captured_on_exit = exec_params.on_exit
      return { close = function() end }, 12345, true, "cc-bash-stub"
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      remove_call_count = remove_call_count + 1
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
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

  MiniTest.expect.equality(true, captured_on_exit ~= nil, "on_exit callback should be captured")
  if captured_on_exit then
    captured_on_exit(0, 0)
  end

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

-- ── Background output file preservation ───────────────────────────────

T["tool: background output file is preserved after natural exit"] = function()
  local function run_scenario(name, seq_fn)
    local registry = tool_mod._internal.SessionRegistry.new()
    local content = "done"
    local captured = {}
    local removed_paths = {}
    local captured_on_exit
    local uv_stub = {
      fs_open = function()
        return 999
      end,
      fs_close = function() end,
      fs_fstat = function()
        return { size = #content }
      end,
      fs_read = function()
        return content
      end,
      new_timer = function()
        return {
          start = function(_, _, _, cb)
            captured.timer_cb = cb
          end,
          stop = function() end,
          close = function() end,
          is_closing = function()
            return true
          end,
        }
      end,
      kill = function() end,
      spawn = function() end,
    }
    local sandbox_stub = {
      is_available = function()
        return true
      end,
      get_description = function()
        return "Sandboxed (test stub)."
      end,
      should_use = function()
        return true
      end,
      run = function(_, exec_params)
        captured_on_exit = exec_params.on_exit
        return { close = function() end }, 12345, true, "cc-bash-stub"
      end,
      kill = function(_, _, _, on_killed)
        if on_killed then
          on_killed()
        end
      end,
    }
    local def = tool_mod.create({ enabled = false }, {
      registry = registry,
      sandbox = sandbox_stub,
      uv = uv_stub,
      os_remove = function(path)
        table.insert(removed_paths, path)
        return true
      end,
      vim_schedule = function(fn)
        fn()
      end,
    })
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
  local registry = tool_mod._internal.SessionRegistry.new()
  local content = "partial output"
  local captured = {}
  local removed_paths = {}
  local captured_on_exit
  local captured_session_id
  local captured_file_path
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = #content }
    end,
    fs_read = function()
      return content
    end,
    new_timer = function()
      return {
        start = function(_, _, _, cb)
          captured.timer_cb = cb
        end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    get_description = function()
      return "Sandboxed (test stub)."
    end,
    should_use = function()
      return true
    end,
    run = function(_, exec_params)
      captured_on_exit = exec_params.on_exit
      captured_file_path = exec_params.file_path
      return { close = function() end }, 12345, true, "cc-bash-stub", "cc-bash-stub"
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function(path)
      table.insert(removed_paths, path)
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]
  local tools = { tool = { opts = { sandbox = { enabled = true } } } }

  handler(tools, { cmd = "echo test", bg_after = 1 }, {
    output_cb = function() end,
  })
  local session_id = next(registry.bg_sessions)
  MiniTest.expect.equality(true, session_id ~= nil, "running session should be in registry")
  MiniTest.expect.equality(true, captured_file_path ~= nil, "running session should have file_path")

  local kill_output
  handler(tools, { action = "kill", session_id = session_id }, {
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
  captured_on_exit = nil
  captured_file_path = nil
  handler(tools, { cmd = "echo test", bg_after = 1 }, {
    output_cb = function() end,
  })
  local exited_session_id = next(registry.bg_sessions)
  MiniTest.expect.equality(true, exited_session_id ~= nil, "exited session should be in registry")
  MiniTest.expect.equality(true, captured_file_path ~= nil, "exited session should have file_path")

  if captured_on_exit then
    captured_on_exit(0, 0)
  end

  local kill_exited_output
  handler(tools, { action = "kill", session_id = exited_session_id }, {
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
  local registry = tool_mod._internal.SessionRegistry.new()
  local captured_path
  local removed_paths = {}
  local uv_stub = {
    fs_open = function(path)
      captured_path = path
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function()
      return nil, "mock error", false, nil
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function(path)
      table.insert(removed_paths, path)
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
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

T["tool: handle_kill reports only after kill callback"] = function()
  local registry = tool_mod._internal.SessionRegistry.new()
  local content = "output"
  local timers = {}
  local captured_kill_cb
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = #content }
    end,
    fs_read = function()
      return content
    end,
    new_timer = function()
      return {
        start = function(_, _, _, cb)
          table.insert(timers, cb)
        end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function()
      return { close = function() end }, 12345, false, nil
    end,
    kill = function(_, _, _, on_killed)
      captured_kill_cb = on_killed
    end,
  }
  local def = tool_mod.create({ enabled = false }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]
  local tools = { tool = { opts = { sandbox = { enabled = false } } } }

  local bg_output
  handler(tools, { cmd = "echo test", bg_after = 1 }, {
    output_cb = function(data)
      bg_output = data
    end,
  })

  MiniTest.expect.equality(1, #timers, "should have created 1 timer")
  timers[1]()

  MiniTest.expect.equality(true, bg_output ~= nil, "should have bg output after timer")
  local session_id = bg_output.data.session_id
  MiniTest.expect.equality(true, session_id ~= nil, "should have session_id")

  local kill_output
  local kill_output_called = false
  handler(tools, { action = "kill", session_id = session_id }, {
    output_cb = function(data)
      kill_output = data
      kill_output_called = true
    end,
  })

  MiniTest.expect.equality("function", type(captured_kill_cb), "should pass a callback")
  MiniTest.expect.equality(false, kill_output_called, "should NOT report before callback")

  captured_kill_cb()

  MiniTest.expect.equality(true, kill_output_called, "should report after callback")
  MiniTest.expect.equality("success", kill_output.status)
  MiniTest.expect.equality("killed", kill_output.data.kill_info)
end

-- ── Validation errors ─────────────────────────────────────────────────

T["tool: bg_after > 60 returns error"] = function()
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
    vim_schedule = function(fn)
      fn()
    end,
  })
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
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
    vim_schedule = function(fn)
      fn()
    end,
  })
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
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
    vim_schedule = function(fn)
      fn()
    end,
  })
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
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
    vim_schedule = function(fn)
      fn()
    end,
  })
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
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
    vim_schedule = function(fn)
      fn()
    end,
  })
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
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
    vim_schedule = function(fn)
      fn()
    end,
  })
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
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
    vim_schedule = function(fn)
      fn()
    end,
  })
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

-- ── Tool definition tests ─────────────────────────────────────────────

T["tool: create returns valid tool definition"] = function()
  local def = tool_mod.create({ enabled = false }, {
    registry = tool_mod._internal.SessionRegistry.new(),
  })

  MiniTest.expect.equality("run_bash", def.name)
  MiniTest.expect.equality(true, def.schema ~= nil)
  MiniTest.expect.equality(true, #def.cmds == 1)
  MiniTest.expect.equality(true, def.output ~= nil)

  local props = def.schema["function"].parameters.properties
  MiniTest.expect.equality(true, props.cmd ~= nil)
  MiniTest.expect.equality(true, props.action ~= nil)
  MiniTest.expect.equality(true, props.timeout ~= nil)
end

T["tool: schema includes skip_sandbox when sandbox available"] = function()
  Helpers.require_sandbox()

  local def = tool_mod.create({
    backend = "sandlock",
    backends = { sandlock = { profile = Helpers.sandbox_profile_path() } },
    rules = {},
  }, {
    registry = tool_mod._internal.SessionRegistry.new(),
  })

  local props = def.schema["function"].parameters.properties
  MiniTest.expect.equality(
    true,
    props.skip_sandbox ~= nil,
    "should have skip_sandbox when sandbox available"
  )
end

-- ── Real subprocess tests ─────────────────────────────────────────────

T["tool: real subprocess echo hello"] = function()
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "echo hello" }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(3000, function()
    return output_data ~= nil
  end, 50)
  MiniTest.expect.equality(true, ok, "output should arrive within 3s")
  if output_data then
    MiniTest.expect.equality("success", output_data.status)
    Helpers.expect_contains("hello", output_data.data.output)
  end
end

T["tool: real subprocess false reports failure"] = function()
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "false" }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(3000, function()
    return output_data ~= nil
  end, 50)
  MiniTest.expect.equality(true, ok, "output should arrive within 3s")
  if output_data then
    MiniTest.expect.equality("error", output_data.status)
    MiniTest.expect.equality(1, output_data.data.exit_code)
  end
end

T["tool: real subprocess sleep completes"] = function()
  local def = tool_mod.create({ enabled = false })
  local handler = def.cmds[1]

  local output_data
  handler({ tool = { opts = { sandbox = { enabled = false } } } }, { cmd = "sleep 0.1" }, {
    output_cb = function(data)
      output_data = data
    end,
  })

  local ok = vim.wait(3000, function()
    return output_data ~= nil
  end, 50)
  MiniTest.expect.equality(true, ok, "output should arrive within 3s")
  if output_data then
    MiniTest.expect.equality("success", output_data.status)
  end
end

-- ── Registry persistence of sandbox_opts / sandbox_name ──────────────

T["tool: registry stores sandbox_opts for foreground sessions"] = function()
  -- Intent: Verify tool.lua stores the sandbox_opts reference in the
  -- foreground process registry entry, enabling kill to pass correct opts.
  local registry = tool_mod._internal.SessionRegistry.new()
  local sandbox_opts = { backend = false }
  local sandbox_stub = {
    is_available = function()
      return false
    end,
    should_use = function()
      return false
    end,
    run = function()
      return { close = function() end }, 7788, false, nil
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
    get_description = function()
      return "stub description."
    end,
  }
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local def = tool_mod.create(sandbox_opts, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]
  handler(
    { tool = { opts = { sandbox = sandbox_opts } } },
    { cmd = "echo test" },
    { output_cb = function() end }
  )

  MiniTest.expect.equality(true, registry.fg_procs[7788] ~= nil, "fg proc should be registered")
  if registry.fg_procs[7788] then
    MiniTest.expect.equality(
      sandbox_opts,
      registry.fg_procs[7788].sandbox_opts,
      "sandbox_opts identity should be preserved"
    )
  end
end

T["tool: registry stores sandbox_name for sandboxed foreground sessions"] = function()
  -- Intent: Verify tool.lua captures the 4th return value from sandbox.run
  -- and stores it as sandbox_name in the registry entry.
  local registry = tool_mod._internal.SessionRegistry.new()
  local sandbox_opts = { backend = "sandlock", backends = { sandlock = {} }, rules = {} }
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    should_use = function()
      return true
    end,
    run = function()
      return { close = function() end }, 1122, true, "cc-bash-test-xyz"
    end,
    kill = function(_, _, _, on_killed)
      if on_killed then
        on_killed()
      end
    end,
    get_description = function()
      return "stub description."
    end,
  }
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local def = tool_mod.create(sandbox_opts, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]
  handler(
    { tool = { opts = { sandbox = sandbox_opts } } },
    { cmd = "echo test" },
    { output_cb = function() end }
  )

  MiniTest.expect.equality(true, registry.fg_procs[1122] ~= nil, "fg proc should be registered")
  if registry.fg_procs[1122] then
    MiniTest.expect.equality(
      "cc-bash-test-xyz",
      registry.fg_procs[1122].sandbox_name,
      "sandbox_name from run return should be stored"
    )
  end
end

T["tool: on_exit handler reads pid and sandbox_name from explicit holders"] = function()
  -- Intent: Verify that spawn_background/spawn_foreground populate holder
  -- tables for pid and sandbox_name, and that on_exit reads from those holders.
  -- This makes the async dependency explicit: uv.spawn returns before on_exit
  -- can fire, so the holders are always populated before the callback runs.
  local registry = tool_mod._internal.SessionRegistry.new()
  local captured_on_exit
  local returned_pid = 12345
  local returned_sandbox_name = "cc-test-holder"
  local kill_calls = {}
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    get_description = function()
      return "stub description."
    end,
    should_use = function()
      return true
    end,
    run = function(_, exec_params)
      captured_on_exit = exec_params.on_exit
      return { close = function() end }, returned_pid, true, returned_sandbox_name
    end,
    kill = function(opts, sandbox_name, pid)
      table.insert(kill_calls, { opts = opts, sandbox_name = sandbox_name, pid = pid })
    end,
  }
  local def = tool_mod.create({ backend = "sandlock", backends = { sandlock = {} }, rules = {} }, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]

  handler({ tool = { opts = { sandbox = { enabled = true } } } }, { cmd = "echo test" }, {
    output_cb = function() end,
  })

  MiniTest.expect.equality(true, captured_on_exit ~= nil, "on_exit should be captured")

  -- Trigger conditional kill by exiting with signal (code=0, signal=15).
  if captured_on_exit then
    captured_on_exit(0, 15)
  end

  MiniTest.expect.equality(1, #kill_calls, "conditional kill should be called")
  MiniTest.expect.equality(returned_pid, kill_calls[1].pid, "kill should use holder pid")
  MiniTest.expect.equality(
    returned_sandbox_name,
    kill_calls[1].sandbox_name,
    "kill should use holder sandbox_name"
  )
end

T["tool: conditional kill on abnormal exit passes sandbox_opts and sandbox_name"] = function()
  -- Intent: Verify make_on_exit_handler calls sandbox.kill with the
  -- sandbox_opts and sandbox_name captured from spawn_foreground's run
  -- return value (not via registry lookup).
  local registry = tool_mod._internal.SessionRegistry.new()
  local sandbox_opts = { backend = "sandlock", backends = { sandlock = {} }, rules = {} }
  local captured = {}
  local captured_on_exit
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    should_use = function()
      return true
    end,
    run = function(_, ep)
      captured_on_exit = ep.on_exit
      return { close = function() end }, 5566, true, "cc-bash-abnormal-id"
    end,
    kill = function(opts, sandbox_name, pid)
      table.insert(captured, { opts = opts, sandbox_name = sandbox_name, pid = pid })
    end,
    get_description = function()
      return "stub description."
    end,
  }
  local uv_stub = {
    fs_open = function()
      return 999
    end,
    fs_close = function() end,
    fs_fstat = function()
      return { size = 0 }
    end,
    fs_read = function()
      return ""
    end,
    new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
        is_closing = function()
          return true
        end,
      }
    end,
    kill = function() end,
    spawn = function() end,
  }
  local def = tool_mod.create(sandbox_opts, {
    registry = registry,
    sandbox = sandbox_stub,
    uv = uv_stub,
    os_remove = function()
      return true
    end,
    vim_schedule = function(fn)
      fn()
    end,
  })
  local handler = def.cmds[1]
  handler(
    { tool = { opts = { sandbox = sandbox_opts } } },
    { cmd = "echo" },
    { output_cb = function() end }
  )

  if captured_on_exit then
    -- code > 128 triggers conditional kill branch
    captured_on_exit(130, 0)
  end

  MiniTest.expect.equality(true, #captured >= 1, "conditional kill should be called for code > 128")
  if #captured >= 1 then
    Helpers.expect_contains("abnormal-id", captured[1].sandbox_name or "")
    MiniTest.expect.equality(
      sandbox_opts,
      captured[1].opts,
      "kill should receive sandbox_opts identity"
    )
    MiniTest.expect.equality(5566, captured[1].pid, "kill should receive the process pid")
  end
end

T["tool: cleanup_all uses each session's own sandbox_opts"] = function()
  -- Intent: Verify SessionRegistry:cleanup_all kills each RUNNING session
  -- with its own sandbox_opts/sandbox_name, ensuring both backend variants
  -- can be cleaned up correctly in a heterogeneous registry.
  local calls = {}
  local sandbox_stub = {
    kill = function(opts, sandbox_name, pid)
      table.insert(calls, { opts = opts, sandbox_name = sandbox_name, pid = pid })
    end,
  }
  local registry = tool_mod._internal.SessionRegistry.new({
    sandbox = sandbox_stub,
    uv = vim.uv,
    os_remove = function()
      return true
    end,
  })
  local opts1 = { backend = "sandlock", backends = { sandlock = {} }, rules = {} }
  local opts2 = { backend = "bubblewrap", backends = { bubblewrap = {} }, rules = {} }
  -- Add two RUNNING bg sessions with different opts
  registry:add_bg("session1", {
    status = "running",
    pid = 1001,
    sandbox_opts = opts1,
    sandbox_name = "sb1",
    fd = nil,
    timer = nil,
    file_path = nil,
    exit_code = nil,
    timer_fired = false,
  })
  registry:add_bg("session2", {
    status = "running",
    pid = 2002,
    sandbox_opts = opts2,
    sandbox_name = "sb2",
    fd = nil,
    timer = nil,
    file_path = nil,
    exit_code = nil,
    timer_fired = false,
  })

  registry:cleanup_all()

  MiniTest.expect.equality(2, #calls, "cleanup_all should kill both running sessions")
  local found_opts1, found_opts2 = false, false
  for _, c in ipairs(calls) do
    if c.opts == opts1 and c.sandbox_name == "sb1" then
      found_opts1 = true
    end
    if c.opts == opts2 and c.sandbox_name == "sb2" then
      found_opts2 = true
    end
  end
  MiniTest.expect.equality(true, found_opts1, "cleanup_all should kill session1 with opts1/sb1")
  MiniTest.expect.equality(true, found_opts2, "cleanup_all should kill session2 with opts2/sb2")
end

T["tool: schema description reflects backend get_description"] = function()
  -- Intent: Verify tool description is built using the facade/backend
  -- get_description instead of a hardcoded sandlock string.
  local sandbox_stub = {
    is_available = function()
      return true
    end,
    should_use = function()
      return true
    end,
    run = function()
      return nil
    end,
    kill = function() end,
    get_description = function()
      return "bubblewrap-backed test sandbox."
    end,
  }
  local def = tool_mod.create(
    { backend = "bubblewrap", backends = { bubblewrap = {} }, rules = {} },
    {
      registry = tool_mod._internal.SessionRegistry.new(),
      sandbox = sandbox_stub,
    }
  )
  MiniTest.expect.equality(
    true,
    def.schema["function"].description:find("bubblewrap%-backed test sandbox") ~= nil,
    "tool description should include backend-specific text"
  )
end

return T
