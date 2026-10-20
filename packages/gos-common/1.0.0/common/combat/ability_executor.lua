local AbilityExecutor = {}
AbilityExecutor.__index = AbilityExecutor

local RECEIPT_CAPACITY = 16

local terminal_states = {
    submitted = true,
    acknowledged = true,
    started = true,
    failed = true,
    superseded = true,
    abandoned = true,
    cancelled = true,
}

local executor_options = {
    idempotencyKey = true,
    adoptBusy = true,
}

local function copy_table(source)
    local copy = {}
    if type(source) == "table" then
        for key, value in pairs(source) do copy[key] = value end
    end
    return copy
end

local function copy_snapshot(source)
    if type(source) ~= "table" then return source end
    local copy = copy_table(source)
    if type(source.core) == "table" then copy.core = copy_table(source.core) end
    return copy
end

local function unknown_core(reason, terminal)
    return {
        known = false,
        state = "unknown",
        terminal = terminal == true,
        acknowledged = false,
        reason = reason or "unknown_command",
    }
end

local function status_is_terminal(status)
    return type(status) == "table" and
        (status.terminal == true or terminal_states[status.state] == true)
end

local function has_activation_target_failure(status)
    local failure = type(status) == "table" and status.activation_target_failure or nil
    return type(failure) == "string" and failure ~= "" and failure ~= "none"
end

local function terminal_disposition(status)
    local state = status.state
    if state == "cancelled" or state == "abandoned" then return state end
    if state == "failed" or state == "superseded" then return "failed" end
    if has_activation_target_failure(status) and
        (state == "submitted" or state == "acknowledged" or
         state == "started" or status.acknowledged == true) then
        return "failed"
    end
    if status.acknowledged == true or state == "acknowledged" or
        state == "started" then
        return "started"
    end
    if state == "submitted" then return "submitted" end
    return "failed"
end

-- Read-only projection for callers holding a raw Core command status.
function AbilityExecutor.terminal_state(status)
    if type(status) == "table" and status.known == true and
        status_is_terminal(status) then
        return terminal_disposition(status)
    end
end

local function retained_core_busy_result(result)
    return type(result) == "table" and result.ok ~= true and
        type(result.command_handle) == "string" and
        (result.reason == "ability_command_busy" or result.reason == "bridge_busy")
end

local function admission_pending_result(result)
    if type(result) ~= "table" or result.ok == true then return false end
    local codes = gos and gos.abilities and gos.abilities.result_codes or nil
    if type(codes) == "table" and type(result.code) == "number" then
        if result.code == codes.castability_pending or
            result.code == codes.ability_submission_pending or
            result.code == codes.explicit_target_sync_pending then
            return true
        end
    end
    return result.reason == "castability_pending" or
        result.reason == "ability_submission_pending" or
        result.reason == "explicit_target_sync_pending"
end

local function validate_options(options)
    if options == nil then options = {} end
    if type(options) ~= "table" then
        return nil, "invalid_executor_options"
    end
    local key = options.idempotencyKey
    if key == nil then
        return nil, "idempotency_key_required"
    end
    if key ~= nil and (type(key) ~= "string" or key == "") then
        return nil, "invalid_idempotency_key"
    end
    if options.expectedStartAt ~= nil or options.timeout ~= nil then
        return nil, "unsupported_executor_lifecycle_option"
    end
    return options
end

local function cast_options(options)
    local result
    for key, value in pairs(options) do
        if not executor_options[key] then
            result = result or {}
            result[key] = value
        end
    end
    return result
end

local function target_identity(target)
    if target == nil then return "none" end
    local kind = type(target)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return kind .. ":" .. tostring(target)
    end
    if kind == "table" or kind == "userdata" then
        local ok_member, handle_method = pcall(function() return target.handle end)
        if ok_member and type(handle_method) == "function" then
            local ok_handle, handle = pcall(handle_method, target)
            if ok_handle and (type(handle) == "string" or type(handle) == "number") then
                return "handle:" .. tostring(handle)
            end
        end
    end
    -- Object identity is valid within one Lua VM and is safer than guessing.
    return target
