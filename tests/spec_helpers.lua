local M = {}

function M.parse_abnf_or_skip(path)
  vim.fn.system({ "python3", "-c", "import abnf" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local script = string.format(
    [[
import sys, abnf
try:
    text = open(%q).read()
    abnf.Rule.create_from_string(text)
    print('OK')
except Exception as e:
    print('FAIL: ' + str(e), file=sys.stderr); sys.exit(1)
]],
    path
  )
  local out = vim.fn.system({ "python3", "-c", script })
  if vim.v.shell_error == 0 and out:match("^OK") then
    return true
  end
  io.stderr:write(out)
  return false
end

function M.find_rule_names(path)
  local f = assert(io.open(path, "r"), "cannot read " .. path)
  local txt = f:read("*a")
  f:close()
  local names, seen = {}, {}
  for line in txt:gmatch("[^\n]+") do
    local name = line:match("^([%w%-]+)%s*=")
    if name and not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  return names
end

return M
