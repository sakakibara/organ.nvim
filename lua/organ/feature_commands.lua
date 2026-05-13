-- lua/organ/feature_commands.lua
-- Maps each feature name (key in M.config) to the list of :Org
-- subcommand PATHS that belong to it.  Used by M.setup() to remove
-- those leaves from the dispatch tree when the feature is disabled.
--
-- Path syntax matches user invocation: `"find link"` means `:Org find
-- link`; `"narrow_to_subtree"` is a single-token leaf at the root.
--
-- Core commands NOT under any feature flag:
--   index, scan, status, todo, fetch_holidays
-- These are always registered and never removed.

local M = {}

M.feature_commands = {
  structure = {
    "promote",
    "demote",
    "promote_headline",
    "demote_headline",
    "move_up",
    "move_down",
    "schedule",
    "deadline",
    "id get_create",
    "narrow_to_subtree",
    "widen",
    "rename_headline",
    "hover",
    "actions",
    "cut_subtree",
    "copy_subtree",
    "paste_subtree",
  },
  inline_edit = {
    "increment",
    "decrement",
  },
  property = {
    "set_property",
    "delete_property",
  },
  table = {
    "table insert_row",
    "table insert_row_above",
    "table delete_row",
    "table move_row_up",
    "table move_row_down",
    "table insert_column",
    "table insert_column_left",
    "table delete_column",
    "table move_column_left",
    "table move_column_right",
    "table sort",
    "table eval_formulas",
  },
  capture = {
    "capture",
    "capture_prompt",
  },
  clock = {
    "clock in",
    "clock out",
    "clock cancel",
    "clock jump",
    "clock report",
  },
  find = {
    "find",
    "find file",
    "find link",
    "find ref",
    "find tag",
    "find todo",
  },
  roam = {
    "roam",
    "roam insert",
    "roam daily today",
    "roam daily yesterday",
    "roam daily tomorrow",
    "roam daily",
  },
  backlinks = {
    "backlinks",
  },
  complete = {
    "complete",
  },
  -- NOTE: watcher.enabled = false means "don't auto-start", not
  -- "disable the feature".  The :Org watch * commands stay available
  -- so users can start/stop the watcher manually even when auto-start
  -- is off.  Do NOT include watcher here.
  sparse = {
    "sparse_tree todo",
    "sparse_tree tag",
    "sparse_tree regex",
    "sparse_tree clear",
  },
  agenda = {
    "agenda",
    "stuck_projects",
    "refile",
    "follow_link",
  },
  archive = {
    "archive subtree",
  },
  links = {
    "store_link",
    "insert_link",
  },
  attach = {
    "attach",
    "attach open",
    "attach reveal",
  },
  lsp = {
    "lsp start",
    "lsp stop",
  },
}

return M
