local physicsCore = {}

local FIXED_DT = 1 / 60
local MAX_FRAME_DT = 1 / 20
local CONSTRAINT_PASSES = 6
local MODEL_UNITS_PER_BLOCK = 16
local AIRFLOW_MAX_SPEED = 8
local AIRFLOW_REFERENCE_SPEED = 4.5
local AIRFLOW_MAX_ACCELERATION = 6
local AIRFLOW_MAX_CHAIN_DEFLECTION = 0.25
local AIRFLOW_RESPONSE_SECONDS = 0.12
local ROOT_INERTIA_RESPONSE_SECONDS = 0.08
local ROOT_INERTIA_MAX_ACCELERATION = 24
local ROOT_INERTIA_MAX_YAW_ACCELERATION = math.rad(720)

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function vector(x, y, z)
  return { x = x or 0, y = y or 0, z = z or 0 }
end

local ZERO_VECTOR = vector(0, 0, 0)

local function safeVector(value)
  if type(value) ~= "table" or not finite(value.x) or not finite(value.y) or not finite(value.z) then
    return vector(0, 0, 0)
  end
  return vector(value.x, value.y, value.z)
end

local function copyPoints(points)
  local result = {}
  for index, point in ipairs(points or {}) do result[index] = safeVector(point) end
  return result
end

local function copyPointsInto(points, result)
  result = result or {}
  for index, point in ipairs(points or {}) do
    local output = result[index]
    if output then
      output.x = finite(point and point.x) and point.x or 0
      output.y = finite(point and point.y) and point.y or 0
      output.z = finite(point and point.z) and point.z or 0
    else
      result[index] = safeVector(point)
    end
  end
  for index = #(points or {}) + 1, #result do result[index] = nil end
  return result
end

