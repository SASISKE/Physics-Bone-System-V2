local configApi = {}

local CONFIG_KEY = "physics_bone_v2"
local PRESET_MODULE = "physics_bone_preset"
local PRESET_ROOT = "PhysicsBoneV2/Characters"

local DEFAULT_SETTINGS = {
  enabled = true,
  gravitySpace = "world",
  gravity = { x = 0, y = -9.81, z = 0 },
  gravityTiltResponse = 0.0,
  gravityFalloff = 0.0,
  -- Balanced starter values: visible secondary motion without disabling pose follow.
  pull = 60.0,
  spring = 0.22,
  damping = 12.0,
  mass = 1.0,
  tipMass = 1.0,
  bendStiffness = 0.75,
  rootMotionResponse = 0.45,
  motionDrag = 0.25,
  avatarMotionResponse = 0.55,
  maxLinearSpeed = 24.0,
  joint = {
    type = "cone",
    axis = { x = 0, y = 1, z = 0 },
    angle = 20.0,
    angularSpeed = 180.0,
  },
  collision = {
    enabled = false,
    avatar = true,
    world = false,
    self = false,
    radius = 0.5,
    friction = 0.25,
    restitution = 0.0,
    maxBlockQueries = 64,
    maxSelfPairs = 2048,
    iterations = 2,
  },
}

