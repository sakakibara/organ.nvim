-- Snacks.picker adapter for organ.nvim find pickers.

local M = {}

local function snacks_or_nil()
  if _G.Snacks and _G.Snacks.picker then
    return _G.Snacks.picker
  end
  local ok, mod = pcall(require, "snacks.picker")
  return ok and mod or nil
end

function M.pick(items, opts)
  local picker = snacks_or_nil()
  if not picker then
    require("organ.notify").error(
      "snacks.nvim not loaded; configure config.find.backend or install snacks.nvim"
    )
    return
  end

  -- Translate organ's item shape to snacks's: file (path), pos
  -- ({ line, col } 1-based), text (fuzzy-match string).  Snacks's
  -- matcher errors with "attempt to index local 'str' (a nil
  -- value)" the moment the user types into a picker without text.
  for _, item in ipairs(items) do
    if item.file_path and not item.file then
      item.file = item.file_path
    end
    if item.line_start and not item.pos then
      item.pos = { item.line_start + 1, 0 }
    end
    if not item.text then
      item.text = item.match or item.display or item.title or ""
    end
  end

  local default = opts.default_action or "jump"

  -- Wrap each action: pull item from the picker if snacks didn't
  -- pass one (signature shifts across snacks versions), close the
  -- picker FIRST so the action's `:edit` / buffer mutation lands
  -- in the user's window, THEN run the action.
  local actions = {}
  for name, fn in pairs(opts.actions) do
    actions[name] = function(p, item)
      item = item or (p and p.current and p:current())
      if p and p.close then
        p:close()
      end
      if item then
        fn(item)
      end
    end
  end
  -- `confirm` aliases the default action.  Snacks routes <CR>
  -- through this name; without it Enter falls back to snacks's
  -- built-in jump which navigates to file:pos and silently
  -- swallows refile / insert_link actions.
  actions.confirm = actions[default]
  if opts.create then
    actions.organ_create = function(p)
      local query = p.input and p.input.filter and p.input.filter.pattern or ""
      if p and p.close then
        p:close()
      end
      opts.create(query)
    end
  end

  -- Build per-action keymaps.  <CR> is reserved for the picker's
  -- default action (wired via top-level confirm below); skip it
  -- defensively even if a user passes it in their keymaps.
  local keys = {}
  for action_name, lhs in pairs(opts.keymaps or {}) do
    if lhs and lhs ~= "" and lhs ~= "<CR>" and actions[action_name] then
      keys[lhs] = { action_name, mode = { "n", "i" } }
    end
  end
  if opts.create and opts.keymaps and opts.keymaps.create and opts.keymaps.create ~= "<CR>" then
    keys[opts.keymaps.create] = { "organ_create", mode = { "n", "i" } }
  end

  picker.pick({
    title = opts.title or "Find",
    items = items,
    format = function(item)
      if item.display_segments and #item.display_segments > 0 then
        return item.display_segments
      end
      return { { item.display } }
    end,
    -- Top-level confirm: close picker first, then run default
    -- action against the picked item.  Same shape as actions.confirm
    -- above so <CR> behavior is identical regardless of which
    -- snacks version routes <CR> where.
    confirm = function(p, item)
      item = item or (p and p.current and p:current())
      if p and p.close then
        p:close()
      end
      if item and opts.actions[default] then
        opts.actions[default](item)
      end
    end,
    actions = actions,
    win = { input = { keys = keys } },
  })
end

return M
