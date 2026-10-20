local Combat = {}

local handlers = {
    player = {},
    current_target = {},
    ally = {},
}
local cursor
local started = false
local dropped_total = 0

local function run_handlers(list, event)
    if not list then
        return
    end
    for index = 1, #list do
        local ok, err = pcall(list[index], event)
        if not ok then
            gos.log.error("[combat-events] handler failed: " .. tostring(err))
        end
    end
end

local function matching_handlers(scope, kind, action)
    return scope[kind] ~= nil or (action ~= nil and action ~= kind and scope[action] ~= nil)
end

local function dispatch(scope, event, kind, action)
    run_handlers(scope[kind], event)
    if action ~= nil and action ~= kind then
        run_handlers(scope[action], event)
    end
end

local function poll()
    local batch = gos.events.combat(cursor)
    cursor = batch.cursor

    if batch.dropped > 0 then
        dropped_total = dropped_total + batch.dropped
        gos.log.warn("[combat-events] dropped " .. batch.dropped ..
            " events (total " .. dropped_total .. ")")
    end

    local world = gos.world()
    local player_handle = world.player and world.player:handle() or nil
    local target_handle = world.current_target and world.current_target:handle() or nil

    for _, event in ipairs(batch.events) do
        local destination = event.target_handle
        local kind = event.kind
        local action = event.action

        if destination ~= nil and destination == player_handle and
            matching_handlers(handlers.player, kind, action) then
            dispatch(handlers.player, event, kind, action)
        end
        if destination ~= nil and destination == target_handle and
            matching_handlers(handlers.current_target, kind, action) then
            dispatch(handlers.current_target, event, kind, action)
        end
        if destination ~= nil and destination ~= player_handle and
            matching_handlers(handlers.ally, kind, action) then
            local unit = world:resolve(destination)
            if unit and unit:reaction() == "friendly" and not unit:is_local_player() then
                dispatch(handlers.ally, event, kind, action)
            end
        end
    end
end

local function register(scope, event_name, callback)
    if type(event_name) ~= "string" or event_name == "" then
        error("combat event name must be a non-empty string", 3)
    end
    if type(callback) ~= "function" then
        error("combat event callback must be a function", 3)
    end

    local list = scope[event_name]
    if not list then
        list = {}
        scope[event_name] = list
    end
    list[#list + 1] = callback

    if not started then
        started = true
        gos.on_tick(poll)
    end
end

function Combat.on_player(event_name, callback)
    register(handlers.player, event_name, callback)
end

function Combat.on_current_target(event_name, callback)
    register(handlers.current_target, event_name, callback)
end

function Combat.on_ally(event_name, callback)
    register(handlers.ally, event_name, callback)
end

return Combat
