-- Pure-Lua contracts for the shared PhysBone world scheduler and contacts.
local api = require("physics_bone_world")
local core = require("physics_bone_core")
local constraints = require("physics_bone_constraints")

local function point(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function near(a, b, e) return math.abs(a - b) <= (e or 0.001) end
local function component(id, points, radii, inverseMasses, group, edges)
  local previous, info = {}, {}
  for i, p in ipairs(points) do
    previous[i] = point(p.x, p.y, p.z)
    info[i] = { radius = radii[i] or 0, inverseMass = inverseMasses[i] or 0,
      group = group or "tail", dynamic = true }
  end
  return { id = id, enabled = true, state = { points = points, previousPoints = previous },
    graph = { edges = edges or {} }, pointInfo = info,
    frame = { toWorldPoint = function(p) return point(p.x, p.y, p.z) end,
      toParentVector = function(p) return point(p.x, p.y, p.z) end } }
end

local function run()
  local passed = 0

  local contactGraph = { edges = {
    { from = 1, to = 2, fromLink = 1, restLength = 1, restVector = point(0, -1, 0) },
    { from = 2, to = 3, fromLink = 2, restLength = 1, restVector = point(0, -1, 0) },
  } }
  local contactPoints = { point(0, 0, 0), point(0, -2, 0), point(1, -2, 0) }
  local contactTargets = { point(0, 0, 0), point(0, -1, 0), point(0, -2, 0) }
  local contactMap = { [2] = true }
  constraints.solveLengths(contactPoints, contactGraph, 12, contactTargets[1], contactMap)
  constraints.solveAngle(contactPoints, contactGraph, function()
    return { joint = { type = "cone", angle = 20, axis = point(0, 1, 0) } }
  end, contactTargets, 1 / 60, contactMap)
  local function segmentLength(a, b)
    return math.sqrt((b.x - a.x)^2 + (b.y - a.y)^2 + (b.z - a.z)^2)
  end
  local firstLength = segmentLength(contactPoints[1], contactPoints[2])
  local secondLength = segmentLength(contactPoints[2], contactPoints[3])
  local targetDirection = point(contactTargets[3].x - contactTargets[2].x,
    contactTargets[3].y - contactTargets[2].y, contactTargets[3].z - contactTargets[2].z)
  local solvedDirection = point(contactPoints[3].x - contactPoints[2].x,
    contactPoints[3].y - contactPoints[2].y, contactPoints[3].z - contactPoints[2].z)
  local dot = targetDirection.x * solvedDirection.x + targetDirection.y * solvedDirection.y
    + targetDirection.z * solvedDirection.z
  local cosine = dot / math.max(0.000001, segmentLength(point(), targetDirection) * segmentLength(point(), solvedDirection))
  local angleDegrees = math.deg(math.acos(math.max(-1, math.min(1, cosine))))
  assert(near(firstLength, 1, 0.02) and near(secondLength, 1, 0.02)
      and angleDegrees <= 20.1 and contactPoints[2].y > -2,
    "contact must not stretch a root-adjacent segment or bypass its joint angle limit")
  passed = passed + 1
  local scheduler = api.new({ fixedStep = 1 / 60, maxSubsteps = 3, maxPoints = 80 })
  local a = component("a", { point() }, { 0 }, { 0 })
  local b = component("b", { point() }, { 0 }, { 0 })
  scheduler:setComponents({ a, b })
  local trace, count = {}, { a = 0, b = 0 }
  local stats = scheduler:step(0.05, nil, {
    integrate = function(item) count[item.id] = count[item.id] + 1; trace[#trace + 1] = "i" .. item.id end,
    contacts = function() trace[#trace + 1] = "c" end,
    resolveLocal = function(item) trace[#trace + 1] = "l" .. item.id end,
  })
  assert(stats.substeps == 3 and count.a == 3 and count.b == 3, "shared fixed-step scheduling")
  assert(trace[1] == "ia" and trace[2] == "ib" and trace[3] == "c" and trace[4] == "la" and trace[5] == "lb",
    "phase order integrates all components before contacts and constraints")
  passed = passed + 1

  local world = api.new({ maxCandidatePairs = 32, contactIterations = 1 })
  local light = component("light", { point(0, 0, 0) }, { 0.5 }, { 1 }, "tail")
  local heavy = component("heavy", { point(0.5, 0, 0) }, { 0.5 }, { 3 }, "ears")
  world:setComponents({ light, heavy })
  local contact = world:resolveDynamicContacts(nil, 1 / 60)
  assert(contact.resolvedContacts == 1, "cross-component points contact")
  assert(near(light.state.points[1].x, -0.125, 0.002) and near(heavy.state.points[1].x, 0.875, 0.002),
    "inverse mass moves both points by weighted amounts")
  passed = passed + 1

  local ccd = api.new({ maxCandidatePairs = 16, contactIterations = 1 })
  local fast = component("fast", { point(1, 0, 0) }, { 0.25 }, { 1 }, "tail")
  local obstacle = component("obstacle", { point(0, 0, 0) }, { 0.25 }, { 0 }, "body")
  fast.state.previousPoints[1] = point(-1, 0, 0)
  ccd:setComponents({ fast, obstacle })
  local swept = ccd:resolveDynamicContacts(nil, 1 / 60)
  assert(swept.resolvedContacts > 0 and fast.state.points[1].x < 0,
    "swept point contact must stop a fast point before it tunnels through a static point")
  passed = passed + 1

  local pointSegment = api.new({ maxCandidatePairs = 32, contactIterations = 1 })
  local particle = component("particle", { point(0, 0, 0) }, { 0.4 }, { 1 }, "tail")
  local bar = component("bar", { point(-1, 0.5, 0), point(1, 0.5, 0) }, { 0.2, 0.2 }, { 1, 1 }, "clothing",
    { { from = 1, to = 2 } })
  pointSegment:setComponents({ particle, bar })
  local segmentContact = pointSegment:resolveDynamicContacts(nil, 1 / 60)
  assert(segmentContact.resolvedContacts > 0 and particle.state.points[1].y < 0,
    "point-segment contact pushes the point away")
  assert(bar.state.points[1].y > 0.5 and bar.state.points[2].y > 0.5,
    "point-segment contact transfers correction to both segment endpoints")
  passed = passed + 1

  local segmentWorld = api.new({ maxCandidatePairs = 64, contactIterations = 1, segmentMode = "segment_segment" })
  local horizontal = component("horizontal", { point(-1, 0, 0), point(1, 0, 0) }, { 0.25, 0.25 }, { 1, 1 }, "tail",
    { { from = 1, to = 2 } })
  local vertical = component("vertical", { point(0, -1, 0.3), point(0, 1, 0.3) }, { 0.25, 0.25 }, { 1, 1 }, "clothing",
    { { from = 1, to = 2 } })
  segmentWorld:setComponents({ horizontal, vertical })
  local segmentSegment = segmentWorld:resolveDynamicContacts(nil, 1 / 60)
  assert(segmentSegment.segmentSegmentPairs > 0 and segmentSegment.resolvedContacts > 0,
    "quality mode broadphase gathers and resolves segment-to-segment contacts")
  assert(horizontal.state.points[1].z < 0 and vertical.state.points[1].z > 0.3,
    "segment-to-segment contact moves both components apart")
  passed = passed + 1

  local segmentCcd = api.new({ maxCandidatePairs = 32, contactIterations = 1 })
  local crossing = component("crossing", { point(0, 1, 0) }, { 0.25 }, { 1 }, "tail")
  local staticBar = component("static_bar", { point(-1, 0, 0), point(1, 0, 0) }, { 0.25, 0.25 }, { 0, 0 }, "body",
    { { from = 1, to = 2 } })
  crossing.state.previousPoints[1] = point(0, -1, 0)
  segmentCcd:setComponents({ crossing, staticBar })
  local segmentSweep = segmentCcd:resolveDynamicContacts(nil, 1 / 60)
  assert(segmentSweep.resolvedContacts > 0 and crossing.state.points[1].y < 0,
    "swept point-segment contact must stop a fast point before it crosses a static segment")
  passed = passed + 1

  local filtered = api.new({ maxCandidatePairs = 32,
    collisionMatrix = { tail = { ears = false }, ears = { tail = false } } })
  local tail = component("tail", { point() }, { 0.5 }, { 1 }, "tail")
  local ears = component("ears", { point(0.5, 0, 0) }, { 0.5 }, { 1 }, "ears")
  filtered:setComponents({ tail, ears })
  assert(filtered:resolveDynamicContacts(nil, 1 / 60).resolvedContacts == 0 and near(tail.state.points[1].x, 0),
    "collision matrix filters a pair")
  passed = passed + 1

  local budgeted = api.new({ maxCandidatePairs = 1, contactIterations = 2 })
  budgeted:setComponents({ component("p1", { point() }, { 1 }, { 1 }),
    component("p2", { point(0.1, 0, 0) }, { 1 }, { 1 }),
    component("p3", { point(0.2, 0, 0) }, { 1 }, { 1 }) })
  local budget = budgeted:resolveDynamicContacts(nil, 1 / 60)
  assert(budget.candidatePairs <= 1 and budget.budgetExceeded, "global pair budget is enforced")
  passed = passed + 1

  local emptyBudget = api.new({ maxCandidatePairs = 0, contactIterations = 1 })
  emptyBudget:setComponents({ component("alone", { point() }, { 0.5 }, { 1 }) })
  local noCandidates = emptyBudget:resolveDynamicContacts(nil, 1 / 60)
  assert(noCandidates.candidatePairs == 0 and not noCandidates.budgetExceeded,
    "a zero pair budget is not reported exhausted when there are no possible contacts")
  emptyBudget:setComponents({ component("left", { point() }, { 0.5 }, { 1 }),
    component("right", { point(0.5, 0, 0) }, { 0.5 }, { 1 }) })
  local skippedContact = emptyBudget:resolveDynamicContacts(nil, 1 / 60)
  assert(skippedContact.budgetExceeded and skippedContact.resolvedContacts == 0,
    "a zero pair budget reports exhaustion when it actually skips a candidate")
  passed = passed + 1

  local noWorldFrame = api.new({ maxCandidatePairs = 8, contactIterations = 1 })
  local noFrameA = component("no_frame_a", { point() }, { 0.5 }, { 1 }, "tail")
  local noFrameB = component("no_frame_b", { point(0.5, 0, 0) }, { 0.5 }, { 1 }, "ears")
  for _, item in ipairs({ noFrameA, noFrameB }) do
    item.frame.frameAvailable = false
    item.frame.toWorldPoint = function() error("must not transform a component without a valid world frame") end
  end
  noWorldFrame:setComponents({ noFrameA, noFrameB })
  local unavailable = noWorldFrame:resolveDynamicContacts(nil, 1 / 60)
  assert(unavailable.frameUnavailableComponents == 2 and unavailable.activePoints == 0
      and unavailable.resolvedContacts == 0,
    "components without a valid world frame must be skipped and diagnosed, not crash the tick")
  passed = passed + 1

  local graph = { pointCount = 2,
    links = { { index = 1, key = "root", depth = 0 } },
    edges = { { from = 1, to = 2, fromLink = 1, restLength = 1,
      restVector = point(0, -1, 0), terminal = true } },
    edgesByLink = { { { from = 1, to = 2, fromLink = 1, restLength = 1,
      restVector = point(0, -1, 0), terminal = true } } } }
  local targets = { point(0, 0, 0), point(0, -1, 0) }
  local state, context = core.prepareWorldStep(nil, graph, targets, {}, {
    gravitySpace = "local", gravity = point(0, 0, 0), gravityFalloff = 0,
    pull = 0, spring = 0, damping = 0, mass = 1, tipMass = 1,
    bendStiffness = 0, maxLinearSpeed = 60,
    joint = { type = "free", axis = point(0, 1, 0), angle = 180, angularSpeed = 720 },
    collision = { enabled = true, avatar = true, world = false, self = false,
      radius = 0.25, iterations = 1, friction = 0, restitution = 0, maxSelfPairs = 16 },
  }, 1 / 60, nil, nil, nil, nil, {
    enabled = true, frameAvailable = true, worldScale = 1, rootOriginWorld = point(0, 0, 0),
    toWorldPoint = function(p) return point(p.x, p.y, p.z) end,
    toParentVector = function(p) return point(p.x, p.y, p.z) end,
    avatarShapes = { { kind = "sphere", center = point(0, 0, 0), radius = 1 } },
  })
  core.advanceWorldSubstep(context, 1 / 60)
  assert(near(state.points[2].y, -1), "deferred substep must integrate without resolving local contacts")
  local localContacts = core.resolveWorldContacts(context, 1 / 60)
  assert(localContacts.contacts > 0, "deferred local contacts resolve after shared world contacts")
  core.finishWorldFrame(context, 1 / 60)
  passed = passed + 1
  return { passed = passed, failed = 0 }
end

return { run = run }
