-- Deepsi animation controller
-- Model-first controller for the Deepsi anthro rabbit/wolf avatar.
-- Keep this file, avatar.json, avatar.png and model.bbmodel in the same avatar folder.
--
-- Layer contract:
--   secondary : priority 0  - tail / ears / cloth life, always playing
--   main      : priority 10 - base loops, sprint turns, one-shots, emotes, hurt, death
--   overlay   : priority 20 - walking turns, attack, mine, item use, bow, shield
--   face      : priority 30 - temporary eyebrow expressions
--   blink     : priority 40 - eyelid blinks, independent from body motion
--
-- Sprint-turns live on the main locomotion layer and phase-match with sprint.
-- Regular turn overlays are reserved for walking and animate the upper body.
-- All clips are authored for this exact rig. Missing clips fall back to idle and
-- are reported once in the log instead of spamming chat every tick.

-- ===========================================================================
-- CONFIG - edit only this block for normal tuning
-- ===========================================================================
local CONFIG = {
  debug = false,                 -- print the resolved animation set once
  hideVanilla = true,            -- hide the vanilla player/armor/elytra meshes

  mainFade = 0.22,               -- base loop crossfade, seconds
  overlayFade = 0.12,            -- overlay crossfade, seconds
  emoteFade = 0.15,              -- emote crossfade, seconds
  hurtFade = 0.06,               -- hurt crossfade, seconds
  deathFade = 0.12,              -- death crossfade, seconds

  moveThreshold = 0.03,          -- blocks/tick considered "moving"
  moveStopGraceTicks = 4,        -- ignore brief speed dips during a turn
  landHardVy = -0.42,            -- vertical speed that selects land_hard
  hurtCooldown = 0.35,           -- seconds between hurt reactions
  pingCooldownTicks = 3,         -- minimum ticks between outgoing pings

  walkSpeedRef = 0.075,          -- blocks/tick at animation speed 1.0
  sprintSpeedRef = 0.13,
  crouchSpeedRef = 0.05,
  swimSpeedRef = 0.08,
  climbSpeedRef = 0.075,
  glideSpeedRef = 0.19,

  turnEnter = 3.5,               -- body-yaw delta that starts the turn overlay
  turnHoldTicks = 6,             -- keep the turn overlay alive after turning stops
  turnSpeedRef = 10.0,           -- yaw delta at animation speed 1.0
}

-- ===========================================================================
-- Clip registry
-- ===========================================================================
local MAIN_LOOPS = {
  "idle", "walk", "sprint", "crouch_idle", "crouch_walk",
  "sprint_turn_left", "sprint_turn_right",
  "jump_air", "fall", "swim_idle", "swim", "climb_idle", "climb",
  "glide", "ride",
}
local MAIN_HOLDS = {
  "walk_start", "walk_stop", "sprint_start", "sprint_stop",
  "crouch_enter", "crouch_exit", "jump_start", "land_soft", "land_hard",
  "swim_enter", "swim_exit", "glide_enter", "glide_exit",
}
local OVERLAY_ONCE = { "attack_right", "attack_left", "mine_right", "mine_left" }
local OVERLAY_LOOPS = {
  "use_item_right", "bow_draw_right", "shield_block_right",
  "use_item_left", "bow_draw_left", "shield_block_left",
  "turn_right", "turn_left",
}
local EMOTE_ONCE = {
  "emote_wave", "emote_bow", "emote_salute", "emote_point",
  "emote_flex", "emote_nod", "emote_shake",
}
local EMOTE_LOOPS = { "emote_dance", "emote_sit", "emote_laugh", "emote_think" }
local FACE_BLINKS = { "face_blink", "face_blink_double", "face_blink_slow" }
local FACE_EXPRESSION_LOOPS = {
  "face_squint", "face_surprised", "face_happy", "face_angry", "face_sad",
  "face_skeptical_left", "face_skeptical_right", "face_focused",
  "face_thinking", "face_relaxed",
}
local CROUCH_POSE_CLIPS = {
  crouch_idle = true,
  crouch_walk = true,
  crouch_enter = true,
  crouch_exit = true,
}

local EMOTE_INFO = {}
for _, name in ipairs(EMOTE_ONCE) do EMOTE_INFO[name] = { loop = false } end
for _, name in ipairs(EMOTE_LOOPS) do EMOTE_INFO[name] = { loop = true } end

local BASE_LOOPS = {}
for _, name in ipairs(MAIN_LOOPS) do BASE_LOOPS[name] = true end

local CLIP_MODE = {}
local CLIP_PRIORITY = {}
for _, name in ipairs(MAIN_LOOPS) do
  CLIP_MODE[name] = "LOOP"
  CLIP_PRIORITY[name] = 10
end
for _, name in ipairs(MAIN_HOLDS) do
  CLIP_MODE[name] = "HOLD"
  CLIP_PRIORITY[name] = 10
end
for _, name in ipairs(OVERLAY_ONCE) do
  CLIP_MODE[name] = "HOLD"
  CLIP_PRIORITY[name] = 20
end
for _, name in ipairs(OVERLAY_LOOPS) do
  CLIP_MODE[name] = "LOOP"
  CLIP_PRIORITY[name] = 20
end
for _, name in ipairs(EMOTE_ONCE) do
  CLIP_MODE[name] = "HOLD"
  CLIP_PRIORITY[name] = 10
end
for _, name in ipairs(EMOTE_LOOPS) do
  CLIP_MODE[name] = "LOOP"
  CLIP_PRIORITY[name] = 10
end
CLIP_MODE.hurt = "HOLD"
CLIP_PRIORITY.hurt = 10
CLIP_MODE.death = "HOLD"
CLIP_PRIORITY.death = 10
CLIP_MODE.secondary = "LOOP"
CLIP_PRIORITY.secondary = 0
for _, name in ipairs(FACE_BLINKS) do
  CLIP_MODE[name] = "ONCE"
  CLIP_PRIORITY[name] = 40
