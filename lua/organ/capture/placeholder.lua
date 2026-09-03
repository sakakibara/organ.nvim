-- Capture placeholder substitution.

local M = {}

local function fmt_date(now, with_time, inactive)
  local fmt = with_time and "%Y-%m-%d %a %H:%M" or "%Y-%m-%d %a"
  local s = os.date(fmt, now)
  if inactive then
    return "[" .. s .. "]"
  end
  return "<" .. s .. ">"
end

-- Turn a `%^t`-family prompt answer into an org timestamp.  A date-less
-- answer means today; the time is written when the answer carries one
-- or the placeholder letter is uppercase (org-capture.el
-- `org-insert-timestamp` with `org-time-was-given`).
local function answer_timestamp(answer, now, upper, inactive)
  answer = answer or ""
  local y, mo, d = answer:match("(%d%d%d%d)%-(%d%d?)%-(%d%d?)")
  local h, mi = answer:match("(%d%d?):(%d%d)")
  local base = os.date("*t", now or os.time())
  local ts = os.time({
    year = y and tonumber(y) or base.year,
    month = mo and tonumber(mo) or base.month,
    day = d and tonumber(d) or base.day,
    hour = h and tonumber(h) or base.hour,
    min = mi and tonumber(mi) or base.min,
    sec = 0,
  })
  return fmt_date(ts, upper or h ~= nil, inactive)
end

local function annotation(ctx)
  if ctx.source_headline_id and ctx.source_headline_id ~= "" then
    return string.format("[[id:%s][%s]]", ctx.source_headline_id, ctx.source_headline_title or "")
  end
  if ctx.source_headline_title and ctx.source_headline_title ~= "" then
    return string.format(
      "[[file:%s::*%s][%s]]",
      ctx.source_file or "",
      ctx.source_headline_title,
      ctx.source_headline_title
    )
  end
  if ctx.source_file and ctx.source_file ~= "" then
    local base = vim.fn.fnamemodify(ctx.source_file, ":t")
    local line = (ctx.source_cursor and ctx.source_cursor[1]) or 1
    return string.format("[[file:%s][%s:%d]]", ctx.source_file, base, line)
  end
  return ""
end

