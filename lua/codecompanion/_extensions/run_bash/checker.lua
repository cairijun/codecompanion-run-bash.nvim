---@brief
---
--- Pause list checker for run_bash extension.
--- Uses treesitter to parse bash commands and check them against pause list rules.
---
--- Interface:
---   checker.new(pauselist_rules) -> checker_instance
---   checker_instance:check_require_approval(cmd_string) -> boolean
---
--- Rule value semantics:
---   true          → always block
---   false         → never block (disable rule)
---   function(args) → boolean  → custom check (true = block, false = allow)
---   nil           → not in pause list (allow)

local M = {}

---Strip surrounding quotes from a string
---@param s string
---@return string
local function strip_quotes(s)
  if type(s) ~= "string" or #s < 2 then
    return s
  end
  -- $'...' (ANSI-C quoting)
  if s:sub(1, 2) == "$'" and s:sub(-1) == "'" then
    return s:sub(3, -2)
  end
  -- '...' or "..."
  local first, last = s:sub(1, 1), s:sub(-1)
  if (first == "'" and last == "'") or (first == '"' and last == '"') then
    return s:sub(2, -2)
  end
  return s
end

---Check if args contain a short flag (e.g. -rf, -fr, -fd, -df)
---Looks for combined short flags and returns which flags were found
---@param args string[]
---@return { r: boolean, f: boolean, d: boolean }
local function check_short_flags(args)
  local result = { r = false, f = false, d = false }
  for _, arg in ipairs(args or {}) do
    -- Only inspect single-dash flags (skip --long-flags)
    if arg:match("^%-[^-]") then
      local flags = arg:sub(2)
      if flags:match("[rR]") then
        result.r = true
      end
      if flags:match("[fF]") then
        result.f = true
      end
      if flags:match("[dD]") then
        result.d = true
      end
    end
  end
  return result
end

---Check if args contain a long flag
---@param args string[]
---@param flag string e.g. "--recursive", "--force"
---@return boolean
local function has_long_flag(args, flag)
  for _, arg in ipairs(args or {}) do
    if arg == flag then
      return true
    end
  end
  return false
end

---Get the first non-flag argument
---@param args string[]
---@return string|nil
local function first_non_flag_arg(args)
  for i, arg in ipairs(args or {}) do
    if not arg:match("^%-") then
      return arg, i
    end
  end
end

---Proxy commands that wrap other commands
local PROXY_COMMANDS = {
  sudo = true,
  env = true,
  exec = true,
  bash = true,
  sh = true,
  xargs = true,
  nohup = true,
  nice = true,
}

---Maximum recursion depth for proxy resolution (e.g., bash -c "bash -c '...'")
local MAX_PROXY_DEPTH = 3

---Forward declaration for recursive proxy resolution
local extract_commands

---Parse bash source into command entries using treesitter
---@param source string
---@return { name: string, args: string[] }[]|nil
local function parse_command_entries(source)
  local ok_p, parser = pcall(vim.treesitter.get_string_parser, source, "bash")
  if not ok_p then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local ok_q, query =
    pcall(vim.treesitter.query.parse, "bash", [[(command name: (command_name) @name)]])
  if not ok_q then
    return nil
  end

  local entries = {}
  for _, name_node in query:iter_captures(tree:root(), source) do
    local name = vim.trim(vim.treesitter.get_node_text(name_node, source))
    -- Normalize full paths to basename so /bin/rm matches rule "rm"
    name = vim.fn.fnamemodify(name, ":t")

    -- Collect args from parent command node's named children
    local args = {}
    local cmd_node = name_node:parent()
    if cmd_node then
      for i = 1, cmd_node:named_child_count() - 1 do
        local child = cmd_node:named_child(i)
        local t = child:type()
        if t == "word" or t == "concatenation" then
          table.insert(args, vim.trim(vim.treesitter.get_node_text(child, source)))
        elseif
          t == "raw_string"
          or t == "string"
          or t == "string_expansion"
          or t == "ansii_c_string"
        then
          table.insert(args, strip_quotes(vim.trim(vim.treesitter.get_node_text(child, source))))
        end
      end
    end

    table.insert(entries, { name = name, args = args })
  end
  return entries
