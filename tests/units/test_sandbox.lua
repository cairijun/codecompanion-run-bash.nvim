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

  T["non-sandbox: kill sends SIGTERM before SIGKILL and fires callback"] = function()
    -- Intent: Verify non-sandbox kill uses two-stage SIGTERM → delayed SIGKILL.
    -- The trap handler proves SIGTERM arrived before SIGKILL;
    -- SIGKILL alone would kill the process without the trap firing.
    local file_path = "/tmp/cc-test-kill-seq-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false
    local callback_fired = false

    local handle, pid = sandbox.run(nil, {
      cmd = "trap 'echo SIGTERM_RECEIVED' TERM; sleep 30",
      fd = fd,
      file_path = file_path,
      use_sandbox = false,
      on_exit = function()
        done = true
      end,
    })

    if handle then
      uv.unref(handle)
    end

    -- Give trap time to be set in the child process
    vim.wait(300, function()
      return false
    end)

    sandbox.kill(nil, pid, function()
      callback_fired = true
    end)

    -- Wait for both process exit and kill callback (SIGTERM + 2s delay + SIGKILL)
    local ok = vim.wait(5000, function()
      return done and callback_fired
    end, 50)
    pcall(uv.fs_close, fd)
    local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
    pcall(os.remove, file_path)

    MiniTest.expect.equality(true, ok, "process should die and callback should fire")
    Helpers.expect_contains("SIGTERM_RECEIVED", content)
  end

  T["non-sandbox: kill without callback does not error"] = function()
    local ok, err = pcall(sandbox.kill, nil, 99999)
    MiniTest.expect.equality(true, ok, "kill without callback should not error: " .. tostring(err))
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
      fs_writable = { vim.fn.getcwd() },
      fs_readable = { vim.fn.expand("$HOME") },
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

  -- profile_path must be defined here — the sandbox mode do...end block above
  -- has its own scope and profile_path doesn't leak into this block.
  local profile_path = Helpers.sandbox_profile_path()

  local orig_spawn = uv.spawn
  local orig_unref = uv.unref
  local orig_close = uv.close
  local orig_os_execute = os.execute

  local spy_set = MiniTest.new_set({
    hooks = {
      post = function()
        uv.spawn = orig_spawn
        uv.unref = orig_unref
        uv.close = orig_close
        os.execute = orig_os_execute
      end,
    },
  })

  spy_set["spy: sandbox mode passes sandlock as executable"] = function()
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
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
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

    MiniTest.expect.equality("sandlock", captured_exe)
    MiniTest.expect.equality(true, captured_exe ~= nil)
  end

  spy_set["spy: sandbox args contain profile and rules flags"] = function()
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
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
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

    MiniTest.expect.equality(true, captured_args ~= nil)
    -- Check for key flags
    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--profile-file", args_str)
    Helpers.expect_contains("--name", args_str)
    Helpers.expect_contains("--port-remap", args_str)
    Helpers.expect_contains("-w", args_str)
    Helpers.expect_contains("-r", args_str)
    Helpers.expect_contains("/var", args_str)
    Helpers.expect_contains("/usr", args_str)
  end

  spy_set["spy: non-sandbox mode passes bash"] = function()
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

    MiniTest.expect.equality("bash", captured_exe)
    MiniTest.expect.equality(true, captured_args ~= nil)
    MiniTest.expect.equality("-c", (captured_args or {})[1])
    MiniTest.expect.equality("echo hi", (captured_args or {})[2])
  end

  spy_set["spy: table rules are expanded"] = function()
    -- Intent: Verify that table rules are expanded into sandlock flag+path pairs.
    -- Uses real existing paths (/var, /etc, /usr) so that resolve_path
    -- existence checks pass.
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
        fs_writable = { "/var", "/etc" },
        fs_readable = { "/usr" },
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

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("/var", args_str)
    Helpers.expect_contains("/etc", args_str)
    Helpers.expect_contains("/usr", args_str)
  end

  spy_set["spy: nil/missing rule produces empty args"] = function()
    -- Intent: Verify that an empty rules table produces no -w/-r flags
    -- in the spawn args.
    local captured_args = nil

    uv.unref = function() end

    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12349
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {},
    }

    local ok, err = pcall(sandbox.run, test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy4",
      on_exit = function() end,
    })

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

  spy_set["spy: kill uses uv.spawn array, not os.execute string"] = function()
    -- Intent: Verify that sandbox.kill passes arguments as an array to uv.spawn
    -- rather than building a shell command string, preventing shell injection.
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

    MiniTest.expect.equality(true, not os_execute_called, "os.execute must NOT be called")
    MiniTest.expect.equality(true, spawn_called, "uv.spawn should be called")
    MiniTest.expect.equality("sandlock", captured_exe)
    MiniTest.expect.equality(true, captured_args ~= nil)
    if captured_args then
      MiniTest.expect.equality("kill", captured_args[1])
      MiniTest.expect.equality(malicious_name, captured_args[2])
    end
  end

  spy_set["spy: mocks properly restored after test"] = function()
    -- Intent: Verify that spy tests properly restore uv.spawn and uv.unref,
    -- preventing test cross-contamination.
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

  spy_set["spy: consecutive spy tests don't contaminate"] = function()
    -- Intent: Verify that two consecutive spy tests don't interfere,
    -- each capturing its own mock values independently.

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

  spy_set["spy: extra_args passed to sandlock"] = function()
    -- Intent: Verify extra_args are inserted into sandlock args before `--`
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12350
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      extra_args = { "--allow-degraded", "signal-scope" },
      rules = {
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy5",
      on_exit = function() end,
    })

    MiniTest.expect.equality(true, captured_args ~= nil)
    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--allow-degraded", args_str)
    Helpers.expect_contains("signal-scope", args_str)
    -- Verify extra_args appear before `--`
    local dash_dash_idx = nil
    local degraded_idx = nil
    for i, arg in ipairs(captured_args or {}) do
      if arg == "--" and not dash_dash_idx then
        dash_dash_idx = i
      end
      if arg == "--allow-degraded" then
        degraded_idx = i
      end
    end
    MiniTest.expect.equality(true, dash_dash_idx ~= nil, "should have -- separator")
    MiniTest.expect.equality(true, degraded_idx ~= nil, "should have --allow-degraded")
    if dash_dash_idx and degraded_idx then
      MiniTest.expect.equality(
        true,
        degraded_idx < dash_dash_idx,
        "extra_args should appear before --"
      )
    end
  end

  spy_set["spy: extra_args nil adds nothing"] = function()
    -- Intent: Verify that when extra_args is nil, no extra args are added
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12351
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy6",
      on_exit = function() end,
    })

    MiniTest.expect.equality(true, captured_args ~= nil)
    local args_str = table.concat(captured_args or {}, " ")
    -- Should not contain any extra_args-related content
    local has_degraded = string.find(args_str, "--allow-degraded") ~= nil
    MiniTest.expect.equality(false, has_degraded, "should not have --allow-degraded")
  end

  spy_set["spy: extra_args empty table adds nothing"] = function()
    -- Intent: Verify that when extra_args is an empty table, no extra args are added
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12352
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      extra_args = {},
      rules = {
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy7",
      on_exit = function() end,
    })

    MiniTest.expect.equality(true, captured_args ~= nil)
    -- Verify the args structure is correct (no extra elements)
    -- The args should end with: ... -r /home -- bash -c echo hi
    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("-- bash -c echo hi", args_str)
  end

  spy_set["spy: extra_args multiple args"] = function()
    -- Intent: Verify that multiple extra_args are all added correctly
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12353
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      extra_args = { "--allow-degraded", "fs-refer", "--disable", "signal-scope" },
      rules = {
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy8",
      on_exit = function() end,
    })

    MiniTest.expect.equality(true, captured_args ~= nil)
    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--allow-degraded", args_str)
    Helpers.expect_contains("fs-refer", args_str)
    Helpers.expect_contains("--disable", args_str)
    Helpers.expect_contains("signal-scope", args_str)
  end

  spy_set["spy: ~ expansion in fs_denied"] = function()
    -- Intent: Verify that ~ in fs_denied paths is expanded to the user's
    -- home directory.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12360
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_denied = { "~/test-deny-path" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-tilde",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--fs-deny", args_str)
    Helpers.expect_contains(vim.fn.expand("~") .. "/test-deny-path", args_str)
  end

  spy_set["spy: $HOME expansion in fs_denied"] = function()
    -- Intent: Verify that $HOME in fs_denied paths is expanded to the
    -- user's home directory.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12361
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_denied = { "$HOME/test-deny" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-home",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--fs-deny", args_str)
    Helpers.expect_contains(vim.fn.expand("$HOME") .. "/test-deny", args_str)
  end

  spy_set["spy: XDG fallback when env var unset"] = function()
    -- Intent: Verify that when $XDG_DATA_HOME is unset, the path falls
    -- back to ~/.local/share.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12362
    end

    local saved = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = nil

    local ok = pcall(function()
      local test_sb_opts = {
        enabled = true,
        profile = "/tmp/fake-profile.toml",
        rules = {
          fs_denied = { "$XDG_DATA_HOME/test" },
        },
      }

      sandbox.run(test_sb_opts, {
        cmd = "echo hi",
        fd = 3,
        file_path = "/tmp/test.out",
        use_sandbox = true,
        sandbox_name = "cc-test-spy-xdg-fallback",
        on_exit = function() end,
      })
    end)

    vim.env.XDG_DATA_HOME = saved

    MiniTest.expect.equality(true, ok, "should not crash")
    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--fs-deny", args_str)
    -- Path should end with /.local/share/test
    Helpers.expect_contains("/.local/share/test", args_str)
  end

  spy_set["spy: XDG env var set"] = function()
    -- Intent: Verify that when $XDG_DATA_HOME is set to a custom path,
    -- it is used instead of the fallback.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12363
    end

    local saved = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = "/tmp/test-xdg-custom"

    local ok = pcall(function()
      local test_sb_opts = {
        enabled = true,
        profile = "/tmp/fake-profile.toml",
        rules = {
          fs_denied = { "$XDG_DATA_HOME/test" },
        },
      }

      sandbox.run(test_sb_opts, {
        cmd = "echo hi",
        fd = 3,
        file_path = "/tmp/test.out",
        use_sandbox = true,
        sandbox_name = "cc-test-spy-xdg-set",
        on_exit = function() end,
      })
    end)

    vim.env.XDG_DATA_HOME = saved

    MiniTest.expect.equality(true, ok, "should not crash")
    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--fs-deny", args_str)
    Helpers.expect_contains("/tmp/test-xdg-custom/test", args_str)
  end

  spy_set["spy: fs_denied with non-existent path"] = function()
    -- Intent: Verify that fs_denied paths are included even if they don't
    -- exist — sandlock --fs-deny allows non-existent paths.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12364
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_denied = { "/nonexistent-deny-xyz" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-deny-nonexist",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("--fs-deny", args_str)
    Helpers.expect_contains("/nonexistent-deny-xyz", args_str)
  end

  spy_set["spy: trailing slash removed"] = function()
    -- Intent: Verify that trailing slashes on paths are removed by
    -- vim.fs.normalize.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12365
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_readable = { "/usr/" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-trailing",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("-r /usr", args_str)
    -- Should NOT contain the trailing slash
    MiniTest.expect.equality(
      nil,
      string.find(args_str, "/usr/ ", 1, true),
      "should not have trailing slash before space"
    )
  end

  spy_set["spy: non-existent path skipped for fs_readable"] = function()
    -- Intent: Verify that non-existent paths are silently skipped for
    -- fs_readable (existence check gates -r/-w).
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12366
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_readable = { "/usr", "/nonexistent-xyz-123" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-nonexist",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("-r /usr", args_str)
    -- Non-existent path should NOT appear
    MiniTest.expect.equality(
      nil,
      string.find(args_str, "nonexistent-xyz-123", 1, true),
      "non-existent path should be skipped"
    )
  end

  spy_set["spy: $XDG_RUNTIME_DIR unset, no fallback"] = function()
    -- Intent: Verify that $XDG_RUNTIME_DIR has no fallback (spec requires
    -- it to be set), so the path is skipped when the env var is unset.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12367
    end

    local saved = vim.env.XDG_RUNTIME_DIR
    vim.env.XDG_RUNTIME_DIR = nil

    local ok = pcall(function()
      local test_sb_opts = {
        enabled = true,
        profile = "/tmp/fake-profile.toml",
        rules = {
          fs_denied = { "$XDG_RUNTIME_DIR/test" },
        },
      }

      sandbox.run(test_sb_opts, {
        cmd = "echo hi",
        fd = 3,
        file_path = "/tmp/test.out",
        use_sandbox = true,
        sandbox_name = "cc-test-spy-xdg-runtime",
        on_exit = function() end,
      })
    end)

    vim.env.XDG_RUNTIME_DIR = saved

    MiniTest.expect.equality(true, ok, "should not crash")
    local args_str = table.concat(captured_args or {}, " ")
    -- Should NOT contain --fs-deny for this path
    MiniTest.expect.equality(
      nil,
      string.find(args_str, "XDG_RUNTIME_DIR", 1, true),
      "XDG_RUNTIME_DIR should not appear in args"
    )
  end

  spy_set["spy: unknown env var, no fallback"] = function()
    -- Intent: Verify that unknown environment variables (not in
    -- XDG_FALLBACKS) result in the path being skipped.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12368
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_denied = { "$UNKNOWN_VAR_123/test" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-unknown-var",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    MiniTest.expect.equality(
      nil,
      string.find(args_str, "UNKNOWN_VAR_123", 1, true),
      "unknown env var should be skipped"
    )
  end

  spy_set["spy: all paths fail -> empty args"] = function()
    -- Intent: Verify that when all paths in a rule fail to resolve,
    -- no corresponding flags are emitted.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12369
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_readable = { "/nonexistent1", "/nonexistent2" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-all-fail",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    -- No -r flag should be present (expand_rule returned empty list)
    MiniTest.expect.equality(nil, string.find(args_str, " -r ", 1, true), "should not have -r flag")
  end

  spy_set["spy: fs_denied, fs_writable, fs_readable all present"] = function()
    -- Intent: Verify that all three rules emit their corresponding flags
    -- in the correct order: -w, -r, --fs-deny.
    local captured_args = nil

    uv.unref = function() end
    uv.spawn = function(exe, opts, on_exit)
      captured_args = opts.args
      return {}, 12370
    end

    local test_sb_opts = {
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
        fs_denied = { "/nonexistent-deny" },
      },
    }

    sandbox.run(test_sb_opts, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy-all-three",
      on_exit = function() end,
    })

    local args_str = table.concat(captured_args or {}, " ")
    Helpers.expect_contains("-w", args_str)
    Helpers.expect_contains("-r", args_str)
    Helpers.expect_contains("--fs-deny", args_str)
    -- Verify order: -w before -r before --fs-deny
    local w_pos = string.find(args_str, "-w ", 1, true)
    local r_pos = string.find(args_str, "-r ", 1, true)
    local deny_pos = string.find(args_str, "--fs-deny", 1, true)
    MiniTest.expect.equality(true, w_pos ~= nil, "-w should be present")
    MiniTest.expect.equality(true, r_pos ~= nil, "-r should be present")
    MiniTest.expect.equality(true, deny_pos ~= nil, "--fs-deny should be present")
    if w_pos and r_pos then
      MiniTest.expect.equality(true, w_pos < r_pos, "-w should come before -r")
    end
    if r_pos and deny_pos then
      MiniTest.expect.equality(true, r_pos < deny_pos, "-r should come before --fs-deny")
    end
  end

  T["spy tests"] = spy_set
end

return T
