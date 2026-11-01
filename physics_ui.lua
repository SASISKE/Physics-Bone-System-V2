local physicsUI = {}
local physicsChain = require("physics_chain")
local physicsConfig = require("physics_config")

local PARAMS = {
  { group = "Возврат и колебания" },
  { key = "pull", label = "Возврат к анимации", shortLabel = "Возврат к позе", step = 0.5, decimals = 1, min = 0, max = 40, unit = " 1/с²",
    help = "1/с². Выше — быстрее возврат к текущей анимированной позе." },
  { key = "spring", label = "Пружинистость", shortLabel = "Пружина", step = 0.05, decimals = 2, min = 0, max = 1,
    help = "0 — без перелёта цели; 1 — свободнее раскачивается." },
  { key = "damping", label = "Затухание", step = 0.2, decimals = 1, min = 0, max = 20, unit = " 1/с",
    help = "1/с. Выше — колебания быстрее успокаиваются." },
  { group = "Движение аватара" },
  { key = "immobile", label = "Игнор движения", shortLabel = "Игнор движения", step = 0.05, decimals = 2, min = 0, max = 1,
    help = "0 — движение игрока влияет полностью; 1 — игнорируется." },
  { key = "avatarInertia", label = "Инерция аватара", shortLabel = "Инерция аватара", step = 0.05, decimals = 2, min = 0, max = 2,
    help = "Реакция на разгон, торможение, прыжки и смену направления. 0 — выключена; 1 — обычная; силу ограничивает решатель." },
  { key = "movementDrag", label = "Поток движения", shortLabel = "Поток движения", step = 0.05, decimals = 2, min = 0, max = 1,
    help = "Сопротивление воздуха для звеньев. Учитывает скорость и угол звена к потоку; сила ограничена и ослабевает при выравнивании. 0 — выключено." },
  { group = "Гравитация" },
  { key = "gravitySpace", kind = "choice", label = "Система гравитации", shortLabel = "Кадр тяжести", chainOnly = true,
    help = "Мир: X/Y/Z заданы по мировым осям и тяжесть учитывает наклон родителей цепи. Локально: оси модели, как в прежних настройках." },
  { key = "gravity.x", label = "Сила X", shortLabel = "Сила X", step = 0.25, decimals = 2, min = -20, max = 20, unit = " бл/с²",
    help = "Постоянное ускорение по выбранной системе координат; единицы — блоки/с²." },
  { key = "gravity.y", label = "Сила Y", shortLabel = "Сила Y", step = 0.25, decimals = 2, min = -20, max = 20, unit = " бл/с²",
    help = "Постоянное ускорение по выбранной системе координат; единицы — блоки/с²." },
  { key = "gravity.z", label = "Сила Z", shortLabel = "Сила Z", step = 0.25, decimals = 2, min = -20, max = 20, unit = " бл/с²",
    help = "Постоянное ускорение по выбранной системе координат; единицы — блоки/с²." },
  { key = "gravityFalloff", label = "Спад у покоя", step = 0.05, decimals = 2, min = 0, max = 1,
    help = "Ослабляет гравитацию рядом с текущей анимированной позой." },
  { group = "Ограничения суставов" },
  { key = "limitType", kind = "choice", label = "Ограничитель",
    help = "Нет, конус вокруг позы или движение по одной оси-шарниру." },
  { key = "limitRotation.x", label = "Ось X", shortLabel = "Ось X", step = 5, decimals = 0, min = -180, max = 180, unit = "°",
    help = "Градусы. Ориентация оси шарнира; используется типом «Шарнир»." },
  { key = "limitRotation.y", label = "Ось Y", shortLabel = "Ось Y", step = 5, decimals = 0, min = -180, max = 180, unit = "°",
    help = "Ориентация оси шарнира; используется типом «Шарнир»." },
  { key = "limitRotation.z", label = "Ось Z", shortLabel = "Ось Z", step = 5, decimals = 0, min = -180, max = 180, unit = "°",
    help = "Ориентация оси шарнира; используется типом «Шарнир»." },
  { key = "maxAngle", label = "Макс. угол", shortLabel = "Макс. угол", step = 1, decimals = 0, min = 0, max = 45, unit = "°",
    help = "Градусы. Максимальное отклонение от текущей анимированной позы." },
  { key = "maxAngularSpeed", label = "Скорость лимита", shortLabel = "Скорость лимита", step = 5, decimals = 0, min = 0, max = 240, unit = "°/с",
    help = "Градусы/с. Ограничивает скорость изменения физического угла." },
  { key = "chainBendLimit", label = "Общий изгиб цепи", shortLabel = "Общий изгиб цепи", step = 5, decimals = 0, min = 0, max = 360, unit = "°", chainOnly = true,
    help = "Максимальная сумма отклонений всех звеньев от их анимированных поз. Не даёт длинной цепи складываться в полный виток. 0 — физический изгиб выключен; 360 — разрешён полный оборот суммарно." },
}

local LINE_HEIGHT = 10
local TREE_START_LINE = 4
local FIXED_SLIDER_SEGMENTS = 14
local CHAIN_ONLY_SETTINGS = { chainBendLimit = true, gravitySpace = true }
local CHOICE_VALUES = {
  limitType = { "none", "cone", "hinge" },
  gravitySpace = { "world", "local" },
}
local CHOICE_LABELS = {
  limitType = { none = "Выкл", cone = "Конус", hinge = "Шарнир" },
  gravitySpace = { world = "Мир", ["local"] = "Локально" },
}

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local args = { ... }
  local ok, result = pcall(fn, object, (table.unpack or unpack)(args))
  if ok then return result end
  return nil
end

