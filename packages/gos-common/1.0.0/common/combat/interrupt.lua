-- Shared PvP interrupt decisions for every combat style with an interrupt.
-- Each top-level class script owns one M.new() controller and its own executor.
-- No tick callback, target selection, executor polling/cancellation, or guessed
-- cast duration lives here. Current cast snapshots are matched by exact name.
local DB = require("combat.interrupt_db")
local M = { build_id = "2026-09-29-shared-interrupt-r5-exact-admission-identity",
    db_revision = DB.revision }
local MAX_CASTS, STALE_MS, RETRY_MS = 64, 750, 120
local by_name = {}

local function finite(v)
    return type(v)=="number" and v==v and v>-math.huge and v<math.huge
end
local function normalize(v)
    if type(v)~="string" then return nil end
    v=v:lower():gsub("^%s+",""):gsub("%s+$","")
    return v~="" and v or nil
end
local function method(object,name,...)
    if not object or type(object[name])~="function" then return nil end
    local ok,result=pcall(object[name],object,...)
    return ok and result or nil
end
local function to_set(values)
    local result={}
    for _,value in ipairs(values or {}) do result[normalize(value)]=true end
    return result
end

for _,rule in ipairs(DB.rules) do
    local key=normalize(rule.name)
    assert(key and not by_name[key] and finite(rule.priority),
        "Invalid/duplicate interrupt rule: "..tostring(rule.name))
    rule._styles,rule._disciplines=to_set(rule.styles),to_set(rule.disciplines)
    by_name[key]=rule
end
function M.lookup(name,style,discipline)
    local rule=by_name[normalize(name)]
    if not rule then return nil,"not_catalogued" end
    style,discipline=normalize(style),normalize(discipline)
    if next(rule._styles) and style and not rule._styles[style] then
        return nil,"style_mismatch"
    end
    if next(rule._disciplines) and discipline and not rule._disciplines[discipline] then
        return nil,"discipline_mismatch"
    end
    return rule,"exact_name_match"
end

function M.objective(name)
    return DB.objectives[normalize(name)]
end

function M.capabilities(loadout)
    if type(loadout)~="table" or loadout.status~="ready" or
        type(loadout.known)~="table" then
        return {status="unavailable",reason="loadout_unavailable"}
    end
    local ability=DB.interruptors[loadout.combat_style]
    if not ability then return {status="unavailable",reason="unsupported_style"} end
    if loadout.known[ability]~=true then
        return {status="unavailable",reason="interrupt_not_learned",ability=ability}
    end
    return {status="ready",ability=ability,style=loadout.combat_style}
end

