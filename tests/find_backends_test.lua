-- Picker backend integration test: mocks each picker (snacks, telescope,
-- fzf-lua), runs find.pick for each backend × source combo, and asserts
-- the items handed to the picker have the shape that picker requires.
--
-- Catches the class of bugs we hit:
--   - snacks picker missing `item.file` (preview pane error)
--   - snacks picker missing `item.text` (matcher crash on filter input)
--   - snacks picker missing `item.pos` (cursor restore broken)
--   - any backend missing `item.display` (renders blank)
--
-- Run via: nvim --headless -l tests/find_backends_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Stub the query layer so backends exercise without a real DB.
local sample_headlines = {
  {
    id = "h1",
    file_path = "/tmp/a.org",
    title = "First headline",
    line_start = 0,
    level = 1,
    todo_state = "TODO",
    priority = "A",
    tags = { "work", "urgent" },
  },
  {
    id = "h2",
    file_path = "/tmp/b.org",
    title = "Second headline",
    line_start = 4,
    level = 2,
    tags = {},
  },
}
local sample_files = {
  { file_path = "/tmp/a.org", basename = "a.org", headline_count = 5 },
  { file_path = "/tmp/b.org", basename = "b.org", headline_count = 3 },
}
local sample_links = {
  {
    id = "h1",
    file_path = "/tmp/a.org",
    title = "First",
    line_start = 0,
    link_target = "id:abc",
    link_description = "see ABC",
  },
}

package.loaded["organ.query"] = {
  headlines = function()
    return sample_headlines
  end,
  files = function()
    return sample_files
  end,
  links = function()
    return sample_links
  end,
  agenda = function()
    return {}
  end,
}

require("organ").setup({ org_dir = "/tmp" })
local find = require("organ.find")

-- Capturing mock for snacks.picker
local snacks_call
package.loaded["snacks.picker"] = {
  pick = function(opts)
    snacks_call = { opts = opts, items = opts.items }
  end,
}

local function reset()
  snacks_call = nil
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- snacks: source = "files"
do
  reset()
  find.pick({ source = "files", default_action = "jump", backend = "snacks" })
  check("snacks files: pick was called", snacks_call ~= nil)
  if snacks_call then
    local item = snacks_call.items[1]
    check(
      "snacks files: item.file populated (snacks preview needs it)",
      item.file ~= nil and type(item.file) == "string",
      "item.file=" .. tostring(item.file)
    )
    check(
      "snacks files: item.text populated (matcher needs it)",
      item.text ~= nil and type(item.text) == "string",
      "item.text=" .. tostring(item.text)
    )
    check(
      "snacks files: item.display populated (format needs it)",
      item.display ~= nil,
      "item.display=" .. tostring(item.display)
    )
    check(
      "snacks files: item.kind == 'file'",
      item.kind == "file",
      "item.kind=" .. tostring(item.kind)
    )
    check(
      "snacks files: original item.file_path preserved (organ action handlers need it)",
      item.file_path ~= nil
    )
  end
end

-- snacks: source = "headlines"
do
  reset()
  find.pick({ source = "headlines", default_action = "jump", backend = "snacks" })
  check("snacks headlines: pick was called", snacks_call ~= nil)
  if snacks_call then
    local item = snacks_call.items[1]
    check("snacks headlines: item.file populated", item.file ~= nil)
    check("snacks headlines: item.text populated", item.text ~= nil)
    check("snacks headlines: item.display populated", item.display ~= nil)
    check(
      "snacks headlines: item.pos populated (cursor restore needs it)",
      item.pos ~= nil and type(item.pos) == "table",
      "item.pos=" .. vim.inspect(item.pos)
    )
    if item.pos then
      check(
        "snacks headlines: item.pos[1] is 1-based line",
        item.pos[1] == (item.line_start or 0) + 1,
        "pos[1]=" .. tostring(item.pos[1]) .. " line_start=" .. tostring(item.line_start)
      )
    end
    check("snacks headlines: item.line_start preserved", item.line_start ~= nil)
    check("snacks headlines: item.title preserved", item.title ~= nil)
  end
end

