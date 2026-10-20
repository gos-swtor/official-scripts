local SCRIPT_ID = "pvp_sense"
local BUILD_ID = "2026-10-05-hostile-class-colors-r10-personal-defaults-20261007-script-library-layout-r1"
local TAG = "[pvp-sense] "
local ICON_ROOT = SPRITE_PATH .. "swtor\\"
local TTL = 0.20
local MAX_DRAW_COMMANDS = 120
local DRAW_CATEGORIES = { "defensive", "offensive" }
local NAMEPLATE_FAR_SCALE = 0.5
local NAMEPLATE_FAR_DISTANCE = 30
local NAMEPLATE_FULL_SCALE_DISTANCE = 60
local OBJECTIVE_TITLE_HEIGHT = 25
local OBJECTIVE_BUTTON_HEIGHT = 34
local OBJECTIVE_CASTBAR_GAP = 2
local OBJECTIVE_CASTBAR_HEIGHT = 12
local OBJECTIVE_ROW_HEIGHT = OBJECTIVE_BUTTON_HEIGHT + OBJECTIVE_CASTBAR_GAP +
    OBJECTIVE_CASTBAR_HEIGHT
local OBJECTIVE_GAP = 3
local OBJECTIVE_MAX_ROWS = 8

local function rgba(r, g, b, a)
    return r + g * 256 + b * 65536 + (a or 255) * 16777216
end

local OBJECTIVE_COLORS = {
    background = rgba(13, 18, 25, 232),
    title = rgba(22, 30, 40, 244),
    title_hover = rgba(35, 47, 61, 248),
    border = rgba(177, 148, 75, 240),
    row = rgba(20, 28, 38, 238),
    row_hover = rgba(34, 46, 60, 246),
    selected = rgba(9, 74, 96, 248),
    selected_accent = rgba(103, 225, 255, 255),
    pending = rgba(242, 181, 65, 255),
    friendly = rgba(74, 222, 128, 255),
    hostile = rgba(248, 113, 113, 255),
    text = rgba(232, 239, 245, 255),
    muted = rgba(153, 164, 176, 255),
}

local function color_with_alpha(text, alpha)
    local red, green, blue = tostring(text):match("^#(%x%x)(%x%x)(%x%x)%x%x$")
    if not red then
        error("pvp_sense colors must be #RRGGBBAA")
    end
    return rgba(tonumber(red, 16), tonumber(green, 16),
        tonumber(blue, 16), alpha)
end

local function nameplate_distance_scale(distance)
    if type(distance) ~= "number" then
        return 1
    end
    local progress = (distance - NAMEPLATE_FAR_DISTANCE) /
        (NAMEPLATE_FULL_SCALE_DISTANCE - NAMEPLATE_FAR_DISTANCE)
    progress = math.max(0, math.min(1, progress))
    return 1 + (NAMEPLATE_FAR_SCALE - 1) * progress
end

local Settings = gos.settings.register(SCRIPT_ID, {
    title = "PvP Sense",
    version = 9,
    activation = { mode = "manual" },
    fields = {
        {
            key = "visible", type = "bool", label = "PvP Sense - Enabled",
            tooltip = "Master switch for active player cooldown awareness.",
            default = true,
        },
        {
            key = "objective_window", type = "bool", label = "Objectives - Interaction Window",
            tooltip = "Show a clickable window only while a player is actively capturing or interacting with a PvP objective.",
            default = true,
        },
        {
            key = "objective_show_friendly", type = "bool", label = "Objectives - Friendly Players",
            tooltip = "Include friendly players who are actively interacting with a PvP objective.",
            default = true,
        },
        {
            key = "objective_show_hostile", type = "bool", label = "Objectives - Hostile Players",
            tooltip = "Include hostile players who are actively interacting with a PvP objective.",
            default = true,
        },
        {
            key = "objective_show_timer", type = "bool", label = "Objectives - Remaining Time",
            tooltip = "Show the observed time left centered on each objective cast bar.",
            default = true,
        },
        {
            key = "objective_position_x", type = "int", label = "Objectives - Position X",
            tooltip = "Horizontal screen position of the movable objective interaction window.",
            default = 760, min = 0, max = 7680, step = 1,
        },
        {
            key = "objective_position_y", type = "int", label = "Objectives - Position Y",
            tooltip = "Vertical screen position of the movable objective interaction window.",
            default = 120, min = 0, max = 4320, step = 1,
        },
        {
            key = "objective_window_width", type = "int", label = "Objectives - Window Width",
            tooltip = "Width of the objective interaction window and its clickable player buttons.",
            default = 300, min = 220, max = 520, step = 5,
        },
        {
            key = "test_mode", type = "bool", label = "Preview - Cycle Icons",
            tooltip = "Cycle through the cooldown catalog using the local player as a preview anchor.",
            default = false,
        },
        {
            key = "hostile_window", type = "bool", label = "Hostiles - Roster Window",
            tooltip = "Show hostile players with class, discipline, HP, equipped item rating and distance. Click a name to target.",
            default = true,
        },
        {
            key = "hostile_position_x", type = "int", label = "Hostiles - Position X",
            tooltip = "Horizontal position of the movable hostile roster.",
            default = 1467, min = 0, max = 7680, step = 1,
        },
        {
            key = "hostile_position_y", type = "int", label = "Hostiles - Position Y",
            tooltip = "Vertical position of the movable hostile roster.",
            default = 496, min = 0, max = 4320, step = 1,
        },
        {
            key = "hostile_compact_width", type = "int", label = "Hostiles - Window Width",
            tooltip = "Width of the compact hostile roster.",
            default = 240, min = 180, max = 480, step = 10,
        },
        {
            key = "hostile_window_rows", type = "int", label = "Hostiles - Rows",
            tooltip = "Maximum visible hostile players, sorted nearest first. The roster reads at most 64 prepared players.",
            default = 16, min = 1, max = 32, step = 1,
        },
        {
            key = "test_cycle_ms", type = "int", label = "Preview - Cycle Speed",
            tooltip = "Milliseconds before the preview advances to the next icons.",
            default = 3000, min = 250, max = 5000, step = 50,
        },
        {
            key = "show_player_defensives", type = "bool", label = "Player Cooldowns - Defensives",
            tooltip = "Show known active defensive cooldown buffs beside player nameplates.",
            default = true,
        },
        {
            key = "show_player_offensives", type = "bool", label = "Player Cooldowns - Offensives",
            tooltip = "Show known active offensive cooldown buffs beside player nameplates.",
            default = true,
        },
        {
            key = "show_action_cues", type = "bool", label = "Player Cooldowns - Action Cues",
            tooltip = "Show the highest-priority response for the current hostile target.",
            default = true,
        },
        {
            key = "cue_show_ability_name", type = "bool", label = "Action Cues - Ability Name",
            tooltip = "Include the active ability name after the recommended response.",
            default = true,
        },
        {
            key = "bold_cue_text", type = "bool", label = "Action Cues - Bold Text",
            tooltip = "Use a stronger double-drawn label for action cues.",
            default = true,
        },
        {
            key = "show_cooldown_timers", type = "bool", label = "Player Cooldowns - Timers",
            tooltip = "Show live remaining time over defensive and offensive icons.",
            default = true,
        },
        {
            key = "show_cooldown_stacks", type = "bool", label = "Player Cooldowns - Stack Counts",
            tooltip = "Include live stack counts in cooldown timer text.",
            default = true,
        },
        {
            key = "show_cooldown_borders", type = "bool", label = "Player Cooldowns - Colored Borders",
            tooltip = "Outline defensive and offensive icons with their category color.",
            default = true,
        },
        {
            key = "show_time_sweep", type = "bool", label = "Icon Effects - Time Sweep",
            tooltip = "Drain the color wash over the effect's full duration when Core supplies it.",
            default = true,
        },
        {
            key = "effect_diagnostics", type = "bool", label = "Diagnostics - Effect Observations",
            tooltip = "Log bounded aggregate effect observation status at most once per second.",
            default = false,
        },
        {
            key = "cooldown_side_layout", type = "select", label = "Player Cooldowns - Side Layout",
            tooltip = "Choose which side displays defensive and offensive cooldowns.",
            default = "Defensives Left",
            options = { "Defensives Left", "Defensives Right" },
        },
        {
            key = "cooldown_icon_direction", type = "select", label = "PvP Layout - Icon Direction",
            tooltip = "Lay each defensive and offensive group out horizontally or from top to bottom.",
            default = "Top to Bottom",
            options = { "Horizontal", "Top to Bottom" },
        },
        {
            key = "show_friendly", type = "bool", label = "Targets - Friendly",
            tooltip = "Show cooldown awareness for friendly players.",
            default = true,
        },
        {
            key = "show_hostile", type = "bool", label = "Targets - Hostile",
            tooltip = "Show cooldown awareness for hostile players.",
            default = true,
        },
        {
            key = "show_neutral", type = "bool", label = "Targets - Neutral",
            tooltip = "Show cooldown awareness for neutral players.",
            default = true,
        },
        {
            key = "show_self", type = "bool", label = "Targets - Self",
            tooltip = "Show cooldown awareness for the local player.",
            default = true,
        },
        {
            key = "max_units", type = "int", label = "Limits - Max Players",
            tooltip = "Maximum players scanned per tick after distance sorting.",
            default = 64, min = 1, max = 64, step = 1,
        },
        {
            key = "max_player_icons", type = "int", label = "Limits - Player Icons per Side",
            tooltip = "Maximum active defensive and offensive icons drawn on each side of a player.",
            default = 3, min = 1, max = 6, step = 1,
        },
        {
            key = "max_distance", type = "int", label = "Limits - Max Distance",
            tooltip = "Maximum player distance to scan. Zero means unlimited.",
            default = 80, min = 0, max = 500, step = 5,
        },
        {
            key = "player_icon_size", type = "int", label = "PvP Layout - Icon Size",
            tooltip = "Defensive and offensive icon size in screen pixels.",
            default = 30, min = 18, max = 48, step = 1,
        },
        {
            key = "player_icon_gap", type = "int", label = "PvP Layout - Icon Gap",
            tooltip = "Spacing between defensive or offensive icons.",
            default = 4, min = 0, max = 20, step = 1,
        },
        {
            key = "player_vertical_offset", type = "int", label = "PvP Layout - Y Offset",
            tooltip = "Vertical center offset for the defensive and offensive groups.",
            default = -38, min = -220, max = 80, step = 1,
        },
        {
            key = "player_side_offset", type = "int", label = "PvP Layout - Side Distance",
            tooltip = "Horizontal distance from the player marker to the center of each group.",
            default = 50, min = 24, max = 260, step = 1,
        },
        {
            key = "cooldown_timer_size", type = "int", label = "PvP Layout - Timer Text Size",
            tooltip = "Font size for cooldown timers and stack counts.",
            default = 12, min = 9, max = 22, step = 1,
        },
        {
            key = "cue_font_size", type = "int", label = "PvP Layout - Cue Text Size",
            tooltip = "Font size for current-target action labels.",
            default = 14, min = 10, max = 26, step = 1,
        },
        {
            key = "cue_vertical_gap", type = "int", label = "PvP Layout - Cue Gap",
            tooltip = "Vertical space between action labels and cooldown icons.",
            default = 18, min = 0, max = 60, step = 1,
        },
        {
            key = "cooldown_border_thickness", type = "int", label = "PvP Layout - Border Width",
            tooltip = "Width of defensive and offensive icon borders.",
            default = 2, min = 1, max = 5, step = 1,
        },
        {
            key = "time_sweep_opacity", type = "int", label = "Icon Effects - Sweep Opacity",
            tooltip = "Opacity of the animated defensive/offensive icon wash.",
            default = 84, min = 16, max = 220, step = 4,
        },
        {
            key = "defensive_color", type = "color", label = "PvP Colors - Defensive",
            tooltip = "Color for defensive icon borders and action cues.",
            default = "#3B82F6FF",
        },
        {
            key = "offensive_color", type = "color", label = "PvP Colors - Offensive",
            tooltip = "Color for offensive icon borders and action cues.",
            default = "#EF4444FF",
        },
    },
})

