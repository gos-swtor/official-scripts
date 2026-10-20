-- Gunnery 1-80 capability catalog. No executor, tick, cooldown, or target ownership.
local Mirror = require("commando.mirror")
local M = { revision = "2026-09-11-gunnery80-r1" }
M.choice_rows = {
    { level = 23, names = { "Proficient Gravitation", "Gravitating Bolt", "Grav Trio" } },
    { level = 27, names = { "Sticky Grenade", "Charged Barrier", "Advanced Recon Droid" } },
    { level = 39, names = { "Customized Round", "Gravitating Compound", "Thermonuclear Plasma" } },
    { level = 43, names = { "Diversion", "Supercharged Celerity", "Overclock" } },
    { level = 51, names = { "Cell Capacitor", "Reflexive Shield", "Tenacious Defense" } },
    { level = 64, names = { "Adrenal Surge", "Combat Shield", "One Man Army" } },
    { level = 68, names = { "Propulsion Round", "Echoing Deterrence", "Cryo Grenade" } },
    { level = 73, names = { "Concussive Force", "Parallactic Combat Stims", "Trauma Stabilizers" } },
}
M.passives = { "Armor-piercing Cell", "Charged Barrel", "Cell Charger", "Curtain of Fire",
    "Blowback", "Target Lock", "Blazing Barrel", "Deadly Cannon", "Advanced Targeting",
    "Honed Lock", "Decoy", "Forced March" }
M.effects = {
    GravityVortex = "effectdef:48DFDC2D8B035FB3", ChargedBarrel = "effectdef:4094612E686B24C8",
    GravPrimer = "effectdef:25C02DF930062E50", CurtainOfFire = "effectdef:5CBEFE1266A504DB",
    TechOverride = "effectdef:14849C9D17C954C2", TechOverrideDouble = "effectdef:AD8760A50CB0EC2C",
    RechargeFree = "effectdef:91971DF4ADA10EE1", VortexBolts = "effectdef:41DBD763301D3125",
}
local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end
M.finite = finite
function M.known(loadout, name)
    return type(loadout) == "table" and loadout.status == "ready" and
        type(loadout.known) == "table" and loadout.known[name] == true
end
function M.progression(loadout, result)
    result = result or {}
    result.talents, result.choiceConflict = {}, false
    for _, row in ipairs(M.choice_rows) do
        local selected, count = nil, 0
        for _, name in ipairs(row.names) do
            local present = M.known(loadout, name)
            result.talents[name] = present
            if present then selected, count = name, count + 1 end
        end
        result["level" .. row.level .. "Choice"] = count == 1 and selected or nil
        if count > 1 then result.choiceConflict = true end
    end
    for _, name in ipairs(M.passives) do result.talents[name] = M.known(loadout, name) end
    result.curtainOfFire = M.known(loadout, "Curtain of Fire")
    result.honedLock = M.known(loadout, "Honed Lock")
    result.blowback = M.known(loadout, "Blowback")
    result.cellCapacitor = M.known(loadout, "Cell Capacitor")
    result.adrenalSurge = M.known(loadout, "Adrenal Surge")
    return result
end
function M.effect(unit, key, loadout)
    key=Mirror.effect_key(loadout,key)
    if key==nil then return nil end
    if not unit or type(unit.effect) ~= "function" then return nil end
    local ok, row = pcall(unit.effect, unit, "", { kind = "buff", definition_key = key })
    if not ok or type(row) ~= "table" or row.status ~= "ready" or row.truncated == true then return nil, row end
    if row.present ~= true then return false, row end
    if row.charge_conflicted == true then return nil, row end
    if row.has_charges == true and (not finite(row.stacks) or row.stacks <= 0) then return nil, row end
    if row.has_timer == true and (not finite(row.remaining) or row.remaining <= 0) then return nil, row end
    return true, row
