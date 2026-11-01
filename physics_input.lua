local physicsInput = {}
physicsInput.__index = physicsInput

-- A single large discontinuity is treated as a teleport or respawn, not motion.
local MAX_ROOT_STEP = 3
local MAX_YAW_STEP = 90
local MAX_ROOT_ACCELERATION = 32
local MAX_ROOT_YAW_ACCELERATION = math.rad(720)
local DEFAULT_SAMPLE_DT = 1 / 20

local function safeMethod(object, method)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, object)
  if ok then return value end
  return nil
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function components(vector)
  if not vector then return nil end
  local x, y, z = vector.x, vector.y, vector.z
  if not finite(x) or not finite(y) or not finite(z) then return nil end
  return x, y, z
end

local function wrapDegrees(angle)
  return (angle + 180) % 360 - 180
end

local function zeroInput(available)
  return {
    rootDelta = { x = 0, y = 0, z = 0 },
    rootAcceleration = { x = 0, y = 0, z = 0 },
    rootYawAcceleration = 0,
    yawDelta = 0,
    available = available == true,
  }
end

local function clampMagnitude(value, maximum)
  local magnitude = math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
  if magnitude <= maximum or magnitude < 0.000001 then return value end
  local factor = maximum / magnitude
  return { x = value.x * factor, y = value.y * factor, z = value.z * factor }
end

local function toAvatarLocal(worldVector, yawDegrees)
  local yaw = math.rad(yawDegrees)
  local cosine, sine = math.cos(yaw), math.sin(yaw)
  return {
    x = -worldVector.x * cosine - worldVector.z * sine,
    y = worldVector.y,
    z = worldVector.x * sine - worldVector.z * cosine,
  }
end

function physicsInput.new()
  return setmetatable({
    previousPosition = nil,
    previousYaw = nil,
    previousWorldVelocity = nil,
    previousYawVelocity = nil,
  }, physicsInput)
end

function physicsInput:reset()
  self.previousPosition = nil
  self.previousYaw = nil
  self.previousWorldVelocity = nil
  self.previousYawVelocity = nil
end

function physicsInput:sample(player, bodyYaw, dt)
  local position = safeMethod(player, "getPos")
  local x, y, z = components(position)
  local yaw = tonumber(bodyYaw)
  if not x or not finite(yaw) then
    self:reset()
    return zeroInput(false)
  end

  local sampleDt = tonumber(dt)
  if not finite(sampleDt) or sampleDt <= 0 then sampleDt = DEFAULT_SAMPLE_DT end
  sampleDt = math.max(1 / 240, math.min(0.25, sampleDt))

  local rootDelta = { x = 0, y = 0, z = 0 }
  local rootAcceleration = { x = 0, y = 0, z = 0 }
  local rootYawAcceleration = 0
  local yawDelta = 0
  local previousPosition = self.previousPosition
  local previousYaw = self.previousYaw
  local nextWorldVelocity
  local nextYawVelocity
  if previousPosition and previousYaw then
    local worldX = x - previousPosition.x
    local worldY = y - previousPosition.y
    local worldZ = z - previousPosition.z
    local deltaYaw = wrapDegrees(yaw - previousYaw)
    local distance = math.sqrt(worldX * worldX + worldY * worldY + worldZ * worldZ)

    -- Teleports, respawns, or abrupt camera/body snaps must not launch the chain.
    if distance <= MAX_ROOT_STEP and math.abs(deltaYaw) <= MAX_YAW_STEP then
      local previousYawRad = math.rad(previousYaw)
      local cosine, sine = math.cos(previousYawRad), math.sin(previousYawRad)
      rootDelta = {
        x = -worldX * cosine - worldZ * sine,
        y = worldY,
        -- The avatar's model forward is local -Z (Figura's world-part example
        -- uses 180 degrees minus bodyYaw), so forward travel maps to negative Z.
        z = worldX * sine - worldZ * cosine,
      }
      yawDelta = math.rad(deltaYaw)
      local yawVelocity = yawDelta / sampleDt
      if self.previousYawVelocity then
        rootYawAcceleration = math.max(-MAX_ROOT_YAW_ACCELERATION,
          math.min(MAX_ROOT_YAW_ACCELERATION,
            (yawVelocity - self.previousYawVelocity) / sampleDt))
      end
      nextYawVelocity = yawVelocity

      local worldVelocity = {
        x = worldX / sampleDt,
        y = worldY / sampleDt,
        z = worldZ / sampleDt,
      }
      if self.previousWorldVelocity then
        local worldAcceleration = {
          x = (worldVelocity.x - self.previousWorldVelocity.x) / sampleDt,
          y = (worldVelocity.y - self.previousWorldVelocity.y) / sampleDt,
          z = (worldVelocity.z - self.previousWorldVelocity.z) / sampleDt,
        }
        rootAcceleration = clampMagnitude(toAvatarLocal(worldAcceleration, yaw), MAX_ROOT_ACCELERATION)
      end
      nextWorldVelocity = worldVelocity
    end
  else
    -- Treat the first valid position sample as the start of a motion history.
    nextWorldVelocity = { x = 0, y = 0, z = 0 }
    nextYawVelocity = 0
  end

  self.previousPosition = { x = x, y = y, z = z }
  self.previousYaw = yaw
  self.previousWorldVelocity = nextWorldVelocity
  self.previousYawVelocity = nextYawVelocity
  return {
    rootDelta = rootDelta,
    rootAcceleration = rootAcceleration,
    rootYawAcceleration = rootYawAcceleration,
    yawDelta = yawDelta,
    available = true,
  }
end

return physicsInput
