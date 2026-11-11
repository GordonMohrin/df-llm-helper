-- BUG-756 (Run 16b i2 Whirledrampart y435: DiagnosePatient 11 unclaimed beside 4 doctors, 10-16 patients): one more doctor per three
-- patients (care.doctors_want, at most DOC_MAX), and a citizen at extreme stress is no candidate (a tantrum can strike the helpless).
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local kmock = require('dfllm.util.k_mock')

local function medic_world(npat, stressed)
  return CW.world{cit = 30, setup = function(W)
    df.unit_labor = {DIAGNOSE = 10, SURGERY = 11, BONE_SETTING = 12}
    df.occupation_type = kmock.enum{'TAVERN_KEEPER', 'DOCTOR', 'DIAGNOSTICIAN', 'SURGEON', 'BONE_DOCTOR'}
    for i = 1, 30 do W.unit(i).status.labors = {[10] = false, [11] = false, [12] = false} end
    for i = 1, 4 do W.unit(i).status.labors = {[10] = true, [11] = true, [12] = true} end     -- four doctors
    for i = 1, npat do W.unit(30 - i + 1).health = {flags = {needs_healthcare = true}} end
    for _, id in ipairs(stressed or {}) do
      W.unit(id).status.current_soul = {personality = {stress = 95000}}
    end
    W.act_result('medic', function(id, on)
      for _, l in ipairs({10, 11, 12}) do W.unit(id).status.labors[l] = on end
      return true, 'enabled'
    end)
  end}
end

T.test('BUG-756: doctors_want: base 4, one more per three patients, at most DOC_MAX', function()
  local Cm = require('dfllm.care')
  T.eq({Cm.doctors_want(4, 0), Cm.doctors_want(4, 10), Cm.doctors_want(4, 13), Cm.doctors_want(4, 16), Cm.doctors_want(4, 60),
        Cm.doctors_want(0, 30)}, {4, 4, 5, 6, 8, 0})
end)

T.test('BUG-756: 15 patients: five doctors, not four (old code: four)', function()
  local W, Cm = medic_world(15)
  W.run(2)
  T.eq(Cm.kpi(W.K).doctors.have, 5)
  T.eq(#W.find_acts('medic'), 1)
end)

T.test('BUG-756: no patients: the base four; a citizen at extreme stress is not made a doctor', function()
  local W, Cm = medic_world(0)
  W.run(2)
  T.eq(#W.find_acts('medic'), 0)
  local W2 = medic_world(0, {5, 6, 7, 8, 9, 10, 11, 12})
  W2.run(2)                                                  -- the scan names the stressed citizens
  for i = 1, 15 do W2.unit(30 - i + 1).health = {flags = {needs_healthcare = true}} end
  CW.day(W2, 2)
  local acts = W2.find_acts('medic')
  T.ok(#acts >= 1, 'a fifth doctor is made')
  for _, a in ipairs(acts) do
    T.ok(a.args[1] > 12, 'doctor ' .. tostring(a.args[1]) .. ' is not one of the stressed citizens')
  end
end)

T.done()
