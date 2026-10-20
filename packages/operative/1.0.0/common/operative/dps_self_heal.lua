-- Shared self-care for both Operative DPS disciplines; Medicine is excluded.
-- Probe facts: abl.agent.kolto_probe, two stacks, instant, base 18s.
-- Infusion is the DPS direct heal; unprocced casts consume one real TA.
-- Quickening requires the owned Lethality passive AND its live effect.
-- Sources: Cease Faith TUj3NTq61Qk (33:05 / linked sFGrbtMX script),
-- Alim Concealment PvP (2021), Ivano Lethality PvP (2024).
-- Costs/cooldowns/ownership come from Core; thresholds below are configurable policy.
-- https://swtor.jedipedia.net/en/abl/kolto-probe-3
-- https://swtor.jedipedia.net/en/abl/kolto-infusion
local Mirror = require("operative.mirror")
local CurrentLoadout
local M = {}
local PROBE, INFUSION = "Kolto Probe", "Kolto Infusion"
local QUICKENING, TA = "Quickening", "Tactical Advantage"
local CONTROL_NAMES = {"Flash Bang","Sleep Dart","Whirlwind","Force Lift"}
local SCOUNDREL_CONTROL_NAMES = {"Flash Bang","Flash Grenade","Sleep Dart","Tranquilizer","Whirlwind","Force Lift"}
local NAMES = { PROBE, INFUSION, "Stealth", "Cloaking Screen" }
local PREFIX = "operative:dps_self_heal:"
local BUFF = { kind = "buff" }
local PROBE_FILTER = { kind = "buff", timed = true }
local SLACK = 0.04
-- Receipt deadlines only limit duplicate submissions; they never assert a heal landed.
local RECEIPT_SECONDS = { [PROBE] = 2.0, [INFUSION] = 5.0 }
local function finite(x)
    return type(x)=="number" and x==x and math.abs(x)<math.huge
end
local function method(unit, name, ...)
    if not unit or type(unit[name])~="function" then return nil end
    local ok, value=pcall(unit[name], unit, ...)
    return ok and value or nil
end
local function time_now()
    local ms=gos.time_ms()
    return finite(ms) and ms/1000.0 or nil
end
local function dps(loadout)
    return type(loadout)=="table" and loadout.status=="ready" and
        loadout.combat_style=="operative" and type(loadout.known)=="table" and
        (loadout.discipline=="Concealment" or loadout.discipline=="Lethality")
end
local function enemy_player(unit)
    return method(unit,"type")=="player" and method(unit,"reaction")=="hostile"
end
local function hp_percent(player)
    local hp=method(player,"hp")
    if type(hp)~="table" or not finite(hp.current) or not finite(hp.max) or
        hp.max<=0 or hp.current<=0 then return nil end
    return math.min(100,hp.current/hp.max*100)
end
local function exact_self(result, handle)
    return type(result)=="table" and result.target_mode=="explicit" and
        result.target_valid==true and result.requested_target_handle==handle and
        result.target_handle==handle and result.target_fallback=="none" and
        result.fallback_used~=true
