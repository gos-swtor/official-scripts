-- Shared live healer pressure history for Seer/Combat Medic triage.
-- Consumes already-owned combat-event streams; never opens its own cursor.
local Formula = require("combat.pressure_formula")
local M = {}

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

function M.new(options)
    options = type(options) == "table" and options or {}
    local hot_names = type(options.hot_names) == "table" and options.hot_names or {}
    local history_ms = finite(options.history_ms) and options.history_ms or 8000
    local hot_window_ms = finite(options.hot_window_ms) and options.hot_window_ms or 4000
    local max_events = finite(options.max_events) and math.floor(options.max_events) or 4096
    local damage_window_ms = math.min(4000, history_ms)
    local attacker_window_ms = math.min(3000, history_ms)
    local effective_hot_window_ms = math.min(hot_window_ms, history_ms)
    local self = {
        damage = {}, hot = {},
        damage_by_target = {}, hot_by_target = {},
        damage_seq = 0, hot_seq = 0,
        damage_min_seq = 1, hot_min_seq = 1,
        degraded_until = 0,
    }

    local function index_by_target(rows)
        local indexed = {}
        for _, row in ipairs(rows) do
            local target = type(row) == "table" and row.target or nil
            if type(target) == "string" then
                local bucket = indexed[target]
                if bucket == nil then
                    bucket = {}
                    indexed[target] = bucket
                end
                bucket[#bucket + 1] = row
            end
        end
        return indexed
    end

    local function append_indexed(kind, row)
        local seq_key = kind .. "_seq"
        local min_key = kind .. "_min_seq"
        local index_key = kind .. "_by_target"
        self[seq_key] = self[seq_key] + 1
        row.seq = self[seq_key]
        self[kind][#self[kind] + 1] = row
        local bucket = self[index_key][row.target]
        if bucket == nil then
            bucket = {}
            self[index_key][row.target] = bucket
        end
        bucket[#bucket + 1] = row
        self[min_key] = math.max(1, self[seq_key] - max_events + 1)

        if #self[kind] > max_events * 2 then
            local kept = {}
            for _, event in ipairs(self[kind]) do
                if event.seq >= self[min_key] then
                    kept[#kept + 1] = event
                end
            end
            self[kind] = kept
            self[index_key] = index_by_target(kept)
        end
    end

    function self:reset()
        self.damage, self.hot = {}, {}
        self.damage_by_target, self.hot_by_target = {}, {}
        self.damage_seq, self.hot_seq = 0, 0
        self.damage_min_seq, self.hot_min_seq = 1, 1
        self.degraded_until = 0
    end

    function self:observe(events, player_handle, dropped, now_ms)
        if not finite(now_ms) then return end
        if finite(dropped) and dropped > 0 then
            self:reset()
            self.degraded_until = now_ms + history_ms
        end
        for _, event in ipairs(type(events) == "table" and events or {}) do
            if type(event) == "table" then
                local at = finite(event.timestamp) and event.timestamp or now_ms
                if event.kind == "damage" and type(event.target_handle) == "string" and
                    finite(event.effective_amount) and event.effective_amount >= 0 then
                    append_indexed("damage", {
                        t = at, target = event.target_handle,
                        source = event.source_handle or "unknown",
                        amount = event.effective_amount,
                    })
                elseif event.kind == "heal" and type(player_handle) == "string" and
                    event.source_handle == player_handle and type(event.target_handle) == "string" and
                    hot_names[event.name] == true and finite(event.amount) and event.amount > 0 then
                    append_indexed("hot", {
                        t = at, target = event.target_handle, amount = event.amount,
                    })
                end
            end
        end
    end
    function self:features(row, now_ms)
        if not finite(now_ms) or now_ms < self.degraded_until or
            type(row) ~= "table" or type(row.handle) ~= "string" or
            not finite(row.current) or not finite(row.maximum) or row.maximum <= 0 then
            return nil
        end
        local d075, d075_2, d2_4 = 0, 0, 0
        local attackers3, recent_sources, older_sources = {}, {}, {}
        for _, event in ipairs(self.damage_by_target[row.handle] or {}) do
            if event.seq >= self.damage_min_seq then
                local age = now_ms - event.t
                if age >= 0 and age <= damage_window_ms then
                    local amount = math.max(0, event.amount or 0)
                    local source = event.source or "unknown"
                    if age <= attacker_window_ms then attackers3[source] = true end
                    if age <= 750 then
                        d075 = d075 + amount
                        recent_sources[source] = true
                    elseif age <= 2000 then
                        d075_2 = d075_2 + amount
                        older_sources[source] = true
                    else
                        d2_4 = d2_4 + amount
                        older_sources[source] = true
                    end
                end
            end
        end
        local attacker_count, recent_count, persistent_count = 0, 0, 0
        for _ in pairs(attackers3) do attacker_count = attacker_count + 1 end
        for source in pairs(recent_sources) do
            recent_count = recent_count + 1
            if older_sources[source] then persistent_count = persistent_count + 1 end
        end
        local recent_hot = 0
        for _, event in ipairs(self.hot_by_target[row.handle] or {}) do
            if event.seq >= self.hot_min_seq then
                local age = now_ms - event.t
                if age >= 0 and age <= effective_hot_window_ms then
                    recent_hot = recent_hot + math.max(0, event.amount or 0)
                end
            end
        end
        local hot_hps = recent_hot / (hot_window_ms / 1000.0)
        return Formula.evaluate({
            hp = row.current, max_hp = row.maximum,
            damage_075s = d075,
            damage_075_2s = d075_2,
            damage_2_4s = d2_4,
            -- Keep the broader count for diagnostics while v2 prediction uses
            -- current-focus count plus continuity from the same attackers.
            attackers_3s = attacker_count,
            recent_attackers = recent_count,
            persistent_attackers = persistent_count,
            hot_healing_2s = hot_hps * 2.0,
            hot_healing_4s = hot_hps * 4.0,
        })
    end

    function self:sort(rows, now_ms, fallback_less)
        if not finite(now_ms) or now_ms < self.degraded_until then return false end
        rows = type(rows) == "table" and rows or {}
        local handles, evidence = {}, false
        for _, row in ipairs(rows) do
            if type(row) == "table" and type(row.handle) == "string" then
                handles[row.handle] = true
            end
        end
        for handle in pairs(handles) do
            for _, event in ipairs(self.damage_by_target[handle] or {}) do
                if event.seq >= self.damage_min_seq then
                    local age = now_ms - event.t
                    if age >= 0 and age <= damage_window_ms then evidence = true; break end
                end
            end
            if evidence then break end
        end
        if not evidence then
            for handle in pairs(handles) do
                for _, event in ipairs(self.hot_by_target[handle] or {}) do
                    if event.seq >= self.hot_min_seq then
                        local age = now_ms - event.t
                        if age >= 0 and age <= effective_hot_window_ms then evidence = true; break end
                    end
                end
                if evidence then break end
            end
        end
        if not evidence then return false end
        local any = false
        for _, row in ipairs(rows) do
            row.pressure = self:features(row, now_ms)
            any = any or row.pressure ~= nil
        end
        if not any then return false end
        table.sort(rows, function(lhs, rhs)
            if lhs.pressure and rhs.pressure then
                local compared = Formula.compare(lhs.pressure, rhs.pressure)
                if compared ~= 0 then return compared < 0 end
            elseif lhs.pressure ~= nil then return true
            elseif rhs.pressure ~= nil then return false end
            return type(fallback_less) == "function" and fallback_less(lhs, rhs) or
                tostring(lhs.handle or "") < tostring(rhs.handle or "")
        end)
        return true
    end

    function self:is_degraded(now_ms)
        return not finite(now_ms) or now_ms < self.degraded_until
    end
    return self
end

M.Formula = Formula
return M
