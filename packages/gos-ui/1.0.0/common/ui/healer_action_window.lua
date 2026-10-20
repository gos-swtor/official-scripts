-- Shared frameless healer action feed used by live healer scripts.
-- Presentation only: it observes accepted route actions and combat events, and
-- never owns casting, target selection, triage, or command lifecycle.
local ActorLabels = require("ui.actor_labels")

local M = { build_id = "2026-10-10-healer-action-window-r2-canonical-ids" }

local TTL = 0.20
local WIDTH = 560
local CONTROL_HEIGHT = 28
local MAX_BUFFER = 16
local EVENT_PASSES = 4
local LABEL_REFRESH_MS = 250

local function rgba(r, g, b, a)
    return r + g * 256 + b * 65536 + (a or 255) * 16777216
end

local COLORS = {
    heal = rgba(91, 224, 143, 255),
    protect = rgba(87, 194, 255, 255),
    cleanse = rgba(226, 166, 255, 255),
    resource = rgba(101, 154, 255, 255),
    support = rgba(239, 196, 94, 255),
    dps = rgba(236, 112, 94, 255),
    proc = rgba(255, 214, 74, 255),
    text = rgba(232, 238, 246, 255),
    muted = rgba(154, 166, 182, 255),
    control = rgba(205, 214, 225, 255),
}

local function safe_method(object, method_name, ...)
    if not object or type(object[method_name]) ~= "function" then return nil end
    local ok, a, b, c = pcall(object[method_name], object, ...)
    if not ok then return nil end
    return a, b, c
end

local function unit_display_name(unit)
    local value = safe_method(unit, "name")
    if type(value) == "string" and value ~= "" then return value end
    value = safe_method(unit, "display_name")
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function actor_handle_suffix(handle)
    if type(handle) ~= "string" then return nil end
    local hex = handle:match("^unit:(%x+)$")
    if type(hex) ~= "string" or #hex < 6 then return nil end
    return hex:sub(-6)
end

local function with_alpha(color, alpha)
    alpha = math.max(0, math.min(255, math.floor(alpha or 255)))
    return color % 16777216 + alpha * 16777216
end

local function fit(text, limit)
    text = tostring(text or "")
    if #text <= limit then return text end
    local cut = utf8.offset(text, 0, math.max(0, limit - 3) + 1)
    if not cut then return text end
    return string.sub(text, 1, cut - 1) .. "..."
end

local function amount_text(value)
    value = math.max(0, value or 0)
    if value >= 1000000 then
        return string.format("%.2fM", value / 1000000)
    elseif value >= 1000 then
        return string.format("%.1fK", value / 1000)
    end
    return string.format("%.0f", value)
end

local function hp(unit)
    local value = unit and safe_method(unit, "hp") or nil
    if type(value) ~= "table" or type(value.current) ~= "number" or
        type(value.max) ~= "number" or value.max <= 0 then
        return nil, nil, nil
    end
    local percent = type(value.percent) == "number" and value.percent or
        (value.current / value.max) * 100
    return value.current, value.max, percent
end

local function valid_handle(value)
    return type(value) == "string" and value:match("^unit:%x+$") ~= nil
end

local function normalized_config(config)
    config = type(config) == "table" and config or {}
    return {
        visible = config.visible ~= false,
        x = type(config.x) == "number" and config.x or 700,
        y = type(config.y) == "number" and config.y or 220,
        fontSize = math.max(16, math.min(36,
            type(config.fontSize) == "number" and math.floor(config.fontSize) or 24)),
        rows = math.max(1, math.min(8,
            type(config.rows) == "number" and math.floor(config.rows) or 5)),
        lifetime = math.max(2, math.min(20,
            type(config.lifetime) == "number" and math.floor(config.lifetime) or 8)),
        showHealAmount = config.showHealAmount ~= false,
        showDamage = config.showDamage ~= false,
        showProcs = config.showProcs ~= false,
    }
end

