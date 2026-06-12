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
local SKIP    = { dualist = true }

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

-- ─── GRIP counterpart resolution ──────────────────────────────────────────
-- GRIP converts weapons between 1H and 2H variants at runtime, writing two
-- maps into the global storage section 'GRIPRecords':
--     OldToNewRecords[origId]    = convertedId
--     NewToOldRecords[convertedId] = origId
-- We read them exactly the way Stance!'s own player/grip.lua does (a player
-- script may read a global section). A weapon's "counterpart" is its other
-- grip form: looking it up lets one hotbar slot satisfy BOTH grip stances
-- (e.g. a longsword under Soloist AND Zweihänder), with GRIP's own toggle
-- performing the actual swap after the slot is equipped.
local function gripMaps()
    if not getGeneral('gripBothForms', true) then return nil, nil end
    local section
    local okSec = pcall(function() section = storage.globalSection('GRIPRecords') end)
    if not okSec or not section then return nil, nil end
    local oldToNew, newToOld
    pcall(function() oldToNew = section:getCopy('OldToNewRecords') end)
    pcall(function() newToOld = section:getCopy('NewToOldRecords') end)
    if type(oldToNew) ~= 'table' then oldToNew = nil end
    if type(newToOld) ~= 'table' then newToOld = nil end
    return oldToNew, newToOld
end

-- The other grip form of recordId, or nil. An id is either an original (key in
-- OldToNew) or a converted form (key in NewToOld) — never both — so one lookup
-- in each direction is sufficient.
local function gripCounterpart(recordId, oldToNew, newToOld)
    if not recordId then return nil end
    if oldToNew and oldToNew[recordId] then return oldToNew[recordId] end
    if newToOld and newToOld[recordId] then return newToOld[recordId] end
    return nil
end

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

-- Walk all Quick Select slots and map each stance id to the FIRST slot that can
-- satisfy it. A slot satisfies the stance of its stored weapon AND — when GRIP
-- is present — the stance of that weapon's other grip form, so one longsword can
-- back both Soloist and Zweihänder. Spell/enchant slots and items that classify
-- to the Commoner fallback (non-weapons, ammo) are ignored. Matches reached via
-- the GRIP counterpart are flagged so activation can hint to toggle GRIP.
local function scanQuickSelect()
    local matches = {}   -- stanceId -> { slot, recordId, viaGrip }
    if not (stanceReady() and quickSelectReady()) then return matches end
    local oldToNew, newToOld = gripMaps()
    for slot = 1, QS_SLOT_COUNT do
        local data
        local okData = pcall(function() data = I.QuickSelect_Storage.getFavoriteItemData(slot) end)
        if okData and type(data) == 'table' and data.item then
            local recordId = data.item

            -- Primary: the weapon's current/stored form. Registered first so a
            -- slot's native stance always wins over a counterpart match.
            local primary = stanceIdFor(recordId)
            if primary and not matches[primary] then
                matches[primary] = { slot = slot, recordId = recordId, viaGrip = false }
            end

            -- Secondary: the GRIP counterpart's stance, if any and different.
            local mateId = gripCounterpart(recordId, oldToNew, newToOld)
            if mateId then
                local mate = stanceIdFor(mateId)
                if mate and mate ~= primary and not matches[mate] then
                    matches[mate] = { slot = slot, recordId = recordId, viaGrip = true }
                end
            end
        end
    end
    return matches
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
                local m = matches[id]
                if m then
                    entry = { id = id, kind = 'weapon', slot = m.slot, recordId = m.recordId, unreachable = false, viaGrip = m.viaGrip }
                elseif showAll then
                    entry = { id = id, kind = 'weapon', unreachable = true }
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

