-- Shared visual awareness; detector icons do not depend on target selection.
local M = { build_id = "stealth-detectors-spatial-point-r3" }

local ICON_ROOT = SPRITE_PATH .. "swtor\\"
local TTL = 0.20
local METERS_PER_WORLD_UNIT = 10.0
local EFFECT_SCAN_BUDGET = 16
local DEFAULT_MAX_UNITS = 64
local DEFAULT_MAX_DISTANCE_METERS = 80
local DEFAULT_ICON_SIZE = 30
local DEFAULT_HEIGHT_METERS = 2.0
local DEFAULT_MAX_ICONS = 2

local DETECTORS = {
    -- Core PrettyEffectName exports this prototype leaf, NOT the localized
    -- "Advanced Stealth Detection" embedded in boss_stealth_detect/4/1.
    -- Local TOR evidence: docs/BOSS_STEALTH_DETECT_20260907.md.
    -- No fixed radius verified: do not fabricate a 15m safe boundary.
    boss_stealth_detect = {
        key = "boss_stealth_detect", order = 5,
        icon = "raw\\focusfire.dds", badge = "DETECT",
        range_status = "unverified",
    },
    advanced_stealth_detection = {
        key = "advanced_stealth_detection", order = 10,
        radius_m = 15.0, icon = "raw\\probedroid.dds",
    },
    stealth_detection = {
        key = "stealth_detection", order = 20,
        radius_m = 15.0, icon = "raw\\probedroid.dds",
    },
    stealth_scan = {
        key = "stealth_scan", order = 30,
        radius_m = 15.0, icon = "raw\\chaffflare.dds",
    },
}

