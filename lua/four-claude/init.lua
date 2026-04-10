local M = {}

local uv = vim.uv or vim.loop

M.instances = {} -- tab_handle -> instance

local defaults = {
  cmd = "claude",
  stagger_ms = 2000,
  max_presets = 5,
  alert = {
    enabled = true,
    delay = 5000,
    interval = 2000,
  },
}

local poll_timer = nil

----------------------------------------------------------------------
-- Presets persistence
----------------------------------------------------------------------
local PRESETS_FILE = vim.fn.stdpath("data") .. "/four-claude-presets.json"

local function load_presets()
  local f = io.open(PRESETS_FILE, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function save_presets_file(data)
  local f = io.open(PRESETS_FILE, "w")
  if not f then return end
  f:write(vim.fn.json_encode(data))
  f:close()
end

local function save_preset(root, paths)
  local all = load_presets()
  local list = all[root] or {}
  local entry = { paths[1], paths[2], paths[3], paths[4] }

  for i = #list, 1, -1 do
    local same = true
    for j = 1, 4 do
      if list[i][j] ~= entry[j] then same = false; break end
    end
    if same then table.remove(list, i) end
  end

  table.insert(list, 1, entry)

  while #list > M.config.max_presets do
    table.remove(list)
  end

  all[root] = list
  save_presets_file(all)
end

----------------------------------------------------------------------
-- Terminal keymaps
----------------------------------------------------------------------
local function setup_term_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", vim.tbl_extend("force", opts, { desc = "Exit terminal mode" }))
  vim.keymap.set("t", "<C-]>", "<C-\\><C-n>", vim.tbl_extend("force", opts, { desc = "Exit terminal mode" }))
  vim.keymap.set("t", "<C-h>", "<cmd>wincmd h<cr>", vim.tbl_extend("force", opts, { desc = "Go to left window" }))
  vim.keymap.set("t", "<C-j>", "<cmd>wincmd j<cr>", vim.tbl_extend("force", opts, { desc = "Go to lower window" }))
  vim.keymap.set("t", "<C-k>", "<cmd>wincmd k<cr>", vim.tbl_extend("force", opts, { desc = "Go to upper window" }))
  vim.keymap.set("t", "<C-l>", "<cmd>wincmd l<cr>", vim.tbl_extend("force", opts, { desc = "Go to right window" }))
  -- Pass through Ctrl+Enter / Shift+Enter for Claude CLI multiline input
  local function send_newline()
    local chan = vim.b[vim.api.nvim_get_current_buf()].terminal_job_id
    if chan then vim.fn.chansend(chan, "\n") end
  end
  vim.keymap.set("t", "<C-CR>", send_newline, vim.tbl_extend("force", opts, { desc = "Newline in input" }))
  vim.keymap.set("t", "<S-CR>", send_newline, vim.tbl_extend("force", opts, { desc = "Newline in input" }))
  vim.keymap.set("t", "<C-PageUp>", "<cmd>tabprevious<cr>", vim.tbl_extend("force", opts, { desc = "Previous tab" }))
  vim.keymap.set("t", "<C-PageDown>", "<cmd>tabnext<cr>", vim.tbl_extend("force", opts, { desc = "Next tab" }))
  vim.keymap.set("t", "<C-z>", function() M.zoom_toggle() end, vim.tbl_extend("force", opts, { desc = "Toggle zoom" }))
  vim.keymap.set("n", "<C-z>", function() M.zoom_toggle() end, vim.tbl_extend("force", opts, { desc = "Toggle zoom" }))
end

----------------------------------------------------------------------
-- Highlights & winbar
----------------------------------------------------------------------
local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "FourClaudeActiveBar", { fg = "#000000", bg = "#ffffff", bold = true })
  hl(0, "FourClaudeActiveSep", { fg = "#ffffff", bold = true })
  hl(0, "FourClaudeInactiveBar", { fg = "#565f89", bg = "#1a1b26" })
  hl(0, "FourClaudeInactiveSep", { fg = "#29293d" })
  hl(0, "FourClaudeDim", { bg = "#101015" })
  hl(0, "FourClaudeAlertBar", { fg = "#000000", bg = "#ff9e64", bold = true })
end

local function make_winbar(inst, n, active)
  local label = "Claude " .. n
  if inst.paths[n] then
    label = label .. " [" .. vim.fn.fnamemodify(inst.paths[n], ":t") .. "]"
  end
  local zoom = inst.zoomed == n and " ▣" or ""
  if active then
    return "%#FourClaudeActiveBar#  ● " .. label .. zoom .. "  %*"
  else
    return "%#FourClaudeInactiveBar#  ○ " .. label .. zoom .. "  %*"
  end
