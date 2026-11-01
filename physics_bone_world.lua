-- Shared scheduler and cross-component particle contacts for PhysBone v2.
-- Components keep their own chain state. This module coordinates the fixed step
-- and resolves contacts in a common world frame.
local worldApi = {}

local DEFAULTS = {
  fixedStep = 1 / 60,
  maxSubsteps = 3,
  maxFrameDt = 0.10,
  maxPoints = 80,
  maxCandidatePairs = 512,
  contactIterations = 2,
  cellSize = 1,
  maxCellsPerProxy = 256,
}

local PERFORMANCE = {
  performance = { fixedStep = 1 / 30, maxSubsteps = 2, maxFrameDt = 0.10, maxPoints = 64,
    maxCandidatePairs = 192, contactIterations = 1, cellSize = 1, maxCellsPerProxy = 128,
    maxBlockQueries = 32, segmentMode = "point_segment" },
  balanced = { fixedStep = 1 / 60, maxSubsteps = 3, maxFrameDt = 0.10, maxPoints = 80,
    maxCandidatePairs = 512, contactIterations = 2, cellSize = 1, maxCellsPerProxy = 256,
    maxBlockQueries = 64, segmentMode = "point_segment" },
  quality = { fixedStep = 1 / 60, maxSubsteps = 3, maxFrameDt = 0.10, maxPoints = 128,
    maxCandidatePairs = 1024, contactIterations = 4, cellSize = 0.75, maxCellsPerProxy = 512,
    maxBlockQueries = 96, segmentMode = "segment_segment" },
}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, minimum, maximum, fallback)
  value = tonumber(value)
  if not finite(value) then value = fallback end
  return math.max(minimum, math.min(maximum, value))
end

local function performanceOptions(mode)
  local source = PERFORMANCE[mode] or PERFORMANCE.balanced
  local result = {}
  for key, value in pairs(source) do result[key] = value end
  result.performance = PERFORMANCE[mode] and mode or "balanced"
  return result
end

