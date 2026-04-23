-- four-claude.nvim entry point.
--
-- Dispatches between two implementations:
--   * zellij path  — fourclaude as a zellij tab in the current session,
--                    4 claude panes. Activated when $ZELLIJ is set and
--                    `zellij` is on PATH.
--   * legacy path  — 4 nvim :terminal buffers in a 2×2 grid (original).
--
-- The zellij path reuses the legacy module's preset picker and config store,
-- but swaps out the launch backend. Command registration, lualine status,
-- and public API all branch on `use_zellij()`.

local zellij = require("four-claude.zellij")
local legacy = require("four-claude.legacy")

local M = {}

local defaults = {
  -- nil = auto-detect (zellij iff $ZELLIJ set and binary available)
  use_zellij = nil,
}

M.config = {}

-- Event-tracked existence of the fourclaude zellij tab. Updated when we run
-- spawn / close. May drift if the user manipulates the tab directly in
-- zellij (e.g. Ctrl+t x); lualine status tolerates this.
M._zellij_tab_alive = false

local function zellij_env_ok()
  return (select(1, zellij.check_env())) == true
end

local function use_zellij()
  local opt = M.config.use_zellij
  if opt == false then return false end
  if opt == true then return zellij_env_ok() end
  return zellij_env_ok() -- auto
end

local function notify_err(msg)
  vim.notify("Four Claude (zellij): " .. msg, vim.log.levels.ERROR,
             { title = "Four Claude" })
end

-- Zellij-path open: pick paths → spawn a fourclaude tab.
local function zellij_open()
  legacy.pick_paths(function(paths)
    zellij.spawn(paths, function(ok, stderr)
      vim.schedule(function()
        if not ok then
          notify_err("new-tab failed: " .. (stderr ~= "" and stderr or "unknown"))
          return
        end
        M._zellij_tab_alive = true
      end)
    end)
  end)
end

-- Zellij-path close: switch to the fourclaude tab (if any) then close it.
local function zellij_close()
  zellij.run_action({ "go-to-tab-name", zellij.TAB_NAME }, function(found)
    if not found then
      M._zellij_tab_alive = false -- nothing to close; clear stale flag
      return
    end
    zellij.run_action({ "close-tab" }, function(ok, stderr)
      vim.schedule(function()
        if ok then
          M._zellij_tab_alive = false
        else
          notify_err("close-tab failed: " .. stderr)
        end
      end)
    end)
  end)
end

local function register_zellij_commands()
  local ucmd = vim.api.nvim_create_user_command
  ucmd("FourClaude", zellij_open, { desc = "Open fourclaude (zellij tab)" })
  ucmd("FourClaudeToggle", zellij_open,
       { desc = "Show fourclaude (zellij tab) — creates if missing" })
  ucmd("FourClaudeClose", zellij_close,
       { desc = "Close the fourclaude zellij tab" })
  ucmd("FourClaudeCloseAll", zellij_close,
       { desc = "Close the fourclaude zellij tab (alias)" })
  ucmd("FourClaudePresets", function() legacy.manage_presets() end,
       { desc = "Manage Four Claude presets" })
end

--- Public API ---------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", defaults, opts)

  -- Legacy's preset helpers (reused by the zellij path) read legacy.config,
  -- so always initialise it.
  legacy.setup_config(opts)

  if use_zellij() then
    register_zellij_commands()
    vim.schedule(function() zellij.cleanup_stale_kdl() end)
  else
    legacy.setup(opts)
  end
end

function M.open()
  if use_zellij() then return zellij_open() end
  return legacy.open()
end

function M.close()
  if use_zellij() then return zellij_close() end
  return legacy.close()
end

function M.close_all()
  if use_zellij() then return zellij_close() end
  return legacy.close_all()
end

function M.toggle()
  if use_zellij() then return zellij_open() end
  return legacy.toggle()
end

function M.is_open()
  if use_zellij() then return M._zellij_tab_alive end
  return legacy.is_open()
end

function M.status()
  if use_zellij() then
    return M._zellij_tab_alive and "● Claude" or ""
  end
  return legacy.status()
end

function M.manage_presets() return legacy.manage_presets() end

return M
