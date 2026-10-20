-- commando.lua
-- Capability-driven Gunnery 1-80 plus shared Assault/Combat Medic routing.
-- Unlocks and all 24 tree choices come from current loadout.known, never level guesses.
-- One shared AbilityExecutor owns commands; Core owns cast/channel/GCD/admission.
-- Gunnery priorities (gear-agnostic):
--   Personal emergency defenses/heals; optional deliberate utility input.
--   Establish Gravity Vortex where needed, Vortex Bolt, observed Curtain of Fire
--   Boltstorm, Demolition Round, five-barrel HIB, Electro Net, ready Boltstorm,
--   instant/normal Grav Round, pre-Grav Charged Bolts, mobile Explosive, Hammer.
--   AoE: selected Thermonuclear setup/spread, Mortar, Thermonuclear Demo,
--   selected three-target Grav Trio, Hail, selected Sticky, normal priorities.
-- Full Auto is used only before Boltstorm is learned. No channel prequeue/clipping.
-- Instant Medical Probe requires an exact observed Tech Override or five barrels;
-- all heals use explicit self-target and no target fallback. No healthy overhealing.
-- Full channel costs are budgeted. A zero startup cost alone is not a free channel.
-- Instant-cast permissions use exact effects, not predicted timers. Mobility/long CC stays
-- manual/opt-in; passive talent effects remain owned by the game's engine.
-- See docs/COMMANDO_GUNNERY_1_80_20260911.md for coverage and simulation limitations.

local AbilityExecutor = require("combat.ability_executor")
local Mirror = require("commando.mirror")
local ActiveLoadout
local GunneryKit = require("commando.gunnery_kit")
local CommandoAssaultSpecialist = require("commando.assault_specialist")
local CommandoCombatMedic = require("commando.combat_medic")
local HealerActionWindow = require("ui.healer_action_window")

local SCRIPT_ID = "commando_gunnery_leveling_r1"
local BUILD_ID = "commando-mercenary-mirror-r1+2026-09-12-commando-multispec-v28-true-combat-opener+native-outcome-ssot+shared-cleanse-r3+stealth-extracted-r1+core-range-r1+cell-cast-guard-r1+effect-key-only-r1+dot-cast-boundary-r1+gunnery-l80-r1+combat-medic-cell-window-r15+combat-medic-cleanse-order-r1+combat-medic-actions-r2-procs+gunnery-admission-diag-r1+gunnery-admission-retry-r1+diagnostics-master-r1+personal-defaults-logging-off-r1-script-library-layout-r1-overlay-local-ids-r1+counterpart-recheck-20261019-r4"
local ExpectedCombatStyle = "commando"
local ExpectedDiscipline = "Gunnery"

-- Current production scripts convert captured CharacterNode units to gameplay
-- metres with this factor.
local METERS_PER_WORLD_UNIT = 10.0
local COOLDOWN_READY_SLACK = 0.04
local GROUND_START_SLACK = 0.04
local RECHARGE_RESCUE_FLOOR_PERCENT = 35.0
local FAILURE_BACKOFF_SECONDS = 0.25
local COMMAND_CONTENTION_BACKOFF_SECONDS = 0.12
local COMBAT_EVENT_PASSES = 4
local GRAVITY_VORTEX_PROOF_TTL = 44.0
local GRAV_PRIMER_PROOF_TTL = 11.5
local CHARGED_BARREL_PROOF_TTL = 14.5
local CHARGED_BARREL_REQUIRED = 5
local HIB_PVP_PREFERRED_BARRELS = 4
local HIB_PVP_PRESSURE_BARRELS = 2
local HIB_PVP_PRESSURE_HP_PERCENT = 50.0
local HIB_PVP_EXECUTE_HP_PERCENT = 25.0
local STICKY_GRENADE_MIN_TARGETS = 4

local Config = {
    abilityQueueWindow = 0.25,
    targetObservationGrace = 0.75,

    energyFloorPercent = 60.0,
    rechargeCellsThresholdPercent = 25.0,
    autoSuperchargedCell = true,
    autoRechargeCells = true,

    aoeEnabled = true,
    automaticTargetCount = true,
    manualRelevantTargets = 1,
    aoeMinTargets = 2,
    aoeClusterRadius = 5.0,
    movingExplosiveRound = true,
    hibPreferredBarrels = 4,
    hibPressureBarrels = 2,

    assaultIncendiaryRefreshSeconds = 1.5,
    assaultPriorityFloorPercent = 60.0,
    assaultFillerFloorPercent = 60.0,
    assaultRechargeThresholdPercent = 45.0,
    assaultAutoSuperchargedCell = true,
    assaultConsumeHyperAssault = true,
    assaultUseStickyGrenade = true,
    assaultUseElectroNet = false,
    assaultAutoSelfHeal = true,
    assaultBactaInfusionHpPercent = 45,
    assaultInstantMedicalProbeHpPercent = 55,
    assaultMedShotHpPercent = 25,
    assaultSelfHealEnergyFloorPercent = 10,
    autoEchoingDeterrence = false,
    echoingDeterrenceHpPercent = 35,

    autoReactiveShield = false,
    reactiveShieldHpPercent = 40,
    autoConcussionCharge = false,
    concussionChargeHpPercent = 50,
    concussionChargeMaxRange = 4.0,
    autoDiversion = false,
    diversionHpPercent = 50,
    autoAdrenalineRush = false,
    adrenalineRushHpPercent = 35,
    autoSuperchargedCelerity = false,

    diagnosticsLogging = false,
    castLog = false,
    decisionLog = false,
    abilityDiagnostics = false,
    abilityDiagnosticsInterval = 1.0,
}

local SettingsSchema = CommandoCombatMedic.settings(GunneryKit.settings(require("combat.cleanse").settings({
    title = "Commando / Mercenary",
    version = 28,
    activation = {
        mode = "hold",
        label = "Rotation Key",
        default = "mouse4",
    },
    fields = {
        {
            key = "ability_queue_window",
            type = "number",
            label = "Ability Queue Window",
            tooltip = "How early normal selected-target abilities may be queued before the current action lock ends. Ground-targeted channels still wait for a fully open lock.",
            default = 0.25,
            min = 0.05,
            max = 0.50,
            step = 0.01,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "energy_floor_percent",
            type = "int",
            label = "Energy Floor %",
            tooltip = "Paid attacks normally cannot leave the resource pool below this percentage. A ready Recharge Cells may permit one controlled dip.",
            default = 60,
            min = 35,
            max = 90,
            step = 1,
            disciplines = { "Gunnery" },
        },
        {
            key = "auto_supercharged_cell",
            type = "bool",
            label = "Auto High Velocity Supercharged Cell",
            tooltip = "Use High Velocity Supercharged Cell when ten Supercharge stacks are observed and its cooldown is ready.",
            default = true,
            requires_ability = "High Velocity Supercharged Cell",
            disciplines = { "Gunnery" },
        },
        {
            key = "auto_recharge_cells",
            type = "bool",
            label = "Auto Recharge Cells",
            tooltip = "Use Recharge Cells at or below the configured Energy threshold and let it fund the next paid attack.",
            default = true,
            requires_ability = "Recharge Cells",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "recharge_cells_threshold_percent",
            type = "int",
            label = "Recharge Cells At %",
            tooltip = "Use Recharge Cells when the resource pool is at or below this percentage. The route may spend down to 35% only when Recharge Cells is already available.",
            default = 25,
            min = 20,
            max = 60,
            step = 1,
            requires_ability = "Recharge Cells",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "aoe_enabled",
            type = "bool",
            label = "Automatic AoE",
            tooltip = "Allow the selected DPS discipline to use its configured area priority when enough relevant targets are present.",
            default = true,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "automatic_target_count",
            type = "bool",
            label = "Target-Centered Auto Count",
            tooltip = "Count live hostiles around the selected target. Falls back to the manual count when spatial data is unavailable.",
            default = true,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "manual_relevant_targets",
            type = "int",
            label = "Relevant Targets",
            tooltip = "Fallback target count when automatic target-centered counting is disabled or unavailable.",
            default = 1,
            min = 1,
            max = 8,
            step = 1,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "aoe_min_targets",
            type = "int",
            label = "AoE Minimum Targets",
            tooltip = "Minimum relevant hostiles before Mortar Volley, Hail of Bolts, and Plasma Grenade enter the priority.",
            default = 2,
            min = 2,
            max = 8,
            step = 1,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "aoe_cluster_radius",
            type = "number",
            label = "AoE Count Radius",
            tooltip = "Radius in gameplay metres around the selected target used for automatic target counting.",
            default = 5.0,
            min = 3.0,
            max = 8.0,
            step = 0.5,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "moving_explosive_round",
            type = "bool",
            label = "Explosive Round While Moving",
            tooltip = "Use Explosive Round as the paid mobile filler when Grav Round or Charged Bolts cannot be cast while moving.",
            default = true,
            requires_ability = "Explosive Round",
            disciplines = { "Gunnery" },
        },
        {
            key = "hib_preferred_barrels",
            type = "int",
            label = "HIB Normal Stacks",
            tooltip = "Normal Charged Barrel threshold for High Impact Bolt on healthy stationary targets. PvP default is 4; set 5 for maximum stacks or lower for more aggression.",
            default = 4,
            min = 0,
            max = 5,
            step = 1,
            requires_ability = "High Impact Bolt",
            disciplines = { "Gunnery" },
        },
        {
            key = "hib_pressure_barrels",
            type = "int",
            label = "HIB Pressure Stacks",
            tooltip = "Charged Barrel threshold for High Impact Bolt while moving or when the target is at or below 50% HP. Execute targets at 25% HP or lower still ignore stack requirements.",
            default = 2,
            min = 0,
            max = 5,
            step = 1,
            requires_ability = "High Impact Bolt",
            disciplines = { "Gunnery" },
        },
        {
            key = "assault_incendiary_refresh_seconds",
            type = "number",
            label = "AS: Incendiary Refresh (s)",
            tooltip = "Refresh Incendiary Round only when its remaining burn is at or below this window.",
            default = 1.5,
            min = 0.0,
            max = 4.0,
            step = 0.1,
            disciplines = { "Assault Specialist" },
            requires_ability = "Incendiary Round",
        },
        {
            key = "assault_priority_floor_percent",
            type = "int",
            label = "AS: Priority Reserve %",
            tooltip = "Minimum Energy remaining AFTER a paid priority ability. Observed free Ionic Accelerator Mag Bolt/HIB bypasses this budget; a usable automatic Recharge Cells permits controlled spending.",
            default = 60,
            min = 35,
            max = 80,
            step = 1,
            disciplines = { "Assault Specialist" },
        },
        {
            key = "assault_filler_reserve_percent",
            type = "int",
            label = "AS: Filler Reserve %",
            tooltip = "Ordinary paid fillers must leave this Energy reserve. Full Auto is budgeted for the complete channel, not its zero upfront cost.",
            default = 60,
            min = 35,
            max = 80,
            step = 1,
            disciplines = { "Assault Specialist" },
        },
        {
            key = "assault_recharge_cells_threshold_percent",
            type = "int",
            label = "AS: Recharge Below %",
            tooltip = "Assault-only Recharge Cells trigger; independent of Gunnery's saved recovery threshold. Requires Auto Recharge Cells.",
            default = 45,
            min = 20,
            max = 60,
            step = 1,
            disciplines = { "Assault Specialist" },
            requires_ability = "Recharge Cells",
        },
        {
            key = "assault_auto_supercharged_cell",
            type = "bool",
            label = "AS: Auto Supercharged Cell",
            tooltip = "Use Supercharged Cell at 10 Supercharge stacks after Incendiary Round is established on the selected target.",
            default = true,
            disciplines = { "Assault Specialist" },
            requires_ability = "Supercharged Cell",
        },
        {
            key = "assault_consume_hyper_assault",
            type = "bool",
            label = "AS: Use Hyper Assault Rounds",
            tooltip = "Consume the actually observed Hyper Assault Rounds buff with its empowered, discounted Explosive Round. Hyper Cinders increases proc opportunities through Incendiary Round; the route never invents HAR from talent selection alone.",
            default = true,
            disciplines = { "Assault Specialist" },
            requires_ability = "Explosive Round",
        },
        {
            key = "assault_use_sticky_grenade",
            type = "bool",
            label = "AS: Use Sticky Grenade",
            tooltip = "Use Sticky Grenade in the Assault AoE filler branch when that level-27 choice is selected.",
            default = true,
            disciplines = { "Assault Specialist" },
            requires_ability = "Sticky Grenade",
        },
        {
            key = "assault_use_electro_net",
            type = "bool",
            label = "AS: Use Electro Net",
            tooltip = "Use Electro Net as a long-cooldown damage GCD after DoT, Ionic Accelerator, Hyper Assault, and DoT-spread obligations. Disable this to keep Net fully player-owned in PvP.",
            default = false,
            disciplines = { "Assault Specialist" },
            requires_ability = "Electro Net",
        },
        {
            key = "assault_auto_self_heal",
            type = "bool",
            label = "AS: Defensive Self-Heal",
            tooltip = "Use Bacta Infusion first, reserve Tech Override for an instant Medical Probe, and use Med Shot only as a critical free fallback.",
            default = true,
            disciplines = { "Assault Specialist" },
        },
        {
            key = "assault_bacta_infusion_hp_percent",
            type = "int",
            label = "AS: Bacta Infusion HP %",
            tooltip = "Use Bacta Infusion on yourself at or below this HP percentage when Defensive Self-Heal is enabled.",
            default = 45,
            min = 10,
            max = 80,
            step = 1,
            disciplines = { "Assault Specialist" },
            requires_ability = "Bacta Infusion",
        },
        {
            key = "assault_instant_medical_probe_hp_percent",
            type = "int",
            label = "AS: Instant Medical Probe HP %",
            tooltip = "Below this HP, reserve Tech Override and spend its exact instant-cast proc on Medical Probe. The route never hard-casts Medical Probe.",
            default = 55,
            min = 10,
            max = 85,
            step = 1,
            disciplines = { "Assault Specialist" },
            requires_ability = "Medical Probe",
        },
        {
            key = "assault_med_shot_hp_percent",
            type = "int",
            label = "AS: Med Shot Fallback HP %",
            tooltip = "Use the free Med Shot only at critically low HP when stronger self-heals are unavailable.",
            default = 25,
            min = 5,
            max = 60,
            step = 1,
            disciplines = { "Assault Specialist" },
            requires_ability = "Med Shot",
        },
        {
            key = "assault_self_heal_energy_floor_percent",
            type = "int",
            label = "AS: Heal Energy Reserve %",
            tooltip = "Emergency Bacta Infusion / Medical Probe may spend below the DPS reserve, but never below this projected Energy percentage.",
            default = 10,
            min = 0,
            max = 50,
            step = 1,
            disciplines = { "Assault Specialist" },
        },
        {
            key = "auto_echoing_deterrence",
            type = "bool",
            label = "AS: Auto Echoing Deterrence",
            tooltip = "If Echoing Deterrence is the selected level-68 ability, allow emergency automatic use below the configured HP threshold.",
            default = false,
            disciplines = { "Assault Specialist" },
            requires_ability = "Echoing Deterrence",
        },
        {
            key = "echoing_deterrence_hp_percent",
            type = "int",
            label = "AS: Echoing Deterrence HP %",
            tooltip = "Emergency HP threshold for automatic Echoing Deterrence.",
            default = 35,
            min = 10,
            max = 80,
            step = 1,
            disciplines = { "Assault Specialist" },
            requires_ability = "Echoing Deterrence",
        },
        {
            key = "auto_reactive_shield",
            type = "bool",
            label = "Auto Reactive Shield",
            tooltip = "Optional emergency defensive. Disabled by default so defensive timing remains player-owned.",
            default = false,
            requires_ability = "Reactive Shield",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "reactive_shield_hp_percent",
            type = "int",
            label = "Reactive Shield HP %",
            tooltip = "Use Reactive Shield only at or below this health percentage when automation is enabled.",
            default = 40,
            min = 10,
            max = 80,
            step = 1,
            requires_ability = "Reactive Shield",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "auto_concussion_charge",
            type = "bool",
            label = "Auto Concussion Charge",
            tooltip = "Use Concussion Charge as a defensive knockback when a hostile is in melee range and your HP is low. It is never used merely for AoE damage.",
            default = false,
            requires_ability = "Concussion Charge",
            disciplines = { "Gunnery" },
        },
        {
            key = "concussion_charge_hp_percent",
            type = "int",
            label = "Concussion Charge HP %",
            tooltip = "Defensive threshold for automatic Concussion Charge. The selected hostile must also be within 4 metres.",
            default = 50,
            min = 10,
            max = 90,
            step = 1,
            requires_ability = "Concussion Charge",
            disciplines = { "Gunnery" },
        },
        {
            key = "auto_diversion",
            type = "bool",
            label = "Auto Diversion",
            tooltip = "If Diversion is the selected level-43 talent, allow the rotation to use it as an emergency defensive. Disabled by default.",
            default = false,
            requires_ability = "Diversion",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "diversion_hp_percent",
            type = "int",
            label = "Diversion HP %",
            tooltip = "Use selected Diversion at or below this HP percentage when Auto Diversion is enabled.",
            default = 50,
            min = 10,
            max = 90,
            step = 1,
            requires_ability = "Diversion",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "auto_adrenaline_rush",
            type = "bool",
            label = "Auto Adrenaline Rush",
            tooltip = "Use Adrenaline Rush only after it is actually learned and HP reaches the emergency threshold. Assault's Adrenal Surge choice raises the automatic trigger to its 60% recovery threshold.",
            default = false,
            requires_ability = "Adrenaline Rush",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "adrenaline_rush_hp_percent",
            type = "int",
            label = "Adrenaline Rush HP %",
            tooltip = "Emergency HP threshold. The baseline level-47 ability begins healing immediately at 35% or below.",
            default = 35,
            min = 10,
            max = 60,
            step = 1,
            requires_ability = "Adrenaline Rush",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "auto_supercharged_celerity",
            type = "bool",
            label = "Auto Supercharged Celerity",
            tooltip = "If the level-43 Celerity talent is selected, allow automatic use at 10 Supercharge stacks. Disabled by default because it competes with the discipline Supercharged Cell for the same stacks.",
            default = false,
            requires_ability = "Supercharged Celerity",
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "cast_log",
            type = "bool",
            label = "Cast Log",
            tooltip = "Log queued abilities, action starts, command failures, and resource decisions.",
            default = false,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "decision_log",
            type = "bool",
            label = "Decision Log",
            tooltip = "Log deduplicated loadout, target, queue, movement, and priority transitions.",
            default = false,
            disciplines = { "Gunnery", "Assault Specialist" },
        },
        {
            key = "ability_diagnostics",
            type = "bool",
            label = "Ability Diagnostics",
            tooltip = "Once per second, log every modeled ability's availability, cost, and blocking reason.",
            default = false,
            disciplines = { "Gunnery" },
        },
    },
})))
SettingsSchema.fields[#SettingsSchema.fields + 1] = {
    key = "diagnostics_logging",
    type = "bool",
    label = "Enable Diagnostics / Logging",
    tooltip = "Master switch for optional Commando cast, decision, ability, healing, and cleanse diagnostics. Keep disabled to skip diagnostic polling and formatting.",
    default = false,
}
Mirror.settings(SettingsSchema)
local Settings = gos.settings.register(SCRIPT_ID, SettingsSchema)

