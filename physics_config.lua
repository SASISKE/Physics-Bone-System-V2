local physicsConfig = {}

local FIELD_LIMITS = {
  pull = { 0, 40 },
  spring = { 0, 1 },
  damping = { 0, 20 },
  avatarInertia = { 0, 2 },
  movementDrag = { 0, 1 },
  gravityFalloff = { 0, 1 },
  immobile = { 0, 1 },
  maxAngle = { 0, 45 },
  maxAngularSpeed = { 0, 240 },
  chainBendLimit = { 0, 360 },
}

local FIELD_STEPS = {
  pull = { 0.5, 1 }, spring = { 0.05, 2 }, damping = { 0.2, 1 },
  avatarInertia = { 0.05, 2 },
  gravityFalloff = { 0.05, 2 }, immobile = { 0.05, 2 },
  movementDrag = { 0.05, 2 },
  maxAngle = { 1, 0 }, maxAngularSpeed = { 5, 0 },
  chainBendLimit = { 5, 0 },
}

local VECTOR_STEPS = { gravity = { 0.25, 2 }, limitRotation = { 5, 0 } }

local TEST_AVATAR_NAME = "Deepsi — Physics Studio (тест)"
local LEGACY_TEST_CONFIG_NAME = "deepsi-physics-studio"
local PORTABLE_PRESET_ROOT = "PhysicsStudio/Characters"
local PORTABLE_PRESET_JSON = "physics_preset.json"
local PORTABLE_PRESET_LUA = "physics_preset.lua"

local DEFAULT_SETTINGS = {
  pull = 12,
  spring = 0.25,
  damping = 6,
  avatarInertia = 1,
  gravity = { x = 0, y = -1, z = 0 },
  gravitySpace = "world",
  gravityFalloff = 0.9,
  immobile = 0.65,
  movementDrag = 0,
  limitType = "cone",
  limitRotation = { x = 0, y = 0, z = 0 },
  maxAngle = 12,
  maxAngularSpeed = 120,
  chainBendLimit = 180,
}

local CHAIN_ONLY_FIELDS = { chainBendLimit = true, gravitySpace = true }

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function quantize(value, step, decimals)
  local stepped = math.floor(value / step + 0.5) * step
  local scale = 10 ^ decimals
  return math.floor(stepped * scale + 0.5) / scale
end