end
function M.observe(state)
    local p = state.playerUnit
    local cof, cofr = M.effect(p, M.effects.CurtainOfFire, state.loadout)
    local ta = M.effect(p, M.effects.TechOverride, state.loadout)
    local tb = M.effect(p, M.effects.TechOverrideDouble, state.loadout)
    local barrel, br = M.effect(p, M.effects.ChargedBarrel, state.loadout)
    local primer, pr = M.effect(p, M.effects.GravPrimer, state.loadout)
    local free = M.effect(p, M.effects.RechargeFree, state.loadout)
    local vb, vbr = M.effect(p, M.effects.VortexBolts, state.loadout)
    state.player.curtainOfFire = state.progression.curtainOfFire and cof == true
    state.player.curtainOfFireStatus = type(cofr) == "table" and cofr.status or "unavailable"
    state.player.techOverride = ta == true or tb == true
    state.player.observedBarrels = barrel == true and br and br.has_charges == true and finite(br.stacks) and
        br.stacks >= 0 and br.stacks <= 5 and br.stacks % 1 == 0 and br.stacks or nil
    state.player.barrelInstant = state.progression.chargedBarrel and state.player.observedBarrels == 5
    state.player.observedGravPrimer = primer == true
    state.player.gravPrimerPresent = primer == true
    state.player.gravPrimerRemaining = primer == true and pr and pr.has_timer == true and pr.remaining or nil
    state.player.chargedBarrelRemaining = barrel == true and br and br.has_timer == true and br.remaining or nil
    state.player.rechargeFree = free == true
    state.player.vortexBolts = vb == true and vbr and finite(vbr.stacks) and vbr.stacks or nil
    if state.player.observedBarrels ~= nil then
        state.player.chargedBarrelStacks = state.player.observedBarrels
    elseif barrel == false then
        state.player.chargedBarrelStacks = 0
    else
        state.player.chargedBarrelStacks = nil
    end
end
-- Effects that grant cast legality must be fresh; acknowledged casts do not
-- manufacture an instant-cast buff. Damage-only evidence stays in the caller.
local controls = {
    { "auto_self_heal", "bool", "Emergency Self-Heals", true },
    { "bacta_hp", "int", "Bacta HP %", 45, 5, 85, "Bacta Infusion" },
    { "probe_hp", "int", "Instant Probe HP %", 55, 5, 85, "Medical Probe" },
    { "medshot_hp", "int", "Med Shot HP %", 25, 5, 60, "Med Shot" },
    { "heal_floor", "int", "Healing Energy Reserve %", 10, 0, 50 },
    { "auto_tech_heal", "bool", "Tech Override for Healing", true, nil, nil, "Tech Override" },
    { "mobile_tech_override", "bool", "Mobile Tech Override", true, nil, nil, "Tech Override" },
    { "use_electro_net", "bool", "Use Electro Net", false, nil, nil, "Electro Net" },
    { "auto_echoing", "bool", "Emergency Echoing Deterrence", false, nil, nil, "Echoing Deterrence" },
    { "echoing_hp", "int", "Echoing HP %", 35, 5, 80, "Echoing Deterrence" },
    { "adrenal_surge_threshold", "bool", "Adrenal Surge 60% Trigger", true, nil, nil, "Adrenal Surge" },
    { "auto_cryo", "bool", "Emergency Player Stun", false, nil, nil, "Cryo Grenade" },
    { "cryo_hp", "int", "Cryo HP %", 40, 5, 80, "Cryo Grenade" },
    { "auto_interrupt", "bool", "Interrupt Current Target", false, nil, nil, "Disabling Shot" },
    { "strict_barrels", "bool", "Five-Barrel Stationary Payoff", true, nil, nil, "Charged Barrel" },
}
function M.settings(schema)
    for _, c in ipairs(controls) do
        schema.fields[#schema.fields + 1] = {
            key = "gunnery_" .. c[1], type = c[2], label = "Gunnery: " .. c[3], default = c[4],
            min = c[5], max = c[6], requires_ability = c[7], disciplines = { "Gunnery" },
        }
    end
    return schema
end
function M.read_settings(settings)
    local out = {}
    local function get(key)
        if type(settings) ~= "table" then return nil end
        local v = settings["gunnery_" .. key]
        if v == nil and type(settings.fields) == "table" then v = settings.fields["gunnery_" .. key] end
        return v
    end
    for _, c in ipairs(controls) do
        local v = get(c[1])
        if c[2] == "bool" then
            if type(v) ~= "boolean" then v = c[4] end
        elseif not finite(v) then v = c[4]
        else v = math.floor(math.max(c[5], math.min(c[6], v))) end
        out[c[1]] = v
    end
    return out
end
function M.target_cast(state)
    if not gos.events or type(gos.events.casts) ~= "function" then return nil end
    local ok, casts = pcall(gos.events.casts)
    if not ok or type(casts) ~= "table" then return nil end
    for i = 1, math.min(#casts, 256) do
        local row = casts[i]
        if type(row) == "table" and row.unit_handle == state.target.handle then return row end
    end
end
return M