local effect_cache = {}
local refresh_cursor = 1
local bootstrap_refresh_passes = 2
local function finite_number(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function safe_method(object, method, ...)
    if not object or type(object[method]) ~= "function" then return nil end
    local ok, value = pcall(object[method], object, ...)
    return ok and value or nil
end

local function effect_key(name)
    return tostring(name or ""):lower():gsub("[%s%-]+", "_"):
        gsub("[^%w_]", "")
end

local function detector_rows(unit)
    local observed = safe_method(unit, "effects", { kind = "any" })
    if type(observed) ~= "table" then return {}, "unavailable" end
    local selected = {}

    local function consider(effect, last_known)
        if type(effect) ~= "table" then return end
        local known = DETECTORS[effect_key(effect.name)]
        if not known or selected[known.key] then return end
        local remaining = effect.has_timer == true and
            finite_number(effect.remaining) and effect.remaining or nil
        if remaining ~= nil and remaining <= 0 then return end
        selected[known.key] = {
            key = known.key, name = effect.name, order = known.order,
            radius_m = known.radius_m, icon = known.icon,
            badge = known.badge, range_status = known.range_status,
            remaining = remaining, last_known = last_known == true,
        }
    end

    if observed.status == "ready" then
        for _, effect in ipairs(observed.items or {}) do consider(effect, false) end
    end
    for _, effect in ipairs(observed.last_known_items or {}) do
        consider(effect, true)
    end

    local rows = {}
    for _, row in pairs(selected) do rows[#rows + 1] = row end
    table.sort(rows, function(left, right) return left.order < right.order end)
    return rows, observed.status
end
local function usable_hostile(unit, options)
    if not unit or safe_method(unit, "reaction") ~= "hostile" then return false end
    if safe_method(unit, "type") == "object" then return false end
    -- Read detector effects independently of Lua projection flags. Core renders
    -- unit-attached icons when visible; an unselected/off-screen snapshot must
    -- not prevent discovering the detector before it enters view.
    local distance = safe_method(unit, "distance")
    local max_m = finite_number(options.maxDistanceMeters) and
        options.maxDistanceMeters or DEFAULT_MAX_DISTANCE_METERS
    if max_m > 0 and finite_number(distance) and
        distance * METERS_PER_WORLD_UNIT > max_m then
        return false
    end
    return true
end

local function collect_units(world, options, selected_handle)
    local units = safe_method(world, "units", { reaction = "hostile" })
    if type(units) ~= "table" then return {} end
    local out = {}
    for _, unit in ipairs(units) do
        if usable_hostile(unit, options) then out[#out + 1] = unit end
    end
    table.sort(out, function(left, right)
        local lc = selected_handle ~= nil and safe_method(left, "handle") == selected_handle
        local rc = selected_handle ~= nil and safe_method(right, "handle") == selected_handle
        if lc ~= rc then return lc end
        local ld = safe_method(left, "distance")
        local rd = safe_method(right, "distance")
        return (finite_number(ld) and ld or math.huge) <
            (finite_number(rd) and rd or math.huge)
    end)
    return out
end
local function effect_age_remaining(effect, age_seconds)
    if not finite_number(effect.remaining) then return nil end
    return math.max(0, effect.remaining - math.max(0, age_seconds or 0))
end

local function active_effects(cached, now_ms)
    if type(cached) ~= "table" then return {} end
    local age = math.max(0, (now_ms - (cached.sample_ms or now_ms)) / 1000.0)
    local out = {}
    for _, effect in ipairs(cached.effects or {}) do
        local remaining = effect_age_remaining(effect, age)
        if remaining == nil or remaining > 0 then
            local row = {}
            for key, value in pairs(effect) do row[key] = value end
            row.remaining = remaining
            out[#out + 1] = row
        end
    end
    return out
end
local function draw_icons(unit, effects, options)
    local size = finite_number(options.iconSize) and options.iconSize or DEFAULT_ICON_SIZE
    local max_icons = finite_number(options.maxIcons) and
        math.max(1, math.floor(options.maxIcons)) or DEFAULT_MAX_ICONS
    local gap = 4
    local count = math.min(#effects, max_icons)
    if count <= 0 then return end
    local height = finite_number(options.heightMeters) and options.heightMeters or DEFAULT_HEIGHT_METERS
    local up = height / METERS_PER_WORLD_UNIT
    local y = -size -- Attach the icon's bottom edge to the projected world point.
    local start_x = -((count - 1) * (size + gap)) * 0.5
    for index = 1, count do
        local effect = effects[index]
        local x = start_x + (index - 1) * (size + gap)
        local id = "op:stealth_detect:" .. tostring(index)
        gos.overlay.draw_image(id .. ":i", {
            at = { unit = unit, anchor = "origin",
                world_offset = { x = 0, y = up, z = 0 },
                pixel_offset = { x = x, y = y } },
            path = ICON_ROOT .. effect.icon, width = size, height = size,
            tint = effect.last_known and { 255, 255, 255, 145 } or "white",
            center_x = true, ttl = TTL, frame = true,
        })
        gos.overlay.draw_rect(id .. ":b", {
            at = { unit = unit, anchor = "origin",
                world_offset = { x = 0, y = up, z = 0 },
                pixel_offset = { x = x - size * 0.5, y = y + size - 13 } },
            width = size, height = 13, color = { 0, 0, 0, 190 },
            filled = true, ttl = TTL, frame = true,
        })
        local badge = effect.badge
        if not badge and finite_number(effect.radius_m) and effect.radius_m > 0 then
            badge = tostring(math.floor(effect.radius_m + 0.5)) .. "m"
        end
        gos.overlay.draw_text(id .. ":t", {
            at = { unit = unit, anchor = "origin",
                world_offset = { x = 0, y = up, z = 0 },
                pixel_offset = { x = x, y = y + size - 6 } },
            text = badge or "DETECT",
            color = effect.last_known and { 190, 190, 190, 215 } or "white",
            font_size = effect.badge and 8 or 12, shadow = true, center_x = true,
            center_y = true, ttl = TTL, frame = true,
        })
    end
end
local function draw_selected_ring(unit, effects, options, selected_handle)
    -- Only the exact current selection gets a range ring. The frame-local
    -- command disappears on the next publication after deselection or a swap.
    if options.showRing == false or type(selected_handle) ~= "string" or
        safe_method(unit, "handle") ~= selected_handle then return end
    local radius_m = 0
    for _, effect in ipairs(effects) do
        if finite_number(effect.radius_m) and effect.radius_m > 0 then
            radius_m = math.max(radius_m, effect.radius_m)
        end
    end
    if radius_m <= 0 then return end
    gos.overlay.draw_circle("op:stealth_detect:ring", {
        at = { unit = unit, anchor = "origin" },
        world_radius = radius_m / METERS_PER_WORLD_UNIT,
        color = { 255, 166, 48, 230 },
        segments = 64, thickness = 2.0,
        ttl = TTL, frame = true,
    })
end

local function refresh_record(unit, now_ms)
    local handle = safe_method(unit, "handle")
    if type(handle) ~= "string" then return end
    local effects, status = detector_rows(unit)
    if status == "ready" or #effects > 0 then
        if #effects > 0 then
            effect_cache[handle] = { effects = effects, sample_ms = now_ms }
        else
            effect_cache[handle] = nil
        end
    elseif status ~= "pending" then
        effect_cache[handle] = nil
    end
end

function M.reset()
    effect_cache = {}
    refresh_cursor = 1
    bootstrap_refresh_passes = 2
end
function M.tick(options)
    options = type(options) == "table" and options or {}
    if options.visible == false then return end
    local world = gos.world()
    if not world then return end
    local selected_handle = safe_method(world.current_target, "handle")
    local units = collect_units(world, options, selected_handle)
    local max_units = finite_number(options.maxUnits) and
        math.max(1, math.floor(options.maxUnits)) or DEFAULT_MAX_UNITS
    local limit = math.min(#units, max_units)
    local now_ms = gos.time_ms() or 0
    local live = {}
    for index = 1, limit do
        local handle = safe_method(units[index], "handle")
        if type(handle) == "string" then live[handle] = true end
    end
    for handle in pairs(effect_cache) do
        if not live[handle] then effect_cache[handle] = nil end
    end

    local refreshed = {}
    local function refresh(index)
        if index < 1 or index > limit or refreshed[index] then return end
        refreshed[index] = true
        refresh_record(units[index], now_ms)
    end

    if bootstrap_refresh_passes > 0 then
        for index = 1, limit do refresh(index) end
        bootstrap_refresh_passes = bootstrap_refresh_passes - 1
        refresh_cursor = 2
    else
        refresh(1)
        local remaining = EFFECT_SCAN_BUDGET - 1
        while remaining > 0 and limit > 1 do
            if refresh_cursor < 2 or refresh_cursor > limit then refresh_cursor = 2 end
            refresh(refresh_cursor)
            refresh_cursor = refresh_cursor + 1
            remaining = remaining - 1
        end
    end
    for index = 1, limit do
        local unit = units[index]
        local handle = safe_method(unit, "handle")
        local cached = type(handle) == "string" and effect_cache[handle] or nil
        local effects = active_effects(cached, now_ms)
        if #effects > 0 then
            -- Icons are unconditional for every observed detector in this set.
            -- Selection gates only the circle, never the icon.
            draw_icons(unit, effects, options)
            draw_selected_ring(unit, effects, options, selected_handle)
        end
    end
end

function M.catalog()
    local out = {}
    for key, row in pairs(DETECTORS) do
        out[key] = {
            radius_m = row.radius_m,
            icon = row.icon,
            order = row.order,
            badge = row.badge,
            range_status = row.range_status,
        }
    end
    return out
end

return M
