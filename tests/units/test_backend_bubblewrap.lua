--[[
Test: backends/bubblewrap.lua — Bubblewrap Backend

Intent: Verify bubblewrap backend maps generic rules to correct bwrap CLI
arguments, handles file/directory deny-rule differences, checks user
namespace availability, performs two-stage kill, and supports extra_args.
]]

local uv = vim.uv
local Helpers = require("tests.helpers")
local backend = require("codecompanion._extensions.run_bash.sandbox.backends.bubblewrap")

local T = MiniTest.new_set()

local function no_op() end

-- Rules sufficient to run /bin/bash and its shared libraries inside bwrap.
local common_rules = {
  writable = { vim.fn.getcwd(), "/tmp" },
  readable = { vim.fn.getcwd(), "/usr", "/bin", "/lib", "/lib64" },
  denied = {},
}

-- ── _build_args tests ────────────────────────────────────────────

T["build_args: writable produces --bind SRC SRC"] = function()
  local args = backend._build_args(
    { extra_args = nil },
    "ls",
    { readable = {}, writable = { "/tmp" }, denied = {} },
    {
      fs_stat = function()
        return nil
      end,
    }
  )
  MiniTest.expect.equality("--bind", args[1])
  MiniTest.expect.equality("/tmp", args[2])
  MiniTest.expect.equality("/tmp", args[3])
end

T["build_args: readable produces --ro-bind SRC SRC"] = function()
  local args = backend._build_args(
    { extra_args = nil },
    "ls",
    { readable = { "/usr" }, writable = {}, denied = {} },
    {
      fs_stat = function()
        return nil
      end,
    }
  )
  MiniTest.expect.equality("--ro-bind", args[1])
  MiniTest.expect.equality("/usr", args[2])
  MiniTest.expect.equality("/usr", args[3])
end

T["build_args: writable bind emitted after readable for same path"] = function()
  -- bwrap mounts are last-mount-wins: a path in both groups must end with
  -- its writable --bind emitted last, or the read-only mount wins.
  local args = backend._build_args(
    { extra_args = nil },
    "ls",
    { readable = { "/x" }, writable = { "/x" }, denied = {} },
    {
      fs_stat = function()
        return nil
      end,
    }
  )
  local ro_bind_pos, bind_pos = nil, nil
  for i, arg in ipairs(args) do
    if arg == "--ro-bind" then
      ro_bind_pos = ro_bind_pos or i
    elseif arg == "--bind" then
      bind_pos = bind_pos or i
    end
  end
  MiniTest.expect.equality(true, ro_bind_pos ~= nil, "--ro-bind mount must be present")
  MiniTest.expect.equality(true, bind_pos ~= nil, "--bind mount must be present")
  MiniTest.expect.equality(
    true,
    bind_pos > ro_bind_pos,
    "writable --bind must be emitted after readable --ro-bind (last mount wins)"
  )
end