end

local function make_alert_winbar(inst, n)
  local label = "Claude " .. n
  if inst.paths[n] then
    label = label .. " [" .. vim.fn.fnamemodify(inst.paths[n], ":t") .. "]"
  end
  return "%#FourClaudeAlertBar#  ⚠ " .. label .. " - INPUT NEEDED  %*"
end

----------------------------------------------------------------------
-- Window options (shared between _launch and zoom restore)
----------------------------------------------------------------------
local FC_FILLCHARS = "eob: ,vert:┃,horiz:━,horizup:┻,horizdown:┳,vertleft:┫,vertright:┣,verthoriz:╋"

local function apply_win_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].wrap = true
  vim.wo[win].sidescrolloff = 0
  pcall(function() vim.wo[win].fillchars = FC_FILLCHARS end)
end

----------------------------------------------------------------------
-- Instance helpers
----------------------------------------------------------------------
local function current_instance()
  local tab = vim.api.nvim_get_current_tabpage()
  return M.instances[tab]
end

local function is_alert(inst, i)
  local mon = inst.buf_monitor[i]
  return mon and mon.phase == "alerted"
end

local function set_win_style(inst, win, i, active)
  if not vim.api.nvim_win_is_valid(win) then return end
  if active then
    vim.wo[win].winbar = make_winbar(inst, i, true)
    vim.wo[win].winhighlight = "WinSeparator:FourClaudeActiveSep"
  elseif is_alert(inst, i) then
    -- keep alert winbar
  else
    vim.wo[win].winbar = make_winbar(inst, i, false)
    vim.wo[win].winhighlight = "Normal:FourClaudeDim,WinSeparator:FourClaudeInactiveSep"
  end
end

----------------------------------------------------------------------
-- Focus tracking
----------------------------------------------------------------------
local function update_focus()
  local inst = current_instance()
  if not inst then return end
  local cur = vim.api.nvim_get_current_win()

  -- Auto-restore zoom when user navigates to a non-zoomed pane
  if inst.zoomed then
    local zoomed_win = inst.wins[inst.zoomed]
    if cur ~= zoomed_win then
      M._zoom_restore(inst)
    end
  end

  for i, win in ipairs(inst.wins) do
    if vim.api.nvim_win_is_valid(win) then
      local active = win == cur
      if active and is_alert(inst, i) then
        M._stop_alert(inst, i)
      end
      set_win_style(inst, win, i, active)
    end
  end
end

----------------------------------------------------------------------
-- Zoom (maximize / restore)
----------------------------------------------------------------------

--- Restore from zoom: equalize windows, reattach all terminals.
--- Does NOT change focus – callers decide where focus should be.
function M._zoom_restore(inst)
  if not inst.zoomed then return end
  inst.zoomed = nil

  -- Detach the zoomed terminal before equalizing
  local scratch = inst.zoom_scratch
  if not scratch or not vim.api.nvim_buf_is_valid(scratch) then
    scratch = vim.api.nvim_create_buf(false, true)
  end
  for _, win in ipairs(inst.wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, scratch)
    end
  end

  -- Equalize to final sizes first
  vim.cmd("wincmd =")

  -- Reattach all terminals at correct final sizes (one clean resize each)
  for i, win in ipairs(inst.wins) do
    if vim.api.nvim_win_is_valid(win) then
      apply_win_opts(win)
      if inst.bufs[i] and vim.api.nvim_buf_is_valid(inst.bufs[i]) then
        vim.api.nvim_win_set_buf(win, inst.bufs[i])
      end
    end
  end

  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  inst.zoom_scratch = nil

  -- Reapply alert winbar for any panes that were alerted during zoom
  for i, win in ipairs(inst.wins) do
    if is_alert(inst, i) and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = make_alert_winbar(inst, i)
    end
  end
end

