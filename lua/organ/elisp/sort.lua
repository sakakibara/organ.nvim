-- Sorting (D5c): Emacs 31's `sort' and the `value<' order it defaults
-- to, ported from fns.c and sort.c.  The timsort (powersort merging,
-- galloping) is ported step by step, so a predicate that is not a strict
-- order gives Emacs's order, and a predicate that signals leaves a list
-- unchanged and a vector sorted in place as Emacs leaves it: a signal
-- while a merge holds elements aside puts them back only once the merge
-- area has outgrown sort.c's fixed buffer (or the keys did), which is
-- when Emacs has registered its cleanup.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local bn = require("organ.calc.bn")
local list = require("organ.elisp.list")
local num = require("organ.elisp.num")

local M = {}

local NIL = V.NIL
local wta = B.wta
local floor = math.floor

local Q_ERROR = V.intern("error")
local Q_TYPE_MISMATCH = V.intern("type-mismatch")
local Q_MACRO = V.intern("macro")
local Q_VALUELT = V.intern("value<")
local Q_IDENTITY = V.intern("identity")
local Q_KEY = V.intern(":key")
local Q_LESSP = V.intern(":lessp")
local Q_REVERSE = V.intern(":reverse")
local Q_IN_PLACE = V.intern(":in-place")

local GALLOP_WIN_MIN = 7
local MERGESTATE_TEMP_SIZE = 256

local function kind(v)
  if type(v) == "number" then
    return "int"
  end
  local k = v.k
  if k == "big" then
    return num.emacs_fixnum(v.n) and "int" or "big"
  end
  return k
end

local function plain_error(text)
  R.signal(Q_ERROR, V.list({ V.str(text) }))
end

local function mismatch(a, b)
  R.signal(Q_TYPE_MISMATCH, V.list({ a, b }))
end

local function num_cmp(a, b)
  local c = num.num_cmp(a, b)
  if not c then
    R.refuse("nan", "value<", { num.is_float(a) and a.x ~= a.x and a or b })
  end
  return c
end

local function string_cmp(run, s1, s2)
  run:step(1 + floor(math.min(#s1, #s2) / 64))
  if s1 == s2 then
    return 0
  end
  return s1 < s2 and -1 or 1
end

--- value_cmp: -1, 0 or 1 as `a` precedes, ties or follows `b` in the
--- order of `value<'.
local function value_cmp(run, a, b, maxdepth)
  if maxdepth < 0 then
    plain_error("Maximum depth exceeded in comparison")
  end
  while true do
    run:step(1)
    if a == b then
      return 0
    end
    local ka, kb = kind(a), kind(b)
    if ka == "fn" or kb == "fn" then
      R.refuse("unprintable", "value< of a function")
    end
    if ka == "int" then
      if kb == "int" or kb == "flt" or kb == "big" then
        return num_cmp(a, b)
      end
      mismatch(a, b)
    elseif ka == "sym" then
      if kb == "sym" then
        return string_cmp(run, a.name.s, b.name.s)
      elseif kb == "cons" and a == NIL then
        return -1
      end
      mismatch(a, b)
    elseif ka == "str" then
      if kb == "str" then
        return string_cmp(run, a.s, b.s)
      end
      mismatch(a, b)
    elseif ka == "cons" then
      local again = false
      while kind(b) == "cons" do
        local c = value_cmp(run, a.car, b.car, maxdepth - 1)
        if c ~= 0 then
          return c
        end
        a = a.cdr
        if kind(a) ~= "cons" then
          b = b.cdr
          again = true
          break
        end
        b = b.cdr
      end
      if not again then
        if b == NIL then
          return 1
        end
        mismatch(a, b)
      end
    elseif ka == "vec" then
      if kb ~= "vec" then
        mismatch(a, b)
      end
      for i = 1, math.min(a.n, b.n) do
        local c = value_cmp(run, a[i], b[i], maxdepth - 1)
        if c ~= 0 then
          return c
        end
      end
      return a.n < b.n and -1 or (a.n > b.n and 1 or 0)
    elseif ka == "big" then
      if kb == "big" then
        return bn.cmp(a.n, b.n)
      elseif kb == "vec" then
        mismatch(a, b)
      end
      return -value_cmp(run, b, a, maxdepth)
    else
      if kb == "flt" or kb == "int" or kb == "big" then
        return num_cmp(a, b)
      end
      mismatch(a, b)
    end
  end
