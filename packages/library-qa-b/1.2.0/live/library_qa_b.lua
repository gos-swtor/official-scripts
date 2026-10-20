local VERSION = "1.2.0"
local Shared = require("library_qa.shared")
assert(Shared.version == "1.1.0", "Library QA requires shared 1.1.0")
local Settings = gos.settings.register("library_qa_b", {
    title = "Library QA B " .. VERSION,
    version = 1,
    activation = { mode = "manual" },
    fields = {
        { key = "marker", type = "int", label = "Saved marker", default = 0,
          min = 0, max = 999999, step = 1,
          tooltip = "Set a distinct value to verify it survives updates and version switches." },
    },
})

gos.log.info("[library-qa-b] script=" .. VERSION .. " shared=" .. Shared.version .. " marker=" .. tostring(Settings.marker))
gos.on_tick(function()
    gos.overlay.draw_text("library-qa-b:version", {
        at = { screen = { x = 28, y = 202 } },
        text = "Library QA B " .. VERSION .. " | shared " .. Shared.version .. " | marker " .. tostring(Settings.marker),
        font_size = 14, shadow = true, ttl = 0.20,
    })
end)
