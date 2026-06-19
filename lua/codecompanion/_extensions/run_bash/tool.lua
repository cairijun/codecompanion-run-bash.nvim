---@brief
---
--- Tool definition for run_bash CodeCompanion extension.
--- Generates schema, system_prompt, cmds handler, and output handlers.
--- Delegates execution to sandbox.lua and uses checker.lua for approval.

local uv = vim.uv
local sandbox = require("codecompanion._extensions.run_bash.sandbox")

local fmt = string.format

-- ── Named constants ───────────────────────────────────────────────────

local MAX_BG_AFTER = 60
local MAX_TIMEOUT = 3600
local DEFAULT_TIMEOUT = 300
local STATUS_RUNNING = "running"
local STATUS_EXITED = "exited"
local STATUS_KILLED = "killed"

-- ── Utility functions ──────────────────────────────────────────────────

---Read file content asynchronously via uv.fs_* functions. Calls callback(err, data).
---Avoids blocking io.open in libuv callbacks.
---@param path string
---@param callback fun(err: string|nil, data: string|nil)
local function read_file_async(path, callback)
  local fd, err = uv.fs_open(path, "r", 384)
  if not fd then
    callback(err or "fs_open failed", nil)
    return
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    callback("fs_fstat failed", nil)
    return
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  callback(nil, data or "")
end

-- Strip ANSI escape sequences (CSI: colors, cursor control, etc.) from output
-- so the agent receives clean text without terminal control codes.
local function strip_ansi(s)
  return (s:gsub("\27%[[%d;]*[a-zA-Z]", ""))
end

---Stop and close a libuv timer, ignoring errors
local function close_timer(timer)
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

-- ── SessionRegistry ───────────────────────────────────────────────────

---Registry encapsulating background sessions and foreground processes.
---Provides a managed interface for session lifecycle (add, get, remove, cleanup).
local SessionRegistry = {}
SessionRegistry.__index = SessionRegistry

function SessionRegistry.new()
  return setmetatable({ bg_sessions = {}, fg_procs = {} }, SessionRegistry)
end

function SessionRegistry:add_bg(session_id, session_data)
  self.bg_sessions[session_id] = session_data
end

function SessionRegistry:get_bg(session_id)
  return self.bg_sessions[session_id]
end

---Remove a background session, closing its timer and fd first.
function SessionRegistry:remove_bg(session_id)
  local session = self.bg_sessions[session_id]
  if session then
    close_timer(session.timer)
    if session.fd then
      pcall(uv.fs_close, session.fd)
    end
    self.bg_sessions[session_id] = nil
  end
end

function SessionRegistry:add_fg(pid, info)
  self.fg_procs[pid] = info
end

function SessionRegistry:remove_fg(pid)
  self.fg_procs[pid] = nil
end

---Kill all running sessions and foreground processes, close fds, remove temp files.
function SessionRegistry:cleanup_all()
  for _, session in pairs(self.bg_sessions) do
    if session.status == STATUS_RUNNING then
      sandbox.kill(session.sandbox_name, session.pid)
    end
    if session.fd then
      pcall(uv.fs_close, session.fd)
    end
    close_timer(session.timer)
    pcall(os.remove, session.file_path)
  end
  for pid, info in pairs(self.fg_procs) do
    sandbox.kill(info.sandbox_name, pid)
    if info.fd then
      pcall(uv.fs_close, info.fd)
    end
    pcall(os.remove, info.file_path)
  end
end

---Generate a unique session ID using timestamp + monotonic counter + random.
function SessionRegistry:gen_session_id()
  self._id_counter = (self._id_counter or 0) + 1
  return fmt("%d-%d-%d", os.time(), self._id_counter, math.random(10000, 99999))
end

local registry = SessionRegistry.new()

-- ── Shared on_exit handler factory ──────────────────────────────────────