end

---Resolve proxy commands by extracting the inner command.
---For bash/sh -c "cmd", recursively parses the command string.
---For other proxies (sudo, env, exec, etc.), extracts the first non-flag arg.
---@param entries { name: string, args: string[] }[]
---@param depth integer Current recursion depth
---@return { name: string, args: string[] }[] resolved entries
local function resolve_proxies(entries, depth)
  if depth >= MAX_PROXY_DEPTH then
    return entries
  end

  local resolved = {}
  for _, entry in ipairs(entries) do
    if not PROXY_COMMANDS[entry.name] then
      table.insert(resolved, entry)
    else
      -- Check for bash -c "cmd" / sh -c "cmd" pattern
      local cmd_string = nil
      if entry.name == "bash" or entry.name == "sh" then
        local found_c = false
        for _, arg in ipairs(entry.args or {}) do
          if found_c and cmd_string == nil then
            cmd_string = arg
            break
          end
          if arg == "-c" then
            found_c = true
          end
        end
      end

      if cmd_string then
        -- Recursively parse the command string
        local inner_entries = extract_commands(cmd_string)
        if inner_entries then
          for _, ie in ipairs(resolve_proxies(inner_entries, depth + 1)) do
            table.insert(resolved, ie)
          end
        else
          table.insert(resolved, entry)
        end
      else
        -- Extract first non-flag argument as inner command
        local inner_name, inner_start = first_non_flag_arg(entry.args)
        if inner_name then
          inner_name = vim.fn.fnamemodify(inner_name, ":t")
          inner_start = inner_start + 1
          local inner_args = {}
          for i = inner_start or 1, #(entry.args or {}) do
            table.insert(inner_args, entry.args[i])
          end
          table.insert(resolved, { name = inner_name, args = inner_args })
        else
          table.insert(resolved, entry)
        end
      end
    end
  end
  return resolved
end

---Extract and resolve commands from a bash script.
---Handles all errors internally, returns nil on any failure.
---@param source string
---@return { name: string, args: string[] }[]|nil
extract_commands = function(source)
  local ok, entries = pcall(function()
    local parsed = parse_command_entries(source)
    if not parsed then
      return nil
    end
    return resolve_proxies(parsed, 0)
  end)
  if not ok then
    return nil
  end
  return entries
end

---System directory prefixes that are always sensitive for chmod/chown
local SYSTEM_DIR_PREFIXES = {
  "/etc/",
  "/usr/",
  "/bin/",
  "/sbin/",
  "/boot/",
  "/lib/",
  "/sys/",
  "/proc/",
  "/dev/",
  "/var/",
  "/root/",
  "/opt/",
}

---Check if any arg targets a system directory
---@param args string[]
---@return boolean
local function targets_system_dir(args)
  for _, arg in ipairs(args or {}) do
    for _, prefix in ipairs(SYSTEM_DIR_PREFIXES) do
      if vim.startswith(arg, prefix) then
        return true
      end
    end
  end
  return false
end

---Factory: block when first arg matches a set of dangerous subcommands
---@param set table<string, boolean>
---@return fun(args: string[]): boolean
local function blocks_subcmd(set)
  return function(args)
    return set[args and args[1]] == true
  end
end

