-- Commando Combat Medic: healing-first with conditional idle DPS through one shared executor.
-- No native calls, own tick registration, command polling, or selected-target changes.
-- Source identities: saved installed-client payloads; see the no-heal repair note.
local Mirror = require("commando.mirror")
local CurrentLoadout
local PressureTracker = require("combat.pressure_tracker")
local PressureFormula = PressureTracker.Formula
local M = { revision = "2026-09-22-combat-medic-cell-handoff-r21+action-procs-r1" }
local OWNER = "combat_medic:"
local MAX_SCAN, MAX_TARGETS = 512, 32
local LIFE_SAVING_HP_PERCENT = 20
-- Native effResult mapping: Core/CombatEventStream.cpp (not a Lua result code).
local NATIVE_CONDITION_FAILED = 7
local Effect = {
    Supercharge = "effectdef:7A432D6CF9248379",
    SupportCell = "effectdef:3C390641629F4D3D",
    EmergencyResponse = "effectdef:1E1237729FDB8C7E",
    FieldTriage = "effectdef:6E6E656AE6111B0A",
    TraumaProbe = "effectdef:665D2BCF57836027",
    TechOverride = "effectdef:14849C9D17C954C2",
    TechOverrideDouble = "effectdef:AD8760A50CB0EC2C",
    FreeCell = "effectdef:91971DF4ADA10EE1",
    ReactiveShield = "effectdef:103891660EBBD7CB",
    AdrenalineFiredUp = "effectdef:D502E612305F58A1",
    AdrenalineMaintaining = "effectdef:61220D98C36B504D",
    EchoingDeterrence = "effectdef:7C066C869F2E70AE",
    -- Installed Running Restoration effect: heal_burst_01/8/1 (hidden passive).
    RunningRestoration = "effectdef:5E0D71565AC0F66F",
    -- Exact 15s proc from the level-73 Parallactic Combat Stims choice.
    ParallacticCombatStims = "effectdef:002298C6BF041F6B",
}
-- Installed SC-4 Treatment Scanner tactical children under
-- abl.itm.tactical.sow.bou_tro.merc_com.body_med.heal_sust_01.
-- Both are exact tactical identities; never key this off the generic display name.
local SC4_EFFECTS = {
    "effectdef:F0EB51F5EE176AB9", -- heal_sust_01/11/0
    "effectdef:A14DDAE20E09C598", -- heal_sust_01/11/1
}
local Ability = {
    ["Hammer Shot"] = { damage = true, intrinsicFree = true },
    ["Charged Bolts"] = { damage = true, cast = true },
    ["High Impact Bolt"] = { damage = true },
    ["Full Auto"] = { damage = true, channel = true, channelCost = 24 },
    ["Electro Net"] = { damage = true },
    ["Bacta Infusion"] = {},
    ["Advanced Medical Probe"] = { cast = true },
    ["Medical Probe"] = { cast = true },
    ["Med Shot"] = { intrinsicFree = true },
    ["Trauma Probe"] = {},
    ["Kolto Bomb"] = { groupRadius = 8 },
    ["Successive Treatment"] = { channel = true, channelCost = 28, groupRadius = 20 },
    ["Supercharged Kolto Cell"] = { targetless = true, offGcd = true },
    ["Recharge Cells"] = { targetless = true, offGcd = true },
    ["Tech Override"] = { targetless = true, offGcd = true },
    ["Reactive Shield"] = { targetless = true, offGcd = true },
    ["Adrenaline Rush"] = { targetless = true, offGcd = true },
    ["Echoing Deterrence"] = { targetless = true, offGcd = true },
}
local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end
local function method(object, key, ...)
    if not object or type(object[key]) ~= "function" then return nil end
    local ok, result = pcall(object[key], object, ...)
    if ok then return result end
end
local function is_selected(loadout)
    loadout=Mirror.adapt_loadout(loadout)
    return type(loadout) == "table" and loadout.status == "ready" and
        loadout.combat_style == "commando" and loadout.discipline == "Combat Medic"
end
local function learned(loadout, name)
    return type(loadout.known) == "table" and loadout.known[name] == true
end
local function effect(unit, key, kind)
    key=Mirror.effect_key(CurrentLoadout,key)
    if key==nil then return nil end
    local row = method(unit, "effect", "", { kind = kind or "buff", definition_key = key })
    if type(row) ~= "table" or row.status ~= "ready" or row.truncated == true or
        row.charge_conflicted == true then return nil, row end
    if row.present ~= true then return false, row end
    if row.has_timer == true and (not finite(row.remaining) or row.remaining <= 0) then return nil, row end
    if row.has_charges == true and (not finite(row.stacks) or row.stacks <= 0 or row.stacks % 1 ~= 0) then
        return nil, row
    end
    return true, row
end
local function sc4_effect(unit)
    local uncertain=false
    for _,key in ipairs(SC4_EFFECTS) do
        local present,row=effect(unit,key,"any")
        if present==true then
            if type(row)=="table" and row.has_ownership==true and row.mine~=true then
                uncertain=true
            else
                return true,key,row
            end
        elseif present==nil then uncertain=true end
    end
    if uncertain then return nil end
    return false
end
-- Recheck queued cast permission using the current snapshot. Only Core may
-- cancel a command; an already dispatched/active cast is never locally aborted.
local function probe_permission(player,name)
    local override=effect(player,Effect.TechOverride)==true or
        effect(player,Effect.TechOverrideDouble)==true
    local is_instant=override or (name=="Advanced Medical Probe" and
        effect(player,Effect.EmergencyResponse)==true)
    if is_instant then return true,true end
    if name=="Advanced Medical Probe" and effect(player,Effect.RunningRestoration,"any")==true then
        return true,false
    end
    local speed=method(player,"speed")
    return finite(speed) and math.abs(speed)<=0.001,false
end
local function adrenaline_context(player,loadout)
    local info=Mirror.call(CurrentLoadout,"info","Adrenaline Rush")
    info=type(info)=="table" and info or {}
    local hp=method(player,"hp")
    local surge=learned(loadout,"Adrenal Surge")
    local threshold=surge and 60 or (loadout.talents_available==true and 35 or nil)
    local low
    if threshold and type(hp)=="table" and finite(hp.current) and finite(hp.max) and hp.max>0 then
        low=hp.current/hp.max*100<=threshold
    end
    local cooling
    if info.has_cooldown_remaining==true and finite(info.cooldown_remaining) then
        cooling=info.cooldown_remaining>0
    end
    local armed=effect(player,Effect.AdrenalineFiredUp)
    local active=effect(player,Effect.AdrenalineMaintaining)
    local known_surge
    if loadout.talents_available==true then known_surge=surge end
    return {ability=info.ability_handle,ready=info.ready,cooling=cooling,low=low,
        surge=known_surge,armed=armed,active=active}
end
local function adrenaline_rearmed(failure,context)
    local before=failure.context
    if type(context.ability)=="string" and type(before.ability)=="string" and
        context.ability~=before.ability then return "ability_changed" end
    if type(before.surge)=="boolean" and type(context.surge)=="boolean" and
        before.surge~=context.surge then return "talent_changed" end
    if before.low==false and context.low==true then return "health_trigger_crossed" end
    for _,key in ipairs({"armed","active"}) do
        if type(before[key])=="boolean" and type(context[key])=="boolean" and
            before[key]~=context[key] then return "effect_state_changed" end
    end
    if context.cooling==true or context.ready==false then failure.saw_unready=true end
    if failure.saw_unready and context.cooling==false and context.ready==true then
        return "observed_ready_transition"
    end
end
local function observed_supercharge(player)
    local present,row=effect(player,Effect.Supercharge)
    if present==false then return 0 end
    if present==true and row.has_charges==true and finite(row.stacks) and row.stacks<=10 then
        return row.stacks
    end
end

local COMBAT_MEDIC_PROC_HEALS = {
    ["Bacta Infusion"] = true,
    ["Advanced Medical Probe"] = true,
    ["Medical Probe"] = true,
    ["Med Shot"] = true,
    ["Kolto Bomb"] = true,
    ["Successive Treatment"] = true,
}

