-- Test helpers for mini.test
local Helpers = {}

-- Extend with expectations
Helpers = vim.tbl_extend("error", Helpers, require("tests.expectations"))

---Start a child Neovim process for testing
---@param child table MiniTest child neovim instance
function Helpers.child_start(child)
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.o.statusline = ""
  child.o.laststatus = 0
  child.o.cmdheight = 0
end

---Setup codecompanion in child process
---@param child table
---@param config? table Optional config overrides to merge with base test config
function Helpers.setup_codecompanion(child, config)
  config = config or {}
  child.lua(
    [[
    local overrides = ...
    local config = require("tests.config")
    if overrides and next(overrides) ~= nil then
      config = vim.tbl_deep_extend("force", config, overrides)
    end
    require("codecompanion").setup(config)
  ]],
    { config }
  )
end

---Create a temporary directory
---@return string path
function Helpers.temp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---Clean up a directory
---@param path string
function Helpers.cleanup_dir(path)
  if path and vim.uv.fs_stat(path) then
    vim.fn.delete(path, "rf")
  end
end

---Setup mock HTTP client in child process
---@param child table MiniTest child neovim instance
---@param adapter? string Adapter variable name in child process (default: "_G.mock_adapter")
---@return nil
function Helpers.mock_http(child, adapter)
  adapter = adapter or "_G.mock_adapter"
  local project_root = vim.fn.getcwd()
  local cc_path_lua = project_root .. "/deps/codecompanion.nvim/?.lua"
  local cc_path_init = project_root .. "/deps/codecompanion.nvim/?/init.lua"

  child.lua(string.format(
    [[
    package.path = package.path .. ";" .. %q .. ";" .. %q

    local mock_client = require("tests.mocks.http").new({ adapter = %s })
    _G.mock_client = mock_client
    package.loaded["codecompanion.http"] = {
      new = function()
        return _G.mock_client
      end,
    }
  ]],
    cc_path_lua,
    cc_path_init,
    adapter
  ))
end

---Queue a mock HTTP response
---@param child table MiniTest child neovim instance
---@param response table The response to queue
---@return nil
function Helpers.queue_mock_http_response(child, response)
  child.lua([[_G.mock_client:queue_response(...)]], { response })
end

