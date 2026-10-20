local SCRIPT_ID = "combat_meter"
local Incoming = require("combat_meter.incoming")
local ActorLabels = require("ui.actor_labels")
local BUILD_ID = Incoming.build_id .. "-personal-defaults-20261007"
local MAX_ACTORS = 64
local MAX_BREAKDOWN = 64
local MAX_ABILITY_TARGETS = 16
local MAX_BATCHES_PER_TICK = 4
local COMPACT_ROWS = 5
local DETAIL_ABILITIES = 12
local DETAIL_TARGETS = 6
local TTL = 0.15

local function rgba(r, g, b, a)
    return r + g * 256 + b * 65536 + (a or 255) * 16777216
end

local function color_from_hex(text)
    local red, green, blue, alpha = tostring(text):match(
        "^#(%x%x)(%x%x)(%x%x)(%x%x)$")
    if not red then
        error("combat_meter background_color must be #RRGGBBAA")
    end
    return rgba(tonumber(red, 16), tonumber(green, 16), tonumber(blue, 16), tonumber(alpha, 16))
end

local function color_with_alpha(color, alpha)
    return color % 16777216 + alpha * 16777216
end

local C = {
    panel_alt = rgba(15, 20, 29, 244),
    rail = rgba(10, 14, 21, 250),
    header = rgba(20, 27, 38, 250),
    border = rgba(72, 86, 105, 225),
    text = rgba(235, 239, 245),
    muted = rgba(145, 156, 173),
    faint = rgba(91, 103, 121),
    gold = rgba(226, 188, 86),
    damage = rgba(211, 87, 66),
    healing = rgba(66, 188, 115),
    taken = rgba(209, 113, 65),
    cc = rgba(181, 126, 235),
    neutral = rgba(104, 126, 153),
    companion = rgba(151, 91, 194),
    selected = rgba(61, 116, 168),
    warning = rgba(236, 164, 66),
}

local COMBAT_STYLE_COLORS = {
    guardian = rgba(97, 75, 160), juggernaut = rgba(97, 75, 160),
    sentinel = rgba(222, 31, 38), marauder = rgba(222, 31, 38),
    sage = rgba(78, 176, 211), assassin = rgba(78, 176, 211),
    shadow = rgba(50, 81, 224), sorcerer = rgba(50, 81, 224),
    vanguard = rgba(116, 183, 44), powertech = rgba(116, 183, 44),
    commando = rgba(42, 144, 71), mercenary = rgba(42, 144, 71),
    gunslinger = rgba(201, 106, 16), operative = rgba(201, 106, 16),
    scoundrel = rgba(220, 223, 70), sniper = rgba(220, 223, 70),
}

local Settings = gos.settings.register(SCRIPT_ID, {
    title = "Combat Meter",
    version = 7,
    activation = {
        mode = "toggle",
        label = "Meter Toggle",
        default = "f5",
    },
    fields = {
        {
            key = "visible", type = "bool", label = "Visible",
            tooltip = "Show the combat meter overlay.", default = true,
        },
        {
            key = "show_class_colors", type = "bool", label = "Class Colors",
            tooltip = "Color player names and contribution bars by combat style.",
            default = true,
        },
        {
            key = "position_x", type = "int", label = "Position X",
            tooltip = "Horizontal screen position. Drag the meter header to update it.",
            default = 436, min = 0, max = 7680, step = 1,
        },
        {
            key = "position_y", type = "int", label = "Position Y",
            tooltip = "Vertical screen position. Drag the meter header to update it.",
            default = 448, min = 0, max = 4320, step = 1,
        },
        {
            key = "detail_position_x", type = "int", label = "Detail Position X",
            tooltip = "Horizontal position of the contributor detail window.",
            default = 575, min = 0, max = 7680, step = 1,
        },
        {
            key = "detail_position_y", type = "int", label = "Detail Position Y",
            tooltip = "Vertical position of the contributor detail window.",
            default = 271, min = 0, max = 4320, step = 1,
        },
        {
            key = "font_size", type = "int", label = "Font Size",
            tooltip = "Base combat meter font size in pixels. 16 px matches the default Core menu.",
            default = 16, min = 11, max = 18, step = 1,
        },
        {
            key = "transparent_mode", type = "bool", label = "Overlay Transparency",
            tooltip = "Hide main, detail, and popup backgrounds while keeping controls, bars, and text.",
            default = true,
        },
        {
            key = "background_color", type = "color", label = "Background Color",
            tooltip = "Combat meter window color and opacity. Set alpha to zero for bars and text only.",
            default = "#080B11EE",
        },
        {
            key = "diagnostics_logging", type = "bool", label = "Diagnostics Logging",
            tooltip = "Log script startup details.", default = false,
        },
    },
})

local cursor
local mode = "damage"
local view = "compact"
local selected_handle
local selected_ability_key
local drag
local font_delta = Settings.font_size - 13
local window_color
local window_alpha
local cc_tracker = Incoming.new_cc_tracker()
local player_identity
local resolution_cache
local incoming_page, incoming_filter = 0, 1
local capture_error, cc_error, metadata_error
local current_actor_epoch, current_actor_revision

local function row_name(row)
    return ActorLabels.text(row.actor_label, row.name or row.name_placeholder)
end

local function actor_color(actor)
    return Settings.show_class_colors and actor.class_color or actor.color
end

local function class_color(unit)
    return type(unit.combat_style) == "function" and
        COMBAT_STYLE_COLORS[unit:combat_style()] or nil
end

local function fresh_encounter(actor_epoch)
    local labels = ActorLabels.new(actor_epoch or current_actor_epoch, Incoming.history_capacity)
    return {
        labels = labels,
        state = "waiting",
        start_ms = nil,
        finished_at = nil,
        actors = {},
        actor_count = 0,
        dropped = 0,
        limited = false,
        timing_missing = false,
        damage_rows = nil,
        healing_rows = nil,
        damage_total = 0, healing_total = 0,
        incoming = Incoming.new(C.taken, labels),
    }
end

local encounter = fresh_encounter()

local function fit_bytes(text, limit)
    text = tostring(text or "")
    if #text <= limit then
        return text
    end
    local content_limit = math.max(0, limit - 3)
    local cut = utf8.offset(text, 0, content_limit + 1)
    return (cut and string.sub(text, 1, cut - 1) or string.sub(text, 1, content_limit)) .. "..."
end

local function number(value)
    return type(value) == "number" and value > 0 and value or nil
end

local function format_amount(value)
    value = math.max(0, value or 0)
    local suffix = ""
    local divisor = 1
    if value >= 1000000000000 then
        suffix, divisor = "T", 1000000000000
    elseif value >= 1000000000 then
        suffix, divisor = "B", 1000000000
    elseif value >= 1000000 then
        suffix, divisor = "M", 1000000
    elseif value >= 1000 then
        suffix, divisor = "K", 1000
    end
    if divisor == 1 then
        return string.format("%.0f", value)
    end
    local scaled = value / divisor
    return (scaled >= 100 and string.format("%.0f", scaled) or
        (scaled >= 10 and string.format("%.1f", scaled) or string.format("%.2f", scaled))) .. suffix
end

local function format_percent(value)
    return string.format("%.1f%%", math.max(0, value or 0))
end

local function duration_seconds()
    if type(encounter.start_ms) ~= "number" then
        return nil
    end
    local finish = encounter.state == "active" and gos.time_ms() or encounter.finished_at
    if type(finish) ~= "number" or finish < encounter.start_ms then
        return nil
    end
    return (finish - encounter.start_ms) / 1000
end

local function actor_total(actor, selected_mode)
    return selected_mode == "healing" and actor.healing or actor.damage
end

local function actor_rate(actor, selected_mode)
    local seconds = duration_seconds()
    if not seconds or seconds <= 0 then
        return nil
    end
    return actor_total(actor, selected_mode) / seconds
end

