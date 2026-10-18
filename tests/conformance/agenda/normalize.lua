-- Agenda gate normalization (rules and reasons in NORMALIZE.md): drop
-- trailing blanks, and move organ's keymap footer out of each view into
-- a "--- footer" section of its own.

local footer = { "" }
vim.list_extend(footer, require("organ.agenda.render").FOOTER_LINES)

local function strip_footer(view)
  local n = #view - #footer
  if n < 1 then
    return view, nil
  end
  for i, l in ipairs(footer) do
    if view[n + i] ~= l then
      return view, nil
    end
  end
  return vim.list_slice(view, 1, n), vim.list_slice(view, n + 1)
end

return function(text, side)
  text = text:gsub("[ \t]+\n", "\n"):gsub("[ \t]+$", "")
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  local views, current = {}, nil
  for _, line in ipairs(lines) do
    if line:match("^=== ") or not current then
      current = {}
      views[#views + 1] = current
    end
    current[#current + 1] = line
  end
  local out = {}
  for _, view in ipairs(views) do
    local body, foot = view, nil
    if side == "organ" then
      body, foot = strip_footer(view)
    end
    vim.list_extend(out, body)
    if view[1] and view[1]:match("^=== ") then
      out[#out + 1] = "--- footer"
      vim.list_extend(out, foot or {})
    end
  end
  return table.concat(out, "\n") .. "\n"
end