end
function M.new(executor, on_ta_reconcile)
    assert(type(executor)=="table", "DPS self-healing requires the shared executor")
    local R={player=nil, discipline=nil, pvp=false, healing=false, cursor=nil,
        identities={}, nextIdentity=0, nativeAdmission=nil, pending=nil,
        requests={}, retry={}, notes={},
        probeApplication=nil, nextTry=0, options={}}
    local function log(level,message)
        local f=R.options.logLine
        if type(f)=="function" then f(level,"operative DPS self-heal: "..message) end
    end
    local function note(key,message,warning)
        if not warning and R.options.decisionLog~=true then return end
        local now=time_now()
        if not now or now<(R.notes[key] or -math.huge)+10.0 then return end
        R.notes[key]=now
        log(warning and "warn" or "debug",message)
    end
    local function owns_pending()
        if not executor:owns_command() then return false end
        local status=executor:status()
        local key=type(status)=="table" and status.idempotency_key or nil
        return type(key)=="string" and key:sub(1,#PREFIX)==PREFIX
    end
    local function stop(reason)
        R.healing=false
        R.nativeAdmission=nil
        if owns_pending() then executor:cancel(reason or "dps_self_heal_inactive") end
        -- Never abandon a game-owned or foreign command to force damage through.
        return owns_pending()
    end
    local function remember_identity(name,row)
        if type(row)=="table" and type(row.ability_handle)=="string" then
            R.identities[name]={submission=row.ability_handle,activation=row.activation_handle}
        end
    end
    local function event_name(event)
        if type(event.ability_handle)~="string" then return nil end
        for _,name in ipairs(NAMES) do
            local row=R.identities[name]
            if row and (event.ability_handle==row.submission or event.ability_handle==row.activation) then
                return name
            end
        end
        return nil
    end
    local function observe_events(batch,loadout,world)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        if not dps(loadout) or type(batch)~="table" then return batch end
        local player=world and world.player or nil
        local handle=method(player,"handle")
        local now=time_now()
        if not handle or not now then return batch end
        local combat_style=Mirror.raw_loadout(loadout).combat_style
        local reset=R.player~=handle or R.discipline~=loadout.discipline or R.style~=combat_style or
            (batch.dropped or 0)>0 or (finite(R.cursor) and finite(batch.cursor) and batch.cursor<R.cursor)
        if reset then
            R.pvp,R.healing=false,false
            R.identities,R.nextIdentity={},0
            R.probeApplication=nil
            R.nativeAdmission=nil
            R.lastInfusionAt=nil
            R.requests,R.retry={},{}
        end
        if reset then R.stealthAt=nil end
        R.player,R.discipline,R.style=handle,loadout.discipline,combat_style
        if batch.cursor==R.cursor and not reset then return batch end
        R.cursor=batch.cursor
        if now>=R.nextIdentity then
            R.nextIdentity=now+2.0
            for _,name in ipairs(NAMES) do
                if loadout.known[name] then remember_identity(name,Mirror.info(CurrentLoadout, name))
                else R.identities[name]=nil end
            end
        end
        local filtered=nil
        local events=type(batch.events)=="table" and batch.events or {}
        for i=1,math.min(64,#events) do
            local event=events[i]
            local consume=false
            if type(event)=="table" then
                if event.kind=="combat" and event.source_handle==handle and event.action=="exit_combat" then
                    R.pvp,R.healing=false,false
                end
                if event.kind=="damage" then
                    local other=event.target_handle==handle and event.source_handle or
                        event.source_handle==handle and event.target_handle or nil
                    if other and other~=handle and enemy_player(method(world,"resolve",other)) then R.pvp=true end
                end
                if event.kind=="ability" and event.action=="ability_activate" and event.source_handle==handle then
                    local name=event_name(event)
                    if name=="Stealth" or name=="Cloaking Screen" then
                        R.stealthAt=finite(event.timestamp) and event.timestamp/1000.0 or now
                    elseif name==PROBE or name==INFUSION then
                        -- Actual Infusion activation invalidates pre-heal TA state;
                        -- a queued receipt never invents resource consumption.
                        local event_time=finite(event.timestamp) and event.timestamp/1000.0 or nil
                        if name==INFUSION and event_time and event_time>(R.lastInfusionAt or -math.huge) then
                            R.lastInfusionAt=event_time
                            if type(on_ta_reconcile)=="function" then
                                on_ta_reconcile(event_time,loadout.discipline)
                            end
                        end
                        consume=true
                        local request=R.requests[name]
                        local t=finite(event.timestamp) and event.timestamp/1000.0 or nil
                        if request and not request.failed and not request.confirmedAt and t and
                            t>=request.submittedAt and t<=request.submittedAt+RECEIPT_SECONDS[name] then
                            if event.target_handle and event.target_handle~=handle then
                                request.failed=true
                                R.retry[name]=now+1.0
                                note("target_diverged","self-heal recipient diverged; refusing to credit the heal",true)
                            else
                                request.confirmedAt=t
                                if R.options.castLog then
                                    log("info","activated "..name.." target=self source=server_event")
                                end
                            end
                        end
                    end
                end
            end
            if consume and not filtered then
                filtered={}
                for j=1,i-1 do filtered[#filtered+1]=events[j] end
            elseif not consume and filtered then filtered[#filtered+1]=event end
        end
        if not filtered then return batch end
        return {cursor=batch.cursor,dropped=batch.dropped,more=batch.more,events=filtered}
    end
    local function service_pending(now)
        local p=R.pending
        if not p then return false end
        if executor:owns_command() then return owns_pending() end
        local status=executor:status()
        if type(status)=="table" and status.idempotency_key==p.key then
            local state=status.core.state
            if state=="failed" or state=="cancelled" or state=="superseded" or state=="abandoned" then
                p.failed=true
                R.retry[p.name]=now+1.0
                if R.probeApplication==p then R.probeApplication=nil end
                note("cast:"..p.name,"rejected "..p.name.." reason="..tostring(status.reason or state),true)
            elseif not p.confirmedAt and status.core.acknowledged~=true and state~="started" and state~="acknowledged" then
                if now<p.submittedAt+RECEIPT_SECONDS[p.name] then
                    return true -- bounded receipt ownership; never invent activation/HP/stacks
                end
                p.failed=true
                R.retry[p.name]=now+1.0
                if R.probeApplication==p then R.probeApplication=nil end
                note("receipt:"..p.name,"no activation confirmation for "..p.name.."; yielding to DPS",true)
            end
        end
        R.pending=nil
        return false
    end
    local function probe_state(player,now)
        local name, filter = Mirror.effect(CurrentLoadout, PROBE, PROBE_FILTER)
        local raw=name and method(player,"effect",name,filter) or nil
        if type(raw)~="table" or raw.status~="ready" or raw.truncated==true then
            return nil,"probe_observation_unavailable"
        end
        local sample=finite(raw.age_ms) and now-raw.age_ms/1000.0 or nil
        local present=raw.present==true
        if present and raw.mine~=true and raw.has_ownership~=true then
            return nil,"probe_ownership_unavailable"
        end
        local mine=present and raw.mine==true
        if mine and (raw.charge_conflicted==true or raw.has_charges~=true or not finite(raw.stacks)) then
            return nil,"probe_stacks_unavailable"
        end
        local n=mine and math.min(2,math.max(0,math.floor(raw.stacks))) or 0
        local remaining=mine and finite(raw.remaining) and math.max(0,raw.remaining) or nil
        local row={stacks=n,remaining=remaining,sample=sample,
            expiry=remaining and now+remaining or nil}
        local p=R.probeApplication
        if p and not p.failed and not p.settledAt then
            local after=p.confirmedAt or p.submittedAt
            local fresh=sample and sample>after
            local advanced=fresh and mine and
                ((p.baselineStacks<2 and n>p.baselineStacks) or
                    (p.baselineStacks>=2 and n>=2 and row.expiry and p.baselineExpiry and
                        row.expiry>p.baselineExpiry+SLACK))
            if advanced then p.settledAt=sample
            elseif not fresh or now<after+1.5 then return nil,"probe_application_reconciling"
            else p.settledAt=sample end -- fresh absence may be a failed application or cleanse
        end
        return row
    end
    local function observed_buff(player,name,now,after)
        local filter=name==QUICKENING and PROBE_FILTER or BUFF
        local actual, actual_filter=Mirror.effect(CurrentLoadout,name,filter)
        local row=actual and method(player,"effect",actual,actual_filter) or nil
        if type(row)~="table" or row.status~="ready" or row.truncated==true then return nil end
        local sampled=finite(row.age_ms) and now-row.age_ms/1000.0 or nil
        if after and (not sampled or sampled<=after) then return nil end
        return row
    end
    local function quickening_available(state)
        if state.loadout.discipline~="Lethality" or not state.loadout.known[QUICKENING] then return false end
        local row=observed_buff(state.player,QUICKENING,state.now,R.lastInfusionAt)
        return row and row.present==true and finite(row.remaining) and row.remaining>state.gcd+SLACK or false
    end
    local function infusion_allowed(state,cfg)
        local quick=quickening_available(state)
        if quick then
            if cfg.useQuickening==false then return false,"quickening_disabled" end
            if method(state.player,"speed")~=0 and cfg.quickeningWhileMoving==false then
                return false,"moving_proc_disabled"
            end
            return true,"quickening"
        end
        if method(state.player,"speed")~=0 then return false,"stationary_required" end
        local row=observed_buff(state.player,TA,state.now,R.lastInfusionAt)
        if not row or row.present~=true or row.charge_conflicted==true or
            row.has_charges==false or not finite(row.stacks) then return false,"ta_unavailable" end
        local reserve=state.urgent and 0 or (cfg.taReserve or 0)
        if math.floor(row.stacks)<1+reserve then return false,"ta_reserved_or_absent" end
        return true,"stationary_ta"
    end
    local function recovery_window(state,world)
        if R.options.inCombat==false then return true,"out_of_combat" end
        local target=world and world.current_target or nil
        if not target or not hp_percent(target) or method(target,"reaction")~="hostile" then
            return true,"no_damage_target"
        end
        local distance=method(target,"distance")
        local melee=state.loadout.discipline=="Lethality" and 10 or 4
        if finite(distance) and distance*10>melee then return true,"outside_damage_range" end
        -- These are opportunities to trade a damage GCD, NOT a claim of safety
        -- against every other opponent. Do not automate movement or crowd control.
        for _,name in ipairs({"Undying Rage","Guarded by the Force","Force Barrier"}) do
            local row=method(target,"effect",name,BUFF)
            if type(row)=="table" and row.status=="ready" and row.present==true and
                finite(row.remaining) and row.remaining>=1.5 then return true,"enemy_defensive_"..name end
        end
        local controls=Mirror.raw_loadout(state.loadout).combat_style=="scoundrel" and
            SCOUNDREL_CONTROL_NAMES or CONTROL_NAMES
        for _,name in ipairs(controls) do
            local row=method(target,"effect",name,{kind="debuff",timed=true})
            if type(row)=="table" and row.status=="ready" and row.present==true and
                finite(row.remaining) and row.remaining>=1.5 then return true,"enemy_controlled_"..name end
        end
        local attack=state.loadout.discipline=="Concealment" and "Backstab" or "Shiv"
        local ok,result=pcall(Mirror.can_cast,CurrentLoadout,attack,nil)
        if ok and type(result)=="table" and result.ok~=true and
            (result.reason=="not_in_line_of_sight" or result.reason=="out_of_range") then
            return true,"damage_"..result.reason
        end
        return false,"no_observed_recovery_window"
    end

    local function cast(name,reason,state,reserve,probe,resume_native)
        local now=state.now
        if not resume_native and
            (now<(R.retry[name] or 0) or now<R.nextTry) then return false end
        if not state.loadout.known[name] then return false end
        if not resume_native and name==INFUSION then
            local permitted,why=infusion_allowed(state,R.options.selfHealing or {})
            if not permitted then note("infusion:"..why,why); return false end
            if state.quickening and why~="quickening" then return false end
        end
        local row=Mirror.info(CurrentLoadout, name)
        remember_identity(name,row)
        if type(row)~="table" or row.on_bar~=true or type(row.ability_handle)~="string" then
            note("unbound:"..name,name.." unavailable or not on a quickbar")
            return false
        end
        if row.has_resource_cost~=true or not finite(row.resource_cost) or row.resource_cost<0 then
            note("cost:"..name,name.." cost is unavailable")
            return false
        end
        if not resume_native and name==INFUSION and state.quickening and row.resource_cost~=0 then
            note("quickening_cost","Quickening visible but native cost is not zero; waiting")
            return false
        end
        local energy=state.energy
        local funded=energy.current>=row.resource_cost and
            (energy.current-row.resource_cost)/energy.max*100>=reserve
        local function pool_energy()
            local target=reserve+row.resource_cost/energy.max*100
            if target>100 then
                note("reserve:"..name,name.." cost plus configured reserve exceeds maximum Energy")
                return
            end
            -- A lower DPS floor must not spend every regenerated point before
            -- the requested heal becomes affordable. This per-tick reservation
            -- uses the existing DPS free-filler policy; it changes no saved setting.
            R.options.energyFloorPercent=math.max(R.options.energyFloorPercent or 0,target)
            R.options.selfHealEnergyPool=name
            note("pool:"..name,"pooling Energy for "..name.."; DPS free filler remains available")
        end
        local cooldown=Mirror.cooldown_remaining(CurrentLoadout, name)
        if not resume_native and
            (not finite(cooldown) or cooldown>state.gcd+SLACK) then return false end
        -- Use the actual explicit-self admission as the single Core check.
        -- A second advisory query has its own identity and cannot be required
        -- before polling an already pending live-admission response.
        if not resume_native and not funded then pool_energy(); return false end
        if not resume_native and name==INFUSION and
            not infusion_allowed(state,R.options.selfHealing or {}) then return false end
        local key=PREFIX..name..":"..state.handle
        R.nativeAdmission=nil
        local accepted=Mirror.submit(executor, CurrentLoadout, name,state.player,{idempotencyKey=key,target_fallback="none"})
        if type(accepted)~="table" or accepted.accepted~=true then
            local why=type(accepted)=="table" and accepted.reason or "invalid_result"
            if type(accepted)=="table" and accepted.admission_pending==true then
                if not exact_self(accepted.core,state.handle) then
                    note("self_contract","pending admission has invalid self-target metadata",true)
                    R.nextTry=now+1.0
                    return false
                end
                R.nativeAdmission={name=name,reason=reason,reserve=reserve,
                    probe=probe~=nil,player=state.handle,
                    discipline=state.loadout.discipline,
                    actorEpoch=state.actorEpoch,abilityHandle=row.ability_handle}
                note("admission:"..name,"admission pending "..name.."; retry next tick")
                return true -- No command/HoT/TA evidence and no retry timer.
            end
            local wait=type(accepted)=="table" and type(accepted.core)=="table" and (accepted.core.ready_in_ms or accepted.core.wait_ms) or nil
            if (why=="gcd" or why=="cooldown") and (type(accepted.core)~="table" or accepted.core.command_admission_blocked~=true) and
                finite(wait) and wait>=0 and wait<=state.queue*1000 then
                return true -- Preserve the existing imminent healing GCD policy.
            end
            if why=="explicit_target_sync_suspended" or why=="ability_command_unavailable" then
                R.nextTry=now+1.0
                note("backend",why.."; self-healing skipped, DPS targeting unchanged",true)
            end
            R.retry[name]=now+0.75
            note("submit:"..name,"not queued "..name.." reason="..tostring(why),true)
            return executor:owns_command()
        end
        local request={name=name,key=key,player=state.handle,submittedAt=now,
            baselineStacks=probe and probe.stacks or 0,baselineExpiry=probe and probe.expiry or nil}
        R.pending,R.requests[name]=request,request
        if name==PROBE then R.probeApplication=request end
        if not exact_self(accepted.core,state.handle) then
            note("submission_contract","unexpected target metadata; cancelling only the owned heal",true)
            if owns_pending() then executor:cancel("dps_self_heal_target_contract") end
            return true
        end
        if R.options.castLog then log("info","queued "..name.." target=self reason="..reason) end
        return true
    end
    local function tick_phase(loadout,active,options,phase,filler_name)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        R.options=type(options)=="table" and options or {}
        local cfg=R.options.selfHealing or {}
        local now=time_now()
        if not now then return false,false end
        local spec_enabled=type(loadout)=="table" and
            (loadout.discipline=="Concealment" and cfg.concealmentEnabled~=false or
             loadout.discipline=="Lethality" and cfg.lethalityEnabled~=false)
        if not dps(loadout) or not active or cfg.enabled==false or not spec_enabled then
            return stop("dps_self_heal_inactive"),false
        end
        if phase=="filler" and cfg.damageFirst==false then return false,false end
        local world=gos.world()
        local player=world and world.player or nil
        local handle=method(player,"handle")
        if R.pending and R.pending.player~=handle then return stop("self_heal_player_changed"),false end
        if service_pending(now) then return true,false end
        if executor:owns_command() then return false,false end
        local completed=executor:status()
        if type(completed)=="table" and completed.command_handle and
            completed.command_handle~=R.lastExternalCommand and
            (type(completed.idempotency_key)~="string" or completed.idempotency_key:sub(1,#PREFIX)~=PREFIX) then
            R.lastExternalCommand=completed.command_handle
            return false,false
        end
        local hp=hp_percent(player)
        if not handle or not hp then R.healing=false; return false,false end
        local native=R.nativeAdmission
        if native then
            local stealth=method(player,"effect","Stealth",BUFF)
            local gcd=gos.abilities.gcd_remaining()
            local energy=method(player,"resource")
            local row=Mirror.info(CurrentLoadout, native.name)
            local actor_epoch=world and world.actor_epoch or nil
            local epoch_matches=native.actorEpoch==nil or actor_epoch==nil or
                native.actorEpoch==actor_epoch
            if native.player~=handle or native.discipline~=loadout.discipline or
                not epoch_matches or type(row)~="table" or
                row.ability_handle~=native.abilityHandle or
                type(stealth)~="table" or stealth.status~="ready" or
                stealth.present==true or not finite(gcd) or gcd<0 or
                type(energy)~="table" or not finite(energy.current) or
                not finite(energy.max) or energy.max<=0 then
                R.nativeAdmission=nil
                return false,false
            end
            local state={now=now,loadout=loadout,player=player,handle=handle,
                actorEpoch=actor_epoch,energy=energy,gcd=gcd,
                queue=R.options.abilityQueueWindow or 0.20,urgent=false}
            local probe=native.probe and probe_state(player,now) or nil
            R.nativeAdmission=nil
            cast(native.name,native.reason,state,native.reserve,probe,true)
            return true,false
        end
        local target=world and world.current_target or nil
        local target_pvp=enemy_player(target) and hp_percent(target)~=nil
        if target_pvp and R.options.inCombat==true then R.pvp=true end
        if cfg.pvpOnly~=false and cfg.assumePvP~=true and not target_pvp and not R.pvp then
            R.healing=false
            note("pvp_gate","gate=pvp_only route="..loadout.discipline..
                " hp="..string.format("%.1f",hp).."; PvE self-healing remains disabled by settings")
            return false,false
        end
        local stealth=method(player,"effect","Stealth",BUFF)
        if R.options.autoStealthPending==true then
            R.nativeAdmission=nil
            return false,false
        end
        if type(stealth)~="table" or stealth.status~="ready" or stealth.present==true then
            R.nativeAdmission=nil
            if hp<=(cfg.healBelow or 70.0) then
                note("stealth_gate","gate=stealth_or_observation_pending route="..loadout.discipline..
                    " hp="..string.format("%.1f",hp))
            end
            return false,false
        end
        if R.stealthAt then
            local sampled=finite(stealth.age_ms) and now-stealth.age_ms/1000.0 or nil
            if not sampled or sampled<=R.stealthAt then return false,false end
            R.stealthAt=nil
        end
        local begin=cfg.healBelow or 70.0
        local finish=math.max(begin,cfg.healTo or 85.0)
        if hp<=begin then R.healing=true elseif hp>=finish then R.healing=false end
        if gos.abilities.is_casting_or_channeling()~=false then return false,false end
        local gcd=gos.abilities.gcd_remaining()
        local queue=R.options.abilityQueueWindow or 0.20
        if not finite(gcd) or gcd<0 or gcd>queue then return false,false end
        local energy=method(player,"resource")
        if type(energy)~="table" or not finite(energy.current) or
            not finite(energy.max) or energy.max<=0 then return false,false end
        local stationary=method(player,"speed")==0
        local urgent=hp<=math.min(begin,cfg.emergencyBelow or 35.0)
        local state={now=now,loadout=loadout,player=player,handle=handle,
            actorEpoch=world and world.actor_epoch or nil,
            energy=energy,gcd=gcd,queue=queue,urgent=urgent}
        state.quickening=quickening_available(state)
        local direct_enabled=cfg.directEnabled~=false and loadout.known[INFUSION]
        local probe,probe_reason=nil,nil
        if cfg.probesEnabled~=false and loadout.known[PROBE] then
            probe,probe_reason=probe_state(player,now)
        end
        local established=probe and probe.stacks>=2
        local refresh_due=established and finite(probe.remaining) and
            probe.remaining<=(cfg.probeRefresh or 3.0)

        -- Critical survival is the only direct-heal path that may preempt a real
        -- damage action. This still requires exact self-targeting, actual TA or
        -- observed Quickening, movement legality and real Energy affordability.
        if urgent and direct_enabled and (stationary or state.quickening) then
            if cast(INFUSION,state.quickening and "critical_quickening" or "critical_self_health",
                state,0) then return true,false end
        end

        -- Concealment has no Lethality Quickening shortcut. When critical and
        -- moving, out of TA, or otherwise unable to Infuse, an affordable instant
        -- self Probe must not wait behind damage for a Rifle/Overload filler.
        -- Infusion had first refusal; real stacks/ownership are still required.
        if loadout.discipline=="Concealment" and urgent and probe and probe.stacks<2 then
            if cast(PROBE,"critical_build_self_probes",state,0,probe) then return true,false end
            if R.options.selfHealEnergyPool then return false,true end
        end

        -- Once two owned Probe stacks exist, preserve them. This is maintenance,
        -- not setup: one refresh GCD inside the configured expiry window may
        -- preempt damage so the already-established defensive layer is not lost.
        if refresh_due then
            if cast(PROBE,"refresh_established_two_stack_self_probes",state,
                urgent and 0 or (cfg.probeReserve or 50.0),probe) then return true,false end
            if R.options.selfHealEnergyPool then return false,true end
        elseif not probe and probe_reason then
            note("probe_state",probe_reason)
        end

        -- Damage-first mode stops here. Probe bootstrap (0/1 -> 2) and normal
        -- Infusion are only offered again after the DPS route reaches a true
        -- filler action. Turning the UI switch off restores self-heal-first mode.
        if phase~="filler" and cfg.damageFirst~=false then return false,false end

        if direct_enabled and cfg.useQuickening~=false and state.quickening and
            hp<=(cfg.quickeningBelow or 90.0) then
            if cast(INFUSION,"filler_quickening_self_heal",state,0) then return true,false end
        end
        local window,window_reason=true,"filler_recovery"
        -- The caller has already exhausted useful Concealment damage actions.
        -- Do not demand a second, unrelated range/LoS gap before replacing its
        -- actual filler with an affordable heal. This never promotes routine
        -- Infusion above Backstab/VS/Laceration or grants a moving hardcast.
        local concealment_filler=loadout.discipline=="Concealment" and
            cfg.concealmentFillerRecovery~=false and phase=="filler" and
            (filler_name=="Rifle Shot" or filler_name=="Overload Shot" or
                filler_name=="no_castable_priority")
        if concealment_filler then
            window_reason="concealment_damage_filler"
        elseif direct_enabled and R.healing and stationary and cfg.opportunityOnly~=false and not urgent then
            window,window_reason=recovery_window(state,world)
        end
        local direct_due=direct_enabled and R.healing and stationary and window
        if direct_due and hp<=begin then
            if cast(INFUSION,urgent and "critical_self_health" or
                ("filler_"..window_reason),state,
                urgent and 0 or (cfg.healReserve or 35.0)) then return true,false end
            if R.options.selfHealEnergyPool then return false,true end
        end
        if cfg.probesEnabled~=false and loadout.known[PROBE] and probe then
            local bootstrap=probe.stacks<2
            if bootstrap then
                local reason="filler_build_two_self_probes"
                if filler_name then reason=reason.."_before_"..tostring(filler_name) end
                if cast(PROBE,reason,state,urgent and 0 or (cfg.probeReserve or 50.0),probe) then
                    return true,false
                end
                if R.options.selfHealEnergyPool then return false,true end
            end
        end
        if direct_due then
            if cast(INFUSION,"filler_"..window_reason,state,
                urgent and 0 or (cfg.healReserve or 35.0)) then return true,false end
            if R.options.selfHealEnergyPool then return false,true end
        elseif direct_enabled and R.healing and stationary and not window then
            note("heal_window","stationary but no recovery opportunity; damage filler remains available")
        end
        return false,false
    end
    local function tick(loadout,active,options)
        return tick_phase(loadout,active,options,"pre",nil)
    end
    local function filler_tick(loadout,active,options,filler_name)
        return tick_phase(loadout,active,options,"filler",filler_name)
    end
    return {tick=tick,filler_tick=filler_tick,stop=stop,owns_pending=owns_pending,
        has_local_pending=function() return R.nativeAdmission~=nil or owns_pending() end,
        observe_events=observe_events,build_id="operative-dps-selfheal-r6-exact-admission-retry"}
end
return M
