-- Lethality route for scripts/live/operative.lua.
-- Progressive 1-80 APL; owned loadout capabilities are authoritative.
-- High-level abilities/passives/tree choices are used only when loadout.known proves them.

local Common = require("operative.lethality_runtime")
local M = {}

function M.new(executor)
    return Common.new(executor, {
        owner = "lethality",
        discipline = "Lethality",
        spender = "Corrosive Assault",
        spenderRange = 10.0,
        dotPolicy = "always",
        dotDuration = 24.0,
        grenadeDuration = 24.0,
        level23Choices = {
            "Corrosive Return",
            "Penetrating Strategies",
            "Corrosive Impair",
        },
        level27Choices = {
            "Curbing Strategies",
            "Debilitate",
            "Sly Countermeasures",
        },
        level39Choices = {
            "Critical Grenade",
            "Corrosive Refund",
            "Corrosive Defense",
        },
        level43Choices = {
            "Tactical Stims",
            "Tactical Overdrive",
            "Tactical Offense",
        },
        level51Choices = {
            "Infiltrator",
            "Advanced Cloaking",
            "Chem-resistant Inlays",
        },
        level64Choices = {
            "Med Shield",
            "Endorphin Rush",
            "Evasive Screen",
        },
        level68Choices = {
            "Infiltrate",
            "Flash Bang",
            "Holotraverse",
        },
        level73Choices = {
            "Evasive Imperative",
            "Jarring Strike",
            "Blow for Blow",
        },
    })
end

return M