-- telescope.nvim adapter for organ.nvim find pickers.
-- Spec: same contract as snacks.lua — pick(items, opts).

local M = {}

local function telescope_or_nil()
  local ok, mod = pcall(require, "telescope.pickers")
  return ok and mod or nil
end

function M.pick(items, opts)
  local pickers = telescope_or_nil()
  if not pickers then
    require("organ.notify").error(
      "telescope.nvim not loaded; configure config.find.backend or install telescope"
    )
    return
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local default_action = opts.default_action or "jump"
  local find = require("organ.find")

  pickers
    .new({}, {
      prompt_title = opts.title or "Find",
      finder = finders.new_table({
        results = items,
        -- entry.display can be a function returning (text, highlights)
        -- where highlights is { { {start_byte, end_byte}, hl_group } }.
        -- When organ pre-built display_segments (build_items in
        -- find.lua does this for headline + link sources), convert to
        -- the byte-range form so todo states / priorities / tags /
        -- paths render with their semantic colors.  Fall back to the
        -- plain string for callers that don't supply segments.
        entry_maker = function(item)
          local display_fn
          if item.display_segments and #item.display_segments > 0 then
            local text, ranges = find.segments_to_ranges(item.display_segments)
            display_fn = function()
              return text, ranges
            end
          end
          return {
            value = item,
            display = display_fn or item.display,
            ordinal = item.match or item.display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        -- Default <CR> runs default_action.
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and opts.actions[default_action] then
            opts.actions[default_action](entry.value)
          end
        end)
        -- Per-action keymaps for non-default keys.  <CR> is reserved
        -- for the picker's default action (wired via select_default
        -- above); skip it defensively even if a user passes it.
        for action_name, lhs in pairs(opts.keymaps or {}) do
          local fn = opts.actions[action_name]
          if fn and lhs and lhs ~= "<CR>" then
            for _, mode in ipairs({ "n", "i" }) do
              map(mode, lhs, function()
                local entry = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if entry then
                  fn(entry.value)
                end
              end)
            end
          end
        end
        -- "create" key: hand the current prompt text to opts.create(query).
        if opts.create and opts.keymaps and opts.keymaps.create then
          for _, mode in ipairs({ "n", "i" }) do
            map(mode, opts.keymaps.create, function()
              local picker = action_state.get_current_picker(prompt_bufnr)
              local query = picker and picker:_get_prompt() or ""
              actions.close(prompt_bufnr)
              opts.create(query)
            end)
          end
        end
        return true
      end,
    })
    :find()
end

return M
