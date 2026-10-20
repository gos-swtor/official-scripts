local SCRIPT_ID = "better_ally_frames"
local BUILD_ID = "baf-class-colors-r5-personal-defaults-20261007-script-library-layout-r1"
local TTL = 0.20
local GAP = 3
local MAX_FRAMES = 32
-- CharacterNode/render coordinates are 0.1x SWTOR gameplay metres.
local METERS_PER_WORLD_UNIT = 10.0
local TITLE_HEIGHT = 26
local TITLE_BUTTON_WIDTH = 24
local TYPE_ORDER = { player = 1, companion = 2, npc = 3 }

local function rgba(r, g, b, a)
    return r + g * 256 + b * 65536 + (a or 255) * 16777216
end

local C = {
    background = rgba(14, 20, 28, 228),
    title = rgba(22, 30, 40, 238),
    title_hover = rgba(34, 45, 58, 245),
    border = rgba(172, 142, 70, 235),
    selected = rgba(67, 204, 244, 255),
    selected_background = rgba(10, 77, 99, 245),
    selected_accent = rgba(103, 225, 255, 255),
    pending = rgba(242, 181, 65, 255),
    text = rgba(224, 235, 243, 255),
    companion = rgba(206, 151, 242, 255),
    npc = rgba(160, 214, 166, 255),
    muted = rgba(142, 153, 164, 255),
    far_background = rgba(24, 26, 29, 220),
    far_border = rgba(91, 94, 99, 230),
    far_text = rgba(139, 142, 147, 255),
    far_bar = rgba(78, 80, 84, 235),
    far_bar_bg = rgba(38, 39, 42, 235),
    health_bg = rgba(55, 18, 18, 235),
    health = rgba(192, 47, 40, 255),
    health_low = rgba(232, 69, 50, 255),
    dead = rgba(80, 80, 84, 255),
    resource_bg = rgba(20, 27, 35, 235),
    force = rgba(50, 125, 220, 255),
    energy = rgba(218, 187, 59, 255),
    rage = rgba(226, 104, 45, 255),
    generic_resource = rgba(91, 180, 128, 255),
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
    title = "Better Ally Frames",
    version = 5,
    activation = { mode = "manual" },
    fields = {
        {
            key = "visible", type = "bool", label = "Visible",
            tooltip = "Show compact frames for friendly players, companions, and NPCs.",
            default = true,
        },
        {
            key = "show_class_colors", type = "bool", label = "Class Colors",
            tooltip = "Color friendly player names by combat style.",
            default = true,
        },
        {
            key = "toggle_hotkey", type = "hotkey", label = "Show / Hide Hotkey",
            tooltip = "Toggle the ally frame panel without disabling the script.",
            default = "f6",
        },
        {
            key = "minimized", type = "bool", label = "Minimized",
            tooltip = "Leave only the Better Ally Frames title bar visible.",
            default = true,
        },
        {
            key = "sort_mode", type = "select", label = "Sort Frames",
            tooltip = "Choose how friendly frames are ordered.",
            default = "Group then name",
            options = { "Group then name", "Distance", "Health %", "Name" },
        },
        {
            key = "far_opacity", type = "int", label = "Out-of-Range Opacity",
            tooltip = "Opacity for allies farther than the configured range.",
            default = 40, min = 20, max = 100, step = 5,
        },
        {
            key = "range_m", type = "int", label = "Range (metres)",
            tooltip = "Allies farther than this exact gameplay distance are dimmed but remain visible.",
            default = 40, min = 5, max = 500, step = 5,
        },
        {
            key = "position_x", type = "int", label = "Position X",
            tooltip = "Horizontal screen position of the frame grid.",
            default = 459, min = 0, max = 7680, step = 1,
        },
        {
            key = "position_y", type = "int", label = "Position Y",
            tooltip = "Vertical screen position of the frame grid.",
            default = 453, min = 0, max = 4320, step = 1,
        },
        {
            key = "columns", type = "int", label = "Columns",
            tooltip = "Number of ally frames in each row.",
            default = 4, min = 1, max = 8, step = 1,
        },
        {
            key = "frame_width", type = "int", label = "Frame Width",
            tooltip = "Width of each compact ally frame.",
            default = 112, min = 80, max = 180, step = 1,
        },
        {
            key = "frame_height", type = "int", label = "Frame Height",
            tooltip = "Height of each compact ally frame.",
            default = 58, min = 34, max = 58, step = 1,
        },
        {
            key = "show_self", type = "bool", label = "Show Self",
            tooltip = "Include the local player in the ally grid.",
            default = true,
        },
        {
            key = "show_players", type = "bool", label = "Show Players",
            tooltip = "Include friendly players.",
            default = true,
        },
        {
            key = "show_companions", type = "bool", label = "Show Companions",
            tooltip = "Include friendly companions.",
            default = true,
        },
        {
            key = "show_npcs", type = "bool", label = "Show Ally NPCs",
            tooltip = "Include other friendly NPCs.",
            default = false,
        },
        {
            key = "show_distance", type = "bool", label = "Show Distance",
            tooltip = "Append rounded distance in metres to each ally name.",
            default = true,
        },
        {
            key = "show_resource", type = "bool", label = "Show Resource Bar",
            tooltip = "Show each ally's available Core resource snapshot.",
            default = true,
        },
        {
            key = "targeting_diagnostics", type = "bool", label = "Targeting Diagnostics",
            tooltip = "Log mouse input, frame hit tests, target requests, and a status update once per second in this script's Log tab.",
            default = false,
        },
    },
})

