# 🙈 NoPeek

Keep your laptop open and your terminal running. Keep everyone else out of Slack (or any app).

When a protected app locks, NoPeek **hides it** (like ⌘H), so its content is gone from every Space and display.
If anyone brings it back (⌘Tab, Dock, notification, swipe), a frosted **lock screen** covers every display
with a slightly rude illustration. You get back in with your own secret: a hotkey, a secret word typed on the
lock screen, or a Touch ID tap. Keep poking at it and it snaps your photo: *"Hehe, caught you 📸 Reporting to Ameya…"*

### Design: why hide + shield
Earlier versions glued an overlay onto the app's window. That fights macOS: windows belong to Spaces,
so swipes, full-screen apps and multiple displays needed constant window polling. Now:
- **Locked app in background**: hidden; nothing tracked or polled → **0% CPU**.
- **Locked app brought forward**: one shield panel per display (`canJoinAllSpaces`, above the menu bar),
  created on demand and destroyed when you leave, so nothing renders while it isn't on screen.
- Animations are event-driven (eyes move only when the mouse moves; blinks and peeks are short one-off animations;
  the pastel background runs on Core Animation in the render server).
- The keystroke guard (Accessibility) is enabled only while something is locked: zero typing overhead otherwise.
- Apps NoPeek hid are always unhidden on quit, `pkill`, and even after a crash (recovered on next launch).

## Features

- **Any app**: add from running apps or /Applications; each app has its own unlock methods and idle timeout.
- **Invisible ways in**: a recordable secret hotkey, a secret word (stored as a salted hash), and/or a discreet Touch ID button.
- **Themes**: 🫣 Peekaboo (light, frosted pastel), 👀 Googly Eyes, 🕶️ The Bouncer, or 🎲 Shuffle. They escalate with every try.
- **Intruder catch** that never catches *you*:
  - Photo only after N wrong tries within M seconds (default 3 in 30s), with a "one more and I'm taking your photo" warning first.
  - "It was me" grace: unlock within 20s of a photo and it's deleted.
  - Cooldown between photos, max photos per lock, auto-purge after N days.
  - The camera is used only if you already allowed it; snoopers never see a permission prompt.
- **Report to owner**: a notification with the photo when you're back, plus a Caught gallery.
- **Tamper resistance**: Unlock, Pause, Settings and Quit (including ⌘Q) need Touch ID or your password while anything is locked. Settings closes itself when locking kicks in.
- **Smart locking**: per-app rules (switch-away and/or idle), or **whole Mac inactivity** mode: one Mac-wide idle timer locks everything together and overrides the per-app rules, so switching apps never locks. Plus screen lock/sleep, global "Lock all" hotkey (default ⌃⌥L). Unlocking your Mac unlocks everything (optional).

## Build & run

```bash
make test      # unit tests (NoPeekCore)
make run       # build → ~/Applications/NoPeek.app → launch
```

Optional, recommended once: `scripts/create-signing-identity.sh`. This creates a stable local signing
identity so macOS remembers Camera/Accessibility permissions across rebuilds.
Without it, ad-hoc signing means re-granting them after every `make install`.

Dev flags: `open ~/Applications/NoPeek.app --args --lock-all` (lock immediately) or `--preview`.

## Permissions

| Permission | Why | Without it |
|---|---|---|
| Camera | Snooper photos | Overlay says "Camera shy? Logged anyway." |
| Accessibility | Swallows keystrokes aimed at a locked app | Overlay still grabs focus; tiny race on ⌘Tab |
| Notifications | "Caught 2 snoopers on Slack" | Check the Caught tab |

## Layout

```
Sources/NoPeekCore/   pure logic: models, IntruderPolicy, OwnerGrace, SecretHasher, copy (unit tested)
Sources/NoPeek/
  App/       entry point, AppCoordinator (wiring + guarded owner actions)
  Core/      LockEngine, LockSession, stores, camera, Touch ID, hotkeys, keystroke guard
  Overlay/   window tracking, overlay panels, themes
  Settings/  settings window, shortcut recorder
  MenuBar/   menu-bar menu
```

Data lives in `~/Library/Application Support/NoPeek/` (settings.json, secrets.json, Captures/).

## Honest limits

It's a deterrent, not a vault. Someone who knows macOS could force-quit it from Activity Monitor.
When you really walk away, ⌃⌘Q (lock screen) still wins. Your terminal keeps running either way.
Notification banners from Slack can still show previews; turn those off in Slack if that matters.
