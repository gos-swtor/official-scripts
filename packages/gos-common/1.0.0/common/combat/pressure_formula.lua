-- Shared live/offline Medicine triage formula.
-- Pure math only: no gos/runtime access and no future-event knowledge.
local M = {}

M.MODE_HP = "Current HP"
M.MODE_PRESSURE = "Incoming Damage Formula"

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function safe(value, fallback)
    return finite(value) and value or fallback
end

function M.evaluate(input)
    input = type(input) == "table" and input or {}
    local maximum = math.max(1, safe(input.max_hp, 1))
    local hp = clamp(safe(input.hp, maximum), 0, maximum)
    local ratio = hp / maximum
    local d075 = math.max(0, safe(input.damage_075s, 0)) / maximum / 0.75
    local attackers = math.max(0, math.floor(safe(input.attackers_3s, 0) + 0.5))
    local has_v2 = finite(input.damage_075_2s) or finite(input.damage_2_4s) or
        finite(input.recent_attackers) or finite(input.persistent_attackers)
    local fast_pressure, slow_pressure, pressure_model
    local recent_attackers, persistent_attackers = 0, 0
    if has_v2 then
        -- IDF v2 uses disjoint time bands so one fresh spike is not counted
        -- again inside both the 2s and 4s rates. Replay tuning across a known
        -- bad arena, later controls and untouched holdouts favored continuity:
        -- current focus matters, but sustained attackers carry more weight.
        local d075_2 = math.max(0, safe(input.damage_075_2s, 0)) /
            maximum / 1.25
        local d2_4 = math.max(0, safe(input.damage_2_4s, 0)) /
            maximum / 2.0
        recent_attackers = math.max(0,
            math.floor(safe(input.recent_attackers, 0) + 0.5))
        persistent_attackers = math.max(0,
            math.floor(safe(input.persistent_attackers, 0) + 0.5))
        local focus_mult = 1.0 +
            0.06 * clamp(recent_attackers - 1, 0, 3) +
            0.20 * persistent_attackers
        fast_pressure = focus_mult *
            (0.45 * d075 + 0.35 * d075_2 + 0.20 * d2_4)
        slow_pressure = focus_mult *
            (0.15 * d075 + 0.45 * d075_2 + 0.40 * d2_4)
        pressure_model = "idf_v2_persistence"
    else
        -- Backward-compatible v1 path for older offline callers that still
        -- provide cumulative windows. Runtime healer collectors use v2 fields.
        local d2 = math.max(0, safe(input.damage_2s, 0)) / maximum / 2.0
        local d4 = math.max(0, safe(input.damage_4s, 0)) / maximum / 4.0
        local attacker_mult = 1.0 + 0.08 * clamp(attackers - 1, 0, 3)
        fast_pressure = attacker_mult * (0.65 * d075 + 0.35 * d2)
        slow_pressure = attacker_mult * (0.70 * d2 + 0.30 * d4)
        pressure_model = "idf_v1_legacy"
    end
    local hot2 = math.max(0, safe(input.hot_healing_2s, 0)) / maximum
    local hot4 = math.max(0, safe(input.hot_healing_4s, 0)) / maximum
    local projected2 = clamp(ratio - 2.0 * fast_pressure + 0.80 * hot2, 0, 1)
    local projected4 = clamp(ratio - 4.0 * slow_pressure + 0.70 * hot4, 0, 1)
    local net_pressure = math.max(0.001, slow_pressure - 0.70 * (hot4 / 4.0))
    local ttd = ratio / net_pressure

    local band = 3
    if ratio <= 0.20 or projected2 <= 0.20 or ttd <= 2.0 then
        band = 0
    elseif projected2 <= 0.35 or ttd <= 4.0 then
        band = 1
    elseif projected2 <= 0.60 or ttd <= 8.0 then
        band = 2
    end

    return {
        hp_percent = ratio, projected_hp_2s = projected2,
        projected_hp_4s = projected4, ttd = ttd, risk_band = band,
        fast_pressure = fast_pressure, slow_pressure = slow_pressure,
        pressure_model = pressure_model,
        attackers_3s = attackers, recent_attackers = recent_attackers,
        persistent_attackers = persistent_attackers,
        hot_healing_2s = hot2, hot_healing_4s = hot4,
    }
end

function M.compare(left, right)
    if left.risk_band ~= right.risk_band then
        return left.risk_band < right.risk_band and -1 or 1
    end
    for _, key in ipairs({ "projected_hp_2s", "ttd", "projected_hp_4s" }) do
        if left[key] ~= right[key] then return left[key] < right[key] and -1 or 1 end
    end
    if left.slow_pressure ~= right.slow_pressure then
        return left.slow_pressure > right.slow_pressure and -1 or 1
    end
    if left.hp_percent ~= right.hp_percent then
        return left.hp_percent < right.hp_percent and -1 or 1
    end
    return 0
end

return M
