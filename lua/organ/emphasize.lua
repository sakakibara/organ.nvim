-- Emphasis markup -- Emacs org-emphasize (C-c C-x C-f).
--
-- Wrap a span in one of org's emphasis markers.  Existing matched
-- marker pairs around the span are peeled off first, so re-emphasizing
-- `/italic/` as bold yields `*italic*` rather than `*/italic/*`, and the
-- `remove` marker strips emphasis outright (Emacs spells that SPC,
-- which a command line cannot carry).

local M = {}

local obuf = require("organ.buf")

-- org-emphasis-alist keys, in its own order.
M.MARKERS = { "*", "/", "_", "=", "~", "+" }

local MARKER_SET = {}
for _, m in ipairs(M.MARKERS) do
  MARKER_SET[m] = true
end

-- org-emphasis-regexp-components: characters that may precede an
-- opening marker, and characters that may follow a closing one.  A
-- neighbour outside its class gets a padding space, so the emphasis
-- stays valid org.
local PRE = "[-%s('\"{]"
local POST = "[-%s.,:!?;'\")}\\%[]"

-- Peel matched marker pairs off both ends (Emacs's strip loop), then
-- wrap in `marker` ("" removes emphasis).
local function rewrap(text, marker)
  while #text > 1 and text:sub(1, 1) == text:sub(-1) and MARKER_SET[text:sub(1, 1)] do
    text = text:sub(2, -2)
  end
  return marker .. text .. marker
end

-- Resolve a user-supplied marker name to the string to wrap with.
-- Returns nil plus a reason for anything org has no marker for.
function M.resolve_marker(name)
  if name == nil or name == "" then
    return nil, "no emphasis marker given"
  end
  if name == "remove" or name == " " then
    return ""
  end
  if MARKER_SET[name] then
    return name
  end
  return nil, ("no such emphasis marker: %s"):format(name)
end

-- Byte span [s, e] (1-based, inclusive) of the word under `col`
-- (0-based byte column) in `text`, extended over any matched pair of
-- emphasis markers already wrapping it.  nil when the cursor is not on
-- a word character.
local function word_span(text, col)
  local i = col + 1
  if not text:sub(i, i):match("[%w_]") then
    return nil
  end
  local s, e = i, i
  while s > 1 and text:sub(s - 1, s - 1):match("[%w_]") do
    s = s - 1
  end
  while e < #text and text:sub(e + 1, e + 1):match("[%w_]") do
    e = e + 1
  end
  while
    s > 1
    and e < #text
    and MARKER_SET[text:sub(s - 1, s - 1)]
    and text:sub(s - 1, s - 1) == text:sub(e + 1, e + 1)
  do
    s, e = s - 1, e + 1
  end
  return s, e
end

-- Replace the byte span [s, e] of row `row` (1-based) with `text`,
-- padding either side when the neighbouring character would otherwise
-- swallow the marker.  Returns the resulting cursor byte column.
local function splice(bufnr, row, s, e, text)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local before = line:sub(1, s - 1)
  local after = line:sub(e + 1)
  if before ~= "" and not before:sub(-1):match(PRE) then
    before = before .. " "
  end
  if after ~= "" and not after:sub(1, 1):match(POST) then
    after = " " .. after
  end
  obuf.set_lines(bufnr, row - 1, row, { before .. text .. after })
  return #before + #text
end

-- Emphasize a byte span of one row.  `s`/`e` are 1-based inclusive; an
-- empty span (e < s) inserts the bare markers.  Returns nil on success
-- or an error string.
function M.span(bufnr, row, s, e, marker_name)
  local marker, why = M.resolve_marker(marker_name)
  if not marker then
    return why
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if not line then
    return "no such line"
  end
  local text = (e >= s) and line:sub(s, e) or ""
  local col = splice(bufnr, row, s, e, rewrap(text, marker))
  if text == "" and marker ~= "" then
    col = col - #marker
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { row, math.max(0, col) })
  return nil
end

-- Emphasize the last charwise visual selection, the word at the cursor,
-- or -- with the cursor on no word -- insert the bare marker pair with
-- the cursor between them (Emacs's no-region behaviour).
function M.dispatch(marker_name, use_selection)
  local bufnr = vim.api.nvim_get_current_buf()
  if use_selection then
    local sp, ep = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if sp[2] ~= ep[2] then
      return "emphasis applies to a selection on one line"
    end
    local line = vim.api.nvim_buf_get_lines(bufnr, sp[2] - 1, sp[2], false)[1] or ""
    local e = math.min(ep[3], #line)
    return M.span(bufnr, sp[2], sp[3], e, marker_name)
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(bufnr, cur[1] - 1, cur[1], false)[1] or ""
  local s, e = word_span(line, cur[2])
  if not s then
    s, e = cur[2] + 1, cur[2]
  end
  return M.span(bufnr, cur[1], s, e, marker_name)
end

M.commands = {
  emphasize = {
    fn = function(cmd)
      local name = cmd and cmd.args ~= "" and cmd.args or nil
      -- A charwise `:'<,'>` invocation is the only one whose byte
      -- columns are meaningful; a plain `:N,MOrg` range is not.
      local charwise = cmd
        and cmd.range
        and cmd.range > 0
        and vim.fn.visualmode() == "v"
        and vim.fn.getpos("'<")[2] == cmd.line1
        and vim.fn.getpos("'>")[2] == cmd.line2
      local function apply(marker)
        local err = M.dispatch(marker, charwise)
        if err then
          require("organ.notify").warn(err)
        end
      end
      if name then
        apply(name)
        return
      end
      local choices = vim.list_extend(vim.list_slice(M.MARKERS), { "remove" })
      vim.ui.select(choices, { prompt = "Emphasis marker:" }, function(choice)
        if choice then
          apply(choice)
        end
      end)
    end,
    nargs = "?",
    range = true,
    complete = function(arg_lead)
      local out = {}
      for _, m in ipairs(vim.list_extend(vim.list_slice(M.MARKERS), { "remove" })) do
        if m:sub(1, #arg_lead) == arg_lead then
          out[#out + 1] = m
        end
      end
      return out
    end,
    desc = "Wrap the selection / word at cursor in an emphasis marker (Emacs C-c C-x C-f)",
  },
}

return M