local function encounter_total(selected_mode)
    if selected_mode == "taken" then return encounter.incoming.total end
    return selected_mode == "healing" and encounter.healing_total or encounter.damage_total
end

local function resolve_unit(world, handle)
    local cached = resolution_cache and resolution_cache[handle]
    if cached ~= nil then return cached ~= false and cached or nil end
    local unit = world:resolve(handle)
    if resolution_cache then resolution_cache[handle] = unit or false end
    return unit
end

local function eligible_actor(world, handle)
    if type(handle) ~= "string" then
        return nil, nil, nil, false
    end
    local unit = resolve_unit(world, handle)
    if not unit then
        return nil, nil, nil, false
    end
    local player_handle = world.player and world.player:handle() or nil
    local unit_type = unit:type()
    if handle ~= player_handle and
       not (unit:reaction() == "friendly" and (unit_type == "player" or unit_type == "companion")) then
        return nil, nil, nil, true
    end
    return unit, unit_type, handle == player_handle, true
end

local function get_actor(world, handle, actor_epoch, source_name)
    local actor = encounter.actors[handle]
    local unit, unit_type, is_self, resolved = eligible_actor(world, handle)
    if not unit and (resolved or not actor) then return nil end
    local label = encounter.labels:track(handle, actor_epoch, source_name)
    if actor then actor.actor_label = label; return actor end
    if encounter.actor_count >= MAX_ACTORS then
        encounter.limited = true
        return nil
    end
    local placeholder = is_self and "You" or
        (unit_type == "companion" and "Observed companion" or "Observed player")
    actor = {
        handle = handle,
        actor_label = label,
        name_placeholder = placeholder,
        unit_type = unit_type,
        color = unit_type == "companion" and C.companion or C.neutral,
        class_color = unit_type == "player" and class_color(unit) or nil,
        damage = 0,
        healing = 0,
        damage_hits = 0,
        healing_hits = 0,
        damage_crits = 0,
        healing_crits = 0,
        damage_abilities = {},
        healing_abilities = {},
        damage_ability_count = 0,
        healing_ability_count = 0,
        damage_targets = {},
        healing_targets = {},
        damage_target_count = 0,
        healing_target_count = 0,
        damage_ability_rows = nil,
        healing_ability_rows = nil,
        damage_target_rows = nil,
        healing_target_rows = nil,
        activations = {},
        activation_count = 0,
    }
    encounter.actors[handle] = actor
    encounter.actor_count = encounter.actor_count + 1
    return actor
end

local function measured_event(event)
    if event.kind == "damage" then
        return number(event.effective_amount), "damage"
    elseif event.kind == "heal" then
        -- Core currently proves only SWTOR's displayed heal amount. There is no
        -- separate overheal field, so this meter never invents one.
        return number(event.amount), "healing"
    end
    return nil, nil
end

local function add_breakdown(map, count, key, name, amount, critical, limit, label, target_row)
    local row = map[key]
    if not row then
        if count >= (limit or MAX_BREAKDOWN) then
            encounter.limited = true
            return count, nil
        end
        row = { key = key, name = not target_row and name or nil,
            actor_label = label, name_placeholder = target_row and "Unresolved target" or nil,
            total = 0, hits = 0, crits = 0 }
        map[key] = row
        count = count + 1
    elseif row.name == "Unknown" and name ~= "Unknown" then
        row.name = name
    end
    row.total = row.total + amount
    row.hits = row.hits + 1
    if critical then
        row.crits = row.crits + 1
    end
    return count, row
end

local function target_identity(event)
    local handle = event.target_handle
    if type(handle) ~= "string" then return "target:unknown", nil end
    return handle, encounter.labels:track(handle, event.actor_epoch, event.target_name)
end

local function aggregate(event, world)
    if encounter.state ~= "active" then
        return
    end
    local amount, selected_mode = measured_event(event)
    if not amount then
        return
    end

    local actor = get_actor(world, event.source_handle, event.actor_epoch, event.source_name)
    if not actor then
        return
    end
    local is_healing = selected_mode == "healing"
    local total_key = is_healing and "healing" or "damage"
    local hits_key = is_healing and "healing_hits" or "damage_hits"
    local crits_key = is_healing and "healing_crits" or "damage_crits"
    encounter[total_key .. "_total"] = encounter[total_key .. "_total"] + amount
    actor[total_key] = actor[total_key] + amount
    actor[hits_key] = actor[hits_key] + 1
    if event.critical == true then
        actor[crits_key] = actor[crits_key] + 1
    end

    local ability_map = is_healing and actor.healing_abilities or actor.damage_abilities
    local ability_count_key = is_healing and "healing_ability_count" or "damage_ability_count"
    local ability_name = type(event.name) == "string" and event.name ~= "" and event.name or "Unknown"
    local ability_key = event.ability_handle or ("name:" .. ability_name)
    local ability_row
    actor[ability_count_key], ability_row = add_breakdown(
        ability_map, actor[ability_count_key], ability_key, ability_name, amount, event.critical == true)

    local target_key, target_label = target_identity(event)
    if ability_row then
        ability_row.targets = ability_row.targets or {}
        ability_row.target_count = ability_row.target_count or 0
        ability_row.target_count = add_breakdown(
            ability_row.targets, ability_row.target_count, target_key, nil,
            amount, event.critical == true, MAX_ABILITY_TARGETS, target_label, true)
        ability_row.target_rows = nil
    end

    local target_map = is_healing and actor.healing_targets or actor.damage_targets
    local target_count_key = is_healing and "healing_target_count" or "damage_target_count"
    actor[target_count_key] = add_breakdown(
        target_map, actor[target_count_key], target_key, nil, amount, event.critical == true, nil, target_label, true)
    if is_healing then
        actor.healing_ability_rows = nil
        actor.healing_target_rows = nil
    else
        actor.damage_ability_rows = nil
        actor.damage_target_rows = nil
    end
    encounter[selected_mode == "healing" and "healing_rows" or "damage_rows"] = nil
end

local function aggregate_activation(event, world)
    if encounter.state ~= "active" or event.kind ~= "ability" or
       event.action ~= "ability_activate" or type(event.ability_handle) ~= "string" then
        return
    end
    local actor = get_actor(world, event.source_handle, event.actor_epoch, event.source_name)
    if not actor then
        return
    end
    if not actor.activations[event.ability_handle] then
        if actor.activation_count >= MAX_BREAKDOWN then
            encounter.limited = true
            return
        end
        actor.activation_count = actor.activation_count + 1
    end
    actor.activations[event.ability_handle] = (actor.activations[event.ability_handle] or 0) + 1
    local name = type(event.name) == "string" and event.name ~= "" and event.name or nil
    if name then
        local damage_row = actor.damage_abilities[event.ability_handle]
        if damage_row and damage_row.name == "Unknown" then
            damage_row.name = name
        end
        local healing_row = actor.healing_abilities[event.ability_handle]
        if healing_row and healing_row.name == "Unknown" then
            healing_row.name = name
        end
    end
end

local function begin_encounter(event)
    encounter = fresh_encounter(event.actor_epoch)
    encounter.state = "active"
    encounter.start_ms = event.timestamp
    if type(encounter.start_ms) ~= "number" then
        encounter.timing_missing = true
    end
    selected_handle = nil
    selected_ability_key = nil
    view = "compact"
    incoming_page = 0
end