local function vec(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function add(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, amount) return vec(a.x * amount, a.y * amount, a.z * amount) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function length(a) return math.sqrt(math.max(0, dot(a, a))) end
local function normalize(a, fallback)
  local size = length(a)
  if size > 0.000001 then return mul(a, 1 / size) end
  return fallback or vec(1, 0, 0)
end

local function sweptPointAabb(proxy, radius, cellSize)
  local start, finish = proxy.previousWorld, proxy.world
  return {
    minX = math.floor((math.min(start.x, finish.x) - radius) / cellSize),
    minY = math.floor((math.min(start.y, finish.y) - radius) / cellSize),
    minZ = math.floor((math.min(start.z, finish.z) - radius) / cellSize),
    maxX = math.floor((math.max(start.x, finish.x) + radius) / cellSize),
    maxY = math.floor((math.max(start.y, finish.y) + radius) / cellSize),
    maxZ = math.floor((math.max(start.z, finish.z) + radius) / cellSize),
  }
end

local function sweptSegmentAabb(segment, radius, cellSize)
  local a0, a1 = segment.first.previousWorld, segment.first.world
  local b0, b1 = segment.second.previousWorld, segment.second.world
  return {
    minX = math.floor((math.min(a0.x, a1.x, b0.x, b1.x) - radius) / cellSize),
    minY = math.floor((math.min(a0.y, a1.y, b0.y, b1.y) - radius) / cellSize),
    minZ = math.floor((math.min(a0.z, a1.z, b0.z, b1.z) - radius) / cellSize),
    maxX = math.floor((math.max(a0.x, a1.x, b0.x, b1.x) + radius) / cellSize),
    maxY = math.floor((math.max(a0.y, a1.y, b0.y, b1.y) + radius) / cellSize),
    maxZ = math.floor((math.max(a0.z, a1.z, b0.z, b1.z) + radius) / cellSize),
  }
end

local function boundsOverlap(a, b)
  return a.minX <= b.maxX and a.maxX >= b.minX
    and a.minY <= b.maxY and a.maxY >= b.minY
    and a.minZ <= b.maxZ and a.maxZ >= b.minZ
end

local function sweptPointBounds(proxy, radius)
  local start, finish = proxy.previousWorld, proxy.world
  return { minX = math.min(start.x, finish.x) - radius,
    minY = math.min(start.y, finish.y) - radius, minZ = math.min(start.z, finish.z) - radius,
    maxX = math.max(start.x, finish.x) + radius,
    maxY = math.max(start.y, finish.y) + radius, maxZ = math.max(start.z, finish.z) + radius }
end

local function sweptSegmentBounds(segment, radius)
  local a0, a1 = segment.first.previousWorld, segment.first.world
  local b0, b1 = segment.second.previousWorld, segment.second.world
  return { minX = math.min(a0.x, a1.x, b0.x, b1.x) - radius,
    minY = math.min(a0.y, a1.y, b0.y, b1.y) - radius,
    minZ = math.min(a0.z, a1.z, b0.z, b1.z) - radius,
    maxX = math.max(a0.x, a1.x, b0.x, b1.x) + radius,
    maxY = math.max(a0.y, a1.y, b0.y, b1.y) + radius,
    maxZ = math.max(a0.z, a1.z, b0.z, b1.z) + radius }
end

local function cellKey(x, y, z) return x .. ":" .. y .. ":" .. z end

local function cellsFor(bounds, limit)
  local count = (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) * (bounds.maxZ - bounds.minZ + 1)
  if count > limit then return nil end
  local cells = {}
  for x = bounds.minX, bounds.maxX do
    for y = bounds.minY, bounds.maxY do
      for z = bounds.minZ, bounds.maxZ do cells[#cells + 1] = cellKey(x, y, z) end
    end
  end
  return cells
end

local function gridCellsFor(bounds, limit)
  local count = (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) * (bounds.maxZ - bounds.minZ + 1)
  if count > limit then return nil end
  local cells = {}
  for x = bounds.minX, bounds.maxX do
    for y = bounds.minY, bounds.maxY do
      for z = bounds.minZ, bounds.maxZ do cells[#cells + 1] = cellKey(x, y, z) end
    end
  end
  return cells
end

local function closestOnSegment(point, a, b)
  local axis = sub(b, a)
  local sizeSquared = dot(axis, axis)
  local t = sizeSquared > 0.000001 and math.max(0, math.min(1, dot(sub(point, a), axis) / sizeSquared)) or 0
  return add(a, mul(axis, t)), t
end

local function closestSegments(a0, a1, b0, b1)
  local firstAxis, secondAxis = sub(a1, a0), sub(b1, b0)
  local between = sub(a0, b0)
  local firstLength, secondLength = dot(firstAxis, firstAxis), dot(secondAxis, secondAxis)
  local firstDot, secondDot = dot(firstAxis, between), dot(secondAxis, between)
  local s, t
  if firstLength <= 0.000001 and secondLength <= 0.000001 then
    s, t = 0, 0
  elseif firstLength <= 0.000001 then
    s, t = 0, math.max(0, math.min(1, secondDot / secondLength))
  elseif secondLength <= 0.000001 then
    t, s = 0, math.max(0, math.min(1, -firstDot / firstLength))
  else
    local crossDot = dot(firstAxis, secondAxis)
    local denominator = firstLength * secondLength - crossDot * crossDot
    s = denominator > 0.000001 and math.max(0, math.min(1,
      (crossDot * secondDot - firstDot * secondLength) / denominator)) or 0
    t = (crossDot * s + secondDot) / secondLength
    if t < 0 then
      t = 0
      s = math.max(0, math.min(1, -firstDot / firstLength))
    elseif t > 1 then
      t = 1
      s = math.max(0, math.min(1, (crossDot - firstDot) / firstLength))
    end
  end
  return add(a0, mul(firstAxis, s)), add(b0, mul(secondAxis, t)), s, t
end

local function lerp(a, b, amount)
  return add(a, mul(sub(b, a), amount))
end

local function stableNormal(firstId, secondId)
  local total = 0
  local text = tostring(firstId) .. "|" .. tostring(secondId)
  for index = 1, #text do total = (total * 31 + text:byte(index)) % 3 end
  if total == 0 then return vec(1, 0, 0) end
  if total == 1 then return vec(0, 1, 0) end
  return vec(0, 0, 1)
end

local function maskAllows(mask, group)
  if type(mask) ~= "table" then return true end
  return mask[group] ~= false
end

local function groupsAllow(world, first, second)
  local firstGroup, secondGroup = first.group or "custom", second.group or "custom"
  local matrix = world.collisionMatrix
  local firstRow = type(matrix[firstGroup]) == "table" and matrix[firstGroup] or nil
  local secondRow = type(matrix[secondGroup]) == "table" and matrix[secondGroup] or nil
  if (firstRow and firstRow[secondGroup] == false) or (secondRow and secondRow[firstGroup] == false) then return false end
  if firstRow and firstRow[secondGroup] == true or secondRow and secondRow[firstGroup] == true then return true end
  return maskAllows(first.mask, secondGroup) and maskAllows(second.mask, firstGroup)
end

local function toWorld(frame, value)
  if frame and frame.frameAvailable == false then return nil end
  if frame and type(frame.toWorldPoint) == "function" then
    local result = frame.toWorldPoint(value)
    if type(result) ~= "table" or not finite(result.x) or not finite(result.y) or not finite(result.z) then return nil end
    return result
  end
  return vec(value.x, value.y, value.z)
end

local function toParent(frame, value)
  if frame and type(frame.toParentVector) == "function" then return frame.toParentVector(value) end
  return vec(value.x, value.y, value.z)
end

local function writePoint(proxy, worldPoint, worldPrevious)
  local state, frame = proxy.component.state, proxy.component.frame
  local current = toParent(frame, worldPoint)
  local previous = toParent(frame, worldPrevious)
  local root = frame and frame.rootOriginWorld
  if root then
    current = sub(current, toParent(frame, root))
    previous = sub(previous, toParent(frame, root))
  end
  state.points[proxy.index] = current
  state.previousPoints[proxy.index] = previous
  proxy.world, proxy.previousWorld = worldPoint, worldPrevious
end

local function setVelocity(proxy, velocity, dt)
  local previousWorld = sub(proxy.world, mul(velocity, dt))
  local state, frame = proxy.component.state, proxy.component.frame
  local localPrevious = toParent(frame, previousWorld)
  local root = frame and frame.rootOriginWorld
  if root then localPrevious = sub(localPrevious, toParent(frame, root)) end
  state.previousPoints[proxy.index] = localPrevious
  proxy.previousWorld = previousWorld
end

local function pointVelocity(proxy, dt)
  if dt <= 0 then return vec(0, 0, 0) end
  return mul(sub(proxy.world, proxy.previousWorld), 1 / dt)
end

local function applyPointPoint(pair, dt)
  local a, b = pair.first, pair.second
  -- Normal points from b toward a so normal impulses separate the pair.
  local delta = sub(a.world, b.world)
  local distance = length(delta)
  local combined = a.radius + b.radius
  if distance >= combined then return false end
  local normal = distance > 0.000001 and mul(delta, 1 / distance) or stableNormal(a.id, b.id)
  local totalWeight = a.inverseMass + b.inverseMass
  if totalWeight <= 0 then return false end
  local penetration = combined - distance
  local movedA = add(a.world, mul(normal, penetration * a.inverseMass / totalWeight))
  local movedB = sub(b.world, mul(normal, penetration * b.inverseMass / totalWeight))
  writePoint(a, movedA, a.previousWorld)
  writePoint(b, movedB, b.previousWorld)

  local velocityA, velocityB = pointVelocity(a, dt), pointVelocity(b, dt)
  local relative = sub(velocityA, velocityB)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (a.restitution + b.restitution) * 0.5))
  local normalImpulse = 0
  if normalSpeed < 0 then
    normalImpulse = -(1 + restitution) * normalSpeed / totalWeight
    velocityA = add(velocityA, mul(normal, normalImpulse * a.inverseMass))
    velocityB = sub(velocityB, mul(normal, normalImpulse * b.inverseMass))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 then
    local friction = math.max(0, math.min(1, (a.friction + b.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityA = sub(velocityA, mul(tangentDirection, impulse * a.inverseMass))
    velocityB = add(velocityB, mul(tangentDirection, impulse * b.inverseMass))
  end
  setVelocity(a, velocityA, dt)
  setVelocity(b, velocityB, dt)
  return true
end

local function applySweptPointPoint(pair, dt)
  local a, b = pair.first, pair.second
  local combined = a.radius + b.radius
  local startDelta = sub(a.previousWorld, b.previousWorld)
  local startDistance = length(startDelta)
  if startDistance <= combined then return false end
  local relativeTravel = sub(sub(a.world, a.previousWorld), sub(b.world, b.previousWorld))
  local travelSquared = dot(relativeTravel, relativeTravel)
  if travelSquared <= 0.00000001 then return false end
  local closestTime = math.max(0, math.min(1, -dot(startDelta, relativeTravel) / travelSquared))
  if closestTime <= 0 then return false end
  local closestDelta = add(startDelta, mul(relativeTravel, closestTime))
  if dot(closestDelta, closestDelta) >= combined * combined then return false end

  local low, high = 0, closestTime
  for _ = 1, 12 do
    local middle = (low + high) * 0.5
    local delta = add(startDelta, mul(relativeTravel, middle))
    if dot(delta, delta) <= combined * combined then high = middle else low = middle end
  end
  local hitTime = high
  local impactA = lerp(a.previousWorld, a.world, hitTime)
  local impactB = lerp(b.previousWorld, b.world, hitTime)
  local normal = normalize(sub(impactA, impactB), stableNormal(a.id, b.id))
  local totalWeight = a.inverseMass + b.inverseMass
  if totalWeight <= 0 then return false end

  local velocityA, velocityB = pointVelocity(a, dt), pointVelocity(b, dt)
  local relative = sub(velocityA, velocityB)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (a.restitution + b.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / totalWeight or 0
  if normalImpulse > 0 then
    velocityA = add(velocityA, mul(normal, normalImpulse * a.inverseMass))
    velocityB = sub(velocityB, mul(normal, normalImpulse * b.inverseMass))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 and normalImpulse > 0 then
    local friction = math.max(0, math.min(1, (a.friction + b.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityA = sub(velocityA, mul(tangentDirection, impulse * a.inverseMass))
    velocityB = add(velocityB, mul(tangentDirection, impulse * b.inverseMass))
  end

  local remaining = dt * (1 - hitTime)
  writePoint(a, add(impactA, mul(velocityA, remaining)), a.previousWorld)
  writePoint(b, add(impactB, mul(velocityB, remaining)), b.previousWorld)
  setVelocity(a, velocityA, dt)
  setVelocity(b, velocityB, dt)
  return true
end

local function applyPointSegment(pair, dt)
  local pointProxy, segment = pair.point, pair.segment
  local closest, t = closestOnSegment(pointProxy.world, segment.first.world, segment.second.world)
  local delta = sub(pointProxy.world, closest)
  local distance = length(delta)
  local combined = pointProxy.radius + segment.radius
  if distance >= combined then return false end
  local firstWeight = segment.first.inverseMass * (1 - t)
  local secondWeight = segment.second.inverseMass * t
  local totalWeight = pointProxy.inverseMass + firstWeight + secondWeight
  if totalWeight <= 0 then return false end
  local normal = distance > 0.000001 and mul(delta, 1 / distance)
    or normalize({ x = -(segment.second.world.z - segment.first.world.z), y = 0,
      z = segment.second.world.x - segment.first.world.x }, stableNormal(pointProxy.id, segment.id))
  local penetration = combined - distance
  writePoint(pointProxy, add(pointProxy.world, mul(normal, penetration * pointProxy.inverseMass / totalWeight)), pointProxy.previousWorld)
  writePoint(segment.first, sub(segment.first.world, mul(normal, penetration * firstWeight / totalWeight)), segment.first.previousWorld)
  writePoint(segment.second, sub(segment.second.world, mul(normal, penetration * secondWeight / totalWeight)), segment.second.previousWorld)

  local velocityPoint = pointVelocity(pointProxy, dt)
  local velocityFirst = pointVelocity(segment.first, dt)
  local velocitySecond = pointVelocity(segment.second, dt)
  local velocitySegment = add(mul(velocityFirst, 1 - t), mul(velocitySecond, t))
  local relative = sub(velocityPoint, velocitySegment)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (pointProxy.restitution + segment.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / totalWeight or 0
  if normalImpulse > 0 then
    velocityPoint = add(velocityPoint, mul(normal, normalImpulse * pointProxy.inverseMass))
    velocityFirst = sub(velocityFirst, mul(normal, normalImpulse * segment.first.inverseMass * (1 - t)))
    velocitySecond = sub(velocitySecond, mul(normal, normalImpulse * segment.second.inverseMass * t))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 then
    local friction = math.max(0, math.min(1, (pointProxy.friction + segment.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityPoint = sub(velocityPoint, mul(tangentDirection, impulse * pointProxy.inverseMass))
    velocityFirst = add(velocityFirst, mul(tangentDirection, impulse * segment.first.inverseMass * (1 - t)))
    velocitySecond = add(velocitySecond, mul(tangentDirection, impulse * segment.second.inverseMass * t))
  end
  setVelocity(pointProxy, velocityPoint, dt)
  setVelocity(segment.first, velocityFirst, dt)
  setVelocity(segment.second, velocitySecond, dt)
  return true
end

local function applySweptPointSegment(pair, dt)
  local pointProxy, segment = pair.point, pair.segment
  local combined = pointProxy.radius + segment.radius
  local pointStart, pointEnd = pointProxy.previousWorld, pointProxy.world
  local firstStart, firstEnd = segment.first.previousWorld, segment.first.world
  local secondStart, secondEnd = segment.second.previousWorld, segment.second.world
  local pointTravel = length(sub(pointEnd, pointStart))
  local firstTravel = length(sub(firstEnd, firstStart))
  local secondTravel = length(sub(secondEnd, secondStart))
  local speedBound = pointTravel + math.max(firstTravel, secondTravel)
  if speedBound <= 0.000001 then return false end

  local function sample(time)
    local movingPoint = lerp(pointStart, pointEnd, time)
    local movingFirst = lerp(firstStart, firstEnd, time)
    local movingSecond = lerp(secondStart, secondEnd, time)
    local closest, segmentT = closestOnSegment(movingPoint, movingFirst, movingSecond)
    return length(sub(movingPoint, closest)), segmentT
  end

  local startDistance = sample(0)
  if startDistance <= combined then return false end
  local time, safeTime, hitTime, hitSegmentT = 0, 0, nil, nil
  for _ = 1, 24 do
    local distance = sample(time)
    local gap = distance - combined
    if gap <= 0.00005 then hitTime = time; break end
    safeTime = time
    local advance = gap / speedBound * 0.8
    if advance <= 0.000001 or time + advance >= 1 then break end
    time = time + advance
  end
  if not hitTime then return false end

  local low, high = safeTime, hitTime
  for _ = 1, 10 do
    local middle = (low + high) * 0.5
    local distance = sample(middle)
    if distance <= combined then high = middle else low = middle end
  end
  hitTime = high
  local distance
  distance, hitSegmentT = sample(hitTime)
  local impactPoint = lerp(pointStart, pointEnd, hitTime)
  local impactFirst = lerp(firstStart, firstEnd, hitTime)
  local impactSecond = lerp(secondStart, secondEnd, hitTime)
  local closest = lerp(impactFirst, impactSecond, hitSegmentT)
  local normal = normalize(sub(impactPoint, closest), stableNormal(pointProxy.id, segment.id))
  local firstWeight = segment.first.inverseMass * (1 - hitSegmentT)
  local secondWeight = segment.second.inverseMass * hitSegmentT
  local totalWeight = pointProxy.inverseMass + firstWeight + secondWeight
  if totalWeight <= 0 then return false end

  local penetration = math.max(0, combined - distance)
  if penetration > 0 then
    impactPoint = add(impactPoint, mul(normal, penetration * pointProxy.inverseMass / totalWeight))
    impactFirst = sub(impactFirst, mul(normal, penetration * firstWeight / totalWeight))
    impactSecond = sub(impactSecond, mul(normal, penetration * secondWeight / totalWeight))
  end

  local velocityPoint = pointVelocity(pointProxy, dt)
  local velocityFirst = pointVelocity(segment.first, dt)
  local velocitySecond = pointVelocity(segment.second, dt)
  local velocitySegment = add(mul(velocityFirst, 1 - hitSegmentT), mul(velocitySecond, hitSegmentT))
  local relative = sub(velocityPoint, velocitySegment)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (pointProxy.restitution + segment.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / totalWeight or 0
  if normalImpulse > 0 then
    velocityPoint = add(velocityPoint, mul(normal, normalImpulse * pointProxy.inverseMass))
    velocityFirst = sub(velocityFirst, mul(normal, normalImpulse * segment.first.inverseMass * (1 - hitSegmentT)))
    velocitySecond = sub(velocitySecond, mul(normal, normalImpulse * segment.second.inverseMass * hitSegmentT))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 and normalImpulse > 0 then
    local friction = math.max(0, math.min(1, (pointProxy.friction + segment.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityPoint = sub(velocityPoint, mul(tangentDirection, impulse * pointProxy.inverseMass))
    velocityFirst = add(velocityFirst, mul(tangentDirection, impulse * segment.first.inverseMass * (1 - hitSegmentT)))
    velocitySecond = add(velocitySecond, mul(tangentDirection, impulse * segment.second.inverseMass * hitSegmentT))
  end

  local remaining = dt * (1 - hitTime)
  writePoint(pointProxy, add(impactPoint, mul(velocityPoint, remaining)), pointProxy.previousWorld)
  writePoint(segment.first, add(impactFirst, mul(velocityFirst, remaining)), segment.first.previousWorld)
  writePoint(segment.second, add(impactSecond, mul(velocitySecond, remaining)), segment.second.previousWorld)
  setVelocity(pointProxy, velocityPoint, dt)
  setVelocity(segment.first, velocityFirst, dt)
  setVelocity(segment.second, velocitySecond, dt)
  return true
end

local function applySegmentSegment(pair, dt)
  local first, second = pair.first, pair.second
  local a, b, s, t = closestSegments(first.first.world, first.second.world, second.first.world, second.second.world)
  local delta = sub(a, b)
  local distance = length(delta)
  local combined = first.radius + second.radius
  if distance >= combined then return false end
  local firstAWeight, firstAFraction = first.first.inverseMass * (1 - s), 1 - s
  local firstBWeight, firstBFraction = first.second.inverseMass * s, s
  local secondAWeight, secondAFraction = second.first.inverseMass * (1 - t), 1 - t
  local secondBWeight, secondBFraction = second.second.inverseMass * t, t
  local totalWeight = firstAWeight + firstBWeight + secondAWeight + secondBWeight
  local effectiveWeight = first.first.inverseMass * firstAFraction * firstAFraction
    + first.second.inverseMass * firstBFraction * firstBFraction
    + second.first.inverseMass * secondAFraction * secondAFraction
    + second.second.inverseMass * secondBFraction * secondBFraction
  if totalWeight <= 0 or effectiveWeight <= 0 then return false end
  local normal = distance > 0.000001 and mul(delta, 1 / distance) or stableNormal(first.id, second.id)
  local penetration = combined - distance
  writePoint(first.first, add(first.first.world, mul(normal, penetration * firstAWeight / totalWeight)), first.first.previousWorld)
  writePoint(first.second, add(first.second.world, mul(normal, penetration * firstBWeight / totalWeight)), first.second.previousWorld)
  writePoint(second.first, sub(second.first.world, mul(normal, penetration * secondAWeight / totalWeight)), second.first.previousWorld)
  writePoint(second.second, sub(second.second.world, mul(normal, penetration * secondBWeight / totalWeight)), second.second.previousWorld)

  local velocityFirstA, velocityFirstB = pointVelocity(first.first, dt), pointVelocity(first.second, dt)
  local velocitySecondA, velocitySecondB = pointVelocity(second.first, dt), pointVelocity(second.second, dt)
  local velocityA = add(mul(velocityFirstA, 1 - s), mul(velocityFirstB, s))
  local velocityB = add(mul(velocitySecondA, 1 - t), mul(velocitySecondB, t))
  local relative = sub(velocityA, velocityB)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (first.restitution + second.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / effectiveWeight or 0
  if normalImpulse > 0 then
    velocityFirstA = add(velocityFirstA, mul(normal, normalImpulse * firstAWeight))
    velocityFirstB = add(velocityFirstB, mul(normal, normalImpulse * firstBWeight))
    velocitySecondA = sub(velocitySecondA, mul(normal, normalImpulse * secondAWeight))
    velocitySecondB = sub(velocitySecondB, mul(normal, normalImpulse * secondBWeight))
  end
  velocityA = add(mul(velocityFirstA, 1 - s), mul(velocityFirstB, s))
  velocityB = add(mul(velocitySecondA, 1 - t), mul(velocitySecondB, t))
  relative = sub(velocityA, velocityB)
  local tangent = sub(relative, mul(normal, dot(relative, normal)))
  local tangentLength = length(tangent)
  local frictionImpulse = 0
  if tangentLength > 0.000001 and normalImpulse > 0 then
    frictionImpulse = math.min(tangentLength / effectiveWeight,
      math.max(0, math.min(1, (first.friction + second.friction) * 0.5)) * normalImpulse)
  end
  local tangentDirection = tangentLength > 0.000001 and mul(tangent, 1 / tangentLength) or vec(0, 0, 0)
  velocityFirstA = sub(velocityFirstA, mul(tangentDirection, frictionImpulse * firstAWeight))
  velocityFirstB = sub(velocityFirstB, mul(tangentDirection, frictionImpulse * firstBWeight))
  velocitySecondA = add(velocitySecondA, mul(tangentDirection, frictionImpulse * secondAWeight))
  velocitySecondB = add(velocitySecondB, mul(tangentDirection, frictionImpulse * secondBWeight))
  setVelocity(first.first, velocityFirstA, dt)
  setVelocity(first.second, velocityFirstB, dt)
  setVelocity(second.first, velocitySecondA, dt)
  setVelocity(second.second, velocitySecondB, dt)
  return true
end

local function applySweptSegmentSegment(pair, dt)
  local first, second = pair.first, pair.second
  local firstStartA, firstStartB = first.first.previousWorld, first.second.previousWorld
  local secondStartA, secondStartB = second.first.previousWorld, second.second.previousWorld
  local firstEndA, firstEndB = first.first.world, first.second.world
  local secondEndA, secondEndB = second.first.world, second.second.world
  local combined = first.radius + second.radius
  local speedBound = math.max(length(sub(firstEndA, firstStartA)), length(sub(firstEndB, firstStartB)))
    + math.max(length(sub(secondEndA, secondStartA)), length(sub(secondEndB, secondStartB)))
  if speedBound <= 0.000001 then return false end
  local function sample(time)
    local a0, a1 = lerp(firstStartA, firstEndA, time), lerp(firstStartB, firstEndB, time)
    local b0, b1 = lerp(secondStartA, secondEndA, time), lerp(secondStartB, secondEndB, time)
    local closestA, closestB = closestSegments(a0, a1, b0, b1)
    return length(sub(closestA, closestB))
  end
  if sample(0) <= combined then return false end
  local time, safeTime, hitTime = 0, 0, nil
  for _ = 1, 32 do
    local gap = sample(time) - combined
    if gap <= 0.00005 then hitTime = time; break end
    safeTime = time
    local advance = gap / speedBound * 0.8
    if advance <= 0.000001 or time + advance >= 1 then break end
    time = time + advance
  end
  if not hitTime then return false end
  local low, high = safeTime, hitTime
  for _ = 1, 12 do
    local middle = (low + high) * 0.5
    if sample(middle) <= combined then high = middle else low = middle end
  end
  hitTime = math.min(1, high + 0.0005)
  first.first.world, first.second.world = lerp(firstStartA, firstEndA, hitTime), lerp(firstStartB, firstEndB, hitTime)
  second.first.world, second.second.world = lerp(secondStartA, secondEndA, hitTime), lerp(secondStartB, secondEndB, hitTime)
  if not applySegmentSegment(pair, dt) then
    first.first.world, first.second.world = firstEndA, firstEndB
    second.first.world, second.second.world = secondEndA, secondEndB
    return false
  end
  local remaining = dt * (1 - hitTime)
  local function finish(proxy)
    local velocity = pointVelocity(proxy, dt)
    local final = add(proxy.world, mul(velocity, remaining))
    writePoint(proxy, final, proxy.previousWorld)
    setVelocity(proxy, velocity, dt)
  end
  finish(first.first); finish(first.second); finish(second.first); finish(second.second)
  return true
end

local World = {}
World.__index = World

function worldApi.new(options)
  options = type(options) == "table" and options or {}
  local world = setmetatable({
    components = {},
    accumulator = 0,
    diagnostics = {},
  }, World)
  world:configure(options)
  return world
end

function World:configure(options)
  options = type(options) == "table" and options or {}
  local profile = performanceOptions(options.performance)
  self.performance = profile.performance
  self.fixedStep = clamp(options.fixedStep, 1 / 120, 1 / 20, profile.fixedStep or DEFAULTS.fixedStep)
  self.maxSubsteps = math.floor(clamp(options.maxSubsteps, 1, 5, profile.maxSubsteps or DEFAULTS.maxSubsteps))
  self.maxFrameDt = clamp(options.maxFrameDt, 1 / 60, 0.25, profile.maxFrameDt or DEFAULTS.maxFrameDt)
  self.maxPoints = math.floor(clamp(options.maxPoints, 1, 512, profile.maxPoints or DEFAULTS.maxPoints))
  self.maxCandidatePairs = math.floor(clamp(options.maxCandidatePairs, 0, 4096,
    profile.maxCandidatePairs or DEFAULTS.maxCandidatePairs))
  self.contactIterations = math.floor(clamp(options.contactIterations, 1, 4,
    profile.contactIterations or DEFAULTS.contactIterations))
  self.cellSize = clamp(options.cellSize, 0.25, 8, profile.cellSize or DEFAULTS.cellSize)
  self.maxCellsPerProxy = math.floor(clamp(options.maxCellsPerProxy, 8, 1024,
    profile.maxCellsPerProxy or DEFAULTS.maxCellsPerProxy))
  self.maxBlockQueries = math.floor(clamp(options.maxBlockQueries, 0, 256,
    profile.maxBlockQueries or 64))
  if options.segmentMode == "segment_segment" then self.segmentMode = "segment_segment"
  elseif options.segmentMode == "point_segment" then self.segmentMode = "point_segment"
  else self.segmentMode = profile.segmentMode or "point_segment" end
  self.collisionMatrix = type(options.collisionMatrix) == "table" and options.collisionMatrix or {}
  self.accumulator = math.min(self.accumulator or 0, self.fixedStep * self.maxSubsteps)
  return self
end

worldApi.performanceOptions = performanceOptions

function World:setComponents(components)
  self.components = {}
  local seen = {}
  for _, component in ipairs(components or {}) do
    if type(component) == "table" and component.id ~= nil then
      local id = tostring(component.id)
      if not seen[id] then
        seen[id] = true
        component.id = id
        self.components[#self.components + 1] = component
      end
    end
  end
  return #self.components
end

function World:addComponent(component)
  if type(component) ~= "table" or component.id == nil then return false end
  local id = tostring(component.id)
  for index, existing in ipairs(self.components) do
    if existing.id == id then self.components[index] = component; return true end
  end
  component.id = id
  self.components[#self.components + 1] = component
  return true
end

function World:removeComponent(id)
  id = tostring(id)
  for index = #self.components, 1, -1 do
    if self.components[index].id == id then table.remove(self.components, index); return true end
  end
  return false
end

local function collectProxies(world, components)
  local points, segments, count, truncated, frameUnavailable = {}, {}, 0, false, 0
  for _, component in ipairs(components or {}) do
    if component.enabled ~= false and type(component.state) == "table"
      and type(component.state.points) == "table" and type(component.state.previousPoints) == "table" then
      local pointInfo = component.pointInfo or {}
      local localProxies = {}
      local missingFrame = false
      for index, current in ipairs(component.state.points) do
        local info = pointInfo[index] or {}
        local radius = math.max(0, tonumber(info.radius) or 0)
        if info.dynamic ~= false and radius > 0 then
          local worldPoint = toWorld(component.frame, current)
          local previousWorld = toWorld(component.frame, component.state.previousPoints[index])
          if not worldPoint or not previousWorld then
            missingFrame = true
          elseif count >= world.maxPoints then
            truncated = true
            break
          else
            count = count + 1
            local proxy = {
              id = component.id .. ":" .. tostring(index), component = component, index = index,
              radius = radius, inverseMass = math.max(0, tonumber(info.inverseMass) or 0),
              group = info.group or component.group or "custom", mask = info.mask or component.mask,
              friction = clamp(info.friction, 0, 1, 0.25), restitution = clamp(info.restitution, 0, 1, 0),
              world = worldPoint, previousWorld = previousWorld,
            }
            localProxies[index] = proxy
            points[#points + 1] = proxy
          end
        end
      end
      if missingFrame then frameUnavailable = frameUnavailable + 1 end
      for _, edge in ipairs(component.graph and component.graph.edges or {}) do
        local first, second = localProxies[edge.from], localProxies[edge.to]
        if first and second then
          local radius = math.max(0, tonumber(edge.radius) or (first.radius + second.radius) * 0.5)
          if radius > 0 then
            segments[#segments + 1] = {
              id = component.id .. ":e:" .. tostring(edge.from) .. ":" .. tostring(edge.to),
              component = component, first = first, second = second, radius = radius,
              group = edge.group or first.group, mask = edge.mask or first.mask,
              friction = (first.friction + second.friction) * 0.5,
              restitution = (first.restitution + second.restitution) * 0.5,
            }
          end
        end
      end
    end
  end
  return points, segments, count, truncated, frameUnavailable
end

local function addProxyToGrid(grid, large, proxy, bounds, cellSize, maxCells)
  -- Bounds are already in grid coordinates; enumerate directly to avoid a second transform.
  local cellCount = (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) * (bounds.maxZ - bounds.minZ + 1)
  if cellCount > maxCells then large[#large + 1] = proxy; return end
  for x = bounds.minX, bounds.maxX do
    for y = bounds.minY, bounds.maxY do
      for z = bounds.minZ, bounds.maxZ do
        local key = cellKey(x, y, z)
        local bucket = grid[key]
        if not bucket then bucket = {}; grid[key] = bucket end
        bucket[#bucket + 1] = proxy
      end
    end
  end
end

function World:resolveDynamicContacts(components, dt, budgetLimit)
  components = components or self.components
  dt = clamp(dt, 0.0001, 0.25, self.fixedStep)
  local stats = { activeComponents = 0, activePoints = 0, activeSegments = 0,
    candidatePairs = 0, resolvedContacts = 0, iterations = 0,
    segmentSegmentPairs = 0, budgetExceeded = false, pointBudgetExceeded = false,
    frameUnavailableComponents = 0, contactPoints = {} }
  for _, component in ipairs(components) do if component.enabled ~= false then stats.activeComponents = stats.activeComponents + 1 end end
  local points, segments, count, truncated, frameUnavailable = collectProxies(self, components)
  stats.activePoints, stats.activeSegments, stats.pointBudgetExceeded = count, #segments, truncated
  stats.frameUnavailableComponents = frameUnavailable
  if #points < 1 then self.diagnostics = stats; return stats end
  local maxCandidatePairs = math.max(0, math.floor(tonumber(budgetLimit) or self.maxCandidatePairs))
  local function collidePass()
    local pointGrid, segmentGrid, largePoints, largeSegments = {}, {}, {}, {}
    for proxyOrder, proxy in ipairs(points) do proxy.order = proxyOrder end
    for segmentOrder, segment in ipairs(segments) do segment.order = segmentOrder end
    for _, proxy in ipairs(points) do
      local bounds = sweptPointAabb(proxy, proxy.radius, self.cellSize)
      proxy.sweepBounds = sweptPointBounds(proxy, proxy.radius)
      addProxyToGrid(pointGrid, largePoints, proxy, bounds, self.cellSize, self.maxCellsPerProxy)
    end
    for _, segment in ipairs(segments) do
      local bounds = sweptSegmentAabb(segment, segment.radius, self.cellSize)
      segment.sweepBounds = sweptSegmentBounds(segment, segment.radius)
      addProxyToGrid(segmentGrid, largeSegments, segment, bounds, self.cellSize, self.maxCellsPerProxy)
    end
    local seen, pairsToCheck = {}, {}
    local function addPair(kind, first, second)
      if first.component == second.component or not groupsAllow(self, first, second) then return true end
      local firstId, secondId = first.id, second.id
      local firstOrder, secondOrder = first.order, second.order
      if firstOrder > secondOrder then firstOrder, secondOrder = secondOrder, firstOrder end
      local kindSeen = seen[kind]
      if not kindSeen then kindSeen = {}; seen[kind] = kindSeen end
      local firstSeen = kindSeen[firstOrder]
      if firstSeen and firstSeen[secondOrder] then return true end
      if stats.candidatePairs >= maxCandidatePairs then stats.budgetExceeded = true; return false end
      if not firstSeen then firstSeen = {}; kindSeen[firstOrder] = firstSeen end
      firstSeen[secondOrder] = true
      stats.candidatePairs = stats.candidatePairs + 1
      if kind == "ss" then stats.segmentSegmentPairs = stats.segmentSegmentPairs + 1 end
      if kind == "pp" or kind == "ss" then pairsToCheck[#pairsToCheck + 1] = { kind = kind, first = first, second = second }
      else pairsToCheck[#pairsToCheck + 1] = { kind = kind, point = first, segment = second } end
      return true
    end
    local function gatherPoint(pointProxy, bucket)
      for _, other in ipairs(bucket or {}) do
        if pointProxy.id < other.id and pointProxy.component ~= other.component
          and boundsOverlap(pointProxy.sweepBounds, other.sweepBounds) then
          if not addPair("pp", pointProxy, other) then return false end
        end
      end
      return true
    end
    local function gatherSegment(pointProxy, bucket)
      for _, segment in ipairs(bucket or {}) do
        if pointProxy.component ~= segment.component
          and boundsOverlap(pointProxy.sweepBounds, segment.sweepBounds) then
          if not addPair("ps", pointProxy, segment) then return false end
        end
      end
      return true
    end
    local function gatherSegmentSegment(segment, bucket)
      for _, other in ipairs(bucket or {}) do
        if segment.order < other.order and segment.component ~= other.component
          and boundsOverlap(segment.sweepBounds, other.sweepBounds) then
          if not addPair("ss", segment, other) then return false end
        end
      end
      return true
    end
    for _, proxy in ipairs(points) do
      local bounds = sweptPointAabb(proxy, proxy.radius, self.cellSize)
      local cells = gridCellsFor(bounds, self.maxCellsPerProxy)
      if cells then
        for _, key in ipairs(cells) do
          if not gatherPoint(proxy, pointGrid[key]) or not gatherSegment(proxy, segmentGrid[key]) then break end
        end
      else
        for _, other in ipairs(points) do
          if proxy.id < other.id and proxy.component ~= other.component
            and boundsOverlap(proxy.sweepBounds, other.sweepBounds) then
            if not addPair("pp", proxy, other) then break end
          end
        end
        for _, segment in ipairs(segments) do
          if proxy.component ~= segment.component and boundsOverlap(proxy.sweepBounds, segment.sweepBounds) then
            if not addPair("ps", proxy, segment) then break end
          end
        end
      end
      for _, other in ipairs(largePoints) do
        if proxy.id < other.id and proxy.component ~= other.component
          and boundsOverlap(proxy.sweepBounds, other.sweepBounds) then
          if not addPair("pp", proxy, other) then break end
        end
      end
      for _, segment in ipairs(largeSegments) do
        if proxy.component ~= segment.component and boundsOverlap(proxy.sweepBounds, segment.sweepBounds) then
          if not addPair("ps", proxy, segment) then break end
        end
      end
      if stats.budgetExceeded then break end
    end
    if self.segmentMode == "segment_segment" and not stats.budgetExceeded then
      for _, segment in ipairs(segments) do
        local bounds = sweptSegmentAabb(segment, segment.radius, self.cellSize)
        local cells = gridCellsFor(bounds, self.maxCellsPerProxy)
        if cells then
          for _, key in ipairs(cells) do
            if not gatherSegmentSegment(segment, segmentGrid[key]) then break end
          end
        else
          for _, other in ipairs(segments) do
            if segment.order < other.order and segment.component ~= other.component
              and boundsOverlap(segment.sweepBounds, other.sweepBounds) then
              if not addPair("ss", segment, other) then break end
            end
          end
        end
        for _, other in ipairs(largeSegments) do
          if segment.order < other.order and segment.component ~= other.component
            and boundsOverlap(segment.sweepBounds, other.sweepBounds) then
            if not addPair("ss", segment, other) then break end
          end
        end
        if stats.budgetExceeded then break end
      end
    end
    for _, pair in ipairs(pairsToCheck) do
      local resolved
      if pair.kind == "pp" then
        resolved = applyPointPoint(pair, dt) or applySweptPointPoint(pair, dt)
      elseif pair.kind == "ss" then
        resolved = applySegmentSegment(pair, dt) or applySweptSegmentSegment(pair, dt)
      else
        resolved = applyPointSegment(pair, dt) or applySweptPointSegment(pair, dt)
      end
      if resolved then
        stats.resolvedContacts = stats.resolvedContacts + 1
        local function mark(proxy)
          local byComponent = stats.contactPoints[proxy.component.id]
          if not byComponent then byComponent = {}; stats.contactPoints[proxy.component.id] = byComponent end
          byComponent[proxy.index] = true
        end
        if pair.kind == "pp" then mark(pair.first); mark(pair.second)
        elseif pair.kind == "ss" then
          mark(pair.first.first); mark(pair.first.second); mark(pair.second.first); mark(pair.second.second)
        else mark(pair.point); mark(pair.segment.first); mark(pair.segment.second) end
      end
    end
  end
  for iteration = 1, self.contactIterations do
    stats.iterations = iteration
    collidePass()
    if stats.budgetExceeded then break end
  end
  self.diagnostics = stats
  return stats
end

function World:step(dt, components, hooks)
  if components ~= nil then self:setComponents(components) end
  hooks = type(hooks) == "table" and hooks or {}
  dt = clamp(dt, 0, self.maxFrameDt, 0)
  self.accumulator = math.min(self.accumulator + dt, self.fixedStep * self.maxSubsteps)
  local stats = { substeps = 0, alpha = 0, activeComponents = 0, activePoints = 0,
    activeSegments = 0, candidatePairs = 0, resolvedContacts = 0, budgetExceeded = false,
    segmentSegmentPairs = 0,
    pointBudgetExceeded = false, performance = self.performance,
    frameUnavailableComponents = 0,
    maxCandidatePairs = self.maxCandidatePairs, maxPoints = self.maxPoints,
    maxSubsteps = self.maxSubsteps, contactIterations = self.contactIterations,
    worldQueries = 0, localContacts = 0, selfPairs = 0,
    worldQueryBudget = self.maxBlockQueries, blockBudgetExceeded = false,
    selfBudgetExceeded = false, worldUnavailable = false }
  for _, component in ipairs(self.components) do if component.enabled ~= false then stats.activeComponents = stats.activeComponents + 1 end end
  while self.accumulator + 0.000000001 >= self.fixedStep and stats.substeps < self.maxSubsteps do
    if type(hooks.beforeSubstep) == "function" then hooks.beforeSubstep(self.components, self.fixedStep) end
    for _, component in ipairs(self.components) do
      if component.enabled ~= false and type(hooks.integrate) == "function" then hooks.integrate(component, self.fixedStep) end
    end
    local remainingPairs = math.max(0, self.maxCandidatePairs - stats.candidatePairs)
    local contacts = self:resolveDynamicContacts(nil, self.fixedStep, remainingPairs)
    stats.activePoints = math.max(stats.activePoints, contacts.activePoints)
    stats.activeSegments = math.max(stats.activeSegments, contacts.activeSegments)
    stats.candidatePairs = stats.candidatePairs + contacts.candidatePairs
    stats.resolvedContacts = stats.resolvedContacts + contacts.resolvedContacts
    stats.segmentSegmentPairs = stats.segmentSegmentPairs + (contacts.segmentSegmentPairs or 0)
    stats.frameUnavailableComponents = math.max(stats.frameUnavailableComponents, contacts.frameUnavailableComponents or 0)
    stats.budgetExceeded = stats.budgetExceeded or contacts.budgetExceeded or contacts.pointBudgetExceeded
    stats.pointBudgetExceeded = stats.pointBudgetExceeded or contacts.pointBudgetExceeded
    if type(hooks.contacts) == "function" then hooks.contacts(self.components, self.fixedStep, contacts) end
    for _, component in ipairs(self.components) do
      if component.enabled ~= false and type(hooks.resolveLocal) == "function" then
        local localStats = hooks.resolveLocal(component, self.fixedStep, contacts.contactPoints[component.id] or {}, contacts)
        if type(localStats) == "table" then
          stats.worldQueries = stats.worldQueries + (tonumber(localStats.worldQueries) or 0)
          stats.localContacts = stats.localContacts + (tonumber(localStats.contacts) or 0)
          stats.selfPairs = stats.selfPairs + (tonumber(localStats.selfPairs) or 0)
          stats.blockBudgetExceeded = stats.blockBudgetExceeded or localStats.budgetExceeded == true
          stats.selfBudgetExceeded = stats.selfBudgetExceeded or localStats.selfBudgetExceeded == true
          stats.worldUnavailable = stats.worldUnavailable or localStats.worldUnavailable == true
        end
      end
    end
    self.accumulator = math.max(0, self.accumulator - self.fixedStep)
    stats.substeps = stats.substeps + 1
  end
  stats.alpha = math.max(0, math.min(1, self.accumulator / self.fixedStep))
  self.diagnostics = stats
  if type(hooks.finish) == "function" then hooks.finish(self.components, stats.alpha, stats) end
  return stats
end

return worldApi