function M.settings(schema)
    assert(type(schema)=="table" and type(schema.fields)=="table")
    local fields={
        {key="interrupt_enabled",type="bool",label="Shared PvP Must-Interrupt",default=true,
         tooltip="Interrupt exact catalogued high-value hostile player casts with the current combat style interrupt."},
        {key="interrupt_progress_percent",type="int",label="Interrupt At Cast %",default=85,min=50,max=95,step=1,
         tooltip="Wait until this much of the observed cast/channel has elapsed. Default 85%. No hard-coded cast duration is guessed."},
        {key="interrupt_current_target_only",type="bool",label="Interrupt: Current Target Only",default=false,
         tooltip="Only consider casts from your exact current hostile player target. The shared controller returns that exact unit/handle to the class adapter."},
        {key="interrupt_preserve_stealth",type="bool",label="Interrupt: Preserve Stealth",default=true,
         tooltip="Do not break an observed local Stealth state just to interrupt."},
        {key="interrupt_diagnostics",type="bool",label="Interrupt Diagnostics",default=false},
    }
    for _,entry in ipairs(fields) do
        for _,existing in ipairs(schema.fields) do
            assert(existing.key~=entry.key,"Duplicate interrupt setting: "..entry.key)
        end
        schema.fields[#schema.fields+1]=entry
    end
    return schema
end

function M.policy(settings)
    local function value(key)
        if type(settings)~="table" then return nil end
        if settings[key]~=nil then return settings[key] end
        return type(settings.fields)=="table" and settings.fields[key] or nil
    end
    local percent=value("interrupt_progress_percent")
    if not finite(percent) then percent=DB.default_progress*100 end
    percent=math.max(50,math.min(95,percent))
    return {
        enabled=value("interrupt_enabled")~=false,
        progress=percent/100,
        current_target_only=value("interrupt_current_target_only")==true,
        preserve_stealth=value("interrupt_preserve_stealth")~=false,
        diagnostics=value("interrupt_diagnostics")==true,
    }
end

local function alive_hostile_player(unit)
    if method(unit,"type")~="player" or method(unit,"reaction")~="hostile" then return false end
    local hp=method(unit,"hp")
    return type(hp)=="table" and finite(hp.current) and hp.current>0
end

local function immune(unit,style)
    if DB.always_skip_styles[style] then return true,DB.always_skip_styles[style] end
    for _,name in ipairs(DB.immunity_buffs) do
        local effect=method(unit,"effect",name,{kind="buff"})
        if type(effect)=="table" and effect.status=="ready" and
            effect.truncated==false and effect.present==true then
            return true,"interrupt_immunity:"..name
        end
    end
    return false,nil
end
local function observe_cast(observations,cast,now)
    if type(cast)~="table" or cast.active==false or type(cast.unit_handle)~="string" or
        not cast.has_timing or not finite(cast.remaining) or cast.remaining<=0 then return nil end
    local name=normalize(cast.name)
    if not name then return nil end
    local identity=type(cast.ability_handle)=="string" and cast.ability_handle or name
    local key=cast.unit_handle.."|"..identity
    local row=observations[key]
    if not row or now-(row.last_seen_ms or 0)>STALE_MS or
        (finite(row.last_remaining) and cast.remaining>row.last_remaining+0.10) then
        row={key=key,handle=cast.unit_handle,name=name,max_remaining=cast.remaining,
            last_remaining=cast.remaining,last_seen_ms=now,attempted=false,retry_ms=0}
        observations[key]=row
    else
        row.max_remaining=math.max(row.max_remaining or cast.remaining,cast.remaining)
        row.last_remaining,row.last_seen_ms=cast.remaining,now
    end
    if not finite(row.max_remaining) or row.max_remaining<=0 then return nil end
    row.remaining=cast.remaining
    row.progress=math.max(0,math.min(1,1-cast.remaining/row.max_remaining))
    return row
end

local function cleanup(observations,now)
    for key,row in pairs(observations) do
        if now-(row.last_seen_ms or 0)>STALE_MS then observations[key]=nil end
    end
end

local function better(a,b)
    if not b then return true end
    if a.priority~=b.priority then return a.priority<b.priority end
    if a.progress~=b.progress then return a.progress>b.progress end
    if a.remaining~=b.remaining then return a.remaining<b.remaining end
    return a.handle<b.handle
end

local function evaluate(observations,context)
    context=type(context)=="table" and context or {}
    local policy=context.policy or M.policy()
    local cap=M.capabilities(context.loadout)
    local plan={status="ready",reason="no_candidate",capabilities=cap}
    if not policy.enabled or cap.status~="ready" then
        plan.status,plan.reason="unavailable",not policy.enabled and "disabled" or cap.reason
        return plan
    end
    local world=context.world
    local player=world and world.player or nil
    if not world or not player then plan.status,plan.reason="unavailable","world_unavailable"; return plan end
    local scope_handle=nil
    if policy.current_target_only then
        local current=world.current_target
        if not alive_hostile_player(current) then
            plan.reason="current_target_unavailable"
            return plan
        end
        scope_handle=method(current,"handle")
        if type(scope_handle)~="string" then
            plan.reason="current_target_handle_unavailable"
            return plan
        end
    end
    -- Keep the ordinary tick cheap. Local stealth/readiness metadata is only
    -- touched after a catalogued hostile cast has actually reached the timing gate.
    local casts=context.casts
    if casts==nil and gos.events and type(gos.events.casts)=="function" then
        local ok,result=pcall(gos.events.casts)
        if ok then casts=result end
    end
    if type(casts)~="table" or #casts>MAX_CASTS then
        plan.status,plan.reason="unavailable","cast_snapshot_unavailable"
        return plan
    end
    local now=gos.time_ms()
    if not finite(now) then plan.status,plan.reason="unavailable","time_unavailable"; return plan end
    local best, preferred
    for i=1,#casts do
        local cast,row=casts[i],nil
        if type(cast)=="table" and type(cast.name)=="string" then
            row=observe_cast(observations,cast,now)
        end
        if row and (scope_handle==nil or row.handle==scope_handle) and
            not row.attempted and now>=(row.retry_ms or 0) then
            local unit=world:resolve(row.handle)
            if alive_hostile_player(unit) then
                local style=normalize(method(unit,"combat_style"))
                local discipline=normalize(method(unit,"discipline"))
                local rule=M.lookup(cast.name,style,discipline)
                if rule and row.progress>=policy.progress then
                    local blocked=immune(unit,style)
                    if not blocked then
                    local candidate={ability=cap.ability,handle=row.handle,cast_key=row.key,
                            cast=rule.name,tier=rule.tier,priority=rule.priority,
                            progress=row.progress,remaining=row.remaining,style=style,discipline=discipline}
                    if candidate.cast_key==context.preferred_cast_key then
                        preferred=candidate
                    end
                    if better(candidate,best) then best=candidate end
                    end
                end
            end
        end
    end
    cleanup(observations,now)
    if context.preferred_cast_key then best=preferred end
    if not best then return plan end

    if policy.preserve_stealth then
        local stealth=method(player,"effect","Stealth",{kind="buff"})
        if type(stealth)~="table" or stealth.status~="ready" or stealth.truncated~=false or
            stealth.present~=false then
            plan.reason="stealth_preservation"
            return plan
        end
    end
    local info=gos.abilities.info(cap.ability)
    if type(info)~="table" or info.on_bar~=true or type(info.ability_handle)~="string" then
        plan.reason="interrupt_unbound"
        return plan
    end
    if context.preferred_ability_handle and
        info.ability_handle~=context.preferred_ability_handle then
        plan.reason="interrupt_ability_changed"
        return plan
    end
    local cd=gos.abilities.cooldown_remaining(cap.ability)
    if finite(cd) and cd>0 then
        plan.reason="interrupt_cooldown"
        return plan
    end
    best.ability_handle=info.ability_handle
    plan.candidate,plan.reason=best,"candidate"
    return plan
end

local function attempt(observations,context)
    assert(type(context)=="table" and type(context.submit)=="function")
    if context.active~=true or context.pending==true then return false end
    context.policy=context.policy or M.policy(context.settings)
    local plan=evaluate(observations,context)
    local candidate=plan.candidate
    if not candidate then return false end
    local unit=context.world and context.world:resolve(candidate.handle) or nil
    if not alive_hostile_player(unit) then return false end
    local result=context.submit(candidate,unit)
    local now=gos.time_ms()
    local row=observations[candidate.cast_key]
    if type(result)=="table" and result.admission_pending==true then
        local player_handle=method(context.world and context.world.player,"handle")
        if type(player_handle)~="string" then return true,nil end
        return true,{cast_key=candidate.cast_key,ability_handle=candidate.ability_handle,
            player_handle=player_handle,actor_epoch=context.world and context.world.actor_epoch or nil}
    end
    if row and finite(now) then row.retry_ms=now+RETRY_MS end
    if type(result)=="table" and (result.accepted==true or result.owned==true) then
        if row then row.attempted=true end
        if result.accepted==true and type(context.log)=="function" then
            context.log("info",string.format("interrupt queued=true ability=%s cast=%s tier=%s target=%s progress=%.0f%% remaining=%.3f outcome=unconfirmed",
                candidate.ability,candidate.cast,candidate.tier,candidate.handle,candidate.progress*100,candidate.remaining))
        end
        return true,nil
    end
    return false,nil
end

function M.new()
    local observations = {}
    local pending_admission
    local controller = {
        build_id = M.build_id,
        db_revision = M.db_revision,
    }
    function controller:evaluate(context)
        return evaluate(observations, context)
    end
    function controller:attempt(context)
        context=type(context)=="table" and context or {}
        if pending_admission then
            local world=context.world
            local player_handle=method(world and world.player,"handle")
            local actor_epoch=world and world.actor_epoch or nil
            if player_handle~=pending_admission.player_handle or
                pending_admission.actor_epoch~=nil and actor_epoch~=nil and
                    actor_epoch~=pending_admission.actor_epoch then
                pending_admission=nil
                return false
            end
        end
        context.preferred_cast_key=pending_admission and pending_admission.cast_key or nil
        context.preferred_ability_handle=pending_admission and
            pending_admission.ability_handle or nil
        local handled,next_pending=attempt(observations, context)
        pending_admission=next_pending
        return handled
    end
    function controller:has_local_pending()
        return pending_admission~=nil
    end
    function controller:reset()
        observations = {}
        pending_admission=nil
    end
    return controller
end

return M
