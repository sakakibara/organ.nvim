-- Unit tests for lua/organ/calc.lua.
-- Run via: nvim --headless -l tests/calc_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local C = require("organ.calc")

-- ---------------------------------------------------------------------------
-- bignum primitives

do
  local bn = C._bn
  -- round-trip ints
  for _, n in ipairs({ 0, 1, -1, 42, -42, 9999999, 10000000, -1234567890 }) do
    local b = bn.from_int(n)
    assert(bn.to_string(b) == tostring(n), ("from_int " .. n .. " -> " .. bn.to_string(b)))
  end

  -- large string round-trip
  local huge = "123456789012345678901234567890"
  local b = bn.from_string(huge)
  assert(bn.to_string(b) == huge, "huge round-trip: " .. bn.to_string(b))

  -- compare
  assert(bn.cmp(bn.from_int(2), bn.from_int(3)) == -1)
  assert(bn.cmp(bn.from_int(-5), bn.from_int(2)) == -1)
  assert(bn.cmp(bn.from_int(5), bn.from_int(5)) == 0)

  -- add / sub
  assert(bn.to_string(bn.add(bn.from_int(7), bn.from_int(35))) == "42")
  assert(bn.to_string(bn.add(bn.from_int(-7), bn.from_int(35))) == "28")
  assert(bn.to_string(bn.sub(bn.from_int(35), bn.from_int(7))) == "28")
  assert(bn.to_string(bn.sub(bn.from_int(7), bn.from_int(35))) == "-28")

  -- multi-limb add
  local a = bn.from_string("9999999999")
  local b2 = bn.from_string("1")
  assert(bn.to_string(bn.add(a, b2)) == "10000000000")

  -- multiplication
  assert(bn.to_string(bn.mul(bn.from_int(6), bn.from_int(7))) == "42")
  assert(bn.to_string(bn.mul(bn.from_int(-6), bn.from_int(7))) == "-42")
  -- big * big
  local x = bn.from_string("12345678901234567890")
  local y = bn.from_string("98765432109876543210")
  local p = bn.mul(x, y)
  assert(bn.to_string(p) == "1219326311370217952237463801111263526900", "x*y: " .. bn.to_string(p))

  -- divmod
  do
    local q, r = bn.divmod(bn.from_int(42), bn.from_int(5))
    assert(
      bn.to_string(q) == "8" and bn.to_string(r) == "2",
      "42/5 = 8 rem 2; got " .. bn.to_string(q) .. " rem " .. bn.to_string(r)
    )
  end
  do
    local q, r = bn.divmod(bn.from_int(-42), bn.from_int(5))
    assert(
      bn.to_string(q) == "-8" and bn.to_string(r) == "-2",
      "-42/5 = -8 rem -2; got " .. bn.to_string(q) .. " rem " .. bn.to_string(r)
    )
  end
  do
    -- exact
    local q, r = bn.divmod(bn.from_int(100), bn.from_int(4))
    assert(bn.to_string(q) == "25" and bn.is_zero(r))
  end
  do
    -- multi-limb
    local q, r =
      bn.divmod(bn.from_string("123456789012345678901234567890"), bn.from_string("987654321"))
    -- 123456789012345678901234567890 / 987654321
    --   = 124999998860937500047... rem ?
    -- Verify (q * b) + r == a.
    local back = bn.add(bn.mul(q, bn.from_string("987654321")), r)
    assert(
      bn.to_string(back) == "123456789012345678901234567890",
      "divmod identity broken: " .. bn.to_string(back)
    )
  end

  -- gcd
  assert(bn.to_string(bn.gcd(bn.from_int(12), bn.from_int(18))) == "6")
  assert(bn.to_string(bn.gcd(bn.from_int(7), bn.from_int(13))) == "1")
end

-- ---------------------------------------------------------------------------
-- Calc value API

-- from_string
do
  assert(C.to_string(C.from_string("42")) == "42")
  assert(C.to_string(C.from_string("-42")) == "-42")
  assert(C.to_string(C.from_string("0")) == "0")
  assert(C.to_string(C.from_string("1/3")) == "1/3")
  assert(C.to_string(C.from_string("-1/3")) == "-1/3")
  assert(C.to_string(C.from_string("12.5")) == "25/2", "12.5 = 25/2")
  assert(C.to_string(C.from_string(".25")) == "1/4")
  assert(C.is_int(C.from_string("3/3")), "3/3 reduces to integer 1")
  assert(C.to_string(C.from_string("3/3")) == "1")
  assert(C.is_int(C.from_string("0/5")), "0/n is integer 0")
end

