--[[
Test: run_bash — Integration Tests (Chat-path)

Intent: Verify the full CodeCompanion chat → run_bash → sandbox → command
pipeline end-to-end, mocking only the LLM Adapter.

]]

local Helpers = require("tests.helpers")
local T = MiniTest.new_set()

-- Helper to extract concatenated content from all tool output messages.
-- Used only by multi-round tests that need full message history.
local function extract_output_content(messages)
  local contents = {}
  for _, msg in ipairs(messages) do
    table.insert(contents, msg.content)
  end
  return table.concat(contents, "\n")
end

-- ── Simple single-round tests (10 tests) ─────────────────────────

T["integration: foreground echo hello succeeds"] = function()
  -- Intent: Verify a simple foreground command produces expected output
  -- through the full Chat → run_bash → sandbox pipeline (non-sandbox mode).
  Helpers.run_simple_chat_test({
    sandbox_opts = { sandbox = { enabled = false } },
    pre_approve = "echo hello",
    tool_args = { cmd = "echo hello" },
    expected_contains = { "hello" },
  })
end

T["integration: foreground false reports failure with exit code"] = function()
  -- Intent: Verify a failing foreground command reports error status with
  -- exit code in the chat output (non-sandbox mode).
  Helpers.run_simple_chat_test({
    sandbox_opts = { sandbox = { enabled = false } },
    pre_approve = "false",
    tool_args = { cmd = "false" },
    expected_contains = { "Failed", "(exit:" },
  })
end

T["integration: timeout kills long-running command"] = function()
  -- Intent: Verify that a foreground command exceeding its timeout is
  -- killed and the output reports the timeout (non-sandbox mode).
  Helpers.run_simple_chat_test({
    sandbox_opts = { sandbox = { enabled = false } },
    pre_approve = "sleep 10",
    tool_args = { cmd = "sleep 10", timeout = 1 },
    expected_contains = { "timed out" },
    timeout = 5000,
  })
end

T["integration: background natural exit reports full output"] = function()
  -- Intent: Verify a quick background command that exits naturally
  -- reports its full output in the chat (non-sandbox mode).
  Helpers.run_simple_chat_test({
    sandbox_opts = { sandbox = { enabled = false } },
    pre_approve = "echo done",
    tool_args = { cmd = "echo done", bg_after = 2 },
    expected_contains = { "done" },
  })
end

T["integration: safe command auto-approved in sandbox"] = function()
  -- Intent: Verify a safe command (not in blocklist) in sandbox mode
  -- is auto-approved and produces sandbox active output.
  Helpers.run_simple_chat_test({
    sandbox_opts = {
      sandbox = { enabled = true, profile = Helpers.sandbox_profile_path(), rules = {} },
    },
    tool_args = { cmd = "echo safe" },
    expected_contains = { "safe", Helpers.SANDBOX_ACTIVE },
  })
end

T["integration: blocklisted command user accepts"] = function()
  -- Intent: Verify that a blocklisted command in sandbox mode, when accepted
  -- by the user, executes successfully with sandbox active output.
  Helpers.run_simple_chat_test({
    sandbox_opts = {
      sandbox = { enabled = true, profile = Helpers.sandbox_profile_path(), rules = {} },
    },
    mock_approval = "Accept",
    tool_args = { cmd = "rm -rf /tmp/cc-test-nonexistent" },
    expected_contains = { Helpers.SANDBOX_ACTIVE },
  })
end

T["integration: blocklisted command user rejects"] = function()
  -- Intent: Verify that a blocklisted command in sandbox mode, when rejected
  -- by the user, produces a "User rejected" message in the chat output.
  Helpers.run_simple_chat_test({
    sandbox_opts = {
      sandbox = { enabled = true, profile = Helpers.sandbox_profile_path(), rules = {} },
    },
    mock_approval = "Reject",
    ui_input_stub = [[vim.ui.input = function(_, cb) cb("test rejection") end]],
    tool_args = { cmd = "rm -rf /tmp/cc-test-nonexistent" },
    expected_contains = { "User rejected" },
  })
end

T["integration: sandbox executes command under sandbox"] = function()
  -- Intent: Verify that a pre-approved command in sandbox mode runs
  -- under sandbox and produces sandbox active output.
  Helpers.run_simple_chat_test({
    sandbox_opts = {
      sandbox = { enabled = true, profile = Helpers.sandbox_profile_path(), rules = {} },
    },
    pre_approve = "echo sandboxed",
    tool_args = { cmd = "echo sandboxed" },
    expected_contains = { "sandboxed", Helpers.SANDBOX_ACTIVE },
  })
end

