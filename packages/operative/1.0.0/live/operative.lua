-- operative.lua
-- Progressive Operative dispatcher: Medicine and Lethality through 80; Concealment 47.
-- Routes Concealment, Lethality, and Medicine from the exact live loadout discipline.
-- Evasion and other CC/major defensives remain player-owned; optional Shield Probe is Lua-controlled for all three specs.

local Mirror = require("operative.mirror")
local Cleanse = require("combat.cleanse")
local Interrupt = require("combat.interrupt")
local CursorHolotraverse = require("operative.cursor_holotraverse")
local AbilityExecutor = require("combat.ability_executor")
local Concealment = require("operative.concealment")
local Lethality = require("operative.lethality")
local Medicine = require("operative.medicine")
local StealthDetection = require("operative.stealth_detection")
local DpsSelfHealing = require("operative.dps_self_heal")
local HealerActionWindow = require("ui.healer_action_window")

local SCRIPT_ID = "operative_leveling_r1"
local BUILD_ID = "2026-09-06-operative-v28-self-priority+lethality-live-r5-native-target+concealment47-sanity-r3+medicine-infusion80+concealment-live-r4+dps-selfheal-r3-damage-first+melee-nowonly-r1+concealment-stealth-parity-r1+concealment-crippling-r1+concealment-facing-r1+lethality80-r1-capability-apl+cast-owner-diag-r1+stealth-icons-always-r1+shared-cleanse-r2+lethality-core-admission-r1+operative-all-specs-admission-r1+medicine-survival-r1+medicine-cleanse-order-r1+medicine-shiv-prebank-r1+medicine-tunnel-ta-r1+medicine-hardcast-pin-r1+medicine-nanotech-stim-r1+shared-interrupt-r5+medicine-battle-rez-r1+medicine-diagnostics-probe-r1+medicine-hot-first-r1+medicine-patient-first-r2+cursor-holotraverse-r2-executor-v2+cursor-command-outcomes-r2-raw-status+spec-settings-gates-r1+medicine-actions-r2-procs+exact-admission-owner-r3+medicine-window-id-r1+dps-cleanse-exact-retry-r1+medicine-fresh-unit-retry-r1+personal-defaults-20261007-r1-script-library-layout-r1-overlay-local-ids-r1+scoundrel-mirrors-r1+counterpart-recheck-20261019-r4"
local AUTO_STEALTH_KEY = "operative:auto_stealth"
local AUTO_STEALTH_ALWAYS = "Always Out of Combat (No Key)"
local AUTO_STEALTH_ROTATION_KEY = "Rotation Key Held"
local MEDICINE_TRIAGE_HP = "Current HP"
local MEDICINE_TRIAGE_PRESSURE = "Incoming Damage Formula"
local LETHALITY_TACTICAL_AUTO = "Auto / Unknown"
local LETHALITY_TACTICAL_SYNOX = "Synox Shots"
local LETHALITY_TACTICAL_VIRAL = "Viral Elements"
local LETHALITY_TACTICAL_CATALYZED = "Catalyzed Toxins"

local Config = {
    abilityQueueWindow = 0.300000011920929,
    energyFloorPercent = 35.0,
    autoStimBoost = false,
    autoAdrenalineProbe = true,
    adrenalineProbeThresholdPercent = 40.0,
    autoStealthOutOfCombat = false,
    autoStealthActivation = AUTO_STEALTH_ROTATION_KEY,
    stealthDetectionAwareness = true,
    stealthDetectionRangeRing = true,
    stealthDetectionMaxDistanceMeters = 80.0,
    stealthDetectionIconSize = 30.0,
    stealthDetectionHeightMeters = 2.0,
    corrosiveDartRefreshSeconds = 1.5,
    corrosiveGrenadeRefreshSeconds = 1.5,
    lethalityTactical = LETHALITY_TACTICAL_AUTO,
    lethalityAutoTacticalSuperiority = true,
    lethalityAutoTacticalOverdrive = true,
    lethalitySingleTargetHaze = true,
    lethalityMinDotLifetime = 6.0,
    aoeEnabled = true,
    concealmentPvPAoEEnabled = false,
    automaticTargetCount = true,
    manualRelevantTargets = 1,
    aoeMinTargets = 3,
    aoeClusterRadius = 5.0,
    medicineTriageMode = MEDICINE_TRIAGE_PRESSURE,
    medicineHealingStyle = "Balanced",
    medicineHealingTargets = "All Friendlies",
    medicineActionWindowVisible = true,
    medicineActionWindowX = 1177,
    medicineActionWindowY = 674,
    medicineActionWindowFontSize = 24,
    medicineActionWindowRows = 5,
    medicineActionWindowLifetime = 8,
    medicineActionWindowShowHealAmount = true,
    medicineActionWindowShowDamage = true,
    medicineActionWindowShowProcs = true,
    medicineKoltoBurstMinAllies = 3,
    medicineKoltoProbeEveryone = true,
    medicineKoltoProbeTargets = 4,
    medicineKoltoProbeRefreshSeconds = 3.0,
    medicineNanotechMinAllies = 2,
    medicineKoltoWavesMinAllies = 3,
    medicineAutoShieldProbe = true,
    medicineShieldProbeBelow = 75.0,
    medicineAutoBattleRez = true,
    medicineAutoTacticalOverdrive = true,
    medicineDpsEnabled = true,
    medicineDpsEnergyReservePercent = 70.0,
    medicineDpsBuildTactical = true,
    medicineDpsCorrosiveDart = true,
    medicineDpsOverloadShot = true,
    medicineDpsRifleShot = true,
    castLog = false,
    decisionLog = false,
    abilityDiagnostics = false,
}

local DPS_DISCIPLINES = { "Concealment", "Lethality" }
local CONCEALMENT_ONLY = { "Concealment" }
local LETHALITY_ONLY = { "Lethality" }
-- Core's authoritative discipline display name is "Medic", even though the
-- route/module and user-facing spec name are Medicine.
local MEDIC_ONLY = { "Medic" }

