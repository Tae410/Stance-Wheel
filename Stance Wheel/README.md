# Stance Wheel

A radial stance selector for **Stance!**. Hold a key, flick the mouse toward a
stance, and release — Stance Wheel reads your **Quick Select Ultimate** hotbar,
finds the weapon that belongs to that stance, equips it, and lets Stance!'s own
resolver flip you into the stance. No weapon for that stance on your bar? It
says so instead of doing nothing.

This is a brand-new native OpenMW Lua mod. It is *inspired by* the original
Quick Wheel (an MWSE mod for the old engine), but shares no code with it and
runs entirely on OpenMW's Lua API.

---

## Requirements

This mod does nothing on its own — it is glue between two other mods. Both must
be installed and loading **before** Stance Wheel:

1. **Stance!** — provides the stances and the `I.Stance` interface
   (`classifyLoadout`, `getStanceDisplayName`, …).
2. **Quick Select Ultimate** — provides the hotbar and the
   `I.QuickSelect_Storage` interface (`getFavoriteItemData`, `equipSlot`).
3. OpenMW 0.49 or newer (uses `types.Actor.setStance`, mutable controls,
   per-frame mouse deltas).

If either interface is missing at runtime, the wheel quietly disables itself —
it will not error out your game.

---

## Install

1. Make sure Stance! and Quick Select Ultimate are installed and working.
2. Drop the `Stance Wheel` folder into your mods/data directory.
3. Register the data path and add the content file in `openmw.cfg` (or via the
   launcher's Data Files tab):

   ```
   data="…/Stance Wheel"
   content=Stance Wheel.omwscripts
   ```

4. **Load order:** put `Stance Wheel.omwscripts` *after* the Stance! and
   Quick Select content files so its scripts see those interfaces.

---

## How to use

1. Put the weapons you want quick access to onto your **Quick Select Ultimate**
   bar, exactly as you normally would (any page).
2. In game, **hold `G`** (default). The wheel fans out around your crosshair,
   showing one icon per stance.
3. **Move the mouse** toward the stance you want — the nearest icon highlights
   and grows.
4. **Release `G`** to confirm. Stance Wheel equips the matching weapon from your
   hotbar and you draw into that stance. Releasing while pointing at the center
   (the dead zone) cancels with no change.

Prefer a tap-tap interaction? Set **Activation Mode → Toggle** and the key opens
the wheel on the first tap and confirms on the second.

While the wheel is open, the camera, combat and magic inputs are frozen and
(optionally) time slows, so aiming a selection never accidentally swings a
weapon or moves the view.

### Using a controller

The wheel supports a gamepad directly:

- **Aiming** uses the **right thumbstick** — push it toward a stance and that
  stance highlights (the stick's *direction* points the selector, so you don't
  have to sweep a cursor). Centering the stick releases the highlight. This is
  on by default; turn it off with **Aim with right stick**, and tune
  **Right-stick dead-zone** if a resting stick drifts the selection.
- **Opening / confirming** from the pad: set **Controller Button** (default
  `None`) to a face/shoulder/stick button. It then opens and confirms the wheel
  using the same Hold / Toggle rule as the keyboard key, so a controller-only
  player never needs to touch the keyboard. The keyboard key keeps working too.

Mouse aiming and stick aiming coexist with no toggle: whichever you move wins,
and the stick takes priority only while it's actually deflected past its
dead-zone.

---

## How a stance gets "set"

Stance! has no setter — it *detects* your stance from what you're holding via a
priority resolver. Stance Wheel works *with* that instead of fighting it:

- For each of your 50 Quick Select slots it asks
  `I.Stance.classifyLoadout({ rightId = <slot item> })`, which is the exact
  inverse mapping: weapon record → stance id. The first slot that resolves to
  the chosen stance is the one it equips (via `I.QuickSelect_Storage.equipSlot`,
  which equips *and* draws). Stance!'s resolver then flips you in on its next
  poll.
- The slot is re-validated at the moment you confirm, so rearranging your bar
  while the wheel is open can't equip the wrong thing.

### Special stances (no weapon needed)

Three stances aren't reached by equipping a hotbar weapon, so the wheel handles
them directly (toggle with **Include Special Stances**):

| Stance   | What the wheel does                                  |
|----------|------------------------------------------------------|
| Commoner | Sheathes everything (`STANCE.Nothing`).              |
| Arcanist | Switches to the spell stance (`STANCE.Spell`).       |
| Brawler  | Empties the right hand and raises fists.             |

### Dualist is intentionally excluded

The Dualist stance needs a specific **off-hand** loadout that a single hotbar
slot can't express, so the wheel doesn't offer it — set it up the normal way.

### "No weapon for that stance"

By default the wheel only shows stances you can actually reach right now (the
specials above plus any stance with a matching weapon on your bar). Turn on
**Show All Stances** to display every stance; ones with no matching hotbar
weapon appear dimmed and, if chosen, just tell you nothing's there rather than
changing your gear.

---

## Settings

Found under **Options → Scripts → Stance Wheel**.

### General

| Setting                  | Default | Notes |
|--------------------------|---------|-------|
| Enabled                  | on      | Master switch. |
| Activation Key           | `G`     | `G` is unbound in vanilla OpenMW, so holding it won't fire a gameplay action. Other letters, `Tab`, `Caps Lock`, `Left Alt/Ctrl/Shift`, `Left Bracket` are available. |
| Activation Mode          | Hold    | `Hold` (hold-aim-release) or `Toggle` (tap-aim-tap). |
| Include Special Stances  | on      | Show Commoner / Arcanist / Brawler entries. |
| Show All Stances         | off     | Show unreachable stances dimmed instead of hiding them. |
| Announce                 | on      | Brief on-screen message when a stance is set. |
| Controller Button        | None    | Optional gamepad button to open/confirm the wheel (same Hold/Toggle rule as the key). |

### Wheel

| Setting             | Default | Notes |
|---------------------|---------|-------|
| Wheel Radius        | 220     | Distance of icons from center, in pixels. |
| Icon Size           | 64      | Base icon size, in pixels. |
| Selected Icon Scale | 1.5     | How much the highlighted icon grows. |
| Dead Zone           | 55      | Center radius (px) that cancels the selection. |
| Mouse Sensitivity   | 1.0     | Multiplier on cursor travel while aiming. |
| Aim with Right Stick| on      | Use the right thumbstick to aim (controller). |
| Right-Stick Dead-Zone | 0.30  | Stick deflection (0-1) ignored as centre noise. |
| Show Stance Name    | on      | Label the highlighted stance. |
| Freeze Camera       | on      | Lock the view/combat/magic inputs while open. |
| Slow Motion         | on      | Slow time while the wheel is open. |
| Time Scale          | 0.25    | Simulation speed used when Slow Motion is on (1.0 = normal). |

---

## Notes & limitations

- Icons are pulled from Stance!'s own `icons/Stance/*.dds`, so they always match
  your installed Stance! version. If an icon can't be loaded, the wheel falls
  back to a text label.
- The stance list is read live from Stance!'s config, so any stances you've
  disabled in Stance! itself are respected. A built-in fallback list keeps the
  wheel usable even if that read ever fails while the interface is present.
- This mod only ever *reads* your Quick Select data and equips an existing slot;
  it never adds, removes, or rearranges your hotbar.

---

*Built to slot into the Stance! ecosystem. Load after Stance! and
Quick Select Ultimate.*
