local SCRIPT_ID = "crowd_control_viewer"
local BUILD_ID = "2026-09-19-sandbox-sprites-v1-personal-defaults-20261007-script-library-layout-r1"
local TAG = "[cc-viewer] "
local ICON_ROOT = SPRITE_PATH .. "swtor\\"
local TTL = 0.20
local MAX_DRAW_COMMANDS = 120

local Settings = gos.settings.register(SCRIPT_ID, {
    title = "Crowd Control Viewer",
    version = 7,
    activation = { mode = "manual" },
    fields = {
        {
            key = "visible", type = "bool", label = "CC Viewer - Enabled",
            tooltip = "Master switch for crowd-control awareness.",
            default = true,
        },
        {
            key = "test_mode", type = "bool", label = "Preview - Test Mode",
            tooltip = "Draw rotating sample crowd-control icons over visible units.",
            default = false,
        },
        {
            key = "show_crowd_control", type = "bool", label = "Awareness - Crowd Control",
            tooltip = "Show active action-locking debuffs above units.",
            default = true,
        },
        {
            key = "show_friendly", type = "bool", label = "Targets - Friendly",
            tooltip = "Show enabled awareness layers for friendly units.",
            default = true,
        },
        {
            key = "show_hostile", type = "bool", label = "Targets - Hostile",
            tooltip = "Show enabled awareness layers for hostile units.",
            default = true,
        },
        {
            key = "show_neutral", type = "bool", label = "Targets - Neutral",
            tooltip = "Show enabled awareness layers for neutral units.",
            default = false,
        },
        {
            key = "show_self", type = "bool", label = "Targets - Self",
            tooltip = "Show enabled awareness layers for the local player.",
            default = true,
        },
        {
            key = "max_units", type = "int", label = "Limits - Max Units",
            tooltip = "Maximum units scanned per tick after distance sorting.",
            default = 64, min = 1, max = 64, step = 1,
        },
        {
            key = "max_icons", type = "int", label = "Limits - CC Icons per Unit",
            tooltip = "Maximum crowd-control icons drawn per unit.",
            default = 2, min = 1, max = 4, step = 1,
        },
        {
            key = "max_distance", type = "int", label = "Limits - Max Distance",
            tooltip = "Maximum unit distance to scan. Zero means unlimited.",
            default = 80, min = 0, max = 500, step = 5,
        },
        {
            key = "icon_size", type = "int", label = "CC - Icon Size",
            tooltip = "Crowd-control icon size in screen pixels.",
            default = 48, min = 18, max = 48, step = 1,
        },
        {
            key = "vertical_offset", type = "int", label = "CC - Y Offset",
            tooltip = "Pixel offset from the top of the unit marker.",
            default = -74, min = -220, max = 80, step = 1,
        },
        {
            key = "diagnostics_logging", type = "bool", label = "Diagnostics Logging",
            tooltip = "Log script startup details.", default = false,
        },
    },
})

local ICONS = {
    -- Generic CC state names.
    afraid = "raw\\afraid.dds",
    asleep = "classes\\agent\\operative\\base\\icons\\sleep_dart.dds",
    blinded = "raw\\blinded.dds",
    carbonized = "raw\\carbonized.dds",
    incapacitated = "classes\\jedi_consular\\shadow\\specs\\infiltration\\icons\\low_slash.dds",
    knockdown = "classes\\sith_inquisitor\\assassin\\specs\\darkness\\mods\\icons\\spike.dds",
    lifted = "abilities\\force_lift.dds",
    sleeping = "classes\\agent\\operative\\base\\icons\\sleep_dart.dds",
    stunned = "abilities\\force_stun.dds",

    -- Current player-cast CC ability names and mirrors.
    awe = "classes\\jedi_knight\\base\\icons\\awe.dds",
    backhand = "classes\\sith_warrior\\juggernaut\\specs\\immortal\\icons\\backhand.dds",
    below_the_belt = "classes\\smuggler\\gunslinger\\specs\\dirty_fighting\\mods\\icons\\below_the_belt.dds",
    carbonize = "classes\\bounty_hunter\\powertech\\base\\icons\\carbonize.dds",
    concussion_missile = "classes\\bounty_hunter\\mercenary\\base\\icons\\concussion_missile.dds",
    concussive_round = "classes\\trooper\\commando\\base\\icons\\concussive_round.dds",
    cryo_grenade = "classes\\trooper\\base\\icons\\cryo_grenade.dds",
    debilitate = "classes\\agent\\operative\\specs\\concealment\\mods\\icons\\debilitate.dds",
    dirty_kick = "classes\\smuggler\\scoundrel\\specs\\ruffian\\mods\\icons\\dirty_kick.dds",
    electro_dart = "classes\\bounty_hunter\\base\\icons\\electro_dart.dds",
    electrocute = "classes\\sith_inquisitor\\assassin\\base\\icons\\electrocute.dds",
    flash_bang = "classes\\agent\\base\\icons\\flash_bang.dds",
    flash_grenade = "classes\\smuggler\\base\\icons\\flash_grenade.dds",
    force_choke = "classes\\sith_warrior\\base\\icons\\force_choke.dds",
    force_lift = "abilities\\force_lift.dds",
    force_push = "classes\\jedi_knight\\guardian\\base\\icons\\force_push.dds",
    force_stasis = "classes\\jedi_knight\\base\\icons\\force_stasis.dds",
    force_stun = "abilities\\force_stun.dds",
    hilt_bash = "classes\\jedi_knight\\guardian\\specs\\defense\\icons\\hilt_bash.dds",
    intimidating_roar = "classes\\sith_warrior\\base\\icons\\intimidating_roar.dds",
    low_slash = "classes\\jedi_consular\\shadow\\specs\\infiltration\\icons\\low_slash.dds",
    maim = "classes\\agent\\sniper\\specs\\engineering\\mods\\icons\\maim.dds",
    maul_spike = "classes\\sith_inquisitor\\assassin\\specs\\deception\\mods\\icons\\maul_spike.dds",
    mind_maze = "classes\\jedi_consular\\shadow\\base\\icons\\mind_maze.dds",
    mind_trap = "classes\\sith_inquisitor\\assassin\\base\\icons\\mind_trap.dds",
    neural_surge = "classes\\trooper\\specialist\\base\\icons\\neural_surge.dds",
    shadow_spike = "classes\\jedi_consular\\shadow\\specs\\infiltration\\mods\\icons\\shadow_spike.dds",
    sleep_dart = "classes\\agent\\operative\\base\\icons\\sleep_dart.dds",
    spike = "classes\\sith_inquisitor\\assassin\\specs\\darkness\\mods\\icons\\spike.dds",
    tranquilizer = "classes\\smuggler\\scoundrel\\base\\icons\\tranquilizer.dds",
    whirlwind = "classes\\sith_inquisitor\\assassin\\specs\\darkness\\mods\\icons\\whirlwind.dds",
}