end

-- Timsort (sort.c).  Arrays are 0-based Lua tables: `K` the keys and
-- `W` the values (nil when the keys are the values); the merge area
-- holds `TK` and `TW`.  `ms.lt(a, b)` is the order predicate.

local function reverse_range(t, lo, hi)
  hi = hi - 1
  while lo < hi do
    t[lo], t[hi] = t[hi], t[lo]
    lo = lo + 1
    hi = hi - 1
  end
end

local function binarysort(ms, lo, hi, start)
  local K, W, lt = ms.K, ms.W, ms.lt
  if lo == start then
    start = start + 1
  end
  while start < hi do
    local l, r = lo, start
    local pivot = K[r]
    repeat
      local p = l + floor((r - l) / 2)
      if lt(pivot, K[p]) then
        r = p
      else
        l = p + 1
      end
    until l >= r
    for p = start, l + 1, -1 do
      K[p] = K[p - 1]
    end
    K[l] = pivot
    if W then
      local pv = W[start]
      for p = start, l + 1, -1 do
        W[p] = W[p - 1]
      end
      W[l] = pv
    end
    start = start + 1
  end
end

local function count_run(ms, lo, hi)
  local K, lt = ms.K, ms.lt
  lo = lo + 1
  if lo == hi then
    return 1, false
  end
  local n = 2
  if lt(K[lo], K[lo - 1]) then
    lo = lo + 1
    while lo < hi and lt(K[lo], K[lo - 1]) do
      lo = lo + 1
      n = n + 1
    end
    return n, true
  end
  lo = lo + 1
  while lo < hi and not lt(K[lo], K[lo - 1]) do
    lo = lo + 1
    n = n + 1
  end
  return n, false
end

-- The k in [0, n] with A[a+k-1] < key <= A[a+k], searching from `hint`.
local function gallop_left(ms, key, A, a, n, hint)
  local lt = ms.lt
  a = a + hint
  local lastofs, ofs = 0, 1
  if lt(A[a], key) then
    local maxofs = n - hint
    while ofs < maxofs and lt(A[a + ofs], key) do
      lastofs = ofs
      ofs = ofs * 2 + 1
    end
    if ofs > maxofs then
      ofs = maxofs
    end
    lastofs = lastofs + hint
    ofs = ofs + hint
  else
    local maxofs = hint + 1
    while ofs < maxofs and not lt(A[a - ofs], key) do
      lastofs = ofs
      ofs = ofs * 2 + 1
    end
    if ofs > maxofs then
      ofs = maxofs
    end
    local k = lastofs
    lastofs = hint - ofs
    ofs = hint - k
  end
  a = a - hint
  lastofs = lastofs + 1
  while lastofs < ofs do
    local m = lastofs + floor((ofs - lastofs) / 2)
    if lt(A[a + m], key) then
      lastofs = m + 1
    else
      ofs = m
    end
  end
  return ofs
end

-- The k in [0, n] with A[a+k-1] <= key < A[a+k], searching from `hint`.
local function gallop_right(ms, key, A, a, n, hint)
  local lt = ms.lt
  a = a + hint
  local lastofs, ofs = 0, 1
  if lt(key, A[a]) then
    local maxofs = hint + 1
    while ofs < maxofs and lt(key, A[a - ofs]) do
      lastofs = ofs
      ofs = ofs * 2 + 1
    end
    if ofs > maxofs then
      ofs = maxofs
    end
    local k = lastofs
    lastofs = hint - ofs
    ofs = hint - k
  else
    local maxofs = n - hint
    while ofs < maxofs and not lt(key, A[a + ofs]) do
      lastofs = ofs
      ofs = ofs * 2 + 1
    end
    if ofs > maxofs then
      ofs = maxofs
    end
    lastofs = lastofs + hint
    ofs = ofs + hint
  end
  a = a - hint
  lastofs = lastofs + 1
  while lastofs < ofs do
    local m = lastofs + floor((ofs - lastofs) / 2)
    if lt(key, A[a + m]) then
      ofs = m
    else
      lastofs = m + 1
    end
  end
  return ofs
