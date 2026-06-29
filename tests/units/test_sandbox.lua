--[[
Test: sandbox/init.lua — Facade & Execution Engine

Intent: Verify facade dispatches to correct backend by opts.backend,
generates sandbox_name as run() 4th return value, validates unknown
backends, and handles non-sandbox execution (bash direct spawn,
two-stage SIGTERM → SIGKILL). Sandbox integration tests verify
end-to-end sandlock execution.
]]

local uv = vim.uv
local Helpers = require("tests.helpers")
local sandbox = require("codecompanion._extensions.run_bash.sandbox")

local T = MiniTest.new_set()

-- Module exists
do
  local ok, _ = pcall(require, "codecompanion._extensions.run_bash.sandbox")
  T["facade exists"] = function()
    MiniTest.expect.equality(true, ok)
  end
end

-- ── Facade dispatch / signature tests ────────────────────────────

T["facade: is_available false when backend=false"] = function()
  MiniTest.expect.equality(false, sandbox.is_available({ backend = false }))
end

T["facade: is_available false when nil opts"] = function()
  MiniTest.expect.equality(false, sandbox.is_available(nil))
end

T["facade: is_available false when backend=nil"] = function()
  MiniTest.expect.equality(false, sandbox.is_available({ backend = nil }))
end

T["facade: should_use false when skip_sandbox=true"] = function()
  MiniTest.expect.equality(
    false,
    sandbox.should_use({ skip_sandbox = true }, { backend = "sandlock" })
  )
end

T["facade: should_use false when backend disabled"] = function()
  MiniTest.expect.equality(false, sandbox.should_use({ skip_sandbox = false }, { backend = false }))
end

T["facade: unknown backend errors with descriptive message"] = function()
  local ok, err = pcall(function()
    sandbox.is_available({ backend = "unknown" })
  end)
  MiniTest.expect.equality(false, ok)
  MiniTest.expect.equality(
    true,
    type(err) == "string" and err:find("unknown backend") ~= nil,
    "error should mention 'unknown backend': " .. tostring(err)
  )
end

T["facade: run returns sandbox_name for naming backend"] = function()
  -- Use spawn spy so we don't actually invoke sandlock
  local function spawn_stub(exe, opts, on_exit)
    return {}, 12345
  end
  local function no_op() end

  local _, _, sandbox_used, sandbox_name = sandbox.run({
    backend = "sandlock",
    rules = {},
    backends = { sandlock = { profile = "/tmp/fake.toml" } },
  }, {
    cmd = "echo hi",
    fd = 3,
    use_sandbox = true,
    on_exit = no_op,
    deps = { spawn = spawn_stub, unref = no_op },
  })

  MiniTest.expect.equality(true, sandbox_used)
  MiniTest.expect.equality(
    true,
    sandbox_name ~= nil,
    "sandbox_name should be non-nil for naming backend"
  )
  MiniTest.expect.equality(true, type(sandbox_name) == "string")
  MiniTest.expect.equality(true, vim.startswith(sandbox_name, "cc-bash-"))
end

T["facade: run returns nil sandbox_name for non-naming backend"] = function()
  local bw_path = "codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"
  package.loaded[bw_path] = {
    capabilities = function()
      return { named_sandbox = false }
    end,
    run = function(opts, exec_params)
      local deps = exec_params.deps or {}
      local spawn = deps.spawn or uv.spawn
      local unref = deps.unref or uv.unref
      local handle, pid = spawn("bwrap", {
        args = {},
        stdio = { nil, exec_params.fd, exec_params.fd },
      }, exec_params.on_exit)
      if handle then
        unref(handle)
      end
      return handle, pid
    end,
    kill = function() end,
    validate_opts = function()
      return nil
    end,
    is_available = function()
      return true
    end,
    get_description = function()
      return "bubblewrap"
    end,
  }

  local function spawn_stub()
    return {}, 99999
  end
  local function no_op() end

  local _, _, _, sandbox_name = sandbox.run(
    { backend = "bubblewrap", rules = {}, backends = { bubblewrap = {} } },
    {
      cmd = "echo hi",
      fd = 3,
      use_sandbox = true,
      on_exit = no_op,
      deps = { spawn = spawn_stub, unref = no_op },
    }
  )

  MiniTest.expect.equality(nil, sandbox_name)

  package.loaded[bw_path] = nil
end