local function process_event(event, world, player_handle, now)
    if current_actor_epoch and event.actor_epoch ~= current_actor_epoch then return end
    if type(player_handle) == "string" and event.kind == "combat" and event.source_handle == player_handle then
        if event.action == "enter_combat" then
            if encounter.state ~= "active" then
                begin_encounter(event)
            end
        elseif event.action == "exit_combat" and encounter.state == "active" then
            encounter.state = "complete"
            encounter.finished_at = event.timestamp
            if type(encounter.finished_at) ~= "number" then
                encounter.timing_missing = true
            end
        end
        return
    end
    if ((encounter.state == "waiting" or encounter.state == "complete") and
        Incoming.is_incoming(event, player_handle)) or
       ((encounter.state == "waiting" or encounter.labels.epoch ~= current_actor_epoch) and measured_event(event) and
        eligible_actor(world, event.source_handle)) then
        local dropped = encounter.dropped
        begin_encounter(event)
        encounter.dropped = dropped
        encounter.observed_start = true
    end
    if encounter.state == "active" then
        Incoming.consume(encounter.incoming, event, player_handle)
    end
    aggregate_activation(event, world)
    aggregate(event, world)
end

local function observe_player(handle)
    if type(handle) ~= "string" then return end
    if player_identity and player_identity ~= handle then
        encounter = fresh_encounter()
        selected_handle, selected_ability_key, view = nil, nil, "compact"
        cc_tracker = Incoming.new_cc_tracker()
        incoming_page = 0
    end
    player_identity = handle
end

local function poll_events()
    local world, player_handle, now
    for _ = 1, MAX_BATCHES_PER_TICK do
        local batch = gos.events.combat(cursor)
        cursor = batch.cursor
        if current_actor_epoch and batch.actor_epoch and current_actor_epoch ~= batch.actor_epoch then
            if encounter.state == "active" then
                encounter.state, encounter.finished_at, encounter.timing_missing = "complete", nil, true
            end
            cc_tracker = Incoming.new_cc_tracker()
        end
        current_actor_epoch, current_actor_revision = batch.actor_epoch, batch.actor_revision
        local events = batch.events or {}
        if #events > 0 and not world then
            world, now = gos.world(), gos.time_ms()
            player_handle = world.player and world.player:handle() or nil
            observe_player(player_handle)
            resolution_cache = {} -- <= 512 source/target handles in four bounded batches.
        end
        if (batch.dropped or 0) > 0 then
            encounter.dropped = encounter.dropped + batch.dropped
        end
        for index = 1, #events do process_event(events[index], world, player_handle, now) end
        if not batch.more then break end
    end
    resolution_cache = nil -- Never retain generation-bound units across ticks.
end

local function sample_self_cc()
    local world, now = gos.world(), gos.time_ms()
    local player = world.player
    observe_player(player and player:handle() or nil)
    local changes = Incoming.sample_cc(cc_tracker, player, now)
    if not changes then return end
    for _, change in ipairs(changes) do
        if change.action == "cc_observed" and encounter.state ~= "active" then
            local dropped = encounter.dropped
            begin_encounter({ timestamp = now, actor_epoch = current_actor_epoch })
            encounter.observed_start, encounter.dropped = true, dropped
        end
        if encounter.state == "active" then Incoming.record_cc(encounter.incoming, change) end
    end
end

local function sorted_actors(selected_mode)
    if selected_mode == "taken" then return Incoming.sources(encounter.incoming) end
    local cache_key = selected_mode == "healing" and "healing_rows" or "damage_rows"
    if not encounter[cache_key] or encounter[cache_key .. "_names"] ~= encounter.labels.version then
        encounter[cache_key .. "_names"] = encounter.labels.version
        local rows = {}
        for _, actor in pairs(encounter.actors) do
            if actor_total(actor, selected_mode) > 0 then
                rows[#rows + 1] = actor
            end
        end
        table.sort(rows, function(left, right)
            local left_total = actor_total(left, selected_mode)
            local right_total = actor_total(right, selected_mode)
            if left_total ~= right_total then
                return left_total > right_total
            end
            if row_name(left) ~= row_name(right) then
                return row_name(left) < row_name(right)
            end
            return left.handle < right.handle
        end)
        encounter[cache_key] = rows
    end
    return encounter[cache_key]
end

local function sort_breakdown_map(map)
    local rows = {}
    for _, row in pairs(map) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(left, right)
        if left.total ~= right.total then
            return left.total > right.total
        end
        if row_name(left) ~= row_name(right) then
            return row_name(left) < row_name(right)
        end
        return left.key < right.key
    end)
    return rows
end

local function bounded_breakdown(rows, limit)
    if #rows <= limit then
        return rows
    end
    rows.views = rows.views or {}
    if rows.views[limit] then return rows.views[limit] end
    local visible = {}
    for index = 1, limit - 1 do
        visible[index] = rows[index]
    end
    local other = { key = "other", name = "Other", total = 0, hits = 0, crits = 0 }
    for index = limit, #rows do
        other.total = other.total + rows[index].total
        other.hits = other.hits + rows[index].hits
        other.crits = other.crits + rows[index].crits
    end
    visible[limit] = other
    rows.views[limit] = visible
    return visible
end

local function sorted_breakdown(actor, selected_mode, targets, limit)
    local map
    local cache_key
    if selected_mode == "healing" then
        map = targets and actor.healing_targets or actor.healing_abilities
        cache_key = targets and "healing_target_rows" or "healing_ability_rows"
    else
        map = targets and actor.damage_targets or actor.damage_abilities
        cache_key = targets and "damage_target_rows" or "damage_ability_rows"
    end
    local rows = actor[cache_key]
    local name_revision = targets and encounter.labels.version or -1
    if not rows or actor[cache_key .. "_names"] ~= name_revision then
        actor[cache_key .. "_names"] = name_revision
        rows = sort_breakdown_map(map)
        actor[cache_key] = rows
    end
    return bounded_breakdown(rows, limit)
end

local function sorted_ability_targets(row, limit)
    if not row.target_rows or row.target_names_revision ~= encounter.labels.version then
        row.target_names_revision = encounter.labels.version
        row.target_rows = sort_breakdown_map(row.targets or {})
    end
    return bounded_breakdown(row.target_rows, limit)
end

local function draw_rect(id, x, y, width, height, color, rounding)
    gos.overlay.draw_rect(id, {
        at = { screen = { x = x, y = y } }, width = width, height = height,
        filled = true, fill_color = color, border = true, border_color = C.border,
        rounding = rounding or 0, ttl = TTL, frame = true,
    })
end

local function draw_surface(id, x, y, width, height, color, rounding)
    gos.overlay.draw_rect(id, {
        at = { screen = { x = x, y = y } }, width = width, height = height,
        filled = true, fill_color = color, border = window_alpha > 0,
        border_color = color_with_alpha(C.border, window_alpha),
        rounding = rounding or 0, ttl = TTL, frame = true,
    })
end

local function draw_outline(id, x, y, width, height, color, rounding)
    gos.overlay.draw_rect(id, {
        at = { screen = { x = x, y = y } }, width = width, height = height,
        filled = false, border = true, border_color = color or C.gold,
        rounding = rounding or 0, ttl = TTL, frame = true,
    })
end

local function draw_bar(id, x, y, width, height, value, color)
    gos.overlay.draw_bar(id, {
        at = { screen = { x = x, y = y } }, width = width, height = height,
        value = math.max(0, math.min(1, value or 0)), fill_color = color,
        bg_color = window_alpha == 0 and color_with_alpha(C.panel_alt, 0) or C.panel_alt,
        border = false, rounding = 2, ttl = TTL, frame = true,
    })
end

local function draw_text(id, x, y, text, color, size, center)
    gos.overlay.draw_text(id, {
        at = { screen = { x = x, y = y } }, text = fit_bytes(text, 63),
        color = color or C.text, font_size = (size or 13) + font_delta, shadow = true,
        center_x = center == true, ttl = TTL, frame = true,
    })
end

local function interact(id, x, y, width, height)
    return gos.overlay.interact(id, {
        x = x, y = y, width = width, height = height, ttl = TTL,
    })
end

local function viewport_size()
    local viewport = gos.overlay.viewport()
    if type(viewport) == "table" and viewport.available == true and
       type(viewport.width) == "number" and type(viewport.height) == "number" and
       viewport.width > 0 and viewport.height > 0 then
        return viewport.width, viewport.height
    end
    return nil, nil