end
for _, name in ipairs(FACE_EXPRESSION_LOOPS) do
  CLIP_MODE[name] = "LOOP"
  CLIP_PRIORITY[name] = 30
end
CLIP_MODE.face_wink_left = "ONCE"
CLIP_PRIORITY.face_wink_left = 40
CLIP_MODE.face_wink_right = "ONCE"
CLIP_PRIORITY.face_wink_right = 40

local BOW_IDS = {
  ["minecraft:bow"] = true,
  ["minecraft:crossbow"] = true,
}

-- ===========================================================================
-- Small utilities
-- ===========================================================================
local DT = 1 / 20
local A = nil
local animationModelKey = nil
local initialised = false
local missingSetWarned = false
local missingClipsWarned = false
local ready = false
local tickCount = 0

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function callBool(obj, method)
  if not obj then return false end
  local ok, value = pcall(function() return obj[method](obj) end)
  return ok and value == true
end

local function callNumber(obj, method)
  if not obj then return nil end
  local ok, value = pcall(function() return obj[method](obj) end)
  if ok and type(value) == "number" then return value end
  return nil
end

local function isHost()
  if not host then return false end
  local ok, value = pcall(function() return host:isHost() end)
  return ok and value == true
end

local function hideVanilla()
  if not CONFIG.hideVanilla or not vanilla_model then return end
  for _, part in ipairs({ "PLAYER", "ARMOR", "ELYTRA" }) do
    local modelPart = vanilla_model[part]
    if modelPart then
      pcall(function() modelPart:setVisible(false) end)
    end
  end
end

local function getAnim(name)
  if not A then return nil end
  local ok, anim = pcall(function() return A[name] end)
  if ok and anim ~= nil then return anim end
  return nil
end

local function getLength(name)
  local anim = getAnim(name)
  if not anim then return 0.3 end
  local ok, length = pcall(function() return anim:getLength() end)
  if ok and type(length) == "number" and length > 0 then return length end
  return 0.3
end

local function getPhase(name)
  local anim = getAnim(name)
  if not anim then return 0 end
  local length = getLength(name)
  local ok, time = pcall(function() return anim:getTime() end)
  if ok and type(time) == "number" and length > 0 then
    return (time % length) / length
  end
  return 0
end

-- ===========================================================================
-- Animation set discovery
-- ===========================================================================
local SIGNATURE = {
  "idle", "walk", "sprint", "crouch_idle",
  "swim", "attack_right", "death", "secondary",
}

local function scoreSet(candidate)
  local score = 0
  for _, name in ipairs(SIGNATURE) do
    local ok, anim = pcall(function() return candidate[name] end)
    if ok and anim ~= nil then score = score + 1 end
  end
  return score
end

local function resolveSet()
  if not animations then return nil, nil end

  local ok, candidate = pcall(function() return animations.model end)
  if ok and candidate and scoreSet(candidate) >= 6 then
    return candidate, "model"
  end

  local best, bestKey, bestScore = nil, nil, 0
  local okScan = pcall(function()
    for key, value in pairs(animations) do
      local score = scoreSet(value)
      if score > bestScore then
        best, bestKey, bestScore = value, key, score
      end
    end
  end)
  if okScan and bestScore >= 4 then return best, bestKey end
  return nil, nil
end

local function initClip(name, priority, mode)
  local anim = getAnim(name)
  if not anim then return false end
  pcall(function() anim:setPriority(priority) end)
  pcall(function() anim:setLoop(mode) end)
  pcall(function() anim:setBlend(0) end)
  pcall(function() anim:setOverrideRot(true) end)
  if CROUCH_POSE_CLIPS[name] then
    pcall(function() anim:setOverridePos(true) end)
  elseif name:sub(1, 5) == "face_" then
    pcall(function() anim:setOverridePos(true) end)
  end
  pcall(function() anim:stop() end)
  return true
end

