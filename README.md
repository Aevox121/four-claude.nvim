# four-claude.nvim

Manage a 4-pane Claude Code workspace from Neovim, with two backends:

- **zellij path** (auto when `zellij` is on PATH) — opens a new nvim tab
  containing a single `:terminal` buffer that runs an ephemeral
  [zellij](https://zellij.dev/) session laid out as a 2×2 grid of `claude`
  processes. Zellij handles TUI rendering and resize inside the terminal
  buffer, so Claude Code stops garbling on window resize. Because
  fourclaude is still a nvim `:terminal`, in-nvim integrations such as
  `TermEnter`-based IME switchers and the lualine indicator still work.
- **legacy path** (fallback when zellij isn't installed, i.e. Windows) —
  4 nvim `:terminal` buffers in a 2×2 grid inside a new nvim tabpage,
  with per-pane winbar, zoom, pin-to-sidebar, and in-nvim input-needed
  alerts.

Backend is selected automatically; override with `use_zellij = true | false` in setup.

## Requirements

- Neovim ≥ 0.10
- Claude Code CLI (`claude`) on PATH
- For the zellij path: `zellij ≥ 0.40` on PATH

You do **not** need to run nvim inside an outer zellij session. The
embedded zellij runs standalone; the plugin clears `$ZELLIJ` via `env -u
ZELLIJ` before launching to bypass zellij's nesting guard.

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
| `:FourClaude` | Always open a new fourclaude tab (preset picker) | Same |
| `:FourClaudeToggle` | If current tab is a fourclaude tab, close it; otherwise open a new one | Same |
| `:FourClaudeClose` | Close the fourclaude tab (SIGHUPs zellij, takes out the 4 claudes) | Close current tab's terminals |
| `:FourClaudeCloseAll` | Close all fourclaude tabs | same |
| `:FourClaudePresets` | Manage preset 4-directory lists for the current cwd | same |
| `:FourClaudeInstallNotifications` | Install OS-native Claude Code `Notification` / `Stop` hooks | — |
| `:FourClaudeZoom` / `:FourClaudePin` | Hint (use zellij's `Alt+f` / `Ctrl+p n` instead) | Zoom current pane / pin a pane to sidebar |

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

No outer zellij session required. You can start nvim however you want —
directly from the terminal, via tmux, or inside your usual zellij — and
`<leader>C` will spawn an embedded zellij inside a new `:terminal` tab.

### First-time setup (optional)

```vim
:FourClaudeInstallNotifications
```

Writes `Notification` and `Stop` hooks into `~/.claude/settings.json`
so you get macOS notifications when Claude needs input or finishes.
Idempotent.

### Daily use

- `<leader>C` from a non-fourclaude tab → opens a new fourclaude tab
  (preset picker on first open for this cwd). Nvim lands you in terminal
  mode on the embedded zellij.
- `<leader>C` from inside a fourclaude tab → closes that fourclaude tab.
- Leave terminal mode with `<C-\><C-n>` to use nvim navigation.
- Multiple fourclaude tabs can coexist — `:FourClaudeCloseAll` to clean up.
- Inside fourclaude, use zellij's native keys:
  - `Ctrl+p` + `h/j/k/l` — switch between the 4 claude panes
  - `Alt+f` (or `Ctrl+p` + `f`) — zoom a pane
  - `Ctrl+p` + `n` — split a fifth pane
  - `Ctrl+q` — quit the embedded zellij (also closes the tab)
- `:FourClaudeClose` to tear down from outside terminal mode.

### Alt-as-Meta on mac

Zellij's `Alt+…` shortcuts only reach the embedded zellij if your outer
terminal forwards Option as Meta. For Ghostty:

```
macos-option-as-alt = true
```

If you don't want to configure this, the `Ctrl+p` / `Ctrl+t` mode
prefixes work without any terminal-side setup.

### Features scoped differently on the zellij path

Per-claude-pane nvim operations (zoom, pin-to-sidebar, diagonal jumps,
per-pane winbar, input-needed alert) don't apply on the zellij path
because fourclaude is one nvim `:terminal`, not four. Use zellij's
native equivalents instead:

| Legacy | zellij replacement |
|---|---|
| Per-pane winbar (`● Claude N [dir]`) | zellij's tab-bar + status-bar (rendered inside the terminal) |
| Zoom toggle (`<C-z>`) | zellij `Alt+f` |
| Diagonal pane jumps (`<C-u>` / `<C-n>`) | zellij `Ctrl+p` + `hjkl` |
| Pin to sidebar (`<leader>cp`) | zellij `Ctrl+p` + `n` (splits a fifth pane in the same tab) |
| Input-needed alert (winbar flash) | OS notification via `:FourClaudeInstallNotifications` |

## Windows / legacy path

Behavior on Windows is unchanged. All legacy features (4 nvim
terminals, winbar, zoom, pin, in-nvim alerts) work as before. The
zellij dispatcher stays dormant because `zellij` isn't installed.

## Architecture

```
lua/four-claude/
├── init.lua           Dispatcher. Picks backend by `zellij` availability.
├── zellij.lua         v3 backend: nvim :terminal hosting an ephemeral zellij.
├── legacy.lua         Legacy backend: 4 nvim :terminal in a 2×2 grid.
└── notifications.lua  ~/.claude/settings.json hook installer.
```

Preset picker (`pick_paths`) and preset storage live in `legacy.lua` and
are shared by both paths — the zellij path reuses them for directory
selection and just swaps the launch backend.
