local core = {}
local constraints = require("physics_bone_constraints")
local collisionSolver = require("physics_bone_collisions")

local FIXED_STEP = 1 / 60
local MAX_SUBSTEPS = 5
local MAX_FRAME_DT = 0.10
local CONSTRAINT_PASSES = 5
local AXIAL_AIR_DRAG_RATIO = 0.12

local function v(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, n) return v(a.x * n, a.y * n, a.z * n) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function length(a) return math.sqrt(dot(a, a)) end
local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function validVector(a) return a and finite(a.x) and finite(a.y) and finite(a.z) end

local function clonePoint(point)
  return v(point and point.x or 0, point and point.y or 0, point and point.z or 0)
end

local function clonePoints(points)
  local result = {}
  for index, point in ipairs(points or {}) do result[index] = clonePoint(point) end
  return result
end

local function identity()
  return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
end

local function multiplyMatrix(a, b)
  local result = { {}, {}, {} }
  for row = 1, 3 do
    for column = 1, 3 do
      result[row][column] = a[row][1] * b[1][column]
        + a[row][2] * b[2][column] + a[row][3] * b[3][column]
    end
  end
  return result
end

local function transposeMatrix(matrix)
  return {
    { matrix[1][1], matrix[2][1], matrix[3][1] },
    { matrix[1][2], matrix[2][2], matrix[3][2] },
    { matrix[1][3], matrix[2][3], matrix[3][3] },
  }
end

local function axisAngleMatrix(rotation)
  local angle = length(rotation)
  if angle < 0.000001 then return identity() end
  local x, y, z = rotation.x / angle, rotation.y / angle, rotation.z / angle
  local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
  return {
    { t * x * x + c, t * x * y - s * z, t * x * z + s * y },
    { t * x * y + s * z, t * y * y + c, t * y * z - s * x },
    { t * x * z - s * y, t * y * z + s * x, t * z * z + c },
  }
end

local function eulerMatrix(rotation)
  local sx, cx = math.sin(rotation.x), math.cos(rotation.x)
  local sy, cy = math.sin(rotation.y), math.cos(rotation.y)
  local sz, cz = math.sin(rotation.z), math.cos(rotation.z)
  return {
    { cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx },
    { sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx },
    { -sy, cy * sx, cy * cx },
  }
end

local function atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  if x > 0 then return math.atan(y / x) end
  if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
  if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
  if x == 0 and y > 0 then return math.pi / 2 end
  if x == 0 and y < 0 then return -math.pi / 2 end
  return 0
end

local function matrixEuler(matrix)
  local pitch = math.asin(math.max(-1, math.min(1, -matrix[3][1])))
  local roll, yaw
  if math.abs(math.cos(pitch)) > 0.000001 then
    roll = atan2(matrix[3][2], matrix[3][3])
    yaw = atan2(matrix[2][1], matrix[1][1])
  else
    roll = atan2(-matrix[2][3], matrix[2][2])
    yaw = 0
  end
  return v(roll, pitch, yaw)
end

local function wrapAngle(angle)
  return (angle + math.pi) % (math.pi * 2) - math.pi
end

local function matrixAxisAngle(matrix)
  local cosine = math.max(-1, math.min(1,
    (matrix[1][1] + matrix[2][2] + matrix[3][3] - 1) * 0.5))
  local angle = math.acos(cosine)
  if angle < 0.000001 then
    return v((matrix[3][2] - matrix[2][3]) * 0.5,
      (matrix[1][3] - matrix[3][1]) * 0.5,
      (matrix[2][1] - matrix[1][2]) * 0.5)
  end
  local sine = math.sin(angle)
  if math.abs(sine) > 0.000001 then
    local scale = angle / (2 * sine)
    return v((matrix[3][2] - matrix[2][3]) * scale,
      (matrix[1][3] - matrix[3][1]) * scale,
      (matrix[2][1] - matrix[1][2]) * scale)
  end
  local x = math.sqrt(math.max(0, (matrix[1][1] + 1) * 0.5))
  local y = math.sqrt(math.max(0, (matrix[2][2] + 1) * 0.5))
  local z = math.sqrt(math.max(0, (matrix[3][3] + 1) * 0.5))
  if x >= y and x >= z and x > 0.000001 then
    y, z = (matrix[1][2] + matrix[2][1]) / (4 * x), (matrix[1][3] + matrix[3][1]) / (4 * x)
  elseif y >= z and y > 0.000001 then
    x, z = (matrix[1][2] + matrix[2][1]) / (4 * y), (matrix[2][3] + matrix[3][2]) / (4 * y)
  elseif z > 0.000001 then
    x, y = (matrix[1][3] + matrix[3][1]) / (4 * z), (matrix[2][3] + matrix[3][2]) / (4 * z)
  else
    return v(0, angle, 0)
  end
  local axis = v(x, y, z)
  return mul(axis, angle / math.max(length(axis), 0.000001))