-- Exact, source-backed timed buff names only. Research rows that still need a
-- live alias capture stay out of this allow-list.
local PLAYER_COOLDOWNS = {
    -- Guardian / Juggernaut and Sentinel / Marauder defensives.
    saber_ward = {
        side = "defensive", order = 10, icon = "raw\\redirect.dds",
        icons = {
            juggernaut = "raw\\lightsaberreflection.dds",
            marauder = "raw\\lightsaberreflection.dds",
        },
    },
    enure = { side = "defensive", order = 11, icon = "raw\\drainingpresence.dds" },
    endure_pain = { side = "defensive", order = 11, icon = "raw\\regenerate.dds" },
    focused_defense = { side = "defensive", order = 12, icon = "raw\\coolhead.dds" },
    enraged_defense = { side = "defensive", order = 12, icon = "raw\\identifyweakness.dds" },
    saber_reflect = {
        side = "defensive", order = 13, icon = "raw\\saberreflectjuggernaut.dds",
        icons = { juggernaut = "raw\\saberreflectguardian.dds" },
    },
    warding_call = { side = "defensive", order = 14, icon = "raw\\auraofinvincibility.dds" },
    invincible = { side = "defensive", order = 14, icon = "raw\\cloakofpain.dds" },
    stalwart_defense = { side = "defensive", order = 20, icon = "raw\\spiritarmor.dds" },
    hardened_defense = { side = "defensive", order = 20, icon = "raw\\spiritarmor.dds" },
    rebuke = { side = "defensive", order = 11, icon = "raw\\auraofvalor.dds" },
    cloak_of_pain = { side = "defensive", order = 11, icon = "raw\\cloakofpain.dds" },
    force_camouflage = {
        side = "defensive", order = 12, icon = "raw\\abl_jk_se_force_camouflage.dds",
        icons = { marauder = "raw\\abl_sw_ma_force_camouflage.dds" },
    },
    guarded_by_the_force = { side = "defensive", order = 10, icon = "raw\\absorbtionfield.dds" },
    undying_rage = { side = "defensive", order = 10, icon = "raw\\shadowcloak.dds" },
    transcendence = { side = "defensive", order = 20, icon = "raw\\promulgator.dds" },
    predation = { side = "defensive", order = 20, icon = "raw\\rampage.dds" },
    steel_self = { side = "defensive", order = 21, icon = "raw\\cc_defensive.dds" },

    -- Guardian / Juggernaut and Sentinel / Marauder offensive windows.
    force_clarity = { side = "offensive", order = 10, icon = "raw\\determined_face_6_0.dds" },
    furious_power = { side = "offensive", order = 10, icon = "raw\\raging_face_6_0.dds" },
    focused = { side = "offensive", order = 14, icon = "raw\\gatherstrength.dds" },
    singularity = { side = "offensive", order = 13, icon = "raw\\riflegrenade.dds" },
    precision = { side = "offensive", order = 10, icon = "raw\\twinarcs.dds" },
    ferocity = { side = "offensive", order = 10, icon = "raw\\abl_sw_ma_ferocity.dds" },
    combat_trance = { side = "offensive", order = 11, icon = "raw\\abl_jk_se_combattrance.dds" },
    blood_frenzy = { side = "offensive", order = 11, icon = "raw\\cc_attack.dds" },
    overload_saber = { side = "offensive", order = 12, icon = "raw\\vengefulstrike.dds" },
    deadly_saber = { side = "offensive", order = 12, icon = "raw\\vengefulstrike.dds" },
    zen = { side = "offensive", order = 12, icon = "raw\\jkmiralukansurvivor.dds" },
    berserk = { side = "offensive", order = 12, icon = "raw\\berserk.dds" },
    gravity_vortex = { side = "offensive", order = 20, icon = "raw\\blue_spiral_6_0.dds" },
    inspiration = { side = "offensive", order = 20, icon = "raw\\twilekvisionary.dds" },
    bloodthirst = { side = "offensive", order = 20, icon = "raw\\bloodthirst.dds" },

    -- Sage / Sorcerer defensives and offensive windows.
    force_armor = { side = "defensive", order = 20, icon = "classes\\jedi_consular\\sage\\base\\icons\\force_armor.dds" },
    static_barrier = { side = "defensive", order = 20, icon = "classes\\sith_inquisitor\\sorcerer\\specs\\lightning\\icons\\static_barrier.dds" },
    force_barrier = {
        side = "defensive", order = 10,
        icon = "classes\\jedi_consular\\sage\\base\\icons\\force_barrier.dds",
        icons = { sorcerer = "classes\\sith_inquisitor\\sorcerer\\base\\icons\\force_barrier.dds" },
    },
    -- Force Barrier is the full-immunity channel. Enduring Bastion is its
    -- numbered post-channel absorb state; Force Armor/Static Barrier only absorb.
    enduring_bastion_1 = {
        side = "defensive", order = 11,
        icon = "classes\\jedi_consular\\sage\\base\\icons\\force_barrier.dds",
        icons = { sorcerer = "classes\\sith_inquisitor\\sorcerer\\base\\icons\\force_barrier.dds" },
    },
    enduring_bastion_2 = {
        side = "defensive", order = 11,
        icon = "classes\\jedi_consular\\sage\\base\\icons\\force_barrier.dds",
        icons = { sorcerer = "classes\\sith_inquisitor\\sorcerer\\base\\icons\\force_barrier.dds" },
    },
    enduring_bastion_3 = {
        side = "defensive", order = 11,
        icon = "classes\\jedi_consular\\sage\\base\\icons\\force_barrier.dds",
        icons = { sorcerer = "classes\\sith_inquisitor\\sorcerer\\base\\icons\\force_barrier.dds" },
    },
    enduring_bastion_4 = {
        side = "defensive", order = 11,
        icon = "classes\\jedi_consular\\sage\\base\\icons\\force_barrier.dds",
        icons = { sorcerer = "classes\\sith_inquisitor\\sorcerer\\base\\icons\\force_barrier.dds" },
    },
    blockout = { side = "defensive", order = 12, icon = "classes\\jedi_consular\\sage\\utility\\icons\\blockout.dds" },
    suppression = { side = "defensive", order = 12, icon = "classes\\sith_inquisitor\\sorcerer\\utility\\icons\\suppression.dds" },
    valorous_spirit = { side = "defensive", order = 13, icon = "classes\\jedi_consular\\sage\\utility\\icons\\valorous_spirit.dds" },
    unnatural_vigor = { side = "defensive", order = 13, icon = "classes\\sith_inquisitor\\sorcerer\\utility\\icons\\unnatural_vigor.dds" },
    mental_alacrity = { side = "offensive", order = 10, icon = "classes\\jedi_consular\\sage\\base\\icons\\mental_alacrity.dds" },
    polarity_shift = { side = "offensive", order = 10, icon = "classes\\sith_inquisitor\\sorcerer\\base\\icons\\polarity_shift.dds" },
    force_empowerment = { side = "offensive", order = 20, icon = "raw\\uti_imp_rep_power_raid_buff.dds" },
    unlimited_power = { side = "offensive", order = 20, icon = "raw\\uti_imp_rep_power_raid_buff.dds" },

    -- Shadow / Assassin defensives and offensive windows.
    deflection = {
        side = "defensive", order = 11,
        icon = "classes\\jedi_consular\\shadow\\base\\icons\\deflection.dds",
        icons = { assassin = "classes\\sith_inquisitor\\assassin\\base\\icons\\deflection.dds" },
    },
    resilience = { side = "defensive", order = 10, icon = "classes\\jedi_consular\\shadow\\specs\\combat\\icons\\resilience.dds" },
    force_shroud = { side = "defensive", order = 10, icon = "classes\\sith_inquisitor\\assassin\\specs\\hatred\\mods\\icons\\force_shroud.dds" },
    kinetic_ward = { side = "defensive", order = 21, icon = "classes\\jedi_consular\\shadow\\specs\\combat\\icons\\kinetic_ward.dds" },
    dark_ward = { side = "defensive", order = 21, icon = "classes\\sith_inquisitor\\assassin\\specs\\darkness\\icons\\dark_ward.dds" },
    shadowsight = { side = "defensive", order = 12, icon = "classes\\jedi_consular\\shadow\\specs\\combat\\icons\\shadowsight.dds" },
    mounting_darkness = { side = "defensive", order = 12, icon = "classes\\sith_inquisitor\\assassin\\specs\\darkness\\icons\\mounting_darkness.dds" },
    battle_readiness = { side = "offensive", order = 11, icon = "classes\\jedi_consular\\shadow\\specs\\serenity\\mods\\icons\\battle_readiness.dds" },
    overcharge_saber = { side = "offensive", order = 11, icon = "classes\\sith_inquisitor\\assassin\\specs\\hatred\\mods\\icons\\overcharge_saber.dds" },
    force_potency = {
        side = "offensive", order = 10,
        icon = "classes\\jedi_consular\\sage\\base\\icons\\force_potency.dds",
        icons = { shadow = "classes\\jedi_consular\\shadow\\specs\\combat\\icons\\force_potency.dds" },
    },
    recklessness = {
        side = "offensive", order = 10,
        icon = "classes\\sith_inquisitor\\sorcerer\\base\\icons\\recklessness.dds",
        icons = { assassin = "classes\\sith_inquisitor\\assassin\\specs\\darkness\\icons\\recklessness.dds" },
    },

    -- Scoundrel / Operative defensives and offensive windows.
    evasion = { side = "defensive", order = 10, icon = "raw\\evasion.dds" },
    dodge = { side = "defensive", order = 10, icon = "raw\\evasion.dds" },
    shield_probe = { side = "defensive", order = 20, icon = "raw\\shieldprobe.dds" },
    defense_screen = { side = "defensive", order = 20, icon = "raw\\shieldprobe.dds" },
    revitalizers = { side = "defensive", order = 12, icon = "raw\\reanimation.dds" },
    defensive_stance = {
        side = "defensive", order = 21, icon = "raw\\upgrade_buff.dds",
        icons = { marauder = "raw\\upgrade_damagedirect_weapon.dds" },
    },
    stim_boost = { side = "offensive", order = 10, icon = "raw\\stimulants.dds" },
    pugnacity = { side = "offensive", order = 10, icon = "raw\\combattechnique.dds" },
    tactical_overdrive = { side = "offensive", order = 11, icon = "raw\\unstable_stimpack_6_0.dds" },
    hot_streak = { side = "offensive", order = 11, icon = "raw\\spinning_blaster_6_0.dds" },
    tactical_superiority = { side = "offensive", order = 20, icon = "raw\\uti_imp_rep_crit_chance_raid_buff.dds" },
    stack_the_deck = { side = "offensive", order = 20, icon = "raw\\uti_imp_rep_crit_chance_raid_buff.dds" },
    tactical_critical = { side = "offensive", order = 21, icon = "raw\\agesmu_taccrit_7_0_imp.dds" },
    upper_critical = { side = "offensive", order = 21, icon = "raw\\agesmu_taccrit_7_0_rep.dds" },
    stim_burst = { side = "offensive", order = 20, icon = "raw\\agesmu_stim_burst_7_0_imp.dds" },

    -- Gunslinger / Sniper defensives and offensive windows.
    entrench = { side = "defensive", order = 10, icon = "raw\\entrench.dds" },
    hunker_down = { side = "defensive", order = 10, icon = "raw\\entrench.dds" },
    ballistic_shield = { side = "defensive", order = 11, icon = "raw\\ballisticshield.dds" },
    scrambling_field = { side = "defensive", order = 11, icon = "raw\\ballisticshield.dds" },
    ballistic_dampers = { side = "defensive", order = 21, icon = "raw\\durablearmors.dds" },
    target_acquired = { side = "offensive", order = 10, icon = "raw\\assassinate.dds" },
    illegal_mods = { side = "offensive", order = 10, icon = "raw\\assaultcannongrenadeattatchment.dds" },
    sniper_volley = { side = "offensive", order = 11, icon = "raw\\abl_ag_sn_snipervolley.dds" },
    burst_volley = { side = "offensive", order = 11, icon = "raw\\abl_sm_gu_burstvolley.dds" },
    systems_upgrade = { side = "offensive", order = 11, icon = "raw\\black_panel_buttons_6_0.dds" },
    integrated_toxins = { side = "offensive", order = 11, icon = "raw\\tech_bracer_2_6_0.dds" },

    -- Commando / Mercenary defensives and offensive windows.
    reactive_shield = { side = "defensive", order = 11, icon = "raw\\carbonitereinforcedshield.dds" },
    energy_shield = { side = "defensive", order = 11, icon = "raw\\energyshield.dds" },
    fired_up = { side = "defensive", order = 12, icon = "raw\\trenchhealer.dds" },
    health_monitor = { side = "defensive", order = 12, icon = "raw\\trenchhealer.dds" },
    adrenaline_rush = { side = "defensive", order = 12, icon = "raw\\adrenelinerush.dds" },
    kolto_overload = { side = "defensive", order = 12, icon = "raw\\adrenelinerush.dds" },
    echoing_deterrence = { side = "defensive", order = 10, icon = "raw\\abl_tr_echoing_deterrence.dds" },
    responsive_safeguards = { side = "defensive", order = 10, icon = "raw\\abl_bh_responsive_obviation.dds" },
    hold_the_line = { side = "defensive", order = 20, icon = "raw\\trepublicelite.dds" },
    hydraulic_overrides = { side = "defensive", order = 20, icon = "raw\\deflection.dds" },
    smoke_screen = { side = "defensive", order = 20, icon = "raw\\merc_comm_uti_smoke_screen.dds" },
    high_velocity_supercharged_cell = { side = "offensive", order = 11, icon = "raw\\mercom_sg_arsenal_rep.dds" },
    high_velocity_supercharged_gas = { side = "offensive", order = 11, icon = "raw\\mercom_sg_arsenal_imp.dds" },
    supercharged_cell = { side = "offensive", order = 11, icon = "raw\\mercom_sg_io_rep.dds" },
    supercharged_gas = { side = "offensive", order = 11, icon = "raw\\mercom_sg_io_imp.dds" },
    supercharged_kolto_cell = { side = "offensive", order = 11, icon = "raw\\bodyguardhealproc.dds" },
    supercharged_kolto_gas = { side = "offensive", order = 11, icon = "raw\\bodyguardhealproc.dds" },
    supercharged_celerity = { side = "offensive", order = 20, icon = "raw\\uti_imp_rep_alacrity_raid_buff.dds" },
    tech_override = { side = "offensive", order = 20, icon = "raw\\complexaccesscard.dds" },
    power_surge = { side = "offensive", order = 20, icon = "raw\\vanguard.dds" },

    -- Vanguard / Powertech defensives and offensive/hybrid windows.
    infused_kolto_packs = { side = "defensive", order = 12, icon = "raw\\energy_yield_rep.dds" },
    energy_yield = { side = "defensive", order = 12, icon = "raw\\energy_yield_imp.dds" },
    sonic_defense = { side = "defensive", order = 13, icon = "raw\\assaulttech.dds" },
    battle_focus = { side = "offensive", order = 10, icon = "raw\\aimboost.dds" },
    explosive_fuel = { side = "offensive", order = 10, icon = "raw\\explosivefuel.dds" },
    shoulder_cannon = { side = "offensive", order = 20, icon = "raw\\powerloaders.dds" },
    balmorran_advanced_weaponry = { side = "offensive", order = 11, icon = "raw\\armament2.dds" },
    power_yield = { side = "offensive", order = 11, icon = "raw\\orange_energy_6_0.dds" },
    durasteel_armor = { side = "offensive", order = 11, icon = "raw\\durablearmors.dds" },
    thermal_yield = { side = "offensive", order = 11, icon = "raw\\thermal_yield_imp.dds" },
}