---Setup a chat buffer with run_bash tools for integration testing
---@param child table MiniTest child neovim instance
---@param opts? table Optional config: { sandbox?: table, blocklist?: table }
---@return string chat_var The variable name where chat is stored ("_G._test_chat")
function Helpers.setup_chat_with_run_bash(child, opts)
  opts = opts or {}

  -- Define adapter inline in child process (functions can't cross process boundary)
  child.lua(
    [[
    local sandbox_opts, blocklist_opts = ...

    -- Define custom adapter for tool_calls
    local adapter = {
      name = "test_adapter_for_run_bash",
      formatted_name = "Test Adapter for run_bash",
      type = "http",
      url = "http://test.local",
      roles = { llm = "assistant", user = "user" },
      features = { tools = true },
      opts = { stream = false },
      schema = { model = { default = "test-model" } },
      handlers = {
        response = {
          parse_chat = function(self, data, tools)
            for _, tool in ipairs(data.tools or {}) do
              table.insert(tools, tool)
            end
            return {
              status = "success",
              output = { role = "assistant", content = data.content or "" },
            }
          end,
        },
        tools = {
          format_calls = function(self, tools)
            return tools
          end,
          format_response = function(self, tool_call, output)
            return {
              role = "tool",
              tools = { call_id = tool_call.id },
              content = output,
              _meta = { tag = tool_call.id },
              opts = { visible = false },
            }
          end,
        },
      },
    }

    -- Setup CodeCompanion with run_bash extension
    local config = require("tests.config")
    config.adapters.http[adapter.name] = adapter
    config.extensions = config.extensions or {}
    config.extensions.run_bash = {
      opts = {
        sandbox = sandbox_opts,
        blocklist = blocklist_opts,
      },
    }
    require("codecompanion").setup(config)

    -- Create chat buffer
    local Chat = require("codecompanion.interactions.chat")
    local adapters = require("codecompanion.adapters")
    local resolved_adapter = adapters.resolve(adapter.name)

    local chat = Chat.new({
      adapter = resolved_adapter,
      buffer_context = { bufnr = 1, filetype = "lua" },
    })

    -- Register run_bash tool to tool_registry
    local tools_config = require("codecompanion.config").interactions.chat.tools
    local tool_cfg = tools_config["run_bash"]
    if tool_cfg then
      chat.tool_registry:add_single_tool("run_bash", { config = tool_cfg, visible = false })
    end

    _G._test_chat = chat
  ]],
    { opts.sandbox, opts.blocklist }
  )

  -- Mock HTTP client
  Helpers.mock_http(child, "_G._test_chat.adapter")

  return "_G._test_chat"
end

---Queue a mock HTTP response containing tool_calls
---@param child table MiniTest child neovim instance
---@param tool_calls table[] Array of tool call objects: { ["function"] = { name, arguments }, id?, type? }
---@param content? string Optional content string (default: "I'll use the tool")
---@return nil
function Helpers.queue_tool_call_response(child, tool_calls, content)
  local response = {
    content = content or "I'll use the tool",
    tools = tool_calls,
  }
  Helpers.queue_mock_http_response(child, response)
end

---Wait for tool execution to complete
---@param child table MiniTest child neovim instance
---@param chat_var? string Chat variable name (default: "_G._test_chat")
---@param timeout? number Timeout in milliseconds (default: 2000)
---@return boolean success Whether the wait completed successfully
function Helpers.wait_for_tool_completion(child, chat_var, timeout)
  chat_var = chat_var or "_G._test_chat"
  timeout = timeout or 2000

  return child.lua(string.format(
    [[
    local chat = %s
    return vim.wait(%d, function()
      return vim.bo[chat.bufnr].modifiable
    end)
  ]],
    chat_var,
    timeout
  ))
end

---Get tool output messages from chat
---@param child table MiniTest child neovim instance
---@param chat_var? string Chat variable name (default: "_G._test_chat")
---@return table[] messages List of messages with { content } format
function Helpers.get_tool_output_messages(child, chat_var)
  chat_var = chat_var or "_G._test_chat"

  return child.lua(string.format(
    [[
    local chat = %s
    if not chat or not chat.messages then
      return {}
    end

    local result = {}
    for _, msg in ipairs(chat.messages) do
      if msg.role == "tool" then
        table.insert(result, { content = msg.content or "" })
      end
    end
    return result
  ]],
    chat_var
  )) or {}
end

---Resolve the sandbox profile path for tests.
---Uses the in-repo profile bound to the test suite.
---@return string
function Helpers.sandbox_profile_path()
  return vim.fn.getcwd() .. "/tests/sandlock_profile.toml"
end

---Unwrap callback output data from tool handler.
---Handles both direct { data = {...} } and array-wrapped { data = { [1] = {...} } } formats.
---@param output_data table|nil
---@return table|nil
function Helpers.unwrap_cb_data(output_data)
  if not output_data then
    return nil
  end
  return output_data.data and output_data.data[1] or output_data.data or output_data
end

---Require sandbox environment for test.
---When SKIP_SANDBOX_TESTS=1, always skip. Otherwise enforce availability.
function Helpers.require_sandbox()
  if os.getenv("SKIP_SANDBOX_TESTS") == "1" then
    MiniTest.skip("SKIP_SANDBOX_TESTS is set")
    return
  end
  if
    vim.fn.executable("sandlock") ~= 1 or vim.uv.fs_stat(Helpers.sandbox_profile_path()) == nil
  then
    error("sandlock or profile not available; set SKIP_SANDBOX_TESTS=1 to skip sandbox tests")
  end
end

return Helpers