local function cloneValue(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return nil end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      result[key] = cloneValue(item, seen)
    end
  end
  seen[value] = nil
  return result
end

function physicsConfig.clone(value)
  return cloneValue(value)
end

function physicsConfig.defaultSettings()
  return cloneValue(DEFAULT_SETTINGS)
end

local function cleanPath(path)
  if type(path) ~= "table" or #path == 0 then return nil end
  local result = {}
  for index, segment in ipairs(path) do
    if type(segment) ~= "table" or type(segment.name) ~= "string"
      or type(segment.sameNameIndex) ~= "number" or not finite(segment.sameNameIndex)
      or segment.sameNameIndex < 1 then return nil end
    result[index] = {
      name = segment.name,
      sameNameIndex = math.floor(segment.sameNameIndex),
    }
  end
  return result
end

local function cleanEndpoint(endpoint, warnings, label)
  if type(endpoint) ~= "table" then endpoint = {} end
  if endpoint.mode == "manual" then
    local value = endpoint.vector
    if type(value) ~= "table" or not finite(value.x) or not finite(value.y) or not finite(value.z) then
      warnings[#warnings + 1] = label .. ": неверная ручная конечная точка"
      return { mode = "manual", vector = { x = 0, y = -1, z = 0 } }
    end
    return { mode = "manual", vector = { x = value.x, y = value.y, z = value.z } }
  end
  if endpoint.mode == "child" then
    local childPath = cleanPath(endpoint.childPath)
    if childPath then return { mode = "child", childPath = childPath } end
    warnings[#warnings + 1] = label .. ": неверный путь дочерней точки"
  end
  return { mode = "marker" }
end

local function cleanSettings(raw, warnings, label)
  raw = type(raw) == "table" and raw or {}
  local result = {}
  for key, range in pairs(FIELD_LIMITS) do
    local value = raw[key]
    if not finite(value) then
      value = DEFAULT_SETTINGS[key]
      if raw[key] ~= nil then warnings[#warnings + 1] = label .. ": неверное значение " .. key end
    end
    value = math.max(range[1], math.min(range[2], value))
    result[key] = quantize(value, FIELD_STEPS[key][1], FIELD_STEPS[key][2])
  end

  result.gravity = {}
  result.limitRotation = {}
  local gravity = type(raw.gravity) == "table" and raw.gravity or {}
  local rotation = type(raw.limitRotation) == "table" and raw.limitRotation or {}
  for _, axis in ipairs({ "x", "y", "z" }) do
    local gravityValue = gravity[axis]
    if not finite(gravityValue) then
      gravityValue = DEFAULT_SETTINGS.gravity[axis]
      if gravity[axis] ~= nil then warnings[#warnings + 1] = label .. ": неверная гравитация " .. axis end
    end
    result.gravity[axis] = quantize(math.max(-20, math.min(20, gravityValue)),
      VECTOR_STEPS.gravity[1], VECTOR_STEPS.gravity[2])

    local rotationValue = rotation[axis]
    if not finite(rotationValue) then
      rotationValue = DEFAULT_SETTINGS.limitRotation[axis]
      if rotation[axis] ~= nil then warnings[#warnings + 1] = label .. ": неверный угол ограничения " .. axis end
    end
    result.limitRotation[axis] = quantize(math.max(-180, math.min(180, rotationValue)),
      VECTOR_STEPS.limitRotation[1], VECTOR_STEPS.limitRotation[2])
  end

  local limitType = raw.limitType
  if limitType ~= "none" and limitType ~= "cone" and limitType ~= "hinge" then
    if limitType ~= nil then warnings[#warnings + 1] = label .. ": неизвестный тип ограничения" end
    limitType = DEFAULT_SETTINGS.limitType
  end
  result.limitType = limitType

  local gravitySpace = raw.gravitySpace
  if gravitySpace ~= "world" and gravitySpace ~= "local" then
    if gravitySpace ~= nil then warnings[#warnings + 1] = label .. ": неизвестная система гравитации" end
    -- Profiles from schema v3 had no selector and used avatar-local axes.
    gravitySpace = gravitySpace == nil and "local" or DEFAULT_SETTINGS.gravitySpace
  end
  result.gravitySpace = gravitySpace
  return result
end

local function cleanOverride(raw, baseSettings, warnings, label)
  if type(raw) ~= "table" then return nil end
  local result, hasValues = {}, false
  for key, range in pairs(FIELD_LIMITS) do
    local value = raw[key]
    if CHAIN_ONLY_FIELDS[key] then
      if value ~= nil then
        warnings[#warnings + 1] = label .. ": общая настройка цепи " .. key .. " не применяется к отдельному звену"
      end
    elseif value ~= nil then
      if finite(value) then
        value = math.max(range[1], math.min(range[2], value))
        result[key] = quantize(value, FIELD_STEPS[key][1], FIELD_STEPS[key][2])
        hasValues = true
      else
        warnings[#warnings + 1] = label .. ": неверное значение " .. key .. "; унаследовано от цепи"
      end
    end
  end
  if raw.limitType ~= nil then
    if raw.limitType == "none" or raw.limitType == "cone" or raw.limitType == "hinge" then
      result.limitType = raw.limitType
      hasValues = true
    else
      warnings[#warnings + 1] = label .. ": неизвестный тип ограничения; унаследован от цепи"
    end
  end
  if raw.gravitySpace ~= nil then
    warnings[#warnings + 1] = label .. ": система гравитации задаётся для всей цепи"
  end

  for _, field in ipairs({ "gravity", "limitRotation" }) do
    local source = raw[field]
    if type(source) == "table" then
      local values = {}
      local changed = false
      for _, axis in ipairs({ "x", "y", "z" }) do
        if source[axis] ~= nil then
          local minimum, maximum = field == "gravity" and -20 or -180, field == "gravity" and 20 or 180
          if finite(source[axis]) then
            local step, decimals = VECTOR_STEPS[field][1], VECTOR_STEPS[field][2]
            values[axis] = quantize(math.max(minimum, math.min(maximum, source[axis])), step, decimals)
            changed = true
          else
            warnings[#warnings + 1] = label .. ": неверное значение " .. field .. "." .. axis .. "; унаследовано от цепи"
          end
        end
      end
      if changed then result[field] = values; hasValues = true end
    end
  end
  return hasValues and result or nil
end

local function cleanOverrides(raw, settings, linkCount, warnings, label)
  local result = {}
  if type(raw) ~= "table" then return result end
  for rawIndex, override in pairs(raw) do
    local index = tonumber(rawIndex)
    if finite(index) and index >= 1 and index <= linkCount and index == math.floor(index) then
      local cleaned = cleanOverride(override, settings, warnings, label .. " звено " .. index)
      if cleaned then result[index] = cleaned end
    else
      warnings[#warnings + 1] = label .. ": пропущена настройка неверного звена"
    end
  end
  return result
end

local function cleanBranchChoices(raw)
  local result = {}
  if type(raw) ~= "table" then return result end
  for parentKey, childKey in pairs(raw) do
    if type(parentKey) == "string" and type(childKey) == "string" then
      result[parentKey] = childKey
    end
  end
  return result
end

local function rootKey(path)
  local parts = {}
  for _, segment in ipairs(path or {}) do
    parts[#parts + 1] = segment.name .. "[" .. segment.sameNameIndex .. "]"
  end
  return table.concat(parts, "/")
end

local function cleanChainPaths(raw, index, warnings)
  local label = "Цепь " .. index
  if type(raw) ~= "table" then
    warnings[#warnings + 1] = label .. ": запись пропущена"
    return nil
  end
  local rootPath = cleanPath(raw.rootPath)
  if not rootPath then
    warnings[#warnings + 1] = label .. ": неверный путь корня; цепь пропущена"
    return nil
  end
  if type(raw.linkPaths) ~= "table" or #raw.linkPaths == 0 then
    warnings[#warnings + 1] = label .. ": отсутствуют звенья; цепь пропущена"
    return nil
  end
  local linkPaths, seen = {}, {}
  for linkIndex, path in ipairs(raw.linkPaths) do
    local cleaned = cleanPath(path)
    if not cleaned then
      warnings[#warnings + 1] = label .. ": неверный путь звена " .. linkIndex .. "; цепь пропущена"
      return nil
    end
    local key = rootKey(cleaned)
    if seen[key] then
      warnings[#warnings + 1] = label .. ": повтор звена; цепь пропущена"
      return nil
    end
    seen[key] = true
    linkPaths[linkIndex] = cleaned
  end
  if rootKey(rootPath) ~= rootKey(linkPaths[1]) then
    warnings[#warnings + 1] = label .. ": путь корня не совпадает с первым звеном; цепь пропущена"
    return nil
  end
  return {
    rootPath = rootPath,
    linkPaths = linkPaths,
    branchChoices = cleanBranchChoices(raw.branchChoices),
    enabled = raw.enabled == true,
  }
end

local function cleanChain(raw, index, warnings)
  local paths = cleanChainPaths(raw, index, warnings)
  if not paths then return nil end
  local label = "Цепь " .. index
  local settings = cleanSettings(raw.settings, warnings, label)
  return {
    rootPath = paths.rootPath,
    linkPaths = paths.linkPaths,
    branchChoices = paths.branchChoices,
    enabled = paths.enabled,
    settings = settings,
    linkOverrides = cleanOverrides(raw.linkOverrides, settings, #paths.linkPaths, warnings, label),
    migrationNotice = raw.migrationNotice == true,
  }
end

local function cleanLegacyTarget(raw, index, warnings)
  if type(raw) ~= "table" then
    warnings[#warnings + 1] = "Старая настройка " .. index .. ": запись пропущена"
    return nil
  end
  local path = cleanPath(raw.rootPath or raw.partPath)
  if not path then
    warnings[#warnings + 1] = "Старая настройка " .. index .. ": неверный путь; цель пропущена"
    return nil
  end
  warnings[#warnings + 1] = "Старая настройка " .. index .. ": профиль сброшен для новой физики"
  return {
    rootPath = path,
    enabled = raw.enabled == true,
    branchChoices = {},
    settings = physicsConfig.defaultSettings(),
    legacyEndpoint = cleanEndpoint(raw.legacyEndpoint or raw.endpoint, warnings, "Старая настройка " .. index),
    migrationNotice = true,
  }
end

function physicsConfig.defaults()
  return { schemaVersion = 4, chains = {}, pendingLegacyTargets = {} }
end

function physicsConfig.validate(raw)
  local warnings = {}
  if type(raw) ~= "table" then
    warnings[#warnings + 1] = "Настройки повреждены; загружен профиль по умолчанию"
    return physicsConfig.defaults(), warnings
  end

  if raw.schemaVersion == 1 then
    local migrated, seen = physicsConfig.defaults(), {}
    for index, candidate in ipairs(type(raw.targets) == "table" and raw.targets or {}) do
      local target = cleanLegacyTarget(candidate, index, warnings)
      if target then
        local key = rootKey(target.rootPath)
        if seen[key] then
          warnings[#warnings + 1] = "Старая настройка " .. index .. ": повторный корень пропущен"
        else
          seen[key] = true
          migrated.pendingLegacyTargets[#migrated.pendingLegacyTargets + 1] = target
        end
      end
    end
    return migrated, warnings
  end

  if raw.schemaVersion ~= 2 and raw.schemaVersion ~= 3 and raw.schemaVersion ~= 4 then
    warnings[#warnings + 1] = "Неизвестная версия настроек; загружен профиль по умолчанию"
    return physicsConfig.defaults(), warnings
  end

  local migratingV2 = raw.schemaVersion == 2
  local result, seenRoots = physicsConfig.defaults(), {}
  if migratingV2 then
    warnings[#warnings + 1] = "Профили v2 сброшены; назначения цепей сохранены"
  end
  for index, candidate in ipairs(type(raw.chains) == "table" and raw.chains or {}) do
    local chain
    if migratingV2 then
      local paths = cleanChainPaths(candidate, index, warnings)
      if paths then
        chain = {
          rootPath = paths.rootPath,
          linkPaths = paths.linkPaths,
          branchChoices = paths.branchChoices,
          enabled = paths.enabled,
          settings = physicsConfig.defaultSettings(),
          linkOverrides = {},
          migrationNotice = true,
        }
      end
    else
      chain = cleanChain(candidate, index, warnings)
    end
    if chain then
      local key = rootKey(chain.rootPath)
      if seenRoots[key] then
        warnings[#warnings + 1] = "Цепь " .. index .. ": повторный корень пропущен"
      else
        seenRoots[key] = true
        result.chains[#result.chains + 1] = chain
      end
    end
  end

  for index, candidate in ipairs(type(raw.pendingLegacyTargets) == "table" and raw.pendingLegacyTargets or {}) do
    local pending = cleanLegacyTarget(candidate, index, warnings)
    if pending then result.pendingLegacyTargets[#result.pendingLegacyTargets + 1] = pending end
  end
  return result, warnings
end

local function currentAvatarName()
  local name
  pcall(function()
    if avatar and type(avatar.getName) == "function" then
      local value = avatar:getName()
      if type(value) == "string" and value ~= "" then name = value end
    end
  end)
  return name
end

local function portableFolder(name)
  name = tostring(name or "avatar")
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then slug = "avatar" end
  slug = slug:sub(1, 48)
  local hash = 0
  for index = 1, #name do hash = (hash * 31 + name:byte(index)) % 2147483647 end
  return PORTABLE_PRESET_ROOT .. "/" .. slug .. "-" .. string.format("%08x", hash)
end

local function portableFilePaths(name)
  local folder = portableFolder(name)
  return folder, folder .. "/" .. PORTABLE_PRESET_JSON, folder .. "/" .. PORTABLE_PRESET_LUA
end

local function canUsePortableFiles(path)
  if not file then return false, "File API Figura недоступен" end
  local allowedOk, allowed = pcall(function() return file:allowed() end)
  if not allowedOk or allowed ~= true then return false, "File API запрещён для этого аватара" end
  if type(file.isPathAllowed) == "function" then
    local pathOk, pathAllowed = pcall(function() return file:isPathAllowed(path) end)
    if not pathOk or pathAllowed ~= true then return false, "путь пресета запрещён File API" end
  end
  return true
end

local function persistableConfig(clean)
  local saved = { schemaVersion = 4, chains = {} }
  for index, chain in ipairs(clean.chains or {}) do
    saved.chains[index] = {
      rootPath = cloneValue(chain.rootPath),
      linkPaths = cloneValue(chain.linkPaths),
      branchChoices = cloneValue(chain.branchChoices),
      enabled = chain.enabled == true,
      settings = cloneValue(chain.settings),
      linkOverrides = cloneValue(chain.linkOverrides),
    }
  end
  return saved
end

function physicsConfig.exportPortablePreset(raw)
  local clean = physicsConfig.validate(raw)
  if #clean.pendingLegacyTargets > 0 then
    return false, "Сначала разреши все перенесённые цепи"
  end
  local name = currentAvatarName()
  if not name then return false, "Не удалось определить имя аватара" end
  local folder, jsonPath, luaPath = portableFilePaths(name)
  local allowed, reason = canUsePortableFiles(folder)
  if not allowed then return false, reason end

  local makeFolderOk = pcall(function() file:mkdirs(folder) end)
  local folderOk, isDirectory = pcall(function() return file:isDirectory(folder) end)
  if not makeFolderOk or not folderOk or isDirectory ~= true then
    return false, "не удалось создать папку пресета в figura/data"
  end

  local jsonOk, jsonText = pcall(function() return toJson(persistableConfig(clean)) end)
  if not jsonOk or type(jsonText) ~= "string" then return false, "не удалось сериализовать профиль" end
  local luaText = "return parseJson(" .. string.format("%q", jsonText) .. ")\n"
  local writeJsonOk = pcall(function() file:writeString(jsonPath, jsonText) end)
  local writeLuaOk = pcall(function() file:writeString(luaPath, luaText) end)
  local jsonExistsOk, jsonExists = pcall(function() return file:exists(jsonPath) end)
  local luaExistsOk, luaExists = pcall(function() return file:exists(luaPath) end)
  if not writeJsonOk or not writeLuaOk or not jsonExistsOk or not jsonExists
    or not luaExistsOk or not luaExists then
    return false, "Figura не смогла записать файлы пресета"
  end
  return true, folder
end

function physicsConfig.importPortablePreset()
  local name = currentAvatarName()
  if not name then return nil, "Не удалось определить имя аватара" end
  local _, jsonPath = portableFilePaths(name)
  local allowed, reason = canUsePortableFiles(jsonPath)
  if not allowed then return nil, reason end
  local readOk, jsonText = pcall(function() return file:readString(jsonPath) end)
  if not readOk or type(jsonText) ~= "string" then return nil, "Экспорт этого аватара не найден" end
  local parseOk, raw = pcall(function() return parseJson(jsonText) end)
  if not parseOk or type(raw) ~= "table" then return nil, "Файл пресета повреждён или имеет неверный формат" end
  local clean, warnings = physicsConfig.validate(raw)
  if #clean.pendingLegacyTargets > 0 then return nil, "В пресете есть неразрешённые старые цепи" end
  return clean, warnings
end

local function loadBundledPreset()
  local ok, raw = pcall(require, "physics_preset")
  if not ok or type(raw) ~= "table" then return nil end
  local clean, warnings = physicsConfig.validate(raw)
  if #clean.pendingLegacyTargets > 0 then return nil end
  return clean, warnings
end

function physicsConfig.load()
  local defaults = physicsConfig.defaults()
  local avatarName = currentAvatarName()
  local stored
  if config then
    if avatarName then pcall(function() config:setName(avatarName) end) end
    local storedOk
    storedOk, stored = pcall(function() return config:load("settings") end)
    if storedOk and stored ~= nil then return physicsConfig.validate(stored) end
  end

  -- Import the old shared profile only for the original test avatar.
  -- Other avatars always start with their own config and never see this file.
  if config and avatarName == TEST_AVATAR_NAME then
    local legacyOk, legacyStored = pcall(function()
      config:setName(LEGACY_TEST_CONFIG_NAME)
      return config:load("settings")
    end)
    pcall(function() config:setName(avatarName) end)
    if legacyOk and legacyStored ~= nil then
      local migrated, warnings = physicsConfig.validate(legacyStored)
      for _, chain in ipairs(migrated.chains or {}) do chain.migrationNotice = true end
      warnings[#warnings + 1] = "Старые настройки перенесены в профиль этого аватара; сохрани их в Physics Studio"
      return migrated, warnings
    end
  end

  local bundled, bundledWarnings = loadBundledPreset()
  if bundled then return bundled, bundledWarnings end

  return defaults, {}
end

function physicsConfig.save(raw)
  if type(raw) == "table" and type(raw.pendingLegacyTargets) == "table"
    and #raw.pendingLegacyTargets > 0 then
    return false, "Сначала разреши все перенесённые цепи"
  end
  local clean, warnings = physicsConfig.validate(raw)
  if #clean.pendingLegacyTargets > 0 then
    return false, "Сначала разреши все перенесённые цепи"
  end
  if not config then return false, "Figura Config недоступен" end
  local saved = persistableConfig(clean)
  local ok, result = pcall(function()
    if avatar and type(avatar.getName) == "function" then
      local name = avatar:getName()
      if type(name) == "string" and name ~= "" then config:setName(name) end
    end
    return config:save("settings", saved)
  end)
  if not ok then return false, tostring(result) end
  if result == false then return false, "Figura Config не сохранил настройки" end
  local portableOk, portableResult = physicsConfig.exportPortablePreset(saved)
  if portableOk then
    return true, "Сохранено локально; physics_preset.lua создан в figura/data"
  end
  return true, "Локально сохранено; пресет не создан: " .. tostring(portableResult)
end

return physicsConfig
