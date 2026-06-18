-- Buffer-local keymap registry + dispatcher (lazy.nvim-style spec).
--
-- Defaults live in M.defaults as a flat list of tuples:
--
--   { lhs, rhs, desc = "...", mode = "n" or { "n", "i" } }
--
-- where `rhs` is either:
--   - a string starting with a capital letter → user-command name (vim.cmd)
--   - a function → installed as the keymap callback
--   - false → suppress the default (only meaningful in the user override list)
--
-- User config overrides via `require("organ").setup({ keys = { ... } })`:
-- same shape, merged on top of defaults. User wins on lhs collision;
-- `{ lhs, false }` removes a default binding entirely.
--
-- The per-feature `<feature>.keymaps` blocks in defaults.lua + their
-- ftplugin installers (subtree, property, table, tag_select, inline_edit,
-- tempo, core) keep doing their own thing — their callbacks carry real
-- logic the flat list can't express.

local M = {}

-- Flat list of default bindings. Keep grouped by topic via comments;
-- evaluation order doesn't matter (user overrides win regardless).
-- Description style: LazyVim convention.
--   * Capitalized first letter, action-first imperative verb
--   * No "Org" prefix (the buffer is already org filetype)
--   * No "category:" prefix (which-key shows the prefix path via groups)
--   * Short — under ~30 chars where possible
M.defaults = {
  -- TODO state bindings are NOT defined here.  They live in
  -- `defaults.lua` -> `todo.keymaps` as the single source of truth
  -- (`cycle = "<M-t>"`, `cycle_back = "<M-T>"`, `fast_pick =
  -- "<LocalLeader>t"`, `set = "<LocalLeader>T"`).  ftplugin/core.lua
  -- wires them as buffer-local maps when the org filetype attaches.

  -- Per-headline single-char ops under <LocalLeader>
  { "<LocalLeader>s", "Org schedule", desc = "Schedule heading" },
  { "<LocalLeader>d", "Org deadline", desc = "Set deadline" },
  { "<LocalLeader>e", "Org set_effort", desc = "Set effort estimate" },
  { "<LocalLeader>n", "Org narrow_to_subtree", desc = "Narrow to subtree" },
  { "<LocalLeader>w", "Org widen", desc = "Widen" },
  { "<LocalLeader>r", "Org refile", desc = "Refile heading" },
  { "<LocalLeader>j", "Org goto", desc = "Fuzzy goto heading" },
  { "<LocalLeader>'", "Org edit_special", desc = "Edit src block" },
  { "<LocalLeader>#", "Org update_statistics", desc = "Update [N/M] cookies" },
  { "<LocalLeader>I", "Org store_link", desc = "Store link to heading" },
  { "<LocalLeader>L", "Org insert_link", desc = "Insert stored link" },
  { "<LocalLeader>@", "Org attach open", desc = "Open attachment" },
  { "<LocalLeader>%", "Org attach reveal", desc = "Reveal attach dir" },

  -- Neovim convention single-key
  { "<CR>", "Org follow_link", desc = "Follow link at cursor" },
  { "gx", "Org follow_link", desc = "Follow link (gx)" },
  { "gO", "Org goto", desc = "Outline picker" },
  { "K", "Org hover", desc = "Hover preview link target" },
  -- LocalLeader-period for the action menu (Emacs C-c C-c equivalent).
  { "<LocalLeader>.", "Org actions", desc = "Open org action menu" },
  { "<LocalLeader>R", "Org rename_headline", desc = "Rename headline + cascade" },

  -- archive
  { "<LocalLeader>aa", "Org archive subtree", desc = "Archive subtree to file" },
  { "<LocalLeader>as", "Org archive to_sibling", desc = "Archive to sibling" },
  { "<LocalLeader>at", "Org archive set_tag", desc = "Toggle :ARCHIVE: tag (no move)" },
  { "<LocalLeader>au", "Org unarchive", desc = "Restore archived subtree to source" },

  -- clock secondary ops (in/out wired in ftplugin/core.lua via clock.keymaps)
  { "<LocalLeader>cc", "Org clock cancel", desc = "Cancel active clock" },
  { "<LocalLeader>cj", "Org clock jump", desc = "Jump to clocked heading" },
  { "<LocalLeader>cr", "Org clock report", desc = "Open clock report" },

  -- footnote
  { "<LocalLeader>fj", "Org footnote jump", desc = "Jump to footnote" },
  { "<LocalLeader>fi", "Org footnote insert", desc = "Insert footnote" },
  { "<LocalLeader>fr", "Org footnote renumber", desc = "Renumber footnotes" },
  { "<LocalLeader>fs", "Org footnote sort", desc = "Sort footnotes by ref" },
  { "<LocalLeader>fn", "Org footnote normalize", desc = "Normalize inline footnote" },

  -- list
  { "<LocalLeader>lr", "Org list repair", desc = "Renumber list" },
  { "<LocalLeader>ls", "Org list sort", desc = "Sort list" },
  { "<LocalLeader>lh", "Org list to_subtree", desc = "Convert list to subtree" },
  { "<LocalLeader>l-", "Org toggle_item", desc = "Toggle item ↔ heading" },

  -- subtree clipboard (capital S; `s` stays free for schedule)
  { "<LocalLeader>Sc", "Org cut_subtree", desc = "Cut subtree" },
  { "<LocalLeader>Sy", "Org copy_subtree", desc = "Copy subtree" },
  { "<LocalLeader>Sp", "Org paste_subtree", desc = "Paste subtree" },

  -- view toggles -- uniform: every <LocalLeader>z<x> flips a single
  -- buf_config bit via `:Org toggle <path>`.  Per-buffer (not global)
  -- so different org files can have different visual modes.
  { "<LocalLeader>zi", "Org toggle indent.enabled", desc = "Toggle indent mode" },
  { "<LocalLeader>zb", "Org toggle modern.bullets", desc = "Toggle modern bullets" },
  { "<LocalLeader>zk", "Org toggle modern.blocks", desc = "Toggle modern blocks" },
  { "<LocalLeader>zp", "Org toggle modern.pills", desc = "Toggle modern pills" },
  { "<LocalLeader>zt", "Org toggle modern.table", desc = "Toggle modern table render" },
  { "<LocalLeader>zs", "Org toggle stars.hide", desc = "Toggle hide leading stars" },
  {
    "<LocalLeader>zd",
    "Org toggle description_list.enabled",
    desc = "Toggle description-list render",
  },
  { "<LocalLeader>ze", "Org toggle entities.enabled", desc = "Toggle pretty entities" },
  { "<LocalLeader>zm", "Org toggle emphasis.enabled", desc = "Toggle emphasis conceal" },

  -- sparse-tree views
  { "<LocalLeader>vt", "Org sparse_tree todo", desc = "Sparse tree: TODO" },
  { "<LocalLeader>v#", "Org sparse_tree tag", desc = "Sparse tree by tag" },
  { "<LocalLeader>v/", "Org sparse_tree regex", desc = "Sparse tree by regex" },
  { "<LocalLeader>vm", "Org sparse_tree match", desc = "Sparse tree by match" },
  { "<LocalLeader>vc", "Org sparse_tree clear", desc = "Clear sparse tree" },

  -- execute (dynamic blocks + babel)
  { "<LocalLeader>xu", "Org update_dblock", desc = "Update dblock at cursor" },
  { "<LocalLeader>xU", "Org update_all_dblocks", desc = "Update all dblocks" },
  { "<LocalLeader>xb", "Org babel execute", desc = "Execute src block" },
  { "<LocalLeader>xB", "Org babel execute_buffer", desc = "Execute all src blocks" },
  { "<LocalLeader>xt", "Org babel tangle", desc = "Tangle :tangle blocks" },

  -- goto / image / id / inlinetask
  { "<LocalLeader>gi", "Org image_reveal", desc = "Reveal image at cursor" },
  { "<LocalLeader>gt", "Org toggle_inline_images", desc = "Toggle inline images" },
  { "<LocalLeader>gI", "Org id get_create", desc = "Ensure :ID: on heading" },
  { "<LocalLeader>ix", "Org inline_task_insert", desc = "Insert inline task" },

  -- backlinks (one-shot for current heading) + roam buffer/graph.
  -- Mirrors Emacs roam: C-c n l (buffer toggle) → \nl, C-c n g (graph)
  -- → \ng. We add \b for the one-shot backlinks view since it's the
  -- single most-asked question for a knowledge-base setup.
  { "<LocalLeader>b", "Org backlinks", desc = "Backlinks for heading" },
  { "<LocalLeader>nl", "Org roam buffer", desc = "Toggle roam sidebar" },
  { "<LocalLeader>ng", "Org roam graph", desc = "Roam graph (float)" },
  { "<LocalLeader>nG", "Org roam graph_mermaid", desc = "Roam graph (Mermaid)" },
  { "<LocalLeader>nf", "Org roam", desc = "Roam find / create" },
  { "<LocalLeader>ni", "Org roam insert", desc = "Roam insert link" },
}

