-- Smoke/contract checks for the reusable F8 UI pages and world-profile controls.
local uiApi = require("physics_bone_ui")
local configApi = require("physics_bone_config")

local function run()
  local draft = configApi.defaults()
  local updates = 0
  local ui = uiApi.new(nil, draft, {
    changed = function() updates = updates + 1 end,
  })
  assert(ui.page == "components", "the existing component editor remains the default page")
  ui:writeSetting({ world = true, path = "performance" }, "quality")
  assert(ui.draft.world.performance == "quality" and ui.draft.world.maxPoints == 128
    and ui.draft.world.maxCandidatePairs == 1024 and ui.draft.world.segmentMode == "segment_segment",
    "choosing Quality applies its matching shared-world budgets and collision tier")
  ui:writeSetting({ world = true, path = "maxBlockQueries" }, 12)
  assert(ui.draft.world.maxBlockQueries == 12 and updates == 2,
    "world parameters are editable and notify the live draft callback")

  local path = { { name = "root", sameNameIndex = 1 } }
  local component = configApi.defaultsForComponent(path, "Ears")
  component.kind = "hair"
  component.settings.collision.group = "hair"
  local node = { key = "root[1]", path = path, transformable = true, children = {} }
  local registry = { flat = { node }, byKey = { [node.key] = node } }
  local componentDraft = configApi.defaults()
  componentDraft.components = { component }
  local componentUi = uiApi.new(registry, componentDraft, { changed = function() updates = updates + 1 end })
  componentUi.selectedKey, componentUi.activeComponentId = node.key, component.id
  componentUi.graphs = { { links = {}, linkByKey = {} } }
  local selectedComponent = componentUi.draft.components[1]
  local defaultPull = selectedComponent.settings.pull
  assert(componentUi:cycleComponentKind(1) and selectedComponent.kind == "ears",
    "the F8 category selector updates the selected component category")
  assert(componentUi:cycleComponentPreset(1) and componentUi.presetChoices[selectedComponent.id] == "heavy_ears"
    and selectedComponent.settings.pull == defaultPull,
    "choosing a starter profile previews it without overwriting settings")
  assert(componentUi:applyComponentPreset() and selectedComponent.presetId == "heavy_ears"
    and selectedComponent.settings.mass > 1 and selectedComponent.settings.collision.group == "ears",
    "applying the selected starter profile updates physics and its collision group")
  return { passed = 6, failed = 0 }
end

return { run = run }
