-- Canonical Commando priorities, translated only at client API boundaries.
-- Pairings: local class_ability_catalog.tsv, package slots and exact effect payloads.
local M = {}
local function finite(n) return type(n)=="number" and n==n and n>-math.huge and n<math.huge end
local DISCIPLINES = {
    commando = { Gunnery="Gunnery", ["Assault Specialist"]="Assault Specialist", ["Combat Medic"]="Combat Medic" },
    mercenary = { Arsenal="Gunnery", ["Innovative Ordnance"]="Assault Specialist", Bodyguard="Combat Medic" },
}
local NAMES = {
    ["Hammer Shot"]="Rapid Shots", ["Charged Bolts"]="Power Shot",
    ["High Impact Bolt"]="Rail Shot", ["Full Auto"]="Unload",
    ["Grav Round"]="Tracer Missile", ["Boltstorm"]="Blazing Bolts",
    ["Demolition Round"]="Heatseeker Missiles", ["Vortex Bolt"]="Priming Shot",
    ["Incendiary Round"]="Incendiary Missile", ["Serrated Bolt"]="Serrated Shot",
    ["Assault Plastique"]="Thermal Detonator", ["Mag Bolt"]="Mag Shot",
    ["Explosive Round"]="Missile Blast", ["Plasma Grenade"]="Fusion Missile",
    ["Mortar Volley"]="Death from Above", ["Hail of Bolts"]="Sweeping Blasters",
    ["Sticky Grenade"]="Sticky Dart", ["Electro Net"]="Electro Net",
    ["High Velocity Supercharged Cell"]="High Velocity Supercharged Gas",
    ["Supercharged Cell"]="Supercharged Gas", ["Supercharged Kolto Cell"]="Supercharged Kolto Gas",
    ["Supercharged Celerity"]="Supercharged Celerity", ["Recharge Cells"]="Vent Heat",
    ["Tech Override"]="Power Surge", ["Reserve Powercell"]="Thermal Sensor Override",
    ["Reactive Shield"]="Energy Shield", ["Adrenaline Rush"]="Kolto Overload",
    ["Echoing Deterrence"]="Responsive Safeguards", ["Diversion"]="Chaff Flare",
    ["Concussion Charge"]="Jet Boost", ["Concussive Round"]="Concussion Missile",
    ["Cryo Grenade"]="Electro Dart", ["Disabling Shot"]="Disabling Shot",
    ["Propulsion Round"]="Rocket Out", ["Hold the Line"]="Hydraulic Overrides",
    ["Tenacity"]="Determination", ["Advanced Recon Droid"]="Advanced Terminator Droid",
    ["Field Aid"]="Cure", ["Recharge and Reload"]="Recharge and Reload",
    ["Bacta Infusion"]="Emergency Scan", ["Medical Probe"]="Rapid Scan",
    ["Advanced Medical Probe"]="Healing Scan", ["Med Shot"]="Kolto Shot",
    ["Trauma Probe"]="Kolto Shell", ["Kolto Bomb"]="Kolto Missile",
    ["Successive Treatment"]="Progressive Scan",
}
-- Talents use Core's FQN-derived title, which preserves capitals in Of/The/And.
local KNOWN = {
    ["Armor-piercing Cell"]="High Velocity Gas Cylinder", ["Charged Barrel"]="Tracer Lock",
    ["Cell Charger"]="Terminal Velocity", ["Curtain of Fire"]="Barrage",
    ["Blowback"]="Blowback", ["Advanced Targeting"]="Advanced Targeting",
    ["Target Lock"]="Advanced Targeting", ["Blazing Barrel"]="Blazing Barrels",
    ["Deadly Cannon"]="Target Tracking", ["Forced March"]="Thrill Of The Hunt",
    ["Decoy"]="Decoy", ["Honed Lock"]="Honed Lock",
    ["Proficient Gravitation"]="Proficient Tracing", ["Gravitating Bolt"]="Signature Shot",
    ["Grav Trio"]="Triple Trace", ["Charged Barrier"]="Power Barrier",
    ["Customized Round"]="Customized Warhead", ["Gravitating Compound"]="Tracing Residue",
    ["Thermonuclear Plasma"]="Thermonuclear Fusion", ["Overclock"]="Power Overrides",
    ["Cell Capacitor"]="Improved Vents", ["Reflexive Shield"]="Energy Rebounder",
    ["Tenacious Defense"]="Jet Escape", ["Adrenal Surge"]="Kolto Surge",
    ["Combat Shield"]="Power Shield", ["One Man Army"]="Tag And Bag",
    ["Concussive Force"]="Afterburners", ["Trauma Stabilizers"]="Trauma Regulators",
    ["Pre-emptive Strike"]="Early Ignition", ["Hyper Cinders"]="Volatile Cinders",
    ["Eruptive Flames"]="Eruptive Flames", ["Incendiary Ignition"]="Incendiary Ignition",
    ["Slow Burn"]="Slow Burn", ["Heavy Shrapnel"]="Heavy Shrapnel",
    ["Explosive Dissemination"]="Collateral Damage", ["Special Munitions"]="Upgraded Arsenal",
    ["Scorching Bolts"]="Superheated Shot", ["Sweltering Heat"]="Sweltering Heat",
    ["Extra Rounds"]="Fuel Reserves", ["Potent Medicine"]="Warden",
    ["Ionic Accelerator"]="Innovative Particle Accelerator",
    ["Hyper Assault Rounds"]="Volatile Warhead", ["Blazing Celerity"]="Speed to Burn",
    ["Relentless Assault"]="Relentless Ordnance", ["Boosted Bolts"]="Surging Shots",
    ["Impact Explosives"]="Impact Explosives", ["Emergency Response"]="Emergency Response",
    ["Field Triage"]="Critical Efficiency", ["Parallactic Combat Stims"]="Gyroscopic Alignment Jets",
}
-- Exact Mercenary producer labels before client-name enrichment.
local MERCENARY_KNOWN = {
    ["Mortar Volley"]="Death From Above",
    ["Recharge and Reload"]="Recharge And Reload",
}
-- These are the exact same installed action nodes before client-name enrichment.
-- Native name lookup ignores case, but does not reorder or rename words.
local MERCENARY_ACTION_NAMES = {
    ["High Velocity Supercharged Cell"]={name="Supercharged Gas High Velocity",discipline="Arsenal"},
    ["Supercharged Kolto Cell"]={name="Supercharged Gas Support",discipline="Bodyguard"},
    ["Sticky Grenade"]={name="Explosive Dart"},
    ["Advanced Recon Droid"]={name="Stealth Scan"},
}
-- Definitions identify the actual proc/DoT, including children sharing a parent label.
local EFFECTS = {
    ["effectdef:48DFDC2D8B035FB3"]="effectdef:2C468CDE650D3843", -- Gravity Vortex / Heat Signature
    ["effectdef:4094612E686B24C8"]="effectdef:0666DCB98B7253BC", -- Charged Barrel / Tracer Lock
    ["effectdef:25C02DF930062E50"]="effectdef:F4DF68FAC7A6C50A", -- Grav Primer / Tracer Beacon
    ["effectdef:5CBEFE1266A504DB"]="effectdef:2ADAA396E37086C2", -- Curtain of Fire / Barrage
    ["effectdef:14849C9D17C954C2"]="effectdef:812AB9EC2DAD1A19",
    ["effectdef:AD8760A50CB0EC2C"]="effectdef:FFD8659326A55E1E",
    ["effectdef:91971DF4ADA10EE1"]="effectdef:7F1955605C7DBAD4",
    ["effectdef:41DBD763301D3125"]="effectdef:7F08272CBDC0673B",
    ["effectdef:288DF8D3BACEF5EF"]="effectdef:D5070629B4DAC3D6",
    ["effectdef:F5B95E8D5747CBD9"]="effectdef:EBF739E9BA71C506",
    ["effectdef:04037875BB6FD1BA"]="effectdef:FDF3D056067A20DB",
    ["effectdef:B8B73D76FE55C715"]="effectdef:5CA00A266DE81AAB",
    ["effectdef:B6F833FC4DFFF529"]="effectdef:34B1E0DA356B3B71",
    ["effectdef:AD25295E3C68B056"]="effectdef:4BFF8834AA9F90D6",
    ["effectdef:85F0A3E5F7B43137"]="effectdef:180FDE0EFD267A1F",
    ["effectdef:4AFB5FCA0B2AD7E3"]="effectdef:0EDAC79E38725513",
    ["effectdef:F53BE068B5FF3435"]="effectdef:0E3445B071FFBBDA",
    ["effectdef:484CD6A543F591ED"]="effectdef:150FC3CD709EF505",
    ["effectdef:3D39BFB7265327BE"]="effectdef:0FBF1CF90AB0973B",
    ["effectdef:7A432D6CF9248379"]="effectdef:659CC691158BE035",
    ["effectdef:3C390641629F4D3D"]="effectdef:90C6F9F7F4F8DAAD",
    ["effectdef:1E1237729FDB8C7E"]="effectdef:1486EC696FA6F474",
    ["effectdef:6E6E656AE6111B0A"]="effectdef:24671DD9B251D63C",
    ["effectdef:665D2BCF57836027"]="effectdef:A527EFD141A65A6F",
    ["effectdef:103891660EBBD7CB"]="effectdef:5B4211E1FB4C0922",
    ["effectdef:D502E612305F58A1"]="effectdef:371D3EF5165E440B",
    ["effectdef:61220D98C36B504D"]="effectdef:D6775A07DCE59C9A",
    ["effectdef:7C066C869F2E70AE"]="effectdef:776AB7AA35D7DA0B",
    ["effectdef:002298C6BF041F6B"]="effectdef:01853F36FF168D7D",
    -- Shared Mercenary/Commando tactical definitions are identical client objects.
    ["effectdef:5E0D71565AC0F66F"]="effectdef:5E0D71565AC0F66F",
    ["effectdef:F0EB51F5EE176AB9"]="effectdef:F0EB51F5EE176AB9",
    ["effectdef:A14DDAE20E09C598"]="effectdef:A14DDAE20E09C598",
}
local EFFECT_NAMES = { ["Recharge Cells"]="Vent Heat", Supercharge="Supercharge",
    ["Charged Barrel"]="Tracer Lock", ["Grav Primer"]="Tracer Beacon" }
