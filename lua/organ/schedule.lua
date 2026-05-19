-- lua/organ/schedule.lua
-- :Org schedule and :Org deadline — set/update planning timestamps.
-- Matches Emacs C-c C-s / C-c C-d.

local M = {}

local obuf = require("organ.buf")
-- Build an org active timestamp string: <YYYY-MM-DD Day>
local function format_active_ts(iso)
  local y, mo, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
  local wd = os.date("%a", t) -- Mon / Tue / Wed …
  return string.format("<%s %s>", iso, wd)
end

-- Return the 1-based line number of the planning line directly after hl_line,
-- or nil if no planning line exists there.
local function find_planning_line(bufnr, hl_line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if hl_line + 1 > total then
    return nil
  end
  local txt = vim.api.nvim_buf_get_lines(bufnr, hl_line, hl_line + 1, false)[1] or ""
  if txt:match("^%s*SCHEDULED:") or txt:match("^%s*DEADLINE:") or txt:match("^%s*CLOSED:") then
    return hl_line + 1
  end
  return nil
end

-- Extract the existing <…> timestamp string for `kind` from a planning line,
-- or nil if absent. Used by the LOGBOOK reschedule hook.
local function existing_ts(line, kind)
  return line:match(kind .. ":%s*(<[^>]*>)")
end

-- Insert or update a SCHEDULED/DEADLINE keyword on the planning line.
-- kind    = "SCHEDULED" | "DEADLINE"
-- date_str = iso string "YYYY-MM-DD"
local function _set_planning(bufnr, hl_line, kind, date_str)
  local ts = format_active_ts(date_str)
  if not ts then
    require("organ.notify").error("organ: invalid date: " .. tostring(date_str))
    return
  end

  -- Snapshot the existing timestamp BEFORE we overwrite, so the log entry can
  -- record the previous value.
  local cfg = (require("organ.buf_config").read(nil, "todo") or {})
  local policy_key = kind == "DEADLINE" and "log_redeadline" or "log_reschedule"
  local policy = cfg[policy_key]
  local verb = kind == "DEADLINE" and "New deadline" or "Rescheduled"

  local pl = find_planning_line(bufnr, hl_line)
  local old_ts
  if pl then
    local line = vim.api.nvim_buf_get_lines(bufnr, pl - 1, pl, false)[1] or ""
    old_ts = existing_ts(line, kind)
  end

  if pl then
    -- Planning line exists — update or append this kind.
    local line = vim.api.nvim_buf_get_lines(bufnr, pl - 1, pl, false)[1] or ""
    local pattern = kind .. ":%s*<[^>]*>"
    if line:match(kind .. ":") then
      -- Replace existing timestamp for this kind.
      line = line:gsub(kind .. ":%s*<[^>]*>", kind .. ": " .. ts, 1)
    else
      -- Append this kind to the line, maintaining canonical order:
      -- SCHEDULED → DEADLINE → CLOSED
      local ORDER = { "SCHEDULED", "DEADLINE", "CLOSED" }
      local new_kw = kind .. ": " .. ts
      -- Find where to insert (after any keywords that come before `kind` in the order).
      local our_pos = 1
      for i, k in ipairs(ORDER) do
        if k == kind then
          our_pos = i
          break
        end
      end
      -- Look for the last keyword whose order position < our_pos.
      local insert_after_pat = nil
      for i = our_pos - 1, 1, -1 do
        local k = ORDER[i]
        if line:match(k .. ":") then
          insert_after_pat = k .. ":%s*<[^>]*>"
          break
        end
      end
      if insert_after_pat then
        -- Insert after that keyword's timestamp.
        line = line:gsub("(" .. insert_after_pat .. ")", "%1 " .. new_kw, 1)
      else
        -- Prepend to the line (trim leading whitespace to re-add uniformly).
        local leading = line:match("^(%s*)") or ""
        line = leading .. new_kw .. " " .. line:gsub("^%s*", "")
      end
    end
    obuf.set_lines(bufnr, pl - 1, pl, { line })
  else
    -- No planning line yet — insert a new one right after the
    -- headline.  Indent via `todo._planning_indent` so SCHEDULED /
    -- DEADLINE / CLOSED all agree (the three were previously
    -- inconsistent: SCHEDULED/DEADLINE went to col 0, CLOSED to
    -- col 2).
    local indent = require("organ.todo")._planning_indent(bufnr, hl_line)
    local new_line = indent .. kind .. ": " .. ts
    obuf.set_lines(bufnr, hl_line, hl_line, { new_line })
  end

  -- LOGBOOK note (only for true CHANGES; first-time schedule with no prior
  -- value bypasses the log to avoid noise — Emacs parity).
  if old_ts and (policy == "time" or policy == "note") then
    require("organ.logbook").write_planning_change(bufnr, hl_line, policy, verb, old_ts)
  end
end

-- Public: set SCHEDULED timestamp via calendar picker.  `opts.bufnr` and
-- `opts.line` default to the current buffer + cursor line.
function M.set_schedule(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return
  end
  require("organ.calendar").pick({ title = "Schedule" }, function(iso)
    if not iso then
      return
    end -- user cancelled
    _set_planning(bufnr, hl.line, "SCHEDULED", iso)
  end)
end

-- Public: set DEADLINE timestamp via calendar picker.  `opts.bufnr` and
-- `opts.line` default to the current buffer + cursor line.
function M.set_deadline(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return
  end
  require("organ.calendar").pick({ title = "Deadline" }, function(iso)
    if not iso then
      return
    end -- user cancelled
    _set_planning(bufnr, hl.line, "DEADLINE", iso)
  end)
end

-- Expose helper for tests.
M._set_planning = _set_planning
M._format_active_ts = format_active_ts

M.commands = {
  schedule = {
    fn = function()
      M.set_schedule()
    end,
    desc = "Set/update SCHEDULED: timestamp on the headline at cursor (Emacs C-c C-s)",
  },
  deadline = {
    fn = function()
      M.set_deadline()
    end,
    desc = "Set/update DEADLINE: timestamp on the headline at cursor (Emacs C-c C-d)",
  },
}

return M