end

local function transform(matrix, point)
  if type(matrix) ~= "table" then return clonePoint(point) end
  return v(
    (matrix[1][1] or 0) * point.x + (matrix[1][2] or 0) * point.y + (matrix[1][3] or 0) * point.z,
    (matrix[2][1] or 0) * point.x + (matrix[2][2] or 0) * point.y + (matrix[2][3] or 0) * point.z,
    (matrix[3][1] or 0) * point.x + (matrix[3][2] or 0) * point.y + (matrix[3][3] or 0) * point.z)
end

local function copyOffsetList(offsets)
  local result = {}
  for index, offset in ipairs(offsets or {}) do result[index] = clonePoint(offset) end
  return result
end

local function zeroOffsets(count)
  local result = {}
  for index = 1, count do result[index] = v(0, 0, 0) end
  return result
end

local function capMagnitude(vector, maximum)
  local magnitude = length(vector)
  if magnitude <= maximum or magnitude < 0.000001 then return vector end
  return mul(vector, maximum / magnitude)
end

local function quadraticDragVelocity(velocity, dragRate, dt, mass)
  local speed = length(velocity)
  if speed < 0.000001 or dragRate <= 0 then return velocity end
  -- Implicit integration of dv/dt = -k|v|v stays stable at high speeds and
  -- preserves the continuous response of the drag control instead of clipping it.
  return mul(velocity, 1 / (1 + dragRate * speed * dt / mass))
end

local function settingsFor(componentSettings, linkOverrides, linkKey)
  local result = componentSettings or {}
  local override = linkOverrides and linkOverrides[linkKey]
  if type(override) ~= "table" then return result end
  local merged = {}
  for key, value in pairs(result) do merged[key] = value end
  for key, value in pairs(override) do
    if type(value) == "table" and type(result[key]) == "table" then
      local child = {}
      for childKey, childValue in pairs(result[key]) do child[childKey] = childValue end
      for childKey, childValue in pairs(value) do child[childKey] = childValue end
      merged[key] = child
    else merged[key] = value end
  end
  return merged
end

local function newOffsets(count)
  local result = {}
  for index = 1, count do result[index] = v(0, 0, 0) end
  return result
end