T["build_args: denied directory produces --tmpfs PATH"] = function()
  local args = backend._build_args(
    { extra_args = nil },
    "ls",
    { readable = {}, writable = {}, denied = { "/secret" } },
    {
      fs_stat = function(path)
        if path == "/secret" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  )
  MiniTest.expect.equality("--tmpfs", args[1])
  MiniTest.expect.equality("/secret", args[2])
end

T["build_args: denied file is skipped (no primitive)"] = function()
  local args = backend._build_args(
    { extra_args = nil },
    "ls",
    { readable = {}, writable = {}, denied = { "/etc/shadow" } },
    {
      fs_stat = function(path)
        if path == "/etc/shadow" then
          return { type = "file" }
        end
        return nil
      end,
    }
  )
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--tmpfs"))
  MiniTest.expect.equality(false, vim.tbl_contains(args, "/etc/shadow"))
end

T["build_args: nonexistent denied path skipped with one-time warning"] = function()
  -- Use with_mocks to capture vim.notify_once call, even on test failure
  local notify_called = false
  local notify_msg = nil
  Helpers.with_mocks({
    ["vim.notify_once"] = function(msg, _level)
      notify_called = true
      notify_msg = msg
    end,
  }, function()
    local args = backend._build_args(
      { extra_args = nil },
      "ls",
      { readable = {}, writable = {}, denied = { "/nonexistent-path-xyz" } },
      {
        fs_stat = function()
          return nil
        end,
      }
    )
    MiniTest.expect.equality(false, vim.tbl_contains(args, "/nonexistent-path-xyz"))
  end)
  MiniTest.expect.equality(true, notify_called, "should call vim.notify_once")
  MiniTest.expect.equality(
    true,
    type(notify_msg) == "string" and notify_msg:find("bubblewrap") ~= nil,
    "warning should mention bubblewrap"
  )
end

T["build_args: writable char device produces --dev-bind, no warning"] = function()
  -- Intent: bind-mounted device nodes cannot be opened inside a user
  -- namespace (kernel restriction), so writable device rules must use
  -- --dev-bind. A writable rule is an explicit write grant, so the mount is
  -- not wider than declared and must NOT warn.
  local notify_called = false
  local args
  Helpers.with_mocks({
    ["vim.notify_once"] = function(_msg, _level)
      notify_called = true
    end,
  }, function()
    args = backend._build_args(
      { extra_args = nil },
      "ls",
      { readable = {}, writable = { "/dev/null" }, denied = {} },
      {
        fs_stat = function(path)
          if path == "/dev/null" then
            return { type = "char" }
          end
          return nil
        end,
      }
    )
  end)
  MiniTest.expect.equality("--dev-bind", args[1])
  MiniTest.expect.equality("/dev/null", args[2])
  MiniTest.expect.equality("/dev/null", args[3])
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--bind"))
  MiniTest.expect.equality(false, notify_called, "writable device is an explicit grant, no warning")
end

T["build_args: readable char device produces --dev-bind with warning"] = function()
  -- Intent: readable device rules must also use --dev-bind (same kernel
  -- restriction), but bwrap has no read-only device bind, so the mount is
  -- wider than the declared rule and MUST warn about the widening.
  local notify_called = false
  local notify_msg = nil
  local args
  Helpers.with_mocks({
    ["vim.notify_once"] = function(msg, _level)
      notify_called = true
      notify_msg = msg
    end,
  }, function()
    args = backend._build_args(
      { extra_args = nil },
      "ls",
      { readable = { "/dev/null" }, writable = {}, denied = {} },
      {
        fs_stat = function(path)
          if path == "/dev/null" then
            return { type = "char" }
          end
          return nil
        end,
      }
    )
  end)
  MiniTest.expect.equality("--dev-bind", args[1])
  MiniTest.expect.equality("/dev/null", args[2])
  MiniTest.expect.equality("/dev/null", args[3])
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--ro-bind"))
  MiniTest.expect.equality(true, notify_called, "widened readable device rule must warn")
  MiniTest.expect.equality(
    true,
    type(notify_msg) == "string" and notify_msg:find("/dev/null", 1, true) ~= nil,
    "warning should name the widened device path"
  )
end

T["build_args: writable block device produces --dev-bind"] = function()
  -- Intent: block devices share the same kernel restriction as char devices;
  -- a fictional path is used because host block device names are not portable.
  local args = backend._build_args(
    { extra_args = nil },
    "ls",
    { readable = {}, writable = { "/dev/fake-block0" }, denied = {} },
    {
      fs_stat = function(path)
        if path == "/dev/fake-block0" then
          return { type = "block" }
        end
        return nil
      end,
    }
  )
  MiniTest.expect.equality("--dev-bind", args[1])
  MiniTest.expect.equality("/dev/fake-block0", args[2])
  MiniTest.expect.equality("/dev/fake-block0", args[3])
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--bind"))
end

T["build_args: writable directory still produces --bind"] = function()
  -- Intent: non-device paths keep the existing --bind/--ro-bind mapping;
  -- the device routing must not alter directory handling.
  local args = backend._build_args(
    { extra_args = nil },
    "ls",
    { readable = {}, writable = { "/tmp" }, denied = {} },
    {
      fs_stat = function(path)
        if path == "/tmp" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  )
  MiniTest.expect.equality("--bind", args[1])
  MiniTest.expect.equality("/tmp", args[2])
  MiniTest.expect.equality("/tmp", args[3])
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--dev-bind"))
end

T["build_args: device in both readable and writable emits --dev-bind twice, no warning"] = function()
  -- Intent: a device covered by an explicit writable grant is not widened by
  -- its readable entry, so warning would be a false positive; both groups
  -- still emit their own --dev-bind mount.
  local notify_called = false
  local args
  Helpers.with_mocks({
    ["vim.notify_once"] = function(_msg, _level)
      notify_called = true
    end,
  }, function()
    args = backend._build_args(
      { extra_args = nil },
      "ls",
      { readable = { "/dev/null" }, writable = { "/dev/null" }, denied = {} },
      {
        fs_stat = function(path)
          if path == "/dev/null" then
            return { type = "char" }
          end
          return nil
        end,
      }
    )
  end)
  local dev_bind_count = 0
  for _, arg in ipairs(args) do
    if arg == "--dev-bind" then
      dev_bind_count = dev_bind_count + 1
    end
  end
  MiniTest.expect.equality(2, dev_bind_count, "both groups should emit --dev-bind")
  MiniTest.expect.equality(false, notify_called, "writable grant already covers write access")
end

T["build_args: nil sandbox_name does not break arg construction"] = function()
  local args = backend._build_args(
    { extra_args = nil },
    "echo hi",
    { readable = { "/usr" }, writable = { "/tmp" }, denied = { "/secret" } },
    {
      fs_stat = function(path)
        if path == "/secret" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  )
  -- Should still generate valid bwrap args (sandbox_name irrelevant for bwrap)
  MiniTest.expect.equality(true, vim.tbl_contains(args, "--bind"))
  MiniTest.expect.equality(true, vim.tbl_contains(args, "--ro-bind"))
  MiniTest.expect.equality(true, vim.tbl_contains(args, "--tmpfs"))
end

T["build_args: extra_args inserted before -- separator"] = function()
  local args = backend._build_args(
    { extra_args = { "--unshare-net" } },
    "ls",
    { readable = { "/usr" }, writable = {}, denied = {} },
    {
      fs_stat = function()
        return nil
      end,
    }
  )
  local dash_idx, extra_idx
  for i, v in ipairs(args) do
    if v == "--" and not dash_idx then
      dash_idx = i
    end
    if v == "--unshare-net" then
      extra_idx = i
    end
  end
  MiniTest.expect.equality(true, dash_idx ~= nil)
  MiniTest.expect.equality(true, extra_idx ~= nil)
  MiniTest.expect.equality(true, extra_idx < dash_idx, "extra_args must precede --")
end

T["build_args: empty rules produce minimal args"] = function()
  local args = backend._build_args(
    { extra_args = nil },
    "echo hi",
    { readable = {}, writable = {}, denied = {} },
    {
      fs_stat = function()
        return nil
      end,
    }
  )
  MiniTest.expect.equality("--", args[1])
  MiniTest.expect.equality("bash", args[2])
  MiniTest.expect.equality("-c", args[3])
  MiniTest.expect.equality("echo hi", args[4])
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--bind"))
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--ro-bind"))
  MiniTest.expect.equality(false, vim.tbl_contains(args, "--tmpfs"))
end

-- ── is_available tests ────────────────────────────────────────────

T["is_available: true when bwrap installed and uid_map has valid mapping"] = function()
  if not Helpers.should_test_backend("bubblewrap") then
    MiniTest.skip("bubblewrap not selected")
  end
  -- Skip if bwrap is not installed on the host
  if vim.fn.executable("bwrap") ~= 1 then
    MiniTest.skip("bwrap not installed")
    return
  end
  -- If the host doesn't have a valid uid_map, bwrap still wouldn't be available
  MiniTest.expect.equality(true, backend.is_available({}))
end

T["is_available: false when uid_map is zero-map (no user namespace)"] = function()
  Helpers.with_mocks({
    ["vim.fn.executable"] = function(_name)
      return 1
    end,
    ["vim.fn.readfile"] = function(_path)
      return { "0 0 0" }
    end,
  }, function()
    MiniTest.expect.equality(false, backend.is_available({}))
  end)
end

T["is_available: false when uid_map file missing"] = function()
  Helpers.with_mocks({
    ["vim.fn.executable"] = function(_name)
      return 1
    end,
    ["vim.fn.readfile"] = function(_path)
      return {}
    end,
  }, function()
    MiniTest.expect.equality(false, backend.is_available({}))
  end)
end

T["is_available: false when bwrap not installed"] = function()
  Helpers.with_mocks({
    ["vim.fn.executable"] = function(_name)
      return 0
    end,
    ["vim.fn.readfile"] = function(_path)
      return { "0 1000 1" }
    end,
  }, function()
    MiniTest.expect.equality(false, backend.is_available({}))
  end)
end

-- ── validate_opts tests ───────────────────────────────────────────

T["validate_opts: nil opts returns nil"] = function()
  MiniTest.expect.equality(nil, backend.validate_opts(nil))
end

T["validate_opts: valid table returns nil"] = function()
  MiniTest.expect.equality(nil, backend.validate_opts({ extra_args = {} }))
  MiniTest.expect.equality(nil, backend.validate_opts({ extra_args = { "--unshare-net" } }))
  MiniTest.expect.equality(nil, backend.validate_opts({}))
end

T["validate_opts: invalid extra_args returns error string"] = function()
  local err = backend.validate_opts({ extra_args = "bad" })
  MiniTest.expect.equality(true, type(err) == "string" and err ~= "")
end

-- ── capabilities tests ───────────────────────────────────────────

T["capabilities: returns expected flags"] = function()
  MiniTest.expect.equality({
    kill_by_name = false,
    fs_deny_files = false,
    fs_deny_dirs = "mask",
  }, backend.capabilities())
end

-- ── run spy tests ─────────────────────────────────────────────────

T["run: spawns bwrap with args, returns true used and nil sandbox_name"] = function()
  local captured = {}
  local function spawn_stub(exe, opts, on_exit)
    captured.exe = exe
    captured.args = opts.args
    return {}, 54321
  end
  local handle, pid, sandbox_used, sandbox_name = backend.run({ extra_args = {} }, {
    cmd = "echo hi",
    fd = 3,
    on_exit = no_op,
    sandbox_name = nil,
    resolved_rules = { readable = {}, writable = {}, denied = {} },
    deps = {
      spawn = spawn_stub,
      unref = no_op,
      fs_stat = function()
        return nil
      end,
    },
  })
  MiniTest.expect.equality("bwrap", captured.exe)
  MiniTest.expect.equality(true, handle ~= nil, "should return a handle")
  MiniTest.expect.equality(54321, pid)
  MiniTest.expect.equality(true, sandbox_used)
  MiniTest.expect.equality(nil, sandbox_name, "bubblewrap does not support named sandboxes")
  -- Last args should be "--", "bash", "-c", "echo hi"
  local last4 = {
    captured.args[#captured.args - 3],
    captured.args[#captured.args - 2],
    captured.args[#captured.args - 1],
    captured.args[#captured.args],
  }
  MiniTest.expect.equality({ "--", "bash", "-c", "echo hi" }, last4)
end

local function require_bubblewrap()
  if not Helpers.should_test_backend("bubblewrap") then
    MiniTest.skip("bubblewrap not selected")
  end
  if vim.fn.executable("bwrap") ~= 1 then
    MiniTest.skip("bwrap not installed")
  end
  if not backend.is_available({}) then
    MiniTest.skip("bubblewrap not available (no valid uid_map)")
  end
end

-- ── kill two-stage tests ─────────────────────────────────────────

T["kill: real bwrap two-stage kill terminates process"] = function()
  require_bubblewrap()

  local uv = vim.uv
  local file_path = "/tmp/cc-bwrap-real-kill-" .. math.random(10000, 99999) .. ".out"
  local fd = uv.fs_open(file_path, "w", 420)
  MiniTest.expect.equality(true, fd ~= nil)

  local done = false
  local kill_callback_fired = false
  local handle, pid = backend.run({}, {
    cmd = "sleep 30",
    fd = fd,
    on_exit = function()
      done = true
    end,
    resolved_rules = common_rules,
  })

  if handle then
    uv.unref(handle)
  end

  vim.wait(500, function()
    return false
  end, 50, true)

  backend.kill({}, nil, pid, function()
    kill_callback_fired = true
  end)

  local ok = vim.wait(5000, function()
    return done and kill_callback_fired
  end, 50, true)
  pcall(uv.fs_close, fd)
  pcall(os.remove, file_path)

  MiniTest.expect.equality(true, ok, "process should exit and kill callback should fire")
end

T["run: real bwrap executes echo"] = function()
  require_bubblewrap()

  local uv = vim.uv
  local file_path = "/tmp/cc-bwrap-real-run-" .. math.random(10000, 99999) .. ".out"
  local fd = uv.fs_open(file_path, "w", 420)
  MiniTest.expect.equality(true, fd ~= nil)

  local exit_code = nil
  local done = false
  local handle, pid, sandbox_used, sandbox_name = backend.run({}, {
    cmd = "echo hello",
    fd = fd,
    on_exit = function(code)
      exit_code = code
      done = true
    end,
    resolved_rules = common_rules,
  })

  if handle then
    uv.unref(handle)
  end

  local ok = vim.wait(5000, function()
    return done
  end, 50, true)
  pcall(uv.fs_close, fd)
  local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
  pcall(os.remove, file_path)

  MiniTest.expect.equality(true, ok, "on_exit should fire within 5s")
  MiniTest.expect.equality(true, handle ~= nil)
  MiniTest.expect.equality("number", type(pid))
  MiniTest.expect.equality(true, sandbox_used)
  MiniTest.expect.equality(nil, sandbox_name)
  if exit_code ~= nil then
    MiniTest.expect.equality(0, exit_code)
  end
  Helpers.expect_contains("hello", content)
end

-- ── kill two-stage tests ─────────────────────────────────────────

T["kill: two-stage SIGTERM then delayed SIGKILL with callback"] = function()
  local kill_calls = {}
  local timer_callback
  local fake_timer = {
    start = function(self, delay_ms, repeat_ms, cb)
      timer_callback = cb
    end,
    stop = function() end,
    close = function() end,
  }
  local function kill_stub(pid, sig)
    table.insert(kill_calls, { pid = pid, sig = sig })
  end
  local callback_fired = false
  backend.kill({}, nil, 12345, function()
    callback_fired = true
  end, {
    kill = kill_stub,
    new_timer = function()
      return fake_timer
    end,
    unref = no_op,
  })
  -- Immediately: just SIGTERM
  MiniTest.expect.equality(1, #kill_calls, "should only send SIGTERM initially")
  MiniTest.expect.equality("sigterm", kill_calls[1].sig)
  MiniTest.expect.equality(-12345, kill_calls[1].pid, "should kill process group via negative pid")
  MiniTest.expect.equality(false, callback_fired, "callback should NOT fire before timer")
  -- Simulate timer firing
  if timer_callback then
    timer_callback()
  end
  MiniTest.expect.equality(2, #kill_calls, "should send SIGKILL after timer fires")
  MiniTest.expect.equality("sigkill", kill_calls[2].sig)
  MiniTest.expect.equality(true, callback_fired, "callback should fire after SIGKILL sequence")
end

return T
