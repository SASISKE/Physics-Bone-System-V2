-- Runs inside Figura through the isolated V2 test driver.
-- These checks exercise the exact Lua collision geometry used by the runtime.
local collisions = require("physics_bone_collisions")
local config = require("physics_bone_config")

local function near(actual, expected, tolerance, label)
  assert(type(actual) == "number" and actual == actual, label .. ": result is not finite")
  assert(math.abs(actual - expected) <= tolerance,
    label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function run()
  local passed = 0
  local box = { min = { x = 0, y = 0, z = 0 }, max = { x = 1, y = 1, z = 1 } }
  local outside, outsideNormal, outsideDepth = collisions.projectSphereAabb(
    { x = 1.5, y = 1.5, z = 1.5 }, 0.25, box)
  assert(outside == nil and outsideNormal == nil and outsideDepth == 0,
    "sphere outside an AABB must remain untouched")
  passed = passed + 1

  local inside = collisions.projectSphereAabb({ x = 0.5, y = 0.9, z = 0.5 }, 0.25, box)
  assert(inside and inside.y > 1.249, "sphere penetrating the top face must be projected above it")
  passed = passed + 1

  local sphere, sphereNormal = collisions.projectSphereCapsule(
    { x = 0, y = 0, z = 0 }, 0.2,
    { x = 0, y = -1, z = 0 }, { x = 0, y = 1, z = 0 }, 0.5)
  assert(sphere and sphereNormal and math.sqrt(sphere.x * sphere.x + sphere.z * sphere.z) > 0.69,
    "capsule centerline overlap must resolve by the combined radii")
  passed = passed + 1

  local point, previous = collisions.resolvePoint(
    { x = 0.5, y = 0.9, z = 0.5 }, { x = 0.3, y = 1.1, z = 0.5 },
    0.25, { box }, 0.02, 0.5, 0)
  assert(point and previous and point.y > 1.249, "contact resolver must project the particle out of the block")
  local velocityX = (point.x - previous.x) / 0.02
  local velocityY = (point.y - previous.y) / 0.02
  near(velocityX, 5, 0.05, "friction must damp tangential velocity")
  near(velocityY, 0, 0.05, "zero restitution must remove inward normal velocity")
  passed = passed + 1

  local sweptAabb, sweptAabbPrevious, aabbContacts = collisions.resolvePoint(
    { x = 2, y = 0.5, z = 0.5 }, { x = -1, y = 0.5, z = 0.5 },
    0.1, { box }, 0.02, 0, 0)
  assert(aabbContacts > 0 and sweptAabb.x < 0 and sweptAabb.x <= -0.099,
    "a fast sphere must not tunnel through a block AABB")
  near((sweptAabb.x - sweptAabbPrevious.x) / 0.02, 0, 0.02,
    "zero restitution must stop normal motion at a swept block contact")
  passed = passed + 1

  local overlapStart = collisions.resolvePoint(
    { x = 2, y = 0.5, z = 0.5 }, { x = -0.05, y = 0.5, z = 0.5 },
    0.1, { box }, 0.02, 0, 0)
  assert(overlapStart.x <= -0.099,
    "an initially overlapping sphere moving into a block must not tunnel out the far side")
  passed = passed + 1

  local sweptSphere, _, sphereContacts = collisions.resolvePoint(
    { x = 2, y = 0, z = 0 }, { x = -2, y = 0, z = 0 },
    0.25, { { kind = "sphere", center = { x = 0, y = 0, z = 0 }, radius = 0.5 } }, 0.02, 0, 0)
  assert(sphereContacts > 0 and sweptSphere.x < -0.74,
    "a fast sphere must not tunnel through an avatar sphere collider")
  passed = passed + 1

  local overlapSphere = collisions.resolvePoint(
    { x = 2, y = 0, z = 0 }, { x = -0.5, y = 0, z = 0 },
    0.25, { { kind = "sphere", center = { x = 0, y = 0, z = 0 }, radius = 0.5 } }, 0.02, 0, 0)
  assert(overlapSphere.x <= -0.74,
    "an overlapping sphere collider must stop a fast particle moving deeper through it")
  passed = passed + 1

  local sweptCapsule, _, capsuleContacts = collisions.resolvePoint(
    { x = 2, y = 0, z = 0 }, { x = -2, y = 0, z = 0 },
    0.25, { { kind = "capsule", a = { x = 0, y = -1, z = 0 },
      b = { x = 0, y = 1, z = 0 }, radius = 0.5 } }, 0.02, 0, 0)
  assert(capsuleContacts > 0 and sweptCapsule.x < -0.74,
    "a fast sphere must not tunnel through an avatar capsule collider")
  passed = passed + 1

  local slidingPoint = collisions.resolvePoint(
    { x = 2, y = 0.5, z = 2 }, { x = -1, y = 0.5, z = 0 },
    0.1, { box }, 0.02, 0.5, 0)
  assert(slidingPoint.x < 0 and slidingPoint.z > 0.5 and slidingPoint.z < 2,
    "swept contact must retain and friction-damp tangential movement")
  passed = passed + 1

  local points = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 2, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
  }
  local previousPoints = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 2, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
  }
  local selfContacts = collisions.resolveSelf(points, previousPoints,
    { edges = { { from = 1, to = 2 }, { from = 2, to = 3 }, { from = 3, to = 4 } } },
    { 0, 0.5, 0.5, 0.5 }, 1 / 60, {}, 2048)
  assert(selfContacts == 1 and math.abs(points[2].x - points[4].x) >= 0.999,
    "self-collision must separate non-adjacent chain points")
  passed = passed + 1

  local branchPoints = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 0, y = 0, z = 0 }, { x = 4, y = 0, z = 0 },
  }
  local branchPrevious = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 0, y = 0, z = 0 }, { x = 4, y = 0, z = 0 },
  }
  local branchContacts, branchPairChecks = collisions.resolveSelf(branchPoints, branchPrevious,
    { edges = { { from = 2, to = 4 }, { from = 4, to = 3 } } },
    { 0, 0.5, 0.5, 0.5 }, 1 / 60, {}, 32, 1)
  assert(branchContacts == 1 and branchPairChecks == 1
      and math.abs(branchPoints[2].x - branchPoints[3].x) >= 0.999,
    "array-adjacent points at graph distance two must still collide")
  passed = passed + 1

  local depthPoints = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 4, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
  }
  local depthPrevious = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 4, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
  }
  local depthContacts, depthPairChecks = collisions.resolveSelf(depthPoints, depthPrevious,
    { edges = { { from = 2, to = 3 }, { from = 3, to = 4 } } },
    { 0, 0.5, 0.5, 0.5 }, 1 / 60, {}, 32, 2)
  assert(depthContacts == 0 and depthPairChecks == 0 and depthPoints[2].x == depthPoints[4].x,
    "configurable graph-distance depth must exclude two-hop neighbors")
  passed = passed + 1

  local directPoints = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 4, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
  }
  local directPrevious = {
    { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
    { x = 4, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
  }
  local directContacts, directPairChecks = collisions.resolveSelf(directPoints, directPrevious,
    { edges = { { from = 2, to = 4 } } }, { 0, 0.5, 0.5, 0.5 }, 1 / 60, {}, 32)
  assert(directContacts == 0 and directPairChecks == 0 and directPoints[2].x == directPoints[4].x,
    "branched direct neighbors with nonadjacent indices must be excluded")
  passed = passed + 1

  local crowdedPoints, crowdedPrevious, crowdedRadii = { { x = 0, y = 0, z = 0 } }, { { x = 0, y = 0, z = 0 } }, { 0 }
  for index = 2, 10 do
    crowdedPoints[index], crowdedPrevious[index], crowdedRadii[index] = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 0.5
  end
  local _, pairChecks, pairBudget = collisions.resolveSelf(crowdedPoints, crowdedPrevious,
    { edges = {} }, crowdedRadii, 1 / 60, {}, 1)
  assert(pairChecks <= 1 and pairBudget,
    "self-collision pair budget must cap candidate checks for dense overlapping chains")
  passed = passed + 1

  local defaults = config.defaults()
  assert(defaults.components and defaults.schema == 2, "config defaults must preserve the current schema")
  local validated, warnings = config.validate({
    schema = 1,
    components = { {
      id = "collision_validation", rootPath = { { name = "root", sameNameIndex = 1 } },
      settings = { collision = { enabled = true, maxBlockQueries = 999, maxSelfPairs = 99999, iterations = 0 } },
      colliders = { {
        id = "body", path = { { name = "root", sameNameIndex = 1 }, { name = "body", sameNameIndex = 1 } },
        shape = "capsule", radius = 999, height = -4, axis = { x = 0, y = 0, z = 0 },
        offset = { x = 100, y = 0, z = 0 },
      } },
    } },
  })
  local component = validated.components[1]
  assert(component.settings.collision.enabled and component.settings.collision.maxBlockQueries == 256,
    "collision settings must validate and clamp query budgets")
  assert(component.settings.collision.maxSelfPairs == 16384 and component.settings.collision.iterations == 1,
    "self-pair and solver-iteration budgets must validate and clamp")
  local collider = component.colliders[1]
  assert(collider.shape == "capsule" and collider.radius == 16 and collider.height == 0,
    "collider shape dimensions must validate within safe bounds")
  assert(collider.offset.x == 64 and collider.axis.y == 1,
    "collider offsets and degenerate local axes must normalize safely")
  assert(#warnings > 0, "clamped malformed collider settings must be reported")
  passed = passed + 1

  return { passed = passed, failed = 0 }
end

return { run = run }