-- Action advice is explicit. An icon without a proven response remains an
-- awareness icon instead of inheriting a generic and potentially wrong cue.
local PLAYER_CUES = {
    guarded_by_the_force = "STOP / SWAP",
    undying_rage = "STOP / SWAP",
    force_barrier = "STOP / SWAP",
    saber_reflect = "STOP CASTS",
    echoing_deterrence = "STOP ATTACKING",
    responsive_safeguards = "STOP ATTACKING",
    resilience = "HOLD FORCE / TECH",
    force_shroud = "HOLD FORCE / TECH",
    force_camouflage = "REACQUIRE",
    rebuke = "DISENGAGE",
    cloak_of_pain = "DISENGAGE",
    hold_the_line = "DO NOT ROOT",
    hydraulic_overrides = "DO NOT ROOT",
    transcendence = "DO NOT ROOT",
    predation = "DO NOT ROOT",
    entrench = "DO NOT CC",
    hunker_down = "DO NOT CC",
    precision = "KITE",
    ferocity = "KITE",
    force_clarity = "KITE",
    furious_power = "KITE",
    overload_saber = "KITE",
    deadly_saber = "KITE",
    combat_trance = "DO NOT CC",
    blood_frenzy = "DO NOT CC",
    gravity_vortex = "DO NOT CC",
    mental_alacrity = "LOS / DEFEND",
    polarity_shift = "LOS / DEFEND",
    tech_override = "LOS",
    power_surge = "LOS",
    inspiration = "TEAM BURST",
    bloodthirst = "TEAM BURST",
    force_empowerment = "TEAM BURST",
    unlimited_power = "TEAM BURST",
    tactical_superiority = "TEAM BURST",
    stack_the_deck = "TEAM BURST",
    supercharged_celerity = "TEAM BURST",
}

local TEST_COOLDOWNS = { defensive = {}, offensive = {} }
for key, known in pairs(PLAYER_COOLDOWNS) do
    local name = key:gsub("_", " "):gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end)
    local out = TEST_COOLDOWNS[known.side]
    out[#out + 1] = {
        name = name,
        icon = known.icon,
        order = known.order,
        side = known.side,
        cue = PLAYER_CUES[key] or "PREVIEW",
    }
