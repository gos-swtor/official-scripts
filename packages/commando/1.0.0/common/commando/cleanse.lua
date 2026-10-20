-- Commando-only cleanse admission. The parent supplies its sole AbilityExecutor.
-- No engine polling, alternate executor, selected-target mutation or saved GosUnit.
local Cleanse = require("combat.cleanse")
local Mirror = require("commando.mirror")
local M = { revision = "2026-09-22-commando-cleanse-admission-r4-action-hook" }
assert(type(Cleanse.revalidate)=="function" and Cleanse.supports_tier_filter==true,
    "Deploy the matching r4 tier-filter cleanse helper and exact-definition database")
local TIER_RANK={must=1,movement=2,pressure=3}
local function finite(v) return type(v)=="number" and v==v and v>-math.huge and v<math.huge end
local function method(unit,name,...)
    if not unit or type(unit[name])~="function" then return nil end
    local ok,value=pcall(unit[name],unit,...)
    if ok then return value end
end
local function candidate_id(c) return c.handle..":"..c.definition_key end
function M.new(executor)
    assert(type(executor)=="table" and type(executor.submit)=="function", "Shared executor required")
    local intent,queued,lastSignature,lastDiagnostic=nil,nil,nil,-math.huge
    local missingIdentityWarned=false
    local function stop(reason)
        intent=nil
        if queued then
            local status=executor:status()
            if executor:owns_command() and status.command_handle==queued.command and
                status.idempotency_key==queued.owner then executor:cancel(reason or "cleanse_inactive") end
            if not executor:owns_command() and status.core.cleanup_pending~=true then queued=nil end
        end
    end
    local function tick(context)
        local now=gos.time_ms()
        if not finite(now) then intent=nil;return false end
        local function report(text)
            if context.policy and context.policy.diagnostics and type(context.log)=="function" and now-lastDiagnostic>=2000 then
                lastDiagnostic=now;context.log("debug","commando cleanse: "..text)
            end
        end
        if context.active~=true or not context.policy or not context.policy.enabled then
            stop("cleanse_disabled_or_key_up");return queued~=nil
        end
        if queued then
            local status=executor:status()
            if status.command_handle==queued.command and status.idempotency_key==queued.owner and
                (executor:owns_command() or status.core.cleanup_pending==true) then return true end
            queued=nil
        end
        if executor:owns_command() then intent=nil;return false end
        local cap=Cleanse.capabilities(context.loadout)
        if cap.status~="ready" then intent=nil;report("unavailable: "..tostring(cap.reason));return false end
        local world=context.world
        local player=world and world.player
        local handle=method(player,"handle")
        local scope=tostring(context.owner)..":"..tostring(context.target_scope)
        local signature=Cleanse.build_id..":"..Cleanse.db_revision..":"..scope..":"..tostring(cap.proof.mental)
        if lastSignature~=signature and type(context.log)=="function" then
            lastSignature=signature
            local types={}
            for _,category in ipairs({"tech","physical","mental","force"}) do
                if cap.removes[category] then types[#types+1]=category end
            end
            context.log("info","commando cleanse build="..M.revision.." helper="..Cleanse.build_id..
                " db="..Cleanse.db_revision.." targets="..tostring(context.target_scope)..
                " categories="..table.concat(types,",").." admission=caller_owned")
        end
        if type(handle)~="string" or type(context.owner)~="string" then intent=nil;return false end
        if gos.abilities.is_casting_or_channeling()~=false then intent=nil;return false end
        local info=gos.abilities.info(cap.ability)
        if type(info)~="table" or type(info.ability_handle)~="string" or info.on_bar~=true then
            intent=nil;report("Field Aid not learned/resolved/bound");return false
        end
        if info.has_resource_cost~=true or not finite(info.resource_cost) or info.resource_cost<0 then
            intent=nil;report("Field Aid resource cost unavailable");return false
        end
        if info.has_cooldown_remaining==true and finite(info.cooldown_remaining) and info.cooldown_remaining>0 then
            intent=nil;return false
        end
        local resource=Mirror.resource(context.loadout,method(player,"resource"))
        if type(resource)~="table" or not finite(resource.current) or resource.current<info.resource_cost then
            intent=nil;return false
        end
        context.capabilities=cap
        local plan=Cleanse.evaluate(context)
        if plan.missing_identity>0 and not missingIdentityWarned and type(context.log)=="function" then
            missingIdentityWarned=true
            context.log("warn","commando cleanse: Core effect definition_key is unavailable; no name-based guesses or casts on missing identities")
        end
        if plan.status~="ready" then intent=nil;report("unavailable: "..tostring(plan.reason));return false end
        local function allowed(candidate)
            return type(context.allow_candidate)~="function" or context.allow_candidate(candidate)==true
        end
        local candidates={}
        for _,candidate in ipairs(plan.candidates) do
            if allowed(candidate) then candidates[#candidates+1]=candidate end
        end
        if #candidates==0 then intent=nil;report("no eligible candidate: "..plan.reason);return false end
        local wait=finite(context.admission_wait_ms) and math.max(0,math.min(500,context.admission_wait_ms)) or 150
        local prior_intent=intent
        local retained
        if intent and intent.player==handle and intent.ability==info.ability_handle and intent.scope==scope and now>=intent.since then
            for _,candidate in ipairs(candidates) do
                if candidate_id(candidate)==intent.id then retained=candidate;break end
            end
        end
        if retained and candidates[1] and TIER_RANK[candidates[1].tier] and
            TIER_RANK[retained.tier] and TIER_RANK[candidates[1].tier]<TIER_RANK[retained.tier] then
            retained=nil
        end
        if not retained then
            intent=nil
            -- A top-level lifecycle service call uses the broad plan so a newly
            -- appeared higher tier can preempt a retained lower-tier admission.
            -- If the old candidate simply vanished, do not silently replace it
            -- with equal/lower utility before the healer scheduler runs again.
            local old_rank=prior_intent and TIER_RANK[prior_intent.tier]
            local new_rank=candidates[1] and TIER_RANK[candidates[1].tier]
            if old_rank and (not new_rank or new_rank>=old_rank) then return false end
        end
        if retained and now-intent.since>=wait then
            report("admission budget elapsed: "..intent.id.."; yielding to healing")
            intent=nil;return false
        end
        if retained then
            for index,candidate in ipairs(candidates) do
                if candidate==retained then table.remove(candidates,index);break end
            end
            table.insert(candidates,1,retained)
        end
        for _,candidate in ipairs(candidates) do
            local unit=Cleanse.revalidate(candidate,context,cap)
            if unit then
                local id=candidate_id(candidate)
                local current=intent and intent.id==id and intent or nil
                local native=current and current.phase=="native"
                local advisory
                if not native then advisory=gos.abilities.can_cast(info.ability_handle,unit) end
                if not native and not Cleanse.explicit_result(advisory,candidate.handle) then
                    local reason=type(advisory)=="table" and advisory.reason or "admission_unavailable"
                    if reason=="castability_pending" or reason=="ability_submission_pending" or
                        reason=="explicit_target_sync_pending" then
                        intent=current or {id=id,player=handle,ability=info.ability_handle,scope=scope,
                            tier=candidate.tier,since=now,phase="advisory"}
                        report("advisory pending: "..id)
                        return true -- Bounded decision retention, NOT a cast command.
                    end
                    intent=nil
                    if not Cleanse.target_failure(advisory) then report("admission rejected: "..tostring(reason));return false end
                else
                    local owner=context.owner..":cleanse:"..id
                    local result=executor:submit(cap.ability,unit,{idempotencyKey=owner,target_fallback="none"})
                    if type(result)=="table" and result.admission_pending==true then
                        intent={id=id,player=handle,ability=info.ability_handle,scope=scope,
                            tier=candidate.tier,since=current and current.since or now,phase="native"}
                        report("native admission pending: "..id)
                        return true -- Do not replace Core's one native request with a heal/DPS request.
                    end
                    intent=nil
                    local accepted=Cleanse.explicit_result(result.core,candidate.handle)
                    if type(result)=="table" and result.accepted==true then
                        queued={command=result.command_handle,owner=owner}
                        if not accepted then executor:cancel("cleanse_explicit_target_contract_mismatch") end
                        if type(context.log)=="function" then
                            context.log(accepted and "info" or "warn","cleanse queued="..tostring(accepted)..
                                " ability="..cap.ability.." effect="..candidate.effect.." target="..candidate.handle..
                                " definition="..candidate.definition_key.." tier="..candidate.tier.." dispel="..candidate.dispel..
                                " capability="..tostring(candidate.proof).." outcome=unconfirmed")
                        end
                        if accepted and type(context.onAction)=="function" then
                            context.onAction({
                                ability=cap.ability, decision="cleanse_"..tostring(candidate.tier),
                                command_handle=result.command_handle, target_handle=candidate.handle,
                                target_name=method(unit,"name"), target_type=method(unit,"type"),
                                untargeted=false,
                                meta={category="cleanse",effect=candidate.effect,tier=candidate.tier},
                            })
                        end
                        return true
                    end
                    if executor:owns_command() then return true end
                    if not Cleanse.target_failure(result.core) then
                        report("submission rejected: "..tostring(type(result)=="table" and result.reason or "unavailable"))
                        return false
                    end
                end
            end
        end
        intent=nil;return false
    end
    return {tick=tick,stop=stop,has_local_pending=function() return intent~=nil or queued~=nil end}
end
return M
