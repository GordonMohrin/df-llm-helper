-- BUG-161 (live round 2, i3: 'dfhack-run dfllm status' printed 'load x8,89'; tostring(share) of a float pacing share):
-- util.num.num is the locale-free drop-in for tostring(number) in text. tests/test_bug161_locale.py pins the source rule.
local T = require('testlib')

local function german(fn)
  local old = os.setlocale(nil, 'numeric')
  local ok = os.setlocale('German_Germany.utf8', 'numeric') or os.setlocale('de_DE.UTF-8', 'numeric')
  if not ok then return false end
  local okr, err = pcall(fn)
  os.setlocale(old or 'C', 'numeric')
  if not okr then error(err, 0) end
  return true
end

T.test('BUG-161: num writes integers plain and floats with a point under a comma locale; tostring does not', function()
  local N = require('dfllm.util.num')
  local ran = german(function()
    T.eq(tostring(2.5), '2,5', 'the host shows the live bug')
    T.eq({N.num(3), N.num(3.0), N.num(2.5), N.num(0.125, 2), N.num(-1.5), N.num(8.888, 2), N.num(0.001)},
         {'3', '3', '2.5', '0.13', '-1.5', '8.89', '0'})
    T.eq(N.dec(889 / 100, 2), '8.89', 'the status load line')
  end)
  T.ok(ran, 'German_Germany.utf8 numeric locale available')
  T.eq({N.num('x'), N.num(nil)}, {'x', 'nil'})
end)

T.done()