-- arithmetic identity laws
do
  local a = C.from_string("1/3")
  local b = C.from_string("2/3")
  assert(C.to_string(C.add(a, b)) == "1", "1/3 + 2/3 = 1")
  assert(C.to_string(C.sub(b, a)) == "1/3", "2/3 - 1/3 = 1/3")
  assert(C.to_string(C.mul(a, b)) == "2/9", "1/3 * 2/3 = 2/9")
  assert(C.to_string(C.div(a, b)) == "1/2", "(1/3)/(2/3) = 1/2")

  -- exact: 1/3 + 1/3 + 1/3 = 1 (no float error)
  local s = C.add(C.add(a, a), a)
  assert(C.to_string(s) == "1", "1/3 * 3 = 1, got " .. C.to_string(s))
end

-- comparison
do
  local a = C.from_string("1/3")
  local b = C.from_string("1/2")
  assert(C.lt(a, b))
  assert(C.le(a, b))
  assert(C.gt(b, a))
  assert(C.ge(b, a))
  assert(not C.eq(a, b))
  assert(C.eq(a, C.from_string("2/6")))
end

-- pow
do
  assert(C.to_string(C.pow(C.from_int(2), 10)) == "1024")
  assert(C.to_string(C.pow(C.from_int(2), 64)) == "18446744073709551616")
  assert(C.to_string(C.pow(C.from_string("1/2"), 3)) == "1/8")
  assert(C.to_string(C.pow(C.from_int(5), 0)) == "1")
  assert(C.to_string(C.pow(C.from_int(2), -2)) == "1/4")
end

-- mod
do
  assert(C.to_string(C.mod(C.from_int(17), C.from_int(5))) == "2")
  assert(C.to_string(C.mod(C.from_int(-17), C.from_int(5))) == "-2")
end

-- abs / neg / sign
do
  assert(C.to_string(C.abs(C.from_int(-5))) == "5")
  assert(C.to_string(C.neg(C.from_int(7))) == "-7")
  assert(C.sign(C.from_int(-3)) == -1)
  assert(C.sign(C.from_int(0)) == 0)
  assert(C.sign(C.from_int(3)) == 1)
end

-- to_number (lossy approx)
do
  assert(C.to_number(C.from_int(42)) == 42)
  assert(math.abs(C.to_number(C.from_string("1/3")) - (1 / 3)) < 1e-15)
  assert(C.to_number(C.from_string("12.5")) == 12.5)
end

-- factorial via repeated mul (sanity check on big integer perf)
do
  local f = C.from_int(1)
  for i = 2, 50 do
    f = C.mul(f, C.from_int(i))
  end
  assert(
    C.to_string(f) == "30414093201713378043612608166064768844377641568960512000000000000",
    "50! = 30414...; got " .. C.to_string(f)
  )
end

-- ---------------------------------------------------------------------------
-- floats and mixed-type arithmetic

do
  local f = C.from_float(1.5)
  assert(C.is_float(f))
  assert(C.to_number(f) == 1.5)
  assert(C.to_string(f) == "1.5")

  -- int + float → float
  local r = C.add(C.from_int(2), C.from_float(0.5))
  assert(C.is_float(r) and C.to_number(r) == 2.5)

  -- rational + float → float
  local r2 = C.add(C.from_string("1/2"), C.from_float(0.5))
  assert(C.is_float(r2) and C.to_number(r2) == 1.0)

  -- comparison across kinds
  assert(C.eq(C.from_int(2), C.from_float(2.0)))
  assert(C.lt(C.from_string("1/3"), C.from_float(0.5)))

  -- from_number autodetects
  assert(C.is_int(C.from_number(42)))
  assert(C.is_float(C.from_number(3.14)))

  -- scientific notation
  assert(C.eq(C.from_string("1.5e3"), C.from_int(1500)))
  assert(C.eq(C.from_string("6.022e23"), C.mul(C.from_string("6022"), C.pow(C.from_int(10), 20))))
end

-- ---------------------------------------------------------------------------
-- math functions

