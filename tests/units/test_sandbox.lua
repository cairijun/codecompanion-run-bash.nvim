--[[
Test: sandbox.lua — Sandbox Execution Engine

Intent: Verify sandbox.is_available, sandbox.run, and sandbox.kill behavior
in both non-sandbox and sandbox modes. Non-sandbox tests always run;
sandbox tests skip if sandlock is unavailable.

]]

local uv = vim.uv
local Helpers = require("tests.helpers")
local T = MiniTest.new_set()

-- Module exists
do
  local ok, _ = pcall(require, "codecompanion._extensions.run_bash.sandbox")
  T["sandbox exists"] = function()
    MiniTest.expect.equality(true, ok)
  end
end

-- ── Non-sandbox mode ──────────────────────────────────────────────

do
  local sandbox = require("codecompanion._extensions.run_bash.sandbox")

  T["non-sandbox: is_available false when enabled=false"] = function()
    MiniTest.expect.equality(false, sandbox.is_available({ enabled = false }))
  end

  T["non-sandbox: is_available false when nil"] = function()
    MiniTest.expect.equality(false, sandbox.is_available(nil))
  end

  T["non-sandbox: is_available false when no profile"] = function()
    MiniTest.expect.equality(false, sandbox.is_available({ enabled = true }))
  end

  T["non-sandbox: run echo hello"] = function()
    local file_path = "/tmp/cc-test-hello-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil, "fs_open failed")

    local exit_code = nil
    local done = false

    local handle, pid, sandbox_used = sandbox.run(nil, {
      cmd = "echo hello",
      fd = fd,
      file_path = file_path,
      use_sandbox = false,
      on_exit = function(code)
        exit_code = code
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(3000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok, "on_exit should fire within 3s")
    if exit_code ~= nil then
      MiniTest.expect.equality(0, exit_code, "exit code should be 0")
    end
    Helpers.expect_contains("hello", content)
    MiniTest.expect.equality(false, sandbox_used, "sandbox should NOT be used")
  end

  T["non-sandbox: run false (exit 1)"] = function()
    local file_path = "/tmp/cc-test-false-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(nil, {
      cmd = "false",
      fd = fd,
      file_path = file_path,
      use_sandbox = false,
      on_exit = function(code)
        exit_code = code
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(3000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok)
    MiniTest.expect.equality(1, exit_code or -1)
  end

  T["non-sandbox: kill running process"] = function()
    local file_path = "/tmp/cc-test-kill-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false

    local handle, pid = sandbox.run(nil, {
      cmd = "sleep 30",
      fd = fd,
      file_path = file_path,
      use_sandbox = false,
      on_exit = function(code)
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    -- Give process time to start
    vim.wait(200, function()
      return false
    end)

    -- Kill the process group
    sandbox.kill(nil, pid)

    -- Wait for on_exit to fire
    local ok = vim.wait(3000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok, "on_exit should fire after kill")
  end

  T["non-sandbox: output interleaving"] = function()
    local file_path = "/tmp/cc-test-interleave-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false

    local handle, pid = sandbox.run(nil, {
      cmd = "echo out1; echo err1 >&2; echo out2",
      fd = fd,
      file_path = file_path,
      use_sandbox = false,
      on_exit = function(code)
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(3000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok)
    Helpers.expect_contains("out1", content)
    Helpers.expect_contains("err1", content)
    Helpers.expect_contains("out2", content)
  end
end

-- ── Sandbox mode (skip if sandlock unavailable) ──────────────────

do
  local sandbox = require("codecompanion._extensions.run_bash.sandbox")

  local profile_path = Helpers.sandbox_profile_path()

  local sandbox_opts = {
    enabled = true,
    profile = profile_path,
    rules = {
      writable = function()
        return { vim.fn.getcwd() }
      end,
      readable = function()
        return { vim.fn.expand("$HOME") }
      end,
    },
  }

  T["sandbox: is_available true when everything present"] = function()
    Helpers.require_sandbox()
    MiniTest.expect.equality(true, sandbox.is_available(sandbox_opts))
  end

  T["sandbox: run echo hello"] = function()
    Helpers.require_sandbox()

    local file_path = "/tmp/cc-sb-hello-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid, sandbox_used = sandbox.run(sandbox_opts, {
      cmd = "echo hello",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
      sandbox_name = "cc-test-hello-" .. math.random(1000, 9999),
      on_exit = function(code)
        exit_code = code
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(5000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok, "on_exit should fire")
    MiniTest.expect.equality(true, sandbox_used, "sandbox should be used")
    if exit_code ~= nil then
      MiniTest.expect.equality(0, exit_code)
    end
    Helpers.expect_contains("hello", content)
  end

  T["sandbox: write outside sandbox fails"] = function()
    Helpers.require_sandbox()

    local file_path = "/tmp/cc-sb-ouside-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(sandbox_opts, {
      cmd = "touch /etc/cc-test-forbidden 2>&1",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
      sandbox_name = "cc-test-outside-" .. math.random(1000, 9999),
      on_exit = function(code)
        exit_code = code
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(5000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok)
    -- In sandbox, this should fail (exit code > 128 for signal-based failure)
    if exit_code ~= nil then
      MiniTest.expect.equality(true, exit_code ~= 0, "should fail (exit code != 0)")
    end
  end

  T["sandbox: read $HOME succeeds"] = function()
    Helpers.require_sandbox()

    local file_path = "/tmp/cc-sb-home-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(sandbox_opts, {
      cmd = "cat ~/.profile",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
      sandbox_name = "cc-test-home-" .. math.random(1000, 9999),
      on_exit = function(code)
        exit_code = code
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(5000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok)
    if exit_code ~= nil then
      MiniTest.expect.equality(0, exit_code, "should succeed reading $HOME")
    end
  end

  T["sandbox: write /tmp succeeds"] = function()
    Helpers.require_sandbox()

    local test_file = "/tmp/cc-sb-write-" .. math.random(10000, 99999) .. ".txt"
    local file_path = "/tmp/cc-sb-write-out-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(sandbox_opts, {
      cmd = "touch " .. test_file,
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
      sandbox_name = "cc-test-tmp-" .. math.random(1000, 9999),
      on_exit = function(code)
        exit_code = code
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(5000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)
    pcall(os.remove, test_file)

    MiniTest.expect.equality(true, ok)
    if exit_code ~= nil then
      MiniTest.expect.equality(0, exit_code, "should succeed writing /tmp")
    end
  end

  T["sandbox: kill running process"] = function()
    Helpers.require_sandbox()

    local file_path = "/tmp/cc-sb-kill-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false
    local sb_name = "cc-test-sbkill-" .. math.random(1000, 9999)

    local handle, pid = sandbox.run(sandbox_opts, {
      cmd = "sleep 30",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
      sandbox_name = sb_name,
      on_exit = function(code)
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    -- Give process time to start
    vim.wait(500, function()
      return false
    end)

    -- Kill via sandbox name (sandlock kill)
    sandbox.kill(sb_name, pid)

    -- Wait for on_exit to fire
    local ok = vim.wait(5000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok, "on_exit should fire after sandbox kill")
  end

  T["sandbox: output interleaving"] = function()
    Helpers.require_sandbox()

    local file_path = "/tmp/cc-sb-interleave-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false

    local handle, pid = sandbox.run(sandbox_opts, {
      cmd = "echo out1; echo err1 >&2; echo out2",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
      sandbox_name = "cc-test-sbinter-" .. math.random(1000, 9999),
      on_exit = function(code)
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    local ok = vim.wait(5000, function()
      return done
    end, 50)
    pcall(uv.fs_close, fd)
    local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok)
    Helpers.expect_contains("out1", content)
    Helpers.expect_contains("err1", content)
    Helpers.expect_contains("out2", content)
  end
end

-- ── Parameter construction (spy on uv.spawn) ───────────────────

do
  local sandbox = require("codecompanion._extensions.run_bash.sandbox")

  T["spy: sandbox mode passes sandlock as executable"] = function()
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref
    local captured_exe = nil
    local captured_args = nil

    uv.unref = function() end -- no-op mock

    uv.spawn = function(exe, opts, on_exit)
      captured_exe = exe
      captured_args = opts.args
      return {}, 12345 -- fake handle (unref mocked)
    end

    local test_sb_opts = {
      enabled = true,
      profile = profile_path,
      rules = {
        writable = function()
          return { "/tmp/writable" }
        end,
        readable = function()
          return { "/home" }
        end,
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy",
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    MiniTest.expect.equality("sandlock", captured_exe)
    MiniTest.expect.equality(true, captured_exe ~= nil)
  end

  T["spy: sandbox args contain profile and rules flags"] = function()
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref
    local captured_args = nil

    uv.unref = function() end

    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12346
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        writable = function()
          return { "/tmp/writable" }
        end,
        readable = function()
          return { "/home" }
        end,
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy2",
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    MiniTest.expect.equality(true, captured_args ~= nil)
    -- Check for key flags
    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--profile-file", args_str)
    Helpers.expect_contains("--name", args_str)
    Helpers.expect_contains("--port-remap", args_str)
    Helpers.expect_contains("-w", args_str)
    Helpers.expect_contains("-r", args_str)
    Helpers.expect_contains("/tmp/writable", args_str)
    Helpers.expect_contains("/home", args_str)
  end

  T["spy: non-sandbox mode passes bash"] = function()
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref
    local captured_exe = nil
    local captured_args = nil

    uv.unref = function() end

    uv.spawn = function(exe, opts, on_exit)
      captured_exe = exe
      captured_args = opts.args
      return {}, 12347
    end

    sandbox.run(nil, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = false,
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    MiniTest.expect.equality("bash", captured_exe)
    MiniTest.expect.equality(true, captured_args ~= nil)
    MiniTest.expect.equality("-c", (captured_args or {})[1])
    MiniTest.expect.equality("echo hi", (captured_args or {})[2])
  end

  T["spy: rules functions are called and expanded"] = function()
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref
    local w_called = false
    local r_called = false
    local captured_args = nil

    uv.unref = function() end

    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12348
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        writable = function()
          w_called = true
          return { "/tmp/a", "/tmp/b" }
        end,
        readable = function()
          r_called = true
          return { "/home/x" }
        end,
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "ls",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy3",
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    MiniTest.expect.equality(true, w_called, "writable function should be called")
    MiniTest.expect.equality(true, r_called, "readable function should be called")

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("/tmp/a", args_str)
    Helpers.expect_contains("/tmp/b", args_str)
    Helpers.expect_contains("/home/x", args_str)
  end

  T["spy: nil-returning rule does not crash"] = function()
    -- Intent: Verify that expand_rule handles a rule function returning nil
    -- without crashing, instead producing an empty args list (no -w/-r flags).
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref
    local captured_args = nil

    uv.unref = function() end

    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12349
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        writable = function()
          return nil
        end,
        readable = function()
          return nil
        end,
      },
    }

    local ok, err = pcall(sandbox.run, test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy4",
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    MiniTest.expect.equality(true, ok, "should not crash: " .. tostring(err))
    MiniTest.expect.equality(true, captured_args ~= nil)
    -- No standalone -w or -r flags should be present (expand_rule returned empty)
    local has_w_flag = false
    local has_r_flag = false
    for _, arg in ipairs(captured_args or {}) do
      if arg == "-w" then
        has_w_flag = true
      end
      if arg == "-r" then
        has_r_flag = true
      end
    end
    MiniTest.expect.equality(true, not has_w_flag, "should not have -w flag")
    MiniTest.expect.equality(true, not has_r_flag, "should not have -r flag")
  end

  T["spy: kill uses uv.spawn array, not os.execute string"] = function()
    -- Intent: Verify that sandbox.kill passes arguments as an array to uv.spawn
    -- rather than building a shell command string, preventing shell injection.
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref
    local orig_close = uv.close
    local orig_os_execute = os.execute

    local spawn_called = false
    local captured_exe = nil
    local captured_args = nil
    local os_execute_called = false

    uv.unref = function() end
    uv.close = function() end

    uv.spawn = function(exe, opts, on_exit)
      spawn_called = true
      captured_exe = exe
      captured_args = opts.args
      return {}, 99999
    end

    os.execute = function()
      os_execute_called = true
      return true
    end

    local malicious_name = "'; rm -rf /; echo '"
    sandbox.kill(malicious_name, 12345)

    uv.spawn = orig_spawn
    uv.unref = orig_unref
    uv.close = orig_close
    os.execute = orig_os_execute

    MiniTest.expect.equality(true, not os_execute_called, "os.execute must NOT be called")
    MiniTest.expect.equality(true, spawn_called, "uv.spawn should be called")
    MiniTest.expect.equality("sandlock", captured_exe)
    MiniTest.expect.equality(true, captured_args ~= nil)
    if captured_args then
      MiniTest.expect.equality("kill", captured_args[1])
      MiniTest.expect.equality(malicious_name, captured_args[2])
    end
  end

  T["spy: mocks properly restored after test"] = function()
    -- Intent: Verify that spy tests properly restore uv.spawn and uv.unref,
    -- preventing test cross-contamination.
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      return {}, 88888
    end

    sandbox.run(nil, {
      cmd = "echo cleanup",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = false,
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    MiniTest.expect.equality(orig_spawn, uv.spawn, "uv.spawn should be restored")
    MiniTest.expect.equality(orig_unref, uv.unref, "uv.unref should be restored")
  end

  T["spy: consecutive spy tests don't contaminate"] = function()
    -- Intent: Verify that two consecutive spy tests don't interfere,
    -- each capturing its own mock values independently.
    local orig_spawn = uv.spawn
    local orig_unref = uv.unref

    -- First spy test
    local first_cmd = nil
    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      first_cmd = opts.args[2]
      return {}, 77771
    end

    sandbox.run(nil, {
      cmd = "echo first",
      fd = 3,
      file_path = "/tmp/test1.out",
      use_sandbox = false,
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    -- Verify restoration between tests
    MiniTest.expect.equality(orig_spawn, uv.spawn, "uv.spawn restored after first test")

    -- Second spy test
    local second_cmd = nil
    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      second_cmd = opts.args[2]
      return {}, 77772
    end

    sandbox.run(nil, {
      cmd = "echo second",
      fd = 3,
      file_path = "/tmp/test2.out",
      use_sandbox = false,
      on_exit = function() end,
    })

    uv.spawn = orig_spawn
    uv.unref = orig_unref

    MiniTest.expect.equality("echo first", first_cmd, "first test should capture its own args")
    MiniTest.expect.equality("echo second", second_cmd, "second test should capture its own args")
    MiniTest.expect.equality(orig_spawn, uv.spawn, "uv.spawn restored after second test")
  end
end

return T