local TEST_ICON_NAMES = {}
for name in pairs(ICONS) do
    TEST_ICON_NAMES[#TEST_ICON_NAMES + 1] = name
end
table.sort(TEST_ICON_NAMES)

local EFFECT_SCAN_BUDGET = 16
local effect_cache = {}
local refresh_cursor = 1
local effect_cache_mode = nil
local bootstrap_refresh_passes = 2

local function effect_key(name)
    return tostring(name or ""):lower():gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
end

local function icon_path(effect)
    local relative = ICONS[effect_key(effect.name)]
    if not relative then
        return nil
    end
    return ICON_ROOT .. relative
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
    if not unit or unit:type() == "object" then
        return false
    end
    if unit:is_local_player() and not Settings.show_self then
        return false
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

local function unit_sort_key(unit)
    if unit:is_current_target() then
        return -1
    end
    local distance = unit:distance()
    return type(distance) == "number" and distance or 999999
end

local function collect_units(world)
    local out = {}
    for _, unit in ipairs(world:units()) do
        if usable_unit(unit) then
            out[#out + 1] = unit
        end
    end
    table.sort(out, function(left, right)
        return unit_sort_key(left) < unit_sort_key(right)
    end)
    return out
end

local function collect_effects(unit)
    local observed = unit:effects({ kind = "debuff", timed = true })
    local selected_cc = {}

    local function consider(effect, last_known)
        local key = effect_key(effect.name)
        if not effect.has_timer or type(effect.remaining) ~= "number" or
            effect.remaining <= 0 then
            return
        end
        if ICONS[key] and not selected_cc[key] then
            selected_cc[key] = {
                name = effect.name,
                remaining = effect.remaining,
                icon = ICONS[key],
                last_known = last_known == true,
            }
        end
    end

    -- Strict rows win. Core last-known rows are presentation-only continuity
    -- while an authoritative refresh is pending or bridging one empty scan.
    if observed.status == "ready" then
        for _, effect in ipairs(observed.items or {}) do
            consider(effect, false)
        end
    end
    for _, effect in ipairs(observed.last_known_items or {}) do
        consider(effect, true)
    end

    local cc = {}
    for _, effect in pairs(selected_cc) do
        cc[#cc + 1] = effect
    end
    table.sort(cc, function(left, right)
        return (left.remaining or 999999) < (right.remaining or 999999)
    end)
    return cc, observed.status
end

local function collect_test_cc(unit_index)
    local out = {}
    local count = math.min(Settings.max_icons, #TEST_ICON_NAMES)
    local bucket = math.floor((gos.time_ms() or 0) / 900)
    for index = 1, count do
        local pick = ((bucket * 7 + unit_index * 13 + index * 5) % #TEST_ICON_NAMES) + 1
        out[#out + 1] = {
            name = TEST_ICON_NAMES[pick],
            has_timer = true,
            remaining = 1 + ((bucket + unit_index + index) % 9),
        }
    end
    return out
end

local function draw_effects(unit, effects, draw_budget, id_prefix,
        vertical_offset, max_icons, age_seconds)
    local size = Settings.icon_size
    local gap = 4
    age_seconds = math.max(0, age_seconds or 0)
    local count = 0
    for index = 1, #effects do
        local effect = effects[index]
        local remaining = type(effect.remaining) == "number" and
            math.max(0, effect.remaining - age_seconds) or effect.remaining
        if type(remaining) ~= "number" or remaining > 0 then
            count = count + 1
            if count >= max_icons then
                break
            end
        end
    end
    local start_x = -((count - 1) * (size + gap)) * 0.5
    local drawn = 0
    for index = 1, #effects do
        local effect = effects[index]
        local remaining = type(effect.remaining) == "number" and
            math.max(0, effect.remaining - age_seconds) or effect.remaining
        if type(remaining) ~= "number" or remaining > 0 then
            if drawn >= max_icons then
                break
            end
            if draw_budget.used + 3 > MAX_DRAW_COMMANDS then
                return false
            end
            drawn = drawn + 1
            local x = start_x + (drawn - 1) * (size + gap)
            local y = vertical_offset
            local id = id_prefix .. ":" .. drawn
            local path = effect.icon and (ICON_ROOT .. effect.icon) or icon_path(effect)
            if path then
                gos.overlay.draw_image(id .. ":i", {
                    at = { unit = unit, anchor = "top",
                        pixel_offset = { x = x, y = y } }, path = path,
                    width = size, height = size,
                    tint = effect.last_known and { 255, 255, 255, 140 } or "white",
                    center_x = true, ttl = TTL, frame = true,
                })
                gos.overlay.draw_rect(id .. ":b", {
                    at = { unit = unit, anchor = "top", pixel_offset = {
                        x = x - size * 0.5, y = y + size - 13 } },
                    width = size, height = 13, color = { 0, 0, 0, 185 },
                    filled = true, ttl = TTL, frame = true,
                })
                gos.overlay.draw_text(id .. ":t", {
                    at = { unit = unit, anchor = "top",
                        pixel_offset = { x = x, y = y + size - 6 } },
                    text = timer_text(remaining),
                    color = effect.last_known and { 180, 180, 180, 210 } or "white",
                    font_size = 12, shadow = true, center_x = true,
                    center_y = true, ttl = TTL, frame = true,
                })
                draw_budget.used = draw_budget.used + 3
            end
        end
    end
    return true
end

if Settings.diagnostics_logging then
    gos.log.info(TAG .. "loaded build=" .. BUILD_ID ..
        " icon_root=" .. ICON_ROOT)
end

gos.on_tick(function()
    Settings = gos.settings.get(SCRIPT_ID)
    if not (Settings.enabled and Settings.active and Settings.visible) then
        return
    end

    local units = collect_units(gos.world())
    local include_cc = Settings.show_crowd_control
    if include_cc ~= effect_cache_mode then
        effect_cache = {}
        refresh_cursor = 1
        effect_cache_mode = include_cc
        bootstrap_refresh_passes = 2
    end

    local budget = { used = 0 }
    local limit = math.min(#units, Settings.max_units)
    local now_ms = gos.time_ms() or 0
    local live = {}
    for index = 1, limit do
        local handle = units[index]:handle()
        if handle then
            live[handle] = true
        end
    end
    for handle in pairs(effect_cache) do
        if not live[handle] then
            effect_cache[handle] = nil
        end
    end

    if not Settings.test_mode and include_cc and limit > 0 then
        local refreshed = {}
        local function refresh(index)
            if index < 1 or index > limit or refreshed[index] then
                return
            end
            refreshed[index] = true
            local unit = units[index]
            local handle = unit:handle()
            if handle then
                local cc, status = collect_effects(unit)
                local has_continuity_rows = #cc > 0
                if status == "ready" or has_continuity_rows then
                    effect_cache[handle] = {
                        cc = cc, sample_ms = now_ms,
                    }
                elseif status ~= "pending" then
                    effect_cache[handle] = nil
                end
            end
        end
        if bootstrap_refresh_passes > 0 then
            for index = 1, limit do
                refresh(index)
            end
            bootstrap_refresh_passes = bootstrap_refresh_passes - 1
            refresh_cursor = 2
        else
            refresh(1) -- Current target sorts first; keep it maximally fresh.
            local remaining = EFFECT_SCAN_BUDGET - 1
            while remaining > 0 and limit > 1 do
                if refresh_cursor < 2 or refresh_cursor > limit then
                    refresh_cursor = 2
                end
                refresh(refresh_cursor)
                refresh_cursor = refresh_cursor + 1
                remaining = remaining - 1
            end
        end
    end

    for index = 1, limit do
        local unit = units[index]
        local cc, age_seconds
        if Settings.test_mode then
            cc = include_cc and collect_test_cc(index) or {}
            age_seconds = 0
        elseif include_cc then
            local handle = unit:handle()
            local cached = handle and effect_cache[handle] or nil
            cc = cached and cached.cc or {}
            age_seconds = cached and math.max(0, (now_ms - cached.sample_ms) / 1000) or 0
        else
            cc, age_seconds = {}, 0
        end
        if #cc > 0 and not draw_effects(unit, cc, budget,
                "ccv", Settings.vertical_offset, Settings.max_icons, age_seconds) then
            break
        end
    end
end, { interval_ms = 33 })
