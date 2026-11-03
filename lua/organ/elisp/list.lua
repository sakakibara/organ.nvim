-- Lists and sequences (D2, D5a, D5c): the list, vector and mapping
-- builtins and the seq.el functions of the subset, ported from fns.c,
-- data.c, subr.el and seq.el.
--
-- Destructive builtins mutate conses as Emacs does.  `nconc' refuses
-- `cycle' before a splice would make any list or vector reach itself,
-- through cdrs or elements, so they stay acyclic.  Identity uses
-- organ.elisp.equal, so `eq' of boxes that could be one object in Emacs
-- refuses.  `delete-dups' and `seq-uniq' on lists longer than 100 hash
-- atoms by type and compare other elements pairwise; where Emacs would
-- compare only on a hash collision, an `equal' too deep to answer
-- refuses `eq-identity', as symbols hash by address.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local bn = require("organ.calc.bn")
local equal = require("organ.elisp.equal")
local str = require("organ.elisp.str")

local M = {}

local NIL, T = V.NIL, V.T
local wta = B.wta
local define = B.define

local Q_ERROR = V.intern("error")
local Q_ARGS_RANGE = V.intern("args-out-of-range")

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

local function is_vec(v)
  return type(v) == "table" and v.k == "vec"
end

local function is_str(v)
  return type(v) == "table" and v.k == "str"
end

local function is_closure(v)
  return type(v) == "table" and v.k == "fn" and v.kind == "closure"
end

local function arg(argv, i)
  if i <= argv.n then
    return argv[i]
  end
  return NIL
end

local function funcall(run, f, ...)
  local argv = { n = select("#", ...), ... }
  return require("organ.elisp.eval").funcall(run, f, argv)
end

-- A call of a subset builtin from a port of its Lisp definition.
local function call(run, name, ...)
  local argv = { n = select("#", ...), ... }
  return B.defs[name].fn(run, argv)
end

local function truthy(v)
  return v ~= NIL
end

local length = str.length
local sequence_items = str.sequence_items

local function new_list(run, items, n)
  run:check_list(n)
  run:step(n)
  run:charge(32 * n)
  return V.list(items, n)
end
M.new_list = new_list

local function new_vector(run, items, n)
  run:check_list(n)
  run:step(n)
  run:charge(8 * n)
  local v = { k = "vec", n = n }
  for i = 1, n do
    v[i] = items[i]
  end
  return v
end
M.new_vector = new_vector

local function car(x)
  if is_cons(x) then
    return x.car
  elseif x == NIL then
    return NIL
  end
  wta("listp", x)
end

local function cdr(x)
  if is_cons(x) then
    return x.cdr
  elseif x == NIL then
    return NIL
  end
  wta("listp", x)
end

--- safe-length: the number of conses in the cdr chain of `x`.
local function safe_length(run, x)
  local n = 0
  while is_cons(x) do
    run:step(1)
    n = n + 1
    x = x.cdr
  end
  return n
end

--- copy-sequence of a list or vector value.
local function copy_sequence(run, x)
  if x == NIL then
    return NIL
  elseif is_vec(x) then
    return new_vector(run, x, x.n)
  elseif is_cons(x) then
    local items, n, t = {}, 0, x
    while is_cons(t) do
      n = n + 1
      items[n] = t.car
      t = t.cdr
    end
    if t ~= NIL then
      wta("listp", t)
    end
    return new_list(run, items, n)
  end
  wta("sequencep", x)
end

-- Elements

define("car-safe", function(_, argv)
  local x = argv[1]
  return is_cons(x) and x.car or NIL
end)

define("cdr-safe", function(_, argv)
  local x = argv[1]
  return is_cons(x) and x.cdr or NIL
end)

define("caar", function(_, argv)
  return car(car(argv[1]))
end)

define("cadr", function(_, argv)
  return car(cdr(argv[1]))
end)

define("cdar", function(_, argv)
  return cdr(car(argv[1]))
end)