local REVERSE = {}
for canonical, actual in pairs(NAMES) do REVERSE[actual]=canonical end
for canonical, actual in pairs(EFFECT_NAMES) do REVERSE[actual]=canonical end
for canonical, actual in pairs(MERCENARY_KNOWN) do REVERSE[actual]=canonical end
local PROTOTYPE_REVERSE = {}
for canonical, prototype in pairs(MERCENARY_ACTION_NAMES) do
    PROTOTYPE_REVERSE[prototype.name]={canonical=canonical,discipline=prototype.discipline}
end
local KNOWN_META = { __index=function(known,name)
    -- Exact PrettyAbilityName for abl.bounty_hunter.skill.innovative_ordnance.speed_to_burn.
    if name=="Blazing Celerity" and known._raw["Speed To Burn"]==true then return true end
    local prototype=MERCENARY_ACTION_NAMES[name]
    if prototype and (not prototype.discipline or prototype.discipline==known._discipline) and
        known._raw[prototype.name]==true then return true end
    local alias=MERCENARY_KNOWN[name]
    if alias and known._raw[alias]==true then return true end
    local actual=KNOWN[name] or NAMES[name]
    return actual and known._raw[actual] or nil
end }

local function style(loadout)
    return type(loadout)=="table" and (loadout._commando_mirror_style or loadout.combat_style) or nil
