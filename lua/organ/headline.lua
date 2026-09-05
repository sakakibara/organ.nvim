local M = {}

-- Split a headline line into its star count and the text that follows.
-- Returns level (number of leading stars) and rest, or nil when the line
-- is not a headline (no star run followed by whitespace).  Tree-sitter is
-- the primary parser elsewhere; this is the one shared piece of the regex
-- fallback used by element, structure, and the indexer, kept in a single
-- place so the three former copies cannot drift.  Metadata parsing (todo
-- source, tag policy, comment flag) stays in each caller because it
-- legitimately differs between them.
function M.split(line)
  local stars, rest = line:match("^(%*+) +(.*)$")
  if stars then
    return #stars, rest
  end
  return nil
end

return M