local Ability = {
    ReactiveShield = {
        id = "Reactive Shield",
        targetless = true,
        offGcd = true,
    },
    HighVelocitySuperchargedCell = {
        id = "High Velocity Supercharged Cell",
        targetless = true,
        offGcd = true,
    },
    RechargeCells = {
        id = "Recharge Cells",
        targetless = true,
        offGcd = true,
    },
    ConcussionCharge = {
        id = "Concussion Charge",
        targetless = true,
        offGcd = true,
    },
    Diversion = {
        id = "Diversion",
        targetless = true,
        offGcd = true,
    },
    AdrenalineRush = {
        id = "Adrenaline Rush",
        targetless = true,
        offGcd = true,
    },
    SuperchargedCelerity = {
        id = "Supercharged Celerity",
        targetless = true,
        offGcd = true,
        requiresSupercharge = true,
    },

    PlasmaGrenade = {
        id = "Plasma Grenade",
        stationary = true,
        fallbackCost = 20.0,
    },
    MortarVolley = {
        id = "Mortar Volley",
        stationary = true,
        channel = true,
        groundTarget = true,
        fallbackCost = 30.0,
    },
    HailOfBolts = {
        id = "Hail of Bolts",
        stationary = true,
        channel = true,
        groundTarget = true,
        fallbackCost = 32.0,
    },
    HighImpactBolt = {
        id = "High Impact Bolt",
        conditionalReady = true,
        fallbackCost = 15.0,
    },
    DemolitionRound = {
        id = "Demolition Round",
        requiresVortex = true,
        fallbackCost = 15.0,
    },
    VortexBolt = {
        id = "Vortex Bolt",
        fallbackCost = 10.0,
    },
    StickyGrenade = {
        id = "Sticky Grenade",
        fallbackCost = 15.0,
    },
    Boltstorm = { id = "Boltstorm", stationary = true, channel = true,
        exactOpenStart = true, fallbackCost = 16, channelTotalCost = 16 },
    ElectroNet = { id = "Electro Net", fallbackCost = 10 },
    TechOverride = { id = "Tech Override", targetless = true, offGcd = true },
    BactaInfusion = { id = "Bacta Infusion", selfTarget = true, fallbackCost = 10, defensiveHeal = true },
    MedicalProbe = { id = "Medical Probe", selfTarget = true, stationary = true, fallbackCost = 13, defensiveHeal = true },
    MedShot = { id = "Med Shot", selfTarget = true, fallbackCost = 0, defensiveHeal = true },
    EchoingDeterrence = { id = "Echoing Deterrence", targetless = true, offGcd = true },
    PropulsionRound = { id = "Propulsion Round", targetless = true },
    HoldTheLine = { id = "Hold the Line", targetless = true, offGcd = true },
    Tenacity = { id = "Tenacity", targetless = true, offGcd = true },
    ConcussiveRound = { id = "Concussive Round", stationary = true },
    CryoGrenade = { id = "Cryo Grenade" },
    DisablingShot = { id = "Disabling Shot", offGcd = true },
    FullAuto = {
        id = "Full Auto",
        stationary = true,
        channel = true,
        exactOpenStart = true,
        fallbackCost = 24.0,
    },
    GravRound = {
        id = "Grav Round",
        stationary = true,
        fallbackCost = 15.0,
    },
    ChargedBolts = {
        id = "Charged Bolts",
        stationary = true,
        fallbackCost = 15.0,
    },
    ExplosiveRound = {
        id = "Explosive Round",
        fallbackCost = 20.0,
    },
    HammerShot = {
        id = "Hammer Shot",
        fallbackCost = 0.0,
    },
}

Ability.FullAuto.channelTotalCost = 24
Ability.MortarVolley.channelTotalCost = 30
Ability.HailOfBolts.channelTotalCost = 32

local AbilityList = {
    Ability.Boltstorm, Ability.ElectroNet, Ability.TechOverride, Ability.BactaInfusion,
    Ability.MedicalProbe, Ability.MedShot, Ability.EchoingDeterrence, Ability.PropulsionRound,
    Ability.HoldTheLine, Ability.Tenacity, Ability.ConcussiveRound, Ability.CryoGrenade, Ability.DisablingShot,
    Ability.ReactiveShield,
    Ability.HighVelocitySuperchargedCell,
    Ability.RechargeCells,
    Ability.ConcussionCharge,
    Ability.Diversion,
    Ability.AdrenalineRush,
    Ability.SuperchargedCelerity,
    Ability.PlasmaGrenade,
    Ability.MortarVolley,
    Ability.HailOfBolts,
    Ability.HighImpactBolt,
    Ability.DemolitionRound,
    Ability.VortexBolt,
    Ability.StickyGrenade,
    Ability.FullAuto,
    Ability.GravRound,
    Ability.ChargedBolts,
    Ability.ExplosiveRound,
    Ability.HammerShot,
}

local Utility = {
    BactaInfusion = "Bacta Infusion",
    ConcussiveRound = "Concussive Round",
    FieldAid = "Field Aid",
    HoldTheLine = "Hold the Line",
}

local Talent = {
    GravTrio = "Grav Trio",
    ProficientGravitation = "Proficient Gravitation",
    GravitatingBolt = "Gravitating Bolt",
    ChargedBarrier = "Charged Barrier",
    AdvancedReconDroid = "Advanced Recon Droid",
    ChargedBarrel = "Charged Barrel",
    BlazingBarrel = "Blazing Barrel",
    TargetLock = "Target Lock",
    CustomizedRound = "Customized Round",
    GravitatingCompound = "Gravitating Compound",
    ThermonuclearPlasma = "Thermonuclear Plasma",
    Overclock = "Overclock",
    CellCharger = "Cell Charger",
    ForcedMarch = "Forced March",
}

local AbilityById = {}
for _, ability in ipairs(AbilityList) do
    AbilityById[ability.id] = ability
end

local Executor = AbilityExecutor.new()
local AssaultRoute = CommandoAssaultSpecialist.new(Executor)
local CombatMedicRoute = CommandoCombatMedic.new(Executor)

local CommandoExecutorOwner = {
    gunnery = true,
    assault_specialist = true,
    combat_medic = true,
}

local function executor_pending_owner()
    if not Executor:owns_command() then
        return nil
    end
    local status = Executor:status()
    local key = type(status) == "table" and status.idempotency_key or nil
    local owner = type(key) == "string" and key:match("^([^:]+):") or nil
    return CommandoExecutorOwner[owner] and owner or "unknown"
end

local function cancel_owned(owner, reason)
    if executor_pending_owner() ~= owner then
        return false
    end
    Executor:cancel(reason)
    return executor_pending_owner() == owner
end

local Runtime = {
    targetMemory = {
        handle = nil,
        lastHostileAt = 0.0,
        reaction = nil,
    },

    techHealReservedUntil = nil,
    pendingAdmission = nil,
    pendingAction = nil,
    commandTargetHandle = nil,
    orphanPendingLogged = false,

    rechargeCredit = false,
    rechargeCreditExpiresAt = 0.0,
    rechargeEffectIgnoreUntil = 0.0,

    combatPlayerHandle = nil,
    combatCursor = nil,
    inCombat = nil,
    combatEpoch = 0,
    combatStartedAt = nil,
    gravityVortexPlayerHandle = nil,
    gravityVortexTargets = {},
    progressionPlayerHandle = nil,
    chargedBarrelStacks = 0,
    chargedBarrelUntil = 0.0,
    gravPrimerUntil = 0.0,
    plasmaSpreadTargetHandle = nil,
    plasmaSpreadUntil = 0.0,
    plasmaSpreadCount = 0,

    failureBackoff = {},
    commandContentionUntil = 0.0,

    buildLogged = false,
    settingsSignature = nil,
    lastLoadoutState = nil,
    lastProgressionSignature = nil,
    lastDecisionLogKey = nil,
    lastNoDecisionDiagnosticAt = -math.huge,
    lastAbilityDiagnosticAt = -math.huge,
    admissionDiagnostic = nil,
    lastCoreLifecycleKey = nil,
    lastActionRejectionSequence = 0,
}

local function now_seconds()
    local value = gos.time_ms()
    if type(value) ~= "number" then
        return 0.0
    end
    return value / 1000.0
end

local function clamp(value, minimum, maximum)
    if type(value) ~= "number" then
        return minimum
    end
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

local function bool_text(value)
    return value and "on" or "off"
end

local function optional_number(value, format)
    if type(value) ~= "number" then
        return "nil"
    end
    if type(format) == "string" then
        return string.format(format, value)
    end
    return tostring(value)
end

local function log_line(level, message)
    if (level == "info" or level == "debug") and not Config.diagnosticsLogging then return end
    local logger = gos and gos.log or nil
    local fn = logger and logger[level] or nil
    if type(fn) == "function" then
        fn(message)
    end
end

local function log_info(message)
    if Config.castLog then
        log_line("info", message)
    end
end

local function log_warn(message)
    log_line("warn", message)
end

local function log_debug(message)
    if Config.decisionLog then
        log_line("debug", message)
    end
end

local function setting_value(settings, key)
    if type(settings) ~= "table" then
        return nil
    end
    if settings[key] ~= nil then
        return settings[key]
    end
    if type(settings.fields) == "table" then
        return settings.fields[key]
    end
    return nil
end

local function setting_bool(settings, key, fallback)
    local value = setting_value(settings, key)
    if type(value) == "boolean" then
        return value
    end
    return fallback
end

local function setting_number(settings, key, fallback, minimum, maximum)
    local value = setting_value(settings, key)
    if type(value) ~= "number" then
        value = fallback
    end
    return clamp(value, minimum, maximum)
end

local function setting_int(settings, key, fallback, minimum, maximum)
    return math.floor(setting_number(settings, key, fallback, minimum, maximum))
end