---Build an on_exit callback shared by foreground and background execution.
---Conditional kill, fd close, async output read, and cleanup
---are handled here, branching on params.is_bg for mode-specific logic.
---@param params table { sandbox_name, fd, file_path, is_bg, session_id,
---  sandbox_used, timer?, kill_timer?, timed_out?, output_cb?, pid? }
---  params.pid is set after uv.spawn returns.
---@return function on_exit
local function make_on_exit_handler(params)
  return function(code, signal)
    local pid = params.pid

    -- Background: skip if session was already killed by handle_kill
    if params.is_bg then
      local session = registry:get_bg(params.session_id)
      if session and session.status == STATUS_KILLED then
        return
      end
    end

    -- Conditional kill on abnormal exit
    if (signal and signal ~= 0) or code > 128 then
      sandbox.kill(params.sandbox_name, pid)
    end
    pcall(uv.fs_close, params.fd)

    if params.is_bg then
      local session = registry:get_bg(params.session_id)
      if session then
        session.status = STATUS_EXITED
        session.exit_code = code
        -- If timer already fired (process exited after timer callback),
        -- clean up now since timer callback won't run again
        if session.timer_fired then
          pcall(os.remove, session.file_path)
          registry:remove_bg(params.session_id)
        end
      end
    else
      -- Foreground: read output async and send response
      read_file_async(params.file_path, function(_, content)
        content = strip_ansi(content or "")
        pcall(os.remove, params.file_path)
        close_timer(params.timer)
        close_timer(params.kill_timer)
        registry:remove_fg(pid)
        vim.schedule(function()
          local status
          if params.timed_out.value or code ~= 0 or signal ~= 0 then
            status = "error"
          else
            status = "success"
          end
          params.output_cb({
            status = status,
            data = {
              output = content,
              exit_code = code,
              signal = signal,
              timed_out = params.timed_out.value,
              sandbox_active = params.sandbox_used,
            },
          })
        end)
      end)
    end
  end
end

-- ── Handler sub-functions ─────────────────────────────────────────────

---Validate args for the 'run' action.
---@param args table
---@return string|nil error_msg nil on success, error string on failure
local function validate_args(args)
  if not args.cmd or args.cmd == "" then
    return "cmd is required for action='run'"
  end

  local bg_after = tonumber(args.bg_after) or 0
  if bg_after > MAX_BG_AFTER then
    return "bg_after cannot exceed " .. MAX_BG_AFTER .. " seconds"
  end

  local timeout = tonumber(args.timeout) or DEFAULT_TIMEOUT
  if timeout <= 0 then
    return "Timeout must be positive"
  end
  if timeout > MAX_TIMEOUT then
    return "Timeout cannot exceed " .. MAX_TIMEOUT .. " seconds"
  end

  return nil
end

---Handle the 'kill' action: terminate a background session.
---@param session_id string|nil
---@param opts table
local function handle_kill(session_id, opts)
  local session = registry:get_bg(session_id)
  if not session then
    opts.output_cb({
      status = "error",
      data = { error = "session not found: " .. (session_id or "?") },
    })
    return
  end
  if session.status == STATUS_EXITED then
    close_timer(session.timer)
    opts.output_cb({
      status = "success",
      data = {
        kill_info = "already exited",
        exit_code = session.exit_code,
        session_id = session_id,
      },
    })
    return
  end
  -- Session is running: kill the entire process group
  sandbox.kill(session.sandbox_name, session.pid)
  session.status = STATUS_KILLED
  pcall(os.remove, session.file_path)
  registry:remove_bg(session_id)
  opts.output_cb({
    status = "success",
    data = {
      kill_info = "killed",
      session_id = session_id,
      pid = session.pid,
    },
  })
end

