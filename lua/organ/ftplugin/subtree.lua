-- lua/organ/ftplugin/subtree.lua
-- Buffer-local attach for structure keymaps.

local M = {}

function M.attach(bufnr)
  local struct_cfg = require("organ.buf_config").read(nil, "structure") or {}
  if struct_cfg.enabled == false then
    return
  end
  -- Rule 2: keymaps = false disables all bindings for this feature.
  if struct_cfg.keymaps == false then
    return
  end
  local cfg = struct_cfg.keymaps or {}
  -- All slot → command mappings, including the *_alt aliases so users with
  -- no Alt-key support can stay productive. The same callback (with count
  -- support) is installed for both primary and alt variants.
  -- Each value is the dispatch path resolved via `require("organ").cmd`.
  local cmd_map = {
    promote_subtree = "promote",
    demote_subtree = "demote",
    promote_subtree_alt = "promote",
    demote_subtree_alt = "demote",
    promote_headline = "promote_headline",
    demote_headline = "demote_headline",
    promote_headline_alt = "promote_headline",
    demote_headline_alt = "demote_headline",
    move_subtree_up = "move_up",
    move_subtree_down = "move_down",
    move_subtree_up_alt = "move_up",
    move_subtree_down_alt = "move_down",
    meta_return = "meta_return",
  }
  local descs = {
    promote_subtree = "promote subtree",
    demote_subtree = "demote subtree",
    promote_subtree_alt = "promote subtree (alt)",
    demote_subtree_alt = "demote subtree (alt)",
    promote_headline = "promote headline",
    demote_headline = "demote headline",
    promote_headline_alt = "promote headline (alt)",
    demote_headline_alt = "demote headline (alt)",
    move_subtree_up = "move subtree up",
    move_subtree_down = "move subtree down",
    move_subtree_up_alt = "move subtree up (alt)",
    move_subtree_down_alt = "move subtree down (alt)",
    meta_return = "insert element below (M-RET)",
  }
  local function dispatch(path)
    local entry = require("organ").cmd(path)
    if not entry or not entry.fn then
      require("organ.notify").warn("organ: subcommand `" .. path .. "` not registered")
      return
    end
    entry.fn({ args = "", fargs = {} })
  end

  -- Which promote/demote slots get a visual-mode binding, and the
  -- direction.  move_* / meta_return have no region semantics.
  local visual_dir = {
    promote_subtree = "promote",
    demote_subtree = "demote",
    promote_subtree_alt = "promote",
    demote_subtree_alt = "demote",
    promote_headline = "promote",
    demote_headline = "demote",
    promote_headline_alt = "promote",
    demote_headline_alt = "demote",
  }

  -- Visual-mode promote/demote: shift the level of EVERY heading in the
  -- selection by one step (Emacs region M-LEFT/M-RIGHT).  `native` is
  -- the literal key to fall through to when the selection contains NO
  -- heading (so a bare `<`/`>` keeps Vim's visual-indent on
  -- non-heading selections); nil = org-only chord (no native meaning).
  local function visual_op(dir, native)
    return function()
      local n = math.max(1, vim.v.count1)
      local vs = vim.fn.getpos("v")[2]
      local cur = vim.fn.getpos(".")[2]
      local s = math.min(vs, cur)
      local e = math.max(vs, cur)
      local structure = require("organ.structure")
      local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
      if structure._range_has_headline(0, s, e) then
        -- Leave visual mode first (the selection is consumed), then
        -- shift the selected headings.  Line range stays valid because
        -- each rewrite is in-place (no line-count change).
        vim.api.nvim_feedkeys(esc, "nx", false)
        local fn = (dir == "promote") and structure.promote_region or structure.demote_region
        for _ = 1, n do
          local err = fn({ start_line = s, end_line = e })
          if err then
            require("organ.notify").warn(err)
            break
          end
        end
      elseif native then
        -- No heading in the selection: preserve Vim's native visual
        -- indent.  Re-feed the key (noremap, so this map doesn't
        -- recurse); still in visual mode here so it indents + exits.
        local keys = (n > 1 and tostring(n) or "") .. native
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
      else
        -- org-only chord (e.g. <M-h>) with no heading selected: nothing
        -- to do; just leave visual mode.
        vim.api.nvim_feedkeys(esc, "nx", false)
      end
    end
  end

  -- Derive the visual-mode lhs + native-fallthrough key for a slot's
  -- normal-mode lhs.  A bare `<`/`<<`/... collapses to a single `<`
  -- (Vim's visual indent operator is single-char) with `<` fallthrough;
  -- likewise `>`.  Everything else (Alt chords, <LocalLeader>< ...) maps
  -- as-is with no native fallthrough.
  local function visual_binding(lhs)
    if lhs:match("^<+$") then
      return "<", "<"
    elseif lhs:match("^>+$") then
      return ">", ">"
    end
    return lhs, nil
  end

  for key, path in pairs(cmd_map) do
    local lhs = cfg[key]
    if lhs and lhs ~= "" and lhs ~= false then
      -- A bare `<<`/`>>` chord falls through to Vim's native indent when
      -- the cursor is not on a headline, so `>>` on a DEADLINE / body /
      -- list line just changes its indent (matching the visual-mode
      -- binding). Alt / LocalLeader chords have no native meaning and
      -- always run the structure op.
      local native = (lhs:match("^<+$") or lhs:match("^>+$")) and lhs or nil
      -- Normal-mode binding for every action.
      vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
        noremap = true,
        silent = true,
        desc = descs[key] or key,
        callback = function()
          -- Honor `vim.v.count` so `2>>` demotes twice, `3<<` promotes
          -- thrice, etc. Default count is 0 which we map to 1.
          local n = math.max(1, vim.v.count1)
          if native then
            local cur = vim.fn.line(".")
            if not require("organ.structure")._range_has_headline(0, cur, cur) then
              pcall(vim.cmd, "normal! " .. (n > 1 and tostring(n) or "") .. native)
              return
            end
          end
          for _ = 1, n do
            dispatch(path)
          end
        end,
      })
      -- Insert-mode binding: same chord, count fixed at 1.  Users
      -- drafting a headline can promote / demote / move without leaving
      -- insert (matches Emacs's mode-less binding model).
      --
      -- Stay in insert mode throughout: dispatch mutates the buffer and
      -- moves the cursor to the new line via nvim APIs (mode-agnostic),
      -- so the user can keep typing the heading title immediately.
      -- Earlier versions did a stopinsert -> dispatch -> startinsert!
      -- dance, but stopinsert fires InsertLeave AFTER dispatch has
      -- moved the cursor onto the new `* ` line; user autocmds that
      -- "strip trailing whitespace on InsertLeave" (a common config)
      -- then ate the trailing space, producing `*` instead of `* `.
      if key == "meta_return" then
        vim.api.nvim_buf_set_keymap(bufnr, "i", lhs, "", {
          noremap = true,
          silent = true,
          desc = descs[key] or key,
          callback = function()
            dispatch(path)
          end,
        })
      else
        vim.api.nvim_buf_set_keymap(bufnr, "i", lhs, "", {
          noremap = true,
          silent = true,
          desc = descs[key] or key,
          callback = function()
            dispatch(path)
          end,
        })
      end
      -- Visual-mode binding for promote/demote slots: shift every
      -- heading in the selection by one step (Emacs region behaviour).
      -- A bare `<`/`>` stays context-aware (native indent when the
      -- selection holds no heading).
      local dir = visual_dir[key]
      if dir then
        local vlhs, native = visual_binding(lhs)
        vim.api.nvim_buf_set_keymap(bufnr, "x", vlhs, "", {
          noremap = true,
          silent = true,
          desc = (descs[key] or key) .. " (visual selection)",
          callback = visual_op(dir, native),
        })
      end
    end
  end
end

return M
