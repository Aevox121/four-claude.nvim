-- four-claude.nvim entry point.
--
-- Dispatches between two backends:
--   * zellij path — `:terminal` containing an embedded ephemeral zellij
--                   running a 2×2 layout of `claude` panes. Activated when
--                   `zellij` is on PATH; works regardless of whether nvim
--                   itself is started inside an outer zellij session.
--   * legacy path — 4 native nvim `:terminal` buffers in a 2×2 grid.
--                   Used on Windows and anywhere zellij isn't installed.
--
-- The zellij path keeps fourclaude inside nvim's sights (TermEnter fires,
-- ch-ime and other nvim features still work) while offloading TUI resize
-- to zellij so Claude Code stops garbling on window resize. The legacy
-- path is preserved for platforms without zellij.

local zellij = require("four-claude.zellij")
local legacy = require("four-claude.legacy")

local M = {}

local defaults = {
  -- nil = auto-detect (zellij iff the binary is available)
  use_zellij = nil,
}

M.config = {}

local function use_zellij()
  local opt = M.config.use_zellij
  if opt == false then return false end
  if opt == true then return zellij.available() end
  return zellij.available()
end

local function notify_err(msg)
  vim.notify("Four Claude (zellij): " .. msg, vim.log.levels.ERROR,
             { title = "Four Claude" })
end

-- Always spawn a new fourclaude tab (picker + embedded zellij). No
-- focus-existing shortcut — matches legacy's M.open semantics so multiple
-- fourclaude tabs can coexist across both backends.
local function zellij_open_new()
  legacy.pick_paths(function(paths)
    local _, err = zellij.open(paths, legacy.config.cmd or "claude")
    if err then notify_err(err) end
  end)
end

-- Toggle: if the current tab is itself a fourclaude tab, close it;
-- otherwise spawn a new one. Mirrors legacy.M.toggle so <leader>C behaves
-- the same across platforms.
local function zellij_toggle()
  local cur = vim.api.nvim_get_current_tabpage()
  if zellij.is_fourclaude_tab(cur) then
    zellij.close(cur)
    return
  end
  zellij_open_new()
end

local function zellij_close()
  local cur = vim.api.nvim_get_current_tabpage()
  if zellij.is_fourclaude_tab(cur) then
    zellij.close(cur)
    return
  end
  zellij.close(zellij.find_instance())
end

local function register_zellij_commands()
  local ucmd = vim.api.nvim_create_user_command
  ucmd("FourClaude", zellij_open_new,
       { desc = "Open a new fourclaude tab (embedded zellij)" })
  ucmd("FourClaudeToggle", zellij_toggle,
       { desc = "Open new fourclaude, or close current one if in a fourclaude tab" })
  ucmd("FourClaudeClose", zellij_close,
       { desc = "Close the fourclaude tab (SIGHUPs zellij + 4 claudes)" })
  ucmd("FourClaudeCloseAll", function() zellij.close_all() end,
       { desc = "Close all fourclaude tabs" })
  ucmd("FourClaudePresets", function() legacy.manage_presets() end,
       { desc = "Manage Four Claude presets" })
  ucmd("FourClaudeInstallNotifications", function()
    require("four-claude.notifications").install()
  end, { desc = "Install OS-native Claude Code notification hooks" })
  ucmd("FourClaudePin", function()
    vim.notify("Four Claude: pin granularity isn't available on the zellij backend. " ..
               "Inside fourclaude use zellij's `Ctrl+p n` to split a fifth pane.",
               vim.log.levels.INFO, { title = "Four Claude" })
  end, { desc = "Pin is handled by zellij on the zellij backend" })
  ucmd("FourClaudeZoom", function()
    vim.notify("Four Claude: zoom granularity isn't available on the zellij backend. " ..
               "Inside fourclaude use zellij's `Alt+f` (or `Ctrl+p f`) to zoom a pane.",
               vim.log.levels.INFO, { title = "Four Claude" })
  end, { desc = "Zoom is handled by zellij on the zellij backend" })
end

-- Drop straight into terminal mode whenever the user lands on a fourclaude
-- tab so keys reach the embedded zellij without an extra `i` press.
local function register_zellij_autocmds()
  local grp = vim.api.nvim_create_augroup("FourClaudeZellij", { clear = true })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = grp,
    callback = function()
      if zellij.is_fourclaude_tab(vim.api.nvim_get_current_tabpage()) then
        vim.cmd("startinsert")
      end
    end,
  })
end

--- Public API ---------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", defaults, opts)

  -- Legacy's preset helpers (shared by both backends) read legacy.config,
  -- so always initialise it.
  legacy.setup_config(opts)

  if use_zellij() then
    register_zellij_commands()
    register_zellij_autocmds()
    vim.schedule(function() zellij.cleanup_stale_kdl() end)
  else
    legacy.setup(opts)
  end
end

function M.open()
  if use_zellij() then return zellij_open_new() end
  return legacy.open()
end

function M.close()
  if use_zellij() then return zellij_close() end
  return legacy.close()
end

function M.close_all()
  if use_zellij() then return zellij.close_all() end
  return legacy.close_all()
end

function M.toggle()
  if use_zellij() then return zellij_toggle() end
  return legacy.toggle()
end

function M.is_open()
  if use_zellij() then return zellij.is_open() end
  return legacy.is_open()
end

function M.status()
  if use_zellij() then return zellij.status() end
  return legacy.status()
end

function M.manage_presets() return legacy.manage_presets() end

return M
