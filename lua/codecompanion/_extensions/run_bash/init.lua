---@brief
---
--- Extension entry for run_bash CodeCompanion extension.
--- Handles setup(), configuration merging, and tool registration.

local checker = require("codecompanion._extensions.run_bash.checker")
local sandbox = require("codecompanion._extensions.run_bash.sandbox")
local tool = require("codecompanion._extensions.run_bash.tool")

local M = {}

---Flag to ensure autocmd is only registered once per session
local vimleave_registered = false

---Store the checker instance for approval decisions
local checker_instance = nil

---CodeCompanion config module name. Single point of update if the host
---plugin renames its config module.
local CC_CONFIG_MODULE = "codecompanion.config"

---Safely resolve the tools config table from CodeCompanion's config.
---Returns nil and notifies the user if the path is unavailable due to
---host plugin refactoring.
---@return table|nil
local function get_tools_config()
  local ok, config = pcall(require, CC_CONFIG_MODULE)
  if not ok or type(config) ~= "table" then
    vim.notify("run_bash: unable to load codecompanion.config module", vim.log.levels.ERROR)
    return nil
  end
  local tools = vim.tbl_get(config, "interactions", "chat", "tools")
  if type(tools) ~= "table" then
    vim.notify(
      "run_bash: config.interactions.chat.tools not found — CodeCompanion config path may have changed",
      vim.log.levels.ERROR
    )
    return nil
  end
  return tools
end

---Setup the run_bash extension
---@param opts table Configuration options
---@param opts.sandbox? table Sandbox configuration: { enabled, profile, rules }
---@param opts.blocklist? table Blocklist overrides: { cmd = true|false|fun(args): boolean }
function M.setup(opts)
  opts = opts or {}

  -- Merge blocklist: user opts override defaults
  local merged_blocklist = vim.tbl_deep_extend("force", checker.defaults, opts.blocklist or {})

  -- Create checker instance
  checker_instance = checker.new(merged_blocklist)

  -- Merge sandbox defaults: user opts override defaults
  local sandbox_opts = vim.tbl_deep_extend("force", sandbox.defaults, opts.sandbox or {})

  -- Register tool in tools_config
  local tools_config = get_tools_config()
  if not tools_config then
    return
  end
  tools_config.run_bash = {
    callback = function()
      return tool.create(sandbox_opts)
    end,
    description = "Execute a Bash command. Sandboxed by default (sandlock).",
    opts = {
      sandbox = sandbox_opts,
      require_cmd_approval = true,
      allowed_in_yolo_mode = false,
      require_approval_before = function(tool_obj, tools)
        -- kill action always auto-approved
        if tool_obj.args.action == "kill" then
          return false
        end

        -- Determine sandbox mode from runtime opts (merged by orchestrator)
        local s_opts = tool_obj.opts and tool_obj.opts.sandbox
        local use_sandbox = sandbox.should_use(tool_obj.args, s_opts)

        if not use_sandbox then
          -- Non-sandbox mode: always requires approval
          return true
        end

        -- Sandbox mode: check blocklist
        return checker_instance:check_require_approval(tool_obj.args.cmd)
      end,
    },
  }

  -- Register VimLeavePre autocmd (only once)
  if not vimleave_registered then
    vimleave_registered = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        tool.cleanup()
      end,
    })
  end

  -- Check bash treesitter parser
  local ok, parser_or_err = pcall(vim.treesitter.get_string_parser, "", "bash")
  if not ok then
    vim.notify(
      "run_bash: bash treesitter parser not found ("
        .. tostring(parser_or_err)
        .. "). All sandbox commands will require approval.",
      vim.log.levels.WARN
    )
  end
end

return M
