-- Holiday calendar fetcher + disk cache for organ.nvim.

local M = {}

-- Per-session notify dedupe so one missing-cache warn isn't spammed.
M._notified = {}

-- Cache dir resolution: tests override M._cache_dir.
M._cache_dir = function()
  local d = require("organ.buf_config").read(nil, "todo.holidays_cache_dir")
  if d then
    return d
  end
  return vim.fn.stdpath("cache") .. "/organ/holidays"
end

local function cache_path(country, year)
  return M._cache_dir() .. "/" .. country .. "-" .. tostring(year) .. ".json"
end

-- Read + parse cache for (country, year). Returns a set keyed by date string,
-- or nil on miss / parse error.
local function read_cache(country, year)
  local path = cache_path(country, year)
  if not vim.uv.fs_stat(path) then
    return nil
  end
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  if body == "" then
    return {}
  end
  local ok, parsed = pcall(vim.json.decode, body)
  if not ok or type(parsed) ~= "table" then
    return nil
  end
  local set = {}
  for _, entry in ipairs(parsed) do
    if entry.date then
      set[entry.date] = true
    end
  end
  return set
end

-- Enumerate every cached holiday entry for a country across every cached
-- year. Returns an array of `{ date = "YYYY-MM-DD", name = "..." }` tables
-- ready for consumption by the calendar UI's holiday-highlight pass.
-- Returns an empty array if no cache files exist for this country (does
-- NOT fetch on demand — the calendar shouldn't block on network IO).
function M.load_calendar(country)
  local entries = {}
  local dir = M._cache_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return entries
  end
  local prefix = country .. "-"
  for _, name in ipairs(vim.fn.readdir(dir)) do
    if name:sub(1, #prefix) == prefix and name:sub(-5) == ".json" then
      local fh = io.open(dir .. "/" .. name, "r")
      if fh then
        local body = fh:read("*a")
        fh:close()
        if body and body ~= "" then
          local ok, parsed = pcall(vim.json.decode, body)
          if ok and type(parsed) == "table" then
            for _, e in ipairs(parsed) do
              if type(e) == "table" and e.date then
                entries[#entries + 1] = e
              end
            end
          end
        end
      end
    end
  end
  return entries
end

function M.is_holiday(country, date_yyyy_mm_dd)
  local year = tonumber(date_yyyy_mm_dd:sub(1, 4))
  if not year then
    return false
  end
  local set = read_cache(country, year)
  if not set then
    -- One-shot warn per (country, session).
    local key = "miss:" .. country .. ":" .. tostring(year)
    if not M._notified[key] then
      M._notified[key] = true
      vim.schedule(function()
        require("organ.notify").warn(
          string.format(
            "holidays for cal:%s aren't cached (run :Org fetch_holidays %s)",
            country,
            country
          )
        )
      end)
    end
    return false
  end
  return set[date_yyyy_mm_dd] == true
end

function M.fetch(country, year, cb)
  vim.fn.mkdir(M._cache_dir(), "p")
  local url = string.format("https://date.nager.at/api/v3/PublicHolidays/%d/%s", year, country)
  vim.system({ "curl", "-fsS", url }, { text = true }, function(res)
    -- curl exit 22 is HTTP 4xx (with -f). We treat this as "country not
    -- supported" and write an empty cache so we don't retry every setup.
    if res.code == 22 then
      vim.schedule(function()
        local fh = io.open(cache_path(country, year), "w")
        if fh then
          fh:write("[]")
          fh:close()
        end
        if cb then
          cb(true)
        end
      end)
      return
    end
    if res.code ~= 0 then
      vim.schedule(function()
        if cb then
          cb(false, res.stderr)
        end
      end)
      return
    end
    -- Validate it's at least JSON-array-shaped before writing.
    local ok, parsed = pcall(vim.json.decode, res.stdout)
    if not ok or type(parsed) ~= "table" then
      vim.schedule(function()
        if cb then
          cb(false, "invalid json from nager.date")
        end
      end)
      return
    end
    vim.schedule(function()
      local fh = io.open(cache_path(country, year), "w")
      if not fh then
        if cb then
          cb(false, "open cache for write failed")
        end
        return
      end
      fh:write(res.stdout)
      fh:close()
      if cb then
        cb(true)
      end
    end)
  end)
end

-- Warm: fetches current_year through current_year + years_ahead.
-- Skips years already cached and < 30 days old.
function M.warm(country, years_ahead, cb)
  years_ahead = years_ahead or 4
  local current = tonumber(os.date("%Y"))
  local pending = 0
  local errors = {}
  local function done()
    pending = pending - 1
    if pending == 0 and cb then
      cb(#errors == 0, errors)
    end
  end
  for y = current, current + years_ahead do
    local p = cache_path(country, y)
    local st = vim.uv.fs_stat(p)
    -- 30 days = 2592000 seconds
    local fresh = st and st.mtime and (os.time() - st.mtime.sec < 2592000)
    if not fresh then
      pending = pending + 1
      M.fetch(country, y, function(ok, err)
        if not ok then
          errors[#errors + 1] = err or ("fetch " .. country .. "-" .. y .. " failed")
        end
        done()
      end)
    end
  end
  if pending == 0 and cb then
    cb(true, {})
  end
end

M.commands = {
  fetch_holidays = {
    fn = function(cmd)
      local args = vim.split(cmd and cmd.args or "", "%s+")
      local cfg = (require("organ.buf_config").read(nil, "todo") or {})
      local country = (args[1] and args[1] ~= "") and args[1] or cfg.default_country
      if not country then
        require("organ.notify").error("no country specified and default_country is nil")
        return
      end
      local years_ahead = 4
      if args[2] and args[2]:match("^%d+%-%d+$") then
        local _, hi = args[2]:match("^(%d+)%-(%d+)$")
        local current = tonumber(os.date("%Y"))
        years_ahead = math.max(0, tonumber(hi) - current)
      end
      M.warm(country, years_ahead, function(ok, errs)
        if ok then
          vim.schedule(function()
            require("organ.notify").info("organ: warmed holidays for " .. country)
          end)
        else
          vim.schedule(function()
            require("organ.notify").warn(
              "warm failed for " .. country .. " (" .. tostring(#errs) .. " errors)"
            )
          end)
        end
      end)
    end,
    nargs = "*",
    desc = "Fetch holiday calendar(s) into the disk cache",
  },
}

return M
