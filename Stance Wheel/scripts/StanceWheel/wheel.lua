--[[
    Stance Wheel — radial stance selector (PLAYER scope)
    =====================================================

    A re-imagining of the MWSE "Quick Wheel" mod, rebuilt natively for OpenMW
    and dedicated to the Stance! mod. Instead of arbitrary item/spell slots it
    shows your STANCES, and instead of storing its own assignments it reads the
    live contents of your Quick Select Ultimate hotbar.

    Flow
    ----
      1. Hold the activation key (Options → Scripts → Stance Wheel; default G).
      2. A radial overlay of stance icons appears. The world optionally slows
         and the camera is frozen so the mouse aims the wheel instead.
      3. Aim the mouse at a stance; it enlarges and its name shows in the centre.
      4. Release the key. The wheel then:
           * scans every Quick Select slot (1..50),
           * asks Stance! which stance each stored weapon would produce
             (I.Stance.classifyLoadout), and
           * equips the first slot whose weapon matches the chosen stance
             (I.QuickSelect_Storage.equipSlot), which draws it and lets Stance!'s
             own resolver flip you into that stance.
      5. Aiming at the dead centre (or moving the mouse less than the dead-zone)
         and releasing cancels with no change.

    The three weaponless stances — Commoner (sheathed), Arcanist (spell stance)
    and Brawler (fists) — can't be reached by equipping a hotbar weapon, so when
    "Include weaponless stances" is on they are offered as special entries that
    set the stance directly via the player's weapon stance.

    Dependencies (all optional; the mod stays dormant if a dependency is absent):
      * Stance!                — I.Stance (classifyLoadout, getStanceDisplayName)
      * Quick Select Ultimate  — I.QuickSelect_Storage (getFavoriteItemData,
                                  equipSlot)

    This script never writes to another mod's storage and ships no patches to
    Stance! or Quick Select; it only reads their public interfaces.
]]

local core    = require('openmw.core')
local self    = require('openmw.self')
local types   = require('openmw.types')
local input   = require('openmw.input')
local ui      = require('openmw.ui')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local camera  = require('openmw.camera')
local I       = require('openmw.interfaces')

-- ─── Math compat ──────────────────────────────────────────────────────────
-- OpenMW runs LuaJIT (Lua 5.1) where math.atan2 exists, but guard anyway so
-- the angle math survives any build that only ships the two-argument math.atan.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- ─── Settings access ──────────────────────────────────────────────────────
local SEC_GENERAL = storage.playerSection('Settings_StanceWheel')
local SEC_WHEEL   = storage.playerSection('Settings_StanceWheel_Wheel')

local function getGeneral(key, default)
    local v = SEC_GENERAL:get(key)
    if v == nil then return default end
    return v
end
local function getWheel(key, default)
    local v = SEC_WHEEL:get(key)
    if v == nil then return default end
    return v
end

-- ─── Key-name → KeyCode map ───────────────────────────────────────────────
-- Only names that actually exist in input.KEY are kept, so a typo or a build
-- that lacks a key simply drops that option rather than crashing.
local KEY_BY_NAME = {}
do
    local pairsToTry = {
        G = 'G', R = 'R', Q = 'Q', E = 'E', F = 'F', T = 'T', Y = 'Y',
        H = 'H', J = 'J', K = 'K', N = 'N', M = 'M', C = 'C', V = 'V',
        B = 'B', X = 'X', Z = 'Z',
        ['Tab'] = 'Tab',
        ['Caps Lock'] = 'CapsLock',
        ['Left Alt'] = 'LeftAlt',
        ['Left Ctrl'] = 'LeftCtrl',
        ['Left Shift'] = 'LeftShift',
        ['Left Bracket'] = 'LeftBracket',
    }
    local KEY = input.KEY or {}
    for displayName, enumName in pairs(pairsToTry) do
        if KEY[enumName] ~= nil then
            KEY_BY_NAME[displayName] = KEY[enumName]
        end
    end
end

local function activationKeyCode()
    local name = getGeneral('activationKey', 'G')
    return KEY_BY_NAME[name] or KEY_BY_NAME['G'] or (input.KEY and input.KEY.G)
end