---Built-in default pause list rules
M.defaults = {
  -- rm: block recursive deletes (-r/-R/--recursive with or without -f)
  rm = function(args)
    local flags = check_short_flags(args)
    if flags.r then
      return true
    end
    if has_long_flag(args, "--recursive") then
      return true
    end
    return false
  end,

  -- git: block destructive subcommands
  git = function(args)
    if not args or #args == 0 then
      return false
    end

    local function check_reset()
      for _, arg in ipairs(args) do
        if arg == "--hard" then
          return true
        end
      end
      return false
    end

    local function check_clean()
      local flags = check_short_flags(args)
      return flags.f and flags.d
    end

    local function check_push()
      for _, arg in ipairs(args) do
        if arg == "--force-with-lease" then
          return false
        end
      end
      local flags = check_short_flags(args)
      if flags.f or has_long_flag(args, "--force") then
        return true
      end
      return has_long_flag(args, "--delete")
    end

    local function check_checkout()
      -- Skip the subcommand itself, check remaining args for "." or "--"
      for i = 2, #args do
        if args[i] == "." or args[i] == "--" then
          return true
        end
      end
      return false
    end

    local function check_stash()
      local second = args[2]
      return second == "drop" or second == "clear"
    end

    local subcmd = args[1]
    if subcmd == "reset" then
      return check_reset()
    elseif subcmd == "clean" then
      return check_clean()
    elseif subcmd == "push" then
      return check_push()
    elseif subcmd == "checkout" then
      return check_checkout()
    elseif subcmd == "stash" then
      return check_stash()
    end
    return false
  end,

  -- Always dangerous commands
  dd = true,
  mkfs = true,
  ["mkfs.ext2"] = true,
  ["mkfs.ext3"] = true,
  ["mkfs.ext4"] = true,
  ["mkfs.btrfs"] = true,
  ["mkfs.xfs"] = true,
  ["mkfs.ntfs"] = true,
  ["mkfs.vfat"] = true,
  ["mkfs.fat"] = true,
  ["mkfs.exfat"] = true,
  shutdown = true,
  reboot = true,
  poweroff = true,
  halt = true,
  mount = true,
  umount = true,
  fdisk = true,
  parted = true,
  iptables = true,
  ip6tables = true,
  kill = true,
  killall = true,
  pkill = true,

  -- chmod / chown on system directories
  chmod = targets_system_dir,
  chown = targets_system_dir,

  -- systemctl: block stop/restart/disable/mask
  systemctl = blocks_subcmd({ stop = true, restart = true, disable = true, mask = true }),

  -- npm: block publish/uninstall/remove/rm
  npm = blocks_subcmd({ publish = true, uninstall = true, remove = true, rm = true }),

  -- pip/pip3: block uninstall
  pip = blocks_subcmd({ uninstall = true }),
  pip3 = blocks_subcmd({ uninstall = true }),

  -- cargo: block publish
  cargo = blocks_subcmd({ publish = true }),
}

---Create a new checker instance
---@param pauselist_rules table<string, boolean|fun(args: string[]): boolean>
---@return { check_require_approval: fun(cmd: string|nil): boolean }
function M.new(pauselist_rules)
  local rules = pauselist_rules or {}

  ---Check whether a command requires approval
  ---@param cmd_string string|nil
  ---@return boolean true if needs approval, false if auto-approve
  local function check_require_approval(self, cmd_string)
    -- Empty/nil input: no commands to check
    if cmd_string == nil then
      return false
    end
    local trimmed = vim.trim(cmd_string)
    if trimmed == "" then
      return false
    end

    -- Parse with treesitter (extract_commands handles all errors internally)
    local entries = extract_commands(trimmed)
    if entries == nil then
      -- Parse failure → conservative: require approval
      return true
    end

    -- No commands extracted (pure assignment, etc.)
    if #entries == 0 then
      return false
    end

    -- Check each command against pause list
    for _, entry in ipairs(entries) do
      local rule = rules[entry.name]
      if rule == true then
        return true
      elseif type(rule) == "function" then
        if rule(entry.args) then
          return true
        end
      end
    end

    -- No pause list hit
    return false
  end

  return {
    check_require_approval = check_require_approval,
  }
end

return M
