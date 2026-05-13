-- Minimal PDF document scaffold over the object-model writer. Knows
-- the structural dicts the spec requires (catalog, page tree, page)
-- but holds no content / font / image awareness -- those layers go on
-- top in later modules.
--
-- The catalog and page tree refs are allocated up front so that each
-- page can carry the correct /Parent ref at the moment it's added,
-- before the tree itself is populated. Final populate-and-emit happens
-- in :bytes().

local writer = require("organ.pdf.writer")

local Document = {}
Document.__index = Document

local M = {}

function M.new()
  local w = writer.new()
  local catalog_ref = w:alloc()
  local pages_ref = w:alloc()
  return setmetatable({
    w = w,
    catalog_ref = catalog_ref,
    pages_ref = pages_ref,
    pages = {},
  }, Document)
end

-- Add an empty page sized in PDF user-space units (points: 1/72 inch).
-- Default is US Letter (612 x 792). Returns the page ref so callers
-- can later attach content streams / resources.
function Document:add_page(opts)
  opts = opts or {}
  local width = opts.width or 612
  local height = opts.height or 792
  local page_ref = self.w:alloc()
  self.w:set(page_ref, {
    Type = "/Page",
    Parent = self.pages_ref,
    MediaBox = { 0, 0, width, height },
    -- writer.dict so an empty table serializes as "<< >>" rather than
    -- "[ ]" (the encoder treats untagged empties as arrays).
    Resources = writer.dict({}),
  })
  self.pages[#self.pages + 1] = { ref = page_ref, width = width, height = height }
  return page_ref
end

-- Populate the page tree + catalog, mark the catalog as the root, and
-- serialize.
function Document:bytes()
  local kids = writer.array({})
  for _, p in ipairs(self.pages) do
    kids[#kids + 1] = p.ref
  end
  self.w:set(self.pages_ref, {
    Type = "/Pages",
    Kids = kids,
    Count = #self.pages,
  })
  self.w:set(self.catalog_ref, {
    Type = "/Catalog",
    Pages = self.pages_ref,
  })
  self.w:set_root(self.catalog_ref)
  return self.w:bytes()
end

M.Document = Document

return M