local Settings = gos.settings.register(SCRIPT_ID, Mirror.settings(CursorHolotraverse.settings(Interrupt.settings(Cleanse.settings({
    title = "Operative / Scoundrel - DPS / Healing 1-80",
    version = 31,
    activation = {
        mode = "hold",
        label = "Rotation Key",
        default = "mouse4",
    },
    fields = {
        {
            key = "ability_queue_window", type = "number",
            label = "Ability Queue Window",
            tooltip = "How early normal Operative abilities may queue before the current action lock ends.",
            default = 0.300000011920929, min = 0.05, max = 0.50, step = 0.01,
        },
        {
            key = "energy_floor_percent", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "Energy Floor %",
            tooltip = "Paid attacks do not deliberately leave Energy below this percentage.",
            default = 35, min = 35, max = 90, step = 1,
        },
        {
            key = "dps_self_heal_enabled", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Self-Healing",
            tooltip = "Shared Concealment/Lethality self-care while holding the rotation key. Two self Kolto Probes, stationary Kolto Infusion, and owned Quickening procs; Medicine is unaffected.",
            default = true,
        },
        {
            key = "dps_self_heal_damage_first", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Damage-First Self-Healing",
            tooltip = "Default: finish real damage priorities first. New Probe stacks and normal Infusion only replace Rifle/Overload filler. Established two-stack Probe refresh and critical direct healing remain protected. Concealment also uses emergency Probe setup and recovery with no damage target.",
            default = true,
        },
        {
            key = "dps_self_heal_pvp_only", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Self-Healing PvP Only",
            tooltip = "Enable against a living hostile player or after damage exchanged with a hostile player until combat ends. Disable to use the same self-care in PvE.",
            default = true,
        },
        {
            key = "dps_self_heal_concealment", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "DPS Self-Heal: Concealment", default = true,
            tooltip = "Enable the shared self-healing policy for Concealment. Master switch still applies.",
        },
        {
            key = "dps_self_heal_lethality", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "DPS Self-Heal: Lethality", default = true,
            tooltip = "Enable the shared self-healing policy for Lethality. Master switch still applies.",
        },
        {
            key = "dps_self_probes_enabled", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Maintain Two Self Probes", default = true,
            tooltip = "Proactively maintain two own Probes, including at full HP and while moving. Does not break the protected stealth opener.",
            requires_ability = "Kolto Probe",
        },
        {
            key = "dps_self_direct_enabled", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Self Kolto Infusion", default = true,
            tooltip = "Use the actual DPS direct heal. Normal Infusion requires a stationary player and observed Tactical Advantage.",
            requires_ability = "Kolto Infusion",
        },
        {
            key = "dps_self_heal_opportunities_only", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Hardcast In Recovery Windows", default = true,
            tooltip = "Normal Infusion requires a damage downtime opportunity: no damage target, range/LoS gap, or observed enemy immunity/mez. Concealment Heal on Damage Filler also treats actual Rifle/Overload filler as an opportunity. Critical HP bypasses the window, never movement or actual TA cost.",
        },
        {
            key = "dps_self_heal_ta_reserve", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Infusion TA To Keep", default = 0, min = 0, max = 1, step = 1,
            tooltip = "Normal hardcast Infusion must leave this many observed TA stacks. Critical health may spend the last real stack. Quickening consumes no TA.",
        },
        {
            key = "dps_self_quickening_enabled", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Use Quickening Self-Heal", default = true,
            tooltip = "Consume an observed Quickening proc with free instant Infusion. Requires the owned passive; no automatic roll and no proc assumed from a timer.",
            requires_ability = "Quickening",
        },
        {
            key = "dps_self_quickening_moving", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Quickening While Moving", default = true,
            tooltip = "Allow only the proven instant/free Quickening Infusion while moving. Normal Infusion always requires standing still.",
            requires_ability = "Quickening",
        },
        {
            key = "dps_self_quickening_below", type = "int",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Quickening Heal Below HP %", default = 90, min = 20, max = 99, step = 1,
            tooltip = "Spend a live free-heal proc below this HP. This is a tunable policy threshold, not a number prescribed by a guide.",
            requires_ability = "Quickening",
        },
        {
            key = "dps_self_heal_assume_pvp", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Self-Heal Manual PvP Context", default = false,
            tooltip = "Manually allow PvP-only self-healing before a player target/damage event is observed. Still needs the rotation key; stealth protection remains. Not an automatic warzone detector.",
        },
        {
            key = "dps_self_heal_below", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Begin Self-Heal HP %",
            tooltip = "Begin stationary Kolto Infusion recovery at or below this health. Probes are maintained in PvP even at full health.",
            default = 70, min = 10, max = 95, step = 1,
        },
        {
            key = "dps_self_heal_to", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Recover To HP %",
            tooltip = "Stop direct self-healing once this health is reached. Never treated as lower than Begin Self-Heal HP.",
            default = 85, min = 20, max = 100, step = 1,
        },
        {
            key = "dps_self_heal_emergency", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Critical Self-Heal HP %",
            tooltip = "At this health, stationary Infusion goes before Probe setup and may spend below the normal healing reserve. Real upfront affordability still applies.",
            default = 30, min = 10, max = 60, step = 1,
        },
        {
            key = "dps_self_probe_refresh", type = "number",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Self Probe Refresh Seconds",
            tooltip = "Refresh your own two-stack Kolto Probe at this remaining engine timer. The second stack is built at the next legal opportunity.",
            default = 3.0, min = 0.5, max = 6.0, step = 0.5,
            requires_ability = "Kolto Probe",
        },
        {
            key = "dps_self_probe_reserve", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Self Probe Energy Reserve %",
            tooltip = "Routine self Probes leave this Energy after their runtime cost; DPS uses free filler while pooling. Critical health may use the remaining affordable Energy.",
            default = 50, min = 0, max = 80, step = 5,
        },
        {
            key = "dps_self_heal_reserve", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "DPS Direct Heal Energy Reserve %",
            tooltip = "Stationary Infusion leaves this reserve; DPS uses free filler while pooling. Critical health bypasses the reserve, not the actual cost.",
            default = 35, min = 0, max = 80, step = 5,
        },
        {
            key = "auto_stim_boost", type = "bool",
            label = "Auto Stim Boost",
            tooltip = "DPS routes restrict Stim Boost to durable targets. Medicine may also use it for emergency Tactical Advantage and level-43 Stim Burst healing windows.",
            default = false, requires_ability = "Stim Boost",
        },
        {
            key = "auto_adrenaline_probe", type = "bool",
            label = "Auto Adrenaline Probe",
            tooltip = "Use Adrenaline Probe automatically when Energy reaches the configured threshold.",
            default = true, requires_ability = "Adrenaline Probe",
        },
        {
            key = "adrenaline_probe_threshold_percent", type = "int",
            label = "Adrenaline Probe At %",
            tooltip = "Use Adrenaline Probe at or below this Energy percentage. During active healing pressure Medicine will not wait below 40% even if this is configured lower.",
            default = 40, min = 10, max = 60, step = 1,
            requires_ability = "Adrenaline Probe",
        },
        {
            key = "medicine_triage_mode", type = "select",
            disciplines = MEDIC_ONLY,
            label = "Medicine Heal Priority",
            tooltip = "Current HP keeps the existing target order. Incoming Damage Formula uses recent damage, attacker count, HoT carry and projected survivability to choose the patient.",
            default = MEDICINE_TRIAGE_PRESSURE,
            options = { MEDICINE_TRIAGE_HP, MEDICINE_TRIAGE_PRESSURE },
        },
        {
            key = "medicine_healing_style", type = "select",
            disciplines = MEDIC_ONLY,
            label = "Medicine Healing Style",
            tooltip = "Safe starts healing earlier, Balanced is the default, Efficient waits for more meaningful damage.",
            default = "Balanced", options = { "Safe", "Balanced", "Efficient" },
        },
        {
            key = "medicine_healing_targets", type = "select",
            disciplines = MEDIC_ONLY,
            label = "Medicine Healing Targets",
            tooltip = "PvP can use Players only; PvE/solo can include companions or every friendly unit.",
            default = "All Friendlies",
            options = { "Players only", "Players + Companions", "All Friendlies" },
        },
        {
            key = "medicine_action_window_visible", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Visible",
            tooltip = "Show the frameless Medicine action feed. Use the on-screen X to hide it and this toggle to restore it.",
            default = true,
        },
        {
            key = "medicine_action_window_x", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Position X",
            tooltip = "Horizontal screen position. Drag the on-screen handle to update it.",
            default = 1177, min = 0, max = 7680, step = 1,
        },
        {
            key = "medicine_action_window_y", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Position Y",
            tooltip = "Vertical screen position. Drag the on-screen handle to update it.",
            default = 674, min = 0, max = 4320, step = 1,
        },
        {
            key = "medicine_action_window_font_size", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Main Font Size",
            tooltip = "Large action-line font size in pixels.",
            default = 24, min = 16, max = 36, step = 1,
        },
        {
            key = "medicine_action_window_rows", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Visible Rows",
            tooltip = "Maximum recent Medicine actions shown at once.",
            default = 5, min = 1, max = 8, step = 1,
        },
        {
            key = "medicine_action_window_lifetime", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Lifetime",
            tooltip = "Seconds each accepted action remains visible before fading out.",
            default = 8, min = 2, max = 20, step = 1,
        },
        {
            key = "medicine_action_window_show_heal_amount", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Show Heal Amount",
            tooltip = "Accumulate measured player heal events into recent Medicine healing actions.",
            default = true,
        },
        {
            key = "medicine_action_window_show_damage", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Show Damage",
            tooltip = "Show Medicine idle-DPS actions and enrich them with measured combat-event damage.",
            default = true,
        },
        {
            key = "medicine_action_window_show_procs", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Actions: Show Proc Enhancements",
            tooltip = "Show proc labels when an accepted Medicine action supplies observed proc metadata.",
            default = true,
        },
        {
            key = "medicine_kolto_burst_min_allies", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Kolto Burst Allies",
            tooltip = "With the level-23 Kolto Burst passive, self-cast Kolto Injection when this many injured allies are within its exact 8m radius.",
            default = 3, min = 2, max = 8, step = 1,
            requires_ability = "Kolto Burst",
        },
        {
            key = "medicine_kolto_probe_everyone", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Probe Everyone",
            tooltip = "Maintain two Kolto Probe stacks on every eligible visible player/companion in 30m. Build the focused patient's HoTs first when safe; urgent patient support overrides ALL unrelated seeding and refreshes. Roster maintenance resumes after the emergency/urgent pressure window.",
            default = true,
            requires_ability = "Kolto Probe",
        },
        {
            key = "medicine_kolto_probe_targets", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Probe Fallback Limit",
            tooltip = "Only used when Medicine Probe Everyone is disabled. Limits the sticky Probe roster while preserving existing one-stack/expiring owners first.",
            default = 4, min = 1, max = 32, step = 1,
            requires_ability = "Kolto Probe",
        },
        {
            key = "medicine_kolto_probe_refresh_seconds", type = "number",
            disciplines = MEDIC_ONLY,
            label = "Medicine Kolto Probe Refresh",
            tooltip = "Refresh an owned two-stack Kolto Probe from the engine timer. The 3s default leaves queue/GCD/movement margin without blindly clipping the HoT.",
            default = 3.0, min = 0.5, max = 6.0, step = 0.5,
            requires_ability = "Kolto Probe",
        },
        {
            key = "medicine_nanotech_min_allies", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Nanotech Allies",
            tooltip = "Use Recuperative Nanotech for meaningful group pressure when this many injured allies cluster within 10m. With Nanotech Stim, prefer the center that affects the most allies (up to 4) to reduce Stim Boost cooldown. This may move RN ahead of routine HoT maintenance while Stim Boost is cooling down; critical rescue/direct heals still come first.",
            default = 2, min = 1, max = 4, step = 1,
            requires_ability = "Recuperative Nanotech",
        },
        {
            key = "medicine_kolto_waves_min_allies", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Kolto Waves Allies",
            tooltip = "At level 60+, channel Kolto Waves only when at least this many meaningfully injured allies fit inside the best 8m cluster. It is never used as a single-target filler.",
            default = 3, min = 2, max = 8, step = 1,
            requires_ability = "Kolto Waves",
        },
        {
            key = "medicine_auto_shield_probe", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Auto Shield Probe",
            tooltip = "Self-only off-GCD Shield Probe while holding the rotation key and in combat. Uses authoritative HP/shield observations; Evasion and other major defensives remain manual.",
            default = true, requires_ability = "Shield Probe",
        },
        {
            key = "medicine_shield_probe_below", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine Shield Probe Below HP %",
            tooltip = "Policy threshold for the automatic self Shield Probe. Unknown shield observations never trigger a guessed refresh.",
            default = 75, min = 10, max = 95, step = 5,
            requires_ability = "Shield Probe",
        },
        {
            key = "medicine_auto_battle_rez", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Auto Battle Rez",
            tooltip = "Automatically use Resuscitation Probe on a proven-dead friendly player while in combat when no living ally needs burst rescue. Your selected dead ally is preferred; otherwise the nearest legal corpse is used. Arena/server restrictions remain authoritative.",
            default = true, requires_ability = "Resuscitation Probe",
        },
        {
            key = "medicine_auto_tactical_overdrive", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Auto Tactical Overdrive",
            tooltip = "Use the selected level-43 Tactical Overdrive during emergency or heavy multi-target healing pressure.",
            default = true, requires_ability = "Tactical Overdrive",
        },
        {
            key = "medicine_dps_enabled", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Idle DPS",
            tooltip = "Fill spare GCDs with damage whenever no meaningful heal is due; healthy HoTs are allowed to cover chip damage instead of forcing overheal.",
            default = true,
        },
        {
            key = "medicine_dps_energy_reserve_percent", type = "int",
            disciplines = MEDIC_ONLY,
            label = "Medicine DPS Energy Reserve %",
            tooltip = "Paid idle-DPS attacks cannot deliberately leave Energy below this reserve; Rifle Shot remains available for free damage.",
            default = 70, min = 50, max = 95, step = 1,
        },
        {
            -- Keep the persisted key for compatibility. This now controls Shiv as
            -- healer resource preparation as well as its later idle-DPS use.
            -- TA recovery remains fail-closed on exact TA and selected-target data.
            key = "medicine_dps_build_tactical", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine Shiv / TA Bank",
            tooltip = "Maintain a 2-TA healing reserve with Shiv when the scheduler has a safe resource-prep GCD and the selected hostile is within 4m. Mobile TA-starved rescue can also use Shiv after stronger heals have first refusal. This works even when Medicine Idle DPS is disabled.",
            default = true, requires_ability = "Shiv",
        },
        {
            key = "medicine_dps_corrosive_dart", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine DPS Corrosive Dart",
            tooltip = "Maintain your Corrosive Dart only on the selected player or durable boss-tier target during a safe idle-DPS window.",
            default = true, requires_ability = "Corrosive Dart",
        },
        {
            key = "medicine_dps_overload_shot", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine DPS Overload Shot",
            tooltip = "Spend surplus Energy on Overload Shot during idle DPS, above the Medicine reserve.",
            default = true, requires_ability = "Overload Shot",
        },
        {
            key = "medicine_dps_rifle_shot", type = "bool",
            disciplines = MEDIC_ONLY,
            label = "Medicine DPS Rifle Shot",
            tooltip = "Use free Rifle Shot as the final idle-DPS filler without risking healing Energy.",
            default = true, requires_ability = "Rifle Shot",
        },
        {
            key = "auto_stealth_out_of_combat", type = "bool",
            label = "Auto Stealth Out of Combat",
            tooltip = "Automatically enter Stealth when enabled, Stealth is known/bound/ready, and you are out of combat.",
            default = false, requires_ability = "Stealth",
        },
        {
            key = "auto_stealth_activation", type = "select",
            label = "Auto Stealth Trigger",
            tooltip = "Always Out of Combat: no key is required. Rotation Key Held: auto-stealth runs only while the configured Rotation Key is held.",
            default = AUTO_STEALTH_ROTATION_KEY,
            options = { AUTO_STEALTH_ALWAYS, AUTO_STEALTH_ROTATION_KEY },
            requires_ability = "Stealth",
        },
        {
            key = "stealth_detection_awareness", type = "bool",
            label = "Stealth Detection Awareness",
            tooltip = "Show icons on every observed hostile detector in range, selected or not. Independent of rotation key, combat, Stealth, and loadout readiness. Core clips off-screen icons.",
            default = true,
        },
        {
            key = "stealth_detection_range_ring", type = "bool",
            label = "Stealth Detection Range Ring",
            tooltip = "Only the selected detector gets a ground range ring. Unselected detectors keep their icons. Radius comes from the detector catalog, not a live range measurement.",
            default = true,
        },
        {
            key = "stealth_detection_max_distance", type = "int",
            label = "Stealth Detection Max Distance",
            tooltip = "Maximum distance in metres for detector awareness scans. Zero means unlimited.",
            default = 80, min = 0, max = 500, step = 5,
        },
        {
            key = "stealth_detection_icon_size", type = "int",
            label = "Stealth Detection Icon Size",
            tooltip = "Detector sprite size in screen pixels. Position follows the target's world origin, independent of other overlays.",
            default = 30, min = 18, max = 48, step = 1,
        },
        {
            key = "stealth_detection_height_meters", type = "number",
            label = "Stealth Icon Height (m)",
            tooltip = "Height above the target's world origin along the vertical axis. Camera distance handles projection; no nameplate or CC-row offsets.",
            default = 2.0, min = 0.0, max = 20.0, step = 0.1,
        },
        {
            key = "corrosive_dart_refresh_seconds", type = "number",
            disciplines = DPS_DISCIPLINES,
            label = "Corrosive Dart Refresh",
            tooltip = "Refresh your Corrosive Dart when its remaining duration reaches this window.",
            default = 1.5, min = 0.0, max = 3.0, step = 0.1,
            requires_ability = "Corrosive Dart",
        },
        {
            key = "lethality_effect_continuity", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Confirmed-Event Continuity",
            tooltip = "Use actual server AbilityActivate events for TA and retain previously observed DoT expiry during effect-scanner gaps. Queued command receipts never grant TA or claim a poison landed.",
            default = true,
        },
        {
            key = "lethality_auto_toxic_blast", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Auto Toxic Blast", default = true,
            tooltip = "Use Toxic Blast according to the learned 1-80 priority. Native cooldowns and cast admission remain authoritative.",
            requires_ability = "Toxic Blast",
        },
        {
            key = "lethality_tactical", type = "select",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Tactical",
            tooltip = "Equipped tactical is not exposed by loadout. Auto / Unknown stays gear-agnostic; Synox favors sustained Toxic Blast; Viral Elements favors real AoE Haze + Lethal Strike windows; Catalyzed uses the PvP fresh-DoT spike sequence without guessing poison consumption.",
            default = LETHALITY_TACTICAL_AUTO,
            options = { LETHALITY_TACTICAL_AUTO, LETHALITY_TACTICAL_SYNOX,
                LETHALITY_TACTICAL_VIRAL, LETHALITY_TACTICAL_CATALYZED },
            requires_ability = "Toxic Blast",
        },
        {
            key = "lethality_auto_tactical_superiority", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Auto Tactical Superiority", default = true,
            tooltip = "Use the learned 5-minute raid buff on Champion/boss PvE targets after poisons are established and a real Tactical Advantage is available. Disabled for player targets so PvP/Arena timing stays manual.",
            requires_ability = "Tactical Superiority",
        },
        {
            key = "lethality_auto_shield_probe", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Auto Shield Probe", default = true,
            tooltip = "Self-only off-GCD defense while holding the rotation key and in combat. Uses observed HP and shield state. Does not delay the protected Stealth opener or use the explicit-target backend.",
            requires_ability = "Shield Probe",
        },
        {
            key = "lethality_shield_probe_below", type = "int",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Shield Probe Below HP %", default = 75,
            min = 10, max = 95, step = 5,
            tooltip = "Policy threshold, not a game restriction. Use Shield Probe at or below this HP in PvE/PvP. Unknown shield observations never trigger guessed refreshes.",
            requires_ability = "Shield Probe",
        },
        {
            key = "lethality_auto_tactical_overdrive", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Auto Tactical Overdrive",
            tooltip = "Reset used Toxic Haze and the currently learned strike (Lethal Strike after it replaces Backstab) during a close-range poison window on a player or boss. Never burns the reset before its abilities have been used.",
            default = true, requires_ability = "Tactical Overdrive",
        },
        {
            key = "lethality_single_target_haze", type = "bool",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Single-Target PvE Haze",
            tooltip = "Allow Haze on a durable NPC only with observed zero movement and sufficient estimated lifetime. Single PvP targets are excluded; Automatic AoE must also be enabled.",
            default = true, requires_ability = "Toxic Haze",
        },
        {
            key = "lethality_min_dot_lifetime", type = "number",
            disciplines = LETHALITY_ONLY,
            label = "Lethality Minimum DoT Lifetime",
            tooltip = "Skip fresh poison setup when recent measured HP loss estimates fewer seconds of life. Unknown lifetime does not block DoTs. Zero disables this policy.",
            default = 6.0, min = 0.0, max = 15.0, step = 0.5,
        },
        {
            key = "corrosive_grenade_refresh_seconds", type = "number",
            disciplines = LETHALITY_ONLY,
            label = "Corrosive Grenade Refresh",
            tooltip = "Refresh your Grenade from its actual engine timer; unavailable or unknown-owner effects never create a guessed refresh.",
            default = 1.5, min = 0.0, max = 3.0, step = 0.1,
            requires_ability = "Corrosive Grenade",
        },
        {
            key = "aoe_enabled", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "Automatic AoE",
            tooltip = "Enable AoE priority. Fragmentation Grenade uses its exact 5m target-centered cluster and caps at 7 enemies; Toxic Haze and Noxious Knives use player-centered geometry.",
            default = true,
        },
        {
            key = "concealment_heal_on_filler", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Heal on Damage Filler", default = true,
            tooltip = "When injured and stationary, normal Kolto Infusion can replace actual Rifle/Overload filler even in melee. Real damage priorities remain first; existing HP, energy, TA and PvP-only settings still apply. No Lethality Quickening is assumed.",
            requires_ability = "Kolto Infusion",
        },
        {
            key = "concealment_auto_shield_probe", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Auto Shield Probe", default = true,
            tooltip = "Reuse Lethality's observed self-shield policy in PvE/PvP. Off-GCD, rotation key held, in combat, shield confirmed absent; no hostile target required. Does not automate Evasion, Cloaking Screen or Stim Boost.",
            requires_ability = "Shield Probe",
        },
        {
            key = "concealment_shield_probe_below", type = "int",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Shield Probe Below HP %", default = 75,
            min = 10, max = 95, step = 5,
            tooltip = "Policy threshold for the automatic self Shield Probe. Unknown shield observations never authorize a guessed refresh.",
            requires_ability = "Shield Probe",
        },
        {
            key = "concealment_tactical", type = "select",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Tactical",
            tooltip = "Select the tactical actually equipped; loadout does not expose equipment. Unknown / Other uses the learned base kit. Acid Lash protects your observed Acid Blade poison with Laceration. Volatile Strike enables Veiled Strike detonation without requiring Dart. Selection never fabricates a poison, crit proc, or Tactical Advantage.",
            default = "Unknown / Other",
            options = { "Unknown / Other", "Acid Lash", "Volatile Strike" },
            requires_ability = "Laceration",
        },
        {
            key = "concealment_spend_reserve_for_procs", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Spend Reserve for Procs", default = true,
            tooltip = "Allow the selected tactical's confirmed burst follow-up or expiring Acid Lash poison refresh to spend below the configured Energy Floor. Requires enough real energy to pay the full cost. No exception for ordinary fillers; disable to enforce the floor strictly.",
            requires_ability = "Laceration",
        },
        {
            key = "concealment_auto_tactical_overdrive", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Auto Tactical Overdrive", default = true,
            tooltip = "Use only when selected and the relevant attacks have spent cooldowns. Wait for confirmed absence of unexploded Volatile Substance; preserve manual use by switching this off.",
            requires_ability = "Tactical Overdrive",
        },
        {
            key = "concealment_auto_crippling", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Auto Crippling Slice / Throw",
            tooltip = "Use Wounds crit setup, Throw below the observed TA cap, or free Slice filler/Best Defense. Never replaces the Stealth Backstab opener.",
            default = true,
        },
        {
            key = "concealment_wounds_followup", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Crippling Wounds Follow-up",
            tooltip = "Prioritize a strong legal direct hit against your observed Crippling Wounds target. Also honors manual Slice with automatic Crippling off; never waits on an impossible combo.",
            default = true, requires_ability = "Crippling Wounds",
        },
        {
            key = "concealment_pvp_aoe", type = "bool",
            disciplines = CONCEALMENT_ONLY,
            label = "Concealment Auto AoE in PvP",
            tooltip = "Opt in to automatic Toxic Haze, Noxious Knives, and Fragmentation Grenade when the selected target is a player. Disabled by default to avoid breaking coordinated mezzes.",
            default = false,
        },
        {
            key = "automatic_target_count", type = "bool",
            disciplines = DPS_DISCIPLINES,
            label = "Target-Centered Auto Count",
            tooltip = "Count live hostiles around the selected target for AoE decisions.",
            default = true,
        },
        {
            key = "manual_relevant_targets", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "Relevant Targets",
            tooltip = "Fallback target count when automatic target counting is unavailable or disabled.",
            default = 1, min = 1, max = 8, step = 1,
        },
        {
            key = "aoe_min_targets", type = "int",
            disciplines = DPS_DISCIPLINES,
            label = "AoE Minimum Targets",
            tooltip = "Minimum clustered hostiles before the low-level AoE priority activates.",
            default = 3, min = 2, max = 8, step = 1,
        },
        {
            key = "aoe_cluster_radius", type = "number",
            disciplines = DPS_DISCIPLINES,
            label = "AoE Cluster Radius",
            tooltip = "Radius in metres around the selected target used for automatic target counting.",
            default = 5.0, min = 3.0, max = 8.0, step = 0.5,
        },
        {
            key = "cast_log", type = "bool",
            label = "Cast Log",
            tooltip = "Log successfully queued Operative actions.",
            default = false,
        },
        {
            key = "decision_log", type = "bool",
            label = "Decision Log",
            tooltip = "Log route decisions, waits, target gates, and selected priorities.",
            default = false,
        },
        {
            key = "ability_diagnostics", type = "bool",
            label = "Ability Diagnostics",
            tooltip = "Every two seconds, log owned/bound/resolved/ready/cost state for the current route.",
            default = false,
        },
    },
}, { cleanse_slows = true, cleanse_pressure = true })))))

