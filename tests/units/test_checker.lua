--[[
Test: checker.lua — Blocklist Checker

Intent: Verify that checker.new(blocklist_rules):check_require_approval(cmd)
correctly identifies dangerous commands per blocklist semantics, handles user
configuration overrides, and behaves safely on edge cases.

]]

local T = MiniTest.new_set()

-- Test the module can be loaded
do
  local ok, _ = pcall(require, "codecompanion._extensions.run_bash.checker")
  T["checker exists"] = function()
    MiniTest.expect.equality(true, ok)
  end
end

-- Default blocklist: positive cases (should return true — needs approval)
do
  local checker = require("codecompanion._extensions.run_bash.checker")
  local c = checker.new(checker.defaults)

  T["default: rm -rf"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("echo hello; rm -rf /tmp/test"))
  end

  T["default: rm -rf in subshell"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("echo $(rm -rf /)"))
  end

  T["default: git reset --hard"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("git reset --hard HEAD~1"))
  end

  T["default: git push --force"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("git push --force origin main"))
  end

  T["default: git push --delete"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("git push --delete origin old-branch"))
  end

  T["default: git clean -fd"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("git clean -fd"))
  end

  T["default: git stash drop"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("git stash drop"))
  end

  T["default: dd"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("dd if=/dev/zero of=/dev/sda"))
  end

  T["default: systemctl stop"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("systemctl stop nginx"))
  end

  T["default: npm publish"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("npm publish"))
  end

  T["default: pip uninstall"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("pip uninstall requests"))
  end

  T["default: cargo publish"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("cargo publish"))
  end

  T["default: kill"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("kill 1234"))
  end

  T["default: iptables"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("iptables -F"))
  end

  T["default: shutdown"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("shutdown -h now"))
  end

  T["default: mkfs.ext4"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("mkfs.ext4 /dev/sda1"))
  end

  T["default: chmod on system dir"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("chmod 777 /etc/passwd"))
  end

  T["default: git stash clear"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("git stash clear"))
  end

  T["default: git checkout ."] = function()
    MiniTest.expect.equality(true, c:check_require_approval("git checkout ."))
  end
end

-- Default blocklist: negative cases (should return false — auto-approve)
do
  local checker = require("codecompanion._extensions.run_bash.checker")
  local c = checker.new(checker.defaults)

  T["default: git status"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("git status && git log"))
  end

  T["default: cat | grep"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("cat file | grep pattern"))
  end

  T["default: ls find"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("ls -la; find . -name '*.lua'"))
  end

  T["default: cd touch"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("cd /tmp && touch test"))
  end

  T["default: npm run build"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("npm run build"))
  end

  T["default: pip install"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("pip install requests"))
  end

  T["default: git push --force-with-lease"] = function()
    MiniTest.expect.equality(
      false,
      c:check_require_approval("git push --force-with-lease origin main")
    )
  end

  T["default: git checkout main"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("git checkout main"))
  end
end

-- Full-path command normalization (basename matching)
do
  local checker = require("codecompanion._extensions.run_bash.checker")
  local c = checker.new(checker.defaults)

  -- Intent: Verify that commands specified by full path are matched against
  -- blocklist rules keyed by basename.

  T["default: /bin/rm -rf blocked"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("/bin/rm -rf /tmp"))
  end

  T["default: /usr/bin/git reset --hard blocked"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("/usr/bin/git reset --hard"))
  end

  T["default: /bin/ls -la allowed"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("/bin/ls -la"))
  end

  T["default: /usr/bin/env rm -rf blocked (proxy + full-path)"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("/usr/bin/env rm -rf /"))
  end
end

-- Proxy command detection (sudo/env/bash/exec/xargs/nohup/nice)
do
  local checker = require("codecompanion._extensions.run_bash.checker")
  local c = checker.new(checker.defaults)

  -- Intent: Verify that dangerous commands wrapped in proxy commands
  -- (sudo, env, bash -c, exec, xargs, nohup, nice) are still detected.

  T["default: sudo rm -rf blocked"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("sudo rm -rf /"))
  end

  T["default: env rm -rf blocked"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("env rm -rf /tmp"))
  end

  T["default: bash -c rm blocked"] = function()
    MiniTest.expect.equality(true, c:check_require_approval('bash -c "rm -rf /tmp"'))
  end

  T["default: sudo git push --force blocked"] = function()
    MiniTest.expect.equality(true, c:check_require_approval("sudo git push --force origin main"))
  end

  T["default: sudo ls allowed"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("sudo ls -la"))
  end
end

-- Blocklist configuration overrides
do
  local checker = require("codecompanion._extensions.run_bash.checker")

  T["config: cargo true blocks cargo build"] = function()
    local c = checker.new({ cargo = true })
    MiniTest.expect.equality(true, c:check_require_approval("cargo build"))
  end

  T["config: rm false allows rm -rf"] = function()
    local c = checker.new({ rm = false })
    MiniTest.expect.equality(false, c:check_require_approval("rm -rf /tmp"))
  end

  T["config: git function overrides default"] = function()
    local c = checker.new({
      git = function(args)
        return false
      end,
    })
    MiniTest.expect.equality(false, c:check_require_approval("git reset --hard"))
  end
end

-- Boundary / edge cases
do
  local checker = require("codecompanion._extensions.run_bash.checker")
  local c = checker.new(checker.defaults)

  T["edge: empty string"] = function()
    MiniTest.expect.equality(false, c:check_require_approval(""))
  end

  T["edge: whitespace only"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("   "))
  end

  T["edge: pure assignment"] = function()
    MiniTest.expect.equality(false, c:check_require_approval("FOO=bar"))
  end

  T["edge: nil input"] = function()
    MiniTest.expect.equality(false, c:check_require_approval(nil))
  end
end

-- Exception cases: parse failure → conservative true
do
  local checker = require("codecompanion._extensions.run_bash.checker")

  T["exception: parse failure returns true"] = function()
    -- Save original function
    local orig_get_string_parser = vim.treesitter.get_string_parser

    -- Replace with failing function
    vim.treesitter.get_string_parser = function()
      error("mock parse failure")
    end

    local c = checker.new(checker.defaults)
    local result = c:check_require_approval("some command")

    -- Restore
    vim.treesitter.get_string_parser = orig_get_string_parser

    MiniTest.expect.equality(true, result)
  end
end

return T