local function apply_settings(settings)
    Config.gunnery = GunneryKit.read_settings(settings)
    Config.abilityQueueWindow =
        setting_number(settings, "ability_queue_window", 0.25, 0.05, 0.50)
    Config.energyFloorPercent =
        setting_number(settings, "energy_floor_percent", 60.0, 35.0, 90.0)
    Config.autoSuperchargedCell =
        setting_bool(settings, "auto_supercharged_cell", true)
    Config.autoRechargeCells = setting_bool(settings, "auto_recharge_cells", true)
    Config.rechargeCellsThresholdPercent = setting_number(settings,
        "recharge_cells_threshold_percent", 25.0, 20.0, 60.0)

    Config.aoeEnabled = setting_bool(settings, "aoe_enabled", true)
    Config.automaticTargetCount =
        setting_bool(settings, "automatic_target_count", true)
    Config.manualRelevantTargets =
        setting_int(settings, "manual_relevant_targets", 1, 1, 8)
    Config.aoeMinTargets = setting_int(settings, "aoe_min_targets", 2, 2, 8)
    Config.aoeClusterRadius =
        setting_number(settings, "aoe_cluster_radius", 5.0, 3.0, 8.0)
    Config.movingExplosiveRound =
        setting_bool(settings, "moving_explosive_round", true)
    Config.hibPreferredBarrels =
        setting_int(settings, "hib_preferred_barrels", 4, 0, CHARGED_BARREL_REQUIRED)
    Config.hibPressureBarrels = math.min(Config.hibPreferredBarrels,
        setting_int(settings, "hib_pressure_barrels", 2, 0, CHARGED_BARREL_REQUIRED))

    Config.assaultIncendiaryRefreshSeconds = setting_number(settings,
        "assault_incendiary_refresh_seconds", 1.5, 0.0, 4.0)
    Config.assaultPriorityFloorPercent = setting_number(settings,
        "assault_priority_floor_percent", 60.0, 35.0, 80.0)
    Config.assaultFillerFloorPercent = setting_number(settings,
        "assault_filler_reserve_percent", 60.0, 35.0, 80.0)
    Config.assaultRechargeThresholdPercent = setting_number(settings,
        "assault_recharge_cells_threshold_percent", 45.0, 20.0, 60.0)
    Config.assaultAutoSuperchargedCell =
        setting_bool(settings, "assault_auto_supercharged_cell", true)
    Config.assaultConsumeHyperAssault =
        setting_bool(settings, "assault_consume_hyper_assault", true)
    Config.assaultUseStickyGrenade =
        setting_bool(settings, "assault_use_sticky_grenade", true)
    Config.assaultUseElectroNet =
        setting_bool(settings, "assault_use_electro_net", false)
    Config.assaultAutoSelfHeal =
        setting_bool(settings, "assault_auto_self_heal", true)
    Config.assaultBactaInfusionHpPercent = setting_int(settings,
        "assault_bacta_infusion_hp_percent", 45, 10, 80)
    Config.assaultInstantMedicalProbeHpPercent = setting_int(settings,
        "assault_instant_medical_probe_hp_percent", 55, 10, 85)
    Config.assaultMedShotHpPercent = setting_int(settings,
        "assault_med_shot_hp_percent", 25, 5, 60)
    Config.assaultSelfHealEnergyFloorPercent = setting_int(settings,
        "assault_self_heal_energy_floor_percent", 10, 0, 50)
    Config.autoEchoingDeterrence =
        setting_bool(settings, "auto_echoing_deterrence", false)
    Config.echoingDeterrenceHpPercent =
        setting_int(settings, "echoing_deterrence_hp_percent", 35, 10, 80)

    Config.autoReactiveShield =
        setting_bool(settings, "auto_reactive_shield", false)
    Config.reactiveShieldHpPercent =
        setting_int(settings, "reactive_shield_hp_percent", 40, 10, 80)
    Config.autoConcussionCharge =
        setting_bool(settings, "auto_concussion_charge", false)
    Config.concussionChargeHpPercent =
        setting_int(settings, "concussion_charge_hp_percent", 50, 10, 90)
    Config.autoDiversion = setting_bool(settings, "auto_diversion", false)
    Config.diversionHpPercent =
        setting_int(settings, "diversion_hp_percent", 50, 10, 90)
    Config.autoAdrenalineRush =
        setting_bool(settings, "auto_adrenaline_rush", false)
    Config.adrenalineRushHpPercent =
        setting_int(settings, "adrenaline_rush_hp_percent", 35, 10, 60)
    Config.autoSuperchargedCelerity =
        setting_bool(settings, "auto_supercharged_celerity", false)

    Config.diagnosticsLogging = setting_bool(settings, "diagnostics_logging", false)
    Config.castLog = Config.diagnosticsLogging and setting_bool(settings, "cast_log", false)
    Config.decisionLog = Config.diagnosticsLogging and setting_bool(settings, "decision_log", false)
    local ability_diagnostics = Config.diagnosticsLogging and
        setting_bool(settings, "ability_diagnostics", false)
    if Config.abilityDiagnostics and not ability_diagnostics then
        Runtime.admissionDiagnostic = nil
    end
    Config.abilityDiagnostics = ability_diagnostics

    if not Config.diagnosticsLogging then
        Runtime.settingsSignature = nil
        return
    end

    if not Runtime.buildLogged then
        Runtime.buildLogged = true
        log_line("info", "build=" .. BUILD_ID ..
            " route=commando/multispec" ..
            " gunnery=progressive_1_80" ..
            " assault=progressive_1_80" ..
            " combat_medic=" .. CommandoCombatMedic.revision ..
            " talent_ssot=loadout.known" ..
            " ground_target_core_owned=on" ..
            " runtime_costs=preferred" ..
            " hib_vortex=effect_or_grav_confirmed" ..
            " defensives=" .. (Config.autoReactiveShield and "optional_auto" or "manual"))
    end

    local signature = table.concat({
        string.format("%.2f", Config.abilityQueueWindow),
        string.format("%.0f", Config.energyFloorPercent),
        string.format("%.0f", Config.rechargeCellsThresholdPercent),
        bool_text(Config.autoSuperchargedCell),
        bool_text(Config.autoRechargeCells),
        bool_text(Config.aoeEnabled),
        bool_text(Config.automaticTargetCount),
        tostring(Config.manualRelevantTargets),
        tostring(Config.aoeMinTargets),
        string.format("%.1f", Config.aoeClusterRadius),
        bool_text(Config.movingExplosiveRound),
        tostring(Config.hibPreferredBarrels),
        tostring(Config.hibPressureBarrels),
        string.format("%.1f", Config.assaultIncendiaryRefreshSeconds),
        string.format("%.0f", Config.assaultPriorityFloorPercent),
        string.format("%.0f", Config.assaultFillerFloorPercent),
        string.format("%.0f", Config.assaultRechargeThresholdPercent),
        bool_text(Config.assaultAutoSuperchargedCell),
        bool_text(Config.assaultConsumeHyperAssault),
        bool_text(Config.assaultUseStickyGrenade),
        bool_text(Config.assaultUseElectroNet),
        bool_text(Config.assaultAutoSelfHeal),
        tostring(Config.assaultBactaInfusionHpPercent),
        tostring(Config.assaultInstantMedicalProbeHpPercent),
        tostring(Config.assaultMedShotHpPercent),
        tostring(Config.assaultSelfHealEnergyFloorPercent),
        bool_text(Config.autoEchoingDeterrence),
        tostring(Config.echoingDeterrenceHpPercent),
        bool_text(Config.autoReactiveShield),
        tostring(Config.reactiveShieldHpPercent),
        bool_text(Config.autoConcussionCharge),
        tostring(Config.concussionChargeHpPercent),
        bool_text(Config.autoDiversion),
        tostring(Config.diversionHpPercent),
        bool_text(Config.autoAdrenalineRush),
        tostring(Config.adrenalineRushHpPercent),
        bool_text(Config.autoSuperchargedCelerity),
        bool_text(Config.diagnosticsLogging),
        bool_text(Config.castLog),
        bool_text(Config.decisionLog),
        bool_text(Config.abilityDiagnostics),
    }, "|")

    if Runtime.settingsSignature ~= signature then
        Runtime.settingsSignature = signature
        log_info("settings: queue=" .. string.format("%.2f", Config.abilityQueueWindow) ..
            " energy_floor_percent=" ..
                string.format("%.0f", Config.energyFloorPercent) ..
            " recharge_at_percent=" ..
                string.format("%.0f", Config.rechargeCellsThresholdPercent) ..
            " auto_hvsc=" .. bool_text(Config.autoSuperchargedCell) ..
            " auto_recharge=" .. bool_text(Config.autoRechargeCells) ..
            " aoe=" .. bool_text(Config.aoeEnabled) ..
            " auto_count=" .. bool_text(Config.automaticTargetCount) ..
            " manual_targets=" .. tostring(Config.manualRelevantTargets) ..
            " aoe_min=" .. tostring(Config.aoeMinTargets) ..
            " radius=" .. string.format("%.1f", Config.aoeClusterRadius) ..
            " moving_explosive=" .. bool_text(Config.movingExplosiveRound) ..
            " hib_normal_stacks=" .. tostring(Config.hibPreferredBarrels) ..
            " hib_pressure_stacks=" .. tostring(Config.hibPressureBarrels) ..
            " as_dot_refresh=" .. string.format("%.1f", Config.assaultIncendiaryRefreshSeconds) ..
            " as_priority_reserve=" .. string.format("%.0f", Config.assaultPriorityFloorPercent) ..
            " as_filler_reserve=" .. string.format("%.0f", Config.assaultFillerFloorPercent) ..
            " as_recharge=" .. string.format("%.0f", Config.assaultRechargeThresholdPercent) ..
            " as_auto_cell=" .. bool_text(Config.assaultAutoSuperchargedCell) ..
            " as_har=" .. bool_text(Config.assaultConsumeHyperAssault) ..
            " as_sticky=" .. bool_text(Config.assaultUseStickyGrenade) ..
            " as_electro_net=" .. bool_text(Config.assaultUseElectroNet) ..
            " as_self_heal=" .. bool_text(Config.assaultAutoSelfHeal) ..
            " as_bacta_hp=" .. tostring(Config.assaultBactaInfusionHpPercent) ..
            " as_instant_probe_hp=" .. tostring(Config.assaultInstantMedicalProbeHpPercent) ..
            " as_medshot_hp=" .. tostring(Config.assaultMedShotHpPercent) ..
            " as_heal_energy_floor=" .. tostring(Config.assaultSelfHealEnergyFloorPercent) ..
            " auto_echoing=" .. bool_text(Config.autoEchoingDeterrence) ..
            " echoing_hp=" .. tostring(Config.echoingDeterrenceHpPercent) ..
            " auto_shield=" .. bool_text(Config.autoReactiveShield) ..
            " shield_hp=" .. tostring(Config.reactiveShieldHpPercent) ..
            " auto_concussion=" .. bool_text(Config.autoConcussionCharge) ..
            " concussion_hp=" .. tostring(Config.concussionChargeHpPercent) ..
            " auto_diversion=" .. bool_text(Config.autoDiversion) ..
            " diversion_hp=" .. tostring(Config.diversionHpPercent) ..
            " auto_adrenaline=" .. bool_text(Config.autoAdrenalineRush) ..
            " adrenaline_hp=" .. tostring(Config.adrenalineRushHpPercent) ..
            " auto_celerity=" .. bool_text(Config.autoSuperchargedCelerity))
    end
end

local function safe_method(unit, method_name, ...)
    if not unit then
        return nil
    end
    local method = unit[method_name]
    if type(method) ~= "function" then
        return nil
    end
    local ok, a, b, c = pcall(method, unit, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

local function unit_handle(unit)
    return safe_method(unit, "handle")
end

local function unit_reaction(unit)
    return safe_method(unit, "reaction")
end

local function unit_distance(unit)
    local value = safe_method(unit, "distance")
    if type(value) ~= "number" then
        return nil
    end
    return value * METERS_PER_WORLD_UNIT
end

local function unit_position(unit)
    local value = safe_method(unit, "position")
    if type(value) ~= "table" or
        type(value.x) ~= "number" or
        type(value.y) ~= "number" or
        type(value.z) ~= "number" then
        return nil
    end
    return value
end

local function position_distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return nil
    end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) * METERS_PER_WORLD_UNIT
end

local function unit_speed(unit)
    local value = safe_method(unit, "speed")
    if type(value) == "number" then
        return value
    end
    return nil
end

local function unit_hp(unit)
    local hp = safe_method(unit, "hp")
    if type(hp) ~= "table" then
        return nil
    end
    local current = type(hp.current) == "number" and hp.current or nil
    local maximum = type(hp.max) == "number" and hp.max or nil
    local percent = type(hp.percent) == "number" and hp.percent or nil
    if percent == nil and current ~= nil and maximum ~= nil and maximum > 0 then
        percent = (current / maximum) * 100.0
    end
    return {
        current = current,
        max = maximum,
        percent = percent,
    }
end

local function unit_resource(unit)
    local resource = Mirror.resource(ActiveLoadout, safe_method(unit, "resource"))
    if type(resource) ~= "table" then
        return nil
    end
    local current = type(resource.current) == "number" and resource.current or nil
    local maximum = type(resource.max) == "number" and resource.max or nil
    local percent = type(resource.percent) == "number" and resource.percent or nil
    if percent == nil and current ~= nil and maximum ~= nil and maximum > 0 then
        percent = (current / maximum) * 100.0
    end
    return {
        current = current,
        max = maximum,
        percent = percent,
        kind = type(resource.kind) == "string" and resource.kind or nil,
    }
end

local function unit_effect(unit, name, options)
    if type(options)=="table" and options.definition_key then
        local key=Mirror.effect_key(ActiveLoadout,options.definition_key)
        if key==nil then return nil end
        if key~=options.definition_key then
            local translated={}
            for k,v in pairs(options) do translated[k]=v end
            translated.definition_key=key
            options=translated
        end
    elseif name~="" then
        name=Mirror.effect_name(ActiveLoadout,name)
        if name==nil then return nil end
    end
    local effect = safe_method(unit, "effect", name, options)
    if type(effect) == "table" then
        return effect
    end
    return nil
end

local function loadout_has(loadout, name)
    return type(loadout) == "table" and
        type(loadout.known) == "table" and
        type(name) == "string" and
        loadout.known[name] == true
end

local function loadout_knows(loadout, ability)
    return type(ability) == "table" and loadout_has(loadout, ability.id)
end

local function fallback_cost_for(loadout, ability)
    local cost = ability.fallbackCost
    if ability == Ability.GravRound and
        loadout_has(loadout, Talent.ProficientGravitation) then
        return 13.0
    end
    if ability == Ability.HighImpactBolt and
        loadout_has(loadout, Talent.CellCharger) then
        return 5.0
    end
    return cost
end

local function selected_loadout_choice(loadout, names)
    for _, name in ipairs(names) do
        if loadout_has(loadout, name) then
            return name
        end
    end
    return nil
end

local function progression_snapshot(loadout)
    return GunneryKit.progression(loadout, {
        bactaInfusion = loadout_has(loadout, Utility.BactaInfusion),
        concussiveRound = loadout_has(loadout, Utility.ConcussiveRound),
        fieldAid = loadout_has(loadout, Utility.FieldAid),
        holdTheLine = loadout_has(loadout, Utility.HoldTheLine),
        chargedBarrel = loadout_has(loadout, Talent.ChargedBarrel),
        blazingBarrel = loadout_has(loadout, Talent.BlazingBarrel),
        targetLock = loadout_has(loadout, Talent.TargetLock),
        cellCharger = loadout_has(loadout, Talent.CellCharger),
        forcedMarch = loadout_has(loadout, Talent.ForcedMarch),
        level23Choice = selected_loadout_choice(loadout, {
            Talent.GravitatingBolt,
            Talent.GravTrio,
            Talent.ProficientGravitation,
        }),
        level27Choice = selected_loadout_choice(loadout, {
            Ability.StickyGrenade.id,
            Talent.ChargedBarrier,
            Talent.AdvancedReconDroid,
        }),
        level39Choice = selected_loadout_choice(loadout, {
            Talent.GravitatingCompound,
            Talent.CustomizedRound,
            Talent.ThermonuclearPlasma,
        }),
        level43Choice = selected_loadout_choice(loadout, {
            Ability.Diversion.id,
            Ability.SuperchargedCelerity.id,
            Talent.Overclock,
        }),
    })
end

local function ability_snapshot(loadout)
    local snapshot = {}
    for _, ability in ipairs(AbilityList) do
        local known = loadout_knows(loadout, ability)
        local info = known and Mirror.call(ActiveLoadout,"info",ability.id) or nil
        local cooldown = known and Mirror.call(ActiveLoadout,"cooldown_remaining",ability.id) or nil
        local info_known = type(info) == "table"
        local invalid_cost = info_known and info.has_resource_cost == true and
            (not GunneryKit.finite(info.resource_cost) or info.resource_cost < 0)
        local invalid_cooldown = cooldown ~= nil and
            (not GunneryKit.finite(cooldown) or cooldown < 0)
        local dynamic_cost = info_known and info.has_resource_cost == true and
            type(info.resource_cost) == "number" and info.resource_cost or nil
        local effective_cost = dynamic_cost
        local cost_source = dynamic_cost ~= nil and "runtime" or "fallback"
        if effective_cost == nil then
            effective_cost = fallback_cost_for(loadout, ability)
        end

        snapshot[ability.id] = {
            known = known,
            invalidCost = invalid_cost,
            invalidCooldown = invalid_cooldown,
            resolved = known and info_known and info.ability_handle ~= nil,
            bound = known and info_known and info.on_bar == true,
            abilityHandle = info_known and info.ability_handle or nil,
            activationHandle = info_known and info.activation_handle or nil,
            ready = known and Mirror.call(ActiveLoadout,"is_ready",ability.id) == true,
            cooldownKnown = type(cooldown) == "number",
            cooldown = type(cooldown) == "number" and math.max(0.0, cooldown) or nil,
            hasResourceCost = type(effective_cost) == "number",
            resourceCost = type(effective_cost) == "number" and
                math.max(0.0, effective_cost) or nil,
            resourceCostSource = cost_source,
        }
    end
    return snapshot