end

-- Copy `n` elements from (SK, SW) at `s` to (DK, DW) at `d`, as memmove.
local function move(DK, DW, d, SK, SW, s, n)
  if d <= s then
    for i = 0, n - 1 do
      DK[d + i] = SK[s + i]
    end
    if DW then
      for i = 0, n - 1 do
        DW[d + i] = SW[s + i]
      end
    end
  else
    for i = n - 1, 0, -1 do
      DK[d + i] = SK[s + i]
    end
    if DW then
      for i = n - 1, 0, -1 do
        DW[d + i] = SW[s + i]
      end
    end
  end
end

-- needmem: a merge area of `need` elements beyond the fixed buffer is
-- allocated, and the cleanup that puts elements back on an error is
-- registered with the first such allocation.
local function needmem(ms, need)
  if need > ms.alloced then
    ms.alloced = need
    ms.cleanup = true
  end
end

-- Stably merge the `na` elements at `ssa` with the `nb` at ssa + na,
-- na <= nb, through the merge area.
local function merge_lo(ms, ssa, na, ssb, nb)
  local K, W, TK, TW, lt = ms.K, ms.W, ms.TK, ms.TW, ms.lt
  needmem(ms, na)
  move(TK, TW, 0, K, W, ssa, na)
  local dest, a, b = ssa, 0, ssb
  ms.reloc = function()
    move(K, W, dest, TK, TW, a, na)
  end
  local function body()
    move(K, W, dest, K, W, b, 1)
    dest, b, nb = dest + 1, b + 1, nb - 1
    if nb == 0 then
      return "done"
    elseif na == 1 then
      return "copy"
    end
    local min_gallop = ms.min_gallop
    while true do
      local acount, bcount = 0, 0
      while true do
        if lt(K[b], TK[a]) then
          move(K, W, dest, K, W, b, 1)
          dest, b, nb = dest + 1, b + 1, nb - 1
          bcount, acount = bcount + 1, 0
          if nb == 0 then
            return "done"
          elseif bcount >= min_gallop then
            break
          end
        else
          move(K, W, dest, TK, TW, a, 1)
          dest, a, na = dest + 1, a + 1, na - 1
          acount, bcount = acount + 1, 0
          if na == 1 then
            return "copy"
          elseif acount >= min_gallop then
            break
          end
        end
      end
      min_gallop = min_gallop + 1
      repeat
        if min_gallop > 1 then
          min_gallop = min_gallop - 1
        end
        ms.min_gallop = min_gallop
        local k = gallop_right(ms, K[b], TK, a, na, 0)
        acount = k
        if k > 0 then
          move(K, W, dest, TK, TW, a, k)
          dest, a, na = dest + k, a + k, na - k
          if na == 1 then
            return "copy"
          elseif na == 0 then
            return "done"
          end
        end
        move(K, W, dest, K, W, b, 1)
        dest, b, nb = dest + 1, b + 1, nb - 1
        if nb == 0 then
          return "done"
        end
        k = gallop_left(ms, TK[a], K, b, nb, 0)
        bcount = k
        if k > 0 then
          move(K, W, dest, K, W, b, k)
          dest, b, nb = dest + k, b + k, nb - k
          if nb == 0 then
            return "done"
          end
        end
        move(K, W, dest, TK, TW, a, 1)
        dest, a, na = dest + 1, a + 1, na - 1
        if na == 1 then
          return "copy"
        end
      until not (acount >= GALLOP_WIN_MIN or bcount >= GALLOP_WIN_MIN)
      min_gallop = min_gallop + 1
      ms.min_gallop = min_gallop
    end
  end
  local outcome = body()
  ms.reloc = nil
  if outcome == "done" then
    if na > 0 then
      move(K, W, dest, TK, TW, a, na)
    end
  else
    move(K, W, dest, K, W, b, nb)
    move(K, W, dest + nb, TK, TW, a, 1)
  end
end