function M.zoom_toggle()
  local inst = current_instance()
  if not inst then return end

  if inst.zoomed then
    M._zoom_restore(inst)
  else
    -- ZOOM IN: keep all 4 windows, maximize one, minimize others
    local cur = vim.api.nvim_get_current_win()
    local idx = nil
    for i, win in ipairs(inst.wins) do
      if win == cur then idx = i; break end
    end
    if not idx then return end
    inst.zoomed = idx

    -- Create scratch buffer for non-zoomed placeholder windows
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].bufhidden = "wipe"
    inst.zoom_scratch = scratch

    -- Navigation keymaps on scratch so user can Ctrl+hjkl from info windows
    local sopts = { buffer = scratch, noremap = true, silent = true }
    vim.keymap.set("n", "<C-h>", "<cmd>wincmd h<cr>", sopts)
    vim.keymap.set("n", "<C-j>", "<cmd>wincmd j<cr>", sopts)
    vim.keymap.set("n", "<C-k>", "<cmd>wincmd k<cr>", sopts)
    vim.keymap.set("n", "<C-l>", "<cmd>wincmd l<cr>", sopts)
    vim.keymap.set("n", "<C-z>", function() M.zoom_toggle() end, sopts)

    -- Detach ALL terminals (replace with scratch) to prevent any resize events
    for i, win in ipairs(inst.wins) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_buf(win, scratch)
      end
    end

    -- Maximize zoomed window (others shrink to minimum)
    vim.api.nvim_set_current_win(cur)
    vim.cmd("wincmd _")
    vim.cmd("wincmd |")

    -- Reattach ONLY the zoomed terminal (one clean resize to full size)
    vim.api.nvim_win_set_buf(cur, inst.bufs[idx])
    apply_win_opts(cur)
  end
  update_focus()
end

----------------------------------------------------------------------
-- Alert system
----------------------------------------------------------------------
function M._start_alert(inst, index)
  if is_alert(inst, index) then return end
  inst.buf_monitor[index].phase = "alerted"

  vim.notify("Claude " .. index .. " needs your input", vim.log.levels.WARN, {
    title = "Four Claude",
  })

  local win = inst.wins[index]
  if not vim.api.nvim_win_is_valid(win) then return end

  local count = 0
  if inst.flash_timers[index] then vim.fn.timer_stop(inst.flash_timers[index]) end
  inst.flash_timers[index] = vim.fn.timer_start(400, function()
    if not vim.api.nvim_win_is_valid(win) or not is_alert(inst, index) then
      if inst.flash_timers[index] then
        vim.fn.timer_stop(inst.flash_timers[index])
        inst.flash_timers[index] = nil
      end
      return
    end
    count = count + 1
    if count > 8 then
      vim.wo[win].winbar = make_alert_winbar(inst, index)
      vim.fn.timer_stop(inst.flash_timers[index])
      inst.flash_timers[index] = nil
      return
    end
    if count % 2 == 1 then
      vim.wo[win].winbar = make_alert_winbar(inst, index)
    else
      vim.wo[win].winbar = make_winbar(inst, index, false)
    end
  end, { ["repeat"] = -1 })
end

function M._stop_alert(inst, index)
  if inst.flash_timers[index] then
    vim.fn.timer_stop(inst.flash_timers[index])
    inst.flash_timers[index] = nil
  end
  inst.buf_monitor[index] = nil
  local win = inst.wins[index]
  if win and vim.api.nvim_win_is_valid(win) then
    local active = win == vim.api.nvim_get_current_win()
    set_win_style(inst, win, index, active)
  end
end

----------------------------------------------------------------------
-- Input-needed detection (content-based)
----------------------------------------------------------------------
local spinner_chars = {
  "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
  "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
  "◐", "◑", "◒", "◓",
}

local function has_spinner(line)
  for _, ch in ipairs(spinner_chars) do
    if line:find(ch, 1, true) then return true end
  end
  return false
end

local function is_prompt_line(line)
  local trimmed = line:match("^%s*(.-)%s*$")
  return trimmed == ">" or trimmed == "❯" or trimmed == "»" or trimmed == "$"
end