local function clamp(value, minimum, maximum)
    if type(value) ~= "number" then return minimum end
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function setting_value(settings, key)
    if type(settings) ~= "table" then return nil end
    if settings[key] ~= nil then return settings[key] end
    if type(settings.fields) == "table" then return settings.fields[key] end
    return nil
end

local function setting_bool(settings, key, fallback)
    local value = setting_value(settings, key)
    if type(value) == "boolean" then return value end
    return fallback
end

local function setting_number(settings, key, fallback, minimum, maximum)
    local value = setting_value(settings, key)
    if type(value) ~= "number" then value = fallback end
    return clamp(value, minimum, maximum)
end

local function setting_int(settings, key, fallback, minimum, maximum)
    return math.floor(setting_number(settings, key, fallback, minimum, maximum))
end

local function setting_string(settings, key, fallback)
    local value = setting_value(settings, key)
    return type(value) == "string" and value or fallback
end

local function apply_settings(settings)
    Config.abilityQueueWindow = setting_number(settings,
        "ability_queue_window", 0.300000011920929, 0.05, 0.50)
    Config.energyFloorPercent = setting_number(settings,
        "energy_floor_percent", 35.0, 35.0, 90.0)
    Config.autoStimBoost = setting_bool(settings, "auto_stim_boost", false)
    Config.lethalityTactical = setting_string(settings, "lethality_tactical", LETHALITY_TACTICAL_AUTO)
    if Config.lethalityTactical ~= LETHALITY_TACTICAL_SYNOX and
        Config.lethalityTactical ~= LETHALITY_TACTICAL_VIRAL and
        Config.lethalityTactical ~= LETHALITY_TACTICAL_CATALYZED then
        Config.lethalityTactical = LETHALITY_TACTICAL_AUTO
    end
    Config.lethalityAutoTacticalSuperiority = setting_bool(settings,
        "lethality_auto_tactical_superiority", true)
    Config.lethalityAutoTacticalOverdrive = setting_bool(settings,
        "lethality_auto_tactical_overdrive", true)
    Config.lethalitySingleTargetHaze = setting_bool(settings,
        "lethality_single_target_haze", true)
    Config.lethalityMinDotLifetime = setting_number(settings,
        "lethality_min_dot_lifetime", 6.0, 0.0, 15.0)
    Config.corrosiveGrenadeRefreshSeconds = setting_number(settings,
        "corrosive_grenade_refresh_seconds", 1.5, 0.0, 3.0)
    Config.autoAdrenalineProbe = setting_bool(settings, "auto_adrenaline_probe", true)
    Config.adrenalineProbeThresholdPercent = setting_number(settings,
        "adrenaline_probe_threshold_percent", 40.0, 10.0, 60.0)
    Config.autoStealthOutOfCombat = setting_bool(settings,
        "auto_stealth_out_of_combat", false)
    Config.autoStealthActivation = setting_string(settings,
        "auto_stealth_activation", AUTO_STEALTH_ROTATION_KEY)
    if Config.autoStealthActivation ~= AUTO_STEALTH_ROTATION_KEY then
        Config.autoStealthActivation = AUTO_STEALTH_ALWAYS
    end
    Config.stealthDetectionAwareness = setting_bool(settings,
        "stealth_detection_awareness", true)
    Config.stealthDetectionRangeRing = setting_bool(settings,
        "stealth_detection_range_ring", true)
    Config.stealthDetectionMaxDistanceMeters = setting_number(settings,
        "stealth_detection_max_distance", 80.0, 0.0, 500.0)
    Config.stealthDetectionIconSize = setting_number(settings,
        "stealth_detection_icon_size", 30.0, 18.0, 48.0)
    Config.stealthDetectionHeightMeters = setting_number(settings,
        "stealth_detection_height_meters", 2.0, 0.0, 20.0)
    Config.corrosiveDartRefreshSeconds = setting_number(settings,
        "corrosive_dart_refresh_seconds", 1.5, 0.0, 3.0)
    Config.aoeEnabled = setting_bool(settings, "aoe_enabled", true)
    Config.concealmentPvPAoEEnabled = setting_bool(settings,
        "concealment_pvp_aoe", false)
    Config.automaticTargetCount = setting_bool(settings, "automatic_target_count", true)
    Config.manualRelevantTargets = setting_int(settings,
        "manual_relevant_targets", 1, 1, 8)
    Config.aoeMinTargets = setting_int(settings, "aoe_min_targets", 3, 2, 8)
    Config.aoeClusterRadius = setting_number(settings,
        "aoe_cluster_radius", 5.0, 3.0, 8.0)
    Config.medicineTriageMode = setting_string(settings,
        "medicine_triage_mode", MEDICINE_TRIAGE_PRESSURE)
    if Config.medicineTriageMode ~= MEDICINE_TRIAGE_PRESSURE then
        Config.medicineTriageMode = MEDICINE_TRIAGE_HP
    end
    Config.medicineHealingStyle = setting_string(settings,
        "medicine_healing_style", "Balanced")
    if Config.medicineHealingStyle ~= "Safe" and
        Config.medicineHealingStyle ~= "Efficient" then
        Config.medicineHealingStyle = "Balanced"
    end
    Config.medicineHealingTargets = setting_string(settings,
        "medicine_healing_targets", "All Friendlies")
    if Config.medicineHealingTargets ~= "Players only" and
        Config.medicineHealingTargets ~= "Players + Companions" then
        Config.medicineHealingTargets = "All Friendlies"
    end
    Config.medicineActionWindowVisible = setting_bool(settings,
        "medicine_action_window_visible", true)
    Config.medicineActionWindowX = setting_int(settings,
        "medicine_action_window_x", 1177, 0, 7680)
    Config.medicineActionWindowY = setting_int(settings,
        "medicine_action_window_y", 674, 0, 4320)
    Config.medicineActionWindowFontSize = setting_int(settings,
        "medicine_action_window_font_size", 24, 16, 36)
    Config.medicineActionWindowRows = setting_int(settings,
        "medicine_action_window_rows", 5, 1, 8)
    Config.medicineActionWindowLifetime = setting_int(settings,
        "medicine_action_window_lifetime", 8, 2, 20)
    Config.medicineActionWindowShowHealAmount = setting_bool(settings,
        "medicine_action_window_show_heal_amount", true)
    Config.medicineActionWindowShowDamage = setting_bool(settings,
        "medicine_action_window_show_damage", true)
    Config.medicineActionWindowShowProcs = setting_bool(settings,
        "medicine_action_window_show_procs", true)
    Config.medicineKoltoBurstMinAllies = setting_int(settings,
        "medicine_kolto_burst_min_allies", 3, 2, 8)
    Config.medicineKoltoProbeEveryone = setting_bool(settings,
        "medicine_kolto_probe_everyone", true)
    Config.medicineKoltoProbeTargets = setting_int(settings,
        "medicine_kolto_probe_targets", 4, 1, 32)
    Config.medicineKoltoProbeRefreshSeconds = setting_number(settings,
        "medicine_kolto_probe_refresh_seconds", 3.0, 0.5, 6.0)
    Config.medicineNanotechMinAllies = setting_int(settings,
        "medicine_nanotech_min_allies", 2, 1, 4)
    Config.medicineKoltoWavesMinAllies = setting_int(settings,
        "medicine_kolto_waves_min_allies", 3, 2, 8)
    Config.medicineAutoShieldProbe = setting_bool(settings,
        "medicine_auto_shield_probe", true)
    Config.medicineShieldProbeBelow = setting_number(settings,
        "medicine_shield_probe_below", 75.0, 10.0, 95.0)
    Config.medicineAutoBattleRez = setting_bool(settings,
        "medicine_auto_battle_rez", true)
    Config.medicineAutoTacticalOverdrive = setting_bool(settings,
        "medicine_auto_tactical_overdrive", true)
    Config.medicineDpsEnabled = setting_bool(settings, "medicine_dps_enabled", true)
    Config.medicineDpsEnergyReservePercent = setting_number(settings,
        "medicine_dps_energy_reserve_percent", 70.0, 50.0, 95.0)
    Config.medicineDpsBuildTactical = setting_bool(settings,
        "medicine_dps_build_tactical", true)
    Config.medicineDpsCorrosiveDart = setting_bool(settings,
        "medicine_dps_corrosive_dart", true)
    Config.medicineDpsOverloadShot = setting_bool(settings,
        "medicine_dps_overload_shot", true)
    Config.medicineDpsRifleShot = setting_bool(settings,
        "medicine_dps_rifle_shot", true)
    Config.castLog = setting_bool(settings, "cast_log", false)
    Config.decisionLog = setting_bool(settings, "decision_log", false)
    Config.abilityDiagnostics = setting_bool(settings, "ability_diagnostics", false)