end

local function current_action_snapshot()
    local cast = gos.abilities.current_cast()
    if type(cast) ~= "table" then
        return nil
    end
    return {
        name = Mirror.canonical(ActiveLoadout,cast.name),
        ability = AbilityById[Mirror.canonical(ActiveLoadout,cast.name)],
        remaining = type(cast.remaining) == "number" and
            math.max(0.0, cast.remaining) or nil,
        hasTiming = cast.has_timing == true or type(cast.remaining) == "number",
    }
end

local function update_target_memory(state)
    local handle = state.target.handle
    if handle == nil then
        return
    end

    local memory = Runtime.targetMemory
    if memory.handle ~= handle then
        memory.handle = handle
        memory.lastHostileAt = 0.0
        memory.reaction = nil
    end

    if state.target.reaction ~= nil then
        memory.reaction = state.target.reaction
    end
    if state.target.reaction == "hostile" then
        memory.lastHostileAt = state.now
    end
end

local function apply_target_memory(state)
    local memory = Runtime.targetMemory
    if state.target.handle == nil or memory.handle ~= state.target.handle then
        return
    end
    if state.target.reaction == nil or state.target.reaction == "unclassified" then
        if state.now - memory.lastHostileAt <= Config.targetObservationGrace then
            state.target.reaction = "hostile"
            state.target.reactionFromGrace = true
        end
    end
end

local function read_state(loadout)
    local now = now_seconds()
    local world = gos.world()
    local player = world and world.player or nil
    local target = world and world.current_target or nil

    local player_hp = unit_hp(player)
    local player_resource = unit_resource(player)
    local target_hp = unit_hp(target)
    local speed = unit_speed(player)
    local movement_known = type(speed) == "number"

    local gcd_remaining = gos.abilities.gcd_remaining()
    if GunneryKit.finite(gcd_remaining) then
        gcd_remaining = math.max(0.0, gcd_remaining)
    else
        gcd_remaining = nil
    end

    local gravity_vortex = unit_effect(target, "", {
        kind = "debuff", definition_key = GunneryKit.effects.GravityVortex,
    })
    local recharge_cells = unit_effect(player, "Recharge Cells", {
        kind = "buff",
        timed = true,
    })
    local supercharge = unit_effect(player, "Supercharge", {
        kind = "buff",
    })
    local charged_barrel = unit_effect(player, "Charged Barrel", {
        kind = "buff",
    })
    local grav_primer = unit_effect(player, "Grav Primer", {
        kind = "buff",
    })

    local player_handle = unit_handle(player)
    local progression = progression_snapshot(loadout)
    if Runtime.progressionPlayerHandle ~= player_handle then
        Runtime.progressionPlayerHandle = player_handle
        Runtime.chargedBarrelStacks = 0
        Runtime.chargedBarrelUntil = 0.0
        Runtime.gravPrimerUntil = 0.0
        Runtime.plasmaSpreadTargetHandle = nil
        Runtime.plasmaSpreadUntil = 0.0
        Runtime.plasmaSpreadCount = 0
    end

    if not progression.chargedBarrel or now >= Runtime.chargedBarrelUntil then
        Runtime.chargedBarrelStacks = 0
        Runtime.chargedBarrelUntil = 0.0
    end
    if progression.chargedBarrel and charged_barrel and
        charged_barrel.status == "ready" and
        charged_barrel.present == true and
        type(charged_barrel.stacks) == "number" then
        Runtime.chargedBarrelStacks = clamp(charged_barrel.stacks, 0,
            CHARGED_BARREL_REQUIRED)
        Runtime.chargedBarrelUntil = now +
            (type(charged_barrel.remaining) == "number" and
                math.max(0.0, charged_barrel.remaining) or
                CHARGED_BARREL_PROOF_TTL)
    end

    if grav_primer and grav_primer.status == "ready" and
        grav_primer.present == true then
        Runtime.gravPrimerUntil = now +
            (type(grav_primer.remaining) == "number" and
                math.max(0.0, grav_primer.remaining) or GRAV_PRIMER_PROOF_TTL)
    elseif now >= Runtime.gravPrimerUntil then
        Runtime.gravPrimerUntil = 0.0
    end

    local grav_primer_remaining = Runtime.gravPrimerUntil > now and
        Runtime.gravPrimerUntil - now or 0.0

    local state = {
        now = now,
        world = world,
        loadout = loadout,
        playerUnit = player,
        targetUnit = target,
        movementKnown = movement_known,
        moving = movement_known and math.abs(speed) > 0.001 or false,
        speed = speed,
        busy = gos.abilities.is_casting_or_channeling() == true,
        gcdRemaining = gcd_remaining,
        currentAction = current_action_snapshot(),
        abilities = ability_snapshot(loadout),
        progression = progression,
        player = {
            handle = player_handle,
            hpCurrent = player_hp and player_hp.current or nil,
            hpMax = player_hp and player_hp.max or nil,
            hpPercent = player_hp and player_hp.percent or nil,
            energyCurrent = player_resource and player_resource.current or nil,
            energyMax = player_resource and player_resource.max or nil,
            energyPercent = player_resource and player_resource.percent or nil,
            resourceKind = player_resource and player_resource.kind or nil,
            rechargeStatus = recharge_cells and recharge_cells.status or nil,
            rechargePresent = recharge_cells and
                recharge_cells.status == "ready" and
                recharge_cells.present == true or false,
            superchargeStatus = supercharge and supercharge.status or nil,
            superchargePresent = supercharge and
                supercharge.status == "ready" and
                supercharge.present == true or false,
            superchargeStacks = supercharge and
                supercharge.status == "ready" and
                type(supercharge.stacks) == "number" and
                math.max(0.0, supercharge.stacks) or nil,
            chargedBarrelStatus = charged_barrel and charged_barrel.status or nil,
            chargedBarrelStacks = progression.chargedBarrel and
                Runtime.chargedBarrelStacks or nil,
            chargedBarrelRemaining = progression.chargedBarrel and
                Runtime.chargedBarrelUntil > now and
                Runtime.chargedBarrelUntil - now or nil,
            gravPrimerStatus = grav_primer and grav_primer.status or nil,
            gravPrimerPresent = grav_primer_remaining > 0.0,
            gravPrimerRemaining = grav_primer_remaining > 0.0 and
                grav_primer_remaining or nil,
        },
        target = {
            exists = target ~= nil,
            handle = unit_handle(target),
            reaction = unit_reaction(target),
            hpCurrent = target_hp and target_hp.current or nil,
            hpMax = target_hp and target_hp.max or nil,
            hpPercent = target_hp and target_hp.percent or nil,
            distance = unit_distance(target),
            position = unit_position(target),
            reactionFromGrace = false,
            gravityVortexStatus = gravity_vortex and gravity_vortex.status or nil,
            gravityVortexPresent = gravity_vortex and
                gravity_vortex.status == "ready" and
                gravity_vortex.present == true or false,
            gravityVortexEventUntil = nil,
            gravityVortexEventRemaining = nil,
            gravityVortexProof = "none",
        },
        relevantTargets = Config.manualRelevantTargets,
        targetCountSource = "manual",
        targetCountReason = "manual_configured",
        rechargeCredit = false,
    }

    GunneryKit.observe(state)
    update_target_memory(state)
    apply_target_memory(state)
    return state
end

local function prune_gravity_vortex_evidence(now)
    for handle, expires_at in pairs(Runtime.gravityVortexTargets) do
        if type(expires_at) ~= "number" or expires_at <= now then
            Runtime.gravityVortexTargets[handle] = nil
        end
    end
end

local function event_matches_grav_round(event, grav_round)
    if type(event.name) == "string" and Mirror.canonical(ActiveLoadout,event.name) == Ability.GravRound.id then
        return true
    end
    if type(event.ability_handle) ~= "string" then
        return false
    end
    return (type(grav_round.activationHandle) == "string" and
        event.ability_handle == grav_round.activationHandle) or
        (type(grav_round.abilityHandle) == "string" and
        event.ability_handle == grav_round.abilityHandle)
end

local function apply_current_gravity_vortex_evidence(state)
    local target_handle = state.target.handle
    local expires_at = target_handle and
        Runtime.gravityVortexTargets[target_handle] or nil

    state.target.gravityVortexEventUntil = expires_at
    state.target.gravityVortexEventRemaining =
        type(expires_at) == "number" and
        math.max(0.0, expires_at - state.now) or nil

    if state.target.gravityVortexPresent == true then
        state.target.gravityVortexProof = "effect"
    elseif type(state.target.gravityVortexEventRemaining) == "number" and
        state.target.gravityVortexEventRemaining > 0.0 then
        state.target.gravityVortexProof = "grav_round_confirmed"
    elseif state.target.gravityVortexStatus == "ready" then
        state.target.gravityVortexProof = "absent"
    else
        state.target.gravityVortexProof = "unavailable"
    end
end

