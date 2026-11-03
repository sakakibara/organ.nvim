-- Calendar, diary and table lookup builtins (D5a, D5b): ports of
-- calendar.el, cal-iso.el and diary-lib.el as Emacs 31.1 compiles them
-- (defsubsts inlined, `nth' and `cadr' as byte-code ops), org-agenda.el's
-- ISO-order wrappers and `org-class', and org-table.el's `org-lookup-*'.
--
-- Arithmetic goes through the subset's builtins, so floats, bignums and
-- malformed dates give Emacs's results and error data.  The diary
-- functions read `date' and `entry' as dynamic variables and
-- `calendar-date-style' as its binding, else `american'.  In the prefix
-- profile diary-lib is loaded only when something else loaded it, so the
-- ISO wrappers refuse `profile' where they call into it.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local equal = require("organ.elisp.equal")
local format = require("organ.elisp.format")
local list = require("organ.elisp.list")
local num = require("organ.elisp.num")
local reader = require("organ.elisp.reader")

local M = {}

local NIL, T = V.NIL, V.T
local define = B.define
local wta = B.wta
local intern = V.intern

local Q_USER_ERROR = intern("user-error")
local Q_ISO = intern("iso")
local Q_EUROPEAN = intern("european")
local Q_HOLIDAYS = intern("holidays")

local function vector_of(items)
  local v = { k = "vec", n = #items }
  for i, x in ipairs(items) do
    v[i] = x
  end
  return v
end

local MONTH_DAYS = vector_of({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })
local TH = V.str("th")
local SUFFIXES = vector_of({ TH, V.str("st"), V.str("nd"), V.str("rd") })
local TEENS = { [11] = true, [12] = true, [13] = true }

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

local function arg(argv, i)
  if i <= argv.n then
    return argv[i]
  end
  return NIL
end

local function call(run, name, ...)
  local argv = { n = select("#", ...), ... }
  return B.defs[name].fn(run, argv)
end

local function truthy(v)
  return v ~= NIL
end

local function evaluator()
  return require("organ.elisp.eval")
end

local function user_error(text)
  R.signal(Q_USER_ERROR, V.list({ V.str(text) }))
end

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

-- Bnth with a constant index: the car of the tail reached by at most n
-- cdrs of conses, so the error names that tail, not the list (Fnth).
local function bnth(n, x)
  for _ = 1, n do
    if not is_cons(x) then
      break
    end
    x = x.cdr
  end
  return car(x)
end

local function month_of(date)
  return car(date)
end

local function day_of(date)
  return car(cdr(date))
end

local function year_of(date)
  return bnth(2, date)
end

local function list3(run, a, b, c)
  return list.new_list(run, { a, b, c }, 3)
end

local function zerop(run, x)
  return truthy(call(run, "=", 0, x))
end

local function leap_year_p(run, year)
  if truthy(call(run, "<", year, 0)) then
    year = call(run, "1-", call(run, "abs", year))
  end
  if not zerop(run, call(run, "%", year, 4)) then
    return false
  end
  return not zerop(run, call(run, "%", year, 100)) or zerop(run, call(run, "%", year, 400))
end

local function last_day_of_month(run, month, year)
  if truthy(call(run, "=", month, 2)) and leap_year_p(run, year) then
    return 29
  end
  return call(run, "aref", MONTH_DAYS, call(run, "1-", month))
end

local function day_number(run, date)
  local month = month_of(date)
  local day = day_of(date)
  local year = year_of(date)
  local doy = call(run, "+", day, call(run, "*", 31, call(run, "1-", month)))
  if truthy(call(run, ">", month, 2)) then
    doy = call(run, "-", doy, call(run, "/", call(run, "+", 23, call(run, "*", 4, month)), 10))
    if leap_year_p(run, year) then
      doy = call(run, "1+", doy)
    end
  end
  return doy
end

local function absolute_from_gregorian(run, date)
  local year = year_of(date)
  if zerop(run, year) then
    user_error("There was no year zero")
  end
  if truthy(call(run, ">", year, 0)) then
    local off = call(run, "1-", year)
    return call(
      run,
      "+",
      day_number(run, date),
      call(run, "*", 365, off),
      call(run, "/", off, 4),
      call(run, "-", call(run, "/", off, 100)),
      call(run, "/", off, 400)
    )
  end
  local off = call(run, "abs", call(run, "1+", year))
  return call(
    run,
    "-",
    day_number(run, date),
    call(run, "*", 365, off),
    call(run, "/", off, 4),
    call(run, "-", call(run, "/", off, 100)),
    call(run, "/", off, 400),
    366
  )
end

local function gregorian_from_absolute(run, date)
  local d0 = call(run, "1-", date)
  local n400 = call(run, "/", d0, 146097)
  local d1 = call(run, "%", d0, 146097)
  local n100 = call(run, "/", d1, 36524)
  local d2 = call(run, "%", d1, 36524)
  local n4 = call(run, "/", d2, 1461)
  local d3 = call(run, "%", d2, 1461)
  local n1 = call(run, "/", d3, 365)
  local day = call(run, "1+", call(run, "%", d3, 365))
  local year =
    call(run, "+", call(run, "*", 400, n400), call(run, "*", 100, n100), call(run, "*", n4, 4), n1)
  if truthy(call(run, "=", n100, 4)) or truthy(call(run, "=", n1, 4)) then
    return list3(run, 12, 31, year)
  end
  year = call(run, "1+", year)
  local month = 1
  while true do
    run:step(1)
    local mdays = last_day_of_month(run, month, year)
    if not truthy(call(run, "<", mdays, day)) then
      break
    end
    day = call(run, "-", day, mdays)
    month = call(run, "1+", month)
  end
  return list3(run, month, day, year)
end

local function day_of_week(run, date)
  return call(run, "mod", absolute_from_gregorian(run, date), 7)
end

local function date_equal(run, a, b)
  return truthy(call(run, "=", month_of(a), month_of(b)))
    and truthy(call(run, "=", day_of(a), day_of(b)))
    and truthy(call(run, "=", year_of(a), year_of(b)))
end

-- length= of a list against 3 (length_internal: a dotted tail after
-- three conses still counts).
local function length3(x)
  for _ = 1, 3 do
    if not is_cons(x) then
      return false
    end
    x = x.cdr
  end
  return not is_cons(x)
end

local function date_is_valid_p(run, date)
  if not (date == NIL or is_cons(date)) or not length3(date) then
    return false
  end
  local month, day, year = month_of(date), day_of(date), year_of(date)
  if not (num.is_int(month) and num.is_int(day) and num.is_int(year)) then
    return false
  end
  return truthy(call(run, "<=", 1, month))
    and truthy(call(run, "<=", month, 12))
    and truthy(call(run, "<=", 1, day))
    and truthy(call(run, "<=", day, last_day_of_month(run, month, year)))
    and truthy(call(run, "<=", 1, year))
end

local function dayname_on_or_before(run, dayname, date)
  return call(run, "-", date, call(run, "%", call(run, "-", date, dayname), 7))
end

local function nth_named_absday(run, n, dayname, month, year, day)
  if truthy(call(run, ">", n, 0)) then
    return call(
      run,
      "+",
      call(run, "*", 7, call(run, "1-", n)),
      dayname_on_or_before(
        run,
        dayname,
        call(
          run,
          "+",
          6,
          absolute_from_gregorian(run, list3(run, month, truthy(day) and day or 1, year))
        )
      )
    )
  end
  return call(
    run,
    "+",
    call(run, "*", 7, call(run, "1+", n)),
    dayname_on_or_before(
      run,
      dayname,
      absolute_from_gregorian(
        run,
        list3(run, month, truthy(day) and day or last_day_of_month(run, month, year), year)
      )
    )
  )
end

-- calendar-iso-to-absolute of (WEEK DAY YEAR).
local function iso_to_absolute(run, date)
  local day = day_of(date)
  return call(
    run,
    "+",
    dayname_on_or_before(
      run,
      1,
      call(run, "+", 3, absolute_from_gregorian(run, list3(run, 1, 1, year_of(date))))
    ),
    call(run, "*", 7, call(run, "1-", month_of(date))),
    zerop(run, day) and 6 or call(run, "1-", day)
  )
end

local function iso_from_absolute(run, date)
  local approx = year_of(gregorian_from_absolute(run, call(run, "-", date, 3)))
  local y, sum = approx, 0
  while true do
    run:step(1)
    local next_year = list3(run, 1, 1, call(run, "1+", y))
    if not truthy(call(run, ">=", date, iso_to_absolute(run, next_year))) then
      break
    end
    sum = call(run, "+", sum, 1)
    y = call(run, "1+", y)
  end
  local year = call(run, "+", approx, sum)
  return list3(
    run,
    call(
      run,
      "1+",
      call(run, "/", call(run, "-", date, iso_to_absolute(run, list3(run, 1, 1, year))), 7)
    ),
    call(run, "%", date, 7),
    year
  )
end

local function bool(b)
  return b and T or NIL
end

define("calendar-extract-month", function(_, argv)
  return month_of(argv[1])
end)

define("calendar-extract-day", function(_, argv)
  return day_of(argv[1])
end)

define("calendar-extract-year", function(_, argv)
  return year_of(argv[1])
end)

define("calendar-leap-year-p", function(run, argv)
  return bool(leap_year_p(run, argv[1]))
end)

define("calendar-last-day-of-month", function(run, argv)
  return last_day_of_month(run, argv[1], argv[2])
end)

define("calendar-day-number", function(run, argv)
  return day_number(run, argv[1])
end)

define("calendar-absolute-from-gregorian", function(run, argv)
  return absolute_from_gregorian(run, argv[1])
end)

define("calendar-gregorian-from-absolute", function(run, argv)
  return gregorian_from_absolute(run, argv[1])
end)

define("calendar-day-of-week", function(run, argv)
  return day_of_week(run, argv[1])
end)

define("calendar-date-is-valid-p", function(run, argv)
  return bool(date_is_valid_p(run, argv[1]))
end)

-- Diary

local function dynamic(run, name)
  return evaluator().dynamic_value(run, intern(name))
end

local function date_style(run)
  return evaluator().date_style(run)
end

-- diary-make-date: (MONTH DAY YEAR) from A B C in `style'.
local function make_date(run, a, b, c, style)
  if style == Q_ISO then
    return list3(run, b, c, a)
  elseif style == Q_EUROPEAN then
    return list3(run, b, a, c)
  end
  return list3(run, a, b, c)
end

local function entry_cons(run, mark)
  run:charge(32)
  return V.cons(mark, dynamic(run, "entry"))
end

local function ordinal_suffix(run, n)
  local r100 = call(run, "%", n, 100)
  if type(r100) == "number" and TEENS[r100] then
    return TH
  end
  if truthy(call(run, "<", 3, call(run, "%", n, 10))) then
    return TH
  end
  return call(run, "aref", SUFFIXES, call(run, "%", n, 10))
end

local function formatted_entry(run, mark, n)
  local entry = dynamic(run, "entry")
  local suffix = ordinal_suffix(run, n)
  local text = format.format(run, { n = 3, entry, n, suffix }, false)
  run:charge(32)
  return V.cons(mark, text)
end

-- (or (and (listp x) (memq v x)) (equal v x) (eq x t))
local function field_matches(run, v, x)
  if (x == NIL or is_cons(x)) and truthy(call(run, "memq", v, x)) then
    return true
  end
  return equal.equal(run, v, x) or x == T
end

local function diary_date(run, argv, style)
  local ddate = make_date(run, argv[1], argv[2], argv[3], style)
  local dd, mm, yy = day_of(ddate), month_of(ddate), year_of(ddate)
  local date = dynamic(run, "date")
  local m = month_of(date)
  local y = year_of(date)
  local d = day_of(date)
  if field_matches(run, d, dd) and field_matches(run, m, mm) and field_matches(run, y, yy) then
    return entry_cons(run, arg(argv, 4))
  end
  return NIL
end

local function diary_block(run, argv, style)
  local date1 = absolute_from_gregorian(run, make_date(run, argv[1], argv[2], argv[3], style))
  local date2 = absolute_from_gregorian(run, make_date(run, argv[4], argv[5], argv[6], style))
  local d = absolute_from_gregorian(run, dynamic(run, "date"))
  if truthy(call(run, "<=", date1, d)) and truthy(call(run, "<=", d, date2)) then
    return entry_cons(run, arg(argv, 7))
  end
  return NIL
end

local function diary_cyclic(run, argv, style)
  local n = argv[1]
  if not truthy(call(run, ">", n, 0)) then
    user_error("Day count must be positive")
  end
  local diff = call(
    run,
    "-",
    absolute_from_gregorian(run, dynamic(run, "date")),
    absolute_from_gregorian(run, make_date(run, argv[2], argv[3], argv[4], style))
  )
  local cycle = call(run, "/", diff, n)
  if truthy(call(run, ">=", diff, 0)) and zerop(run, call(run, "%", diff, n)) then
    return formatted_entry(run, arg(argv, 5), cycle)
  end
  return NIL
end

local function diary_anniversary(run, argv, style)
  local ddate = make_date(run, argv[1], argv[2], arg(argv, 3), style)
  local dd, mm, yy = day_of(ddate), month_of(ddate), year_of(ddate)
  local date = dynamic(run, "date")
  local y = year_of(date)
  local diff = truthy(yy) and call(run, "-", y, yy) or 100
  if
    truthy(call(run, "=", mm, 2))
    and truthy(call(run, "=", dd, 29))
    and not leap_year_p(run, y)
  then
    mm, dd = 3, 1
  end
  if truthy(call(run, ">", diff, 0)) and date_equal(run, list3(run, mm, dd, y), date) then
    return formatted_entry(run, arg(argv, 4), diff)
  end
  return NIL
end

-- (or (eq month t) (if (listp month) (memq m month) (= m month)))
local function month_matches(run, month, m)
  if month == T then
    return true
  elseif month == NIL or is_cons(month) then
    return truthy(call(run, "memq", m, month))
  end
  return truthy(call(run, "=", m, month))
end

local function diary_float(run, argv)
  local month, dayname, n, day = argv[1], argv[2], argv[3], arg(argv, 4)
  local date = dynamic(run, "date")
  if not truthy(call(run, "=", dayname, day_of_week(run, date))) then
    return NIL
  end
  local m = month_of(date)
  local d = day_of(date)
  local y = year_of(date)
  local limit = nth_named_absday(run, call(run, "-", n), dayname, m, y, d)
  local positive = truthy(call(run, ">", n, 0))
  local last_abs = positive and limit or call(run, "+", limit, 6)
  local first_abs = positive and call(run, "-", limit, 6) or limit
  local last = gregorian_from_absolute(run, last_abs)
  local first = gregorian_from_absolute(run, first_abs)
  local m1, d1, y1 = month_of(first), day_of(first), year_of(first)
  local m2, d2, y2 = month_of(last), day_of(last), year_of(last)
  local function base_day(mx, yx)
    if truthy(day) then
      return day
    elseif truthy(call(run, ">", n, 0)) then
      return 1
    end
    return last_day_of_month(run, mx, yx)
  end
  local applies = false
  if truthy(call(run, "=", m1, m2)) and month_matches(run, month, m1) then
    local bd = base_day(m1, y1)
    applies = truthy(call(run, "<=", d1, bd)) and truthy(call(run, "<=", bd, d2))
  end
  if not applies then
    applies = (
      truthy(call(run, "<", y1, y2))
      or (truthy(call(run, "=", y1, y2)) and truthy(call(run, "<", m1, m2)))
    )
      and (
        (month_matches(run, month, m1) and truthy(call(run, "<=", d1, base_day(m1, y1))))
        or (month_matches(run, month, m2) and truthy(call(run, "<=", base_day(m2, y2), d2)))
      )
  end
  if applies then
    return entry_cons(run, arg(argv, 5))
  end
  return NIL
end

local function diary(name, fn)
  define(name, function(run, argv)
    return fn(run, argv, date_style(run))
  end)
end

diary("diary-date", diary_date)
diary("diary-block", diary_block)
diary("diary-cyclic", diary_cyclic)
diary("diary-anniversary", diary_anniversary)
define("diary-float", diary_float)

-- org-agenda's wrappers bind calendar-date-style to iso and call the
-- diary-lib function, which the prefix profile has only when something
-- else loaded diary-lib.
local function iso_wrapper(name, target, fn)
  define(name, function(run, argv)
    if run.profile ~= "diary" then
      R.refuse("profile", target)
    end
    return fn(run, argv, Q_ISO)
  end)
end

iso_wrapper("org-date", "diary-date", diary_date)
iso_wrapper("org-block", "diary-block", diary_block)
iso_wrapper("org-cyclic", "diary-cyclic", diary_cyclic)
iso_wrapper("org-anniversary", "diary-anniversary", diary_anniversary)

local function has_holiday_name(skip)
  local x = skip
  while is_cons(x) do
    if x.car == Q_HOLIDAYS or (type(x.car) == "table" and x.car.k == "str") then
      return true
    end
    x = x.cdr
  end
  return false
end

-- (calendar-check-holidays date): the consumer's function when given.
-- Without it, the holidays only matter for a `holidays' or string
-- element of SKIP-WEEKS, or for a date the holiday forms may reject or
-- never finish on (Emacs's default holidays loop on years near 10^6).
local function holidays(run, skip, date)
  local fns = run.ctx.functions
  if fns and fns["calendar-check-holidays"] then
    return evaluator().funcall(run, intern("calendar-check-holidays"), { n = 1, date })
  end
  if run.profile ~= "diary" then
    R.refuse("profile", "calendar-check-holidays")
  end
  if
    has_holiday_name(skip)
    or not date_is_valid_p(run, date)
    or truthy(call(run, ">", year_of(date), 9999))
  then
    R.refuse("holidays", "calendar-check-holidays")
  end
  return NIL
end

define("org-class", function(run, argv)
  local skip = NIL
  for i = argv.n, 8, -1 do
    run:charge(32)
    skip = V.cons(argv[i], skip)
  end
  local date1 = absolute_from_gregorian(run, list3(run, argv[2], argv[3], argv[1]))
  local date2 = absolute_from_gregorian(run, list3(run, argv[5], argv[6], argv[4]))
  local d = absolute_from_gregorian(run, dynamic(run, "date"))
  local h = NIL
  if skip ~= NIL then
    h = holidays(run, skip, dynamic(run, "date"))
  end
  if not truthy(call(run, "<=", date1, d)) or not truthy(call(run, "<=", d, date2)) then
    return NIL
  end
  if not truthy(call(run, "=", day_of_week(run, dynamic(run, "date")), argv[7])) then
    return NIL
  end
  if skip ~= NIL then
    local week = car(iso_from_absolute(run, d))
    if truthy(call(run, "member", week, skip)) then
      return NIL
    end
  end
  if h ~= NIL and truthy(call(run, "memq", Q_HOLIDAYS, skip)) then
    return NIL
  end
  local member = B.internal("org-class--holiday", function(r, a)
    return call(r, "member", a[1], skip)
  end)
  if truthy(call(run, "delq", NIL, call(run, "mapcar", member, h))) then
    return NIL
  end
  return dynamic(run, "entry")
end)

-- Org tables

local function lookup(mode)
  define("org-lookup-" .. mode, function(run, argv)
    local val, sl = argv[1], argv[2]
    local p = truthy(arg(argv, 4)) and argv[4] or intern("equal")
    local rl = truthy(arg(argv, 3)) and argv[3] or sl
    local ret, rets, matched = NIL, {}, false
    local funcall = evaluator().funcall
    while truthy(sl) and not (mode == "first" and matched) do
      run:step(1)
      if truthy(funcall(run, p, { n = 2, val, car(sl) })) then
        matched = true
        local rval = car(rl)
        if mode == "all" then
          rets[#rets + 1] = rval
        else
          ret = rval
        end
      end
      sl = cdr(sl)
      rl = cdr(rl)
    end
    if mode == "all" then
      return list.new_list(run, rets, #rets)
    end
    return ret
  end)
end

lookup("first")
lookup("last")
lookup("all")

-- XT-10: a diary sexp that is one call of these with every argument
-- written as a decimal integer (or t where allowed) reads each date
-- triple year-first when its first value is a number above 31, or t
-- while its last is not t and not a number above 31.
local XT10 = {
  ["diary-date"] = { n = 3, triples = { 1 }, t_ok = true },
  ["diary-anniversary"] = { n = 3, triples = { 1 } },
  ["diary-cyclic"] = { n = 4, triples = { 2 } },
  ["diary-block"] = { n = 6, triples = { 1, 4 } },
}

local function decimal_spelling(text, v, rule)
  return text:match("^[+-]?%d+$") ~= nil or (rule.t_ok and v == T and text == "t")
end

--- The form XT-10 evaluates in place of diary-profile `form`, or `form`.
--- `src` is the text `form` was read from at byte 1, whose argument
--- spellings decide; without it only fixnum arguments (and t) qualify,
--- as their printed spelling is decimal.
function M.year_first(run, form, src)
  if not (is_cons(form) and type(form.car) == "table" and form.car.k == "sym") then
    return form
  end
  local name = form.car.name.s
  local rule = XT10[name]
  local ctx = run.ctx
  if
    not rule
    or form.car.uninterned
    or (ctx.functions and ctx.functions[name])
    or (ctx.macros and ctx.macros[name])
  then
    return form
  end
  local args, n, x = {}, 0, form.cdr
  while is_cons(x) do
    local v = x.car
    local fixnum = type(v) == "number"
      or (type(v) == "table" and v.k == "big" and num.emacs_fixnum(v.n))
    if not ((src and num.is_int(v) or fixnum) or (rule.t_ok and v == T)) then
      return form
    end
    n = n + 1
    args[n] = v
    x = x.cdr
  end
  if x ~= NIL or n ~= rule.n then
    return form
  end
  if src then
    local texts = reader.elements(run, src, 1)
    if not texts or #texts ~= n + 1 then
      return form
    end
    for i = 1, n do
      if not decimal_spelling(texts[i + 1], args[i], rule) then
        return form
      end
    end
  end
  local function above31(v)
    return num.is_num(v) and truthy(call(run, ">", v, 31))
  end
  local changed = false
  for _, i in ipairs(rule.triples) do
    local a, b, c = args[i], args[i + 1], args[i + 2]
    local year_last = c == T or above31(c)
    if above31(a) or (a == T and not year_last) then
      args[i], args[i + 1], args[i + 2] = b, c, a
      changed = true
    end
  end
  if not changed then
    return form
  end
  return V.cons(form.car, list.new_list(run, args, n))
end

return M