end

local function log_line(level, message)
    if (level == "info" or level == "debug") and not
        (Config.castLog or Config.decisionLog or Config.abilityDiagnostics or
         setting_bool(Settings, "cleanse_diagnostics", false) or
         setting_bool(Settings, "interrupt_diagnostics", false)) then return end
    local logger = gos and gos.log or nil
    local fn = logger and logger[level] or nil
    if type(fn) == "function" then fn("[operative] " .. tostring(message)) end
end

local Executor = AbilityExecutor.new()
local InterruptController = Interrupt.new()
local CursorHolo = CursorHolotraverse.new(Executor)
local ConcealmentRoute = Concealment.new(Executor)
local LethalityRoute = Lethality.new(Executor)
local MedicineRoute = Medicine.new(Executor)
local ActiveLoadout
local DpsSelfHeal = DpsSelfHealing.new(Executor, function(activation_time, discipline)
    if discipline=="Lethality" then LethalityRoute.observe_self_heal_ta(activation_time)
    elseif discipline=="Concealment" then ConcealmentRoute.observe_self_heal_ta(activation_time) end
end)

local MedicineActionWindow = HealerActionWindow.new({
    idPrefix = "actions",
    scriptId = SCRIPT_ID,
    visibleKey = "medicine_action_window_visible",
    xKey = "medicine_action_window_x",
    yKey = "medicine_action_window_y",
    title = "MEDICINE ACTIONS",
    readyText = "MEDICINE READY",
    resourceLabel = "ENERGY RECOVERY",
    log = log_line,
    healActions = {
        ["Diagnostic Scan"] = true,
        ["Kolto Injection"] = true,
        ["Kolto Infusion"] = true,
        ["Kolto Probe"] = true,
        ["Recuperative Nanotech"] = true,
        ["Surgical Probe"] = true,
        ["Kolto Waves"] = true,
    },
    groupHeals = {
        ["Recuperative Nanotech"] = true,
        ["Kolto Waves"] = true,
    },
    protectActions = { ["Shield Probe"] = true },
    resourceActions = { ["Adrenaline Probe"] = true },
    supportActions = {
        ["Stim Boost"] = true,
        ["Tactical Overdrive"] = true,
        ["Resuscitation Probe"] = true,
    },
    dpsActions = {
        ["Backstab"] = true,
        ["Shiv"] = true,
        ["Corrosive Dart"] = true,
        ["Noxious Knives"] = true,
        ["Overload Shot"] = true,
        ["Rifle Shot"] = true,
    },
    areaDamage = { ["Noxious Knives"] = true },
    displayAbility = function(ability)
        return Mirror.ability(ActiveLoadout, ability)
    end,
})

