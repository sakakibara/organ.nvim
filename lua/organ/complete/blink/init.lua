-- blink.cmp integration for organ completion.
--
-- Registers organ's completion sources via blink's
-- add_source_provider + add_filetype_source APIs and (when blink is
-- lazy-loaded) defers registration until blink loads.
--
-- Sources registered:
--   organ_link       - [[id: / [[* / [[file: / [[attachment: / [[<PROP>:
--   organ_todo       - TODO keyword at headline start
--   organ_tags       - :tag: completion in tag block
--   organ_directive  - #+TITLE: / #+AUTHOR: / etc.
--   organ_drawer     - :PROPERTIES: / :LOGBOOK: keys (when complete.drawer ~= false)
--   organ_src_lang   - #+begin_src <lang> tokens
--   organ_roam_node  - org-roam node titles + aliases (when complete.roam_everywhere)
--   organ_cite       - [cite:@key / [@key (when complete.cite ~= false)

local M = {}

local SOURCES = {
  { id = "organ_link", module = "organ.complete.blink.link" },
  { id = "organ_todo", module = "organ.complete.blink.todo" },
  { id = "organ_tags", module = "organ.complete.blink.tags" },
  { id = "organ_directive", module = "organ.complete.blink.directive" },
  { id = "organ_src_lang", module = "organ.complete.blink.src_lang" },
  {
    id = "organ_drawer",
    module = "organ.complete.blink.drawer",
    gate = function(cfg)
      return cfg.complete and cfg.complete.drawer ~= false
    end,
  },
  {
    id = "organ_roam_node",
    module = "organ.complete.blink.roam_node",
    gate = function(cfg)
      return cfg.complete and cfg.complete.roam_everywhere
    end,
  },
  {
    id = "organ_cite",
    module = "organ.complete.blink.cite",
    gate = function(cfg)
      return not cfg.complete or cfg.complete.cite ~= false
    end,
  },
}

local function do_register(blink)
  local cfg_ok, organ = pcall(require, "organ")
  if not cfg_ok or not organ.config then
    return
  end
  local cfg = organ.config
  if cfg.complete and cfg.complete.blink == false then
    return
  end
  for _, s in ipairs(SOURCES) do
    if not s.gate or s.gate(cfg) then
      -- add_source_provider throws on duplicate id; pcall handles repeat-setup.
      pcall(blink.add_source_provider, s.id, {
        name = s.id,
        module = s.module,
      })
      pcall(blink.add_filetype_source, "org", s.id)
    end
  end
end

-- Public: try to register sources with blink.cmp.
--
-- If blink is already loaded, register immediately. Otherwise, set up
-- a one-shot autocmd on `User LazyLoad` matching "blink.cmp" (lazy.nvim
-- emits this when a plugin loads) AND a fallback FileType=org autocmd
-- in case lazy.nvim isn't in use.
function M.maybe_register()
  local loaded = package.loaded["blink.cmp"]
  if loaded and type(loaded.add_source_provider) == "function" then
    do_register(loaded)
    return
  end
  local registered = false
  local function attempt()
    if registered then
      return
    end
    local ok, blink = pcall(require, "blink.cmp")
    if not ok then
      return
    end
    -- Verify the v1 API is present before claiming success.
    if type(blink.add_source_provider) ~= "function" then
      return
    end
    registered = true
    do_register(blink)
  end
  -- Primary trigger: lazy.nvim emits `User LazyLoad <plugin>`.
  vim.api.nvim_create_autocmd("User", {
    pattern = "LazyLoad",
    callback = function(args)
      if args.data == "blink.cmp" then
        attempt()
      end
    end,
  })
  -- Fallback: on first org buffer open. If blink loads at FileType=org
  -- (rare) or earlier, we catch it; if blink loads later (e.g. on
  -- InsertEnter), the User-LazyLoad autocmd handles it.
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "org",
    once = true,
    callback = attempt,
  })
end

return M