local function add(a, b)
  return vector(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function sub(a, b)
  return vector(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function scale(value, factor)
  return vector(value.x * factor, value.y * factor, value.z * factor)
end

local function dot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

local function cross(a, b)
  return vector(a.y * b.z - a.z * b.y,
    a.z * b.x - a.x * b.z,
    a.x * b.y - a.y * b.x)
end

local function length(value)
  return math.sqrt(math.max(0, dot(value, value)))
end

local function normalize(value, fallback)
  local magnitude = length(value)
  if magnitude < 0.000001 then return safeVector(fallback or vector(0, -1, 0)) end
  return scale(value, 1 / magnitude)
end

local function clampMagnitude(value, maximum)
  local magnitude = length(value)
  if magnitude <= maximum or magnitude < 0.000001 then return value end
  return scale(value, maximum / magnitude)
end

local function angleVector(from, to)
  local a, b = normalize(from), normalize(to)
  local axis = cross(a, b)
  local axisLength = length(axis)
  local cosine = clamp(dot(a, b), -1, 1)
  local angle = math.acos(cosine)
  if axisLength < 0.000001 or angle < 0.000001 then
    if cosine < 0 then
      local fallback = math.abs(a.x) < 0.8 and vector(1, 0, 0) or vector(0, 0, 1)
      axis = normalize(cross(a, fallback))
      return scale(axis, angle)
    end
    return vector(0, 0, 0)
  end
  return scale(axis, angle / axisLength)
end

local function rotateByVector(value, rotation)
  local angle = length(rotation)
  if angle < 0.000001 then return safeVector(value) end
  local axis = scale(rotation, 1 / angle)
  local cosine, sine = math.cos(angle), math.sin(angle)
  return add(add(scale(value, cosine), scale(cross(axis, value), sine)),
    scale(axis, dot(axis, value) * (1 - cosine)))
end

local function validBase(points, linkCount)
  return type(points) == "table" and #points == linkCount + 1
end

local function rotateYaw(value, angle)
  local cosine, sine = math.cos(angle), math.sin(angle)
  return vector(value.x * cosine + value.z * sine, value.y,
    -value.x * sine + value.z * cosine)
end

local function rotateEuler(value, rotation)
  rotation = safeVector(rotation)
  local x, y, z = math.rad(rotation.x), math.rad(rotation.y), math.rad(rotation.z)
  local sx, cx, sy, cy, sz, cz = math.sin(x), math.cos(x), math.sin(y), math.cos(y), math.sin(z), math.cos(z)
  local afterX = vector(value.x, value.y * cx - value.z * sx, value.y * sx + value.z * cx)
  local afterY = vector(afterX.x * cy + afterX.z * sy, afterX.y, -afterX.x * sy + afterX.z * cy)
  return vector(afterY.x * cz - afterY.y * sz, afterY.x * sz + afterY.y * cz, afterY.z)
end

local function hingeAxis(baseDirection, rotation)
  local reference = rotateEuler(vector(1, 0, 0), rotation)
  local axis = cross(baseDirection, reference)
  if length(axis) < 0.000001 then
    reference = rotateEuler(vector(0, 0, 1), rotation)
    axis = cross(baseDirection, reference)
  end
  if length(axis) < 0.000001 then axis = cross(baseDirection, vector(0, 1, 0)) end
  return normalize(axis, vector(0, 0, 1))
end

local function linkSettings(settings, index)
  local result = {}
  for key, value in pairs(settings or {}) do
    if key ~= "linkOverrides" then result[key] = value end
  end
  local override = settings and settings.linkOverrides and settings.linkOverrides[index]
  if type(override) == "table" then
    for key, value in pairs(override) do
      if (key == "gravity" or key == "limitRotation") and type(value) == "table" then
        local merged = safeVector(result[key])
        for axis, axisValue in pairs(value) do merged[axis] = axisValue end
        result[key] = merged
      else
        result[key] = value
      end
    end
  end
  return result
end

local function writeGravityInChainFrame(frame, source, target)
  source = type(source) == "table" and source or {}
  local sourceX = finite(source.x) and source.x or 0
  local sourceY = finite(source.y) and source.y or 0
  local sourceZ = finite(source.z) and source.z or 0
  target = type(target) == "table" and target or {}
  local valid = type(frame) == "table" and type(frame[1]) == "table"
    and type(frame[2]) == "table" and type(frame[3]) == "table"
  if valid then
    for row = 1, 3 do
      for column = 1, 3 do
        if not finite(frame[row][column]) then valid = false break end
      end
      if not valid then break end
    end
  end
  if valid then
    target.x = frame[1][1] * sourceX + frame[1][2] * sourceY + frame[1][3] * sourceZ
    target.y = frame[2][1] * sourceX + frame[2][2] * sourceY + frame[2][3] * sourceZ
    target.z = frame[3][1] * sourceX + frame[3][2] * sourceY + frame[3][3] * sourceZ
  else
    target.x, target.y, target.z = sourceX, sourceY, sourceZ
  end
  return target
end

function physicsCore.resolveLinks(settings, linkCount)
  local result = {}
  for index = 1, linkCount or 0 do
    local link = linkSettings(settings, index)
    -- The solver rewrites this cached vector into the current chain frame each
    -- tick. Give it an owned copy so the avatar config/UI keeps world XYZ intact.
    link.gravity = safeVector(link.gravity)
    link.gravitySource = safeVector(link.gravity)
    result[index] = link
  end
  return result
end

local function cleanLengths(restLengths, linkCount, basePoints, result)
  result = result or {}
  for index = 1, linkCount do
    local candidate = tonumber(restLengths and restLengths[index])
    if not finite(candidate) or candidate < 0.001 then
      candidate = length(sub(basePoints[index + 1], basePoints[index]))
    end
    result[index] = math.max(0.001, finite(candidate) and candidate or 0.001)
  end
  for index = linkCount + 1, #result do result[index] = nil end
  return result
end

local function getDirection(points, index)
  return sub(points[index + 1], points[index])
end

local function angleForLink(points, basePoints, index)
  return angleVector(getDirection(basePoints, index), getDirection(points, index))
end

local function enforceLengths(points, restLengths)
  -- Keep the same six-pass distance projection, but do the hot arithmetic with
  -- scalars so each joint correction does not allocate several short-lived tables.
  local root = points[1]
  if type(root) ~= "table" or not finite(root.x) or not finite(root.y) or not finite(root.z) then
    root = vector(0, 0, 0)
    points[1] = root
  end
  for _ = 1, CONSTRAINT_PASSES do
    for index = 1, #restLengths do
      local first, second = points[index], points[index + 1]
      local dx, dy, dz = second.x - first.x, second.y - first.y, second.z - first.z
      local distance = math.sqrt(math.max(0, dx * dx + dy * dy + dz * dz))
      local correctionX, correctionY, correctionZ
      if distance > 0.000001 then
        local inverseDistance = 1 / distance
        local correctionScale = distance - restLengths[index]
        correctionX = (dx * inverseDistance) * correctionScale
        correctionY = (dy * inverseDistance) * correctionScale
        correctionZ = (dz * inverseDistance) * correctionScale
      else
        -- Same fallback direction as the vector implementation: (0, -1, 0).
        correctionX, correctionY, correctionZ = 0, restLengths[index] - distance, 0
      end
      if index == 1 then
        second.x, second.y, second.z = second.x - correctionX, second.y - correctionY, second.z - correctionZ
      else
        local halfX, halfY, halfZ = correctionX * 0.5, correctionY * 0.5, correctionZ * 0.5
        first.x, first.y, first.z = first.x + halfX, first.y + halfY, first.z + halfZ
        second.x, second.y, second.z = second.x - halfX, second.y - halfY, second.z - halfZ
      end
    end
  end
end

local function clampLinkAngles(state, basePoints, restLengths, settings, stepDt, resolvedLinks, collectDiagnostics)
  -- Reuse the old offset array as scratch output. Keeping two alternating arrays
  -- avoids allocating one vector per joint on every physics substep.
  local outputs = state.scratchAngleOutputs or {}
  state.scratchAngleOutputs = state.offsets or {}
  local diagnostics = collectDiagnostics and {} or nil
  local workingPoints = copyPointsInto(state.currentPoints, state.scratchWorkingPoints)
  state.scratchWorkingPoints = workingPoints
  local workingRoot = workingPoints[1] or vector(0, 0, 0)
  local baseRoot = basePoints[1]
  workingRoot.x, workingRoot.y, workingRoot.z = baseRoot.x, baseRoot.y, baseRoot.z
  workingPoints[1] = workingRoot
  for index = 1, #state.linkKeys do
    local link = resolvedLinks and resolvedLinks[index] or linkSettings(settings, index)
    local maxAngle = math.rad(clamp(tonumber(link.maxAngle) or 12, 0, 45))
    local maxSpeed = math.rad(clamp(tonumber(link.maxAngularSpeed) or 120, 0, 240))
    local baseFirst, baseSecond = basePoints[index], basePoints[index + 1]
    local baseX, baseY, baseZ = baseSecond.x - baseFirst.x, baseSecond.y - baseFirst.y, baseSecond.z - baseFirst.z
    local baseLength = math.sqrt(math.max(0, baseX * baseX + baseY * baseY + baseZ * baseZ))
    if baseLength < 0.000001 then
      baseX, baseY, baseZ = 0, -1, 0
    else
      baseX, baseY, baseZ = baseX / baseLength, baseY / baseLength, baseZ / baseLength
    end
    local simulatedFirst, simulatedSecond = workingPoints[index], workingPoints[index + 1]
    local simX, simY, simZ = simulatedSecond.x - simulatedFirst.x,
      simulatedSecond.y - simulatedFirst.y, simulatedSecond.z - simulatedFirst.z
    local simLength = math.sqrt(math.max(0, simX * simX + simY * simY + simZ * simZ))
    if simLength < 0.000001 then
      simX, simY, simZ = 0, -1, 0
    else
      simX, simY, simZ = simX / simLength, simY / simLength, simZ / simLength
    end
    local axisX, axisY, axisZ = baseY * simZ - baseZ * simY,
      baseZ * simX - baseX * simZ, baseX * simY - baseY * simX
    local axisLength = math.sqrt(math.max(0, axisX * axisX + axisY * axisY + axisZ * axisZ))
    local cosine = clamp(baseX * simX + baseY * simY + baseZ * simZ, -1, 1)
    local angle = math.acos(cosine)
    local requestedX, requestedY, requestedZ = 0, 0, 0
    if axisLength < 0.000001 or angle < 0.000001 then
      if cosine < 0 then
        local fallbackX, fallbackY, fallbackZ
        if math.abs(baseX) < 0.8 then fallbackX, fallbackY, fallbackZ = 1, 0, 0
        else fallbackX, fallbackY, fallbackZ = 0, 0, 1 end
        axisX, axisY, axisZ = baseY * fallbackZ - baseZ * fallbackY,
          baseZ * fallbackX - baseX * fallbackZ, baseX * fallbackY - baseY * fallbackX
        axisLength = math.sqrt(math.max(0, axisX * axisX + axisY * axisY + axisZ * axisZ))
        if axisLength < 0.000001 then axisX, axisY, axisZ = 0, 0, 1
        else axisX, axisY, axisZ = axisX / axisLength, axisY / axisLength, axisZ / axisLength end
        requestedX, requestedY, requestedZ = axisX * angle, axisY * angle, axisZ * angle
      end
    else
      local angleScale = angle / axisLength
      requestedX, requestedY, requestedZ = axisX * angleScale, axisY * angleScale, axisZ * angleScale
    end
    local hingeX, hingeY, hingeZ
    if link.limitType == "hinge" then
      local hinge = hingeAxis(vector(baseX, baseY, baseZ), link.limitRotation)
      hingeX, hingeY, hingeZ = hinge.x, hinge.y, hinge.z
      local projection = clamp(requestedX * hingeX + requestedY * hingeY + requestedZ * hingeZ,
        -maxAngle, maxAngle)
      requestedX, requestedY, requestedZ = hingeX * projection, hingeY * projection, hingeZ * projection
    elseif link.limitType ~= "none" then
      local requestedLength = math.sqrt(math.max(0,
        requestedX * requestedX + requestedY * requestedY + requestedZ * requestedZ))
      if requestedLength > maxAngle and requestedLength > 0.000001 then
        local factor = maxAngle / requestedLength
        requestedX, requestedY, requestedZ = requestedX * factor, requestedY * factor, requestedZ * factor
      end
    end

    local previous = state.offsets[index]
    local previousX = finite(previous and previous.x) and previous.x or 0
    local previousY = finite(previous and previous.y) and previous.y or 0
    local previousZ = finite(previous and previous.z) and previous.z or 0
    local deltaX, deltaY, deltaZ = requestedX - previousX, requestedY - previousY, requestedZ - previousZ
    local deltaLength = math.sqrt(math.max(0, deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ))
    local maxDelta = maxSpeed * stepDt
    if deltaLength > maxDelta and deltaLength > 0.000001 then
      local factor = maxDelta / deltaLength
      deltaX, deltaY, deltaZ = deltaX * factor, deltaY * factor, deltaZ * factor
    end
    local appliedX, appliedY, appliedZ = previousX + deltaX, previousY + deltaY, previousZ + deltaZ
    if hingeX then
      local projection = clamp(appliedX * hingeX + appliedY * hingeY + appliedZ * hingeZ, -maxAngle, maxAngle)
      appliedX, appliedY, appliedZ = hingeX * projection, hingeY * projection, hingeZ * projection
    elseif link.limitType ~= "none" then
      local appliedLength = math.sqrt(math.max(0, appliedX * appliedX + appliedY * appliedY + appliedZ * appliedZ))
      if appliedLength > maxAngle and appliedLength > 0.000001 then
        local factor = maxAngle / appliedLength
        appliedX, appliedY, appliedZ = appliedX * factor, appliedY * factor, appliedZ * factor
      end
    end
    local appliedLength = math.sqrt(math.max(0, appliedX * appliedX + appliedY * appliedY + appliedZ * appliedZ))
    local directionX, directionY, directionZ = baseX, baseY, baseZ
    if appliedLength >= 0.000001 then
      local rotX, rotY, rotZ = appliedX / appliedLength, appliedY / appliedLength, appliedZ / appliedLength
      local cosineRotation, sineRotation = math.cos(appliedLength), math.sin(appliedLength)
      local crossX, crossY, crossZ = rotY * baseZ - rotZ * baseY,
        rotZ * baseX - rotX * baseZ, rotX * baseY - rotY * baseX
      local projection = rotX * baseX + rotY * baseY + rotZ * baseZ
      local axisScale = projection * (1 - cosineRotation)
      directionX = baseX * cosineRotation + crossX * sineRotation + rotX * axisScale
      directionY = baseY * cosineRotation + crossY * sineRotation + rotY * axisScale
      directionZ = baseZ * cosineRotation + crossZ * sineRotation + rotZ * axisScale
      local directionLength = math.sqrt(math.max(0,
        directionX * directionX + directionY * directionY + directionZ * directionZ))
      if directionLength >= 0.000001 then
        directionX, directionY, directionZ = directionX / directionLength,
          directionY / directionLength, directionZ / directionLength
      else
        directionX, directionY, directionZ = baseX, baseY, baseZ
      end
    end
    local point = workingPoints[index + 1] or vector(0, 0, 0)
    point.x = workingPoints[index].x + directionX * restLengths[index]
    point.y = workingPoints[index].y + directionY * restLengths[index]
    point.z = workingPoints[index].z + directionZ * restLengths[index]
    workingPoints[index + 1] = point
    local output = outputs[index] or vector(0, 0, 0)
    output.x, output.y, output.z = appliedX, appliedY, appliedZ
    outputs[index] = output
  end

  -- Per-link limits alone can accumulate into a full curl on long chains.
  -- Restrict the sum of absolute offsets while preserving the per-link speed cap.
  local chainBendLimit = math.rad(clamp(tonumber(settings.chainBendLimit) or 180, 0, 360))
  local requestedTotal = 0
  local previousTotal = 0
  for index, applied in ipairs(outputs) do
    requestedTotal = requestedTotal + math.sqrt(math.max(0,
      applied.x * applied.x + applied.y * applied.y + applied.z * applied.z))
    local previous = state.offsets[index]
    local px = finite(previous and previous.x) and previous.x or 0
    local py = finite(previous and previous.y) and previous.y or 0
    local pz = finite(previous and previous.z) and previous.z or 0
    previousTotal = previousTotal + math.sqrt(math.max(0, px * px + py * py + pz * pz))
  end
  if requestedTotal > chainBendLimit + 0.000001 then
    if previousTotal <= chainBendLimit + 0.000001 then
      -- Interpolate from the previous valid pose toward the requested one. A
      -- binary search finds the largest step that stays inside the chain budget.
      local low, high = 0, 1
      for _ = 1, 14 do
        local alpha = (low + high) * 0.5
        local total = 0
        for index, requested in ipairs(outputs) do
          local previous = state.offsets[index]
          local px = finite(previous and previous.x) and previous.x or 0
          local py = finite(previous and previous.y) and previous.y or 0
          local pz = finite(previous and previous.z) and previous.z or 0
          local x = px + (requested.x - px) * alpha
          local y = py + (requested.y - py) * alpha
          local z = pz + (requested.z - pz) * alpha
          total = total + math.sqrt(math.max(0, x * x + y * y + z * z))
        end
        if total <= chainBendLimit then low = alpha else high = alpha end
      end
      for index, requested in ipairs(outputs) do
        local previous = state.offsets[index]
        local px = finite(previous and previous.x) and previous.x or 0
        local py = finite(previous and previous.y) and previous.y or 0
        local pz = finite(previous and previous.z) and previous.z or 0
        requested.x = px + (requested.x - px) * low
        requested.y = py + (requested.y - py) * low
        requested.z = pz + (requested.z - pz) * low
      end
    else
      -- If the user lowers the configured limit below the current pose, enforce
      -- it immediately; ordinary simulation steps use the speed-preserving path above.
      local factor = chainBendLimit / math.max(requestedTotal, 0.000001)
      for _, requested in ipairs(outputs) do
        requested.x, requested.y, requested.z = requested.x * factor, requested.y * factor, requested.z * factor
      end
    end
  end

  local currentRoot = state.currentPoints[1] or vector(0, 0, 0)
  currentRoot.x, currentRoot.y, currentRoot.z = basePoints[1].x, basePoints[1].y, basePoints[1].z
  state.currentPoints[1] = currentRoot
  for index, applied in ipairs(outputs) do
    local first, second = basePoints[index], basePoints[index + 1]
    local baseX, baseY, baseZ = second.x - first.x, second.y - first.y, second.z - first.z
    local baseLength = math.sqrt(math.max(0, baseX * baseX + baseY * baseY + baseZ * baseZ))
    if baseLength < 0.000001 then baseX, baseY, baseZ = 0, -1, 0
    else baseX, baseY, baseZ = baseX / baseLength, baseY / baseLength, baseZ / baseLength end
    local appliedLength = math.sqrt(math.max(0, applied.x * applied.x + applied.y * applied.y + applied.z * applied.z))
    local directionX, directionY, directionZ = baseX, baseY, baseZ
    if appliedLength >= 0.000001 then
      local rotX, rotY, rotZ = applied.x / appliedLength, applied.y / appliedLength, applied.z / appliedLength
      local cosineRotation, sineRotation = math.cos(appliedLength), math.sin(appliedLength)
      local crossX, crossY, crossZ = rotY * baseZ - rotZ * baseY,
        rotZ * baseX - rotX * baseZ, rotX * baseY - rotY * baseX
      local projection = rotX * baseX + rotY * baseY + rotZ * baseZ
      local axisScale = projection * (1 - cosineRotation)
      directionX = baseX * cosineRotation + crossX * sineRotation + rotX * axisScale
      directionY = baseY * cosineRotation + crossY * sineRotation + rotY * axisScale
      directionZ = baseZ * cosineRotation + crossZ * sineRotation + rotZ * axisScale
      local directionLength = math.sqrt(math.max(0,
        directionX * directionX + directionY * directionY + directionZ * directionZ))
      if directionLength >= 0.000001 then
        directionX, directionY, directionZ = directionX / directionLength,
          directionY / directionLength, directionZ / directionLength
      else
        directionX, directionY, directionZ = baseX, baseY, baseZ
      end
    end
    local currentPoint = state.currentPoints[index + 1] or vector(0, 0, 0)
    currentPoint.x = state.currentPoints[index].x + directionX * restLengths[index]
    currentPoint.y = state.currentPoints[index].y + directionY * restLengths[index]
    currentPoint.z = state.currentPoints[index].z + directionZ * restLengths[index]
    state.currentPoints[index + 1] = currentPoint
    local previous = state.offsets[index]
    local previousX = finite(previous and previous.x) and previous.x or 0
    local previousY = finite(previous and previous.y) and previous.y or 0
    local previousZ = finite(previous and previous.z) and previous.z or 0
    local dx, dy, dz = applied.x - previousX, applied.y - previousY, applied.z - previousZ
    if diagnostics then
      diagnostics[index] = {
        angle = appliedLength,
        speed = stepDt > 0 and math.sqrt(math.max(0, dx * dx + dy * dy + dz * dz)) / stepDt or 0,
      }
    end
  end
  return outputs, diagnostics
end

function physicsCore.newChainState(linkKeys, basePoints)
  local keys, points = {}, copyPoints(basePoints)
  for index, key in ipairs(linkKeys or {}) do keys[index] = key end
  if #points ~= #keys + 1 then
    points = {}
    for index = 1, #keys + 1 do points[index] = vector(0, -(index - 1), 0) end
  end
  local offsets, diagnostics = {}, {}
  for index = 1, #keys do
    offsets[index] = vector(0, 0, 0)
    diagnostics[index] = { angle = 0, speed = 0 }
  end
  return {
    linkKeys = keys,
    currentPoints = copyPoints(points),
    previousPoints = copyPoints(points),
    renderPreviousOffsets = copyPoints(offsets),
    offsets = offsets,
    previousBasePoints = copyPoints(points),
    scratchAirflowPositions = {},
    scratchAirflowPreviousPositions = {},
    scratchUnconstrainedPoints = {},
    cleanRestLengths = {},
    diagnostics = diagnostics,
    accumulator = 0,
    airflowVelocity = vector(0, 0, 0),
    rootAcceleration = vector(0, 0, 0),
    rootYawAcceleration = 0,
    airflowDiagnostics = {},
  }
end

function physicsCore.stepChain(state, input, animatedBasePoints, restLengths, settings, dt, collectDiagnostics, cachedResolvedLinks)
  input = input or {}
  settings = settings or {}
  if collectDiagnostics == nil then collectDiagnostics = true end
  collectDiagnostics = collectDiagnostics == true
  local linkCount = state and #(state.linkKeys or {}) or 0
  if linkCount == 0 or not validBase(animatedBasePoints, linkCount) then
    return state or physicsCore.newChainState({}, {}), {}, {}, "invalid chain base points"
  end
  state = state or physicsCore.newChainState({}, animatedBasePoints)
  -- The studio builds a fresh animated base for this call and the solver never
  -- writes to it, so keep the input instead of allocating another full copy.
  local base = animatedBasePoints
  state.cleanRestLengths = state.cleanRestLengths or {}
  local lengths = cleanLengths(restLengths, linkCount, base, state.cleanRestLengths)
  -- Resolve chain inheritance and per-link overrides once for this frame. The
  -- same immutable settings are then reused by every fixed substep and clamp pass.
  local resolvedLinks = cachedResolvedLinks
  if type(resolvedLinks) ~= "table" or #resolvedLinks ~= linkCount then
    resolvedLinks = physicsCore.resolveLinks(settings, linkCount)
  end
  for _, link in ipairs(resolvedLinks) do
    local source = link.gravitySource or link.gravity
    if link.gravitySpace == "world" then
      link.gravity = writeGravityInChainFrame(settings.gravityFrame, source, link.gravity)
    elseif type(source) == "table" then
      link.gravity = writeGravityInChainFrame(nil, source, link.gravity)
    end
  end
  local totalChainLength = 0
  for _, restLength in ipairs(lengths) do totalChainLength = totalChainLength + restLength end
  local frameDelta = clamp(tonumber(dt) or MAX_FRAME_DT, 0, MAX_FRAME_DT)
  local yawDelta = finite(input.yawDelta) and clamp(input.yawDelta, -math.pi / 2, math.pi / 2) or 0
  local movementDelta = safeVector(input.rootDelta)
  local targetRootAcceleration = clampMagnitude(safeVector(input.rootAcceleration), ROOT_INERTIA_MAX_ACCELERATION)
  local targetRootYawAcceleration = clamp(tonumber(input.rootYawAcceleration) or 0,
    -ROOT_INERTIA_MAX_YAW_ACCELERATION, ROOT_INERTIA_MAX_YAW_ACCELERATION)
  local targetAirflowVelocity = vector(0, 0, 0)
  if frameDelta > 0.000001 then
    targetAirflowVelocity = rotateYaw(scale(movementDelta, 1 / frameDelta), yawDelta)
    targetAirflowVelocity = clampMagnitude(targetAirflowVelocity, AIRFLOW_MAX_SPEED)
  end

  -- Re-express the simulated points in the current avatar frame. Yaw changes rotate
  -- the stored pose; linear motion is handled by relative airflow below. Applying
  -- rootDelta as a position shift here every tick accumulates an unbounded drift.
  if validBase(state.previousBasePoints, linkCount) then
    local oldAnchor = safeVector(state.previousBasePoints[1])
    local newAnchor = safeVector(base[1])
    for index = 2, linkCount + 1 do
      local link = resolvedLinks[index - 1]
      local rotationInfluence = 1 - clamp(tonumber(link.immobile) or 0.65, 0, 1)
      local rotation = yawDelta * rotationInfluence
      local currentLocal = sub(safeVector(state.currentPoints[index]), oldAnchor)
      local previousLocal = sub(safeVector(state.previousPoints[index]), oldAnchor)
      currentLocal = rotateYaw(currentLocal, rotation)
      previousLocal = rotateYaw(previousLocal, rotation)
      state.currentPoints[index] = add(newAnchor, currentLocal)
      state.previousPoints[index] = add(newAnchor, previousLocal)
    end
    state.currentPoints[1] = newAnchor
    state.previousPoints[1] = newAnchor
  else
    state.currentPoints = copyPoints(base)
    state.previousPoints = copyPoints(base)
  end
  state.previousBasePoints = copyPointsInto(base, state.previousBasePoints)
  -- The filtered movement vector is stored in avatar-local coordinates too.
  state.airflowVelocity = rotateYaw(safeVector(state.airflowVelocity), yawDelta)
  state.rootAcceleration = rotateYaw(safeVector(state.rootAcceleration), yawDelta)
  state.renderPreviousOffsets = copyPointsInto(state.offsets, state.renderPreviousOffsets)
  state.accumulator = math.min((state.accumulator or 0) + frameDelta, MAX_FRAME_DT)

  -- Gravity values are blocks/s²; chain points are ModelPart units.
  local maxSteps = math.max(1, math.floor(MAX_FRAME_DT / FIXED_DT + 0.5))
  local steps = 0

  while state.accumulator >= FIXED_DT and steps < maxSteps do
    local stepDt = FIXED_DT
    -- The UI only displays diagnostics for the latest completed substep.
    -- Avoid building them for intermediate steps and while the panel is closed.
    local hasAnotherStep = state.accumulator - FIXED_DT >= FIXED_DT and steps + 1 < maxSteps
    local collectStepDiagnostics = collectDiagnostics and not hasAnotherStep
    local airflowDiagnostics = collectStepDiagnostics and {} or nil
    local airflowBlend = 1 - math.exp(-stepDt / AIRFLOW_RESPONSE_SECONDS)
    local inertiaBlend = 1 - math.exp(-stepDt / ROOT_INERTIA_RESPONSE_SECONDS)
    state.airflowVelocity = add(safeVector(state.airflowVelocity),
      scale(sub(targetAirflowVelocity, safeVector(state.airflowVelocity)), airflowBlend))
    state.rootAcceleration = add(safeVector(state.rootAcceleration),
      scale(sub(targetRootAcceleration, safeVector(state.rootAcceleration)), inertiaBlend))
    local previousYawAcceleration = tonumber(state.rootYawAcceleration) or 0
    state.rootYawAcceleration = previousYawAcceleration
      + (targetRootYawAcceleration - previousYawAcceleration) * inertiaBlend
    state.currentPoints[1] = safeVector(base[1])
    local airflowPositions = copyPointsInto(state.currentPoints, state.scratchAirflowPositions)
    local airflowPreviousPositions = copyPointsInto(state.previousPoints, state.scratchAirflowPreviousPositions)
    airflowPositions[1] = safeVector(base[1])
    airflowPreviousPositions[1] = safeVector(base[1])
    local apparentAirVelocity = scale(state.airflowVelocity, -MODEL_UNITS_PER_BLOCK)

    for index = 2, linkCount + 1 do
      local link = resolvedLinks[index - 1]
      local current = safeVector(state.currentPoints[index])
      local previous = safeVector(state.previousPoints[index])
      local pull = clamp(tonumber(link.pull) or 12, 0, 40)
      local damping = clamp(tonumber(link.damping) or 6, 0, 20)
      local spring = clamp(tonumber(link.spring) or 0.25, 0, 1)
      local gravity = scale(safeVector(link.gravity), MODEL_UNITS_PER_BLOCK)
      local immobile = clamp(tonumber(link.immobile) or 0.65, 0, 1)
      local inertiaStrength = clamp(tonumber(link.avatarInertia) or 1, 0, 2) * (1 - immobile)
      local airflowStrength = clamp(tonumber(link.movementDrag) or 0, 0, 1)
        * (1 - immobile)
      local linkIndex = index - 1
      local needAirflowMetrics = airflowStrength > 0 or airflowDiagnostics ~= nil
      local segmentDirection
      if needAirflowMetrics or inertiaStrength > 0 then
        segmentDirection = normalize(
          sub(airflowPositions[index], airflowPositions[linkIndex]),
          getDirection(base, linkIndex))
      end
      local crossFlowVelocity = ZERO_VECTOR
      local crossFlowSpeed = 0
      local airflowSpeed = 0
      if needAirflowMetrics then
        local parentVelocity = scale(sub(airflowPositions[linkIndex], airflowPreviousPositions[linkIndex]), 1 / stepDt)
        local childVelocity = scale(sub(airflowPositions[index], airflowPreviousPositions[index]), 1 / stepDt)
        local segmentVelocity = scale(add(parentVelocity, childVelocity), 0.5)
        local relativeAirVelocity = sub(apparentAirVelocity, segmentVelocity)
        crossFlowVelocity = sub(relativeAirVelocity,
          scale(segmentDirection, dot(relativeAirVelocity, segmentDirection)))
        crossFlowSpeed = length(crossFlowVelocity)
        airflowSpeed = crossFlowSpeed / MODEL_UNITS_PER_BLOCK
      end
      local airflow = ZERO_VECTOR
      local airflowAcceleration = 0
      local avatarAcceleration = ZERO_VECTOR
      local avatarInertiaAcceleration = 0
      if airflowStrength > 0 and crossFlowSpeed > 0.000001 then
        local speedFactor = clamp(airflowSpeed / AIRFLOW_REFERENCE_SPEED, 0, 1)
        local tipWeight = (linkIndex - 1) / math.max(1, linkCount - 1)
        tipWeight = 0.2 + 0.8 * tipWeight
        -- Bound the static offset caused by the airflow relative to the whole
        -- chain, while leaving the strength slider useful at ordinary speeds.
        local chainAccelerationCap = AIRFLOW_MAX_ACCELERATION
        if pull > 0.000001 then
          chainAccelerationCap = math.min(chainAccelerationCap,
            pull * totalChainLength * AIRFLOW_MAX_CHAIN_DEFLECTION / MODEL_UNITS_PER_BLOCK)
        end
        airflowAcceleration = math.min(AIRFLOW_MAX_ACCELERATION
          * airflowStrength * speedFactor * speedFactor * tipWeight, chainAccelerationCap)
        airflow = scale(crossFlowVelocity, airflowAcceleration * MODEL_UNITS_PER_BLOCK / crossFlowSpeed)
      end
      if inertiaStrength > 0 then
        local rootRelativePosition = scale(sub(current, base[1]), 1 / MODEL_UNITS_PER_BLOCK)
        local rotationalAcceleration = vector(
          -state.rootYawAcceleration * rootRelativePosition.z,
          0,
          state.rootYawAcceleration * rootRelativePosition.x)
        local apparentAcceleration = clampMagnitude(add(
          scale(state.rootAcceleration, -inertiaStrength),
          scale(rotationalAcceleration, inertiaStrength)), ROOT_INERTIA_MAX_ACCELERATION)
        avatarAcceleration = sub(apparentAcceleration,
          scale(segmentDirection, dot(apparentAcceleration, segmentDirection)))
        avatarInertiaAcceleration = length(avatarAcceleration)
        avatarAcceleration = scale(avatarAcceleration, MODEL_UNITS_PER_BLOCK)
      end
      if airflowDiagnostics then
        airflowDiagnostics[index - 1] = {
          speed = airflowSpeed,
          acceleration = airflowAcceleration,
          avatarInertiaAcceleration = avatarInertiaAcceleration,
        }
      end
      -- Spring controls how underdamped the return is (and therefore how much it
      -- overshoots); Damping adds independent friction to the saved velocity.
      local springDamping = 2 * math.sqrt(pull) * (1 - spring)
      local velocity = scale(sub(current, previous), math.exp(-(damping + springDamping) * stepDt))
      local gravityScale = 1
      if link.gravityFalloff ~= nil then
        local linkIndex = math.min(linkCount, index - 1)
        local deviation = length(angleForLink(state.currentPoints, base, linkIndex))
        local maxAngle = math.rad(math.max(1, tonumber(link.maxAngle) or 12))
        local falloff = clamp(tonumber(link.gravityFalloff) or 0, 0, 1)
        gravityScale = 1 - falloff * (1 - clamp(deviation / maxAngle, 0, 1))
      end
      local external = add(add(scale(gravity, gravityScale), airflow), avatarAcceleration)
      local springAcceleration = scale(sub(base[index], current), pull)
      local nextPoint = add(add(current, velocity), scale(add(external, springAcceleration), stepDt * stepDt))
      state.previousPoints[index] = current
      state.currentPoints[index] = safeVector(nextPoint)
    end

    local unconstrainedPoints = copyPointsInto(state.currentPoints, state.scratchUnconstrainedPoints)
    enforceLengths(state.currentPoints, lengths)
    state.offsets, state.diagnostics = clampLinkAngles(state, base, lengths, settings,
      stepDt, resolvedLinks, collectStepDiagnostics)
    state.airflowDiagnostics = airflowDiagnostics
    if collectStepDiagnostics then
      for index, diagnostic in ipairs(state.diagnostics) do
        local airflowState = airflowDiagnostics[index] or {}
        diagnostic.airflowSpeed = tonumber(airflowState.speed) or length(state.airflowVelocity)
        diagnostic.airflowAcceleration = tonumber(airflowState.acceleration) or 0
        diagnostic.avatarInertiaAcceleration = tonumber(airflowState.avatarInertiaAcceleration) or 0
      end
    end
    -- Move both Verlet samples by each constraint correction so the constraint
    -- solver does not inject a fake velocity into the next substep.
    for index = 2, linkCount + 1 do
      local correction = sub(state.currentPoints[index], unconstrainedPoints[index])
      state.previousPoints[index] = add(state.previousPoints[index], correction)
    end
    state.accumulator = state.accumulator - FIXED_DT
    steps = steps + 1
  end

  if steps == 0 then
    state.currentPoints[1] = safeVector(base[1])
    state.offsets, state.diagnostics = clampLinkAngles(state, base, lengths, settings,
      math.max(frameDelta, 0.0001), resolvedLinks, collectDiagnostics)
    if collectDiagnostics then
      for index, diagnostic in ipairs(state.diagnostics) do
        local airflowState = state.airflowDiagnostics and state.airflowDiagnostics[index] or {}
        diagnostic.airflowSpeed = tonumber(airflowState.speed) or length(state.airflowVelocity)
        diagnostic.airflowAcceleration = tonumber(airflowState.acceleration) or 0
        diagnostic.avatarInertiaAcceleration = tonumber(airflowState.avatarInertiaAcceleration) or 0
      end
    else
      state.airflowDiagnostics = nil
    end
  end
  return state, state.offsets, state.diagnostics
end

function physicsCore.interpolateOffsets(state, alpha, result)
  alpha = clamp(tonumber(alpha) or 1, 0, 1)
  result = result or {}
  for index, current in ipairs(state and state.offsets or {}) do
    local previous = state.renderPreviousOffsets and state.renderPreviousOffsets[index] or current
    local px = finite(previous and previous.x) and previous.x or 0
    local py = finite(previous and previous.y) and previous.y or 0
    local pz = finite(previous and previous.z) and previous.z or 0
    local cx = finite(current and current.x) and current.x or 0
    local cy = finite(current and current.y) and current.y or 0
    local cz = finite(current and current.z) and current.z or 0
    local output = result[index]
    if output then
      output.x = px * (1 - alpha) + cx * alpha
      output.y = py * (1 - alpha) + cy * alpha
      output.z = pz * (1 - alpha) + cz * alpha
    else
      result[index] = vector(
        px * (1 - alpha) + cx * alpha,
        py * (1 - alpha) + cy * alpha,
        pz * (1 - alpha) + cz * alpha)
    end
  end
  for index = #(state and state.offsets or {}) + 1, #result do result[index] = nil end
  return result
end

return physicsCore