local function medicine_action_config()
    return {
        visible = Config.medicineActionWindowVisible,
        x = Config.medicineActionWindowX,
        y = Config.medicineActionWindowY,
        fontSize = Config.medicineActionWindowFontSize,
        rows = Config.medicineActionWindowRows,
        lifetime = Config.medicineActionWindowLifetime,
        showHealAmount = Config.medicineActionWindowShowHealAmount,
        showDamage = Config.medicineActionWindowShowDamage,
        showProcs = Config.medicineActionWindowShowProcs,
    }
end

local Runtime = {
    lastLoadout = nil,
    combatCursor = nil,
    inCombat = nil,
    cleanseAdmission = nil,
    autoStealthAdmission = nil,
    autoStealthAttemptUntil = 0.0,
    autoStealthAssumeUntil = 0.0,
}

local function now_seconds()
    local value = gos.time_ms()
    return type(value) == "number" and value / 1000.0 or 0.0
end

local function player_handle()
    local world = gos.world()
    local player = world and world.player or nil
    if not player or type(player.handle) ~= "function" then return nil end
    local ok, handle = pcall(player.handle, player)
    return ok and handle or nil
end

local function update_combat_state()
    Runtime.combatBatch = nil
    if not gos.events or type(gos.events.combat) ~= "function" then return end
    local ok, batch = pcall(gos.events.combat, Runtime.combatCursor)
    if not ok or type(batch) ~= "table" then return end
    Runtime.combatCursor = batch.cursor
    Runtime.combatBatch = batch
    local handle = player_handle()
    if handle == nil then return end
    for _, event in ipairs(batch.events or {}) do
        if type(event) == "table" and event.kind == "combat" and
            event.source_handle == handle then
            if event.action == "enter_combat" then
                Runtime.inCombat = true
                Runtime.autoStealthAdmission = nil
                Runtime.autoStealthAssumeUntil = 0.0
            elseif event.action == "exit_combat" then
                Runtime.inCombat = false
                Runtime.autoStealthAttemptUntil = 0.0
                Runtime.autoStealthAssumeUntil = 0.0
            end
        end
    end
end