local function action_proc_markers(loadout, player, name)
    if not player or not COMBAT_MEDIC_PROC_HEALS[name] then return nil end
    local markers = {}
    local function add(label, detail)
        markers[#markers + 1] = {label=label, detail=detail}
    end

    if name=="Advanced Medical Probe" then
        if effect(player,Effect.EmergencyResponse)==true then
            add("Emergency Response","instant AMP")
        end
        if effect(player,Effect.TechOverrideDouble)==true then
            add("Tech Override x2","instant cast")
        elseif effect(player,Effect.TechOverride)==true then
            add("Tech Override","instant cast")
        end
        local field,row=effect(player,Effect.FieldTriage)
        if field==true then
            if row and row.has_charges==true and finite(row.stacks) and
                row.stacks>=1 and row.stacks<=3 and row.stacks%1==0 then
                add("Field Triage x"..tostring(math.floor(row.stacks)),
                    "-"..tostring(math.floor(row.stacks)*5).." Energy")
            else
                add("Field Triage","reduced Energy")
            end
        end
        if effect(player,Effect.RunningRestoration,"any")==true then
            add("Running Restoration","+15% heal / mobile")
        end
    elseif name=="Medical Probe" then
        if effect(player,Effect.TechOverrideDouble)==true then
            add("Tech Override x2","instant cast")
        elseif effect(player,Effect.TechOverride)==true then
            add("Tech Override","instant cast")
        end
    end

    if learned(loadout,"Parallactic Combat Stims") and
        effect(player,Effect.ParallacticCombatStims,"any")==true then
        add("Parallactic Combat Stims","+10% heal")
    end
    if effect(player,Effect.SupportCell)==true then
        add("Supercharged Kolto Cell","+5% heal")
    end
    return #markers>0 and markers or nil
end

local function position(unit)
    local p = method(unit, "position")
    if type(p) == "table" and finite(p.x) and finite(p.y) and finite(p.z) then return p end
end
local function distance(a, b)
    if not a or not b then return nil end
    local x,y,z = a.x-b.x,a.y-b.y,a.z-b.z
    return math.sqrt(x*x+y*y+z*z)*10
end
-- Seer style thresholds mapped to Commando actions, not Seer Force mechanics.
-- Custom retains the existing per-ability sliders and resource policy.
local Profiles = {
    Safe = { heal_start=98, focused_hp=94, group_hp=90, channel_hp=90, direct_hp=85 },
    Balanced = { heal_start=95, focused_hp=90, group_hp=85, channel_hp=85, direct_hp=80 },
    Efficient = { heal_start=90, focused_hp=85, group_hp=80, channel_hp=80, direct_hp=75 },
}
local Selects = {
    { key="triage_mode",label="Heal Priority",default=PressureFormula.MODE_PRESSURE,
      options={PressureFormula.MODE_HP,PressureFormula.MODE_PRESSURE},
      tooltip="Current HP preserves the existing target order. Incoming Damage Formula ranks recent pressure, attackers, observed HoT carry, projected HP, and time-to-die." },
    { key="healing_style",label="Healing: Style",default="Balanced",
      options={"Safe","Balanced","Efficient","Custom"},
      tooltip="Seer-style profiles. Safe reacts earlier, Balanced is general-purpose, Efficient saves paid heals for larger injuries. Custom uses the saved threshold sliders. Emergency and energy controls always apply." },
    { key="healing_targets",label="Healing: Targets",default="Players + Companions",
      options={"Players only","Players + Companions","All Friendlies"},
      tooltip="The same target choices as Seer. All Friendlies also includes valid friendly NPCs. This controls direct heals, group counts, Trauma Probe and idle-DPS safety. Self remains included." },
}
local function setting(settings,key)
    if type(settings)~="table" then return nil end
    local value=settings["medic_"..key]
    if value==nil and type(settings.fields)=="table" then value=settings.fields["medic_"..key] end
    return value
end
local function choice(value,choices)
    for _,candidate in ipairs(choices) do if value==candidate then return value end end
end
local function healable_type(kind,cfg)
    if kind=="player" then return true end
    if kind=="companion" then return cfg.healing_targets~="Players only" end
    if kind=="npc" then return cfg.healing_targets=="All Friendlies" end
    return false
end
local Fields = {
    { "enabled", "bool", "Enable Healing", true },
    { "focused_hp", "int", "Custom: Burst Heal HP %", 98, 25, 100 },
    { "group_hp", "int", "Custom: Group Heal Injury HP %", 98, 25, 100 },
    { "channel_hp", "int", "Custom: Single-Target Treatment HP %", 70, 25, 100 },
    { "heal_start", "int", "Custom: Heal Below HP %", 98, 50, 100 },
    { "direct_hp", "int", "Custom: Medical Probe HP %", 85, 25, 98, "Medical Probe" },
    { "emergency_hp", "int", "Emergency HP %", 40, 10, 70 },
    { "critical_hp", "int", "Critical: Spend Through Reserve HP %", 65, 40, 85, nil,
      "At or below this HP, paid healing uses the Critical Energy Reserve instead of preserving the routine reserve. This prevents saving cells while a target is dying." },
    { "critical_floor", "int", "Critical Energy Reserve %", 20, 0, 50, nil,
      "Reserve used for targets at or below Critical HP. True Emergency HP can still use the lower Emergency Energy Reserve." },
    { "self_bias", "int", "Self Triage Priority %", 5, 0, 15 },
    { "self_survival_first", "bool", "Self Survival: Prioritize Healer", true, nil, nil, nil,
      "Below Self Survival HP, prefer self rescue unless a more urgent critical ally needs healing and you are above Emergency HP. Your own emergency retains first refusal. Defensives still activate at the survival boundary." },
    { "self_survival_hp", "int", "Self Survival: First-Priority HP %", 70, 40, 90, nil,
      "Self protection starts below this HP. A more urgent critical ally can receive healing while you are above Emergency HP. Blocked self-heals still yield to legal ally healing." },
    { "self_kolto", "bool", "Self Survival: Kolto Bomb", true, nil, nil, "Kolto Bomb",
      "Allow a self-centered Bomb below Self Survival HP even without a second injured ally. When moving or critical, prefer it to ordinary hardcasts after available instant burst heals. Actual cost, cooldown and ground admission still apply." },
    { "energy_floor", "int", "Routine Energy Reserve %", 60, 20, 80 },
    { "emergency_floor", "int", "Emergency Energy Reserve %", 0, 0, 40 },
    { "recharge", "bool", "Auto Recharge Cells", true, nil, nil, "Recharge Cells" },
    { "recharge_at", "int", "Recharge Below Energy %", 20, 20, 65, "Recharge Cells" },
    { "supercharge", "bool", "Auto Supercharged Kolto Cell", true, nil, nil, "Supercharged Kolto Cell" },
    { "supercharge_hp", "int", "Supercharge: Single-Target Burst HP %", 75, 20, 90, "Supercharged Kolto Cell",
      "Burst threshold when AMP has no observed cooldown to reset. A real AMP cooldown plus a target inside the profile's AMP healing threshold can trigger Cell earlier. Cell reserves AMP as its follow-up." },
    { "supercharge_group_hp", "int", "Supercharge: Group Injury HP %", 80, 30, 90, "Supercharged Kolto Cell",
      "Only allies at or below this HP count toward a group burst window. The active profile's AMP threshold also applies." },
    { "supercharge_group_min", "int", "Supercharge: Group Injured Count", 2, 2, 8, "Supercharged Kolto Cell",
      "Require this many meaningfully injured allies for a group window, not merely two actors missing a little health." },
    { "tech_override", "bool", "Emergency Tech Override", true, nil, nil, "Tech Override" },
    { "trauma", "bool", "Maintain Trauma Probe", true, nil, nil, "Trauma Probe" },
    { "trauma_lull_roster", "bool", "Trauma: Maintain Roster During Lulls", true, nil, nil, "Trauma Probe",
      "When nobody needs an active heal, keep Trauma Probe on eligible allies before idle DPS. Self is maintained first; unknown or foreign ownership is never overwritten." },
    { "trauma_charges", "int", "Trauma Refresh Charges", 1, 0, 4, "Trauma Probe" },
    { "group_heals", "bool", "Group Healing", true },
    { "group_min", "int", "Group Heal Minimum Injured", 2, 2, 8 },
    { "shield", "bool", "Emergency Reactive Shield", false, nil, nil, "Reactive Shield" },
    { "shield_hp", "int", "Reactive Shield HP %", 40, 10, 80, "Reactive Shield" },
    { "adrenaline", "bool", "Emergency Adrenaline Rush", true, nil, nil, "Adrenaline Rush" },
    { "echoing", "bool", "Emergency Echoing Deterrence", false, nil, nil, "Echoing Deterrence" },
    { "diagnostics", "bool", "Healing Diagnostics", false },
    { "medical_probe_bridge", "bool", "Healing: Medical Probe Between Burst Heals", true, nil, nil, "Medical Probe",
      "When stronger suitable heals are unavailable, use Medical Probe up to the profile's focused-heal HP threshold if its full cost preserves the configured energy reserve. Avoids free-filler-only healing with high energy." },
    { "readiness_wait_ms", "int", "Readiness: Preferred Heal Wait (ms)", 150, 0, 500, nil,
      "Maximum preference wait for asynchronous strong-heal validation before trying another useful action. This is a scheduling budget, never a claimed cooldown or permission to cast without Core validation." },
    { "idle_dps_after_heals", "bool", "Continuity: Free DPS After Unusable Heals", true, nil, nil, nil,
      "After all suitable heals fail, allow only Hammer Shot on your selected hostile if everyone remains above Critical/Self Survival HP. Does not override an urgent heal, native command, cast, GCD, or unknown friendly data." },
    { "pre_trauma_incoming", "bool", "Trauma: Protect Incoming Target", true, nil, nil, "Trauma Probe",
      "Like Seer's incoming pre-shield: protect a healthy eligible ally only when this tick's hostile ability activation names that exact ally. Never predicts damage amounts or targets the nearest unit." },
    { "recover_before_dps", "bool", "Recovery: Recharge Before Idle DPS", true, nil, nil, "Recharge Cells",
      "During observed combat and a safe healing lull, use configured low-energy Recharge Cells before damage. A denied recovery does not lock the tick; useful healing always remains first." },
    { "proc_expiry", "int", "Procs: Emergency Response Expiry Seconds", 3, 0, 5, "Emergency Response",
      "Spend a freshly observed expiring Emergency Response on an injured ally before routine Bacta. Never heals full HP to consume it. Zero disables this early promotion." },
    { "kolto_min", "int", "Group: Kolto Bomb Minimum Injured", 0, 0, 8, "Kolto Bomb",
      "Zero follows Group Heal Minimum Injured. Otherwise require at least two qualifying injuries inside the real 8m radius." },
    { "successive_min", "int", "Group: Treatment Minimum Injured", 0, 0, 8, "Successive Treatment",
      "Zero follows Group Heal Minimum Injured. Otherwise require at least two qualifying injuries inside the real 20m spread radius." },
    { "dps_enabled", "bool", "DPS: Enable During Healing Downtime", true, nil, nil, nil,
      "Damage only while no eligible ally needs healing. A rejected heal never enables DPS. Uses only your selected hostile target." },
    { "dps_in_combat_only", "bool", "DPS: In Combat Only", true, nil, nil, nil,
      "Require the existing observed player enter-combat state. Unknown/out-of-combat blocks damage; disable to allow deliberate pulls with the rotation key." },
    { "dps_min_hp", "int", "DPS: Minimum Ally HP %", 98, 50, 100, nil,
      "Every in-range eligible ally, including yourself, must meet this threshold. Cannot override Heal Below HP % to ignore a healing need." },
    { "dps_energy_floor", "int", "DPS: Energy Reserve %", 75, 0, 100, nil,
      "Paid damage must leave this percentage of energy. The healer's routine reserve also applies. Hammer Shot can still fire below the reserve." },
    { "dps_free_only", "bool", "DPS: Free Attacks Only", true, nil, nil, nil,
      "Use only the intrinsically free Hammer Shot; no paid attacks, even under a temporary free-cost proc." },
    { "dps_charged_bolts", "bool", "DPS: Charged Bolts", true, nil, nil, "Charged Bolts",
      "Allow the casted damage filler. It waits for a stationary or verified instant cast, and never activates Tech Override for damage." },
    { "dps_hib", "bool", "DPS: High Impact Bolt", true, nil, nil, "High Impact Bolt",
      "Use only when native target-condition/cooldown admission accepts it. No Gunnery Gravity Vortex assumptions in the healer spec." },
    { "dps_full_auto", "bool", "DPS: Full Auto Channel", true, nil, nil, "Full Auto",
      "Optional full damage channel, budgeted for all 24 energy cells. An already-started channel must finish before healing can resume." },
    { "dps_electro_net", "bool", "DPS: Electro Net", false, nil, nil, "Electro Net",
      "Spend the long-cooldown control ability on the selected hostile during safe downtime. Off by default to preserve manual PvP timing." },
    { "dps_preserve_procs", "bool", "DPS: Reserve Healing Procs", true, nil, nil, nil,
      "Preserve Tech Override for heals and Recharge Cells' free-ability proc. Unknown proc observations also block the attacks that could consume them." },
    { "action_window_visible", "bool", "Actions: Visible", false, nil, nil, nil,
      "Show the frameless Combat Medic action feed. Use the on-screen X to hide it and this toggle to restore it." },
    { "action_window_x", "int", "Actions: Position X", 966, 0, 7680, nil,
      "Horizontal screen position. Drag the on-screen handle to update it." },
    { "action_window_y", "int", "Actions: Position Y", 512, 0, 4320, nil,
      "Vertical screen position. Drag the on-screen handle to update it." },
    { "action_window_font_size", "int", "Actions: Main Font Size", 24, 16, 36, nil,
      "Large action-line font size in pixels." },
    { "action_window_rows", "int", "Actions: Visible Rows", 5, 1, 8, nil,
      "Maximum recent Combat Medic actions shown at once." },
    { "action_window_lifetime", "int", "Actions: Lifetime", 8, 2, 20, nil,
      "Seconds each accepted action remains visible before fading out." },
    { "action_window_show_heal_amount", "bool", "Actions: Show Heal Amount", true, nil, nil, nil,
      "Accumulate measured player heal events into recent Combat Medic healing actions." },
    { "action_window_show_damage", "bool", "Actions: Show Damage", true, nil, nil, nil,
      "Show Combat Medic downtime damage and enrich it with measured combat-event damage." },
    { "action_window_show_procs", "bool", "Actions: Show Proc Enhancements", true, nil, nil, nil,
      "Show proc labels when an accepted Combat Medic action supplies observed proc metadata." },

}
function M.settings(schema)
    for _,select in ipairs(Selects) do
        schema.fields[#schema.fields+1]={key="medic_"..select.key,type="select",label="Medic: "..select.label,
            default=select.default,options=select.options,tooltip=select.tooltip,disciplines={"Combat Medic"}}
    end
    for _, f in ipairs(Fields) do
        schema.fields[#schema.fields+1] = {
            key="medic_"..f[1],type=f[2],label="Medic: "..f[3],default=f[4],min=f[5],max=f[6],
            requires_ability=f[7],tooltip=f[8],disciplines={"Combat Medic"},
        }
    end
    return schema
end
function M.options(settings)
    local result={}
    for _,select in ipairs(Selects) do
        result[select.key]=choice(setting(settings,select.key),select.options) or select.default
    end
    -- Compatibility for old callers/snapshots without the new target selector.
    -- The explicit new selector wins; old booleans cannot override a user choice.
    if setting(settings,"healing_targets")==nil and setting(settings,"players_only")==true then
        result.healing_targets="Players only"
    end
    for _,f in ipairs(Fields) do
        local value=setting(settings,f[1])
        if f[2]=="bool" then
            if type(value)~="boolean" then value=f[4] end
        elseif not finite(value) then value=f[4]
        else value=math.max(f[5],math.min(f[6],math.floor(value))) end
        result[f[1]]=value
    end
    local profile=Profiles[result.healing_style]
    if profile then for key,value in pairs(profile) do result[key]=value end end
    result.focused_hp=math.min(result.focused_hp,result.heal_start)
    result.group_hp=math.min(result.group_hp,result.heal_start)
    result.channel_hp=math.min(result.channel_hp,result.heal_start)
    result.direct_hp=math.min(result.direct_hp,result.heal_start)
    result.kolto_min=result.kolto_min==0 and result.group_min or math.max(2,result.kolto_min)
    result.successive_min=result.successive_min==0 and result.group_min or math.max(2,result.successive_min)
    return result
end
local TriageNames = {"emergency","critical","routine"}
-- Consume v2's existing urgent bands, not a new forecast or invented heal size.
-- Current HP remains untouched; only evidenced urgency can promote a decision.
local function pressure_urgency(row,cfg)
    local p=row and row.pressure
    if cfg.triage_mode~=PressureFormula.MODE_PRESSURE or type(p)~="table" or
        p.pressure_model~="idf_v2_persistence" or not finite(p.fast_pressure) or p.fast_pressure<=0 or
        not finite(p.projected_hp_2s) or p.projected_hp_2s<0 or p.projected_hp_2s>1 or
        not finite(p.ttd) or p.ttd<0 or p.hp_percent~=row.current/row.maximum then return nil end
    if p.risk_band==0 or p.risk_band==1 then return p.risk_band end
end
local function triage_band(row,cfg)
    local actual=row.hp<=cfg.emergency_hp and 0 or (row.hp<=cfg.critical_hp and 1 or 2)
    return math.min(actual,pressure_urgency(row,cfg) or 2)
end
local function healing_needed(row,cfg,limit)
    return row and row.hp>0 and row.hp<100 and
        (row.hp<=limit or pressure_urgency(row,cfg)~=nil)
end
local function healing_reserve(row,cfg)
    local band=row and triage_band(row,cfg) or 2
    return band==0 and cfg.emergency_floor or (band==1 and cfg.critical_floor or cfg.energy_floor)
end
-- Urgency first, then actual health buffer in urgent bands. A percentage alone
-- treats 3k/10k as safer than 100k/400k against the same absolute hit.
-- Ordinary healing keeps the existing percentage/self-bias policy.
local function triage_less(a,b,cfg)
    local lhs,rhs=triage_band(a,cfg),triage_band(b,cfg)
    if lhs~=rhs then return lhs<rhs end
    if lhs<2 then
        if a.current~=b.current then return a.current<b.current end
        if a.hp~=b.hp then return a.hp<b.hp end
    elseif a.score~=b.score then return a.score<b.score end
    if a.missing~=b.missing then return a.missing>b.missing end
    if a.isSelf~=b.isSelf then return a.isSelf end
    return a.handle<b.handle
end
local function self_first(rows,self_hp,cfg)
    if not cfg.self_survival_first or self_hp>=cfg.self_survival_hp then return false end
    if self_hp<=cfg.emergency_hp then return true end
    local first=rows[1]
    return not first or first.isSelf or triage_band(first,cfg)==2
end
local function urgent_preempts(recipient,rows,self_hp,cfg,name,selection)
    if not recipient then return false end
    if self_first(rows,self_hp,cfg) then return not recipient.isSelf end
    local first=rows[1]
    if not first or first.handle==recipient.handle or triage_band(first,cfg)>=2 or
        triage_band(recipient,cfg)<=triage_band(first,cfg) then return false end
    -- A group rescue must still cover this target. Separate group work chosen
    -- after unavailable rescue may continue while that urgency is unchanged.
    local unchanged=selection and selection.priority_target==first.handle and
        selection.priority_band and triage_band(first,cfg)>=selection.priority_band
    local radius=Ability[name] and Ability[name].groupRadius
    local separation=radius and distance(first.position,recipient.position)
    if radius then
        if unchanged and selection.priority_covered==false then return false end
        return not separation or separation>radius
    end
    -- If this urgency already existed when the command was chosen, its rescue
    -- options were exhausted first. Do not repeatedly cancel permitted work.
    -- A new critical target or a worse band still preempts it.
    return not unchanged
end
-- Heal rows plus a conservative all-clear observation for damage admission.
-- Missing/truncated friendly data is not evidence that everyone is healthy.
local function collect(world, cfg, pressure_tracker, pressure_now)
    local rows, seen = {}, {}
    local observation={complete=true,min_hp=100,eligible=0,reason="ready",all={}}
    local function incomplete(reason)
        observation.complete=false
        if observation.reason=="ready" then observation.reason=reason end
    end
    local player_handle=method(world.player,"handle")
    if type(player_handle)~="string" then incomplete("player_identity_unavailable") end
    local function add(unit)
        if not unit then return end
        local handle=method(unit,"handle")
        if type(handle)=="string" and seen[handle] then return end
        local self=type(player_handle)=="string" and handle==player_handle
        local kind=method(unit,"type")
        if not self and (method(unit,"reaction")~="friendly" or
            not healable_type(kind,cfg)) then return end
        if type(handle)~="string" then incomplete("friendly_identity_unavailable");return end
        seen[handle]=true
        if not self then
            local range=method(unit,"distance")
            if not finite(range) or range<0 then incomplete("friendly_range_unavailable");return end
            if range*10>30 then return end
        end
        local hp=method(unit,"hp")
        if type(hp)~="table" or not finite(hp.current) or not finite(hp.max) or
            hp.max<=0 or hp.current<0 or hp.current>hp.max then
            if not observation.hp_failure then
                observation.hp_failure={handle=handle,kind=kind,available=type(hp)=="table",
                    current=type(hp)=="table" and hp.current or nil,
                    maximum=type(hp)=="table" and hp.max or nil}
            end
            incomplete("friendly_hp_unavailable");return
        end
        if hp.current==0 then return end -- Dead actors are not direct-heal candidates.
        local ratio=hp.current/hp.max*100
        local row={unit=unit,handle=handle,hp=ratio,isSelf=self,position=position(unit),
            score=ratio-(self and cfg.self_bias or 0),kind=kind,current=hp.current,maximum=hp.max,missing=hp.max-hp.current}
        observation.min_hp=math.min(observation.min_hp,ratio)
        observation.eligible=observation.eligible+1
        observation.all[#observation.all+1]=row
        local lowest=observation.lowest
        if not lowest or row.hp<lowest.hp or
            (row.hp==lowest.hp and row.missing>lowest.missing) or
            (row.hp==lowest.hp and row.missing==lowest.missing and row.isSelf and not lowest.isSelf) or
            (row.hp==lowest.hp and row.missing==lowest.missing and row.isSelf==lowest.isSelf and row.handle<lowest.handle) then
            observation.lowest=row
        end
        if hp.current==hp.max then return end
        -- Evaluate injured patients before the HP gate: an urgent v2 forecast
        -- must not disappear merely because current HP is still above it.
        rows[#rows+1]=row
    end
    add(world.player)
    add(world.current_target)
    local units=method(world,"units",{reaction="friendly"})
    if type(units)~="table" then incomplete("friendly_scan_unavailable")
    else
        if #units>MAX_SCAN then incomplete("friendly_scan_truncated") end
        for i=1,math.min(#units,MAX_SCAN) do add(units[i]) end
    end
    table.sort(observation.all,function(a,b)
        if a.isSelf~=b.isSelf then return a.isSelf end
        if a.hp~=b.hp then return a.hp<b.hp end
        if a.missing~=b.missing then return a.missing>b.missing end
        return a.handle<b.handle
    end)
    table.sort(rows,function(a,b) return triage_less(a,b,cfg) end)
    for _,row in ipairs(rows) do
        if row.hp<=cfg.heal_start then observation.hp_priority=row;break end
    end
    if cfg.triage_mode==PressureFormula.MODE_PRESSURE and pressure_tracker then
        pressure_tracker:sort(rows,pressure_now,function(a,b) return triage_less(a,b,cfg) end)
    end
    local kept,total=0,#rows
    for i=1,total do
        local row=rows[i]
        if kept<MAX_TARGETS and healing_needed(row,cfg,cfg.heal_start) then
            kept=kept+1;rows[kept]=row
        end
    end
    for i=total,kept+1,-1 do rows[i]=nil end
    return rows,observation
end
local function selected_hostile(world)
    local unit=world and world.current_target
    local handle=method(unit,"handle")
    if type(handle)~="string" or handle==method(world.player,"handle") or
        method(unit,"reaction")~="hostile" then return nil,"no_selected_hostile" end
    local kind=method(unit,"type")
    if kind~="player" and kind~="npc" and kind~="companion" then return nil,"invalid_hostile_type" end
    local hp=method(unit,"hp")
    if type(hp)~="table" or not finite(hp.current) or not finite(hp.max) or
        hp.max<=0 or hp.current<=0 or hp.current>hp.max then return nil,"hostile_dead_or_hp_unknown" end
    return {unit=unit,handle=handle,hp=hp.current/hp.max*100,kind=kind},"ready"
end

-- Seer's protection policy translated to a reactive Trauma Probe, not Force Armor.
-- Known foreign protection is preserved; missing/ambiguous ownership is not absence.
local function trauma_due(unit,cfg)
    local present,row=effect(unit,Effect.TraumaProbe)
    if present==false then return true end
    if present~=true or type(row)~="table" or row.has_ownership~=true or row.mine~=true then return false end
    return (row.has_charges==true and row.stacks<=cfg.trauma_charges) or
        (row.has_timer==true and row.remaining<=3)
end
local function fresh_friendly(world,handle,cfg,ranked_rows)
    local unit=method(world,"resolve",handle)
    if not unit or method(unit,"handle")~=handle then return nil end
    local self=handle==method(world.player,"handle")
    if not self and (method(unit,"reaction")~="friendly" or not healable_type(method(unit,"type"),cfg)) then return nil end
    local hp=method(unit,"hp")
    if type(hp)~="table" or not finite(hp.current) or not finite(hp.max) or
        hp.max<=0 or hp.current<=0 or hp.current>hp.max then return nil end
    if not self then
        local range=method(unit,"distance")
        if not finite(range) or range<0 or range*10>30 then return nil end
    end
    local percent=hp.current/hp.max*100
    local pressure
    -- Reuse only this decision's bounded, exact-health row. No extra history
    -- scans and no old forecast copied across a fresh health change.
    for i=1,math.min(type(ranked_rows)=="table" and #ranked_rows or 0,MAX_TARGETS) do
        local ranked=ranked_rows[i]
        if ranked.handle==handle and ranked.current==hp.current and ranked.maximum==hp.max then
            pressure=ranked.pressure;break
        end
    end
    return {unit=unit,handle=handle,hp=percent,isSelf=self,position=position(unit),
        score=percent-(self and cfg.self_bias or 0),kind=method(unit,"type"),pressure=pressure,
        current=hp.current,maximum=hp.max,missing=hp.max-hp.current}
end
local function incoming_trauma_targets(world,events,cfg)
    local targets,seen={},{}
    if type(events)~="table" then return targets end
    for i=1,math.min(#events,256) do
        local event=events[i]
        if type(event)=="table" and event.kind=="ability" and event.action=="ability_activate" and
            type(event.source_handle)=="string" and type(event.target_handle)=="string" and
            not seen[event.target_handle] then
            local source=method(world,"resolve",event.source_handle)
            if source and method(source,"handle")==event.source_handle and method(source,"reaction")=="hostile" then
                local row=fresh_friendly(world,event.target_handle,cfg)
                if row then
                    seen[row.handle]=true;targets[#targets+1]=row
                    if #targets>=MAX_TARGETS then break end
                end
            end
        end
    end
    table.sort(targets,function(a,b) return triage_less(a,b,cfg) end)
    return targets
end
-- Like Seer's best-center search: count real qualifying injuries, break ties
-- by measured missing HP and triage, and never substitute distance-to-player.
local function clusters(rows,radius,minimum,maximum_hp,skips,required)
    local centers={}
    for _,center in ipairs(rows) do
        if center.position and not skips[center.handle] then
            local required_distance=required and distance(center.position,required.position) or nil
            if not required or (required_distance and required_distance<=radius) then
                local count,missing=0,0
                for _,other in ipairs(rows) do
                    local separation=distance(center.position,other.position)
                    if other.hp<=maximum_hp and separation and separation<=radius then
                        count=count+1;missing=missing+(other.missing or 0)
                    end
                end
                if count>=minimum then centers[#centers+1]={row=center,count=count,missing=missing} end
            end
        end
    end
    table.sort(centers,function(a,b)
        if a.count~=b.count then return a.count>b.count end
        if a.missing~=b.missing then return a.missing>b.missing end
        if a.row.score~=b.row.score then return a.row.score<b.row.score end
        return a.row.handle<b.row.handle
    end)
    return centers
end

-- Burst-cooldown usefulness is separate from instant-cast legality. A proc
-- does not make a nearly-full target a worthwhile burst-heal recipient.
local function healing_limit(name,cfg,is_self)
    local limit=cfg.heal_start
    if name=="Bacta Infusion" or name=="Advanced Medical Probe" then limit=cfg.focused_hp end
    if is_self and cfg.self_survival_first then limit=math.max(limit,math.min(cfg.heal_start,cfg.self_survival_hp)) end
    return math.max(limit,cfg.emergency_hp)
end

local function self_kolto_needed(row,cfg)
    return cfg.self_kolto and cfg.self_survival_first and row and row.isSelf and
        row.hp>0 and row.hp<cfg.self_survival_hp
end

-- One benefit policy for first attempt, retained native admission and queued
-- cancellation. Counts meaningful AMP recipients, not arbitrary injured actors.
local function amp_on_cooldown(info)
    return type(info)=="table" and info.has_cooldown_remaining==true and
        finite(info.cooldown_remaining) and info.cooldown_remaining>0
end
local function supercharge_demand(rows,cfg,hard_self,reset)
    local grouped={}
    local single,reset_target
    for _,row in ipairs(rows) do
        local ceiling=healing_limit("Advanced Medical Probe",cfg,row.isSelf)
        if healing_needed(row,cfg,ceiling) then
            if hard_self and row.isSelf then return row,"self_rescue",1 end
            if reset and not reset_target then reset_target=row end
            if not single and healing_needed(row,cfg,math.max(cfg.supercharge_hp,cfg.emergency_hp)) then single=row end
            if row.hp<=cfg.supercharge_group_hp then grouped[#grouped+1]=row end
        end
    end
    if reset_target then return reset_target,"cooldown_reset",1 end
    if single then return single,"single_burst",#grouped end
    if #grouped>=cfg.supercharge_group_min then return grouped[1],"group_burst",#grouped end
end
local function refund_recipient(rows,cfg,hard_self,resource,cost,amp)
    if type(amp)~="table" or amp.has_cooldown_remaining~=true or amp.cooldown_remaining~=0 or
        not finite(cost) or cost<=0 or type(resource)~="table" or
        not finite(resource.current) or not finite(resource.max) or resource.max<=0 or
        resource.current<0 or resource.current>resource.max then return end
    local row=supercharge_demand(rows,cfg,hard_self,true)
    if not row then return end
    local floor=healing_reserve(row,cfg)
    if row.isSelf and hard_self then floor=math.min(healing_reserve(row,cfg),cfg.critical_floor) end
    local required=cost+resource.max*floor/100
    -- Cell restores ten energy cells, independent of the resource capacity.
    if resource.current<required and math.min(resource.max,resource.current+10)>=required then return row end
end

function M.new(executor)
    assert(type(executor)=="table" and type(executor.submit)=="function" and
        type(executor.status)=="function", "Combat Medic requires the shared AbilityExecutor")
    local pending, lastDiagnostic, buildLogged, lastPolicy, bactaFollowTarget, awaitTechOverrideEffect = nil, -math.huge, false, nil, nil, false
    local nativeIntent, preferenceSince, lastPlayer = nil, nil, nil
    local pressurePlayerHandle, lastSc4Key
    local adrenalineAttempt, adrenalineFailure, rejectionPlayer, rejectionEpoch
    local hot_names = { ["Trauma Probe"] = true }
    local pressure_tracker = PressureTracker.new({ hot_names = hot_names })
    local lastPressureDiagnostic = -math.huge
    local cellFollow
    local function owns_pending()
        if not executor:owns_command() then return false end
        local s=executor:status()
        return type(s)=="table" and type(s.idempotency_key)=="string" and
            s.idempotency_key:sub(1,#OWNER)==OWNER
    end
    local function stop(reason)
        cellFollow=nil
        pressure_tracker:reset()
        pressurePlayerHandle=nil
        if reason~="combat_medic_key_up" then lastSc4Key=nil end
        nativeIntent,preferenceSince,bactaFollowTarget,awaitTechOverrideEffect=nil,nil,nil,false
        if owns_pending() then executor:cancel(reason or "combat_medic_inactive") end
        if not executor:owns_command() then pending=nil end
        return owns_pending()
    end
    local function priority_state(loadout,world,cfg)
        loadout=Mirror.adapt_loadout(loadout)
        CurrentLoadout=loadout
        if not is_selected(loadout) or not world or not world.player then return nil end
        cfg=type(cfg)=="table" and cfg or M.options({})
        local hp=method(world.player,"hp")
        if type(hp)~="table" or not finite(hp.current) or not finite(hp.max) or hp.current<=0 or hp.max<=0 then return nil end
        local priority_now=type(gos.time_ms)=="function" and gos.time_ms() or nil
        local rows,observation=collect(world,cfg,pressure_tracker,priority_now)
        local self_hp=hp.current/hp.max*100
        return {healing=#rows>0,self_survival=self_first(rows,self_hp,cfg),
            lowest=observation and observation.min_hp or nil}
    end
    local function tick(loadout, active, options)
        loadout=Mirror.adapt_loadout(loadout)
        CurrentLoadout=loadout
        options=type(options)=="table" and options or {}
        local cfg=options.healing or M.options({})
        local function emit(level,text)
            if type(options.logLine)=="function" then options.logLine(level,text) end
        end
        local now=type(gos.time_ms)=="function" and gos.time_ms() or nil
        if not finite(now) then return true end
        local event_world=gos.world()
        local event_player=event_world and event_world.player or nil
        local event_player_handle=method(event_player,"handle")
        local epoch=event_world and event_world.actor_epoch
        if cellFollow and (cellFollow.player~=event_player_handle or cellFollow.epoch~=epoch) then
            cellFollow=nil
        end
        if rejectionPlayer~=event_player_handle or rejectionEpoch~=epoch or not is_selected(loadout) then
            adrenalineAttempt,adrenalineFailure=nil,nil
            rejectionPlayer,rejectionEpoch=event_player_handle,epoch
        end
        if adrenalineAttempt or adrenalineFailure then
            local status=executor:status()
            local core=type(status)=="table" and type(status.core)=="table" and status.core or {}
            if adrenalineAttempt and core.known==true and
                status.command_handle==adrenalineAttempt.command then
                if core.activation_proven==true then
                    adrenalineAttempt,adrenalineFailure=nil,nil
                elseif core.terminal==true and core.state=="failed" and
                    core.game_result_known==true and core.game_result==NATIVE_CONDITION_FAILED then
                    adrenalineFailure={context=adrenalineAttempt.context}
                    if cfg.diagnostics then emit("info","combat medic Adrenaline Rush held: condition_failed command="..
                        adrenalineAttempt.command.." until=observed_condition_change") end
                    adrenalineAttempt=nil
                elseif core.terminal==true and core.state~="submitted" then adrenalineAttempt=nil end
            end
            if adrenalineFailure then
                local changed=adrenaline_rearmed(adrenalineFailure,adrenaline_context(event_player,loadout))
                if changed then
                    adrenalineFailure=nil
                    if cfg.diagnostics then emit("info","combat medic Adrenaline Rush rearmed: "..changed) end
                end
            end
        end
        if event_player_handle~=pressurePlayerHandle then
            pressure_tracker:reset()
            pressurePlayerHandle=event_player_handle
        end
        local raw_loadout = Mirror.raw_loadout(loadout)
        hot_names["Kolto Shell"] = type(raw_loadout)=="table" and raw_loadout.combat_style=="mercenary" or nil
        pressure_tracker:observe(options.combatEvents,
            event_player_handle, options.combatDropped or 0, now)
        local function diagnostic(text)
            if cfg.diagnostics and now-lastDiagnostic>=2000 then
                lastDiagnostic=now; emit("info","combat medic: "..text)
            end
        end
        if not is_selected(loadout) then stop("combat_medic_wrong_loadout"); return false end
        if not active or not cfg.enabled then stop("combat_medic_key_up"); return true end
        if type(options.logLine)=="function" then
            if not buildLogged then
                buildLogged=true
                emit("info","combat medic build="..M.revision.." healer=active idle_dps=conditional heal_target=explicit dps_target=selected admission=stable_native_retry")
            end
            local policy_signature=table.concat({cfg.triage_mode,cfg.healing_style,cfg.healing_targets,tostring(cfg.heal_start),
                tostring(cfg.focused_hp),tostring(cfg.group_hp),tostring(cfg.channel_hp),tostring(cfg.direct_hp),
                tostring(cfg.self_kolto),tostring(cfg.shield),tostring(cfg.adrenaline),tostring(cfg.echoing)},"/")
            if policy_signature~=lastPolicy then
                lastPolicy=policy_signature
                emit("info","combat medic policy: style="..cfg.healing_style.." targets="..cfg.healing_targets..
                    " heal="..cfg.heal_start.." focused="..cfg.focused_hp.." group="..cfg.group_hp..
                    " channel="..cfg.channel_hp.." filler="..cfg.direct_hp..
                    " triage="..tostring(cfg.triage_mode).." self_kolto="..tostring(cfg.self_kolto).." shield="..tostring(cfg.shield)..
                    " adrenaline="..tostring(cfg.adrenaline).." echoing="..tostring(cfg.echoing))
            end
        end
        if pending then
            local state=executor:status()
            local command_core=type(state)=="table" and type(state.core)=="table" and state.core or {}
            if owns_pending() and command_core.state=="queued" and
                command_core.activation_proven~=true and
                (pending.name=="Advanced Medical Probe" or pending.name=="Medical Probe") then
                local snapshot=gos.world()
                local allowed,instant_now=probe_permission(snapshot and snapshot.player,pending.name)
                if not allowed or (pending.instant_required and not instant_now) then
                    executor:cancel("combat_medic_queued_cast_permission_changed")
                end
            end
            if pending.name=="Supercharged Kolto Cell" and owns_pending() then
                local snapshot=gos.world()
                local healing_gcd=gos.abilities.gcd_remaining()
                if not cfg.supercharge then executor:cancel("supercharge_disabled")
                elseif not finite(healing_gcd) or healing_gcd~=0 then executor:cancel("supercharge_healing_gcd_blocked")
                elseif snapshot and snapshot.player then
                    local fresh,observed=collect(snapshot,cfg,pressure_tracker,now)
                    local self_row=fresh_friendly(snapshot,method(snapshot.player,"handle"),cfg)
                    local self_need=self_row and self_first(fresh,self_row.hp,cfg)
                    local amp=Mirror.call(CurrentLoadout,"info","Advanced Medical Probe")
                    local moving=method(snapshot.player,"speed")
                    local mobile_amp=effect(snapshot.player,Effect.EmergencyResponse)==true or
                        effect(snapshot.player,Effect.TechOverride)==true or effect(snapshot.player,Effect.TechOverrideDouble)==true or
                        effect(snapshot.player,Effect.RunningRestoration,"any")==true
                    local cannot_amp=not learned(loadout,"Advanced Medical Probe") or type(amp)~="table" or
                        type(amp.ability_handle)~="string" or amp.on_bar~=true or
                        (not mobile_amp and (not finite(moving) or math.abs(moving)>0.001))
                    if cannot_amp then executor:cancel("supercharge_amp_became_unusable")
                    elseif effect(snapshot.player,Effect.SupportCell)==true then executor:cancel("supercharge_already_active")
                    elseif observed.complete and not supercharge_demand(fresh,cfg,self_need,amp_on_cooldown(amp)) then
                        local cost=amp.has_resource_cost==true and amp.resource_cost or nil
                        if finite(cost) and effect(snapshot.player,Effect.FreeCell)==true then cost=0 end
                        if not refund_recipient(fresh,cfg,self_need,Mirror.resource(CurrentLoadout,method(snapshot.player,"resource")),cost,amp) then
                            executor:cancel("supercharge_burst_need_resolved")
                        end
                    end
                end
            end
            -- Only cancel our queued damage; Core decides whether it is still
            -- safely cancellable. Never fake an interrupt of an active cast.
            if pending.phase=="dps" and owns_pending() then
                local snapshot=gos.world()
                local heal_rows,observation
                if snapshot and snapshot.player then heal_rows,observation=collect(snapshot,cfg,pressure_tracker,now) end
                local hostile=snapshot and snapshot.player and selected_hostile(snapshot) or nil
                local continuity_safe=pending.decision=="unusable_heals_free_dps" and cfg.idle_dps_after_heals and
                    observation and observation.complete and observation.min_hp>=pending.guard_min_hp and
                    (not heal_rows[1] or triage_band(heal_rows[1],cfg)==2) and
                    observation.min_hp>math.max(cfg.critical_hp,cfg.emergency_hp,
                        cfg.self_survival_first and cfg.self_survival_hp or 0)
                local no_longer_safe=not cfg.dps_enabled or not observation or not observation.complete or
                    (not continuity_safe and (#heal_rows>0 or observation.min_hp<math.max(cfg.heal_start,cfg.dps_min_hp))) or
                    (cfg.dps_in_combat_only and options.inCombat~=true) or not hostile or
                    hostile.handle~=pending.target
                if no_longer_safe then executor:cancel("combat_medic_healing_preempts_queued_dps") end
            end
            if pending.phase=="healing" and pending.target~="none" and owns_pending() then
                local snapshot=gos.world()
                local fresh=snapshot and snapshot.player and collect(snapshot,cfg,pressure_tracker,now) or {}
                local recipient=snapshot and snapshot.player and fresh_friendly(snapshot,pending.target,cfg,fresh) or nil
                local player_handle=snapshot and snapshot.player and method(snapshot.player,"handle") or nil
                local player_row=player_handle and fresh_friendly(snapshot,player_handle,cfg,fresh) or nil
                if player_row and urgent_preempts(recipient,fresh,player_row.hp,cfg,pending.name,pending) then
                    executor:cancel("combat_medic_urgent_triage_preempts_queued_heal")
                elseif not recipient then
                    executor:cancel("combat_medic_target_policy_or_heal_no_longer_needed")
                elseif pending.decision=="self_survival_kolto" and not self_kolto_needed(recipient,cfg) then
                    executor:cancel("combat_medic_self_kolto_no_longer_needed")
                elseif pending.name~="Trauma Probe" then
                    local needed_until=healing_limit(pending.name,cfg,recipient.isSelf)
                    if pending.decision=="maintenance_topoff_to_dps_floor" then
                        needed_until=math.max(cfg.heal_start,cfg.dps_min_hp)
                    end
                    if not healing_needed(recipient,cfg,needed_until) then
                        executor:cancel("combat_medic_target_policy_or_heal_no_longer_needed")
                    end
                end
            end
            local status=executor:status()
            local core=type(status)=="table" and type(status.core)=="table" and status.core or {}
            if executor:owns_command() or core.cleanup_pending==true then
                diagnostic("awaiting Core command/cleanup: "..pending.name)
                return true
            end
            if type(status)=="table" and status.command_handle==pending.command then
                if core.activation_proven==true then
                    if pending.name=="Bacta Infusion" then bactaFollowTarget=pending.target
                    elseif pending.name=="Advanced Medical Probe" then bactaFollowTarget=nil
                    elseif pending.name=="Tech Override" then awaitTechOverrideEffect=true end
                    if options.castLog~=false then emit("info","combat medic action started: ability="..pending.name.." target="..pending.target) end
                elseif core.state=="submitted" then
                    diagnostic("native submission without activation proof: "..pending.name)
                else
                    diagnostic("command result: "..pending.name.." state="..tostring(core.state).." reason="..tostring(status.reason))
                end
            end
            pending=nil
        end
        if executor:owns_command() then diagnostic("shared executor owned by another action"); return true end
        local world=gos.world()
        if not world or not world.player then diagnostic("player unavailable"); return true end
        local player=world.player
        local currentPlayer=method(player,"handle")
        if currentPlayer~=lastPlayer then
            cellFollow=nil
            nativeIntent,preferenceSince,bactaFollowTarget,awaitTechOverrideEffect=nil,nil,nil,false
            lastSc4Key=nil
            lastPlayer=currentPlayer
        end
        local hp=method(player,"hp")
        if type(hp)~="table" or not finite(hp.current) or not finite(hp.max) or hp.current<=0 or hp.max<=0 then
            cellFollow=nil
            diagnostic("player dead or HP unavailable"); return true
        end
        local busy=gos.abilities.is_casting_or_channeling()
        local current=gos.abilities.current_cast()
        if busy~=false or (type(current)=="table" and
            (current.active==true or (finite(current.remaining) and current.remaining>0))) then return true end
        local gcd=gos.abilities.gcd_remaining()
        if not finite(gcd) or gcd<0 then diagnostic("GCD unavailable"); return true end
        local speed=method(player,"speed")
        local rows,healing_observation=collect(world,cfg,pressure_tracker,now)
        if cfg.triage_mode==PressureFormula.MODE_PRESSURE and options.decisionLog==true and
            rows[1] and healing_observation.hp_priority and
            rows[1].handle~=healing_observation.hp_priority.handle and rows[1].pressure and
            now-lastPressureDiagnostic>=500 then
            lastPressureDiagnostic=now
            local f=rows[1].pressure
            emit("debug",string.format(
                "combat medic pressure triage: model=%s hp_target=%s selected=%s hp=%.1f%% p2=%.1f%% p4=%.1f%% ttd=%.2fs attackers=%d recent=%d persistent=%d band=%d",
                tostring(f.pressure_model or "unknown"),
                tostring(healing_observation.hp_priority.handle),tostring(rows[1].handle),rows[1].hp,
                f.projected_hp_2s*100,f.projected_hp_4s*100,f.ttd,f.attackers_3s,
                f.recent_attackers or 0,f.persistent_attackers or 0,f.risk_band))
        end
        local resource=Mirror.resource(CurrentLoadout,method(player,"resource"))
        local energy_known=type(resource)=="table" and finite(resource.current) and finite(resource.max) and
            resource.max>0 and resource.current>=0 and resource.current<=resource.max
        local energy_percent=energy_known and resource.current/resource.max*100 or nil
        local support=effect(player,Effect.SupportCell)
        if cellFollow then
            local receipt=executor:status()
            local receipt_core=type(receipt)=="table" and type(receipt.core)=="table" and receipt.core or {}
            if receipt.command_handle==cellFollow.command then
                if receipt_core.activation_proven==true then cellFollow.proven=true
                elseif receipt_core.known==true and receipt_core.terminal==true and receipt_core.state~="submitted" then cellFollow=nil end
            end
        end
        if support==true then
            -- A current effect owns the window even for manual Cell use.
            cellFollow=cellFollow or {player=currentPlayer,epoch=world.actor_epoch}
            cellFollow.support_seen=true
        elseif support==false and cellFollow and cellFollow.support_seen then
            cellFollow=nil -- Observed end, not an assumed duration.
        end
        local emergency_response,emergency_observation=effect(player,Effect.EmergencyResponse)
        local running_restoration=effect(player,Effect.RunningRestoration,"any")
        local sc4,sc4_key=sc4_effect(player)
        if sc4==true and lastSc4Key~=sc4_key then
            lastSc4Key=sc4_key
            emit("info","combat medic tactical observed: SC-4 Treatment Scanner effect="..sc4_key..
                " source=exact_heal_sust_01")
        elseif sc4==false then lastSc4Key=nil end
        local override=effect(player,Effect.TechOverride)
        local override_double=effect(player,Effect.TechOverrideDouble)
        local instant=override==true or override_double==true
        if instant then
            awaitTechOverrideEffect=false
        elseif awaitTechOverrideEffect and #rows>0 then
            -- Activation can be proven one render/update slice before the exact
            -- buff snapshot publishes. Hold exactly this reevaluation instead of
            -- burning the next GCD on Med Shot, then require real effect evidence.
            awaitTechOverrideEffect=false
            diagnostic("awaiting Tech Override effect snapshot")
            return true
        end
        local free_cell=effect(player,Effect.FreeCell)
        local supercharge,sc=effect(player,Effect.Supercharge)
        local supercharge_stacks
        if supercharge==false then supercharge_stacks=0
        elseif supercharge==true and sc and sc.has_charges==true and finite(sc.stacks) and sc.stacks<=10 then
            supercharge_stacks=sc.stacks
        end
        local cache,reasons,skips,strongPending,attempted={},{},{},false,{}
        local amp_rejection
        local continuityDps=false
        local function preference_pending()
            if preferenceSince==nil then preferenceSince=now end
            return now-preferenceSince<cfg.readiness_wait_ms
        end
        local function stable_for_continuity()
            return cfg.idle_dps_after_heals and cfg.dps_enabled and healing_observation.complete and
                (not rows[1] or triage_band(rows[1],cfg)==2) and
                healing_observation.min_hp>math.max(cfg.critical_hp,cfg.emergency_hp,
                    cfg.self_survival_first and cfg.self_survival_hp or 0) and
                (not cfg.dps_in_combat_only or options.inCombat==true)
        end
        local function why(name,reason)
            if name=="Advanced Medical Probe" then amp_rejection=reason end
            if #reasons<8 then reasons[#reasons+1]=name.."="..tostring(reason) end
        end
        local function metadata(name)
            if cache[name] then return cache[name] end
            local spec=Ability[name]
            if not spec or not learned(loadout,name) then return nil,"not_learned" end
            local info=Mirror.call(CurrentLoadout,"info",name)
            if type(info)~="table" or type(info.ability_handle)~="string" then return nil,"metadata_unavailable" end
            if info.on_bar~=true then return nil,"not_on_quickbar" end
            local cost
            if info.has_resource_cost==true then
                if not finite(info.resource_cost) or info.resource_cost<0 then return nil,"invalid_resource_cost" end
                cost=info.resource_cost
            elseif spec.intrinsicFree then
                cost=0 -- Med Shot / Hammer Shot are intrinsically free, not proc guesses.
            elseif spec.targetless then
                cost=0 -- These named defensive/resource cooldowns spend no energy; native admission owns their other requirements.
            else return nil,"resource_cost_unavailable" end
            if spec.channelCost then
                if not energy_known then return nil,"energy_unavailable" end
                cost=math.max(cost,spec.channelCost*resource.max/100)
            end
            if free_cell==true then cost=0 end
            local row={info=info,cost=cost,spec=spec}
            cache[name]=row
            return row
        end
        local function movable(name, spec)
            if not spec.cast and not spec.channel then return true end
            if name=="Advanced Medical Probe" and running_restoration==true then return true end
            if spec.cast and (instant or (name=="Advanced Medical Probe" and emergency_response==true)) then return true end
            -- Frontline Medic collides with a baseline passive display name.
            -- Delegate Treatment movement to Core admission; true here only
            -- allows that check, never authorizes the cast or assumes a talent.
            if name=="Successive Treatment" then return true end
            if name=="Full Auto" and learned(loadout,"Forced March") then return true end
            return finite(speed) and math.abs(speed)<=0.001
        end
        local supercharge_plan,stack_builder_plan
        local function try(name,row,reason,floor,resume_native,resume_since)
            local key=name..":"..(row and row.handle or "none")
            if attempted[key] then return false end
            attempted[key]=true
            if row and skips[row.handle] then return false end
            local meta,err=metadata(name)
            if not meta then why(name,err); return false end
            if name=="Adrenaline Rush" and adrenalineFailure then
                why(name,"condition_failed_wait_state_change");return false
            end
            local instant_required=meta.spec.cast and
                (instant or (name=="Advanced Medical Probe" and emergency_response==true)) or false
            if reason=="amp_stack_completion" or reason=="sc4_stack_builder" then
                local builder,recipient,builder_reason=stack_builder_plan()
                if builder~=name or builder_reason~=reason or not recipient or not row or recipient.handle~=row.handle then
                    why(name,reason.."_changed");return false
                end
            end
            if reason=="amp_before_cell_reset" and not (cfg.supercharge and supercharge_stacks==10 and support==false and
                meta.info.has_cooldown_remaining==true and meta.info.cooldown_remaining==0 and metadata("Supercharged Kolto Cell")) then
                why(name,"cell_reset_preparation_changed");return false
            end
            local cell_plan
            if reason=="self_survival_kolto" and not self_kolto_needed(row,cfg) then
                why(name,"self_kolto_disabled_or_survival_resolved");return false
            end
            if name=="Supercharged Kolto Cell" then
                local plan,why_not=supercharge_plan(resume_native==true)
                if not plan then why(name,why_not);return false end
                cell_plan=plan
                reason="amp_window_"..plan.reason.."_hp_"..string.format("%.1f",plan.row.hp)
            end
            if nativeIntent and nativeIntent.name==name and nativeIntent.target==(row and row.handle or "none") and
                nativeIntent.ability==meta.info.ability_handle then
                resume_native=true;resume_since=nativeIntent.since
            end
            if not meta.spec.damage and not meta.spec.targetless and row and name~="Trauma Probe" then
                local limit=healing_limit(name,cfg,row.isSelf)
                if reason=="maintenance_topoff_to_dps_floor" then limit=math.max(limit,cfg.dps_min_hp) end
                if not healing_needed(row,cfg,limit) then why(name,"no_meaningful_heal_need");return false end
                if name=="Advanced Medical Probe" and not instant and emergency_response~=true and support~=true and
                    not (cellFollow and cellFollow.proven and reason=="supercharged_advanced_probe") and
                    reason~="amp_before_cell_reset" and
                    triage_band(row,cfg)>=2 and not (row.isSelf and cfg.self_survival_first and row.hp<cfg.self_survival_hp) then
                    why(name,"amp_reserved_for_burst_or_instant");return false
                end
            end
            if meta.spec.damage then
                if continuityDps then
                    if name~="Hammer Shot" or not stable_for_continuity() then return false end
                elseif #rows>0 or not healing_observation.complete then why(name,"healing_not_clear");return false end
                if not row or method(row.unit,"reaction")~="hostile" or
                    method(world.current_target,"handle")~=row.handle then why(name,"selected_hostile_changed");return false end
                if not meta.spec.intrinsicFree then
                    if cfg.dps_free_only then why(name,"free_attacks_only");return false end
                    if cfg.dps_preserve_procs and free_cell~=false then why(name,"healing_free_cell_reserved_or_unknown");return false end
                    if cfg.dps_preserve_procs and meta.spec.cast and
                        (override~=false or override_double~=false) then why(name,"healing_instant_reserved_or_unknown");return false end
                end
            end
            if not movable(name,meta.spec) then why(name,"moving_or_movement_unknown"); return false end
            if not meta.spec.offGcd and gcd>0 then return false end
            if meta.cost>0 and (not energy_known or resource.current<meta.cost or
                (resource.current-meta.cost)/resource.max*100<(floor or cfg.energy_floor)) then
                why(name,"energy_reserve"); return false
            end
            local target=not meta.spec.targetless and row and row.unit or nil
            if not meta.spec.targetless and not target then return false end
            local handle=row and row.handle or "none"
            local explicit_target=not meta.spec.targetless and not meta.spec.damage
            -- Healing must keep the immutable exact-target contract. Damage has
            -- already proven the hostile is the selected target, so use omitted
            -- selected-target semantics and avoid unnecessary target leases while
            -- mobs die or the client clears combat selection.
            local cast_target=explicit_target and target or nil
            local advice
            if not resume_native then advice=Mirror.call(CurrentLoadout,"can_cast",name,cast_target) end
            if not resume_native and (type(advice)~="table" or advice.ok~=true) then
                local denied=type(advice)=="table" and advice.reason or "admission_unavailable"
                why(name,denied)
                if (denied=="castability_pending" or denied=="ability_submission_pending" or
                    denied=="explicit_target_sync_pending") and not meta.spec.damage and not meta.spec.offGcd and
                    ((name~="Med Shot" and name~="Trauma Probe") or (row and triage_band(row,cfg)<2)) then
                    strongPending=preference_pending() or strongPending
                end
                if row and (denied=="target_view_blocked" or denied=="target_dead" or denied=="target_unavailable" or
                    denied=="target_out_of_range" or denied=="out_of_range") then skips[row.handle]=true end
                return false
            end
            if not resume_native and meta.spec.damage then
                if advice.target_mode~="selected" or advice.target_valid~=true or
                    advice.target_handle~=handle or advice.fallback_used==true or advice.target_override==true then
                    why(name,"selected_target_admission_mismatch"); return false
                end
            elseif not resume_native and explicit_target and (advice.target_mode~="explicit" or advice.target_valid~=true or
                advice.requested_target_handle~=handle or advice.target_handle~=handle or advice.fallback_used==true) then
                why(name,"explicit_target_admission_mismatch"); return false
            elseif not resume_native and meta.spec.targetless and advice.target_mode~="none" then
                why(name,"targetless_admission_mismatch"); return false
            end
            local submit_options={idempotencyKey=OWNER..name..":"..handle}
            if explicit_target then submit_options.target_fallback="none" end
            local priority=rows[1]
            local separation=meta.spec.groupRadius and row and priority and distance(row.position,priority.position)
            -- Same contract as Seer: snapshot only effects proven present immediately
            -- before submission, then attach those markers only if Core accepts it.
            local proc_markers=type(options.onAction)=="function" and
                action_proc_markers(loadout,player,name) or nil
            local result=executor:submit(Mirror.ability(CurrentLoadout,name),cast_target,submit_options)
            if type(result)=="table" and result.admission_pending==true then
                local since=resume_since or now
                if not resume_native or now-since<cfg.readiness_wait_ms or
                    (name=="Advanced Medical Probe" and reason=="supercharged_advanced_probe" and
                        (cellFollow or support==true)) then
                    nativeIntent={name=name,target=handle,decision=reason,floor=floor,since=since,
                        priority_target=priority and priority.handle,priority_band=priority and triage_band(priority,cfg),
                        priority_covered=separation and separation<=meta.spec.groupRadius,
                        instant_required=instant_required,ability=meta.info.ability_handle,damage=meta.spec.damage==true}
                    diagnostic("native admission pending: ability="..name.." target="..handle..
                        " waited_ms="..tostring(now-since))
                    return true -- Decision retained; no command/activation is claimed.
                end
                why(name,"native_admission_budget_elapsed")
                return false
            end
            if type(result)=="table" and result.accepted==true then
                if name=="Adrenaline Rush" then
                    adrenalineAttempt={command=result.command_handle,context=adrenaline_context(player,loadout)}
                end
                if cell_plan and result.core.target_mode=="none" then
                    -- Submission is not activation. Reserve AMP while the
                    -- existing receipt/effect snapshots catch up; never fake a reset.
                    cellFollow={command=result.command_handle,proven=false,
                        player=currentPlayer,epoch=world.actor_epoch}
                end
                nativeIntent,preferenceSince=nil,nil
                pending={name=name,target=handle,command=result.command_handle,phase=meta.spec.damage and "dps" or "healing",decision=reason,
                    priority_target=priority and priority.handle,priority_band=priority and triage_band(priority,cfg),
                    priority_covered=separation and separation<=meta.spec.groupRadius,
                    guard_min_hp=healing_observation.min_hp,instant_required=instant_required}
                local action_contract_ok=true
                if meta.spec.damage then
                    if result.core.target_mode~="selected" or result.core.target_valid~=true or
                        result.core.target_handle~=handle or result.core.fallback_used==true or result.core.target_override==true then
                        action_contract_ok=false
                        emit("warn","combat medic selected-target result mismatch: "..name)
                        if owns_pending() then executor:cancel("combat_medic_target_contract") end
                    elseif options.castLog~=false then
                        emit("info","combat medic cast queued: ability="..name.." target="..handle..
                            " hp="..(row and string.format("%.1f",row.hp) or "self").." reason="..reason..
                            " phase="..pending.phase)
                    end
                elseif explicit_target and (result.core.target_mode~="explicit" or result.core.target_valid~=true or
                    result.core.requested_target_handle~=handle or result.core.target_handle~=handle or result.core.fallback_used==true) then
                    action_contract_ok=false
                    emit("warn","combat medic explicit-target result mismatch: "..name)
                    if owns_pending() then executor:cancel("combat_medic_target_contract") end
                elseif meta.spec.targetless and result.core.target_mode~="none" then
                    action_contract_ok=false
                    emit("warn","combat medic targetless result mismatch: "..name)
                    if owns_pending() then executor:cancel("combat_medic_target_contract") end
                elseif options.castLog~=false then
                    emit("info","combat medic cast queued: ability="..name.." target="..handle..
                        " hp="..(row and string.format("%.1f",row.hp) or "self").." reason="..reason..
                        " phase="..pending.phase..(cell_plan and " amp_target="..cell_plan.row.handle or "")..
                        (reason=="amp_stack_completion" and (" stacks="..supercharge_stacks.."->10 amp_cd="..
                            tostring(cache["Advanced Medical Probe"].info.cooldown_remaining)) or "")..
                        (reason=="sc4_stack_builder" and (" sc4=observed effect="..tostring(sc4_key)..
                            " stacks="..tostring(supercharge_stacks).." deficit="..tostring(10-supercharge_stacks)..
                            " channel_credit=observed_only") or "")..(row and
                            (" health="..string.format("%.0f/%.0f",row.current,row.maximum)..
                            " triage="..TriageNames[triage_band(row,cfg)+1]..
                            " reserve="..tostring(floor or cfg.energy_floor)..
                            (pressure_urgency(row,cfg)~=nil and string.format(" idf_risk=%d p2=%.1f%% ttd=%.2fs",
                                row.pressure.risk_band,row.pressure.projected_hp_2s*100,row.pressure.ttd) or "")) or ""))
                end
                if action_contract_ok and type(options.onAction)=="function" then
                    local action_meta={category=meta.spec.damage and "dps" or nil}
                    if type(proc_markers)=="table" and #proc_markers>0 then
                        action_meta.procs=proc_markers
                    end
                    options.onAction({
                        ability=name, decision=reason, command_handle=result.command_handle,
                        target_handle=handle,
                        target_name=row and row.unit and method(row.unit,"name") or nil,
                        target_type=row and row.unit and method(row.unit,"type") or
                            (meta.spec.targetless and "none" or "unknown"),
                        untargeted=meta.spec.targetless==true,
                        meta=action_meta,
                    })
                end
                return true
            end
            why(name,type(result)=="table" and result.reason or "cast_result_unavailable")
            return executor:owns_command()
        end
        local function reserve_for(row) return healing_reserve(row,cfg) end
        local function try_cleanse(tier)
            return type(options.tryCleanseTier)=="function" and
                options.tryCleanseTier(tier)==true
        end
        local function life_saving_target(row)
            return row and (row.hp<=LIFE_SAVING_HP_PERCENT or
                pressure_urgency(row,cfg)==0)
        end
        local function try_life_saving(row)
            if not life_saving_target(row) then return false end
            local floor=cfg.emergency_floor
            if try("Bacta Infusion",row,"life_saving_bacta",floor) then return true end
            if (instant or emergency_response==true) and
                try("Advanced Medical Probe",row,"life_saving_instant_advanced_probe",floor) then return true end
            if instant and try("Medical Probe",row,"life_saving_instant_medical_probe",floor) then return true end
            if cfg.tech_override and not instant and emergency_response~=true then
                local probe=metadata("Advanced Medical Probe") or metadata("Medical Probe")
                if probe and (probe.cost<=0 or (energy_known and resource.current>=probe.cost)) and
                    try("Tech Override",nil,"life_saving_tech_override",0) then return true end
            end
            if cfg.group_heals and try("Kolto Bomb",row,"life_saving_kolto_bomb",floor) then return true end
            if try("Advanced Medical Probe",row,"life_saving_advanced_probe",floor) then return true end
            if try("Successive Treatment",row,"life_saving_successive_treatment",floor) then return true end
            if try("Medical Probe",row,"life_saving_medical_probe",floor) then return true end
            if strongPending then
                diagnostic("life-saving target awaiting high-priority castability: target="..
                    tostring(row.handle).." hp="..string.format("%.1f",row.hp))
                return true
            end
            return false
        end
        local function each(name,max_hp,reason,filter)
            for _,row in ipairs(rows) do
                if healing_needed(row,cfg,max_hp) and (not filter or filter(row)) then
                    if try(name,row,reason,reserve_for(row)) then return true end
                end
            end
            return false
        end

        local self_hp=hp.current/hp.max*100
        local self_pressure=cfg.self_survival_first and self_hp<cfg.self_survival_hp
        local hard_self=self_first(rows,self_hp,cfg)
        local amp_advice={}
        local function amp_target_advice(recipient)
            local advice=amp_advice[recipient.handle]
            if advice==nil then
                advice=Mirror.call(CurrentLoadout,"can_cast","Advanced Medical Probe",recipient.unit)
                amp_advice[recipient.handle]=type(advice)=="table" and advice or false
            end
            if type(advice)~="table" then return nil,"amp_admission_unavailable" end
            if advice.target_mode~="explicit" or advice.target_valid~=true or
                advice.target_handle~=recipient.handle or advice.requested_target_handle~=recipient.handle or
                advice.fallback_used==true then return nil,"amp_target_not_validated" end
            return advice
        end
        supercharge_plan=function(resuming)
            if not cfg.supercharge then return nil,"disabled" end
            if cellFollow then return nil,"cell_handoff_or_window_owned" end
            if supercharge_stacks~=10 then return nil,"ten_stacks_not_observed" end
            if support~=false then return nil,"support_active_or_unknown" end
            if gcd>0 then return nil,"wait_for_open_healing_gcd" end
            local amp,why_not=metadata("Advanced Medical Probe")
            if not amp then return nil,"amp_"..tostring(why_not) end
            local reset=amp_on_cooldown(amp.info)
            local recipient,reason,count=supercharge_demand(rows,cfg,hard_self,reset)
            if not recipient then
                recipient=refund_recipient(rows,cfg,hard_self,resource,amp.cost,amp.info)
                if recipient then reason,count="refund_funds_amp",1 end
            end
            if not recipient then return nil,"no_meaningful_amp_window" end
            if not movable("Advanced Medical Probe",amp.spec) then return nil,"amp_cannot_cast_while_moving" end
            if not energy_known then return nil,"energy_unavailable" end
            -- Planning only: the authored ten-cell refund can fund the next AMP.
            -- Do not mutate observed energy, assume a discount, or bypass native
            -- admission when the actual AMP is subsequently submitted.
            local after_refund=math.min(resource.max,resource.current+10)
            local reserve=reserve_for(recipient)
            if recipient.isSelf and hard_self then
                reserve=math.min(healing_reserve(recipient,cfg),cfg.critical_floor)
            end
            if after_refund<amp.cost or (after_refund-amp.cost)/resource.max*100<reserve then
                return nil,"insufficient_energy_for_amp_window"
            end
            local advice,advice_error=amp_target_advice(recipient)
            if not advice then return nil,advice_error end
            -- Retain an already-planned native cell request across an ephemeral
            -- advisory gap, but drop it on any fresh definite AMP rejection.
            local advisory_refresh=resuming and (advice.reason=="castability_pending" or
                advice.reason=="ability_submission_pending" or advice.reason=="explicit_target_sync_pending")
            if advice.ok~=true and advice.reason~="cooldown" and advice.reason~="insufficient_resource" and
                not advisory_refresh then
                return nil,"amp_"..tostring(advice.reason)
            end
            return {row=recipient,reason=reason,count=count}
        end
        stack_builder_plan=function()
            if not cfg.supercharge or support~=false or gcd>0 or hard_self or not healing_observation.complete then return nil,nil,"scheduler_guard" end
            local recipient=rows[1]
            if not recipient or triage_band(recipient,cfg)<2 or recipient.hp>cfg.focused_hp or skips[recipient.handle] then return nil,nil,"recipient_not_routine_or_needed" end
            local name,reason
            if supercharge_stacks==8 and learned(loadout,"Potent Medicine") then
                if recipient.hp>cfg.direct_hp and not cfg.medical_probe_bridge then return nil,nil,"probe_bridge_disabled" end
                name,reason="Medical Probe","amp_stack_completion"
            elseif supercharge_stacks==9 and recipient.hp>cfg.direct_hp then
                name,reason="Med Shot","amp_stack_completion"
            elseif sc4==true and type(supercharge_stacks)=="number" and
                supercharge_stacks>=6 and supercharge_stacks<=8 then
                -- SC-4 can supply the current 2-4 stack deficit during a useful
                -- Treatment channel. The plan never credits those stacks early.
                name,reason="Successive Treatment","sc4_stack_builder"
            else return nil,nil,"no_single_builder" end
            local amp=metadata("Advanced Medical Probe")
            local builder=metadata(name)
            if not amp or not amp_on_cooldown(amp.info) or not builder or not metadata("Supercharged Kolto Cell") or
                not movable("Advanced Medical Probe",amp.spec) or not movable(name,builder.spec) or not energy_known then return nil,nil,"ability_cooldown_mobility_or_energy_unknown" end
            -- Budget both actions using observed costs and the authored Cell
            -- refund. No predicted regeneration, crit refund, SC-4 stack credit,
            -- or extra Field Triage discount is used for admission.
            local after_refund=math.min(resource.max,resource.current-builder.cost+10)
            if after_refund<amp.cost or (after_refund-amp.cost)/resource.max*100<reserve_for(recipient) then return nil,nil,"followup_energy_budget" end
            local advice=amp_target_advice(recipient)
            if not advice or (advice.ok~=true and advice.reason~="cooldown" and advice.reason~="insufficient_resource") then return nil,nil,"amp_native_admission" end
            return name,recipient,reason
        end
        local shield_active=effect(player,Effect.ReactiveShield)
        local adrenaline_armed=effect(player,Effect.AdrenalineFiredUp)
        local adrenaline_active=effect(player,Effect.AdrenalineMaintaining)
        local echoing_active=effect(player,Effect.EchoingDeterrence)
        -- Stagger defenses normally. Active regeneration is not sufficient
        -- protection when the observed HP is still below the emergency boundary.
        local regen_cover=adrenaline_active==true and self_hp>cfg.emergency_hp
        if cfg.echoing and self_hp<=35 and echoing_active~=true and shield_active~=true and
            not regen_cover and try("Echoing Deterrence",nil,"emergency_self_reflect",0) then return true end
        local shield_trigger=self_pressure and cfg.self_survival_hp or cfg.shield_hp
        if cfg.shield and self_hp<=shield_trigger and shield_active~=true and echoing_active~=true and
            not regen_cover and try("Reactive Shield",nil,"self_survival_shield",0) then return true end
        local adrenal_hp=learned(loadout,"Adrenal Surge") and 60 or 35
        if self_pressure then adrenal_hp=math.max(adrenal_hp,cfg.self_survival_hp) end
        if cfg.adrenaline and self_hp<=adrenal_hp and adrenaline_armed~=true and adrenaline_active~=true and
            shield_active~=true and echoing_active~=true and
            try("Adrenaline Rush",nil,"self_survival_adrenaline",0) then return true end

        local function resume_native_intent()
            -- Core live admission has one request identity. Finish that exact
            -- candidate first instead of replacing it with another request each tick.
            -- This is not a retained command; the native cast path revalidates all
            -- current conditions, and never uses an old advisory result as permission.
            if nativeIntent then
                local intent=nativeIntent; nativeIntent=nil
                local candidate,needed=nil,false
                if intent.damage then
                    candidate=selected_hostile(world)
                    needed=candidate and candidate.handle==intent.target and cfg.dps_enabled and
                        (not cfg.dps_in_combat_only or options.inCombat==true)
                    if intent.decision=="unusable_heals_free_dps" then
                        needed=needed and stable_for_continuity()
                    else
                        needed=needed and #rows==0 and healing_observation.complete and
                            healing_observation.min_hp>=math.max(cfg.heal_start,cfg.dps_min_hp)
                    end
                elseif intent.target~="none" then
                    candidate=fresh_friendly(world,intent.target,cfg,rows)
                    needed=candidate~=nil and not urgent_preempts(candidate,rows,self_hp,cfg,intent.name,intent)
                    if needed and intent.instant_required then
                        local _,instant_now=probe_permission(player,intent.name)
                        needed=instant_now
                    end
                    if intent.name=="Trauma Probe" then needed=needed and cfg.trauma and trauma_due(candidate and candidate.unit,cfg) end
                elseif intent.name=="Recharge Cells" then
                    needed=cfg.recharge and energy_known and energy_percent<=cfg.recharge_at
                elseif intent.name=="Supercharged Kolto Cell" then
                    needed=supercharge_plan(true)~=nil
                elseif intent.name=="Tech Override" then
                    needed=cfg.tech_override and #rows>0 and not instant and emergency_response~=true
                elseif intent.name=="Reactive Shield" then
                    needed=cfg.shield and self_hp<=shield_trigger and shield_active~=true and echoing_active~=true and not regen_cover
                elseif intent.name=="Adrenaline Rush" then
                    needed=cfg.adrenaline and self_hp<=adrenal_hp and adrenaline_armed~=true and adrenaline_active~=true and
                        shield_active~=true and echoing_active~=true
                elseif intent.name=="Echoing Deterrence" then
                    needed=cfg.echoing and self_hp<=35 and echoing_active~=true and shield_active~=true and not regen_cover
                end
                local current_meta=metadata(intent.name)
                if needed and current_meta and current_meta.info.ability_handle==intent.ability then
                    continuityDps=intent.decision=="unusable_heals_free_dps"
                    local current_floor=intent.floor
                    if candidate and not intent.damage and intent.name~="Trauma Probe" then
                        current_floor=reserve_for(candidate)
                        if candidate.isSelf and hard_self then
                            current_floor=math.min(healing_reserve(candidate,cfg),cfg.critical_floor)
                        end
                        if intent.decision=="maintenance_topoff_to_dps_floor" then current_floor=0 end
                    elseif intent.damage then current_floor=math.max(cfg.energy_floor,cfg.dps_energy_floor) end
                    local consumed=try(intent.name,candidate,intent.decision,current_floor,true,intent.since)
                    continuityDps=false
                    if consumed then return true end
                end
            end
            return false
        end
        -- Unsubmitted filler may not jump ahead of a live Cell handoff.
        if not (cellFollow or support==true) and resume_native_intent() then return true end
        local function continuity_action()
            if strongPending or not stable_for_continuity() or gcd>0 then return false end
            local hostile=selected_hostile(world)
            if not hostile then return false end
            continuityDps=true
            local consumed=try("Hammer Shot",hostile,"unusable_heals_free_dps",cfg.dps_energy_floor)
            continuityDps=false
            return consumed
        end

        -- A new imminent-death decision gets instant rescue before the Cell
        -- hardcast preference. Running Restoration is mobile, not instant.
        local rescue_priority=rows[1]
        if hard_self then
            -- Keep the user's own-emergency priority in the early rescue lane,
            -- not only in the later ordinary healing branches.
            rescue_priority=nil
            for _,row in ipairs(rows) do if row.isSelf then rescue_priority=row;break end end
        end
        local life_saving=rescue_priority and life_saving_target(rescue_priority) and rescue_priority or nil
        if life_saving and try_life_saving(life_saving) then return true end

        -- Cell's exact submission and observed effect own the AMP preference.
        -- A 150ms readiness budget must not turn a delayed reset into a filler
        -- GCD. Native admission still decides whether an AMP can actually cast.
        if cellFollow or support==true then
            local recipient=supercharge_demand(rows,cfg,hard_self,true)
            if not recipient then cellFollow=nil
            elseif gcd>0 then return true
            else
                local wait_reason
                if not movable("Advanced Medical Probe",Ability["Advanced Medical Probe"]) then
                    diagnostic("Cell window yielded: AMP moving or movement unknown")
                elseif cellFollow and not cellFollow.proven and support~=true then
                    wait_reason="cell_activation_or_effect_pending"
                else
                    local reserve=reserve_for(recipient)
                    if recipient.isSelf and hard_self then
                        reserve=math.min(healing_reserve(recipient,cfg),cfg.critical_floor)
                    end
                    if try("Advanced Medical Probe",recipient,"supercharged_advanced_probe",reserve) then return true end
                    local refreshing=amp_rejection=="castability_pending" or amp_rejection=="castability_unavailable" or
                        amp_rejection=="cooldown" or amp_rejection=="ability_metadata_unavailable" or
                        amp_rejection=="metadata_unavailable" or amp_rejection=="resource_cost_unavailable" or
                        amp_rejection=="native_admission_budget_elapsed" or amp_rejection=="ability_submission_pending"
                    if refreshing then wait_reason=amp_rejection
                    else diagnostic("Cell window yielded: AMP="..tostring(amp_rejection)) end
                end
                if wait_reason then
                    -- Preserve real rescue/cleanse opportunities without allowing
                    -- routine Med Shot, hardcast Medical Probe or maintenance to
                    -- replace the pending reset. These casts do not release Cell.
                    if try_cleanse("must") then return true end
                    if triage_band(recipient,cfg)<2 then
                        local reserve=reserve_for(recipient)
                        if try("Bacta Infusion",recipient,"cell_wait_bacta_rescue",reserve) then return true end
                        if instant and try("Medical Probe",recipient,"cell_wait_instant_rescue",reserve) then return true end
                        if cfg.group_heals then
                            for _,center in ipairs(clusters(rows,Ability["Successive Treatment"].groupRadius,
                                math.max(4,cfg.successive_min),cfg.group_hp,skips,recipient)) do
                                if try("Successive Treatment",center.row,"cell_wait_group_rescue",reserve) then return true end
                            end
                        end
                        if life_saving_target(recipient) and
                            try("Med Shot",recipient,"cell_wait_emergency_free_heal",cfg.emergency_floor) then return true end
                    end
                    diagnostic("Cell AMP preference held: target="..recipient.handle.." reason="..wait_reason..
                        " support="..tostring(support).." activation_proven="..tostring(cellFollow and cellFollow.proven==true))
                    return true
                end
            end
        end
        if resume_native_intent() then return true end

        -- Scheduler shared with the other healers, adapted to Commando tools:
        -- imminent-death direct rescue -> must-cleanse -> emergency healing ->
        -- movement cleanse -> routine healing -> pressure cleanse -> DPS.

        if try_cleanse("must") then return true end

        if #rows==0 then
            if try_cleanse("movement") then return true end
            -- Recovery/protection are useful healing-lull actions, not DPS.
            if cfg.recover_before_dps and cfg.recharge and options.inCombat==true and
                energy_known and energy_percent<=cfg.recharge_at and
                try("Recharge Cells",nil,"healing_lull_recovery",0) then return true end
            if cfg.pre_trauma_incoming and cfg.trauma and gcd==0 and learned(loadout,"Trauma Probe") then
                for _,candidate in ipairs(incoming_trauma_targets(world,options.combatEvents,cfg)) do
                    if trauma_due(candidate.unit,cfg) and
                        try("Trauma Probe",candidate,"incoming_hostile_exact_target",cfg.energy_floor) then return true end
                end
            end
            if cfg.trauma_lull_roster and cfg.trauma and gcd==0 and learned(loadout,"Trauma Probe") then
                for _,candidate in ipairs(healing_observation.all or {}) do
                    if trauma_due(candidate.unit,cfg) and
                        try("Trauma Probe",candidate,"healing_lull_trauma_maintenance",cfg.energy_floor) then return true end
                end
            end
            if not healing_observation.complete then
                local failure=healing_observation.hp_failure
                local detail=failure and string.format(" actor=%s type=%s hp_available=%s current=%s max=%s",
                    tostring(failure.handle),tostring(failure.kind),tostring(failure.available),
                    tostring(failure.current),tostring(failure.maximum)) or ""
                diagnostic("DPS blocked: "..healing_observation.reason..detail);return true
            end
            local threshold=math.max(cfg.heal_start,cfg.dps_min_hp)
            if healing_observation.min_hp<threshold then
                if gcd>0 then return true end
                local topoff=healing_observation.lowest
                if topoff and topoff.hp<100 and
                    try("Med Shot",topoff,"maintenance_topoff_to_dps_floor",0) then return true end
                if topoff and cfg.trauma and learned(loadout,"Trauma Probe") and trauma_due(topoff.unit,cfg) and
                    try("Trauma Probe",topoff,"maintenance_topoff_trauma",cfg.energy_floor) then return true end
                if try_cleanse("pressure") then return true end
                if continuity_action() then return true end
                diagnostic("maintenance top-off blocked: hp="..
                    string.format("%.1f",healing_observation.min_hp).." target="..
                    tostring(topoff and topoff.handle or "none").." | "..table.concat(reasons,"; "))
                return true
            end
            if try_cleanse("pressure") then return true end
            if not cfg.dps_enabled then diagnostic("idle: no healing needed; DPS disabled");return true end
            if cfg.dps_in_combat_only and options.inCombat~=true then diagnostic("DPS blocked: not in observed combat");return true end
            if gcd>0 then return true end
            local hostile,target_reason=selected_hostile(world)
            if not hostile then diagnostic("DPS idle: "..target_reason);return true end
            local reserve=math.max(cfg.energy_floor,cfg.dps_energy_floor)
            if not cfg.dps_free_only then
                if cfg.dps_electro_net and try("Electro Net",hostile,"idle_dps_electro_net",reserve) then return true end
                if cfg.dps_hib and try("High Impact Bolt",hostile,"idle_dps_high_impact_bolt",reserve) then return true end
                if cfg.dps_full_auto and try("Full Auto",hostile,"idle_dps_full_auto",reserve) then return true end
                if cfg.dps_charged_bolts and try("Charged Bolts",hostile,"idle_dps_charged_bolts",reserve) then return true end
            end
            if try("Hammer Shot",hostile,"idle_dps_free_filler",reserve) then return true end
            diagnostic("DPS no legal attack | "..table.concat(reasons,"; "));return true
        end
        -- A ready direct rescue gets first refusal; otherwise a useful cell
        -- reset remains available while the healer is in danger.
        if hard_self then
            local urgent_self=fresh_friendly(world,method(player,"handle"),cfg,rows)
            local reserve=self_hp<=cfg.emergency_hp and cfg.emergency_floor or cfg.critical_floor
            if urgent_self and try("Bacta Infusion",urgent_self,"self_survival_bacta",reserve) then return true end
            if urgent_self and (instant or emergency_response==true or support==true) and
                try("Advanced Medical Probe",urgent_self,"self_survival_advanced_probe",reserve) then return true end
            if urgent_self and instant and
                try("Medical Probe",urgent_self,"self_survival_instant_medical_probe",reserve) then return true end
        end
        if supercharge_stacks==10 and cfg.supercharge and support==false then
            -- Use an actually ready AMP before spending its reset. If healing
            -- is still needed when its real cooldown appears, Cell can reset it.
            local amp=metadata("Advanced Medical Probe")
            if amp and amp.info.has_cooldown_remaining==true and amp.info.cooldown_remaining==0 and
                metadata("Supercharged Kolto Cell") then
                local recipient=supercharge_demand(rows,cfg,hard_self,true)
                local reserve=reserve_for(recipient)
                if recipient and recipient.isSelf and hard_self then
                    reserve=math.min(healing_reserve(recipient,cfg),cfg.critical_floor)
                end
                if recipient and try("Advanced Medical Probe",recipient,"amp_before_cell_reset",reserve) then return true end
            end
            if try("Supercharged Kolto Cell",nil,"amp_burst_window",0) then return true end
        end
        if cfg.recharge and energy_known and energy_percent<=cfg.recharge_at and
            try("Recharge Cells",nil,"low_energy",0) then return true end

        -- Own emergencies retain first refusal. Less severe self pressure must
        -- not monopolize healing while a more urgent critical ally is dying.
        local self_row=fresh_friendly(world,method(player,"handle"),cfg,rows)
        if hard_self and self_row then
            local floor=self_hp<=cfg.emergency_hp and cfg.emergency_floor or cfg.critical_floor
            if try("Bacta Infusion",self_row,"self_survival_bacta",floor) then return true end
            local survival_amp=metadata("Advanced Medical Probe")
            if survival_amp and (support==true or emergency_response==true or instant or survival_amp.cost==0) and
                try("Advanced Medical Probe",self_row,"self_survival_advanced_probe",floor) then return true end
            if cfg.tech_override and not instant and emergency_response~=true then
                local probe=survival_amp or metadata("Medical Probe")
                if probe and (probe.cost<=0 or (energy_known and resource.current>=probe.cost)) and
                    try("Tech Override",nil,"self_survival_tech_override",0) then return true end
            end
            -- The fatal capture lost both channels and repeatedly used Med Shot
            -- while moving. Self rescue does not require a second injured ally.
            if self_kolto_needed(self_row,cfg) and
                (self_hp<=cfg.emergency_hp or not movable("Medical Probe",Ability["Medical Probe"])) and
                try("Kolto Bomb",self_row,"self_survival_kolto",floor) then return true end
            if try("Advanced Medical Probe",self_row,"self_survival_unprocced_advanced_probe",floor) then return true end
            if try("Successive Treatment",self_row,"self_survival_successive_treatment",floor) then return true end
            if try("Medical Probe",self_row,"self_survival_medical_probe",floor) then return true end
            if self_kolto_needed(self_row,cfg) and
                try("Kolto Bomb",self_row,"self_survival_kolto",floor) then return true end
            if strongPending then
                diagnostic("self-survival awaiting high-priority admission: hp="..string.format("%.1f",self_hp))
                return true
            end
            if cfg.trauma and learned(loadout,"Trauma Probe") and trauma_due(self_row.unit,cfg) and
                try("Trauma Probe",self_row,"self_survival_trauma",floor) then return true end
            if try("Med Shot",self_row,"self_survival_free_med_shot",0) then return true end
            if strongPending then diagnostic("self-survival awaiting rescue castability");return true end
            diagnostic("self-survival first refusal blocked: hp="..string.format("%.1f",self_hp)..
                " threshold="..tostring(cfg.self_survival_hp).." | "..table.concat(reasons,"; "))
        end
        if gcd>0 then return true end
        local urgent=rows[1] and triage_band(rows[1],cfg)<2 and rows[1] or nil
        local emergency=urgent and triage_band(urgent,cfg)==0
        if emergency_response==true and type(bactaFollowTarget)=="string" then
            local follow=fresh_friendly(world,bactaFollowTarget,cfg,rows)
            if follow and follow.hp<100 and rows[1] and rows[1].handle==follow.handle then
                local reserve=reserve_for(follow)
                if try("Advanced Medical Probe",follow,"bacta_emergency_response_followup",reserve) then return true end
            elseif not follow or follow.hp>=100 then
                bactaFollowTarget=nil
            end
        end
        local function group_heal(high_value,required)
            if not cfg.group_heals then return false end
            local minimum=high_value and 4 or 2
            for _,center in ipairs(clusters(rows,Ability["Successive Treatment"].groupRadius,math.max(minimum,cfg.successive_min),cfg.group_hp,skips,required)) do
                local reason=required and "critical_group_cover_" or (high_value and "high_value_group_successive_" or "group_successive_")
                local reserve=required and reserve_for(required) or reserve_for(center.row)
                if try("Successive Treatment",center.row,reason..center.count,reserve) then return true end
            end
            for _,center in ipairs(clusters(rows,Ability["Kolto Bomb"].groupRadius,math.max(minimum,cfg.kolto_min),cfg.group_hp,skips,required)) do
                local reason=required and "critical_group_cover_" or (high_value and "high_value_group_kolto_" or "group_kolto_")
                local reserve=required and reserve_for(required) or reserve_for(center.row)
                if try("Kolto Bomb",center.row,reason..center.count,reserve) then return true end
            end
            return false
        end
        -- A four-plus injured cluster is higher total rescue value than a routine
        -- single-target critical heal, but only when the AoE actually covers the
        -- critical patient. True emergencies keep direct first refusal.
        if urgent and not emergency and group_heal(true,urgent) then return true end
        -- Finish the highest critical target's useful options before trying
        -- maintenance on healthier actors, including just above Emergency HP.
        if urgent then
            local prefix=triage_band(urgent,cfg)==0 and "emergency" or "critical"
            local reserve=reserve_for(urgent)
            if try("Bacta Infusion",urgent,prefix.."_bacta",reserve) then return true end
            if try("Advanced Medical Probe",urgent,prefix.."_advanced_probe",reserve) then return true end
            if cfg.tech_override and triage_band(urgent,cfg)==0 and not skips[urgent.handle] and
                not instant and emergency_response~=true then
                local probe=metadata("Advanced Medical Probe") or metadata("Medical Probe")
                if probe and (probe.cost<=0 or (energy_known and resource.current>=probe.cost)) and
                    try("Tech Override",nil,"emergency_instant_heal_setup",0) then return true end
            end
            if instant and try("Medical Probe",urgent,prefix.."_instant_medical_probe",reserve) then return true end
            if try("Successive Treatment",urgent,prefix.."_successive_treatment",reserve) then return true end
            if try("Medical Probe",urgent,prefix.."_medical_probe",reserve) then return true end
        end
        if strongPending then
            diagnostic("critical healing awaiting high-priority castability")
            return true
        end
        -- Emergency/critical direct burst above gets first refusal. Roots and
        -- other enabled movement controls now outrank fallback/maintenance heals.
        if try_cleanse("movement") then return true end
        if urgent then
            if group_heal(false,urgent) then return true end
            if cfg.trauma and trauma_due(urgent.unit,cfg) and
                try("Trauma Probe",urgent,"critical_trauma",reserve_for(urgent)) then return true end
            if try("Med Shot",urgent,"critical_free_heal",0) then return true end
            if strongPending then diagnostic("critical target awaiting rescue castability");return true end
            diagnostic("critical rescue unavailable: target="..urgent.handle.." hp="..string.format("%.1f",urgent.hp)..
                " | "..table.concat(reasons,"; "))
        end
        -- Four genuinely injured clustered allies outrank routine single heals.
        if not emergency and group_heal(true,nil) then return true end
        if cfg.proc_expiry>0 and emergency_response==true and type(emergency_observation)=="table" and
            emergency_observation.has_timer==true and finite(emergency_observation.remaining) and
            emergency_observation.remaining<=cfg.proc_expiry and
            each("Advanced Medical Probe",cfg.heal_start,"expiring_emergency_response") then return true end
        if each("Bacta Infusion",cfg.heal_start,"bacta_infusion") then return true end
        if (emergency_response==true or instant) and
            each("Advanced Medical Probe",cfg.heal_start,"observed_instant_advanced_probe") then return true end
        if not emergency and group_heal(false,nil) then return true end
        if each("Advanced Medical Probe",cfg.focused_hp,"advanced_probe") then return true end
        local builder,recipient,builder_reason=stack_builder_plan()
        if builder and try(builder,recipient,builder_reason,reserve_for(recipient)) then return true end
        if each("Successive Treatment",cfg.channel_hp,"single_target_pressure") then return true end
        if cfg.trauma and learned(loadout,"Trauma Probe") then
            for _,row in ipairs(rows) do
                if trauma_due(row.unit,cfg) and try("Trauma Probe",row,"trauma_probe_maintenance",cfg.energy_floor) then return true end
            end
        end
        if each("Medical Probe",cfg.direct_hp,"medical_probe_filler") then return true end
        if rows[1] and rows[1].hp<=cfg.critical_hp and strongPending then
            diagnostic("critical target awaiting high-priority castability")
            return true
        end
        if cfg.medical_probe_bridge and not strongPending and
            each("Medical Probe",cfg.focused_hp,"medical_probe_between_burst_heals") then return true end
        if each("Med Shot",cfg.heal_start,"free_heal_and_supercharge_builder") then return true end
        if try_cleanse("pressure") then return true end
        if continuity_action() then return true end
        diagnostic("no castable heal; injured="..#rows.." lowest="..string.format("%.1f",rows[1].hp)..
            " energy="..(energy_known and string.format("%.1f",energy_percent) or "unknown")..
            " | "..table.concat(reasons,"; "))
        return true
    end
    return {
        is_selected=is_selected, owns_pending=owns_pending, stop=stop, tick=tick,
        priority_state=priority_state,
        has_local_pending=function() return pending~=nil or nativeIntent~=nil or cellFollow~=nil end,
    }
end
return M