local pending_handle
local pending_request
local pending_started_at = 0
local pending_until = 0
local pending_queued = false
local pending_busy = false
local pending_session
local drag
local targeting_diagnostics_was_enabled = false
local diagnostic_next_status_at = 0
local diagnostic_mouse_down = false
local visible_override
local minimized_override

local function clear_pending()
    if pending_request then gos.target.cancel(pending_request) end
    pending_handle = nil
    pending_request = nil
    pending_started_at = 0
    pending_until = 0
    pending_queued = false
    pending_busy = false
    pending_session = nil
end

local function target_diagnostic(message)
    if Settings.targeting_diagnostics then
        gos.log.info("[better-ally-frames] target " .. message)
    end
end

local function log_interaction(id, state, handle)
    if Settings.targeting_diagnostics and
        (state.pressed or state.released or state.clicked) then
        target_diagnostic("interaction id=" .. id .. " handle=" .. tostring(handle) ..
            " hovered=" .. tostring(state.hovered) .. " down=" .. tostring(state.down) ..
            " pressed=" .. tostring(state.pressed) ..
            " released=" .. tostring(state.released) ..
            " clicked=" .. tostring(state.clicked) ..
            " mouse=" .. tostring(state.mouse_x) .. "," .. tostring(state.mouse_y))
    end
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function with_opacity(color, opacity)
    local alpha = math.floor(color / 16777216) % 256
    return color % 16777216 + math.floor(alpha * clamp(opacity, 0, 1) + 0.5) * 16777216
end

local function class_color(unit)
    return type(unit.combat_style) == "function" and
        COMBAT_STYLE_COLORS[unit:combat_style()] or nil
end

local function fit_bytes(text, maximum)
    text = tostring(text or "")
    if #text <= maximum then
        return text
    end
    return string.sub(text, 1, math.max(1, maximum - 1)) .. "~"
end

local function percentage(snapshot)
    if type(snapshot) ~= "table" then
        return nil
    end
    if type(snapshot.percent) == "number" then
        return clamp(snapshot.percent, 0, 100)
    end
    if type(snapshot.current) == "number" and type(snapshot.max) == "number" and
        snapshot.max > 0 then
        return clamp((snapshot.current / snapshot.max) * 100, 0, 100)
    end
    return nil
end

local function format_compact(value)
    local whole = math.max(0, math.floor(value or 0))
    if whole >= 1000000 then
        local tenths = math.floor(whole / 100000)
        if tenths >= 100 or tenths % 10 == 0 then
            return tostring(math.floor(tenths / 10)) .. "m"
        end
        return tostring(math.floor(tenths / 10)) .. "." ..
            tostring(tenths % 10) .. "m"
    end
    if whole >= 1000 then
        return tostring(math.floor(whole / 1000)) .. "k"
    end
    return tostring(whole)
end

