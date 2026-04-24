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
  -- Agents are declared on legacy.config (shared between both backends).
  -- See legacy.lua defaults; the user's setup opts are passed straight
  -- through, so `setup({ agents = {...}, default_agent = "..." })` lives
  -- in legacy.config.agents after setup().
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
local function zellij_open_new(agent_arg)
  local info, err = legacy.resolve_agent(agent_arg)
  if not info then notify_err(err); return end
  legacy.pick_paths(function(paths)
    local _, e = zellij.open(paths, info.cmd, info.name)
    if e then notify_err(e) end
  end, info.name)
end

-- Toggle: if the current tab is itself a fourclaude tab, close it;
-- otherwise spawn a new one. Mirrors legacy.M.toggle so <leader>C behaves
-- the same across platforms.
local function zellij_toggle(agent_arg)
  local cur = vim.api.nvim_get_current_tabpage()
  if zellij.is_fourclaude_tab(cur) then
    zellij.close(cur)
    return
  end
  zellij_open_new(agent_arg)
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
  local complete_agents = function() return legacy.agent_names() end

  ucmd("FourClaude", function(c) zellij_open_new(c.args) end, {
    desc = "Open a new fourclaude tab (optional agent name)",
    nargs = "?",
    complete = complete_agents,
  })
  ucmd("FourClaudeToggle", function(c) zellij_toggle(c.args) end, {
    desc = "Open new fourclaude, or close current one if in a fourclaude tab (optional agent name)",
    nargs = "?",
    complete = complete_agents,
  })
  ucmd("FourClaudeClose", zellij_close,
       { desc = "Close the fourclaude tab (SIGHUPs zellij + 4 agents)" })
  ucmd("FourClaudeCloseAll", function() zellij.close_all() end,
       { desc = "Close all fourclaude tabs" })
  ucmd("FourClaudePresets", function(c) legacy.manage_presets(c.args) end, {
    desc = "Manage Four Claude presets (optional agent name)",
    nargs = "?",
    complete = complete_agents,
  })
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

function M.open(agent)
  if use_zellij() then return zellij_open_new(agent) end
  return legacy.open(agent)
end

function M.close()
  if use_zellij() then return zellij_close() end
  return legacy.close()
end

function M.close_all()
  if use_zellij() then return zellij.close_all() end
  return legacy.close_all()
end

function M.toggle(agent)
  if use_zellij() then return zellij_toggle(agent) end
  return legacy.toggle(agent)
end

function M.is_open()
  if use_zellij() then return zellij.is_open() end
  return legacy.is_open()
end

function M.status()
  if use_zellij() then return zellij.status() end
  return legacy.status()
end

function M.manage_presets(agent) return legacy.manage_presets(agent) end

return M