-- Controller (gamepad) face/button activation. Display names mirror the items
-- in settings.lua; each maps to an input.CONTROLLER_BUTTON enum member, and we
-- only keep the ones the running build actually exposes (graceful degrade).
local BUTTON_BY_NAME = {}
do
    local pairsToTry = {
        ['A'] = 'A', ['B'] = 'B', ['X'] = 'X', ['Y'] = 'Y',
        ['Left Shoulder'] = 'LeftShoulder', ['Right Shoulder'] = 'RightShoulder',
        ['Left Stick'] = 'LeftStick', ['Right Stick'] = 'RightStick',
        ['Back'] = 'Back', ['Start'] = 'Start',
        ['D-Pad Up'] = 'DPadUp', ['D-Pad Down'] = 'DPadDown',
        ['D-Pad Left'] = 'DPadLeft', ['D-Pad Right'] = 'DPadRight',
    }
    local BTN = input.CONTROLLER_BUTTON or {}
    for displayName, enumName in pairs(pairsToTry) do
        if BTN[enumName] ~= nil then
            BUTTON_BY_NAME[displayName] = BTN[enumName]
        end
    end
end

-- Returns the configured controller button id, or nil when set to 'None' or
-- when no controller button is configured/available.
local function activationButtonCode()
    local name = getGeneral('controllerButton', 'None')
    if name == 'None' then return nil end
    return BUTTON_BY_NAME[name]
end

-- ─── Stance catalogue ─────────────────────────────────────────────────────
-- Primary source is Stance!'s own config (authoritative for ids, names, icons
-- and detection order). A built-in fallback keeps the wheel usable even if that
-- require ever fails while the interface is still present.
local SPECIAL = { commoner = true, arcanist = true, brawler = true }
-- Stances that can never be reached by equipping a single hotbar weapon and
-- aren't offered as "special" entries either, so they're skipped entirely.
-- dualist needs an off-hand loadout; muse is a non-combat "play idly" stance.
local SKIP    = { dualist = true, muse = true }

local FALLBACK_STANCES = {
    { id = 'arcanist',     displayName = 'Arcanist',     icon = 'icons/Stance/Arcanist.dds' },
    { id = 'reforger',     displayName = 'Reforger',     icon = 'icons/Stance/Reforger.dds' },
    { id = 'blademeister', displayName = 'Blademeister', icon = 'icons/Stance/Blademeister.dds' },
    { id = 'angler',       displayName = 'Angler',       icon = 'icons/Stance/Angler.dds' },
    { id = 'huntsman',     displayName = 'Huntsman',     icon = 'icons/Stance/Huntsman.dds' },
    { id = 'apothecary',   displayName = 'Apothecary',   icon = 'icons/Stance/Apothecary.dds' },
    { id = 'twirler',      displayName = 'Twirler',      icon = 'icons/Stance/Twirler.dds' },
    { id = 'thaumaturge',  displayName = 'Thaumaturge',  icon = 'icons/Stance/Thaumaturge.dds' },
    { id = 'forager',      displayName = 'Forager',      icon = 'icons/Stance/Forager.dds' },
    { id = 'guisarmier',   displayName = 'Guisarmier',   icon = 'icons/Stance/Guisarmier.dds' },
    { id = 'pitmen',       displayName = 'Pitmen',       icon = 'icons/Stance/Pitman.dds' },
    { id = 'axeman',       displayName = 'Axeman',       icon = 'icons/Stance/Axeman.dds' },
    { id = 'mjolnir',      displayName = 'Mjolnir',      icon = 'icons/Stance/Mjolnir.dds' },
    { id = 'zweihander',   displayName = 'Zweihänder',   icon = 'icons/Stance/Zweihander.dds' },
    { id = 'soloist',      displayName = 'Soloist',      icon = 'icons/Stance/Soloist.dds' },
    { id = 'thief',        displayName = 'Thief',        icon = 'icons/Stance/Thief.dds' },
    { id = 'locksmith',    displayName = 'Locksmith',    icon = 'icons/Stance/Locksmith.dds' },
    { id = 'brawler',      displayName = 'Brawler',      icon = 'icons/Stance/Brawler.dds' },
    { id = 'commoner',     displayName = 'Commoner',     icon = 'icons/Stance/Commoner.dds' },
}

