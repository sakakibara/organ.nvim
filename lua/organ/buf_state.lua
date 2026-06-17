-- Per-buffer teardown registry.  Modules that keep `something[bufnr]` state
-- register a cleanup here at the point they create that state; one
-- BufWipeout autocmd (see init.lua) drains the registry.  This replaces a
-- hand-maintained list of cleanups in the autocmd, where every new stateful
-- module had to remember to add itself or leak.
local M = {}

-- bufnr -> { key = fn }.  Keyed so a module re-registering on re-attach is
-- idempotent rather than piling up duplicate teardowns.
local registry = {}

-- Register `fn` to run when `bufnr` is cleaned up.  `key` namespaces the
-- registration per module so repeated calls replace rather than accumulate.
function M.on_cleanup(bufnr, key, fn)
  local bucket = registry[bufnr]
  if not bucket then
    bucket = {}
    registry[bufnr] = bucket
  end
  bucket[key] = fn
end

-- Run and clear every teardown registered for `bufnr`.  Each runs under
-- pcall so one failing teardown does not block the others.
function M.cleanup(bufnr)
  local bucket = registry[bufnr]
  if not bucket then
    return
  end
  registry[bufnr] = nil
  for _, fn in pairs(bucket) do
    pcall(fn, bufnr)
  end
end

return M
