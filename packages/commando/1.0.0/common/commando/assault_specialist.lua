-- Assault Specialist route for scripts/live/commando.lua.
-- Capability-driven through level 80: loadout.known is authoritative.

local Mirror = require("commando.mirror")
local CurrentLoadout
local M = {}
local EXPECTED_STYLE = "commando"
local EXPECTED_DISCIPLINE = "Assault Specialist"
local OWNER_PREFIX = "assault_specialist:"
local READY_SLACK = 0.04
local DEFAULT_DOT_REFRESH = 1.5
local DEFAULT_PRIORITY_FLOOR = 60.0
local DEFAULT_FILLER_FLOOR = 60.0
local HAR_MIN_REMAINING = 1.55
-- Installed-client Ionic Accelerator: 10s proc buff, 7s internal proc cooldown.
-- Full Auto channels for ~3s, so start it only when that channel can reach the
-- next IA eligibility window instead of spending it blindly on cooldown.
local IONIC_PROC_DURATION = 10.0
local IONIC_INTERNAL_COOLDOWN = 7.0
local FULL_AUTO_IA_SETUP_WINDOW = 3.0
local GUIDE_OPENER_WINDOW = 10.0
local FAILURE_BACKOFF = 0.25
local CONTENTION_BACKOFF = 0.12
local METERS_PER_WORLD_UNIT = 10.0
-- Exact current-client definitions from docs/research/pvp_cleanse_effects_20260907.csv.
-- Incendiary's burn/slow/Assailable all pretty-print to the same parent name.
-- Names, timed filters, or submission acknowledgements cannot identify its DoT.
local EffectKey = {
    Incendiary = "effectdef:288DF8D3BACEF5EF",
    Serrated = "effectdef:F5B95E8D5747CBD9",
    IonicAccelerator = "effectdef:04037875BB6FD1BA",
    HyperAssault = "effectdef:B8B73D76FE55C715",
    ReservePowercell = "effectdef:B6F833FC4DFFF529",
    SuperchargedCell = "effectdef:AD25295E3C68B056",
    BlazingCelerity = "effectdef:85F0A3E5F7B43137",
    RelentlessAssault = "effectdef:4AFB5FCA0B2AD7E3",
    BoostedBolts = "effectdef:F53BE068B5FF3435",
    OneManArmy = "effectdef:484CD6A543F591ED",
    TraumaStabilizers = "effectdef:3D39BFB7265327BE",
    -- Tech Override has two current-client 15s proc effect definitions carrying
    -- tag.abl.trooper.tech_override_effect. Either one is valid instant-cast proof.
    TechOverridePrimary = "effectdef:14849C9D17C954C2",
    TechOverrideSecondary = "effectdef:AD8760A50CB0EC2C",
}
local SUPERCHARGE_EFFECT = "Supercharge"
local HOSTILE_FILTER = { reaction = "hostile" }
local BUFF = { kind = "buff" }

local Ability = {
    IncendiaryRound = { id = "Incendiary Round", fallbackCost = 15 },
    SerratedBolt = { id = "Serrated Bolt", fallbackCost = 15, stationary = true },
    AssaultPlastique = { id = "Assault Plastique", fallbackCost = 15 },
    MagBolt = { id = "Mag Bolt", fallbackCost = 15 },
    HighImpactBolt = { id = "High Impact Bolt", fallbackCost = 15 },
    FullAuto = {
        id = "Full Auto", fallbackCost = 24, channelTotalCost = 24,
        stationary = true, channel = true, exactOpenStart = true,
    },
    MortarVolley = {
        id = "Mortar Volley", fallbackCost = 30,
        stationary = true, channel = true, groundTarget = true,
        exactOpenStart = true,
    },
    HailOfBolts = {
        id = "Hail of Bolts", fallbackCost = 32,
        stationary = true, channel = true, groundTarget = true,
        exactOpenStart = true,
    },
    ChargedBolts = {
        id = "Charged Bolts", fallbackCost = 15,
        stationary = true,
    },
    ExplosiveRound = { id = "Explosive Round", fallbackCost = 20 },
    HammerShot = { id = "Hammer Shot", fallbackCost = 0 },
    PlasmaGrenade = {
        id = "Plasma Grenade", fallbackCost = 20,
        stationary = true,
    },
    StickyGrenade = { id = "Sticky Grenade", fallbackCost = 15 },
    ElectroNet = { id = "Electro Net", fallbackCost = 10 },
    SuperchargedCell = { id = "Supercharged Cell", targetless = true, offGcd = true },
    RechargeCells = { id = "Recharge Cells", targetless = true, offGcd = true },
    Diversion = { id = "Diversion", targetless = true, offGcd = true },
    SuperchargedCelerity = { id = "Supercharged Celerity", targetless = true, offGcd = true },
    ReactiveShield = { id = "Reactive Shield", targetless = true, offGcd = true },
    AdrenalineRush = { id = "Adrenaline Rush", targetless = true, offGcd = true },
    TechOverride = { id = "Tech Override", targetless = true, offGcd = true },
    BactaInfusion = { id = "Bacta Infusion", selfTarget = true, fallbackCost = 10, defensiveHeal = true },
    MedicalProbe = { id = "Medical Probe", selfTarget = true, stationary = true, fallbackCost = 13, defensiveHeal = true },
    MedShot = { id = "Med Shot", selfTarget = true, fallbackCost = 0, defensiveHeal = true },
    EchoingDeterrence = { id = "Echoing Deterrence", targetless = true, offGcd = true },
    PropulsionRound = { id = "Propulsion Round", targetless = true },
    CryoGrenade = { id = "Cryo Grenade", fallbackCost = 5 },
    AdvancedReconDroid = { id = "Advanced Recon Droid", groundTarget = true },
    ConcussionCharge = { id = "Concussion Charge", targetless = true },
    Tenacity = { id = "Tenacity", targetless = true, offGcd = true },
    HoldTheLine = { id = "Hold the Line", targetless = true, offGcd = true },
    DisablingShot = { id = "Disabling Shot" },
    ConcussiveRound = { id = "Concussive Round", stationary = true, fallbackCost = 5 },
    FieldAid = { id = "Field Aid", fallbackCost = 10 },
    RechargeAndReload = { id = "Recharge and Reload", targetless = true },
}

-- Only actions the route may actually submit are polled every tick. Remaining
-- level-80 combat abilities are still modeled below as manual/player-owned so
-- "full coverage" does not turn into dozens of unnecessary Core queries/frame.
local AbilityList = {
    Ability.IncendiaryRound, Ability.SerratedBolt, Ability.AssaultPlastique,
    Ability.MagBolt, Ability.HighImpactBolt, Ability.FullAuto,
    Ability.MortarVolley, Ability.HailOfBolts, Ability.ChargedBolts,
    Ability.ExplosiveRound, Ability.HammerShot, Ability.PlasmaGrenade,
    Ability.StickyGrenade, Ability.ElectroNet,
    Ability.SuperchargedCell, Ability.RechargeCells, Ability.Diversion,
    Ability.SuperchargedCelerity, Ability.ReactiveShield, Ability.AdrenalineRush,
    Ability.TechOverride, Ability.BactaInfusion, Ability.MedicalProbe,
    Ability.MedShot, Ability.EchoingDeterrence,
}

local ManualAbilityList = {
    Ability.PropulsionRound, Ability.CryoGrenade, Ability.AdvancedReconDroid,
    Ability.ConcussionCharge, Ability.Tenacity, Ability.HoldTheLine,
    Ability.DisablingShot, Ability.ConcussiveRound, Ability.FieldAid,
    Ability.RechargeAndReload,
}

local Talent = {
    PreEmptiveStrike = "Pre-emptive Strike",
    HyperCinders = "Hyper Cinders",
    EruptiveFlames = "Eruptive Flames",
    IncendiaryIgnition = "Incendiary Ignition",
    ChargedBarrier = "Charged Barrier",
    AdvancedReconDroid = "Advanced Recon Droid",
    ImpactExplosives = "Impact Explosives",
    SlowBurn = "Slow Burn",
    HeavyShrapnel = "Heavy Shrapnel",
    Overclock = "Overclock",
    CellCapacitor = "Cell Capacitor",
    ReflexiveShield = "Reflexive Shield",
    TenaciousDefense = "Tenacious Defense",
    AdrenalSurge = "Adrenal Surge",
    CombatShield = "Combat Shield",
    OneManArmy = "One Man Army",
    ConcussiveForce = "Concussive Force",
    ParallacticCombatStims = "Parallactic Combat Stims",
    TraumaStabilizers = "Trauma Stabilizers",
    ExplosiveDissemination = "Explosive Dissemination",
    SpecialMunitions = "Special Munitions",
    HyperAssaultRounds = "Hyper Assault Rounds",
    ScorchingBolts = "Scorching Bolts",
    ForcedMarch = "Forced March",
    SwelteringHeat = "Sweltering Heat",
    TargetLock = "Target Lock",
    IonicAccelerator = "Ionic Accelerator",
    RelentlessAssault = "Relentless Assault",
    ExtraRounds = "Extra Rounds",
    BlazingCelerity = "Blazing Celerity",
    AssaultTraining = "Assault Training",
    BoostedBolts = "Boosted Bolts",
}

local function clamp(value, minimum, maximum)
    if type(value) ~= "number" then return minimum end
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function safe_method(unit, name, ...)
    if not unit or type(unit[name]) ~= "function" then return nil end
    local ok, value = pcall(unit[name], unit, ...)
    return ok and value or nil
end