define("cddr", function(_, argv)
  return cdr(cdr(argv[1]))
end)

--- Fnthcdr.
local function nthcdr(run, n, list)
  local count
  if type(n) == "number" then
    if n <= 0 then
      return list
    end
    count = n
  elseif type(n) == "table" and n.k == "big" then
    if n.n.sign < 0 then
      return list
    end
    count = math.huge
  else
    wta("integerp", n)
  end
  local tail, walked = list, 0
  while count > 0 do
    if not is_cons(tail) then
      run:step(walked)
      if tail ~= NIL then
        wta("listp", list)
      end
      return NIL
    end
    tail = tail.cdr
    count = count - 1
    walked = walked + 1
  end
  run:step(walked)
  return tail
end
M.nthcdr = nthcdr

define("nthcdr", function(run, argv)
  return nthcdr(run, argv[1], argv[2])
end)

define("nth", function(run, argv)
  return car(nthcdr(run, argv[1], argv[2]))
end)

--- Faref of a string or vector value.
local function aref(run, array, idx)
  local i = str.fixnum_value(idx)
  if not i then
    wta("fixnump", idx)
  end
  if is_str(array) then
    local s, b = array.s, 1
    if i >= 0 and i < math.huge then
      for _ = 1, i do
        local c = s:byte(b)
        if not c then
          break
        end
        b = b + (c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4)
      end
      run:step(1 + math.floor(b / 64))
      if b <= #s then
        return (V.utf8_next(s, b))
      end
    end
    R.signal(Q_ARGS_RANGE, V.list({ array, idx }))
  elseif is_vec(array) then
    if i < 0 or i >= array.n then
      R.signal(Q_ARGS_RANGE, V.list({ array, idx }))
    end
    return array[i + 1]
  elseif is_closure(array) then
    R.refuse("unprintable", "aref of a function")
  end
  wta("arrayp", array)
end

define("aref", function(run, argv)
  return aref(run, argv[1], argv[2])
end)

--- Felt.
local function elt(run, seq, n)
  if is_cons(seq) or seq == NIL then
    return car(nthcdr(run, n, seq))
  elseif not (is_str(seq) or is_vec(seq)) then
    wta("sequencep", seq)
  end
  return aref(run, seq, n)
end

define("elt", function(run, argv)
  return elt(run, argv[1], argv[2])
end)

define("last", function(run, argv)
  local list, n = argv[1], arg(argv, 2)
  if n ~= NIL then
    if not truthy(call(run, ">=", n, 0)) then
      return NIL
    end
    local m = safe_length(run, list)
    if truthy(call(run, "<", n, m)) then
      return nthcdr(run, call(run, "-", m, n), list)
    end
    return list
  end
  if list == NIL then
    return NIL
  end
  return nthcdr(run, safe_length(run, list) - 1, list)
end)

--- Ftake.
local function take(run, n, list)
  local m
  if type(n) == "number" then
    if n <= 0 then
      return NIL
    end
    m = n
  elseif type(n) == "table" and n.k == "big" then
    if n.n.sign < 0 then
      return NIL
    end
    m = math.huge
  else
    wta("integerp", n)
  end
  if not (is_cons(list) or list == NIL) then
    wta("listp", list)
  end
  local items, k = {}, 0
  while m > 0 and is_cons(list) do
    k = k + 1
    items[k] = list.car
    list = list.cdr
    m = m - 1
  end
  if m > 0 and list ~= NIL then
    wta("listp", list)
  end
  return new_list(run, items, k)
end

define("butlast", function(run, argv)
  local list, n = argv[1], arg(argv, 2)
  if n == NIL then
    n = 1
  end
  if truthy(call(run, "<=", n, 0)) then
    return list
  end
  return take(run, call(run, "-", length(run, list), n), list)
end)

-- Building

