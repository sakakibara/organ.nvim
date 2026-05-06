-- CSL-JSON bibliography parser.
--
-- CSL-JSON is the citation-style-language native data format
-- (https://docs.citationstyles.org/en/stable/specification.html#appendix-iv-variables).
-- It's the input format citeproc-js consumes; many tools (Zotero,
-- Pandoc) emit it. Compared to BibTeX it has cleaner field names
-- (`container-title` vs `journal`) and structured author objects out
-- of the box, so the parser is mostly a JSON decode + light
-- normalisation.

local M = {}

local function decode_json(text)
  if vim and vim.json and vim.json.decode then
    return vim.json.decode(text)
  end
  error("organ.cite.csl_json: needs vim.json (Neovim 0.10+)")
end

-- Returns a list of CSL-JSON entries. Each entry has at minimum
-- `id` and `type`; common fields are `author`, `title`, `issued`,
-- `container-title`, `volume`, `issue`, `page`, `publisher`, `DOI`.
function M.parse(text)
  if not text or text == "" then
    return {}
  end
  local raw = decode_json(text)
  if type(raw) ~= "table" then
    return {}
  end
  -- Some files wrap entries in `{ items = [...] }`; flatten.
  if raw.items and type(raw.items) == "table" then
    raw = raw.items
  end
  local out = {}
  for _, e in ipairs(raw) do
    -- Mirror the bibtex parser shape: { type, key, fields, author,
    -- year } so the renderer doesn't care which source it came from.
    local ne = {
      type = e.type or "article",
      key = e.id,
      fields = {},
      author = e.author,
      editor = e.editor,
    }
    -- CSL `issued` is a date object: { ["date-parts"] = { { 2020 } } }.
    if e.issued and type(e.issued) == "table" and e.issued["date-parts"] then
      local dp = e.issued["date-parts"][1]
      if dp and dp[1] then
        ne.year = tonumber(dp[1])
      end
    end
    -- Map common CSL fields to the generic `fields` bucket so renderer
    -- code can treat both bibtex and CSL-JSON inputs uniformly.
    ne.fields.title = e.title
    ne.fields.journal = e["container-title"]
    ne.fields.volume = e.volume and tostring(e.volume) or nil
    ne.fields.number = e.issue and tostring(e.issue) or nil
    ne.fields.pages = e.page and tostring(e.page) or nil
    ne.fields.publisher = e.publisher
    ne.fields.address = e["publisher-place"]
    ne.fields.doi = e.DOI
    ne.fields.url = e.URL
    out[#out + 1] = ne
  end
  return out
end

function M.parse_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local text = f:read("*a")
  f:close()
  return M.parse(text)
end

function M.index(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[e.key] = e
  end
  return out
end

return M
