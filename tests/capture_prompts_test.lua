-- Unit tests for capture.placeholder.prompt_pass with mocked vim.ui.
-- Run via: nvim --headless -l tests/capture_prompts_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local placeholder = require("organ.capture.placeholder")

-- 1. Single %^{Prompt} fires vim.ui.input and stores the value.
do
  local original = vim.ui.input
  vim.ui.input = function(_opts, cb)
    cb("alice")
  end
  local ctx = {}
  local ok = placeholder.prompt_pass("Hi %^{Name}", ctx)
  vim.ui.input = original
  assert(ok, "prompt_pass should succeed")
  assert(ctx.prompts.text[1] == "alice", "got: " .. tostring(ctx.prompts.text[1]))
end

-- 2. %^{Prompt|a|b|c} fires vim.ui.select with three choices.
do
  local original_select = vim.ui.select
  local seen_opts
  vim.ui.select = function(opts, _o, cb)
    seen_opts = opts
    cb("b")
  end
  local ctx = {}
  local ok = placeholder.prompt_pass("Pick %^{Color|red|green|blue}", ctx)
  vim.ui.select = original_select
  assert(ok)
  assert(
    seen_opts[1] == "red" and seen_opts[2] == "green" and seen_opts[3] == "blue",
    "opts: " .. vim.inspect(seen_opts)
  )
  assert(ctx.prompts.text[1] == "b")
end

-- 3. Cancelled vim.ui.input → prompt_pass returns false.
do
  local original = vim.ui.input
  vim.ui.input = function(_opts, cb)
    cb(nil)
  end
  local ctx = {}
  local ok = placeholder.prompt_pass("Hi %^{Name}", ctx)
  vim.ui.input = original
  assert(ok == false, "prompt_pass should return false on cancel")
end

-- 4. Cancelled vim.ui.select → prompt_pass returns false.
do
  local original = vim.ui.select
  vim.ui.select = function(_opts, _o, cb)
    cb(nil)
  end
  local ctx = {}
  local ok = placeholder.prompt_pass("Pick %^{X|a|b}", ctx)
  vim.ui.select = original
  assert(ok == false)
end

-- 5. %^g fires vim.ui.input and stores into ctx.prompts.tags.
do
  local original = vim.ui.input
  vim.ui.input = function(_opts, cb)
    cb(":work:urgent:")
  end
  local ctx = {}
  local ok = placeholder.prompt_pass("Tags: %^g", ctx)
  vim.ui.input = original
  assert(ok)
  assert(ctx.prompts.tags == ":work:urgent:", "got: " .. tostring(ctx.prompts.tags))
end

-- 6. %^t fires vim.ui.input with today's date as default.
do
  local original = vim.ui.input
  local seen_default
  vim.ui.input = function(opts, cb)
    seen_default = opts.default
    cb("2026-05-01")
  end
  local ctx = { now = os.time({ year = 2026, month = 4, day = 26, hour = 12, min = 0, sec = 0 }) }
  local ok = placeholder.prompt_pass("when: %^t", ctx)
  vim.ui.input = original
  assert(ok)
  assert(seen_default == "2026-04-26", "default should be today; got " .. tostring(seen_default))
  assert(ctx.prompts.dates[1] == "2026-05-01")
end

-- 7. Multiple prompts in order: text[1], text[2], dates[1].
do
  local input_calls = 0
  local input_returns = { "alpha", "beta", "2026-05-01" }
  local original = vim.ui.input
  vim.ui.input = function(_opts, cb)
    input_calls = input_calls + 1
    cb(input_returns[input_calls])
  end
  local ctx = { now = os.time({ year = 2026, month = 4, day = 26, hour = 12, min = 0, sec = 0 }) }
  local ok = placeholder.prompt_pass("%^{A} %^{B} %^t", ctx)
  vim.ui.input = original
  assert(ok)
  assert(ctx.prompts.text[1] == "alpha")
  assert(ctx.prompts.text[2] == "beta")
  assert(ctx.prompts.dates[1] == "2026-05-01")
end

-- 8. No prompts in body → returns true, ctx untouched.
do
  local ctx = {}
  local ok = placeholder.prompt_pass("just plain %t text", ctx)
  assert(ok)
  assert(#(ctx.prompts.text or {}) == 0)
end

-- 9. %^u / %^U prompt like %^t / %^T (inactive variants).
do
  local original = vim.ui.input
  local seen = {}
  vim.ui.input = function(opts, cb)
    seen[#seen + 1] = opts.default
    cb("2026-05-01")
  end
  local ctx = { now = os.time({ year = 2026, month = 4, day = 26, hour = 12, min = 0, sec = 0 }) }
  local ok = placeholder.prompt_pass("%^u %^U", ctx)
  vim.ui.input = original
  assert(ok)
  assert(seen[1] == "2026-04-26", "u default: " .. tostring(seen[1]))
  assert(seen[2] == "2026-04-26 12:00", "U default: " .. tostring(seen[2]))
  assert(#ctx.prompts.dates == 2, "got " .. vim.inspect(ctx.prompts.dates))
end

-- 10. Asynchronous vim.ui (callback fired later, as snacks/dressing do):
-- the continuation receives the result once every prompt has answered.
do
  local original = vim.ui.input
  vim.ui.input = function(_opts, cb)
    vim.schedule(function()
      cb("later")
    end)
  end
  local ctx = {}
  local done
  local ret = placeholder.prompt_pass("%^{A} %^{B}", ctx, function(ok)
    done = ok
  end)
  assert(ret == nil, "no synchronous result for an async UI; got " .. tostring(ret))
  assert(done == nil, "continuation must not run before the UI answers")
  vim.wait(500, function()
    return done ~= nil
  end)
  vim.ui.input = original
  assert(done == true, "continuation should receive true; got " .. tostring(done))
  assert(
    ctx.prompts.text[1] == "later" and ctx.prompts.text[2] == "later",
    "got: " .. vim.inspect(ctx.prompts)
  )
end

-- 11. Asynchronous cancel reaches the continuation as false.
do
  local original = vim.ui.input
  vim.ui.input = function(_opts, cb)
    vim.schedule(function()
      cb(nil)
    end)
  end
  local done
  placeholder.prompt_pass("%^{A}", {}, function(ok)
    done = ok
  end)
  vim.wait(500, function()
    return done ~= nil
  end)
  vim.ui.input = original
  assert(done == false, "continuation should receive false; got " .. tostring(done))
end

-- 12. Synchronous UI with a continuation: both the return value and the
-- callback report the result.
do
  local original = vim.ui.input
  vim.ui.input = function(_opts, cb)
    cb("now")
  end
  local ctx = {}
  local done
  local ret = placeholder.prompt_pass("%^{A}", ctx, function(ok)
    done = ok
  end)
  vim.ui.input = original
  assert(ret == true and done == true, "ret=" .. tostring(ret) .. " done=" .. tostring(done))
  assert(ctx.prompts.text[1] == "now")
end

io.write("capture prompts ok\n")
os.exit(0)