-- Stably merge the `na` elements at `ssa` with the `nb` at ssa + na,
-- na >= nb, from the right through the merge area.
local function merge_hi(ms, ssa, na, ssb, nb)
  local K, W, TK, TW, lt = ms.K, ms.W, ms.TK, ms.TW, ms.lt
  needmem(ms, nb)
  move(TK, TW, 0, K, W, ssb, nb)
  local dest, basea = ssb + nb - 1, ssa
  local a, b = ssa + na - 1, nb - 1
  ms.reloc = function()
    move(K, W, dest - (nb - 1), TK, TW, 0, nb)
  end
  local function body()
    move(K, W, dest, K, W, a, 1)
    dest, a, na = dest - 1, a - 1, na - 1
    if na == 0 then
      return "done"
    elseif nb == 1 then
      return "copy"
    end
    local min_gallop = ms.min_gallop
    while true do
      local acount, bcount = 0, 0
      while true do
        if lt(TK[b], K[a]) then
          move(K, W, dest, K, W, a, 1)
          dest, a, na = dest - 1, a - 1, na - 1
          acount, bcount = acount + 1, 0
          if na == 0 then
            return "done"
          elseif acount >= min_gallop then
            break
          end
        else
          move(K, W, dest, TK, TW, b, 1)
          dest, b, nb = dest - 1, b - 1, nb - 1
          bcount, acount = bcount + 1, 0
          if nb == 1 then
            return "copy"
          elseif bcount >= min_gallop then
            break
          end
        end
      end
      min_gallop = min_gallop + 1
      repeat
        if min_gallop > 1 then
          min_gallop = min_gallop - 1
        end
        ms.min_gallop = min_gallop
        local k = na - gallop_right(ms, TK[b], K, basea, na, na - 1)
        acount = k
        if k > 0 then
          dest, a = dest - k, a - k
          move(K, W, dest + 1, K, W, a + 1, k)
          na = na - k
          if na == 0 then
            return "done"
          end
        end
        move(K, W, dest, TK, TW, b, 1)
        dest, b, nb = dest - 1, b - 1, nb - 1
        if nb == 1 then
          return "copy"
        end
        k = nb - gallop_left(ms, K[a], TK, 0, nb, nb - 1)
        bcount = k
        if k > 0 then
          dest, b = dest - k, b - k
          move(K, W, dest + 1, TK, TW, b + 1, k)
          nb = nb - k
          if nb == 1 then
            return "copy"
          elseif nb == 0 then
            return "done"
          end
        end
        move(K, W, dest, K, W, a, 1)
        dest, a, na = dest - 1, a - 1, na - 1
        if na == 0 then
          return "done"
        end
      until not (acount >= GALLOP_WIN_MIN or bcount >= GALLOP_WIN_MIN)
      min_gallop = min_gallop + 1
      ms.min_gallop = min_gallop
    end
  end
  local outcome = body()
  ms.reloc = nil
  if outcome == "done" then
    if nb > 0 then
      move(K, W, dest - (nb - 1), TK, TW, 0, nb)
    end
  else
    move(K, W, dest + 1 - na, K, W, a + 1 - na, na)
    dest = dest - na
    move(K, W, dest, TK, TW, b, 1)
  end
end

-- Merge the runs at pending[i] and pending[i + 1].
local function merge_at(ms, i)
  local p = ms.pending
  local ssa, na = p[i].base, p[i].len
  local ssb, nb = p[i + 1].base, p[i + 1].len
  p[i].len = na + nb
  if i == ms.n - 2 then
    local q = p[i + 2]
    p[i + 1] = { base = q.base, len = q.len, power = q.power }
  end
  ms.n = ms.n - 1
  local k = gallop_right(ms, ms.K[ssb], ms.K, ssa, na, 0)
  ssa, na = ssa + k, na - k
  if na == 0 then
    return
  end
  nb = gallop_left(ms, ms.K[ssa + na - 1], ms.K, ssb, nb, nb - 1)
  if nb == 0 then
    return
  end
  if na <= nb then
    merge_lo(ms, ssa, na, ssb, nb)
  else
    merge_hi(ms, ssa, na, ssb, nb)
  end
end