do
  -- sqrt of perfect squares stays exact
  assert(C.eq(C.sqrt(C.from_int(16)), C.from_int(4)))
  assert(C.eq(C.sqrt(C.from_int(0)), C.from_int(0)))
  -- non-square falls to float
  assert(C.is_float(C.sqrt(C.from_int(2))))
  assert(math.abs(C.to_number(C.sqrt(C.from_int(2))) - math.sqrt(2)) < 1e-12)

  assert(math.abs(C.to_number(C.sin(C.from_float(0))) - 0) < 1e-15)
  assert(math.abs(C.to_number(C.cos(C.from_float(0))) - 1) < 1e-15)
  assert(math.abs(C.to_number(C.exp(C.from_int(0))) - 1) < 1e-15)
  assert(math.abs(C.to_number(C.ln(C.from_int(1))) - 0) < 1e-15)

  -- gcd / lcm
  assert(C.eq(C.gcd(C.from_int(12), C.from_int(18)), C.from_int(6)))
  assert(C.eq(C.lcm(C.from_int(4), C.from_int(6)), C.from_int(12)))

  -- factorial
  assert(C.eq(C.factorial(C.from_int(5)), C.from_int(120)))
  assert(C.eq(C.factorial(C.from_int(0)), C.from_int(1)))

  -- binomial
  assert(C.eq(C.binomial(C.from_int(5), C.from_int(2)), C.from_int(10)))
  assert(C.eq(C.binomial(C.from_int(10), C.from_int(0)), C.from_int(1)))

  -- ceil / floor / round / trunc
  assert(C.eq(C.ceil(C.from_string("3/2")), C.from_int(2)))
  assert(C.eq(C.ceil(C.from_string("-3/2")), C.from_int(-1)))
  assert(C.eq(C.floor(C.from_string("3/2")), C.from_int(1)))
  assert(C.eq(C.floor(C.from_string("-3/2")), C.from_int(-2)))
  assert(C.eq(C.trunc(C.from_string("3/2")), C.from_int(1)))
  assert(C.eq(C.trunc(C.from_string("-3/2")), C.from_int(-1)))
end

-- ---------------------------------------------------------------------------
-- logical and conditional

do
  assert(C.is_true(C.from_int(1)))
  assert(not C.is_true(C.from_int(0)))
  assert(C.eq(C.lnot(C.from_int(0)), C.from_int(1)))
  assert(C.eq(C.lnot(C.from_int(5)), C.from_int(0)))
  assert(C.eq(C.land(C.from_int(1), C.from_int(2)), C.from_int(1)))
  assert(C.eq(C.land(C.from_int(0), C.from_int(2)), C.from_int(0)))
  assert(C.eq(C.lor(C.from_int(0), C.from_int(0)), C.from_int(0)))
  assert(C.eq(C.lor(C.from_int(0), C.from_int(5)), C.from_int(1)))

  -- ifte returns the other Lua value as-is
  assert(C.ifte(C.from_int(1), "yes", "no") == "yes")
  assert(C.ifte(C.from_int(0), "yes", "no") == "no")
end

-- ---------------------------------------------------------------------------
-- aggregations

do
  local vs = { C.from_int(1), C.from_int(2), C.from_int(3), C.from_int(4) }
  assert(C.eq(C.vsum(vs), C.from_int(10)))
  assert(C.eq(C.vmean(vs), C.from_string("5/2")))
  assert(C.eq(C.vmax(vs), C.from_int(4)))
  assert(C.eq(C.vmin(vs), C.from_int(1)))
  assert(C.eq(C.vlen(vs), C.from_int(4)))
  assert(C.eq(C.vproduct(vs), C.from_int(24)))
  assert(C.eq(C.vmedian(vs), C.from_string("5/2")))

  -- median of odd-length list
  local odd = { C.from_int(7), C.from_int(1), C.from_int(3), C.from_int(5), C.from_int(2) }
  assert(C.eq(C.vmedian(odd), C.from_int(3)))

  -- variance / stddev
  -- vs = [1,2,3,4]; mean = 2.5; ss = (1.5^2 + 0.5^2 + 0.5^2 + 1.5^2) = 5; sample var = 5/3
  assert(C.eq(C.vvar(vs), C.from_string("5/3")))

  -- vmaxabs
  local mixed = { C.from_int(-5), C.from_int(3), C.from_int(-1) }
  assert(C.eq(C.vmaxabs(mixed), C.from_int(5)))
end

-- ---------------------------------------------------------------------------
-- units

do
  local one_km = C.with_unit(C.from_int(1), "km")
  local five_h = C.with_unit(C.from_int(500), "m")
  local total = C.add(one_km, five_h)
  -- Output unit is the left operand's: 1 km + 500 m = 1.5 km
  assert(C.is_unit(total))
  assert(total.name == "km")
  assert(C.to_number(total) == 1.5)

  -- Multiplication scales dimensions
  local area = C.mul(one_km, one_km)
  assert(C.is_unit(area), "km * km has dimension")
  -- m^2 dim: m=2
  assert(area.dim.m == 2)

  -- Division strips equal units → plain numeric
  local ratio = C.div(one_km, C.with_unit(C.from_int(500), "m"))
  -- 1 km / 500 m = 1000/500 = 2 (dimensionless)
  assert(not C.is_unit(ratio))
  assert(C.eq(ratio, C.from_int(2)))

  -- Dimension mismatch errors loudly
  local kg = C.with_unit(C.from_int(1), "kg")
  local ok = pcall(C.add, one_km, kg)
  assert(not ok, "km + kg should error")

  -- Convert
  local conv = C.convert(one_km, "m")
  assert(conv.name == "m" and C.to_number(conv) == 1000)

  -- Time prefixes / aliases
  local hour = C.with_unit(C.from_int(1), "hr")
  local sec = C.convert(hour, "s")
  assert(C.to_number(sec) == 3600)
