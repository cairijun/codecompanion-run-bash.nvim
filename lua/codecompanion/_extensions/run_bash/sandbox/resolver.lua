---@brief
---
--- Generic path resolution for sandbox backends.
--- Expands ~, $VAR, XDG fallbacks; checks existence per rule type.

local uv = vim.uv

local M = {}

-- XDG environment variable fallback paths. Keys are full variable names
-- with $ prefix (e.g. "$XDG_DATA_HOME") for O(1) hash lookup.
-- $XDG_RUNTIME_DIR has no fallback — the spec requires it to be set.
local XDG_FALLBACKS = {
  ["$XDG_DATA_HOME"] = "~/.local/share",
  ["$XDG_CONFIG_HOME"] = "~/.config",
  ["$XDG_CACHE_HOME"] = "~/.cache",
  ["$XDG_STATE_HOME"] = "~/.local/state",
}

---Expand a single path: normalize → XDG fallback → (optional) existence check
---@param path string Raw path (may contain ~ and $VAR)
---@param check_existence boolean Whether to check path existence (false for fs_denied)
---@param fs_stat? function Optional fs_stat override (defaults to vim.uv.fs_stat)
---@return string|nil Expanded normalized absolute path, nil if unresolvable
function M.resolve_path(path, check_existence, fs_stat)
  fs_stat = fs_stat or uv.fs_stat

  -- Reject non-string types early (fail-fast)
  if type(path) ~= "string" then
    error("run_bash: rule path must be a string, got " .. type(path))
  end

  -- Step 1: vim.fs.normalize handles ~, $VAR, ., .., trailing slash
  local normalized = vim.fs.normalize(path)

  -- Step 2: if result still starts with $ (env var unset), try XDG fallback
  if vim.startswith(normalized, "$") then
    -- Extract first path component (the variable name): from $ to next / or end
    local slash_pos = normalized:find("/", 2)
    local var_name = slash_pos and normalized:sub(1, slash_pos - 1) or normalized
    local fallback = XDG_FALLBACKS[var_name]
    if fallback then
      local suffix = normalized:sub(#var_name + 1) -- sub-path after var name (incl. / or empty)
      normalized = vim.fs.normalize(fallback .. suffix)
    else
      return nil -- Not in fallback table, cannot resolve
    end
  end

  -- Step 3: existence check (only for fs_readable/fs_writable;
  -- fs_denied skips this — backends may accept non-existent deny paths)
  if check_existence then
    if normalized == "" or not fs_stat(normalized) then
      return nil
    end
  end

  return normalized
end

---Expand a rules table into grouped absolute path arrays.
---fs_readable/fs_writable skip non-existent paths (existence checked);
---fs_denied includes all resolved paths (no existence check).
---Deduplicates within each group.
---@param rules table|nil { fs_readable, fs_writable, fs_denied }
---@param fs_stat? function Optional fs_stat override
---@return { readable: string[], writable: string[], denied: string[] }
function M.resolve_fs_rules(rules, fs_stat)
  rules = rules or {}

  local function expand(rule, check_existence)
    local result = {}
    local seen = {}
    local paths = (type(rule) == "table" and rule) or {}
    for _, path in ipairs(paths) do
      local resolved = M.resolve_path(path, check_existence, fs_stat)
      if resolved and not seen[resolved] then
        seen[resolved] = true
        table.insert(result, resolved)
      end
    end
    return result
  end

  return {
    readable = expand(rules.fs_readable, true),
    writable = expand(rules.fs_writable, true),
    denied = expand(rules.fs_denied, false),
  }
end

return M
