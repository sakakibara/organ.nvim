-- vim.ui.select fallback backend.  No external picker dep -- works
-- on any nvim install.  Used as the auto-fallback when snacks /
-- telescope / fzf-lua aren't loaded so :Org refile / :Org find /
-- :Org capture etc. work out of the box.  UX is plain (a single
-- numbered list, no fuzzy matching, no preview) but the operations
-- complete; users who want a richer picker install snacks et al.

local M = {}

function M.pick(items, opts)
  opts = opts or {}
  if not items or #items == 0 then
    return
  end

  -- Build the display list.  Reuse organ's per-item display fields
  -- when present (`display` > `match` > `title`); fall back to a
  -- best-effort string when nothing structured is on the item.
  local function format_item(item)
    return item.display or item.match or item.title or item.text or item.file or tostring(item)
  end

  vim.ui.select(items, {
    prompt = opts.prompt or "Pick:",
    format_item = format_item,
  }, function(choice)
    if not choice then
      return
    end

    -- Map snacks-style action keymaps to a single default action --
    -- vim.ui.select returns just the picked item, no key context, so
    -- we always invoke the configured default (jump, refile_here, etc.)
    -- when the user makes a choice.  Custom keymaps from the snacks
    -- backend (split / vsplit / tab / backlinks etc.) aren't reachable
    -- here -- that's the tradeoff for working without a real picker.
    local default = opts.default_action or "jump"
    local action = (opts.actions or {})[default]
    if action then
      action(choice)
    end
  end)
end

return M
