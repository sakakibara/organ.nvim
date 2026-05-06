-- Org-protocol URI handler.
--
-- Recognised schemes (Emacs `org-protocol-protocol-alist` subset):
--   org-protocol://capture?template=KEY&url=URL&title=TITLE&body=BODY[&immediate=1]
--   org-protocol://store-link?url=URL&title=TITLE
--   org-protocol://open-source?url=file:///abs/path
--
-- Setup: register an OS-level x-scheme-handler/org-protocol (Linux) or
-- LSHandlerURLScheme (macOS) that invokes:
--   nvim --server $NVIM_LISTEN_ADDRESS --remote-send "<Cmd>OrgProtocol $1<CR>"
-- or, simpler, a one-shot:
--   nvim "+OrgProtocol $1"

local M = {}

-- Decode a percent-encoded value via Neovim's helper.
local function uri_decode(s)
  if not s then
    return nil
  end
  -- vim.uri_decode handles the standard encoding. Fall back to a manual
  -- pass for older Neovim where the function is missing.
  if vim.uri_decode then
    return vim.uri_decode(s)
  end
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return s
end

-- Parse a query string ("a=1&b=2&...") into a table { a = "1", b = "2" }.
-- Repeated keys keep the last value (matching browser convention).
function M.parse_query(qs)
  local out = {}
  if not qs or qs == "" then
    return out
  end
  for chunk in qs:gmatch("[^&]+") do
    local k, v = chunk:match("^([^=]+)=?(.*)$")
    if k then
      out[uri_decode(k)] = uri_decode(v or "")
    end
  end
  return out
end

-- Parse an org-protocol URI. Returns (sub_protocol, params_table).
function M.parse(uri)
  if not uri then
    return nil
  end
  -- Accept both forms:
  --   org-protocol://capture?template=...
  --   org-protocol:/capture?template=...   (legacy)
  local sub, qs = uri:match("^org%-protocol://?([%w%-_]+)%??(.*)$")
  if not sub then
    return nil
  end
  return sub, M.parse_query(qs)
end

-- Dispatch a parsed URI to the appropriate organ feature.
function M.handle(uri)
  local sub, params = M.parse(uri)
  if not sub then
    require("organ.notify").warn("organ: malformed org-protocol URI: " .. tostring(uri))
    return
  end
  local handler = M.handlers[sub]
  if not handler then
    require("organ.notify").warn("organ: unknown org-protocol sub-protocol: " .. sub)
    return
  end
  return handler(params or {})
end

-- ---------------------------------------------------------------------------
-- Per-sub-protocol handlers.

M.handlers = {}

function M.handlers.capture(params)
  -- Drop the captured URL/title/body into the link store so the capture
  -- template can pull them via %a / %i / %t placeholders. We reuse the
  -- link_store module rather than threading params through capture.
  if params.url then
    pcall(function()
      require("organ.link_store").push({
        target = params.url,
        description = params.title or params.url,
        source_file = nil,
        source_line = nil,
      })
    end)
  end
  -- Capture body text gets stashed as the visual region content via a
  -- module-local hook; capture template's %i interpolation reads it.
  M._captured_body = params.body or ""
  -- Open the capture popup with the requested template. Validate the
  -- template name strictly — `params.template` came from an external URL
  -- handler (browser, OS), so anything other than `[A-Za-z0-9_-]+` could
  -- inject vim commands (`|qall!`, `<CR>!rm -rf ~`, etc.).
  if params.template and params.template ~= "" then
    if params.template:match("^[%w_%-]+$") then
      pcall(require("organ.capture").open, { key = params.template })
    else
      require("organ.notify").warn(
        "organ.protocol: rejected unsafe template name: " .. tostring(params.template)
      )
    end
  else
    pcall(require("organ.capture").open)
  end
end

M.handlers["store-link"] = function(params)
  if not params.url or params.url == "" then
    require("organ.notify").warn("store-link missing url")
    return
  end
  require("organ.link_store").push({
    target = params.url,
    description = params.title or params.url,
    source_file = nil,
    source_line = nil,
  })
  require("organ.notify").info("organ: stored link " .. params.url)
end

M.handlers["open-source"] = function(params)
  local url = params.url
  if not url or url == "" then
    return
  end
  -- Strip optional file:// prefix.
  local path = url:gsub("^file://", "")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

-- The capture template can call this to pull the org-protocol body.
function M.captured_body()
  local b = M._captured_body
  M._captured_body = nil
  return b or ""
end

M.commands = {
  protocol = {
    fn = function(cmd)
      if not cmd or cmd.args == "" then
        require("organ.notify").warn(":Org protocol requires a URI argument")
        return
      end
      M.handle(cmd.args)
    end,
    nargs = 1,
    desc = "Handle an org-protocol://... URI (capture / store-link / open-source)",
  },
}

return M