local function powerloop(s1, n1, n2, n)
  local a = 2 * s1 + n1
  local b = a + n1 + n2
  local result = 0
  while true do
    result = result + 1
    if a >= n then
      a, b = a - n, b - n
    elseif b >= n then
      break
    end
    a, b = a * 2, b * 2
  end
  return result
end

local function found_new_run(ms, n2)
  if ms.n > 0 then
    local p = ms.pending
    local top = p[ms.n]
    local power = powerloop(top.base, top.len, n2, ms.listlen)
    while ms.n > 1 and p[ms.n - 1].power > power do
      merge_at(ms, ms.n - 1)
    end
    p[ms.n].power = power
  end
end

local function merge_force_collapse(ms)
  local p = ms.pending
  while ms.n > 1 do
    local i = ms.n - 1
    if i > 1 and p[i - 1].len < p[i + 1].len then
      i = i - 1
    end
    merge_at(ms, i)
  end
end

local function compute_minrun(n)
  local r = 0
  while n >= 64 do
    if n % 2 == 1 then
      r = 1
    end
    n = floor(n / 2)
  end
  return n + r
end

--- Sort the 0-based array `K` of `n` >= 2 keys, moving the parallel
--- values `W` (or nil) with them, under the order `lt`.  On an error the
--- arrays are left as Emacs's cleanup (or its absence) leaves them.
local function timsort(n, K, W, lt)
  local ms = {
    K = K,
    W = W,
    TK = {},
    TW = W and {} or nil,
    lt = lt,
    alloced = W and math.min(floor((n + 1) / 2), MERGESTATE_TEMP_SIZE / 2) or MERGESTATE_TEMP_SIZE,
    cleanup = W ~= nil and n >= MERGESTATE_TEMP_SIZE / 2,
    n = 0,
    pending = {},
    min_gallop = GALLOP_WIN_MIN,
    listlen = n,
  }
  local ok, err = pcall(function()
    local minrun = compute_minrun(n)
    local lo, nremaining = 0, n
    repeat
      local run_len, descending = count_run(ms, lo, lo + nremaining)
      if descending then
        reverse_range(K, lo, lo + run_len)
        if W then
          reverse_range(W, lo, lo + run_len)
        end
      end
      if run_len < minrun then
        local force = math.min(nremaining, minrun)
        binarysort(ms, lo, lo + force, lo + run_len)
        run_len = force
      end
      found_new_run(ms, run_len)
      ms.n = ms.n + 1
      ms.pending[ms.n] = { base = lo, len = run_len }
      lo = lo + run_len
      nremaining = nremaining - run_len
    until nremaining == 0
    merge_force_collapse(ms)
  end)
  if not ok then
    if ms.reloc and ms.cleanup then
      ms.reloc()
    end
    error(err, 0)
  end
end

local function funcall(run, f, ...)
  local argv = { n = select("#", ...), ... }
  return require("organ.elisp.eval").funcall(run, f, argv)
end

-- resolve_fun's effect on calls: a symbol naming a macro is called as
-- its (macro . FN) definition, which funcall reports as invalid.
local function resolve(run, f)
  if type(f) == "table" and f.k == "sym" and f ~= NIL and not f.uninterned then
    local name = f.name.s
    if run.ctx.macros and run.ctx.macros[name] then
      R.refuse("function", name)
    end
    local calls = B.calls(name)
    if calls and calls.kind == "macro" then
      return V.cons(Q_MACRO, { k = "fn", kind = "subr", name = name, def = calls })
    end
  end
  return f
end

--- tim_sort: sort the 0-based array `seq` of `n` values in place.
local function tim_sort(run, predicate, keyfunc, seq, n, reverse)
  if predicate == Q_VALUELT then
    predicate = NIL
  end
  if keyfunc == Q_IDENTITY then
    keyfunc = NIL
  end
  if predicate ~= NIL then
    predicate = resolve(run, predicate)
  end
  if reverse and n > 0 then
    reverse_range(seq, 0, n)
  end
  local K, W = seq, nil
  if keyfunc ~= NIL then
    keyfunc = resolve(run, keyfunc)
    K, W = {}, seq
    for i = 0, n - 1 do
      K[i] = funcall(run, keyfunc, seq[i])
    end
  end
  local lt
  if predicate == NIL then
    lt = function(a, b)
      return value_cmp(run, a, b, 200) < 0
    end
  else
    lt = function(a, b)
      run:step(1)
      return funcall(run, predicate, a, b) ~= NIL
    end
  end
  timsort(n, K, W, lt)
  if reverse then
    reverse_range(seq, 0, n)
  end