local function route_options()
    return {
        abilityQueueWindow = Config.abilityQueueWindow,
        allowAutoHolotraverse = not CursorHolotraverse.reserve_rotation(Settings),
        energyFloorPercent = Config.energyFloorPercent,
        inCombat = Runtime.inCombat,
        combatBatch = Runtime.combatBatch,
        cleanse = Cleanse.policy(Settings),
        autoStealthPending = now_seconds() < Runtime.autoStealthAssumeUntil,
        selfHealing = {
            enabled = setting_bool(Settings, "dps_self_heal_enabled", true),
            pvpOnly = setting_bool(Settings, "dps_self_heal_pvp_only", true),
            damageFirst = setting_bool(Settings, "dps_self_heal_damage_first", true),
            concealmentEnabled = setting_bool(Settings, "dps_self_heal_concealment", true),
            concealmentFillerRecovery = setting_bool(Settings, "concealment_heal_on_filler", true),
            lethalityEnabled = setting_bool(Settings, "dps_self_heal_lethality", true),
            probesEnabled = setting_bool(Settings, "dps_self_probes_enabled", true),
            directEnabled = setting_bool(Settings, "dps_self_direct_enabled", true),
            opportunityOnly = setting_bool(Settings, "dps_self_heal_opportunities_only", true),
            taReserve = setting_number(Settings, "dps_self_heal_ta_reserve", 0, 0, 1),
            useQuickening = setting_bool(Settings, "dps_self_quickening_enabled", true),
            quickeningWhileMoving = setting_bool(Settings, "dps_self_quickening_moving", true),
            quickeningBelow = setting_number(Settings, "dps_self_quickening_below", 90, 20, 99),
            assumePvP = setting_bool(Settings, "dps_self_heal_assume_pvp", false),
            healBelow = setting_number(Settings, "dps_self_heal_below", 70, 10, 95),
            healTo = setting_number(Settings, "dps_self_heal_to", 85, 20, 100),
            emergencyBelow = setting_number(Settings, "dps_self_heal_emergency", 35, 10, 60),
            probeRefresh = setting_number(Settings, "dps_self_probe_refresh", 3, 0.5, 6),
            probeReserve = setting_number(Settings, "dps_self_probe_reserve", 50, 0, 80),
            healReserve = setting_number(Settings, "dps_self_heal_reserve", 35, 0, 80),
        },
        autoStimBoost = Config.autoStimBoost,
        lethalityAutoToxicBlast = setting_bool(Settings, "lethality_auto_toxic_blast", true),
        lethalityTactical = Config.lethalityTactical,
        lethalityAutoTacticalSuperiority = Config.lethalityAutoTacticalSuperiority,
        lethalityAutoShieldProbe = setting_bool(Settings, "lethality_auto_shield_probe", true),
        lethalityShieldProbeBelow = setting_number(Settings, "lethality_shield_probe_below", 75, 10, 95),
        lethalityAutoTacticalOverdrive = Config.lethalityAutoTacticalOverdrive,
        lethalityEffectContinuity = setting_bool(Settings, "lethality_effect_continuity", true),
        lethalitySingleTargetHaze = Config.lethalitySingleTargetHaze,
        lethalityMinDotLifetime = Config.lethalityMinDotLifetime,
        corrosiveGrenadeRefreshSeconds = Config.corrosiveGrenadeRefreshSeconds,
        autoTacticalOverdrive = Config.medicineAutoTacticalOverdrive,
        medicineAutoShieldProbe = Config.medicineAutoShieldProbe,
        medicineShieldProbeBelow = Config.medicineShieldProbeBelow,
        medicineAutoBattleRez = Config.medicineAutoBattleRez,
        autoAdrenalineProbe = Config.autoAdrenalineProbe,
        adrenalineProbeThresholdPercent = Config.adrenalineProbeThresholdPercent,
        corrosiveDartRefreshSeconds = Config.corrosiveDartRefreshSeconds,
        aoeEnabled = Config.aoeEnabled,
        concealmentPvPAoEEnabled = Config.concealmentPvPAoEEnabled,
        concealmentAutoShieldProbe = setting_bool(Settings, "concealment_auto_shield_probe", true),
        concealmentShieldProbeBelow = setting_number(Settings, "concealment_shield_probe_below", 75, 10, 95),
        concealmentTactical = setting_string(Settings, "concealment_tactical", "Unknown / Other"),
        concealmentSpendReserveForProcs = setting_bool(Settings, "concealment_spend_reserve_for_procs", true),
        concealmentAutoTacticalOverdrive = setting_bool(Settings, "concealment_auto_tactical_overdrive", true),
        concealmentAutoCrippling = setting_bool(Settings, "concealment_auto_crippling", true),
        concealmentWoundsFollowup = setting_bool(Settings, "concealment_wounds_followup", true),
        automaticTargetCount = Config.automaticTargetCount,
        manualRelevantTargets = Config.manualRelevantTargets,
        aoeMinTargets = Config.aoeMinTargets,
        aoeClusterRadius = Config.aoeClusterRadius,
        healing = {
            triageMode = Config.medicineTriageMode,
            style = Config.medicineHealingStyle,
            targets = Config.medicineHealingTargets,
            koltoBurstMinAllies = Config.medicineKoltoBurstMinAllies,
            koltoProbeEveryone = Config.medicineKoltoProbeEveryone,
            koltoProbeTargets = Config.medicineKoltoProbeTargets,
            koltoProbeRefreshSeconds = Config.medicineKoltoProbeRefreshSeconds,
            nanotechMinAllies = Config.medicineNanotechMinAllies,
            koltoWavesMinAllies = Config.medicineKoltoWavesMinAllies,
        },
        dps = {
            enabled = Config.medicineDpsEnabled,
            energyReservePercent = Config.medicineDpsEnergyReservePercent,
            buildTactical = Config.medicineDpsBuildTactical,
            backstab = true,
            corrosiveDart = Config.medicineDpsCorrosiveDart,
            overloadShot = Config.medicineDpsOverloadShot,
            rifleShot = Config.medicineDpsRifleShot,
        },
        castLog = Config.castLog,
        decisionLog = Config.decisionLog,
        abilityDiagnostics = Config.abilityDiagnostics,
        onAction = function(action)
            MedicineActionWindow:push(action, medicine_action_config())
        end,
        logLine = log_line,
    }
end

local function try_shared_interrupt(loadout, rotation_active)
    if rotation_active~=true then
        InterruptController:reset()
        return false
    end
    if Executor:owns_command() then return false end
    local world=gos.world()
    if not world then return false end
    return InterruptController:attempt({
        active=true,
        pending=false,
        world=world,
        loadout=Mirror.raw_loadout(loadout),
        settings=Settings,
        policy=Interrupt.policy(Settings),
        log=log_line,
        submit=function(candidate,unit)
            local key="operative:interrupt:"..candidate.handle..":"..candidate.cast
            local result=Executor:submit(candidate.ability,unit,{
                idempotencyKey=key,
                target_fallback="none",
            })
            if type(result)~="table" then return {accepted=false} end
            local core=type(result.core)=="table" and result.core or {}
            local exact=core.target_mode=="explicit" and core.target_valid==true and
                core.requested_target_handle==candidate.handle and
                core.target_handle==candidate.handle and core.target_fallback=="none" and
                core.fallback_used~=true
            if result.admission_pending==true then
                return {admission_pending=exact}
            end
            local owned=Executor:owns_command()
            if result.accepted==true then
                if not exact then
                    if owned then Executor:cancel("interrupt_target_contract") end
                    log_line("warn","interrupt target contract mismatch; command cancelled")
                    return {owned=owned}
                end
                return {accepted=true,owned=true}
            end
            return {accepted=false,owned=owned}
        end,
    })
end

local function tick_stealth_detection()
    -- Visual-only: never gate hostile warnings on a DPS discipline, a pending
    -- loadout, the rotation key, player Stealth, combat, or casting ownership.
    if Config.stealthDetectionAwareness ~= true then return end
    StealthDetection.tick({
        visible = true,
        showRing = Config.stealthDetectionRangeRing,
        maxDistanceMeters = Config.stealthDetectionMaxDistanceMeters,
        iconSize = Config.stealthDetectionIconSize,
        heightMeters = Config.stealthDetectionHeightMeters,
        maxIcons = 2,
    })
end

