-- Pure-Lua tests for schema migration and the PhysicsWorld configuration contract.
local config = require("physics_bone_config")

local function run()
  local passed = 0
  local path = { { name = "root", sameNameIndex = 1 }, { name = "tail", sameNameIndex = 1 } }

  local migrated = config.validate({ schema = 1, diagnostics = true, components = {
    { id = "legacy-tail", name = "Tail", rootPath = path,
      settings = { pull = 42, collision = { enabled = true, self = true } },
      linkOverrides = { ["tail:tip"] = { mass = 2 } } },
  } })
  assert(migrated.schema == 2 and migrated.world.performance == "balanced", "schema 1 profiles migrate to safe schema 2 defaults")
  assert(migrated.components[1].id == "legacy-tail" and migrated.components[1].settings.pull == 42,
    "migration preserves component identity and existing solver values")
  assert(migrated.components[1].settings.collision.self and migrated.components[1].linkOverrides["tail:tip"].mass == 2,
    "migration preserves collision and per-link overrides")
  passed = passed + 1

  local current = config.validate({ schema = 2, world = { performance = "quality", maxPoints = 999,
    collisionMatrix = { body = { tail = false } } }, components = {
    { id = "tail-v2", name = "Tail", kind = "tail", rootPath = path,
      restPose = { { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 } },
      settings = { animationTargetMode = "rest", animationInfluence = 1.4,
        collision = { group = "tail", selfNeighborDepth = 99, mask = { hair = false } } },
      linkOverrides = { ["tail:tip"] = { animationInfluence = 0.25,
        collision = { selfNeighborDepth = 2 } } },
    },
  } })
  local component = current.components[1]
  assert(current.world.performance == "quality" and current.world.maxPoints == 512
    and current.world.collisionMatrix.body.tail == false, "world settings are validated and filters preserved")
  assert(component.kind == "tail" and component.restPose[2].y == -1, "component type and calibrated rest pose are retained")
  assert(component.settings.animationTargetMode == "rest" and component.settings.animationInfluence == 1,
    "animation settings are clamped and kept")
  assert(component.settings.collision.selfNeighborDepth == 8 and component.settings.collision.mask.hair == false,
    "self-collision depth and masks are validated")
  local effective = config.effective(component, "tail:tip")
  assert(effective.animationInfluence == 0.25 and effective.collision.selfNeighborDepth == 2,
    "nested per-link physics overrides merge without leaking")
  passed = passed + 1

  local shared = config.validate({ schema = 2, colliders = {
    { id = "body", path = path, shape = "capsule", group = "body", radius = 2,
      axis = { x = 0, y = 4, z = 0 }, mask = { tail = false } },
  } })
  assert(#shared.colliders == 1 and shared.colliders[1].shape == "capsule"
    and shared.colliders[1].axis.y == 1 and shared.colliders[1].mask.tail == false,
    "avatar-wide colliders are normalized, filtered, and preserved outside any single component")
  passed = passed + 1

  local kinds = config.componentKinds()
  local tailPresets = config.presetsForKind("tail")
  assert(#kinds >= 7 and #tailPresets == 3, "component categories and tail starter profiles are discoverable")
  local foundNaturalTail = false
  for _, preset in ipairs(tailPresets) do
    if preset.id == "natural_tail" then foundNaturalTail = preset.label == "Естественный хвост" end
  end
  assert(foundNaturalTail, "the natural tail starter profile is available to users")

  local starter = config.defaultsForComponent(path, "Tail")
  local defaultPull = starter.settings.pull
  starter.colliders = { { id = "keep", path = path } }
  starter.linkOverrides["tail:tip"] = { mass = 3 }
  local applied, label = config.applyPreset(starter, "natural_tail")
  assert(applied and label == "Естественный хвост" and starter.kind == "tail"
    and starter.presetId == "natural_tail" and starter.settings.collision.group == "tail",
    "applying a starter profile records its category and routes the chain to its collision group")
  assert(starter.settings.pull ~= defaultPull and #starter.colliders == 1
    and starter.linkOverrides["tail:tip"].mass == 3,
    "starter profiles change only component physics settings and preserve collider and link setup")
  starter.settings.pull = 17
  local normalizedStarter = config.validate({ schema = 2, components = { starter } }).components[1]
  assert(normalizedStarter.presetId == "natural_tail" and normalizedStarter.settings.pull == 17,
    "preset identity and later user edits survive save validation")
  passed = passed + 1
  return { passed = passed, failed = 0 }
end

return { run = run }
