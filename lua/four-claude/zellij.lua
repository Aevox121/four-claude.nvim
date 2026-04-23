-- v3 zellij backend: embedded mini-zellij inside a single nvim :terminal.
--
-- Structure: `<leader>C` opens a new nvim tabpage holding one :terminal
-- buffer. That terminal runs `env -u ZELLIJ zellij --layout <kdl>` as an
-- ephemeral standalone zellij session (not attached to any outer session).
-- Zellij renders a 4-pane layout of claude processes inside.
--
-- Rationale: keeps fourclaude in nvim's sights (TermEnter fires, ch-ime
-- works, winbar renders, one paradigm) while letting zellij handle TUI
-- resize so Claude Code doesn't garble on window resize. Works equally
-- well whether the user's nvim is launched from inside or outside an outer
-- zellij session — the `env -u ZELLIJ` prefix clears the nesting guard.

local uv = vim.uv or vim.loop

local M = {}

-- tab_handle -> { buf = bufnr, job = job_id }
M.instances = {}

---------------------------------------------------------------------------
-- env / environment checks
---------------------------------------------------------------------------

function M.available()
  return vim.fn.executable("zellij") == 1
end

---------------------------------------------------------------------------
-- KDL layout generation
---------------------------------------------------------------------------

function M.kdl_path()
  return vim.fn.stdpath("cache") .. "/four-claude-" .. vim.fn.getpid() .. ".kdl"
end

local function kdl_str(s)
  return '"' .. (s or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- KDL for the embedded zellij. No outer `tab name=…` wrapper is needed
-- because this is a whole ephemeral session — its single tab is the 2×2
-- grid plus zellij's tab-bar / status-bar plugins for mode hints.
function M.render_kdl(paths, cmd)
  assert(paths and #paths >= 4, "render_kdl: expected 4 paths")
  cmd = cmd or "claude"
  local cmd_kdl = kdl_str(cmd)
  local p = {}
  for i = 1, 4 do p[i] = kdl_str(paths[i]) end
  return table.concat({
    "layout {",
    '    default_tab_template {',
    "        pane size=1 borderless=true {",
    '            plugin location="zellij:tab-bar"',
    "        }",
    "        children",
    "        pane size=2 borderless=true {",
    '            plugin location="zellij:status-bar"',
    "        }",
    "    }",
    '    tab name="fourclaude" {',
    '        pane split_direction="vertical" {',
    '            pane split_direction="horizontal" {',
    "                pane cwd=" .. p[1] .. " {",
    "                    command " .. cmd_kdl,
    "                }",
    "                pane cwd=" .. p[2] .. " {",
    "                    command " .. cmd_kdl,
    "                }",
    "            }",
    '            pane split_direction="horizontal" {',
    "                pane cwd=" .. p[3] .. " {",
    "                    command " .. cmd_kdl,
    "                }",
    "                pane cwd=" .. p[4] .. " {",
    "                    command " .. cmd_kdl,
    "                }",
    "            }",
    "        }",
    "    }",
    "}",
    "",
  }, "\n")
end

function M.write_kdl(paths, cmd)
  local path = M.kdl_path()
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(M.render_kdl(paths, cmd))
  f:close()
  return path, nil
end

-- Best-effort cleanup of stale kdl files left behind by other nvim pids
-- that are no longer running. Called from setup().
function M.cleanup_stale_kdl()
  local glob = vim.fn.stdpath("cache") .. "/four-claude-*.kdl"
  local files = vim.fn.glob(glob, false, true)
  local my_pid = tostring(vim.fn.getpid())
  local cutoff = os.time() - 86400
  for _, f in ipairs(files) do
    local pid = f:match("four%-claude%-(%d+)%.kdl$")
    if pid and pid ~= my_pid then
      local stat = uv.fs_stat(f)
      if stat and stat.mtime and stat.mtime.sec < cutoff then
        pcall(os.remove, f)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Instance lifecycle
---------------------------------------------------------------------------

local function close_tab_windows(tab)
  if not vim.api.nvim_tabpage_is_valid(tab) then return end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    pcall(vim.api.nvim_win_close, w, true)
  end
end

-- Called when the embedded zellij process exits (user Ctrl+q, crash, or
-- our SIGHUP via M.close). Idempotent — M.close may have cleared state.
function M._on_exit(tab)
  local inst = M.instances[tab]
  if not inst then return end
  M.instances[tab] = nil
  vim.schedule(function()
    close_tab_windows(tab)
    if vim.api.nvim_buf_is_valid(inst.buf) then
      pcall(vim.api.nvim_buf_delete, inst.buf, { force = true })
    end
  end)
end

-- Opens a new nvim tab hosting a :terminal running the embedded zellij.
-- Returns the tab handle on success, or (nil, err) on failure.
function M.open(paths, cmd)
  local kdl, err = M.write_kdl(paths, cmd)
  if not kdl then return nil, "kdl write failed: " .. tostring(err) end

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local buf = vim.api.nvim_get_current_buf()

  local argv = { "env", "-u", "ZELLIJ", "zellij", "--layout", kdl }
  local job = vim.fn.termopen(argv, {
    on_exit = function() M._on_exit(tab) end,
  })

  if job <= 0 then
    pcall(vim.cmd, "tabclose")
    return nil, "termopen returned " .. tostring(job)
  end

  vim.bo[buf].buflisted = false
  vim.wo.winbar = "● Four Claude"
  M.instances[tab] = { buf = buf, job = job }

  vim.cmd("startinsert")
  return tab
end

-- Returns the handle of any live fourclaude tab, or nil.
function M.find_instance()
  for tab, _ in pairs(M.instances) do
    if vim.api.nvim_tabpage_is_valid(tab) then return tab end
    M.instances[tab] = nil
  end
  return nil
end

function M.is_open()
  return M.find_instance() ~= nil
end

-- Returns true if the given tab belongs to a fourclaude instance.
function M.is_fourclaude_tab(tab)
  return M.instances[tab] ~= nil
end

-- Closes the given tab (or the first live fourclaude tab if nil).
function M.close(tab)
  tab = tab or M.find_instance()
  if not tab then return end
  local inst = M.instances[tab]
  M.instances[tab] = nil
  if inst then pcall(vim.fn.jobstop, inst.job) end
  close_tab_windows(tab)
end

function M.close_all()
  for tab, _ in pairs(M.instances) do M.close(tab) end
end

function M.status()
  return M.is_open() and "● Claude" or ""
end

return M