-- Saved engine state to restore on close.
local savedControlSwitch = {}  -- switchKey -> previous boolean
local savedCombatOverride = false
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

    -- Centre label: the highlighted stance's name (or a hint when none).
    if getWheel('showStanceName', true) then
        local labelText
        if highlightIndex and entries[highlightIndex] then
            local e = entries[highlightIndex]
            labelText = e.name or e.id
            if e.unreachable then labelText = labelText .. '  (no weapon)' end
        else
            labelText = '— cancel —'
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
        local ang = math.atan2(accumX, -accumY)
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
    highlightIndex = nil
    accumX, accumY = 0, 0
    if getWheel('freezeCamera', true) then freezeControls() end
    applyTimeScale()
    rebuildWheel()
end

-- Forward declaration; defined below.
local activateEntry

local function closeWheel(confirm)
    if not wheelOpen then return end
    local chosen = (confirm and highlightIndex) and entries[highlightIndex] or nil
    wheelOpen = false
    if wheelElement then wheelElement:destroy(); wheelElement = nil end
    restoreControls()
    restoreTimeScale()
    highlightIndex = nil
    accumX, accumY = 0, 0
    if chosen then activateEntry(chosen) end
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

activateEntry = function(entry)
    if not entry then return end
    if entry.unreachable then
        announce(string.format('No %s weapon in your Quick Select slots.', entry.name or entry.id))
        return
    end
    if entry.kind == 'special' then
        doSpecial(entry.id)
        return
    end
    -- Weapon stance: hand the matched slot to Quick Select, which equips and
    -- draws it; Stance!'s resolver then flips you into the stance on its next
    -- poll. We re-validate the slot at activation time in case the hotbar
    -- changed while the wheel was open.
    if not quickSelectReady() then return end
    local slot = entry.slot
    local viaGrip = entry.viaGrip
    local data
    local okData = pcall(function() data = I.QuickSelect_Storage.getFavoriteItemData(slot) end)
    if not (okData and type(data) == 'table' and data.item == entry.recordId) then
        -- The slot moved; re-scan and find a fresh match for this stance.
        local matches = scanQuickSelect()
        local m = matches[entry.id]
        if not m then
            announce(string.format('No %s weapon in your Quick Select slots.', entry.name or entry.id))
            return
        end
        slot = m.slot
        viaGrip = m.viaGrip
    end
    pcall(function() I.QuickSelect_Storage.equipSlot(slot) end)
    local name = entry.name or entry.id
    if viaGrip then
        -- The slot holds this weapon's other grip form; equipping it is correct,
        -- but Stance! won't read the target stance until GRIP swaps the grip.
        announce(string.format('%s equipped — toggle GRIP to switch grip.', name))
    else
        announce(string.format('Stance: %s', name))
    end
end

-- ─── Input handling ───────────────────────────────────────────────────────
local function isActivationKey(key)
    local code = activationKeyCode()
    return code ~= nil and key.code == code
end

-- Shared open/confirm flow so keyboard and controller behave identically under
-- both Hold and Toggle modes.
local function handleActivatePress()
    local mode = getGeneral('activationMode', 'Hold')
    if mode == 'Toggle' then
        if wheelOpen then
            closeWheel(true)              -- second tap confirms
        elseif canOpen() then
            openWheel()
        end
        return
    end
    -- Hold mode: ignore auto-repeat; open only on the first press.
    if wheelKeyHeld then return end
    wheelKeyHeld = true
    if canOpen() then openWheel() end
end

local function handleActivateRelease()
    wheelKeyHeld = false
    if getGeneral('activationMode', 'Hold') == 'Hold' and wheelOpen then
        closeWheel(true)
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
        closeWheel(false)
        return
    end
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
    highlightIndex = nil
    accumX, accumY = 0, 0
    stanceCatalogue = nil
end

return {
    interfaceName = 'StanceWheel',
    interface = {
        version = 1,
        -- Lets other scripts open/close the wheel or query state if desired.
        open = function() if canOpen() then openWheel() end end,
        close = function(confirm) closeWheel(confirm and true or false) end,
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