-- Group descriptions for which-key. Pressing the prefix shows this label
-- as the heading of the group menu (e.g. \a → "+archive").
M.groups = {
  { "<LocalLeader>a", group = "archive" },
  { "<LocalLeader>c", group = "clock" },
  { "<LocalLeader>f", group = "footnote" },
  { "<LocalLeader>g", group = "goto / id / image" },
  { "<LocalLeader>i", group = "insert" },
  { "<LocalLeader>l", group = "list" },
  { "<LocalLeader>n", group = "narrow / roam" },
  { "<LocalLeader>p", group = "property" },
  { "<LocalLeader>S", group = "subtree clipboard" },
  { "<LocalLeader>v", group = "sparse tree" },
  { "<LocalLeader>x", group = "execute / dblock / babel" },
  { "<LocalLeader>z", group = "view toggles" },
}

-- Build the resolved binding set: defaults overlaid with user_keys.
-- User wins on lhs collision; `{ lhs, false, ... }` removes the default.
function M.resolve(user_keys)
  local by_lhs = {}
  -- 1) seed with defaults (preserving order)
  local order = {}
  for _, b in ipairs(M.defaults) do
    by_lhs[b[1]] = b
    order[#order + 1] = b[1]
  end
  -- 2) overlay user keys
  for _, b in ipairs(user_keys or {}) do
    local lhs = b[1]
    if b[2] == false then
      by_lhs[lhs] = nil
    else
      if not by_lhs[lhs] then
        order[#order + 1] = lhs
      end
      by_lhs[lhs] = b
    end
  end
  -- 3) emit in seeded-then-appended order
  local out = {}
  for _, lhs in ipairs(order) do
    if by_lhs[lhs] then
      out[#out + 1] = by_lhs[lhs]
    end
  end
  return out
end

local function make_callback(rhs)
  if type(rhs) == "function" then
    return rhs
  end
  if type(rhs) == "string" then
    return function()
      vim.cmd(rhs)
    end
  end
  error("organ.keymaps: rhs must be string (cmd) or function; got " .. type(rhs))
end

local function modes_of(b)
  local m = b.mode
  if m == nil then
    return { "n" }
  end
  if type(m) == "string" then
    return { m }
  end
  return m
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local resolved = M.resolve(require("organ.buf_config").read(bufnr, "keys") or {})
  for _, b in ipairs(resolved) do
    local lhs, rhs = b[1], b[2]
    if lhs and rhs and rhs ~= false then
      local cb = make_callback(rhs)
      for _, mode in ipairs(modes_of(b)) do
        vim.api.nvim_buf_set_keymap(bufnr, mode, lhs, "", {
          noremap = true,
          silent = true,
          desc = b.desc or "",
          callback = cb,
        })
      end
    end
  end
end

-- Iterator helper for which-key registration. Yields one entry per
-- (lhs, mode) pair so multi-mode bindings show up under each mode.
function M.iter_bindings()
  local out = {}
  for _, b in ipairs(M.resolve(require("organ.buf_config").read(nil, "keys") or {})) do
    for _, mode in ipairs(modes_of(b)) do
      out[#out + 1] = {
        lhs = b[1],
        rhs = b[2],
        desc = b.desc or "",
        mode = mode,
      }
    end
  end
  return out
end

-- which-key.add() integration. No-op without which-key.
function M.register_which_key()
  local ok, wk = pcall(require, "which-key")
  if not ok or not wk or not wk.add then
    return false
  end
  local entries = {}
  -- Group headers (so pressing the prefix shows "+archive", "+clock", etc.
  -- instead of an unlabeled list).
  for _, g in ipairs(M.groups or {}) do
    entries[#entries + 1] = { g[1], group = g.group }
  end
  for _, b in ipairs(M.iter_bindings()) do
    entries[#entries + 1] = { b.lhs, desc = b.desc, mode = b.mode }
  end
  pcall(function()
    wk.add(entries)
  end)
  return true
end

return M