local function resource_color(kind)
    if kind == "force" then
        return C.force
    end
    if kind == "focus" or kind == "rage" or kind == "heat" then
        return C.rage
    end
    if kind == "energy" or kind == "ammo_plasma" or kind == "ammo_ion" or
        kind == "ammo_ap" or kind == "ammo_normal" then
        return C.energy
    end
    return C.generic_resource
end

local function included_ally(unit)
    if unit:reaction() ~= "friendly" then return false end
    local unit_type = unit:type()
    local local_player = unit:is_local_player()
    return local_player and Settings.show_self or
        (not local_player and unit_type == "player" and Settings.show_players) or
        (unit_type == "companion" and Settings.show_companions) or
        (unit_type == "npc" and Settings.show_npcs)
end

local function collect_allies(world)
    local allies = {}
    for _, unit in ipairs(world:units({ reaction = "friendly" })) do
        local unit_type = unit:type()
        local local_player = unit:is_local_player()
        local include = included_ally(unit)
        if include then
            local raw_distance = local_player and 0 or unit:distance()
            local distance = type(raw_distance) == "number" and
                raw_distance * METERS_PER_WORLD_UNIT or nil
            local hp = unit:hp()
            local far_scale = Settings.far_opacity / 100
            local out_of_range = type(distance) ~= "number" or
                distance > Settings.range_m
            allies[#allies + 1] = {
                unit = unit,
                handle = unit:handle() or "",
                name = unit:name() or "Unknown ally",
                unit_type = unit_type,
                class_color = Settings.show_class_colors and unit_type == "player" and
                    class_color(unit) or nil,
                local_player = local_player,
                distance = distance,
                hp = hp,
                hp_percent = percentage(hp),
                opacity = out_of_range and far_scale or 1,
                out_of_range = out_of_range,
            }
        end
    end

    local sort_mode = Settings.sort_mode
    table.sort(allies, function(left, right)
        if sort_mode == "Distance" then
            local left_distance = type(left.distance) == "number" and left.distance or math.huge
            local right_distance = type(right.distance) == "number" and right.distance or math.huge
            if left_distance ~= right_distance then
                return left_distance < right_distance
            end
        elseif sort_mode == "Health %" then
            local left_health = left.hp_percent or math.huge
            local right_health = right.hp_percent or math.huge
            if left_health ~= right_health then
                return left_health < right_health
            end
        elseif sort_mode ~= "Name" and left.local_player ~= right.local_player then
            return left.local_player
        end
        local left_type = TYPE_ORDER[left.unit_type] or 4
        local right_type = TYPE_ORDER[right.unit_type] or 4
        if sort_mode ~= "Name" and left_type ~= right_type then
            return left_type < right_type
        end
        local left_name = string.lower(left.name)
        local right_name = string.lower(right.name)
        if left_name ~= right_name then
            return left_name < right_name
        end
        return left.handle < right.handle
    end)
    return allies
end