end

local function clamp_position(x, y, width, height, viewport_width, viewport_height)
    local max_x = viewport_width and math.max(0, viewport_width - width) or nil
    local max_y = viewport_height and math.max(0, viewport_height - height) or nil
    x = math.max(0, max_x and math.min(x, max_x) or x)
    y = math.max(0, max_y and math.min(y, max_y) or y)
    return x, y
end

local function persist_position(x, y, x_key, y_key)
    local px = math.max(0, math.floor(x + 0.5))
    local py = math.max(0, math.floor(y + 0.5))
    local ok_x, error_x = gos.settings.set(SCRIPT_ID, x_key, px)
    local ok_y, error_y = gos.settings.set(SCRIPT_ID, y_key, py)
    if not ok_x or not ok_y then
        gos.log.warn("[combat-meter] position save failed: " .. tostring(error_x or error_y))
    end
end

local function update_drag(id, x, y, width, height, x_key, y_key,
                           viewport_width, viewport_height)
    local state = interact(id, x, y, width, 34)
    if state.pressed then
        drag = { id = id, dx = state.mouse_x - x, dy = state.mouse_y - y, x = x, y = y }
    end
    if drag and drag.id == id and (state.down or state.released) then
        drag.x, drag.y = clamp_position(
            state.mouse_x - drag.dx, state.mouse_y - drag.dy,
            width, height, viewport_width, viewport_height)
    end
    if drag and drag.id == id and state.released then
        persist_position(drag.x, drag.y, x_key, y_key)
        x, y = drag.x, drag.y
        drag = nil
    elseif drag and drag.id == id then
        x, y = drag.x, drag.y
    end
    return x, y
end

local function status_text()
    local seconds = duration_seconds()
    local duration = seconds and string.format("%.1fs", seconds) or "--"
    if encounter.state == "active" then
        return (encounter.observed_start and "OBSERVED  " or "LIVE  ") .. duration
    elseif encounter.state == "complete" then
        return "COMPLETE  " .. duration
    end
    return "WAITING FOR COMBAT"
end

local function warning_text()
    if capture_error then
        return "CAPTURE STOPPED - see Lua console; reload scripts"
    elseif metadata_error then
        return "ACTOR METADATA STOPPED - see Lua console; reload scripts"
    elseif type(gos.actor_names) ~= "function" then
        return "ACTOR NAMES: load the updated Core"
    elseif encounter.labels.limited then
        return "ACTOR LABEL LIMIT - received totals retained"
    elseif encounter.dropped > 0 then
        return "INCOMPLETE - " .. tostring(encounter.dropped) .. " events dropped"
    elseif cc_error then
        return "CC SAMPLER STOPPED - see Lua console; reload scripts"
    elseif encounter.timing_missing then
        return "INCOMPLETE - combat boundary timestamp missing"
    elseif encounter.incoming.invalid_damage > 0 then
        return "INCOMPLETE - incoming damage amount unavailable"
    elseif encounter.incoming.untimed > 0 then
        return "INCOMPLETE - incoming event timestamps missing"
    elseif encounter.limited then
        return "INCOMPLETE - bounded model limit reached"
    end
    return nil
end

local TAB_MODES = { "damage", "healing", "taken" }
local TAB_LABELS = { "Damage Done", "Healing Done", "Taken to Me" }
local function update_tabs(x, y, width)
    local cell = math.floor(width / 3)
    local damage_state = interact("cm:damage", x, y, cell, 28)
    local healing_state = interact("cm:healing", x + cell, y, cell, 28)
    local taken_state = interact("cm:taken", x + cell * 2, y, width - cell * 2, 28)
    local next_mode = damage_state.clicked and "damage" or
        (healing_state.clicked and "healing" or (taken_state.clicked and "taken" or mode))
    if next_mode ~= mode then
        mode, selected_ability_key = next_mode, nil
        if mode == "taken" then selected_handle = nil end
    end
    return damage_state, healing_state, taken_state
end

local function draw_tabs(x, y, width, damage_state, healing_state, taken_state)
    local cell = math.floor(width / 3)
    local states = { damage_state, healing_state, taken_state }
    for index = 1, 3 do
        local sx, sw = x + (index - 1) * cell, index == 3 and width - cell * 2 or cell
        if mode == TAB_MODES[index] then
            draw_rect("cm:tab_active", sx, y, sw, 28, C[mode], 2)
        end
        draw_text("cm:tt" .. (index == 1 and "d" or (index == 2 and "h" or "t")),
            sx + sw * 0.5, y + 6, TAB_LABELS[index], states[index].hovered and C.gold or C.text, 13, true)
    end
    -- One active surface + three texts: same four draw commands as the old tabs.
end

local function draw_hover(actor, right_x, left_x, y, viewport_width, viewport_height)
    local ability_rows = sorted_breakdown(actor, mode, false, 5)
    local target_rows = sorted_breakdown(actor, mode, true, 3)
    local width = 310
    local height = 88 + #ability_rows * 22 + 25 + #target_rows * 22
    local x = right_x
    if viewport_width and x + width > viewport_width and left_x >= 0 then
        x = left_x
    end
    x, y = clamp_position(x, y, width, height, viewport_width, viewport_height)
    draw_surface("cm:pop", x, y, width, height, window_color, 4)
    local color = actor_color(actor)
    draw_text("cm:popn", x + 10, y + 8, fit_bytes(row_name(actor), 34), color, 15)
    local total = actor_total(actor, mode)
    local rate = actor_rate(actor, mode)
    local encounter_value = encounter_total(mode)
    draw_text("cm:popm", x + 10, y + 29,
        format_amount(total) .. (mode == "healing" and " healing" or " damage") ..
        "  |  " .. (rate and format_amount(rate) or "--") ..
        (mode == "healing" and " HPS" or " DPS") .. "  |  " ..
        format_percent(encounter_value > 0 and total * 100 / encounter_value or 0),
        C.text, 12)
    draw_text("cm:pops", x + 10, y + 51, "Abilities", C.gold, 12)
    local row_y = y + 68
    for index, row in ipairs(ability_rows) do
        draw_bar("cm:pa" .. index, x + 8, row_y, width - 16, 19,
            total > 0 and row.total / total or 0, color)
        draw_text("cm:pan" .. index, x + 14, row_y + 2, fit_bytes(row_name(row), 27), C.text, 12)
        draw_text("cm:pav" .. index, x + 260, row_y + 2,
            format_amount(row.total) .. "  " .. format_percent(total > 0 and row.total * 100 / total or 0),
            C.text, 12, true)
        row_y = row_y + 22
    end
    draw_text("cm:popt", x + 10, row_y + 3, "Targets", C.gold, 12)
    row_y = row_y + 25
    for index, row in ipairs(target_rows) do
        draw_bar("cm:pt" .. index, x + 8, row_y, width - 16, 19,
            total > 0 and row.total / total or 0, color)
        draw_text("cm:ptn" .. index, x + 14, row_y + 2, fit_bytes(row_name(row), 27), C.text, 12)
        draw_text("cm:ptv" .. index, x + 260, row_y + 2,
            format_amount(row.total) .. "  " .. format_percent(total > 0 and row.total * 100 / total or 0),
            C.text, 12, true)
        row_y = row_y + 22
    end
    draw_text("cm:poph", x + 10, row_y + 3, "Click contributor for details", C.faint, 11)
end