local function cloneTable(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return nil end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do result[key] = cloneTable(item, seen) end
  seen[value] = nil
  return result
end

local function text(value)
  return tostring(value or "")
end

local ERROR_STATUS_MARKERS = {
  "Ошибка", "Импорт не выполнен", "Не удалось", "не сохранил", "недоступен",
  "запрещён", "Миграция остановлена", "Перенос цепи не разрешился", "некорректный pivot",
  "Сохранение заблокировано", "Есть ещё старая цепь", "Осталась старая цепь",
}

local function isErrorStatus(value)
  local status = text(value)
  for _, marker in ipairs(ERROR_STATUS_MARKERS) do
    if status:find(marker, 1, true) then return true end
  end
  return false
end

local function errorPanelText(ui, status)
  local lines = { "§cPhysics Studio — ошибка§r", "§f" .. text(status) }
  if text(status):find("Сначала разреши все перенесённые цепи", 1, true) then
    local pendingCount = #(ui.draft and ui.draft.pendingLegacyTargets or {})
    lines[#lines + 1] = "§7Осталось старых цепей: " .. pendingCount
    lines[#lines + 1] = "§7Чтобы перенести старую цепь, выбери её ветвь в дереве."
    lines[#lines + 1] = "§7Чтобы убрать старые записи, нажми внизу Outliner:"
    lines[#lines + 1] = "§f«Удалить переносы (" .. pendingCount .. ")»."
    lines[#lines + 1] = "§7Новые назначенные цепи останутся."
  end
  return table.concat(lines, "\n")
end

local function messagePanelText(ui, status, hint)
  local lines = {}
  if isErrorStatus(status) then
    for line in errorPanelText(ui, status):gmatch("[^\n]+") do
      lines[#lines + 1] = line
    end
  elseif status and status ~= "" then
    lines[#lines + 1] = "§eПоследнее сообщение§r"
    lines[#lines + 1] = "§f" .. text(status)
  end
  if hint and hint ~= "" then
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = "§bПодсказка§r"
    lines[#lines + 1] = "§f" .. hint
  else
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = "§bПодсказка§r"
    lines[#lines + 1] = "§7Наведи курсор на настройку — здесь появится её описание."
  end
  return table.concat(lines, "\n")
end

local function plainText(value)
  return (text(value):gsub("§.", ""))
end

local function pathWithin(parentPath, childPath)
  if type(parentPath) ~= "table" or type(childPath) ~= "table" or #childPath < #parentPath then return false end
  for index, segment in ipairs(parentPath) do
    local other = childPath[index]
    if not other or segment.name ~= other.name or segment.sameNameIndex ~= other.sameNameIndex then return false end
  end
  return true
end

local function nodeForPath(registry, path)
  if not registry or type(path) ~= "table" then return nil end
  for _, node in ipairs(registry.flat or {}) do
    if #node.path == #path and pathWithin(path, node.path) then return node end
  end
  return nil
end

local function shortPath(node)
  if not node or type(node.path) ~= "table" then return "—" end
  local segments = {}
  local first = math.max(1, #node.path - 2)
  if first > 1 then segments[#segments + 1] = "…" end
  for index = first, #node.path do
    local segment = node.path[index]
    local label = segment.name
    if segment.sameNameIndex > 1 then label = label .. "#" .. segment.sameNameIndex end
    segments[#segments + 1] = label
  end
  return table.concat(segments, "/")
end

local function getMouseGui()
  local position = safeCall(client, "getMousePos")
  local scale = tonumber(safeCall(client, "getGuiScale")) or 1
  if not position then return 0, 0 end
  return (tonumber(position.x) or 0) / math.max(scale, 1), (tonumber(position.y) or 0) / math.max(scale, 1)
end

local function formatValue(value, decimals)
  return string.format("%0." .. tostring(decimals) .. "f", tonumber(value) or 0)
end

local function quantizeSetting(param, value)
  value = math.max(param.min, math.min(param.max, tonumber(value) or param.min))
  local steps = math.floor((value - param.min) / param.step + 0.5)
  local stepped = param.min + steps * param.step
  local scale = 10 ^ (param.decimals or 0)
  return math.max(param.min, math.min(param.max, math.floor(stepped * scale + 0.5) / scale))
end

local function textWidth(value)
  local plain = plainText(value)
  local width = safeCall(client, "getTextWidth", plain)
  if type(width) == "number" then return width end
  return #plain * 6
end

-- Keep this bounded: Figura's text metrics may omit some leading/trailing spaces.
local function spacesForWidth(width)
  local spaceWidth = textWidth(" ")
  if spaceWidth <= 0 or width <= 0 then return "" end
  local count = math.floor(width / spaceWidth)
  return string.rep(" ", math.max(0, math.min(count, 128)))
end

local function padToWidth(value, targetWidth)
  value = value or ""
  return value .. spacesForWidth(targetWidth - textWidth(value))
end

local function rightAlignToWidth(value, targetWidth)
  value = value or ""
  return spacesForWidth(targetWidth - textWidth(value)) .. value
end

local function truncateToWidth(value, maxWidth)
  value = text(value)
  if textWidth(value) <= maxWidth then return value end
  local result = value
  while result ~= "" and textWidth(result .. "…") > maxWidth do
    local index = #result
    while index > 1 do
      local byte = result:byte(index)
      if byte < 128 or byte >= 192 then break end
      index = index - 1
    end
    result = result:sub(1, index - 1)
  end
  return result .. (result ~= "" and "…" or "")
end

local function widestSettingLabel()
  local width = 0
  for _, param in ipairs(PARAMS) do
    local label = param.group or ((param.shortLabel or param.label) .. "*")
    if label then width = math.max(width, textWidth(label)) end
  end
  return width
end

local function settingColumns(rightWidth, displayScale)
  displayScale = math.max(0.01, tonumber(displayScale) or 1)
  local gap = math.max(1, textWidth(" "))
  local labelGap = gap * 2
  local minusWidth = textWidth("[−]")
  local valueContentWidth = textWidth("-20.00▏")
  local valueWidth = textWidth("[") + valueContentWidth + textWidth("]")
  local plusWidth = textWidth("[+]")
  local inheritWidth = textWidth("[↶]")
  local minimumSliderWidth = textWidth("[■]")
  local desiredLabelWidth = widestSettingLabel()
  local controlsBeforeSlider = minusWidth + valueWidth + plusWidth + inheritWidth + gap * 4
  local labelWidth = math.min(desiredLabelWidth,
    math.max(0, rightWidth - labelGap - controlsBeforeSlider - minimumSliderWidth))
  local controlStart = labelWidth + labelGap
  local minusStart = controlStart
  local minusEnd = minusStart + minusWidth
  local valueStart = minusEnd + gap
  local valueEnd = valueStart + valueWidth
  local plusStart = valueEnd + gap
  local plusEnd = plusStart + plusWidth
  local inheritStart = plusEnd + gap
  local inheritEnd = inheritStart + inheritWidth
  local sliderStart = inheritEnd + gap
  local blockWidth = math.max(1, textWidth("■"))
  local availableSegments = math.max(0, math.floor((rightWidth - sliderStart - textWidth("[]")) / blockWidth))
  local fixedSegments = math.floor(FIXED_SLIDER_SEGMENTS / displayScale + 0.5)
  local sliderSegments = math.max(0, math.min(availableSegments, fixedSegments))
  local sliderWidth = sliderSegments > 0
    and textWidth("[" .. string.rep("■", sliderSegments) .. "]") or 0
  local sliderEnd = rightWidth
  return {
    labelWidth = labelWidth, labelGap = labelGap, controlStart = controlStart,
    minusStart = minusStart, minusEnd = minusEnd,
    valueStart = valueStart, valueEnd = valueEnd, valueContentWidth = valueContentWidth,
    plusStart = plusStart, plusEnd = plusEnd,
    inheritStart = inheritStart, inheritEnd = inheritEnd,
    sliderStart = sliderStart, sliderEnd = sliderEnd,
    sliderInnerStart = sliderStart + textWidth("["),
    sliderInnerEnd = sliderStart + textWidth("[" .. string.rep("■", sliderSegments) .. "]") - textWidth("]"),
    sliderWidth = sliderWidth,
  }, sliderSegments
end

local function textRange(prefix, value)
  return { start = textWidth(prefix), finish = textWidth(prefix .. value) }
end

local function measuredLineHeight()
  local one = tonumber(safeCall(client, "getTextHeight", "A"))
  local two = tonumber(safeCall(client, "getTextHeight", "A\nA"))
  if one and (not two or two <= one) then
    local dimensions = safeCall(client, "getTextDimensions", "A\nA")
    two = dimensions and tonumber(dimensions.y) or two
  end
  if one and two and two > one then return two - one end
  return LINE_HEIGHT
end

local function targetKey(target)
  if not target then return nil end
  return table.concat({ target.kind or "", tostring(target.key or ""), tostring(target.row or "") }, ":")
end

local function settingValue(settings, key)
  if key == "gravity.x" then return settings.gravity.x end
  if key == "gravity.y" then return settings.gravity.y end
  if key == "gravity.z" then return settings.gravity.z end
  if key == "limitRotation.x" then return settings.limitRotation.x end
  if key == "limitRotation.y" then return settings.limitRotation.y end
  if key == "limitRotation.z" then return settings.limitRotation.z end
  return settings[key]
end

local function setSetting(settings, key, value)
  if key == "gravity.x" then settings.gravity.x = value
  elseif key == "gravity.y" then settings.gravity.y = value
  elseif key == "gravity.z" then settings.gravity.z = value
  elseif key == "limitRotation.x" then settings.limitRotation.x = value
  elseif key == "limitRotation.y" then settings.limitRotation.y = value
  elseif key == "limitRotation.z" then settings.limitRotation.z = value
  else settings[key] = value end
end

local function newDefaultSettings()
  return physicsConfig.defaultSettings()
end

local function mergeSettings(base, override)
  local result = cloneTable(base or newDefaultSettings())
  for key, value in pairs(override or {}) do
    if (key == "gravity" or key == "limitRotation") and type(value) == "table" then
      result[key] = cloneTable(result[key] or {})
      for axis, axisValue in pairs(value) do result[key][axis] = axisValue end
    else
      result[key] = cloneTable(value)
    end
  end
  return result
end

local function nodeIndent(node)
  return math.min(node and node.depth or 0, 6) * 12
end

local function chainKey(chain)
  return physicsChain.pathKey(chain and chain.rootPath)
end

function physicsUI.new(registry, draft, callbacks)
  local ui = setmetatable({}, { __index = physicsUI })
  ui.registry = registry
  ui.nodes = registry and registry.flat or {}
  ui.draft = draft or { schemaVersion = 4, chains = {}, pendingLegacyTargets = {} }
  ui.callbacks = callbacks or {}
  ui.open = false
  ui.selectedKey = ui.nodes[1] and ui.nodes[1].key or nil
  ui.treeOffset = 0
  ui.settingsOffset = 0
  ui.collapsedKeys = {}
  ui.branchChoices = {}
  ui.search = ""
  ui.searchFocused = false
  ui.diagnostics = false
  ui.pendingAssignment = nil
  ui.repeatAction = nil
  ui.hoverTarget = nil
  ui.editingSetting = nil
  ui.sidebarText = nil
  ui.detailsText = nil
  ui.settingTextTasks = {}
  ui.hud = nil
  ui.cursorWasUnlocked = nil
  ui.status = "Выбери группу и назначь цепь"
  ui.layout = { x = 9, y = 7, width = 400, height = 230, leftWidth = 158, lineHeight = LINE_HEIGHT }
  ui:migrateUnambiguousTargets()
  return ui
end

function physicsUI:migrateUnambiguousTargets()
  local pending = self.draft.pendingLegacyTargets or {}
  local remaining, migrated = {}, false
  self.pendingMigration = nil
  for pendingIndex, old in ipairs(pending) do
    local node = nodeForPath(self.registry, old.rootPath)
    if not node then
      remaining[#remaining + 1] = old
    else
      local found, err = physicsChain.discover(self.registry, node.key, old.branchChoices)
      if found and found.complete then
        local candidate = {
          rootPath = cloneTable(old.rootPath),
          linkPaths = cloneTable(found.linkPaths),
          branchChoices = cloneTable(old.branchChoices or {}),
          enabled = old.enabled == true,
          settings = newDefaultSettings(),
          linkOverrides = {},
          migrationNotice = true,
          legacyEndpoint = cloneTable(old.legacyEndpoint),
        }
        local conflict = physicsChain.findOverlap(self.draft.chains, candidate)
        if not conflict then
          self.draft.chains[#self.draft.chains + 1] = candidate
          migrated = true
        else
          remaining[#remaining + 1] = old
          self.status = "Миграция: цепь пересекается с уже назначенной"
        end
      elseif found and found.unresolvedBranches and found.unresolvedBranches[1] and not self.pendingMigration then
        remaining[#remaining + 1] = old
        self.pendingMigration = {
          pendingIndex = pendingIndex,
          target = old,
          rootKey = node.key,
          branchChoices = cloneTable(old.branchChoices or {}),
          result = found,
        }
        self.status = "Старая настройка: выбери неоднозначную ветвь в Outliner"
      else
        remaining[#remaining + 1] = old
        if found and not (found.unresolvedBranches and found.unresolvedBranches[1]) then
          self.status = "Миграция остановлена: в цепи есть некорректный pivot"
        else
          self.status = err or "Миграция: выбери ветвь в Outliner"
        end
      end
    end
  end
  self.draft.pendingLegacyTargets = remaining
  if migrated then self:notifyChanged() end
end

function physicsUI:setRegistry(registry)
  self.registry = registry
  self.nodes = registry and registry.flat or {}
  if self.selectedKey and not registry.byKey[self.selectedKey] then self.selectedKey = self.nodes[1] and self.nodes[1].key end
  self:migrateUnambiguousTargets()
  self:refresh()
end

function physicsUI:setDraft(draft)
  self.draft = draft or { schemaVersion = 4, chains = {}, pendingLegacyTargets = {} }
  self:refresh()
end

function physicsUI:notifyChanged()
  if type(self.callbacks.onConfigChanged) == "function" then
    self.callbacks.onConfigChanged(cloneTable(self.draft))
  end
end

function physicsUI:selectedNode()
  return self.registry and self.registry.byKey[self.selectedKey] or nil
end

function physicsUI:findChainForNode(key)
  for index, chain in ipairs(self.draft.chains or {}) do
    for linkIndex, path in ipairs(chain.linkPaths or {}) do
      if physicsChain.pathKey(path) == key then return chain, index, linkIndex end
    end
  end
  return nil
end

function physicsUI:currentChain()
  return self:findChainForNode(self.selectedKey)
end

function physicsUI:settingsForSelection()
  local chain, chainIndex, linkIndex = self:currentChain()
  if not chain then return nil, nil, nil, nil, false end
  local override = linkIndex and linkIndex > 1 and chain.linkOverrides and chain.linkOverrides[linkIndex] or nil
  return mergeSettings(chain.settings, override), chainIndex, linkIndex, chain, override ~= nil
end

local function settingIsOverridden(chain, linkIndex, key)
  if CHAIN_ONLY_SETTINGS[key] then return false end
  if not chain or not linkIndex or linkIndex <= 1 then return false end
  local override = chain.linkOverrides and chain.linkOverrides[linkIndex]
  if type(override) ~= "table" then return false end
  local group, axis = key:match("^(%w+)%.(%w+)$")
  if group == "gravity" or group == "limitRotation" then
    return type(override[group]) == "table" and override[group][axis] ~= nil
  end
  return override[key] ~= nil
end

local function countOverrides(chain, linkIndex)
  local override = chain and chain.linkOverrides and chain.linkOverrides[linkIndex]
  if type(override) ~= "table" then return 0 end
  local count = 0
  for key, value in pairs(override) do
    if key == "gravity" or key == "limitRotation" then
      if type(value) == "table" then for _ in pairs(value) do count = count + 1 end end
    else
      count = count + 1
    end
  end
  return count
end

function physicsUI:writeSelectedSetting(key, value)
  local effective, _, linkIndex, chain = self:settingsForSelection()
  if not chain then return false end
  if CHAIN_ONLY_SETTINGS[key] then
    setSetting(chain.settings, key, value)
  elseif linkIndex and linkIndex > 1 then
    chain.linkOverrides = chain.linkOverrides or {}
    local override = chain.linkOverrides[linkIndex]
    if type(override) ~= "table" then
      override = {}
      chain.linkOverrides[linkIndex] = override
    end
    if key:sub(1, 8) == "gravity." then override.gravity = override.gravity or {}
    elseif key:sub(1, 14) == "limitRotation." then override.limitRotation = override.limitRotation or {} end
    setSetting(override, key, value)
  else
    setSetting(chain.settings, key, value)
  end
  return true
end

function physicsUI:createVisuals()
  if self.hud then return end
  local ok, root = pcall(function() return models:newPart("PhysicsStudioHUD", "HUD") end)
  if not ok or not root then self.status = "Не удалось создать HUD ModelPart"; return end
  self.hud = root
  self.sidebarText = safeCall(root, "newText", "PhysicsStudioTree")
  self.detailsText = safeCall(root, "newText", "PhysicsStudioSettings")
  self.errorText = safeCall(root, "newText", "PhysicsStudioError")
  self.settingTextTasks = {}
  for _, spec in ipairs({
    { "minus", "PhysicsStudioMinus" }, { "value", "PhysicsStudioValue" },
    { "plus", "PhysicsStudioPlus" }, { "inherit", "PhysicsStudioInherit" },
    { "slider", "PhysicsStudioSlider" }, { "choice", "PhysicsStudioChoice" },
  }) do
    local task = safeCall(root, "newText", spec[2])
    self.settingTextTasks[spec[1]] = task
  end
  for _, task in ipairs({ self.sidebarText, self.detailsText }) do
    if task then
      safeCall(task, "setScale", 1)
      safeCall(task, "setOutline", true)
      safeCall(task, "setOutlineColor", 0.02, 0.02, 0.025)
      safeCall(task, "setBackground", true)
      safeCall(task, "setBackgroundColor", 0.035, 0.045, 0.06)
      safeCall(task, "setOpacity", 0.94)
      safeCall(task, "setSeeThrough", true)
      safeCall(task, "setWidth", 250)
      safeCall(task, "setWrap", false)
    end
  end
  if self.errorText then
    safeCall(self.errorText, "setScale", 1)
    safeCall(self.errorText, "setOutline", true)
    safeCall(self.errorText, "setOutlineColor", 0.02, 0.02, 0.025)
    safeCall(self.errorText, "setBackground", true)
    safeCall(self.errorText, "setBackgroundColor", 0.16, 0.025, 0.035)
    safeCall(self.errorText, "setOpacity", 0.97)
    safeCall(self.errorText, "setSeeThrough", true)
    safeCall(self.errorText, "setWidth", 220)
    safeCall(self.errorText, "setWrap", true)
    safeCall(self.errorText, "setText", "")
  end
  for _, task in pairs(self.settingTextTasks) do
    if task then
      safeCall(task, "setScale", 1)
      safeCall(task, "setOutline", true)
      safeCall(task, "setOutlineColor", 0.02, 0.02, 0.025)
      safeCall(task, "setBackground", false)
      safeCall(task, "setOpacity", 1)
      safeCall(task, "setSeeThrough", true)
      safeCall(task, "setWidth", 250)
      safeCall(task, "setWrap", false)
    end
  end
end

function physicsUI:toggle()
  if self.open and self.editingSetting then self:commitNumberEdit(false) end
  self.open = not self.open
  if self.open then
    self.cursorWasUnlocked = safeCall(host, "isCursorUnlocked") == true
    safeCall(host, "setUnlockCursor", true)
    self:createVisuals()
    if self.hud then safeCall(self.hud, "setVisible", true) end
    self:refresh()
  else
    if self.hud then safeCall(self.hud, "setVisible", false) end
    safeCall(host, "setUnlockCursor", self.cursorWasUnlocked == true)
    self.cursorWasUnlocked = nil
    self.searchFocused = false
    self.dragging = false
    self.repeatAction = nil
    self.hoverTarget = nil
  end
end

function physicsUI:tick()
  local repeatAction = self.repeatAction
  if not self.open or not repeatAction then return end
  repeatAction.ticks = repeatAction.ticks + 1
  if repeatAction.ticks < 6 then return end
  local interval = repeatAction.ticks >= 20 and 2 or 3
  if (repeatAction.ticks - 6) % interval == 0 then
    self:adjustSetting(repeatAction.row, repeatAction.direction)
  end
end

function physicsUI:visibleNodes()
  local result = {}
  local needle = string.lower(self.search or "")
  local function matching(node)
    if needle == "" then return true end
    if string.find(string.lower(node.name or ""), needle, 1, true) then return true end
    for _, child in ipairs(node.children or {}) do if matching(child) then return true end end
    return false
  end
  local function append(node)
    if needle ~= "" and not matching(node) then return end
    result[#result + 1] = node
    local forceExpanded = needle ~= ""
    if forceExpanded or not self.collapsedKeys[node.key] then
      for _, child in ipairs(node.children or {}) do append(child) end
    end
  end
  for _, root in ipairs(self.registry and self.registry.roots or {}) do append(root) end
  return result
end

function physicsUI:selectNode(node)
  self.selectedKey = node.key
  local migration = self.pendingMigration
  local migrationBranch = migration and migration.result and migration.result.unresolvedBranches[1] or nil
  if migrationBranch then
    for _, candidate in ipairs(migrationBranch.candidates or {}) do
      if candidate.key == node.key then
        migration.branchChoices[migrationBranch.parentKey] = candidate.key
        local result = physicsChain.discover(self.registry, migration.rootKey, migration.branchChoices)
        migration.result = result
        if result and result.complete then
          local target = migration.target
          local chain = {
            rootPath = cloneTable(target.rootPath), linkPaths = cloneTable(result.linkPaths),
            branchChoices = cloneTable(migration.branchChoices), enabled = target.enabled == true,
            settings = newDefaultSettings(), linkOverrides = {}, migrationNotice = true,
            legacyEndpoint = cloneTable(target.legacyEndpoint),
          }
          local conflict = physicsChain.findOverlap(self.draft.chains, chain)
          if conflict then
            self.status = "Перенос цепи пересекается с другой цепью"
          else
            self.draft.chains[#self.draft.chains + 1] = chain
            for index = #self.draft.pendingLegacyTargets, 1, -1 do
              if physicsChain.pathKey(self.draft.pendingLegacyTargets[index].rootPath) == physicsChain.pathKey(target.rootPath) then
                table.remove(self.draft.pendingLegacyTargets, index)
              end
            end
            self.pendingMigration = nil
            self.status = "Старая цепь перенесена; нажми «Сохранить»"
            self:notifyChanged()
            -- Continue with the next legacy chain instead of leaving the save
            -- blocked with pending entries but no active branch selection.
            self:migrateUnambiguousTargets()
            if #((self.draft.pendingLegacyTargets) or {}) == 0 then
              self.status = "Все старые цепи перенесены; нажми «Сохранить»"
            elseif self.pendingMigration then
              self.status = "Есть ещё старая цепь: выбери ветвь в Outliner"
            else
              self.status = "Осталась старая цепь, которую нельзя сопоставить с моделью"
            end
          end
        elseif result and result.unresolvedBranches[1] then
          self.status = "Есть ещё ветвь: выбери продолжение в дереве"
        else
          self.status = "Перенос цепи не разрешился"
        end
        self:refresh()
        return
      end
    end
  end
  local pending = self.pendingAssignment
  local branch = pending and pending.result and pending.result.unresolvedBranches[1] or nil
  if branch then
    for _, candidate in ipairs(branch.candidates or {}) do
      if candidate.key == node.key then
        pending.branchChoices[branch.parentKey] = candidate.key
        local result = physicsChain.discover(self.registry, pending.rootKey, pending.branchChoices)
        pending.result = result
        if result and result.complete then
          pending.ready = true
          self.status = "Цепь найдена: " .. #result.linkKeys .. " звеньев. Нажми «Применить»"
        elseif result and result.unresolvedBranches[1] then
          self.status = "Есть ещё ветвь: выбери продолжение в дереве"
        else
          self.status = "Не удалось продолжить цепь"
        end
        self:refresh()
        return
      end
    end
  end
  self:refresh()
end

function physicsUI:refresh()
  if not self.open then return end
  self:createVisuals()
  if not self.hud then return end
  local size = safeCall(client, "getScaledWindowSize")
  local width = size and tonumber(size.x) or 427
  local height = size and tonumber(size.y) or 240
  local leftRowStep = measuredLineHeight()
  local panelWidth = math.max(300, math.min(440, width - 18))
  local panelHeight = math.max(180, height - 12)
  local treePanelHeight = math.min(236, math.max(180, height - 14))
  local leftWidth = math.max(130, math.min(174, math.floor(panelWidth * 0.40)))
  local rightWidth = panelWidth - leftWidth - 12
  local hasSelectedChain = self:currentChain() ~= nil
  local estimatedDetailsLines = hasSelectedChain
    and (4 + #PARAMS + (self.diagnostics and 6 or 0) + 3) or 7
  if self.pendingAssignment and self.pendingAssignment.result and self.pendingAssignment.result.complete then
    estimatedDetailsLines = estimatedDetailsLines + 2
  end
  local detailScale = math.min(1, math.max(0.45,
    (panelHeight - 6) / math.max(1, estimatedDetailsLines * leftRowStep)))
  local rightRowStep = leftRowStep * detailScale
  self.layout = { x = 9, y = 7, width = panelWidth, height = panelHeight,
    leftWidth = leftWidth, rightWidth = rightWidth, lineHeight = leftRowStep,
    leftLineHeight = leftRowStep, rightLineHeight = rightRowStep, detailScale = detailScale }
  if self.errorText then
    local messageWidth = math.max(140, math.min(280, math.floor(width * 0.30)))
    local messageX = self.layout.x + panelWidth + 8
    if messageX + messageWidth > width - 8 then
      messageX = math.max(self.layout.x + leftWidth + 8, width - messageWidth - 8)
      messageWidth = math.max(140, math.min(messageWidth, width - messageX - 8))
    end
    safeCall(self.errorText, "setPos", -messageX, -(self.layout.y + 10), -0.3)
    safeCall(self.errorText, "setWidth", messageWidth)
    safeCall(self.errorText, "setWrap", true)
  end
  self.settingColumns, self.sliderSegments = settingColumns(rightWidth / detailScale, detailScale)
  safeCall(self.sidebarText, "setPos", -self.layout.x, -self.layout.y, 0)
  safeCall(self.detailsText, "setPos", -(self.layout.x + leftWidth + 8), -self.layout.y, -0.1)
  safeCall(self.sidebarText, "setWidth", leftWidth)
  safeCall(self.detailsText, "setScale", detailScale, detailScale, detailScale)
  safeCall(self.detailsText, "setWidth", math.floor(rightWidth / detailScale))

  local visible = self:visibleNodes()
  local maxRows = math.max(1, math.floor((treePanelHeight - 82) / leftRowStep))
  self.treeOffset = math.max(0, math.min(self.treeOffset, math.max(0, #visible - maxRows)))
  local searchHovered = self.hoverTarget and self.hoverTarget.kind == "search"
  local searchColor = searchHovered and "§b" or "§7"
  local leftLines = { "§6Physics Studio — Outliner§r", searchColor .. "Поиск: §f" .. (self.searchFocused and "▏" or "") .. self.search,
    "§8⯆ раскрыть   имя выбрать" }
  local rowMap = {}
  for index = self.treeOffset + 1, math.min(#visible, self.treeOffset + maxRows) do
    local node = visible[index]
    local hasChildren = #(node.children or {}) > 0
    local indentText = string.rep(" ", math.floor(nodeIndent(node) / 6))
    local marker = hasChildren and (self.collapsedKeys[node.key] and "▸" or "▾") or "·"
    local chain = self:findChainForNode(node.key)
    local badge = chain and " §a●" or ""
    local hovered = self.hoverTarget and self.hoverTarget.key == node.key
      and (self.hoverTarget.kind == "tree-node" or self.hoverTarget.kind == "tree-disclosure")
    local hoveredDisclosure = hovered and self.hoverTarget.kind == "tree-disclosure"
    local selected = node.key == self.selectedKey
    -- Keep this prefix the same width for selected and hovered rows so the arrow never shifts under the cursor.
    local prefixText = "  "
    local prefixColor = hovered and "§b" or (selected and "§e" or "§7")
    local markerColor = hoveredDisclosure and "§b" or (selected and "§e" or "§7")
    local nameColor = hovered and not selected and "§b" or (selected and "§e" or "§7")
    local markerX = textWidth(prefixText .. indentText)
    local markerWidth = textWidth(marker)
    leftLines[#leftLines + 1] = prefixColor .. prefixText .. "§r" .. indentText
      .. markerColor .. marker .. "§r " .. nameColor .. node.name .. badge .. "§r"
    rowMap[#rowMap + 1] = { node = node,
      disclosureStart = math.max(0, markerX - 2), disclosureEnd = markerX + markerWidth + 2,
      hasChildren = hasChildren }
  end
  self.visibleTreeRows = rowMap
  leftLines[#leftLines + 1] = "§8────────────────"
  local actionLabel, actionColor = "Назначить цепь", "§a"
  if self.pendingMigration then actionLabel, actionColor = "Перенос: выбери ветвь", "§e" end
  if self.pendingAssignment then
    actionLabel, actionColor = self.pendingAssignment.ready and "Применить цепь" or "Выбери ветвь",
      self.pendingAssignment.ready and "§b" or "§e"
  end
  local assignHovered = self.hoverTarget and self.hoverTarget.kind == "left-assign"
  local deleteHovered = self.hoverTarget and self.hoverTarget.kind == "left-delete"
  leftLines[#leftLines + 1] = (assignHovered and "§b" or actionColor) .. actionLabel
    .. " §7| " .. (deleteHovered and "§b" or "§c") .. "Удалить"
  self.leftActionHitboxes = {
    assign = textRange("", actionLabel),
    delete = textRange(actionLabel .. " | ", "Удалить"),
  }
  self.leftActionLine = 4 + #rowMap + 1
  local pendingLegacyCount = #((self.draft and self.draft.pendingLegacyTargets) or {})
  self.pendingLegacyDeleteLine = nil
  self.pendingLegacyDeleteHitbox = nil
  if pendingLegacyCount > 0 then
    local actionLabel = "Удалить переносы (" .. pendingLegacyCount .. ")"
    local hovered = self.hoverTarget and self.hoverTarget.kind == "left-clear-pending"
    leftLines[#leftLines + 1] = (hovered and "§b" or "§c") .. actionLabel
    self.pendingLegacyDeleteLine = self.leftActionLine + 1
    self.pendingLegacyDeleteHitbox = textRange("", actionLabel)
  end
  leftLines[#leftLines + 1] = "§7F8 — закрыть"
  self.treeStartLine = TREE_START_LINE
  self.leftActionY = (self.leftActionLine - 1) * leftRowStep
  safeCall(self.sidebarText, "setText", table.concat(leftLines, "\n"))

  local node = self:selectedNode()
  local chain = self:currentChain()
  local pendingRoot = nil
  for _, pending in ipairs(self.draft.pendingLegacyTargets or {}) do
    if physicsChain.pathKey(pending.rootPath) == self.selectedKey then pendingRoot = pending break end
  end
  local diagnostic = chain and type(self.callbacks.getDiagnostics) == "function"
    and self.callbacks.getDiagnostics(chain) or nil
  local settingTextLines = { minus = {}, value = {}, plus = {}, inherit = {}, slider = {}, choice = {} }
  local lines = { "§6Physics Studio§r | §f" .. (node and node.name or "—") }
  self.controlLines = {}
  if chain then
    local _, _, selectedLinkIndex = self:currentChain()
    local rootNode = nodeForPath(self.registry, chain.rootPath)
    self.controlLines.enabled = #lines + 1
    local enabledHovered = self.hoverTarget and self.hoverTarget.kind == "enabled"
    lines[#lines + 1] = "§eЦепь: §f" .. (rootNode and rootNode.name or "?")
      .. " §7| " .. #(chain.linkPaths or {}) .. " звеньев | "
      .. (enabledHovered and "§b" or "§e") .. "Физика "
      .. (chain.enabled and "ВКЛ" or "ВЫКЛ") .. (enabledHovered and " [нажать]" or " §8[нажать]")
    lines[#lines + 1] = "§8Путь: " .. shortPath(node)
    local effective = self:settingsForSelection()
    if selectedLinkIndex and selectedLinkIndex > 1 then
      local overrideCount = countOverrides(chain, selectedLinkIndex)
      lines[#lines + 1] = chain.migrationNotice and "§eПрофиль сброшен — сохрани настройки" or
        ("§8Звено " .. selectedLinkIndex .. "/" .. #chain.linkPaths .. ": отдельно "
          .. overrideCount .. ", остальное наследуется")
    else
      lines[#lines + 1] = chain.migrationNotice and "§eПрофиль сброшен — сохрани настройки"
        or "§8Профиль цепи применяется ко всем звеньям"
    end
    self.settingStartLine = #lines + 1
    local settingsRows, hitboxes = {}, {}
    local columns = self.settingColumns
    for paramIndex, param in ipairs(PARAMS) do
      if param.group then
        settingsRows[#settingsRows + 1] = {
          kind = "group", label = "§6" .. truncateToWidth(param.group, columns.labelWidth) .. "§r", parts = {},
        }
        hitboxes[#hitboxes + 1] = {}
      elseif param.kind == "choice" then
        local names = CHOICE_LABELS[param.key] or {}
        local values = CHOICE_VALUES[param.key] or {}
        local value = names[effective[param.key]] or names[values[1]] or "—"
        local overridden = not param.chainOnly and settingIsOverridden(chain, selectedLinkIndex, param.key)
        local rowIndex = #settingsRows + 1
        local choiceText = "[‹ " .. value .. " ›]"
        local hoverChoice = self.hoverTarget and self.hoverTarget.kind == "setting-choice"
          and self.hoverTarget.row == rowIndex
        local hoverInherit = self.hoverTarget and self.hoverTarget.kind == "setting-inherit"
          and self.hoverTarget.row == rowIndex
        local displayLabel = param.shortLabel or param.label
        local choiceStart = columns.controlStart * detailScale
        local choiceEnd = choiceStart + textWidth(choiceText) * detailScale
        local inheritStart = overridden and columns.inheritStart * detailScale or nil
        local inheritEnd = overridden and (inheritStart + textWidth("[↶]") * detailScale) or nil
        local inheritText = overridden and ((hoverInherit and "§b" or "§8") .. "[↶]§r") or ""
        settingsRows[#settingsRows + 1] = { kind = "parameter", paramIndex = paramIndex,
          overridden = overridden, label = "§f" .. displayLabel .. "§r",
          parts = {
            choice = (hoverChoice and "§b" or "§f") .. choiceText .. "§r",
            inherit = inheritText,
          } }
        hitboxes[#hitboxes + 1] = {
          choiceStart = choiceStart, choiceEnd = choiceEnd,
          inheritStart = inheritStart, inheritEnd = inheritEnd,
        }
      else
        local value = settingValue(effective, param.key)
        local overridden = not param.chainOnly and settingIsOverridden(chain, selectedLinkIndex, param.key)
        local displayLabel = (param.shortLabel or param.label) .. (overridden and "*" or "")
        local range = param.max - param.min
        local fraction = range > 0 and math.max(0, math.min(1, ((tonumber(value) or 0) - param.min) / range)) or 0
        local filled = math.floor(fraction * self.sliderSegments + 0.5)
        local displayRow = #settingsRows + 1
        local hoverKind = self.hoverTarget and self.hoverTarget.row == displayRow and self.hoverTarget.kind or nil
        local minusColor = hoverKind == "setting-minus" and "§b" or "§7"
        local plusColor = hoverKind == "setting-plus" and "§b" or "§a"
        local valueColor = hoverKind == "setting-value" and "§b" or "§f"
        local sliderColor = hoverKind == "setting-slider" and "§f" or "§b"
        local edit = self.editingSetting and self.editingSetting.row == displayRow and self.editingSetting or nil
        local valueText = edit and edit.text or formatValue(value, param.decimals)
        local inputCursor = edit and "▏" or ""
        local sliderText = "[" .. (sliderColor == "§b" and "§b" or "§f")
          .. string.rep("■", filled) .. "§8" .. string.rep("·", self.sliderSegments - filled) .. "§r]"
        local inputColor = edit and "§e" or valueColor
        local valueCell = inputColor .. "["
          .. rightAlignToWidth(valueText .. inputCursor, columns.valueContentWidth) .. "]§r"
        local inheritColor = hoverKind == "setting-inherit" and "§b" or "§8"
        local inheritText = overridden and (inheritColor .. "[↶]§r") or ""
        settingsRows[#settingsRows + 1] = { kind = "parameter", paramIndex = paramIndex,
          overridden = overridden,
          label = "§f" .. displayLabel .. "§r",
          parts = {
            minus = minusColor .. "[−]§r",
            value = valueCell,
            plus = plusColor .. "[+]§r",
            inherit = inheritText,
            slider = sliderText,
          } }
        hitboxes[#hitboxes + 1] = {
          minusStart = columns.minusStart * detailScale,
          minusEnd = (columns.minusStart + textWidth("[−]")) * detailScale,
          valueStart = columns.valueStart * detailScale,
          valueEnd = (columns.valueStart + textWidth(valueCell)) * detailScale,
          plusStart = columns.plusStart * detailScale,
          plusEnd = (columns.plusStart + textWidth("[+]")) * detailScale,
          inheritStart = overridden and columns.inheritStart * detailScale or nil,
          inheritEnd = overridden and (columns.inheritStart + textWidth("[↶]")) * detailScale or nil,
          sliderStart = (columns.sliderStart + textWidth("[")) * detailScale,
          sliderEnd = (columns.sliderStart + textWidth(sliderText) - textWidth("]")) * detailScale,
        }
      end
    end
    self.maxSettingsOffset = 0
    self.settingsOffset = 0
    self.visibleSettingHitboxes, self.visibleSettingsRows = {}, {}
    for row = 1, #settingsRows do
      lines[#lines + 1] = truncateToWidth(settingsRows[row].label, columns.labelWidth)
      local parts = settingsRows[row].parts or {}
      for name, textLines in pairs(settingTextLines) do
        textLines[#textLines + 1] = parts[name] or ""
      end
      self.visibleSettingsRows[row] = settingsRows[row]
      self.visibleSettingHitboxes[row] = hitboxes[row]
    end
    if self.diagnostics and diagnostic then
      local root = diagnostic.rootDelta or { x = 0, y = 0, z = 0 }
      local acceleration = diagnostic.rootAcceleration or { x = 0, y = 0, z = 0 }
      lines[#lines + 1] = "§8Смещение/тик: " .. formatValue(root.x, 3) .. ", "
        .. formatValue(root.y, 3) .. ", " .. formatValue(root.z, 3)
        .. " yaw " .. formatValue(math.deg(diagnostic.yawDelta or 0), 1) .. "°"
      lines[#lines + 1] = "§8Ускорение корня: " .. formatValue(acceleration.x, 1) .. ", "
        .. formatValue(acceleration.y, 1) .. ", " .. formatValue(acceleration.z, 1) .. " бл/с²; поворот "
        .. formatValue(math.deg(diagnostic.rootYawAcceleration or 0), 0) .. "°/с²"
      if diagnostic.gravitySpace == "world" then
        lines[#lines + 1] = diagnostic.gravityFrameAvailable and "§8Кадр тяжести: мир, мировой поворот доступен"
          or "§cКадр тяжести: нет мировой матрицы, временно локально"
      end
      local selectedLink = diagnostic.links and diagnostic.links[selectedLinkIndex or 1]
      if selectedLink then
        local target, offset = selectedLink.target or {}, selectedLink.offset or {}
        lines[#lines + 1] = "§8Анимация XYZ: " .. formatValue(target.x, 1) .. ", "
          .. formatValue(target.y, 1) .. ", " .. formatValue(target.z, 1) .. "°"
        lines[#lines + 1] = "§8Физика rotvec: " .. formatValue(offset.x, 1) .. ", "
          .. formatValue(offset.y, 1) .. ", " .. formatValue(offset.z, 1) .. "°; угол "
          .. formatValue(selectedLink.angle, 1) .. "° / " .. formatValue(selectedLink.speed, 1) .. "°/с"
        lines[#lines + 1] = "§8Поток: " .. formatValue(selectedLink.airflowSpeed, 1)
          .. " бл/с; поток " .. formatValue(selectedLink.airflowAcceleration, 1)
          .. "; инерция " .. formatValue(selectedLink.avatarInertiaAcceleration, 1) .. " бл/с²"
      end
    end
  elseif pendingRoot then
    lines[#lines + 1] = "§eСтарая настройка ожидает ветвь"
    lines[#lines + 1] = "§7Выбери продолжение в дереве"
    lines[#lines + 1] = "§8Сохранение заблокировано до завершения переноса"
    self.visibleSettingsRows, self.visibleSettingHitboxes = {}, {}
  else
    lines[#lines + 1] = "§cЦепь не назначена"
    lines[#lines + 1] = node and node.partType == "GROUP" and "§7Нажми «Назначить цепь» слева" or "§7Назначать можно только GROUP"
    lines[#lines + 1] = "§7Сначала покажу состав цепи и крепления"
    self.maxSettingsOffset = 0
    self.settingsOffset = 0
    self.visibleSettingsRows, self.visibleSettingHitboxes = {}, {}
    self.settingStartLine = nil
  end

  if self.pendingAssignment then
    local result = self.pendingAssignment.result
    if result and result.complete then
      lines[#lines + 1] = "§bПредпросмотр: " .. table.concat((function()
        local names = {}
        for _, key in ipairs(result.linkKeys) do names[#names + 1] = self.registry.byKey[key].name end
        return names
      end)(), " → ")
      if #result.attachments > 0 then
        local attachments = {}
        for _, item in ipairs(result.attachments) do attachments[#attachments + 1] = item.name end
        lines[#lines + 1] = "§8Крепления: " .. table.concat(attachments, ", ")
      end
    end
  end
  self.footerLine = #lines + 1
  lines[#lines + 1] = "§aСохранить §7| §cОтмена §7| §eСброс §7| §bДиагн."
  self.presetLine = #lines + 1
  local importHovered = self.hoverTarget and self.hoverTarget.kind == "footer-import"
  lines[#lines + 1] = (importHovered and "§f" or "§b") .. "Импорт пресета"
  local hint
  if self.editingSetting then
    hint = "Ввод числа: Enter применить, Esc отменить, Backspace стереть."
  elseif self.hoverTarget and (self.hoverTarget.kind == "setting-plus" or self.hoverTarget.kind == "setting-minus") then
    hint = "Короткий клик — шаг; удерживай для повтора."
  end
  local hovered = self.hoverTarget and self.visibleSettingsRows
    and self.visibleSettingsRows[self.hoverTarget.row]
  if not hint and hovered and hovered.kind == "parameter" then
    local param = PARAMS[hovered.paramIndex]
    hint = param and param.help
  end
  if not hint then
    local hoverHints = {
      search = "Введи часть имени кости, чтобы отфильтровать дерево.",
      ["tree-disclosure"] = "Раскрывает или сворачивает ветвь дерева.",
      ["tree-node"] = "Выбирает кость и показывает её назначенную цепь.",
      ["left-assign"] = "Назначает физическую цепь от выбранной группы вниз по иерархии.",
      ["left-delete"] = "Удаляет старую запись на выбранной кости, если она есть; иначе удаляет назначенную цепь.",
      ["left-clear-pending"] = "Удаляет только старые записи переноса. Новые назначенные цепи и их настройки сохраняются.",
      enabled = "Включает или выключает физику выбранной цепи.",
      ["setting-inherit"] = "Убирает настройку этого звена и возвращает наследование от цепи.",
      ["setting-choice"] = "Переключает выбранный тип ограничения сустава.",
      ["setting-value"] = "Нажми, чтобы ввести число с клавиатуры.",
      ["setting-slider"] = "Перетащи ползунок, чтобы менять значение плавно.",
      ["footer-save"] = "Сохраняет текущие настройки и удаляет решённые записи миграции.",
      ["footer-cancel"] = "Отменяет черновик и загружает последнее сохранённое состояние.",
      ["footer-reset"] = "Сбрасывает настройки выбранной цепи или звена.",
      ["footer-diagnostics"] = "Показывает или скрывает диагностические данные физики.",
      ["footer-import"] = "Загружает пресет в черновик; нажми «Сохранить», чтобы применить его.",
    }
    local hoverKind = self.hoverTarget and self.hoverTarget.kind
    hint = hoverHints[hoverKind]
  end
  if self.errorText then
    local errorActive = isErrorStatus(self.status)
    safeCall(self.errorText, "setBackgroundColor",
      errorActive and 0.16 or (hint and 0.025 or 0.035),
      errorActive and 0.025 or (hint and 0.07 or 0.045),
      errorActive and 0.035 or (hint and 0.16 or 0.06))
    safeCall(self.errorText, "setText", messagePanelText(self, self.status, hint))
  end
  local footerHovered = self.hoverTarget and self.hoverTarget.kind or nil
  local saveColor = footerHovered == "footer-save" and "§b" or "§a"
  local cancelColor = footerHovered == "footer-cancel" and "§b" or "§c"
  local resetColor = footerHovered == "footer-reset" and "§b" or "§e"
  local diagColor = footerHovered == "footer-diagnostics" and "§f" or "§b"
  self.footerHitboxes = {
    save = textRange("", "Сохранить"),
    cancel = textRange("Сохранить | ", "Отмена"),
    reset = textRange("Сохранить | Отмена | ", "Сброс"),
    diagnostics = textRange("Сохранить | Отмена | Сброс | ", "Диагн."),
    import = textRange("", "Импорт пресета"),
  }
  for _, hitbox in pairs(self.footerHitboxes) do
    hitbox.start = hitbox.start * detailScale
    hitbox.finish = hitbox.finish * detailScale
  end
  self.footerY = (self.footerLine - 1) * rightRowStep
  lines[self.footerLine] = saveColor .. "Сохранить §7| " .. cancelColor .. "Отмена §7| "
    .. resetColor .. "Сброс §7| " .. diagColor .. "Диагн."
  safeCall(self.detailsText, "setText", table.concat(lines, "\n"))
  local columns = self.settingColumns
  local panelX = self.layout.x + leftWidth + 8
  local controlY = self.settingStartLine
    and (self.layout.y + (self.settingStartLine - 1) * rightRowStep) or self.layout.y
  local positions = {
    minus = columns.minusStart * detailScale, value = columns.valueStart * detailScale,
    plus = columns.plusStart * detailScale, inherit = columns.inheritStart * detailScale,
    slider = columns.sliderStart * detailScale, choice = columns.controlStart * detailScale,
  }
  for name, task in pairs(self.settingTextTasks or {}) do
    local x = positions[name] or columns.controlStart
    if positions[name] == nil then x = x * detailScale end
    safeCall(task, "setPos", -(panelX + x), -controlY, -0.2)
    safeCall(task, "setScale", detailScale, detailScale, detailScale)
    safeCall(task, "setWidth", math.max(0, math.floor(rightWidth / detailScale - x / detailScale)))
    safeCall(task, "setText", table.concat(settingTextLines[name] or {}, "\n"))
  end
end

function physicsUI:beginAssignment()
  local node = self:selectedNode()
  if not node or node.partType ~= "GROUP" then
    self.status = "Выбери GROUP ModelPart"
    self:refresh()
    return
  end
  local existing = self:findChainForNode(node.key)
  local rootKey = existing and chainKey(existing) or node.key
  local choices = cloneTable(existing and existing.branchChoices or self.branchChoices[rootKey] or {})
  local result, err = physicsChain.discover(self.registry, rootKey, choices)
  if not result then
    self.status = "Цепь не найдена: " .. text(err)
    self:refresh()
    return
  end
  self.pendingAssignment = { rootKey = rootKey, branchChoices = choices, result = result, ready = result.complete,
    replace = existing ~= nil }
  if result.complete then
    self.status = "Проверь состав и крепления, затем нажми «Применить цепь»"
  elseif result.unresolvedBranches and result.unresolvedBranches[1] then
    self.status = "Неоднозначная ветвь: выбери продолжение в дереве"
  else
    self.pendingAssignment = nil
    self.status = "Нулевой или некорректный интервал между pivot; цепь не назначена"
  end
  self:refresh()
end

function physicsUI:applyAssignment()
  local pending = self.pendingAssignment
  if not pending then self:beginAssignment(); return end
  if not pending.ready or not pending.result or not pending.result.complete then
    self.status = "Сначала выбери ветвь в Outliner"
    self:refresh()
    return
  end
  local result = pending.result
  local candidate = {
    rootPath = cloneTable(result.rootPath),
    linkPaths = cloneTable(result.linkPaths),
    branchChoices = cloneTable(pending.branchChoices),
    enabled = true,
    settings = newDefaultSettings(),
    linkOverrides = {},
  }
  local prior, priorIndex
  for index, chain in ipairs(self.draft.chains or {}) do
    if chainKey(chain) == physicsChain.pathKey(candidate.rootPath) then prior, priorIndex = chain, index end
  end
  if prior then
    candidate.settings = cloneTable(prior.settings)
    candidate.linkOverrides = cloneTable(prior.linkOverrides or {})
    candidate.enabled = prior.enabled
    self.draft.chains[priorIndex] = candidate
  else
    local conflictPath = physicsChain.findOverlap(self.draft.chains, candidate)
    if conflictPath then
      local conflictNode = nodeForPath(self.registry, conflictPath)
      self.status = "Цепь пересекается с " .. (conflictNode and conflictNode.name or shortPath({ path = conflictPath }))
      self:refresh()
      return
    end
    self.draft.chains[#self.draft.chains + 1] = candidate
  end
  self.pendingAssignment = nil
  self.status = "Назначена цепь из " .. #candidate.linkPaths .. " звеньев"
  self:notifyChanged()
  self:refresh()
end

function physicsUI:removeSelected()
  local removedPending = false
  for index = #((self.draft.pendingLegacyTargets) or {}), 1, -1 do
    if physicsChain.pathKey(self.draft.pendingLegacyTargets[index].rootPath) == self.selectedKey then
      table.remove(self.draft.pendingLegacyTargets, index)
      removedPending = true
    end
  end
  if removedPending then
    self.status = "Старая запись переноса удалена"
  else
    local _, chainIndex = self:currentChain()
    if chainIndex then
      table.remove(self.draft.chains, chainIndex)
      self.status = "Цепь удалена целиком"
    else
      self.status = "На этой части нет цепи"
    end
  end
  self.pendingAssignment = nil
  self:notifyChanged()
  if removedPending then
    self:migrateUnambiguousTargets()
    if #((self.draft.pendingLegacyTargets) or {}) == 0 then
      self.status = "Перенос удалён; оставшиеся настройки можно сохранить"
    elseif self.pendingMigration then
      self.status = "Есть ещё старая цепь: выбери ветвь в Outliner"
    end
  end
  self:refresh()
end

function physicsUI:adjustSetting(rowIndex, direction)
  local chain = self:currentChain()
  local entry = self.visibleSettingsRows and self.visibleSettingsRows[rowIndex]
  local param = entry and entry.paramIndex and PARAMS[entry.paramIndex]
  if not chain or not param then return end
  local settings = self:settingsForSelection()
  local value = quantizeSetting(param,
    (tonumber(settingValue(settings, param.key)) or 0) + direction * param.step)
  self:writeSelectedSetting(param.key, value)
  self:notifyChanged()
  self:refresh()
end

function physicsUI:setSlider(rowIndex, columnX, trackStart, trackEnd)
  local entry = self.visibleSettingsRows and self.visibleSettingsRows[rowIndex]
  local param = entry and entry.paramIndex and PARAMS[entry.paramIndex]
  local chain = self:currentChain()
  if not chain or not param or trackEnd <= trackStart then return end
  local fraction = math.max(0, math.min(1, (columnX - trackStart) / (trackEnd - trackStart)))
  local rawValue = param.min + fraction * (param.max - param.min)
  local value = quantizeSetting(param, rawValue)
  self:writeSelectedSetting(param.key, value)
  self:notifyChanged()
  self:refresh()
end

function physicsUI:startNumberEdit(rowIndex)
  local entry = self.visibleSettingsRows and self.visibleSettingsRows[rowIndex]
  local param = entry and entry.paramIndex and PARAMS[entry.paramIndex]
  local chain = self:currentChain()
  if not chain or not param or param.kind == "choice" then return false end
  local settings = self:settingsForSelection()
  local current = tonumber(settingValue(settings, param.key)) or param.min
  self.editingSetting = {
    row = rowIndex,
    key = param.key,
    text = formatValue(current, param.decimals),
    maxLength = math.max(#formatValue(param.min, param.decimals), #formatValue(param.max, param.decimals)),
    replaceOnType = true,
  }
  self.status = "Ввод числа: Enter применить, Esc отменить"
  self:refresh()
  return true
end

function physicsUI:commitNumberEdit(keepInvalid)
  local edit = self.editingSetting
  if not edit then return true end
  local entry = self.visibleSettingsRows and self.visibleSettingsRows[edit.row]
  local param = entry and entry.paramIndex and PARAMS[entry.paramIndex]
  local chain = self:currentChain()
  if not chain or not param or param.key ~= edit.key then
    self.editingSetting = nil
    return false
  end
  local parsed = tonumber(((edit.text or ""):gsub(",", ".")))
  if parsed == nil then
    if keepInvalid then
      self.status = "Введи корректное число, затем нажми Enter"
      self:refresh()
      return false
    end
    self.editingSetting = nil
    self.status = "Некорректный ввод отброшен"
    self:refresh()
    return false
  end
  local settings = self:settingsForSelection()
  local current = tonumber(settingValue(settings, param.key)) or param.min
  local value = quantizeSetting(param, parsed)
  self.editingSetting = nil
  if math.abs(value - current) > 0.0000001 then
    self:writeSelectedSetting(param.key, value)
    self:notifyChanged()
  end
  self.status = "Значение применено: " .. formatValue(value, param.decimals) .. (param.unit or "")
  self:refresh()
  return true
end

function physicsUI:cancelNumberEdit()
  if not self.editingSetting then return false end
  self.editingSetting = nil
  self.status = "Ввод числа отменён"
  self:refresh()
  return true
end

function physicsUI:appendNumberInput(character)
  local edit = self.editingSetting
  if not edit or type(character) ~= "string" then return false end
  local entry = self.visibleSettingsRows and self.visibleSettingsRows[edit.row]
  local param = entry and entry.paramIndex and PARAMS[entry.paramIndex]
  if not param then return true end
  local input = character:gsub(",", ".")
  for index = 1, #input do
    local char = input:sub(index, index)
    if char:match("[%d%.%-]") then
      local base = edit.replaceOnType and "" or edit.text
      local candidate = base .. char
      local hasDot = candidate:find(".", 1, true) ~= nil
      local valid = candidate:match("^%-?%d*%.?%d*$") ~= nil
        and #candidate <= edit.maxLength
        and (param.min < 0 or candidate:sub(1, 1) ~= "-")
        and (param.decimals > 0 or not hasDot)
      if valid then
        edit.text = candidate
        edit.replaceOnType = false
      end
    end
  end
  self:refresh()
  return true
end

function physicsUI:targetAt(localX, localY)
  if localX < 0 or localY < 0 or localY >= self.layout.height then return nil end
  local leftWidth = self.layout.leftWidth

  if localX < leftWidth then
    local leftLineHeight = self.layout.leftLineHeight or self.layout.lineHeight or LINE_HEIGHT
    local line = math.floor(localY / leftLineHeight) + 1
    if line == 2 then return { kind = "search" } end
    if line >= (self.treeStartLine or TREE_START_LINE) and line < (self.leftActionLine or math.huge) then
      local rowIndex = line - (self.treeStartLine or TREE_START_LINE) + 1
      local entry = self.visibleTreeRows and self.visibleTreeRows[rowIndex]
      if not entry then return nil end
      if entry.hasChildren and localX >= entry.disclosureStart and localX < entry.disclosureEnd then
        return { kind = "tree-disclosure", key = entry.node.key }
      end
      return { kind = "tree-node", key = entry.node.key }
    end
    if line == self.pendingLegacyDeleteLine and self.pendingLegacyDeleteHitbox then
      local hitbox = self.pendingLegacyDeleteHitbox
      if localX >= hitbox.start - 2 and localX <= hitbox.finish + 2 then
        return { kind = "left-clear-pending" }
      end
      return nil
    end
    if line == self.leftActionLine and self.leftActionHitboxes then
      local assign = self.leftActionHitboxes.assign
      local delete = self.leftActionHitboxes.delete
      if localX >= assign.start - 2 and localX <= assign.finish + 2 then return { kind = "left-assign" } end
      if localX >= delete.start - 2 and localX <= delete.finish + 2 then return { kind = "left-delete" } end
    end
    return nil
  end

  local rightStart = leftWidth + 8
  if localX < rightStart or localX >= rightStart + (self.layout.rightWidth or 0) then return nil end
  local rightLineHeight = self.layout.rightLineHeight or self.layout.lineHeight or LINE_HEIGHT
  local line = math.floor(localY / rightLineHeight) + 1
  local columnX = localX - rightStart
  local chain = self:currentChain()
  if chain and self.controlLines and line == self.controlLines.enabled then return { kind = "enabled" } end

  if chain and self.settingStartLine and line >= self.settingStartLine and line < self.footerLine then
    local rowIndex = line - self.settingStartLine + 1 + (self.settingsOffset or 0)
    local hitbox = self.visibleSettingHitboxes and self.visibleSettingHitboxes[rowIndex]
    local entry = self.visibleSettingsRows and self.visibleSettingsRows[rowIndex]
    if entry and entry.kind == "parameter" and PARAMS[entry.paramIndex]
      and PARAMS[entry.paramIndex].kind == "choice" then
      if hitbox and hitbox.inheritStart and columnX >= hitbox.inheritStart - 2
        and columnX <= hitbox.inheritEnd + 2 then
        return { kind = "setting-inherit", row = rowIndex }
      end
      if hitbox and columnX >= hitbox.choiceStart - 2 and columnX <= hitbox.choiceEnd + 2 then
        return { kind = "setting-choice", row = rowIndex }
      end
      return nil
    end
    if hitbox and entry and entry.kind == "parameter" then
      if hitbox.inheritStart and columnX >= hitbox.inheritStart - 2
        and columnX <= hitbox.inheritEnd + 2 then
        return { kind = "setting-inherit", row = rowIndex }
      end
      if hitbox.valueStart and columnX >= hitbox.valueStart - 2 and columnX <= hitbox.valueEnd + 2 then
        return { kind = "setting-value", row = rowIndex }
      end
      if columnX >= hitbox.minusStart - 2 and columnX <= hitbox.minusEnd + 2 then
        return { kind = "setting-minus", row = rowIndex }
      end
      if columnX >= hitbox.plusStart - 2 and columnX <= hitbox.plusEnd + 2 then
        return { kind = "setting-plus", row = rowIndex }
      end
      if hitbox.sliderStart and columnX >= hitbox.sliderStart and columnX <= hitbox.sliderEnd then
        return { kind = "setting-slider", row = rowIndex }
      end
    end
  end

  if line == self.footerLine and self.footerHitboxes then
    for _, item in ipairs({
      { kind = "footer-save", hitbox = self.footerHitboxes.save },
      { kind = "footer-cancel", hitbox = self.footerHitboxes.cancel },
      { kind = "footer-reset", hitbox = self.footerHitboxes.reset },
      { kind = "footer-diagnostics", hitbox = self.footerHitboxes.diagnostics },
    }) do
      if columnX >= item.hitbox.start - 2 and columnX <= item.hitbox.finish + 2 then return { kind = item.kind } end
    end
  end
  if line == self.presetLine and self.footerHitboxes and self.footerHitboxes.import then
    local hitbox = self.footerHitboxes.import
    if columnX >= hitbox.start - 2 and columnX <= hitbox.finish + 2 then
      return { kind = "footer-import" }
    end
  end
  return nil
end

function physicsUI:setHoverTarget(target)
  if targetKey(self.hoverTarget) == targetKey(target) then return false end
  self.hoverTarget = target
  self:refresh()
  return true
end

function physicsUI:mouseInside()
  local x, y = getMouseGui()
  return x >= self.layout.x and x <= self.layout.x + self.layout.width
    and y >= self.layout.y and y <= self.layout.y + self.layout.height
end

function physicsUI:onMousePress(button, action)
  if not self.open then return false end
  if action == 0 then
    self.dragging = false
    self.repeatAction = nil
    return self:mouseInside()
  end
  if action ~= 1 or button ~= 0 then return self:mouseInside() end
  local mouseX, mouseY = getMouseGui()
  local localX, localY = mouseX - self.layout.x, mouseY - self.layout.y
  if not self:mouseInside() then
    if self.editingSetting then self:commitNumberEdit(false) end
    return false
  end
  local target = self:targetAt(localX, localY)
  if self.editingSetting and not (target and target.kind == "setting-value"
    and target.row == self.editingSetting.row) then
    self:commitNumberEdit(false)
  end
  self:setHoverTarget(target)
  if not target then
    self.searchFocused = false
    self:refresh()
    return true
  end

  if target.kind == "search" then
    self.searchFocused = true
  else
    self.searchFocused = false
  end

  if target.kind == "tree-disclosure" then
    self.collapsedKeys[target.key] = not self.collapsedKeys[target.key]
  elseif target.kind == "tree-node" then
    local node = self.registry and self.registry.byKey[target.key]
    if node then self:selectNode(node) end
    return true
  elseif target.kind == "left-assign" then
    self:applyAssignment()
    return true
  elseif target.kind == "left-delete" then
    self:removeSelected()
    return true
  elseif target.kind == "left-clear-pending" then
    local count = #((self.draft.pendingLegacyTargets) or {})
    self.draft.pendingLegacyTargets = {}
    self.pendingMigration = nil
    self.status = "Удалено старых записей: " .. count .. "; новые цепи не затронуты. Нажми «Сохранить»"
    self:notifyChanged()
    self:refresh()
    return true
  elseif target.kind == "enabled" then
    local chain = self:currentChain()
    if chain then
      chain.enabled = not chain.enabled
      self.status = chain.enabled and "Физика цепи включена" or "Физика цепи выключена"
      self:notifyChanged()
    end
  elseif target.kind == "setting-minus" then
    self.repeatAction = { kind = target.kind, row = target.row, direction = -1, ticks = 0 }
    self:adjustSetting(target.row, -1)
    return true
  elseif target.kind == "setting-plus" then
    self.repeatAction = { kind = target.kind, row = target.row, direction = 1, ticks = 0 }
    self:adjustSetting(target.row, 1)
    return true
  elseif target.kind == "setting-value" then
    if not self.editingSetting or self.editingSetting.row ~= target.row then
      self:startNumberEdit(target.row)
    end
    return true
  elseif target.kind == "setting-slider" then
    local hitbox = self.visibleSettingHitboxes and self.visibleSettingHitboxes[target.row]
    if hitbox then
      self.dragging = target.row
      self:setSlider(target.row, localX - self.layout.leftWidth - 8, hitbox.sliderStart, hitbox.sliderEnd)
    end
    return true
  elseif target.kind == "setting-choice" then
    local entry = self.visibleSettingsRows and self.visibleSettingsRows[target.row]
    local param = entry and entry.paramIndex and PARAMS[entry.paramIndex]
    local settings = self:settingsForSelection()
    local choices = param and CHOICE_VALUES[param.key]
    if choices and settings then
      local currentIndex = 0
      for index, choice in ipairs(choices) do
        if settings[param.key] == choice then currentIndex = index break end
      end
      local nextValue = choices[currentIndex % #choices + 1]
      self:writeSelectedSetting(param.key, nextValue)
      self:notifyChanged()
    end
    return true
  elseif target.kind == "setting-inherit" then
    local entry = self.visibleSettingsRows and self.visibleSettingsRows[target.row]
    local param = entry and entry.paramIndex and PARAMS[entry.paramIndex]
    local chain, _, linkIndex = self:currentChain()
    local override = chain and linkIndex and chain.linkOverrides and chain.linkOverrides[linkIndex]
    if param and override and linkIndex > 1 then
      local group, axis = param.key:match("^(%w+)%.(%w+)$")
      if (group == "gravity" or group == "limitRotation") and type(override[group]) == "table" then
        override[group][axis] = nil
        if next(override[group]) == nil then override[group] = nil end
      else
        override[param.key] = nil
      end
      if next(override) == nil then chain.linkOverrides[linkIndex] = nil end
      self.status = param.label .. " снова наследуется от цепи"
      self:notifyChanged()
    end
    return true
  elseif target.kind == "footer-save" then
    local ok, err = false, "callback unavailable"
    if #((self.draft.pendingLegacyTargets) or {}) > 0 then
      err = "Сначала разреши все перенесённые цепи"
    elseif type(self.callbacks.onSave) == "function" then
      ok, err = self.callbacks.onSave(cloneTable(self.draft))
    end
    if ok then
      self.status = type(err) == "string" and err or "Настройки сохранены локально"
    elseif err == "Сначала разреши все перенесённые цепи" then
      self.status = "Сохранение заблокировано: " .. text(err)
    else
      self.status = "Ошибка сохранения: " .. text(err)
    end
  elseif target.kind == "footer-import" then
    local imported, err
    if type(self.callbacks.onImport) == "function" then imported, err = self.callbacks.onImport() end
    if imported then
      self.draft = cloneTable(imported)
      self.pendingAssignment = nil
      self:notifyChanged()
      self.status = "Пресет загружен в черновик; нажми «Сохранить»"
    else
      self.status = "Импорт не выполнен: " .. text(err or "callback unavailable")
    end
  elseif target.kind == "footer-cancel" then
    if type(self.callbacks.onCancel) == "function" then self.draft = self.callbacks.onCancel() or self.draft end
    self.pendingAssignment = nil
    self.status = "Черновик отменён"
  elseif target.kind == "footer-reset" then
    local chain, _, linkIndex = self:currentChain()
    if chain and linkIndex and linkIndex > 1 then
      if chain.linkOverrides then chain.linkOverrides[linkIndex] = nil end
      self.status = "Звено снова наследует профиль цепи"
      self:notifyChanged()
    elseif chain then
      chain.settings = newDefaultSettings()
      chain.linkOverrides = {}
      chain.migrationNotice = nil
      self.status = "Профиль цепи сброшен"
      self:notifyChanged()
    else
      self.status = "Выбери назначенную цепь"
    end
  elseif target.kind == "footer-diagnostics" then
    self.diagnostics = not self.diagnostics
    self.status = self.diagnostics and "Диагностика включена" or "Диагностика скрыта"
  end
  self:refresh()
  return true
end

function physicsUI:onMouseMove()
  if not self.open then return false end
  local mouseX, mouseY = getMouseGui()
  local localX, localY = mouseX - self.layout.x, mouseY - self.layout.y
  if self.dragging and self:mouseInside() then
    local line = math.floor(localY / (self.layout.rightLineHeight or self.layout.lineHeight)) + 1
    local rowIndex = line - (self.settingStartLine or 0) + 1 + (self.settingsOffset or 0)
    if rowIndex == self.dragging then
      local hitbox = self.visibleSettingHitboxes and self.visibleSettingHitboxes[rowIndex]
      if hitbox and hitbox.sliderStart then
        self:setSlider(rowIndex, localX - self.layout.leftWidth - 8, hitbox.sliderStart, hitbox.sliderEnd)
      end
    end
  end
  local target = self:mouseInside() and self:targetAt(localX, localY) or nil
  if self.repeatAction and (not target or target.kind ~= self.repeatAction.kind or target.row ~= self.repeatAction.row) then
    self.repeatAction = nil
  end
  self:setHoverTarget(target)
  return false
end

function physicsUI:onMouseScroll(delta)
  if not self.open or not self:mouseInside() then return false end
  if self.editingSetting then self:commitNumberEdit(false) end
  local mouseX = getMouseGui()
  local localX = mouseX - self.layout.x
  if localX < self.layout.leftWidth then
    self.treeOffset = math.max(0, self.treeOffset - (delta > 0 and 1 or -1))
  elseif localX >= self.layout.leftWidth + 8 and self:currentChain() then
    self.settingsOffset = math.max(0, math.min(self.maxSettingsOffset or 0,
      (self.settingsOffset or 0) - (delta > 0 and 1 or -1)))
  else
    return false
  end
  self:refresh()
  return true
end

function physicsUI:onCharTyped(character)
  if not self.open or type(character) ~= "string" then return false end
  if self.editingSetting then return self:appendNumberInput(character) end
  if not self.searchFocused then return false end
  if #self.search < 40 then self.search = self.search .. character end
  self.treeOffset = 0
  self:refresh()
  return true
end

function physicsUI:onKeyPress(key, action)
  if not self.open or action ~= 1 then return false end
  if self.editingSetting then
    if key == 256 then
      self:cancelNumberEdit()
    elseif key == 259 then
      local edit = self.editingSetting
      edit.text = edit.text:sub(1, math.max(0, #edit.text - 1))
      edit.replaceOnType = false
      self:refresh()
    elseif key == 257 or key == 335 then
      self:commitNumberEdit(true)
    end
    return true
  end
  if key == 259 and self.searchFocused then
    self.search = self.search:sub(1, math.max(0, #self.search - 1))
    self.treeOffset = 0
    self:refresh()
    return true
  elseif key == 256 then
    self:toggle()
    return true
  end
  return false
end

return physicsUI
