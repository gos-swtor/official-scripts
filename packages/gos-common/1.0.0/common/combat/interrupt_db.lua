-- Shared PvP interrupt catalog. Exact normalized cast names only.
-- Cast snapshots currently expose no stable public definition key, so this DB
-- deliberately does not pretend to have cleanse_db-style definition identity.
-- Names below were cross-checked against the installed class ability catalog.
return {
    revision = "2026-09-18-pvp-interrupt-db-r3-heal-cc-priority",
    identity = "exact_cast_name_v1",
    default_progress = 0.85,
    interruptors = {
        operative = "Distraction", scoundrel = "Distraction",
        sniper = "Distraction", gunslinger = "Distraction",
        mercenary = "Disabling Shot", commando = "Disabling Shot",
        powertech = "Quell", vanguard = "Riot Strike",
        sorcerer = "Jolt", assassin = "Jolt",
        sage = "Mind Snap", shadow = "Mind Snap",
        juggernaut = "Disruption", marauder = "Disruption",
        guardian = "Force Kick", sentinel = "Force Kick",
    },
    -- Hold Position makes Sniper/Gunslinger interrupt-immune while in cover.
    -- Public GoS has no proven cover-state flag, so callers fail closed here.
    always_skip_styles = { sniper = "cover_interrupt_immunity", gunslinger = "cover_interrupt_immunity" },
    immunity_buffs = {
        "Polarity Shift", "Mental Alacrity", "Power Surge", "Tech Override",
        "Power Shield", "Combat Shield", "Entrench", "Hunker Down",
    },
    sources = {
        local_catalog = "build/generated/swtor/class_ability_catalog.tsv",
        vulkk_79 = "Current SWTOR 7.9 class guides (checked 2026-09-17)",
        swtorista = "Current class ability/basics pages (checked 2026-09-17)",
        pvp = "PvP guides/community interrupt recommendations",
    },
    rules = {
        -- P1: healer battle resurrection.
        { name="Reanimation", priority=1, tier="resurrection", styles={"sorcerer"}, disciplines={"corruption"} },
        { name="Revival", priority=1, tier="resurrection", styles={"sage"}, disciplines={"seer"} },
        { name="Resuscitation Probe", priority=1, tier="resurrection", styles={"operative"}, disciplines={"medic"} },
        { name="Heartrigger Patch", priority=1, tier="resurrection", styles={"scoundrel"}, disciplines={"sawbones"} },
        { name="Onboard AED", priority=1, tier="resurrection", styles={"mercenary"}, disciplines={"bodyguard"} },
        { name="Emergency Medical Probe", priority=1, tier="resurrection", styles={"commando"}, disciplines={"combat medic"} },

        -- P10: core healer channels. Valuable, but major direct heals and long pre-landing CC rank above them.
        -- Mirror pairs stay symmetric: Innervate=Healing Trance, Progressive Scan=Successive Treatment.
        { name="Innervate", priority=10, tier="healer_core", styles={"sorcerer"}, disciplines={"corruption"} },
        { name="Healing Trance", priority=10, tier="healer_core", styles={"sage"}, disciplines={"seer"} },
        { name="Progressive Scan", priority=10, tier="healer_core", styles={"mercenary"}, disciplines={"bodyguard"} },
        { name="Successive Treatment", priority=10, tier="healer_core", styles={"commando"}, disciplines={"combat medic"} },
        { name="Kolto Waves", priority=10, tier="healer_core", styles={"operative","scoundrel"}, disciplines={"medic","sawbones"} },
        -- P8: major direct heals. Denying the large committed heal generally beats interrupting a cheap healer channel.
        { name="Healing Scan", priority=8, tier="healer_big", styles={"mercenary"}, disciplines={"bodyguard"} },
        { name="Advanced Medical Probe", priority=8, tier="healer_big", styles={"commando"}, disciplines={"combat medic"} },
        { name="Kolto Injection", priority=8, tier="healer_big", styles={"operative"}, disciplines={"medic"} },
        { name="Underworld Medicine", priority=8, tier="healer_big", styles={"scoundrel"}, disciplines={"sawbones"} },
        { name="Kolto Infusion", priority=8, tier="healer_big", styles={"operative"} },
        { name="Kolto Pack", priority=8, tier="healer_big", styles={"scoundrel"} },
        { name="Dark Infusion", priority=8, tier="healer_big", styles={"sorcerer"}, disciplines={"corruption"} },
        { name="Deliverance", priority=8, tier="healer_big", styles={"sage"}, disciplines={"seer"} },

        -- P16: casted healer fallback. Useful lockout, but loses to the heals above.
        { name="Rapid Scan", priority=16, tier="healer_fallback", styles={"mercenary"} },
        { name="Medical Probe", priority=16, tier="healer_fallback", styles={"commando"} },
        { name="Dark Heal", priority=16, tier="healer_fallback", styles={"sorcerer"} },
        { name="Benevolence", priority=16, tier="healer_fallback", styles={"sage"} },

        -- P5: long pre-landing mezzes. If these complete, a player can lose multiple GCDs.
        { name="Whirlwind", priority=5, tier="control", styles={"sorcerer","assassin"} },
        { name="Force Lift", priority=5, tier="control", styles={"sage","shadow"} },
        { name="Concussion Missile", priority=5, tier="control", styles={"mercenary"} },
        { name="Concussive Round", priority=5, tier="control", styles={"commando"} },
        -- P14: casted ground/group healing. Valuable under stacked pressure.
        { name="Revivification", priority=14, tier="healer_area", styles={"sorcerer"}, disciplines={"corruption"} },
        { name="Salvation", priority=14, tier="healer_area", styles={"sage"}, disciplines={"seer"} },

        -- P30: high-value burst casts/channels called out by current spec guides.
        { name="Thundering Blast", priority=30, tier="burst", styles={"sorcerer"}, disciplines={"lightning"} },
        { name="Turbulence", priority=30, tier="burst", styles={"sage"}, disciplines={"telekinetics"} },
        { name="Force Leech", priority=30, tier="burst", styles={"sorcerer"}, disciplines={"madness"} },
        { name="Force Serenity", priority=30, tier="burst", styles={"sage"}, disciplines={"balance"} },
        { name="Blazing Bolts", priority=30, tier="burst", styles={"mercenary"}, disciplines={"arsenal"} },
        { name="Boltstorm", priority=30, tier="burst", styles={"commando"}, disciplines={"gunnery"} },
        { name="Unload", priority=32, tier="pressure_channel", styles={"mercenary"} },
        { name="Full Auto", priority=32, tier="pressure_channel", styles={"commando"} },

        -- P35: meaningful hardcasts that establish/refresh high-value pressure.
        { name="Crushing Darkness", priority=35, tier="pressure_cast", styles={"sorcerer"} },
        { name="Mind Crush", priority=35, tier="pressure_cast", styles={"sage"} },
        { name="Demolish", priority=35, tier="pressure_cast", styles={"sorcerer"}, disciplines={"madness"} },
        { name="Vanquish", priority=35, tier="pressure_cast", styles={"sage"}, disciplines={"balance"} },
    },

    -- Objective interactions are exposed by gos.events.casts(), but PvP rules stop
    -- them reliably with direct damage. Keep them queryable, never feed them to an
    -- interrupt ability until native evidence proves Distraction-style interrupts work.
    objectives = {
        ["capturing the objective"] = { priority=0, method="direct_damage", label="CAPTURE" },
        ["controlling the turret"] = { priority=0, method="direct_damage", label="CAPTURE" },
        ["disarming explosives"] = { priority=0, method="direct_damage", label="DISARM" },
        ["placing explosives"] = { priority=0, method="direct_damage", label="PLANT" },
    },
}