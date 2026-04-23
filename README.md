# four-claude.nvim

Manage a 4-pane Claude Code workspace from Neovim, with two backends:

- **zellij path** (auto on macOS / Linux when `$ZELLIJ` is set and `zellij` is on PATH)
  — creates a tab named `fourclaude` in the current zellij session, 4 panes each
  running `claude` in a chosen directory. Rendering and resize handled natively
  by zellij.
- **legacy path** (fallback on Windows, or anywhere without zellij) — 4 nvim
  `:terminal` buffers in a 2×2 grid inside a new nvim tabpage, with per-pane
  winbar, zoom, pin-to-sidebar, and in-nvim input-needed alerts.

Backend is selected automatically; override with `use_zellij = true | false` in setup.

## Requirements

- Neovim ≥ 0.10
- Claude Code CLI (`claude`) on PATH
- For the zellij path: `zellij ≥ 0.40` on PATH, nvim running inside a zellij session

## Installation (lazy.nvim)

```lua
{
  "Aevox121/four-claude.nvim",
  main = "four-claude",
  config = function()
    require("four-claude").setup({
      -- use_zellij = nil,  -- nil (default) = auto; true = force; false = never
    })
  end,
  keys = {
    { "<leader>C", "<cmd>FourClaudeToggle<cr>", desc = "Show fourclaude" },
  },
}
```

## Commands

| Command | zellij path | legacy path |
|---------|---|---|
| `:FourClaude` / `:FourClaudeToggle` | Ensure the `fourclaude` zellij tab is focused (create via preset picker if missing) | Open / toggle the 4-pane nvim tab |
| `:FourClaudeClose` / `:FourClaudeCloseAll` | Close the `fourclaude` zellij tab (SIGHUPs the 4 claudes) | Close current tab's terminals |
| `:FourClaudePresets` | Manage preset 4-directory lists for the current cwd | same |
| `:FourClaudeInstallNotifications` | Install OS-native Claude Code `Notification` / `Stop` hooks (macOS `osascript`, Linux `notify-send`) | — |
| `:FourClaudeZoom` / `:FourClaudePin` | — | Zoom current pane / pin a pane to sidebar |

## Lualine indicator

Shows `● Claude` in the statusline whenever fourclaude is alive.

```lua
{
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    local function fc_status()
      local ok, fc = pcall(require, "four-claude")
      return ok and fc.status() or ""
    end
    opts.sections = opts.sections or {}
    opts.sections.lualine_x = opts.sections.lualine_x or {}
    table.insert(opts.sections.lualine_x, 1, {
      fc_status,
      cond = function() return fc_status() ~= "" end,
      color = { fg = "#ff9e64" },
    })
  end,
}
```

## macOS workflow (zellij path)

### Prerequisites

```sh
brew install zellij
```

Configure your terminal emulator to launch zellij on startup. For Ghostty:

```
command = zellij attach -c -s main
```

Then run `nvim` inside the zellij session as usual.

### First-time setup

Run once:

```vim
:FourClaudeInstallNotifications
```

This writes `Notification` and `Stop` hooks into `~/.claude/settings.json`
so you get macOS notifications when Claude needs input or finishes. Idempotent.

### Daily use

- `<leader>C` from anywhere → focuses the `fourclaude` tab, creating it (with
  preset picker) if it doesn't exist.
- When focused on fourclaude, use zellij's tab keys (`Alt+h`/`Alt+l` by default)
  to switch back to nvim.
- `:FourClaudeClose` to tear down. Four claude processes get SIGHUP.

### Features dropped on the zellij path

Because the 4 panes live inside zellij rather than as nvim buffers, these
legacy features are replaced by zellij-native equivalents:

| Legacy | zellij replacement |
|---|---|
| Per-pane winbar (`● Claude N [dir]`) | zellij status bar |
| Zoom toggle (`<C-z>`) | zellij `Alt+f` |
| Diagonal pane jumps (`<C-u>` / `<C-n>`) | zellij `Ctrl+p` + `hjkl` |
| Pin to sidebar (`<leader>cp`) | Split inside zellij (`Ctrl+p` + `n`) or just switch tabs |
| Input-needed alert (winbar flash) | OS notification via `:FourClaudeInstallNotifications` |

## Windows / legacy path

Behavior on Windows is unchanged from pre-v2. All legacy features (4 nvim
terminals, winbar, zoom, pin, in-nvim alerts) work as before. The zellij
dispatcher stays dormant because `$ZELLIJ` is never set.

## Architecture

```
lua/four-claude/
├── init.lua           Dispatcher. Reads $ZELLIJ and picks a backend.
├── zellij.lua         zellij-path backend: KDL render + zellij action calls.
├── legacy.lua         legacy-path backend: 4 nvim :terminal in a 2×2 grid.
└── notifications.lua  ~/.claude/settings.json hook installer.
```

Preset picker (`pick_paths`) and preset storage live in `legacy.lua` and are
shared by both paths — the zellij path reuses them and just swaps the launch
backend.
