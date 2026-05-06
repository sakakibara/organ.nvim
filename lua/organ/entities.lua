local M = {}

-- Subset of Emacs `org-entities` covering the everyday math / Greek /
-- arrow set. Users can add more via `entities.extra` config.
M.builtin = {
  -- Greek lowercase
  alpha = "α",
  beta = "β",
  gamma = "γ",
  delta = "δ",
  epsilon = "ε",
  varepsilon = "ε",
  zeta = "ζ",
  eta = "η",
  theta = "θ",
  vartheta = "ϑ",
  iota = "ι",
  kappa = "κ",
  lambda = "λ",
  mu = "μ",
  nu = "ν",
  xi = "ξ",
  pi = "π",
  varpi = "ϖ",
  rho = "ρ",
  varrho = "ϱ",
  sigma = "σ",
  varsigma = "ς",
  tau = "τ",
  upsilon = "υ",
  phi = "φ",
  varphi = "φ",
  chi = "χ",
  psi = "ψ",
  omega = "ω",
  -- Greek uppercase
  Gamma = "Γ",
  Delta = "Δ",
  Theta = "Θ",
  Lambda = "Λ",
  Xi = "Ξ",
  Pi = "Π",
  Sigma = "Σ",
  Upsilon = "Υ",
  Phi = "Φ",
  Psi = "Ψ",
  Omega = "Ω",
  -- Arrows
  to = "→",
  rightarrow = "→",
  Rightarrow = "⇒",
  leftarrow = "←",
  Leftarrow = "⇐",
  leftrightarrow = "↔",
  Leftrightarrow = "⇔",
  uparrow = "↑",
  downarrow = "↓",
  longrightarrow = "⟶",
  longleftarrow = "⟵",
  -- Math symbols
  pm = "±",
  mp = "∓",
  times = "×",
  div = "÷",
  cdot = "·",
  ast = "∗",
  star = "⋆",
  leq = "≤",
  geq = "≥",
  neq = "≠",
  approx = "≈",
  equiv = "≡",
  sim = "∼",
  propto = "∝",
  infty = "∞",
  partial = "∂",
  nabla = "∇",
  forall = "∀",
  exists = "∃",
  nexists = "∄",
  in_ = "∈",
  notin = "∉",
  subset = "⊂",
  supset = "⊃",
  cap = "∩",
  cup = "∪",
  emptyset = "∅",
  sum = "∑",
  prod = "∏",
  int = "∫",
  oint = "∮",
  -- Common typography
  ldots = "…",
  dots = "…",
  quot = '"',
  amp = "&",
  copy = "©",
  reg = "®",
  trade = "™",
  ndash = "–",
  mdash = "—",
  hellip = "…",
  laquo = "«",
  raquo = "»",
  -- Logical / set theory
  ["and"] = "∧",
  ["or"] = "∨",
  ["not"] = "¬",
  iff = "⇔",
  implies = "⇒",
}

local LATEX_TO_UNICODE = {}

local function rebuild_table()
  LATEX_TO_UNICODE = {}
  for k, v in pairs(M.builtin) do
    if k:sub(-1) == "_" then
      k = k:sub(1, -2)
    end
    LATEX_TO_UNICODE["\\" .. k] = v
  end
  local extra = (require("organ").config.entities or {}).extra or {}
  for k, v in pairs(extra) do
    LATEX_TO_UNICODE["\\" .. k] = v
  end
end

function M.lookup(text)
  if next(LATEX_TO_UNICODE) == nil then
    rebuild_table()
  end
  return LATEX_TO_UNICODE[text]
end

function M.refresh()
  rebuild_table()
end

local NS = vim.api.nvim_create_namespace("organ_entities")
local PATTERN = "\\([A-Za-z]+)"

-- Scan a single line and apply conceal extmarks for any \name occurrence.
local function decorate_line(bufnr, lnum, line)
  local i = 1
  while true do
    local s, e, name = line:find(PATTERN, i)
    if not s then
      break
    end
    local literal = "\\" .. name
    local glyph = M.lookup(literal)
    if glyph then
      vim.api.nvim_buf_set_extmark(bufnr, NS, lnum - 1, s - 1, {
        end_col = e,
        conceal = glyph,
        hl_group = "@org.entity",
      })
    end
    i = e + 1
  end
end

local function decorate_buffer(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  if next(LATEX_TO_UNICODE) == nil then
    rebuild_table()
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    decorate_line(bufnr, i, line)
  end
end

local attached = {}

function M.attach(bufnr)
  if attached[bufnr] then
    return
  end
  attached[bufnr] = true
  decorate_buffer(bufnr)

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b, _, first, _, last_new)
      if not vim.api.nvim_buf_is_valid(b) then
        attached[b] = nil
        return true
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(b) then
          return
        end
        vim.api.nvim_buf_clear_namespace(b, NS, first, last_new)
        local lines = vim.api.nvim_buf_get_lines(b, first, last_new, false)
        for off, line in ipairs(lines) do
          decorate_line(b, first + off, line)
        end
      end)
    end,
    on_detach = function(_, b)
      attached[b] = nil
    end,
  })

  -- Conceal level 2 = replace with cchar (or our `conceal` extmark text).
  pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = 0 })
  pcall(vim.api.nvim_set_option_value, "concealcursor", "nc", { win = 0 })
end

function M.detach(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  attached[bufnr] = nil
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if attached[bufnr] then
    M.detach(bufnr)
  else
    M.attach(bufnr)
  end
end

M.commands = {
  pretty_entities = {
    fn = function()
      M.toggle(0)
    end,
    desc = "Toggle pretty-entities (display \\alpha as alpha, \\to as ->, etc.)",
  },
}

return M