local function bindSet()
  if A then return true end

  A, animationModelKey = resolveSet()
  if not A then
    if not missingSetWarned then
      print("[Deepsi] Animation set not found. Keep model.bbmodel in the avatar root and preserve its name.")
      missingSetWarned = true
    end
    return false
  end

  local missing = {}
  for name, mode in pairs(CLIP_MODE) do
    if not initClip(name, CLIP_PRIORITY[name] or 10, mode) then
      missing[#missing + 1] = name
    end
  end

  local life = getAnim("secondary")
  if life then
    pcall(function()
      life:setPriority(0)
      life:setLoop("LOOP")
      life:setBlend(1)
      life:setOverrideRot(true)
      life:play()
    end)
  end

  initialised = true
  if #missing > 0 and not missingClipsWarned then
    print("[Deepsi] Missing clips: " .. table.concat(missing, ", "))
    missingClipsWarned = true
  end
  if CONFIG.debug then
    print("[Deepsi] Animation set connected: " .. tostring(animationModelKey))
  end
  return true
end

-- ===========================================================================
-- Layer engine
-- ===========================================================================
local mainLayer = {
  name = "main",
  fade = CONFIG.mainFade,
  weights = {},
  goals = {},
  applied = {},
  target = nil,
}
local overlayLayer = {
  name = "overlay",
  fade = CONFIG.overlayFade,
  weights = {},
  goals = {},
  applied = {},
  target = nil,
}
local faceLayer = {
  name = "face",
  fade = 0.16,
  weights = {},
  goals = {},
  applied = {},
  target = nil,
}
local blinkLayer = {
  name = "blink",
  fade = 0.06,
  weights = {},
  goals = {},
  applied = {},
  target = nil,
}
local activeBlink = nil
local blinkCooldown = 4.0

local function setLayerTarget(layer, name, fade, phase, restart)
  fade = math.max(0.045, fade or layer.fade)
  layer.fade = fade

  if name and not getAnim(name) then
    -- A missing main clip must not leave the avatar in the vanilla pose.
    if layer == mainLayer and getAnim("idle") then
      name = "idle"
    else
      name = nil
    end
  end

  if layer.target == name and not restart then return end

  for other in pairs(layer.weights) do
    layer.goals[other] = 0
  end
  layer.target = name
  if not name then return end

  local anim = getAnim(name)
  if not anim then
    layer.target = nil
    return
  end

  if layer.weights[name] == nil then layer.weights[name] = 0 end
  layer.goals[name] = 1

  local okPlaying, playing = pcall(function() return anim:isPlaying() end)
  if restart or not okPlaying or not playing then
    pcall(function() anim:restart() end)
  end
  pcall(function() anim:setSpeed(1) end)

  if phase and phase > 0 then
    local length = getLength(name)
    pcall(function() anim:setTime(length * phase) end)
  end
end

local function tickLayer(layer)
  local tau = math.max(0.02, layer.fade * 0.42)
  local alpha = 1 - math.exp(-DT / tau)
  local remove = nil

  for name, weight in pairs(layer.weights) do
    local goal = layer.goals[name] or 0
    local nextWeight = weight + (goal - weight) * alpha
    if math.abs(goal - nextWeight) < 0.004 then nextWeight = goal end
    nextWeight = clamp(nextWeight, 0, 1)
    layer.weights[name] = nextWeight

    local anim = getAnim(name)
    if anim then
      -- Only cross the Lua/Java boundary when the weight actually changed.
      if layer.applied[name] ~= nextWeight then
        pcall(function() anim:setBlend(nextWeight) end)
        layer.applied[name] = nextWeight
      end
      if nextWeight <= 0.0001 and goal <= 0 then
        pcall(function() anim:stop() end)
        remove = remove or {}
        remove[#remove + 1] = name
      end
    end
  end

  if remove then
    for _, name in ipairs(remove) do
      layer.weights[name] = nil
      layer.goals[name] = nil
      layer.applied[name] = nil
    end
  end
end

-- ===========================================================================
-- State reading
-- ===========================================================================
local function isGrounded()
  local okPos, pos = pcall(function() return player:getPos() end)
  if okPos and pos and world then
    local okBlock, block = pcall(function()
      return world.getBlockState(pos:add(0, -0.1, 0))
    end)
    if okBlock and block then
      local okSolid, solid = pcall(function() return block:isSolidBlock() end)
      if okSolid and solid then return true end
    end
  end
  return callBool(player, "isOnGround")
end

local function readState()
  local s = {
    pose = "STANDING",
    speed = 0,
    vx = 0,
    vy = 0,
    vz = 0,
    yaw = 0,
    grounded = false,
    moving = false,
    crouch = false,
    sprint = false,
    swim = false,
    glide = false,
    climb = false,
    ride = false,
    inWater = false,
    using = false,
    blocking = false,
    swinging = false,
    swingTime = 0,
    dead = false,
  }

  pcall(function() s.pose = player:getPose() or "STANDING" end)

  local velocity = nil
  pcall(function() velocity = player:getVelocity() end)
  if velocity then
    s.vx = velocity.x or 0
    s.vy = velocity.y or 0
    s.vz = velocity.z or 0
  end
  s.speed = math.sqrt(s.vx * s.vx + s.vz * s.vz)

  s.grounded = isGrounded()
  s.crouch = (s.pose == "CROUCHING") or callBool(player, "isCrouching")
  s.sprint = callBool(player, "isSprinting")
  s.glide = callBool(player, "isGliding") or s.pose == "FALL_FLYING"
  s.swim = callBool(player, "isVisuallySwimming") or s.pose == "SWIMMING"
  s.climb = callBool(player, "isClimbing")
  pcall(function() s.ride = player:getVehicle() ~= nil end)
  s.inWater = callBool(player, "isInWater")
  s.using = callBool(player, "isUsingItem")
  s.blocking = callBool(player, "isBlocking")
  s.swinging = callBool(player, "isSwingingArm")
  s.swingTime = callNumber(player, "getSwingTime") or 0

  local alive = true
  pcall(function() alive = player:isAlive() end)
  local deathTime = 0
  pcall(function() deathTime = player:getDeathTime() or 0 end)
  s.dead = (not alive) or deathTime > 0 or s.pose == "DYING"

  s.moving = s.speed > CONFIG.moveThreshold
  pcall(function() s.yaw = player:getBodyYaw() or 0 end)
  return s
end

-- ===========================================================================
-- Emote / action bookkeeping
-- ===========================================================================
local mainAction = nil
local overlayAction = nil
local deathActive = false
local hurtCooldown = 0
local turnHold = 0
local turnDir = nil
local turnDelta = 0
local toggleActions = {}
local conflictAnimationsDisabled = false
local conflictAnimationsToggle = nil
local clothingActions = {}
local clothingState = { vestRemoved = false, shortsRemoved = false, underwearRemoved = false }
local clothingParts = {}
local ARMOR_PART_PATHS = {
  helmet = {
    "model.root.Head.armor_helmet",
  },
  chest = {
    "model.root.Body.body_chest.armor_chest_body",
    "model.root.LeftArm.L_upper_arm.armor_chest_left_arm",
    "model.root.RightArm.R_upper_arm.armor_chest_right_arm",
  },
  leggings = {
    "model.root.Body.taz.armor_leggings_waist",
    "model.root.LeftLeg.L_upper_leg.armor_leggings_left_thigh",
    "model.root.LeftLeg.L_upper_leg.L_midle_leg.armor_leggings_left_knee",
    "model.root.LeftLeg.L_upper_leg.L_midle_leg.L_down_leg.armor_leggings_left_shin",
    "model.root.RightLeg.R_upper_leg.armor_leggings_right_thigh",
    "model.root.RightLeg.R_upper_leg.R_midle_leg.armor_leggings_right_knee",
    "model.root.RightLeg.R_upper_leg.R_midle_leg.R_down_leg.armor_leggings_right_shin",
  },
  boots = {
    "model.root.LeftLeg.L_upper_leg.L_midle_leg.L_down_leg.L_leg.armor_boots_left",
    "model.root.RightLeg.R_upper_leg.R_midle_leg.R_down_leg.R_leg.armor_boots_right",
  },
}
local ARMOR_EQUIPMENT_SLOTS = {
  { name = "boots", index = 3 },
  { name = "leggings", index = 4 },
  { name = "chest", index = 5 },
  { name = "helmet", index = 6 },
}
local armorParts = {}
local armorState = {}
local armorPartsInitialized = false

local pendingPing = nil
local lastPingTick = -999

local prev = {
  ready = false,
  speed = 0,
  vy = 0,
  grounded = true,
  sprint = false,
  crouch = false,
  swim = false,
  glide = false,
  climb = false,
  ride = false,
  moving = false,
  swinging = false,
  swingTime = 0,
  yaw = 0,
  dead = false,
}

local movementDropTicks = 0

local function stabilizeMovement(s)
  local rawMoving = s.moving
  local bypassGrace = s.crouch or not s.grounded or s.swim or s.glide or s.ride or s.climb
  if rawMoving then
    movementDropTicks = 0
  elseif bypassGrace then
    movementDropTicks = 0
  elseif prev.moving and movementDropTicks < CONFIG.moveStopGraceTicks then
    movementDropTicks = movementDropTicks + 1
    s.moving = true
  else
    movementDropTicks = 0
  end
end

local playEmoteLocal
local cancelEmote
local startHurt

local function queuePing(kind, name)
  if not isHost() then return end
  pendingPing = { kind = kind, name = name }
end

local function resolveModelPart(path)
  local current = models
  for name in path:gmatch("[^%.]+") do
    if not current then return nil end
    local ok, child = pcall(function() return current[name] end)
    if not ok or not child then return nil end
    current = child
  end
  return current
end

local function initArmorParts()
  if armorPartsInitialized then return end
  for slot, paths in pairs(ARMOR_PART_PATHS) do
    local parts = {}
    for _, path in ipairs(paths) do
      local part = resolveModelPart(path)
      if part then parts[#parts + 1] = part end
    end
    armorParts[slot] = parts
  end
  armorPartsInitialized = true
end

local function setArmorSlotVisible(slot, visible)
  for _, part in ipairs(armorParts[slot] or {}) do
    pcall(function() part:setVisible(visible) end)
  end
end

local function readArmorSlot(index)
  local item
  local ok = pcall(function() item = player:getItem(index) end)
  if not ok or not item then return false end
  local isArmor = false
  local armorCallOk = pcall(function() isArmor = item:isArmor() end)
  return armorCallOk and isArmor == true
end

local function updateArmorVisibility()
  initArmorParts()
  for _, equipment in ipairs(ARMOR_EQUIPMENT_SLOTS) do
    local visible = readArmorSlot(equipment.index)
    if armorState[equipment.name] ~= visible then
      armorState[equipment.name] = visible
      setArmorSlotVisible(equipment.name, visible)
    end
  end
end

local function initClothingParts()
  if next(clothingParts) then return end
  clothingParts.vest = resolveModelPart("model.root.Body.body_chest.cloth_west")
  clothingParts.shorts = resolveModelPart("model.root.Body.taz.cloth_short")
  clothingParts.leftShortLeg = resolveModelPart("model.root.LeftLeg.L_upper_leg.L_cloth_leg")
  clothingParts.rightShortLeg = resolveModelPart("model.root.RightLeg.R_upper_leg.R_cloth_leg")
  clothingParts.underwear = resolveModelPart("model.root.Body.taz.underwear")
end

local function clothingStateCode()
  return (clothingState.vestRemoved and 1 or 0)
    + (clothingState.shortsRemoved and 2 or 0)
    + (clothingState.underwearRemoved and 4 or 0)
end

local function applyClothingState(code)
  if type(code) ~= "number" then return end
  code = math.floor(clamp(code, 0, 7))
  clothingState.vestRemoved = code % 2 == 1
  clothingState.shortsRemoved = math.floor(code / 2) % 2 == 1
  clothingState.underwearRemoved = math.floor(code / 4) % 2 == 1

  initClothingParts()
  pcall(function() if clothingParts.vest then clothingParts.vest:setVisible(not clothingState.vestRemoved) end end)
  pcall(function() if clothingParts.shorts then clothingParts.shorts:setVisible(not clothingState.shortsRemoved) end end)
  pcall(function() if clothingParts.leftShortLeg then clothingParts.leftShortLeg:setVisible(not clothingState.shortsRemoved) end end)
  pcall(function() if clothingParts.rightShortLeg then clothingParts.rightShortLeg:setVisible(not clothingState.shortsRemoved) end end)
  pcall(function()
    if clothingParts.underwear then
      clothingParts.underwear:setVisible(clothingState.shortsRemoved and not clothingState.underwearRemoved)
    end
  end)
  pcall(function() if clothingActions.vest then clothingActions.vest:setToggled(clothingState.vestRemoved) end end)
  pcall(function() if clothingActions.shorts then clothingActions.shorts:setToggled(clothingState.shortsRemoved) end end)
  pcall(function() if clothingActions.underwear then clothingActions.underwear:setToggled(clothingState.underwearRemoved) end end)
end

local function onToggleClothing(item, removed)
  if item == "vest" then
    clothingState.vestRemoved = removed == true
  elseif item == "shorts" then
    clothingState.shortsRemoved = removed == true
  elseif item == "underwear" then
    clothingState.underwearRemoved = removed == true
  else
    return
  end
  local code = clothingStateCode()
  applyClothingState(code)
  queuePing("clothing", code)
end

local function applyConflictAnimationMode(disabled)
  conflictAnimationsDisabled = disabled
  if disabled then
    turnHold = 0
    turnDir = nil
  end
  if conflictAnimationsToggle then
    pcall(function() conflictAnimationsToggle:setToggled(disabled) end)
  end
end

local function flushPing()
  if not pendingPing then return end
  if tickCount - lastPingTick < CONFIG.pingCooldownTicks then return end
  if not isHost() then
    pendingPing = nil
    return
  end

  local queued = pendingPing
  pendingPing = nil
  lastPingTick = tickCount

  pcall(function()
    if queued.kind == "play" then
      pings.playEmote(queued.name)
    elseif queued.kind == "stop" then
      pings.stopEmote()
    elseif queued.kind == "hurt" then
      pings.hurt()
    elseif queued.kind == "conflict_animations" then
      pings.setConflictAnimationsDisabled(queued.name)
    elseif queued.kind == "clothing" then
      pings.setClothingState(queued.name)
    end
  end)
end

function pings.playEmote(name)
  if type(name) ~= "string" then return end
  if playEmoteLocal then playEmoteLocal(name, true) end
end

function pings.stopEmote()
  if cancelEmote then cancelEmote(false) end
end

function pings.hurt()
  if startHurt then startHurt() end
end

function pings.setConflictAnimationsDisabled(disabled)
  if type(disabled) ~= "boolean" then return end
  applyConflictAnimationMode(disabled)
end

function pings.setClothingState(code)
  applyClothingState(code)
end

local function updateToggles(activeName)
  for name, action in pairs(toggleActions) do
    pcall(function() action:setToggled(name == activeName) end)
  end
end

local function currentEmote()
  if mainAction and mainAction.kind == "emote" then return mainAction end
  return nil
end

local function canStartEmote()
  if not player then return false end
  local loaded = false
  pcall(function() loaded = player:isLoaded() end)
  if not loaded then return false end

  local s = readState()
  if s.dead or s.pose == "SLEEPING" then return false end
  if s.moving or not s.grounded then return false end
  if s.crouch or s.swim or s.glide or s.climb or s.ride or s.inWater then return false end
  if s.using or s.blocking or s.swinging then return false end
  if mainAction and mainAction.kind == "hurt" then return false end
  return true
end

local function emoteShouldCancel(s)
  if not currentEmote() then return false end
  if s.dead then return true end
  if s.moving or not s.grounded then return true end
  if s.vy > 0.06 then return true end
  if s.crouch or s.swim or s.glide or s.climb or s.ride or s.inWater then return true end
  if s.using or s.blocking or s.swinging then return true end
  return false
end

playEmoteLocal = function(name, fromPing)
  local info = EMOTE_INFO[name]
  if not info then return false end
  if deathActive then return false end
  if mainAction and mainAction.kind == "hurt" then return false end

  if not player then return false end
  local loaded = false
  pcall(function() loaded = player:isLoaded() end)
  if not loaded then return false end

  if not fromPing and not canStartEmote() then return false end
  if fromPing then
    local s = readState()
    if s.dead then return false end
  end

  mainAction = {
    name = name,
    kind = "emote",
    left = info.loop and nil or getLength(name),
    loop = info.loop or false,
  }
  setLayerTarget(mainLayer, name, CONFIG.emoteFade, nil, true)
  updateToggles(info.loop and name or nil)
  return true
end

cancelEmote = function(sendPing)
  local emote = currentEmote()
  if not emote then return false end
  mainAction = nil
  updateToggles(nil)
  if sendPing then queuePing("stop") end
  return true
end

local function requestEmote(name)
  if not playEmoteLocal(name, false) then return false end
  queuePing("play", name)
  return true
end

local function requestStopEmote()
  if not cancelEmote(false) then return false end
  queuePing("stop")
  return true
end

local function startMainAction(name, fade, kind)
  if not getAnim(name) then return false end
  mainAction = {
    name = name,
    kind = kind or "oneshot",
    left = getLength(name),
    loop = false,
  }
  setLayerTarget(mainLayer, name, fade or 0.10, nil, true)
  return true
end

local function startOverlayAction(name)
  if not getAnim(name) then return false end
  overlayAction = {
    name = name,
    left = getLength(name),
  }
  setLayerTarget(overlayLayer, name, CONFIG.overlayFade, nil, true)
  return true
end

local function clearOverlay(fade)
  overlayAction = nil
  setLayerTarget(overlayLayer, nil, fade or CONFIG.overlayFade)
end

startHurt = function()
  if deathActive then return end
  if mainAction and mainAction.kind == "hurt" then return end
  cancelEmote(true)
  clearOverlay(CONFIG.hurtFade)
  turnHold = 0
  startMainAction("hurt", CONFIG.hurtFade, "hurt")
end

-- ===========================================================================
-- Base state selection
-- ===========================================================================
local function desiredBase(s)
  if s.dead then return "death" end
  if s.glide then return "glide" end
  if s.swim then
    if s.speed > CONFIG.moveThreshold or math.abs(s.vy) > 0.03 then return "swim" end
    return "swim_idle"
  end
  if s.climb then
    if math.abs(s.vy) > 0.02 then return "climb" end
    return "climb_idle"
  end
  if s.ride then return "ride" end
  if not s.grounded then
    if s.vy > 0.02 then return "jump_air" end
    if conflictAnimationsDisabled then return nil end
    return "fall"
  end
  if s.crouch then
    if s.moving then return "crouch_walk" end
    return "crouch_idle"
  end
  if s.moving then
    if s.sprint then
      if not conflictAnimationsDisabled and turnHold > 0 and turnDir then
        return "sprint_" .. turnDir
      end
      return "sprint"
    end
    return "walk"
  end
  if conflictAnimationsDisabled then return nil end
  return "idle"
end

local function chooseTrigger(s)
  if not prev.ready or s.dead then return nil end

  if s.glide ~= prev.glide then
    return { name = s.glide and "glide_enter" or "glide_exit", fade = 0.10 }
  end
  if s.swim ~= prev.swim then
    return { name = s.swim and "swim_enter" or "swim_exit", fade = 0.10 }
  end

  local landed = (not prev.grounded) and s.grounded
  if landed and not s.ride and not s.climb and not s.swim and not s.glide then
    if prev.vy < CONFIG.landHardVy then
      return { name = "land_hard", fade = 0.06 }
    end
    if prev.vy < -0.12 then
      return { name = "land_soft", fade = 0.08 }
    end
  end

  local jumped = prev.grounded and (not s.grounded) and s.vy > 0.03
  if jumped and not s.ride and not s.climb and not s.swim and not s.glide then
    return { name = "jump_start", fade = 0.08 }
  end

  if s.crouch ~= prev.crouch and not s.swim and not s.glide and not s.ride and not s.climb then
    if not s.moving then
      return { name = s.crouch and "crouch_enter" or "crouch_exit", fade = 0.10 }
    end
  end

  if s.grounded and not s.crouch and not s.swim and not s.glide and not s.ride and not s.climb then
    if s.sprint and not prev.sprint and s.moving and not prev.moving then
      return { name = "sprint_start", fade = 0.10 }
    end
    if s.moving and not prev.moving then
      return { name = s.sprint and "sprint_start" or "walk_start", fade = 0.10 }
    end
    if (not s.moving) and prev.moving then
      if prev.sprint then return { name = "sprint_stop", fade = 0.10 } end
      return { name = "walk_stop", fade = 0.10 }
    end
  end

  return nil
end

-- ===========================================================================
-- Overlay selection
-- ===========================================================================
local function handIsLeft(hand)
  local leftHanded = false
  pcall(function() leftHanded = player:isLeftHanded() end)
  if hand == "OFF_HAND" then return not leftHanded end
  return leftHanded
end

local function swingSide()
  local hand = nil
  pcall(function() hand = player:getSwingArm() end)
  if handIsLeft(hand) then return "left" end
  return "right"
end

local function activeHandSide()
  local hand = nil
  pcall(function() hand = player:getActiveHand() end)
  if handIsLeft(hand) then return "left" end
  return "right"
end

local function activeItemId()
  local id = nil
  pcall(function()
    local stack = player:getActiveItem()
    if stack then id = stack.id end
  end)
  return id or ""
end

local function hasEntityTarget()
  local ok, entity = pcall(function() return player:getTargetedEntity(4.5) end)
  return ok and entity ~= nil
end

local function hasBlockTarget()
  local ok, block = pcall(function() return player:getTargetedBlock(true, 4.5) end)
  return ok and block ~= nil
end

local function updateTurn(s)
  if conflictAnimationsDisabled then
    turnHold = 0
    turnDir = nil
    return
  end
  if not prev.ready then return end
  if not s.grounded or s.crouch or s.swim or s.glide or s.ride or s.climb then
    turnHold = 0
    turnDir = nil
    return
  end

  local delta = ((s.yaw - prev.yaw + 180) % 360) - 180
  if math.abs(delta) > 90 then delta = 0 end

  if math.abs(delta) > CONFIG.turnEnter then
    turnHold = CONFIG.turnHoldTicks
    turnDir = delta > 0 and "turn_right" or "turn_left"
    turnDelta = delta
  elseif turnHold > 0 then
    turnHold = turnHold - 1
  end
end

local function updateOverlay(s)
  if deathActive or (mainAction and (mainAction.kind == "hurt" or mainAction.kind == "emote")) then
    clearOverlay(CONFIG.hurtFade)
    return
  end

  -- A new swing, including a re-swing while the arm never stopped.
  -- getSwingTime() counts up from 0, so a reset to a lower value is a new swing.
  local newSwing = s.swinging and (
    (not prev.swinging) or
    (s.swingTime + 1 < prev.swingTime) or
    (s.swingTime > prev.swingTime + 1)
  )
  if newSwing then
    local side = swingSide()
    local clip
    if hasEntityTarget() then
      clip = "attack_" .. side
    elseif hasBlockTarget() then
      clip = "mine_" .. side
    else
      clip = "attack_" .. side
    end
    startOverlayAction(clip)
  end

  if overlayAction then
    overlayAction.left = overlayAction.left - DT
    if overlayAction.left > 0 then
      setLayerTarget(overlayLayer, overlayAction.name, CONFIG.overlayFade)
      return
    end
    overlayAction = nil
    setLayerTarget(overlayLayer, nil, CONFIG.overlayFade)
  end

  local desired = nil
  if s.blocking then
    desired = "shield_block_" .. activeHandSide()
  elseif s.using then
    local side = activeHandSide()
    if BOW_IDS[activeItemId()] then
      -- bow_draw_<side> is authored for the hand that DRAWS the string;
      -- the bow itself is held by the opposite (active item) hand.
      desired = "bow_draw_" .. (side == "right" and "left" or "right")
    else
      desired = "use_item_" .. side
    end
  elseif not conflictAnimationsDisabled and not s.crouch and s.grounded and not s.swim and not s.glide and not s.ride and not s.climb and turnHold > 0 then
    if not (s.sprint and s.moving) then desired = turnDir end
  end

  setLayerTarget(overlayLayer, desired, CONFIG.overlayFade)
end

local function setClipSpeed(name, value)
  local anim = getAnim(name)
  if anim then pcall(function() anim:setSpeed(value) end) end
end

local function updateSpeeds(s)
  local target = mainLayer.target
  if target == "walk" then
    setClipSpeed("walk", clamp(s.speed / CONFIG.walkSpeedRef, 0.78, 1.55))
  elseif target == "sprint" or target == "sprint_turn_left" or target == "sprint_turn_right" then
    setClipSpeed(target, clamp(s.speed / CONFIG.sprintSpeedRef, 0.85, 1.45))
  elseif target == "crouch_walk" then
    setClipSpeed("crouch_walk", clamp(s.speed / CONFIG.crouchSpeedRef, 0.72, 1.35))
  elseif target == "swim" then
    setClipSpeed("swim", clamp(s.speed / CONFIG.swimSpeedRef, 0.75, 1.35))
  elseif target == "climb" then
    setClipSpeed("climb", clamp(math.abs(s.vy) / CONFIG.climbSpeedRef, 0.72, 1.35))
  elseif target == "glide" then
    setClipSpeed("glide", clamp(s.speed / CONFIG.glideSpeedRef, 0.75, 1.30))
  end

  local overlayTarget = overlayLayer.target
  if overlayTarget == "turn_left" or overlayTarget == "turn_right" then
    setClipSpeed(overlayTarget, clamp(math.abs(turnDelta) / CONFIG.turnSpeedRef, 0.75, 1.60))
  end
end

local function desiredFaceExpression(s)
  if s.dead then return nil end

  if mainAction then
    if mainAction.kind == "hurt" then return "face_surprised" end
    if mainAction.kind == "emote" then
      if mainAction.name == "emote_laugh" then return "face_happy" end
      if mainAction.name == "emote_think" then return "face_thinking" end
      if mainAction.name == "emote_sit" then return "face_relaxed" end
    end
  end

  if s.using or s.blocking or s.swinging then return "face_focused" end
  return nil
end

local function updateBlink(s)
  if s.dead then
    activeBlink = nil
    blinkCooldown = 2.0
    setLayerTarget(blinkLayer, nil, 0.08)
    tickLayer(blinkLayer)
    return
  end

  if activeBlink then
    local anim = getAnim(activeBlink)
    local elapsed = callNumber(anim, "getTime") or 0
    local finished = elapsed >= getLength(activeBlink) - 0.02
    if not finished and anim then
      local ok, playing = pcall(function() return anim:isPlaying() end)
      finished = ok and not playing and elapsed > 0
    end
    if finished then
      setLayerTarget(blinkLayer, nil, 0.07)
      activeBlink = nil
      blinkCooldown = math.random(58, 132) * DT
    end
  else
    blinkCooldown = blinkCooldown - DT
    if blinkCooldown <= 0 then
      local roll = math.random(1, 100)
      local name = "face_blink"
      if roll <= 12 then
        name = "face_blink_double"
      elseif roll <= 19 then
        name = "face_blink_slow"
      end

      if getAnim(name) then
        activeBlink = name
        setLayerTarget(blinkLayer, name, 0.055, nil, true)
      else
        blinkCooldown = 2.0
      end
    end
  end

  tickLayer(blinkLayer)
end

local function updateFace(s)
  setLayerTarget(faceLayer, desiredFaceExpression(s), 0.16)
  tickLayer(faceLayer)
  updateBlink(s)
end

-- ===========================================================================
-- Action Wheel
-- ===========================================================================
local wheelBuilt = false

local function onToggleEmote(name, state, action)
  if state then
    if not requestEmote(name) then
      pcall(function() action:setToggled(false) end)
    end
  else
    local emote = currentEmote()
    if emote and emote.name == name then
      requestStopEmote()
    end
  end
end

local function onToggleConflictAnimations(state)
  local disabled = state == true
  applyConflictAnimationMode(disabled)
  queuePing("conflict_animations", disabled)
end

local function buildWheel()
  if wheelBuilt then return true end
  if not action_wheel then return false end

  local ok = pcall(function()
    local homePage = action_wheel:newPage("Deepsi: меню")
    local page1 = action_wheel:newPage("Deepsi: эмоции")
    local page2 = action_wheel:newPage("Deepsi: эмоции — ещё")
    local clothingPage = action_wheel:newPage("Deepsi: одежда")

    homePage:newAction()
      :title("Одежда →")
      :item("minecraft:leather_chestplate")
      :setOnLeftClick(function() action_wheel:setPage(clothingPage) end)

    homePage:newAction()
      :title("Эмоции →")
      :item("minecraft:gold_ingot")
      :setOnLeftClick(function() action_wheel:setPage(page1) end)

    conflictAnimationsToggle = homePage:newAction()
      :title("Совместимость: выкл")
      :toggleTitle("Совместимость: вкл")
      :item("minecraft:compass")
      :toggleItem("minecraft:barrier")
      :setOnToggle(function(state) onToggleConflictAnimations(state) end)
    conflictAnimationsToggle:setToggled(conflictAnimationsDisabled)

    page1:newAction()
      :title("Помахать")
      :item("minecraft:feather")
      :setOnLeftClick(function() requestEmote("emote_wave") end)

    page1:newAction()
      :title("Поклониться")
      :item("minecraft:gold_ingot")
      :setOnLeftClick(function() requestEmote("emote_bow") end)

    page1:newAction()
      :title("Отдать честь")
      :item("minecraft:shield")
      :setOnLeftClick(function() requestEmote("emote_salute") end)

    page1:newAction()
      :title("Указать")
      :item("minecraft:spectral_arrow")
      :setOnLeftClick(function() requestEmote("emote_point") end)

    toggleActions["emote_dance"] = page1:newAction()
      :title("Танец: выкл")
      :toggleTitle("Танец: вкл")
      :item("minecraft:jukebox")
      :toggleItem("minecraft:glowstone_dust")
      :setOnToggle(function(state, action) onToggleEmote("emote_dance", state, action) end)

    toggleActions["emote_sit"] = page1:newAction()
      :title("Сесть: выкл")
      :toggleTitle("Сесть: вкл")
      :item("minecraft:oak_stairs")
      :toggleItem("minecraft:glowstone_dust")
      :setOnToggle(function(state, action) onToggleEmote("emote_sit", state, action) end)

    page1:newAction()
      :title("Ещё →")
      :item("minecraft:book")
      :setOnLeftClick(function() action_wheel:setPage(page2) end)

    page1:newAction()
      :title("← Меню")
      :item("minecraft:compass")
      :setOnLeftClick(function() action_wheel:setPage(homePage) end)

    page2:newAction()
      :title("Показать силу")
      :item("minecraft:iron_block")
      :setOnLeftClick(function() requestEmote("emote_flex") end)

    toggleActions["emote_laugh"] = page2:newAction()
      :title("Смеяться: выкл")
      :toggleTitle("Смеяться: вкл")
      :item("minecraft:cake")
      :toggleItem("minecraft:glowstone_dust")
      :setOnToggle(function(state, action) onToggleEmote("emote_laugh", state, action) end)

    toggleActions["emote_think"] = page2:newAction()
      :title("Задуматься: выкл")
      :toggleTitle("Задуматься: вкл")
      :item("minecraft:written_book")
      :toggleItem("minecraft:glowstone_dust")
      :setOnToggle(function(state, action) onToggleEmote("emote_think", state, action) end)

    page2:newAction()
      :title("Кивнуть")
      :item("minecraft:emerald")
      :setOnLeftClick(function() requestEmote("emote_nod") end)

    page2:newAction()
      :title("Покачать головой")
      :item("minecraft:gunpowder")
      :setOnLeftClick(function() requestEmote("emote_shake") end)

    page2:newAction()
      :title("Стоп эмоция")
      :item("minecraft:barrier")
      :setOnLeftClick(function() requestStopEmote() end)

    page2:newAction()
      :title("← Эмоции")
      :item("minecraft:compass")
      :setOnLeftClick(function() action_wheel:setPage(page1) end)

    clothingActions.vest = clothingPage:newAction()
      :title("Жилетка: надета")
      :toggleTitle("Жилетка снята")
      :item("minecraft:leather_chestplate")
      :toggleItem("minecraft:barrier")
      :setOnToggle(function(state) onToggleClothing("vest", state) end)

    clothingActions.shorts = clothingPage:newAction()
      :title("Шорты: надеты")
      :toggleTitle("Шорты сняты — трусы видны")
      :item("minecraft:leather_leggings")
      :toggleItem("minecraft:rabbit_hide")
      :setOnToggle(function(state) onToggleClothing("shorts", state) end)

    clothingActions.underwear = clothingPage:newAction()
      :title("Трусы: надеты")
      :toggleTitle("Трусы сняты")
      :item("minecraft:rabbit_hide")
      :toggleItem("minecraft:barrier")
      :setOnToggle(function(state) onToggleClothing("underwear", state) end)

    clothingPage:newAction()
      :title("← Меню")
      :item("minecraft:compass")
      :setOnLeftClick(function() action_wheel:setPage(homePage) end)

    applyClothingState(clothingStateCode())

    action_wheel:setPage(homePage)
  end)

  if ok then
    wheelBuilt = true
    updateToggles(nil)
  end
  return wheelBuilt
end

pcall(buildWheel)

-- ===========================================================================
-- Events
-- ===========================================================================
function events.entity_init()
  hideVanilla()
  bindSet()
  if not wheelBuilt then pcall(buildWheel) end
end

function events.damage(damageType, source, attacker, position)
  if not ready or not player then return end
  -- The owner drives the reaction; observers receive the hurt ping.
  if not isHost() then return end
  if hurtCooldown > 0 then return end

  local s = readState()
  if s.dead then return end

  local health = nil
  pcall(function() health = player:getHealth() end)
  if health ~= nil and health <= 0 then return end

  -- Fall damage is already represented by land_soft / land_hard.
  local dtype = tostring(damageType or "")
  if dtype == "fall" or dtype == "minecraft:fall" then return end

  hurtCooldown = CONFIG.hurtCooldown
  startHurt()
  queuePing("hurt")
end

function events.tick()
  tickCount = tickCount + 1
  hideVanilla()

  if not bindSet() then return end
  if not player then return end

  local loaded = false
  pcall(function() loaded = player:isLoaded() end)
  if not loaded then return end

  updateArmorVisibility()

  if hurtCooldown > 0 then
    hurtCooldown = math.max(0, hurtCooldown - DT)
  end

  local s = readState()
  stabilizeMovement(s)
  updateTurn(s)

  -- Death is a state, not a timed one-shot. It holds until respawn.
  if s.dead then
    if not deathActive then
      deathActive = true
      cancelEmote(false)
      mainAction = nil
      clearOverlay(0.08)
      turnHold = 0
      setLayerTarget(mainLayer, "death", CONFIG.deathFade, nil, true)
    end
  elseif deathActive then
    deathActive = false
    setLayerTarget(mainLayer, desiredBase(s), CONFIG.mainFade)
  end

  -- A manual emote never blocks locomotion for more than one tick.
  if not deathActive and emoteShouldCancel(s) then
    cancelEmote(true)
  end

  -- Timed main actions (base one-shots, one-shot emotes, hurt).
  if mainAction and not mainAction.loop then
    mainAction.left = mainAction.left - DT
    if mainAction.left <= 0 then
      local finished = mainAction
      mainAction = nil
      if finished.kind == "emote" then updateToggles(nil) end
    end
  end

  -- Base transition one-shots may replace other base one-shots, but never
  -- replace an emote or hurt reaction.
  if not deathActive and (mainAction == nil or mainAction.kind == "oneshot") then
    local trigger = chooseTrigger(s)
    if trigger then
      startMainAction(trigger.name, trigger.fade, "oneshot")
    end
  end

  if not deathActive then
    local desired = nil
    local fade = CONFIG.mainFade

    if mainAction then
      desired = mainAction.name
      if mainAction.kind == "hurt" then
        fade = CONFIG.hurtFade
      elseif mainAction.kind == "emote" then
        fade = CONFIG.emoteFade
      else
        fade = 0.10
      end
    else
      desired = desiredBase(s)
    end

    local phase = nil
    if mainAction == nil and mainLayer.target and BASE_LOOPS[mainLayer.target] and BASE_LOOPS[desired] then
      phase = getPhase(mainLayer.target)
    end
    setLayerTarget(mainLayer, desired, fade, phase)
  end
  tickLayer(mainLayer)
  updateFace(s)

  updateOverlay(s)
  tickLayer(overlayLayer)
  updateSpeeds(s)
  flushPing()

  prev.ready = true
  prev.speed = s.speed
  prev.vy = s.vy
  prev.grounded = s.grounded
  prev.sprint = s.sprint
  prev.crouch = s.crouch
  prev.swim = s.swim
  prev.glide = s.glide
  prev.climb = s.climb
  prev.ride = s.ride
  prev.moving = s.moving
  prev.swinging = s.swinging
  prev.swingTime = s.swingTime
  prev.yaw = s.yaw
  prev.dead = s.dead

  ready = true
end

