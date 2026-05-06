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
        emit(ctx.visual_text or "")
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
        elseif n2 == "t" or n2 == "T" then
          prompt_date_idx = prompt_date_idx + 1
          emit((prompts.dates or {})[prompt_date_idx] or "")
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

-- Prompt pass: scan body for %^{...} / %^g / %^t / %^T placeholders and
-- fire interactive UI for each, populating ctx.prompts. Returns true on
-- success, false if any prompt was cancelled.
function M.prompt_pass(body, ctx)
  ctx.prompts = ctx.prompts or { text = {}, tags = nil, dates = {} }
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
        local prompt_label, choices = content:match("^([^|]*)|(.*)$")
        if choices then
          local opts = {}
          for opt in (choices .. "|"):gmatch("([^|]*)|") do
            opts[#opts + 1] = opt
          end
          local choice
          vim.ui.select(opts, { prompt = prompt_label .. ": " }, function(c)
            choice = c
          end)
          if choice == nil then
            return false
          end
          ctx.prompts.text[#ctx.prompts.text + 1] = choice
        else
          local input
          vim.ui.input({ prompt = (content == "" and "" or content) .. ": " }, function(v)
            input = v
          end)
          if input == nil then
            return false
          end
          ctx.prompts.text[#ctx.prompts.text + 1] = input
        end
        i = close + 1
      else
        i = pct + 2
      end
    elseif n2 == "g" then
      local input
      vim.ui.input({ prompt = "Tags: " }, function(v)
        input = v
      end)
      if input == nil then
        return false
      end
      ctx.prompts.tags = input
      i = pct + 3
    elseif n2 == "t" or n2 == "T" then
      local default = (n2 == "T") and os.date("%Y-%m-%d %H:%M", ctx.now or os.time())
        or os.date("%Y-%m-%d", ctx.now or os.time())
      local input
      vim.ui.input({ prompt = "Date: ", default = default }, function(v)
        input = v
      end)
      if input == nil then
        return false
      end
      ctx.prompts.dates[#ctx.prompts.dates + 1] = input
      i = pct + 3
    else
      i = pct + 2
    end
  end
  return true
end

return M