end

-- Refuse `cycle' when `root` reaches itself through cars, cdrs or
-- vector elements (each box once, charged).
local function check_acyclic(run, root)
  local state, nodes, pos, top = { [root] = 1 }, { root }, { 0 }, 1
  while top > 0 do
    local v = nodes[top]
    local i = pos[top] + 1
    pos[top] = i
    local child, done
    if v.k == "cons" then
      child, done = i == 1 and v.car or v.cdr, i > 2
    else
      child, done = v[i], i > v.n
    end
    if done then
      state[v] = 2
      top = top - 1
    elseif type(child) == "table" and (child.k == "cons" or child.k == "vec") then
      local st = state[child]
      if st == 1 then
        R.refuse("cycle", "sort")
      elseif not st then
        run:step(1)
        state[child] = 1
        top = top + 1
        nodes[top], pos[top] = child, 0
      end
    end
  end
end

-- The 0-based slots of vector `vec`, so that sorting them sorts `vec`
-- itself, as Lisp code the predicate runs sees it.
local function slots(vec)
  return setmetatable({}, {
    __index = function(_, i)
      return vec[i + 1]
    end,
    __newindex = function(_, i, v)
      vec[i + 1] = v
    end,
  })
end

local function signal_error(msg, arg)
  local t = arg
  while type(t) == "table" and t.k == "cons" do
    t = t.cdr
  end
  if t ~= NIL then
    arg = V.list({ arg })
  end
  R.signal(Q_ERROR, V.cons(V.str(msg), arg))
end

B.define("sort", function(run, argv)
  local nargs, seq = argv.n, argv[1]
  local key, lessp, inplace, reverse = NIL, NIL, false, false
  if nargs == 2 then
    lessp, inplace = argv[2], true
  elseif nargs % 2 == 0 then
    plain_error("Invalid argument list")
  else
    for i = 2, nargs - 1, 2 do
      local kw = argv[i]
      if kw == Q_KEY then
        key = argv[i + 1]
      elseif kw == Q_LESSP then
        lessp = argv[i + 1]
      elseif kw == Q_IN_PLACE then
        inplace = argv[i + 1] ~= NIL
      elseif kw == Q_REVERSE then
        reverse = argv[i + 1] ~= NIL
      else
        signal_error("Invalid keyword argument", kw)
      end
    end
  end
  if type(seq) == "table" and seq.k == "cons" then
    local n, t = 0, seq
    while type(t) == "table" and t.k == "cons" do
      run:step(1)
      n = n + 1
      t = t.cdr
    end
    if t ~= NIL then
      wta("listp", t)
    end
    if n < 2 then
      return inplace and seq or list.new_list(run, { seq.car }, 1)
    end
    local arr = {}
    t = seq
    for i = 0, n - 1 do
      arr[i] = t.car
      t = t.cdr
    end
    tim_sort(run, lessp, key, arr, n, reverse)
    if inplace then
      local i, nested = 0, false
      t = seq
      while type(t) == "table" and t.k == "cons" do
        if i >= n then
          R.refuse("cycle", "list grew while sorting")
        end
        run:step(1)
        local x = arr[i]
        nested = nested or (type(x) == "table" and (x.k == "cons" or x.k == "vec"))
        t.car = x
        t = t.cdr
        i = i + 1
      end
      if nested then
        check_acyclic(run, seq)
      end
      return seq
    end
    local items = {}
    for i = 0, n - 1 do
      items[i + 1] = arr[i]
    end
    return list.new_list(run, items, n)
  elseif seq == NIL then
    return seq
  elseif type(seq) == "table" and seq.k == "vec" then
    local vec = inplace and seq or list.new_vector(run, seq, seq.n)
    local n = vec.n
    if n >= 2 then
      tim_sort(run, lessp, key, slots(vec), n, reverse)
    end
    return vec
  end
  wta("list-or-vector-p", seq)
end)

return M