-- snacks: actions table
do
  reset()
  find.pick({ source = "files", default_action = "jump", backend = "snacks" })
  if snacks_call then
    check(
      "snacks: actions table has 'jump' wrapped",
      type(snacks_call.opts.actions) == "table"
        and type(snacks_call.opts.actions.jump) == "function"
    )
    check(
      "snacks: actions.confirm exists for <CR> dispatch",
      type(snacks_call.opts.actions.confirm) == "function"
    )
    check(
      "snacks: top-level confirm callback present",
      type(snacks_call.opts.confirm) == "function"
    )
  end
end

-- telescope mock
local telescope_call
package.loaded["telescope.finders"] = {
  new_table = function(t)
    telescope_call = telescope_call or {}
    telescope_call.finder = t
    return t
  end,
}
package.loaded["telescope.pickers"] = {
  new = function(_, opts)
    telescope_call = telescope_call or {}
    telescope_call.opts = opts
    return { find = function() end }
  end,
}
package.loaded["telescope.config"] =
  { values = {
    generic_sorter = function()
      return {}
    end,
  } }
package.loaded["telescope.actions"] = {
  select_default = setmetatable({}, {
    __index = function()
      return function() end
    end,
  }),
  close = function() end,
}
package.loaded["telescope.actions.state"] = {
  get_selected_entry = function()
    return { value = nil }
  end,
}

do
  telescope_call = nil
  find.pick({ source = "files", default_action = "jump", backend = "telescope" })
  check("telescope files: picker was created", telescope_call ~= nil)
  if telescope_call and telescope_call.finder then
    local first_item = telescope_call.finder.results[1]
    -- entry_maker reads display + match (for ordinal)
    check("telescope files: item.display populated", first_item.display ~= nil)
    check("telescope files: item.match populated (used as ordinal)", first_item.match ~= nil)
    -- Run entry_maker to verify it produces { value, display, ordinal }
    local entry = telescope_call.finder.entry_maker(first_item)
    check("telescope files: entry_maker produces value", entry.value ~= nil)
    check("telescope files: entry_maker produces display", entry.display ~= nil)
    check("telescope files: entry_maker produces ordinal", entry.ordinal ~= nil)
  end
end

-- fzf-lua mock
local fzf_call
package.loaded["fzf-lua"] = {
  fzf_exec = function(lines, opts)
    fzf_call = { lines = lines, opts = opts }
  end,
}

do
  fzf_call = nil
  find.pick({ source = "files", default_action = "jump", backend = "fzf_lua" })
  check("fzf_lua files: fzf_exec was called", fzf_call ~= nil)
  if fzf_call then
    check(
      "fzf_lua files: lines is an array of strings",
      type(fzf_call.lines) == "table" and type(fzf_call.lines[1]) == "string",
      "first line type=" .. type(fzf_call.lines and fzf_call.lines[1])
    )
    check(
      "fzf_lua files: lines have 'index\\tdisplay' format",
      fzf_call.lines[1]:match("^%d+\t.+") ~= nil,
      "first line=" .. tostring(fzf_call.lines[1])
    )
    check(
      "fzf_lua files: actions.default callback is set",
      type(fzf_call.opts.actions) == "table"
        and type(fzf_call.opts.actions["default"]) == "function"
    )
  end
end

-- Action-execution tests: invoking confirm/actions actually opens the file
-- (or runs the right command). This is the layer above shape — catches
-- bugs like the snacks close-order issue where the action fired but the
-- buffer didn't change.