local function try_auto_stealth(loadout, script_enabled, rotation_active)
    local pending_admission = Runtime.autoStealthAdmission
    if script_enabled ~= true or Config.autoStealthOutOfCombat ~= true then
        Runtime.autoStealthAdmission = nil
        return false
    end
    if Config.autoStealthActivation == AUTO_STEALTH_ROTATION_KEY and
        rotation_active ~= true then
        Runtime.autoStealthAdmission = nil
        return false
    end
    if Runtime.inCombat == true then
        Runtime.autoStealthAdmission = nil
        return false
    end
    if type(loadout) ~= "table" or loadout.status ~= "ready" or
        loadout.combat_style ~= "operative" or type(loadout.known) ~= "table" or
        loadout.known["Stealth"] ~= true then
        Runtime.autoStealthAdmission = nil
        return false
    end

    local status = Executor:status()
    local now = now_seconds()
    if Executor:owns_command() then
        return type(status) == "table" and status.idempotency_key == AUTO_STEALTH_KEY
    end

    if Runtime.autoStealthAssumeUntil > 0 and
        type(status) == "table" and status.idempotency_key == AUTO_STEALTH_KEY and
        status.core.acknowledged ~= true and
        (status.core.state == "failed" or status.core.state == "cancelled" or
            status.core.state == "superseded" or status.core.state == "abandoned") then
        -- Failed auto-Stealth must not repeatedly reserve the entire rotation.
        -- No command was activated, so let the route read actual Stealth state.
        Runtime.autoStealthAssumeUntil = 0.0
        Runtime.autoStealthAttemptUntil = now + 0.50
        return false
    end

    local world = gos.world()
    local player = world and world.player or nil
    if not player or type(player.effect) ~= "function" then
        Runtime.autoStealthAdmission = nil
        return false
    end
    local ok_effect, stealth = pcall(player.effect, player, "Stealth", { kind = "buff" })
    if (not ok_effect or type(stealth) ~= "table") and not pending_admission then
        return false
    end
    stealth = type(stealth) == "table" and stealth or {}
    if stealth.status == "ready" and stealth.present == true then
        Runtime.autoStealthAdmission = nil
        Runtime.autoStealthAssumeUntil = 0.0
        return false
    end

    if not pending_admission then
        if now < Runtime.autoStealthAssumeUntil then return true end
        if stealth.status ~= "ready" then return false end
        if now < Runtime.autoStealthAttemptUntil then return false end
    end

    local info = gos.abilities.info("Stealth")
    if type(info) ~= "table" or info.ability_handle == nil or info.on_bar ~= true or
        not pending_admission and gos.abilities.is_ready("Stealth") ~= true then
        Runtime.autoStealthAdmission = nil
        return false
    end
    local actor_epoch = world and world.actor_epoch or nil
    if pending_admission and
        (pending_admission.playerHandle ~= player_handle() or
            pending_admission.actorEpoch ~= nil and actor_epoch ~= nil and
                pending_admission.actorEpoch ~= actor_epoch or
            pending_admission.abilityHandle ~= info.ability_handle) then
        Runtime.autoStealthAdmission = nil
        return false
    end

    -- submit performs Core's authoritative admission. Do not put a separate
    -- asynchronous advisory check in front of each live-admission retry.
    Runtime.autoStealthAdmission = nil
    local result = Executor:submit("Stealth", nil, { idempotencyKey = AUTO_STEALTH_KEY })
    if type(result) == "table" and
        (result.accepted == true or result.admission_pending == true) then
        local core = type(result.core) == "table" and result.core or {}
        if core.target_mode ~= "none" or core.fallback_used == true then
            local owned = Executor:status()
            if Executor:owns_command() and type(owned) == "table" and
                owned.idempotency_key == AUTO_STEALTH_KEY then
                Executor:cancel("auto_stealth_target_contract")
            end
            Runtime.autoStealthAttemptUntil = now + 0.50
            log_line("warn", "auto stealth target contract mismatch; no alternate target path")
            return true
        end
        if result.admission_pending == true then
            local world_epoch = world and world.actor_epoch or nil
            Runtime.autoStealthAdmission = {
                playerHandle = player_handle(), actorEpoch = world_epoch,
                abilityHandle = info.ability_handle,
            }
            return true -- Retry next tick; no assumed Stealth or failure delay.
        end
    end
    if type(result) == "table" and result.accepted == true then
        Runtime.autoStealthAttemptUntil = now + 1.0
        Runtime.autoStealthAssumeUntil = now + 1.5
        log_line("info", "auto stealth queued: combat_state=" ..
            tostring(Runtime.inCombat == nil and "unknown_ready_guard" or "out_of_combat"))
        return true
    end

    local reason = type(result) == "table" and
        tostring(result.reason or result.code or "cast_failed") or "invalid_result"
    Runtime.autoStealthAttemptUntil = now +
        ((reason == "gcd" or reason == "cooldown") and 0.10 or 0.50)
    if Config.decisionLog then
        log_line("debug", "auto stealth not queued: reason=" .. reason)
    end
    return false
end

local function log_loadout(loadout, route_name)
    loadout = Mirror.raw_loadout(loadout)
    local signature = table.concat({
        tostring(loadout and loadout.status or "nil"),
        tostring(loadout and loadout.combat_style or "nil"),
        tostring(loadout and loadout.discipline or "nil"),
        tostring(route_name or "none"),
    }, "|")
    if Runtime.lastLoadout == signature then return end
    Runtime.lastLoadout = signature
    log_line("info", "loadout: status=" .. tostring(loadout and loadout.status or "nil") ..
        " style=" .. tostring(loadout and loadout.combat_style or "nil") ..
        " discipline=" .. tostring(loadout and loadout.discipline or "nil") ..
        " route=" .. tostring(route_name or "none"))
end

local function stop_all(reason)
    Runtime.cleanseAdmission = nil
    Runtime.autoStealthAdmission = nil
    local waiting = CursorHolo.stop(reason)
    waiting = DpsSelfHeal.stop(reason) or waiting
    waiting = ConcealmentRoute.stop(reason) or waiting
    waiting = LethalityRoute.stop(reason) or waiting
    waiting = MedicineRoute.stop(reason) or waiting
    return waiting
end

local function try_dps_cleanse(loadout, active, options, after_emergency)
    if not active or type(loadout) ~= "table" or loadout.status ~= "ready" or
        loadout.combat_style ~= "operative" or Executor:owns_command() then
        if not active or type(loadout) ~= "table" or loadout.status ~= "ready" or
            loadout.combat_style ~= "operative" then
            Runtime.cleanseAdmission = nil
        end
        return false
    end
    local owner = loadout.discipline == "Concealment" and "concealment" or
        loadout.discipline == "Lethality" and "lethality" or nil
    if not owner then
        Runtime.cleanseAdmission = nil
        return false
    end
    local world = gos.world()
    local player = world and world.player or nil
    local pending = Runtime.cleanseAdmission
    local function submit_cleanse(candidate, unit)
        local key = owner .. ":cleanse:" .. candidate.handle .. ":" .. candidate.key
        local info = gos.abilities.info(candidate.ability)
        local ability_handle = type(info) == "table" and info.ability_handle or nil
        Runtime.cleanseAdmission = nil
        local result = Executor:submit(candidate.ability, unit, {
            idempotencyKey = key, target_fallback = "none",
        })
        local core = type(result) == "table" and type(result.core) == "table" and result.core or {}
        local exact = Cleanse.explicit_target(core, candidate.handle)
        local admission_pending = type(result) == "table" and
            result.admission_pending == true and exact and type(ability_handle) == "string"
        if admission_pending then
            Runtime.cleanseAdmission = {
                owner = owner, candidate = candidate, key = key,
                playerHandle = player_handle(),
                actorEpoch = world and world.actor_epoch or nil,
                abilityHandle = ability_handle,
            }
        end
        return { accepted = type(result) == "table" and
                    result.accepted == true and exact,
            admission_pending = admission_pending,
            owned = Executor:owns_command(),
            reason = type(result) == "table" and result.reason or "invalid_cast_result",
            code = type(result) == "table" and result.code or nil }
    end
    if pending then
        local actor_epoch = world and world.actor_epoch or nil
        if pending.owner ~= owner or pending.playerHandle ~= player_handle() or
            pending.actorEpoch ~= nil and actor_epoch ~= nil and
                pending.actorEpoch ~= actor_epoch then
            Runtime.cleanseAdmission = nil
            return false
        end
        local info = gos.abilities.info(pending.candidate.ability)
        if type(info) ~= "table" or info.ability_handle ~= pending.abilityHandle then
            Runtime.cleanseAdmission = nil
            return false
        end
        local cap = Cleanse.capabilities(Mirror.raw_loadout(loadout))
        local unit, fresh_candidate
        if cap.status == "ready" then
            unit, fresh_candidate = Cleanse.refresh_candidate(pending.candidate, {
                active = active, loadout = Mirror.raw_loadout(loadout), world = world,
                policy = options.cleanse, preserve_stealth = true,
                auto_stealth_pending = options.autoStealthPending,
            }, cap)
        end
        if not unit then
            Runtime.cleanseAdmission = nil
            return false
        end
        pending.candidate = fresh_candidate
        submit_cleanse(pending.candidate, unit)
        return true
    end
    local hp = player and player:hp() or nil
    local emergency = type(hp) == "table" and type(hp.current) == "number" and
        type(hp.max) == "number" and hp.max > 0 and
        hp.current / hp.max * 100 <= options.selfHealing.emergencyBelow
    if emergency ~= after_emergency then return false end
    return Cleanse.attempt({
        active = active, loadout = Mirror.raw_loadout(loadout), world = world,
        admission_via_submit = true,
        policy = options.cleanse, log = log_line,
        preserve_stealth = true, auto_stealth_pending = options.autoStealthPending,
        submit = submit_cleanse,
    })
end

local function selected_route_has_local_pending(loadout)
    if ConcealmentRoute.is_selected(loadout) then
        return ConcealmentRoute.has_local_pending()
    end
    if LethalityRoute.is_selected(loadout) then
        return LethalityRoute.has_local_pending()
    end
    if MedicineRoute.is_selected(loadout) then
        return MedicineRoute.has_local_pending()
    end
    return false
end

local function dispatch(loadout, active, options)
    if ConcealmentRoute.is_selected(loadout) then
        log_loadout(loadout, "concealment")
        options.selfHealFiller = function(filler_name)
            return DpsSelfHeal.filler_tick(loadout, active, options, filler_name)
        end
        if LethalityRoute.stop("concealment_route_selected") then return end
        if MedicineRoute.stop("concealment_route_selected") then return end
        if Executor:owns_command() and not ConcealmentRoute.owns_pending() then return end
        ConcealmentRoute.tick(loadout, active, options)
        return
    end

    if LethalityRoute.is_selected(loadout) then
        log_loadout(loadout, "lethality")
        options.selfHealFiller = function(filler_name)
            return DpsSelfHeal.filler_tick(loadout, active, options, filler_name)
        end
        if ConcealmentRoute.stop("lethality_route_selected") then return end
        if MedicineRoute.stop("lethality_route_selected") then return end
        if Executor:owns_command() and not LethalityRoute.owns_pending() then return end
        LethalityRoute.tick(loadout, active, options)
        return
    end

    if MedicineRoute.is_selected(loadout) then
        log_loadout(loadout, "medicine")
        if ConcealmentRoute.stop("medicine_route_selected") then return end
        if LethalityRoute.stop("medicine_route_selected") then return end
        if Executor:owns_command() and not MedicineRoute.owns_pending() then return end
        MedicineRoute.tick(loadout, active, options)
        return
    end

    log_loadout(loadout, "none")
    stop_all("loadout_gate")
end

log_line("info", "loaded build=" .. BUILD_ID ..
    " concealment_runtime=" .. tostring(ConcealmentRoute.build_id) ..
    " self_heal_runtime=" .. tostring(DpsSelfHeal.build_id) ..
    " medicine_runtime=" .. tostring(MedicineRoute.build_id))
