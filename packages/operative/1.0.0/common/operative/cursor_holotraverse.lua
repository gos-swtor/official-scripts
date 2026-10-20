-- Manual cursor Holotraverse for every Operative discipline.
-- Selection is screen-space only; casting stays on the dispatcher's executor.
local Mirror = require("operative.mirror")
local CurrentLoadout
local M = { build_id = "operative-cursor-holotraverse-r7-personal-defaults" }
local ABILITY = "Holotraverse"
local PREFIX = "operative:cursor-holotraverse:"
local MAX_UNITS = 512 -- GOS_SWTOR_MAX_WORLD_UNITS
local MAX_RANGE_METERS = 30
local METERS_PER_WORLD_UNIT = 10
-- Physical chord-down state authorizes every new attempt. There is no key-up
-- activation window or one-success latch. Actual commands still own their exact
-- target through native completion and cleanup before another attempt can start.
local PREVIEW_INTERVAL_MS = 50
local filters = {
    "All", "All players", "Allied players", "Allies + NPCs",
    "Hostile players", "Hostiles + NPCs", "NPCs + companions",
}
local modifiers = {
    ["None"]={false,false,false}, ["Ctrl"]={true,false,false},
    ["Shift"]={false,true,false}, ["Alt"]={false,false,true},
    ["Ctrl + Shift"]={true,true,false}, ["Ctrl + Alt"]={true,false,true},
    ["Shift + Alt"]={false,true,true}, ["Ctrl + Shift + Alt"]={true,true,true},
}
local function finite(v)
    return type(v)=="number" and v==v and v>-math.huge and v<math.huge
end
local function method(unit, name, ...)
    if unit == nil or type(unit[name]) ~= "function" then return nil end
    local ok, value = pcall(unit[name], unit, ...)
    if ok then return value end
end
local function value(settings, key, default)
    local fields = type(settings)=="table" and (settings.fields or settings) or {}
    local v=fields[key]; if v==nil then return default end; return v
