local M = {}

M.defaults = {
  enabled = false,
  commands = {
    n = "next_visible",
    p = "prev_visible",
    f = "fold_cycle",
    F = "fold_cycle_global",
    t = "todo_cycle",
    T = "todo_set",
    s = "schedule",
    d = "deadline",
    a = "archive",
    A = "archive_to_sibling",
    I = "clock_in",
    O = "clock_out",
    g = "agenda",
    c = "capture",
    ["?"] = "show_help",
    ["<"] = "promote",
    [">"] = "demote",
    ["U"] = "move_up",
    ["D"] = "move_down",
  },
}

local function at_headline_col0()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  if col ~= 0 then
    return false
  end
  return line:match("^%*+%s") ~= nil
end

local DISPATCH = {
  next_visible = function()
    vim.cmd("normal! ]]")
  end,
  prev_visible = function()
    vim.cmd("normal! [[")
  end,
  fold_cycle = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    require("organ.fold").cycle(bufnr, line)
  end,
  fold_cycle_global = function()
    require("organ.fold").cycle_global(vim.api.nvim_get_current_buf())
  end,
  todo_cycle = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local err = require("organ.todo").cycle(bufnr, line)
    if err then
      require("organ.notify").error(err)
    end
  end,
  todo_set = function()
    local choices = { "(none)" }
    for _, k in ipairs(require("organ.todo").all_keywords()) do
      choices[#choices + 1] = k
    end
    vim.ui.select(choices, { prompt = "TODO state: " }, function(choice)
      if not choice then
        return
      end
      local state = choice == "(none)" and nil or choice
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local err = require("organ.todo").set(bufnr, line, state)
      if err then
        require("organ.notify").error(err)
      end
    end)
  end,
  schedule = function()
    require("organ.schedule").set_schedule()
  end,
  deadline = function()
    require("organ.schedule").set_deadline()
  end,
  archive = function()
    local err, arc_path = require("organ.archive").archive_subtree()
    if err then
      require("organ.notify").error(err)
    else
      require("organ.notify").info("archived to " .. (arc_path or "archive file"))
    end
  end,
  archive_to_sibling = function()
    local err = require("organ.archive").archive_to_sibling()
    if err then
      require("organ.notify").error(err)
    else
      require("organ.notify").info("subtree archived to sibling")
    end
  end,
  clock_in = function()
    require("organ.clock").start()
  end,
  clock_out = function()
    require("organ.clock").stop()
  end,
  agenda = function()
    require("organ.agenda").dispatch()
  end,
  capture = function()
    require("organ.capture").open()
  end,
  show_help = function()
    local cfg = (require("organ.buf_config").read(nil, "speed") or {}).commands
      or M.defaults.commands
    local lines = { "organ.speed commands (active when cursor is at column 0 of a headline):" }
    local keys = {}
    for k in pairs(cfg) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      lines[#lines + 1] = string.format("  %-3s  %s", k, tostring(cfg[k]))
    end
    vim.api.nvim_echo({ { table.concat(lines, "\n"), "None" } }, true, {})
  end,
  promote = function()
    local err = require("organ.structure").promote_subtree()
    if err then
      require("organ.notify").warn(err)
    end
  end,
  demote = function()
    local err = require("organ.structure").demote_subtree()
    if err then
      require("organ.notify").warn(err)
    end
  end,
  move_up = function()
    local err = require("organ.structure").move_subtree_up()
    if err then
      require("organ.notify").warn(err)
    end
  end,
  move_down = function()
    local err = require("organ.structure").move_subtree_down()
    if err then
      require("organ.notify").warn(err)
    end
  end,
}

function M.dispatch(action)
  local fn
  if type(action) == "function" then
    fn = action
  elseif type(action) == "string" then
    fn = DISPATCH[action]
  end
  if fn then
    fn()
  else
    require("organ.notify").warn("organ.speed: unknown command")
  end
end

function M.is_active()
  return at_headline_col0()
end

local function expr_dispatch(key, action)
  return function()
    if at_headline_col0() then
      M.dispatch(action)
    else
      -- Pass through as the literal key so vim's default mapping (or none)
      -- applies.  We use feedkeys with the 'n' flag so it isn't remapped.
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
    end
  end
end

function M.attach(bufnr)
  local cfg = (require("organ.buf_config").read(nil, "speed") or {})
  if cfg.enabled == false then
    return
  end
  local commands = cfg.commands or M.defaults.commands
  for key, action in pairs(commands) do
    if action ~= false and key ~= false then
      vim.api.nvim_buf_set_keymap(bufnr, "n", key, "", {
        noremap = true,
        silent = true,
        desc = "Speed: " .. tostring(action),
        callback = expr_dispatch(key, action),
      })
    end
  end
end

return M
