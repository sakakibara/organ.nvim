-- plugin/organ.lua
-- Runs at startup (before any user config). Registers the :Org user command
-- and the `org` filetype so that command-line completion + lazy-loading work
-- without calling setup() first.
--
-- Guard: only run once, even if rtp contains the directory twice.
if vim.g.loaded_organ then
  return
end
vim.g.loaded_organ = true

-- Ensure .org buffers always get filetype = "org".
vim.filetype.add({ extension = { org = "org" } })

-- Register tree-sitter directives used by queries/org/injections.scm
-- (src-block embedded-language injection, etc.).  Cheap; safe at startup.
pcall(function()
  require("organ.treesitter_directives").register()
end)

-- nvim-treesitter integration (only when that plugin is loaded).
--
-- We CLAIM the `org` and `org_inline` slots in nvim-treesitter's parser-
-- config table. organ.nvim's queries are tightly coupled to the
-- tree-sitter-organ grammar's AST shape; using any other tree-sitter
-- Org parser would produce wrong highlights / wrong indexing / silent
-- breakage. The right behavior is for `:TSInstall org` to install OUR
-- grammar, so users running both organ.nvim and nvim-treesitter end up
-- with consistent state.
--
-- The runtime separately canary-verifies the loaded parser at load
-- time (see lua/organ/runtime.lua) — so even if a stale foreign parser
-- is cached at <data>/site/parser/org.so from before organ.nvim was
-- installed, we'll detect the mismatch and refuse to use it rather
-- than silently producing wrong ASTs.
pcall(function()
  local has_ts, parsers = pcall(require, "nvim-treesitter.parsers")
  if not has_ts then
    return
  end
  local cfgs = parsers.get_parser_configs()
  cfgs.org = {
    install_info = {
      url = "https://github.com/sakakibara/tree-sitter-organ",
      branch = "main",
      files = {
        "src/parser.c",
        "src/scanner.c",
        "src/prepass.c",
        "src/prepass_scalar.c",
        "src/prepass_simd.c",
        "src/interval_tree.c",
      },
    },
    filetype = "org",
  }
  cfgs.org_inline = {
    install_info = {
      url = "https://github.com/sakakibara/tree-sitter-organ-inline",
      branch = "main",
      files = { "src/parser.c", "src/scanner.c" },
    },
  }
end)

-- Make the built parsers discoverable via Neovim's standard tree-sitter
-- runtimepath search. grammar_install.install() writes to
-- stdpath("data")/organ/parser/{org,org_inline}.so — by prepending
-- stdpath("data")/organ here, that becomes equivalent to a runtimepath
-- entry whose `parser/` directory Neovim auto-scans. No explicit
-- vim.treesitter.language.add() needed; ftplugin/org.lua's
-- vim.treesitter.start() finds the parser through the standard mechanism.
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/organ")

-- ---------------------------------------------------------------------------
-- :Org subcommand registry.
--
-- One user command (`:Org`) with snake_case subcommands, modeled on
-- :Telescope / :Lazy / :Mason. Each domain module owns its own
-- subcommands via `M.commands = { name = { fn, desc, nargs?,
-- complete?, range?, bang? } }`; this file iterates DOMAIN_MODULES to
-- fold those entries into the central dispatch dict.
--
-- To add a new :Org subcommand: add the entry to the relevant
-- domain's M.commands and append the module here.
-- ---------------------------------------------------------------------------
local DOMAIN_MODULES = {
  "organ.agenda",
  "organ.archive",
  "organ.attach",
  "organ.babel",
  "organ.backlinks",
  "organ.capture",
  "organ.checkbox",
  "organ.cite",
  "organ.clipboard",
  "organ.clock",
  "organ.column_view",
  "organ.complete",
  "organ.conceal",
  "organ.dblock",
  "organ.dependencies",
  "organ.directive",
  "organ.edit_special",
  "organ.entities",
  "organ.expand",
  "organ.export",
  "organ.find",
  "organ.footnote",
  "organ.format",
  "organ.goto",
  "organ.holidays",
  "organ.id",
  "organ.image",
  "organ.indent",
  "organ.indexer",
  "organ.inline_edit",
  "organ.latex_preview",
  "organ.latex_render",
  "organ.link",
  "organ.list",
  "organ.list_convert",
  "organ.meta_return",
  "organ.notifier",
  "organ.property",
  "organ.protocol",
  "organ.publish",
  "organ.refile",
  "organ.roam",
  "organ.schedule",
  "organ.sparse",
  "organ.statistics",
  "organ.structure",
  "organ.table",
  "organ.table_edit",
  "organ.tag_select",
  "organ.todo",
  "organ.watcher",
}