end
function M.settings(schema)
    local rows = {
        {key="cursor_holo_enabled",type="bool",label="Cursor Holotraverse",default=true,
         tooltip="Manual cursor-targeted Holotraverse for all Operative specs, independent of the rotation key. Requires learned Holotraverse and the cursor API Core."},
        {key="cursor_holo_key",type="hotkey",label="Holotraverse Key",default="v",
         tooltip="Hold the complete chord to continuously attempt Holotraverse as soon as native rules permit. It rearms after settled outcomes and waits through cooldown without another press. Releasing either key stops new submissions immediately; an already submitted command may still finish. Do not bind this chord to an in-game ability."},
        {key="cursor_holo_modifier",type="select",label="Holotraverse Modifier",default="Shift",
         options={"None","Ctrl","Shift","Alt","Ctrl + Shift","Ctrl + Alt","Shift + Alt","Ctrl + Shift + Alt"}},
        {key="cursor_holo_filter",type="select",label="Holotraverse Targets",default="All",options=filters,
         tooltip="All includes friendly, hostile and neutral players/NPCs/companions, never self or objects. Other filters use the exact observed reaction/type."},
        {key="cursor_holo_radius",type="int",label="Holotraverse Cursor Radius (px)",default=120,min=20,max=600,step=10,
         tooltip="Pick the nearest projected body center inside this screen-pixel circle, within Holotraverse range. This is not world distance."},
        {key="cursor_holo_preview",type="bool",label="Holotraverse Cursor Preview",default=true,
         tooltip="Show radius and candidate while the configured modifier is held. Without a modifier, preview while holding the base key. A marker is not proof of line of sight."},
        {key="cursor_holo_reserve",type="bool",label="Reserve Holotraverse for Hotkey",default=true,
         disciplines={"Lethality"},
         tooltip="While Cursor Holotraverse is enabled, prevent Lethality from automatically spending Holotraverse for gap closing or Tactical Advantage."},
    }
    for _,row in ipairs(rows) do
        row.requires_ability=ABILITY
        for _,existing in ipairs(schema.fields) do assert(existing.key~=row.key,"Duplicate cursor Holotraverse setting") end
        schema.fields[#schema.fields+1]=row
    end
    return schema
end
function M.reserve_rotation(settings)
    return value(settings,"cursor_holo_enabled",true)==true and
        value(settings,"cursor_holo_reserve",true)==true
end
function M.matches(filter,kind,reaction)
    if kind~="player" and kind~="npc" and kind~="companion" then return false end
    if reaction~="friendly" and reaction~="hostile" and reaction~="neutral" then return false end
    if filter=="All" then return true end
    if filter=="All players" then return kind=="player" end
    if filter=="Allied players" then return kind=="player" and reaction=="friendly" end
    if filter=="Allies + NPCs" then return reaction=="friendly" end
    if filter=="Hostile players" then return kind=="player" and reaction=="hostile" end
    if filter=="Hostiles + NPCs" then return reaction=="hostile" end
    if filter=="NPCs + companions" then return kind=="npc" or kind=="companion" end
    return false
end
local function alive(unit)
    local hp=method(unit,"hp")
    return type(hp)=="table" and finite(hp.current) and finite(hp.max) and
        hp.max>0 and hp.current>0 and hp.current<=hp.max
end
local function eligible(unit,player,filter)
    if unit==nil then return false,"target_unresolved" end
    if unit==player then return false,"self_target" end
    local is_local=method(unit,"is_local_player")
    if is_local~=false then return false,"local_player_flag_not_false" end
    if not alive(unit) then
        local hp=method(unit,"hp")
        local dead=type(hp)=="table" and finite(hp.current) and hp.current<=0
        return false,dead and "target_dead" or "target_hp_unavailable_or_invalid"
    end
    if not M.matches(filter,method(unit,"type"),method(unit,"reaction")) then
        return false,"target_filter_mismatch"
    end
    if method(unit,"is_on_screen")~=true then return false,"target_not_projected" end
    -- Native distance is the same game-world unit used by the existing routes.
    local distance=method(unit,"distance")
    if not finite(distance) or distance<0 then return false,"target_distance_unavailable" end
    if distance*METERS_PER_WORLD_UNIT>MAX_RANGE_METERS then return false,"target_out_of_range" end
    return true,"eligible"
end

-- Only called for an actual request diagnostic, never during preview scans.
local function target_diagnostic(unit)
    local hp=method(unit,"hp")
    local distance=method(unit,"distance")
    return " resolved="..tostring(unit~=nil)..
        " type="..tostring(method(unit,"type"))..
        " reaction="..tostring(method(unit,"reaction"))..
        " on_screen="..tostring(method(unit,"is_on_screen"))..
        " hp="..tostring(type(hp)=="table" and hp.current or nil)..
        "/"..tostring(type(hp)=="table" and hp.max or nil)..
        " distance_m="..(finite(distance) and string.format("%.3f",distance*METERS_PER_WORLD_UNIT) or "unknown")
end
function M.pick(world,cursor,filter,radius,counts)
    if not world or not world.player or not cursor or cursor.available~=true or
        not finite(cursor.x) or not finite(cursor.y) or not finite(cursor.width) or not finite(cursor.height) or
        cursor.width<=0 or cursor.height<=0 or not finite(radius) or radius<=0 then
        return nil,"cursor_unavailable"
    end
    local units=method(world,"units")
    if type(units)~="table" or #units>MAX_UNITS then return nil,"world_unavailable" end
    local best,limit=nil,radius*radius
    if counts then
        counts.total,counts.eligible,counts.range,counts.projection,counts.other,counts.outside = #units,0,0,0,0,0
        counts.nearest_px=nil
    end
    for _,unit in ipairs(units) do
        local allowed,gate=eligible(unit,world.player,filter)
        if counts and not allowed then
            if gate=="target_out_of_range" then counts.range=counts.range+1
            elseif gate=="target_not_projected" then counts.projection=counts.projection+1
            else counts.other=counts.other+1 end
        end
        if allowed then
            if counts then counts.eligible=counts.eligible+1 end
            local pos=method(unit,"screen_position","center")
            local handle=method(unit,"handle")
            if type(pos)=="table" and finite(pos.x) and finite(pos.y) and type(handle)=="string" and
                pos.x>=0 and pos.y>=0 and pos.x<cursor.width and pos.y<cursor.height then
                local dx,dy=pos.x-cursor.x,pos.y-cursor.y
                local d2=dx*dx+dy*dy
                if counts then
                    local pixels=math.sqrt(d2)
                    counts.nearest_px=math.min(counts.nearest_px or pixels,pixels)
                    if d2>limit then counts.outside=counts.outside+1 end
                end
                if d2<=limit and (not best or d2<best.d2 or (d2==best.d2 and handle<best.handle)) then
                    best={handle=handle,d2=d2,x=pos.x,y=pos.y}
                end
            elseif counts then
                counts.projection=counts.projection+1
            end
        end
    end
    return best,best and "candidate" or "no_target_in_cursor_radius"
end
local function exact(result,handle)
    return type(result)=="table" and result.target_mode=="explicit" and
        result.target_valid==true and result.requested_target_handle==handle and
        result.target_handle==handle and result.target_fallback=="none" and result.fallback_used~=true
end
local function chord_state(key,modifier)
    local mask=modifiers[modifier]
    if not mask then return false,false,false end
    local ctrl=gos.input.is_down(17)==true
    local shift=gos.input.is_down(16)==true
    local alt=gos.input.is_down(18)==true
    local match=ctrl==mask[1] and shift==mask[2] and alt==mask[3]
    local down=gos.input.is_down(key)==true
    return down,match
end
local function draw_preview(cursor,candidate,radius)
    gos.overlay.draw_circle("op_holo_cursor",{at={screen={x=cursor.x,y=cursor.y}},
        radius=radius,color="cyan",thickness=1.5,ttl=0.12})
    if candidate then
        gos.overlay.draw_circle("op_holo_candidate",{at={screen={x=candidate.x,y=candidate.y}},
            radius=12,color="yellow",thickness=2,ttl=0.12})
    end
end

-- Admission retries do not own a command yet. A held gesture can wait through
-- reversible game gates, but never bypasses their current native verdict.
local admission_waits={castability_pending=true,ability_metadata_unavailable=true,
    ability_submission_pending=true,explicit_target_sync_pending=true,
    bridge_busy=true,ability_command_busy=true,executor_command_pending=true,
    gcd=true,busy=true}
local held_waits={cooldown=true,castability_unavailable=true,too_far=true,too_close=true,
    not_facing=true,target_view_blocked=true,stunned=true,incapacitated=true,
    insufficient_resource=true}
local held_target_waits={target_not_projected=true,target_out_of_range=true,
    target_distance_unavailable=true,target_hp_unavailable_or_invalid=true}
-- Repeated attempts are explicitly requested by held input, never inferred
-- from an expired timeout. A settled, positively failed command may be retried;
-- an unconfirmed submission is retained until actual outcome evidence arrives.

function M.new(executor)
    local service={build_id=M.build_id}
    local request,issued_key,issued_handle
    local chord_was_held,binding,preview_at=false,nil,-math.huge
    local blocked_reason
    local preview_candidate
    local serial=0
    local function log(context,level,text)
        if type(context.log)=="function" then context.log(level,"cursor Holotraverse: "..text) end
    end
    local function wait(context,reason,detail)
        if request and request.last_reason~=reason then
            request.last_reason=reason
            log(context,"info","admission_wait reason="..reason..
                " target="..tostring(request.handle or "not_acquired")..(detail or ""))
        end
    end
    local function owns_status(status)
        return issued_handle~=nil and type(status)=="table" and
            status.command_handle==issued_handle and status.idempotency_key==issued_key
    end
    function service.owns_pending()
        local status=executor:status()
        return owns_status(status) and (executor:owns_command() or
            status.core.cleanup_pending==true or status.core.known~=true or status.core.terminal~=true)
    end
    function service.stop(reason)
        request=nil;preview_candidate=nil;preview_at=-math.huge;chord_was_held=false;blocked_reason=nil
        if service.owns_pending() then
            -- Only an actually owned pending command is cancellable. Cleanup is
            -- observed, never cancelled or replaced through another owner.
            if executor:owns_command() then executor:cancel(reason or "cursor_holo_stop") end
            return true
        end
        issued_key,issued_handle=nil,nil
        return false
    end
    function service.tick(context)
        local settings=context.settings or {}
        local loadout=Mirror.adapt_loadout(context.loadout)
        CurrentLoadout=loadout
        if context.enabled~=true or value(settings,"cursor_holo_enabled",true)~=true or
            type(loadout)~="table" or loadout.status~="ready" or loadout.combat_style~="operative" or
            type(loadout.known)~="table" or loadout.known[ABILITY]~=true then
            return service.stop("cursor_holo_disabled_or_unlearned")
        end
        local key=value(settings,"cursor_holo_key","v")
        local modifier=value(settings,"cursor_holo_modifier","Shift")
        local filter=value(settings,"cursor_holo_filter","All")
        local radius=value(settings,"cursor_holo_radius",120)
        if type(key)~="string" or not finite(radius) or radius<20 or radius>600 then
            return service.stop("cursor_holo_invalid_binding")
        end
        local signature=key.."|"..modifier.."|"..filter.."|"..tostring(radius)
        if binding~=signature then
            request=nil;preview_candidate=nil;preview_at=-math.huge;binding=signature
        end
        local down,modifier_down=chord_state(key,modifier)
        local held=down and modifier_down
        local pressed=held and not chord_was_held -- diagnostics only, never admission
        local released=not held and chord_was_held
        chord_was_held=held
        if not held then
            blocked_reason=nil
            if request and not request.command_handle then
                log(context,"info","request cancelled: hold_released last_reason="..request.last_reason..
                    " target="..tostring(request.handle).." key_down="..tostring(down)..
                    " modifier_down="..tostring(modifier_down))
                request=nil
            elseif released then
                log(context,"info","hold_released new_submissions=false command="..tostring(issued_handle))
            end
        end
        -- Observe ONLY the dispatcher's already-polled status. No new attempt
        -- can overlap a submitted command's native outcome or target cleanup.
        if issued_handle then
            local status=executor:status()
            if service.owns_pending() then
                if pressed then log(context,"info","already_pending command="..issued_handle) end
                return true
            end
            if owns_status(status) then
                if status.core.activation_proven==true or status.core.acknowledged==true then
                    log(context,"info","hold_completed activation_confirmed=true command="..issued_handle..
                        " repeat_held="..tostring(held))
                    request=nil -- next held cycle acquires a fresh destination
                elseif status.core.known==true and status.core.terminal==true and
                    status.core.cleanup_pending==false and status.core.state=="failed" and
                    status.game_result_known==true then
                    log(context,"info","hold_retry command="..issued_handle..
                        " result="..tostring(status.game_result_name)..
                        " repeat_held="..tostring(held))
                    request=nil -- actual failure, not guessed success or a blacklist
                else
                    if request and request.last_reason~="outcome_unconfirmed" then
                        wait(context,"outcome_unconfirmed"," command="..issued_handle)
                    end
                    return held -- no timed duplicate; late exact results may still arrive
                end
            else
                log(context,"warn","hold_stopped reason=command_owner_changed command="..issued_handle)
                request=nil;blocked_reason="command_owner_changed"
            end
            issued_key,issued_handle=nil,nil
        end
        if blocked_reason then return false end
        local want_preview=value(settings,"cursor_holo_preview",true)==true and modifier_down and
            (modifier~="None" or down)
        if not held and not want_preview then return false end
        local key_state=gos.input.state(key)
        if type(key_state)~="table" or key_state.known~=true or not finite(key_state.virtual_key) or
            key_state.virtual_key==16 or key_state.virtual_key==17 or key_state.virtual_key==18 or
            (key_state.virtual_key>=160 and key_state.virtual_key<=165) then
            if pressed then log(context,"warn","bind a base key, not a modifier") end
            request=nil;return false
        end
        if pressed then
            log(context,"info","press key="..key.." modifier="..modifier..
                " filter="..filter.." radius_px="..tostring(radius).." hold_retry=true activation_mode=continuous_down")
        end
        local now=gos.time_ms()
        if not finite(now) then request=nil;return false end
        local world=gos.world()
        local player=world and world.player
        if not player or not alive(player) then request=nil;return false end
        if not gos.input or type(gos.input.cursor)~="function" or
            type(player.screen_position)~="function" then
            if pressed then log(context,"warn","requires Core with gos.input.cursor and unit:screen_position") end
            request=nil;return false
        end
        local player_handle=method(player,"handle")
        local actor_epoch=world.actor_epoch
        if type(player_handle)~="string" or player_handle=="" or
            type(actor_epoch)~="string" or actor_epoch=="" then
            if pressed or request then log(context,"info","request cancelled: session_identity_unavailable") end
            request=nil;return false
        end
        if request and (request.player_handle~=player_handle or request.actor_epoch~=actor_epoch) then
            log(context,"info","request cancelled: world_changed last_reason="..request.last_reason)
            request=nil;return false
        end
        if held and not request then
            serial=serial+1
            request={player_handle=player_handle,actor_epoch=actor_epoch,filter=filter,
                radius=radius,key=PREFIX..serial,search_at=now,last_reason="pending",counts={}}
        end
        local cursor=gos.input.cursor()
        if type(cursor)~="table" or cursor.available~=true then
            if request then
                if request.last_reason~="cursor_unavailable" then
                wait(context,"cursor_unavailable",
                    " mouse1="..tostring(gos.input.is_down("mouse1"))..
                    " mouse2="..tostring(gos.input.is_down("mouse2"))..
                    " mouse3="..tostring(gos.input.is_down("mouse3"))..
                    " mouse4="..tostring(gos.input.is_down("mouse4"))..
                    " mouse5="..tostring(gos.input.is_down("mouse5")))
                end
                if not held then request=nil end
            end
            preview_candidate=nil;return false
        end
        local scanned=false
        if request and not request.handle and now>=request.search_at then
            -- No target on the press is not a spent hold. Reacquire on the same
            -- bounded 20Hz cadence as preview, without reusing its stale result.
            if not held then
                request=nil
            else
                local selected,reason=M.pick(world,cursor,request.filter,request.radius,request.counts)
                scanned=true;preview_at=now;preview_candidate=selected
                request.search_at=now+PREVIEW_INTERVAL_MS
                if selected then
                    request.handle=selected.handle
                    request.pixel_distance=math.sqrt(selected.d2)
                    request.last_reason="selected"
                    log(context,"info","selected target="..selected.handle..
                        " cursor_px="..string.format("%.1f",request.pixel_distance)..
                        target_diagnostic(method(world,"resolve",selected.handle)))
                else
                    local c=request.counts
                    wait(context,reason," total="..tostring(c.total)..
                        " eligible="..tostring(c.eligible).." over_30m="..tostring(c.range)..
                        " not_projected="..tostring(c.projection)..
                        " other_excluded="..tostring(c.other)..
                        " outside_radius="..tostring(c.outside)..
                        " nearest_eligible_px="..tostring(c.nearest_px))
                end
            end
        end
        if want_preview then
            if not scanned and now-preview_at>=PREVIEW_INTERVAL_MS then
                preview_at=now
                if request and request.handle then
                    local locked=method(world,"resolve",request.handle)
                    local point=method(locked,"screen_position","center")
                    preview_candidate=type(point)=="table" and finite(point.x) and finite(point.y) and
                        {handle=request.handle,x=point.x,y=point.y} or nil
                else
                    preview_candidate=M.pick(world,cursor,filter,radius)
                end
            end
            draw_preview(cursor,preview_candidate,radius)
        else
            preview_candidate=nil
        end
        if not held or not request or not request.handle then return false end
        -- A held intent never steals an existing command or its cleanup. Once
        -- ownership clears, explicit admission is attempted on THIS next tick.
        local latest=executor:status()
        if executor:owns_command() or (type(latest)=="table" and latest.core and latest.core.cleanup_pending==true) then
            wait(context,"executor_busy");return true
        end
        local unit=method(world,"resolve",request.handle)
        local target_ok,target_reason=eligible(unit,player,request.filter)
        if not target_ok then
            if held and held_target_waits[target_reason] then
                if request.last_reason~=target_reason then wait(context,target_reason,target_diagnostic(unit)) end
                return false
            end
            log(context,"info","request cancelled: target_no_longer_eligible reason="..target_reason..
                " target="..request.handle.." last_reason="..request.last_reason..target_diagnostic(unit))
            request=nil;return false
        end
        local info=Mirror.info(CurrentLoadout, ABILITY)
        if type(info)~="table" then wait(context,"ability_metadata_unavailable");return true end
        if info.on_bar~=true then
            wait(context,"ability_not_bound");return false
        end
        local result=Mirror.submit(executor, CurrentLoadout, ABILITY,unit,{idempotencyKey=request.key,target_fallback="none"})
        local reason=type(result)=="table" and tostring(result.reason or result.code or "rejected") or "invalid_result"
        local accepted=type(result)=="table" and result.accepted==true
        local admission_pending=type(result)=="table" and result.admission_pending==true
        if accepted or admission_pending then
            if not exact(result.core,request.handle) then
                local status=executor:status()
                if executor:owns_command() and type(status)=="table" and
                    status.idempotency_key==request.key and status.command_handle==result.command_handle then
                    executor:cancel("cursor_holo_target_contract")
                end
                log(context,"warn","explicit target contract rejected")
                request=nil;blocked_reason="explicit_target_contract";return true
            end
        end
        if accepted then
            issued_key,issued_handle=request.key,result.command_handle
            request.command_handle=result.command_handle
            log(context,"info","queued target="..request.handle.." name="..tostring(method(unit,"name") or "?")..
                " cursor_px="..string.format("%.1f",request.pixel_distance).." filter="..request.filter..
                " command="..tostring(issued_handle).." held=true key_down=true modifier_down=true")
            return true -- retain exact request through native outcome AND cleanup
        end
        if admission_pending or admission_waits[reason] then wait(context,reason);return true end
        if held and held_waits[reason] then
            wait(context,reason)
            return reason=="castability_unavailable" -- cooldown/geometry cannot monopolize the rotation
        end
        wait(context,reason);return false -- fresh down-state retry, not a key-up action
    end
    return service
end
return M
