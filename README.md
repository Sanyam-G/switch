# Switch

A keyboard-driven window switcher for macOS. ⌘-Tab shows every open window, including the ones on other Spaces, and typing filters the list. Like it? [Buy me a coffee →](https://www.paypal.com/paypalme/sanyamg0)

<p align="center">
  <img src="assets/demo.svg" width="720" alt="Switch: ⌘-Tab steps through every window, typing filters them, picking a window on another Space switches to that Space, then the vertical list and ⌥-` within one app">
</p>

→ [switch-dev.sanyamgarg.com](https://switch-dev.sanyamgarg.com)

## Install

```
brew install --cask Sanyam-G/switch/switch
```

Or [download the latest .dmg](https://switch-dev.sanyamgarg.com).

Notarized by Apple. macOS 14+, Apple silicon and Intel. Free.

## Features

- One picker with every open window, most recent first, with thumbnails
- Type part of an app name or window title to filter
- Windows on other Spaces and fullscreen windows are in the list, and picking one takes you to it
- ⌥-` cycles the windows of the current app
- Grid or vertical list
- Extra hotkeys for the current Space only or the current display only
- Close, quit or hide from inside the picker
- Pin apps to the top of the picker
- Dock notification badges on app icons
- Hide apps, or windows by title, from the picker
- Pass-through apps (a VM or remote desktop) keep the hotkeys while they're in front
- Lists windows of apps off the Stage Manager stage
- Lists Steam's windows, though a helper process draws them
- Updates itself

## How it compares

| | Switch | AltTab | Contexts | Witch |
|---|---|---|---|---|
| Price | Free | Free, Pro $9.99 or $24.99 lifetime | $9.99 | $14 |
| Type to filter | Yes | Pro only | Yes | Yes |
| Source | Source-available ([FSL-1.1-MIT](LICENSE.md)) | Open source (GPL-3.0) | Closed | Closed |

Prices from each app's site in November 2026. AltTab has many more settings, so if you want to tune everything, it's the better pick.

## Shortcuts

- ⌘-Tab cycles all windows, ⇧ goes backward
- ⌥-` cycles the windows of the current app
- Type to filter by app name or window title
- 1-9 (or numpad) picks a tile
- Optional Vim-style H J K L navigation, or home row keys A S D F G J K L ; to pick (either one turns off type to filter)
- ⇧⌘W closes the selected window, ⇧⌘Q quits its app, ⇧⌘H hides it (plain ⌘W / ⌘Q / ⌘H in sticky mode or with type to filter off)
- ↵ commits, Esc cancels, ⌘, opens Settings

## Cross-Space

Windows on other Spaces show up in the picker, badged with their Space (DESKTOP 2, FULLSCREEN). Minimized and hidden windows are badged too. Pick one and Switch takes you to it. Toggle off, and choose whether to mix Spaces by recency, in Settings → Picker → Cross-Space. Settings → General → Hotkeys has separate hotkeys for the current Space and the current display.

## Vertical list

Settings → Appearance → Vertical mode → Vertical list. Single-column layout with app icon, name, window title, and thumbnail.

## Pinned apps

Hover a window and click its pin to keep that app's windows at the top. Settings → Picker → Pinned apps lists them.

## Excluded apps

Settings → Picker → Excluded apps. Hide windows from specific apps. Excluded titles does the same for windows by title (untitled windows match their app name).

Menu bar apps are left out. Settings → Picker → Always include apps lists their windows anyway, matched by part of the app name.

## Sticky mode

Settings → Picker → Sticky picker. Release ⌘ to keep the picker open. ↵ to switch, Esc to cancel. Settings → General → Hotkeys → Sticky toggle binds a separate hotkey that flips sticky on or off at runtime. Settings → General → Hotkeys → Sticky picker binds hotkeys that always open it sticky.

## Click only

Settings → Picker → Click only, on by default. Hovering leaves the selection alone, so only the keyboard and clicks move it. Click a window to pick it. Without sticky mode, keep ⌘ held until you click, since releasing it switches to the selected window. Keyboard only overrides this setting.

## Stage Manager

With Stage Manager on, windows of apps off the stage are still listed. Picking one brings its app onto the stage. macOS may show the app's last-used window rather than the one you picked, since Stage Manager suspends off-stage apps.

## Permissions

Accessibility, to catch ⌘-Tab and focus windows. Screen Recording, only for thumbnails. Turn off Settings → Appearance → Show thumbnails and Switch doesn't need it. Settings → Permissions shows what's granted. Switch has no analytics and no account. The only network request is the update check.

## Updates

Built-in. Daily background check, which you can turn off in Settings → General → Updates. Settings → About → Check for Updates for manual. EdDSA-signed appcast via Sparkle.

## Uninstall

```
brew uninstall --cask Sanyam-G/switch/switch
```

Or quit Switch and drag `Switch.app` from `/Applications` to the Trash.

## Roadmap

[switch-dev.sanyamgarg.com/development](https://switch-dev.sanyamgarg.com/development/).

## Star History

<img alt="Star History Chart" src="https://raw.githubusercontent.com/Sanyam-G/Sanyam-G/main/assets/star-history-switch.svg" />

## Contributing

I'll take feature ideas from AI-generated PRs, but I won't merge them. Hand-written PRs are welcome; [CONTRIBUTING.md](CONTRIBUTING.md) has the build steps.

## License

[FSL-1.1-MIT](LICENSE.md). Source-available, not OSI open source. Free for any non-competing use. Converts to MIT on May 6, 2028.

---

© 2026 Sanyam Garg