T["facade: kill dispatches to sandlock backend with opts"] = function()
  local captured = {}
  local function spawn_stub(exe, opts, on_exit)
    captured.exe = exe
    captured.args = opts.args
    if on_exit then
      on_exit()
    end
    return {}, 99999
  end
  local function no_op() end

  sandbox.kill(
    { backend = "sandlock", backends = { sandlock = { profile = "/tmp/fake.toml" } } },
    "test-sb",
    12345,
    nil,
    { spawn = spawn_stub, close = no_op, unref = no_op }
  )

  MiniTest.expect.equality("sandlock", captured.exe)
  MiniTest.expect.equality("kill", (captured.args or {})[1])
  MiniTest.expect.equality("test-sb", (captured.args or {})[2])
end

-- ── Non-sandbox mode ──────────────────────────────────────────────

do
  local sandbox_opts = { backend = false }

  T["non-sandbox: run echo hello"] = function()
    local file_path = "/tmp/cc-test-hello-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil, "fs_open failed")

    local exit_code = nil
    local done = false

    local handle, pid, sandbox_used, sandbox_name = sandbox.run(sandbox_opts, {
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
    MiniTest.expect.equality(nil, sandbox_name, "sandbox_name should be nil for non-sandbox")
  end

  T["non-sandbox: run false (exit 1)"] = function()
    local file_path = "/tmp/cc-test-false-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(sandbox_opts, {
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

    local handle, pid = sandbox.run(sandbox_opts, {
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

    sandbox.kill(sandbox_opts, nil, pid, function()
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
    local ok, err = pcall(sandbox.kill, sandbox_opts, nil, 99999)
    MiniTest.expect.equality(true, ok, "kill without callback should not error: " .. tostring(err))
  end

  T["non-sandbox: output interleaving"] = function()
    local file_path = "/tmp/cc-test-interleave-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false

    local handle, pid = sandbox.run(sandbox_opts, {
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
  local function make_sandbox_opts()
    return {
      backend = "sandlock",
      rules = {
        fs_writable = { vim.fn.getcwd() },
        fs_readable = { vim.fn.expand("$HOME") },
      },
      backends = {
        sandlock = {
          profile = Helpers.sandbox_profile_path(),
        },
      },
    }
  end

  T["sandbox: is_available true when everything present"] = function()
    Helpers.require_sandbox()
    MiniTest.expect.equality(true, sandbox.is_available(make_sandbox_opts()))
  end

  T["sandbox: run echo hello"] = function()
    Helpers.require_sandbox()

    local sb_opts = make_sandbox_opts()
    local file_path = "/tmp/cc-sb-hello-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid, sandbox_used, sandbox_name = sandbox.run(sb_opts, {
      cmd = "echo hello",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
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
    MiniTest.expect.equality(true, sandbox_name ~= nil, "sandbox_name should be returned")
    if exit_code ~= nil then
      MiniTest.expect.equality(0, exit_code)
    end
    Helpers.expect_contains("hello", content)
  end

  T["sandbox: write outside sandbox fails"] = function()
    Helpers.require_sandbox()

    local sb_opts = make_sandbox_opts()
    local file_path = "/tmp/cc-sb-ouside-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(sb_opts, {
      cmd = "touch /etc/cc-test-forbidden 2>&1",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
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

    local sb_opts = make_sandbox_opts()
    local file_path = "/tmp/cc-sb-home-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(sb_opts, {
      cmd = "cat ~/.profile",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
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

    local sb_opts = make_sandbox_opts()
    local test_file = "/tmp/cc-sb-write-" .. math.random(10000, 99999) .. ".txt"
    local file_path = "/tmp/cc-sb-write-out-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local exit_code = nil
    local done = false

    local handle, pid = sandbox.run(sb_opts, {
      cmd = "touch " .. test_file,
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
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

    local sb_opts = make_sandbox_opts()
    local file_path = "/tmp/cc-sb-kill-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false

    local handle, pid, _, sb_name = sandbox.run(sb_opts, {
      cmd = "sleep 30",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
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

    -- Kill via facade, passing sandbox_opts and sandbox_name from run return
    sandbox.kill(sb_opts, sb_name, pid)

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

    local sb_opts = make_sandbox_opts()
    local file_path = "/tmp/cc-sb-interleave-" .. math.random(10000, 99999) .. ".out"
    local fd = uv.fs_open(file_path, "w", 420)
    MiniTest.expect.equality(true, fd ~= nil)

    local done = false

    local handle, pid = sandbox.run(sb_opts, {
      cmd = "echo out1; echo err1 >&2; echo out2",
      fd = fd,
      file_path = file_path,
      use_sandbox = true,
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

return T