local subcommands = {
  -- Timer
  ["timer start"] = {
    fn = function(opts)
      require("organ.timer").start(opts.args)
    end,
    nargs = "?",
    desc = "Start a countdown timer (default 25m). Accepts 25, 25m, 1h, 90s, 1h30m, 0:25:00",
  },
  ["timer stop"] = {
    fn = function()
      require("organ.timer").stop()
    end,
    desc = "Stop / clear the active countdown timer",
  },
  ["timer pause"] = {
    fn = function()
      require("organ.timer").pause()
    end,
    desc = "Pause / resume the countdown timer",
  },
  ["timer status"] = {
    fn = function()
      local s = require("organ.timer").status()
      if not s.status then
        print("organ.timer: no timer running")
      else
        print(
          string.format(
            "organ.timer: %s, %d s remaining (of %d s)",
            s.status,
            s.remaining or 0,
            s.duration_s or 0
          )
        )
      end
    end,
    desc = "Print remaining time on the active countdown timer",
  },

  -- Profiler
  ["profile start"] = {
    fn = function(opts)
      local slow = tonumber(opts.args)
      local p = require("organ.profile")
      p.start({ slow_ms = slow })
      vim.notify("organ.profile: recording (slow >= " .. p._slow_ms .. " ms)")
    end,
    nargs = "?",
    desc = "Begin profiling organ hot paths (optional slow-ms threshold)",
  },
  ["profile stop"] = {
    fn = function()
      require("organ.profile").stop()
    end,
    desc = "Stop profiling and print the report",
  },
  ["profile report"] = {
    fn = function()
      require("organ.profile").report()
    end,
    desc = "Print the current profile report (without stopping)",
  },

  -- Links / hover / actions
  hover = {
    fn = function()
      require("organ.hover").open()
    end,
    desc = "Preview the headline target of the link under the cursor",
  },
  actions = {
    fn = function()
      require("organ.action_menu").open()
    end,
    desc = "Open the context-aware org action menu",
  },
  rename_headline = {
    fn = function(opts)
      local name = opts.args ~= "" and opts.args or nil
      require("organ.refactor").rename_at_cursor(name)
    end,
    nargs = "?",
    desc = "Rename the headline at cursor and update all *Title references",
  },

  -- LSP
  ["lsp start"] = {
    fn = function()
      require("organ.lsp").attach()
    end,
    desc = "Start the in-process LSP server for this org buffer",
  },
  ["lsp stop"] = {
    fn = function()
      local clients = vim.lsp.get_clients({ name = "organ" })
      for _, c in ipairs(clients) do
        c:stop()
      end
    end,
    desc = "Stop all running organ LSP clients",
  },

  -- Outline movement

  -- Cursor value increment

  narrow_to_subtree = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local structure = require("organ.structure")
      local hl = structure._find_containing_headline(bufnr, line)
      if not hl then
        require("organ.notify").warn("no headline at cursor")
        return
      end
      local end_line = structure._subtree_end(bufnr, hl)
      local err = require("narrow").to_range(bufnr, hl.line, end_line)
      if err then
        require("organ.notify").warn(err)
      end
    end,
    desc = "Narrow buffer view to the subtree at cursor (`:Org widen` to restore)",
  },
  widen = {
    fn = function()
      require("narrow").widen(0)
    end,
    desc = "Widen: restore buffer view after `:Org narrow_to_subtree`",
  },
}

-- ---------------------------------------------------------------------------
-- Subcommand registry: tree (for dispatch + completion) and flat
-- mirror (legacy snake_case lookup for tests / external API).
--
-- A domain module's `M.commands` may use SPACE-separated path keys
-- to declare hierarchical commands:
--
--   M.commands = {
--     ["notifier install"]   = { fn = ..., desc = ... },
--     ["notifier uninstall"] = { fn = ..., desc = ... },
--     ["agenda"]             = { fn = ..., desc = ... },  -- bare leaf
--     ["agenda day"]         = { fn = ..., desc = ... },  -- sub-leaf
--   }
--
-- A flat snake_case key (`set_property`) is treated as a single
-- token: it lives at the root with `_` preserved in the user-facing
-- form (`:Org set_property`).  Use space-separated keys when you want
-- the dispatcher to take a sub-action argument.
-- ---------------------------------------------------------------------------

-- Tree node shape: { fn?, desc?, nargs?, complete?, range?, bang?, children? }
-- Internal nodes have `children` (a table of child nodes by name) and
-- may also have `fn` (dual: callable bare AND has sub-actions).
local subcommand_tree = {}

local function ensure_node(parts)
  local node = subcommand_tree
  for i, part in ipairs(parts) do
    local container = (i == 1) and subcommand_tree or node.children
    if i > 1 then
      node.children = node.children or {}
      container = node.children
    end
    container[part] = container[part] or {}
    node = container[part]
  end
  return node
end

local function register(path_key, leaf, source)
  local parts = vim.split(path_key, "%s+", { trimempty = true })
  if #parts == 0 then
    return
  end
  local node = ensure_node(parts)
  if node.fn ~= nil then
    error(
      string.format(
        "organ: duplicate :Org subcommand %q -- redefined by %s",
        path_key,
        source or "?"
      )
    )
  end
  for k, v in pairs(leaf) do
    if k ~= "children" then
      node[k] = v
    end
  end
end

-- Seed tree from the inline `subcommands` table built above (legacy
-- single-token entries: timer_*, profile_*, lsp_*, hover, actions, etc.).
for k, v in pairs(subcommands) do
  register(k, v, "plugin/organ.lua")