---Spawn a command in background mode.
---@param sandbox_opts table|nil Runtime sandbox config
---@param args table Tool args
---@param tools table Tools object
---@param opts table Output opts
local function spawn_background(sandbox_opts, args, tools, opts)
  local use_sandbox = sandbox.should_use(args, sandbox_opts)
  local session_id = registry:gen_session_id()
  local file_path = vim.fn.tempname()
  local sandbox_name = use_sandbox and ("cc-bash-" .. session_id) or nil
  local bg_after = tonumber(args.bg_after) or 0

  local fd = uv.fs_open(file_path, "w", 384)
  if not fd then
    opts.output_cb({
      status = "error",
      data = { output = "fs_open failed: " .. file_path },
    })
    return
  end

  local on_exit_params = {
    sandbox_name = sandbox_name,
    fd = fd,
    file_path = file_path,
    is_bg = true,
    session_id = session_id,
    sandbox_used = use_sandbox,
  }
  local on_exit = make_on_exit_handler(on_exit_params)

  local handle, pid_or_err, sandbox_used
  handle, pid_or_err, sandbox_used = sandbox.run(sandbox_opts, {
    cmd = args.cmd,
    fd = fd,
    file_path = file_path,
    use_sandbox = use_sandbox,
    sandbox_name = sandbox_name,
    on_exit = on_exit,
  })
  on_exit_params.pid = pid_or_err

  if not handle then
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)
    opts.output_cb({
      status = "error",
      data = { output = "spawn failed: " .. tostring(pid_or_err) },
    })
    return
  end

  registry:add_bg(session_id, {
    pid = pid_or_err,
    handle = handle,
    fd = fd,
    file_path = file_path,
    status = STATUS_RUNNING,
    exit_code = nil,
    timer = nil,
    timer_fired = false,
    sandbox_name = sandbox_name,
  })

  local timer = uv.new_timer()
  registry:get_bg(session_id).timer = timer

  local bg_after_ms = bg_after * 1000
  timer:start(bg_after_ms, 0, function()
    local session = registry:get_bg(session_id)
    if not session or session.status == STATUS_KILLED then
      return
    end
    session.timer_fired = true
    if session.status == STATUS_EXITED then
      -- Process exited before timer fired: read full output and report
      local exit_code = session.exit_code
      local fp = session.file_path
      read_file_async(fp, function(_, content)
        content = strip_ansi(content or "")
        -- Clean up session resources
        pcall(os.remove, fp)
        registry:remove_bg(session_id)
        vim.schedule(function()
          opts.output_cb({
            status = exit_code == 0 and "success" or "error",
            data = {
              output = content,
              exit_code = exit_code,
              bg_exited = true,
              session_id = session_id,
              file_path = fp,
              sandbox_active = sandbox_used,
            },
          })
        end)
      end)
    else
      read_file_async(session.file_path, function(_, content)
        content = strip_ansi(content or "")
        vim.schedule(function()
          opts.output_cb({
            status = "success",
            data = {
              output = content,
              session_id = session_id,
              file_path = session.file_path,
              bg_running = true,
              pid = pid_or_err,
              sandbox_active = sandbox_used,
            },
          })
        end)
      end)
    end
  end)
end

---Spawn a command in foreground mode.
---@param sandbox_opts table|nil Runtime sandbox config
---@param args table Tool args
---@param tools table Tools object
---@param opts table Output opts
local function spawn_foreground(sandbox_opts, args, tools, opts)
  local use_sandbox = sandbox.should_use(args, sandbox_opts)
  local session_id = registry:gen_session_id()
  local file_path = vim.fn.tempname()
  local sandbox_name = use_sandbox and ("cc-bash-" .. session_id) or nil
  local timeout = tonumber(args.timeout) or DEFAULT_TIMEOUT
  local timeout_ms = timeout * 1000

  local fd = uv.fs_open(file_path, "w", 384)
  if not fd then
    opts.output_cb({
      status = "error",
      data = { output = "fs_open failed: " .. file_path },
    })
    return
  end

  local timed_out = { value = false }
  local timer = uv.new_timer()
  local kill_timer = uv.new_timer()

  local on_exit_params = {
    sandbox_name = sandbox_name,
    fd = fd,
    file_path = file_path,
    is_bg = false,
    sandbox_used = use_sandbox,
    timer = timer,
    kill_timer = kill_timer,
    timed_out = timed_out,
    output_cb = opts.output_cb,
  }
  local on_exit = make_on_exit_handler(on_exit_params)

  local handle, pid_or_err, sandbox_used
  handle, pid_or_err, sandbox_used = sandbox.run(sandbox_opts, {
    cmd = args.cmd,
    fd = fd,
    file_path = file_path,
    use_sandbox = use_sandbox,
    sandbox_name = sandbox_name,
    on_exit = on_exit,
  })
  on_exit_params.pid = pid_or_err

  if not handle then
    close_timer(timer)
    close_timer(kill_timer)
    pcall(uv.fs_close, fd)
    pcall(os.remove, file_path)
    opts.output_cb({
      status = "error",
      data = { output = "spawn failed: " .. tostring(pid_or_err) },
    })
    return
  end

  registry:add_fg(pid_or_err, { file_path = file_path, fd = fd, sandbox_name = sandbox_name })

  timer:start(timeout_ms, 0, function()
    timed_out.value = true
    if sandbox_name then
      -- Sandbox: sandlock kill handles full cleanup
      sandbox.kill(sandbox_name, pid_or_err)
    else
      -- Non-sandbox: two-stage SIGTERM → SIGKILL
      pcall(uv.kill, -pid_or_err, "sigterm")
      kill_timer:start(2000, 0, function()
        pcall(uv.kill, -pid_or_err, "sigkill")
      end)
    end
  end)
