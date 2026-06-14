-- Capture entry point: float lifecycle + finalise/cancel.

local M = {}

local obuf = require("organ.buf")
local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return require("organ.buf_config").read(nil, "capture") or {}
end

local function open_capture_buf(template_name, body_lines, cursor_offset)
  local cfg = get_config()
  local win_cfg = cfg.window or {}
  local kind = win_cfg.kind or "float"

  local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
  end
  local function size(spec, total, lo)
    if not spec then
      return math.floor(total * 0.5)
    end
    if spec >= 1 then
      return clamp(spec, lo, total - 4)
    end
    return clamp(math.floor(total * spec), lo, total - 4)
  end

  local bufnr = vim.api.nvim_create_buf(false, false)
  obuf.set_lines(bufnr, 0, -1, body_lines)
  vim.bo[bufnr].bufhidden = "wipe"
  -- Set buffer-local flags BEFORE filetype=org because the FileType
  -- autocmd fires synchronously on assignment.  organ_no_startup_fold
  -- tells the ftplugin to skip its `startup.folded` resolution so the
  -- 1-2-line capture body isn't folded under the headline regardless
  -- of what the user picked for the default.
  vim.b[bufnr].organ_capture = { template_name = template_name }
  vim.b[bufnr].organ_no_startup_fold = true
  vim.bo[bufnr].filetype = "org"
  vim.bo[bufnr].modified = false

  local win
  if kind == "split" then
    -- Horizontal split: open split, then switch it to our scratch buffer.
    local height = size(win_cfg.height, vim.o.lines, 5)
    vim.cmd("split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.api.nvim_win_set_height(win, height)
  elseif kind == "vsplit" then
    -- Vertical split.
    local width = size(win_cfg.width, vim.o.columns, 10)
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.api.nvim_win_set_width(win, width)
  else
    -- Default: floating window (original behavior).
    local width = size(win_cfg.width, vim.o.columns, 10)
    local height = size(win_cfg.height, vim.o.lines, 5)
    local title_fmt = win_cfg.title or "Capture: %s"
    win = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      border = win_cfg.border or "rounded",
      title = string.format(title_fmt, template_name),
      title_pos = win_cfg.title_pos or "center",
      style = "minimal",
    })
  end

  -- Force foldlevel=99 on the capture window AFTER it opens so the
  -- 1-2 line body isn't auto-folded under its headline.  The
  -- ftplugin sets this on the SOURCE window during attach; the
  -- new float doesn't inherit window-local options from the
  -- previously-current window in a useful way.
  --
  -- foldenable stays TRUE so a user composing a multi-headline
  -- capture entry can still `zc`/`zM`/`zR` on subtrees -- only
  -- the AUTOMATIC startup-fold is suppressed.
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_option_value, "foldlevel", 99, { win = win })
  end

  -- Winbar: keymap reference visible in every window kind (float / split /
  -- vsplit). Built dynamically from the user's actual keymap config so
  -- overrides reflect immediately. Toggleable via cfg.window.winbar = false.
  if (win_cfg.winbar ~= false) and win and vim.api.nvim_win_is_valid(win) then
    local km = cfg.keymaps or {}
    local function show(lhs)
      return (lhs and lhs ~= false and lhs ~= "") and lhs or nil
    end
    local hints = {}
    local fin = show(km.finalise) or "ZZ"
    local fin_a = show(km.finalise_alt)
    local can = show(km.cancel) or "ZQ"
    local can_n = show(km.cancel_normal)
    local refi = show(km.refile_finalise)
    hints[#hints + 1] = "%#OrganCaptureLabel#capture: " .. template_name .. "%* "
    hints[#hints + 1] = "%#OrganCaptureKey#" .. fin .. "%* finalise"
    if fin_a then
      hints[#hints + 1] = " / %#OrganCaptureKey#" .. fin_a .. "%*"
    end
    hints[#hints + 1] = "  %#OrganCaptureKey#" .. can .. "%* cancel"
    if can_n then
      hints[#hints + 1] = " / %#OrganCaptureKey#" .. can_n .. "%*"
    end
    if refi then
      hints[#hints + 1] = "  %#OrganCaptureKey#" .. refi .. "%* refile-then-finalise"
    end
    local winbar = table.concat(hints)
    pcall(function()
      vim.wo[win].winbar = winbar
    end)
    -- Highlight defaults (default = true so user/colorscheme override wins).
    vim.api.nvim_set_hl(0, "OrganCaptureLabel", { link = "Title", default = true, bold = true })
    vim.api.nvim_set_hl(0, "OrganCaptureKey", { link = "Special", default = true, bold = true })
  end

  if cursor_offset then
    local row, col, acc = 1, 0, 0
    for i, l in ipairs(body_lines) do
      if cursor_offset <= acc + #l then
        row = i
        col = cursor_offset - acc
        break
      end
      acc = acc + #l + 1
      row = i + 1
    end
    -- Set to clamped position first, then enter insert mode so that
    -- col == #line (end-of-line) is reachable (nvim_win_set_cursor clamps to len-1).
    local line_len = #(body_lines[row] or "")
    if col >= line_len then
      -- cursor at or after end of line: use append (startinsert!)
      pcall(vim.api.nvim_win_set_cursor, win, { row, math.max(0, line_len - 1) })
      vim.cmd("startinsert!")
    else
      pcall(vim.api.nvim_win_set_cursor, win, { row, col })
      vim.cmd("startinsert")
    end
  else
    local last = #body_lines
    local last_len = #(body_lines[last] or "")
    pcall(vim.api.nvim_win_set_cursor, win, { last, math.max(0, last_len - 1) })
    vim.cmd("startinsert!")
  end

  return bufnr, win
end

local function attach_keymaps(bufnr)
  local cfg = get_config()
  local keymaps = cfg.keymaps or {}
  local function map(mode, lhs, fn)
    if lhs == nil or lhs == false or lhs == "" then
      return
    end
    vim.api.nvim_buf_set_keymap(bufnr, mode, lhs, "", {
      noremap = true,
      silent = true,
      callback = fn,
    })
  end
  map("n", keymaps.finalise or "ZZ", function()
    M.finalise(bufnr)
  end)
  map("i", keymaps.finalise or "ZZ", function()
    M.finalise(bufnr)
  end)
  -- finalise_alt: normal-mode only (Enter to confirm, familiar from quickfix/help)
  map("n", keymaps.finalise_alt or "<CR>", function()
    M.finalise(bufnr)
  end)
  map("n", keymaps.cancel or "ZQ", function()
    M.cancel(bufnr)
  end)
  map("i", keymaps.cancel or "ZQ", function()
    M.cancel(bufnr)
  end)
  map("i", keymaps.cancel_insert, function()
    M.cancel(bufnr)
  end)
  map("n", keymaps.cancel_normal or "q", function()
    if vim.bo[bufnr].modified then
      return
    end
    M.cancel(bufnr)
  end)
end

-- Build the capture-context table that templates resolve placeholders
-- against (`%t`, `%i`, `%a`, ID/title of the headline at cursor, …).
-- Captures buffer + cursor + visual selection + nearest section title/ID.
function M.build_ctx()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local cword = vim.fn.expand("<cword>")
  local source_file = vim.api.nvim_buf_get_name(bufnr)

  local source_id, source_title
  if vim.bo[bufnr].filetype == "org" then
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
    if ok and parser then
      parser:parse()
      local node = vim.treesitter.get_node({ bufnr = bufnr, lang = "org" })
      while node and node:type() ~= "section" do
        node = node:parent()
      end
      if node then
        local sr = select(1, node:range())
        local query = require("organ.query")
        local rows = query.headlines({
          file = require("organ.path").canonical(source_file) or source_file,
          include_properties = true,
        })
        for _, r in ipairs(rows) do
          if r.line_start == sr then
            source_title = r.title
            if (r.properties or {}).ID then
              source_id = r.properties.ID
            end
            break
          end
        end
      end
    end
  end

  local visual_text = ""
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local s = vim.fn.getpos("v")
    local e = vim.fn.getpos(".")
    local lines = vim.api.nvim_buf_get_text(bufnr, s[2] - 1, s[3] - 1, e[2] - 1, e[3], {})
    visual_text = table.concat(lines, "\n")
  end

  return {
    source_bufnr = bufnr,
    source_win = win,
    source_cursor = cursor,
    source_file = source_file,
    source_headline_id = source_id,
    source_headline_title = source_title,
    cword = cword,
    visual_text = visual_text,
    prompts = { text = {}, tags = nil, dates = {} },
    now = os.time(),
  }
end

-- High-level action: open the capture flow.
--   opts.key = "x"  → start the template whose `key` is "x"
--   opts.key = nil  → popup if any template defines `key`, else picker
function M.open(opts)
  opts = opts or {}
  local templates = (require("organ.buf_config").read(nil, "capture") or {}).templates or {}
  local key = opts.key
  if key and key ~= "" then
    local t = require("organ.capture.template").find_by_key(templates, key)
    if not t then
      require("organ.notify").warn("no capture template with key '" .. key .. "'")
      return
    end
    M.start(t, M.build_ctx())
    return
  end
  local with_keys = {}
  for _, t in ipairs(templates) do
    if t.key then
      with_keys[#with_keys + 1] = t
    end
  end
  if #with_keys > 0 then
    require("organ.capture.popup").open(M.build_ctx(), function(t)
      M.start(t, M.build_ctx())
    end)
  else
    require("organ.capture.picker").pick(templates, function(t)
      M.start(t, M.build_ctx())
    end)
  end
end

-- Open capture via the prefix-tree popup regardless of how many templates
-- have keys (Emacs `org-capture-prompt`).
function M.open_prompt()
  require("organ.capture.popup").open(M.build_ctx(), function(t)
    M.start(t, M.build_ctx())
  end)
end

function M.start(template, ctx)
  local template_mod = require("organ.capture.template")
  local placeholder_mod = require("organ.capture.placeholder")

  local t = template_mod.normalise(template)
  ctx = ctx or {}
  ctx.now = ctx.now or os.time()
  ctx.prompts = ctx.prompts or { text = {}, tags = nil, dates = {} }

  local body_str
  if type(t.body) == "function" then
    local ok, result = pcall(t.body, ctx)
    if not ok then
      require("organ.notify").error("capture: template body function errored: " .. tostring(result))
      return
    end
    body_str = result
  else
    body_str = t.body
  end

  local ok = placeholder_mod.prompt_pass(body_str, ctx)
  if not ok then
    require("organ.notify").info("capture aborted")
    return
  end

  local text, cursor_offset = placeholder_mod.expand(body_str, ctx)

  -- Compile hooks (Emacs `org-capture-after-finalize-hook` style;
  -- nvim-orgmode `_compile_hooks`). Each hook receives
  --   fn(content, content_type, ctx) → string | nil
  -- where content_type ∈ "target" | "content". Hooks run in
  -- registration order; returning nil keeps the previous content,
  -- returning a string replaces it. Useful for stripping signatures,
  -- normalising whitespace, injecting metadata.
  local hooks = (template.compile_hooks or template_mod.normalise(template).compile_hooks or {})
  for _, hook in ipairs(hooks) do
    local ok_h, replaced = pcall(hook, text, "content", ctx)
    if ok_h and type(replaced) == "string" then
      text = replaced
    end
  end

  local body_lines = vim.split(text, "\n", { plain = true })
  if body_lines[#body_lines] == "" then
    table.remove(body_lines)
  end

  local source_win = ctx.source_win or vim.api.nvim_get_current_win()
  local bufnr = open_capture_buf(t.name, body_lines, cursor_offset)
  vim.b[bufnr].organ_capture = {
    template_name = t.name,
    target = t.target,
    ctx = ctx,
    source_win = source_win,
    empty_lines_before = t.empty_lines_before,
    empty_lines_after = t.empty_lines_after,
    prepend = t.prepend,
    jump_after_finalise = t.jump_after_finalise,
    on_finalise = t.on_finalise,
    whole_file = t.whole_file == true,
  }
  attach_keymaps(bufnr)
end

function M.finalise(bufnr)
  local meta = vim.b[bufnr] and vim.b[bufnr].organ_capture
  if not meta then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end

  if #lines == 0 then
    require("organ.notify").warn("nothing to capture")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end

  local target_mod = require("organ.capture.target")
  local ok, path, insert_line, prelude, target_level_or_datetree =
    pcall(target_mod.resolve, meta.target, meta.ctx, meta.prepend)
  if not ok then
    require("organ.notify").error("organ: capture failed: " .. tostring(path))
    return
  end
  -- file_headline / file_olp resolvers return the parent target's
  -- level so the captured entry can be re-leveled to land as a
  -- CHILD instead of a sibling.  file_olp_datetree returns the
  -- datetree leaf's level (handled separately below; preserves
  -- the pre-existing datetree relevel path).
  local parent_level
  local datetree_leaf_level
  if meta.target then
    local k = meta.target.kind
    if k == "file_headline" or k == "file_olp" then
      parent_level = target_level_or_datetree
    elseif k == "file_olp_datetree" then
      datetree_leaf_level = target_level_or_datetree
    end
  end

  -- whole_file mode: replace the target file's entire content with the
  -- captured body. Used for "this template owns the whole file"
  -- workflows (e.g. a freshly-generated template-from-scratch). Skips
  -- the insert-at-line + prelude + datetree machinery entirely.
  if meta.whole_file then
    local body = table.concat(lines, "\n") .. "\n"
    local ok_w, werr = require("organ.path").write_atomic(path, body)
    if not ok_w then
      require("organ.notify").error(
        "organ.capture: failed to write " .. path .. ": " .. tostring(werr)
      )
      return
    end
    if meta.on_finalise then
      pcall(meta.on_finalise, meta.ctx, lines)
    end
    pcall(function()
      require("organ.queue").enqueue_interactive(require("organ.path").canonical(path) or path)
    end)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    if meta.source_win and vim.api.nvim_win_is_valid(meta.source_win) then
      vim.api.nvim_set_current_win(meta.source_win)
    end
    require("organ.notify").info("captured (whole_file) to " .. path)
    return
  end

  -- Re-level captured headlines so they nest UNDER the target.
  -- Without this, `* TODO %?` template land at level 1 even when
  -- the target is `* Inbox` (also level 1) -- the captured entry
  -- becomes a sibling rather than a child, with a stray blank
  -- separator and an awkward fold artifact between them.  Emacs's
  -- `org-capture` does the same re-level for `entry`-type
  -- templates.
  --
  -- file_headline / file_olp: bump captured-headline levels so
  --   level 1 -> parent_level + 1 (child of the named headline).
  -- file_olp_datetree: bump so level 1 -> datetree_leaf_level + 1
  --   (child of the auto-created date leaf).
  local extra
  if parent_level and parent_level > 0 then
    extra = parent_level
  elseif datetree_leaf_level and datetree_leaf_level > 0 then
    extra = datetree_leaf_level
  end
  if extra then
    local releveled = {}
    for _, l in ipairs(lines) do
      local stars, rest = l:match("^(%*+)(.*)")
      if stars then
        releveled[#releveled + 1] = string.rep("*", #stars + extra) .. rest
      else
        releveled[#releveled + 1] = l
      end
    end
    lines = releveled
  end

  local file_lines = vim.fn.readfile(path)
  local before = {}
  for _ = 1, (meta.empty_lines_before or 0) do
    before[#before + 1] = ""
  end
  local after = {}
  for _ = 1, (meta.empty_lines_after or 0) do
    after[#after + 1] = ""
  end

  local insert = {}
  for _, l in ipairs(prelude) do
    insert[#insert + 1] = l
  end
  for _, l in ipairs(before) do
    insert[#insert + 1] = l
  end
  for _, l in ipairs(lines) do
    insert[#insert + 1] = l
  end
  for _, l in ipairs(after) do
    insert[#insert + 1] = l
  end

  local out = {}
  for i = 1, insert_line - 1 do
    out[#out + 1] = file_lines[i]
  end
  for _, l in ipairs(insert) do
    out[#out + 1] = l
  end
  for i = insert_line, #file_lines do
    out[#out + 1] = file_lines[i]
  end

  -- Atomic-rename write so a crash mid-finalise can't corrupt the user's
  -- inbox file (would otherwise leave a half-truncated org file).
  local body = table.concat(out, "\n") .. "\n"
  local ok, werr = require("organ.path").write_atomic(path, body)
  if not ok then
    require("organ.notify").error(
      "organ.capture: failed to write " .. path .. ": " .. tostring(werr)
    )
    return
  end

  -- If the target file is currently loaded as a buffer (the user has
  -- inbox.org open in a window, or any other plugin loaded it), the
  -- atomic write went to disk but the buffer's in-memory copy is now
  -- stale.  :checktime asks vim to re-read any buffer whose mtime
  -- changed -- without this the user has to manually `:e` to see the
  -- captured entry, and any fold/cursor state references the old
  -- line numbers.
  do
    local canonical = require("organ.path").canonical(path) or path
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        local bcanon = require("organ.path").canonical(name) or name
        if bcanon == canonical then
          pcall(vim.api.nvim_buf_call, b, function()
            vim.cmd("silent! checktime")
          end)
        end
      end
    end
  end

  local entry_line = (insert_line - 1) + #prelude + #before + 1

  if meta.on_finalise then
    pcall(meta.on_finalise, meta.ctx, lines)
  end

  pcall(function()
    require("organ.queue").enqueue_interactive(require("organ.path").canonical(path) or path)
  end)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if meta.source_win and vim.api.nvim_win_is_valid(meta.source_win) then
    vim.api.nvim_set_current_win(meta.source_win)
  end

  require("organ.notify").info(string.format("captured to %s:%d", path, entry_line))

  local jump
  if meta.jump_after_finalise ~= nil then
    jump = meta.jump_after_finalise
  else
    jump = (get_config().jump_after_finalise == true)
  end
  if jump then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    pcall(vim.api.nvim_win_set_cursor, 0, { entry_line, 0 })
  end
end

function M.cancel(bufnr)
  local meta = vim.b[bufnr] and vim.b[bufnr].organ_capture
  if not meta then
    return
  end
  if vim.bo[bufnr].modified then
    local response
    vim.ui.input({ prompt = "Discard captured text? [y/N] " }, function(v)
      response = v
    end)
    if response == nil or (response ~= "y" and response ~= "Y") then
      return
    end
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if meta.source_win and vim.api.nvim_win_is_valid(meta.source_win) then
    vim.api.nvim_set_current_win(meta.source_win)
  end
end

local function complete_capture_keys(arg_lead)
  local cfg = (require("organ.buf_config").read(nil, "capture") or {})
  local out = {}
  for _, t in ipairs(cfg.templates or {}) do
    if t.key and t.key:find(arg_lead, 1, true) == 1 then
      out[#out + 1] = t.key
    end
  end
  return out
end

M.commands = {
  capture = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      M.open({ key = args ~= "" and args or nil })
    end,
    nargs = "?",
    complete = complete_capture_keys,
    desc = "Open the capture float for the matching template (or pick from a popup)",
  },
  capture_prompt = {
    fn = function()
      M.open_prompt()
    end,
    desc = "Capture entry via prefix-tree popup",
  },
}

return M