local function draw_frame(entry, index, x, y, width, height, now)
    local unit = entry.unit
    local hp = entry.hp
    local hp_percent = entry.hp_percent
    local selected = unit:is_current_target()
    if selected and pending_handle == entry.handle then
        clear_pending()
    end
    local pending = pending_handle == entry.handle and now < pending_until
    local opacity = (selected or pending) and 1 or entry.opacity
    local border = selected and C.selected or
        (pending and C.pending or (entry.out_of_range and C.far_border or C.border))
    local name_color = entry.unit_type == "companion" and C.companion or
        (entry.unit_type == "npc" and C.npc or entry.class_color or C.text)
    if selected then
        name_color = C.selected_accent
    elseif entry.out_of_range then
        name_color = C.far_text
    end
    local alive = type(hp) ~= "table" or type(hp.current) ~= "number" or hp.current > 0

    gos.overlay.draw_rect("baf:" .. index .. ":bg", {
        at = { screen = { x = x, y = y } }, width = width, height = height,
        filled = true,
        fill_color = with_opacity(selected and C.selected_background or
            (entry.out_of_range and C.far_background or C.background), opacity),
        border = true, border_color = with_opacity(border, opacity), rounding = 1,
        ttl = TTL, frame = true,
    })

    if selected then
        gos.overlay.draw_rect("baf:" .. index .. ":selected", {
            at = { screen = { x = x, y = y } }, width = 3, height = height,
            filled = true, fill_color = C.selected_accent,
            border = false, ttl = TTL, frame = true,
        })
    end

    local health_y = y + 17
    local resource_height = Settings.show_resource and 4 or 0
    local health_height = math.max(10, height - 21 - resource_height)
    gos.overlay.draw_bar("baf:" .. index .. ":hp", {
        at = { screen = { x = x + 2, y = health_y } },
        width = width - 4, height = health_height,
        value = hp_percent and hp_percent / 100 or 0,
        fill_color = with_opacity(entry.out_of_range and C.far_bar or
            (not alive and C.dead or
                (hp_percent and hp_percent < 30 and C.health_low or C.health)), opacity),
        bg_color = with_opacity(entry.out_of_range and C.far_bar_bg or C.health_bg, opacity),
        border = false, rounding = 0,
        ttl = TTL, frame = true,
    })

    if Settings.show_resource then
        local resource = unit:resource()
        local resource_percent = percentage(resource)
        gos.overlay.draw_bar("baf:" .. index .. ":resource", {
            at = { screen = { x = x + 2, y = y + height - 5 } },
            width = width - 4, height = 3,
            value = resource_percent and resource_percent / 100 or 0,
            fill_color = with_opacity(entry.out_of_range and C.far_bar or
                resource_color(resource and resource.kind), opacity),
            bg_color = with_opacity(entry.out_of_range and C.far_bar_bg or
                C.resource_bg, opacity),
            border = false, rounding = 0,
            ttl = TTL, frame = true,
        })
    end

    local name = entry.name
    local distance_suffix = ""
    if Settings.show_distance and not entry.local_player then
        distance_suffix = " " .. (type(entry.distance) == "number" and
            (math.floor(entry.distance + 0.5) .. "m") or "?m")
    end
    local max_name_bytes = math.max(7, math.floor((width - 8) / 8))
    name = fit_bytes(name, math.max(3, max_name_bytes - #distance_suffix)) ..
        distance_suffix
    gos.overlay.draw_text("baf:" .. index .. ":name", {
        at = { screen = { x = x + (selected and 7 or 4), y = y + 1 } },
        text = fit_bytes(name, max_name_bytes), color = with_opacity(name_color, opacity),
        font_size = 16, shadow = true, ttl = TTL, frame = true,
    })

    local health_text = "--"
    if type(hp) == "table" and type(hp.current) == "number" then
        health_text = format_compact(hp.current)
        if hp_percent then
            health_text = health_text .. " (" .. math.floor(hp_percent + 0.5) .. "%)"
        end
    end
    gos.overlay.draw_text("baf:" .. index .. ":hptext", {
        at = { screen = { x = x + width / 2,
            y = health_y + math.max(0, (health_height - 14) / 2) } },
        text = fit_bytes(health_text, 31),
        color = with_opacity(entry.out_of_range and C.far_text or
            (alive and C.text or C.muted), opacity),
        font_size = 14, shadow = true, center_x = true,
        ttl = TTL, frame = true,
    })
end

local function persist_position(x, y)
    local px = math.max(0, math.floor(x + 0.5))
    local py = math.max(0, math.floor(y + 0.5))
    local ok_x, error_x = gos.settings.set(SCRIPT_ID, "position_x", px)
    local ok_y, error_y = gos.settings.set(SCRIPT_ID, "position_y", py)
    if not ok_x or not ok_y then
        gos.log.warn("[better-ally-frames] position save failed: " ..
            tostring(error_x or error_y))
    end
end

local function update_drag(x, y, width, height, viewport)
    local state = gos.overlay.interact("baf:move", {
        x = x, y = y, width = width, height = TITLE_HEIGHT, ttl = TTL,
    })
    log_interaction("baf:move", state)
    if state.pressed then
        drag = { dx = state.mouse_x - x, dy = state.mouse_y - y, x = x, y = y }
    end
    if drag and (state.down or state.released) then
        drag.x = state.mouse_x - drag.dx
        drag.y = state.mouse_y - drag.dy
        if viewport.available then
            drag.x = clamp(drag.x, 0, math.max(0, viewport.width - width))
            drag.y = clamp(drag.y, 0, math.max(0, viewport.height - height))
        end
    end
    if drag and state.released then
        x, y = drag.x, drag.y
        persist_position(x, y)
        drag = nil
    elseif drag then
        x, y = drag.x, drag.y
    end
    return x, y, state.hovered
end

local function service_pending_selection(world, now)
    if not pending_handle then
        return
    end
    if pending_session ~= world.session_generation then
        clear_pending()
        return
    end
    if now >= pending_until then
        target_diagnostic("timeout handle=" .. tostring(pending_handle) ..
            " elapsed_ms=" .. tostring(now - pending_started_at) ..
            " queued=" .. tostring(pending_queued) ..
            " busy=" .. tostring(pending_busy) ..
            " current_target=" .. tostring(world.current_target and world.current_target:handle()))
        gos.log.warn(pending_busy and
            "[better-ally-frames] target selection remained busy" or
            "[better-ally-frames] queued target was not confirmed")
        clear_pending()
        return
    end

    local unit = world:resolve(pending_handle)
    if not unit or not included_ally(unit) then
        target_diagnostic("ally_unavailable handle=" .. tostring(pending_handle) ..
            " reason=" .. (unit and "frame_filter" or "snapshot_miss"))
        gos.log.warn("[better-ally-frames] requested ally is no longer available in the frame roster")
        clear_pending()
        return
    end
    if unit:is_current_target() then
        target_diagnostic("confirmed handle=" .. tostring(pending_handle) ..
            " elapsed_ms=" .. tostring(now - pending_started_at))
        clear_pending()
        return
    end
    if pending_request then
        local status = gos.target.status(pending_request)
        if status.state == "observed" then
            target_diagnostic("observed request=" .. pending_request ..
                " elapsed_ms=" .. tostring(now - pending_started_at))
            clear_pending()
        elseif status.terminal then
            target_diagnostic("terminal request=" .. pending_request ..
                " state=" .. tostring(status.state))
            gos.log.warn("[better-ally-frames] target request ended: " ..
                tostring(status.state))
            clear_pending()
        end
        return
    end
end

local function request_selection(handle, world, now, target_intent)
    local unit = handle and world:resolve(handle) or nil
    if not unit or not included_ally(unit) then
        target_diagnostic("request_rejected handle=" .. tostring(handle) ..
            " reason=" .. (unit and "frame_filter" or "snapshot_miss"))
        return
    end
    -- Submit the new intent now. Core atomically supersedes only this owner's
    -- undispatched requests and retains evidence if an older dispatch won.
    if not target_intent then
        gos.log.warn("[better-ally-frames] target selection rejected: missing native click ticket")
        return
    end
    local ok, error_text, request_handle = gos.target.select(unit, target_intent)
    if not ok then
        target_diagnostic("request_rejected handle=" .. tostring(handle) ..
            " reason=" .. tostring(error_text))
        return
    end
    clear_pending()
    if not request_handle then return end -- already selected; older intent was superseded
    target_diagnostic("request handle=" .. tostring(handle) .. " name=" .. tostring(unit:name()))
    pending_handle = handle
    pending_request = request_handle
    pending_session = world.session_generation
    pending_started_at = now
    pending_until = now + 2000
    pending_queued = true
    pending_busy = false
    service_pending_selection(world, now)
end

local function queue_setting(key, value)
    local ok, error_text = gos.settings.set(SCRIPT_ID, key, value)
    if not ok then
        gos.log.warn("[better-ally-frames] setting update failed: " ..
            tostring(error_text))
    end
    return ok
end

if Settings.targeting_diagnostics then
    gos.log.info("[better-ally-frames] loaded build=" .. BUILD_ID ..
        " targeting_diagnostics=" .. tostring(Settings.targeting_diagnostics) ..
        " logs=Better Ally Frames > Log (INFO)")
end

gos.on_tick(function()
    Settings = gos.settings.get(SCRIPT_ID)
    if Settings.targeting_diagnostics and not targeting_diagnostics_was_enabled then
        gos.log.info("[better-ally-frames] target diagnostics enabled build=" .. BUILD_ID)
        diagnostic_next_status_at = 0
    end
    targeting_diagnostics_was_enabled = Settings.targeting_diagnostics == true
    if visible_override ~= nil then
        if Settings.visible == visible_override then
            visible_override = nil
        else
            Settings.visible = visible_override
        end
    end
    if minimized_override ~= nil then
        if Settings.minimized == minimized_override then
            minimized_override = nil
        else
            Settings.minimized = minimized_override
        end
    end
    local now = gos.time_ms()
    local diagnostic_report = false
    local diagnostic_cursor
    if Settings.targeting_diagnostics then
        local mouse = gos.input.state("mouse1")
        diagnostic_report = now >= diagnostic_next_status_at or mouse.pressed or mouse.released or
            mouse.down ~= diagnostic_mouse_down
        diagnostic_mouse_down = mouse.down
        if diagnostic_report then
            diagnostic_next_status_at = now + 1000
            diagnostic_cursor = gos.input.cursor()
            target_diagnostic("input enabled=" .. tostring(Settings.enabled) ..
                " active=" .. tostring(Settings.active) .. " visible=" .. tostring(Settings.visible) ..
                " minimized=" .. tostring(Settings.minimized) ..
                " mouse1_known=" .. tostring(mouse.known) .. " down=" .. tostring(mouse.down) ..
                " pressed=" .. tostring(mouse.pressed) .. " released=" .. tostring(mouse.released) ..
                " cursor_available=" .. tostring(diagnostic_cursor.available) ..
                " cursor=" .. tostring(diagnostic_cursor.x) .. "," .. tostring(diagnostic_cursor.y))
        end
    end
    if not (Settings.enabled and Settings.active) then
        clear_pending()
        return
    end
    if type(Settings.toggle_hotkey) == "string" and Settings.toggle_hotkey ~= "" and
        gos.input.was_pressed(Settings.toggle_hotkey) then
        local visible = not Settings.visible
        if queue_setting("visible", visible) then
            Settings.visible = visible
            visible_override = visible
        end
    end
    if not Settings.visible then
        clear_pending()
        return
    end

    local world = gos.world()
    service_pending_selection(world, now)
    local allies = collect_allies(world)

    -- ponytail: 32 frames stay below the current overlay command budget;
    -- add paging only if a live operation proves that ceiling insufficient.
    local minimized = Settings.minimized
    local visible_count = minimized and 0 or math.min(#allies, MAX_FRAMES)
    local columns = visible_count > 0 and math.min(Settings.columns, visible_count) or 1
    local width = Settings.frame_width
    local height = Settings.frame_height
    local row_count = visible_count > 0 and math.ceil(visible_count / columns) or 0
    local grid_width = visible_count > 0 and columns * width + (columns - 1) * GAP or 0
    local grid_height = row_count > 0 and row_count * height + (row_count - 1) * GAP or 0
    local surface_width = minimized and 180 or math.max(160, grid_width)
    local overflow_height = not minimized and #allies > visible_count and 15 or 0
    local total_height = visible_count > 0 and
        TITLE_HEIGHT + GAP + grid_height + overflow_height or TITLE_HEIGHT
    local viewport = gos.overlay.viewport()
    local x = Settings.position_x
    local y = Settings.position_y
    if viewport.available then
        x = clamp(x, 0, math.max(0, viewport.width - surface_width))
        y = clamp(y, 0, math.max(0, viewport.height - total_height))
    end
    local title_hovered
    x, y, title_hovered = update_drag(
        x, y, surface_width, total_height, viewport)

    local minimize_state = gos.overlay.interact("baf:minimize", {
        x = x + surface_width - TITLE_BUTTON_WIDTH, y = y,
        width = TITLE_BUTTON_WIDTH, height = TITLE_HEIGHT, ttl = TTL,
    })
    log_interaction("baf:minimize", minimize_state)
    local layout_changed = false
    if minimize_state.clicked then
        minimized = not minimized
        if queue_setting("minimized", minimized) then
            Settings.minimized = minimized
            minimized_override = minimized
            -- Rebuild the full layout from the persisted setting next tick.
            visible_count = 0
            layout_changed = true
        else
            minimized = Settings.minimized
        end
    end

    gos.overlay.draw_rect("baf:title_bg", {
        at = { screen = { x = x, y = y } },
        width = surface_width, height = TITLE_HEIGHT,
        filled = true, fill_color = title_hovered and C.title_hover or C.title,
        border = true, border_color = C.border, rounding = 1,
        ttl = TTL, frame = true,
    })
    gos.overlay.draw_text("baf:title", {
        at = { screen = { x = x + 6, y = y + 3 } },
        text = title_hovered and "Drag to move" or
            (minimized and "Ally Frames" or "Better Ally Frames"),
        color = C.text,
        font_size = 16, shadow = true, ttl = TTL, frame = true,
    })
    gos.overlay.draw_rect("baf:minimize_bg", {
        at = { screen = {
            x = x + surface_width - TITLE_BUTTON_WIDTH, y = y } },
        width = TITLE_BUTTON_WIDTH, height = TITLE_HEIGHT,
        filled = true, fill_color = minimize_state.hovered and C.title_hover or C.background,
        border = true, border_color = C.border, rounding = 1,
        ttl = TTL, frame = true,
    })
    gos.overlay.draw_text("baf:minimize_text", {
        at = { screen = {
            x = x + surface_width - TITLE_BUTTON_WIDTH / 2, y = y + 4 } },
        text = minimized and "+" or "-",
        color = C.text, font_size = 16, shadow = false, center_x = true,
        ttl = TTL, frame = true,
    })

    local grid_y = y + TITLE_HEIGHT + GAP
    local diagnostic_hovered_slot
    local diagnostic_cursor_slot

    for index = 1, visible_count do
        local zero = index - 1
        local column = zero % columns
        local row = math.floor(zero / columns)
        local frame_x = x + column * (width + GAP)
        local frame_y = grid_y + row * (height + GAP)
        local entry = allies[index]
        draw_frame(entry, index, frame_x, frame_y, width, height, now)
        local state = gos.overlay.interact("baf:slot:" .. index, {
            x = frame_x, y = frame_y,
            width = width, height = height, ttl = TTL,
            entity = entry.handle,
        })
        log_interaction("baf:slot:" .. index, state, state.entity_handle)
        if diagnostic_report then
            if state.hovered then diagnostic_hovered_slot = index end
            if diagnostic_cursor.available and diagnostic_cursor.x >= frame_x and
                diagnostic_cursor.x <= frame_x + width and diagnostic_cursor.y >= frame_y and
                diagnostic_cursor.y <= frame_y + height then
                diagnostic_cursor_slot = index
                target_diagnostic("frame slot=" .. tostring(index) .. " name=" .. entry.name ..
                    " event_handle=" .. tostring(state.entity_handle) ..
                    " current_handle=" .. entry.handle ..
                    " rect=" .. tostring(frame_x) .. "," .. tostring(frame_y) .. "," ..
                        tostring(width) .. "," .. tostring(height) ..
                    " hovered=" .. tostring(state.hovered) .. " down=" .. tostring(state.down) ..
                    " pressed=" .. tostring(state.pressed) .. " released=" .. tostring(state.released) ..
                    " clicked=" .. tostring(state.clicked))
            end
        end
        if state.clicked then
            if state.entity_session_generation == world.session_generation then
                request_selection(state.entity_handle, world, now, state.target_intent)
            else
                target_diagnostic("click_rejected reason=stale_display_session event=" ..
                    tostring(state.entity_session_generation) .. " world=" .. tostring(world.session_generation))
            end
        end
    end
    if diagnostic_report then
        target_diagnostic("status frames=" .. tostring(visible_count) ..
            " panel=" .. tostring(x) .. "," .. tostring(y) .. "," ..
                tostring(surface_width) .. "," .. tostring(total_height) ..
            " hovered_slot=" .. tostring(diagnostic_hovered_slot) ..
            " cursor_slot=" .. tostring(diagnostic_cursor_slot) ..
            " current_target=" .. tostring(world.current_target and world.current_target:handle()) ..
            " pending=" .. tostring(pending_handle) .. " queued=" .. tostring(pending_queued) ..
            " busy=" .. tostring(pending_busy))
    end

    if not minimized and not layout_changed and #allies > visible_count then
        gos.overlay.draw_text("baf:overflow", {
            at = { screen = { x = x, y = grid_y + grid_height + 2 } },
            text = "+" .. (#allies - visible_count) .. " more allies",
            color = C.pending, font_size = 12, shadow = true,
            ttl = TTL, frame = true,
        })
    end

end)