local function compact_layout()
    local rows = sorted_actors(mode)
    local visible = math.min(COMPACT_ROWS, #rows)
    local warning = warning_text()
    local body_rows = math.max(1, visible)
    local height = 34 + 28 + 20 + body_rows * 29 + (mode == "taken" and 27 or 0) + (warning and 24 or 6)
    return rows, visible, warning, height
end

local function draw_compact(x, y, viewport_width, viewport_height)
    local width = 360
    local rows, visible, warning, height = compact_layout()
    x, y = clamp_position(x, y, width, height, viewport_width, viewport_height)
    x, y = update_drag("cm:drag", x, y, width, height,
        "position_x", "position_y", viewport_width, viewport_height)
    local damage_state, healing_state, taken_state = update_tabs(x, y + 34, width)
    rows, visible, warning, height = compact_layout()
    x, y = clamp_position(x, y, width, height, viewport_width, viewport_height)

    local reset = interact("cm:reset", x + width - 46, y + 3, 42, 27)
    if reset.clicked then
        encounter = fresh_encounter()
        selected_handle = nil
        selected_ability_key = nil
        rows, visible, warning, height = compact_layout()
    end

    if mode == "taken" then
        local open = interact("cm:taken_open", x + width - 72, y + height - (warning and 51 or 33), 66, 24)
        if open.clicked then
            selected_handle, selected_ability_key, view = nil, nil, "detail"
            return true
        end
    end
    local row_states = {}
    local hovered_actor
    local hovered_y
    local interaction_y = y + 82
    for index = 1, visible do
        local actor = rows[index]
        local state = interact("cm:r" .. index, x + 6, interaction_y, width - 12, 26)
        row_states[index] = state
        if state.clicked then
            selected_handle = actor.handle
            selected_ability_key = nil
            view = "detail"
            return true
        end
        if state.hovered then
            hovered_actor = actor
            hovered_y = interaction_y
        end
        interaction_y = interaction_y + 29
    end

    draw_surface("cm:bg", x, y, width, height, window_color, 5)
    draw_surface("cm:head", x, y, width, 34, color_with_alpha(C.header, window_alpha), 5)
    draw_text("cm:title", x + 12, y + 7, "Combat Meter", C.gold, 16)
    draw_text("cm:state", x + width - 125, y + 9, status_text(), C.muted, 12, true)
    draw_text("cm:reset_t", x + width - 25, y + 9, "Reset",
        reset.hovered and C.text or C.muted, 11, true)
    draw_tabs(x, y + 34, width, damage_state, healing_state, taken_state)

    local total = encounter_total(mode)
    draw_text("cm:cols", x + 10, y + 67, mode == "taken" and "#  Attacker" or "#  Contributor", C.muted, 11)
    draw_text("cm:colv", x + 236, y + 67,
        mode == "taken" and "Taken" or (mode == "healing" and "Healing Done" or "Damage Done"), C.muted, 11, true)
    draw_text("cm:colr", x + 286, y + 67, mode == "taken" and "DTPS" or (mode == "healing" and "HPS" or "DPS"), C.muted, 11, true)
    draw_text("cm:colp", x + 337, y + 67, "%", C.muted, 11, true)

    local row_y = y + 82
    local max_total = rows[1] and actor_total(rows[1], mode) or 0
    for index = 1, visible do
        local actor = rows[index]
        local state = row_states[index] or {}
        local actor_value = actor_total(actor, mode)
        local color = actor_color(actor)
        draw_bar("cm:rb" .. index, x + 6, row_y, width - 12, 26,
            max_total > 0 and actor_value / max_total or 0, color)
        if state.hovered then
            draw_outline("cm:rho" .. index, x + 6, row_y, width - 12, 26, C.gold, 2)
        end
        draw_text("cm:rr" .. index, x + 12, row_y + 5, tostring(index), C.muted, 12)
        draw_text("cm:rn" .. index, x + 34, row_y + 4,
            fit_bytes(row_name(actor), 20), color, 14)
        local rate = actor_rate(actor, mode)
        draw_text("cm:rv" .. index, x + 236, row_y + 5,
            format_amount(actor_value), C.text, 12, true)
        draw_text("cm:rrate" .. index, x + 286, row_y + 5,
            rate and format_amount(rate) or "--", C.text, 12, true)
        draw_text("cm:rp" .. index, x + 337, row_y + 5,
            format_percent(total > 0 and actor_value * 100 / total or 0), C.text, 12, true)
        row_y = row_y + 29
    end
    if visible == 0 then
        draw_text("cm:empty", x + width * 0.5, row_y + 5, "No combat data yet", C.faint, 12, true)
    end
    if mode == "taken" then
        local footer_y = y + height - (warning and 46 or 28)
        local incoming = encounter.incoming
        draw_text("cm:taken_summary", x + 10, footer_y,
            format_amount(incoming.total) .. " taken | CC obs " .. incoming.cc_observations ..
            " | Int " .. incoming.interrupts, C.muted, 11)
        draw_text("cm:taken_open_t", x + width - 38, footer_y, "Details", C.gold, 11, true)
    end
    if warning then
        draw_text("cm:foot", x + 10, y + height - 18, warning, C.warning, 11)
    end
    if hovered_actor and view == "compact" and mode ~= "taken" then
        draw_hover(hovered_actor, x + width + 8, x - 318, hovered_y,
            viewport_width, viewport_height)
    end
    return false
end

local function selected_actor(rows)
    local previous = selected_handle
    if selected_handle then
        for _, actor in ipairs(rows) do
            if actor.handle == selected_handle then
                return actor
            end
        end
    end
    selected_handle = rows[1] and rows[1].handle or nil
    if selected_handle ~= previous then
        selected_ability_key = nil
    end
    return rows[1]
end

local function detail_model()
    local actor_rows = sorted_actors(mode)
    local actor = selected_actor(actor_rows)
    local ability_rows = actor and sorted_breakdown(actor, mode, false, DETAIL_ABILITIES) or {}
    local target_rows = actor and sorted_breakdown(actor, mode, true, DETAIL_TARGETS) or {}
    local ability
    if selected_ability_key then
        for _, row in ipairs(ability_rows) do
            if row.key == selected_ability_key and row.key ~= "other" then
                ability = row
                break
            end
        end
        if not ability then
            selected_ability_key = nil
        end
    end
    return actor_rows, actor, ability_rows, target_rows, ability
end

local function detail_layout(actor_rows, ability_rows, target_rows, ability, warning)
    local actor_bottom = 70 + math.min(COMPACT_ROWS, #actor_rows) * 35
    local table_bottom = math.max(
        260,
        160 + #ability_rows * 25,
        160 + #target_rows * 27,
        actor_bottom)
    local inspector_y
    local content_bottom = table_bottom
    if ability then
        inspector_y = content_bottom + 10
        content_bottom = inspector_y + 104
    end
    return content_bottom + (warning and 26 or 12), inspector_y
end

local function update_ability_selection(rows, x, y, width, row_height)
    if #rows == 0 then
        return nil, nil
    end
    local state = interact("cm:abilities", x, y, width, #rows * row_height)
    local index
    if state.hovered or state.clicked then
        index = math.floor((state.mouse_y - y) / row_height) + 1
        if index < 1 or index > #rows then
            index = nil
        end
    end
    if state.clicked and index and rows[index].key ~= "other" then
        selected_ability_key = rows[index].key
    end
    return state, index
end

local function draw_ability_rows(rows, actor_total_value, actor_color,
                                 x, y, width, row_height, hovered_index)
    local row_y = y
    for index, row in ipairs(rows) do
        draw_bar("cm:sb" .. index, x, row_y, width, row_height - 2,
            actor_total_value > 0 and row.total / actor_total_value or 0, actor_color)
        if row.key == selected_ability_key or index == hovered_index then
            draw_outline("cm:so" .. index, x, row_y, width, row_height - 2,
                row.key == selected_ability_key and C.gold or C.text, 2)
        end
        draw_text("cm:sn" .. index, x + 8, row_y + 4,
            tostring(index) .. "  " .. fit_bytes(row_name(row), 27), C.text, 12)
        local crit = row.hits > 0 and row.crits * 100 / row.hits or 0
        draw_text("cm:sv" .. index, x + 306, row_y + 4,
            format_amount(row.total), C.text, 12, true)
        draw_text("cm:ss" .. index, x + 354, row_y + 4,
            format_percent(actor_total_value > 0 and row.total * 100 / actor_total_value or 0),
            C.text, 11, true)
        draw_text("cm:sc" .. index, x + 405, row_y + 4,
            tostring(row.hits) .. " / " .. format_percent(crit), C.muted, 11, true)
        row_y = row_y + row_height
    end
end

local function draw_target_rows(rows, actor_total_value, actor_color, x, y, width)
    local row_y = y
    for index, row in ipairs(rows) do
        draw_bar("cm:tb" .. index, x, row_y, width, 23,
            actor_total_value > 0 and row.total / actor_total_value or 0, actor_color)
        draw_text("cm:tn" .. index, x + 8, row_y + 4,
            tostring(index) .. "  " .. fit_bytes(row_name(row), 16), C.text, 12)
        draw_text("cm:tv" .. index, x + 180, row_y + 4,
            format_amount(row.total) .. "  " ..
            format_percent(actor_total_value > 0 and row.total * 100 / actor_total_value or 0),
            C.text, 11, true)
        row_y = row_y + 27
    end
end

local function draw_ability_inspector(actor, row, x, y, width)
    local color = actor_color(actor)
    draw_surface("cm:inspector", x, y, width, 104,
        color_with_alpha(C.panel_alt, window_alpha), 4)
    draw_text("cm:iname", x + 10, y + 8, fit_bytes(row_name(row), 38), color, 15)
    local seconds = duration_seconds()
    local rate = seconds and seconds > 0 and row.total / seconds or nil
    local casts
    if type(row.key) == "string" and string.sub(row.key, 1, 8) == "ability:" then
        casts = actor.activations[row.key] or 0
    end
    local normal = math.max(0, row.hits - row.crits)
    local crit_rate = row.hits > 0 and row.crits * 100 / row.hits or 0
    draw_text("cm:im1", x + 10, y + 31,
        (mode == "healing" and "Healing Done  " or "Damage Done  ") .. format_amount(row.total) ..
        "  |  " .. (mode == "healing" and "HPS  " or "DPS  ") ..
        (rate and format_amount(rate) or "--") .. "  |  Share  " ..
        format_percent(actor_total(actor, mode) > 0 and row.total * 100 / actor_total(actor, mode) or 0),
        C.text, 12)
    draw_text("cm:im2", x + 10, y + 52,
        "Casts  " .. (casts ~= nil and tostring(casts) or "--") ..
        "  |  Hits  " .. tostring(row.hits) .. "  |  " ..
        (mode == "healing" and "Normal Heals  " or "Normal Hits  ") .. tostring(normal),
        C.text, 12)
    draw_text("cm:im3", x + 10, y + 73,
        (mode == "healing" and "Critical Heals  " or "Critical Hits  ") .. tostring(row.crits) ..
        "  |  Crit Rate  " .. format_percent(crit_rate), C.text, 12)

    local targets = sorted_ability_targets(row, 3)
    local target_x = x + 420
    draw_text("cm:ith", target_x, y + 9, "Targets", C.gold, 12)
    local target_y = y + 28
    for index, target in ipairs(targets) do
        draw_bar("cm:itb" .. index, target_x, target_y, width - 430, 18,
            row.total > 0 and target.total / row.total or 0, color)
        draw_text("cm:itn" .. index, target_x + 6, target_y + 2,
            fit_bytes(row_name(target), 14), C.text, 11)
        draw_text("cm:itv" .. index, x + width - 42, target_y + 2,
            format_amount(target.total) .. "  " ..
            format_percent(row.total > 0 and target.total * 100 / row.total or 0),
            C.text, 10, true)
        target_y = target_y + 22
    end
end

local function draw_done_detail(x, y, viewport_width, viewport_height)
    local width = 880
    local actor_rows, actor, ability_rows, target_rows, ability = detail_model()
    local warning = warning_text()
    local height = detail_layout(actor_rows, ability_rows, target_rows, ability, warning)
    x, y = clamp_position(x, y, width, height, viewport_width, viewport_height)
    x, y = update_drag("cm:detail_drag", x, y, width, height,
        "detail_position_x", "detail_position_y", viewport_width, viewport_height)

    local damage_state, healing_state, taken_state = update_tabs(x + 200, y + 34, width - 200)
    if mode == "taken" then return false end
    actor_rows, actor, ability_rows, target_rows, ability = detail_model()

    local actor_states = {}
    local actor_y = y + 70
    for index = 1, math.min(COMPACT_ROWS, #actor_rows) do
        local state = interact("cm:r" .. index, x + 8, actor_y, 184, 32)
        actor_states[index] = state
        if state.clicked then
            selected_handle = actor_rows[index].handle
            selected_ability_key = nil
        end
        actor_y = actor_y + 35
    end
    actor_rows, actor, ability_rows, target_rows, ability = detail_model()

    local _, hovered_ability = update_ability_selection(
        ability_rows, x + 218, y + 160, 430, 25)
    actor_rows, actor, ability_rows, target_rows, ability = detail_model()
    local inspector_y
    height, inspector_y = detail_layout(actor_rows, ability_rows, target_rows, ability, warning)
    x, y = clamp_position(x, y, width, height, viewport_width, viewport_height)

    local close = interact("cm:close", x + width - 36, y + 3, 32, 27)
    if close.clicked then
        view = "compact"
        selected_ability_key = nil
        return true
    end

    draw_surface("cm:bg", x, y, width, height, window_color, 5)
    draw_surface("cm:head", x, y, width, 34, color_with_alpha(C.header, window_alpha), 5)
    draw_surface("cm:rail", x, y + 34, 200, height - 34,
        color_with_alpha(C.rail, window_alpha), 0)
    draw_text("cm:title", x + 14, y + 7, "Combat Meter", C.gold, 16)
    draw_text("cm:state", x + width - 130, y + 9, status_text(), C.muted, 12, true)
    draw_text("cm:close_t", x + width - 20, y + 7, "X",
        close.hovered and C.text or C.muted, 15, true)
    draw_tabs(x + 200, y + 34, width - 200, damage_state, healing_state, taken_state)

    draw_text("cm:actors_h", x + 12, y + 46, "Observed contributors", C.gold, 12)
    local total = encounter_total(mode)
    local max_total = actor_rows[1] and actor_total(actor_rows[1], mode) or 0
    actor_y = y + 70
    for index = 1, math.min(COMPACT_ROWS, #actor_rows) do
        local row = actor_rows[index]
        local state = actor_states[index] or {}
        local value = actor_total(row, mode)
        local color = actor_color(row)
        draw_bar("cm:ab" .. index, x + 8, actor_y, 184, 30,
            max_total > 0 and value / max_total or 0, color)
        if row.handle == selected_handle or state.hovered then
            draw_outline("cm:ao" .. index, x + 8, actor_y, 184, 30,
                row.handle == selected_handle and C.gold or C.text, 2)
        end
        draw_text("cm:an" .. index, x + 15, actor_y + 4,
            tostring(index) .. "  " .. fit_bytes(row_name(row), 19), color, 12)
        draw_text("cm:av" .. index, x + 150, actor_y + 16,
            format_amount(value) .. "  " .. format_percent(total > 0 and value * 100 / total or 0), C.muted, 10, true)
        actor_y = actor_y + 35
    end
    if warning then
        draw_text("cm:foot", x + 12, y + height - 19, warning, C.warning, 11)
    end

    if not actor then
        draw_text("cm:empty", x + 218, y + 95,
            "No observed contributor data for this tab.", C.muted, 14)
        return
    end
    local actor_value = actor_total(actor, mode)
    local color = actor_color(actor)
    draw_text("cm:who", x + 218, y + 72, row_name(actor), color, 18)
    local rate = actor_rate(actor, mode)
    draw_text("cm:sum_l", x + 218, y + 99,
        mode == "healing" and "Healing Done" or "Damage Done", C.muted, 12)
    draw_text("cm:sum", x + 310, y + 98, format_amount(actor_value), C.text, 14)
    draw_text("cm:rate_l", x + 382, y + 99,
        mode == "healing" and "HPS" or "DPS", C.muted, 12)
    draw_text("cm:rate", x + 418, y + 98,
        rate and format_amount(rate) or "--", C.text, 14)

    draw_text("cm:spells_h", x + 218, y + 126, "Abilities - click for details", C.gold, 13)
    draw_text("cm:spells_name", x + 218, y + 145, "#  Ability", C.muted, 11)
    draw_text("cm:spells_value", x + 524, y + 145,
        mode == "healing" and "Healing" or "Damage", C.muted, 11, true)
    draw_text("cm:spells_share", x + 572, y + 145, "%", C.muted, 11, true)
    draw_text("cm:spells_hitcrit", x + 623, y + 145, "Hits / Crit%", C.muted, 11, true)
    draw_ability_rows(ability_rows, actor_value, color,
        x + 218, y + 160, 430, 25, hovered_ability)

    draw_text("cm:targets_h", x + 658, y + 126, "Targets", C.gold, 13)
    draw_text("cm:targets_name", x + 658, y + 145, "#  Target", C.muted, 11)
    draw_text("cm:targets_value", x + 838, y + 145, "Done / %", C.muted, 11, true)
    draw_target_rows(target_rows, actor_value, color, x + 658, y + 160, 210)

    if ability and inspector_y then
        draw_ability_inspector(actor, ability, x + 218, y + inspector_y, 650)
    end
    return false
end

local function draw_taken_detail(x, y, viewport_width, viewport_height)
    local width, height = 880, 644
    x, y = clamp_position(x, y, width, height, viewport_width, viewport_height)
    x, y = update_drag("cm:detail_drag", x, y, width, height,
        "detail_position_x", "detail_position_y", viewport_width, viewport_height)
    local damage_state, healing_state, taken_state = update_tabs(x + 200, y + 34, width - 200)
    if mode ~= "taken" then return false end
    local close = interact("cm:close", x + width - 36, y + 3, 32, 27)
    if close.clicked then view = "compact"; return true end
    local incoming, now = encounter.incoming, gos.time_ms()
    local sources = Incoming.sources(incoming)
    local all = interact("cm:taken_all", x + 244, y + 249, 78, 23)
    if all.clicked then selected_handle = nil end
    local source_states = {}
    for index = 1, math.min(5, #sources) do
        local state = interact("cm:r" .. index, x + 12, y + 277 + (index - 1) * 23, 310, 22)
        source_states[index] = state
        if state.clicked then selected_handle = sources[index].handle end
    end
    if selected_handle and not incoming.sources[selected_handle] then selected_handle = nil end
    local abilities, selected_total, source_name = Incoming.abilities(incoming, selected_handle)

    local filter_button = interact("cm:taken_filter", x + 417, y + 405, 205, 24)
    local previous = interact("cm:taken_prev", x + 638, y + 405, 40, 24)
    local next_page = interact("cm:taken_next", x + 822, y + 405, 40, 24)
    if filter_button.clicked then
        incoming_filter = incoming_filter % #Incoming.filters + 1
        incoming_page = 0
    end
    if previous.clicked then incoming_page = math.max(0, incoming_page - 1) end
    if next_page.clicked then incoming_page = incoming_page + 1 end
    local filter = Incoming.filters[incoming_filter]
    local events, event_total, page = Incoming.page(incoming, filter, incoming_page, 7, now)
    incoming_page = page

    draw_surface("cm:bg", x, y, width, height, window_color, 5)
    draw_surface("cm:head", x, y, width, 34, color_with_alpha(C.header, window_alpha), 5)
    draw_text("cm:title", x + 14, y + 7, "Combat Meter", C.gold, 16)
    draw_text("cm:state", x + width - 140, y + 9, status_text(), C.muted, 12, true)
    draw_text("cm:close_t", x + width - 20, y + 7, "X", close.hovered and C.text or C.muted, 15, true)
    draw_tabs(x + 200, y + 34, width - 200, damage_state, healing_state, taken_state)
    draw_text("cm:incoming_self", x + 14, y + 43, "SELF / INCOMING", C.taken, 11)
    local seconds = duration_seconds()
    draw_text("cm:incoming_title", x + 14, y + 73, "Damage Taken To Me", C.taken, 17)
    draw_text("cm:incoming_total", x + 346, y + 76,
        format_amount(incoming.total) .. " total | " ..
        (seconds and seconds > 0 and format_amount(incoming.total / seconds) or "--") .. " DTPS", C.text, 14)
    draw_text("cm:incoming_counts", x + 14, y + 103,
        "Damage rows " .. incoming.hits .. " | Zero " .. incoming.zero_hits .. " | Crits " .. incoming.crits, C.text, 12)
    draw_text("cm:incoming_controls", x + 462, y + 103,
        "CC observations " .. incoming.cc_observations .. " | Interrupts " .. incoming.interrupts, C.text, 12)

    -- Twenty-four reusable 2.5-second buckets: at most 24 columns + 24 labels.
    -- Markers summarize each bucket; hover reads exact counts. No guessed CC duration.
    local gx, gy, gw, gh = x + 14, y + 157, width - 28, 67
    local anchor = encounter.state == "complete" and encounter.finished_at or now
    local last = math.floor((type(anchor) == "number" and anchor or now) / Incoming.bucket_ms)
    local first = last - Incoming.bucket_count + 1
    local peak = 0
    for key = first, last do
        local bucket = Incoming.bucket(incoming, key)
        if bucket then peak = math.max(peak, bucket.damage) end
    end
    draw_text("cm:incoming_graph_title", gx, y + 130, "All sources - last 60s | C: CC observed | I: interruption", C.gold, 12)
    draw_surface("cm:incoming_graph", gx, gy, gw, gh, color_with_alpha(C.panel_alt, window_alpha), 2)
    local step = gw / Incoming.bucket_count
    for index = 1, Incoming.bucket_count do
        local bucket = Incoming.bucket(incoming, first + index - 1)
        if bucket then
            local bx = gx + (index - 1) * step + 2
            if bucket.damage > 0 and peak > 0 then
                local bh = math.max(1, gh * bucket.damage / peak)
                draw_rect("cm:incoming_b" .. index, bx, gy + gh - bh, step - 4, bh, C.taken, 1)
            end
            if bucket.cc > 0 or bucket.interrupts > 0 then
                local marker = bucket.cc > 0 and "C" or ""
                if bucket.interrupts > 0 then marker = marker .. (marker ~= "" and "/" or "") .. "I" end
                draw_text("cm:incoming_m" .. index, bx + (step - 4) * 0.5, gy + 4,
                    marker, bucket.interrupts > 0 and C.warning or C.cc, 9, true)
            end
        end
    end
    local chart_hover = interact("cm:taken_chart", gx, gy, gw, gh)
    local caption = "Damage per 2.5s | Peak " .. format_amount(peak) .. " | Hover a column for its values"
    if chart_hover.hovered then
        local index = math.max(0, math.min(Incoming.bucket_count - 1, math.floor((chart_hover.mouse_x - gx) / step)))
        local bucket = Incoming.bucket(incoming, first + index)
        caption = "Bucket: " .. format_amount(bucket and bucket.damage or 0) ..
            " damage | CC observed " .. (bucket and bucket.cc or 0) ..
            " | Interrupt events " .. (bucket and bucket.interrupts or 0)
    end
    draw_text("cm:incoming_graph_caption", gx, y + 229, caption, C.muted, 11)

    draw_text("cm:incoming_sources", x + 14, y + 254, "Sources - top 5 / " .. #sources, C.gold, 12)
    draw_text("cm:incoming_all", x + 282, y + 254, "All sources",
        (not selected_handle or all.hovered) and C.gold or C.muted, 11, true)
    draw_text("cm:incoming_abilities", x + 348, y + 254,
        fit_bytes(source_name or "All sources", 30) .. " - abilities (top 5)", C.gold, 12)
    local maximum = sources[1] and sources[1].damage or 0
    for index = 1, math.min(5, #sources) do
        local row, ry = sources[index], y + 277 + (index - 1) * 23
        draw_bar("cm:incoming_sb" .. index, x + 12, ry, 310, 21,
            maximum > 0 and row.damage / maximum or 0, C.taken)
        if selected_handle == row.handle or source_states[index].hovered then
            draw_outline("cm:incoming_so" .. index, x + 12, ry, 310, 21, C.gold, 1)
        end
        draw_text("cm:incoming_sn" .. index, x + 18, ry + 3, fit_bytes(row_name(row), 24), C.text, 11)
        draw_text("cm:incoming_sv" .. index, x + 283, ry + 3, format_amount(row.damage), C.text, 11, true)
    end
    for index = 1, math.min(5, #abilities) do
        local row, ry = abilities[index], y + 277 + (index - 1) * 23
        draw_bar("cm:incoming_ab" .. index, x + 346, ry, width - 360, 21,
            selected_total > 0 and row.total / selected_total or 0, C.taken)
        draw_text("cm:incoming_an" .. index, x + 352, ry + 3, fit_bytes(row_name(row), 36), C.text, 11)
        draw_text("cm:incoming_av" .. index, x + width - 82, ry + 3,
            format_amount(row.total) .. " / " .. format_percent(selected_total > 0 and row.total * 100 / selected_total or 0), C.text, 11, true)
    end
    if #sources == 0 then draw_text("cm:incoming_empty", x + 14, y + 284, "No incoming damage yet", C.muted, 12) end

    draw_text("cm:incoming_events_h", x + 14, y + 410, "History - all sources / receipt order", C.gold, 12)
    draw_text("cm:incoming_filter", x + 519, y + 410, Incoming.filter_labels[filter], C.gold, 11, true)
    draw_text("cm:incoming_prev", x + 658, y + 410, "<", previous.hovered and C.gold or C.text, 13, true)
    draw_text("cm:incoming_page", x + 752, y + 410,
        (page + 1) .. " / " .. math.max(1, math.ceil(event_total / 7)), C.muted, 11, true)
    draw_text("cm:incoming_next", x + 842, y + 410, ">", next_page.hovered and C.gold or C.text, 13, true)
    for index, event in ipairs(events) do
        local ry = y + 442 + (index - 1) * 21
        local time = event.timestamp and encounter.start_ms and
            string.format("%+.1fs", (event.timestamp - encounter.start_ms) / 1000) or "?time"
        local prefix, color, detail = event.kind:upper(), C.muted, ""
        if event.kind == "damage" then
            prefix, color = "DMG", C.taken
            detail = (event.amount and format_amount(event.amount) or "?amount") ..
                (event.critical and "* " or " ") ..
                ActorLabels.text(event.actor_label, event.source_name or "Unresolved source")
            if event.amount == 0 and event.result then detail = event.result .. " | " .. detail end
        elseif event.kind == "cc" then
            prefix, color = event.action == "cc_observed" and "CC+" or "CC-", C.cc
            detail = (event.category or "Control") .. " | snapshot observation"
        elseif event.kind == "interrupt" then
            prefix, color, detail = "INT", C.warning, "Your cast; interrupter not supplied"
        elseif event.kind == "effect" then
            prefix = event.action == "add_effect" and "FX+" or "FX-"
            detail = event.effect_handle or "Effect identity unavailable"
        elseif event.kind == "death" then color = C.damage end
        draw_text("cm:incoming_el" .. index, x + 14, ry,
            time .. " " .. prefix .. " " .. fit_bytes(event.name, 43), color, 11)
        draw_text("cm:incoming_er" .. index, x + 528, ry, fit_bytes(detail, 40), C.text, 11)
    end
    if #events == 0 then draw_text("cm:incoming_events_empty", x + 14, y + 442, "No retained events for this filter", C.muted, 12) end
    draw_text("cm:incoming_retention", x + 14, y + 594,
        "History " .. incoming.count .. "/" .. Incoming.history_capacity .. " | Rolled out " .. incoming.overwritten, C.muted, 10)
    draw_text("cm:incoming_retained", x + 456, y + 594,
        "Received totals retained" .. (incoming.limited and " | Other groups used" or ""), C.muted, 10)
    draw_text("cm:incoming_cc_status", x + 14, y + 610,
        "CC: " .. (cc_error and "sampler error" or cc_tracker.status) .. " | Observation times only", C.muted, 10)
    draw_text("cm:incoming_cc_limit", x + 456, y + 610,
        "Brief/NPC CC may be missed; no caster attribution", C.muted, 10)
    local warning = warning_text()
    if warning then draw_text("cm:foot", x + 14, y + 626, warning, C.warning, 10) end
    return false
end

local function draw_detail(x, y, viewport_width, viewport_height)
    for _ = 1, 2 do
        local previous_mode = mode
        local closed
        if mode == "taken" then closed = draw_taken_detail(x, y, viewport_width, viewport_height)
        else closed = draw_done_detail(x, y, viewport_width, viewport_height) end
        if closed then return true end
        if mode == previous_mode then return false end
    end
    return false
end

if Settings.diagnostics_logging then
    gos.log.info("[combat-meter] loaded build=" .. BUILD_ID .. "; incoming history=2048; CC=sampled exact definitions")
end

gos.on_tick(function()
    local ok, err = pcall(function()
        encounter.labels:refresh(current_actor_epoch, current_actor_revision, 2)
    end)
    if not ok then metadata_error = tostring(err); error(err) end
end, { interval_ms = 250 })

-- Core owns overlay frames per callback source/line. Separate cadence callbacks
-- preserve the 50 ms render snapshot while the 16 ms capture callback runs.
gos.on_tick(function()
    local ok, err = pcall(poll_events)
    if not ok then
        resolution_cache = nil
        capture_error = tostring(err)
        error(err) -- Native host disables this callback and retains the error.
    end
end, { interval_ms = 16 })

gos.on_tick(function()
    local ok, err = pcall(sample_self_cc)
    if not ok then cc_error = tostring(err); error(err) end
end, { interval_ms = 200 })

gos.on_tick(function()
    Settings = gos.settings.get(SCRIPT_ID)
    if not (Settings.enabled and Settings.active and Settings.visible) then
        return
    end
    font_delta = Settings.font_size - 13
    window_color = color_from_hex(Settings.background_color)
    window_alpha = Settings.transparent_mode and 0 or math.floor(window_color / 16777216) % 256
    window_color = color_with_alpha(window_color, window_alpha)
    local viewport_width, viewport_height = viewport_size()
    if view == "detail" then
        local x = drag and drag.id == "cm:detail_drag" and drag.x or Settings.detail_position_x
        local y = drag and drag.id == "cm:detail_drag" and drag.y or Settings.detail_position_y
        if draw_detail(x, y, viewport_width, viewport_height) and view == "compact" then
            local compact_x = drag and drag.id == "cm:drag" and drag.x or Settings.position_x
            local compact_y = drag and drag.id == "cm:drag" and drag.y or Settings.position_y
            draw_compact(compact_x, compact_y, viewport_width, viewport_height)
        end
    else
        local x = drag and drag.id == "cm:drag" and drag.x or Settings.position_x
        local y = drag and drag.id == "cm:drag" and drag.y or Settings.position_y
        if draw_compact(x, y, viewport_width, viewport_height) and view == "detail" then
            local detail_x = drag and drag.id == "cm:detail_drag" and drag.x or Settings.detail_position_x
            local detail_y = drag and drag.id == "cm:detail_drag" and drag.y or Settings.detail_position_y
            draw_detail(detail_x, detail_y, viewport_width, viewport_height)
        end
    end
end, { interval_ms = 50 })