end

local function same_request(pending, name, target, key)
    return pending ~= nil and key ~= nil and
        pending.idempotencyKey == key and pending.name == name and
        pending.targetIdentity == target_identity(target)
end

function AbilityExecutor.new()
    local self = setmetatable({
        pending = nil,
        receiptOrder = {},
        receiptByHandle = {},
        receiptRefreshCursor = 1,
        lastStatus = {},
    }, AbilityExecutor)
    self:_publish(unknown_core("no_command", true), "idle", nil)
    return self
end

function AbilityExecutor:_record_receipt(snapshot)
    local handle = snapshot and snapshot.command_handle
    if type(handle) ~= "string" then return end
    if self.receiptByHandle[handle] == nil then
        self.receiptOrder[#self.receiptOrder + 1] = handle
        if #self.receiptOrder > RECEIPT_CAPACITY then
            local oldest = table.remove(self.receiptOrder, 1)
            self.receiptByHandle[oldest] = nil
            if self.receiptRefreshCursor > #self.receiptOrder then
                self.receiptRefreshCursor = 1
            end
        end
    end
    self.receiptByHandle[handle] = copy_snapshot(snapshot)
end

local function legacy_executor_state(disposition, meta, owns)
    if owns == true then
        if meta and meta.cancelRequested then return "cancel_requested" end
        if meta and meta.replacesHandle then return "replacing" end
        if meta and meta.adopted then return "adopted" end
        return "pending"
    end
    return disposition
end

function AbilityExecutor:_snapshot(core, disposition, meta, owns)
    core = type(core) == "table" and copy_table(core) or
        unknown_core("invalid_command_status", false)
    local handle = core.command_handle or (meta and meta.handle) or nil
    local ability = core.name or (meta and meta.name) or nil
    local key = meta and meta.idempotencyKey or nil
    if key == nil and handle and self.receiptByHandle[handle] then
        key = self.receiptByHandle[handle].idempotency_key
    end
    local can_replace = owns == true and meta and
        meta.cancelRequested ~= true and handle == meta.handle and
        core.replacement_allowed == true
    local snapshot = {
        disposition = disposition,
        owns_command = owns == true,
        can_submit = owns ~= true,
        can_replace = can_replace == true,
        blocks_submission = owns == true,
        command_handle = handle,
        ability = ability,
        idempotency_key = key,
        target_identity = meta and meta.targetIdentity or nil,
        reason = core.reason or disposition,
        core = core,
    }
    -- Compatibility surface: old callers can continue reading raw Core fields
    -- and executor_state while v2 callers use disposition + nested core.
    for field, value in pairs(core) do
        if snapshot[field] == nil then snapshot[field] = value end
    end
    snapshot.name = snapshot.name or ability
    snapshot.executor_state = legacy_executor_state(disposition, meta, owns)
    snapshot.awaiting_terminal = owns == true
    snapshot.cancel_reason = meta and meta.cancelReason or nil
    return snapshot
end

function AbilityExecutor:_publish(core, disposition, meta)
    local snapshot = self:_snapshot(core, disposition, meta, self.pending ~= nil)
    self.lastStatus = snapshot
    self:_record_receipt(snapshot)
    return copy_snapshot(snapshot)
end

function AbilityExecutor:_finish(core)
    local pending = self.pending
    self.pending = nil
    return self:_publish(core, terminal_disposition(core), pending)
end

function AbilityExecutor:_finish_core_status(core)
    if core.known ~= true or not status_is_terminal(core) then
        local disposition = self.pending and
            (self.pending.cancelRequested and "cancel_requested" or
                (core.known == true and "owned" or "unresolved")) or "observing"
        return self:_publish(core, disposition, self.pending)
    end

    local pending = self.pending
    local retained = pending and pending.replacedPending or nil
    if retained and core.retained_command_handle == retained.handle then
        -- Preserve the terminal replacement before foreground ownership
        -- returns to the retained command.
        self:_record_receipt(self:_snapshot(
            core, terminal_disposition(core), pending, false))

        local retained_status = gos.abilities.command_status(retained.handle)
        if type(retained_status) ~= "table" then
            retained_status = unknown_core("invalid_command_status", false)
        end
        if retained_status.known ~= true or not status_is_terminal(retained_status) then
            self.pending = retained
            return self:_publish(retained_status,
                retained.cancelRequested and "cancel_requested" or
                    (retained_status.known == true and "owned" or "unresolved"),
                retained)
        end
        -- Both replacement and retained owner are terminal.
        self.pending = retained
        return self:_finish(retained_status)
    end

    return self:_finish(core)
end

local function receipt_needs_refresh(snapshot)
    local core = type(snapshot) == "table" and snapshot.core or nil
    return type(snapshot) == "table" and
        type(snapshot.command_handle) == "string" and
        type(core) == "table" and
        (core.cleanup_pending == true or not status_is_terminal(core) or
            (core.state == "submitted" and core.acknowledged ~= true))
end

function AbilityExecutor:_refresh_one_receipt(exclude_handle)
    local count = #self.receiptOrder
    if count == 0 then return end
    if self.receiptRefreshCursor < 1 or self.receiptRefreshCursor > count then
        self.receiptRefreshCursor = 1
    end

    for offset = 0, count - 1 do
        local index = ((self.receiptRefreshCursor - 1 + offset) % count) + 1
        local handle = self.receiptOrder[index]
        local old = self.receiptByHandle[handle]
        if handle ~= exclude_handle and
            (self.pending == nil or handle ~= self.pending.handle) and
            receipt_needs_refresh(old) then
            self.receiptRefreshCursor = (index % count) + 1
            local core = gos.abilities.command_status(handle)
            if type(core) ~= "table" then return end
            local disposition = core.known == true and status_is_terminal(core) and
                terminal_disposition(core) or "observing"
            local meta = {
                handle = handle,
                name = old.ability,
                idempotencyKey = old.idempotency_key,
            }
            local current_owner = self.pending ~= nil
            local refreshed = self:_snapshot(core, disposition, meta, false)
            refreshed.can_submit = not current_owner
            refreshed.blocks_submission = current_owner
            self:_record_receipt(refreshed)
            if self.lastStatus and self.lastStatus.command_handle == handle and
                not current_owner then
                self.lastStatus = copy_snapshot(refreshed)
            end
            return
        end
    end
    self.receiptRefreshCursor = (self.receiptRefreshCursor % count) + 1
end

function AbilityExecutor:_poll_pending()
    local pending = self.pending
    if not pending then return copy_snapshot(self.lastStatus) end

    local core = gos.abilities.command_status(pending.handle)
    if type(core) ~= "table" then
        return self:_publish(unknown_core("invalid_command_status", false),
            pending.cancelRequested and "cancel_requested" or "unresolved", pending)
    end
    if core.known == true and status_is_terminal(core) then
        return self:_finish_core_status(core)
    end
    return self:_publish(core,
        pending.cancelRequested and "cancel_requested" or
            (core.known == true and "owned" or "unresolved"),
        pending)
end

function AbilityExecutor:tick()
    local polled_handle = self.pending and self.pending.handle or nil
    local status = self:_poll_pending()
    self:_refresh_one_receipt(polled_handle)
    return copy_snapshot(self.lastStatus or status)
end

function AbilityExecutor:owns_command()
    return self.pending ~= nil
end

function AbilityExecutor:can_submit()
    return self.pending == nil
end

-- Backward-compatible alias. New code should prefer owns_command().
function AbilityExecutor:has_pending()
    return self:owns_command()
end

function AbilityExecutor:can_replace()
    return self.lastStatus ~= nil and self.lastStatus.can_replace == true
end

function AbilityExecutor:status()
    return copy_snapshot(self.lastStatus)
end

function AbilityExecutor:receipt(handle)
    handle = handle or (self.lastStatus and self.lastStatus.command_handle)
    if type(handle) ~= "string" then return nil end
    return copy_snapshot(self.receiptByHandle[handle])
end

function AbilityExecutor:receipts(limit)
    local out = {}
    local max_count = type(limit) == "number" and
        math.max(0, math.floor(limit)) or RECEIPT_CAPACITY
    if max_count == 0 then return out end
    for index = #self.receiptOrder, 1, -1 do
        local receipt = self.receiptByHandle[self.receiptOrder[index]]
        if receipt then
            out[#out + 1] = copy_snapshot(receipt)
            if #out >= max_count then break end
        end
    end
    return out
end

function AbilityExecutor:last_receipts(limit)
    return self:receipts(limit)
end

function AbilityExecutor:_operation_result(disposition, accepted, core, owner_meta,
        new_command, request_name, request_key, reason_override)
    core = type(core) == "table" and copy_table(core) or nil
    owner_meta = owner_meta or self.pending
    local handle = core and core.command_handle or
        (owner_meta and owner_meta.handle) or nil
    local owner_ability = core and core.name or
        (owner_meta and owner_meta.name) or nil
    local owner_key = owner_meta and owner_meta.idempotencyKey or nil
    local owns = self.pending ~= nil
    local command_state = core and (core.command_state or core.state) or
        (self.lastStatus and self.lastStatus.state) or nil
    local legacy_state = legacy_executor_state(
        self.lastStatus and self.lastStatus.disposition or disposition,
        self.pending, owns)
    return {
        -- Legacy surface.
        ok = accepted == true,
        reason = reason_override or (core and core.reason) or disposition,
        code = core and core.code or nil,
        command_handle = handle,
        command_state = command_state,
        executor_state = legacy_state,
        deduplicated = disposition == "deduplicated",
        adopted = disposition == "adopted",
        awaiting_terminal = owns,
        replaced_command_handle =
            disposition == "replaced" and owner_meta and owner_meta.replacesHandle or nil,

        -- V2 surface.
        disposition = disposition,
        accepted = accepted == true,
        admission_pending = disposition == "admission_pending",
        new_command = new_command == true,
        owns_command = owns,
        blocks_submission = owns,
        can_submit = not owns,
        can_replace = owns and self:can_replace() or false,
        ability = owner_ability,
        idempotency_key = owner_key,
        request_ability = request_name,
        request_idempotency_key = request_key,
        core = core,
    }
end

function AbilityExecutor:cancel(reason)
    local pending = self.pending
    if not pending then
        return self:_operation_result("no_owner", false, nil, nil, false)
    end
    if pending.cancelRequested then
        return self:_operation_result("cancel_requested", false,
            self.lastStatus and self.lastStatus.core or nil, pending, false)
    end

    pending.cancelReason = reason or "cancel_requested"
    pending.cancelRequested = true

    local released = gos.abilities.release_command(pending.handle)
    if type(released) ~= "table" then
        self:_publish(unknown_core("invalid_cancel_response", false),
            "cancel_requested", pending)
        return self:_operation_result("cancel_requested", false, nil, pending, false)
    end
    if released.known == true and status_is_terminal(released) then
        local finished = self:_finish_core_status(released)
        return self:_operation_result(finished.disposition,
            released.state == "cancelled", released, pending, false)
    end
    self:_publish(released, "cancel_requested", pending)
    return self:_operation_result("cancel_requested", released.ok == true,
        released, pending, false)
end

function AbilityExecutor:_adopt_retained_command(core, request_name, request_key, target)
    local handle = core.command_handle
    self.pending = {
        handle = handle,
        name = core.name or "retained_core_command",
        idempotencyKey = request_key,
        targetIdentity = target_identity(target),
        adopted = true,
        submissionCore = copy_table(core),
    }
    local status = {
        known = true,
        state = core.command_state or "unknown",
        terminal = false,
        acknowledged = false,
        reason = core.reason or "ability_command_busy",
        command_handle = handle,
        name = core.name,
    }
    self:_publish(status, "owned", self.pending)
    return self:_operation_result(
        "adopted", false, core, self.pending, false, request_name, request_key)
end

function AbilityExecutor:submit(name, target, options)
    local normalized, option_error = validate_options(options)
    if not normalized then
        return self:_operation_result("invalid", false, nil, nil, false,
            name, type(options) == "table" and options.idempotencyKey or nil,
            option_error)
    end
    local key = normalized.idempotencyKey

    if self.pending then
        if same_request(self.pending, name, target, key) then
            return self:_operation_result("deduplicated", true,
                self.pending.submissionCore, self.pending, false, name, key,
                "idempotent_command_pending")
        end
        return self:_operation_result("owner_busy", false, nil,
            self.pending, false, name, key, "executor_command_pending")
    end

    local core = gos.abilities.cast(name, target, cast_options(normalized))
    if type(core) ~= "table" then
        return self:_operation_result(
            "invalid", false, nil, nil, false, name, key,
            "invalid_cast_result")
    end

    local receipt = core.command_handle and self.receiptByHandle[core.command_handle]
    if retained_core_busy_result(core) and normalized.adoptBusy == true and
        receipt and receipt.idempotency_key == key and receipt.ability == name and
        receipt.target_identity == target_identity(target) then
        return self:_adopt_retained_command(core, name, key, target)
    end
    if core.ok ~= true then
        local disposition = admission_pending_result(core) and
            "admission_pending" or "rejected"
        return self:_operation_result(
            disposition, false, core, nil, false, name, key)
    end
    if type(core.command_handle) ~= "string" then
        return self:_operation_result("invalid", false, {
            code = core.code,
            reason = "missing_command_handle",
        }, nil, false, name, key)
    end

    self.pending = {
        handle = core.command_handle,
        name = name,
        idempotencyKey = key,
        targetIdentity = target_identity(target),
        submissionCore = copy_table(core),
    }
    local initial = copy_table(core)
    initial.known = true
    initial.state = core.command_state or "queued"
    initial.terminal = false
    initial.acknowledged = false
    initial.command_handle = core.command_handle
    initial.name = name
    self:_publish(initial, "owned", self.pending)
    return self:_operation_result(
        "submitted", true, core, self.pending, true, name, key)
end

function AbilityExecutor:replace(name, target, options)
    local normalized, option_error = validate_options(options)
    if not normalized then
        return self:_operation_result("invalid", false, nil, self.pending, false,
            name, type(options) == "table" and options.idempotencyKey or nil,
            option_error)
    end
    local key = normalized.idempotencyKey

    local pending = self.pending
    if not pending then
        return self:_operation_result(
            "rejected", false, nil, nil, false, name, key,
            "executor_command_missing")
    end
    if same_request(pending, name, target, key) then
        return self:_operation_result("deduplicated", true,
            pending.submissionCore, pending, false, name, key,
            "idempotent_command_pending")
    end
    if not self:can_replace() then
        return self:_operation_result(
            "owner_busy", false, nil, pending, false, name, key,
            "executor_command_pending")
    end

    local core_options = cast_options(normalized) or {}
    core_options.replace_command = pending.handle
    local core = gos.abilities.cast(name, target, core_options)
    if type(core) ~= "table" then
        return self:_operation_result(
            "invalid", false, nil, pending, false, name, key,
            "invalid_cast_result")
    end
    if core.ok ~= true then
        local disposition = admission_pending_result(core) and
            "admission_pending" or "rejected"
        return self:_operation_result(
            disposition, false, core, pending, false, name, key)
    end
    if type(core.command_handle) ~= "string" then
        return self:_operation_result("invalid", false, {
            code = core.code,
            reason = "missing_command_handle",
        }, pending, false, name, key)
    end

    local retained = pending
    self.pending = {
        handle = core.command_handle,
        name = name,
        idempotencyKey = key,
        targetIdentity = target_identity(target),
        submissionCore = copy_table(core),
        replacesHandle = retained.handle,
        replacedPending = retained,
    }
    local initial = copy_table(core)
    initial.known = true
    initial.state = core.command_state or "queued"
    initial.terminal = false
    initial.acknowledged = false
    initial.command_handle = core.command_handle
    initial.name = name
    self:_publish(initial, "owned", self.pending)
    return self:_operation_result(
        "replaced", true, core, self.pending, true, name, key)
end

return {
    new = AbilityExecutor.new,
    terminal_state = AbilityExecutor.terminal_state,
}
