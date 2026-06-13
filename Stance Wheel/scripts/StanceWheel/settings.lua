--[[
    Stance Wheel — Settings Page (MENU scope)

    Registers two settings groups under one Options page:

        1) General — master toggle, activation key + mode, which stances appear,
                     and whether a confirmation message is shown.
        2) Wheel   — the radial overlay's look and feel (radius, icon size,
                     highlight scale, mouse dead-zone / sensitivity), plus the
                     camera-freeze and slow-motion behaviours while it is open.

    Storage sections (read by scripts/StanceWheel/wheel.lua via
    storage.playerSection):
        General → 'Settings_StanceWheel'
        Wheel   → 'Settings_StanceWheel_Wheel'

    The activation-key dropdown stores a plain key NAME string; wheel.lua maps
    it to an openmw.input KeyCode at runtime (see KEY_BY_NAME there). Only key
    names that exist in input.KEY are offered, so the mapping never misses.
]]

local I = require('openmw.interfaces')

local MODNAME = 'StanceWheel'

I.Settings.registerPage {
    key = MODNAME,
    l10n = MODNAME,
    name = 'PageName',
    description = 'PageDescription',
}

-- ─── 1. General ───────────────────────────────────────────────────────────
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME,
    page = MODNAME,
    l10n = MODNAME,
    name = 'GroupGeneralName',
    description = 'GroupGeneralDescription',
    order = 1,
    permanentStorage = true,
    settings = {
        {
            key = 'enabled',
            renderer = 'checkbox',
            name = 'SettingEnabled',
            description = 'SettingEnabledDescription',
            default = true,
        },
        {
            key = 'activationKey',
            renderer = 'select',
            name = 'SettingActivationKey',
            description = 'SettingActivationKeyDescription',
            -- Default 'G' is unbound in a vanilla OpenMW control scheme, so
            -- holding it to open the wheel won't also fire a gameplay action.
            default = 'G',
            argument = {
                -- Each item is BOTH the display string and the stored value.
                -- wheel.lua maps these names to input.KEY codes.
                items = {
                    'G', 'R', 'Q', 'E', 'F', 'T', 'Y', 'H', 'J', 'K',
                    'N', 'M', 'C', 'V', 'B', 'X', 'Z',
                    'Tab', 'Caps Lock', 'Left Alt', 'Left Ctrl', 'Left Shift',
                    'Left Bracket',
                },
            },
        },
        {
            key = 'activationMode',
            renderer = 'select',
            name = 'SettingActivationMode',
            description = 'SettingActivationModeDescription',
            default = 'Hold',
            argument = {
                -- Hold:   hold the key, aim with the mouse, release to confirm.
                -- Toggle: tap the key to open, aim, tap again to confirm.
                items = { 'Hold', 'Toggle' },
            },
        },
        {
            key = 'includeSpecialStances',
            renderer = 'checkbox',
            name = 'SettingIncludeSpecialStances',
            description = 'SettingIncludeSpecialStancesDescription',
            default = true,
        },
        {
            key = 'showAllStances',
            renderer = 'checkbox',
            name = 'SettingShowAllStances',
            description = 'SettingShowAllStancesDescription',
            default = false,
        },
        {
            key = 'announce',
            renderer = 'checkbox',
            name = 'SettingAnnounce',
            description = 'SettingAnnounceDescription',
            default = true,
        },
        {
            key = 'controllerButton',
            renderer = 'select',
            name = 'SettingControllerButton',
            description = 'SettingControllerButtonDescription',
            -- 'None' keeps the wheel keyboard-only by default so picking up a
            -- controller never silently hijacks a face button. Choose a button
            -- here to open/confirm the wheel from a gamepad, using the same
            -- Hold / Toggle rule as the keyboard key above.
            default = 'None',
            argument = {
                items = {
                    'None',
                    'A', 'B', 'X', 'Y',
                    'Left Shoulder', 'Right Shoulder',
                    'Left Stick', 'Right Stick',
                    'Back', 'Start',
                    'D-Pad Up', 'D-Pad Down', 'D-Pad Left', 'D-Pad Right',
                },
            },
        },
    },
}

-- ─── 2. Wheel (look & feel + behaviour) ───────────────────────────────────
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Wheel',
    page = MODNAME,
    l10n = MODNAME,
    name = 'GroupWheelName',
    description = 'GroupWheelDescription',
    order = 2,
    permanentStorage = true,
    settings = {
        {
            key = 'wheelRadius',
            renderer = 'number',
            name = 'SettingWheelRadius',
            description = 'SettingWheelRadiusDescription',
            default = 220,
            argument = { min = 80, max = 600, integer = true },
        },
        {
            key = 'iconSize',
            renderer = 'number',
            name = 'SettingIconSize',
            description = 'SettingIconSizeDescription',
            default = 64,
            argument = { min = 24, max = 160, integer = true },
        },
        {
            key = 'selectedIconScale',
            renderer = 'number',
            name = 'SettingSelectedIconScale',
            description = 'SettingSelectedIconScaleDescription',
            default = 1.5,
            argument = { min = 1.0, max = 3.0, step = 0.05 },
        },
        {
            key = 'deadzone',
            renderer = 'number',
            name = 'SettingDeadzone',
            description = 'SettingDeadzoneDescription',
            default = 55,
            argument = { min = 0, max = 400, integer = true },
        },
        {
            key = 'mouseSensitivity',
            renderer = 'number',
            name = 'SettingMouseSensitivity',
            description = 'SettingMouseSensitivityDescription',
            default = 1.0,
            argument = { min = 0.1, max = 5.0, step = 0.1 },
        },
        {
            key = 'stickAim',
            renderer = 'checkbox',
            name = 'SettingStickAim',
            description = 'SettingStickAimDescription',
            -- When on, deflecting the right stick points the selector directly
            -- (stick direction = chosen stance). The mouse still works whenever
            -- the stick is centred, so keyboard+mouse and controller coexist.
            default = true,
        },
        {
            key = 'stickDeadzone',
            renderer = 'number',
            name = 'SettingStickDeadzone',
            description = 'SettingStickDeadzoneDescription',
            -- Fraction of full stick deflection (0..1) ignored as centre noise.
            default = 0.30,
            argument = { min = 0.05, max = 0.95, step = 0.05 },
        },
        {
            key = 'showStanceName',
            renderer = 'checkbox',
            name = 'SettingShowStanceName',
            description = 'SettingShowStanceNameDescription',
            default = true,
        },
        {
            key = 'freezeCamera',
            renderer = 'checkbox',
            name = 'SettingFreezeCamera',
            description = 'SettingFreezeCameraDescription',
            default = true,
        },
        {
            key = 'slowMotion',
            renderer = 'checkbox',
            name = 'SettingSlowMotion',
            description = 'SettingSlowMotionDescription',
            default = true,
        },
        {
            key = 'timeScale',
            renderer = 'number',
            name = 'SettingTimeScale',
            description = 'SettingTimeScaleDescription',
            default = 0.25,
            argument = { min = 0.05, max = 1.0, step = 0.05 },
        },
    },
}
