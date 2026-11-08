-- Fuzz of the duration gate: items generated from fixed seeds, written as
-- case files, rendered by Emacs (emacs.el) and by organ (organ.lua) and
-- compared line by line.  Emacs prints "!! out of range" for an item that
-- crosses the range condition, so organ must refuse exactly there and
-- answer byte for byte everywhere else.

local M = {}

local root = vim.fn.getcwd()

local printer = require("organ.elisp.printer")

local SEEDS = { 1, 2, 3, 4, 5 }
local STRINGS = 1500
local VALUES = 250
local LISTS = 300
local RANDOM_FORMATS = 3
local MAX_TOKENS = 12
local CHUNK = 2000

-- floor(2^53 / 60): from_minutes refuses from just above it.
local Q = 150119987579016

local function new_rng(seed)
  local s = seed * 7919 % 2147483646 + 1
  local function next_s()
    s = s * 48271 % 2147483647
    return s
  end
  return {
    int = function(lo, hi)
      return lo + next_s() % (hi - lo + 1)
    end,
    real = function()
      return next_s() / 2147483647
    end,
  }
end

local G = {}
G.__index = G

function G:int(lo, hi)
  return self.rng.int(lo, hi)
end

function G:chance(p)
  return self.rng.real() < p
end

function G:pick(t)
  return t[self.rng.int(1, #t)]
end

local function lisp_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r") .. '"'
end

-- Strings

local UNIT_TOKENS = {
  "min",
  "h",
  "d",
  "m",
  "w",
  "y",
  "MIN",
  "Min",
  "mIn",
  "H",
  "D",
  "M",
  "W",
  "Y",
  "mins",
  "hr",
  "s",
  "mi",
}
local BLANKS = { " ", "\t", "  ", " \t" }
local NOISE = {
  "x",
  "e",
  "E",
  "+",
  "-",
  ".",
  ":",
  "\r",
  "\n",
  '"',
  "\\",
  ",",
  "/",
  "\u{130}",
  "\u{131}",
  "\u{212A}",
  "\u{FF48}",
  "\u{17F}",
}

function G:digits(n)
  local t = {}
  for i = 1, n do
    t[i] = string.char(48 + self:int(0, 9))
  end
  return table.concat(t)
end

function G:number()
  local r = self:int(1, 100)
  local n
  if r <= 70 then
    n = self:int(1, 3)
  elseif r <= 85 then
    n = self:int(4, 8)
  elseif r <= 95 then
    n = self:int(15, 25)
  else
    n = self:int(30, 60)
  end
  local s = self:digits(n)
  if self:chance(0.2) then
    s = s .. "." .. self:digits(self:int(0, 3))
  end
  return s
end

function G:blank()
  return self:chance(0.4) and self:pick(BLANKS) or ""
end

function G:unit()
  return self:chance(0.6) and self:pick({ "min", "h", "d", "m", "w", "y" })
    or self:pick(UNIT_TOKENS)
end

function G:hms()
  local function two()
    return self:chance(0.9) and self:digits(2) or self:digits(self:pick({ 1, 3 }))
  end
  local s = self:digits(self:chance(0.8) and self:int(1, 3) or self:int(14, 20)) .. ":" .. two()
  if self:chance(0.4) then
    s = s .. ":" .. two()
  end
  return s
end

-- A string as a token list, from a template, then mutated.
function G:tokens()
  local t = {}
  local function add(x)
    t[#t + 1] = x
  end
  local function units()
    for _ = 1, self:int(1, 4) do
      add(self:blank())
      add(self:number())
      add(self:blank())
      add(self:unit())
    end
  end
  local kind = self:int(1, 6)
  if kind <= 2 then
    units()
  elseif kind == 3 then
    add(self:blank())
    add(self:hms())
  elseif kind == 4 then
    units()
    add(self:blank())
    add(self:hms())
  elseif kind == 5 then
    add(self:number())
  else
    for _ = 1, self:int(1, 8) do
      local c = self:int(1, 5)
      add(
        c == 1 and self:number()
          or c == 2 and self:unit()
          or c == 3 and self:pick(BLANKS)
          or c == 4 and self:pick(NOISE)
          or self:hms()
      )
    end
  end
  add(self:blank())
  if self:chance(0.3) then
    for _ = 1, self:int(1, 2) do
      local at = self:int(1, #t + 1)
      local op = self:int(1, 3)
      local new =
        self:pick({ self:pick(NOISE), self:pick(BLANKS), self:digits(1), ":", self:unit() })
      if op == 1 then
        table.insert(t, at, new)
      elseif op == 2 and t[at] then
        table.remove(t, at)
      elseif t[at] then
        t[at] = new
      end
    end
  end
  while #t > MAX_TOKENS do
    table.remove(t)
  end
  return t
end

function G:duration()
  return table.concat(self:tokens())
end

-- Minutes

local function float_src(x)
  if x ~= x then
    return "0.0e+NaN"
  end
  return printer.float_string(x)
end

-- A value and whether it is integral (then it is also sent as an
-- integer).
function G:minutes()
  local r = self:int(1, 100)
  local x
  if r <= 15 then
    x = self:int(0, 3000)
  elseif r <= 30 then
    x = self:pick({ 60, 1440, 10080, 43200, 525960 }) * self:int(0, 20) + self:int(-2, 2)
  elseif r <= 40 then
    x = self:int(0, 999999) * self:pick({ 1, 1000, 1000000 })
  elseif r <= 50 then
    x = Q + self:int(-50, 50)
  elseif r <= 57 then
    x =
      self:pick({ Q + self:int(1, 1000000), 2 ^ 53 + self:int(-100, 100) * 2, 2 ^ 60, 1e18, 1e20 })
  elseif r <= 70 then
    x = self:int(0, 100000) + self:int(0, 3) / 4
  elseif r <= 80 then
    x = self:int(0, 100000) + self.rng.real()
  elseif r <= 85 then
    x = self.rng.real() * self:pick({ 1e-10, 1, 60, 1e6 })
  elseif r <= 95 then
    x = Q + self:int(-64, 64) / 32
  else
    x = self:pick({ -0.0, math.huge, -math.huge, 0 / 0, 1e300, 5e-324 })
  end
  if x == x and self:chance(0.25) then
    x = -x
  end
  return x
end

local FORMATS = {
  "h:mm",
  "h:mm:ss",
  "nil",
  '(("d") (special . h:mm:ss))',
  '(("d") ("h") ("min"))',
  '(("y") ("m") ("w") ("d") ("h") ("min") compact)',
  '(("h" . t) (special . 1))',
  '(("min") (special . 0))',
  '(("d") ("min"))',
  '(("w" . t) (special . h:mm) compact)',
  '(("min" . t))',
  '(("y") (special . h:mm))',
  '(("d") (special . h:mm))',
  "(compact)",
  "((special . 2))",
}

function G:format()
  local entries = {}
  for _ = 1, self:int(0, 4) do
    local u = self:chance(0.05) and "x" or self:pick({ "min", "h", "d", "w", "m", "y" })
    entries[#entries + 1] = self:chance(0.3) and string.format('("%s" . t)', u)
      or string.format('("%s")', u)
  end
  if self:chance(0.5) then
    local mode = self:pick({ "h:mm", "h:mm:ss", "0", "1", "2", "3", "-1" })
    table.insert(entries, self:int(1, #entries + 1), "(special . " .. mode .. ")")
  end
  if self:chance(0.3) then
    table.insert(entries, self:int(1, #entries + 1), "compact")
  end
  return "(" .. table.concat(entries, " ") .. ")"
end

local function write(path, lines)
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

local function read_lines(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local t = vim.split(f:read("*a"), "\n", { plain = true })
  f:close()
  if t[#t] == "" then
    t[#t] = nil
  end
  return t
end

-- The items of one seed.
local function items_of(seed)
  local g = setmetatable({ rng = new_rng(seed) }, G)
  local items = {}
  local function add(s)
    items[#items + 1] = s
  end
  for _ = 1, STRINGS do
    local s = lisp_string(g:duration())
    add("(p " .. s .. ")")
    add("(to-minutes " .. s .. ")")
    add("(to-minutes " .. s .. " t)")
  end
  for _ = 1, VALUES do
    local x = g:minutes()
    local srcs = { float_src(x) }
    if x == math.floor(x) and math.abs(x) < math.huge and 1 / x ~= -math.huge then
      srcs[2] = string.format("%.0f", x)
    end
    local formats = vim.list_extend({}, FORMATS)
    for _ = 1, RANDOM_FORMATS do
      formats[#formats + 1] = g:format()
    end
    for _, src in ipairs(srcs) do
      for _, f in ipairs(formats) do
        add(string.format("(from-minutes %s %s%s)", src, f, g:chance(0.2) and " t" or ""))
      end
    end
  end
  for _ = 1, LISTS do
    local l = {}
    for k = 1, g:int(0, 4) do
      l[k] = lisp_string(g:chance(0.5) and (g:blank() .. g:hms() .. g:blank()) or g:duration())
    end
    add("(h-mm-only-p (" .. table.concat(l, " ") .. "))")
  end
  return items
end

--- Run the fuzz: problems go to `problems`; returns a summary.
function M.run(area, problems)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local chunks, files = {}, {}
  for _, seed in ipairs(SEEDS) do
    local items = items_of(seed)
    for first = 1, #items, CHUNK do
      local part = { unpack(items, first, math.min(first + CHUNK - 1, #items)) }
      local path = string.format("%s/fuzz-%d-%06d.el", dir, seed, first)
      write(path, part)
      files[#files + 1] = path
      chunks[#chunks + 1] = { seed = seed, path = path, items = part }
    end
  end
  local list = dir .. "/cases.txt"
  vim.fn.writefile(files, list)
  local log = vim.fn.system({
    "env",
    "TZ=UTC",
    "LC_ALL=C",
    "timeout",
    "-k",
    "5",
    "300",
    "emacs",
    "--batch",
    "-Q",
    "-l",
    root .. "/tests/conformance/_collate.el",
    "-l",
    root .. "/tests/conformance/duration/emacs.el",
    "--eval",
    string.format("(conformance-run %q %q nil)", list, dir),
  })
  if vim.v.shell_error ~= 0 then
    problems[#problems + 1] =
      string.format("fuzz: emacs failed (exit %d): %s", vim.v.shell_error, log:sub(1, 2000))
    vim.fn.delete(dir, "rf")
    return "emacs failed"
  end
  local stats = {}
  local shown = 0
  local total = { items = 0, refused = 0, disagree = 0 }
  for _, ch in ipairs(chunks) do
    local st = stats[ch.seed] or { items = 0, refused = 0, disagree = 0 }
    stats[ch.seed] = st
    local want = read_lines(ch.path .. ".out") or {}
    if #want ~= #ch.items then
      problems[#problems + 1] = string.format(
        "fuzz: %s: emacs wrote %d lines for %d items",
        vim.fn.fnamemodify(ch.path, ":t"),
        #want,
        #ch.items
      )
    end
    for i, src in ipairs(ch.items) do
      local ok, got = pcall(area.item, src)
      if not ok then
        got = "ORGAN-ERROR: " .. tostring(got):gsub("\n", " ")
      end
      st.items = st.items + 1
      if want[i] == "!! out of range" then
        st.refused = st.refused + 1
      end
      if got ~= want[i] then
        st.disagree = st.disagree + 1
        shown = shown + 1
        if shown <= 20 then
          problems[#problems + 1] = string.format(
            "fuzz seed %d: %s\n    emacs: %s\n    organ: %s",
            ch.seed,
            src,
            tostring(want[i]),
            got
          )
        end
      end
    end
  end
  vim.fn.delete(dir, "rf")
  local parts = {}
  for _, seed in ipairs(SEEDS) do
    local st = stats[seed]
    total.items = total.items + st.items
    total.refused = total.refused + st.refused
    total.disagree = total.disagree + st.disagree
    parts[#parts + 1] = string.format("seed %d: %d items, %d refused", seed, st.items, st.refused)
  end
  if total.disagree > 0 then
    problems[#problems + 1] = string.format("fuzz: %d disagreement(s)", total.disagree)
  end
  return string.format(
    "%d seeds, %d items, %d refused, %d disagreements (%s)",
    #SEEDS,
    total.items,
    total.refused,
    total.disagree,
    table.concat(parts, "; ")
  )
end

return M