end

-- ---------------------------------------------------------------------------
-- symbolic simplification

do
  local x = C.sym("x")
  -- x + 0 = x
  assert(C.simplify_binop("+", x, C.from_int(0)) == x)
  -- 0 * x = 0
  assert(C.eq(C.simplify_binop("*", C.from_int(0), x), C.from_int(0)))
  -- 1 * x = x
  assert(C.simplify_binop("*", C.from_int(1), x) == x)
  -- x - x = 0
  assert(C.eq(C.simplify_binop("-", x, x), C.from_int(0)))
  -- x / x = 1
  assert(C.eq(C.simplify_binop("/", x, x), C.from_int(1)))
  -- nil when no rule applies
  assert(C.simplify_binop("+", x, x) == nil)
end

-- ---------------------------------------------------------------------------
-- financial functions

do
  -- Standard mortgage: 30 yrs * 12 mo, 6%/yr → 0.5%/mo, $200k loan.
  -- Excel PMT(0.005, 360, 200000) ≈ -1199.10
  local pmt = C.to_number(C.pmt(C.from_float(0.005), C.from_int(360), C.from_int(200000)))
  assert(math.abs(pmt - -1199.10) < 0.01, "PMT mortgage: " .. pmt)

  -- FV of $100/mo for 10 yrs at 5%/yr:
  -- FV(0.05/12, 120, -100, 0) ≈ 15528.23
  local fv = C.to_number(C.fv(C.from_float(0.05 / 12), C.from_int(120), C.from_int(-100)))
  assert(math.abs(fv - 15528.23) < 0.5, "FV: " .. fv)

  -- PV inverse of FV:
  local pv = C.to_number(C.pv(C.from_float(0.05 / 12), C.from_int(120), C.from_int(-100)))
  assert(math.abs(pv - 9428.14) < 0.5, "PV: " .. pv)

  -- NPV of {-100, 30, 40, 50} at 10%:
  -- t=1: -100 / 1.1, t=2: 30 / 1.21, t=3: 40 / 1.331, t=4: 50 / 1.4641
  -- ≈ -90.91 + 24.79 + 30.05 + 34.15 ≈ -1.92
  local npv = C.to_number(
    C.npv(C.from_float(0.1), { C.from_int(-100), C.from_int(30), C.from_int(40), C.from_int(50) })
  )
  assert(math.abs(npv - -1.92) < 0.1, "NPV: " .. npv)

  -- IRR: solve -100 + 30/(1+r) + 40/(1+r)^2 + 50/(1+r)^3 = 0  →  r ≈ 0.0890
  local irr = C.to_number(C.irr({
    C.from_int(-100),
    C.from_int(30),
    C.from_int(40),
    C.from_int(50),
  }))
  assert(math.abs(irr - 0.0890) < 0.01, "IRR: " .. irr)

  -- Zero rate edge case
  local pmt0 = C.to_number(C.pmt(C.from_int(0), C.from_int(12), C.from_int(1200)))
  assert(pmt0 == -100, "PMT zero rate: " .. pmt0)
end

-- ---------------------------------------------------------------------------
-- primality + factoring

