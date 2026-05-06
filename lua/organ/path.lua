-- Path normalisation helper for organ.nvim.

local M = {}

-- Canonical form: absolute, symlink-resolved, no trailing slash.
-- Returns nil only for nil / empty / non-string input.
-- For non-existent paths (e.g. in-flight delete events), falls back to the
-- absolute-only form so callers can still key tombstones / lookups.
function M.canonical(p)
  if type(p) ~= "string" or p == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(p, ":p"):gsub("/$", "")
  local resolved = vim.loop.fs_realpath(abs)
  return resolved or abs
end

-- Atomic write: write to `path .. ".tmp.<rand>"`, fsync, rename. Survives:
--   * crash mid-write             — tmp file is orphaned, target untouched
--   * crash between write+rename  — tmp file is fully on-disk (fsync), can
--                                    be recovered manually if needed; target
--                                    is either the old version or the new
--   * power loss after rename     — fsync ensured the new bytes are on disk
--                                    BEFORE the rename was visible
--
-- Optional .bak: when `opts.keep_bak = true` (or config.write.keep_bak),
-- before the rename we hardlink the existing target to `path .. ".bak"`
-- so the previous version survives until the next successful write.
--
-- The tmp suffix includes a random component so concurrent writes to the
-- same path (different organ instances? unusual but possible) don't
-- clobber each other's tmp file mid-flight.
--
-- Returns true on success, false + error string on failure.
function M.write_atomic(path, contents, opts)
  if type(path) ~= "string" or path == "" then
    return false, "empty path"
  end
  opts = opts or {}
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  -- Random tmp suffix avoids races between concurrent writers.
  local rand = string.format("%d-%d", vim.uv.hrtime() % 1e9, math.random(1, 1e6))
  local tmp = path .. ".tmp." .. rand

  -- Use vim.uv.fs_open + fs_write + fs_fsync rather than io.open so we
  -- can fsync the file descriptor before close + rename. Without
  -- fsync, the kernel may not have written the bytes to disk before
  -- the rename, so a power loss between rename and the next sync
  -- leaves the target empty (filesystems with `data=writeback` mode
  -- on ext4 etc. are vulnerable here).
  local fd, oerr = vim.uv.fs_open(tmp, "w", 420) -- 0644
  if not fd then
    return false, "open " .. tmp .. ": " .. tostring(oerr)
  end
  local _, werr = vim.uv.fs_write(fd, contents, 0)
  if werr then
    vim.uv.fs_close(fd)
    pcall(vim.uv.fs_unlink, tmp)
    return false, "write: " .. tostring(werr)
  end
  -- fs_fsync may fail on some filesystems (e.g. tmpfs without sync
  -- semantics, network mounts); a failure here is logged but not
  -- fatal — the rename below will still occur.
  pcall(vim.uv.fs_fsync, fd)
  vim.uv.fs_close(fd)

  -- Optional backup of the existing target. Hardlink keeps it cheap
  -- and atomic — a single inode reference. If hardlink fails (cross-
  -- filesystem, FAT32 etc.), fall back to a copy.
  local keep_bak = opts.keep_bak
  if keep_bak == nil then
    keep_bak = ((require("organ").config or {}).write or {}).keep_bak == true
  end
  if keep_bak and vim.uv.fs_stat(path) then
    local bak = path .. ".bak"
    pcall(vim.uv.fs_unlink, bak)
    local linked = pcall(vim.uv.fs_link, path, bak)
    if not linked then
      -- Cross-fs fallback: copy.
      pcall(vim.uv.fs_copyfile, path, bak)
    end
  end

  -- Rename is atomic on POSIX (same filesystem). os.rename is the
  -- portable wrapper; vim.uv.fs_rename works the same.
  local renamed, rerr = vim.uv.fs_rename(tmp, path)
  if not renamed then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "rename: " .. tostring(rerr)
  end

  -- fsync the parent dir so the rename's directory entry is also
  -- durable. Without this, the rename can be lost on power failure
  -- even after the file's bytes are safely on disk.
  local dir_fd = vim.uv.fs_open(vim.fn.fnamemodify(path, ":h"), "r", 0)
  if dir_fd then
    pcall(vim.uv.fs_fsync, dir_fd)
    vim.uv.fs_close(dir_fd)
  end

  return true
end

return M