end
for _, entries in pairs(TEST_COOLDOWNS) do
    table.sort(entries, function(left, right)
        return left.name < right.name
    end)
end

local function effect_key(name)
    return tostring(name or ""):lower():gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
end

local function timer_text(remaining)
    if type(remaining) ~= "number" then
        return ""
    end
    remaining = math.max(0, remaining)
    if remaining < 10 then
        return string.format("%.1f", remaining)
    end
    return string.format("%.0f", remaining)
end

local function effect_text(effect, show_stacks)
    local timer = timer_text(effect.remaining)
    if show_stacks ~= false and type(effect.stacks) == "number" and effect.stacks > 1 then
        return tostring(effect.stacks) .. "x " .. timer
    end
    return timer
end

local function cooldown_order(left, right)
    if left.order ~= right.order then
        return left.order < right.order
    end
    if left.remaining ~= right.remaining then
        return left.remaining < right.remaining
    end
    return tostring(left.catalog_key or left.name or "") <
        tostring(right.catalog_key or right.name or "")
end

local function cooldown_layout(side)
    local defensives_left = Settings.cooldown_side_layout ~= "Defensives Right"
    if side == "defensive" then
        return defensives_left and "left" or "right"
    end
    return defensives_left and "right" or "left"
end

local function visible_reaction(unit)
    local reaction = unit:reaction()
    if reaction == "friendly" then
        return Settings.show_friendly
    elseif reaction == "hostile" then
        return Settings.show_hostile
    elseif reaction == "neutral" then
        return Settings.show_neutral
    end
    return false
end

local function usable_unit(unit)
    if not unit or unit:type() ~= "player" then
        return false
    end
    if not unit:is_on_screen() then
        return false
    end
    if Settings.test_mode and not unit:is_local_player() then
        return false
    end
    if unit:is_local_player() then
        if Settings.test_mode then
            return true
        elseif not Settings.show_self then
            return false
        end
    end
    if not visible_reaction(unit) and not unit:is_current_target() then
        return false
    end
    local distance = unit:distance()
    if Settings.max_distance > 0 and type(distance) == "number" and distance > Settings.max_distance then
        return false
    end
    return true
end

local function collect_units(world)
    local out = {}
    for _, unit in ipairs(world:units()) do
        if usable_unit(unit) then
            local distance = unit:distance()
            out[#out + 1] = {
                unit = unit,
                target = unit:is_current_target(),
                distance = type(distance) == "number" and distance or 999999,
                nameplate_scale = nameplate_distance_scale(distance),
                handle = tostring(unit:handle() or ""),
            }
        end
    end
    -- Precompute every sort key once. The handle tie-breaker keeps output
    -- deterministic when several players share a distance.
    table.sort(out, function(left, right)
        if left.target ~= right.target then
            return left.target
        end
        if left.distance ~= right.distance then
            return left.distance < right.distance
        end
        return left.handle < right.handle
    end)
    return out
end

