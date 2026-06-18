-- Shared LOGBOOK helpers used by todo state changes, schedule/deadline
-- mutations, and refile.
--
-- All entry kinds share the Emacs `- <verb> ... <ts> \\` line format and the
-- same drawer-vs-bare placement rule (config.todo.log_into_drawer).

local M = {}

local obuf = require("organ.buf")
local drawer = require("organ.drawer")

local function get_todo_cfg()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return require("organ.buf_config").read(nil, "todo") or {}
end

local DOW = { [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local function now_inactive_ts()
  local t = os.date("*t")
  local dow = DOW[tonumber(os.date("%w", os.time(t)))]
  return string.format("[%04d-%02d-%02d %s %02d:%02d]", t.year, t.month, t.day, dow, t.hour, t.min)
end

-- Build a state-change entry: `- State "TO"       from "FROM"       <ts> \\`.
function M.build_state_entry(from_state, to_state, note)
  local ts = now_inactive_ts()
  local first = string.format(
    '- State "%s"       from "%s"       %s \\\\',
    to_state or "(none)",
    from_state or "(none)",
    ts
  )
  if note and note ~= "" then
    return { first, "  " .. note }
  end
  return { first }
end

-- Build a `- Rescheduled from "<old>" on <ts>` entry. `verb` is one of
-- "Rescheduled" | "New deadline" | "Refiled" — matches Emacs phrasing.
function M.build_planning_entry(verb, old_value, note)
  local ts = now_inactive_ts()
  local body
  if old_value and old_value ~= "" then
    body = string.format('- %s from "%s" on %s \\\\', verb, old_value, ts)
  else
    body = string.format("- %s on %s \\\\", verb, ts)
  end
  if note and note ~= "" then
    return { body, "  " .. note }
  end
  return { body }
end

-- Insert `entry_lines` (list) into the LOGBOOK drawer for the headline at
-- hl_line. Honors todo.log_into_drawer and todo.log_drawer.
function M.append(bufnr, hl_line, entry_lines)
  local cfg = get_todo_cfg()
  local drawer_name = cfg.log_drawer or "LOGBOOK"
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if cfg.log_into_drawer == false then
    local pos = drawer.insert_position(lines, hl_line, bufnr)
    obuf.set_lines(bufnr, pos - 1, pos - 1, entry_lines)
    return
  end

  local s, _ = drawer.find(lines, hl_line, drawer_name, bufnr)
  if s then
    -- Newest first: insert just after the :DRAWER: line.
    obuf.set_lines(bufnr, s, s, entry_lines)
  else
    local pos = drawer.insert_position(lines, hl_line, bufnr)
    local block = { ":" .. drawer_name .. ":" }
    for _, l in ipairs(entry_lines) do
      block[#block + 1] = l
    end
    block[#block + 1] = ":END:"
    obuf.set_lines(bufnr, pos - 1, pos - 1, block)
  end
end

-- Resolve a "time" | "note" | false | nil policy. If "time", call append
-- synchronously with no note. If "note", prompt via vim.ui.input and append
-- after user confirms (cancelled prompt → no entry). Returns immediately;
-- the prompt path is async-friendly.
function M.write_planning_change(bufnr, hl_line, policy, verb, old_value)
  if policy ~= "time" and policy ~= "note" then
    return
  end
  if policy == "time" then
    M.append(bufnr, hl_line, M.build_planning_entry(verb, old_value, nil))
    return
  end
  local prompt = string.format("%s note: ", verb)
  vim.ui.input({ prompt = prompt }, function(note)
    if note == nil then
      return
    end -- cancelled
    M.append(bufnr, hl_line, M.build_planning_entry(verb, old_value, note))
    -- Save so BufWritePost reindexes.
    local cur = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_set_current_buf, bufnr)
    pcall(vim.cmd, "silent! write")
    pcall(vim.api.nvim_set_current_buf, cur)
  end)
end

return M