end

local M = {}

---Create a tool definition table
---@param sandbox_opts table|nil Sandbox config subtable
---@return table tool_definition
function M.create(sandbox_opts)
  local sandbox_available = sandbox.is_available(sandbox_opts)

  -- ── Dynamic schema ────────────────────────────────────────────────

  local props = {
    cmd = {
      type = "string",
      description = "Bash command to execute. Multi-line, pipes, redirects OK. Required when action is 'run'.",
    },
    action = {
      type = "string",
      enum = { "run", "kill" },
      description = "Action to perform. 'run' (default): execute command. 'kill': terminate a background session.",
    },
    session_id = {
      type = "string",
      description = "Background session ID to kill. Required when action is 'kill'.",
    },
    bg_after = {
      type = "integer",
      description = "Background mode wait time in seconds. <=0: foreground (default). >0: run detached, tool returns after this many seconds with partial output + session_id + output file path. Max 60.",
    },
    timeout = {
      type = "integer",
      description = "Timeout in seconds (foreground only, ignored when bg_after>0). Default 300, max 3600.",
    },
  }
  if sandbox_available then
    props.skip_sandbox = {
      type = "boolean",
      description = "Set true to skip sandbox, run directly (needs approval). Use only when sandbox blocks legitimate work.",
    }
  end

  local schema = {
    type = "function",
    ["function"] = {
      name = "run_bash",
      description = sandbox_available
          and "Execute a Bash command. Sandboxed by default (sandlock). Supports foreground and background execution."
        or "Execute a Bash command.",
      parameters = {
        type = "object",
        properties = props,
        required = {},
        additionalProperties = false,
      },
    },
  }

  -- ── Dynamic system_prompt ─────────────────────────────────────────

  local shared_prompt_body =
    [[Output: merged stdout+stderr (interleaved by time). Exit code reported on failure.

ANSI color codes auto-stripped from output.

Timeout: default 300s. Set `"timeout"` (max 3600s) for long commands. Foreground only.

Background mode (`"bg_after"` > 0): runs command detached. Tool waits `bg_after` seconds (max 60) for startup output, then returns partial output + `session_id` + output file path. Read the file later for ongoing output. Kill with `{"action": "kill", "session_id": "..."}`.

Safety:
- Do NOT run destructive commands: rm -rf, format disks, modify system configs.
- Do NOT install software (pip install, npm install -g, apt-get).
- Do NOT download from untrusted URLs.
- Prefer read-only operations. Write only within the project workspace.
]]

  local system_prompt
  if sandbox_available then
    system_prompt = [[# run_bash — Execute Bash commands

Runs bash commands. Sandboxed by default (sandlock: Landlock + seccomp).

Sandbox mode (default): auto-approved unless the command matches a blocklist rule (rm -rf, git reset --hard, etc.). Blocklisted commands require user approval.
- Sandbox may block file access outside allowed paths or dangerous syscalls.
- If command fails with permission errors or exit code > 128, retry with `"skip_sandbox": true`.

Non-sandbox (`"skip_sandbox": true`): always requires user approval. Only when sandbox blocks legitimate work.

]] .. shared_prompt_body
  else
    system_prompt = [[# run_bash — Execute Bash commands

Runs bash commands. Requires user approval for all commands.

]] .. shared_prompt_body
  end

  -- ── cmds handler ──────────────────────────────────────────────────

  local handler = function(tools, args, opts)
    local action = args.action or "run"

    if action == "kill" then
      handle_kill(args.session_id, opts)
      return
    end

    if action ~= "run" then
      opts.output_cb({
        status = "error",
        data = { error = "unknown action: " .. tostring(action) },
      })
      return
    end

    local err = validate_args(args)
    if err then
      opts.output_cb({
        status = "error",
        data = { error = err },
      })
      return
    end

    local runtime_sandbox_opts = tools.tool.opts and tools.tool.opts.sandbox
    local bg_after = tonumber(args.bg_after) or 0

    if bg_after > 0 then
      spawn_background(runtime_sandbox_opts, args, tools, opts)
    else
      spawn_foreground(runtime_sandbox_opts, args, tools, opts)
    end
  end

  -- ── Output handlers ───────────────────────────────────────────────

  local output = {
    cmd_string = function(self, meta)
      if self.args.action == "kill" then
        return ("kill session %s"):format(self.args.session_id or "?")
      end
      return self.args.cmd
    end,

    prompt = function(self, meta)
      if self.args.action == "kill" then
        return ("Kill background session %s?"):format(self.args.session_id or "?")
      end
      local cmd = self.args.cmd
      return ("Run the following Bash command?\n````bash\n%s\n````"):format(cmd)
    end,

    success = function(self, data, meta)
      local d = data and data[1] or data

      if d.kill_info then
        if d.kill_info == "already exited" then
          return meta.tools.chat:add_tool_output(
            self,
            fmt("Session %s already exited (code: %s).", d.session_id or "?", d.exit_code or "?")
          )
        end
        return meta.tools.chat:add_tool_output(
          self,
          fmt("Killed background session %s (PID %d).", d.session_id, d.pid)
        )
      end

      if d.bg_running then
        local sandbox_note = d.sandbox_active
            and 'Sandbox active. If result suggests sandbox interference, retry with `"skip_sandbox": true`.\n'
          or ""
        local message = fmt(
          'Background command started.\n%sSession ID: %s\nOutput file: %s\nKill with: {"action": "kill", "session_id": "%s"}\n\nPartial output:\n\n%s',
          sandbox_note,
          d.session_id,
          d.file_path,
          d.session_id,
          d.output
        )
        local user_msg = fmt(
          [[Background command started: `%s`
Session: %s | PID: %d | File: %s
````
%s
````
]],
          self.args.cmd,
          d.session_id,
          d.pid,
          d.file_path,
          d.output
        )
        return meta.tools.chat:add_tool_output(self, message, user_msg)
      end

      -- Foreground success / bg_exited success
      local out = d.output or "(no output)"
      local sandbox_note = d.sandbox_active
          and 'Sandbox active. If result suggests sandbox interference, retry with `"skip_sandbox": true`.\n'
        or ""
      local message = fmt("Success.\n%sOutput:\n\n%s", sandbox_note, out)
      local user_msg = fmt(
        [[Bash command success: `%s`
Sandbox: %s
````
%s
````
]],
        self.args.cmd,
        d.sandbox_active and "YES" or "NO",
        out
      )
      return meta.tools.chat:add_tool_output(self, message, user_msg)
    end,

    error = function(self, data, meta)
      local d = data and data[1] or data

      if d.error then
        return meta.tools.chat:add_tool_output(self, d.error)
      end

      local out = d.output or "unknown error"
      local timed_out_note = d.timed_out and " (timed out)" or ""
      local sandbox_note = d.sandbox_active
          and 'Sandbox active. If result suggests sandbox interference, retry with `"skip_sandbox": true`.\n'
        or ""
      local message = fmt(
        "Failed (exit: %s)%s.\n%sOutput:\n\n%s",
        d.exit_code or "UNKNOWN",
        timed_out_note,
        sandbox_note,
        out
      )
      local user_msg = fmt(
        [[Bash command failed (exit: %s)%s: `%s`
Sandbox: %s
````
%s
````
]],
        d.exit_code or "UNKNOWN",
        timed_out_note,
        self.args.cmd,
        d.sandbox_active and "YES" or "NO",
        out
      )
      return meta.tools.chat:add_tool_output(self, message, user_msg)
    end,

    rejected = function(self, meta)
      return meta.tools.chat:add_tool_output(
        self,
        "User rejected: " .. (meta.opts.reason or "no reason given")
      )
    end,
  }

  return {
    name = "run_bash",
    description = "Execute a Bash command. Sandboxed by default (sandlock).",
    cmds = { handler },
    schema = schema,
    system_prompt = system_prompt,
    output = output,
  }
end

---Cleanup function for VimLeavePre
---Kills all background sessions and foreground processes, closes fds, removes temp files
function M.cleanup()
  registry:cleanup_all()
end

return M