local RANGES = {
  gravity = { -40, 40 }, gravityTiltResponse = { 0, 1 }, gravityFalloff = { 0, 1 }, pull = { 0, 500 },
  tipMass = { 1, 6 },
  spring = { 0, 1 }, damping = { 0, 24 }, mass = { 0.05, 20 },
  bendStiffness = { 0, 24 },
  rootMotionResponse = { 0, 2 }, motionDrag = { 0, 2 }, avatarMotionResponse = { 0, 2 },
  maxLinearSpeed = { 0, 60 }, angle = { 0, 180 }, angularSpeed = { 0, 720 },
  collisionRadius = { 0.05, 16 }, collisionFriction = { 0, 1 }, collisionRestitution = { 0, 1 },
  collisionQueries = { 0, 256 }, collisionSelfPairs = { 0, 16384 }, collisionIterations = { 1, 4 },
}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function configApi.clone(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return nil end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do result[key] = configApi.clone(item, seen) end
  seen[value] = nil
  return result
end

function configApi.defaults()
  return { schema = 1, components = {}, diagnostics = false }
end

local function clamp(value, range, fallback, label, warnings)
  value = tonumber(value)
  if not finite(value) then
    warnings[#warnings + 1] = label .. ": заменено значением по умолчанию"
    return fallback
  end
  local clean = math.max(range[1], math.min(range[2], value))
  if clean ~= value then warnings[#warnings + 1] = label .. ": ограничено допустимым диапазоном" end
  return clean
end

local function cleanPath(path)
  if type(path) ~= "table" or #path == 0 or #path > 128 then return nil end
  local result = {}
  for index, segment in ipairs(path) do
    if type(segment) ~= "table" or type(segment.name) ~= "string"
      or #segment.name > 128 or not finite(segment.sameNameIndex) or segment.sameNameIndex < 1 then return nil end
    result[index] = { name = segment.name, sameNameIndex = math.floor(segment.sameNameIndex) }
  end
  return result
end

local function cleanSettings(raw, warnings, label)
  raw = type(raw) == "table" and raw or {}
  local result = configApi.clone(DEFAULT_SETTINGS)
  result.enabled = raw.enabled ~= false
  result.gravitySpace = raw.gravitySpace == "local" and "local" or "world"
  local sourceGravity = type(raw.gravity) == "table" and raw.gravity or {}
  for _, axis in ipairs({ "x", "y", "z" }) do
    result.gravity[axis] = clamp(sourceGravity[axis], RANGES.gravity, DEFAULT_SETTINGS.gravity[axis], label .. " gravity." .. axis, warnings)
  end
  for _, field in ipairs({ "gravityTiltResponse", "gravityFalloff", "pull", "spring", "damping", "mass", "tipMass", "bendStiffness", "rootMotionResponse", "motionDrag", "avatarMotionResponse", "maxLinearSpeed" }) do
    result[field] = clamp(raw[field], RANGES[field], DEFAULT_SETTINGS[field], label .. " " .. field, warnings)
  end
  local joint = type(raw.joint) == "table" and raw.joint or {}
  result.joint.type = (joint.type == "free" or joint.type == "cone" or joint.type == "hinge") and joint.type or "cone"
  local axis = type(joint.axis) == "table" and joint.axis or {}
  local axisLength = math.sqrt((tonumber(axis.x) or 0)^2 + (tonumber(axis.y) or 0)^2 + (tonumber(axis.z) or 0)^2)
  if not finite(axis.x) or not finite(axis.y) or not finite(axis.z) or not finite(axisLength) or axisLength < 0.001 then
    result.joint.axis = { x = 0, y = 1, z = 0 }
    warnings[#warnings + 1] = label .. " joint.axis: сброшена на локальную Y"
  else
    result.joint.axis = { x = axis.x / axisLength, y = axis.y / axisLength, z = axis.z / axisLength }
  end
  result.joint.angle = clamp(joint.angle, RANGES.angle, DEFAULT_SETTINGS.joint.angle, label .. " joint.angle", warnings)
  result.joint.angularSpeed = clamp(joint.angularSpeed, RANGES.angularSpeed, DEFAULT_SETTINGS.joint.angularSpeed, label .. " joint.angularSpeed", warnings)
  local collision = type(raw.collision) == "table" and raw.collision or {}
  result.collision.enabled = collision.enabled == true
  result.collision.avatar = collision.avatar ~= false
  result.collision.world = collision.world == true
  result.collision.self = collision.self == true
  result.collision.radius = clamp(collision.radius, RANGES.collisionRadius, DEFAULT_SETTINGS.collision.radius, label .. " collision.radius", warnings)
  result.collision.friction = clamp(collision.friction, RANGES.collisionFriction, DEFAULT_SETTINGS.collision.friction, label .. " collision.friction", warnings)
  result.collision.restitution = clamp(collision.restitution, RANGES.collisionRestitution, DEFAULT_SETTINGS.collision.restitution, label .. " collision.restitution", warnings)
  result.collision.maxBlockQueries = math.floor(clamp(collision.maxBlockQueries, RANGES.collisionQueries,
    DEFAULT_SETTINGS.collision.maxBlockQueries, label .. " collision.maxBlockQueries", warnings))
  result.collision.maxSelfPairs = math.floor(clamp(collision.maxSelfPairs, RANGES.collisionSelfPairs,
    DEFAULT_SETTINGS.collision.maxSelfPairs, label .. " collision.maxSelfPairs", warnings))
  result.collision.iterations = math.floor(clamp(collision.iterations, RANGES.collisionIterations,
    DEFAULT_SETTINGS.collision.iterations, label .. " collision.iterations", warnings))
  return result
end

local function cleanOverride(raw, warnings, label)
  local result = {}
  if type(raw) ~= "table" then return result end
  for _, field in ipairs({ "enabled", "gravitySpace" }) do
    if raw[field] ~= nil then
      if field == "enabled" then result.enabled = raw.enabled == true
      else result.gravitySpace = raw.gravitySpace == "local" and "local" or "world" end
    end
  end
  for _, field in ipairs({ "gravityTiltResponse", "gravityFalloff", "pull", "spring", "damping", "mass", "tipMass", "bendStiffness", "rootMotionResponse", "motionDrag", "avatarMotionResponse", "maxLinearSpeed" }) do
    if raw[field] ~= nil then
      result[field] = clamp(raw[field], RANGES[field], DEFAULT_SETTINGS[field], label .. " " .. field, warnings)
    end
  end
  if type(raw.gravity) == "table" then
    result.gravity = {}
    for _, axis in ipairs({ "x", "y", "z" }) do
      if raw.gravity[axis] ~= nil then result.gravity[axis] = clamp(raw.gravity[axis], RANGES.gravity, DEFAULT_SETTINGS.gravity[axis], label .. " gravity." .. axis, warnings) end
    end
  end
  if type(raw.joint) == "table" then
    result.joint = {}
    local joint = raw.joint
    if joint.type ~= nil then result.joint.type = (joint.type == "free" or joint.type == "cone" or joint.type == "hinge") and joint.type or "cone" end
    for _, field in ipairs({ "angle", "angularSpeed" }) do
      if joint[field] ~= nil then result.joint[field] = clamp(joint[field], RANGES[field], DEFAULT_SETTINGS.joint[field], label .. " joint." .. field, warnings) end
    end
    if type(joint.axis) == "table" then
      local axis = joint.axis
      local x, y, z = tonumber(axis.x), tonumber(axis.y), tonumber(axis.z)
      local size = math.sqrt((x or 0)^2 + (y or 0)^2 + (z or 0)^2)
      if finite(x) and finite(y) and finite(z) and finite(size) and size >= 0.001 then
        result.joint.axis = { x = x / size, y = y / size, z = z / size }
      end
    end
  end
  if type(raw.collision) == "table" then
    local collision = raw.collision
    result.collision = {}
    for _, field in ipairs({ "enabled", "avatar", "world", "self" }) do
      if collision[field] ~= nil then result.collision[field] = collision[field] == true end
    end
    for _, field in ipairs({ "radius", "friction", "restitution", "maxBlockQueries", "maxSelfPairs", "iterations" }) do
      if collision[field] ~= nil then
        local rangeKey = ({ radius = "collisionRadius", friction = "collisionFriction",
          restitution = "collisionRestitution", maxBlockQueries = "collisionQueries",
          maxSelfPairs = "collisionSelfPairs", iterations = "collisionIterations" })[field]
        result.collision[field] = clamp(collision[field], RANGES[rangeKey], DEFAULT_SETTINGS.collision[field],
          label .. " collision." .. field, warnings)
        if field == "maxBlockQueries" or field == "maxSelfPairs" or field == "iterations" then
          result.collision[field] = math.floor(result.collision[field])
        end
      end
    end
  end
  return result
end

function configApi.validate(raw)
  local clean, warnings = configApi.defaults(), {}
  if type(raw) ~= "table" then
    warnings[#warnings + 1] = "настройки v2 повреждены; загружены значения по умолчанию"
    return clean, warnings
  end
  if raw.schema ~= 1 then warnings[#warnings + 1] = "неизвестная версия схемы; используется схема 1" end
  clean.diagnostics = raw.diagnostics == true
  local roots = {}
  for index, source in ipairs(type(raw.components) == "table" and raw.components or {}) do
    if index > 64 then warnings[#warnings + 1] = "превышен лимит 64 компонентов"; break end
    if type(source) ~= "table" then
      warnings[#warnings + 1] = "компонент " .. index .. " пропущен: неверный формат"
    else
      local rootPath = cleanPath(source.rootPath)
      local identity = rootPath and require("physics_bone_registry").pathKey(rootPath) or nil
      if not rootPath or roots[identity] then
        warnings[#warnings + 1] = "компонент " .. index .. " пропущен: отсутствует путь или повторяется корень"
      else
        roots[identity] = true
        local component = {
          id = type(source.id) == "string" and source.id:sub(1, 80) or ("component_" .. index),
          name = type(source.name) == "string" and source.name:sub(1, 80) or "PhysBone",
          enabled = source.enabled ~= false,
          rootPath = rootPath,
          branchMode = source.branchMode == "all" and "all" or "selected",
          branchChoices = {}, excludedPaths = {},
          endpoint = { mode = "child" },
          colliders = {},
          settings = cleanSettings(source.settings, warnings, "компонент " .. index),
          linkOverrides = {},
        }
        for parentKey, childKey in pairs(type(source.branchChoices) == "table" and source.branchChoices or {}) do
          if type(parentKey) == "string" and type(childKey) == "string" then component.branchChoices[parentKey:sub(1, 512)] = childKey:sub(1, 512) end
        end
        for _, path in ipairs(type(source.excludedPaths) == "table" and source.excludedPaths or {}) do
          local cleanExcluded = cleanPath(path)
          if cleanExcluded and #component.excludedPaths < 256 then component.excludedPaths[#component.excludedPaths + 1] = cleanExcluded end
        end
        local endpoint = type(source.endpoint) == "table" and source.endpoint or {}
        if endpoint.mode == "child" then
          component.endpoint = { mode = "child" }
        elseif type(endpoint.vector) == "table" then
          local vector = { x = tonumber(endpoint.vector.x), y = tonumber(endpoint.vector.y), z = tonumber(endpoint.vector.z) }
          local len = math.sqrt((vector.x or 0)^2 + (vector.y or 0)^2 + (vector.z or 0)^2)
          if finite(vector.x) and finite(vector.y) and finite(vector.z) and finite(len) and len >= 0.001 and len <= 64 then
            component.endpoint = { mode = "manual", vector = vector }
          else
            warnings[#warnings + 1] = "компонент " .. index .. ": ручная конечная точка некорректна"
          end
        end
        for key, override in pairs(type(source.linkOverrides) == "table" and source.linkOverrides or {}) do
          if type(key) == "string" and type(override) == "table" then
            component.linkOverrides[key:sub(1, 512)] = cleanOverride(override, warnings, "звено " .. key)
          end
        end
        local colliderIds = {}
        for colliderIndex, sourceCollider in ipairs(type(source.colliders) == "table" and source.colliders or {}) do
          if colliderIndex > 128 then warnings[#warnings + 1] = "компонент " .. index .. ": превышен лимит 128 коллайдеров"; break end
          if type(sourceCollider) == "table" then
            local path = cleanPath(sourceCollider.path)
            local id = type(sourceCollider.id) == "string" and sourceCollider.id:sub(1, 512)
              or (path and require("physics_bone_registry").pathKey(path))
            if path and id and not colliderIds[id] then
              colliderIds[id] = true
              local offsetSource = type(sourceCollider.offset) == "table" and sourceCollider.offset or {}
              local axisSource = type(sourceCollider.axis) == "table" and sourceCollider.axis or {}
              local axis = { x = tonumber(axisSource.x), y = tonumber(axisSource.y), z = tonumber(axisSource.z) }
              local axisLength = math.sqrt((axis.x or 0)^2 + (axis.y or 0)^2 + (axis.z or 0)^2)
              if not finite(axis.x) or not finite(axis.y) or not finite(axis.z) or not finite(axisLength) or axisLength < 0.001 then
                axis = { x = 0, y = 1, z = 0 }
              else
                axis = { x = axis.x / axisLength, y = axis.y / axisLength, z = axis.z / axisLength }
              end
              local offset = {}
              for _, coordinate in ipairs({ "x", "y", "z" }) do
                offset[coordinate] = clamp(offsetSource[coordinate], { -64, 64 }, 0,
                  "коллайдер " .. id .. " offset." .. coordinate, warnings)
              end
              component.colliders[#component.colliders + 1] = {
                id = id, path = path,
                enabled = sourceCollider.enabled ~= false,
                shape = sourceCollider.shape == "capsule" and "capsule" or "sphere",
                offset = offset, axis = axis,
                radius = clamp(sourceCollider.radius, RANGES.collisionRadius, DEFAULT_SETTINGS.collision.radius,
                  "коллайдер " .. id .. " radius", warnings),
                height = clamp(sourceCollider.height, { 0, 64 }, 4,
                  "коллайдер " .. id .. " height", warnings),
              }
            elseif path then
              warnings[#warnings + 1] = "компонент " .. index .. ": повторяется коллайдер " .. id
            else
              warnings[#warnings + 1] = "компонент " .. index .. ": коллайдер " .. colliderIndex .. " пропущен — неверный путь"
            end
          end
        end
        clean.components[#clean.components + 1] = component
      end
    end
  end
  return clean, warnings
end

function configApi.effective(component, linkKey)
  local result = configApi.clone(component.settings or DEFAULT_SETTINGS)
  local override = component.linkOverrides and component.linkOverrides[linkKey]
  if type(override) == "table" then
    for key, value in pairs(override) do
      if type(value) == "table" and type(result[key]) == "table" then
        for subKey, subValue in pairs(value) do result[key][subKey] = subValue end
      else
        result[key] = value
      end
    end
  end
  return result
end

function configApi.load()
  local raw
  if config then
    pcall(function()
      if avatar and type(avatar.getName) == "function" then config:setName(avatar:getName()) end
      raw = config:load(CONFIG_KEY)
    end)
  end
  if type(raw) == "table" then return configApi.validate(raw) end
  local ok, bundled = pcall(require, PRESET_MODULE)
  if ok and type(bundled) == "table" then return configApi.validate(bundled) end
  return configApi.defaults(), {}
end

local function portablePaths(name)
  name = tostring(name or "avatar")
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then slug = "avatar" end
  slug = slug:sub(1, 40)
  local hash = 0
  for index = 1, #name do hash = (hash * 31 + name:byte(index)) % 2147483647 end
  local folder = PRESET_ROOT .. "/" .. slug .. "-" .. string.format("%08x", hash)
  return folder, folder .. "/physics_bone_preset.json", folder .. "/physics_bone_preset.lua"
end

function configApi.exportPreset(raw)
  local clean = configApi.validate(raw)
  if not file then return false, "File API Figura недоступен" end
  local allowedOk, allowed = pcall(function() return file:allowed() end)
  if not allowedOk or allowed ~= true then return false, "сначала разреши File API для этого аватара" end
  local avatarName = "avatar"
  pcall(function() if avatar and type(avatar.getName) == "function" then avatarName = avatar:getName() end end)
  local folder, jsonPath, luaPath = portablePaths(avatarName)
  if type(file.isPathAllowed) == "function" then
    local pathOk, pathAllowed = pcall(function() return file:isPathAllowed(folder) end)
    if not pathOk or pathAllowed ~= true then return false, "Figura запретила запись в figura/data для пресета" end
  end
  local mkdirOk = pcall(function() file:mkdirs(folder) end)
  local dirOk, isDirectory = pcall(function() return file:isDirectory(folder) end)
  if not mkdirOk or not dirOk or isDirectory ~= true then return false, "не удалось создать папку в figura/data" end
  if type(toJson) ~= "function" then return false, "Figura JSON API недоступен" end
  local jsonOk, jsonText = pcall(function() return toJson(clean) end)
  if not jsonOk or type(jsonText) ~= "string" then return false, "не удалось сформировать JSON профиля" end
  local luaText = "return parseJson(" .. string.format("%q", jsonText) .. ")\n"
  local writeJson = pcall(function() file:writeString(jsonPath, jsonText) end)
  local writeLua = pcall(function() file:writeString(luaPath, luaText) end)
  local jsonExistsOk, jsonExists = pcall(function() return file:exists(jsonPath) end)
  local luaExistsOk, luaExists = pcall(function() return file:exists(luaPath) end)
  if not writeJson or not writeLua or not jsonExistsOk or not jsonExists or not luaExistsOk or not luaExists then
    return false, "Figura не подтвердила запись обоих файлов профиля"
  end
  return true, folder
end

function configApi.importBundledPreset()
  local ok, raw = pcall(require, PRESET_MODULE)
  if not ok or type(raw) ~= "table" then return nil, "рядом со скриптами нет physics_bone_preset.lua" end
  local clean, warnings = configApi.validate(raw)
  return clean, warnings
end

function configApi.save(raw)
  local clean, warnings = configApi.validate(raw)
  if not config then return false, "Figura Config недоступен", clean, warnings end
  local ok, result = pcall(function()
    if avatar and type(avatar.getName) == "function" then config:setName(avatar:getName()) end
    return config:save(CONFIG_KEY, clean)
  end)
  if not ok or result == false then return false, "не удалось сохранить настройки v2: " .. tostring(result), clean, warnings end
  return true, "настройки v2 сохранены отдельно для этого аватара", clean, warnings
end

function configApi.defaultsForComponent(rootPath, name)
  local rootKey = require("physics_bone_registry").pathKey(rootPath or {})
  local hash = 0
  for index = 1, #rootKey do hash = (hash * 31 + rootKey:byte(index)) % 2147483647 end
  return {
    id = "physbone_" .. string.format("%08x", hash),
    name = name or "PhysBone",
    enabled = true,
    rootPath = configApi.clone(rootPath), branchMode = "selected",
    branchChoices = {}, excludedPaths = {},
    colliders = {},
    endpoint = { mode = "child" },
    settings = configApi.clone(DEFAULT_SETTINGS), linkOverrides = {},
  }
end

return configApi
