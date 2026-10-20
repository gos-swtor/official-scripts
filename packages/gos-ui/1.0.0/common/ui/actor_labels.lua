-- Presentation-only actor labels. Core is the sole name authority.
-- No world lookup, cast, file I/O, tick callback or process-wide singleton.
local M = { build_id = "2026-09-15-actor-labels-r1" }
local Registry = {}; Registry.__index = Registry
local CHUNK, MAX_CAPACITY = 64, 4096
local function epoch(value)
    return type(value) == "string" and #value == 23 and value:match("^actors:%x+$") ~= nil and value ~= "actors:0000000000000000"
end
local function handle(value)
    return type(value) == "string" and #value == 21 and value:match("^unit:%x+$") ~= nil and
        value ~= "unit:0000000000000000"
end
local function revision(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end
local function name(value)
    return type(value) == "string" and #value > 0 and #value <= 63 and
        not value:find("\0", 1, true) and utf8.len(value) ~= nil
end
function M.new(initial_epoch, capacity)
    capacity = capacity or 2048
    assert(revision(capacity) and capacity > 0 and capacity <= MAX_CAPACITY)
    return setmetatable({ epoch = epoch(initial_epoch) and initial_epoch or nil,
        capacity = capacity, count = 0, records = {}, chunks = {}, next_chunk = 1,
        version = 0, observed_revision = nil, status = "waiting", limited = false }, Registry)
end
function M.text(label, placeholder)
    return label and label.name or placeholder or "Unknown actor"
end
function Registry:note(current_epoch, current_revision)
    if not epoch(current_epoch) or not revision(current_revision) then
        self.status = "metadata unavailable"; return false
    end
    if not self.epoch then self.epoch = current_epoch end
    if current_epoch ~= self.epoch then
        self.status = "previous session"; return false
    end
    self.observed_revision = math.max(self.observed_revision or 0, current_revision)
    return true
end
function Registry:track(actor_handle, actor_epoch, initial_name)
    -- Already admitted identities need no repeated pattern/UTF-8 validation.
    local cached = actor_epoch == self.epoch and type(actor_handle) == "string" and self.records[actor_handle]
    if cached then
        if cached.name == nil and name(initial_name) then
            cached.name = initial_name; self.version = self.version + 1
        end
        return cached
    end
    if not handle(actor_handle) or not epoch(actor_epoch) then return nil end
    if not self.epoch then self.epoch = actor_epoch end
    if self.epoch ~= actor_epoch then return nil end
    local label = self.records[actor_handle]
    if not label then
        if self.count == self.capacity then self.limited = true; return nil end
        label = { handle = actor_handle, epoch = actor_epoch, revision = 0, status = "not_retained" }
        self.records[actor_handle] = label
        local index = math.floor(self.count / CHUNK) + 1
        local chunk = self.chunks[index]
        if not chunk then chunk = { handles = {} }; self.chunks[index] = chunk end
        chunk.handles[#chunk.handles + 1] = actor_handle
        chunk.revision = nil -- This exact request set has never been read.
        self.count = self.count + 1
    end
    -- Immutable older event names bootstrap, but never downgrade a later label.
    if label.name == nil and name(initial_name) then
        label.name = initial_name
        self.version = self.version + 1
    end
    return label
end
function Registry:refresh(current_epoch, current_revision, max_batches)
    if not self:note(current_epoch, current_revision) then return false end
    if type(gos.actor_names) ~= "function" then self.status = "Core update required"; return false end
    max_batches = max_batches or 2
    assert(revision(max_batches) and max_batches > 0 and max_batches <= 4)
    local before, examined, fetched = self.version, 0, 0
    while examined < #self.chunks and fetched < max_batches do
        local index = self.next_chunk
        local chunk = self.chunks[index]
        self.next_chunk = index % #self.chunks + 1
        examined = examined + 1
        if chunk.revision ~= self.observed_revision then
            local result = gos.actor_names(chunk.handles, self.epoch)
            fetched = fetched + 1
            if type(result) ~= "table" or result.status ~= "ready" or result.epoch ~= self.epoch then
                self.status = type(result) == "table" and result.status or "metadata unavailable"
                return self.version ~= before
            end
            if not revision(result.revision) or type(result.items) ~= "table" or #result.items ~= #chunk.handles then
                self.status = "invalid metadata"; return self.version ~= before
            end
            -- Validate the whole bounded response before acknowledging this chunk.
            for i = 1, #chunk.handles do
                local row = result.items[i]
                if type(row) ~= "table" or row.handle ~= chunk.handles[i] or not revision(row.revision) or
                    row.revision > result.revision or
                    (row.status ~= "ready" and row.status ~= "not_retained") or
                    (row.status == "ready" and not name(row.name)) then
                    self.status = "invalid metadata"; return self.version ~= before
                end
            end
            for i = 1, #chunk.handles do
                local row = result.items[i]
                local label = self.records[row.handle]
                label.status = row.status
                if row.status == "ready" and row.revision > label.revision then
                    if label.name ~= row.name then label.name = row.name; self.version = self.version + 1 end
                    label.revision = row.revision
                end -- Not retained never erases the encounter's delivered name.
            end
            chunk.revision = result.revision
            self.observed_revision = math.max(self.observed_revision, result.revision)
        end
    end
    self.status = "ready"
    return self.version ~= before
end
return M