-- Capture vim.cmd / nvim_win_set_cursor calls so we can assert side effects.
local cmd_log
local cursor_log
local original_cmd = vim.cmd
local original_set_cursor = vim.api.nvim_win_set_cursor
local function start_capturing()
  cmd_log = {}
  cursor_log = {}
  vim.cmd = function(s)
    cmd_log[#cmd_log + 1] = s
  end
  vim.api.nvim_win_set_cursor = function(w, p)
    cursor_log[#cursor_log + 1] = { w, p }
  end
end
local function stop_capturing()
  vim.cmd = original_cmd
  vim.api.nvim_win_set_cursor = original_set_cursor
end

-- snacks: file pick → top-level confirm callback fires `:edit <file>`
do
  reset()
  find.pick({ source = "files", default_action = "jump", backend = "snacks" })
  if snacks_call then
    local item = snacks_call.items[1] -- /tmp/a.org
    start_capturing()
    -- Mock picker handle has a no-op close (we already test close-order via
    -- ordering of close vs action; here we focus on "did the action run?")
    local mock_picker = {
      current = function()
        return item
      end,
      close = function() end,
    }
    snacks_call.opts.confirm(mock_picker, item)
    stop_capturing()

    local edit_cmd = nil
    for _, c in ipairs(cmd_log) do
      if c:match("^edit ") then
        edit_cmd = c
        break
      end
    end
    check(
      "snacks files: confirm fires `:edit <file>`",
      edit_cmd ~= nil,
      "cmd_log=" .. vim.inspect(cmd_log)
    )
    check(
      "snacks files: edit targets the actual file_path",
      edit_cmd and edit_cmd:find("/tmp/a%.org") ~= nil,
      "edit_cmd=" .. tostring(edit_cmd)
    )
  end
end

-- snacks: headline pick → confirm fires `:edit <file>` AND positions cursor
do
  reset()
  find.pick({ source = "headlines", default_action = "jump", backend = "snacks" })
  if snacks_call then
    local item = snacks_call.items[1] -- line_start = 0
    start_capturing()
    local mock_picker = {
      current = function()
        return item
      end,
      close = function() end,
    }
    snacks_call.opts.confirm(mock_picker, item)
    stop_capturing()

    local edit_cmd = nil
    for _, c in ipairs(cmd_log) do
      if c:match("^edit ") then
        edit_cmd = c
        break
      end
    end
    check("snacks headlines: confirm fires `:edit`", edit_cmd ~= nil)
    check(
      "snacks headlines: cursor positioned after edit",
      #cursor_log >= 1,
      "cursor_log=" .. vim.inspect(cursor_log)
    )
    if #cursor_log >= 1 then
      local pos = cursor_log[1][2]
      check(
        "snacks headlines: cursor row is line_start + 1 (1-based)",
        pos[1] == (item.line_start or 0) + 1,
        "pos=" .. vim.inspect(pos) .. " line_start=" .. tostring(item.line_start)
      )
    end
  end
end

-- snacks: close-then-act ordering — mock that records call order
do
  reset()
  find.pick({ source = "files", default_action = "jump", backend = "snacks" })
  if snacks_call then
    local item = snacks_call.items[1]
    local order = {}
    start_capturing()
    -- Wrap vim.cmd to also record relative order
    local orig = vim.cmd
    vim.cmd = function(s)
      orig(s)
      if s:match("^edit ") then
        table.insert(order, "EDIT")
      end
    end
    local mock_picker = {
      current = function()
        return item
      end,
      close = function()
        table.insert(order, "CLOSE")
      end,
    }
    snacks_call.opts.confirm(mock_picker, item)
    stop_capturing()

    -- Critical: close must come BEFORE edit so the edit lands in the user's
    -- original window, not the picker window which is about to be torn down.
    check(
      "snacks: close fires BEFORE edit (so edit targets user's window)",
      order[1] == "CLOSE" and order[2] == "EDIT",
      "order=" .. vim.inspect(order)
    )
  end
end

-- snacks: actions.confirm (the actions-table fallback dispatch) also fires
do
  reset()
  find.pick({ source = "files", default_action = "jump", backend = "snacks" })
  if snacks_call and snacks_call.opts.actions and snacks_call.opts.actions.confirm then
    local item = snacks_call.items[1]
    start_capturing()
    local mock_picker = {
      current = function()
        return item
      end,
      close = function() end,
    }
    snacks_call.opts.actions.confirm(mock_picker, item)
    stop_capturing()
    local edit_fired = false
    for _, c in ipairs(cmd_log) do
      if c:match("^edit /tmp/a%.org") then
        edit_fired = true
        break
      end
    end
    check(
      "snacks: actions.confirm dispatches the default action too",
      edit_fired,
      "cmd_log=" .. vim.inspect(cmd_log)
    )
  end
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("find_backends_test: PASS")