T["integration: skip_sandbox triggers approval then bypasses sandbox"] = function()
  -- Intent: Verify that skip_sandbox=true forces the approval prompt
  -- and bypasses the sandbox (no sandbox active in output).
  Helpers.run_simple_chat_test({
    sandbox_opts = {
      sandbox = { enabled = true, profile = Helpers.sandbox_profile_path(), rules = {} },
    },
    mock_approval = "Accept",
    tool_args = { cmd = "echo no-sandbox", skip_sandbox = true },
    expected_contains = { "no-sandbox" },
    expected_not_contains = { Helpers.SANDBOX_ACTIVE },
  })
end

T["integration: fallback when profile missing triggers approval"] = function()
  -- Intent: Verify that when the sandlock profile is missing, the system
  -- falls back to requiring approval and runs without sandbox.
  Helpers.run_simple_chat_test({
    sandbox_opts = {
      sandbox = { enabled = true, profile = "/nonexistent/profile.toml", rules = {} },
    },
    mock_approval = "Accept",
    tool_args = { cmd = "echo fallback" },
    expected_contains = { "fallback" },
    expected_not_contains = { Helpers.SANDBOX_ACTIVE },
  })
end

-- ── Multi-round tests (4 tests) ──────────────────────────────────

T["integration: background mode returns session_id"] = function()
  -- Intent: Verify that a background command returns a session_id
  -- in the initial output and the session can be killed in a second round.
  local child = MiniTest.new_child_neovim()
  Helpers.child_start(child)
  Helpers.setup_chat_with_run_bash(child, { sandbox = { enabled = false } })
  Helpers.pre_approve_cmd(child, "echo STARTING; sleep 10")
  Helpers.queue_tool_call_response(child, {
    {
      ["function"] = {
        name = "run_bash",
        arguments = { cmd = "echo STARTING; sleep 10", bg_after = 1 },
      },
      id = "call_1",
    },
  })
  child.lua(
    [[ local chat = _G._test_chat; chat:add_buf_message({ role = "user", content = "Run background command" }); chat:submit() ]]
  )
  local ok = Helpers.wait_for_tool_output(child)
  MiniTest.expect.equality(true, ok, "Tool output should appear within timeout")
  local messages = Helpers.get_tool_output_messages(child)
  local content = extract_output_content(messages)
  Helpers.expect_contains("STARTING", content)
  -- Extract session_id and kill
  local session_id = content:match("Session ID: (%S+)")
  MiniTest.expect.equality(true, session_id ~= nil, "Should have session_id")
  if session_id then
    Helpers.queue_tool_call_response(child, {
      {
        ["function"] = {
          name = "run_bash",
          arguments = { action = "kill", session_id = session_id },
        },
        id = "call_2",
      },
    })
    child.lua(
      [[ local chat = _G._test_chat; chat:add_buf_message({ role = "user", content = "Kill session" }); chat:submit() ]]
    )
    Helpers.wait_for_new_tool_output(child)
  end
  child.stop()
end

T["integration: background kill via action=kill"] = function()
  -- Intent: Verify that a running background command can be killed
  -- via action=kill, and the kill output is reported in the latest message.
  local child = MiniTest.new_child_neovim()
  Helpers.child_start(child)
  Helpers.setup_chat_with_run_bash(child, { sandbox = { enabled = false } })
  -- Round 1: Start background command
  Helpers.pre_approve_cmd(child, "sleep 100")
  Helpers.queue_tool_call_response(child, {
    {
      ["function"] = { name = "run_bash", arguments = { cmd = "sleep 100", bg_after = 1 } },
      id = "call_1",
    },
  })
  child.lua(
    [[ local chat = _G._test_chat; chat:add_buf_message({ role = "user", content = "Start background sleep" }); chat:submit() ]]
  )
  local ok = Helpers.wait_for_tool_output(child)
  MiniTest.expect.equality(true, ok, "Tool output should appear within timeout")
  local messages = Helpers.get_tool_output_messages(child)
  local content = extract_output_content(messages)
  local session_id = content:match("Session ID: (%S+)")
  MiniTest.expect.equality(true, session_id ~= nil, "Should have session_id")
  -- Round 2: Kill the session (kill is synchronous — message added inside submit)
  if session_id then
    -- Count tool messages before submit to verify new output later
    local before_count = child.lua([[local chat = _G._test_chat; local n = 0
      for _, m in ipairs(chat.messages) do
        if m.role == 'tool' and m.content and m.content ~= '' then n = n + 1 end
      end; return n]])
    Helpers.queue_tool_call_response(child, {
      {
        ["function"] = {
          name = "run_bash",
          arguments = { action = "kill", session_id = session_id },
        },
        id = "call_2",
      },
    })
    child.lua(
      [[ local chat = _G._test_chat; chat:add_buf_message({ role = "user", content = "Kill the background session" }); chat:submit() ]]
    )
    MiniTest.expect.equality(true, child.lua([[local chat = _G._test_chat; local n = 0
        for _, m in ipairs(chat.messages) do
          if m.role == 'tool' and m.content and m.content ~= '' then n = n + 1 end
        end; return n]]) > before_count, "Kill should produce a new tool message")
    local content2 = Helpers.get_latest_tool_output_content(child)
    Helpers.expect_contains("Killed", content2)
  end
  child.stop()
