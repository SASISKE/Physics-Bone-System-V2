local constraints = {}

local function vec(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function sub(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
local function add(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
local function scale(a, amount) return vec(a.x * amount, a.y * amount, a.z * amount) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return vec(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function length(a) return math.sqrt(dot(a, a)) end
local function normalize(a, fallback)
  local size = length(a)
  if size < 0.000001 or size ~= size or size == math.huge then return fallback or vec(0, -1, 0) end
  return scale(a, 1 / size)
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

local function edgeLength(points, edge)
  return length(sub(points[edge.to], points[edge.from]))
end

function constraints.solveLengths(points, graph, passes, pinnedRoot)
  if type(points) ~= "table" or type(graph) ~= "table" then return points end
  passes = math.max(1, math.min(12, math.floor(tonumber(passes) or 4)))
  pinnedRoot = pinnedRoot or points[1]
  for _ = 1, passes do
    for _, edge in ipairs(graph.edges or {}) do
      local from, to = points[edge.from], points[edge.to]
      if from and to and edge.restLength and edge.restLength > 0 then
        local delta = sub(to, from)
        local current = length(delta)
        if current < 0.000001 then
          delta = edge.restVector or vec(0, -edge.restLength, 0)
          current = length(delta)
        end
        local correction = scale(delta, (current - edge.restLength) / math.max(current, 0.000001))
        local fromPinned = edge.from == 1
        local toPinned = edge.to == 1
        if fromPinned then points[edge.to] = sub(to, correction)
        elseif toPinned then points[edge.from] = add(from, correction)
        else
          points[edge.from] = add(from, scale(correction, 0.5))
          points[edge.to] = sub(to, scale(correction, 0.5))
        end
      end
    end
    if points[1] then points[1] = vec(pinnedRoot.x, pinnedRoot.y, pinnedRoot.z) end

  end

  -- Finish with one root-to-tip projection. Earlier symmetric passes let
  -- downstream links pull against the pinned root, leaving residual stretch
  -- on long chains after a hard impulse. Walking the tree outward only moves
  -- each child, so all segment lengths are exact at the end of the solve.
  for _, edge in ipairs(graph.edges or {}) do
    local from, to = points[edge.from], points[edge.to]
    if from and to and edge.restLength and edge.restLength > 0 then
      local delta = sub(to, from)
      local current = length(delta)
      if current < 0.000001 then
        delta = edge.restVector or vec(0, -edge.restLength, 0)
        current = length(delta)
      end
      points[edge.to] = add(from, scale(delta, edge.restLength / math.max(current, 0.000001)))
    end
  end
  if points[1] then points[1] = vec(pinnedRoot.x, pinnedRoot.y, pinnedRoot.z) end
  return points
end

local function rotateAroundAxis(v, axis, angle)
  axis = normalize(axis)
  local c, s = math.cos(angle), math.sin(angle)
  return add(add(scale(v, c), scale(cross(axis, v), s)), scale(axis, dot(axis, v) * (1 - c)))
end

local function clampCone(direction, reference, maximumAngle)
  local current = normalize(direction)
  local target = normalize(reference)
  local cosine = math.max(-1, math.min(1, dot(target, current)))
  local angle = math.acos(cosine)
  if angle <= maximumAngle or angle < 0.000001 then return current end
  local axis = cross(target, current)
  if length(axis) < 0.00001 then
    axis = cross(target, math.abs(target.y) < 0.9 and vec(0, 1, 0) or vec(1, 0, 0))
  end
  return normalize(rotateAroundAxis(target, axis, maximumAngle), target)
end

local function clampHinge(direction, reference, axis, maximumAngle)
  axis = normalize(axis, vec(0, 1, 0))
  local base = normalize(reference)
  local current = normalize(direction)
  local basePerpendicular = sub(base, scale(axis, dot(base, axis)))
  local currentPerpendicular = sub(current, scale(axis, dot(current, axis)))
  if length(basePerpendicular) < 0.00001 or length(currentPerpendicular) < 0.00001 then return base end
  basePerpendicular, currentPerpendicular = normalize(basePerpendicular), normalize(currentPerpendicular)
  local angle = atan2(dot(axis, cross(basePerpendicular, currentPerpendicular)), dot(basePerpendicular, currentPerpendicular))
  local limit = math.max(0, maximumAngle)
  return normalize(rotateAroundAxis(base, axis, math.max(-limit, math.min(limit, angle))), base)
end

function constraints.solveAngle(points, graph, settingsForLink, targetPoints, dt, contactPoints)
  if type(points) ~= "table" or type(graph) ~= "table" or type(targetPoints) ~= "table" then return points end
  for _, edge in ipairs(graph.edges or {}) do
    local settings = settingsForLink and settingsForLink(edge.fromLink) or nil
    local joint = settings and settings.joint or {}
    local kind = joint.type or "cone"
    local touchingSurface = contactPoints and (contactPoints[edge.from] or contactPoints[edge.to])
    if kind ~= "free" and not touchingSurface then
      local from, to = points[edge.from], points[edge.to]
      local targetFrom, targetTo = targetPoints[edge.from], targetPoints[edge.to]
      if from and to and targetFrom and targetTo then
        local current = sub(to, from)
        local reference = sub(targetTo, targetFrom)
        local maximum = math.rad(math.max(0, math.min(180, tonumber(joint.angle) or 35)))
        local direction = normalize(current, normalize(reference))
        if kind == "hinge" then
          direction = clampHinge(direction, normalize(reference), joint.axis or vec(0, 1, 0), maximum)
        else
          direction = clampCone(direction, normalize(reference), maximum)
        end
        local distance = edge.restLength or length(current)
        points[edge.to] = add(from, scale(direction, distance))
      end
    end
  end
  return points
end

function constraints.solveBend(points, graph, settingsForLink, targetPoints, dt, contactPoints)
  if type(points) ~= "table" or type(graph) ~= "table" or type(targetPoints) ~= "table" then return points end
  dt = tonumber(dt) or 0
  if dt <= 0 then return points end
  for _, edge in ipairs(graph.edges or {}) do
    local middleIndex = edge.fromLink
    local middleLink = graph.links and graph.links[middleIndex]
    local parentIndex = middleLink and middleLink.parentIndex
    local setting = settingsForLink and settingsForLink(middleIndex) or nil
    local stiffness = math.max(0, tonumber(setting and setting.bendStiffness) or 0)
    local parent, middle, child = parentIndex and points[parentIndex], points[middleIndex], points[edge.to]
    local targetParent = parentIndex and targetPoints[parentIndex]
    local targetMiddle, targetChild = targetPoints[middleIndex], targetPoints[edge.to]
    local touchingSurface = contactPoints and ((parentIndex and contactPoints[parentIndex]) or contactPoints[middleIndex]
      or contactPoints[edge.to])
    if parent and middle and child and targetParent and targetMiddle and targetChild and stiffness > 0
      and not touchingSurface then
      local ix, iy, iz = middle.x - parent.x, middle.y - parent.y, middle.z - parent.z
      local il = math.sqrt(ix * ix + iy * iy + iz * iz)
      local ox, oy, oz = child.x - middle.x, child.y - middle.y, child.z - middle.z
      local ol = math.sqrt(ox * ox + oy * oy + oz * oz)
      local tix, tiy, tiz = targetMiddle.x - targetParent.x, targetMiddle.y - targetParent.y, targetMiddle.z - targetParent.z
      local til = math.sqrt(tix * tix + tiy * tiy + tiz * tiz)
      local tox, toy, toz = targetChild.x - targetMiddle.x, targetChild.y - targetMiddle.y, targetChild.z - targetMiddle.z
      local tol = math.sqrt(tox * tox + toy * toy + toz * toz)
      if il > 0.000001 and ol > 0.000001 and til > 0.000001 and tol > 0.000001 then
        ix, iy, iz = ix / il, iy / il, iz / il
        ox, oy, oz = ox / ol, oy / ol, oz / ol
        tix, tiy, tiz = tix / til, tiy / til, tiz / til
        tox, toy, toz = tox / tol, toy / tol, toz / tol
        local ex = (tox - tix) - (ox - ix)
        local ey = (toy - tiy) - (oy - iy)
        local ez = (toz - tiz) - (oz - iz)
        local errorSquared = ex * ex + ey * ey + ez * ez
        if errorSquared > 0.000000000001 then
          -- The linearized bend spring avoids per-link trigonometry and vector allocations.
          local blend = math.min(1, stiffness * dt)
          ox, oy, oz = ox + ex * blend, oy + ey * blend, oz + ez * blend
          local correctedLength = math.sqrt(ox * ox + oy * oy + oz * oz)
          if correctedLength > 0.000001 then
            local edgeLength = tonumber(edge.restLength) or ol
            points[edge.to] = {
              x = middle.x + ox / correctedLength * edgeLength,
              y = middle.y + oy / correctedLength * edgeLength,
              z = middle.z + oz / correctedLength * edgeLength,
            }
          end
        end
      end
    end
  end
  return points
end

function constraints.directionRotation(fromDirection, toDirection)
  local from, to = normalize(fromDirection), normalize(toDirection)
  local cosine = math.max(-1, math.min(1, dot(from, to)))
  local axis = cross(from, to)
  local axisLength = length(axis)
  local angle = math.acos(cosine)
  if angle < 0.000001 then return vec(0, 0, 0) end
  if axisLength < 0.000001 then
    axis = cross(from, math.abs(from.y) < 0.9 and vec(0, 1, 0) or vec(1, 0, 0))
    axisLength = length(axis)
  end
  axis = scale(axis, 1 / math.max(axisLength, 0.000001))
  return scale(axis, angle)
end

return constraints