end

-- Fold in domain-owned commands from each migrated module.
for _, mod_name in ipairs(DOMAIN_MODULES) do
  local mod = require(mod_name)
  if type(mod.commands) == "table" then
    for k, v in pairs(mod.commands) do
      register(k, v, mod_name)
    end
  end
end

-- Expose the tree so tests / external callers can introspect.
require("organ")._subcommand_tree = subcommand_tree

-- Path-resolver: walk the tree to the leaf or group at `path` (a
-- space-separated string like "find link" or "notifier install").
-- Returns the entry or nil.
require("organ").cmd = function(path)
  local node = { children = subcommand_tree }
  for tok in (path or ""):gmatch("%S+") do
    if not (node.children and node.children[tok]) then
      return nil
    end
    node = node.children[tok]
  end
  return node
end

-- ---------------------------------------------------------------------------
-- :Org user command — single dispatcher.
-- ---------------------------------------------------------------------------

-- Walk the tree greedily: consume tokens that match a child at each
-- level, stop when the next token isn't a child OR the current node
-- has no children.  Returns (entry, consumed) where `entry` is the
-- selected node and `consumed` is the count of fargs used.
local function resolve(fargs)
  local node = { children = subcommand_tree }
  local consumed = 0
  for i, tok in ipairs(fargs) do
    if node.children and node.children[tok] then
      node = node.children[tok]
      consumed = i
    else
      break
    end
  end
  if consumed == 0 then
    return nil, 0
  end
  return node, consumed
end

local function group_children_list(node)
  local kids = {}
  if node.children then
    for k in pairs(node.children) do
      kids[#kids + 1] = k
    end
    table.sort(kids)
  end
  return kids
end

local function dispatch(opts)
  local fargs = opts.fargs or {}
  if #fargs < 1 then
    vim.notify(
      "Usage: :Org <subcommand> [args]   (run :Org <Tab> for completion)",
      vim.log.levels.WARN
    )
    return
  end
  local entry, consumed = resolve(fargs)
  if not entry then
    vim.notify(
      "Unknown :Org subcommand: " .. fargs[1] .. "  (try :Org <Tab>)",
      vim.log.levels.ERROR
    )
    return
  end
  if not entry.fn then
    -- Group with no callable bare form: list the available children.
    local kids = group_children_list(entry)
    local path = table.concat({ unpack(fargs, 1, consumed) }, " ")
    vim.notify(
      ":Org " .. path .. " requires a sub-action. Available: " .. table.concat(kids, ", "),
      vim.log.levels.WARN
    )
    return
  end
  local rest = { unpack(fargs, consumed + 1) }
  local sub_opts = {
    name = table.concat({ unpack(fargs, 1, consumed) }, " "),
    fargs = rest,
    args = table.concat(rest, " "),
    bang = opts.bang or false,
    range = opts.range or 0,
    line1 = opts.line1,
    line2 = opts.line2,
    count = opts.count,
    mods = opts.mods,
    smods = opts.smods,
    reg = opts.reg,
  }
  entry.fn(sub_opts)
end

local function complete(arg_lead, cmdline, cursor_pos)
  local before = cmdline:sub(1, cursor_pos)
  local after_org = before:match("^%s*Org!?%s+(.*)$") or ""

  -- Tokenize what's been typed so far.  The token under the cursor is
  -- `arg_lead` (possibly empty if the cursor is on whitespace).
  local prefix_text = after_org:sub(1, #after_org - #arg_lead)
  local prefix_tokens = vim.split(prefix_text, "%s+", { trimempty = true })

  -- Walk the tree to find the deepest matching group node for the
  -- prefix tokens.  If we exhaust the prefix INSIDE the tree, we're
  -- completing a child name; if we land on a leaf, defer to the
  -- leaf's own `complete` callback for arg-completion.
  local node = { children = subcommand_tree }
  for _, tok in ipairs(prefix_tokens) do
    if node.children and node.children[tok] then
      node = node.children[tok]
    else
      -- Past the tree: this prefix token was a free arg to a leaf.
      -- Defer arg-completion to that leaf if it has one.
      if node.complete then
        if type(node.complete) == "string" then
          return vim.fn.getcompletion(arg_lead, node.complete)
        end
        return node.complete(arg_lead, cmdline, cursor_pos)
      end
      return {}
    end
  end

  -- Still inside the tree: complete against this node's children.
  if node.children then
    local out = {}
    for name in pairs(node.children) do
      if name:sub(1, #arg_lead) == arg_lead then
        out[#out + 1] = name
      end
    end
    table.sort(out)
    return out
  end

  -- Landed on a leaf with no children: forward to its arg-completer.
  if node.complete then
    if type(node.complete) == "string" then
      return vim.fn.getcompletion(arg_lead, node.complete)
    end
    return node.complete(arg_lead, cmdline, cursor_pos)
  end
  return {}
end

vim.api.nvim_create_user_command("Org", dispatch, {
  bang = true,
  range = true,
  nargs = "+",
  complete = complete,
  desc = "organ.nvim: dispatch to a subcommand (run `:Org <Tab>` for the list)",
})