end

T["integration: blocklisted command always accept cached on second call"] = function()
  -- Intent: Verify that "Always accept" caches the approval decision:
  -- the mock approval is called only once across two tool calls.
  Helpers.require_sandbox()
  local child = MiniTest.new_child_neovim()
  Helpers.child_start(child)
  Helpers.mock_approval_prompt(child)
  Helpers.set_approval_choice(child, "Always accept")
  local profile = Helpers.sandbox_profile_path()
  Helpers.setup_chat_with_run_bash(
    child,
    { sandbox = { enabled = true, profile = profile, rules = {} } }
  )
  -- Round 1
  Helpers.queue_tool_call_response(child, {
    {
      ["function"] = { name = "run_bash", arguments = { cmd = "rm -rf /tmp/cc-test-nonexistent" } },
      id = "call_1",
    },
  })
  child.lua(
    [[ local chat = _G._test_chat; chat:add_buf_message({ role = "user", content = "Run rm -rf first time" }); chat:submit() ]]
  )
  local ok = Helpers.wait_for_new_tool_output(child)
  MiniTest.expect.equality(true, ok, "First tool output should appear within timeout")
  Helpers.expect_tool_output_contains(child, Helpers.SANDBOX_ACTIVE)
  -- Round 2
  Helpers.queue_tool_call_response(child, {
    {
      ["function"] = { name = "run_bash", arguments = { cmd = "rm -rf /tmp/cc-test-nonexistent" } },
      id = "call_2",
    },
  })
  child.lua(
    [[ local chat = _G._test_chat; chat:add_buf_message({ role = "user", content = "Run rm -rf second time" }); chat:submit() ]]
  )
  ok = Helpers.wait_for_new_tool_output(child)
  MiniTest.expect.equality(true, ok, "Second tool output should appear within timeout")
  Helpers.expect_tool_output_contains(child, Helpers.SANDBOX_ACTIVE)
  MiniTest.expect.equality(
    1,
    child.lua([[return _G._mock_approval_call_count]]),
    "Mock approval should be called once (cached on second call)"
  )
  child.stop()
end

T["integration: write to denied path blocked by sandbox"] = function()
  -- Intent: Verify that writing to a path denied by the sandlock profile
  -- produces a permission error with sandbox active in the output.
  Helpers.require_sandbox()
  local test_dir = "/tmp/cc-run-bash-test-deny"
  vim.fn.mkdir(test_dir, "p")
  local child = MiniTest.new_child_neovim()
  Helpers.child_start(child)
  local profile = Helpers.sandbox_profile_path()
  Helpers.setup_chat_with_run_bash(
    child,
    { sandbox = { enabled = true, profile = profile, rules = {} } }
  )
  Helpers.pre_approve_cmd(
    child,
    "mkdir -p /tmp/cc-run-bash-test-deny; touch /tmp/cc-run-bash-test-deny/test 2>&1"
  )
  Helpers.queue_tool_call_response(child, {
    {
      ["function"] = {
        name = "run_bash",
        arguments = {
          cmd = "mkdir -p /tmp/cc-run-bash-test-deny; touch /tmp/cc-run-bash-test-deny/test 2>&1",
        },
      },
      id = "call_1",
    },
  })
  child.lua(
    [[ local chat = _G._test_chat; chat:add_buf_message({ role = "user", content = "Try to write to denied path" }); chat:submit() ]]
  )
  local ok = Helpers.wait_for_tool_output(child)
  MiniTest.expect.equality(true, ok, "Tool output should appear within timeout")
  local messages = Helpers.get_tool_output_messages(child)
  local content = extract_output_content(messages)
  MiniTest.expect.equality(
    true,
    content:find("Permission denied") ~= nil
      or content:find("Operation not permitted") ~= nil
      or content:find("Failed") ~= nil,
    "Should contain permission error or failure status"
  )
  Helpers.expect_contains(Helpers.SANDBOX_ACTIVE, content)
  pcall(vim.fn.delete, test_dir, "rf")
  child.stop()
end

return T