local function poll_commando_combat_events(world)
    local player_handle = unit_handle(world and world.player or nil)
    if type(player_handle) ~= "string" then
        return {}, player_handle, 0
    end

    if Runtime.combatPlayerHandle ~= player_handle then
        Runtime.combatPlayerHandle = player_handle
        Runtime.combatCursor = nil
        Runtime.inCombat = nil
        Runtime.combatEpoch = 0
        Runtime.combatStartedAt = nil
        Runtime.gravityVortexPlayerHandle = nil
        Runtime.gravityVortexTargets = {}
    end

    if not gos.events or type(gos.events.combat) ~= "function" then
        return {}, player_handle, 0
    end

    local events = {}
    local dropped = 0
    for _ = 1, COMBAT_EVENT_PASSES do
        local ok, batch = pcall(gos.events.combat, Runtime.combatCursor)
        if not ok or type(batch) ~= "table" or
            type(batch.cursor) ~= "number" or type(batch.events) ~= "table" then
            Runtime.combatCursor = nil
            return {}, player_handle, 0
        end
        Runtime.combatCursor = batch.cursor
        if type(batch.dropped) == "number" and batch.dropped > 0 then
            dropped = dropped + batch.dropped
        end
        for index = 1, #batch.events do
            events[#events + 1] = batch.events[index]
        end
        if batch.more ~= true then break end
    end

    if dropped > 0 then
        log_warn("combat event gap: dropped=" .. tostring(dropped))
    end

    for _, event in ipairs(events) do
        if type(event) == "table" and event.kind == "combat" and
            event.source_handle == player_handle then
            if event.action == "enter_combat" then
                if Runtime.inCombat ~= true then
                    Runtime.inCombat = true
                    Runtime.combatEpoch = Runtime.combatEpoch + 1
                    Runtime.combatStartedAt = now_seconds()
                end
            elseif event.action == "exit_combat" then
                Runtime.inCombat = false
                Runtime.combatStartedAt = nil
            end
        end
    end
    return events, player_handle, dropped
end

local function refresh_gravity_vortex_evidence(state, combat_events)
    local player_handle = state.player.handle
    prune_gravity_vortex_evidence(state.now)

    if type(player_handle) ~= "string" then
        apply_current_gravity_vortex_evidence(state)
        return
    end

    if Runtime.gravityVortexPlayerHandle ~= player_handle then
        Runtime.gravityVortexPlayerHandle = player_handle
        Runtime.gravityVortexTargets = {}
    end

    local grav_round = state.abilities[Ability.GravRound.id] or {}
    for index = 1, #(combat_events or {}) do
        local event = combat_events[index]
        if type(event) == "table" and event.kind == "damage" and
            event.source_handle == player_handle and
            type(event.target_handle) == "string" and
            event_matches_grav_round(event, grav_round) then
            Runtime.gravityVortexTargets[event.target_handle] =
                state.now + GRAVITY_VORTEX_PROOF_TTL
            log_info("Gravity Vortex evidence: source=Grav Round damage" ..
                " target=" .. event.target_handle ..
                " ttl=" .. string.format("%.0f", GRAVITY_VORTEX_PROOF_TTL))
        end
    end

    prune_gravity_vortex_evidence(state.now)
    apply_current_gravity_vortex_evidence(state)
end

local function loadout_match(loadout)
    if type(loadout) ~= "table" then
        return false, "invalid_response"
    end
    if loadout.status == "pending" then
        return false, "pending"
    end
    if loadout.status == "unavailable" then
        return false, "unavailable"
    end
    if loadout.status ~= "ready" then
        return false, "status:" .. tostring(loadout.status)
    end
    if loadout.combat_style ~= ExpectedCombatStyle then
        return false, "style:" .. tostring(loadout.combat_style)
    end
    if loadout.discipline ~= ExpectedDiscipline then
        return false, "disc:" .. tostring(loadout.discipline)
    end
    if type(loadout.known) ~= "table" then
        return false, "known_invalid"
    end
    return true, "ready"
end

local function log_loadout_state(reason)
    if not Config.diagnosticsLogging then return end
    if Runtime.lastLoadoutState == reason then
        return
    end
    Runtime.lastLoadoutState = reason
    if reason == "ready" then
        local actual=Mirror.raw_loadout(ActiveLoadout)
        log_line("info", "loadout ready: style=" .. tostring(actual.combat_style) ..
            " disc=" .. tostring(actual.discipline))
    else
        log_line("warn", "loadout gate: reason=" .. reason ..
            " expected=style:" .. ExpectedCombatStyle ..
            "/disc:" .. ExpectedDiscipline)
    end
end

local function log_progression_state(state)
    if not Config.diagnosticsLogging then return end
    local p = state.progression or {}
    local signature = table.concat({
        tostring(p.level23Choice or "none"),
        tostring(p.level27Choice or "none"),
        tostring(p.level39Choice or "none"),
        tostring(p.level43Choice or "none"),
        tostring(p.chargedBarrel == true),
        tostring(p.forcedMarch == true),
        tostring((state.abilities[Ability.DemolitionRound.id] or {}).known == true),
        tostring((state.abilities[Ability.VortexBolt.id] or {}).known == true),
    }, "|")
    if Runtime.lastProgressionSignature == signature then
        return
    end
    Runtime.lastProgressionSignature = signature
    log_line("info", "progression: level23=" .. tostring(p.level23Choice or "none") ..
        " level27=" .. tostring(p.level27Choice or "none") ..
        " level39=" .. tostring(p.level39Choice or "none") ..
        " level43=" .. tostring(p.level43Choice or "none") ..
        " charged_barrel=" .. bool_text(p.chargedBarrel == true) ..
        " forced_march=" .. bool_text(p.forcedMarch == true) ..
        " demolition_round=" ..
            bool_text((state.abilities[Ability.DemolitionRound.id] or {}).known == true) ..
        " vortex_bolt=" ..
            bool_text((state.abilities[Ability.VortexBolt.id] or {}).known == true))
end

local function valid_hostile_target(state)
    if not state.target.exists or state.target.handle == nil then
        return false, "missing_current_target"
    end
    if state.target.reaction ~= "hostile" then
        return false, "target_not_hostile_or_unobserved"
    end
    if type(state.target.hpCurrent) == "number" and state.target.hpCurrent <= 0 then
        return false, "target_dead"
    end
    return true, "target_ready"
end

local function refresh_target_count(state)
    state.relevantTargets = Config.manualRelevantTargets
    state.targetCountSource = "manual"
    state.targetCountReason = Config.automaticTargetCount and
        "automatic_unavailable" or "automatic_disabled"

    if not Config.automaticTargetCount then
        return
    end
    if not state.target.position then
        state.targetCountReason = "target_position_unavailable"
        return
    end
    if not state.world or type(state.world.units) ~= "function" then
        state.targetCountReason = "world_units_unavailable"
        return
    end

    local ok, hostiles = pcall(state.world.units, state.world, {
        reaction = "hostile",
    })
    if not ok or type(hostiles) ~= "table" then
        state.targetCountReason = "hostile_units_unavailable"
        return
    end

    local count = 0
    local counted = {}
    for _, unit in ipairs(hostiles) do
        local handle = unit_handle(unit)
        local hp = unit_hp(unit)
        local alive = hp == nil or hp.current == nil or hp.current > 0
        local position = unit_position(unit)
        local distance = position_distance(state.target.position, position)
        if handle ~= nil and not counted[handle] and alive and
            type(distance) == "number" and
            distance <= Config.aoeClusterRadius then
            counted[handle] = true
            count = count + 1
        end
    end

    if state.target.handle ~= nil and not counted[state.target.handle] then
        count = count + 1
    end

    state.relevantTargets = math.max(1, count)
    state.targetCountSource = "automatic"
    state.targetCountReason = "target_centered_radius"
end

local function refresh_recharge_credit(state)
    if state.now >= Runtime.rechargeEffectIgnoreUntil and
        state.player.rechargeStatus == "ready" then
        if state.player.rechargePresent then
            Runtime.rechargeCredit = true
            Runtime.rechargeCreditExpiresAt = state.now + 4.0
        elseif state.now >= Runtime.rechargeCreditExpiresAt then
            Runtime.rechargeCredit = false
        end
    elseif state.now >= Runtime.rechargeCreditExpiresAt then
        Runtime.rechargeCredit = false
    end
    state.rechargeCredit = Runtime.rechargeCredit
end

local function ability_state(state, ability)
    return state.abilities[ability.id] or {}
end

local function action_lock_remaining(state)
    if type(state.gcdRemaining) ~= "number" then
        return nil, "gcd_unavailable"
    end
    if state.busy then
        if state.currentAction and type(state.currentAction.remaining) == "number" then
            return math.max(state.gcdRemaining, state.currentAction.remaining),
                "cast_or_channel"
        end
        return nil, "busy_without_timing"
    end
    return state.gcdRemaining, "gcd"
end

local function ability_failure_backoff(state, ability)
    local until_time = Runtime.failureBackoff[ability.id]
    if type(until_time) == "number" and state.now < until_time then
        return until_time - state.now
    end
    return nil
end

local function ability_ready(state, ability)
    local snapshot = ability_state(state, ability)
    if snapshot.known ~= true then return false, "not_owned" end
    if snapshot.invalidCost then return false, "malformed_resource_cost" end
    if snapshot.invalidCooldown then return false, "malformed_cooldown" end
    if snapshot.resolved ~= true then
        return false, "unresolved"
    end
    if snapshot.bound ~= true then
        return false, "not_on_quickbar"
    end

    local backoff = ability_failure_backoff(state, ability)
    if backoff ~= nil then
        return false, "failure_backoff=" .. string.format("%.2f", backoff)
    end

    if ability == Ability.HighVelocitySuperchargedCell or
        ability.requiresSupercharge == true then
        if state.player.superchargeStatus ~= "ready" then
            return false, "supercharge_unavailable"
        end
        if state.player.superchargePresent ~= true then
            return false, "supercharge_absent"
        end
        if type(state.player.superchargeStacks) ~= "number" then
            return false, "supercharge_stacks_unavailable"
        end
        if state.player.superchargeStacks < 10.0 then
            return false, "supercharge_stacks=" ..
                string.format("%.0f", state.player.superchargeStacks)
        end
    end

    if ability.offGcd == true then
        if snapshot.cooldownKnown == true then
            if snapshot.cooldown <= COOLDOWN_READY_SLACK then
                return true, "off_gcd_cooldown_ready"
            end
            return false, "off_gcd_cooldown"
        end
        if snapshot.ready == true then
            return true, "off_gcd_runtime_ready"
        end
        return false, "off_gcd_readiness_unavailable"
    end

    local starts_in = action_lock_remaining(state)
    if type(starts_in) ~= "number" then
        return false, "start_time_unavailable"
    end

    local vortex_required = (ability.conditionalReady == true and
            ability_state(state, Ability.GravRound).known == true) or
        ability.requiresVortex == true or
        (ability == Ability.VortexBolt and
            state.progression.level23Choice == Talent.GravitatingBolt)
    local vortex_proof = state.target.gravityVortexProof
    if vortex_required and vortex_proof ~= "effect" and
        vortex_proof ~= "grav_round_confirmed" then
        if vortex_proof == "unavailable" then
            return false, "gravity_vortex_unavailable"
        end
        return false, "gravity_vortex_absent"
    end

    if ability == Ability.HighImpactBolt and state.progression.chargedBarrel then
        local stacks = state.player.chargedBarrelStacks
        if type(stacks) ~= "number" then
            return false, "charged_barrel=?"
        end

        local whole_stacks = math.floor(stacks)
        local target_hp = state.target.hpPercent
        local player_target = safe_method(state.targetUnit, "type") == "player"
        local pressure = player_target and type(target_hp) == "number" and
            target_hp <= HIB_PVP_PRESSURE_HP_PERCENT
        local execute = player_target and type(target_hp) == "number" and
            target_hp <= HIB_PVP_EXECUTE_HP_PERCENT
        local moving = state.movementKnown == true and state.moving == true

        local preferred = Config.gunnery.strict_barrels and 5 or Config.hibPreferredBarrels
        local allow_hib = whole_stacks >= preferred or
            (whole_stacks >= Config.hibPressureBarrels and
                (moving or pressure)) or
            ((moving and pressure) or execute)
        if not allow_hib then
            return false, "charged_barrel=" .. tostring(whole_stacks)
        end
    end

    if snapshot.cooldownKnown == true then
        if snapshot.cooldown <= starts_in + COOLDOWN_READY_SLACK then
            if vortex_required then
                return true, "gravity_vortex_" .. tostring(vortex_proof) ..
                    "_and_cooldown"
            end
            return true, "cooldown_ready_at_start"
        end
        return false, "cooldown_not_ready_at_start"
    end
    if snapshot.ready == true then
        if vortex_required then
            return true, "gravity_vortex_" .. tostring(vortex_proof) ..
                "_and_runtime_ready"
        end
        return true, "runtime_ready"
    end
    return false, "readiness_unavailable"
end

local function paid_cost(state, ability)
    local snapshot = ability_state(state, ability)
    local cost = snapshot.hasResourceCost == true and snapshot.resourceCost or ability.fallbackCost
    if not GunneryKit.finite(cost) or cost < 0 then return nil end
    local maximum = state.player.energyMax
    local scale = GunneryKit.finite(maximum) and maximum > 0 and maximum / 100 or nil
    if snapshot.resourceCostSource == "fallback" then
        if not scale then return nil end
        cost = cost * scale
    end
    -- Channel metadata is the startup/per-tick charge, not the whole channel.
    -- Only the exact observed free-cell effect authorizes a free paid channel.
    if ability.channelTotalCost then
        if not scale then return nil end
        cost = math.max(cost, ability.channelTotalCost * scale)
    end
    if state.player.rechargeFree == true and cost > 0 then return 0 end
    return cost
end

local function recharge_can_rescue(state, projected)
    if not Config.autoRechargeCells or Runtime.rechargeCredit then
        return false
    end
    local maximum = state.player.energyMax
    if type(projected) ~= "number" or type(maximum) ~= "number" or
        maximum <= 0.0 then
        return false
    end
    local projected_percent = (projected / maximum) * 100.0
    if projected_percent < RECHARGE_RESCUE_FLOOR_PERCENT or
        projected_percent > 60.0 then
        return false
    end

    local recharge = ability_state(state, Ability.RechargeCells)
    if recharge.known ~= true or recharge.resolved ~= true or recharge.bound ~= true then
        return false
    end
    if type(gos.abilities.can_cast) ~= "function" then return false end
    local ok, admission = pcall(Mirror.call, ActiveLoadout, "can_cast", Ability.RechargeCells.id)
    return ok and type(admission) == "table" and admission.ok == true
end

local function resource_allows(state, ability)
    local cost = paid_cost(state, ability)
    if cost == nil then
        return false, "resource_cost_unavailable", nil, nil
    end
    if cost <= 0.0 then
        return true, "free", cost, state.player.energyCurrent
    end

    local current = state.player.energyCurrent
    local maximum = state.player.energyMax
    if not GunneryKit.finite(current) or not GunneryKit.finite(maximum) or
        maximum <= 0.0 or current < 0.0 or current > maximum then
        return false, "energy_unavailable", cost, nil
    end

    if state.player.rechargeFree == true then
        return true, "observed_free_cell", 0.0, current
    end
    if current < cost then
        return false, "insufficient_energy", cost, current - cost
    end

    local projected = current - cost
    local current_percent = (current / maximum) * 100.0
    local projected_percent = (projected / maximum) * 100.0

    -- High Impact Bolt is a rotational payoff, not filler. Gunnery guidance is
    -- to avoid entering HIB while already below roughly 60 Energy Cells, not
    -- to preserve 60 after paying its cost. Once the PvP barrel gate admits HIB,
    -- get it on cooldown instead of wasting pressure behind the generic floor.
    if ability == Ability.HighImpactBolt then
        if current_percent >= 60.0 then
            return true, "hib_priority_spend", cost, projected
        end
        if recharge_can_rescue(state, projected) then
            return true, "hib_recharge_rescue", cost, projected
        end
        return false, "hib_energy_low", cost, projected
    end

    if ability.defensiveHeal then
        return projected_percent >= Config.gunnery.heal_floor, "healing_reserve", cost, projected
    end

    if projected_percent >= Config.energyFloorPercent then
        return true, "energy_floor_ok", cost, projected
    end
    if recharge_can_rescue(state, projected) then
        return true, "recharge_rescue", cost, projected
    end
    return false, "energy_floor", cost, projected
end

local function can_cast(state, ability, options)
    options = options or {}
    if not GunneryKit.finite(state.player.hpCurrent) or state.player.hpCurrent <= 0 then
        return false, "player_dead_or_unknown"
    end
    if state.progression.choiceConflict then return false, "talent_choice_conflict" end
    if ability == Ability.FullAuto and ability_state(state, Ability.Boltstorm).known then
        return false, "replaced_by_boltstorm"
    end
    if ability == Ability.ChargedBolts and ability_state(state, Ability.GravRound).known then
        return false, "replaced_by_grav_round"
    end
    if ability == Ability.MedicalProbe and not
        (state.player.techOverride or state.player.barrelInstant) then
        return false, "instant_probe_proc_unavailable"
    end

    -- Supercharged Cell must not cancel a cast/channel already in progress.
    if ability == Ability.HighVelocitySuperchargedCell and
        (state.busy or (state.currentAction and
            type(state.currentAction.remaining) == "number" and
            state.currentAction.remaining > 0)) then
        return false, "cast_or_channel_active"
    end

    local ready, ready_reason = ability_ready(state, ability)
    if not ready then
        return false, ready_reason
    end

    if ability.targetless ~= true and ability.selfTarget ~= true then
        local target_ok, target_reason = valid_hostile_target(state)
        if not target_ok then
            return false, target_reason
        end
        -- Range is checked by shared Core cast admission.
    end

    if ability.stationary == true then
        local movement_override =
            ((ability == Ability.GravRound or ability == Ability.ChargedBolts or
                ability == Ability.ConcussiveRound) and state.player.techOverride == true) or
            (ability == Ability.GravRound and state.player.observedGravPrimer == true) or
            (ability == Ability.MedicalProbe and (state.player.techOverride or state.player.barrelInstant)) or
            ((ability == Ability.FullAuto or ability == Ability.Boltstorm) and
                state.progression.forcedMarch == true)
        if not movement_override then
            if not state.movementKnown then
                return false, "movement_unavailable"
            end
            if state.moving then
                return false, "moving"
            end
        end
    end

    if ability.exactOpenStart == true and options.ignoreExactOpenStart ~= true then
        if state.busy or type(state.gcdRemaining) ~= "number" or
            state.gcdRemaining > GROUND_START_SLACK then
            return false, "exact_open_start_locked"
        end
    end

    if ability.groundTarget == true and options.ignoreGroundStart ~= true then
        if state.busy or type(state.gcdRemaining) ~= "number" or
            state.gcdRemaining > GROUND_START_SLACK then
            return false, "ground_start_locked"
        end
    end

    if type(ability.fallbackCost) == "number" then
        local allowed, resource_reason = resource_allows(state, ability)
        if not allowed then
            return false, resource_reason
        end
    end

    if type(gos.abilities.can_cast) ~= "function" then return false, "core_admission_unavailable" end
    local explicit_target = ability.selfTarget and state.playerUnit or nil
    local ok, admission = pcall(Mirror.call, ActiveLoadout, "can_cast", ability.id, explicit_target)
    if not ok or type(admission) ~= "table" then return false, "core_admission_unavailable" end
    if admission.ok ~= true then
        return false, admission.reason or "core_admission_rejected",
            Config.abilityDiagnostics and admission or nil
    end
    return true, ready_reason, Config.abilityDiagnostics and admission or nil
end

local function can_queue_input(state)
    if state.now < Runtime.commandContentionUntil then
        return false, "command_contention=" ..
            string.format("%.3f", Runtime.commandContentionUntil - state.now)
    end

    if state.busy and state.currentAction and
        state.currentAction.ability and
        state.currentAction.ability.channel == true then
        return false, "channel_active=" .. state.currentAction.ability.id
    end

    local remaining, reason = action_lock_remaining(state)
    if remaining == nil then
        return false, reason
    end
    if remaining > Config.abilityQueueWindow then
        return false, "locked_for=" .. string.format("%.3f", remaining)
    end
    return true, "queue_open"
end

local function decision(ability, reason, priority, options, advisory)
    return {
        ability = ability,
        reason = reason,
        priority = priority,
        options = options or {},
        advisory = Config.abilityDiagnostics and advisory or nil,
    }
end

local function wait_decision(ability, reason, priority)
    return {
        wait = true,
        ability = ability,
        reason = reason,
        priority = priority,
        options = {},
    }
end

local function consider(state, ability, reason, priority)
    local castable, _, advisory = can_cast(state, ability)
    if castable then
        return decision(ability, reason, priority, nil, advisory)
    end
    return nil
end

local function consider_ground(state, ability, reason, priority)
    local castable, blocked, advisory = can_cast(state, ability)
    if castable then
        return decision(ability, reason, priority, { groundTarget = true }, advisory)
    end
    if blocked == "ground_start_locked" then
        local otherwise_castable = can_cast(state, ability, {
            ignoreGroundStart = true,
        })
        if otherwise_castable then
            return wait_decision(ability, "await_exact_ground_start", priority)
        end
    end
    return nil
end

local function consider_exact_open_start(state, ability, reason, priority)
    local castable, blocked, advisory = can_cast(state, ability)
    if castable then
        return decision(ability, reason, priority, nil, advisory)
    end
    if blocked == "exact_open_start_locked" then
        local otherwise_castable = can_cast(state, ability, {
            ignoreExactOpenStart = true,
        })
        if otherwise_castable then
            return wait_decision(ability, "await_exact_open_start", priority)
        end
    end
    return nil
end

local function select_selfheal(state)
    local cfg, hp = Config.gunnery, state.player.hpPercent
    if not cfg.auto_self_heal or not GunneryKit.finite(hp) or hp <= 0 then return nil end
    if hp <= cfg.bacta_hp then
        local action = consider(state, Ability.BactaInfusion, "emergency_bacta_self", 0)
        if action then return action end
    end
    if hp <= cfg.probe_hp then
        local action = consider(state, Ability.MedicalProbe,
            state.player.barrelInstant and "five_barrel_instant_probe_self" or "tech_instant_probe_self", 1)
        if action then return action end
        if Runtime.techHealReservedUntil and state.now < Runtime.techHealReservedUntil then
            return wait_decision(Ability.MedicalProbe, "await_observed_tech_override_for_selfheal", 1)
        end
    end
    if hp <= cfg.medshot_hp then
        return consider(state, Ability.MedShot, "critical_free_med_shot_self", 2)
    end
end

local function select_offgcd_action(state)
    if state.now < Runtime.commandContentionUntil then
        return nil
    end
    if state.busy then
        return nil
    end

    local cfg, hp = Config.gunnery, state.player.hpPercent
    if cfg.auto_echoing and GunneryKit.finite(hp) and hp <= cfg.echoing_hp then
        local action = consider(state, Ability.EchoingDeterrence, "emergency_echoing_self", 0)
        if action then return action end
    end
    local adrenaline_hp = state.progression.adrenalSurge and cfg.adrenal_surge_threshold and
        60 or Config.adrenalineRushHpPercent
    if Config.autoAdrenalineRush and
        type(state.player.hpPercent) == "number" and
        state.player.hpPercent <= adrenaline_hp then
        local selected = consider(state, Ability.AdrenalineRush,
            "emergency_hp_" .. string.format("%.0f", state.player.hpPercent), 0)
        if selected then
            return selected
        end
    end

    if Config.autoReactiveShield and
        type(state.player.hpPercent) == "number" and
        state.player.hpPercent <= Config.reactiveShieldHpPercent then
        local selected = consider(state, Ability.ReactiveShield,
            "hp_" .. string.format("%.0f", state.player.hpPercent), 1)
        if selected then
            return selected
        end
    end

    if Config.autoDiversion and
        type(state.player.hpPercent) == "number" and
        state.player.hpPercent <= Config.diversionHpPercent then
        local selected = consider(state, Ability.Diversion,
            "selected_defensive_hp_" ..
                string.format("%.0f", state.player.hpPercent), 1)
        if selected then
            return selected
        end
    end

    if Config.autoConcussionCharge and valid_hostile_target(state) and
        type(state.player.hpPercent) == "number" and
        state.player.hpPercent <= Config.concussionChargeHpPercent and
        type(state.target.distance) == "number" and
        state.target.distance <= Config.concussionChargeMaxRange then
        local selected = consider(state, Ability.ConcussionCharge,
            "defensive_knockback_hp_" ..
                string.format("%.0f", state.player.hpPercent), 2)
        if selected then
            return selected
        end
    end

    -- Reserve the actual Tech Override proc, not an invented instant-cast timer.
    -- The bounded reservation below only prevents a filler stealing its delivery.
    if cfg.auto_self_heal and cfg.auto_tech_heal and GunneryKit.finite(hp) and hp > 0 and
        hp <= cfg.probe_hp and not state.player.techOverride and not state.player.barrelInstant and
        (not Runtime.techHealReservedUntil or state.now >= Runtime.techHealReservedUntil) and
        type(state.gcdRemaining) == "number" and state.gcdRemaining <= GROUND_START_SLACK then
        local probe = ability_state(state, Ability.MedicalProbe)
        local bacta_due = hp <= cfg.bacta_hp and can_cast(state, Ability.BactaInfusion)
        if not bacta_due and probe.known and probe.resolved and probe.bound and
            probe.cooldownKnown and probe.cooldown <= COOLDOWN_READY_SLACK and
            resource_allows(state, Ability.MedicalProbe) then
            local action = consider(state, Ability.TechOverride, "tech_override_heal_reservation", 2)
            if action then return action end
        end
    end

    local hostile = valid_hostile_target(state)
    if hostile and cfg.auto_interrupt then
        local cast = GunneryKit.target_cast(state)
        if cast and cast.active == true and cast.has_timing == true and
            GunneryKit.finite(cast.remaining) and cast.remaining > 0 then
            local action = consider(state, Ability.DisablingShot, "opt_in_current_target_interrupt", 2)
            if action then return action end
        end
    end
    if hostile and Config.autoSuperchargedCelerity then
        local selected = consider(state, Ability.SuperchargedCelerity,
            "selected_celerity_supercharge_" ..
                optional_number(state.player.superchargeStacks, "%.0f"), 3)
        if selected then
            return selected
        end
    end

    if hostile and Config.autoSuperchargedCell then
        local selected = consider(state, Ability.HighVelocitySuperchargedCell,
            "supercharge_" ..
                optional_number(state.player.superchargeStacks, "%.0f"), 4)
        if selected then
            return selected
        end
    end

    if Config.autoRechargeCells and state.player.rechargeFree ~= true and
        (hostile or (cfg.auto_self_heal and GunneryKit.finite(hp) and hp <= cfg.probe_hp)) and
        type(state.player.energyPercent) == "number" and
        state.player.energyPercent <= Config.rechargeCellsThresholdPercent then
        local selected = consider(state, Ability.RechargeCells,
            "energy_percent_" ..
                string.format("%.0f", state.player.energyPercent), 5)
        if selected then
            return selected
        end
    end

    return nil
end

local function select_priority_action(state)
    local multi = Config.aoeEnabled and state.relevantTargets >= 2
    local aoe = Config.aoeEnabled and
        state.relevantTargets >= Config.aoeMinTargets
    local vortex_proven = state.target.gravityVortexProof == "effect" or
        state.target.gravityVortexProof == "grav_round_confirmed"
    local thermonuclear =
        state.progression.level39Choice == Talent.ThermonuclearPlasma
    local gravitating_bolt =
        state.progression.level23Choice == Talent.GravitatingBolt
    local vortex_known = ability_state(state, Ability.VortexBolt).known == true

    -- Thermonuclear Plasma cannot spread until the primary target has Gravity
    -- Vortex. Gravitating Bolt also makes Vortex Bolt substantially stronger
    -- on a vortexed target, so establish the debuff first in those cases.
    if not vortex_proven and
        ((thermonuclear and multi) or
            (gravitating_bolt and vortex_known and not aoe)) then
        local selected = consider(state, Ability.GravRound,
            "gravity_vortex_setup", 6)
        if selected then
            return selected
        end
    end

    if thermonuclear and multi and vortex_proven then
        local spread_due = Runtime.plasmaSpreadTargetHandle ~= state.target.handle or
            state.now >= Runtime.plasmaSpreadUntil or
            state.relevantTargets > Runtime.plasmaSpreadCount
        if spread_due then
            local selected = consider(state, Ability.PlasmaGrenade,
                "thermonuclear_vortex_spread_" ..
                    tostring(state.relevantTargets), 7)
            if selected then
                return selected
            end
        end
    end

    if aoe then
        local selected = consider_ground(state, Ability.MortarVolley,
            "aoe_" .. tostring(state.relevantTargets), 10)
        if selected then
            return selected
        end

        if thermonuclear and vortex_proven then
            selected = consider(state, Ability.DemolitionRound, "thermonuclear_demolition_aoe", 10)
            if selected then return selected end
        end
        if state.progression.level23Choice == Talent.GravTrio and state.relevantTargets <= 3 then
            selected = consider(state, Ability.GravRound, "grav_trio_three_target_filler", 11)
            if selected then return selected end
        end
        selected = consider_ground(state, Ability.HailOfBolts,
            "aoe_" .. tostring(state.relevantTargets), 11)
        if selected then
            return selected
        end

        if state.relevantTargets >= STICKY_GRENADE_MIN_TARGETS then
            selected = consider(state, Ability.StickyGrenade,
                "selected_sticky_aoe_" .. tostring(state.relevantTargets), 12)
            if selected then
                return selected
            end
        end
    end

    do
        local selected = consider(state, Ability.VortexBolt,
            vortex_proven and "vortex_bolt" or "vortex_bolt_pre_setup", 20)
        if selected then
            return selected
        end
    end

    -- Once Demo/HIB are learned, do not spend those cooldowns into an
    -- un-vortexed target. This also repairs a fresh target after Vortex Bolt
    -- when the selected level-23 talent does not itself require prior Vortex.
    if not vortex_proven and
        (ability_state(state, Ability.DemolitionRound).known == true or
            ability_state(state, Ability.HighImpactBolt).known == true) then
        local selected = consider(state, Ability.GravRound,
            "gravity_vortex_setup", 21)
        if selected then
            return selected
        end
    end

    -- Spend a real Curtain of Fire reset before another Grav can overwrite it.
    -- No tactical equipment or fabricated ICD is required for this branch.
    if state.player.curtainOfFire then
        local selected = consider_exact_open_start(state, Ability.Boltstorm, "curtain_of_fire_boltstorm", 21)
        if selected then return selected end
    end

    do
        local selected = consider(state, Ability.DemolitionRound,
            "demolition_round", 22)
        if selected then
            return selected
        end
    end

    do
        local selected = consider(state, Ability.HighImpactBolt,
            "hib_barrels_" ..
                optional_number(state.player.chargedBarrelStacks, "%.0f"), 23)
        if selected then
            return selected
        end
    end

    if Config.gunnery.use_electro_net then
        local selected = consider(state, Ability.ElectroNet, "electro_net_damage", 24)
        if selected then return selected end
    end
    do
        local channel = ability_state(state, Ability.Boltstorm).known and Ability.Boltstorm or Ability.FullAuto
        local selected = consider_exact_open_start(state, channel,
            channel == Ability.Boltstorm and "boltstorm" or "leveling_full_auto", 25)
        if selected then
            return selected
        end
    end

    local cfg, hp = Config.gunnery, state.player.hpPercent
    if cfg.mobile_tech_override and state.moving and not state.busy and
        not state.player.techOverride and not state.player.observedGravPrimer and
        GunneryKit.finite(hp) and hp > cfg.probe_hp then
        local filler = ability_state(state, Ability.GravRound).known and Ability.GravRound or Ability.ChargedBolts
        local snapshot = ability_state(state, filler)
        if snapshot.known and snapshot.resolved and snapshot.bound and
            snapshot.cooldownKnown and snapshot.cooldown <= COOLDOWN_READY_SLACK and resource_allows(state, filler) then
            local selected = consider(state, Ability.TechOverride, "mobile_tech_override", 29)
            if selected then return selected end
        end
    end
    do
        local reason = state.player.observedGravPrimer and
            "grav_primer_filler" or (state.player.techOverride and "tech_override_filler" or "gunnery_filler")
        local selected = consider(state, Ability.GravRound, reason, 30)
        if selected then
            return selected
        end
    end

    do
        local selected = consider(state, Ability.ChargedBolts,
            "pre_grav_filler", 31)
        if selected then
            return selected
        end
    end

    if Config.movingExplosiveRound and state.moving then
        local selected = consider(state, Ability.ExplosiveRound,
            "mobile_paid_filler", 40)
        if selected then
            return selected
        end
    end

    return consider(state, Ability.HammerShot, "free_filler", 50)
end

local function executor_options(state, ability, phase)
    local target_handle = "none"
    if ability.selfTarget then
        target_handle = state.player.handle or "none"
    elseif not ability.targetless then
        target_handle = state.target.handle or "none"
    end
    return {
        idempotencyKey = table.concat({
            "gunnery",
            phase or "regular",
            ability.id,
            tostring(target_handle),
        }, ":"),
    }
end

local function admission_fields(result)
    if type(result) ~= "table" then return "invalid_result" end
    return table.concat({
        tostring(result.reason or "-"),
        "code=" .. tostring(result.code or "-"),
        "mode=" .. tostring(result.target_mode or "-"),
        "target=" .. tostring(result.target_handle or "-"),
        "requested=" .. tostring(result.requested_target_handle or "-"),
        "valid=" .. bool_text(result.target_valid == true),
        "wait_ms=" .. tostring(result.wait_ms or "-"),
        "sample=" .. bool_text(result.client_check_available == true),
        "eff=" .. tostring(result.client_eff_result or "-"),
        "los=" .. bool_text(result.client_los_checked == true),
        "thread=" .. tostring(result.client_check_thread_id or "-"),
        "qpc=" .. tostring(result.client_check_qpc or "-"),
        "unavailable_at=" .. tostring(result.client_check_unavailable_at or "-"),
        "blocked=" .. bool_text(result.command_admission_blocked == true),
        "lifecycle_mask=" .. tostring(result.lifecycle_unavailable_mask or "-"),
    }, ",")
end

local function log_admission_diagnostic(state, selected, phase, options, result)
    if not Config.abilityDiagnostics then return end
    local pending = type(result) == "table" and result.admission_pending == true
    local trace = Runtime.admissionDiagnostic
    if pending then
        trace = trace or { since = state.now, count = 0, switches = 0, lastLogAt = -math.huge }
        if trace.key and trace.key ~= options.idempotencyKey then
            trace.switches = trace.switches + 1
        end
        trace.key = options.idempotencyKey
        trace.count = trace.count + 1
        Runtime.admissionDiagnostic = trace
        if trace.count > 1 and state.now - trace.lastLogAt <
            Config.abilityDiagnosticsInterval then return end
        trace.lastLogAt = state.now
    else
        Runtime.admissionDiagnostic = nil
    end

    local core = type(result) == "table" and result.core or nil
    log_line("info", "gunnery admission: ability=" .. selected.ability.id ..
        " phase=" .. phase .. " choice=" .. selected.reason ..
        " lua_key=" .. options.idempotencyKey ..
        " pending_count=" .. tostring(trace and trace.count or 0) ..
        " lua_key_changes=" .. tostring(trace and trace.switches or 0) ..
        " pending_ms=" .. optional_number(trace and (state.now - trace.since) * 1000, "%.0f") ..
        " backoff_ms=" .. optional_number((ability_failure_backoff(state, selected.ability) or 0) * 1000, "%.0f") ..
        " gcd=" .. optional_number(state.gcdRemaining, "%.3f") ..
        " busy=" .. bool_text(state.busy) ..
        " distance=" .. optional_number(state.target.distance, "%.1f") ..
        " advisory={" .. admission_fields(selected.advisory) .. "}" ..
        " submit=" .. tostring(type(result) == "table" and result.disposition or "invalid") ..
        " handle=" .. tostring(type(result) == "table" and result.command_handle or "-") ..
        " core={" .. admission_fields(core) .. "}")
end

local function log_cast_failure(state, selected, result)
    Runtime.failureBackoff[selected.ability.id] =
        state.now + FAILURE_BACKOFF_SECONDS

    local reason = type(result) == "table" and
        (result.reason or result.code or result.core and result.core.command_state) or
        "invalid_result"
    if reason == "ability_command_busy" or reason == "bridge_busy" or
        reason == "command_busy" or reason == "ability_submission_pending" then
        Runtime.commandContentionUntil = math.max(Runtime.commandContentionUntil,
            state.now + COMMAND_CONTENTION_BACKOFF_SECONDS)
    end

    log_warn("cast failed: ability=" .. selected.ability.id ..
        " reason=" .. tostring(reason))
end

local function track_command(state, selected, result, phase)
    local cost = paid_cost(state, selected.ability) or 0.0
    local consumes_recharge = Runtime.rechargeCredit and cost > 0.0
    local target_handle
    if selected.ability.selfTarget then target_handle = state.player.handle
    elseif not selected.ability.targetless then target_handle = state.target.handle end
    if selected.reason == "tech_override_heal_reservation" then
        Runtime.techHealReservedUntil = state.now + 1.5
    end
    Runtime.pendingAction = {
        ability = selected.ability,
        reason = selected.reason,
        phase = phase,
        commandHandle = result.command_handle,
        targetHandle = target_handle,
        relevantTargets = state.relevantTargets,
        consumesRecharge = consumes_recharge,
    }
    Runtime.commandTargetHandle = target_handle

    -- Reserve the one-shot credit as soon as Core accepts a paid command. If
    -- that command later fails, a fresh observed Recharge Cells buff restores
    -- the credit after the short stale-effect suppression window.
    if consumes_recharge then
        Runtime.rechargeCredit = false
        Runtime.rechargeCreditExpiresAt = 0.0
        Runtime.rechargeEffectIgnoreUntil = state.now + 1.0
    end
end

local function submit_action(state, selected, phase)
    phase = phase or (selected.ability.groundTarget and "ground" or "regular")
    local options = executor_options(state, selected.ability, phase)
    local target = selected.ability.selfTarget and state.playerUnit or nil
    if selected.ability.selfTarget then options.target_fallback = "none" end
    local result = Executor:submit(Mirror.ability(ActiveLoadout,selected.ability.id), target, options)
    if type(result) == "table" and result.admission_pending == true then
        -- Admission owns no executor command. Retain the exact request locally
        -- so Core can correlate and publish its one-tick result.
        Runtime.pendingAdmission = {
            selected = selected,
            phase = phase,
            requestKey = options.idempotencyKey,
            playerHandle = state.player.handle,
        }
        if Config.abilityDiagnostics then
            log_admission_diagnostic(state, selected, phase, options, result)
        end
        return false
    end

    Runtime.pendingAdmission = nil
    if type(result) ~= "table" or result.accepted ~= true then
        log_cast_failure(state, selected, result)
        if Config.abilityDiagnostics then
            log_admission_diagnostic(state, selected, phase, options, result)
        end
        return false
    end

    if Config.abilityDiagnostics then
        log_admission_diagnostic(state, selected, phase, options, result)
    end
    track_command(state, selected, result, phase)

    local snapshot = ability_state(state, selected.ability)
    local cost = paid_cost(state, selected.ability)
    log_info("cast queued: phase=" .. phase ..
        " ability=" .. selected.ability.id ..
        " reason=" .. selected.reason ..
        " target=" .. tostring(state.target.handle or "none") ..
        " targets=" .. tostring(state.relevantTargets) ..
        " count_source=" .. tostring(state.targetCountSource) ..
        " energy=" .. optional_number(state.player.energyCurrent, "%.0f") ..
        "/" .. optional_number(state.player.energyMax, "%.0f") ..
        " (" .. optional_number(state.player.energyPercent, "%.0f") .. "%)" ..
        " cost=" .. optional_number(cost, "%.0f") ..
        " cost_source=" .. tostring(snapshot.resourceCostSource or "none") ..
        " recharge_credit=" .. bool_text(Runtime.rechargeCredit))
    return true
end

local function service_pending_admission(state)
    local pending = Runtime.pendingAdmission
    if not pending then return false end

    local ability = pending.selected.ability
    local options = executor_options(state, ability, pending.phase)
    local target_ok = true
    if not ability.selfTarget and not ability.targetless then
        target_ok = valid_hostile_target(state)
    end
    local player_matches = state.player.handle == pending.playerHandle
    if not target_ok or not player_matches or
        options.idempotencyKey ~= pending.requestKey then
        if Config.abilityDiagnostics then
            log_line("info", "gunnery admission released: ability=" .. ability.id ..
                " previous_key=" .. pending.requestKey ..
                " current_key=" .. options.idempotencyKey ..
                " reason=" .. (not target_ok and "target_invalid" or
                    (not player_matches and "player_changed" or "identity_changed")))
        end
        Runtime.pendingAdmission = nil
        return false
    end

    submit_action(state, pending.selected, pending.phase)
    return true
end

local function action_started(tracked)
    if not tracked then
        return false
    end
    local status = Executor:status()
    return type(status) == "table" and
        status.command_handle == tracked.commandHandle and
        status.core.acknowledged == true
end

local function apply_started_action(state, tracked)
    if tracked.ability == Ability.GravRound then
        if state.progression.chargedBarrel then
            Runtime.chargedBarrelStacks = math.min(CHARGED_BARREL_REQUIRED,
                Runtime.chargedBarrelStacks + (state.progression.targetLock and 2 or 1))
            Runtime.chargedBarrelUntil =
                state.now + CHARGED_BARREL_PROOF_TTL
            log_info("Charged Barrel evidence: source=Grav Round acknowledged" ..
                " stacks=" .. tostring(Runtime.chargedBarrelStacks))
        end
        Runtime.gravPrimerUntil = 0.0
    elseif tracked.ability == Ability.VortexBolt then
        Runtime.gravPrimerUntil = state.now + GRAV_PRIMER_PROOF_TTL
        log_info("Grav Primer evidence: source=Vortex Bolt acknowledged" ..
            " ttl=" .. string.format("%.1f", GRAV_PRIMER_PROOF_TTL))
    elseif (tracked.ability == Ability.HighImpactBolt or tracked.ability == Ability.MedicalProbe) and
        state.progression.chargedBarrel then
        Runtime.chargedBarrelStacks = 0
        Runtime.chargedBarrelUntil = 0.0
        log_info("Charged Barrel consumed by " .. tracked.ability.id)
    elseif tracked.ability == Ability.PlasmaGrenade and
        state.progression.level39Choice == Talent.ThermonuclearPlasma and
        type(tracked.targetHandle) == "string" then
        Runtime.plasmaSpreadTargetHandle = tracked.targetHandle
        Runtime.plasmaSpreadUntil = state.now + GRAVITY_VORTEX_PROOF_TTL
        Runtime.plasmaSpreadCount = type(tracked.relevantTargets) == "number" and
            tracked.relevantTargets or state.relevantTargets
        log_info("Thermonuclear Plasma spread confirmed: target=" ..
            tracked.targetHandle .. " targets=" ..
            tostring(Runtime.plasmaSpreadCount))
    end

    if tracked.ability == Ability.RechargeCells then
        Runtime.rechargeCredit = true
        Runtime.rechargeCreditExpiresAt = state.now + 4.0
        log_info("Recharge Cells confirmed: next paid attack credited")
    elseif tracked.consumesRecharge then
        log_info("Recharge Cells credit consumed by " .. tracked.ability.id)
    end
end

local function service_pending_action(state)
    local pending = Runtime.pendingAction
    if not pending then
        return false
    end

    if action_started(pending) then
        apply_started_action(state, pending)
        log_info("action started: ability=" .. pending.ability.id ..
            " phase=" .. tostring(pending.phase))
        Runtime.pendingAction = nil
        Runtime.commandTargetHandle = nil
        return true
    end

    local status = Executor:status()
    if type(status) == "table" and
        status.command_handle == pending.commandHandle and
        status.core.known == true and status.core.terminal == true then
        if pending.ability == Ability.RechargeCells and
            status.core.acknowledged == true then
            apply_started_action(state, pending)
        end
        if status.core.acknowledged ~= true and
            status.core.state ~= "submitted" then
            Runtime.failureBackoff[pending.ability.id] =
                state.now + FAILURE_BACKOFF_SECONDS
            Runtime.commandContentionUntil = math.max(Runtime.commandContentionUntil,
                state.now + COMMAND_CONTENTION_BACKOFF_SECONDS)
            log_warn("command terminal without start: ability=" ..
                pending.ability.id ..
                " state=" .. tostring(status.core.state) ..
                " reason=" .. tostring(status.reason))
        end
        Runtime.pendingAction = nil
        Runtime.commandTargetHandle = nil
        return true
    end

    if not Executor:owns_command() then
        Runtime.pendingAction = nil
        Runtime.commandTargetHandle = nil
        return false
    end

    return true
end

local function service_orphan_executor()
    if not Executor:owns_command() then
        Runtime.orphanPendingLogged = false
        return false
    end
    if Runtime.pendingAction then
        Runtime.orphanPendingLogged = false
        return false
    end
    local status = Executor:status()
    local owner_key = type(status) == "table" and status.idempotency_key or nil
    if type(owner_key) == "string" and owner_key:match("^[^:]+:cleanse:") then
        return true -- Expected shared utility; still await Core's terminal state.
    end

    if not Runtime.orphanPendingLogged then
        Runtime.orphanPendingLogged = true
        log_warn("untracked executor command; awaiting exact terminal status")
    end
    return true
end

local function reset_transient_state()
    Runtime.techHealReservedUntil = nil
    Runtime.pendingAdmission = nil
    Runtime.pendingAction = nil
    Runtime.commandTargetHandle = nil
    Runtime.orphanPendingLogged = false
    Runtime.rechargeCredit = false
    Runtime.rechargeCreditExpiresAt = 0.0
    Runtime.rechargeEffectIgnoreUntil = 0.0
    Runtime.commandContentionUntil = 0.0
    Runtime.admissionDiagnostic = nil
end

local function log_core_lifecycle()
    local status = Executor:status()
    if type(status) ~= "table" or
        (status.core.known ~= true and status.command_handle == nil) then
        return
    end

    local key = table.concat({
        tostring(status.command_handle or "-"),
        tostring(status.ability or "-"),
        tostring(status.core.state or "-"),
        tostring(status.disposition or "-"),
        tostring(status.reason or "-"),
        tostring(status.core.acknowledged == true),
        tostring(status.core.terminal == true),
        tostring(status.last_lifecycle_sequence or 0),
        tostring(status.game_result_known == true),
        tostring(status.game_result or 0),
        tostring(status.game_result_source or "-"),
        tostring(status.core.activation_proven == true),
        tostring(status.core.cleanup_pending == true),
    }, "|")
    if Runtime.lastCoreLifecycleKey == key then
        return
    end
    Runtime.lastCoreLifecycleKey = key

    log_debug("core lifecycle: command=" ..
        tostring(status.command_handle or "-") ..
        " ability=" .. tostring(status.ability or "-") ..
        " state=" .. tostring(status.core.state or "-") ..
        " executor=" .. tostring(status.disposition or "-") ..
        " reason=" .. tostring(status.reason or "-") ..
        " acknowledged=" .. bool_text(status.core.acknowledged == true) ..
        " terminal=" .. bool_text(status.core.terminal == true) ..
        " game_result=" .. tostring(status.game_result_name or "unknown") ..
        " game_code=" .. tostring(status.game_result or 0) ..
        " game_source=" .. tostring(status.game_result_source or "-") ..
        " activation_proven=" .. bool_text(status.core.activation_proven == true) ..
        " cleanup_pending=" .. bool_text(status.core.cleanup_pending == true))
end

local function log_action_rejection_capture()
    local status = Executor:status()
    local sequence = type(status) == "table" and
        status.action_rejection_sequence or nil
    if type(status) ~= "table" or
        status.action_rejection_observed ~= true or
        type(sequence) ~= "number" or
        sequence <= Runtime.lastActionRejectionSequence then
        return
    end
    Runtime.lastActionRejectionSequence = sequence
    log_warn("Core action rejection: command=" ..
        tostring(status.command_handle or "-") ..
        " ability=" .. tostring(status.ability or "-") ..
        " rejected_action=" ..
        tostring(status.action_rejection_name or "nil") ..
        " sequence=" .. tostring(sequence))
end

local function log_decision_state(state, phase, detail)
    if not Config.decisionLog then
        return
    end
    local key = table.concat({
        phase,
        tostring(detail or "-"),
        tostring(state.target.handle or "-"),
        tostring(state.moving),
        tostring(state.gcdRemaining or "-"),
        tostring(state.player.energyCurrent or "-"),
        tostring(state.player.superchargeStacks or "-"),
        tostring(state.player.chargedBarrelStacks or "-"),
        tostring(state.player.gravPrimerPresent == true),
        tostring(state.progression.level23Choice or "-"),
        tostring(state.progression.level27Choice or "-"),
        tostring(state.progression.level39Choice or "-"),
        tostring(state.progression.level43Choice or "-"),
        tostring(state.target.gravityVortexPresent),
        tostring(state.target.gravityVortexProof or "-"),
        tostring(state.target.gravityVortexEventRemaining or "-"),
        tostring(state.relevantTargets or "-"),
        tostring(state.targetCountSource or "-"),
    }, "|")
    if Runtime.lastDecisionLogKey == key then
        return
    end
    Runtime.lastDecisionLogKey = key

    log_debug("state: phase=" .. phase ..
        " detail=" .. tostring(detail or "-") ..
        " target=" .. tostring(state.target.handle or "-") ..
        " reaction=" .. tostring(state.target.reaction or "-") ..
        " distance=" .. optional_number(state.target.distance, "%.1f") ..
        " moving=" .. bool_text(state.moving) ..
        " speed=" .. optional_number(state.speed, "%.3f") ..
        " busy=" .. bool_text(state.busy) ..
        " gcd=" .. optional_number(state.gcdRemaining, "%.3f") ..
        " energy=" .. optional_number(state.player.energyCurrent, "%.0f") ..
        "/" .. optional_number(state.player.energyMax, "%.0f") ..
        " (" .. optional_number(state.player.energyPercent, "%.0f") .. "%)" ..
        " resource=" .. tostring(state.player.resourceKind or "-") ..
        " supercharge=" ..
            optional_number(state.player.superchargeStacks, "%.0f") ..
        " supercharge_status=" ..
            tostring(state.player.superchargeStatus or "-") ..
        " charged_barrel=" ..
            optional_number(state.player.chargedBarrelStacks, "%.0f") ..
        " grav_primer=" .. bool_text(state.player.gravPrimerPresent) ..
        " choices=" .. tostring(state.progression.level23Choice or "-") ..
            "/" .. tostring(state.progression.level27Choice or "-") ..
            "/" .. tostring(state.progression.level39Choice or "-") ..
            "/" .. tostring(state.progression.level43Choice or "-") ..
        " gravity_vortex=" .. bool_text(state.target.gravityVortexPresent) ..
        " gravity_vortex_status=" ..
            tostring(state.target.gravityVortexStatus or "-") ..
        " gravity_vortex_proof=" ..
            tostring(state.target.gravityVortexProof or "-") ..
        " gravity_vortex_event=" ..
            optional_number(state.target.gravityVortexEventRemaining, "%.1f") ..
        " targets=" .. tostring(state.relevantTargets) ..
        " count_source=" .. tostring(state.targetCountSource) ..
        " count_reason=" .. tostring(state.targetCountReason) ..
        " recharge_credit=" .. bool_text(Runtime.rechargeCredit))
end

local function log_ability_diagnostics(state, selected)
    if not Config.abilityDiagnostics or
        state.now - Runtime.lastAbilityDiagnosticAt <
            Config.abilityDiagnosticsInterval then
        return
    end
    Runtime.lastAbilityDiagnosticAt = state.now

    local parts = {}
    for _, ability in ipairs(AbilityList) do
        local snapshot = ability_state(state, ability)
        local castable, reason = can_cast(state, ability)
        local cost = paid_cost(state, ability)
        parts[#parts + 1] = ability.id ..
            "(known=" .. bool_text(snapshot.known == true) ..
            "/resolved=" .. bool_text(snapshot.resolved == true) ..
            "/bound=" .. bool_text(snapshot.bound == true) ..
            "/ready=" .. bool_text(snapshot.ready == true) ..
            "/cd=" .. optional_number(snapshot.cooldown, "%.2f") ..
            "/cost=" .. optional_number(cost, "%.0f") ..
            "/" .. tostring(snapshot.resourceCostSource or "none") ..
            ")=" .. tostring(reason or castable)
    end

    local selected_text = selected and
        ((selected.wait and "wait:" or "") ..
        selected.ability.id .. ":" .. selected.reason) or "none"
    log_line("info", "ability diagnostics: selected=" .. selected_text ..
        " energy=" .. optional_number(state.player.energyCurrent, "%.0f") ..
        "/" .. optional_number(state.player.energyMax, "%.0f") ..
        " (" .. optional_number(state.player.energyPercent, "%.0f") .. "%)" ..
        " supercharge=" ..
            optional_number(state.player.superchargeStacks, "%.0f") ..
        " charged_barrel=" ..
            optional_number(state.player.chargedBarrelStacks, "%.0f") ..
        " grav_primer=" .. bool_text(state.player.gravPrimerPresent) ..
        " choices=" .. tostring(state.progression.level23Choice or "-") ..
            "/" .. tostring(state.progression.level27Choice or "-") ..
            "/" .. tostring(state.progression.level39Choice or "-") ..
            "/" .. tostring(state.progression.level43Choice or "-") ..
        " gravity_vortex=" .. bool_text(state.target.gravityVortexPresent) ..
        " gravity_vortex_proof=" ..
            tostring(state.target.gravityVortexProof or "-") ..
        " gravity_vortex_event=" ..
            optional_number(state.target.gravityVortexEventRemaining, "%.1f") ..
        " target_distance=" .. optional_number(state.target.distance, "%.1f") ..
        " moving=" .. bool_text(state.moving) ..
        " targets=" .. tostring(state.relevantTargets) ..
        " | " .. table.concat(parts, " | "))
end

local function log_no_decision_diagnostics(state)
    if not Config.diagnosticsLogging then return end
    if state.now - Runtime.lastNoDecisionDiagnosticAt < 1.0 then
        return
    end
    Runtime.lastNoDecisionDiagnosticAt = state.now
    log_warn("no castable priority: energy=" ..
        optional_number(state.player.energyCurrent, "%.0f") ..
        "/" .. optional_number(state.player.energyMax, "%.0f") ..
        " (" .. optional_number(state.player.energyPercent, "%.0f") .. "%)" ..
        " gravity_vortex_proof=" ..
            tostring(state.target.gravityVortexProof or "-") ..
        " gravity_vortex_event=" ..
            optional_number(state.target.gravityVortexEventRemaining, "%.1f") ..
        " distance=" .. optional_number(state.target.distance, "%.1f") ..
        " moving=" .. bool_text(state.moving) ..
        " targets=" .. tostring(state.relevantTargets) ..
        " count_source=" .. tostring(state.targetCountSource))
end

Runtime.cleanse = require("combat.cleanse")
Runtime.cleanseController = require("commando.cleanse").new(Executor)

local CombatMedicActionWindow = HealerActionWindow.new({
    idPrefix = "actions",
    scriptId = SCRIPT_ID,
    visibleKey = "medic_action_window_visible",
    xKey = "medic_action_window_x",
    yKey = "medic_action_window_y",
    title = "COMBAT MEDIC ACTIONS",
    readyText = "COMBAT MEDIC READY",
    resourceLabel = "RESOURCE RECOVERY",
    displayAbility = function(name) return Mirror.ability(ActiveLoadout,name) or name end,
    log = log_line,
    healActions = {
        ["Bacta Infusion"] = true,
        ["Advanced Medical Probe"] = true,
        ["Medical Probe"] = true,
        ["Med Shot"] = true,
        ["Kolto Bomb"] = true,
        ["Successive Treatment"] = true,
    },
    groupHeals = {
        ["Kolto Bomb"] = true,
        ["Successive Treatment"] = true,
    },
    protectActions = {
        ["Trauma Probe"] = true,
        ["Reactive Shield"] = true,
        ["Adrenaline Rush"] = true,
        ["Echoing Deterrence"] = true,
    },
    cleanseActions = { ["Field Aid"] = true },
    resourceActions = { ["Recharge Cells"] = true },
    supportActions = {
        ["Supercharged Kolto Cell"] = true,
        ["Tech Override"] = true,
    },
    dpsActions = {
        ["Hammer Shot"] = true,
        ["Charged Bolts"] = true,
        ["High Impact Bolt"] = true,
        ["Full Auto"] = true,
        ["Electro Net"] = true,
    },
})

local function combat_medic_action_config(policy)
    policy = type(policy) == "table" and policy or {}
    return {
        visible = policy.action_window_visible,
        x = policy.action_window_x,
        y = policy.action_window_y,
        fontSize = policy.action_window_font_size,
        rows = policy.action_window_rows,
        lifetime = policy.action_window_lifetime,
        showHealAmount = policy.action_window_show_heal_amount,
        showDamage = policy.action_window_show_damage,
        showProcs = policy.action_window_show_procs,
    }
end

function Runtime.try_shared_cleanse(loadout, active, world, medic_policy, medic_priority, tier)
    local controller=Runtime.cleanseController
    if not active or type(loadout)~="table" or loadout.status~="ready" or loadout.combat_style~="commando" then
        controller.stop("commando_cleanse_inactive");return controller.has_local_pending()
    end
    if not controller.has_local_pending() and (Executor:owns_command() or Runtime.pendingAdmission or
        Runtime.pendingAction or
        (CombatMedicRoute.is_selected(loadout) and CombatMedicRoute.has_local_pending())) then return false end
    local owner=loadout.discipline=="Gunnery" and "gunnery" or
        loadout.discipline=="Assault Specialist" and "assault_specialist" or
        loadout.discipline=="Combat Medic" and "combat_medic" or nil
    if not owner then controller.stop("commando_cleanse_wrong_route");return false end
    local scope=medic_policy and medic_policy.healing_targets or "Players only"
    local allow_candidate
    if tier==nil then
        allow_candidate=function(candidate)
            -- DPS specs retain the previous broad shared-cleanse scheduler. The
            -- Combat Medic route passes an explicit tier and owns its heal/cleanse order.
            if medic_priority and medic_priority.self_survival then
                return candidate.isSelf and candidate.tier=="must"
            end
            if medic_policy and medic_priority and type(medic_priority.lowest)=="number" and
                medic_priority.lowest<=medic_policy.emergency_hp then return candidate.tier=="must" end
            return true
        end
    end
    local cleanse_policy = Runtime.cleanse.policy(Settings)
    cleanse_policy.diagnostics = Config.diagnosticsLogging and cleanse_policy.diagnostics
    return controller.tick({
        active=active,loadout=Mirror.raw_loadout(loadout),world=world or gos.world(),owner=owner,
        policy=cleanse_policy,
        log=Config.diagnosticsLogging and log_line or nil,target_scope=scope,tier=tier,
        target_types={player=true,companion=scope~="Players only",npc=scope=="All Friendlies"},
        admission_wait_ms=medic_policy and medic_policy.readiness_wait_ms or 150,
        allow_candidate=allow_candidate,
        onAction=owner=="combat_medic" and function(action)
            CombatMedicActionWindow:push(Mirror.event(ActiveLoadout,action), combat_medic_action_config(medic_policy))
        end or nil,
    })
end

gos.on_tick(function()
    Settings = gos.settings.get(SCRIPT_ID) or Settings or {}
    apply_settings(Settings)

    local loadout = Mirror.adapt_loadout(gos.abilities.loadout())
    ActiveLoadout = loadout
    local active = Settings.enabled == true and Settings.active == true

    Executor:tick()
    local raw_loadout=Mirror.raw_loadout(loadout)
    local profile=type(raw_loadout)=="table" and raw_loadout.status=="ready" and
        tostring(raw_loadout.combat_style)..":"..tostring(raw_loadout.discipline) or nil
    if Runtime.mirrorProfile and profile and Runtime.mirrorProfile~=profile then
        Runtime.cleanseController.stop("combat_style_changed")
        AssaultRoute.stop("combat_style_changed")
        CombatMedicRoute.stop("combat_style_changed")
        cancel_owned("gunnery","combat_style_changed")
        if Executor:owns_command() then return end
        reset_transient_state()
        Runtime.progressionPlayerHandle=nil
        Runtime.gravityVortexTargets={}
        Runtime.failureBackoff={}
        Runtime.lastLoadoutState=nil
    end
    if profile then Runtime.mirrorProfile=profile end
    if Config.diagnosticsLogging then
        log_core_lifecycle()
        log_action_rejection_capture()
    end

    local world = gos.world()
    local combat_events, _, combat_dropped = poll_commando_combat_events(world)
    local now = now_seconds()
    local medic_policy = CombatMedicRoute.is_selected(loadout) and CommandoCombatMedic.options(Settings) or nil
    if medic_policy and not Config.diagnosticsLogging then medic_policy.diagnostics=false end
    local medic_priority = medic_policy and CombatMedicRoute.priority_state(loadout, world, medic_policy) or nil
    -- A previously admitted/pending cleanse keeps its exact shared-executor
    -- lifecycle until it resolves. Fresh Combat Medic cleanse decisions are made
    -- inside the healer route so they can be interleaved with healing priority.
    if Runtime.cleanseController.has_local_pending() and
        Runtime.try_shared_cleanse(loadout, active, world, medic_policy, medic_priority) then
        if medic_policy then
            CombatMedicActionWindow:draw(world, combat_medic_action_config(medic_policy))
        end
        return
    end
    if not CombatMedicRoute.is_selected(loadout) and not AssaultRoute.has_local_pending() and
        not Runtime.pendingAdmission and
        Runtime.try_shared_cleanse(loadout, active, world, medic_policy, medic_priority) then return end

    -- Class route: exactly one Commando discipline owns the shared executor.
    if AssaultRoute.is_selected(loadout) then
        if CombatMedicRoute.stop("assault_route_selected") then
            return
        end
        if cancel_owned("gunnery", "assault_route_selected") then
            return
        end
        if Executor:owns_command() and not AssaultRoute.owns_pending() then
            return
        end
        reset_transient_state()
        AssaultRoute.tick(loadout, active, {
            castLog = Config.castLog,
            decisionLog = Config.decisionLog,
            logLine = Config.diagnosticsLogging and log_line or nil,
            abilityQueueWindow = Config.abilityQueueWindow,
            targetObservationGrace = Config.targetObservationGrace,
            inCombat = Runtime.inCombat,
            combatEpoch = Runtime.combatEpoch,
            combatStartedAt = Runtime.combatStartedAt,
            incendiaryRefreshSeconds = Config.assaultIncendiaryRefreshSeconds,
            priorityFloorPercent = Config.assaultPriorityFloorPercent,
            fillerFloorPercent = Config.assaultFillerFloorPercent,
            autoSuperchargedCell = Config.assaultAutoSuperchargedCell,
            autoRechargeCells = Config.autoRechargeCells,
            rechargeThresholdPercent = Config.assaultRechargeThresholdPercent,
            consumeHyperAssault = Config.assaultConsumeHyperAssault,
            useStickyGrenade = Config.assaultUseStickyGrenade,
            useElectroNet = Config.assaultUseElectroNet,
            autoSelfHeal = Config.assaultAutoSelfHeal,
            bactaInfusionHpPercent = Config.assaultBactaInfusionHpPercent,
            instantMedicalProbeHpPercent = Config.assaultInstantMedicalProbeHpPercent,
            medShotHpPercent = Config.assaultMedShotHpPercent,
            selfHealEnergyFloorPercent = Config.assaultSelfHealEnergyFloorPercent,
            aoeEnabled = Config.aoeEnabled,
            automaticTargetCount = Config.automaticTargetCount,
            manualRelevantTargets = Config.manualRelevantTargets,
            aoeMinTargets = Config.aoeMinTargets,
            aoeClusterRadius = Config.aoeClusterRadius,
            autoReactiveShield = Config.autoReactiveShield,
            reactiveShieldHpPercent = Config.reactiveShieldHpPercent,
            autoAdrenalineRush = Config.autoAdrenalineRush,
            adrenalineRushHpPercent = Config.adrenalineRushHpPercent,
            autoEchoingDeterrence = Config.autoEchoingDeterrence,
            echoingDeterrenceHpPercent = Config.echoingDeterrenceHpPercent,
            autoDiversion = Config.autoDiversion,
            diversionHpPercent = Config.diversionHpPercent,
            autoSuperchargedCelerity = Config.autoSuperchargedCelerity,
        })
        return
    end
    if AssaultRoute.stop("loadout_gate") then
        return
    end

    if CombatMedicRoute.is_selected(loadout) then
        if cancel_owned("gunnery", "combat_medic_route_selected") then
            return
        end
        if Executor:owns_command() and not CombatMedicRoute.owns_pending() then
            return
        end
        reset_transient_state()
        CombatMedicRoute.tick(loadout, active, {
            logLine = Config.diagnosticsLogging and log_line or nil,
            castLog = Config.castLog,
            decisionLog = Config.decisionLog,
            healing = medic_policy or CommandoCombatMedic.options(Settings),
            inCombat = Runtime.inCombat,
            combatEvents = combat_events,
            combatDropped = combat_dropped,
            onAction = function(action)
                CombatMedicActionWindow:push(action, combat_medic_action_config(medic_policy))
            end,
            tryCleanseTier = function(tier)
                return Runtime.try_shared_cleanse(loadout, active, gos.world(),
                    medic_policy, medic_priority, tier)
            end,
        })
        CombatMedicActionWindow:draw(world, combat_medic_action_config(medic_policy))
        return
    end
    if CombatMedicRoute.stop("loadout_gate") then
        return
    end

    local state = read_state(loadout)
    refresh_gravity_vortex_evidence(state, combat_events)
    refresh_recharge_credit(state)

    local loadout_ok, loadout_reason = loadout_match(loadout)
    if not loadout_ok then
        if Executor:owns_command() then
            Executor:cancel("loadout_gate:" .. loadout_reason)
        end
        if Runtime.pendingAdmission or Runtime.pendingAction or Runtime.commandTargetHandle then
            reset_transient_state()
        end
        log_loadout_state(loadout_reason)
        return
    end
    log_loadout_state("ready")
    log_progression_state(state)

    if not active then
        if Executor:owns_command() then
            Executor:cancel("rotation_inactive")
            if Executor:owns_command() then
                log_decision_state(state, "inactive",
                    "awaiting_command_terminal")
                return
            end
        end
        reset_transient_state()
        log_decision_state(state, "inactive", "activation_key_up")
        return
    end

    if service_pending_action(state) then
        log_decision_state(state, "command_dispatch",
            Runtime.pendingAction and
            Runtime.pendingAction.ability.id or "released")
        return
    end

    if service_orphan_executor() then
        log_decision_state(state, "command_pending", "executor_dispatch")
        return
    end

    if Executor:owns_command() then
        log_decision_state(state, "command_pending",
            "executor_busy_untracked")
        return
    end

    if service_pending_admission(state) then
        log_decision_state(state, "waiting_admission",
            Runtime.pendingAdmission and
            Runtime.pendingAdmission.selected.ability.id or "resolved")
        return
    end

    -- Personal defensives/heals must not depend on having a hostile selected.
    local offgcd = select_offgcd_action(state)
    if offgcd then
        log_decision_state(state, "selected_offgcd",
            offgcd.ability.id .. ":" .. offgcd.reason)
        submit_action(state, offgcd, "offgcd")
        return
    end

    local queueable, queue_reason = can_queue_input(state)
    if not queueable then
        log_decision_state(state, "waiting_lock", queue_reason)
        return
    end

    local healing = select_selfheal(state)
    if healing then
        if healing.wait then log_decision_state(state, "waiting_heal_proc", healing.reason)
        else submit_action(state, healing, "selfheal") end
        return
    end
    local target_ok, target_reason = valid_hostile_target(state)
    if not target_ok then
        log_decision_state(state, "waiting_target", target_reason)
        return
    end
    local cfg = Config.gunnery
    if cfg.auto_cryo and safe_method(state.targetUnit, "type") == "player" and
        GunneryKit.finite(state.player.hpPercent) and state.player.hpPercent <= cfg.cryo_hp then
        local control = consider(state, Ability.CryoGrenade, "opt_in_emergency_player_stun", 3)
        if control then submit_action(state, control, "control"); return end
    end
    refresh_target_count(state)
    local selected = select_priority_action(state)
    log_ability_diagnostics(state, selected)

    if not selected then
        log_no_decision_diagnostics(state)
        log_decision_state(state, "no_decision", "no_castable_priority")
        return
    end

    if selected.wait then
        log_decision_state(state, "waiting_ground",
            selected.ability.id .. ":" .. selected.reason)
        return
    end

    log_decision_state(state, "selected",
        selected.ability.id .. ":" .. selected.reason)
    submit_action(state, selected)
end)