local function collect_player_cooldowns(unit)
    if unit:type() ~= "player" then
        return {}, {}, nil
    end
    local observed = unit:effects({ kind = "buff", timed = true })
    local defensives = {}
    local offensives = {}
    local selected = {}
    local style = type(unit.combat_style) == "function" and unit:combat_style() or nil

    local function consider(effect, last_known)
        local key = effect_key(effect.name)
        local known = PLAYER_COOLDOWNS[key]
        if not known or selected[key] or not effect.has_timer or
            type(effect.remaining) ~= "number" or effect.remaining <= 0 then
            return
        end
        local icon = known.icon
        if known.icons and type(style) == "string" then
            icon = known.icons[style] or icon
        end
        selected[key] = {
            name = effect.name,
            remaining = effect.remaining,
            duration = effect.has_duration and effect.duration or nil,
            stacks = effect.stacks,
            icon = icon,
            order = known.order,
            side = known.side,
            cue = PLAYER_CUES[key],
            catalog_key = key,
            last_known = last_known == true,
        }
    end

    -- Strict fresh rows always win. If an incomplete fresh row cannot satisfy
    -- the timed catalog contract, an explicitly last-known row may still
    -- supply presentation continuity without becoming gameplay evidence.
    if observed.status == "ready" then
        for _, effect in ipairs(observed.items or {}) do
            consider(effect, false)
        end
    end
    for _, effect in ipairs(observed.last_known_items or {}) do
        consider(effect, true)
    end

    for _, effect in pairs(selected) do
        local out = effect.side == "defensive" and defensives or offensives
        out[#out + 1] = effect
    end
    table.sort(defensives, cooldown_order)
    table.sort(offensives, cooldown_order)
    return defensives, offensives, observed
end

local function collect_test_player_cooldowns(unit_index)
    local now = gos.time_ms() or 0
    local bucket = math.floor(now / Settings.test_cycle_ms)
    local remaining_ms = Settings.test_cycle_ms - (now % Settings.test_cycle_ms)
    local remaining = remaining_ms / 1000
    local function collect(side)
        local source = TEST_COOLDOWNS[side]
        local out = {}
        local count = math.min(Settings.max_player_icons, #source)
        for index = 1, count do
            local pick = ((bucket + unit_index + index - 2) % #source) + 1
            local sample = source[pick]
            out[#out + 1] = {
                name = sample.name,
                remaining = remaining,
                duration = Settings.test_cycle_ms / 1000,
                icon = sample.icon,
                order = sample.order,
                side = sample.side,
                cue = sample.cue,
            }
        end
        return out
    end
    return collect("defensive"), collect("offensive")
end

local function emit_overlay(draw_budget, callback)
    if draw_budget.used >= MAX_DRAW_COMMANDS then
        draw_budget.clipped = draw_budget.clipped + 1
        return false, false
    end
    local emitted = callback() == true
    if emitted then
        draw_budget.used = draw_budget.used + 1
        draw_budget.emitted = draw_budget.emitted + 1
    else
        draw_budget.rejected = draw_budget.rejected + 1
    end
    return true, emitted
end

local function category_enabled(category)
    return category == "defensive" and Settings.show_player_defensives or
        category == "offensive" and Settings.show_player_offensives
end

local function category_color(category)
    return category == "defensive" and Settings.defensive_color or
        Settings.offensive_color
end

local function dimmed_category_color(category, effect, alpha)
    if not effect.last_known then
        return color_with_alpha(category_color(category), alpha)
    end
    return color_with_alpha(category_color(category),
        math.floor((alpha or 255) * 0.55))
end

local function scaled_side_offset(scale)
    local icon_half = Settings.player_icon_size * 0.5
    return icon_half + (Settings.player_side_offset - icon_half) *
        (scale or 1)
end

local function effect_position(effects, index, max_icons, layout,
        vertical_offset, scale)
    local size = Settings.player_icon_size
    local gap = Settings.player_icon_gap
    local count = math.min(#effects, max_icons)
    local step = size + gap
    local step_x = layout == "left" and -step or step
    local step_y = 0
    local side_offset = scaled_side_offset(scale)
    local start_x = layout == "left" and -side_offset or side_offset
    local start_y = vertical_offset
    if Settings.cooldown_icon_direction == "Top to Bottom" then
        step_x = 0
        step_y = step
        start_y = start_y - (count - 1) * step * 0.5
    else
        start_x = start_x - (count - 1) * step_x * 0.5
    end
    return start_x + (index - 1) * step_x,
        start_y + (index - 1) * step_y
end

local function draw_effect_image(unit, effect, draw_budget, id, x, y)
    local path = effect.icon and (ICON_ROOT .. effect.icon) or nil
    if not path then
        draw_budget.rejected = draw_budget.rejected + 1
        return true, false
    end
    return emit_overlay(draw_budget, function()
        return gos.overlay.draw_image(id .. ":i", {
            at = { unit = unit, anchor = "top",
                pixel_offset = { x = x, y = y } }, path = path,
            width = Settings.player_icon_size, height = Settings.player_icon_size,
            tint = effect.last_known and { 255, 255, 255, 140 } or "white",
            center_x = true, ttl = TTL, frame = true,
        })
    end)
end

local function draw_effect_decorations(unit, effect, draw_budget, id, x, y,
        category)
    local size = Settings.player_icon_size
    local color = category_color(category)

    -- Timer information is more important than cosmetic borders/sweeps and is
    -- allocated first. Background and text remain an atomic budget decision.
    if Settings.show_cooldown_timers then
        if draw_budget.used + 2 > MAX_DRAW_COMMANDS then
            draw_budget.degraded = draw_budget.degraded + 2
            return false
        end
        local timer_height = math.max(11, Settings.cooldown_timer_size + 2)
        local timer_y = y + size - timer_height
        local ok = emit_overlay(draw_budget, function()
            return gos.overlay.draw_rect(id .. ":b", {
                at = { unit = unit, anchor = "top", pixel_offset = {
                    x = x - size * 0.5, y = timer_y } },
                width = size, height = timer_height,
                color = effect.last_known and { 0, 0, 0, 135 } or
                    { 0, 0, 0, 195 },
                filled = true, ttl = TTL, frame = true,
            })
        end)
        if not ok then
            return false
        end
        ok = emit_overlay(draw_budget, function()
            return gos.overlay.draw_text(id .. ":t", {
                at = { unit = unit, anchor = "top", pixel_offset = {
                    x = x, y = timer_y + timer_height * 0.5 } },
                text = effect_text(effect, Settings.show_cooldown_stacks),
                color = effect.last_known and { 180, 180, 180, 210 } or
                    "white",
                font_size = Settings.cooldown_timer_size,
                shadow = true, center_x = true, center_y = true, ttl = TTL,
                frame = true,
            })
        end)
        if not ok then
            return false
        end
    end

    if Settings.show_cooldown_borders then
        local ok = emit_overlay(draw_budget, function()
            return gos.overlay.draw_rect(id .. ":o", {
                at = { unit = unit, anchor = "top", pixel_offset = {
                    x = x - size * 0.5, y = y } },
                width = size, height = size,
                color = effect.last_known and
                    dimmed_category_color(category, effect, 180) or color,
                filled = false, thickness = Settings.cooldown_border_thickness,
                ttl = TTL, frame = true,
            })
        end)
        if not ok then
            draw_budget.degraded = draw_budget.degraded + 1
            return false
        end
    end

    if Settings.show_time_sweep and type(effect.duration) == "number" and effect.duration > 0 then
        local ok = emit_overlay(draw_budget, function()
            local phase = math.max(0, math.min(1, effect.remaining / effect.duration))
            local sweep_height = math.ceil(size * phase)
            return gos.overlay.draw_rect(id .. ":s", {
                at = { unit = unit, anchor = "top", pixel_offset = {
                    x = x - size * 0.5, y = y + size - sweep_height } },
                width = size, height = sweep_height,
                color = dimmed_category_color(category, effect,
                    Settings.time_sweep_opacity),
                filled = true, ttl = TTL, frame = true,
            })
        end)
        if not ok then
            draw_budget.degraded = draw_budget.degraded + 1
            return false
        end
    end
    return true
end

local function draw_image_slot(record, category, index, draw_budget)
    if not category_enabled(category) then
        return true
    end
    local effects = record[category]
    local effect = effects[index]
    if not effect or record.drawn[category][index] then
        return true
    end
    local x, y = effect_position(effects, index, Settings.max_player_icons,
        cooldown_layout(category), Settings.player_vertical_offset,
        record.nameplate_scale)
    local id_prefix = category == "defensive" and "pvp:d" or "pvp:o"
    local continue, emitted = draw_effect_image(record.unit, effect, draw_budget,
        id_prefix .. ":" .. index, x, y)
    if emitted then
        record.drawn[category][index] = true
    end
    return continue
end

local function first_image_slot(record)
    local defensive = Settings.show_player_defensives and record.defensive[1] or nil
    local offensive = Settings.show_player_offensives and record.offensive[1] or nil
    if defensive and offensive then
        if offensive.order < defensive.order then
            return "offensive", 1
        end
        return "defensive", 1
    elseif defensive then
        return "defensive", 1
    elseif offensive then
        return "offensive", 1
    end
    return nil, nil
end

local function draw_images(records, limit, draw_budget)
    -- First pass: at most one mandatory image per affected player.
    for record_index = 1, limit do
        local record = records[record_index]
        local category, index = first_image_slot(record)
        if category and not draw_image_slot(record, category, index,
                draw_budget) then
            return false
        end
    end
    -- Later passes allocate every remaining configured icon fairly by rank.
    for index = 1, Settings.max_player_icons do
        for record_index = 1, limit do
            local record = records[record_index]
            for _, category in ipairs(DRAW_CATEGORIES) do
                if not draw_image_slot(record, category, index,
                        draw_budget) then
                    return false
                end
            end
        end
    end
    return true
end

local function draw_decorations(records, limit, draw_budget)
    for index = 1, Settings.max_player_icons do
        for record_index = 1, limit do
            local record = records[record_index]
            for _, category in ipairs(DRAW_CATEGORIES) do
                local effects = record[category]
                local effect = category_enabled(category) and effects[index] or nil
                if effect and record.drawn[category][index] then
                    local x, y = effect_position(effects, index,
                        Settings.max_player_icons, cooldown_layout(category),
                        Settings.player_vertical_offset,
                        record.nameplate_scale)
                    local id_prefix = category == "defensive" and
                        "pvp:d" or "pvp:o"
                    if not draw_effect_decorations(record.unit, effect,
                            draw_budget, id_prefix .. ":" .. index, x, y,
                            category) then
                        return false
                    end
                end
            end
        end
    end
    return true
end

local function draw_action_cue(unit, effect, draw_budget, id, layout, icon_count,
        scale)
    if not effect or effect.last_known == true or
        type(effect.cue) ~= "string" or effect.cue == "" then
        return true
    end
    local side_offset = scaled_side_offset(scale)
    local x = layout == "left" and -side_offset or side_offset
    local y = Settings.player_vertical_offset - Settings.cue_vertical_gap
    if Settings.cooldown_icon_direction == "Top to Bottom" then
        y = y - (math.max(1, icon_count) - 1) *
            (Settings.player_icon_size + Settings.player_icon_gap) * 0.5
    end
    local text = effect.cue
    if Settings.cue_show_ability_name then
        text = text .. " - " .. tostring(effect.name or "")
    end
    local color = effect.side == "defensive" and Settings.defensive_color or
        Settings.offensive_color
    local function draw(suffix, offset_x)
        return emit_overlay(draw_budget, function()
            return gos.overlay.draw_text(id .. suffix, {
                at = { unit = unit, anchor = "top",
                    pixel_offset = { x = x + offset_x, y = y } },
                text = text, color = color, font_size = Settings.cue_font_size,
                shadow = true, center_x = true, center_y = true, ttl = TTL,
                frame = true,
            })
        end)
    end
    if not draw(":a", 0) then
        return false
    end
    if Settings.bold_cue_text and not draw(":b", 1) then
        return false
    end
    return true
end

-- Reviewed ability/placeable families and source identities:
-- docs/PVP_OBJECTIVE_ABILITY_FAMILIES_20261001.md. Each alias below is an exact
-- localized title or Core PrettyAbilityName output for an installed prototype.
-- Public casts expose opaque ability handles, not raw definition IDs; never
-- compare them to archive IDs or infer identity from a partial name.
-- ponytail: exact-name catalog; definition-keyed matching needs a public resolver.
local OBJECTIVE_CAST_NAMES = {
    -- Seline / Ancient Hypergate and Yavin. The shared localized capture title
    -- covers both 6s capture and 8s extraction, so its total stays unknown.
    ["capturing the objective"] = { label = "CAPTURE" },
    ["use objective"] = { label = "CAPTURE", duration = 6 },
    ["use objective purple"] = { label = "CAPTURE", duration = 6 },
    ["use extraction"] = { label = "CAPTURE", duration = 8 },
    ["gathering orbs"] = { label = "ORB", duration = 5 },
    ["gather energy"] = { label = "ORB", duration = 5 },
    ["picking up the artifact"] = { label = "PICKUP", duration = 6 },
    ["use vip"] = { label = "PICKUP", duration = 6 },

    -- Alderaan (also used by its Yavin reskin).
    ["controlling the turret"] = { label = "CAPTURE", duration = 8 },

    -- Modern Voidstar. Do not borrow the legacy ship's 3s plant duration.
    ["planting the bomb"] = { label = "PLANT", duration = 6 },
    ["plant bomb"] = { label = "PLANT", duration = 6 },
    ["defusing the bomb"] = { label = "DISARM", duration = 3 },
    ["defuse bomb"] = { label = "DISARM", duration = 3 },
    ["extending the bridge"] = { label = "INTERACT", duration = 6 },
    ["bridge console"] = { label = "INTERACT", duration = 6 },
    ["deactivating the forcefield"] = { label = "INTERACT", duration = 6 },
    ["forcefield console"] = { label = "INTERACT", duration = 6 },
    ["downloading the data core"] = { label = "INTERACT", duration = 0.5 },
    ["data core"] = { label = "INTERACT", duration = 0.5 },
    ["interacting"] = { label = "INTERACT", duration = 3 },
    ["interact"] = { label = "INTERACT", duration = 3 },

    -- Separate legacy ship definitions retained, including unsplit leaf names.
    ["disarming explosives"] = { label = "DISARM", duration = 3 },
    ["defusebomb"] = { label = "DISARM", duration = 3 },
    ["placing explosives"] = { label = "PLANT", duration = 3 },
    ["plantbomb"] = { label = "PLANT", duration = 3 },
    ["slicing terminal"] = { label = "INTERACT", duration = 1.5 },
    ["bridgecontrols"] = { label = "INTERACT", duration = 1.5 },
    ["bridgedoor"] = { label = "INTERACT", duration = 1.5 },
    ["retrieving datacore"] = { label = "INTERACT", duration = 5 },
    ["datacore"] = { label = "INTERACT", duration = 5 },
    ["overriding security terminal"] = { label = "INTERACT", duration = 5 },
    -- Shared leaf: Alderaan capture (8s) or legacy security terminal (5s).
    ["turretswitch"] = { label = "INTERACT" },

    -- Novare Coast: 18s channel, not its 2s warm-up or retained capture buff.
    ["accessing the emplacement"] = { label = "CAPTURE", duration = 18 },
    ["generator1"] = { label = "CAPTURE", duration = 18 },
    ["generator2"] = { label = "CAPTURE", duration = 18 },
    ["generator3"] = { label = "CAPTURE", duration = 18 },

    -- Huttball pickup is instant; only display it if Core supplies an active row.
    ["grabbing the ball"] = { label = "PICKUP" },
    ["ballstand"] = { label = "PICKUP" },

    -- Ilum objective interactions; weapon attacks/explosions are not interactions.
    ["capture landing zone"] = { label = "CAPTURE", duration = 4 },
    ["take landing area"] = { label = "CAPTURE", duration = 4 },
    ["repairing the turret"] = { label = "INTERACT", duration = 10 },
    ["repair imp turret"] = { label = "INTERACT", duration = 10 },
    ["repair rep turret"] = { label = "INTERACT", duration = 10 },
    ["opening supply crate"] = { label = "INTERACT", duration = 5 },
    ["supply crate use"] = { label = "INTERACT", duration = 5 },
    ["mount particle cannon"] = { label = "INTERACT", duration = 0.5 },
    ["mount turret"] = { label = "INTERACT", duration = 0.5 },
    ["mount turret imp"] = { label = "INTERACT", duration = 0.5 },
    ["mount turret rep"] = { label = "INTERACT", duration = 0.5 },

    -- Previously observed generic title has multiple unrelated definitions.
    ["accessing"] = { label = "INTERACT" },
}

local window_drags = {}
local objective_pending_handle
local objective_pending_request
local objective_pending_until = 0
local objective_pending_queued = false
local objective_pending_busy = false
local objective_pending_session
local objective_pending_source

local function objective_clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function objective_fit_bytes(text, maximum)
    text = tostring(text or "")
    if #text <= maximum then
        return text
    end
    -- Same UTF-8 boundary rule as Seer's action window; never split a name.
    local cut = utf8.offset(text, 0, math.max(1, maximum))
    return string.sub(text, 1, cut - 1) .. "~"
end

local function objective_key(name)
    return tostring(name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function objective_cast_info(cast)
    return OBJECTIVE_CAST_NAMES[objective_key(cast.name)]
end

local function objective_clear_pending(source)
    if source and objective_pending_source ~= source then return end
    if objective_pending_request then gos.target.cancel(objective_pending_request) end
    objective_pending_handle = nil
    objective_pending_request = nil
    objective_pending_until = 0
    objective_pending_queued = false
    objective_pending_busy = false
    objective_pending_session = nil
    objective_pending_source = nil
end

local function objective_visible_reaction(unit)
    local reaction = unit:reaction()
    if reaction == "friendly" then
        return Settings.objective_show_friendly
    elseif reaction == "hostile" then
        return Settings.objective_show_hostile
    end
    return false
end

local function collect_objective_casts(world)
    local out = {}
    local seen = {}
    local casts = gos.events.casts()
    local diagnostics = {
        raw = #casts, casts = 0, matched = 0, unknown = {},
        unresolved = 0, filtered = 0, activeUnknowns = {}, omitted = 0,
    }
    for _, cast in ipairs(casts) do
        if cast.active ~= true then
            diagnostics.filtered = diagnostics.filtered + 1
        else
            diagnostics.casts = diagnostics.casts + 1
            local key = objective_key(cast.name)
            local known = objective_cast_info(cast)
            local handle = cast.unit_handle
            if not known then
                key = key ~= "" and key or "-"
                diagnostics.unknown[key] = (diagnostics.unknown[key] or 0) + 1
                if #diagnostics.activeUnknowns < 8 then
                    local remaining = cast.has_timing and
                        type(cast.remaining) == "number" and
                        string.format("%.2f", math.max(0, cast.remaining)) or "-"
                    diagnostics.activeUnknowns[#diagnostics.activeUnknowns + 1] =
                        "name=" .. key .. "|unit=" .. tostring(handle or "-") ..
                        "|remaining=" .. remaining
                else
                    diagnostics.omitted = diagnostics.omitted + 1
                end
            elseif type(handle) ~= "string" or handle == "" or seen[handle] then
                diagnostics.filtered = diagnostics.filtered + 1
            else
                local unit = world:resolve(handle)
                if not unit then
                    diagnostics.unresolved = diagnostics.unresolved + 1
                elseif unit:type() == "player" and objective_visible_reaction(unit) then
                    local remaining = cast.has_timing and cast.remaining or nil
                    out[#out + 1] = {
                        unit = unit,
                        handle = handle,
                        name = unit:name() or "Unknown player",
                        reaction = unit:reaction(),
                        action = known.label,
                        cast_name = cast.name,
                        duration = known.duration,
                        remaining = type(remaining) == "number" and
                            math.max(0, remaining) or nil,
                    }
                    seen[handle] = true
                    diagnostics.matched = diagnostics.matched + 1
                else
                    diagnostics.filtered = diagnostics.filtered + 1
                end
            end
        end
    end
    table.sort(out, function(left, right)
        if left.reaction ~= right.reaction then
            return left.reaction == "hostile"
        end
        local left_remaining = left.remaining or math.huge
        local right_remaining = right.remaining or math.huge
        if left_remaining ~= right_remaining then
            return left_remaining < right_remaining
        end
        local left_name = string.lower(left.name)
        local right_name = string.lower(right.name)
        if left_name ~= right_name then
            return left_name < right_name
        end
        return left.handle < right.handle
    end)
    return out, diagnostics
end

local function persist_window_position(source, x, y)
    local px = math.max(0, math.floor(x + 0.5))
    local py = math.max(0, math.floor(y + 0.5))
    local ok_x, error_x = gos.settings.set(SCRIPT_ID, source .. "_position_x", px)
    local ok_y, error_y = gos.settings.set(SCRIPT_ID, source .. "_position_y", py)
    if not ok_x or not ok_y then
        gos.log.warn(TAG .. source .. " position save failed: " ..
            tostring(error_x or error_y))
    end
end

local function update_window_drag(source, x, y, width, height, viewport)
    local state = gos.overlay.interact("pvp:" .. source .. ":move", {
        x = x, y = y, width = source == "hostile" and 34 or width,
        height = OBJECTIVE_TITLE_HEIGHT, ttl = TTL,
    })
    if state.pressed then
        window_drags[source] = {
            dx = state.mouse_x - x, dy = state.mouse_y - y, x = x, y = y,
        }
    end
    local drag = window_drags[source]
    if drag and (state.down or state.released) then
        drag.x = state.mouse_x - drag.dx
        drag.y = state.mouse_y - drag.dy
        if viewport.available then
            drag.x = objective_clamp(drag.x, 0,
                math.max(0, viewport.width - width))
            drag.y = objective_clamp(drag.y, 0,
                math.max(0, viewport.height - height))
        end
    end
    if drag and state.released then
        x, y = drag.x, drag.y
        persist_window_position(source, x, y)
        window_drags[source] = nil
    elseif drag then
        x, y = drag.x, drag.y
    end
    return x, y, state.hovered
end

local function objective_has_entry(entries, handle)
    for _, entry in ipairs(entries) do if entry.handle == handle then return true end end
    return false
end

local function service_objective_selection(world, now, entries, source)
    source = source or "objective"
    if not objective_pending_handle or objective_pending_source ~= source then
        return
    end
    if objective_pending_session ~= world.session_generation or not Settings[source .. "_window"] or
        not objective_has_entry(entries, objective_pending_handle) then
        objective_clear_pending()
        return
    end
    if now >= objective_pending_until then
        gos.log.warn(objective_pending_busy and
            TAG .. source .. " target selection remained busy" or
            TAG .. source .. " target selection was not confirmed")
        objective_clear_pending()
        return
    end
    local unit = world:resolve(objective_pending_handle)
    if not unit then
        gos.log.warn(TAG .. source .. " target left the world snapshot")
        objective_clear_pending()
        return
    end
    if unit:is_current_target() then
        objective_clear_pending()
        return
    end
    if objective_pending_request then
        local status = gos.target.status(objective_pending_request)
        if status.state == "observed" then
            objective_clear_pending()
        elseif status.terminal then
            gos.log.warn(TAG .. source .. " target request ended: " ..
                tostring(status.state))
            objective_clear_pending()
        end
        return
    end
end

local function request_objective_selection(handle, world, now, target_intent, entries, source)
    source = source or "objective"
    local unit = handle and world:resolve(handle) or nil
    if not unit or not objective_has_entry(entries, handle) then
        return
    end
    if not target_intent then
        gos.log.warn(TAG .. source .. " target selection rejected: missing native click ticket")
        return
    end
    local ok, error_text, request_handle = gos.target.select(unit, target_intent)
    if not ok then
        gos.log.warn(TAG .. source .. " target selection failed: " .. tostring(error_text))
        return
    end
    objective_clear_pending()
    if not request_handle then return end
    objective_pending_handle = handle
    objective_pending_request = request_handle
    objective_pending_session = world.session_generation
    objective_pending_source = source
    objective_pending_until = now + 2000
    objective_pending_queued = true
    objective_pending_busy = false
    if Settings.effect_diagnostics then
        gos.log.info(TAG .. source .. " target request=" .. tostring(request_handle) ..
            " unit=" .. tostring(handle))
    end
    service_objective_selection(world, now, entries, source)
end

local function draw_objective_window(world, now)
    if not Settings.objective_window then
        objective_clear_pending("objective")
        window_drags.objective = nil
        return {
            raw = 0, casts = 0, matched = 0, unknown = {},
            unresolved = 0, filtered = 0, activeUnknowns = {}, omitted = 0,
        }
    end

    local entries, diagnostics = collect_objective_casts(world)
    service_objective_selection(world, now, entries)
    if #entries == 0 then
        return diagnostics
    end

    local visible_count = math.min(#entries, OBJECTIVE_MAX_ROWS)
    local width = Settings.objective_window_width
    local rows_height = visible_count * OBJECTIVE_ROW_HEIGHT +
        math.max(0, visible_count - 1) * OBJECTIVE_GAP
    local overflow_height = #entries > visible_count and 15 or 0
    local total_height = OBJECTIVE_TITLE_HEIGHT + OBJECTIVE_GAP +
        rows_height + overflow_height
    local viewport = gos.overlay.viewport()
    local x = Settings.objective_position_x
    local y = Settings.objective_position_y
    if viewport.available then
        x = objective_clamp(x, 0, math.max(0, viewport.width - width))
        y = objective_clamp(y, 0, math.max(0, viewport.height - total_height))
    end

    local title_hovered
    x, y, title_hovered = update_window_drag("objective", x, y, width, total_height, viewport)
    gos.overlay.draw_rect("pvp:objective:title:bg", {
        at = { screen = { x = x, y = y } },
        width = width, height = OBJECTIVE_TITLE_HEIGHT,
        filled = true,
        fill_color = title_hovered and OBJECTIVE_COLORS.title_hover or
            OBJECTIVE_COLORS.title,
        border = true, border_color = OBJECTIVE_COLORS.border, rounding = 1,
        ttl = TTL, frame = true,
    })
    gos.overlay.draw_text("pvp:objective:title", {
        at = { screen = { x = x + 7, y = y + 3 } },
        text = title_hovered and "Drag objective window" or
            ("Objective Interaction  [" .. tostring(#entries) .. "]"),
        color = OBJECTIVE_COLORS.text, font_size = 16, shadow = true,
        ttl = TTL, frame = true,
    })

    local grid_y = y + OBJECTIVE_TITLE_HEIGHT + OBJECTIVE_GAP
    local action_width = 70
    for index = 1, visible_count do
        local entry = entries[index]
        local row_y = grid_y + (index - 1) *
            (OBJECTIVE_ROW_HEIGHT + OBJECTIVE_GAP)
        local state = gos.overlay.interact("pvp:objective:row:" .. index, {
            x = x, y = row_y, width = width, height = OBJECTIVE_BUTTON_HEIGHT,
            ttl = TTL,
            entity = entry.handle,
        })
        local selected = entry.unit:is_current_target()
        if selected and objective_pending_source == "objective" and
            objective_pending_handle == entry.handle then
            objective_clear_pending()
        end
        local pending = objective_pending_source == "objective" and
            objective_pending_handle == entry.handle and
            now < objective_pending_until
        local relation_color = entry.reaction == "hostile" and
            OBJECTIVE_COLORS.hostile or OBJECTIVE_COLORS.friendly
        local row_fill = selected and OBJECTIVE_COLORS.selected or
            (state.hovered and OBJECTIVE_COLORS.row_hover or OBJECTIVE_COLORS.row)
        local border_color = pending and OBJECTIVE_COLORS.pending or
            (selected and OBJECTIVE_COLORS.selected_accent or relation_color)

        gos.overlay.draw_rect("pvp:objective:" .. index .. ":bg", {
            at = { screen = { x = x, y = row_y } },
            width = width, height = OBJECTIVE_BUTTON_HEIGHT,
            filled = true, fill_color = row_fill,
            border = true, border_color = border_color, rounding = 1,
            ttl = TTL, frame = true,
        })
        gos.overlay.draw_rect("pvp:objective:" .. index .. ":accent", {
            at = { screen = { x = x, y = row_y } },
            width = 3, height = OBJECTIVE_BUTTON_HEIGHT,
            filled = true, fill_color = relation_color, border = false,
            ttl = TTL, frame = true,
        })

        local name_width = math.max(50, width - 16 - action_width)
        local name_bytes = math.max(6, math.floor(name_width / 8))
        gos.overlay.draw_text("pvp:objective:" .. index .. ":name", {
            at = { screen = { x = x + 8, y = row_y + 3 } },
            text = objective_fit_bytes(entry.name, name_bytes),
            color = selected and OBJECTIVE_COLORS.selected_accent or
                OBJECTIVE_COLORS.text,
            font_size = 15, shadow = true, ttl = TTL, frame = true,
        })
        gos.overlay.draw_text("pvp:objective:" .. index .. ":hint", {
            at = { screen = { x = x + 8, y = row_y + 19 } },
            text = entry.reaction == "hostile" and "Enemy - click to target" or
                "Ally - click to target",
            color = pending and OBJECTIVE_COLORS.pending or OBJECTIVE_COLORS.muted,
            font_size = 11, shadow = true, ttl = TTL, frame = true,
        })

        local action_x = x + width - action_width * 0.5
        gos.overlay.draw_text("pvp:objective:" .. index .. ":action", {
            at = { screen = { x = action_x, y = row_y + 8 } },
            text = entry.action, color = relation_color,
            font_size = 13, shadow = true, center_x = true,
            ttl = TTL, frame = true,
        })
        local castbar_y = row_y + OBJECTIVE_BUTTON_HEIGHT + OBJECTIVE_CASTBAR_GAP
        local progress = 0
        if type(entry.duration) == "number" and entry.duration > 0 and
            type(entry.remaining) == "number" then
            progress = objective_clamp(1 - entry.remaining / entry.duration, 0, 1)
        end
        gos.overlay.draw_bar("pvp:objective:" .. index .. ":castbar", {
            at = { screen = { x = x, y = castbar_y } },
            width = width, height = OBJECTIVE_CASTBAR_HEIGHT,
            value = progress, color = relation_color,
            bg_color = OBJECTIVE_COLORS.background,
            border = true, border_color = border_color,
            ttl = TTL, frame = true,
        })
        if Settings.objective_show_timer then
            local timer_text_value = entry.remaining and
                string.format("%.1fs", entry.remaining) or "--"
            gos.overlay.draw_text("pvp:objective:" .. index .. ":timer", {
                at = { screen = { x = x + width * 0.5,
                    y = castbar_y - 1 } }, text = timer_text_value,
                color = OBJECTIVE_COLORS.text, font_size = 10, shadow = true,
                center_x = true, ttl = TTL, frame = true,
            })
        end

        if state.clicked and state.entity_session_generation == world.session_generation then
            request_objective_selection(state.entity_handle, world, now, state.target_intent, entries)
        end
    end

    if #entries > visible_count then
        gos.overlay.draw_text("pvp:objective:overflow", {
            at = { screen = { x = x + 4,
                y = grid_y + rows_height + 1 } },
            text = "+" .. tostring(#entries - visible_count) .. " more interactions",
            color = OBJECTIVE_COLORS.pending, font_size = 11, shadow = true,
            ttl = TTL, frame = true,
        })
    end
    return diagnostics
end

local HOSTILE_CLASS_ABBREVIATIONS = {
    sage = "SAGE", sorcerer = "SORC", shadow = "SHD", assassin = "SIN",
    guardian = "GRD", juggernaut = "JUG", sentinel = "SENT", marauder = "MARA",
    vanguard = "VG", powertech = "PT", commando = "COM", mercenary = "MERC",
    gunslinger = "GS", sniper = "SNIP", scoundrel = "SCO", operative = "OP",
}
local HOSTILE_CLASS_COLORS = {
    guardian = rgba(97, 75, 160), juggernaut = rgba(97, 75, 160),
    sentinel = rgba(222, 31, 38), marauder = rgba(222, 31, 38),
    sage = rgba(78, 176, 211), assassin = rgba(78, 176, 211),
    shadow = rgba(50, 81, 224), sorcerer = rgba(50, 81, 224),
    vanguard = rgba(116, 183, 44), powertech = rgba(116, 183, 44),
    commando = rgba(42, 144, 71), mercenary = rgba(42, 144, 71),
    gunslinger = rgba(201, 106, 16), operative = rgba(201, 106, 16),
    scoundrel = rgba(220, 223, 70), sniper = rgba(220, 223, 70),
}
local HOSTILE_ROW_HEIGHT = 31
local HOSTILE_EMPTY_HEIGHT = 19
local hostile_rating_api_warned = false

local function collect_hostile_roster(world)
    local out = {}
    local units = world:units({ type = "player", reaction = "hostile" })
    for index = 1, math.min(#units, 64) do
        local unit = units[index]
        local handle = unit:handle()
        if type(handle) ~= "string" or handle == "" then goto continue_hostile end
        local distance = unit:distance()
        if type(distance) ~= "number" or distance < 0 or distance >= math.huge or
            distance ~= distance then distance = nil end
        local hp = unit:hp()
        local percent
        if hp and type(hp.current) == "number" and type(hp.max) == "number" and
            hp.current >= 0 and hp.current < math.huge and hp.max > 0 and hp.max < math.huge then
            percent = objective_clamp(hp.current / hp.max * 100, 0, 100)
        end
        local rating
        if type(unit.item_rating) == "function" then
            rating = unit:item_rating()
        elseif not hostile_rating_api_warned then
            -- Explicit API-availability gate: no alternative source or guessed gear.
            gos.log.warn(TAG .. "hostile roster iLvl unavailable: activate the Core build with unit:item_rating()")
            hostile_rating_api_warned = true
        end
        local name = unit:name()
        local style = unit:combat_style()
        out[#out + 1] = {
            unit = unit, handle = handle, name = name or "--",
            sort_name = (name or ""):lower(), distance = distance,
            class = HOSTILE_CLASS_ABBREVIATIONS[style] or "--",
            class_color = HOSTILE_CLASS_COLORS[style] or OBJECTIVE_COLORS.hostile,
            spec = unit:discipline() or "--", hp_percent = percent,
            item_rating = rating,
        }
        ::continue_hostile::
    end
    table.sort(out, function(left, right)
        local ld, rd = left.distance or math.huge, right.distance or math.huge
        if ld ~= rd then return ld < rd end
        if left.sort_name ~= right.sort_name then return left.sort_name < right.sort_name end
        return left.handle < right.handle
    end)
    return out
end

local function hostile_text(id, x, y, text, color, size)
    gos.overlay.draw_text("pvp:hostile:" .. id, {
        at = { screen = { x = x, y = y } }, text = text,
        color = color or OBJECTIVE_COLORS.text, font_size = size or 14,
        shadow = true, ttl = TTL, frame = true,
    })
end

local function draw_hostile_window(world, now)
    if not Settings.hostile_window then
        objective_clear_pending("hostile")
        window_drags.hostile = nil
        return
    end
    local entries = collect_hostile_roster(world)
    service_objective_selection(world, now, entries, "hostile")
    local width = Settings.hostile_compact_width
    local visible = math.min(#entries, Settings.hostile_window_rows)
    local viewport = gos.overlay.viewport()
    if viewport.available and visible > 0 then
        local fit = math.max(1, math.floor((viewport.height - OBJECTIVE_TITLE_HEIGHT - 18) /
            HOSTILE_ROW_HEIGHT))
        visible = math.min(visible, fit)
    end
    local height = OBJECTIVE_TITLE_HEIGHT + (visible > 0 and
        visible * HOSTILE_ROW_HEIGHT or HOSTILE_EMPTY_HEIGHT) +
        (#entries > visible and 18 or 0)
    local x, y = Settings.hostile_position_x, Settings.hostile_position_y
    if viewport.available then
        x = objective_clamp(x, 0, math.max(0, viewport.width - width))
        y = objective_clamp(y, 0, math.max(0, viewport.height - height))
    end
    local hovered
    x, y, hovered = update_window_drag("hostile", x, y, width, height, viewport)
    local close = gos.overlay.interact("pvp:hostile:close", {
        x = x + width - 34, y = y, width = 34, height = OBJECTIVE_TITLE_HEIGHT, ttl = TTL,
    })
    if close.clicked then
        local ok, err = gos.settings.set(SCRIPT_ID, "hostile_window", false)
        if ok then
            Settings.hostile_window = false
            objective_clear_pending("hostile")
            window_drags.hostile = nil
            return
        end
        gos.log.warn(TAG .. "hostile roster hide failed: " .. tostring(err))
    end
    gos.overlay.draw_rect("pvp:hostile:bg", {
        at = { screen = { x = x, y = y } }, width = width, height = height,
        filled = true, fill_color = OBJECTIVE_COLORS.background,
        border = true, border_color = OBJECTIVE_COLORS.border, ttl = TTL, frame = true,
    })
    hostile_text("move:text", x + 5, y + 1, "[=]",
        hovered and OBJECTIVE_COLORS.selected_accent or OBJECTIVE_COLORS.muted, 20)
    hostile_text("title", x + 38, y + 5, "HOSTILES  [" .. #entries .. "]",
        OBJECTIVE_COLORS.muted, 13)
    hostile_text("close:text", x + width - 23, y + 1, "X",
        close.hovered and OBJECTIVE_COLORS.selected_accent or OBJECTIVE_COLORS.muted, 20)
    if visible == 0 then
        hostile_text("empty", x + 8, y + OBJECTIVE_TITLE_HEIGHT + 2,
            "No hostiles", OBJECTIVE_COLORS.muted, 12)
    end
    for index = 1, visible do
        local entry = entries[index]
        local row_y = y + OBJECTIVE_TITLE_HEIGHT + (index - 1) * HOSTILE_ROW_HEIGHT
        local name_width = width - 110
        local state = gos.overlay.interact("pvp:hostile:row:" .. index, {
            x = x + 6, y = row_y, width = name_width, height = 16,
            ttl = TTL, entity = entry.handle,
        })
        local selected = entry.unit:is_current_target()
        local pending = objective_pending_source == "hostile" and
            objective_pending_handle == entry.handle and now < objective_pending_until
        gos.overlay.draw_rect("pvp:hostile:" .. index .. ":bg", {
            at = { screen = { x = x + 2, y = row_y } },
            width = width - 4, height = HOSTILE_ROW_HEIGHT - 1, filled = true,
            fill_color = selected and OBJECTIVE_COLORS.selected or
                (state.hovered and OBJECTIVE_COLORS.row_hover or OBJECTIVE_COLORS.row),
            border = selected or pending,
            border_color = pending and OBJECTIVE_COLORS.pending or OBJECTIVE_COLORS.selected_accent,
            ttl = TTL, frame = true,
        })
        local text_color = selected and OBJECTIVE_COLORS.selected_accent or OBJECTIVE_COLORS.text
        hostile_text(index .. ":name", x + 6, row_y + 2,
            objective_fit_bytes(entry.name, math.max(1, math.floor(name_width / 7))), text_color, 13)
        hostile_text(index .. ":hp", x + width - 98, row_y + 2,
            entry.hp_percent and string.format("%.0f%%", entry.hp_percent) or "--", text_color, 12)
        hostile_text(index .. ":distance", x + width - 44, row_y + 2,
            entry.distance and string.format("%.0fm", entry.distance * 10) or "--", text_color, 12)
        hostile_text(index .. ":class", x + 6, row_y + 17, entry.class,
            selected and OBJECTIVE_COLORS.selected_accent or entry.class_color, 11)
        hostile_text(index .. ":spec", x + 50, row_y + 17,
            objective_fit_bytes(entry.spec, math.max(1, math.floor((width - 120) / 7))),
            text_color, 11)
        hostile_text(index .. ":rating", x + width - 66, row_y + 17,
            entry.item_rating and "iLvl " .. tostring(entry.item_rating) or "iLvl --", text_color, 11)
        gos.overlay.draw_bar("pvp:hostile:" .. index .. ":hp:bar", {
            at = { screen = { x = x + width - 98, y = row_y + 16 } },
            width = 32, height = 2, value = entry.hp_percent and entry.hp_percent / 100 or 0,
            color = OBJECTIVE_COLORS.hostile, bg_color = OBJECTIVE_COLORS.background,
            ttl = TTL, frame = true,
        })
        if state.clicked and state.entity_session_generation == world.session_generation then
            request_objective_selection(state.entity_handle, world, now, state.target_intent, entries, "hostile")
        end
    end
    if #entries > visible then
        hostile_text("overflow", x + 8, y + height - 16,
            "+" .. (#entries - visible) .. " more - increase Hostiles - Rows", OBJECTIVE_COLORS.muted, 12)
    end
end

local last_effect_diagnostics_ms = nil

local function add_count(counts, key)
    key = tostring(key or "-")
    counts[key] = (counts[key] or 0) + 1
end

local function format_counts(counts)
    local keys = {}
    for key in pairs(counts) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local out = {}
    for _, key in ipairs(keys) do
        out[#out + 1] = key .. "=" .. tostring(counts[key])
    end
    return table.concat(out, ",")
end

local function log_effect_diagnostics(records, limit, draw_budget, objective)
    if not Settings.effect_diagnostics then
        return
    end
    local now = gos.time_ms() or 0
    if last_effect_diagnostics_ms ~= nil and
        now - last_effect_diagnostics_ms < 1000 then
        return
    end
    last_effect_diagnostics_ms = now

    local statuses, reasons, stages = {}, {}, {}
    local ready, pending, unavailable, truncated = 0, 0, 0, 0
    local fresh_items, retained_items = 0, 0
    local max_age, max_last_known_age = nil, nil
    for index = 1, limit do
        local observed = records[index].observed
        if observed then
            add_count(statuses, observed.status)
            add_count(reasons, observed.reason)
            add_count(stages, observed.producer_stage)
            if observed.status == "ready" then
                ready = ready + 1
            elseif observed.status == "pending" then
                pending = pending + 1
            elseif observed.status == "unavailable" then
                unavailable = unavailable + 1
            end
            if observed.truncated == true then
                truncated = truncated + 1
            end
            fresh_items = fresh_items + #(observed.items or {})
            retained_items = retained_items + #(observed.last_known_items or {})
            if type(observed.age_ms) == "number" and
                (max_age == nil or observed.age_ms > max_age) then
                max_age = observed.age_ms
            end
            if type(observed.last_known_age_ms) == "number" and
                (max_last_known_age == nil or
                    observed.last_known_age_ms > max_last_known_age) then
                max_last_known_age = observed.last_known_age_ms
            end
        end
    end
    gos.log.info(TAG .. "effect diagnostics: units=" .. tostring(limit) ..
        " ready=" .. tostring(ready) .. " pending=" .. tostring(pending) ..
        " unavailable=" .. tostring(unavailable) ..
        " truncated=" .. tostring(truncated) ..
        " fresh_items=" .. tostring(fresh_items) ..
        " last_known_items=" .. tostring(retained_items) ..
        " max_age_ms=" .. tostring(max_age or "-") ..
        " max_last_known_age_ms=" .. tostring(max_last_known_age or "-") ..
        " commands=" .. tostring(draw_budget.used) ..
        " emitted=" .. tostring(draw_budget.emitted) ..
        " rejected=" .. tostring(draw_budget.rejected) ..
        " clipped=" .. tostring(draw_budget.clipped) ..
        " degraded=" .. tostring(draw_budget.degraded) ..
        " statuses={" .. format_counts(statuses) .. "}" ..
        " reasons={" .. format_counts(reasons) .. "}" ..
        " producer_stages={" .. format_counts(stages) .. "}")
    gos.log.info(TAG .. "objective casts=" .. tostring(objective.casts) ..
        " matched=" .. tostring(objective.matched) ..
        " unknown={" .. format_counts(objective.unknown) .. "}" ..
        " unresolved=" .. tostring(objective.unresolved) ..
        " filtered=" .. tostring(objective.filtered) ..
        " raw=" .. tostring(objective.raw) ..
        " active_unknowns={" .. table.concat(objective.activeUnknowns, ";") ..
        "} omitted=" .. tostring(objective.omitted))
end

local function first_fresh_effect(effects)
    for index = 1, math.min(#effects, Settings.max_player_icons) do
        if effects[index].last_known ~= true then
            return effects[index]
        end
    end
    return nil
end

if Settings.effect_diagnostics then
    gos.log.info(TAG .. "loaded build=" .. BUILD_ID ..
        " icon_root=" .. ICON_ROOT)
end

gos.on_tick(function()
    Settings = gos.settings.get(SCRIPT_ID)
    if not (Settings.enabled and Settings.active and Settings.visible) then
        objective_clear_pending()
        window_drags = {}
        return
    end

    local world = gos.world()
    local now = gos.time_ms() or 0
    local objective_diagnostics = draw_objective_window(world, now)
    draw_hostile_window(world, now)

    local records = collect_units(world)
    local budget = {
        used = 0, emitted = 0, rejected = 0, clipped = 0, degraded = 0,
    }
    local limit = math.min(#records, Settings.max_units)
    for index = 1, limit do
        local record = records[index]
        if Settings.test_mode then
            record.defensive, record.offensive =
                collect_test_player_cooldowns(index)
            record.observed = nil
        else
            record.defensive, record.offensive, record.observed =
                collect_player_cooldowns(record.unit)
        end
        record.drawn = { defensive = {}, offensive = {} }
    end

    -- Reserve the small, current-target-only cue budget before awareness
    -- images. A cue is meaningful only for a strict fresh row.
    if Settings.show_action_cues then
        for index = 1, limit do
            local record = records[index]
            local unit = record.unit
            if Settings.test_mode or
                (record.target and unit:reaction() == "hostile") then
                if Settings.show_player_defensives then
                    local effect = first_fresh_effect(record.defensive)
                    if effect and not draw_action_cue(unit, effect, budget,
                            "pvp:c:d", cooldown_layout("defensive"),
                            math.min(#record.defensive,
                                Settings.max_player_icons),
                            record.nameplate_scale) then
                        log_effect_diagnostics(records, limit, budget,
                            objective_diagnostics)
                        return
                    end
                end
                if Settings.show_player_offensives then
                    local effect = first_fresh_effect(record.offensive)
                    if effect and not draw_action_cue(unit, effect, budget,
                            "pvp:c:o", cooldown_layout("offensive"),
                            math.min(#record.offensive,
                                Settings.max_player_icons),
                            record.nameplate_scale) then
                        log_effect_diagnostics(records, limit, budget,
                            objective_diagnostics)
                        return
                    end
                end
            end
        end
    end

    draw_images(records, limit, budget)
    draw_decorations(records, limit, budget)
    log_effect_diagnostics(records, limit, budget, objective_diagnostics)
end)
