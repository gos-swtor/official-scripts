-- sage.lua
--
-- Sage class rotation dispatcher. Discipline logic lives in the matching
-- common/sage/*.lua route module. This file owns settings, one shared
-- AbilityExecutor, and top-level route selection.
--
-- SCRIPT_ID is a compatibility key retained so existing settings persist.

local AbilityExecutor = require("combat.ability_executor")
local SageMirror = require("sage.mirror")
local SageBalance = require("sage.balance")
local SageSeer = require("sage.seer")
local SageTelekinetics = require("sage.telekinetics")
local HealerActionWindow = require("ui.healer_action_window")

local SCRIPT_ID = "telekinetics_rotation_r5_no_hardcast"
local BUILD_ID = "2026-09-30-sage-sorcerer-mirror-r27-personal-defaults-20261007-script-library-layout-r2-aoe-feed-overlay-local-ids-r1+counterpart-audit-20261019+counterpart-recheck-20261019-r4"

local Config = {
    abilityQueueWindow = 0.25,

    manualRelevantTargets = 1,
    automaticTargetCount = true,
    balanceMaxSpread = true,
    balanceMaxSpreadKey = "mouse5",
    balanceSpreadRadius = 20.0,
    balanceForcequakeRadius = 8.0,
    balanceForcequakeMinTargets = 3,
    balanceMovingRejuvenate = false,
    balanceRejuvenateHpPercent = 90,
    balanceSelfArmor = true,
    balanceMobilityAdvisor = true,
    balanceMobilityX = 0,
    balanceMobilityY = 160,
    balanceMobilityWidth = 320,
    targetClusterRadius = 8.5,
    forcequakeClusterRadius = 8.5,
    showTargetCountVisual = false,
    showMobilityBar = true,
    mobilityBarX = 0,
    mobilityBarY = 160,
    mobilityBarRefresh = 0.05,
    mobilityBarPlanRefresh = 0.10,
    targetCountVisualRefresh = 0.20,
    targetCountRefresh = 0.10,

    tremorsForcequakeMinTargets = 2,
    forcequakeMinTargets = 4,
    durableHpRatio = 1.0,
    mindCrushMinHpPercent = 50,

    seerTriageMode = "Incoming Damage Formula",
    seerHealingStyle = "Balanced",
    seerHealingTargets = "All Friendlies",
    seerAutoForceArmor = true,
    seerPreShieldIncoming = true,
    seerAutoForceMend = true,
    seerForceMendHpPercent = 75,
    seerAutoCleanse = true,
    seerCleanseSelf = true,
    seerCleanseAllies = true,
    seerCleansePhysical = true,
    seerCleansePressure = true,
    seerCleansePressureHpPercent = 90,
    seerCleanseMinRemaining = 0.8,
    seerActionWindowVisible = false,
    seerActionWindowX = 588,
    seerActionWindowY = 619,
    seerActionWindowFontSize = 24,
    seerActionWindowRows = 5,
    seerActionWindowLifetime = 8,
    seerActionWindowShowHealAmount = true,
    seerActionWindowShowDps = true,
    seerActionWindowShowProcs = true,
    seerAutoMentalAlacrity = true,
    seerAutoForcePotency = true,
    seerSalvationMinAllies = 3,
    seerAutoVindicate = true,
    seerVindicateBelowPercent = 85,
    seerDpsForceReservePercent = 40,
    seerCastTargetLines = true,
    seerCastTargetLineThickness = 2.5,
    seerCastTargetLineOutline = true,

    seerDpsEnabled = true,
    seerDpsWeakenMind = true,
    seerDpsForcequake = true,
    seerDpsMindCrush = true,
    seerDpsProject = true,
    seerDpsTelekineticThrow = true,
    seerDpsDisturbance = true,

    telekineticsBurstPooling = false,
    telekineticsBurstKey = "7",
    telekineticsBurstStatusLabel = true,
    telekineticsBurstProgressLabel = true,

    tidalInternalCooldown = 10.0,

    castLog = false,
    decisionLog = false,
}

local Settings = gos.settings.register(SCRIPT_ID, require("combat.cleanse").settings({
    title = "Sage / Sorcerer",
    version = 38,
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
            tooltip = "How early the script begins retrying the next priority before the current GCD/cast/channel ends.",
            default = 0.25,
            min = 0.05,
            max = 0.50,
            step = 0.01,
            disciplines = { "Balance", "Madness", "Telekinetics", "Lightning" },
        },
        {
            key = "manual_relevant_targets",
            type = "int",
            label = "Relevant Targets",
            tooltip = "Authoritative target count used by the priority system unless target-centered automatic counting succeeds.",
            default = 1,
            min = 1,
            max = 8,
            step = 1,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "automatic_target_count",
            type = "bool",
            label = "Target-Centered Auto Count",
            tooltip = "Counts hostiles around the current target only when unit-position data is available. Falls back to Relevant Targets; never counts every hostile near the player.",
            default = true,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "balance_max_spread",
            type = "bool",
            label = "Balance: Max AoE Spread",
            tooltip = "Maximizes spreadable DoT coverage around the current target. Uses Force in Balance when it can spread; otherwise temporarily casts missing Sever Force and Weaken Mind on one exact nearby target at a time without changing your selection.",
            default = true,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_max_spread_key",
            type = "hotkey",
            label = "Balance: Max Spread Key",
            tooltip = "Press once to enable Max AoE Spread and press again to disable it. The saved menu toggle follows the hotkey.",
            default = "mouse5",
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_spread_radius",
            type = "number",
            label = "Balance: Spread Radius",
            tooltip = "Radius in metres around the current target for Max AoE direct DoT candidates. A cyan range circle and orange next-target circle are shown while the mode runs.",
            default = 20.0,
            min = 1.0,
            max = 30.0,
            step = 0.5,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_forcequake_radius",
            type = "number",
            label = "Balance: Forcequake Radius",
            tooltip = "Radius in metres around the current target used for Balance Forcequake target counting.",
            default = 8.0,
            min = 1.0,
            max = 12.0,
            step = 0.5,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_forcequake_min_targets",
            type = "int",
            label = "Balance: Forcequake Targets",
            tooltip = "Minimum targets inside the Balance Forcequake count radius before Forcequake is allowed as an AoE filler.",
            default = 3,
            min = 2,
            max = 8,
            step = 1,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_moving_rejuvenate",
            type = "bool",
            label = "Balance: Moving Rejuvenate",
            tooltip = "Maintain your own Rejuvenate while moving and below the configured HP threshold, after all normal priorities and before Project filler.",
            default = false,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_rejuvenate_hp_percent",
            type = "int",
            label = "Balance: Rejuvenate HP %",
            tooltip = "Use moving Rejuvenate only while your HP is strictly below this percentage.",
            default = 90,
            min = 1,
            max = 100,
            step = 1,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_self_armor",
            type = "bool",
            label = "Balance: Self Mending Armor",
            tooltip = "Keep Mending Force Armor on yourself only when no observed Sage/Sorcerer shield or lockout effect is active.",
            default = true,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_mobility_advisor",
            type = "bool",
            label = "Balance Mobility Overlay: Enabled",
            tooltip = "While moving, fills toward the exact next stationary Balance priority. Yellow means keep moving until the countdown ends; red means stand now.",
            default = true,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_mobility_x",
            type = "int",
            label = "Balance Mobility Overlay: X",
            tooltip = "Horizontal offset in pixels from screen center.",
            default = 0,
            min = -3840,
            max = 3840,
            step = 1,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_mobility_y",
            type = "int",
            label = "Balance Mobility Overlay: Y",
            tooltip = "Vertical offset in pixels from screen center.",
            default = 160,
            min = -2160,
            max = 2160,
            step = 1,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "balance_mobility_width",
            type = "int",
            label = "Balance Mobility Overlay: Width",
            tooltip = "Width in pixels of the Balance movement countdown bar.",
            default = 320,
            min = 160,
            max = 640,
            step = 10,
            disciplines = { "Balance", "Madness" },
        },
        {
            key = "target_cluster_radius",
            type = "number",
            label = "Forceful Retribution Radius",
            tooltip = "Radius in metres around the current target used only for Forceful Retribution's hostile count.",
            default = 8.5,
            min = 1.0,
            max = 12.0,
            step = 0.5,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "forcequake_cluster_radius",
            type = "number",
            label = "Forcequake Count Radius",
            tooltip = "Radius in metres around the current target used for Tremors and normal Forcequake target counts.",
            default = 8.5,
            min = 1.0,
            max = 12.0,
            step = 0.5,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "show_target_count_visual",
            type = "bool",
            label = "Target Count Visual",
            tooltip = "Draw both configured count radii around the current target and label nearby hostiles with their Forceful and Forcequake membership plus exact distances.",
            default = false,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "show_mobility_bar",
            type = "bool",
            label = "Mobility Bar: Enabled",
            tooltip = "While moving, counts through known instant/mobile priorities to show when the next stationary priority needs you to stand.",
            default = true,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "overlay_mobility_bar_x",
            type = "int",
            label = "Mobility Bar: X",
            tooltip = "Horizontal offset in pixels from screen center.",
            default = 0,
            min = -3840,
            max = 3840,
            step = 1,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "overlay_mobility_bar_y",
            type = "int",
            label = "Mobility Bar: Y",
            tooltip = "Vertical offset in pixels from screen center.",
            default = 160,
            min = -2160,
            max = 2160,
            step = 1,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "tremors_forcequake_min_targets",
            type = "int",
            label = "Tremors Forcequake Targets",
            tooltip = "Minimum relevant targets for Forcequake when Tremors is active or expected from the preceding Wave.",
            default = 2,
            min = 2,
            max = 8,
            step = 1,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "forcequake_min_targets",
            type = "int",
            label = "Normal Forcequake Targets",
            tooltip = "Minimum relevant targets for Forcequake without Tremors.",
            default = 4,
            min = 2,
            max = 8,
            step = 1,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "durable_hp_ratio",
            type = "number",
            label = "Weaken Mind HP Ratio",
            tooltip = "A target is durable when current HP is at least this multiple of the player's maximum HP, or its rank is Strong/Elite/Champion/Boss.",
            default = 1.0,
            min = 0.5,
            max = 3.0,
            step = 0.1,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "mind_crush_min_hp_percent",
            type = "int",
            label = "Mind Crush HP Floor",
            tooltip = "Do not start Mind Crush unless a hostile player or durable NPC is above this HP percentage and likely to survive its cast plus DoT.",
            default = 50,
            min = 50,
            max = 80,
            step = 1,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "telekinetics_burst_pooling",
            type = "bool",
            label = "Telekinetics: Pool for Burst",
            tooltip = "Preserve the level-51 burst cooldowns and Force while using safe fillers during longer waits.",
            default = false,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "telekinetics_burst_key",
            type = "hotkey",
            label = "Telekinetics: Burst Key",
            tooltip = "Press once to prepare and execute the burst; press again to cancel it.",
            default = "7",
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "telekinetics_burst_status_label",
            type = "bool",
            label = "Telekinetics: Burst Status Label",
            tooltip = "Show Pool, Ready, Active, or Blocked over the selected burst target.",
            default = true,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "telekinetics_burst_progress_label",
            type = "bool",
            label = "Telekinetics: Burst Readiness %",
            tooltip = "Show readiness from the exact level-51 cooldown, Force, loadout, and Tidal gates.",
            default = true,
            disciplines = { "Telekinetics", "Lightning" },
        },
        {
            key = "seer_triage_mode",
            type = "select",
            label = "Seer: Heal Priority",
            tooltip = "Current HP preserves the existing target order. Incoming Damage Formula ranks recent pressure, attackers, observed HoT carry, projected HP, and time-to-die.",
            default = "Incoming Damage Formula",
            options = { "Current HP", "Incoming Damage Formula" },
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_healing_style",
            type = "select",
            label = "Seer Healing: Style",
            tooltip = "Choose the overall healing aggressiveness. Safe heals earlier, Balanced preserves the normal triage profile, and Efficient waits for more meaningful damage before spending healing GCDs.",
            default = "Balanced",
            options = { "Safe", "Balanced", "Efficient" },
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_healing_targets",
            type = "select",
            label = "Seer Healing: Targets",
            tooltip = "Choose which friendly unit types Seer may heal. All Friendlies preserves support for players, companions, and valid friendly NPCs.",
            default = "All Friendlies",
            options = { "Players only", "Players + Companions", "All Friendlies" },
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_auto_cleanse",
            type = "bool",
            label = "Seer PvP: Auto Cleanse",
            tooltip = "Use the shared researched PvP cleanse catalog. Physical coverage requires learned Mend Wounds; ambiguous effects are never guessed.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cleanse_self",
            type = "bool",
            label = "Seer PvP: Cleanse Self",
            tooltip = "Allow automatic Restoration on the Sage when a proven cleanseable PvP control effect is active.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cleanse_allies",
            type = "bool",
            label = "Seer PvP: Cleanse Allies",
            tooltip = "Allow automatic Restoration on friendly players in healing range when a proven cleanseable PvP control effect is active.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cleanse_physical",
            type = "bool",
            label = "Seer PvP: Physical with Mend Wounds",
            tooltip = "When Mend Wounds is learned, let Restoration also clear allow-listed Physical crowd control and pressure debuffs. This setting never treats Physical effects as cleanseable without the passive.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cleanse_pressure",
            type = "bool",
            label = "Seer PvP: Cleanse Pressure Debuffs",
            tooltip = "After control and movement candidates, cleanse verified pressure effects such as Trauma and Assailable. Unverified older pressure aliases stay disabled.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cleanse_pressure_hp_percent",
            type = "int",
            label = "Seer PvP: Pressure Cleanse HP %",
            tooltip = "Only spend Restoration on the lowest-priority pressure-debuff tier when that player is at or below this HP percentage. Must-cleanse CC ignores this threshold.",
            default = 90,
            min = 30,
            max = 100,
            step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cleanse_min_remaining",
            type = "number",
            label = "Seer PvP: Min Cleanse Remaining",
            tooltip = "Do not spend Restoration on an eligible control, movement or pressure debuff with less than this many seconds remaining.",
            default = 0.8,
            min = 0.0,
            max = 3.0,
            step = 0.1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_visible",
            type = "bool",
            label = "Seer Actions: Visible",
            tooltip = "Show the frameless Seer action feed. Use the on-screen X to hide it and this toggle to restore it.",
            default = false,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_x",
            type = "int",
            label = "Seer Actions: Position X",
            tooltip = "Horizontal screen position. Drag the on-screen handle to update it.",
            default = 588, min = 0, max = 7680, step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_y",
            type = "int",
            label = "Seer Actions: Position Y",
            tooltip = "Vertical screen position. Drag the on-screen handle to update it.",
            default = 619, min = 0, max = 4320, step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_font_size",
            type = "int",
            label = "Seer Actions: Main Font Size",
            tooltip = "Large action-line font size in pixels.",
            default = 24, min = 16, max = 36, step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_rows",
            type = "int",
            label = "Seer Actions: Visible Rows",
            tooltip = "Maximum recent Seer actions shown at once.",
            default = 5, min = 1, max = 8, step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_lifetime",
            type = "int",
            label = "Seer Actions: Lifetime",
            tooltip = "Seconds each accepted action remains visible before fading out.",
            default = 8, min = 2, max = 20, step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_show_heal_amount",
            type = "bool",
            label = "Seer Actions: Show Heal Amount",
            tooltip = "Accumulate measured player heal events into recent Seer healing actions. No overheal value is invented.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_show_damage",
            type = "bool",
            label = "Seer Actions: Show Damage",
            tooltip = "Show Seer's damaging actions and enrich them with measured damage from the combat-event stream.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_action_window_show_procs",
            type = "bool",
            label = "Seer Actions: Show Proc Enhancements",
            tooltip = "Highlight an accepted Seer action when a freshly observed learned/selected proc or buff materially enhanced that cast.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_auto_force_armor",
            type = "bool",
            label = "Seer Healing: Auto Force Armor",
            tooltip = "Use the selected Force Armor variant early in single-target triage. During healing lulls, protect the lowest partially injured eligible friendly before DPS while preserving the Force reserve. Four-plus clustered injuries and hard-reserve recovery remain higher-value exceptions.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_pre_shield_incoming",
            type = "bool",
            label = "Seer Healing: Pre-Shield Incoming",
            tooltip = "Pre-shield a healthy friendly when an observed hostile activation proves that exact friendly is being targeted. This is independent of routine Auto Force Armor.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_auto_force_mend",
            type = "bool",
            label = "Seer Healing: Auto Force Mend",
            tooltip = "Optional HP-threshold automation for Force Mend. Uses the configured HP threshold; the current API does not expose an exact predicted full-heal amount.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_force_mend_hp_percent",
            type = "int",
            label = "Seer Healing: Force Mend HP %",
            tooltip = "Only used when optional Auto Force Mend is enabled.",
            default = 75,
            min = 30,
            max = 100,
            step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_auto_mental_alacrity",
            type = "bool",
            label = "Seer Healing: Auto Mental Alacrity",
            tooltip = "Use Mental Alacrity during proven heavy healing pressure: a critical target with additional injured allies, or a five-plus injured Salvation cluster.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_auto_force_potency",
            type = "bool",
            label = "Seer Healing: Auto Force Potency",
            tooltip = "Use Force Potency with Healing Trance for heavy-healing or low-Force Resplendence generation when Conveyance is not already supplying the critical bonus.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_salvation_min_allies",
            type = "int",
            label = "Seer Healing: Salvation Allies",
            tooltip = "Minimum injured allies inside the Salvation area before Seer spends a GCD on Salvation.",
            default = 3,
            min = 2,
            max = 8,
            step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_auto_vindicate",
            type = "bool",
            label = "Seer Force: Auto Vindicate",
            tooltip = "Use Vindicate automatically with Resplendence first; Amnesty can safely cover one debt Vindicate but is preserved until Force is near the hard reserve or the buff is about to expire. Three Resplendence stacks may also be spent early to avoid proc overflow.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_vindicate_below_percent",
            type = "int",
            label = "Seer Force: Recover Below %",
            tooltip = "Spend earned Resplendence below this Force percentage. With no healing demand, soft-recovery Trance requires an existing Conveyance or Force Potency. Three-stack overflow, hard-reserve and Weary repair retain their recovery rules.",
            default = 85,
            min = 20,
            max = 99,
            step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_force_reserve_percent",
            type = "int",
            label = "Seer Force: Reserve %",
            tooltip = "Shared Force floor for healing and paid off-DPS. At or below it Seer suppresses Force-spending damage, while free/affordable idle DPS can still continue when no healing is needed.",
            default = 40,
            min = 0,
            max = 80,
            step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_min_ally_hp_percent",
            type = "int",
            label = "Seer DPS: Minimum Ally HP %",
            tooltip = "Commando-style all-clear gate. Seer will not spend a damage GCD while any eligible friendly is below this HP percentage; partial lulls can instead maintain Force Armor.",
            default = 98,
            min = 50,
            max = 100,
            step = 1,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cast_target_lines",
            type = "bool",
            label = "Seer Awareness: Cast Target Lines",
            tooltip = "Draw a line from each hostile unit with a proven active cast to the exact current target captured for that cast.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cast_target_line_thickness",
            type = "number",
            label = "Seer Awareness: Line Thickness",
            tooltip = "Thickness in pixels of the colored hostile-cast target line.",
            default = 2.5,
            min = 1.0,
            max = 6.0,
            step = 0.5,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_cast_target_line_outline",
            type = "bool",
            label = "Seer Awareness: Dark Outline",
            tooltip = "Draw a thicker dark line behind each cast-target line so relationships remain readable over the game world.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_enabled",
            type = "bool",
            label = "Seer DPS: Enabled",
            tooltip = "Use the selected hostile target for low-priority damage only after healing and safe Force recovery have no action to submit.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_weaken_mind",
            type = "bool",
            label = "Seer DPS: Weaken Mind",
            tooltip = "Maintain your own Weaken Mind on the selected hostile as Seer's first idle-DPS action whenever healing and Force recovery allow DPS. It is skipped while your own debuff is already active.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_forcequake",
            type = "bool",
            label = "Seer DPS: Forcequake",
            tooltip = "Use Forcequake on the selected hostile when the shared target-centered spatial count proves at least 2 relevant hostiles. Healing and safe Force recovery remain higher priority.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_mind_crush",
            type = "bool",
            label = "Seer DPS: Mind Crush",
            tooltip = "Use Mind Crush after Weaken Mind and any eligible 2+ target Forcequake while stationary and no healing or Force recovery action is needed.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_project",
            type = "bool",
            label = "Seer DPS: Project",
            tooltip = "Use Project after Mind Crush while stationary and as the direct filler while moving.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_telekinetic_throw",
            type = "bool",
            label = "Seer DPS: Telekinetic Throw",
            tooltip = "Use Telekinetic Throw after Project during stationary idle DPS windows.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "seer_dps_disturbance",
            type = "bool",
            label = "Seer DPS: Disturbance",
            tooltip = "Use Disturbance as the final stationary Seer DPS filler after the higher-priority damage abilities.",
            default = true,
            disciplines = { "Seer", "Corruption" },
        },
        {
            key = "cast_log",
            type = "bool",
            label = "Cast Log",
            tooltip = "Log executor admission, receipt-backed activation, exact Tidal grants, and Forcequake confirmation.",
            default = false,
        },
        {
            key = "decision_log",
            type = "bool",
            label = "Decision Log",
            tooltip = "Log deduplicated route gates, exact unavailable inputs, executor and combat-event waits, ability snapshots, and decision transitions.",
            default = false,
        },
    },
}))


local Executor = AbilityExecutor.new()
local ActiveLoadout
local RoutedExecutor = {}

local function routed_name(name)
    return SageMirror.ability(ActiveLoadout, name)
end

local function mirror_unavailable(name)
    return {
        accepted = false,
        new_command = false,
        blocks_submission = false,
        admission_pending = false,
        reason = "mirror_name_unavailable:" .. tostring(name),
    }
end

function RoutedExecutor:submit(name, target, options)
    local actual = routed_name(name)
    if actual == nil then return mirror_unavailable(name) end
    return Executor:submit(actual, target, options)
end

function RoutedExecutor:replace(name, target, options)
    local actual = routed_name(name)
    if actual == nil then return mirror_unavailable(name) end
    return Executor:replace(actual, target, options)
end

function RoutedExecutor:cancel(reason)
    return Executor:cancel(reason)
end

function RoutedExecutor:owns_command()
    return Executor:owns_command()
end

function RoutedExecutor:status()
    local status = Executor:status()
    if type(status) ~= "table" then return status end
    local out = {}
    for key, value in pairs(status) do out[key] = value end
    if type(out.ability) == "string" then
        out.ability = SageMirror.canonical(ActiveLoadout, out.ability) or out.ability
    end
    if type(out.name) == "string" then
        out.name = SageMirror.canonical(ActiveLoadout, out.name) or out.name
    end
    return out
end

function RoutedExecutor:receipt(command_handle)
    return Executor:receipt(command_handle)
end

function RoutedExecutor:can_replace()
    return Executor:can_replace()
end

local BalanceRoute = SageBalance.new(RoutedExecutor)
local SeerRoute = SageSeer.new(RoutedExecutor)
local TelekineticsRoute = SageTelekinetics.new(RoutedExecutor)

local SageExecutorOwner = {
    telekinetics = true,
    balance = true,
    seer = true,
}

local function executor_pending_owner()
    if not Executor:owns_command() then
        return nil
    end
    local status = Executor:status()
    local key = type(status) == "table" and status.idempotency_key or nil
    local owner = type(key) == "string" and key:match("^([^:]+):") or nil
    return SageExecutorOwner[owner] and owner or "unknown"
end

local Runtime = {
    seerCastAwareness = { cursor = nil, tick = 0, targets = {} },
    seerExplicitTargetWatches = {},
    buildLogged = false,
    settingsSignature = nil,
    lastActionRejectionSequence = 0,
    lastCoreLifecycleKey = nil,
    lastBalanceDispatchKey = nil,
    tickWatch = {
        lastTickMs = nil,
        stage = "init",
        stageAtMs = nil,
        seerSelected = false,
    },
}

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

local function positive(value)
    if type(value) == "number" and value > 0 then
        return value
    end
    return 0.0
end

local function bool_text(value)
    return value and "on" or "off"
end

local function log_line(level, message)
    if (level == "info" or level == "debug") and
        not (Config.castLog or Config.decisionLog or Settings.cleanse_diagnostics == true) then
        return
    end
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

local SAGE_TICK_WATCH_GAP_MS = 750
local SAGE_TICK_WATCH_STAGE_MS = 250

local function sage_tick_watch_mark(stage)
    local watch = Runtime.tickWatch
    local now = type(gos.time_ms) == "function" and gos.time_ms() or nil
    if type(now) ~= "number" then return end

    if Config.decisionLog and watch.seerSelected == true and
        type(watch.stageAtMs) == "number" then
        local elapsed = now - watch.stageAtMs
        if elapsed >= SAGE_TICK_WATCH_STAGE_MS then
            log_warn("route=sage phase=tick_watch slow_stage=" ..
                tostring(watch.stage or "unknown") ..
                " elapsed_ms=" .. tostring(math.floor(elapsed + 0.5)))
        end
    end
    watch.stage = tostring(stage or "unknown")
    watch.stageAtMs = now
end

local function sage_tick_watch_enter()
    local watch = Runtime.tickWatch
    local now = type(gos.time_ms) == "function" and gos.time_ms() or nil
    if type(now) ~= "number" then return end

    if Config.decisionLog and watch.seerSelected == true and
        type(watch.lastTickMs) == "number" then
        local gap = now - watch.lastTickMs
        if gap >= SAGE_TICK_WATCH_GAP_MS then
            log_warn("route=sage phase=tick_watch callback_gap_ms=" ..
                tostring(math.floor(gap + 0.5)) ..
                " previous_stage=" .. tostring(watch.stage or "unknown"))
        end
    end
    watch.lastTickMs = now
    watch.seerSelected = false
    watch.stage = "tick_enter"
    watch.stageAtMs = now
end

local function sage_tick_watch_seer(selected)
    Runtime.tickWatch.seerSelected = selected == true
end

local function setting_bool(settings, key, fallback)
    local value = settings and settings[key]
    if type(value) == "boolean" then
        return value
    end
    return fallback
end

local function setting_number(settings, key, fallback, minimum, maximum)
    local value = settings and settings[key] or nil
    if type(value) ~= "number" then
        value = fallback
    end
    return clamp(value, minimum, maximum)
end

local function setting_int(settings, key, fallback, minimum, maximum)
    return math.floor(setting_number(settings, key, fallback, minimum, maximum) + 0.5)
end

local function setting_string(settings, key, fallback)
    local value = settings and settings[key]
    return type(value) == "string" and value or fallback
end

local function apply_settings(settings)
    Config.abilityQueueWindow = setting_number(settings, "ability_queue_window", 0.25, 0.05, 0.50)
    Config.manualRelevantTargets = setting_int(settings, "manual_relevant_targets", 1, 1, 8)
    Config.automaticTargetCount = setting_bool(settings, "automatic_target_count", true)
    Config.balanceMaxSpread = setting_bool(settings, "balance_max_spread", true)
    Config.balanceMaxSpreadKey =
        setting_string(settings, "balance_max_spread_key", "mouse5")
    Config.balanceSpreadRadius =
        setting_number(settings, "balance_spread_radius", 20.0, 1.0, 30.0)
    Config.balanceForcequakeRadius =
        setting_number(settings, "balance_forcequake_radius", 8.0, 1.0, 12.0)
    Config.balanceForcequakeMinTargets =
        setting_int(settings, "balance_forcequake_min_targets", 3, 2, 8)
    Config.balanceMovingRejuvenate =
        setting_bool(settings, "balance_moving_rejuvenate", false)
    Config.balanceRejuvenateHpPercent =
        setting_int(settings, "balance_rejuvenate_hp_percent", 90, 1, 100)
    Config.balanceSelfArmor =
        setting_bool(settings, "balance_self_armor", true)
    Config.balanceMobilityAdvisor =
        setting_bool(settings, "balance_mobility_advisor", true)
    Config.balanceMobilityX =
        setting_int(settings, "balance_mobility_x", 0, -3840, 3840)
    Config.balanceMobilityY =
        setting_int(settings, "balance_mobility_y", 160, -2160, 2160)
    Config.balanceMobilityWidth =
        setting_int(settings, "balance_mobility_width", 320, 160, 640)
    Config.targetClusterRadius = setting_number(settings, "target_cluster_radius", 8.5, 1.0, 12.0)
    Config.forcequakeClusterRadius =
        setting_number(settings, "forcequake_cluster_radius", 8.5, 1.0, 12.0)
    Config.showTargetCountVisual = setting_bool(settings, "show_target_count_visual", false)
    Config.showMobilityBar = setting_bool(settings, "show_mobility_bar", true)
    Config.mobilityBarX = setting_int(settings, "overlay_mobility_bar_x", 0, -3840, 3840)
    Config.mobilityBarY = setting_int(settings, "overlay_mobility_bar_y", 160, -2160, 2160)
    Config.tremorsForcequakeMinTargets =
        setting_int(settings, "tremors_forcequake_min_targets", 2, 2, 8)
    Config.forcequakeMinTargets = setting_int(settings, "forcequake_min_targets", 4, 2, 8)
    Config.durableHpRatio = setting_number(settings, "durable_hp_ratio", 1.0, 0.5, 3.0)
    Config.mindCrushMinHpPercent = setting_int(settings, "mind_crush_min_hp_percent", 50, 50, 80)
    Config.seerTriageMode = setting_string(settings, "seer_triage_mode", "Incoming Damage Formula")
    if Config.seerTriageMode ~= "Incoming Damage Formula" then
        Config.seerTriageMode = "Current HP"
    end
    Config.seerHealingStyle = setting_string(settings, "seer_healing_style", "Balanced")
    Config.seerHealingTargets = setting_string(settings, "seer_healing_targets", "All Friendlies")
    Config.seerAutoForceArmor = setting_bool(settings, "seer_auto_force_armor", true)
    Config.seerPreShieldIncoming = setting_bool(settings, "seer_pre_shield_incoming", true)
    Config.seerAutoForceMend = setting_bool(settings, "seer_auto_force_mend", true)
    Config.seerForceMendHpPercent =
        setting_int(settings, "seer_force_mend_hp_percent", 75, 30, 100)
    Config.seerAutoCleanse = setting_bool(settings, "seer_auto_cleanse", true)
    Config.seerCleanseSelf = setting_bool(settings, "seer_cleanse_self", true)
    Config.seerCleanseAllies = setting_bool(settings, "seer_cleanse_allies", true)
    Config.seerCleansePhysical = setting_bool(settings, "seer_cleanse_physical", true)
    Config.seerCleansePressure = setting_bool(settings, "seer_cleanse_pressure", true)
    Config.seerCleansePressureHpPercent =
        setting_int(settings, "seer_cleanse_pressure_hp_percent", 90, 30, 100)
    Config.seerCleanseMinRemaining =
        setting_number(settings, "seer_cleanse_min_remaining", 0.8, 0.0, 3.0)
    Config.seerActionWindowVisible =
        setting_bool(settings, "seer_action_window_visible", false)
    Config.seerActionWindowX =
        setting_int(settings, "seer_action_window_x", 588, 0, 7680)
    Config.seerActionWindowY =
        setting_int(settings, "seer_action_window_y", 619, 0, 4320)
    Config.seerActionWindowFontSize =
        setting_int(settings, "seer_action_window_font_size", 24, 16, 36)
    Config.seerActionWindowRows =
        setting_int(settings, "seer_action_window_rows", 5, 1, 8)
    Config.seerActionWindowLifetime =
        setting_int(settings, "seer_action_window_lifetime", 8, 2, 20)
    Config.seerActionWindowShowHealAmount =
        setting_bool(settings, "seer_action_window_show_heal_amount", true)
    Config.seerActionWindowShowDps =
        setting_bool(settings, "seer_action_window_show_damage", true)
    Config.seerActionWindowShowProcs =
        setting_bool(settings, "seer_action_window_show_procs", true)
    Config.seerAutoMentalAlacrity =
        setting_bool(settings, "seer_auto_mental_alacrity", true)
    Config.seerAutoForcePotency =
        setting_bool(settings, "seer_auto_force_potency", true)
    Config.seerSalvationMinAllies =
        setting_int(settings, "seer_salvation_min_allies", 3, 2, 8)
    Config.seerAutoVindicate = setting_bool(settings, "seer_auto_vindicate", true)
    Config.seerVindicateBelowPercent =
        setting_int(settings, "seer_vindicate_below_percent", 85, 20, 99)
    Config.seerDpsForceReservePercent =
        setting_int(settings, "seer_dps_force_reserve_percent", 40, 0, 80)
    Config.seerDpsMinAllyHpPercent =
        setting_int(settings, "seer_dps_min_ally_hp_percent", 98, 50, 100)
    Config.seerCastTargetLines = setting_bool(settings, "seer_cast_target_lines", true)
    Config.seerCastTargetLineThickness =
        setting_number(settings, "seer_cast_target_line_thickness", 2.5, 1.0, 6.0)
    Config.seerCastTargetLineOutline =
        setting_bool(settings, "seer_cast_target_line_outline", true)
    Config.seerDpsEnabled = setting_bool(settings, "seer_dps_enabled", true)
    Config.seerDpsWeakenMind = setting_bool(settings, "seer_dps_weaken_mind", true)
    Config.seerDpsForcequake = setting_bool(settings, "seer_dps_forcequake", true)
    Config.seerDpsMindCrush = setting_bool(settings, "seer_dps_mind_crush", true)
    Config.seerDpsProject = setting_bool(settings, "seer_dps_project", true)
    Config.seerDpsTelekineticThrow =
        setting_bool(settings, "seer_dps_telekinetic_throw", true)
    Config.seerDpsDisturbance = setting_bool(settings, "seer_dps_disturbance", true)
    Config.telekineticsBurstPooling =
        setting_bool(settings, "telekinetics_burst_pooling", false)
    Config.telekineticsBurstKey =
        setting_string(settings, "telekinetics_burst_key", "7")
    Config.telekineticsBurstStatusLabel =
        setting_bool(settings, "telekinetics_burst_status_label", true)
    Config.telekineticsBurstProgressLabel =
        setting_bool(settings, "telekinetics_burst_progress_label", true)
    Config.castLog = setting_bool(settings, "cast_log", false)
    Config.decisionLog = setting_bool(settings, "decision_log", false)

    if not Runtime.buildLogged and (Config.castLog or Config.decisionLog) then
        Runtime.buildLogged = true
        log_line("info", "build=" .. BUILD_ID ..
            " route=sage/dispatcher hardcast_wave=off" ..
            " telekinetics_burst=level51" ..
            " resource_fallback=none executor_ownership_barrier=on" ..
            " core_direct_admission=on cooldown_shadow=off")
    end

    local signature = table.concat({
        string.format("%.2f", Config.abilityQueueWindow),
        tostring(Config.manualRelevantTargets),
        bool_text(Config.automaticTargetCount),
        bool_text(Config.balanceMaxSpread),
        tostring(Config.balanceMaxSpreadKey),
        string.format("%.1f", Config.balanceSpreadRadius),
        string.format("%.1f", Config.balanceForcequakeRadius),
        tostring(Config.balanceForcequakeMinTargets),
        bool_text(Config.balanceMovingRejuvenate),
        tostring(Config.balanceRejuvenateHpPercent),
        bool_text(Config.balanceSelfArmor),
        bool_text(Config.balanceMobilityAdvisor),
        tostring(Config.balanceMobilityX),
        tostring(Config.balanceMobilityY),
        tostring(Config.balanceMobilityWidth),
        string.format("%.1f", Config.targetClusterRadius),
        string.format("%.1f", Config.forcequakeClusterRadius),
        bool_text(Config.showTargetCountVisual),
        bool_text(Config.showMobilityBar),
        tostring(Config.mobilityBarX),
        tostring(Config.mobilityBarY),
        tostring(Config.tremorsForcequakeMinTargets),
        tostring(Config.forcequakeMinTargets),
        string.format("%.1f", Config.durableHpRatio),
        tostring(Config.mindCrushMinHpPercent),
        tostring(Config.seerHealingStyle),
        tostring(Config.seerHealingTargets),
        bool_text(Config.seerAutoForceArmor),
        bool_text(Config.seerPreShieldIncoming),
        bool_text(Config.seerAutoForceMend),
        tostring(Config.seerForceMendHpPercent),
        bool_text(Config.seerAutoCleanse),
        bool_text(Config.seerCleanseSelf),
        bool_text(Config.seerCleanseAllies),
        bool_text(Config.seerCleansePhysical),
        bool_text(Config.seerCleansePressure),
        tostring(Config.seerCleansePressureHpPercent),
        string.format("%.1f", Config.seerCleanseMinRemaining),
        bool_text(Config.seerActionWindowVisible),
        tostring(Config.seerActionWindowX),
        tostring(Config.seerActionWindowY),
        tostring(Config.seerActionWindowFontSize),
        tostring(Config.seerActionWindowRows),
        tostring(Config.seerActionWindowLifetime),
        bool_text(Config.seerActionWindowShowHealAmount),
        bool_text(Config.seerActionWindowShowDps),
        bool_text(Config.seerAutoMentalAlacrity),
        bool_text(Config.seerAutoForcePotency),
        tostring(Config.seerSalvationMinAllies),
        bool_text(Config.seerAutoVindicate),
        tostring(Config.seerVindicateBelowPercent),
        tostring(Config.seerDpsForceReservePercent),
        bool_text(Config.seerCastTargetLines),
        string.format("%.1f", Config.seerCastTargetLineThickness),
        bool_text(Config.seerCastTargetLineOutline),
        bool_text(Config.seerDpsEnabled),
        bool_text(Config.seerDpsWeakenMind),
        bool_text(Config.seerDpsForcequake),
        bool_text(Config.seerDpsMindCrush),
        bool_text(Config.seerDpsProject),
        bool_text(Config.seerDpsTelekineticThrow),
        bool_text(Config.seerDpsDisturbance),
        bool_text(Config.telekineticsBurstPooling),
        tostring(Config.telekineticsBurstKey),
        bool_text(Config.telekineticsBurstStatusLabel),
        bool_text(Config.telekineticsBurstProgressLabel),
        bool_text(Config.castLog),
        bool_text(Config.decisionLog),
    }, "|")

    if Runtime.settingsSignature ~= signature then
        Runtime.settingsSignature = signature
        log_info("settings: queue=" .. string.format("%.2f", Config.abilityQueueWindow) ..
            " targets=" .. tostring(Config.manualRelevantTargets) ..
            " auto_count=" .. bool_text(Config.automaticTargetCount) ..
            " balance_max_spread=" .. bool_text(Config.balanceMaxSpread) ..
            " balance_max_spread_key=" ..
                tostring(Config.balanceMaxSpreadKey) ..
            " balance_spread_radius=" ..
                string.format("%.1f", Config.balanceSpreadRadius) ..
            " balance_forcequake_radius=" ..
                string.format("%.1f", Config.balanceForcequakeRadius) ..
            " balance_forcequake_targets=" ..
                tostring(Config.balanceForcequakeMinTargets) ..
            " balance_moving_rejuvenate=" ..
                bool_text(Config.balanceMovingRejuvenate) ..
            " balance_rejuvenate_hp=" ..
                tostring(Config.balanceRejuvenateHpPercent) ..
            " balance_self_armor=" .. bool_text(Config.balanceSelfArmor) ..
            " balance_mobility_bar=" .. bool_text(Config.balanceMobilityAdvisor) ..
            " balance_mobility_xy=" .. tostring(Config.balanceMobilityX) .. "," ..
                tostring(Config.balanceMobilityY) ..
            " balance_mobility_width=" .. tostring(Config.balanceMobilityWidth) ..
            " forceful_radius=" .. string.format("%.1f", Config.targetClusterRadius) ..
            " forcequake_radius=" .. string.format("%.1f", Config.forcequakeClusterRadius) ..
            " count_visual=" .. bool_text(Config.showTargetCountVisual) ..
            " mobility_bar=" .. bool_text(Config.showMobilityBar) ..
            " mobility_xy=" .. tostring(Config.mobilityBarX) .. "," ..
            tostring(Config.mobilityBarY) ..
            " tremors_fq=" .. tostring(Config.tremorsForcequakeMinTargets) ..
            " normal_fq=" .. tostring(Config.forcequakeMinTargets) ..
            " mind_crush_floor=" .. tostring(Config.mindCrushMinHpPercent) ..
            " seer_style=" .. tostring(Config.seerHealingStyle) ..
            " seer_targets=" .. tostring(Config.seerHealingTargets) ..
            " seer_armor=" .. bool_text(Config.seerAutoForceArmor) ..
            " seer_pre_shield=" .. bool_text(Config.seerPreShieldIncoming) ..
            " seer_force_mend=" .. bool_text(Config.seerAutoForceMend) ..
            " seer_force_mend_hp=" .. tostring(Config.seerForceMendHpPercent) ..
            " seer_cleanse=" .. bool_text(Config.seerAutoCleanse) ..
            " seer_cleanse_self=" .. bool_text(Config.seerCleanseSelf) ..
            " seer_cleanse_allies=" .. bool_text(Config.seerCleanseAllies) ..
            " seer_cleanse_physical=" .. bool_text(Config.seerCleansePhysical) ..
            " seer_cleanse_pressure=" .. bool_text(Config.seerCleansePressure) ..
            " seer_cleanse_pressure_hp=" ..
                tostring(Config.seerCleansePressureHpPercent) ..
            " seer_cleanse_min=" ..
                string.format("%.1f", Config.seerCleanseMinRemaining) ..
            " seer_mental_alacrity=" .. bool_text(Config.seerAutoMentalAlacrity) ..
            " seer_force_potency=" .. bool_text(Config.seerAutoForcePotency) ..
            " seer_salvation_allies=" .. tostring(Config.seerSalvationMinAllies) ..
            " seer_vindicate=" .. bool_text(Config.seerAutoVindicate) ..
            " seer_vindicate_below=" .. tostring(Config.seerVindicateBelowPercent) ..
            " seer_dps_reserve=" .. tostring(Config.seerDpsForceReservePercent) ..
            " seer_dps_min_ally_hp=" .. tostring(Config.seerDpsMinAllyHpPercent) ..
            " seer_cast_lines=" .. bool_text(Config.seerCastTargetLines) ..
            " seer_cast_line_thickness=" ..
                string.format("%.1f", Config.seerCastTargetLineThickness) ..
            " seer_cast_line_outline=" .. bool_text(Config.seerCastTargetLineOutline) ..
            " seer_dps=" .. bool_text(Config.seerDpsEnabled) ..
            " seer_dps_wm=" .. bool_text(Config.seerDpsWeakenMind) ..
            " seer_dps_fq=" .. bool_text(Config.seerDpsForcequake) ..
            " seer_dps_mc=" .. bool_text(Config.seerDpsMindCrush) ..
            " seer_dps_project=" .. bool_text(Config.seerDpsProject) ..
            " seer_dps_tt=" .. bool_text(Config.seerDpsTelekineticThrow) ..
            " seer_dps_disturbance=" .. bool_text(Config.seerDpsDisturbance) ..
            " burst_pooling=" .. bool_text(Config.telekineticsBurstPooling) ..
            " burst_key=" .. tostring(Config.telekineticsBurstKey) ..
            " burst_status_label=" ..
                bool_text(Config.telekineticsBurstStatusLabel) ..
            " burst_progress_label=" ..
                bool_text(Config.telekineticsBurstProgressLabel))
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
    local value = safe_method(unit, "handle")
    return value
end

local function unit_reaction(unit)
    local value = safe_method(unit, "reaction")
    return value
end

local SEER_HEAL_ACTIONS = {
    ["Benevolence"] = true,
    ["Deliverance"] = true,
    ["Keeper of Peace"] = true,
    ["Healing Trance"] = true,
    ["Rejuvenate"] = true,
    ["Wandering Mend"] = true,
    ["Salvation"] = true,
    ["Force Mend"] = true,
}
local SEER_GROUP_HEALS = {
    ["Wandering Mend"] = true,
    ["Salvation"] = true,
}
local SEER_SHIELD_ACTIONS = {
    ["Force Armor"] = true,
    ["Mending Force Armor"] = true,
    ["Preserved Force Armor"] = true,
}
local SEER_SUPPORT_ACTIONS = {
    ["Mental Alacrity"] = true,
    ["Force Potency"] = true,
}
local SEER_DPS_ACTIONS = {
    ["Weaken Mind"] = true,
    ["Forcequake"] = true,
    ["Mind Crush"] = true,
    ["Project"] = true,
    ["Telekinetic Throw"] = true,
    ["Disturbance"] = true,
}

local SeerActionWindow = HealerActionWindow.new({
    idPrefix = "actions",
    scriptId = SCRIPT_ID,
    visibleKey = "seer_action_window_visible",
    xKey = "seer_action_window_x",
    yKey = "seer_action_window_y",
    title = "SEER ACTIONS",
    readyText = "SEER READY",
    resourceLabel = "FORCE RECOVERY",
    untargetedDamageLabel = "Self",
    log = log_line,
    healActions = SEER_HEAL_ACTIONS,
    groupHeals = SEER_GROUP_HEALS,
    protectActions = SEER_SHIELD_ACTIONS,
    resourceActions = { ["Vindicate"] = true },
    supportActions = SEER_SUPPORT_ACTIONS,
    dpsActions = SEER_DPS_ACTIONS,
    areaDamage = { ["Forcequake"] = true },
    displayAbility = function(ability)
        return SageMirror.ability(ActiveLoadout, ability) or ability
    end,
    formatRow = function(row, target)
        if row.category == "protect" then
            return (row.confirmed and "SHIELDED  " or "SHIELDING  ") .. target, row.ability
        elseif row.category == "cleanse" then
            return (row.confirmed and "DISPELLED  " or "DISPELLING  ") .. target,
                tostring(row.effect or "negative effect") .. "   -   " .. row.ability
        elseif row.category == "support" then
            return "PREPARED  " .. target, row.ability
        end
    end,
})

local function seer_action_config()
    return {
        visible = Config.seerActionWindowVisible,
        x = Config.seerActionWindowX,
        y = Config.seerActionWindowY,
        fontSize = Config.seerActionWindowFontSize,
        rows = Config.seerActionWindowRows,
        lifetime = Config.seerActionWindowLifetime,
        showHealAmount = Config.seerActionWindowShowHealAmount,
        showDamage = Config.seerActionWindowShowDps,
        showProcs = Config.seerActionWindowShowProcs,
    }
end

local function seer_action_push(action)
    SeerActionWindow:push(action, seer_action_config())
end

local function draw_seer_action_window(world)
    SeerActionWindow:draw(world, seer_action_config())
end

local SEER_CAST_AWARENESS_MAX_RELATIONSHIPS = 48
local SEER_CAST_AWARENESS_EVENT_PASSES = 4

local function reset_seer_cast_awareness()
    Runtime.seerCastAwareness.cursor = nil
    Runtime.seerCastAwareness.tick = 0
    Runtime.seerCastAwareness.targets = {}
end

local function seer_cast_identity_matches(cast, edge)
    if type(cast) ~= "table" or type(edge) ~= "table" then
        return false
    end
    local cast_handle = type(cast.ability_handle) == "string" and
        cast.ability_handle or nil
    local edge_handle = type(edge.abilityHandle) == "string" and
        edge.abilityHandle or nil
    if cast_handle and edge_handle then
        return cast_handle == edge_handle
    end
    return type(cast.name) == "string" and type(edge.name) == "string" and
        cast.name == edge.name
end

local function draw_seer_cast_target_lines(world)
    local awareness = Runtime.seerCastAwareness
    awareness.tick = awareness.tick + 1

    for _ = 1, SEER_CAST_AWARENESS_EVENT_PASSES do
        local batch = gos.events.combat(awareness.cursor)
        if type(batch) ~= "table" or type(batch.cursor) ~= "number" or
            type(batch.events) ~= "table" then
            reset_seer_cast_awareness()
            return
        end
        awareness.cursor = batch.cursor
        if batch.dropped ~= 0 then
            awareness.targets = {}
        end
        for index = 1, #batch.events do
            local event = batch.events[index]
            if type(event) == "table" and event.kind == "ability" and
                event.action == "ability_activate" and
                type(event.source_handle) == "string" and
                type(event.target_handle) == "string" then
                awareness.targets[event.source_handle] = {
                    targetHandle = event.target_handle,
                    abilityHandle = type(event.ability_handle) == "string" and
                        event.ability_handle or nil,
                    name = type(event.name) == "string" and event.name or nil,
                    createdTick = awareness.tick,
                    matched = false,
                }
            end
        end
        if batch.more ~= true then
            break
        end
    end

    local casts = gos.events.casts()
    if type(casts) ~= "table" then
        awareness.targets = {}
        return
    end

    local matched_sources = {}
    local drawn = 0
    for index = 1, #casts do
        local cast = casts[index]
        local source_handle = type(cast) == "table" and cast.unit_handle or nil
        local edge = type(source_handle) == "string" and
            awareness.targets[source_handle] or nil
        if edge and seer_cast_identity_matches(cast, edge) then
            edge.matched = true
            matched_sources[source_handle] = true
            local source = safe_method(world, "resolve", source_handle)
            local target = safe_method(world, "resolve", edge.targetHandle)
            if source and target and unit_reaction(source) == "hostile" and
                source_handle ~= edge.targetHandle and
                drawn < SEER_CAST_AWARENESS_MAX_RELATIONSHIPS then
                drawn = drawn + 1
                local line_id = string.format("seerctl%02d", drawn)
                if Config.seerCastTargetLineOutline then
                    gos.overlay.draw_line(line_id .. "o", {
                        from = { unit = source, anchor = "center" },
                        to = { unit = target, anchor = "center" },
                        color = { 0, 0, 0, 210 },
                        thickness = Config.seerCastTargetLineThickness + 2.0,
                        ttl = 0.25,
                        frame = true,
                    })
                end
                gos.overlay.draw_line(line_id, {
                    from = { unit = source, anchor = "center" },
                    to = { unit = target, anchor = "center" },
                    color = { 255, 72, 72, 235 },
                    thickness = Config.seerCastTargetLineThickness,
                    ttl = 0.25,
                    frame = true,
                })
            end
        end
    end

    for source_handle, edge in pairs(awareness.targets) do
        if edge.matched == true then
            if matched_sources[source_handle] ~= true then
                awareness.targets[source_handle] = nil
            end
        elseif awareness.tick > (edge.createdTick or 0) + 1 then
            awareness.targets[source_handle] = nil
        end
    end
end


local function log_action_rejection_capture()
    local snapshot = Executor:status()
    local status = type(snapshot) == "table" and snapshot.core or nil
    local sequence = type(status) == "table" and status.action_rejection_sequence or nil
    if type(status) ~= "table" or status.action_rejection_observed ~= true or
        type(sequence) ~= "number" or sequence <= Runtime.lastActionRejectionSequence then
        return
    end
    Runtime.lastActionRejectionSequence = sequence
    if not Config.decisionLog then
        return
    end

    local function number_text(value)
        return type(value) == "number" and string.format("%.3f", value) or "nil"
    end
    log_warn("Core action rejection captured: command=" ..
        tostring(status.command_handle or "-") ..
        " ability=" .. tostring(status.name or "-") ..
        " rejected_action=" .. tostring(status.action_rejection_name or "nil") ..
        " sequence=" .. tostring(sequence) ..
        " field10=" .. tostring(status.action_rejection_field_10 or "nil") ..
        " field18=" .. tostring(status.action_rejection_field_18 or "nil") ..
        " field28=" .. tostring(status.action_rejection_field_28 or "nil") ..
        " field30=" .. tostring(status.action_rejection_field_30 or "nil") ..
        " field54=" .. tostring(status.action_rejection_field_54 or "nil") ..
        " flag6f=" .. tostring(status.action_rejection_field_6f or "nil") ..
        " xyz90=" .. number_text(status.action_rejection_field_90) .. "," ..
            number_text(status.action_rejection_field_94) .. "," ..
            number_text(status.action_rejection_field_98) ..
        " valuea8=" .. number_text(status.action_rejection_field_a8) ..
        " flagb9=" .. tostring(status.action_rejection_field_b9 or "nil") ..
        " input_flag=" .. tostring(status.action_rejection_input_flag or "nil"))
end

local function watch_seer_explicit_target_command(command_handle, ability_name, target_handle)
    if not Config.decisionLog or
        type(command_handle) ~= "string" or command_handle == "" then
        return
    end
    Runtime.seerExplicitTargetWatches[command_handle] = {
        ability = ability_name,
        target = target_handle,
        lastKey = nil,
    }
end

local SeerExplicitTargetTerminalState = {
    restored = true,
    failed = true,
    abandoned = true,
}

local function log_seer_explicit_target_watches()
    if not Config.decisionLog then
        return
    end
    for command_handle, watch in pairs(Runtime.seerExplicitTargetWatches) do
        local receipt = Executor:receipt(command_handle)
        local status = type(receipt) == "table" and receipt.core or nil
        -- The bounded executor ledger owns historical observations. Eviction
        -- ends this diagnostic watch; it is not a fabricated command outcome.
        if receipt == nil then
            Runtime.seerExplicitTargetWatches[command_handle] = nil
        end
        if type(status) == "table" and status.known == true then
            local diagnostic_evidence =
                tostring(status.diagnostic_evidence or "")
            local repin_tail =
                string.match(diagnostic_evidence, "target_repin=.*")
            local key = table.concat({
                tostring(status.explicit_target_state or "-"),
                tostring(status.explicit_target_failure or "-"),
                tostring(status.explicit_target_requested_node_id or "-"),
                tostring(status.explicit_target_wire_node_id or "-"),
                tostring(status.explicit_target_activation_target_present == true),
                tostring(status.explicit_target_activation_node_id or "-"),
                tostring(status.explicit_target_request_event_sequence or 0),
                tostring(status.explicit_target_activation_event_sequence or 0),
                tostring(status.target_lease_state or "-"),
                tostring(status.target_lease_release_reason or "-"),
                tostring(status.target_restore_attempted == true),
                tostring(status.target_restore_succeeded == true),
                tostring(status.explicit_target_session_suspended == true),
                tostring(repin_tail or "-"),
            }, "|")
            if key ~= watch.lastKey then
                watch.lastKey = key
                local message = "Seer explicit target: command=" .. command_handle ..
                    " ability=" .. tostring(watch.ability or status.name or "-") ..
                    " target=" .. tostring(watch.target or "-") ..
                    " state=" .. tostring(status.explicit_target_state or "-") ..
                    " failure=" .. tostring(status.explicit_target_failure or "-") ..
                    " requested=" ..
                        tostring(status.explicit_target_requested_node_id or "-") ..
                    " wire=" .. tostring(status.explicit_target_wire_node_id or "-") ..
                    " activation_present=" ..
                        tostring(status.explicit_target_activation_target_present == true) ..
                    " activation=" ..
                        tostring(status.explicit_target_activation_node_id or "-") ..
                    " request_seq=" ..
                        tostring(status.explicit_target_request_event_sequence or 0) ..
                    " activation_seq=" ..
                        tostring(status.explicit_target_activation_event_sequence or 0) ..
                    " lease=" .. tostring(status.target_lease_state or "-") ..
                    " release=" ..
                        tostring(status.target_lease_release_reason or "-") ..
                    " restore=" .. tostring(status.target_restore_attempted == true) ..
                        "/" .. tostring(status.target_restore_succeeded == true) ..
                    " suspended=" ..
                        tostring(status.explicit_target_session_suspended == true) ..
                    " core_reason=" .. tostring(status.reason or "-") ..
                    " evidence=" .. tostring(status.diagnostic_evidence or "-")
                local failure = tostring(status.explicit_target_failure or "none")
                if failure ~= "none" or
                    status.explicit_target_session_suspended == true or
                    status.target_lease_state == "failed" then
                    log_warn(message)
                else
                    log_debug(message)
                end
                local lease_tail =
                    string.match(diagnostic_evidence, "target_lease=.*")
                local repin_interesting = lease_tail and
                    not string.find(lease_tail,
                        "target_repin=0/0/0/0/0/not_attempted", 1, true)
                if lease_tail and (failure ~= "none" or
                        status.explicit_target_session_suspended == true or
                        repin_interesting) then
                    local detail = "Seer target lease detail: command=" ..
                        command_handle .. " " .. lease_tail
                    if failure ~= "none" or
                        status.explicit_target_session_suspended == true then
                        log_warn(detail)
                    else
                        log_debug(detail)
                    end
                end
            end
            if SeerExplicitTargetTerminalState[status.explicit_target_state] then
                Runtime.seerExplicitTargetWatches[command_handle] = nil
            end
        end
    end
end

local function log_core_lifecycle()
    if not Config.decisionLog then
        Runtime.lastCoreLifecycleKey = nil
        return
    end
    local snapshot = Executor:status()
    local status = type(snapshot) == "table" and snapshot.core or nil
    if type(status) ~= "table" or status.known ~= true then
        return
    end

    local key = table.concat({
        tostring(status.command_handle or "-"),
        tostring(status.state or "-"),
        tostring(status.reason or "-"),
        tostring(status.last_lifecycle_sequence or 0),
        tostring(status.request_event_sequence or 0),
        tostring(status.request_native_lifecycle_sequence or 0),
        tostring(status.miniqueue_event_sequence or 0),
        tostring(status.miniqueue_native_lifecycle_sequence or 0),
        tostring(status.miniqueue_loss_event_sequence or 0),
        tostring(status.miniqueue_cancel_result or "-"),
        tostring(status.miniqueue_cancel_expected_player_node_id or "-"),
        tostring(status.miniqueue_cancel_expected_ability_id or "-"),
        tostring(status.miniqueue_cancel_expected_timestamp or "-"),
        tostring(status.miniqueue_cancel_expected_metadata or "-"),
        tostring(status.miniqueue_cancel_observed_player_node_id or "-"),
        tostring(status.miniqueue_cancel_observed_ability_id or "-"),
        tostring(status.miniqueue_cancel_observed_timestamp or "-"),
        tostring(status.miniqueue_cancel_observed_metadata or "-"),
        tostring(status.ability_activate_bound == true),
        tostring(status.ability_activate_event_sequence or 0),
        tostring(status.ability_activate_request_lifecycle_sequence or 0),
        tostring(status.activation_event_sequence or 0),
        tostring(status.baseline_gcd_sample_revision or 0),
        tostring(status.baseline_gcd_activation_revision or 0),
        tostring(status.competing_activation_event_sequence or 0),
        tostring(status.competing_activation_handle or "-"),
        tostring(status.competing_gcd_sample_revision or 0),
        tostring(status.competing_gcd_activation_revision or 0),
        tostring(status.request_capture_active == true),
        tostring(status.request_capture_records or 0),
        tostring(status.request_capture_dropped or 0),
        tostring(status.request_capture_unreadable or 0),
        tostring(status.ability_activate_capture_active == true),
        tostring(status.ability_activate_capture_records or 0),
        tostring(status.ability_activate_capture_dropped or 0),
        tostring(status.ability_activate_capture_unreadable or 0),
        tostring(status.miniqueue_mutation_capture_records or 0),
        tostring(status.miniqueue_mutation_capture_dropped or 0),
    }, "|")
    if key == Runtime.lastCoreLifecycleKey then
        return
    end
    Runtime.lastCoreLifecycleKey = key

    log_debug("Core lifecycle: command=" .. tostring(status.command_handle or "-") ..
        " ability=" .. tostring(status.name or "-") ..
        " state=" .. tostring(status.state or "-") ..
        " reason=" .. tostring(status.reason or "-") ..
        " bridge=" .. tostring(status.bridge_sequence or 0) ..
        " lifecycle=" .. tostring(status.last_lifecycle_sequence or 0) ..
        " request=" .. tostring(status.request_event_sequence or 0) ..
        " miniqueue=" .. tostring(status.miniqueue_event_sequence or 0) ..
        " miniqueue_native=" ..
            tostring(status.miniqueue_native_lifecycle_sequence or 0) ..
        " loss=" .. tostring(status.miniqueue_loss_event_sequence or 0) ..
        " miniqueue_cancel=" ..
            tostring(status.miniqueue_cancel_result or "-") ..
        " cancel_expected=" ..
            tostring(status.miniqueue_cancel_expected_player_node_id or "-") .. "/" ..
            tostring(status.miniqueue_cancel_expected_ability_id or "-") .. "/" ..
            tostring(status.miniqueue_cancel_expected_timestamp or "-") .. "/" ..
            tostring(status.miniqueue_cancel_expected_metadata or "-") ..
        " cancel_observed=" ..
            tostring(status.miniqueue_cancel_observed_player_node_id or "-") .. "/" ..
            tostring(status.miniqueue_cancel_observed_ability_id or "-") .. "/" ..
            tostring(status.miniqueue_cancel_observed_timestamp or "-") .. "/" ..
            tostring(status.miniqueue_cancel_observed_metadata or "-") ..
        " b934_bound=" .. tostring(status.ability_activate_bound == true) ..
        " b934_complete=" .. tostring(status.ability_activate_event_sequence or 0) ..
        " receipt=" .. tostring(status.request_native_lifecycle_sequence or 0) ..
            "/" .. tostring(status.ability_activate_request_lifecycle_sequence or 0) ..
        " b934_ok=" .. tostring(status.ability_activate_succeeded == true) ..
        " b934_eff=" .. tostring(status.ability_activate_eff_result or 0) ..
        " activation=" .. tostring(status.activation_event_sequence or 0) ..
        " competing=" .. tostring(status.competing_activation_event_sequence or 0) ..
            "/" .. tostring(status.competing_activation_handle or "-") ..
        " competing_gcd=" ..
            tostring(status.baseline_gcd_sample_revision or 0) ..
            "/" .. tostring(status.baseline_gcd_activation_revision or 0) ..
            "->" .. tostring(status.competing_gcd_sample_revision or 0) ..
            "/" .. tostring(status.competing_gcd_activation_revision or 0) ..
        " request_capture=" .. tostring(status.request_capture_records or 0) ..
            "/" .. tostring(status.request_capture_dropped or 0) ..
            "/" .. tostring(status.request_capture_unreadable or 0) ..
        " b934_capture=" .. tostring(status.ability_activate_capture_records or 0) ..
            "/" .. tostring(status.ability_activate_capture_dropped or 0) ..
            "/" .. tostring(status.ability_activate_capture_unreadable or 0) ..
        " miniqueue_capture=" ..
            tostring(status.miniqueue_mutation_capture_records or 0) ..
            "/" .. tostring(status.miniqueue_mutation_capture_dropped or 0) ..
        " hooks=" .. tostring(status.request_capture_active == true) ..
            "/" .. tostring(status.ability_activate_capture_active == true) ..
        " evidence=" .. tostring(status.diagnostic_evidence or "-"))
end


local function log_balance_dispatch_gate(reason)
    if not Config.decisionLog then
        Runtime.lastBalanceDispatchKey = nil
        return
    end
    local status = Executor:status()
    local core = type(status) == "table" and status.core or nil
    local owner = executor_pending_owner() or "none"
    local key = table.concat({
        tostring(reason),
        tostring(owner),
        tostring(type(status) == "table" and status.command_handle or "-"),
        tostring(type(core) == "table" and core.state or "-"),
        tostring(type(status) == "table" and status.disposition or "-"),
        tostring(type(status) == "table" and status.reason or "-"),
    }, "|")
    if Runtime.lastBalanceDispatchKey == key then
        return
    end
    Runtime.lastBalanceDispatchKey = key
    log_debug("route=balance phase=dispatch state=blocked" ..
        " reason=" .. tostring(reason) ..
        " owner=" .. tostring(owner) ..
        " command=" .. tostring(
            type(status) == "table" and status.command_handle or "-") ..
        " ability=" .. tostring(
            type(status) == "table" and status.ability or "-") ..
        " command_state=" .. tostring(
            type(core) == "table" and core.state or "-") ..
        " executor_state=" .. tostring(
            type(status) == "table" and status.disposition or "-") ..
        " core_reason=" .. tostring(
            type(status) == "table" and status.reason or "-") ..
        " idempotency=" .. tostring(
            type(status) == "table" and status.idempotency_key or "-") ..
        " awaiting_terminal=" .. tostring(
            type(status) == "table" and status.owns_command == true))
end

local function clear_balance_dispatch_gate()
    if Runtime.lastBalanceDispatchKey == nil then
        return
    end
    log_debug("route=balance phase=dispatch state=cleared")
    Runtime.lastBalanceDispatchKey = nil
end

Runtime.cleanse = require("combat.cleanse")
function Runtime.sync_profile(loadout)
    local profile = type(loadout) == "table" and loadout.status == "ready" and
        tostring(loadout._sage_mirror_style or loadout.combat_style) .. ":" ..
        tostring(loadout._sage_mirror_discipline or loadout.discipline) or nil
    if profile and Runtime.mirrorProfile and profile ~= Runtime.mirrorProfile then
        Runtime.cleanseAdmission = nil
        local waiting = TelekineticsRoute.stop("combat_style_changed")
        waiting = BalanceRoute.stop("combat_style_changed") or waiting
        waiting = SeerRoute.stop("combat_style_changed", true) or waiting
        if waiting or Executor:owns_command() then return false end
        reset_seer_cast_awareness()
    end
    if profile then
        Runtime.mirrorProfile = profile
        ActiveLoadout = loadout
    end
    return true
end

function Runtime.try_dps_cleanse(loadout, active)
    if not active or type(loadout) ~= "table" or loadout.status ~= "ready" or
        loadout.combat_style ~= "sage" or Executor:owns_command() or
        TelekineticsRoute.blocks_cleanse() then
        if not active then Runtime.cleanseAdmission = nil end
        return false
    end
    local owner = loadout.discipline == "Balance" and "balance" or
        loadout.discipline == "Telekinetics" and "telekinetics" or nil
    if not owner or owner == "telekinetics" and
        TelekineticsRoute.burst_active() then return false end
    local world = gos.world()
    local player = world and world.player or nil
    local player_handle = unit_handle(player)
    local actor_epoch = world and world.actor_epoch or nil
    local policy = Runtime.cleanse.policy(Settings)
    local function submit(candidate, unit)
        local key = owner .. ":cleanse:" .. candidate.handle .. ":" .. candidate.key
        local actual = routed_name(candidate.ability)
        local info = actual and gos.abilities.info(actual) or nil
        Runtime.cleanseAdmission = nil
        -- Cleansing preempts an unowned DPS admission, never an owned command.
        if owner == "balance" then BalanceRoute.clear_native_admission()
        else TelekineticsRoute.clear_native_admission() end
        local result = RoutedExecutor:submit(candidate.ability, unit, {
            idempotencyKey = key, target_fallback = "none",
        })
        local core = type(result) == "table" and result.core or nil
        local exact = Runtime.cleanse.explicit_target(core, candidate.handle)
        if type(result) == "table" and result.admission_pending == true and exact and
            type(info) == "table" and type(info.ability_handle) == "string" then
            Runtime.cleanseAdmission = { candidate = candidate, owner = owner,
                player = player_handle, epoch = actor_epoch, ability = info.ability_handle }
        end
        if type(result) == "table" and (result.accepted == true or result.admission_pending == true) and
            not exact and Executor:owns_command() then
            local status = Executor:status()
            if type(status) == "table" and status.idempotency_key == key and
                status.command_handle == result.command_handle then
                Executor:cancel("cleanse_target_contract")
            end
        end
        return { accepted = type(result) == "table" and result.accepted == true and exact,
            owned = Executor:owns_command(), admission_pending = Runtime.cleanseAdmission ~= nil,
            reason = type(result) == "table" and result.reason or "invalid_cast_result",
            code = type(result) == "table" and result.code or nil }
    end
    local pending = Runtime.cleanseAdmission
    if pending then
        local actual = routed_name(pending.candidate.ability)
        local info = actual and gos.abilities.info(actual) or nil
        if pending.owner ~= owner or pending.player ~= player_handle or
            pending.epoch ~= nil and actor_epoch ~= nil and pending.epoch ~= actor_epoch or
            type(info) ~= "table" or info.ability_handle ~= pending.ability then
            Runtime.cleanseAdmission = nil
            return false
        end
        local cap = Runtime.cleanse.capabilities(loadout)
        local unit, candidate
        if cap.status == "ready" then
            unit, candidate = Runtime.cleanse.refresh_candidate(pending.candidate, {
                active = active, loadout = loadout, world = world, policy = policy,
            }, cap)
        end
        if not unit or not candidate then Runtime.cleanseAdmission = nil; return false end
        pending.candidate = candidate
        submit(candidate, unit)
        return true
    end
    return Runtime.cleanse.attempt({
        active = active, loadout = loadout, world = world,
        admission_via_submit = true,
        ability_name = function(name)
            return SageMirror.ability(ActiveLoadout, name)
        end,
        policy = policy, log = log_line, submit = submit,
    })
end

-- Class route: canonical Sage priorities with an explicit Sorcerer boundary.
gos.on_tick(function()
    sage_tick_watch_enter()
    sage_tick_watch_mark("settings")
    Settings = gos.settings.get(SCRIPT_ID) or Settings or {}
    apply_settings(Settings)
    TelekineticsRoute.configure(Config)

    sage_tick_watch_mark("loadout")
    local loadout = SageMirror.adapt_loadout(gos.abilities.loadout())
    local rotation_active =
        Settings.enabled == true and Settings.active == true
    local burst_pressed = Config.telekineticsBurstKey ~= "" and
        gos.input.was_pressed(Config.telekineticsBurstKey)

    sage_tick_watch_mark("executor")
    Executor:tick()
    if not Runtime.sync_profile(loadout) then return end
    sage_tick_watch_mark("lifecycle_logs")
    log_core_lifecycle()
    log_action_rejection_capture()
    log_seer_explicit_target_watches()

    sage_tick_watch_mark("dispatch")
    if SeerRoute.is_selected(loadout) then
        sage_tick_watch_seer(true)
        Runtime.lastBalanceDispatchKey = nil
        sage_tick_watch_mark("seer_world")
        local seer_world = gos.world()
        sage_tick_watch_mark("seer_visual")
        if Settings.enabled == true and Config.seerCastTargetLines and seer_world then
            draw_seer_cast_target_lines(seer_world)
        else
            reset_seer_cast_awareness()
        end
        sage_tick_watch_mark("seer_route_stops")
        if TelekineticsRoute.stop("seer_route_selected") then
            sage_tick_watch_mark("tick_exit")
            return
        end
        if BalanceRoute.stop("seer_route_selected") then
            sage_tick_watch_mark("tick_exit")
            return
        end
        if Executor:owns_command() and not SeerRoute.owns_pending() then
            sage_tick_watch_mark("tick_exit")
            return
        end
        sage_tick_watch_mark("seer_tick")
        SeerRoute.tick(loadout, rotation_active, {
            castLog = Config.castLog,
            decisionLog = Config.decisionLog,
            logLine = log_line,
            onExplicitTargetCommand = watch_seer_explicit_target_command,
            onAction = seer_action_push,
            cleanse = Runtime.cleanse.policy(Settings),
            healing = {
                triageMode = Config.seerTriageMode,
                style = Config.seerHealingStyle,
                targets = Config.seerHealingTargets,
                autoForceArmor = Config.seerAutoForceArmor,
                preShieldIncoming = Config.seerPreShieldIncoming,
                autoForceMend = Config.seerAutoForceMend,
                forceMendHpPercent = Config.seerForceMendHpPercent,
                autoCleanse = Config.seerAutoCleanse,
                cleanseSelf = Config.seerCleanseSelf,
                cleanseAllies = Config.seerCleanseAllies,
                cleansePhysical = Config.seerCleansePhysical,
                cleansePressure = Config.seerCleansePressure,
                cleansePressureHpPercent = Config.seerCleansePressureHpPercent,
                cleanseMinRemaining = Config.seerCleanseMinRemaining,
                autoMentalAlacrity = Config.seerAutoMentalAlacrity,
                autoForcePotency = Config.seerAutoForcePotency,
                salvationMinAllies = Config.seerSalvationMinAllies,
                autoVindicate = Config.seerAutoVindicate,
                vindicateBelowPercent = Config.seerVindicateBelowPercent,
            },
            dps = {
                enabled = Config.seerDpsEnabled,
                forceReservePercent = Config.seerDpsForceReservePercent,
                minAllyHpPercent = Config.seerDpsMinAllyHpPercent,
                weakenMind = Config.seerDpsWeakenMind,
                forcequake = Config.seerDpsForcequake,
                mindCrush = Config.seerDpsMindCrush,
                project = Config.seerDpsProject,
                telekineticThrow = Config.seerDpsTelekineticThrow,
                disturbance = Config.seerDpsDisturbance,
            },
        })
        sage_tick_watch_mark("seer_action_window")
        if Settings.enabled == true then
            draw_seer_action_window(seer_world)
        end
        sage_tick_watch_mark("tick_exit")
        return
    end
    reset_seer_cast_awareness()
    if SeerRoute.stop("loadout_gate", rotation_active ~= true) then
        if BalanceRoute.is_selected(loadout) then
            log_balance_dispatch_gate("seer_command_awaiting_terminal")
        end
        return
    end

    if Runtime.try_dps_cleanse(loadout, rotation_active) then return end

    if BalanceRoute.is_selected(loadout) then
        local spread_pressed = Config.balanceMaxSpreadKey ~= "" and
            gos.input.was_pressed(Config.balanceMaxSpreadKey)
        if spread_pressed then
            local next_value = not Config.balanceMaxSpread
            local changed, change_error = gos.settings.set(
                SCRIPT_ID, "balance_max_spread", next_value)
            if changed then
                Config.balanceMaxSpread = next_value
                log_line("info", "balance max spread hotkey: enabled=" ..
                    tostring(next_value) ..
                    " key=" .. tostring(Config.balanceMaxSpreadKey))
            else
                log_line("warn", "balance max spread hotkey rejected: " ..
                    tostring(change_error or "unknown"))
            end
        end
        if TelekineticsRoute.stop("balance_route_selected") then
            log_balance_dispatch_gate("telekinetics_command_awaiting_terminal")
            return
        end
        if Executor:owns_command() and not BalanceRoute.owns_pending() then
            log_balance_dispatch_gate("foreign_command_pending")
            return
        end
        clear_balance_dispatch_gate()
        BalanceRoute.tick(loadout, rotation_active, {
            castLog = Config.castLog,
            decisionLog = Config.decisionLog,
            abilityQueueWindow = Config.abilityQueueWindow,
            maxSpread = Config.balanceMaxSpread,
            spreadKey = Config.balanceMaxSpreadKey,
            spreadRadius = Config.balanceSpreadRadius,
            forcequakeRadius = Config.balanceForcequakeRadius,
            forcequakeMinTargets = Config.balanceForcequakeMinTargets,
            movingRejuvenate = Config.balanceMovingRejuvenate,
            rejuvenateHpPercent = Config.balanceRejuvenateHpPercent,
            selfArmor = Config.balanceSelfArmor,
            mobilityAdvisor = Config.balanceMobilityAdvisor,
            mobilityX = Config.balanceMobilityX,
            mobilityY = Config.balanceMobilityY,
            mobilityWidth = Config.balanceMobilityWidth,
            logLine = log_line,
        })
        return
    end
    Runtime.lastBalanceDispatchKey = nil
    if BalanceRoute.stop("loadout_gate") then
        return
    end

    TelekineticsRoute.tick(loadout, rotation_active, burst_pressed)
end)