define("append", function(run, argv)
  local n = argv.n
  if n == 0 then
    return NIL
  end
  local all, total = {}, 0
  for i = 1, n - 1 do
    local items, k = sequence_items(run, argv[i])
    for j = 1, k do
      all[total + j] = items[j]
    end
    total = total + k
    run:check_list(total)
  end
  run:step(total)
  run:charge(32 * total)
  local out = argv[n]
  for i = total, 1, -1 do
    out = V.cons(all[i], out)
  end
  return out
end)

define("vconcat", function(run, argv)
  local all, total = {}, 0
  for i = 1, argv.n do
    local items, k = sequence_items(run, argv[i])
    for j = 1, k do
      all[total + j] = items[j]
    end
    total = total + k
    run:check_list(total)
  end
  return new_vector(run, all, total)
end)

--- Whether cons `target` is reachable from `x` through cars, cdrs and
--- vector elements, each box visited once and charged.
local function reaches(run, x, target)
  local seen, stack, top = {}, { x }, 1
  while top > 0 do
    local v = stack[top]
    stack[top] = nil
    top = top - 1
    if type(v) == "table" and not seen[v] then
      seen[v] = true
      run:step(1)
      if v == target then
        return true
      elseif v.k == "cons" then
        stack[top + 1], stack[top + 2] = v.cdr, v.car
        top = top + 2
      elseif v.k == "vec" then
        for i = v.n, 1, -1 do
          top = top + 1
          stack[top] = v[i]
        end
      end
    end
  end
  return false
end

--- Fnconc of args[1..n] (modified: an argument after a nil one is
--- replaced by the last cons before it).
local function nconc(run, args, n)
  local val = NIL
  for i = 1, n do
    local tem = args[i]
    if tem ~= NIL then
      if val == NIL then
        val = tem
      end
      if i == n then
        break
      end
      if not is_cons(tem) then
        wta("consp", tem)
      end
      local tail, walked = tem, 0
      while is_cons(tail.cdr) do
        tail = tail.cdr
        walked = walked + 1
      end
      run:step(walked)
      local nxt = args[i + 1]
      if reaches(run, nxt, tail) then
        R.refuse("cycle", "nconc")
      end
      tail.cdr = nxt
      if nxt == NIL then
        args[i + 1] = tail
      end
    end
  end
  return val
end

define("nconc", function(run, argv)
  return nconc(run, argv, argv.n)
end)

