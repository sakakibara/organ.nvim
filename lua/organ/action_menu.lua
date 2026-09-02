-- Context-aware action menu (Emacs `C-c C-c` / VSCode "Quick fix").
--
-- Inspects the cursor context (headline / list-item / drawer / link
-- / src-block / table) and presents the relevant org actions through
-- vim.ui.select. Routes each pick into the existing module that owns
-- that operation — no duplicate logic.
--
-- Powers the LSP codeAction handler too (the LSP path returns the
-- same action set as LSP CodeAction[] objects).

local M = {}

-- Build the action list for the current cursor context. Each entry:
--   { title = "…", run = function() … end }
function M.actions_at_cursor()
  local out = {}
  local function add(title, run)
    out[#out + 1] = { title = title, run = run }
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]

  -- TS-driven element classification.
  local element = require("organ.element")
  local at = element.at(bufnr, row, col)
  local kind = at and at.kind or nil
  -- on_link is its own check so the regex fallback (which doesn't
  -- classify links via at()) still works.
  local on_link = element.link_at(bufnr, row, col) ~= nil
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local on_headline = line:match("^%*+ ") ~= nil and not on_link
  local on_list = (kind == "list_item" or kind == "list")
    or (line:match("^%s*[-+*]%s") ~= nil or line:match("^%s*%d+%.%s") ~= nil)

  if on_headline then
    local function sub(path)
      return function()
        local entry = require("organ").cmd(path)
        if entry and entry.fn then
          entry.fn({ args = "", fargs = {} })
        else
          require("organ.notify").error("organ: no such command: " .. path)
        end
      end
    end
    local function line_at_cursor()
      return vim.api.nvim_win_get_cursor(0)[1]
    end
    add("Cycle TODO state", function()
      local err = require("organ.todo").cycle(bufnr, line_at_cursor())
      if err then
        require("organ.notify").error(err)
      end
    end)
    add("Set TODO from menu", function()
      local choices = { "(none)" }
      for _, k in ipairs(require("organ.todo").all_keywords()) do
        choices[#choices + 1] = k
      end
      vim.ui.select(choices, { prompt = "TODO state: " }, function(choice)
        if not choice then
          return
        end
        local state = choice == "(none)" and nil or choice
        local err = require("organ.todo").set(bufnr, line_at_cursor(), state)
        if err then
          require("organ.notify").error(err)
        end
      end)
    end)
    add("Schedule…", sub("schedule"))
    add("Set deadline…", sub("deadline"))
    add("Set priority…", function()
      local pri_cfg = require("organ.buf_config").read(nil, "priority") or {}
      local hi, lo = pri_cfg.highest or "A", pri_cfg.lowest or "C"
      local choices = { "(none)" }
      for c = string.byte(hi), string.byte(lo) do
        choices[#choices + 1] = string.char(c)
      end
      vim.ui.select(choices, { prompt = "Priority: " }, function(choice)
        if not choice then
          return
        end
        local letter = choice == "(none)" and nil or choice
        require("organ.inline_edit").set_priority(bufnr, line_at_cursor(), letter)
      end)
    end)
    add("Set tags…", sub("set_tags"))
    add("Promote subtree", sub("promote"))
    add("Demote subtree", sub("demote"))
    add("Move subtree up", sub("move_up"))
    add("Move subtree down", sub("move_down"))
    add("Refile…", sub("refile"))
    add("Archive subtree", sub("archive_subtree"))
    add("Rename headline…", function()
      require("organ.refactor").rename_at_cursor()
    end)
    add("Show backlinks", sub("backlinks"))
    add("Insert link…", function()
      require("organ.link").insert_link()
    end)
  end

  if on_list then
    add("Toggle checkbox", function()
      if not require("organ.checkbox").toggle() then
        require("organ.notify").warn("not on a list item")
      end
    end)
    add("Convert to subtree", function()
      local ok, err = require("organ.list_convert").list_to_subtree()
      if not ok then
        require("organ.notify").warn(tostring(err))
      end
    end)
  end

  if on_link then
    add("Follow link", function()
      require("organ.link").follow()
    end)
    add("Hover preview", function()
      require("organ.hover").open()
    end)
  end

  -- Always-available low-level conversions.
  if not on_headline then
    add("Convert line to headline", function()
      local kind, err = require("organ.list_convert").toggle_heading()
      if not kind then
        require("organ.notify").warn(tostring(err))
      end
    end)
    add("Convert line to list item", function()
      local kind, err = require("organ.list_convert").toggle_item()
      if not kind then
        require("organ.notify").warn(tostring(err))
      end
    end)
  end

  return out
end

-- Public: open the menu and run the chosen action.
function M.open()
  local actions = M.actions_at_cursor()
  if #actions == 0 then
    require("organ.notify").info("no org actions for this context")
    return
  end
  vim.ui.select(actions, {
    prompt = "Org action:",
    format_item = function(a)
      return a.title
    end,
  }, function(choice)
    if choice then
      choice.run()
    end
  end)
end

return M