local function emit(options, level, message)
    local logger = type(options) == "table" and options.logLine or nil
    if type(logger) == "function" then logger(level, message) end
end

local function loadout_has(loadout, name)
    return type(loadout) == "table" and type(loadout.known) == "table" and
        loadout.known[name] == true
end

local function selected_choice(loadout, names)
    for _, name in ipairs(names) do
        if loadout_has(loadout, name) then return name end
    end
    return nil
end
local function is_selected(loadout)
    loadout=Mirror.adapt_loadout(loadout)
    return type(loadout) == "table" and loadout.status == "ready" and
        loadout.combat_style == EXPECTED_STYLE and
        loadout.discipline == EXPECTED_DISCIPLINE
end

local function progression(loadout)
    return {
        -- Current 7.9 client data exposes Pre-emptive Strike as an Assault
        -- Specialist baseline passive. loadout.known does not consistently
        -- surface hidden baseline passives, so AP itself is the capability gate.
        preEmptiveStrike = loadout_has(loadout, Talent.PreEmptiveStrike) or
            (is_selected(loadout) and loadout_has(loadout, Ability.AssaultPlastique.id)),
        level23 = selected_choice(loadout, {
            Talent.HyperCinders, Talent.EruptiveFlames, Talent.IncendiaryIgnition,
        }),
        level27 = selected_choice(loadout, {
            Ability.StickyGrenade.id, Talent.ChargedBarrier,
            Ability.AdvancedReconDroid.id, "Suppression Droid",
        }),
        level39 = selected_choice(loadout, {
            Talent.ImpactExplosives, Talent.SlowBurn, Talent.HeavyShrapnel,
        }),
        level43 = selected_choice(loadout, {
            Ability.Diversion.id, Ability.SuperchargedCelerity.id, Talent.Overclock,
        }),
        level51 = selected_choice(loadout, {
            Talent.CellCapacitor, Talent.ReflexiveShield, Talent.TenaciousDefense,
        }),
        level64 = selected_choice(loadout, {
            Talent.OneManArmy, Talent.CombatShield, Talent.AdrenalSurge,
        }),
        level68 = selected_choice(loadout, {
            Ability.EchoingDeterrence.id, Ability.PropulsionRound.id, Ability.CryoGrenade.id,
        }),
        level73 = selected_choice(loadout, {
            Talent.ConcussiveForce, Talent.ParallacticCombatStims, Talent.TraumaStabilizers,
        }),
        explosiveDissemination = loadout_has(loadout, Talent.ExplosiveDissemination),
        specialMunitions = loadout_has(loadout, Talent.SpecialMunitions),
        hyperAssaultRounds = loadout_has(loadout, Talent.HyperAssaultRounds),
        scorchingBolts = loadout_has(loadout, Talent.ScorchingBolts),
        forcedMarch = loadout_has(loadout, Talent.ForcedMarch),
        swelteringHeat = loadout_has(loadout, Talent.SwelteringHeat),
        targetLock = loadout_has(loadout, Talent.TargetLock),
        ionicAccelerator = loadout_has(loadout, Talent.IonicAccelerator),
        relentlessAssault = loadout_has(loadout, Talent.RelentlessAssault),
        extraRounds = loadout_has(loadout, Talent.ExtraRounds),
        blazingCelerity = loadout_has(loadout, Talent.BlazingCelerity),
        assaultTraining = loadout_has(loadout, Talent.AssaultTraining),
        boostedBolts = loadout_has(loadout, Talent.BoostedBolts),
        electroNet = loadout_has(loadout, Ability.ElectroNet.id),
        magBolt = loadout_has(loadout, Ability.MagBolt.id),
        serratedBolt = loadout_has(loadout, Ability.SerratedBolt.id),
    }
end
local function unit_hp(unit)
    local hp = safe_method(unit, "hp")
    if type(hp) ~= "table" then return nil end
    local current = type(hp.current) == "number" and hp.current or nil
    local maximum = type(hp.max) == "number" and hp.max or nil
    local percent = type(hp.percent) == "number" and hp.percent or nil
    if percent == nil and current and maximum and maximum > 0 then
        percent = current / maximum * 100
    end
    return { current = current, max = maximum, percent = percent }
end

local function unit_resource(unit)
    local resource = Mirror.resource(CurrentLoadout,safe_method(unit, "resource"))
    if type(resource) ~= "table" then return nil end
    local current = type(resource.current) == "number" and resource.current or nil
    local maximum = type(resource.max) == "number" and resource.max or nil
    local percent = type(resource.percent) == "number" and resource.percent or nil
    if percent == nil and current and maximum and maximum > 0 then
        percent = current / maximum * 100
    end
    return { current = current, max = maximum, percent = percent, kind = resource.kind }
end

local function unit_position(unit)
    local value = safe_method(unit, "position")
    if type(value) ~= "table" or type(value.x) ~= "number" or
        type(value.y) ~= "number" or type(value.z) ~= "number" then
        return nil
    end
    return value
end

local function position_distance(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) * METERS_PER_WORLD_UNIT
end

local function effect(unit, name, options)
    local value = safe_method(unit, "effect", name, options)
    return type(value) == "table" and value or nil
end

-- Exact identity is a Core query primitive. Rotations consume the singular,
-- aggregated effect contract instead of rescanning raw effect rows themselves.
local function exact_effect(unit, kind, key, own)
    key=Mirror.effect_key(CurrentLoadout,key)
    if key==nil then return nil,nil,"mirror_effect_unavailable",nil end
    -- Combat-log labels and Core display names differ. An empty name leaves
    -- identity matching to the exact definition key instead of adding a name gate.
    local observed = effect(unit, "", {
        kind = kind,
        definition_key = key,
    })
    if type(observed) ~= "table" then
        return nil, nil, "effect_query_unavailable", nil
    end
    if observed.status ~= "ready" then
        return nil, nil, observed.status or "unavailable", observed
    end
    if observed.present ~= true then
        return false, 0, "effect_definition_absent", observed
    end
    if own == true and observed.mine ~= true then
        if observed.has_ownership ~= true then
            return nil, nil, "effect_scope_unavailable", observed
        end
        return false, 0, "effect_definition_foreign", observed
    end
    if observed.has_timer == true and
        (type(observed.remaining) ~= "number" or observed.remaining ~= observed.remaining) then
        return nil, nil, "effect_timing_unavailable", observed
    end
    local remaining = observed.has_timer == true and math.max(0, observed.remaining) or nil
    return true, remaining, "effect_definition", observed
end

local function current_cast()
    local cast = gos.abilities.current_cast()
    if type(cast) ~= "table" then return nil end
    return {
        name = Mirror.canonical(CurrentLoadout,cast.name),
        remaining = cast.has_timing == true and type(cast.remaining) == "number" and
            math.max(0, cast.remaining) or nil,
    }
end
local function ability_snapshot(loadout)
    local result = {}
    for _, ability in ipairs(AbilityList) do
        local known = loadout_has(loadout, ability.id)
        local info = known and Mirror.call(CurrentLoadout,"info",ability.id) or nil
        local cooldown = known and Mirror.call(CurrentLoadout,"cooldown_remaining",ability.id) or nil
        local runtime_cost = type(info) == "table" and info.has_resource_cost == true and
            type(info.resource_cost) == "number" and info.resource_cost or nil
        result[ability.id] = {
            known = known,
            resolved = type(info) == "table" and info.ability_handle ~= nil or false,
            bound = type(info) == "table" and info.on_bar == true or false,
            abilityHandle = type(info) == "table" and info.ability_handle or nil,
            ready = known and Mirror.call(CurrentLoadout,"is_ready",ability.id) == true,
            cooldownKnown = type(cooldown) == "number",
            cooldown = type(cooldown) == "number" and math.max(0, cooldown) or nil,
            cost = runtime_cost or ability.fallbackCost,
            costSource = runtime_cost ~= nil and "runtime" or "fallback",
        }
    end
    return result
end

local function ability_state(state, ability)
    return state.abilities[ability.id] or { known = false }
end

local function valid_target(state)
    if not state.target then return false, "missing_target" end
    if safe_method(state.target, "reaction") ~= "hostile" then
        return false, "target_not_hostile"
    end
    if state.targetHp and type(state.targetHp.current) == "number" and
        state.targetHp.current <= 0 then
        return false, "target_dead"
    end
    return true, "ready"
end

local function scaled_cost(state, ability)
    local snapshot = ability_state(state, ability)
    -- A live Ionic Accelerator or Reserve Powercell is the only zero-cost proof.
    if (ability == Ability.HighImpactBolt or ability == Ability.MagBolt) and
        state.ionicAccelerator == true then
        return 0
    end
    if state.reservePowercell == true and type(ability.fallbackCost) == "number" then
        return 0
    end
    local cost = snapshot.cost
    if type(cost) ~= "number" then return nil end
    -- Full Auto's upfront metadata may be zero; the channel spends 6 cells on
    -- application and each of its three ticks (24 total), not zero in total.
    if ability.channelTotalCost then
        local maximum = state.energy and state.energy.max or nil
        if type(maximum) ~= "number" or maximum <= 0 then return nil end
        return ability.channelTotalCost * maximum / 100
    end

    local maximum = state.energy and state.energy.max or nil
    local scaled = cost
    if snapshot.costSource == "fallback" and
        type(maximum) == "number" and maximum > 0 then
        scaled = cost * maximum / 100
    end

    -- Hyper Assault Rounds makes the next Explosive Round cost 10 fewer cells.
    -- The observed buff is authoritative for this modifier. Clamp against the
    -- verified discounted fallback so both cases are safe:
    --   * Core already publishes the discounted live cost -> no double discount.
    --   * Core still publishes the base cost -> the proc is not falsely blocked.
    if ability == Ability.ExplosiveRound and state.hyperAssault == true and
        type(ability.fallbackCost) == "number" then
        local discounted = math.max(0, ability.fallbackCost - 10)
        if type(maximum) == "number" and maximum > 0 then
            discounted = discounted * maximum / 100
        end
        scaled = math.min(scaled, discounted)
    end

    return scaled
