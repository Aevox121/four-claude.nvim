-- Claude Code Notification/Stop hook installer.
--
-- Writes OS-native notification hooks into ~/.claude/settings.json so the
-- user gets a system notification when Claude needs input or finishes.
-- Replaces fourclaude's legacy in-nvim winbar alert (which can't distinguish
-- individual zellij panes from the nvim side).
--
-- Idempotent: each installed hook carries MARKER in its command string, so
-- re-running the installer is a no-op when markers are already present.

local M = {}

local MARKER = "# four-claude-notification"

local function settings_path()
  local home = vim.env.HOME or (vim.uv or vim.loop).os_homedir()
  return home .. "/.claude/settings.json"
end

local function notif_command()
  if vim.fn.has("mac") == 1 then
    return [[osascript -e 'display notification "Claude needs input" with title "Four Claude"' ]] .. MARKER
  elseif vim.fn.has("unix") == 1 then
    return [[notify-send "Four Claude" "Claude needs input" ]] .. MARKER
  end
  return nil
end

local function stop_command()
  if vim.fn.has("mac") == 1 then
    return [[osascript -e 'display notification "Claude finished" with title "Four Claude"' ]] .. MARKER
  elseif vim.fn.has("unix") == 1 then
    return [[notify-send "Four Claude" "Claude finished" ]] .. MARKER
  end
  return nil
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if content == "" then return {} end
  local ok, parsed = pcall(vim.json.decode, content)
  if not ok or type(parsed) ~= "table" then return {} end
  return parsed
end

local function write_json(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then return false, "json encode failed" end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(encoded)
  f:close()
  return true, nil
end

local function has_marker(hooks_list)
  if type(hooks_list) ~= "table" then return false end
  for _, group in ipairs(hooks_list) do
    if type(group) == "table" and type(group.hooks) == "table" then
      for _, h in ipairs(group.hooks) do
        if type(h.command) == "string" and h.command:find(MARKER, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

local function install_hook(settings, event, command)
  if not command then return false end
  settings.hooks = settings.hooks or {}
  settings.hooks[event] = settings.hooks[event] or {}
  if has_marker(settings.hooks[event]) then return false end
  table.insert(settings.hooks[event], {
    hooks = { { type = "command", command = command } },
  })
  return true
end

function M.install()
  local path = settings_path()
  local settings = read_json(path)

  local added_n = install_hook(settings, "Notification", notif_command())
  local added_s = install_hook(settings, "Stop", stop_command())

  if not (added_n or added_s) then
    vim.notify("Four Claude notifications already installed.",
               vim.log.levels.INFO, { title = "Four Claude" })
    return
  end

  local ok, err = write_json(path, settings)
  if not ok then
    vim.notify("Failed to write " .. path .. ": " .. tostring(err),
               vim.log.levels.ERROR, { title = "Four Claude" })
    return
  end

  local msg = "Installed Notification/Stop hooks → " .. path
  if added_n and added_s then
    msg = msg .. " (both events)"
  elseif added_n then
    msg = msg .. " (Notification)"
  else
    msg = msg .. " (Stop)"
  end
  vim.notify(msg, vim.log.levels.INFO, { title = "Four Claude" })
end

return M
