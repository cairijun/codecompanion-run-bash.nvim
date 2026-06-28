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

-- ── Parameter construction ──────────────────────────────────────

do
  local sandbox = require("codecompanion._extensions.run_bash.sandbox")
  local profile_path = Helpers.sandbox_profile_path()

  local function truthy_fs()
    return {}
  end

  local function mk_fs(exists_set)
    return function(path)
      return exists_set[path] and {}
    end
  end

  local arg_set = MiniTest.new_set()

  arg_set["build_sandlock_args: returns expected sandlock arg table"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", rules = {} },
      "echo hi",
      "test-sb",
      { fs_stat = truthy_fs }
    )
    MiniTest.expect.equality({
      "run",
      "--profile-file",
      "/tmp/fake-profile.toml",
      "--name",
      "test-sb",
      "--port-remap",
      "--",
      "bash",
      "-c",
      "echo hi",
    }, args)
  end

  arg_set["build_sandlock_args: expands writable/readable/denied rules in order"] = function()
    local args = sandbox.build_sandlock_args({
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
        fs_denied = { "/nonexistent-deny" },
      },
    }, "ls", "test-sb", { fs_stat = mk_fs({ ["/var"] = true, ["/usr"] = true }) })
    MiniTest.expect.equality({
      "run",
      "--profile-file",
      "/tmp/fake-profile.toml",
      "--name",
      "test-sb",
      "--port-remap",
      "-w",
      "/var",
      "-r",
      "/usr",
      "--fs-deny",
      "/nonexistent-deny",
      "--",
      "bash",
      "-c",
      "ls",
    }, args)
  end

  arg_set["build_sandlock_args: extra_args inserted before --"] = function()
    local args = sandbox.build_sandlock_args({
      profile = "/tmp/fake-profile.toml",
      extra_args = { "--allow-degraded", "signal-scope" },
      rules = {},
    }, "echo hi", "test-sb", { fs_stat = truthy_fs })
    local dash_idx = nil
    local extra_idx = nil
    for i, v in ipairs(args) do
      if v == "--" and not dash_idx then
        dash_idx = i
      end
      if v == "--allow-degraded" then
        extra_idx = i
      end
    end
    MiniTest.expect.equality(true, dash_idx ~= nil)
    MiniTest.expect.equality(true, extra_idx ~= nil)
    MiniTest.expect.equality(true, extra_idx < dash_idx)
  end

  arg_set["build_sandlock_args: empty rules produce no rule flags"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", rules = {} },
      "echo hi",
      "test-sb",
      { fs_stat = truthy_fs }
    )
    for _, v in ipairs(args) do
      MiniTest.expect.equality(false, v == "-w" or v == "-r" or v == "--fs-deny")
    end
  end

  arg_set["build_sandlock_args: empty extra_args add nothing"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", extra_args = {}, rules = {} },
      "echo hi",
      "test-sb",
      { fs_stat = truthy_fs }
    )
    MiniTest.expect.equality({
      "run",
      "--profile-file",
      "/tmp/fake-profile.toml",
      "--name",
      "test-sb",
      "--port-remap",
      "--",
      "bash",
      "-c",
      "echo hi",
    }, args)
  end

  arg_set["build_sandlock_args: ~ expands to home directory"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", rules = { fs_denied = { "~/test-deny" } } },
      "echo hi",
      "test-sb",
      { fs_stat = truthy_fs }
    )
    local home = vim.fn.expand("~")
    MiniTest.expect.equality(true, vim.tbl_contains(args, "--fs-deny"))
    MiniTest.expect.equality(true, vim.tbl_contains(args, home .. "/test-deny"))
  end

  arg_set["build_sandlock_args: $HOME expands"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", rules = { fs_denied = { "$HOME/test-deny" } } },
      "echo hi",
      "test-sb",
      { fs_stat = truthy_fs }
    )
    local home = vim.fn.expand("$HOME")
    MiniTest.expect.equality(true, vim.tbl_contains(args, "--fs-deny"))
    MiniTest.expect.equality(true, vim.tbl_contains(args, home .. "/test-deny"))
  end

  arg_set["build_sandlock_args: fs_denied includes non-existent paths"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", rules = { fs_denied = { "/nonexistent-deny-xyz" } } },
      "echo hi",
      "test-sb",
      { fs_stat = truthy_fs }
    )
    MiniTest.expect.equality(true, vim.tbl_contains(args, "--fs-deny"))
    MiniTest.expect.equality(true, vim.tbl_contains(args, "/nonexistent-deny-xyz"))
  end

  arg_set["build_sandlock_args: fs_readable non-existent path skipped"] = function()
    local args = sandbox.build_sandlock_args({
      profile = "/tmp/fake-profile.toml",
      rules = { fs_readable = { "/usr", "/nonexistent-xyz-123" } },
    }, "echo hi", "test-sb", { fs_stat = mk_fs({ ["/usr"] = true }) })
    MiniTest.expect.equality(true, vim.tbl_contains(args, "-r"))
    MiniTest.expect.equality(true, vim.tbl_contains(args, "/usr"))
    MiniTest.expect.equality(false, vim.tbl_contains(args, "/nonexistent-xyz-123"))
  end

  arg_set["build_sandlock_args: trailing slash removed"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", rules = { fs_readable = { "/usr/" } } },
      "echo hi",
      "test-sb",
      { fs_stat = mk_fs({ ["/usr"] = true }) }
    )
    local str = table.concat(args, " ")
    MiniTest.expect.equality(true, str:find("-r /usr ", 1, true) ~= nil)
    MiniTest.expect.equality(nil, str:find("/usr/ ", 1, true))
  end

  arg_set["build_sandlock_args: XDG_DATA_HOME fallback when unset"] = function()
    local saved = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = nil
    local ok, args = pcall(sandbox.build_sandlock_args, {
      profile = "/tmp/fake-profile.toml",
      rules = { fs_denied = { "$XDG_DATA_HOME/test" } },
    }, "echo hi", "test-sb", { fs_stat = truthy_fs })
    vim.env.XDG_DATA_HOME = saved
    MiniTest.expect.equality(true, ok)
    MiniTest.expect.equality(true, vim.tbl_contains(args, "--fs-deny"))
    MiniTest.expect.equality(
      true,
      vim.tbl_contains(args, vim.fn.expand("~") .. "/.local/share/test")
    )
  end

  arg_set["build_sandlock_args: XDG_DATA_HOME set to custom path"] = function()
    local saved = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = "/tmp/test-xdg-custom"
    local ok, args = pcall(sandbox.build_sandlock_args, {
      profile = "/tmp/fake-profile.toml",
      rules = { fs_denied = { "$XDG_DATA_HOME/test" } },
    }, "echo hi", "test-sb", { fs_stat = truthy_fs })
    vim.env.XDG_DATA_HOME = saved
    MiniTest.expect.equality(true, ok)
    MiniTest.expect.equality(true, vim.tbl_contains(args, "/tmp/test-xdg-custom/test"))
  end

  arg_set["build_sandlock_args: XDG_RUNTIME_DIR unset no fallback"] = function()
    local saved = vim.env.XDG_RUNTIME_DIR
    vim.env.XDG_RUNTIME_DIR = nil
    local ok, args = pcall(sandbox.build_sandlock_args, {
      profile = "/tmp/fake-profile.toml",
      rules = { fs_denied = { "$XDG_RUNTIME_DIR/test" } },
    }, "echo hi", "test-sb", { fs_stat = truthy_fs })
    vim.env.XDG_RUNTIME_DIR = saved
    MiniTest.expect.equality(true, ok)
    MiniTest.expect.equality(false, vim.tbl_contains(args, "XDG_RUNTIME_DIR"))
  end

  arg_set["build_sandlock_args: unknown env var skipped"] = function()
    local args = sandbox.build_sandlock_args(
      { profile = "/tmp/fake-profile.toml", rules = { fs_denied = { "$UNKNOWN_VAR_123/test" } } },
      "echo hi",
      "test-sb",
      { fs_stat = truthy_fs }
    )
    MiniTest.expect.equality(false, vim.tbl_contains(args, "UNKNOWN_VAR_123"))
  end

  arg_set["build_sandlock_args: non-string rule path raises"] = function()
    local ok = pcall(sandbox.build_sandlock_args, {
      profile = "/tmp/fake-profile.toml",
      rules = { fs_writable = { 123 } },
    }, "echo hi", "test-sb", { fs_stat = truthy_fs })
    MiniTest.expect.equality(false, ok)
  end

  local run_set = MiniTest.new_set()

  local function no_op() end

  run_set["run: sandbox mode passes sandlock as executable"] = function()
    local captured = {}
    local function spawn_stub(exe, opts, on_exit)
      captured.exe = exe
      captured.args = opts.args
      return {}, 12345
    end

    sandbox.run({
      enabled = true,
      profile = profile_path,
      rules = {},
    }, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy",
      on_exit = no_op,
      deps = { spawn = spawn_stub, unref = no_op, fs_stat = truthy_fs },
    })

    MiniTest.expect.equality("sandlock", captured.exe)
  end

  run_set["run: sandbox args contain profile and rules flags"] = function()
    local captured = {}
    local function spawn_stub(exe, opts, on_exit)
      captured.args = opts.args
      return {}, 12346
    end

    sandbox.run({
      enabled = true,
      profile = "/tmp/fake-profile.toml",
      rules = {
        fs_writable = { "/var" },
        fs_readable = { "/usr" },
      },
    }, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = true,
      sandbox_name = "cc-test-spy2",
      on_exit = no_op,
      deps = { spawn = spawn_stub, unref = no_op, fs_stat = truthy_fs },
    })

    local str = table.concat(captured.args or {}, " ")
    Helpers.expect_contains("--profile-file", str)
    Helpers.expect_contains("--name", str)
    Helpers.expect_contains("--port-remap", str)
    Helpers.expect_contains("-w", str)
    Helpers.expect_contains("-r", str)
    Helpers.expect_contains("/var", str)
    Helpers.expect_contains("/usr", str)
  end

  run_set["run: non-sandbox mode passes bash"] = function()
    local captured = {}
    local function spawn_stub(exe, opts, on_exit)
      captured.exe = exe
      captured.args = opts.args
      return {}, 12347
    end

    sandbox.run(nil, {
      cmd = "echo hi",
      fd = 3,
      file_path = "/tmp/test.out",
      use_sandbox = false,
      on_exit = no_op,
      deps = { spawn = spawn_stub, unref = no_op },
    })

    MiniTest.expect.equality("bash", captured.exe)
    MiniTest.expect.equality("-c", (captured.args or {})[1])
    MiniTest.expect.equality("echo hi", (captured.args or {})[2])
  end

  run_set["kill: uses uv.spawn array, not os.execute"] = function()
    local captured = {}
    local function spawn_stub(exe, opts, on_exit)
      captured.exe = exe
      captured.args = opts.args
      return {}, 99999
    end

    local malicious_name = "'; rm -rf /; echo '"
    sandbox.kill(malicious_name, 12345, no_op, {
      spawn = spawn_stub,
      close = no_op,
      unref = no_op,
    })

    MiniTest.expect.equality("sandlock", captured.exe)
    MiniTest.expect.equality("kill", (captured.args or {})[1])
    MiniTest.expect.equality(malicious_name, (captured.args or {})[2])
  end

  T["argument construction"] = arg_set
  T["run/kill stubs"] = run_set
end

return T