function M.new(spec)
    assert(type(spec) == "table" and type(spec.idPrefix) == "string" and
        type(spec.scriptId) == "string" and type(spec.visibleKey) == "string" and
        type(spec.xKey) == "string" and type(spec.yKey) == "string",
        "healer_action_window.new requires stable ids/settings keys")
    assert(spec.displayAbility == nil or type(spec.displayAbility) == "function")
    assert(spec.formatRow == nil or type(spec.formatRow) == "function")

    local state = {
        labels = ActorLabels.new(nil, 512),
        rows = {},
        nextId = 0,
        drag = nil,
        combatCursor = nil,
        nextLabelRefresh = 0,
    }

    local function classify(action)
        local meta = type(action) == "table" and action.meta or nil
        local explicit = type(meta) == "table" and meta.category or nil
        if explicit == "heal" or explicit == "protect" or explicit == "cleanse" or
            explicit == "resource" or explicit == "support" or explicit == "dps" then
            return explicit
        end
        local ability = type(action) == "table" and action.ability or nil
        local decision = type(action) == "table" and tostring(action.decision or "") or ""
        if decision:find("cleanse", 1, true) then return "cleanse" end
        if spec.cleanseActions and spec.cleanseActions[ability] then return "cleanse" end
        if spec.protectActions and spec.protectActions[ability] then return "protect" end
        if spec.healActions and spec.healActions[ability] then return "heal" end
        if spec.resourceActions and spec.resourceActions[ability] then return "resource" end
        if spec.dpsActions and spec.dpsActions[ability] then return "dps" end
        return "support"
    end

    local function reset_for_epoch(world)
        local actor_epoch = world and world.actor_epoch or nil
        if state.labels.epoch and actor_epoch and state.labels.epoch ~= actor_epoch then
            state.labels = ActorLabels.new(actor_epoch, 512)
            state.rows = {}
            state.combatCursor = nil
        end
    end

    local function proc_text(row, config)
        if config.showProcs ~= true or type(row.procs) ~= "table" then return nil end
        local labels = {}
        for index = 1, math.min(#row.procs, 3) do
            local proc = row.procs[index]
            local label = type(proc) == "table" and proc.label or nil
            if type(label) == "string" and label ~= "" then labels[#labels + 1] = label end
        end
        if #labels == 0 then return nil end
        local text = "PROC: " .. table.concat(labels, "+")
        if #row.procs > 3 then text = text .. " +" .. tostring(#row.procs - 3) end
        return text
    end

    function state:push(action, raw_config)
        local config = normalized_config(raw_config)
        if config.visible ~= true or type(action) ~= "table" then return end
        local category = classify(action)
        if category == "dps" and config.showDamage ~= true then return end

        local now = gos.time_ms()
        if type(now) ~= "number" then return end
        if self.combatCursor == nil and gos.events and type(gos.events.combat) == "function" then
            local bootstrap = gos.events.combat(nil)
            if type(bootstrap) == "table" and type(bootstrap.cursor) == "number" then
                self.combatCursor = bootstrap.cursor
            end
        end

        local world = gos.world()
        reset_for_epoch(world)
        local meta = type(action.meta) == "table" and action.meta or {}
        local canonical_ability = tostring(action.ability or "Unknown")
        local display_ability = canonical_ability
        if spec.displayAbility then display_ability = spec.displayAbility(canonical_ability) end
        assert(type(display_ability) == "string" and display_ability ~= "")
        local target_name = type(action.target_name) == "string" and
            action.target_name ~= "" and action.target_name or nil
        local actor_epoch = world and world.actor_epoch or nil
        local target_handle = action.target_handle
        local unit = valid_handle(target_handle) and world and
            safe_method(world, "resolve", target_handle) or nil
        if action.untargeted == true and not unit and world then unit = world.player end
        if target_name == nil then target_name = unit_display_name(unit) end
        local target_label = valid_handle(target_handle) and
            self.labels:track(target_handle, actor_epoch, target_name) or nil
        local before, maximum, before_percent = hp(unit)

        -- Reuse bounded row slots so Core's 31-byte overlay IDs never grow.
        self.nextId = self.nextId % MAX_BUFFER + 1
        local row = {
            id = self.nextId,
            created_ms = now,
            ability = display_ability,
            canonical_ability = canonical_ability,
            decision = tostring(action.decision or ""),
            command_handle = action.command_handle,
            category = category,
            target_handle = target_handle,
            target_type = type(action.target_type) == "string" and
                action.target_type or nil,
            target_label = target_label,
            actor_epoch = actor_epoch,
            captured_target_name = target_name,
            untargeted = action.untargeted == true,
            effect = meta.effect,
            procs = type(meta.procs) == "table" and meta.procs or nil,
            heal_amount = 0,
            heal_hits = 0,
            heal_before = category == "heal" and before or nil,
            heal_max = category == "heal" and maximum or nil,
            heal_before_percent = category == "heal" and before_percent or nil,
            heal_after = nil,
            heal_after_percent = nil,
            damage_amount = 0,
            damage_hits = 0,
        }
        row.confirmed = category ~= "protect" and category ~= "dps" and
            (category ~= "heal" or config.showHealAmount ~= true) and
            (category ~= "cleanse" or type(row.effect) ~= "string")
        table.insert(self.rows, 1, row)
        while #self.rows > MAX_BUFFER do table.remove(self.rows) end
    end

    local function prune(now, config)
        local lifetime_ms = config.lifetime * 1000
        for index = #state.rows, 1, -1 do
            local row = state.rows[index]
            if type(row.created_ms) ~= "number" or now - row.created_ms > lifetime_ms then
                table.remove(state.rows, index)
            end
        end
        if #state.rows == 0 and state.labels.count > 0 then
            state.labels = ActorLabels.new(nil, 512)
        end
    end

    local function event_matches(row, event, now, config)
        if row.actor_epoch ~= event.actor_epoch then return false end
        if tostring(event.name or "") ~= row.ability then return false end
        if row.category == "heal" then
            if event.kind ~= "heal" or type(event.amount) ~= "number" or event.amount <= 0 then
                return false
            end
            if not (spec.groupHeals and spec.groupHeals[row.canonical_ability]) and
                valid_handle(row.target_handle) and event.target_handle ~= row.target_handle then
                return false
            end
        elseif row.category == "dps" then
            if event.kind ~= "damage" or type(event.effective_amount) ~= "number" or
                event.effective_amount <= 0 then
                return false
            end
            if not (spec.areaDamage and spec.areaDamage[row.canonical_ability]) and
                valid_handle(row.target_handle) and event.target_handle ~= row.target_handle then
                return false
            end
        else
            return false
        end
        local event_time = event.timestamp
        if type(event_time) == "number" and type(row.created_ms) == "number" and
            event_time + 250 < row.created_ms then
            return false
        end
        return now - row.created_ms <= config.lifetime * 1000
    end

    local function poll_combat(world, now, config)
        if not gos.events or type(gos.events.combat) ~= "function" then return end
        local player_handle = world and world.player and safe_method(world.player, "handle") or nil
        if type(player_handle) ~= "string" then return end
        for _ = 1, EVENT_PASSES do
            local batch = gos.events.combat(state.combatCursor)
            if type(batch) ~= "table" or type(batch.cursor) ~= "number" or
                type(batch.events) ~= "table" then return end
            state.combatCursor = batch.cursor
            for _, event in ipairs(batch.events) do
                if event.source_handle == player_handle and
                    (event.kind == "heal" or event.kind == "damage") then
                    for index = 1, #state.rows do
                        local row = state.rows[index]
                        if event_matches(row, event, now, config) then
                            if row.category == "heal" and config.showHealAmount == true then
                                row.heal_amount = row.heal_amount + event.amount
                                row.heal_hits = row.heal_hits + 1
                                row.confirmed = true
                                if valid_handle(row.target_handle) and
                                    event.target_handle == row.target_handle then
                                    local unit = safe_method(world, "resolve", row.target_handle)
                                    row.heal_after, _, row.heal_after_percent = hp(unit)
                                end
                            elseif row.category == "dps" and config.showDamage == true then
                                row.damage_amount = row.damage_amount + event.effective_amount
                                row.damage_hits = row.damage_hits + 1
                                row.confirmed = true
                            end
                            break
                        end
                    end
                end
            end
            if batch.more ~= true then break end
        end
    end

    local function row_unit(world, row)
        if valid_handle(row.target_handle) then
            return safe_method(world, "resolve", row.target_handle)
        end
        if row.untargeted == true then return world and world.player or nil end
        return nil
    end

    local function update_confirmations(world, now)
        for _, row in ipairs(state.rows) do
            if row.confirmed ~= true and now - row.created_ms >= 150 then
                local unit = row_unit(world, row)
                if unit and row.category == "protect" then
                    local effect_name = spec.protectEffects and
                        spec.protectEffects[row.canonical_ability] or row.ability
                    local effect = safe_method(unit, "effect", effect_name, { kind = "buff" })
                    if type(effect) == "table" and effect.status == "ready" and
                        effect.present == true then
                        row.confirmed = true
                    end
                elseif unit and row.category == "cleanse" and type(row.effect) == "string" then
                    local effect = safe_method(unit, "effect", row.effect, { kind = "debuff" })
                    if type(effect) == "table" and effect.status == "ready" and
                        effect.present == false then
                        row.confirmed = true
                    end
                end
            end
        end
    end

    local function target_placeholder(row)
        if row.untargeted == true and row.category == "dps" then
            return spec.untargetedDamageLabel or "Area"
        end
        if row.untargeted == true then return "Self" end
        if spec.groupHeals and spec.groupHeals[row.canonical_ability] then return "Area" end
        local suffix = actor_handle_suffix(row.target_handle)
        local target_type = type(row.target_type) == "string" and row.target_type or "target"
        if target_type == "player" then
            return suffix and ("Player #" .. suffix) or "Player"
        elseif target_type == "companion" then
            return suffix and ("Companion #" .. suffix) or "Companion"
        elseif target_type == "npc" then
            return suffix and ("NPC #" .. suffix) or "NPC"
        end
        return suffix and ("Target #" .. suffix) or "Target"
    end

    local function target_text(row)
        if row.target_label then
            return ActorLabels.text(row.target_label, row.captured_target_name or target_placeholder(row))
        end
        if type(row.captured_target_name) == "string" and row.captured_target_name ~= "" then
            return row.captured_target_name
        end
        return target_placeholder(row)
    end

    local function row_text(row, config)
        local target = target_text(row)
        if spec.formatRow then
            local main, detail = spec.formatRow(row, target)
            if main ~= nil then return main, detail end
        end
        if row.category == "heal" then
            local verb = row.confirmed and "HEALED" or "HEALING"
            local metric
            if config.showHealAmount and row.heal_amount > 0 then
                local amount = "+" .. amount_text(row.heal_amount)
                if type(row.heal_before_percent) == "number" and
                    type(row.heal_after_percent) == "number" then
                    metric = string.format("%d%% -> %d%%   %s",
                        math.floor(row.heal_before_percent + 0.5),
                        math.floor(row.heal_after_percent + 0.5), amount)
                else
                    metric = amount
                end
                if row.heal_hits > 1 then metric = metric .. "   x" .. tostring(row.heal_hits) end
            end
            return verb .. "  " .. target, row.ability, metric, "heal"
        elseif row.category == "protect" then
            return (row.confirmed and "PROTECTED  " or "PROTECTING  ") .. target, row.ability
        elseif row.category == "cleanse" then
            return (row.confirmed and "CLEANSED  " or "CLEANSING  ") .. target, row.ability
        elseif row.category == "resource" then
            return tostring(spec.resourceLabel or "RESOURCE RECOVERY"), row.ability
        elseif row.category == "dps" then
            local verb = row.confirmed and "DAMAGED" or "ATTACKING"
            local metric
            if row.damage_amount > 0 then
                metric = "-" .. amount_text(row.damage_amount)
                if row.damage_hits > 1 then metric = metric .. "   x" .. tostring(row.damage_hits) end
            end
            return verb .. "  " .. target, row.ability, metric, "dps"
        end
        if row.untargeted == true then return "ACTIVATED", row.ability end
        return "PREPARED  " .. target, row.ability
    end

    local function persist_position(x, y)
        local px = math.max(0, math.floor(x + 0.5))
        local py = math.max(0, math.floor(y + 0.5))
        local ok_x, error_x = gos.settings.set(spec.scriptId, spec.xKey, px)
        local ok_y, error_y = gos.settings.set(spec.scriptId, spec.yKey, py)
        if not (ok_x and ok_y) and type(spec.log) == "function" then
            spec.log("warn", tostring(spec.title or "healer") ..
                " action window position save failed: " .. tostring(error_x or error_y))
        end
    end

    function state:draw(world, raw_config)
        local config = normalized_config(raw_config)
        if config.visible ~= true or not world then return end
        -- Headless simulation/test harnesses intentionally omit overlay APIs.
        -- Presentation must be a strict no-op there, including no combat-event
        -- polling, so this UI can never perturb rotation/event regression tests.
        if type(gos.overlay) ~= "table" or
            type(gos.overlay.viewport) ~= "function" or
            type(gos.overlay.interact) ~= "function" or
            type(gos.overlay.draw_text) ~= "function" then
            return
        end
        local now = gos.time_ms()
        if type(now) ~= "number" then return end

        reset_for_epoch(world)
        prune(now, config)
        poll_combat(world, now, config)
        update_confirmations(world, now)
        if #self.rows > 0 and now >= self.nextLabelRefresh then
            self.nextLabelRefresh = now + LABEL_REFRESH_MS
            self.labels:refresh(world.actor_epoch, world.actor_revision, 1)
        end

        local font_size = config.fontSize
        local detail_size = math.max(13, font_size - 8)
        local row_height = font_size + detail_size + 12
        local visible_rows = math.min(config.rows, #self.rows)
        local content_rows = math.max(1, visible_rows)
        local total_height = CONTROL_HEIGHT + content_rows * row_height
        local viewport = gos.overlay.viewport()
        local x, y = config.x, config.y
        if type(viewport) == "table" and viewport.available == true then
            x = math.max(0, math.min(x, math.max(0, viewport.width - WIDTH)))
            y = math.max(0, math.min(y, math.max(0, viewport.height - total_height)))
        end

        local drag_state = gos.overlay.interact(spec.idPrefix .. ":drag", {
            x = x, y = y, width = 34, height = CONTROL_HEIGHT, ttl = TTL,
        })
        if drag_state.pressed then
            self.drag = {
                dx = drag_state.mouse_x - x,
                dy = drag_state.mouse_y - y,
                x = x, y = y,
            }
        end
        local drag = self.drag
        if drag and (drag_state.down or drag_state.released) then
            drag.x = drag_state.mouse_x - drag.dx
            drag.y = drag_state.mouse_y - drag.dy
            if type(viewport) == "table" and viewport.available == true then
                drag.x = math.max(0, math.min(drag.x, math.max(0, viewport.width - WIDTH)))
                drag.y = math.max(0, math.min(drag.y, math.max(0, viewport.height - total_height)))
            end
            x, y = drag.x, drag.y
        end
        if drag and drag_state.released then
            persist_position(drag.x, drag.y)
            self.drag = nil
        end

        local close_state = gos.overlay.interact(spec.idPrefix .. ":close", {
            x = x + WIDTH - 34, y = y, width = 34, height = CONTROL_HEIGHT, ttl = TTL,
        })
        if close_state.clicked then
            local ok, error_text = gos.settings.set(spec.scriptId, spec.visibleKey, false)
            if not ok and type(spec.log) == "function" then
                spec.log("warn", tostring(spec.title or "healer") ..
                    " action window hide failed: " .. tostring(error_text))
            end
            return
        end

        gos.overlay.draw_text(spec.idPrefix .. ":drag_text", {
            at = { screen = { x = x + 5, y = y + 1 } },
            text = "[=]", color = with_alpha(COLORS.control,
                drag_state.hovered and 255 or 180),
            font_size = 20, shadow = true, ttl = TTL, frame = true,
        })
        gos.overlay.draw_text(spec.idPrefix .. ":title", {
            at = { screen = { x = x + 38, y = y + 6 } },
            text = tostring(spec.title or "HEALER ACTIONS"),
            color = with_alpha(COLORS.muted, 150),
            font_size = 12, shadow = true, ttl = TTL, frame = true,
        })
        gos.overlay.draw_text(spec.idPrefix .. ":close_txt", {
            at = { screen = { x = x + WIDTH - 17, y = y + 1 } },
            text = "X", color = with_alpha(COLORS.control,
                close_state.hovered and 255 or 180),
            font_size = 20, shadow = true, center_x = true,
            ttl = TTL, frame = true,
        })

        if visible_rows == 0 then
            gos.overlay.draw_text(spec.idPrefix .. ":ready", {
                at = { screen = { x = x + 38, y = y + CONTROL_HEIGHT + 4 } },
                text = tostring(spec.readyText or "HEALER READY"),
                color = with_alpha(COLORS.muted, 135),
                font_size = math.max(16, font_size - 4), shadow = true,
                ttl = TTL, frame = true,
            })
            return
        end

        local lifetime_ms = config.lifetime * 1000
        for index = 1, visible_rows do
            local row = self.rows[index]
            local age = math.max(0, now - row.created_ms)
            local remaining = math.max(0, 1 - age / lifetime_ms)
            local alpha = math.floor(55 + 200 * remaining)
            local main, detail, metric, metric_category = row_text(row, config)
            local proc = proc_text(row, config)
            local color = COLORS[row.category] or COLORS.text
            local row_y = y + CONTROL_HEIGHT + (index - 1) * row_height

            gos.overlay.draw_text(spec.idPrefix .. ":main:" .. tostring(row.id), {
                at = { screen = { x = x + 38, y = row_y } },
                text = fit(main, proc and 24 or 52),
                color = with_alpha(color, alpha), font_size = font_size,
                shadow = true, ttl = TTL, frame = true,
            })
            if type(proc) == "string" and proc ~= "" then
                gos.overlay.draw_text(spec.idPrefix .. ":proc:" .. tostring(row.id), {
                    at = { screen = { x = x + 285, y = row_y + 6 } },
                    text = fit(proc, 46),
                    color = with_alpha(COLORS.proc, math.max(90, alpha - 5)),
                    font_size = math.max(10, font_size - 13), shadow = true,
                    ttl = TTL, frame = true,
                })
            end
            gos.overlay.draw_text(spec.idPrefix .. ":detail:" .. tostring(row.id), {
                at = { screen = { x = x + 40, y = row_y + font_size + 2 } },
                text = fit(detail, 28),
                color = with_alpha(COLORS.text, math.max(45, alpha - 45)),
                font_size = detail_size, shadow = true, ttl = TTL, frame = true,
            })
            if type(metric) == "string" and metric ~= "" then
                local metric_color = COLORS[metric_category] or color
                gos.overlay.draw_text(spec.idPrefix .. ":metric:" .. tostring(row.id), {
                    at = { screen = { x = x + 265, y = row_y + font_size + 3 } },
                    text = fit(metric, 36),
                    color = with_alpha(metric_color, math.max(70, alpha - 20)),
                    font_size = math.max(12, detail_size - 1), shadow = true,
                    ttl = TTL, frame = true,
                })
            end
        end
    end

    return state
end

return M