-- Substitution pass. Pure transformation; reads only ctx.
-- Returns (text, cursor_offset_or_nil). Cursor offset is the byte offset
-- of the FIRST %? in the result string (0-based).
function M.expand(body, ctx)
  ctx = ctx or {}
  local prompts = ctx.prompts or { text = {}, tags = nil, dates = {} }

  local out = {}
  local cursor_offset = nil
  local out_len = 0
  local i = 1
  local prompt_text_idx = 0
  local prompt_date_idx = 0

  local function emit(s)
    out[#out + 1] = s
    out_len = out_len + #s
  end

  -- Text emitted so far on the current output line.
  local function line_lead()
    return table.concat(out):match("[^\n]*$")
  end

  while i <= #body do
    local ch = body:sub(i, i)
    if ch ~= "%" then
      emit(ch)
      i = i + 1
    else
      local n1 = body:sub(i + 1, i + 1)
      if n1 == "%" then
        emit("%")
        i = i + 2
      elseif n1 == "?" then
        if cursor_offset == nil then
          cursor_offset = out_len
        end
        i = i + 2
      elseif n1 == "t" then
        emit(fmt_date(ctx.now, false, false))
        i = i + 2
      elseif n1 == "T" then
        emit(fmt_date(ctx.now, true, false))
        i = i + 2
      elseif n1 == "u" then
        emit(fmt_date(ctx.now, false, true))
        i = i + 2
      elseif n1 == "U" then
        emit(fmt_date(ctx.now, true, true))
        i = i + 2
      elseif n1 == "a" then
        emit(annotation(ctx))
        i = i + 2
      elseif n1 == "i" then
        -- Every inserted line repeats the text that precedes %i on its
        -- line (org-capture.el "repeat leading characters before
        -- initial place holder every line").
        local lead = "\n" .. line_lead()
        emit((ctx.visual_text or ""):gsub("\n", function()
          return lead
        end))
        i = i + 2
      elseif n1 == "f" then
        -- %f → source file basename (no path).
        emit(ctx.source_file and vim.fn.fnamemodify(ctx.source_file, ":t") or "")
        i = i + 2
      elseif n1 == "F" then
        -- %F → source file absolute path.
        emit(ctx.source_file or "")
        i = i + 2
      elseif n1 == "n" then
        -- %n → user login name.
        emit(
          (vim.uv and vim.uv.os_get_passwd and vim.uv.os_get_passwd().username)
            or vim.fn.expand("$USER")
            or ""
        )
        i = i + 2
      elseif n1 == "x" then
        -- %x → system clipboard contents (best-effort; empty on failure).
        local ok, val = pcall(vim.fn.getreg, "+")
        emit((ok and val) or "")
        i = i + 2
      elseif n1 == "c" then
        -- %c → most recent yank/kill.
        local ok, val = pcall(vim.fn.getreg, "0")
        emit((ok and val) or "")
        i = i + 2
      elseif n1 == "<" then
        local close = body:find(">", i + 2, true)
        if close then
          local fmt = body:sub(i + 2, close - 1)
          emit(os.date(fmt, ctx.now))
          i = close + 1
        else
          emit(ch)
          i = i + 1 -- malformed: leave the % alone
        end
      elseif n1 == "^" then
        local n2 = body:sub(i + 2, i + 2)
        if n2 == "{" then
          local close = body:find("}", i + 3, true)
          if close then
            prompt_text_idx = prompt_text_idx + 1
            emit((prompts.text or {})[prompt_text_idx] or "")
            i = close + 1
          else
            emit(ch)
            i = i + 1
          end
        elseif n2 == "g" then
          emit(prompts.tags or "")
          i = i + 3
        elseif n2 == "t" or n2 == "T" or n2 == "u" or n2 == "U" then
          prompt_date_idx = prompt_date_idx + 1
          local answer = (prompts.dates or {})[prompt_date_idx]
          emit(answer_timestamp(answer, ctx.now, n2 == "T" or n2 == "U", n2 == "u" or n2 == "U"))
          i = i + 3
        else
          emit(ch)
          i = i + 1
        end
      else
        -- Unknown %X escape: leave verbatim (matches Emacs lenient behavior).
        emit(ch .. n1)
        i = i + 2
      end
    end
  end

  return table.concat(out), cursor_offset
end

-- Scan body for the interactive placeholders, in order.
local function collect_prompts(body)
  local steps = {}
  local i = 1
  while i <= #body do
    local pct = body:find("%%%^", i)
    if not pct then
      break
    end
    local n2 = body:sub(pct + 2, pct + 2)
    if n2 == "{" then
      local close = body:find("}", pct + 3, true)
      if close then
        local content = body:sub(pct + 3, close - 1)
        local label, choices = content:match("^([^|]*)|(.*)$")
        if choices then
          local opts = {}
          for opt in (choices .. "|"):gmatch("([^|]*)|") do
            opts[#opts + 1] = opt
          end
          steps[#steps + 1] = { kind = "select", label = label, opts = opts }
        else
          steps[#steps + 1] = { kind = "text", label = content }
        end
        i = close + 1
      else
        i = pct + 2
      end
    elseif n2 == "g" then
      steps[#steps + 1] = { kind = "tags" }
      i = pct + 3
    elseif n2 == "t" or n2 == "T" or n2 == "u" or n2 == "U" then
      steps[#steps + 1] = { kind = "date", with_time = (n2 == "T" or n2 == "U") }
      i = pct + 3
    else
      i = pct + 2
    end
  end
  return steps
end

-- Prompt pass: fire interactive UI for each %^{...} / %^g / %^t / %^T /
-- %^u / %^U placeholder, populating ctx.prompts.  Prompts chain through
-- their vim.ui callbacks, so a UI that answers asynchronously works.
-- `cb(ok)` runs once every prompt has answered (false when one was
-- cancelled).  The return value is that same result when the UI
-- answered synchronously, nil otherwise.
function M.prompt_pass(body, ctx, cb)
  ctx.prompts = ctx.prompts or { text = {}, tags = nil, dates = {} }
  local steps = collect_prompts(body)
  local result

  local function finish(ok)
    result = ok
    if cb then
      cb(ok)
    end
  end

  local function run(k)
    local step = steps[k]
    if not step then
      return finish(true)
    end
    local function answered(v, store)
      if v == nil then
        return finish(false)
      end
      store(v)
      run(k + 1)
    end
    if step.kind == "select" then
      vim.ui.select(step.opts, { prompt = step.label .. ": " }, function(v)
        answered(v, function(c)
          ctx.prompts.text[#ctx.prompts.text + 1] = c
        end)
      end)
    elseif step.kind == "text" then
      vim.ui.input({ prompt = step.label .. ": " }, function(v)
        answered(v, function(c)
          ctx.prompts.text[#ctx.prompts.text + 1] = c
        end)
      end)
    elseif step.kind == "tags" then
      vim.ui.input({ prompt = "Tags: " }, function(v)
        answered(v, function(c)
          ctx.prompts.tags = c
        end)
      end)
    else
      local now = ctx.now or os.time()
      local default = step.with_time and os.date("%Y-%m-%d %H:%M", now) or os.date("%Y-%m-%d", now)
      vim.ui.input({ prompt = "Date: ", default = default }, function(v)
        answered(v, function(c)
          ctx.prompts.dates[#ctx.prompts.dates + 1] = c
        end)
      end)
    end
  end

  run(1)
  return result
end

return M