do
  -- small primes
  for _, n in ipairs({ 2, 3, 5, 7, 11, 13, 97, 101, 1009 }) do
    assert(C.is_prime(C.from_int(n)), n .. " is prime")
  end
  -- composites
  for _, n in ipairs({ 4, 6, 8, 9, 100, 1000 }) do
    assert(not C.is_prime(C.from_int(n)), n .. " is composite")
  end
  -- Mersenne prime 2^31 - 1
  assert(C.is_prime(C.sub(C.pow(C.from_int(2), 31), C.from_int(1))), "2^31 - 1 is prime")
  -- 2^32 + 1 = 4294967297 = 641 * 6700417 (composite — Euler 1732)
  assert(not C.is_prime(C.add(C.pow(C.from_int(2), 32), C.from_int(1))), "2^32 + 1 is composite")

  -- factor
  do
    local fs = C.prime_factors(C.from_int(12))
    assert(
      #fs == 3
        and C.eq(fs[1], C.from_int(2))
        and C.eq(fs[2], C.from_int(2))
        and C.eq(fs[3], C.from_int(3)),
      "factor(12) = {2,2,3}"
    )
  end
  do
    local fs = C.prime_factors(C.from_int(360))
    -- 360 = 2^3 * 3^2 * 5
    local s = ""
    for _, f in ipairs(fs) do
      s = s .. C.to_string(f) .. ","
    end
    assert(s == "2,2,2,3,3,5,", "factor(360): " .. s)
  end
  do
    -- 4294967297 = 641 * 6700417
    local fs = C.prime_factors(C.add(C.pow(C.from_int(2), 32), C.from_int(1)))
    assert(#fs == 2)
    assert(C.eq(fs[1], C.from_int(641)) and C.eq(fs[2], C.from_int(6700417)), "F5 factors")
  end
  -- 1 has no prime factors
  assert(#C.prime_factors(C.from_int(1)) == 0)
end

-- ---------------------------------------------------------------------------
-- matrix algebra

do
  local A = C.matrix({
    { 1, 2, 3 },
    { 4, 5, 6 },
    { 7, 8, 10 },
  })
  -- det(A) = -3 (well-known small integer matrix)
  local d = C.det(A)
  assert(C.eq(d, C.from_int(-3)), "det: " .. C.to_string(d))

  -- A^-1 * A = I
  local A_inv = C.inv(A)
  local prod = C.mat_mul(A_inv, A)
  for i = 1, 3 do
    for j = 1, 3 do
      local expected = (i == j) and 1 or 0
      local actual = C.to_number(prod.d[i][j])
      assert(
        math.abs(actual - expected) < 1e-10,
        ("(A^-1*A)[%d][%d] = %s, expected %d"):format(i, j, actual, expected)
      )
    end
  end

  -- transpose
  local T = C.transpose(A)
  assert(T.rows == 3 and T.cols == 3)
  assert(C.eq(T.d[1][2], C.from_int(4))) -- A[2][1] → T[1][2]
  assert(C.eq(T.d[3][1], C.from_int(3))) -- A[1][3] → T[3][1]

  -- mat_add / mat_sub / mat_mul
  local I = C.matrix({ { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } })
  local AmI = C.mat_sub(A, I) -- A - I
  assert(C.eq(AmI.d[1][1], C.from_int(0)))
  assert(C.eq(AmI.d[3][3], C.from_int(9)))

  -- non-square mat_mul shape
  local B = C.matrix({ { 1, 2 }, { 3, 4 }, { 5, 6 } }) -- 3x2
  local AB = C.mat_mul(A, B) -- 3x3 * 3x2 → 3x2
  assert(AB.rows == 3 and AB.cols == 2)
  -- (1*1 + 2*3 + 3*5, 1*2 + 2*4 + 3*6) = (22, 28)
  assert(C.eq(AB.d[1][1], C.from_int(22)))
  assert(C.eq(AB.d[1][2], C.from_int(28)))

  -- singular matrix
  local S = C.matrix({ { 1, 2 }, { 2, 4 } })
  assert(C.eq(C.det(S), C.from_int(0)))
  local ok = pcall(C.inv, S)
  assert(not ok, "inv of singular fails")

  -- exact rational matrix arithmetic
  local R = C.matrix({
    { C.from_string("1/2"), C.from_string("1/3") },
    { C.from_string("1/4"), C.from_string("1/5") },
  })
  local detR = C.det(R)
  -- det = 1/2 * 1/5 - 1/3 * 1/4 = 1/10 - 1/12 = 6/60 - 5/60 = 1/60
  assert(C.eq(detR, C.from_string("1/60")), "rational det: " .. C.to_string(detR))
end

-- ---------------------------------------------------------------------------
-- eigenvalues (power iteration; reliable for symmetric matrices)

do
  -- Symmetric 2x2: A = [[2, 1], [1, 2]]; eigenvalues are 3 and 1.
  local A = C.matrix({ { 2, 1 }, { 1, 2 } })
  local eigs = C.eigenvalues(A)
  local vals = {}
  for _, e in ipairs(eigs) do
    vals[#vals + 1] = C.to_number(e)
  end
  table.sort(vals)
  assert(math.abs(vals[1] - 1) < 1e-6, "smallest eig: " .. vals[1])
  assert(math.abs(vals[2] - 3) < 1e-6, "largest eig: " .. vals[2])

  -- Diagonal matrix: eigenvalues are the diagonal entries.
  local D = C.matrix({ { 5, 0, 0 }, { 0, 3, 0 }, { 0, 0, 7 } })
  local eigs2 = C.eigenvalues(D)
  local vals2 = {}
  for _, e in ipairs(eigs2) do
    vals2[#vals2 + 1] = C.to_number(e)
  end
  table.sort(vals2)
  assert(math.abs(vals2[1] - 3) < 1e-6, "diag eig 3: " .. vals2[1])
  assert(math.abs(vals2[2] - 5) < 1e-6, "diag eig 5: " .. vals2[2])
  assert(math.abs(vals2[3] - 7) < 1e-6, "diag eig 7: " .. vals2[3])
end

-- ---------------------------------------------------------------------------
-- symbolic differentiation

do
  local F = require("organ.table.formula")

  -- Simple var: parse "x" → {kind="const", name="x"}; d(x)/dx = 1.
  local x_ast = F.parse("$1 = x")[1].expr
  local one = C.deriv(x_ast, "x")
  assert(one.kind == "num" and one.value == 1, "d(x)/dx = 1")

  -- d(y)/dx = 0
  local y_ast = F.parse("$1 = y")[1].expr
  local zero = C.deriv(y_ast, "x")
  assert(zero.kind == "num" and zero.value == 0, "d(y)/dx = 0")

  -- d(x^2)/dx = 2x; after simplification.
  local sq = F.parse("$1 = x^2")[1].expr
  local d_sq = C.deriv_simplify(sq, "x")
  -- 2 * x^1 * 1, simplified to 2 * x
  -- Evaluate at x=3: 2*3 = 6
  local ctx = { rows = {}, current_row = 1, current_col = 1 }
  -- We need to substitute x; cheat by adding x as a const = 3.
  -- The evaluator's const lookup only knows pi/e, so we'll evaluate
  -- via direct AST evaluation without symbol lookup.
  -- Instead, verify the AST shape is correct: 2 * x.
  -- After deriv_simplify, the tree is: binop(*, num(2), const(x))
  --   or some equivalent shape. Check that calling deriv on x is 1
  --   and that 2 appears in the tree.
  local function find_num(n, target)
    if n.kind == "num" and n.value == target then
      return true
    end
    if n.left and find_num(n.left, target) then
      return true
    end
    if n.right and find_num(n.right, target) then
      return true
    end
    if n.arg and find_num(n.arg, target) then
      return true
    end
    if n.args then
      for _, a in ipairs(n.args) do
        if find_num(a, target) then
          return true
        end
      end
    end
    return false
  end
  assert(find_num(d_sq, 2), "deriv of x^2 contains '2'")

  -- d(sin(x))/dx = cos(x) * 1 = cos(x), simplified.
  local sin_x = F.parse("$1 = sin(x)")[1].expr
  local d_sin = C.deriv_simplify(sin_x, "x")
  assert(d_sin.kind == "call" and d_sin.name == "cos", "deriv of sin(x) is cos(x)")

  -- d(exp(x))/dx = exp(x).
  local exp_x = F.parse("$1 = exp(x)")[1].expr
  local d_exp = C.deriv_simplify(exp_x, "x")
  assert(d_exp.kind == "call" and d_exp.name == "exp", "deriv of exp(x) is exp(x)")

  -- d(ln(x))/dx = 1/x.
  local ln_x = F.parse("$1 = ln(x)")[1].expr
  local d_ln = C.deriv_simplify(ln_x, "x")
  assert(d_ln.kind == "binop" and d_ln.op == "/", "deriv of ln(x) is a division")

  -- Sum rule: d(x + 5)/dx = 1
  local sum = F.parse("$1 = x + 5")[1].expr
  local d_sum = C.deriv_simplify(sum, "x")
  assert(d_sum.kind == "num" and d_sum.value == 1, "deriv of x+5 simplifies to 1")

  -- Product rule: d(x * x)/dx
  --   raw: x * 1 + x * 1 = 2x (after simplification we'd want 2x but
  --   the simplifier doesn't combine like terms; we just verify the
  --   structure is non-empty).
  local prod = F.parse("$1 = x * x")[1].expr
  local d_prod = C.deriv_simplify(prod, "x")
  assert(d_prod ~= nil, "product-rule deriv produces something")
end

-- ---------------------------------------------------------------------------
-- date arithmetic

do
  local d = C.date(2026, 1, 15)
  assert(C.date_to_string(d) == "2026-01-15")
  assert(C.date_year(d) == 2026)
  assert(C.date_month(d) == 1)
  assert(C.date_day(d) == 15)

  -- ISO parse round-trip
  assert(C.date_to_string(C.date_from_string("2000-12-31")) == "2000-12-31")

  -- Add days
  local d2 = C.date_add_days(d, 30)
  assert(C.date_to_string(d2) == "2026-02-14", "+30 days: " .. C.date_to_string(d2))

  -- Add days across year boundary
  local newyear = C.date_add_days(C.date(2026, 12, 25), 10)
  assert(C.date_to_string(newyear) == "2027-01-04")

  -- Subtract days (negative add)
  local back = C.date_add_days(d, -15)
  assert(C.date_to_string(back) == "2025-12-31")

  -- Difference
  local diff = C.date_diff(C.date(2026, 12, 31), C.date(2026, 1, 1))
  assert(C.eq(diff, C.from_int(364)), "days in 2026: " .. C.to_string(diff))

  -- Leap year (2024)
  local leap_diff = C.date_diff(C.date(2025, 1, 1), C.date(2024, 1, 1))
  assert(C.eq(leap_diff, C.from_int(366)), "2024 was leap")

  -- Comparison
  assert(C.date_cmp(C.date(2026, 1, 1), C.date(2026, 1, 2)) == -1)
  assert(C.date_cmp(C.date(2026, 1, 2), C.date(2026, 1, 1)) == 1)
  assert(C.date_cmp(C.date(2026, 1, 1), C.date(2026, 1, 1)) == 0)

  -- Weekday (1970-01-01 was Thursday → weekday=4)
  assert(C.date_weekday(C.date(1970, 1, 1)) == 4, "Thu")
  assert(C.date_weekday(C.date(2000, 1, 1)) == 6, "Sat") -- 2000-01-01 was Saturday

  -- Add months with day clamping
  local end_of_jan = C.date(2026, 1, 31)
  local feb = C.date_add_months(end_of_jan, 1)
  -- Feb 2026 has 28 days → clamp 31 → 28
  assert(C.date_to_string(feb) == "2026-02-28", "Jan 31 + 1mo = Feb 28: " .. C.date_to_string(feb))

  -- Far-future dates
  local far = C.date_add_days(C.date(2026, 1, 1), 365 * 100)
  assert(C.date_year(far) >= 2125, "100 yrs forward: " .. C.date_year(far))
end

-- ---------------------------------------------------------------------------
-- limits

do
  local F = require("organ.table.formula")

  -- Continuous: lim x → 3 of x^2 = 9
  local x_sq = F.parse("$1 = x^2")[1].expr
  local lim = C.limit(x_sq, "x", C.from_int(3))
  assert(
    lim ~= nil and C.eq(lim, C.from_int(9)),
    "lim x→3 x^2 = 9; got " .. (lim and C.to_string(lim) or "nil")
  )

  -- Removable singularity: lim x → 1 of (x^2 - 1)/(x - 1) = 2
  -- L'Hôpital: derivative of x^2-1 is 2x, of x-1 is 1; lim (2x/1) at 1 = 2
  local removable = F.parse("$1 = (x^2 - 1) / (x - 1)")[1].expr
  local lim2 = C.limit(removable, "x", C.from_int(1))
  assert(
    lim2 ~= nil and math.abs(C.to_number(lim2) - 2) < 1e-9,
    "lim x→1 (x^2-1)/(x-1) = 2; got " .. (lim2 and C.to_string(lim2) or "nil")
  )

  -- 0/0 with sin: lim x → 0 of sin(x)/x = 1
  local sinc = F.parse("$1 = sin(x) / x")[1].expr
  local lim3 = C.limit(sinc, "x", C.from_int(0))
  assert(
    lim3 ~= nil and math.abs(C.to_number(lim3) - 1) < 1e-9,
    "lim x→0 sin(x)/x = 1; got " .. (lim3 and C.to_string(lim3) or "nil")
  )
end

-- ---------------------------------------------------------------------------
-- symbolic integration

do
  local F = require("organ.table.formula")

  -- ∫ 5 dx = 5*x; eval at x=2 → 10.
  local five = F.parse("$1 = 5")[1].expr
  local int_five = C.integ_simplify(five, "x")
  local v = F.eval_calc(
    int_five,
    { rows = {}, current_row = 1, current_col = 1, vars = { x = C.from_int(2) } }
  )
  assert(C.eq(v, C.from_int(10)), "∫5dx at x=2 = 10")

  -- ∫ x dx = x^2/2; eval at x=4 → 8.
  local x = F.parse("$1 = x")[1].expr
  local int_x = C.integ_simplify(x, "x")
  v = F.eval_calc(
    int_x,
    { rows = {}, current_row = 1, current_col = 1, vars = { x = C.from_int(4) } }
  )
  assert(C.eq(v, C.from_int(8)), "∫x dx at x=4 = 8; got " .. C.to_string(v))

  -- ∫ x^3 dx = x^4 / 4; eval at x=2 → 16/4 = 4.
  local x3 = F.parse("$1 = x^3")[1].expr
  local int_x3 = C.integ_simplify(x3, "x")
  v = F.eval_calc(
    int_x3,
    { rows = {}, current_row = 1, current_col = 1, vars = { x = C.from_int(2) } }
  )
  assert(C.eq(v, C.from_int(4)), "∫x^3 dx at x=2 = 4; got " .. C.to_string(v))

  -- ∫ sin(x) dx = -cos(x)
  local sin_x = F.parse("$1 = sin(x)")[1].expr
  local int_sin = C.integ_simplify(sin_x, "x")
  -- result is unop(- (call cos x))
  assert(
    int_sin.kind == "unop"
      and int_sin.op == "-"
      and int_sin.arg.kind == "call"
      and int_sin.arg.name == "cos",
    "∫sin(x) dx = -cos(x)"
  )

  -- ∫ exp(x) dx = exp(x)
  local exp_x = F.parse("$1 = exp(x)")[1].expr
  local int_exp = C.integ_simplify(exp_x, "x")
  assert(int_exp.kind == "call" and int_exp.name == "exp", "∫exp(x) dx = exp(x)")

  -- ∫ 1/x dx = ln(x)
  local one_over_x = F.parse("$1 = 1 / x")[1].expr
  local int_inv = C.integ_simplify(one_over_x, "x")
  assert(int_inv.kind == "call" and int_inv.name == "ln", "∫1/x dx = ln(x)")

  -- ∫ (x + 5) dx = x^2/2 + 5*x; eval at x=2 → 2 + 10 = 12
  local sum = F.parse("$1 = x + 5")[1].expr
  local int_sum = C.integ_simplify(sum, "x")
  v = F.eval_calc(
    int_sum,
    { rows = {}, current_row = 1, current_col = 1, vars = { x = C.from_int(2) } }
  )
  assert(C.eq(v, C.from_int(12)), "∫(x+5) dx at x=2 = 12; got " .. C.to_string(v))
end

-- ---------------------------------------------------------------------------
-- polynomial / algebraic manipulation

do
  local F = require("organ.table.formula")

  local function eval_at(ast, x_val)
    local ctx = {
      rows = {},
      current_row = 1,
      current_col = 1,
      vars = { x = C.from_int(x_val), y = C.from_int(7) },
    }
    return F.eval_calc(ast, ctx)
  end

  -- expand((x+1) * (x-1)) — should be equivalent to x^2 - 1.
  -- We don't expect canonical form; verify by evaluating at multiple points.
  local poly = F.parse("$1 = (x + 1) * (x - 1)")[1].expr
  local expanded = C.expand(poly)
  for _, n in ipairs({ 0, 1, 2, 3, -1, 5 }) do
    local before = C.to_number(eval_at(poly, n))
    local after = C.to_number(eval_at(expanded, n))
    assert(
      math.abs(before - after) < 1e-9,
      ("expand at x=%d: before=%s after=%s"):format(n, before, after)
    )
  end

  -- expand((x+1)^3) — verify equivalent to x^3 + 3x^2 + 3x + 1.
  local cube = F.parse("$1 = (x + 1) ^ 3")[1].expr
  local cube_expanded = C.expand(cube)
  for _, n in ipairs({ 0, 1, 2, 3, 5 }) do
    local manual = (n + 1) ^ 3
    local actual = C.to_number(eval_at(cube_expanded, n))
    assert(
      math.abs(manual - actual) < 1e-9,
      ("(x+1)^3 at x=%d: manual=%s actual=%s"):format(n, manual, actual)
    )
  end

  -- factor(x^2 - y^2) → (x - y)*(x + y); verify equivalence at points.
  local diff_sq = F.parse("$1 = x^2 - y^2")[1].expr
  local factored = C.factor(diff_sq)
  -- factored should now be (x-y)*(x+y).
  assert(factored.kind == "binop" and factored.op == "*", "factor(x^2 - y^2) is a product")
  -- Verify equivalence at (x=3, y=2): both are 5.
  for _, pair in ipairs({ { 3, 2 }, { 5, 1 }, { -2, 3 } }) do
    local x_val, y_val = pair[1], pair[2]
    local ctx = {
      rows = {},
      current_row = 1,
      current_col = 1,
      vars = { x = C.from_int(x_val), y = C.from_int(y_val) },
    }
    local before = C.to_number(F.eval_calc(diff_sq, ctx))
    local after = C.to_number(F.eval_calc(factored, ctx))
    assert(math.abs(before - after) < 1e-9, "factor equivalent at " .. x_val .. "," .. y_val)
  end
end

-- ---------------------------------------------------------------------------
-- variable-exponent derivative (logarithmic differentiation)

do
  local F = require("organ.table.formula")
  -- d/dx of x^x; standard result: x^x * (1 + ln(x)).
  -- Just verify it doesn't error and produces non-trivial AST.
  local ast = F.parse("$1 = x ^ x")[1].expr
  local d = C.deriv(ast, "x")
  assert(d ~= nil, "d/dx x^x produces something")
  -- Evaluate at x=2: x^x * (v' ln u + v u'/u) = 4 * (1*ln(2) + 2*1/2)
  --                                          = 4 * (ln 2 + 1) ≈ 6.7726
  local ctx = { rows = {}, current_row = 1, current_col = 1, vars = { x = C.from_int(2) } }
  local v = F.eval_calc(d, ctx)
  local expected = 4 * (math.log(2) + 1)
  assert(
    math.abs(C.to_number(v) - expected) < 1e-9,
    "d/dx x^x at x=2: got " .. C.to_number(v) .. " expected " .. expected
  )
end

io.write("calc ok\n")
os.exit(0)