--- Analyse the last visible lines of a Claude Code terminal buffer.
--- Returns "urgent" for permission/approval prompts, "prompt" for
--- a regular input prompt, or false if Claude appears to still be working.
local function detect_input_needed(lines)
  -- Collect last non-empty lines (skip trailing blanks)
  local meaningful = {}
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line and line:match("%S") then
      table.insert(meaningful, 1, line)
      if #meaningful >= 6 then break end
    end
  end
  if #meaningful == 0 then return false end

  local last = meaningful[#meaningful]

  -- Active spinner on last meaningful line → still processing
  if has_spinner(last) then return false end

  local text = table.concat(meaningful, "\n")

  -- Permission / approval prompts (urgent)
  if text:match("[Aa]llow") then return "urgent" end
  if text:match("[Dd]eny") then return "urgent" end
  if text:match("%[Y/n%]") or text:match("%[y/N%]") then return "urgent" end
  if text:match("%(Y%)es") or text:match("%(y%)es") then return "urgent" end
  if text:match("%(N%)o") or text:match("%(n%)o") then return "urgent" end
  if text:match("Do you want to proceed") then return "urgent" end
  if text:match("Would you like to") then return "urgent" end
  if text:match("[Aa]ccept") and text:match("[Rr]eject") then return "urgent" end

  -- Regular input prompt (waiting for next user message)
  if is_prompt_line(last) then return "prompt" end

  return false
end

local function check_for_alerts()
  local now = uv.now()
  for _, inst in pairs(M.instances) do
    if not vim.api.nvim_tabpage_is_valid(inst.tab) then goto next_inst end
    for i, buf in ipairs(inst.bufs) do
      if not vim.api.nvim_buf_is_valid(buf) then goto continue end
      local win = inst.wins[i]
      local win_valid = win and vim.api.nvim_win_is_valid(win)

      -- Skip alert for the currently focused window
      if win_valid and win == vim.api.nvim_get_current_win() then
        if is_alert(inst, i) then M._stop_alert(inst, i) end
        inst.buf_monitor[i] = nil
        goto continue
      end

      local ok, line_count = pcall(vim.api.nvim_buf_line_count, buf)
      if not ok then goto continue end
      local start = math.max(0, line_count - 15)
      local ok2, lines = pcall(vim.api.nvim_buf_get_lines, buf, start, -1, false)
      if not ok2 then goto continue end
      local text = table.concat(lines, "\n")

      local mon = inst.buf_monitor[i]
      if not mon then
        inst.buf_monitor[i] = { text = text, changed_at = now, phase = "init" }
        goto continue
      end

      if mon.text ~= text then
        mon.text = text
        mon.changed_at = now
        if mon.phase == "alerted" then
          M._stop_alert(inst, i)
          inst.buf_monitor[i] = { text = text, changed_at = now, phase = "flowing" }
        else
          mon.phase = "flowing"
        end
      elseif mon.phase == "flowing" then
        local needed = detect_input_needed(lines)
        if needed == "urgent" then
          -- Permission prompts: alert faster (2s or configured delay, whichever is less)
          local urgent_delay = math.min(2000, M.config.alert.delay)
          if now - mon.changed_at >= urgent_delay then
            M._start_alert(inst, i)
          end
        elseif needed == "prompt" then
          -- Regular input prompt: use configured delay
          if now - mon.changed_at >= M.config.alert.delay then
            M._start_alert(inst, i)
          end
        end
        -- No pattern matched → Claude is likely still processing, don't alert
      end

      ::continue::
    end
    ::next_inst::
  end
end

local function ensure_poll_timer()
  if poll_timer then return end
  if not M.config.alert.enabled then return end
  poll_timer = vim.fn.timer_start(M.config.alert.interval, function()
    check_for_alerts()
  end, { ["repeat"] = -1 })
end

local function maybe_stop_poll_timer()
  if next(M.instances) == nil and poll_timer then
    vim.fn.timer_stop(poll_timer)
    poll_timer = nil
  end
end

----------------------------------------------------------------------
-- Directory choices & path pickers
----------------------------------------------------------------------
local function format_path(p, root)
  if p == root then return "." end
  return vim.fn.fnamemodify(p, ":t")
end

local function format_preset(preset, root)
  local names = {}
  for _, p in ipairs(preset) do
    table.insert(names, format_path(p, root))
  end
  return names[1] .. "  |  " .. names[2] .. "  |  " .. names[3] .. "  |  " .. names[4]
end

local function pick_paths_custom(callback)
  local root = vim.fn.getcwd()
  local paths = {}

  local function pick(index)
    if index > 4 then
      callback(paths)
      return
    end
    local default = paths[index - 1] or root
    vim.ui.input({
      prompt = "Claude " .. index .. " directory: ",
      default = default,
      completion = "dir",
    }, function(input)
      if not input or input == "" then return end
      local p = vim.fn.fnamemodify(input, ":p"):gsub("[/\\]+$", "")
      paths[index] = p
      pick(index + 1)
    end)
  end

  pick(1)
end

----------------------------------------------------------------------
-- Setup & commands
----------------------------------------------------------------------
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  setup_highlights()

  vim.api.nvim_create_user_command("FourClaude", function()
    M.open()
  end, { desc = "Open 4 Claude terminals in a new tab" })

  vim.api.nvim_create_user_command("FourClaudeClose", function()
    M.close()
  end, { desc = "Close current tab's Claude terminals" })

  vim.api.nvim_create_user_command("FourClaudeToggle", function()
    M.toggle()
  end, { desc = "Toggle current tab's Claude terminals" })

  vim.api.nvim_create_user_command("FourClaudeCloseAll", function()
    M.close_all()
  end, { desc = "Close all Four Claude instances" })

  vim.api.nvim_create_user_command("FourClaudePresets", function()
    M.manage_presets()
  end, { desc = "Manage Four Claude presets" })

  vim.api.nvim_create_user_command("FourClaudeZoom", function()
    M.zoom_toggle()
  end, { desc = "Toggle zoom on current Claude pane" })
end

function M.is_open()
  return current_instance() ~= nil
end

function M.open()
  local root = vim.fn.getcwd()
  local all_presets = load_presets()
  local presets = all_presets[root] or {}

  local function do_custom()
    pick_paths_custom(function(paths)
      save_preset(root, paths)
      M._launch(paths)
    end)
  end

  if #presets == 0 then
    do_custom()
    return
  end

  local choices = {}
  for _, preset in ipairs(presets) do
    table.insert(choices, { type = "preset", paths = preset })
  end
  table.insert(choices, { type = "custom" })
  table.insert(choices, { type = "manage" })

  vim.ui.select(choices, {
    prompt = "Four Claude - select preset or customize:",
    format_item = function(item)
      if item.type == "custom" then
        return "✚ New custom..."
      elseif item.type == "manage" then
        return "⚙ Manage presets..."
      end
      return format_preset(item.paths, root)
    end,
  }, function(choice)
    if not choice then return end
    if choice.type == "custom" then
      do_custom()
    elseif choice.type == "manage" then
      M.manage_presets()
    else
      local paths = {}
      for i, p in ipairs(choice.paths) do paths[i] = p end
      save_preset(root, paths)
      M._launch(paths)
    end
  end)
end

----------------------------------------------------------------------
-- Preset management
----------------------------------------------------------------------
function M.manage_presets()
  local root = vim.fn.getcwd()
  local all = load_presets()
  local presets = all[root] or {}

  if #presets == 0 then
    vim.notify("No presets for this project", vim.log.levels.INFO, { title = "Four Claude" })
    return
  end

  local choices = {}
  for i, preset in ipairs(presets) do
    table.insert(choices, { index = i, paths = preset })
  end

  vim.ui.select(choices, {
    prompt = "Manage presets - select one to edit/delete:",
    format_item = function(item)
      return item.index .. ". " .. format_preset(item.paths, root)
    end,
  }, function(choice)
    if not choice then return end

    vim.ui.select({ "Delete", "Edit", "Cancel" }, {
      prompt = "Action for preset " .. choice.index .. ":",
    }, function(action)
      if not action or action == "Cancel" then return end

      if action == "Delete" then
        table.remove(presets, choice.index)
        all[root] = #presets > 0 and presets or nil
        save_presets_file(all)
        vim.notify("Preset deleted", vim.log.levels.INFO, { title = "Four Claude" })
        if #presets > 0 then
          vim.schedule(function() M.manage_presets() end)
        end

      elseif action == "Edit" then
        local old = choice.paths
        local new_paths = {}
        local function edit_path(i)
          if i > 4 then
            presets[choice.index] = new_paths
            all[root] = presets
            save_presets_file(all)
            vim.notify("Preset updated", vim.log.levels.INFO, { title = "Four Claude" })
            return
          end
          vim.ui.input({
            prompt = "Claude " .. i .. " directory: ",
            default = old[i] or "",
            completion = "dir",
          }, function(input)
            if not input or input == "" then return end
            new_paths[i] = vim.fn.fnamemodify(input, ":p"):gsub("[/\\]+$", "")
            edit_path(i + 1)
          end)
        end
        edit_path(1)
      end
    end)
  end)
end

----------------------------------------------------------------------
-- Launch grid
----------------------------------------------------------------------
function M._launch(paths)
  local inst = {
    bufs = {},
    wins = {},
    paths = paths,
    tab = nil,
    augroup = nil,
    buf_monitor = {},
    flash_timers = {},
    zoomed = nil, -- index of zoomed pane, or nil
  }

  local sr = vim.o.splitright
  local sb = vim.o.splitbelow
  vim.o.splitright = true
  vim.o.splitbelow = true

  vim.cmd("tabnew")
  inst.tab = vim.api.nvim_get_current_tabpage()
  M.instances[inst.tab] = inst

  -- Build 2x2 grid: vertical split first (shared separator), then split each column
  vim.cmd("vnew")
  local top_right = vim.api.nvim_get_current_win()
  vim.cmd("wincmd h")
  local top_left = vim.api.nvim_get_current_win()
  vim.cmd("new")
  local bot_left = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(top_right)
  vim.cmd("new")
  local bot_right = vim.api.nvim_get_current_win()

  local wins = { top_left, top_right, bot_left, bot_right }

  for i, win in ipairs(wins) do
    inst.wins[i] = win
    apply_win_opts(win)
    vim.wo[win].winbar = make_winbar(inst, i, false)
  end

  vim.cmd("wincmd =")

  -- Autocmds (unique augroup per instance)
  inst.augroup = vim.api.nvim_create_augroup("FourClaude_" .. inst.tab, { clear = true })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = inst.augroup,
    callback = function()
      if vim.api.nvim_tabpage_is_valid(inst.tab) and vim.api.nvim_get_current_tabpage() == inst.tab then
        vim.schedule(update_focus)
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = inst.augroup,
    callback = function()
      if vim.api.nvim_tabpage_is_valid(inst.tab) and vim.api.nvim_get_current_tabpage() == inst.tab then
        local buf = vim.api.nvim_get_current_buf()
        if vim.bo[buf].buftype == "terminal" then
          vim.fn.winrestview({ leftcol = 0 })
          vim.cmd("startinsert")
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = inst.augroup,
    callback = function()
      if not vim.api.nvim_tabpage_is_valid(inst.tab) then
        M._cleanup_instance(inst)
      end
    end,
  })

  -- Alert polling (single global timer for all instances)
  ensure_poll_timer()

  -- Staggered terminal launch
  local function launch_term(index)
    if not vim.api.nvim_tabpage_is_valid(inst.tab) then return end
    local win = wins[index]
    if not vim.api.nvim_win_is_valid(win) then return end

    local user_win = vim.api.nvim_get_current_win()

    vim.api.nvim_set_current_win(win)
    local job_id = vim.fn.termopen(vim.o.shell, { cwd = paths[index] })
    vim.defer_fn(function()
      pcall(vim.fn.chansend, job_id, M.config.cmd .. "\r")
    end, 500)
    local buf = vim.api.nvim_get_current_buf()
    inst.bufs[index] = buf
    setup_term_keymaps(buf)
    apply_win_opts(win)
    vim.cmd("wincmd =")

    if index == 1 then
      update_focus()
      vim.cmd("startinsert")
    else
      if vim.api.nvim_win_is_valid(user_win) then
        vim.api.nvim_set_current_win(user_win)
      end
      vim.schedule(update_focus)
    end

    if index < #wins then
      vim.defer_fn(function()
        launch_term(index + 1)
      end, M.config.stagger_ms)
    end
  end

  vim.api.nvim_set_current_win(top_left)
  launch_term(1)

  vim.o.splitright = sr
  vim.o.splitbelow = sb
end

----------------------------------------------------------------------
-- Cleanup & close
----------------------------------------------------------------------
function M._cleanup_instance(inst)
  if inst.zoom_scratch and vim.api.nvim_buf_is_valid(inst.zoom_scratch) then
    pcall(vim.api.nvim_buf_delete, inst.zoom_scratch, { force = true })
  end
  inst.zoom_scratch = nil
  inst.zoomed = nil
  for i = 1, 4 do
    if inst.flash_timers[i] then
      vim.fn.timer_stop(inst.flash_timers[i])
      inst.flash_timers[i] = nil
    end
    inst.buf_monitor[i] = nil
  end
  if inst.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, inst.augroup)
    inst.augroup = nil
  end
  for _, buf in ipairs(inst.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if inst.tab then
    M.instances[inst.tab] = nil
  end
  maybe_stop_poll_timer()
end

function M.close()
  local inst = current_instance()
  if not inst then return end
  M._cleanup_instance(inst)
end

function M.close_all()
  local all = vim.tbl_values(M.instances)
  for _, inst in ipairs(all) do
    M._cleanup_instance(inst)
  end
  maybe_stop_poll_timer()
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