define("reverse", function(run, argv)
  local seq = argv[1]
  if seq == NIL then
    return NIL
  elseif is_cons(seq) then
    local out, t = NIL, seq
    while is_cons(t) do
      run:step(1)
      run:charge(32)
      out = V.cons(t.car, out)
      t = t.cdr
    end
    if t ~= NIL then
      wta("listp", t)
    end
    return out
  elseif is_vec(seq) then
    local items = {}
    for i = 1, seq.n do
      items[i] = seq[seq.n - i + 1]
    end
    return new_vector(run, items, seq.n)
  elseif is_str(seq) then
    local codes, n = sequence_items(run, seq)
    local out = {}
    for i = n, 1, -1 do
      out[#out + 1] = V.utf8_char(codes[i])
    end
    return str.new_string(run, table.concat(out))
  end
  wta("sequencep", seq)
end)

define("nreverse", function(run, argv)
  local seq = argv[1]
  if seq == NIL then
    return seq
  elseif is_cons(seq) then
    local prev, tail = NIL, seq
    while is_cons(tail) do
      run:step(1)
      local nxt = tail.cdr
      tail.cdr = prev
      prev = tail
      tail = nxt
    end
    if tail ~= NIL then
      wta("listp", seq)
    end
    return prev
  elseif is_vec(seq) then
    local n = seq.n
    for i = 1, math.floor(n / 2) do
      seq[i], seq[n - i + 1] = seq[n - i + 1], seq[i]
    end
    run:step(n)
    return seq
  elseif is_str(seq) then
    return B.defs.reverse.fn(run, { n = 1, seq })
  end
  wta("arrayp", seq)
end)

define("number-sequence", function(run, argv)
  local from, to, inc = argv[1], arg(argv, 2), arg(argv, 3)
  if to == NIL or truthy(call(run, "=", from, to)) then
    return new_list(run, { from }, 1)
  end
  if inc == NIL then
    inc = 1
  end
  if truthy(call(run, "zerop", inc)) then
    R.signal(Q_ERROR, V.list({ V.str("The increment can not be zero") }))
  end
  local up = truthy(call(run, ">", inc, 0))
  local cap = run.caps.list
  local small = 2 ^ 31
  if
    type(from) == "number"
    and type(to) == "number"
    and type(inc) == "number"
    and math.abs(from) <= small
    and math.abs(to) <= small
    and math.abs(inc) <= small
  then
    local count = 0
    if (up and from <= to) or (not up and from >= to) then
      count = math.floor((to - from) / inc) + 1
    end
    if count > cap then
      R.limit("list")
    end
    local items = {}
    for k = 1, count do
      items[k] = from + (k - 1) * inc
    end
    return new_list(run, items, count)
  end
  local items, n, nxt = {}, 0, from
  local cmp = up and "<=" or ">="
  while truthy(call(run, cmp, nxt, to)) do
    if n + 1 > cap then
      R.limit("list")
    end
    n = n + 1
    items[n] = nxt
    nxt = call(run, "+", from, call(run, "*", n, inc))
  end
  return new_list(run, items, n)
end)

-- Membership and association

--- Walk list `list` until `test(car)` holds: the tail found, or nil
--- after checking the end (wrong-type-argument listp LIST).
local function find_tail(run, list, test)
  local tail = list
  while is_cons(tail) do
    run:step(1)
    if test(tail.car) then
      return tail
    end
    tail = tail.cdr
  end
  if tail ~= NIL then
    wta("listp", list)
  end
  return NIL
end

local function eq(run, a, b)
  return equal.eq(run, a, b)
end

define("memq", function(run, argv)
  local elt = argv[1]
  return find_tail(run, argv[2], function(x)
    return eq(run, x, elt)
  end)
end)

define("memql", function(run, argv)
  local elt = argv[1]
  return find_tail(run, argv[2], function(x)
    return equal.eql(run, elt, x)
  end)
end)

local function member(run, elt, list)
  return find_tail(run, list, function(x)
    return equal.equal(run, elt, x)
  end)
end

define("member", function(run, argv)
  return member(run, argv[1], argv[2])
end)

local function assq(run, key, alist)
  local found = find_tail(run, alist, function(x)
    return is_cons(x) and eq(run, x.car, key)
  end)
  return is_cons(found) and found.car or NIL
end

local function assoc(run, key, alist, testfn)
  local found = find_tail(run, alist, function(x)
    if not is_cons(x) then
      return false
    elseif testfn == NIL then
      return equal.equal(run, x.car, key)
    end
    return truthy(funcall(run, testfn, x.car, key))
  end)
  return is_cons(found) and found.car or NIL
end

define("assq", function(run, argv)
  return assq(run, argv[1], argv[2])
end)

define("assoc", function(run, argv)
  return assoc(run, argv[1], argv[2], arg(argv, 3))
end)

define("rassq", function(run, argv)
  local key = argv[1]
  local found = find_tail(run, argv[2], function(x)
    return is_cons(x) and eq(run, x.cdr, key)
  end)
  return is_cons(found) and found.car or NIL
end)

define("rassoc", function(run, argv)
  local key = argv[1]
  local found = find_tail(run, argv[2], function(x)
    return is_cons(x) and equal.equal(run, x.cdr, key)
  end)
  return is_cons(found) and found.car or NIL
end)

define("alist-get", function(run, argv)
  local key, alist = argv[1], argv[2]
  local default, testfn = arg(argv, 3), arg(argv, 5)
  local x
  if testfn == NIL then
    x = assq(run, key, alist)
  else
    x = assoc(run, key, alist, testfn)
  end
  if x ~= NIL then
    return x.cdr
  end
  return default
end)

-- Deletion

--- Remove the elements of list `list` for which `test(car)` holds by
--- splicing its conses (Fdelq, Fdelete): the resulting list.
local function delete_from(run, list, test)
  local prev, tail = NIL, list
  while is_cons(tail) do
    run:step(1)
    if test(tail.car) then
      if prev == NIL then
        list = tail.cdr
      else
        prev.cdr = tail.cdr
      end
    else
      prev = tail
    end
    tail = tail.cdr
  end
  if tail ~= NIL then
    wta("listp", list)
  end
  return list
end

local function delq(run, elt, list)
  return delete_from(run, list, function(x)
    return eq(run, elt, x)
  end)
end

define("delq", function(run, argv)
  return delq(run, argv[1], argv[2])
end)

--- Fdelete.
local function delete(run, elt, seq)
  if seq == NIL then
    return seq
  elseif is_cons(seq) then
    return delete_from(run, seq, function(x)
      return equal.equal(run, elt, x)
    end)
  elseif is_vec(seq) then
    local kept, n = {}, 0
    for i = 1, seq.n do
      if not equal.equal(run, seq[i], elt) then
        n = n + 1
        kept[n] = seq[i]
      end
    end
    if n == seq.n then
      return seq
    end
    return new_vector(run, kept, n)
  elseif is_str(seq) then
    if not (type(elt) == "number" and elt >= 0 and elt <= 0x3FFFFF) then
      return seq
    end
    local codes, n = sequence_items(run, seq)
    local out, changed = {}, false
    for i = 1, n do
      if codes[i] == elt then
        changed = true
      else
        out[#out + 1] = V.utf8_char(codes[i])
      end
    end
    if not changed then
      return seq
    end
    return str.new_string(run, table.concat(out))
  end
  wta("sequencep", seq)
end

define("delete", function(run, argv)
  return delete(run, argv[1], argv[2])
end)

define("remove", function(run, argv)
  local elt, seq = argv[1], argv[2]
  if is_cons(seq) or seq == NIL then
    seq = copy_sequence(run, seq)
  end
  return delete(run, elt, seq)
end)

define("remq", function(run, argv)
  local elt, list = argv[1], argv[2]
  while eq(run, elt, car(list)) do
    list = cdr(list)
    if list == NIL then
      break
    end
  end
  if find_tail(run, list, function(x)
    return eq(run, x, elt)
  end) ~= NIL then
    return delq(run, elt, copy_sequence(run, list))
  end
  return list
end)

-- Hashing under `equal' (delete-dups, seq-uniq): the key of an atom,
-- or nil for an element compared pairwise.
local function hash_key(run, x)
  local tx = type(x)
  if tx == "number" then
    return x
  end
  local k = x.k
  if k == "big" then
    return "i" .. bn.to_string(x.n)
  elseif k == "flt" then
    if x.x ~= x.x then
      R.refuse("nan", "hashing", { x })
    end
    return "f" .. string.format("%a", x.x)
  elseif k == "str" then
    run:step(math.floor(#x.s / 64))
    return "s" .. x.s
  elseif k == "sym" then
    return x
  end
  return nil
end

--- An `equal' set of the elements seen so far, as Emacs's
--- (make-hash-table :test #'equal) answers membership.
local function equal_set(run)
  local keys, others = {}, {}
  local set = {}
  function set.has(x)
    local key = hash_key(run, x)
    if key ~= nil then
      return keys[key] == true
    end
    for i = 1, #others do
      local ok, same = pcall(equal.equal, run, others[i], x)
      if not ok then
        if type(same) == "table" and same.elisp == "signal" then
          R.refuse("eq-identity", "equal in a hash table", { others[i], x })
        end
        error(same, 0)
      end
      if same then
        return true
      end
    end
    return false
  end
  function set.add(x)
    local key = hash_key(run, x)
    if key ~= nil then
      keys[key] = true
    else
      others[#others + 1] = x
    end
  end
  return set
end

define("delete-dups", function(run, argv)
  local list = argv[1]
  local l = length(run, list)
  if l > 100 then
    local set = equal_set(run)
    set.add(car(list))
    local tail = list
    while true do
      local retail = cdr(tail)
      if retail == NIL then
        break
      end
      run:step(1)
      local x = retail.car
      if set.has(x) then
        tail.cdr = retail.cdr
      else
        set.add(x)
        tail = retail
      end
    end
    return list
  end
  local tail = list
  while tail ~= NIL do
    local x = car(tail)
    tail.cdr = delete(run, x, tail.cdr)
    tail = tail.cdr
  end
  return list
end)

-- Mapping

--- mapcar1: call `each(i, x)` on each of the `leni` elements of `seq`,
--- reading a list's conses as the calls change them, until one returns
--- true; the number of elements reached.
local function map1(run, seq, leni, each)
  if seq == NIL then
    return 0
  elseif is_cons(seq) then
    local tail = seq
    for i = 1, leni do
      if not is_cons(tail) then
        return i - 1
      end
      if each(i, tail.car) then
        return i
      end
      tail = tail.cdr
    end
  elseif is_vec(seq) then
    for i = 1, leni do
      if each(i, seq[i]) then
        return i
      end
    end
  elseif is_str(seq) then
    local codes = sequence_items(run, seq)
    for i = 1, leni do
      if each(i, codes[i]) then
        return i
      end
    end
  else
    wta("sequencep", seq)
  end
  return leni
end
M.map1 = map1

--- Fmapcar's results: the array of FN's values and their count.
local function map_values(run, fn, seq)
  local leni = length(run, seq)
  local vals = {}
  local n = map1(run, seq, leni, function(i, x)
    vals[i] = funcall(run, fn, x)
  end)
  return vals, n
end

define("mapcar", function(run, argv)
  local vals, n = map_values(run, argv[1], argv[2])
  return new_list(run, vals, n)
end)

define("mapc", function(run, argv)
  local fn, seq = argv[1], argv[2]
  map1(run, seq, length(run, seq), function(_, x)
    funcall(run, fn, x)
  end)
  return seq
end)

define("mapcan", function(run, argv)
  local vals, n = map_values(run, argv[1], argv[2])
  return nconc(run, vals, n)
end)

-- seq.el

local function is_list(v)
  return v == NIL or is_cons(v)
end

--- The elements of `seq` for which `keep(x)` holds, as seq-filter
--- maps them.
local function seq_filter(run, seq, keep)
  local leni = length(run, seq)
  local kept, n = {}, 0
  map1(run, seq, leni, function(_, x)
    if keep(x) then
      n = n + 1
      kept[n] = x
    end
  end)
  return new_list(run, kept, n)
end

define("seq-filter", function(run, argv)
  local pred = argv[1]
  return seq_filter(run, argv[2], function(x)
    return truthy(funcall(run, pred, x))
  end)
end)

define("seq-remove", function(run, argv)
  local pred = argv[1]
  return seq_filter(run, argv[2], function(x)
    return not truthy(funcall(run, pred, x))
  end)
end)

define("seq-map", function(run, argv)
  local vals, n = map_values(run, argv[1], argv[2])
  return new_list(run, vals, n)
end)

define("seq-reduce", function(run, argv)
  local fn, seq, acc = argv[1], argv[2], argv[3]
  if is_list(seq) then
    if seq == NIL then
      return acc
    end
  elseif length(run, seq) == 0 then
    return acc
  end
  map1(run, seq, length(run, seq), function(_, x)
    acc = funcall(run, fn, acc, x)
  end)
  return acc
end)

local function substring(run, seq, from, to)
  return B.defs.substring.fn(run, { n = 3, seq, from, to })
end

--- seq-drop.
local function seq_drop(run, seq, n)
  if is_list(seq) then
    return nthcdr(run, n, seq)
  end
  if truthy(call(run, "<=", n, 0)) then
    return seq
  end
  local len = length(run, seq)
  return substring(run, seq, call(run, "min", n, len), len)
end

define("seq-take", function(run, argv)
  local seq, n = argv[1], argv[2]
  if is_list(seq) then
    return take(run, n, seq)
  end
  local m = call(run, "max", n, 0)
  return substring(run, seq, 0, call(run, "min", m, length(run, seq)))
end)

define("seq-drop", function(run, argv)
  return seq_drop(run, argv[1], argv[2])
end)

-- Belt, the byte-code `elt' seq.el's compiled methods run: a list
-- indexed below 128 signals with the tail it reaches.
local function compiled_elt(run, seq, n)
  if is_cons(seq) and type(n) == "number" and n >= 0 and n <= 127 then
    local v = seq
    for _ = 1, n do
      if not is_cons(v) then
        break
      end
      v = v.cdr
    end
    run:step(n)
    return car(v)
  end
  return elt(run, seq, n)
end

define("seq-elt", function(run, argv)
  return compiled_elt(run, argv[1], argv[2])
end)

define("seq-first", function(run, argv)
  return elt(run, argv[1], 0)
end)

define("seq-rest", function(run, argv)
  return seq_drop(run, argv[1], 1)
end)

--- seq-contains-p's search of `seq` for `x`: the first non-nil value of
--- (TESTFN E X), and the 0-based index of its element.
local function seq_search(run, seq, x, testfn)
  local found, at = NIL, nil
  map1(run, seq, length(run, seq), function(i, e)
    local r
    if testfn == NIL then
      r = equal.equal(run, e, x) and T or NIL
    else
      r = funcall(run, testfn, e, x)
    end
    if r ~= NIL then
      found, at = r, i - 1
      return true
    end
  end)
  return found, at
end

define("seq-contains-p", function(run, argv)
  return (seq_search(run, argv[1], argv[2], arg(argv, 3)))
end)

define("seq-position", function(run, argv)
  local found, at = seq_search(run, argv[1], argv[2], arg(argv, 3))
  if found == NIL then
    return NIL
  end
  return at
end)

define("seq-uniq", function(run, argv)
  local seq, testfn = argv[1], arg(argv, 2)
  local kept, n = {}, 0
  if not is_list(seq) then
    local result = NIL
    map1(run, seq, length(run, seq), function(_, x)
      if seq_search(run, result, x, testfn) == NIL then
        result = V.cons(x, result)
        run:charge(32)
        n = n + 1
        kept[n] = x
      end
    end)
    return new_list(run, kept, n)
  end
  if testfn == NIL then
    local l = length(run, seq)
    if l > 100 then
      local set = equal_set(run)
      local t = seq
      while t ~= NIL do
        run:step(1)
        local x = t.car
        if not set.has(x) then
          set.add(x)
          n = n + 1
          kept[n] = x
        end
        t = t.cdr
      end
      return new_list(run, kept, n)
    end
    local result = NIL
    local t = seq
    while t ~= NIL do
      local x = t.car
      if member(run, x, result) == NIL then
        result = V.cons(x, result)
        run:charge(32)
        n = n + 1
        kept[n] = x
      end
      t = t.cdr
    end
    return new_list(run, kept, n)
  end
  local result = NIL
  local t = seq
  while t ~= NIL do
    local found = NIL
    local r = result
    while is_cons(r) do
      run:step(1)
      local elem = r.car
      if truthy(funcall(run, testfn, elem, car(t))) then
        found = elem
        break
      end
      r = r.cdr
    end
    if found == NIL then
      local x = car(t)
      result = V.cons(x, result)
      run:charge(32)
      n = n + 1
      kept[n] = x
    end
    t = cdr(t)
  end
  return new_list(run, kept, n)
end)

return M