local stanceCatalogue = nil
local function getStanceCatalogue()
    if stanceCatalogue then return stanceCatalogue end
    local list = {}
    local ok, cfg = pcall(require, 'scripts.stance.config')
    if ok and type(cfg) == 'table' and type(cfg.stances) == 'table' then
        for _, s in ipairs(cfg.stances) do
            if type(s) == 'table' and s.id then
                list[#list + 1] = {
                    id = s.id,
                    displayName = s.displayName or s.id,
                    icon = s.icon,
                }
            end
        end
    end
    if #list == 0 then
        for _, s in ipairs(FALLBACK_STANCES) do list[#list + 1] = s end
    end
    stanceCatalogue = list
    return list
end

local function displayNameFor(id, fallback)
    if I.Stance and I.Stance.getStanceDisplayName then
        local ok, name = pcall(I.Stance.getStanceDisplayName, id)
        if ok and type(name) == 'string' and name ~= '' then return name end
    end
    return fallback or id
end

-- ─── Texture cache ────────────────────────────────────────────────────────
local textureCache = {}
local function textureFor(path)
    if not path then return nil end
    local cached = textureCache[path]
    if cached ~= nil then return cached or nil end
    local ok, tex = pcall(function() return ui.texture { path = path } end)
    if ok and tex then textureCache[path] = tex; return tex end
    textureCache[path] = false
    return nil
end

-- ─── Screen / layer size ──────────────────────────────────────────────────
local function screenSize()
    local ok, id = pcall(function() return ui.layers.indexOf('HUD') end)
    if ok and id and ui.layers[id] and ui.layers[id].size then
        return ui.layers[id].size
    end
    return util.vector2(1920, 1080)
end

-- ─── Dependency presence ──────────────────────────────────────────────────
local function stanceReady()
    return I.Stance ~= nil and I.Stance.classifyLoadout ~= nil
end
local function quickSelectReady()
    return I.QuickSelect_Storage ~= nil
        and I.QuickSelect_Storage.getFavoriteItemData ~= nil
        and I.QuickSelect_Storage.equipSlot ~= nil
end

local QS_SLOT_COUNT = 50

-- Classify a single record id to a stance id, or nil for the Commoner fallback
-- / a non-weapon / a classify failure.
local function stanceIdFor(recordId)
    local res
    local ok = pcall(function() res = I.Stance.classifyLoadout({ rightId = recordId }) end)
    if ok and type(res) == 'table' and res.id and res.id ~= 'commoner' then
        return res.id
    end
    return nil
end

-- Walk all Quick Select slots and collect, per stance, EVERY slot whose stored
-- weapon produces that stance (in slot order, de-duplicated by record so the
-- same weapon favourited twice isn't offered twice). Spell/enchant slots and
-- items that classify to the Commoner fallback (non-weapons, ammo) are ignored.
--   matches[stanceId] = { { slot = n, recordId = id }, ... }
local function scanQuickSelect()
    local matches = {}
    if not (stanceReady() and quickSelectReady()) then return matches end
    for slot = 1, QS_SLOT_COUNT do
        local data
        local okData = pcall(function() data = I.QuickSelect_Storage.getFavoriteItemData(slot) end)
        if okData and type(data) == 'table' and data.item then
            local recordId = data.item
            local id = stanceIdFor(recordId)
            if id then
                local lst = matches[id]
                if not lst then lst = {}; matches[id] = lst end
                local dup = false
                for _, e in ipairs(lst) do
                    if e.recordId == recordId then dup = true; break end
                end
                if not dup then
                    lst[#lst + 1] = { slot = slot, recordId = recordId }
                end
            end
        end
    end
    return matches
end

-- Display name + inventory icon for a carried-right record id, probing the
-- weapon-like record tables. Falls back to the raw id with no icon.
local function recordDisplay(recordId)
    local name, icon = recordId, nil
    local function tryType(T)
        if not (T and T.records) then return false end
        local rec
        local ok = pcall(function() rec = T.records[recordId] end)
        if ok and rec then
            if rec.name and rec.name ~= '' then name = rec.name end
            if rec.icon and rec.icon ~= '' then icon = rec.icon end
            return true
        end
        return false
    end
    local _ = tryType(types.Weapon) or tryType(types.Lockpick) or tryType(types.Probe)
    return name, icon
end

-- Build the per-weapon entries shown in the second-stage "pick a weapon" wheel
-- for a stance that has more than one matching hotbar slot.
local function buildWeaponEntries(slots)
    local out = {}
    for _, s in ipairs(slots) do
        local name, icon = recordDisplay(s.recordId)
        out[#out + 1] = {
            id = s.recordId,
            name = name,
            icon = icon,
            kind = 'weaponpick',
            slot = s.slot,
            recordId = s.recordId,
            unreachable = false,
        }
    end
    return out
end

-- ─── Build the ordered list of wheel entries ──────────────────────────────
-- Each entry: { id, name, icon, kind = 'weapon'|'special', slot?, recordId?,
--               unreachable = bool }
local function buildEntries()
    local catalogue   = getStanceCatalogue()
    local matches     = scanQuickSelect()
    local includeSpec = getGeneral('includeSpecialStances', true)
    local showAll     = getGeneral('showAllStances', false)

    local entries = {}
    for _, s in ipairs(catalogue) do
        local id = s.id
        if not SKIP[id] then
            local entry
            if SPECIAL[id] then
                if includeSpec then
                    entry = { id = id, kind = 'special', unreachable = false }
                elseif showAll then
                    entry = { id = id, kind = 'special', unreachable = true }
                end
            else
                local lst = matches[id]
                if lst and #lst > 0 then
                    entry = { id = id, kind = 'weapon', slots = lst, unreachable = false }
                elseif showAll then
                    entry = { id = id, kind = 'weapon', slots = {}, unreachable = true }
                end
            end
            if entry then
                entry.name = displayNameFor(id, s.displayName)
                entry.icon = s.icon
                entries[#entries + 1] = entry
            end
        end
    end
    return entries
end

-- ─── Wheel state ──────────────────────────────────────────────────────────
local wheelOpen       = false
local wheelKeyHeld    = false
local wheelElement    = nil
local entries         = {}
local highlightIndex  = nil    -- 1..#entries, or nil for centre/cancel
local accumX, accumY  = 0, 0

-- Two-stage selection: 'stance' picks the stance; if it has more than one
-- matching hotbar weapon we switch to 'weapon' to pick which one.
local phase           = 'stance'
local pendingStance   = nil    -- the stance entry awaiting a weapon choice

-- Saved engine state to restore on close.
local savedControlSwitch = {}  -- switchKey -> previous boolean
local savedCombatOverride = false
-- Camera lock (works in first AND third person): we pin yaw/pitch every frame
-- while open, since freezing the Looking control switch alone doesn't stop the
-- third-person free-look orbit.
local cameraLocked    = false
local savedYaw, savedPitch = nil, nil
local timeScaleApplied    = false

-- ─── Control-switch + time-scale helpers ──────────────────────────────────
local function setControlSwitch(switchKey, value)
    if not switchKey then return end
    -- Prefer the non-deprecated types.Player API; fall back to input.
    if types.Player and types.Player.setControlSwitch then
        pcall(types.Player.setControlSwitch, self, switchKey, value)
    elseif input.setControlSwitch then
        pcall(input.setControlSwitch, switchKey, value)
    end
end
local function getControlSwitch(switchKey)
    if not switchKey then return nil end
    local ok, v
    if types.Player and types.Player.getControlSwitch then
        ok, v = pcall(types.Player.getControlSwitch, self, switchKey)
    elseif input.getControlSwitch then
        ok, v = pcall(input.getControlSwitch, switchKey)
    end
    if ok then return v end
    return nil
end

local function freezeControls()
    savedControlSwitch = {}
    local CS = input.CONTROL_SWITCH or {}
    -- Looking: stop the camera from spinning while we read mouse deltas.
    -- Fighting / Magic: stop the held key (or a click) from attacking/casting.
    for _, k in ipairs({ CS.Looking, CS.Fighting, CS.Magic }) do
        if k ~= nil then
            savedControlSwitch[k] = getControlSwitch(k)
            setControlSwitch(k, false)
        end
    end
    -- Belt-and-braces: also suppress the "toggle weapon/spell/attack" actions so
    -- an activation key that happens to be a combat bind doesn't fire mid-wheel.
    savedCombatOverride = false
    if I.Controls and I.Controls.overrideCombatControls then
        pcall(I.Controls.overrideCombatControls, true)
        savedCombatOverride = true
    end

    -- Capture the current view so onFrame can re-pin it. This is what makes the
    -- lock effective in third person (and a harmless no-op in first person,
    -- where the Looking switch already holds the view still).
    cameraLocked = false
    savedYaw, savedPitch = nil, nil
    if camera and camera.getYaw and camera.getPitch then
        local okY, y = pcall(camera.getYaw)
        local okP, p = pcall(camera.getPitch)
        if okY and okP then
            savedYaw, savedPitch = y, p
            cameraLocked = true
        end
    end
end

local function restoreControls()
    for k, prev in pairs(savedControlSwitch) do
        -- Restore to the prior value when we knew it, otherwise re-enable.
        if prev == nil then prev = true end
        setControlSwitch(k, prev)
    end
    savedControlSwitch = {}
    if savedCombatOverride and I.Controls and I.Controls.overrideCombatControls then
        pcall(I.Controls.overrideCombatControls, false)
    end
    savedCombatOverride = false
    cameraLocked = false
    savedYaw, savedPitch = nil, nil
end

-- Re-assert the frozen view. Called every frame while open; counteracts both
-- first-person look and the third-person free-look orbit.
local function pinCamera()
    if not cameraLocked then return end
    if savedYaw ~= nil and camera and camera.setYaw and type(camera.setYaw) == 'function' then
        pcall(camera.setYaw, savedYaw)
    end
    if savedPitch ~= nil and camera and camera.setPitch and type(camera.setPitch) == 'function' then
        pcall(camera.setPitch, savedPitch)
    end
end

local function applyTimeScale()
    if not getWheel('slowMotion', true) then return end
    local scale = tonumber(getWheel('timeScale', 0.25)) or 0.25
    pcall(core.sendGlobalEvent, 'SetSimulationTimeScale', scale)
    timeScaleApplied = true
end
local function restoreTimeScale()
    if not timeScaleApplied then return end
    pcall(core.sendGlobalEvent, 'SetSimulationTimeScale', 1.0)
    timeScaleApplied = false
end

-- ─── UI construction ──────────────────────────────────────────────────────
local NAME_COLOR     = util.color.rgb(0.95, 0.90, 0.65)
local NAME_SHADOW    = util.color.rgb(0.0, 0.0, 0.0)
local DIM_TINT       = util.color.rgba(1.0, 1.0, 1.0, 0.35)
local SELECTED_TINT  = util.color.rgb(1.0, 1.0, 1.0)
local NORMAL_TINT    = util.color.rgba(1.0, 1.0, 1.0, 0.85)

-- Build a single icon (or a name-only placeholder when the texture is missing).
local function iconWidget(entry, sizePx, selected)
    local tex = textureFor(entry.icon)
    local tint
    if entry.unreachable then
        tint = DIM_TINT
    elseif selected then
        tint = SELECTED_TINT
    else
        tint = NORMAL_TINT
    end
    if tex then
        return {
            type = ui.TYPE.Image,
            props = {
                resource = tex,
                size = util.vector2(sizePx, sizePx),
                color = tint,
            },
        }
    end
    -- Fallback: a short text token so the entry is still selectable/visible.
    return {
        type = ui.TYPE.Text,
        props = {
            text = entry.name or entry.id,
            textSize = math.max(12, math.floor(sizePx * 0.28)),
            textColor = tint,
            textShadow = true,
            textShadowColor = NAME_SHADOW,
        },
    }
end

local function rebuildWheel()
    if wheelElement then wheelElement:destroy(); wheelElement = nil end
    if not wheelOpen then return end

    local size    = screenSize()
    local cx, cy  = size.x / 2, size.y / 2
    local radius  = tonumber(getWheel('wheelRadius', 220)) or 220
    local iconPx  = tonumber(getWheel('iconSize', 64)) or 64
    local selScl  = tonumber(getWheel('selectedIconScale', 1.5)) or 1.5
    local n       = #entries

    local content = {}

    if n > 0 then
        local step = (2 * math.pi) / n
        for i, entry in ipairs(entries) do
            local theta = (i - 1) * step            -- 0 = top, clockwise
            local ox =  math.sin(theta) * radius
            local oy = -math.cos(theta) * radius
            local selected = (i == highlightIndex)
            local sz = selected and math.floor(iconPx * selScl + 0.5) or iconPx
            local px = cx + ox - sz / 2
            local py = cy + oy - sz / 2
            content[#content + 1] = {
                type = ui.TYPE.Widget,
                props = {
                    position = util.vector2(px, py),
                    size = util.vector2(sz, sz),
                },
                content = ui.content({ iconWidget(entry, sz, selected) }),
            }
        end
    end

    -- Centre label: the highlighted entry's name (or a hint when none).
    if getWheel('showStanceName', true) then
        local labelText
        if highlightIndex and entries[highlightIndex] then
            local e = entries[highlightIndex]
            labelText = e.name or e.id
            if e.unreachable then labelText = labelText .. '  (no weapon)' end
        else
            labelText = (phase == 'weapon') and '— back —' or '— cancel —'
        end
        local labelSize = math.max(18, math.floor(iconPx * 0.42))
        content[#content + 1] = {
            type = ui.TYPE.Text,
            props = {
                position = util.vector2(cx, cy),
                anchor = util.vector2(0.5, 0.5),
                text = labelText,
                textSize = labelSize,
                textColor = NAME_COLOR,
                textShadow = true,
                textShadowColor = NAME_SHADOW,
            },
        }
        -- During weapon selection, name the stance being chosen for, just above.
        if phase == 'weapon' and pendingStance then
            content[#content + 1] = {
                type = ui.TYPE.Text,
                props = {
                    position = util.vector2(cx, cy - labelSize - 6),
                    anchor = util.vector2(0.5, 0.5),
                    text = string.format('Choose weapon · %s', pendingStance.name or pendingStance.id),
                    textSize = math.max(14, math.floor(labelSize * 0.7)),
                    textColor = NAME_COLOR,
                    textShadow = true,
                    textShadowColor = NAME_SHADOW,
                },
            }
        end
    end

    wheelElement = ui.create({
        layer = 'HUD',
        props = {
            position = util.vector2(0, 0),
            size = size,
        },
        content = ui.content(content),
    })
end

-- ─── Selection geometry ───────────────────────────────────────────────────
local function recomputeHighlight()
    local n = #entries
    if n == 0 then
        if highlightIndex ~= nil then highlightIndex = nil; rebuildWheel() end
        return
    end
    local deadzone = tonumber(getWheel('deadzone', 55)) or 55
    local dist = math.sqrt(accumX * accumX + accumY * accumY)
    local newIndex
    if dist < deadzone then
        newIndex = nil
    else
        -- angle 0 = up, increasing clockwise toward +x (matches icon layout).
        local ang = atan2(accumX, -accumY)
        if ang < 0 then ang = ang + 2 * math.pi end
        local step = (2 * math.pi) / n
        local idx = math.floor(ang / step + 0.5) % n
        newIndex = idx + 1
    end
    if newIndex ~= highlightIndex then
        highlightIndex = newIndex
        rebuildWheel()
    end
end

-- ─── Open / close ─────────────────────────────────────────────────────────
local function canOpen()
    if not getGeneral('enabled', true) then return false end
    if not (stanceReady() and quickSelectReady()) then return false end
    -- Only in normal gameplay (no menu/inventory/console, world not paused).
    if I.UI and I.UI.getMode and I.UI.getMode() ~= nil then return false end
    if core.isWorldPaused and core.isWorldPaused() then return false end
    return true
end

local function openWheel()
    if wheelOpen then return end
    entries = buildEntries()
    if #entries == 0 then
        ui.showMessage('Stance Wheel: no stance weapons found in your Quick Select slots.')
        return
    end
    wheelOpen = true
    phase = 'stance'
    pendingStance = nil
    highlightIndex = nil
    accumX, accumY = 0, 0
    if getWheel('freezeCamera', true) then freezeControls() end
    applyTimeScale()
    rebuildWheel()
end

-- Tear down the wheel and restore engine state. Does NOT itself activate a
-- selection — confirmSelection() drives what happens on a choice.
local function closeWheel()
    if not wheelOpen then return end
    wheelOpen = false
    if wheelElement then wheelElement:destroy(); wheelElement = nil end
    restoreControls()
    restoreTimeScale()
    phase = 'stance'
    pendingStance = nil
    highlightIndex = nil
    accumX, accumY = 0, 0
end

-- ─── Activation ───────────────────────────────────────────────────────────
local function announce(msg)
    if getGeneral('announce', true) then ui.showMessage(msg) end
end

local function doSpecial(id)
    local STANCE = types.Actor.STANCE
    if not STANCE then return end
    if id == 'commoner' then
        pcall(types.Actor.setStance, self, STANCE.Nothing)
        announce('Stance: Commoner (weapons sheathed).')
    elseif id == 'arcanist' then
        pcall(types.Actor.setStance, self, STANCE.Spell)
        announce('Stance: Arcanist (spell stance).')
    elseif id == 'brawler' then
        -- Empty the right hand, then draw fists.
        local SLOT = types.Actor.EQUIPMENT_SLOT and types.Actor.EQUIPMENT_SLOT.CarriedRight
        if SLOT then
            local eq
            local okGet = pcall(function() eq = types.Actor.getEquipment(self) end)
            if okGet and type(eq) == 'table' then
                eq[SLOT] = nil
                pcall(types.Actor.setEquipment, self, eq)
            end
        end
        async:newUnsavableSimulationTimer(0.2, function()
            pcall(types.Actor.setStance, self, STANCE.Weapon)
        end)
        announce('Stance: Brawler (fists up).')
    end
end

-- Equip a stance's weapon by slot, re-validating against the live hotbar (which
-- may have changed while the wheel was open). On a stale slot we re-scan and
-- take the first current match for the stance.
local function equipSlotForStance(stanceId, slot, recordId, stanceName)
    if not quickSelectReady() then return end
    local data
    local okData = pcall(function() data = I.QuickSelect_Storage.getFavoriteItemData(slot) end)
    if not (okData and type(data) == 'table' and data.item == recordId) then
        local lst = scanQuickSelect()[stanceId]
        if not lst or #lst == 0 then
            announce(string.format('No %s weapon in your Quick Select slots.', stanceName))
            return
        end
        slot = lst[1].slot
    end
    pcall(function() I.QuickSelect_Storage.equipSlot(slot) end)
    announce(string.format('Stance: %s', stanceName))
end

-- Confirm the current highlight. Centre (no highlight) cancels in the stance
-- phase and steps back in the weapon phase. A multi-weapon stance opens the
-- weapon phase instead of closing.
local function confirmSelection()
    if not wheelOpen then return end
    local entry = (highlightIndex and entries[highlightIndex]) or nil

    if phase == 'weapon' then
        if not entry then
            -- Back to the stance wheel.
            entries = buildEntries()
            phase = 'stance'
            pendingStance = nil
            highlightIndex = nil
            accumX, accumY = 0, 0
            rebuildWheel()
            return
        end
        local stanceId   = pendingStance and pendingStance.id
        local stanceName = (pendingStance and (pendingStance.name or pendingStance.id)) or entry.id
        local slot, recordId = entry.slot, entry.recordId
        closeWheel()
        equipSlotForStance(stanceId, slot, recordId, stanceName)
        return
    end

    -- phase == 'stance'
    if not entry then closeWheel(); return end
    local name = entry.name or entry.id
    if entry.unreachable then
        closeWheel()
        announce(string.format('No %s weapon in your Quick Select slots.', name))
        return
    end
    if entry.kind == 'special' then
        closeWheel()
        doSpecial(entry.id)
        return
    end
    -- Weapon stance.
    local slots = entry.slots or {}
    if #slots > 1 then
        -- Drill into a weapon picker for this stance.
        pendingStance = entry
        entries = buildWeaponEntries(slots)
        phase = 'weapon'
        highlightIndex = nil
        accumX, accumY = 0, 0
        rebuildWheel()
        return
    end
    local s = slots[1]
    local stanceId = entry.id
    closeWheel()
    if s then
        equipSlotForStance(stanceId, s.slot, s.recordId, name)
    else
        announce(string.format('No %s weapon in your Quick Select slots.', name))
    end
end

-- ─── Input handling ───────────────────────────────────────────────────────
local function isActivationKey(key)
    local code = activationKeyCode()
    return code ~= nil and key.code == code
end

-- Shared open/confirm flow so keyboard and controller behave identically under
-- both Hold and Toggle modes, across both selection phases.
local function handleActivatePress()
    local mode = getGeneral('activationMode', 'Hold')
    if mode == 'Toggle' then
        if wheelOpen then
            confirmSelection()            -- each tap confirms the current phase
        elseif canOpen() then
            openWheel()
        end
        return
    end
    -- Hold mode: a press opens the wheel the first time; once open (including the
    -- weapon phase) further presses just re-arm — the matching release confirms.
    if wheelKeyHeld then return end
    wheelKeyHeld = true
    if not wheelOpen and canOpen() then openWheel() end
end

local function handleActivateRelease()
    wheelKeyHeld = false
    if getGeneral('activationMode', 'Hold') == 'Hold' and wheelOpen then
        confirmSelection()
    end
end

local function onKeyPress(key)
    if not isActivationKey(key) then return end
    handleActivatePress()
end

local function onKeyRelease(key)
    if not isActivationKey(key) then return end
    handleActivateRelease()
end

-- Controller button id may arrive as a bare number (current engine) or, on some
-- builds, wrapped in a table — accept either without assuming one shape.
local function buttonIdOf(arg)
    if type(arg) == 'table' then return arg.button or arg.code or arg.id end
    return arg
end

local function isActivationButton(arg)
    local code = activationButtonCode()
    return code ~= nil and buttonIdOf(arg) == code
end

local function onControllerButtonPress(arg)
    if not isActivationButton(arg) then return end
    handleActivatePress()
end

local function onControllerButtonRelease(arg)
    if not isActivationButton(arg) then return end
    handleActivateRelease()
end

-- Accumulate mouse movement every frame the wheel is open and refresh the
-- highlight. onFrame runs at real time, so slow-motion never makes the wheel
-- feel sluggish.
local function onFrame(dt)
    if not wheelOpen then return end
    -- If we somehow lost gameplay focus (menu opened, game paused), bail safely.
    if (I.UI and I.UI.getMode and I.UI.getMode() ~= nil)
        or (core.isWorldPaused and core.isWorldPaused()) then
        wheelKeyHeld = false
        closeWheel()
        return
    end

    -- Hold the frozen view (effective in first AND third person).
    pinCamera()

    local sens = tonumber(getWheel('mouseSensitivity', 1.0)) or 1.0

    -- Right stick takes priority when actively deflected: its position is
    -- absolute (each axis -1..1), so the stick direction maps straight to the
    -- aim vector — push toward a stance to highlight it. When the stick is
    -- inside its dead zone we fall back to accumulating mouse movement, so a
    -- keyboard+mouse player and a controller player both work without a toggle.
    local usedStick = false
    if getWheel('stickAim', true) and input.getAxisValue and input.CONTROLLER_AXIS then
        local sx, sy = 0, 0
        pcall(function() sx = input.getAxisValue(input.CONTROLLER_AXIS.RightX) or 0 end)
        pcall(function() sy = input.getAxisValue(input.CONTROLLER_AXIS.RightY) or 0 end)
        local mag = math.sqrt(sx * sx + sy * sy)
        local sdz = tonumber(getWheel('stickDeadzone', 0.30)) or 0.30
        if mag > sdz and mag > 0 then
            -- Normalise to a point at wheel radius so it always clears the
            -- pixel dead zone and points exactly where the stick points.
            local radius = tonumber(getWheel('wheelRadius', 220)) or 220
            accumX = (sx / mag) * radius
            accumY = (sy / mag) * radius
            usedStick = true
        end
    end

    if not usedStick then
        local mx, my = 0, 0
        pcall(function() mx = input.getMouseMoveX() or 0 end)
        pcall(function() my = input.getMouseMoveY() or 0 end)
        accumX = accumX + (mx * sens)
        accumY = accumY + (my * sens)
    end
    recomputeHighlight()
end

-- ─── Lifecycle ────────────────────────────────────────────────────────────
local function hardReset()
    if wheelElement then pcall(function() wheelElement:destroy() end); wheelElement = nil end
    if wheelOpen then
        restoreControls()
        restoreTimeScale()
    end
    wheelOpen = false
    wheelKeyHeld = false
    phase = 'stance'
    pendingStance = nil
    highlightIndex = nil
    accumX, accumY = 0, 0
    cameraLocked = false
    savedYaw, savedPitch = nil, nil
    stanceCatalogue = nil
end

return {
    interfaceName = 'StanceWheel',
    interface = {
        version = 1,
        -- Lets other scripts open/close the wheel or query state if desired.
        open = function() if canOpen() then openWheel() end end,
        close = function(confirm) if confirm then confirmSelection() else closeWheel() end end,
        isOpen = function() return wheelOpen end,
    },
    engineHandlers = {
        onKeyPress = onKeyPress,
        onKeyRelease = onKeyRelease,
        onControllerButtonPress = onControllerButtonPress,
        onControllerButtonRelease = onControllerButtonRelease,
        onFrame = onFrame,
        onLoad = hardReset,
        onInit = hardReset,
        onSave = function() return {} end,
    },
}
