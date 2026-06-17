-- Async tree walker shared by the watcher rescan and the indexer scan.
--
-- walk_async(root_dir, batch_size, on_dir, on_file, on_done)
--   root_dir   : absolute path to walk.
--   batch_size : entries processed per vim.schedule yield.
--   on_dir     : function(absolute_path)             — called once per dir entered.
--   on_file    : function(absolute_path, stat_table) — called once per regular file.
--   on_done    : function() | nil                    — called exactly once when the walk finishes.
--
-- Follows symlinks (uses fs_stat, not fs_lstat) so symlinked subdirs are
-- entered like any other dir. Inode-keyed cycle detection prevents loops.

local M = {}

function M.walk_async(root_dir, batch_size, on_dir, on_file, on_done)
  local visited = {}
  local pending = 0
  local done = false
  local function maybe_done()
    if done and pending == 0 and on_done then
      on_done()
    end
  end
  local function visit(d)
    pending = pending + 1
    vim.loop.fs_scandir(d, function(_err, handle)
      if not handle then
        pending = pending - 1
        return maybe_done()
      end
      local entries = {}
      while true do
        local name, t = vim.loop.fs_scandir_next(handle)
        if not name then
          break
        end
        entries[#entries + 1] = { name = name, t = t }
      end
      require("organ.errors").schedule("organ.walk", function()
        local i = 0
        local function step_chunk()
          local stop = math.min(i + batch_size, #entries)
          while i < stop do
            i = i + 1
            local e = entries[i]
            local full = d .. "/" .. e.name
            pending = pending + 1
            vim.loop.fs_stat(full, function(_, st)
              if st then
                if st.type == "directory" then
                  if not visited[st.ino] then
                    visited[st.ino] = true
                    -- on_dir / visit() may need a normal context (callers
                    -- can use vim.fn.*); bounce out of the fast-event
                    -- context, and count the bounce in `pending` so on_done
                    -- only fires after every callback has completed.
                    pending = pending + 1
                    require("organ.errors").schedule("organ.walk", function()
                      if on_dir then
                        on_dir(full)
                      end
                      visit(full)
                      pending = pending - 1
                      maybe_done()
                    end)
                  end
                elseif st.type == "file" and on_file then
                  pending = pending + 1
                  require("organ.errors").schedule("organ.walk", function()
                    on_file(full, st)
                    pending = pending - 1
                    maybe_done()
                  end)
                end
              end
              pending = pending - 1
              maybe_done()
            end)
          end
          if i < #entries then
            require("organ.errors").schedule("organ.walk", step_chunk)
          else
            pending = pending - 1
            maybe_done()
          end
        end
        step_chunk()
      end)
    end)
  end
  visit(root_dir)
  done = true
  maybe_done()
end

return M
