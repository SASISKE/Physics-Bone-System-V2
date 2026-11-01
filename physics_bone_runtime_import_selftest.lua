-- Figura adapter import smoke test with the smallest required event stubs.
keybinds = { newKeybind = function() return {} end }
events = setmetatable({}, { __index = function()
  return { register = function() end }
end })

local studio = require("physics_bone_studio")

local function run()
  assert(type(studio.tick) == "function" and type(studio.render) == "function"
    and type(studio.postRender) == "function", "the Figura adapter imports and exposes its scheduled callbacks")
  return { passed = 1, failed = 0 }
end

return { run = run }