end

local function action_lock_remaining(state)
    local remaining = state.gcd
    if state.currentCast and type(state.currentCast.remaining) == "number" then
        remaining = math.max(type(remaining) == "number" and remaining or 0,
            state.currentCast.remaining)
    end
    return type(remaining) == "number" and math.max(0, remaining) or nil
end
local function cooldown_ready(state, ability)
    local snapshot = ability_state(state, ability)
    if snapshot.known ~= true or snapshot.resolved ~= true or snapshot.bound ~= true then
        return false
    end
    if ability.offGcd then
        return snapshot.ready == true or
            (snapshot.cooldownKnown and snapshot.cooldown <= READY_SLACK)
    end
    local starts_in = action_lock_remaining(state)
    if type(starts_in) ~= "number" then return false end
    if snapshot.cooldownKnown then
        return snapshot.cooldown <= starts_in + READY_SLACK
    end
    return snapshot.ready == true
end

local function cooldown_within(state, ability, seconds)
    local snapshot = ability_state(state, ability)
    if snapshot.known ~= true or snapshot.resolved ~= true or snapshot.bound ~= true then
        return false
    end
    if snapshot.ready == true then return true end
    return snapshot.cooldownKnown == true and type(snapshot.cooldown) == "number" and
        snapshot.cooldown <= math.max(0, seconds or 0) + READY_SLACK
end

local function target_count(world, target, radius)
    if not world or type(world.units) ~= "function" then
        return nil, "world_units_unavailable"
    end
    local center = unit_position(target)
    if not center then return nil, "target_position_unavailable" end

    local ok, units = pcall(world.units, world, HOSTILE_FILTER)
    if not ok or type(units) ~= "table" then
        return nil, "hostile_units_unavailable"
    end

    local count = 0
    local counted = {}
    for _, unit in ipairs(units) do
        local handle = safe_method(unit, "handle")
        local hp = unit_hp(unit)
        local alive = hp == nil or hp.current == nil or hp.current > 0
        local pos = unit_position(unit)
        local distance = position_distance(center, pos)
        if handle ~= nil and not counted[handle] and alive and
            type(distance) == "number" and distance <= radius then
            counted[handle] = true
            count = count + 1
        end
    end

    -- The selected target is authoritative hostile intent. world:units() can
    -- transiently omit it during PvP snapshot churn, so preserve it exactly once.
    local target_handle = safe_method(target, "handle")
    if target_handle ~= nil and not counted[target_handle] then
        count = count + 1
    end
    return math.max(1, count), "target_centered_radius"
