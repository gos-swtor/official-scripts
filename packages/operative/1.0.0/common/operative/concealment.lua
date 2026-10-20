-- Concealment route for scripts/live/operative.lua.
-- Progressive 1-80 APL; owned loadout capabilities are authoritative.

local Common = require("operative.route_common")
local M = {}

function M.new(executor)
    return Common.new(executor, {
        owner = "concealment",
        discipline = "Concealment",
        spender = "Laceration",
        dotPolicy = "durable",
        dotDuration = 18.0,
        level23Choices = {
            "Roll Knife",
            "Relentless Blades",
            "Defensive Stance",
        },
        level27Choices = {
            "Curbing Strategies",
            "Debilitate",
            "Quick Countermeasures",
        },
        level39Choices = {
            "Crippling Throw",
            "The Best Defense",
            "Crippling Wounds",
        },
        level43Choices = {
            "Tactical Critical",
            "Advanced Stealth",
            "Tactical Overdrive",
        },
        level51Choices = {
            "Infiltrator", "Advanced Cloaking", "Chem-resistant Inlays",
        },
        level64Choices = {
            "Med Shield", "Endorphin Rush", "Evasive Screen",
        },
        level68Choices = {
            "Infiltrate", "Flash Bang", "Holotraverse",
        },
        level73Choices = {
            "Evasive Imperative", "Jarring Strike", "Blow for Blow",
        },
    })
end

return M