function core.newComponentState(graph, animatedPoints)
  local count = math.max(0, tonumber(graph and graph.pointCount) or #(animatedPoints or {}))
  local points = clonePoints(animatedPoints)
  for index = #points + 1, count do points[index] = v(0, 0, 0) end
  return {
    points = points,
    previousPoints = clonePoints(points),
    renderPreviousOffsets = newOffsets(#(graph and graph.links or {})),
    offsets = newOffsets(#(graph and graph.links or {})),
    gravityReferenceByLink = {},
    accumulator = 0,
    initialized = true,
    diagnostics = {},
  }
end

local function stateMatches(state, graph, targets)
  return type(state) == "table" and type(state.points) == "table"
    and #state.points == (graph.pointCount or #targets)
    and #(state.offsets or {}) == #(graph.links or {})
end

local function preservingConstraintSolve(state, graph, targets, settingsForLink, dt, bendDt, contactPoints)
  local before = clonePoints(state.points)
  local lengthPasses = CONSTRAINT_PASSES
  if type(contactPoints) == "table" and next(contactPoints) ~= nil then
    lengthPasses = math.min(12, CONSTRAINT_PASSES * 2)
  end
  constraints.solveLengths(state.points, graph, lengthPasses, targets[1], contactPoints)
  constraints.solveBend(state.points, graph, settingsForLink, targets, bendDt or dt, contactPoints)
  -- Bend preservation changes child directions. Apply angle/hinge limits last
  -- so bend stiffness cannot push a segment back outside its configured joint.
  -- Contacts may skip bend smoothing, but they do not pin articulated points or
  -- exempt lengths/joints; otherwise a root-adjacent contact stretches the bone.
  constraints.solveAngle(state.points, graph, settingsForLink, targets, dt, contactPoints)
  for index, point in ipairs(state.points) do
    local old = before[index]
    local prior = state.previousPoints[index]
    if old and prior then
      local correction = sub(point, old)
      state.previousPoints[index] = add(prior, correction)
    end
  end
end

local function emptyCollisionStats()
  return { contacts = 0, worldQueries = 0, selfPairs = 0, selfBudgetExceeded = false,
    budgetExceeded = false, worldUnavailable = false, contactPoints = {} }
end

local function mergeCollisionStats(target, source)
  source = source or {}
  target.contacts = target.contacts + (tonumber(source.contacts) or 0)
  target.worldQueries = math.max(target.worldQueries, tonumber(source.worldQueries) or 0)
  target.selfPairs = target.selfPairs + (tonumber(source.selfPairs) or 0)
  target.selfBudgetExceeded = target.selfBudgetExceeded or source.selfBudgetExceeded == true
  target.budgetExceeded = target.budgetExceeded or source.budgetExceeded == true
  target.worldUnavailable = target.worldUnavailable or source.worldUnavailable == true
  for pointIndex in pairs(source.contactPoints or {}) do target.contactPoints[pointIndex] = true end
  return target
end

local function mergeContactPoints(target, source)
  for pointIndex in pairs(source or {}) do target[pointIndex] = true end
  return target
end

local function resolveLocalContacts(state, context, dt, extraContactPoints)
  local stats = emptyCollisionStats()
  mergeContactPoints(stats.contactPoints, extraContactPoints)
  local collisionContext = context.collisionContext
  if not collisionContext or not collisionContext.enabled then
    state.collisionDiagnostics = stats
    return stats
  end
  local rootCollision = context.effectiveSettings[1] and context.effectiveSettings[1].collision or {}
  local iterations = math.max(1, math.min(4, math.floor(tonumber(rootCollision.iterations) or 2)))
  local bendDt = dt / (iterations + 1)
  for iteration = 1, iterations do
    local pass = collisionSolver.resolveState(state, context.graph, collisionContext,
      context.effectiveSettings, context.pointOwners, dt, iteration == 1)
    mergeCollisionStats(stats, pass)
    preservingConstraintSolve(state, context.graph, context.targets,
      function(index) return context.constraintSettings[index] end, dt, bendDt, stats.contactPoints)
  end
  -- Keep length/angle constraints last so contact projection cannot stretch links.
  state.collisionDiagnostics = stats
  return stats
end

local function simulateStep(state, graph, targets, input, effectiveSettings, gravityByLink, pointOwners,
    tipMassByLink, dt, collisionContext, deferContacts, stepContext)
  local rootTarget = targets[1] or v(0, 0, 0)
  local rootAcceleration = input and input.rootAcceleration or v(0, 0, 0)
  if not validVector(rootAcceleration) then rootAcceleration = v(0, 0, 0) end
  local rootVelocity = input and input.rootVelocity or v(0, 0, 0)
  if not validVector(rootVelocity) then rootVelocity = v(0, 0, 0) end
  local angularAcceleration = tonumber(input and input.rootYawAcceleration) or 0
  if not finite(angularAcceleration) then angularAcceleration = 0 end
  local alpha = validVector(input and input.rootAngularAcceleration)
    and clonePoint(input.rootAngularAcceleration) or v(0, angularAcceleration, 0)
  local angularVelocity = validVector(input and input.rootAngularVelocity)
    and clonePoint(input.rootAngularVelocity) or v(0, 0, 0)
  for pointIndex = 2, #state.points do
    local target = targets[pointIndex] or state.points[pointIndex]
    local current = state.points[pointIndex]
    local previous = state.previousPoints[pointIndex]
    if validVector(target) and validVector(current) and validVector(previous) then
      local ownerIndex = pointOwners[pointIndex] or pointIndex
      local setting = effectiveSettings[ownerIndex] or effectiveSettings[1] or {}
      local gravity = gravityByLink[ownerIndex] or v(0, -9.81, 0)
      local tipMass = math.max(1, tonumber(tipMassByLink and tipMassByLink[ownerIndex]) or 1)
      local falloff = math.max(0, math.min(1, tonumber(setting.gravityFalloff) or 0))
      local mass = math.max(0.05, tonumber(setting.mass) or 1)
      local effectiveMass = mass * tipMass
      local pull = math.max(0, tonumber(setting.pull) or 0) / effectiveMass
      local spring = math.max(0, math.min(1, tonumber(setting.spring) or 0))
      local damping = math.max(0, tonumber(setting.damping) or 0) / math.sqrt(effectiveMass)
      local offset = sub(current, target)
      local gravityScale = 1 - falloff * math.exp(-length(offset) * 2.0)
      local acceleration = add(mul(gravity, gravityScale), mul(sub(target, current), pull))
      -- Fictitious acceleration from the moving avatar frame is independent of
      -- mass. Tip mass increases lag by weakening pose-follow and drag below,
      -- not by multiplying the external acceleration itself.
      acceleration = sub(acceleration, mul(rootAcceleration,
        (tonumber(setting.rootMotionResponse) or 0)))
      local relative = sub(current, rootTarget)
      local angularResponse = tonumber(setting.avatarMotionResponse) or 0
      -- Coriolis inertia is required when a link already moves relative to an
      -- animated rotating parent. Verlet position deltas are expressed in the
      -- parent frame, so convert that delta to velocity before applying it.
      local relativeVelocity = mul(sub(current, previous), 1 / math.max(dt, 0.000001))
      local angularAccelerationInertia = mul(cross(alpha, relative), -angularResponse)
      local centripetalInertia = mul(cross(angularVelocity, cross(angularVelocity, relative)), -angularResponse)
      local coriolisInertia = mul(cross(angularVelocity, relativeVelocity), -2 * angularResponse)
      local angularInertia = add(add(angularAccelerationInertia, centripetalInertia), coriolisInertia)
      acceleration = add(acceleration, angularInertia)
      local dragRate = math.max(0, tonumber(setting.motionDrag) or 0)
      local velocity = mul(sub(current, previous), math.exp(-damping * dt))
      local maxSpeed = math.max(0, tonumber(setting.maxLinearSpeed) or 24)
      velocity = capMagnitude(velocity, maxSpeed * dt)
      local nextVelocity = add(mul(velocity, 1 / math.max(dt, 0.000001)), mul(acceleration, dt))
      if dragRate > 0 then
        -- Resist motion through the stationary environment. Avatar translation
        -- and rotation are added to the point's local velocity before drag, so
        -- each link trails when its animated root moves without any wind force.
        local airRelativeVelocity = add(add(nextVelocity, rootVelocity), cross(angularVelocity, relative))
        local parentPointIndex = pointIndex - 1
        local link = graph.links and graph.links[ownerIndex]
        if pointIndex <= #(graph.links or {}) and link and tonumber(link.parentIndex) then
          parentPointIndex = tonumber(link.parentIndex)
        end
        local linkDirection = parentPointIndex >= 1 and sub(current, state.points[parentPointIndex]) or v(0, 0, 0)
        local linkLength = length(linkDirection)
        if linkLength > 0.000001 then
          local tangent = mul(linkDirection, 1 / linkLength)
          local axialVelocity = mul(tangent, dot(airRelativeVelocity, tangent))
          local transverseVelocity = sub(airRelativeVelocity, axialVelocity)
          local dampedTransverse = quadraticDragVelocity(transverseVelocity, dragRate, dt, mass * tipMass)
          local dampedAxial = quadraticDragVelocity(axialVelocity, dragRate * AXIAL_AIR_DRAG_RATIO, dt, mass * tipMass)
          nextVelocity = add(nextVelocity, sub(add(dampedTransverse, dampedAxial), airRelativeVelocity))
        else
          local dampedVelocity = quadraticDragVelocity(airRelativeVelocity, dragRate, dt, mass * tipMass)
          nextVelocity = add(nextVelocity, sub(dampedVelocity, airRelativeVelocity))
        end
      end
      if spring > 0 then
        -- `spring` is the velocity returned when a point crosses its current
        -- animation target. Pull controls how strongly it returns; damping
        -- controls how quickly existing velocity fades. These controls no
        -- longer alter one another.
        local nextPoint = add(current, mul(nextVelocity, dt))
        local nextOffset = sub(nextPoint, target)
        local offsetLength = length(offset)
        if offsetLength > 0.000001 and dot(offset, nextOffset) < 0 then
          local outward = mul(offset, 1 / offsetLength)
          local inwardSpeed = dot(nextVelocity, outward)
          if inwardSpeed < 0 then
            nextVelocity = sub(nextVelocity, mul(outward, (1 + spring) * inwardSpeed))
          end
        end
      end
      state.previousPoints[pointIndex] = clonePoint(current)
      state.points[pointIndex] = add(current, mul(nextVelocity, dt))
      if not validVector(state.points[pointIndex]) then
        state.points[pointIndex], state.previousPoints[pointIndex] = clonePoint(target), clonePoint(target)
      end
    end
  end
  state.points[1], state.previousPoints[1] = clonePoint(rootTarget), clonePoint(rootTarget)

  local function effective(index) return effectiveSettings[index] end
  preservingConstraintSolve(state, graph, targets, effective, dt)
  if deferContacts then
    state.collisionDiagnostics = { contacts = 0, worldQueries = 0, selfPairs = 0,
      selfBudgetExceeded = false, budgetExceeded = false, worldUnavailable = false, deferred = true }
  elseif collisionContext and collisionContext.enabled then
    if stepContext then resolveLocalContacts(state, stepContext, dt) end
  else
    state.collisionDiagnostics = emptyCollisionStats()
  end
  state.points[1], state.previousPoints[1] = clonePoint(rootTarget), clonePoint(rootTarget)
end

local function averageEdgeDirection(points, graph, linkIndex)
  local sum = v(0, 0, 0)
  local count = 0
  for _, edge in ipairs((graph.edgesByLink and graph.edgesByLink[linkIndex]) or {}) do
      local delta = sub(points[edge.to], points[edge.from])
      local magnitude = length(delta)
      if magnitude > 0.000001 then sum = add(sum, mul(delta, 1 / magnitude)); count = count + 1 end
  end
  if count == 0 then return nil end
  return v(sum.x / count, sum.y / count, sum.z / count)
end

local function inverseRotate(matrix, vector)
  if type(matrix) ~= "table" then return clonePoint(vector) end
  return v(
    matrix[1][1] * vector.x + matrix[2][1] * vector.y + matrix[3][1] * vector.z,
    matrix[1][2] * vector.x + matrix[2][2] * vector.y + matrix[3][2] * vector.z,
    matrix[1][3] * vector.x + matrix[2][3] * vector.y + matrix[3][3] * vector.z)
end

local function capOffsetChange(current, previous, maximum)
  local delta = sub(current, previous)
  local distance = length(delta)
  if distance <= maximum or distance < 0.000001 then return current end
  return add(previous, mul(delta, maximum / distance))
end

local function computeOffsets(state, graph, targets, linkFrames, jointFrames, dt, effectiveSettings)
  local offsets, diagnostics, solvedFrames = {}, {}, {}
  for linkIndex, link in ipairs(graph.links or {}) do
    local animatedDirection = averageEdgeDirection(targets, graph, linkIndex)
    local solvedDirection = averageEdgeDirection(state.points, graph, linkIndex)
    local animatedParentFrame = linkFrames and linkFrames[linkIndex] or identity()
    local actualParentFrame = link.parentIndex and solvedFrames[link.parentIndex] or animatedParentFrame
    local parentMotion = multiplyMatrix(actualParentFrame, transposeMatrix(animatedParentFrame))
    local animatedPartFrame = jointFrames and jointFrames[linkIndex] or animatedParentFrame
    local animatedLocalFrame = multiplyMatrix(transposeMatrix(animatedParentFrame), animatedPartFrame)
    local animatedLocalEuler = matrixEuler(animatedLocalFrame)
    local offset = v(0, 0, 0)
    if animatedDirection and solvedDirection then
      -- Child targets already include their animated ancestors. Carry that
      -- target through each solved parent bend before computing this joint's
      -- own correction; otherwise every child reapplies the parent's full
      -- world-space bend as another local rotation and the chain corkscrews.
      local carriedDirection = transform(parentMotion, animatedDirection)
      local worldAxisAngle = constraints.directionRotation(carriedDirection, solvedDirection)
      local actualBasePartFrame = multiplyMatrix(parentMotion, animatedPartFrame)
      local desiredPartFrame = multiplyMatrix(axisAngleMatrix(worldAxisAngle), actualBasePartFrame)
      local desiredLocalFrame = multiplyMatrix(transposeMatrix(actualParentFrame), desiredPartFrame)
      local desiredLocalEuler = matrixEuler(desiredLocalFrame)
      offset = matrixAxisAngle(eulerMatrix(v(
        wrapAngle(desiredLocalEuler.x - animatedLocalEuler.x),
        wrapAngle(desiredLocalEuler.y - animatedLocalEuler.y),
        wrapAngle(desiredLocalEuler.z - animatedLocalEuler.z))))
    end
    local setting = effectiveSettings[linkIndex] or effectiveSettings[1] or {}
    local maximum = math.rad(math.max(0, tonumber(setting.joint and setting.joint.angularSpeed) or 180)) * dt
    offset = capOffsetChange(offset, state.offsets[linkIndex] or v(0, 0, 0), maximum)
    offsets[linkIndex] = offset
    local appliedEuler = matrixEuler(axisAngleMatrix(offset))
    solvedFrames[linkIndex] = multiplyMatrix(actualParentFrame,
      eulerMatrix(add(animatedLocalEuler, appliedEuler)))
    diagnostics[linkIndex] = {
      offsetRadians = length(offset),
      angleDegrees = math.deg(length(offset)),
      speedDegrees = dt > 0 and math.deg(length(sub(offset, state.offsets[linkIndex] or v(0, 0, 0))) / dt) or 0,
    }
  end
  return offsets, diagnostics
end

function core.prepareWorldStep(state, graph, animatedPoints, input, settings, dt, gravityFrame,
    linkFrames, linkOverrides, jointFrames, collisionContext, restPose)
  settings = settings or {}
  local safeDt = tonumber(dt)
  if not finite(safeDt) or safeDt <= 0 then safeDt = 1 / 20 end
  safeDt = math.min(MAX_FRAME_DT, safeDt)
  if not stateMatches(state, graph, animatedPoints) then state = core.newComponentState(graph, animatedPoints) end
  state.renderPreviousOffsets = copyOffsetList(state.offsets)
  local frame = gravityFrame or identity()
  local effectiveSettings, constraintSettings, gravityByLink, pointOwners, tipMassByLink = {}, {}, {}, {}, {}
  state.gravityReferenceByLink = state.gravityReferenceByLink or {}
  local maximumDepth = 0
  for index, link in ipairs(graph.links or {}) do
    maximumDepth = math.max(maximumDepth, tonumber(link.depth) or (index - 1))
  end
  local hasEnabledCollision = false
  for index, link in ipairs(graph.links or {}) do
    local setting = settingsFor(settings, linkOverrides, link.key)
    effectiveSettings[index] = setting
    local depth = math.max(0, tonumber(link.depth) or (index - 1))
    local progress = maximumDepth > 0 and math.max(0, math.min(1, depth / maximumDepth)) or 0
    local tipMultiplier = math.max(1, math.min(6, tonumber(setting.tipMass) or 1))
    local tipMass = 1 + (tipMultiplier - 1) * progress
    tipMassByLink[index] = tipMass
    if setting.collision and setting.collision.enabled == true then hasEnabledCollision = true end
    local constraintSetting = {}
    for key, value in pairs(setting) do constraintSetting[key] = value end
    constraintSetting.joint = {}
    for key, value in pairs(setting.joint or {}) do constraintSetting.joint[key] = value end
    constraintSetting.bendStiffness = (tonumber(setting.bendStiffness) or 0) / tipMass
    constraintSetting.joint.axis = transform((jointFrames and jointFrames[index]) or identity(),
      setting.joint and setting.joint.axis or v(0, 1, 0))
    constraintSettings[index] = constraintSetting
    local rawGravity = setting.gravity or { x = 0, y = -9.81, z = 0 }
    local gravitySpace = setting.gravitySpace == "local" and "local" or "world"
    local gravity = gravitySpace == "local"
      and v(rawGravity.x or 0, rawGravity.y or 0, rawGravity.z or 0)
      or transform(frame, rawGravity)
    local sourceMagnitude = length(rawGravity)
    if sourceMagnitude > 0.000001 then
      local sourceDirection = mul(rawGravity, 1 / sourceMagnitude)
      local reference = state.gravityReferenceByLink[index]
      if not reference or reference.space ~= gravitySpace
        or not reference.sourceDirection
        or length(sub(reference.sourceDirection, sourceDirection)) > 0.0001 then
        local gravityMagnitude = length(gravity)
        state.gravityReferenceByLink[index] = {
          direction = gravityMagnitude > 0.000001 and mul(gravity, 1 / gravityMagnitude) or nil,
          sourceDirection = sourceDirection,
          space = gravitySpace,
        }
        reference = state.gravityReferenceByLink[index]
      end
      local tiltResponse = gravitySpace == "world"
        and math.max(0, math.min(1, tonumber(setting.gravityTiltResponse) or 0)) or 0
      if tiltResponse > 0 and reference.direction then
        -- Balance the constant force at the component's initial pose. Only a
        -- change in world gravity relative to that pose can then deflect the
        -- chain. Clamp the differential force to one base gravity.
        local referenceGravity = mul(reference.direction, length(gravity))
        local dynamicGravity = sub(gravity, referenceGravity)
        dynamicGravity = capMagnitude(dynamicGravity, length(gravity))
        gravity = add(mul(gravity, 1 - tiltResponse), mul(dynamicGravity, tiltResponse))
      end
    end
    gravityByLink[index] = validVector(gravity) and gravity or v(0, -9.81, 0)
    pointOwners[index] = index
  end
  for _, edge in ipairs(graph.edges or {}) do
    if edge.terminal then pointOwners[edge.to] = edge.fromLink end
  end
  restPose = type(restPose) == "table" and restPose or settings.restPose
  local targets = clonePoints(animatedPoints)
  local restPoseAvailable = type(restPose) == "table" and #restPose == #targets
  for pointIndex = 2, #targets do
    local owner = pointOwners[pointIndex] or pointIndex
    local setting = effectiveSettings[owner] or effectiveSettings[1] or {}
    local mode = setting.animationTargetMode
    local rest = restPoseAvailable and restPose[pointIndex] or nil
    if validVector(rest) then
      if mode == "rest" then
        targets[pointIndex] = clonePoint(rest)
      elseif mode == "hybrid" then
        local influence = math.max(0, math.min(1, tonumber(setting.animationInfluence) or 1))
        targets[pointIndex] = add(rest, mul(sub(animatedPoints[pointIndex], rest), influence))
      end
    end
  end
  if collisionContext then collisionContext.enabled = hasEnabledCollision and collisionContext.frameAvailable == true end
  local context = {
    state = state, graph = graph, targets = targets, animatedTargets = animatedPoints,
    restPose = restPose, restPoseAvailable = restPoseAvailable, input = input,
    settings = settings, linkFrames = linkFrames, jointFrames = jointFrames,
    collisionContext = collisionContext, effectiveSettings = effectiveSettings,
    constraintSettings = constraintSettings, gravityByLink = gravityByLink,
    pointOwners = pointOwners, tipMassByLink = tipMassByLink,
    hasEnabledCollision = hasEnabledCollision, safeDt = safeDt,
    frameCollisionDiagnostics = emptyCollisionStats(),
  }
  return state, context
end

function core.advanceWorldSubstep(context, dt)
  if type(context) ~= "table" or type(context.state) ~= "table" then return nil end
  dt = tonumber(dt)
  if not finite(dt) or dt <= 0 then dt = FIXED_STEP end
  simulateStep(context.state, context.graph, context.targets, context.input,
    context.constraintSettings, context.gravityByLink, context.pointOwners,
    context.tipMassByLink, dt, context.collisionContext, true, context)
  context.substeps = (context.substeps or 0) + 1
  return context.state
end

function core.resolveWorldContacts(context, dt, contactPoints)
  if type(context) ~= "table" or type(context.state) ~= "table" then return emptyCollisionStats() end
  dt = tonumber(dt)
  if not finite(dt) or dt <= 0 then dt = FIXED_STEP end
  local stats
  if context.collisionContext and context.collisionContext.enabled then
    stats = resolveLocalContacts(context.state, context, dt, contactPoints)
  else
    stats = emptyCollisionStats()
    preservingConstraintSolve(context.state, context.graph, context.targets,
      function(index) return context.constraintSettings[index] end, dt, dt, contactPoints)
    context.state.collisionDiagnostics = stats
  end
  local frame = context.frameCollisionDiagnostics
  frame.contacts = frame.contacts + stats.contacts
  frame.worldQueries = frame.worldQueries + stats.worldQueries
  frame.selfPairs = frame.selfPairs + stats.selfPairs
  frame.selfBudgetExceeded = frame.selfBudgetExceeded or stats.selfBudgetExceeded
  frame.budgetExceeded = frame.budgetExceeded or stats.budgetExceeded
  frame.worldUnavailable = frame.worldUnavailable or stats.worldUnavailable
  return stats
end

function core.finishWorldFrame(context, dt)
  if type(context) ~= "table" or type(context.state) ~= "table" then return nil, {}, {} end
  local safeDt = tonumber(dt) or context.safeDt or 1 / 20
  local state = context.state
  local offsets, diagnostics = computeOffsets(state, context.graph, context.targets,
    context.linkFrames, context.jointFrames, safeDt, context.effectiveSettings)
  for index, diagnostic in ipairs(diagnostics or {}) do
    diagnostic.gravityInParent = clonePoint(context.gravityByLink[index] or v(0, -9.81, 0))
  end
  state.offsets, state.diagnostics = offsets, diagnostics
  local frameStats = context.frameCollisionDiagnostics or emptyCollisionStats()
  frameStats.frameUnavailable = context.hasEnabledCollision
    and context.collisionContext ~= nil and context.collisionContext.frameAvailable ~= true or false
  state.collisionDiagnostics = frameStats
  return state, offsets, diagnostics
end

function core.worldPointInfo(context)
  local result = {}
  if type(context) ~= "table" or type(context.state) ~= "table" then return result end
  for pointIndex = 1, #context.state.points do
    local owner = context.pointOwners[pointIndex] or (pointIndex == 1 and 1 or nil)
    local setting = owner and (context.effectiveSettings[owner] or context.effectiveSettings[1]) or nil
    local collision = setting and setting.collision or {}
    local mass = math.max(0.05, tonumber(setting and setting.mass) or 1)
    local tipMass = math.max(1, tonumber(context.tipMassByLink[owner or 1]) or 1)
    local enabled = collision.enabled == true and collision.dynamic ~= false
    local radius = enabled and math.max(0, tonumber(collision.radius) or 0) or 0
    result[pointIndex] = {
      radius = radius,
      inverseMass = pointIndex == 1 and 0 or 1 / (mass * tipMass),
      group = collision.group or "custom",
      mask = collision.mask,
      friction = collision.friction,
      restitution = collision.restitution,
      dynamic = radius > 0,
    }
  end
  return result
end

function core.step(state, graph, animatedPoints, input, settings, dt, gravityFrame, linkFrames, linkOverrides, jointFrames, collisionContext)
  local safeDt = tonumber(dt)
  if not finite(safeDt) or safeDt <= 0 then safeDt = 1 / 20 end
  safeDt = math.min(MAX_FRAME_DT, safeDt)
  local context
  state, context = core.prepareWorldStep(state, graph, animatedPoints, input, settings, safeDt,
    gravityFrame, linkFrames, linkOverrides, jointFrames, collisionContext)
  state.accumulator = math.min((state.accumulator or 0) + safeDt, FIXED_STEP * MAX_SUBSTEPS)
  local steps = 0
  while state.accumulator >= FIXED_STEP and steps < MAX_SUBSTEPS do
    simulateStep(state, graph, animatedPoints, input, context.constraintSettings,
      context.gravityByLink, context.pointOwners, context.tipMassByLink,
      FIXED_STEP, context.collisionContext, false, context)
    local stepStats = state.collisionDiagnostics or {}
    context.frameCollisionDiagnostics.contacts = context.frameCollisionDiagnostics.contacts + (tonumber(stepStats.contacts) or 0)
    context.frameCollisionDiagnostics.worldQueries = context.frameCollisionDiagnostics.worldQueries + (tonumber(stepStats.worldQueries) or 0)
    context.frameCollisionDiagnostics.selfPairs = context.frameCollisionDiagnostics.selfPairs + (tonumber(stepStats.selfPairs) or 0)
    context.frameCollisionDiagnostics.selfBudgetExceeded = context.frameCollisionDiagnostics.selfBudgetExceeded or stepStats.selfBudgetExceeded == true
    context.frameCollisionDiagnostics.budgetExceeded = context.frameCollisionDiagnostics.budgetExceeded or stepStats.budgetExceeded == true
    context.frameCollisionDiagnostics.worldUnavailable = context.frameCollisionDiagnostics.worldUnavailable or stepStats.worldUnavailable == true
    state.accumulator = state.accumulator - FIXED_STEP
    steps = steps + 1
  end
  return core.finishWorldFrame(context, safeDt)
end

function core.interpolate(state, alpha)
  local blend = math.max(0, math.min(1, tonumber(alpha) or 1))
  local result = {}
  for index, current in ipairs(state and state.offsets or {}) do
    local previous = state.renderPreviousOffsets and state.renderPreviousOffsets[index] or current
    result[index] = v(
      previous.x + (current.x - previous.x) * blend,
      previous.y + (current.y - previous.y) * blend,
      previous.z + (current.z - previous.z) * blend)
  end
  return result
end

return core