log_line("info", "stealth_detection_runtime=" .. tostring(StealthDetection.build_id) ..
    " icons=all_observed_detectors ring=selected_only")
log_line("info", "interrupt_runtime=" .. tostring(InterruptController.build_id) ..
    " db=" .. tostring(InterruptController.db_revision) .. " default_progress=85%")

log_line("info", "cursor_holotraverse_runtime=" .. CursorHolo.build_id .. " default_key=Shift+V outcome_diagnostics=r1")

-- Diagnostics only: never cancel/release a command because time has elapsed.
-- The top-level executor remains the single owner of lifecycle polling.
-- BEGIN_CURSOR_COMMAND_OUTCOME_DIAGNOSTICS
-- Read-only evidence after the dispatcher's one Executor:tick().
-- Recent exact handles retain late results after another request is submitted.
-- Diagnostic limits never cancel commands, hold the rotation, or retry casts.
local CURSOR_OUTCOME_MAX_RECORDS = 8
local CURSOR_OUTCOME_POLL_MS = 100
local CURSOR_OUTCOME_RETAIN_MS = 3000
local CURSOR_OUTCOME_PREFIX = "operative:cursor-holotraverse:"
local CursorOutcomeDiagnostic = {records={}, order={}, next_poll=0, last_handle=nil}

local function log_cursor_command_outcomes()
    local diagnostic = CursorOutcomeDiagnostic
    if Config.decisionLog ~= true and Config.abilityDiagnostics ~= true then
        if #diagnostic.order > 0 then diagnostic.records, diagnostic.order = {}, {} end
        return
    end
    local latest = Executor:status()
    local key = type(latest) == "table" and latest.idempotency_key or nil
    local handle = type(key) == "string" and
        key:sub(1, #CURSOR_OUTCOME_PREFIX) == CURSOR_OUTCOME_PREFIX and
        latest.command_handle or nil
    if type(handle) ~= "string" then handle = nil end
    if #diagnostic.order == 0 and (not handle or handle == diagnostic.last_handle) then return end
    local now = gos.time_ms()
    if type(now) ~= "number" or now ~= now or now == math.huge or now == -math.huge then return end
    if handle and handle ~= diagnostic.last_handle then
        diagnostic.last_handle = handle
        if not diagnostic.records[handle] then
            if #diagnostic.order >= CURSOR_OUTCOME_MAX_RECORDS then
                local oldest = table.remove(diagnostic.order, 1)
                diagnostic.records[oldest] = nil
                log_line("debug", "cursor Holotraverse: outcome_history_evicted command="..oldest.." diagnostic_only=true")
            end
            diagnostic.records[handle] = {key=key, expires=now+CURSOR_OUTCOME_RETAIN_MS}
            diagnostic.order[#diagnostic.order+1] = handle
        end
    end
    local function publish(command, row, status)
        if type(status) ~= "table" then return end
        local core = type(status.core) == "table" and status.core or status
        local function field(name)
            if status[name] ~= nil then return status[name] end
            return core[name]
        end
        local confirmed = core.activation_proven == true or core.acknowledged == true
        local outcome = confirmed and "activation_confirmed" or "activation_unconfirmed"
        local game_result_known = field("game_result_known")
        local value = "state="..tostring(core.state).." reason="..tostring(field("reason"))..
            " known="..tostring(core.known).." terminal="..tostring(core.terminal)..
            " outcome="..outcome.." acknowledged="..tostring(core.acknowledged)..
            " activation_proven="..tostring(core.activation_proven)..
            " cleanup_pending="..tostring(core.cleanup_pending)..
            " game_result_known="..tostring(game_result_known)..
            " game_result="..tostring(game_result_known == true and field("game_result") or "unknown")..
            " game_result_name="..tostring(game_result_known == true and field("game_result_name") or "unknown")..
            " game_result_source="..tostring(field("game_result_source"))..
            " target_mode="..tostring(core.target_mode)..
            " requested_target="..tostring(core.requested_target_handle)..
            " override="..tostring(field("target_override_applied"))..
            " restore_attempted="..tostring(field("target_restore_attempted"))..
            " restore_succeeded="..tostring(field("target_restore_succeeded"))..
            " explicit_state="..tostring(field("explicit_target_state"))..
            " explicit_failure="..tostring(field("explicit_target_failure"))
        if row.signature ~= value then
            row.signature, row.confirmed = value, confirmed
            log_line("info", "cursor Holotraverse: command_outcome command="..command.." key="..row.key.." "..value)
        end
    end
    if handle and diagnostic.records[handle] then publish(handle, diagnostic.records[handle], latest) end
    if now < diagnostic.next_poll then return end
    diagnostic.next_poll = now + CURSOR_OUTCOME_POLL_MS
    for index=#diagnostic.order,1,-1 do
        local command = diagnostic.order[index]
        local row = diagnostic.records[command]
        if command ~= handle and type(gos.abilities.command_status) == "function" then
            publish(command, row, gos.abilities.command_status(command))
        end
        if now >= row.expires then
            if row.confirmed ~= true then
                log_line("info", "cursor Holotraverse: outcome_window_closed command="..command..
                    " activation_unconfirmed=true diagnostic_only=true")
            end
            diagnostic.records[command] = nil
            table.remove(diagnostic.order, index)
        end
    end
end
-- END_CURSOR_COMMAND_OUTCOME_DIAGNOSTICS

local PendingDiagnostic = {}
local function log_pending_owner()
    if Config.decisionLog ~= true and Config.abilityDiagnostics ~= true then return end
    if not Executor:owns_command() then PendingDiagnostic.handle = nil; return end
    local status = Executor:status()
    if type(status) ~= "table" then return end
    local now = gos.time_ms()
    if type(now) ~= "number" then return end
    if PendingDiagnostic.handle ~= status.command_handle then
        PendingDiagnostic.handle = status.command_handle
        PendingDiagnostic.since, PendingDiagnostic.logged = now, now
        return
    end
    if not PendingDiagnostic.since or now - PendingDiagnostic.since < 2000 or
        now - PendingDiagnostic.logged < 5000 then return end
    PendingDiagnostic.logged = now
    log_line("debug", "casting owner pending: ability=" .. tostring(status.ability) ..
        " command=" .. tostring(status.command_handle) ..
        " state=" .. tostring(status.core.state) .. " reason=" .. tostring(status.reason) ..
        " age_ms=" .. tostring(now - PendingDiagnostic.since) ..
        " gcd=" .. tostring(gos.abilities.gcd_remaining()) ..
        " native_eff=" .. tostring(status.ability_activate_eff_result) ..
        " terminal=" .. tostring(status.core.terminal) ..
        " acknowledged=" .. tostring(status.core.acknowledged))
end

gos.on_tick(function()
    Settings = gos.settings.get(SCRIPT_ID) or Settings or {}
    apply_settings(Settings)
    local script_enabled = Settings.enabled == true
    if script_enabled then
        -- Publish awareness before all combat/event/rotation processing.
        tick_stealth_detection()
    else
        StealthDetection.reset()
    end
    update_combat_state()

    Executor:tick()
    log_cursor_command_outcomes()
    log_pending_owner()

    local loadout = Mirror.adapt_loadout(gos.abilities.loadout())
    ActiveLoadout = loadout
    local raw_loadout = Mirror.raw_loadout(loadout)
    local combat_style = type(raw_loadout) == "table" and raw_loadout.combat_style or nil
    if Runtime.combatStyle ~= combat_style then
        Runtime.combatStyle = combat_style
        if stop_all("combat_style_changed") then return end
    end
    local dpsBatch = DpsSelfHeal.observe_events(Runtime.combatBatch, loadout, gos.world())
    LethalityRoute.observe_events(dpsBatch, loadout, player_handle())
    ConcealmentRoute.observe_events(dpsBatch, loadout, player_handle())
    if script_enabled ~= true then
        InterruptController:reset()
        stop_all("script_disabled")
        return
    end

    local active = Settings.active == true
    local options = route_options()
    if MedicineRoute.is_selected(loadout) then
        MedicineActionWindow:draw(gos.world(), medicine_action_config())
    end
    -- Manual movement intent is independent of Mouse4 and runs before automatic
    -- spec/utility choices. The shared executor remains polled only above.
    if CursorHolo.tick({settings=Settings,loadout=Mirror.raw_loadout(loadout),enabled=script_enabled,log=log_line}) then return end
    -- Shared must-interrupt runs before spec GCD work, cleanses and self-heals.
    -- Distraction is off-GCD and explicit-targeted, so successful admission does
    -- not replace the player's visible selected target.
    if try_shared_interrupt(loadout, active) then return end
    if selected_route_has_local_pending(loadout) then
        dispatch(loadout, active, options)
        return
    end
    if Runtime.cleanseAdmission then
        if active then
            try_dps_cleanse(loadout, active, options, false)
        else
            Runtime.cleanseAdmission = nil
        end
        return
    end
    if DpsSelfHeal.has_local_pending() then
        DpsSelfHeal.tick(loadout, active, options)
        return
    end
    if Runtime.autoStealthAdmission then
        try_auto_stealth(loadout, script_enabled, active)
        return
    end
    if try_dps_cleanse(loadout, active, options, false) then return end
    if DpsSelfHeal.tick(loadout, active, options) then return end
    if try_dps_cleanse(loadout, active, options, true) then return end
    if try_auto_stealth(loadout, script_enabled, active) then return end

    dispatch(loadout, active, options)
end)