end
function M.raw_loadout(loadout)
    return type(loadout)=="table" and (loadout._commando_mirror_raw or loadout) or loadout
end
function M.adapt_loadout(loadout)
    if type(loadout)~="table" or loadout._commando_mirror_style then return loadout end
    if loadout.combat_style=="commando" then return loadout end
    local disciplines=DISCIPLINES[loadout.combat_style]
    local discipline=disciplines and disciplines[loadout.discipline]
    if not discipline then return loadout end
    local out={}
    for key,value in pairs(loadout) do out[key]=value end
    out._commando_mirror_raw=loadout
    out._commando_mirror_style=loadout.combat_style
    out.combat_style,out.discipline="commando",discipline
    if type(loadout.known)=="table" then
        out.known=setmetatable({_raw=loadout.known,_discipline=loadout.discipline},KNOWN_META)
    end
    return out
end
function M.ability(loadout,name)
    if style(loadout)~="mercenary" then return name end
    local actual=NAMES[name]
    local raw=M.raw_loadout(loadout)
    if type(raw)~="table" or type(raw.known)~="table" then return actual end
    if raw.known[actual]==true then return actual end
    local prototype=MERCENARY_ACTION_NAMES[name]
    if prototype and (not prototype.discipline or prototype.discipline==raw.discipline) and
        raw.known[prototype.name]==true then return prototype.name end
    return actual
end
function M.call(loadout,operation,name,...)
    local actual=M.ability(loadout,name)
    if actual==nil then return nil end
    return gos.abilities[operation](actual,...)
end
function M.effect_key(loadout,key)
    if style(loadout)~="mercenary" then return key end
    return EFFECTS[key]
end
function M.effect_name(loadout,name)
    if style(loadout)~="mercenary" then return name end
    return EFFECT_NAMES[name]
end
function M.canonical(loadout,name)
    if style(loadout)~="mercenary" then return name end
    local prototype=PROTOTYPE_REVERSE[name]
    local raw=M.raw_loadout(loadout)
    if prototype and (not prototype.discipline or type(raw)=="table" and
        prototype.discipline==raw.discipline) then return prototype.canonical end
    return REVERSE[name] or name
end
function M.event(loadout,event)
    if style(loadout)~="mercenary" or type(event)~="table" then return event end
    local name=M.canonical(loadout,event.name)
    local ability=M.canonical(loadout,event.ability)
    if name==event.name and ability==event.ability then return event end
    local out={}
    for key,value in pairs(event) do out[key]=value end
    out.name,out.ability=name,ability
    return out
end
function M.resource(loadout,resource)
    if style(loadout)~="mercenary" then return resource end
    if type(resource)~="table" or resource.kind~="heat" or not finite(resource.current) or
        not finite(resource.max) or resource.max<=0 or resource.current<0 or resource.current>resource.max then return nil end
    return {current=resource.max-resource.current,max=resource.max,
        percent=(resource.max-resource.current)/resource.max*100,kind=resource.kind}
end
function M.settings(schema)
    for _,field in ipairs(schema.fields) do
        if type(field.disciplines)=="table" then
            local count=#field.disciplines
            for i=1,count do
                for actual,canonical in pairs(DISCIPLINES.mercenary) do
                    if field.disciplines[i]==canonical then field.disciplines[#field.disciplines+1]=actual end
                end
            end
        end
        if field.requires_ability and NAMES[field.requires_ability]~=field.requires_ability then
            -- Core's schema accepts one raw name; the route owns learned-ability admission.
            field.requires_ability=nil
        end
    end
    return schema
end
return M
