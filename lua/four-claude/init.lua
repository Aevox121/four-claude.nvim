-- four-claude.nvim entry point.
--
-- Dispatches between two implementations:
--   * zellij path  — fourclaude as a zellij tab in the current session,
--                    4 claude panes. Activated when $ZELLIJ is set and
--                    `zellij` is on PATH.
--   * legacy path  — 4 nvim :terminal buffers in a 2×2 grid.
--
-- This file currently delegates everything to the legacy module. The zellij
-- path will be layered in via subsequent commits on this branch.

return require("four-claude.legacy")
