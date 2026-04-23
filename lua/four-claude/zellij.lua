-- Zellij-backed implementation of fourclaude.
--
-- Creates a zellij tab named "fourclaude" in the current zellij session,
-- laid out as a 2×2 grid of claude panes. Assumes nvim is running inside
-- a zellij session ($ZELLIJ is set).
--
-- This module is pure glue to `zellij action …` commands — it does not
-- hold state. State (tab existence, lualine status) lives in the init.lua
-- dispatcher layer.

local uv = vim.uv or vim.loop

local M = {}

M.TAB_NAME = "fourclaude"

-- Cache path for this nvim process's layout file.
function M.kdl_path()
  return vim.fn.stdpath("cache") .. "/four-claude-" .. vim.fn.getpid() .. ".kdl"
end

-- Returns (true, nil) when nvim is inside a zellij session and `zellij` is
-- on PATH; (false, reason) otherwise.
function M.check_env()
  if vim.env.ZELLIJ == nil or vim.env.ZELLIJ == "" then
    return false, "$ZELLIJ not set — nvim must run inside a zellij session"
  end
  if vim.fn.executable("zellij") ~= 1 then
    return false, "zellij executable not found on PATH"
  end
  return true, nil
end

-- KDL v1 string literal escape.
local function kdl_str(s)
  return '"' .. (s or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- Renders the KDL layout for a fourclaude tab with the given 4 cwds.
function M.render_kdl(paths)
  assert(paths and #paths >= 4, "render_kdl: expected 4 paths")
  local p = {}
  for i = 1, 4 do p[i] = kdl_str(paths[i]) end
  return table.concat({
    "layout {",
    '    tab name="' .. M.TAB_NAME .. '" {',
    '        pane split_direction="vertical" {',
    '            pane split_direction="horizontal" {',
    "                pane cwd=" .. p[1] .. " {",
    '                    command "claude"',
    "                }",
    "                pane cwd=" .. p[2] .. " {",
    '                    command "claude"',
    "                }",
    "            }",
    '            pane split_direction="horizontal" {',
    "                pane cwd=" .. p[3] .. " {",
    '                    command "claude"',
    "                }",
    "                pane cwd=" .. p[4] .. " {",
    '                    command "claude"',
    "                }",
    "            }",
    "        }",
    "    }",
    "}",
    "",
  }, "\n")
end

-- Writes the layout kdl to the per-nvim cache path.
function M.write_kdl(paths)
  local path = M.kdl_path()
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(M.render_kdl(paths))
  f:close()
  return path, nil
end

-- Generic async wrapper around `zellij action <args>`.
local function run_zellij_action(args, on_done)
  local cmd = { "zellij", "action" }
  vim.list_extend(cmd, args)
  local stderr_lines = {}
  return vim.fn.jobstart(cmd, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stderr_lines, line) end
      end
    end,
    on_exit = function(_, code)
      if on_done then on_done(code == 0, table.concat(stderr_lines, "\n")) end
    end,
  })
end

M.run_action = run_zellij_action

-- Spawns a fourclaude tab in the current zellij session.
function M.spawn(paths, on_done)
  local path, err = M.write_kdl(paths)
  if not path then
    if on_done then on_done(false, "kdl write failed: " .. tostring(err)) end
    return nil
  end
  return run_zellij_action(
    { "new-tab", "--name", M.TAB_NAME, "--layout", path },
    on_done
  )
end

-- Remove kdl cache files from other pids that are older than 1 day. Called
-- asynchronously from setup(); best-effort, ignores errors.
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

return M