end
function M.new(executor)
    assert(type(executor) == "table" and type(executor.submit) == "function" and
        type(executor.status) == "function",
        "commando_assault_specialist.new requires the shared AbilityExecutor")

    local Runtime = {
        dotObservations = {},
        pending = nil,
        failureBackoff = {},
        contentionUntil = 0,
        lastDecision = nil,
        lastDecisionAt = 0,
        lastIdentityWarningAt = nil,
        lastProgression = nil,
        lastState = nil,
        plastiqueFollowupTarget = nil,
        plastiqueFollowupReady = false,
        plastiqueFollowupStage = 0,
        lastIonicProcAt = nil,
        combatEpoch = nil,
        combatStartedAt = nil,
        openerNeedsInitialIa = false,
        selfHealTechOverrideUntil = nil,
        lastAoeDiagnostic = nil,
        lastAoeDiagnosticAt = 0,
    }

    local function owns_pending()
        if not executor:owns_command() then return false end
        local status = executor:status()
        local key = type(status) == "table" and status.idempotency_key or nil
        return type(key) == "string" and key:sub(1, #OWNER_PREFIX) == OWNER_PREFIX
    end

    local function has_local_pending()
        return Runtime.pending ~= nil or Runtime.admission ~= nil
    end

    local function reset_transient(clear_dot)
        Runtime.pending = nil
        Runtime.admission = nil
        Runtime.failureBackoff = {}
        Runtime.contentionUntil = 0
        Runtime.lastDecision = nil
        Runtime.plastiqueFollowupTarget = nil
        Runtime.plastiqueFollowupReady = false
        Runtime.plastiqueFollowupStage = 0
        Runtime.lastIonicProcAt = nil
        Runtime.selfHealTechOverrideUntil = nil
        Runtime.lastAoeDiagnostic = nil
        Runtime.lastAoeDiagnosticAt = 0
        if clear_dot then
            Runtime.dotObservations = {}
        end
    end

    local function sync_combat_opener(options, now)
        local epoch = type(options.combatEpoch) == "number" and options.combatEpoch or nil
        local started_at = type(options.combatStartedAt) == "number" and
            options.combatStartedAt or nil

        if options.inCombat == false then
            Runtime.combatEpoch = epoch
            Runtime.combatStartedAt = nil
            Runtime.openerNeedsInitialIa = false
            return
        end

        if options.inCombat == true and epoch ~= nil and Runtime.combatEpoch ~= epoch then
            Runtime.combatEpoch = epoch
            Runtime.combatStartedAt = started_at
            Runtime.openerNeedsInitialIa = started_at ~= nil and
                now - started_at >= 0 and now - started_at <= GUIDE_OPENER_WINDOW
        elseif options.inCombat == true and started_at ~= nil then
            Runtime.combatStartedAt = started_at
        end

        if Runtime.openerNeedsInitialIa == true and Runtime.combatStartedAt ~= nil and
            now - Runtime.combatStartedAt > GUIDE_OPENER_WINDOW then
            Runtime.openerNeedsInitialIa = false
        end
    end

    local function target_dot(target, handle, now, cast, busy, ability, key)
        local dispatched = Runtime.dotObservations[ability.id]
        if dispatched then
            if cast and cast.name == ability.id and busy == true then
                dispatched.casting = true
                dispatched.after = now
            elseif dispatched.casting and busy == false then
                -- Core's busy flag includes the direct-cast -> terminal handoff.
                -- A missing current_cast alone does not prove completion. Once
                -- idle, require an effect observation AFTER this cast boundary;
                -- snapshots taken during Serrated's cast still say absent.
                dispatched.casting = false
                dispatched.after = now
            end
        end
        local present, remaining, source, observed = exact_effect(
            target, "debuff", key, true)
        -- Neither dispatch nor cast completion proves the DoT landed.
        if dispatched and dispatched.target == handle and
            type(observed) == "table" and observed.status == "ready" then
            if type(observed.age_ms) ~= "number" or
                now - math.max(0, observed.age_ms) / 1000 <= dispatched.after then
                return nil, nil, "awaiting_fresh_effect_snapshot"
            end
        end
        return present, remaining, source
    end

    local function supercharge_stacks(player)
        local observed = effect(player, SUPERCHARGE_EFFECT, BUFF)
        if not observed or observed.status ~= "ready" or observed.present ~= true or
            observed.has_charges ~= true or observed.charge_conflicted == true or
            type(observed.stacks) ~= "number" then
            return nil
        end
        return math.max(0, observed.stacks)
    end

    local function read_state(loadout, options)
        local world = gos.world()
        local player = world and world.player or nil
        local target = world and world.current_target or nil
        local now = gos.time_ms() / 1000
        local p = progression(loadout)
        local handle = target and safe_method(target, "handle") or nil
        if Runtime.plastiqueFollowupReady == true and
            Runtime.plastiqueFollowupTarget ~= handle then
            Runtime.plastiqueFollowupReady = false
            Runtime.plastiqueFollowupTarget = nil
            Runtime.plastiqueFollowupStage = 0
        end
        local cast = current_cast()
        local busy = gos.abilities.is_casting_or_channeling()
        local burning, burning_remaining, burning_source = false, nil, "none"
        local bleeding, bleeding_remaining, bleeding_source = false, nil, "none"
        if target and handle then
            burning, burning_remaining, burning_source = target_dot(
                target, handle, now, cast, busy, Ability.IncendiaryRound, EffectKey.Incendiary)
            if loadout_has(loadout, Ability.SerratedBolt.id) then
                bleeding, bleeding_remaining, bleeding_source = target_dot(
                    target, handle, now, cast, busy, Ability.SerratedBolt, EffectKey.Serrated)
            else
                bleeding_source = "ability_unknown"
            end
        end
        local har, har_remaining, har_source = exact_effect(
            player, "buff", EffectKey.HyperAssault, false)
        local ionic, ionic_remaining, ionic_source = exact_effect(
            player, "buff", EffectKey.IonicAccelerator, false)
        if ionic == true then
            local proc_at = now
            if type(ionic_remaining) == "number" then
                proc_at = now - math.max(0, IONIC_PROC_DURATION -
                    clamp(ionic_remaining, 0, IONIC_PROC_DURATION))
            end
            if Runtime.lastIonicProcAt == nil or proc_at > Runtime.lastIonicProcAt then
                Runtime.lastIonicProcAt = proc_at
            end
            -- The guide opener's only special obligation is to establish the
            -- first Ionic Accelerator cycle. Once observed, the rest of this
            -- combat session uses sustained priority even after key-up/key-down.
            Runtime.openerNeedsInitialIa = false
        end
        local ionic_ready_in = Runtime.lastIonicProcAt and
            math.max(0, Runtime.lastIonicProcAt + IONIC_INTERNAL_COOLDOWN - now) or nil
        local reserve, _, reserve_source = exact_effect(
            player, "buff", EffectKey.ReservePowercell, false)
        local supercharged_cell, supercharged_cell_remaining = exact_effect(
            player, "buff", EffectKey.SuperchargedCell, false)
        local blazing, blazing_remaining, blazing_source = false, nil, "ability_unknown"
        if p.blazingCelerity then
            blazing, blazing_remaining, blazing_source = exact_effect(
                player, "buff", EffectKey.BlazingCelerity, false)
        end
        local relentless, relentless_remaining = false, nil
        if p.relentlessAssault then
            relentless, relentless_remaining = exact_effect(
                player, "buff", EffectKey.RelentlessAssault, false)
        end
        local boosted, boosted_remaining, boosted_source, boosted_observed =
            false, nil, "ability_unknown", nil
        if p.boostedBolts then
            boosted, boosted_remaining, boosted_source, boosted_observed = exact_effect(
                player, "buff", EffectKey.BoostedBolts, false)
        end
        local boosted_stacks = type(boosted_observed) == "table" and
            boosted_observed.has_charges == true and type(boosted_observed.stacks) == "number" and
            math.max(0, boosted_observed.stacks) or nil
        local one_man_army, one_man_army_remaining = false, nil
        if p.level64 == Talent.OneManArmy then
            one_man_army, one_man_army_remaining = exact_effect(
                player, "buff", EffectKey.OneManArmy, false)
        end
        local trauma, trauma_remaining, trauma_source, trauma_observed =
            false, nil, "ability_unknown", nil
        if p.level73 == Talent.TraumaStabilizers then
            trauma, trauma_remaining, trauma_source, trauma_observed = exact_effect(
                player, "buff", EffectKey.TraumaStabilizers, false)
        end
        local trauma_stacks = type(trauma_observed) == "table" and
            trauma_observed.has_charges == true and type(trauma_observed.stacks) == "number" and
            math.max(0, trauma_observed.stacks) or nil

        local tech_override, tech_override_remaining, tech_override_source =
            false, nil, "ability_unknown"
        if loadout_has(loadout, Ability.TechOverride.id) then
            local a, ar, as = exact_effect(player, "buff", EffectKey.TechOverridePrimary, false)
            local b, br, bs = exact_effect(player, "buff", EffectKey.TechOverrideSecondary, false)
            if a == true or b == true then
                tech_override = true
                tech_override_remaining = math.max(
                    type(ar) == "number" and ar or 0,
                    type(br) == "number" and br or 0)
                tech_override_source = "effect_definition"
            elseif a == nil or b == nil then
                tech_override = nil
                tech_override_source = a == nil and as or bs
            else
                tech_override = false
                tech_override_remaining = 0
                tech_override_source = "effect_definition_absent"
            end
        end
        if Runtime.selfHealTechOverrideUntil and now > Runtime.selfHealTechOverrideUntil then
            Runtime.selfHealTechOverrideUntil = nil
        end
        local speed = safe_method(player, "speed")
        local state = {
            now = now, world = world, player = player, target = target,
            targetHandle = handle, targetHp = unit_hp(target),
            energy = unit_resource(player),
            playerHp = unit_hp(player), movementKnown = type(speed) == "number",
            moving = type(speed) == "number" and speed > 0.01 or false,
            busy = busy == true,
            currentCast = cast, gcd = gos.abilities.gcd_remaining(),
            abilities = ability_snapshot(loadout), progression = p,
            burning = burning, burningRemaining = burning_remaining,
            burningSource = burning_source, bleeding = bleeding,
            bleedingRemaining = bleeding_remaining, bleedingSource = bleeding_source,
            hyperAssault = har,
            hyperAssaultRemaining = har_remaining, hyperAssaultSource = har_source,
            ionicAccelerator = ionic, ionicAcceleratorRemaining = ionic_remaining,
            ionicAcceleratorSource = ionic_source, ionicReadyIn = ionic_ready_in,
            reservePowercell = reserve,
            superchargedCell = supercharged_cell,
            superchargedCellRemaining = supercharged_cell_remaining,
            blazingCelerity = blazing, blazingCelerityRemaining = blazing_remaining,
            blazingCeleritySource = blazing_source,
            relentlessAssault = relentless, relentlessAssaultRemaining = relentless_remaining,
            boostedBolts = boosted, boostedBoltsRemaining = boosted_remaining,
            boostedBoltsSource = boosted_source, boostedBoltsStacks = boosted_stacks,
            oneManArmy = one_man_army, oneManArmyRemaining = one_man_army_remaining,
            traumaStabilizers = trauma, traumaStabilizersRemaining = trauma_remaining,
            traumaStabilizersSource = trauma_source, traumaStabilizersStacks = trauma_stacks,
            techOverride = tech_override, techOverrideRemaining = tech_override_remaining,
            techOverrideSource = tech_override_source,
            selfHealTechOverrideReserved = Runtime.selfHealTechOverrideUntil ~= nil,
            superchargeStacks = supercharge_stacks(player),
            aoeTargets = math.max(1, math.floor(options.manualRelevantTargets or 1)),
            targetCountSource = "manual",
            targetCountReason = options.automaticTargetCount == false and
                "automatic_disabled" or "automatic_unavailable",
        }
        -- Target counting is telemetry/state collection, not an AoE-casting side
        -- effect. Keep it live even when Automatic AoE is disabled so PvP can
        -- prove the cluster count independently of the cast toggle.
        if options.automaticTargetCount ~= false and target then
            local count, reason = target_count(world, target,
                clamp(options.aoeClusterRadius or 5.0, 3.0, 8.0))
            if type(count) == "number" then
                state.aoeTargets = count
                state.targetCountSource = "automatic"
            end
            state.targetCountReason = reason or "automatic_unavailable"
        end
        return state
    end

    local function recharge_ready(state, options)
        return options.autoRechargeCells ~= false and
            state.now >= (Runtime.failureBackoff[Ability.RechargeCells.id] or 0) and
            state.now >= Runtime.contentionUntil and
            cooldown_ready(state, Ability.RechargeCells)
    end

    local function resource_allows(state, ability, options, priority_spend)
        local cost = scaled_cost(state, ability)
        if type(cost) ~= "number" or cost ~= cost or cost < 0 then
            return false, "cost_unavailable"
        end
        if cost == 0 then return true, "free" end
        local energy = state.energy
        if not energy or type(energy.current) ~= "number" or
            type(energy.max) ~= "number" or energy.max <= 0 or
            energy.current ~= energy.current or energy.current < 0 or
            energy.current > energy.max then
            return false, "energy_unavailable"
        end
        if energy.current < cost then return false, "insufficient_energy" end
        local current = energy.current / energy.max * 100
        local projected = (energy.current - cost) / energy.max * 100
        local floor
        if ability.defensiveHeal == true then
            floor = clamp(options.selfHealEnergyFloorPercent or 10, 0, 60)
        else
            floor = priority_spend == true and
                clamp(options.priorityFloorPercent or DEFAULT_PRIORITY_FLOOR, 35, 90) or
                clamp(options.fillerFloorPercent or DEFAULT_FILLER_FLOOR, 35, 90)
        end
        if projected >= floor then
            return true, priority_spend == true and "priority_reserve" or "filler_reserve"
        end
        -- The existing controlled rescue budget is valid only with a usable
        -- automatic Recharge Cells. Once below its trigger, recover first.
        -- Never spend against a fabricated four-second recharge credit.
        local recharge_at = clamp(options.rechargeThresholdPercent or 45, 20, 60)
        if current > recharge_at and projected >= 35 and
            recharge_ready(state, options) then
            return true, state.progression.level51 == Talent.CellCapacitor and
                "cell_capacitor_recharge_rescue" or "ready_recharge_rescue"
        end
        return false, priority_spend == true and "priority_energy_reserve" or
            "filler_energy_reserve"
    end

    local function can_cast(state, ability, options, priority_spend)
        -- Cell activation cancels an active cast, including Full Auto.
        -- Being off the GCD does not make it safe to insert into a channel.
        if ability == Ability.SuperchargedCell and
            (state.busy or (state.currentCast and
                type(state.currentCast.remaining) == "number" and
                state.currentCast.remaining > 0)) then
            return false, "cast_or_channel_active"
        end
        if state.now < (Runtime.failureBackoff[ability.id] or 0) then
            return false, "failure_backoff"
        end
        if state.now < Runtime.contentionUntil then return false, "command_contention" end
        if not cooldown_ready(state, ability) then return false, "not_ready" end
        if ability.targetless ~= true and ability.selfTarget ~= true then
            local ok, reason = valid_target(state)
            if not ok then return false, reason end
            -- Range is checked by shared Core cast admission.
        end
        if ability.stationary == true then
            local movement_override =
                (ability == Ability.FullAuto and state.progression.forcedMarch == true) or
                ((ability == Ability.ChargedBolts or ability == Ability.SerratedBolt) and
                    state.blazingCelerity == true) or
                (ability == Ability.MedicalProbe and state.techOverride == true)
            if not movement_override then
                if not state.movementKnown then return false, "movement_unavailable" end
                if state.moving then return false, "moving" end
            end
        end
        if ability.exactOpenStart == true then
            if state.busy or type(state.gcd) ~= "number" or state.gcd > READY_SLACK then
                return false, "exact_open_start_locked"
            end
        end
        -- Assault uses Medical Probe only as a guaranteed instant defensive heal.
        -- Never let the DPS route unexpectedly hard-cast it and sacrifice uptime.
        if ability == Ability.MedicalProbe and state.techOverride ~= true then
            return false, "tech_override_instant_absent"
        end
        if (ability == Ability.HighImpactBolt or ability == Ability.MagBolt) and
            not state.burning then
            return false, "target_not_burning"
        end
        if ability == Ability.ExplosiveRound then
            if options.consumeHyperAssault == false or not state.hyperAssault then
                return false, "hyper_assault_absent"
            end
            if type(state.hyperAssaultRemaining) == "number" and
                state.hyperAssaultRemaining < HAR_MIN_REMAINING then
                return false, "hyper_assault_expiring"
            end
        end
        if ability == Ability.SuperchargedCell or ability == Ability.SuperchargedCelerity then
            if type(state.superchargeStacks) ~= "number" or state.superchargeStacks < 10 then
                return false, "supercharge_unavailable"
            end
        end
        if type(ability.fallbackCost) == "number" then
            local allowed, reason = resource_allows(state, ability, options, priority_spend)
            if not allowed then return false, reason end
        end
        return true, "ready"
    end
    local function can_queue(state, options)
        if state.now < Runtime.contentionUntil then return false, "command_contention" end
        -- This Core's admission is now_only, not the game's action-bar queue.
        -- A 250 ms prequeue here produces GCD rejection / priority churn.
        if state.busy then return false, "cast_or_channel_active" end
        if state.currentCast and type(state.currentCast.remaining) == "number" and
            state.currentCast.remaining > 0 then
            return false, "cast_remaining=" .. string.format("%.3f", state.currentCast.remaining)
        end
        if type(state.gcd) ~= "number" then return false, "gcd_unavailable" end
        return state.gcd <= 0,
            "gcd_remaining=" .. string.format("%.3f", state.gcd)
    end

    local function consider(state, ability, options, reason, priority_spend)
        local ok, block = can_cast(state, ability, options, priority_spend)
        if not ok then return nil, block end
        return { ability = ability, reason = reason, prioritySpend = priority_spend }
    end

    local function consider_exact_open(state, ability, options, reason, priority_spend)
        local selected, block = consider(state, ability, options, reason, priority_spend)
        if selected then return selected end
        if block == "exact_open_start_locked" and cooldown_ready(state, ability) then
            return { ability = ability, reason = "await_exact_open_start", wait = true }
        end
        return nil
    end

    local function select_offgcd(state, options)
        local p = state.progression
        local hp = state.playerHp and state.playerHp.percent or nil

        -- Reserve Tech Override specifically for an emergency instant Medical
        -- Probe. Do not spend it when Bacta Infusion can already cover the GCD.
        if options.autoSelfHeal ~= false and type(hp) == "number" and
            hp <= (options.instantMedicalProbeHpPercent or 55) and
            state.techOverride ~= true and Runtime.selfHealTechOverrideUntil == nil then
            local bacta_available = false
            if hp <= (options.bactaInfusionHpPercent or 45) then
                bacta_available = can_cast(state, Ability.BactaInfusion, options, true) == true
            end
            local probe = ability_state(state, Ability.MedicalProbe)
            local probe_energy_ok = resource_allows(state, Ability.MedicalProbe, options, true) == true
            if not bacta_available and probe.known == true and probe.resolved == true and
                probe.bound == true and cooldown_ready(state, Ability.MedicalProbe) and
                probe_energy_ok then
                local selected = consider(state, Ability.TechOverride, options,
                    "tech_override_instant_self_heal", false)
                if selected then return selected end
            end
        end

        if options.autoAdrenalineRush == true and type(hp) == "number" then
            local ar_threshold = options.adrenalineRushHpPercent or 35
            if p.level64 == Talent.AdrenalSurge then
                ar_threshold = math.max(ar_threshold, 60)
            end
            if hp <= ar_threshold then
                local selected = consider(state, Ability.AdrenalineRush, options,
                    p.level64 == Talent.AdrenalSurge and "adrenal_surge_emergency" or
                        "adrenaline_rush_emergency", false)
                if selected then return selected end
            end
        end
        if p.level68 == Ability.EchoingDeterrence.id and
            options.autoEchoingDeterrence == true and type(hp) == "number" and
            hp <= (options.echoingDeterrenceHpPercent or 35) then
            local selected = consider(state, Ability.EchoingDeterrence, options,
                "echoing_deterrence_emergency", false)
            if selected then return selected end
        end
        if options.autoReactiveShield == true and type(hp) == "number" and
            hp <= (options.reactiveShieldHpPercent or 40) then
            local shield_reason = p.level51 == Talent.ReflexiveShield and
                "reflexive_shield_emergency" or "emergency_reactive_shield"
            local selected = consider(state, Ability.ReactiveShield, options,
                shield_reason, false)
            if selected then return selected end
        end
        if p.level43 == Ability.Diversion.id and options.autoDiversion == true and
            type(hp) == "number" and hp <= (options.diversionHpPercent or 50) then
            local selected = consider(state, Ability.Diversion, options,
                "selected_diversion", false)
            if selected then return selected end
        end
        if p.level43 == Ability.SuperchargedCelerity.id and
            options.autoSuperchargedCelerity == true then
            local selected = consider(state, Ability.SuperchargedCelerity, options,
                "selected_celerity", false)
            if selected then return selected end
        end
        if options.autoSuperchargedCell ~= false and state.burning then
            local selected = consider(state, Ability.SuperchargedCell, options,
                "supercharged_cell_burning", false)
            if selected then return selected end
        end
        if options.autoRechargeCells ~= false and state.energy and
            type(state.energy.percent) == "number" and
            state.energy.percent <= (options.rechargeThresholdPercent or 45) then
            local recharge_reason = p.level51 == Talent.CellCapacitor and
                "cell_capacitor_energy_recovery" or "energy_recovery"
            local selected = consider(state, Ability.RechargeCells, options,
                recharge_reason, false)
            if selected then return selected end
        end
        return nil
    end

    local function select_self_heal(state, options)
        if options.autoSelfHeal == false then
            Runtime.selfHealTechOverrideUntil = nil
            return nil
        end
        local hp = state.playerHp and state.playerHp.percent or nil
        if type(hp) ~= "number" then return nil end

        local bacta_at = clamp(options.bactaInfusionHpPercent or 45, 10, 90)
        local probe_at = clamp(options.instantMedicalProbeHpPercent or 55, 10, 90)
        local medshot_at = clamp(options.medShotHpPercent or 25, 5, 60)

        -- Fastest real heal first. Bacta Infusion is already instant and does
        -- not waste the scarce Tech Override proc.
        if hp <= bacta_at then
            local selected = consider(state, Ability.BactaInfusion, options,
                "defensive_bacta_infusion", true)
            if selected then return selected end
        end

        if hp <= probe_at then
            if state.techOverride == true then
                local selected = consider(state, Ability.MedicalProbe, options,
                    "tech_override_instant_medical_probe", true)
                if selected then return selected end
            elseif Runtime.selfHealTechOverrideUntil ~= nil then
                -- We intentionally stop the DPS APL for a very short snapshot
                -- handoff so a just-fired Tech Override cannot be consumed by
                -- Serrated Bolt/Charged Bolts before Medical Probe sees it.
                return {
                    ability = Ability.MedicalProbe,
                    reason = "await_tech_override_self_heal_effect",
                    wait = true,
                }
            end
        elseif Runtime.selfHealTechOverrideUntil ~= nil then
            -- An external/Bacta heal already lifted us out of the trigger range.
            Runtime.selfHealTechOverrideUntil = nil
        end

        -- Last-resort free self-heal. This is intentionally very low so the DPS
        -- route does not spam weak Med Shot healing instead of applying pressure.
        if hp <= medshot_at then
            local selected = consider(state, Ability.MedShot, options,
                "critical_med_shot_fallback", false)
            if selected then return selected end
        end
        return nil
    end

    local function aoe_block_diagnostic(state, options, ability, block)
        if options.decisionLog ~= true then return end
        local key = tostring(ability.id) .. ":" .. tostring(block)
        if Runtime.lastAoeDiagnostic == key and
            state.now - Runtime.lastAoeDiagnosticAt < 1.0 then
            return
        end
        Runtime.lastAoeDiagnostic = key
        Runtime.lastAoeDiagnosticAt = state.now
        emit(options, "debug", "assault aoe blocked: ability=" .. tostring(ability.id) ..
            " block=" .. tostring(block) ..
            " targets=" .. tostring(state.aoeTargets) ..
            " energy=" .. tostring(state.energy and state.energy.percent or "-") ..
            " moving=" .. tostring(state.moving) ..
            " burning=" .. tostring(state.burning) ..
            " bleeding=" .. tostring(state.bleeding))
    end

    local function select_priority(state, options)
        local p = state.progression
        local hyper_cinders = p.level23 == Talent.HyperCinders
        local aoe_min = clamp(options.aoeMinTargets or 3, 2, 8)
        local aoe = options.aoeEnabled == true and state.aoeTargets >= aoe_min
        -- Current 7.9 guidance only replaces Full Auto / Charged Bolts with
        -- Hail when it can actually hit 3+ targets for the channel. Keep
        -- two-target DoT spreading enabled without downgrading the IA generator.
        local hail_aoe = options.aoeEnabled == true and state.aoeTargets >= math.max(3, aoe_min)
        local target_hp = state.targetHp and state.targetHp.percent or nil
        local target_durable = type(target_hp) ~= "number" or target_hp > 10
        local early_plastique = p.preEmptiveStrike == true and
            p.level39 ~= Talent.ImpactExplosives

        -- Never break the guide's AP burst once it has actually started.
        -- L60+: Assault Plastique -> Mag Bolt -> Charged Bolts -> IA Mag Bolt.
        -- Pre-60: Assault Plastique -> Charged Bolts. Impact Explosives disables
        -- early detonation in the game, so that talent never arms this state.
        if Runtime.plastiqueFollowupReady == true and
            Runtime.plastiqueFollowupTarget == state.targetHandle then
            if p.magBolt and Runtime.plastiqueFollowupStage == 1 then
                local selected = consider(state, Ability.MagBolt, options,
                    "assault_plastique_mag_bolt", true)
                if selected then return selected end
            else
                local reason = p.magBolt and
                    (state.blazingCelerity == true and
                        "blazing_celerity_plastique_charged_bolts_ia" or
                        "plastique_mag_bolt_charged_bolts_ia") or
                    "preemptive_strike_plastique_detonate_ia"
                local selected = consider(state, Ability.ChargedBolts, options,
                    reason, true)
                if selected then return selected end
            end
        end

        -- Hold an observed IA proc for the AP burst only when AP is ready now.
        -- Otherwise cash the free Mag Bolt immediately so the proc is never lost.
        if state.ionicAccelerator == true then
            if p.magBolt and early_plastique and target_durable and
                state.burning == true and (not p.serratedBolt or state.bleeding == true) and
                ability_state(state, Ability.AssaultPlastique).known == true then
                local selected = consider(state, Ability.AssaultPlastique, options,
                    "assault_plastique_ia_burst_setup", true)
                if selected then return selected end
            end
            local payoff = p.magBolt and Ability.MagBolt or Ability.HighImpactBolt
            local reason = p.magBolt and
                "ionic_accelerator_free_mag_bolt" or "ionic_accelerator_free_hib"
            local selected = consider(state, payoff, options, reason, true)
            if selected then return selected end
        end

        -- Maintain the two 15s DoTs. Incendiary first deliberately staggers the
        -- two 15-cell costs instead of paying both at the same action boundary.
        local refresh = clamp(options.incendiaryRefreshSeconds or DEFAULT_DOT_REFRESH, 0, 4)
        if ability_state(state, Ability.IncendiaryRound).known == true and
            (state.burning == false or (state.burning == true and
                type(state.burningRemaining) == "number" and state.burningRemaining <= refresh)) then
            local selected = consider(state, Ability.IncendiaryRound, options,
                state.burning == true and "incendiary_refresh" or "incendiary_apply", true)
            if selected then return selected end
        end
        local serrated_refresh = clamp(options.serratedRefreshSeconds or
            options.incendiaryRefreshSeconds or DEFAULT_DOT_REFRESH, 0, 4)
        if ability_state(state, Ability.SerratedBolt).known == true and
            (state.bleeding == false or (state.bleeding == true and
                type(state.bleedingRemaining) == "number" and
                state.bleedingRemaining <= serrated_refresh)) then
            local selected = consider(state, Ability.SerratedBolt, options,
                state.bleeding == true and "serrated_refresh" or "serrated_apply", true)
            if selected then return selected end
        end

        -- Assault Plastique is a core cooldown, not filler. In the level-60+
        -- opener, however, current 7.9 guidance spends the one unprocced Mag Bolt
        -- and establishes the first IA proc before AP. After that first IA cycle,
        -- use AP on cooldown once the mandatory DoTs are established.
        if ability_state(state, Ability.AssaultPlastique).known == true and target_durable and
            (not p.magBolt or Runtime.openerNeedsInitialIa ~= true) then
            local selected = consider(state, Ability.AssaultPlastique, options,
                p.level39 == Talent.ImpactExplosives and
                    "impact_explosives_assault_plastique" or "assault_plastique", true)
            if selected then return selected end
        end

        -- PvP clusters are short-lived. Once the anchor DoTs are established,
        -- spend the first available filler GCD on Explosive Dissemination rather
        -- than letting opener/IA setup consume the entire cluster window.
        if aoe and p.explosiveDissemination == true and
            (state.burning == true or state.bleeding == true) then
            local spread = state.burning == true and state.bleeding == true and "both" or
                (state.burning == true and "burn" or "bleed")
            local selected, block = consider(state, Ability.PlasmaGrenade, options,
                "explosive_dissemination_" .. spread .. "_spread_" ..
                    tostring(state.aoeTargets), false)
            if selected then return selected end
            aoe_block_diagnostic(state, options, Ability.PlasmaGrenade, block)
        end

        -- True fresh-combat opener only: spend the one unprocced Mag Bolt first.
        -- Releasing/reholding the rotation key does not recreate this state.
        -- In an active AoE cluster, Hail is the preferred IA generator because
        -- it preserves IA timing while actually dealing area damage. Full Auto
        -- remains the normal single-target/default generator.
        if p.magBolt and Runtime.openerNeedsInitialIa == true then
            local selected = consider(state, Ability.MagBolt, options,
                "mag_bolt_unprocced_opener", true)
            if selected then return selected end
            if hail_aoe then
                selected = consider_exact_open(state, Ability.HailOfBolts, options,
                    "initial_ionic_accelerator_hail_aoe_" .. tostring(state.aoeTargets), false)
                if selected then return selected end
            end
            selected = consider_exact_open(state, Ability.FullAuto, options,
                "initial_ionic_accelerator_full_auto", false)
            if selected then return selected end
            selected = consider(state, Ability.ChargedBolts, options,
                "initial_ionic_accelerator_charged_bolts", false)
            if selected then return selected end
        end

        -- IA timing is the highest-priority filler concern. Charged Bolts deals
        -- damage at the end of its cast, so start it when IA is within one GCD.
        -- If it cannot be used, Full Auto (or Hail in AoE) can reach a wider 3s
        -- setup window because their first damage tick occurs during the channel.
        if p.ionicAccelerator and state.ionicAccelerator ~= true and
            type(state.ionicReadyIn) == "number" and state.ionicReadyIn <= 1.55 then
            local selected
            if hail_aoe then
                selected = consider_exact_open(state, Ability.HailOfBolts, options,
                    "ionic_accelerator_hail_setup_" .. tostring(state.aoeTargets), false)
                if selected then return selected end
            end
            selected = consider(state, Ability.ChargedBolts, options,
                state.blazingCelerity == true and
                    "blazing_celerity_ionic_accelerator_charged_bolts" or
                    "ionic_accelerator_charged_bolts_setup", false)
            if selected then return selected end
        end
        if p.ionicAccelerator and state.ionicAccelerator ~= true and
            type(state.ionicReadyIn) == "number" and
            state.ionicReadyIn <= FULL_AUTO_IA_SETUP_WINDOW then
            local selected
            if hail_aoe then
                selected = consider_exact_open(state, Ability.HailOfBolts, options,
                    "ionic_accelerator_hail_window_" .. tostring(state.aoeTargets), false)
                if selected then return selected end
            end
            selected = consider_exact_open(state, Ability.FullAuto, options,
                "ionic_accelerator_full_auto_setup", false)
            if selected then return selected end
        end

        -- Unprocced Mag Bolt is mostly an opener / downtime recovery action.
        -- Once learned, HIB is fully superseded for Assault Specialist.
        do
            local payoff = p.magBolt and Ability.MagBolt or Ability.HighImpactBolt
            local reason = p.magBolt and "mag_bolt_unprocced" or
                "high_impact_bolt_after_plastique"
            local selected = consider(state, payoff, options, reason, true)
            if selected then return selected end
        end

        -- Hyper Assault Rounds makes Explosive Round efficient. The existing
        -- impact-time expiry gate prevents firing a projectile after the proc dies.
        if options.consumeHyperAssault ~= false and state.hyperAssault == true then
            local selected = consider(state, Ability.ExplosiveRound, options,
                hyper_cinders and "hyper_cinders_hyper_assault_rounds" or
                    "hyper_assault_rounds", true)
            if selected then return selected end
        end

        -- Electro Net is a long-CD damage GCD. It does not generate Supercharge,
        -- so it sits behind IA / HAR / DoT-spread obligations but ahead of normal
        -- strong fillers. It can be disabled for player-owned PvP timing.
        if options.useElectroNet ~= false and p.electroNet and
            (type(target_hp) ~= "number" or target_hp > 20) then
            local selected = consider(state, Ability.ElectroNet, options,
                state.superchargedCell == true and "electro_net_supercharged" or
                    (p.level64 == Talent.OneManArmy and "electro_net_one_man_army" or
                        "electro_net"), false)
            if selected then return selected end
        end

        -- General channeled AoE is only a gain at 3+ targets. Plasma spreading
        -- can still activate at 2, but do not replace stronger single-target IA
        -- generators with Hail/Mortar merely because one extra enemy is nearby.
        if hail_aoe then
            if recharge_ready(state, options) then
                local selected = consider_exact_open(state, Ability.MortarVolley, options,
                    "aoe_mortar_" .. tostring(state.aoeTargets), false)
                if selected then return selected end
            end
            local selected = consider_exact_open(state, Ability.HailOfBolts, options,
                "aoe_hail_" .. tostring(state.aoeTargets), false)
            if selected then return selected end
        end
        if aoe and options.useStickyGrenade ~= false and
            p.level27 == Ability.StickyGrenade.id then
            local selected = consider(state, Ability.StickyGrenade, options,
                "selected_sticky_grenade_aoe", false)
            if selected then return selected end
        end

        -- Outside IA setup, Full Auto is reserved for movement where Charged
        -- Bolts cannot be cast. Forced March makes the full channel mobile.
        if state.moving then
            local selected = consider_exact_open(state, Ability.FullAuto, options,
                "forced_march_full_auto_filler", false)
            if selected then return selected end
        end

        -- Boosted Bolts deliberately does not change this decision: the 1%-per-
        -- stack bonus is too small to justify holding Charged Bolts. Blazing
        -- Celerity is consumed naturally here if the AP block did not use it.
        do
            local selected = consider(state, Ability.ChargedBolts, options,
                state.boostedBolts == true and
                    "boosted_bolts_charged_bolts_filler" or "charged_bolts_filler", false)
            if selected then return selected end
        end
        return consider(state, Ability.HammerShot, options, "free_filler", false)
    end

    local function decision_log(state, options, kind, detail)
        if options.decisionLog ~= true then return end
        local stable_detail = tostring(detail)
        if kind == "waiting_lock" then stable_detail = stable_detail:match("^[^=]+") end
        local key = tostring(kind) .. "|" .. stable_detail .. "|" ..
            tostring(state.targetHandle or "-")
        if Runtime.lastDecision == key and state.now - Runtime.lastDecisionAt < 1.0 then return end
        Runtime.lastDecision = key
        Runtime.lastDecisionAt = state.now
        emit(options, "debug", "assault decision: " .. tostring(kind) ..
            " detail=" .. tostring(detail) ..
            " energy=" .. tostring(state.energy and state.energy.percent or "-") ..
            " self_hp=" .. tostring(state.playerHp and state.playerHp.percent or "-") ..
            " tech_override=" .. tostring(state.techOverride) ..
            " tech_override_left=" .. tostring(state.techOverrideRemaining) ..
            " self_heal_reserved=" .. tostring(state.selfHealTechOverrideReserved) ..
            " combat=" .. tostring(options.inCombat) ..
            " combat_epoch=" .. tostring(options.combatEpoch) ..
            " opener_ia=" .. tostring(Runtime.openerNeedsInitialIa) ..
            " targets=" .. tostring(state.aoeTargets) ..
            " count_source=" .. tostring(state.targetCountSource) ..
            " count_reason=" .. tostring(state.targetCountReason) ..
            " burning=" .. tostring(state.burning) ..
            " burn_source=" .. tostring(state.burningSource) ..
            " burn_left=" .. tostring(state.burningRemaining) ..
            " bleeding=" .. tostring(state.bleeding) ..
            " bleed_source=" .. tostring(state.bleedingSource) ..
            " bleed_left=" .. tostring(state.bleedingRemaining) ..
            " ia=" .. tostring(state.ionicAccelerator) ..
            " ia_left=" .. tostring(state.ionicAcceleratorRemaining) ..
            " ia_ready_in=" .. tostring(state.ionicReadyIn) ..
            " har=" .. tostring(state.hyperAssault) ..
            " har_left=" .. tostring(state.hyperAssaultRemaining) ..
            " supercharged_cell=" .. tostring(state.superchargedCell) ..
            " blazing=" .. tostring(state.blazingCelerity) ..
            " blazing_left=" .. tostring(state.blazingCelerityRemaining) ..
            " relentless=" .. tostring(state.relentlessAssault) ..
            " boosted=" .. tostring(state.boostedBolts) ..
            " boosted_stacks=" .. tostring(state.boostedBoltsStacks) ..
            " one_man_army=" .. tostring(state.oneManArmy) ..
            " trauma_stacks=" .. tostring(state.traumaStabilizersStacks))
    end

    local function progression_log(state, options)
        if type(options.logLine)~="function" then return end
        local p = state.progression
        local key = table.concat({
            tostring(p.preEmptiveStrike), tostring(p.level23 or "none"), tostring(p.level27 or "none"),
            tostring(p.level39 or "none"), tostring(p.level43 or "none"),
            tostring(p.level51 or "none"), tostring(p.level64 or "none"),
            tostring(p.level68 or "none"), tostring(p.level73 or "none"),
            tostring(p.explosiveDissemination), tostring(p.specialMunitions),
            tostring(p.hyperAssaultRounds), tostring(p.scorchingBolts),
            tostring(p.forcedMarch), tostring(p.targetLock),
            tostring(p.ionicAccelerator), tostring(p.relentlessAssault),
            tostring(p.extraRounds), tostring(p.blazingCelerity),
            tostring(p.assaultTraining), tostring(p.boostedBolts),
            tostring(p.electroNet), tostring(p.magBolt), tostring(p.serratedBolt),
        }, "|")
        if Runtime.lastProgression == key then return end
        Runtime.lastProgression = key
        emit(options, "info", "assault progression: preemptive_strike=" ..
            tostring(p.preEmptiveStrike) .. " level23=" ..
            tostring(p.level23 or "none") .. " level27=" ..
            tostring(p.level27 or "none") .. " level39=" ..
            tostring(p.level39 or "none") .. " level43=" ..
            tostring(p.level43 or "none") .. " level51=" ..
            tostring(p.level51 or "none") .. " level64=" ..
            tostring(p.level64 or "none") .. " level68=" ..
            tostring(p.level68 or "none") .. " level73=" ..
            tostring(p.level73 or "none") ..
            " explosive_dissemination=" .. tostring(p.explosiveDissemination) ..
            " special_munitions=" .. tostring(p.specialMunitions) ..
            " har=" .. tostring(p.hyperAssaultRounds) ..
            " scorching=" .. tostring(p.scorchingBolts) ..
            " forced_march=" .. tostring(p.forcedMarch) ..
            " target_lock=" .. tostring(p.targetLock) ..
            " ionic_accelerator=" .. tostring(p.ionicAccelerator) ..
            " relentless_assault=" .. tostring(p.relentlessAssault) ..
            " extra_rounds=" .. tostring(p.extraRounds) ..
            " blazing_celerity=" .. tostring(p.blazingCelerity) ..
            " assault_training=" .. tostring(p.assaultTraining) ..
            " boosted_bolts=" .. tostring(p.boostedBolts) ..
            " electro_net=" .. tostring(p.electroNet) ..
            " mag_bolt=" .. tostring(p.magBolt) ..
            " serrated_bolt=" .. tostring(p.serratedBolt))
    end

    local function command_started(status)
        return type(status) == "table" and status.core.activation_proven == true
    end

    local function cast_result_detail(result, reason)
        local detail = tostring(reason or "cast_failed")
        local core = type(result) == "table" and result.core or nil
        if type(core) ~= "table" then return detail end
        if type(core.lifecycle_unavailable_mask) == "number" and
            core.lifecycle_unavailable_mask ~= 0 then
            detail = detail .. string.format(" lifecycle_mask=0x%03X",
                core.lifecycle_unavailable_mask)
        end
        if core.lifecycle_capture_lost == true then
            detail = detail .. " lifecycle_capture_lost=true"
        end
        if type(core.client_eff_result) == "number" and core.client_eff_result ~= 0 then
            detail = detail .. " client_eff=" .. tostring(core.client_eff_result)
        end
        if type(core.client_check_unavailable_at) == "number" and
            core.client_check_unavailable_at ~= 0 then
            detail = detail .. string.format(" unavailable_at=0x%X",
                core.client_check_unavailable_at)
        end
        return detail
    end

    local function admission_wait(state, result, reason)
        local core = type(result) == "table" and result.core or nil
        -- Core publishes this response for one worker tick. A contention
        -- delay skips that response and resubmits the same request forever.
        -- The read-only query owns no command: poll it again next tick.
        if reason == "castability_pending" then return true end
        if reason == "gcd" or reason == "cooldown" then
            local remaining_ms = type(core) == "table" and
                (core.ready_in_ms or core.wait_ms) or nil
            local delay = type(remaining_ms) == "number" and remaining_ms / 1000 or
                (type(state.gcd) == "number" and state.gcd or 0.015)
            Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                state.now + clamp(delay, 0.010, 0.200))
            return true
        end
        if reason == "busy" or reason == "executor_command_pending" or
            reason == "ability_command_busy" or reason == "command_busy" or
            reason == "ability_submission_pending" or reason == "explicit_target_sync_pending" or
            reason == "bridge_busy" or reason == "session_suspended" then
            Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                state.now + (reason == "session_suspended" and 0.75 or CONTENTION_BACKOFF))
            return true
        end
        if reason == "ability_command_unavailable" or
            reason == "castability_unavailable" or
            reason == "ability_metadata_unavailable" or
            reason == "no_combat_snapshot" or reason == "core_unavailable" or
            reason == "cast_unavailable" then
            Runtime.contentionUntil = math.max(Runtime.contentionUntil, state.now + 0.100)
            return true
        end
        if reason == "target_view_blocked" or reason == "too_far" or
            reason == "too_close" or reason == "not_facing" or
            reason == "target_dead" or reason == "target_untargetable" or
            reason == "missing_target" or reason == "player_dead" or
            reason == "stunned" or reason == "incapacitated" then
            Runtime.contentionUntil = math.max(Runtime.contentionUntil, state.now + 0.050)
            return true
        end
        return false
    end

    local function apply_started_priority_state(pending)
        if type(pending) ~= "table" or pending.startedApplied == true then return end
        pending.startedApplied = true
        local ability = pending.ability
        if ability == Ability.TechOverride then
            -- Submission already reserved the proc through the effect-snapshot handoff.
            return
        end
        if ability == Ability.MedicalProbe then
            Runtime.selfHealTechOverrideUntil = nil
            -- It is a GCD and therefore intentionally breaks any pending AP burst.
        end
        if ability == Ability.AssaultPlastique then
            if pending.plastiqueCanDetonate == true then
                Runtime.plastiqueFollowupTarget = pending.targetHandle
                Runtime.plastiqueFollowupReady = true
                Runtime.plastiqueFollowupStage = 1
            else
                Runtime.plastiqueFollowupTarget = nil
                Runtime.plastiqueFollowupReady = false
                Runtime.plastiqueFollowupStage = 0
            end
            return
        end
        if Runtime.plastiqueFollowupReady ~= true or
            Runtime.plastiqueFollowupTarget ~= pending.targetHandle or
            not ability or ability.targetless == true then
            return
        end
        if Runtime.plastiqueFollowupStage == 1 and ability == Ability.MagBolt then
            Runtime.plastiqueFollowupStage = 2
            return
        end
        -- Pre-60 AP -> Charged Bolts and level-60 AP -> Mag Bolt -> Charged
        -- Bolts both finish the forced bridge here. The IA proc that follows is
        -- observed independently and cashed by Mag Bolt at the top of priority.
        if ability == Ability.ChargedBolts then
            Runtime.plastiqueFollowupReady = false
            Runtime.plastiqueFollowupTarget = nil
            Runtime.plastiqueFollowupStage = 0
            return
        end
        -- Any other target GCD means the contiguous AP combo was interrupted.
        Runtime.plastiqueFollowupReady = false
        Runtime.plastiqueFollowupTarget = nil
        Runtime.plastiqueFollowupStage = 0
    end

    local function service_pending(state, options)
        local pending = Runtime.pending
        if pending == nil then return owns_pending() end
        local status = executor:status()
        local same = type(status) == "table" and status.idempotency_key == pending.key
        if same and command_started(status) then
            pending.acknowledged = true
            apply_started_priority_state(pending)
        end
        if executor:owns_command() then return true end
        if not same then
            Runtime.pending = nil
            return false
        end
        if status.core.cleanup_pending == true then return true end
        if pending.acknowledged ~= true then
            local reason = tostring(status.reason or status.core.state or "terminal_without_start")
            if status.core.state == "submitted" or reason == "request_submission_completed" then
                if options.decisionLog == true then
                    emit(options, "debug", "assault submitted without activation proof: ability=" ..
                        pending.ability.id)
                end
            elseif not admission_wait(state, status, reason) then
                Runtime.failureBackoff[pending.ability.id] = state.now + FAILURE_BACKOFF
                emit(options, "warn", "assault command terminal without start: ability=" ..
                    pending.ability.id .. " reason=" .. reason)
            end
        end
        Runtime.pending = nil
        return true
    end

    local function request_key(state, ability, phase)
        return table.concat({ "assault_specialist", phase or "regular", ability.id,
            tostring(state.targetHandle or "none") }, ":")
    end

    local function submit(state, selected, options, phase)
        local ability = selected.ability
        local target = nil
        if ability.selfTarget == true then
            target = state.player
        elseif ability.targetless ~= true and ability.groundTarget ~= true then
            target = state.target
        end

        local key = request_key(state, ability, phase)
        local result = executor:submit(Mirror.ability(CurrentLoadout,ability.id), target, { idempotencyKey = key })
        Runtime.admission = nil
        if type(result) == "table" and result.admission_pending == true then
            local raw_loadout = Mirror.raw_loadout(CurrentLoadout)
            Runtime.admission = {
                selected = selected, phase = phase, targetHandle = state.targetHandle,
                requestKey = key, combatStyle = raw_loadout.combat_style,
                discipline = raw_loadout.discipline,
                playerHandle = safe_method(state.player, "handle"),
                actorEpoch = state.world and state.world.actor_epoch,
                abilityHandle = ability_state(state, ability).abilityHandle,
            }
            return true
        end
        if type(result) ~= "table" or result.accepted ~= true then
            local reason = type(result) == "table" and
                tostring(result.reason or result.code or "cast_failed") or "invalid_result"
            local detail = ability.id .. ":" .. cast_result_detail(result, reason)
            if admission_wait(state, result, reason) then
                decision_log(state, options, "waiting_admission", detail)
            else
                Runtime.failureBackoff[ability.id] = state.now + FAILURE_BACKOFF
                emit(options, "warn", "assault cast failed: ability=" .. ability.id ..
                    " reason=" .. detail)
            end
            return false
        end
        Runtime.pending = {
            ability = ability, key = key, targetHandle = state.targetHandle,
            acknowledged = false,
            plastiqueCanDetonate = ability == Ability.AssaultPlastique and
                state.progression.preEmptiveStrike == true and
                state.progression.level39 ~= Talent.ImpactExplosives,
        }
        if ability == Ability.TechOverride then
            -- Reserve the next cast while the exact 15s proc reaches the effect
            -- snapshot. This prevents the DPS APL from accidentally consuming it.
            Runtime.selfHealTechOverrideUntil = state.now + 1.25
        end
        if ability == Ability.IncendiaryRound or ability == Ability.SerratedBolt then
            Runtime.dotObservations[ability.id] = {
                target = state.targetHandle, after = state.now, casting = false,
            }
        end
        emit(options, "info", "assault cast queued: ability=" .. ability.id ..
            " reason=" .. tostring(selected.reason) ..
            " energy=" .. tostring(state.energy and state.energy.percent or "-") ..
            " cost=" .. tostring(scaled_cost(state, ability)) ..
            " burning=" .. tostring(state.burning) ..
            " burn_source=" .. tostring(state.burningSource) ..
            " bleeding=" .. tostring(state.bleeding) ..
            " bleed_source=" .. tostring(state.bleedingSource) ..
            " ia=" .. tostring(state.ionicAccelerator) ..
            " har=" .. tostring(state.hyperAssault))
        return true
    end

    local function service_pending_admission(state, options)
        local pending = Runtime.admission
        if not pending then return false end
        local ability = pending.selected.ability
        local raw_loadout = Mirror.raw_loadout(CurrentLoadout)
        if pending.playerHandle ~= safe_method(state.player, "handle") or
            pending.actorEpoch ~= (state.world and state.world.actor_epoch) or
            type(raw_loadout) ~= "table" or pending.combatStyle ~= raw_loadout.combat_style or
            pending.discipline ~= raw_loadout.discipline or
            pending.targetHandle ~= state.targetHandle or
            pending.requestKey ~= request_key(state, ability, pending.phase) or
            pending.abilityHandle ~= ability_state(state, ability).abilityHandle or
            not can_cast(state, ability, options, pending.selected.prioritySpend) then
            Runtime.admission = nil
            return false
        end
        -- Retry the exact decision before another priority replaces Core's result.
        submit(state, pending.selected, options, pending.phase)
        return true
    end

    local function stop(reason)
        Runtime.lastDecision = nil
        Runtime.lastProgression = nil
        if owns_pending() then
            executor:cancel(reason or "assault_route_inactive")
            return owns_pending()
        end

        reset_transient(true)
        return false
    end

    local function tick(loadout, active, options)
        loadout=Mirror.adapt_loadout(loadout)
        CurrentLoadout=loadout
        options = type(options) == "table" and options or {}
        if not is_selected(loadout) then return false end
        local route_now = gos.time_ms() / 1000
        sync_combat_opener(options, route_now)
        if active ~= true then
            stop("rotation_inactive")
            return true
        end
        local state = read_state(loadout, options)
        progression_log(state, options)
        if service_pending(state, options) then
            decision_log(state, options, "command_pending", "assault")
            return true
        end
        if executor:owns_command() then
            decision_log(state, options, "foreign_pending", "executor")
            return true
        end
        if service_pending_admission(state, options) then return true end
        -- Defensive self-healing is allowed even if the hostile target just died
        -- or was dropped. Off-GCD recovery first, then a self-targeted healing GCD.
        local offgcd = select_offgcd(state, options)
        if offgcd then
            submit(state, offgcd, options, "offgcd")
            return true
        end
        local queueable, queue_reason = can_queue(state, options)
        if queueable then
            local self_heal = select_self_heal(state, options)
            if self_heal then
                if self_heal.wait == true then
                    decision_log(state, options, "waiting_self_heal",
                        self_heal.ability.id .. ":" .. self_heal.reason)
                    return true
                end
                submit(state, self_heal, options, "self_heal")
                return true
            end
        end

        local target_ok, target_reason = valid_target(state)
        if not target_ok then
            decision_log(state, options, "waiting_target", target_reason)
            return true
        end
        if state.burningSource == "effect_identity_unavailable" or
            state.hyperAssaultSource == "effect_identity_unavailable" then
            if Runtime.lastIdentityWarningAt == nil or
                state.now - Runtime.lastIdentityWarningAt >= 5.0 then
                Runtime.lastIdentityWarningAt = state.now
                emit(options, "warn", "assault effect identity unavailable; using exact-name compatibility path")
            end
        end
        if not queueable then
            decision_log(state, options, "waiting_lock", queue_reason)
            return true
        end

        local selected = select_priority(state, options)
        if not selected then
            decision_log(state, options, "no_decision", "no_castable_priority")
            return true
        end
        if selected.wait == true then
            decision_log(state, options, "waiting_exact_start",
                selected.ability.id .. ":" .. selected.reason)
            return true
        end
        submit(state, selected, options, "regular")
        return true
    end

    return {
        is_selected = is_selected,
        owns_pending = owns_pending,
        has_local_pending = has_local_pending,
        stop = stop,
        tick = tick,
    }
end

return M
