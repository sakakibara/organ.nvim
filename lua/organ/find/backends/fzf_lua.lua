-- fzf-lua adapter for organ.nvim find pickers.
-- Spec: same contract as snacks.lua — pick(items, opts).
--
-- fzf-lua's fzf_exec returns the user's selected line as a string. We
-- prefix each entry with a numeric id, then map back to the original item
-- in actions. The display column shows item.display unchanged.

local M = {}

local function fzf_or_nil()
  local ok, mod = pcall(require, "fzf-lua")
  return ok and mod or nil
end

function M.pick(items, opts)
  local fzf = fzf_or_nil()
  if not fzf then
    require("organ.notify").error(
      "fzf-lua not loaded; configure config.find.backend or install fzf-lua"
    )
    return
  end

  -- Index entries so we can recover the item from the picked line.
  -- Convert display_segments (when present) to ANSI-wrapped strings
  -- so fzf renders todo states / priorities / tags / paths with the
  -- same semantic colors snacks shows.  Fall back to the plain
  -- display string when the item has no segments or when fzf-lua's
  -- utility module isn't available; in those cases `--ansi` is a
  -- harmless no-op.
  local find = require("organ.find")
  local index = {}
  local lines = {}
  local any_ansi = false
  for i, item in ipairs(items) do
    index[i] = item
    local body
    if item.display_segments and #item.display_segments > 0 then
      local s, used_ansi = find.segments_to_ansi(item.display_segments)
      body = s
      if used_ansi then
        any_ansi = true
      end
    else
      body = item.display or ""
    end
    lines[#lines + 1] = string.format("%d\t%s", i, body)
  end

  local default_action = opts.default_action or "jump"

  local function pick_item(selected_line)
    if not selected_line or selected_line == "" then
      return nil
    end
    local id = tonumber(selected_line:match("^(%d+)\t"))
    return id and index[id] or nil
  end

  -- fzf-lua maps Vim-style keys to handler tables. Build the table from
  -- our action map.
  local fzf_actions = {}
  fzf_actions["default"] = function(sel)
    local item = pick_item(sel and sel[1])
    if item and opts.actions[default_action] then
      opts.actions[default_action](item)
    end
  end
  -- Per-action keys for non-default keys.  <CR> is reserved for
  -- fzf_actions["default"] above; skip defensively even if a user
  -- passes it in their keymaps.
  for action_name, lhs in pairs(opts.keymaps or {}) do
    local fn = opts.actions[action_name]
    if fn and lhs and lhs ~= "<CR>" then
      fzf_actions[lhs] = function(sel)
        local item = pick_item(sel and sel[1])
        if item then
          fn(item)
        end
      end
    end
  end
  if opts.create and opts.keymaps and opts.keymaps.create then
    fzf_actions[opts.keymaps.create] = function(_, fzf_opts)
      local query = fzf_opts and fzf_opts.last_query or ""
      opts.create(query)
    end
  end

  -- `--ansi` enables ANSI-escape-driven coloring; only set when at
  -- least one line carries codes.  `--with-nth=2..` hides the leading
  -- index column so the user only sees the colored body, while we
  -- still recover the item by parsing the index from the raw
  -- selected line.
  local fzf_opts = { ["--with-nth"] = "2..", ["--delimiter"] = "\t" }
  if any_ansi then
    fzf_opts["--ansi"] = true
  end

  -- Window title (fzf-lua native title slot, padded for visibility)
  -- vs the input-prompt prefix which stays at fzf-lua's default '> '.
  local title = opts.title or "Find"
  fzf.fzf_exec(lines, {
    winopts = { title = " " .. title .. " ", title_pos = "center" },
    actions = fzf_actions,
    fzf_opts = fzf_opts,
  })
end

return M
