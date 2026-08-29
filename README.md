<p align="center">
  <img src="docs/icon.png" width="112" alt="">
</p>

<h1 align="center">Dim Keys</h1>

<p align="center">
  Keyboard backlight limiter for MacBook
</p>

<p align="center">
  Set a brightness limit for your keyboard and adjust ambient light<br>
  sensitivity to control when the backlight turns on.
</p>

<p align="center">
  <a href="https://github.com/dmartoon/MacBook-Keyboard-Backlight-Limiter/releases/latest"><img src="docs/download-button.png" width="252" alt="Download for macOS"></a>
</p>

<p align="center">
  <sub>Free · Universal · &lt; 2 MB · macOS 13 or later</sub>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="320" alt="The Dim Keys panel">
</p>

A macOS menu-bar app that caps how bright the keyboard backlight can get and
drives it from the ambient light sensor, with a sensitivity you choose.

**If you just want to use it, [dimkeys.com](https://dimkeys.com) is the better
page.** It has the download, what the settings do, and what to expect. This one
is about how the app works and why it is built the way it is.

## The constraint everything else follows from

There is no public API for keyboard backlight control on macOS. Exactly one call
reaches the hardware from an unprivileged process:

```objc
[BrightnessSystemClient setProperty:value
                            withKey:@"KeyboardBacklightBrightness"
                         keyboardID:id]
```

**Writing that property disengages macOS's own keyboard auto-brightness.**
macOS treats the write as a manual override and stops driving the keys itself.
It does not come back on a timeout, and it does not come back when the ambient
level changes. Pressing F5/F6 hands control back, and so does quitting the app.
See *Known limitations*.

That one fact rules out the design everyone reaches for first. A limiter that
sits back and clamps the backlight only when it exceeds your ceiling would work
exactly once: the first clamp kills the ambient response, and for as long as the
app keeps running, nothing raises the keys again. It cannot be a limiter in the
passive sense.

So the app owns the whole curve. Read the lux, compute the brightness, write it,
every time — the ceiling is an input to that calculation rather than a lid
placed on top of somebody else's.

## The curve

```
lux ≥ offLux                    →  0
lux < onLux, or already lit     →  max(min(minVisible, ceiling),
                                       ceiling × min(1, darkness × 1.4))

darkness = 1 − lux / offLux
```

| Sensitivity | Comes on below | Goes off at |
|---|---|---|
| Low | 7 lux | 10 lux |
| Med | 48 lux | 60 lux |
| High | 120 lux | 150 lux |

Four things in there are important:

- **The gap between `onLux` and `offLux` is hysteresis.** Ambient readings jitter
  by several lux, and with a single threshold the keys blink on and off at the
  boundary. A proportional band was tried and is too narrow at low thresholds,
  hence explicit on/off points per sensitivity.
- **`× 1.4` lets the brightness saturate at the ceiling before pitch black**, so
  the top of the range is reachable in a normally dark room rather than only in
  a darkroom.
- **`minVisible` is a floor, not decoration.** Scaling a low ceiling by the
  ambient factor otherwise lands below what the hardware can actually show, so
  at the Min preset every "lit" state came out invisible and changing the
  sensitivity looked like it did nothing.
- **A ceiling of `0` collapses the whole expression to `0`** with no special
  case, and the result equals the current brightness, so the deadband writes
  nothing further. That is what keeps the Off preset from becoming a write storm.

## What the hardware actually does

Measured on this machine (`Mac17,9`, M5 Pro, macOS 26.6.2) by writing values and
reading `backlightLevelForKeyboard:` back:

- PWM range is **100–14660**. The normalized→PWM mapping is linear,
  `PWM = 100 + n × 14560` — **except that `0` maps to PWM 0.**
- So **PWM 1–99 does not exist.** It is a cliff, not a floor: zero is dark, and
  any positive value at all lands at PWM 100 or above. The entire span from
  `1e-7` to `1e-4` covers about 1.5 PWM steps out of 14560, which is not
  perceptible.

That is why the panel's slider runs **1–100% rather than 0–100%**, and why a
genuinely dark keyboard is the separate **Off** preset rather than a slider
position. Labelling the dimmest lit state "0%" read as though the keyboard were
off, and there is no meaningful travel below it to expose.

## Things that do not work

Each was verified broken here, on macOS 26.6.2. They look plausible, several of
them return success, and none of them move the hardware.

| Approach | What happens |
|---|---|
| `IOHIDDeviceSetReport` on the Keyboard Backlight HID device | Returns `kIOReturnSuccess`, hardware never changes |
| `IOHIDDeviceGetReport` / `IOHIDDeviceGetValue` | `kIOReturnUnsupported` — the device is write-only to us |
| `IOHIDDeviceOpen` with `kIOHIDOptionsTypeSeizeDevice`, then write at 20 Hz | Seize succeeds, writes still dropped |
| `KeyboardBrightnessClient.setBrightness:fadeSpeed:commit:forKeyboard:` | Returns `true`, no effect |
| `KeyboardBrightnessClient.enableAutoBrightness:` then write | No effect |
| Running as root | Irrelevant — the gate is entitlement-based, not uid-based |

`corebrightnessd` holds `com.apple.hid.manager.user-access-protected`, and the
driver honours only clients carrying it. Apple does not grant it to third
parties, **so a privileged `SMAppService` helper daemon hits exactly the same
wall** — that is the workaround worth not spending a weekend on.

## Architecture

About 1,900 lines of Swift, no dependencies, no bundled frameworks.

```
main.swift                        NSApplication bootstrap, .accessory policy
AppDelegate.swift                 Menu bar item and the NSPopover panel — one page, no settings screen
KeyboardBacklight.swift           CoreBrightness bridge: read, write, change notifications
AmbientLightSensor.swift          IO registry walk for a node publishing CurrentLux
Limiter.swift                     Owns the lux→brightness curve and writes the result
Settings.swift                    Presets, sensitivity thresholds, UserDefaults
LaunchAtLogin.swift               SMAppService wrapper
UpdateCheck.swift                 GitHub releases check — notifies, never installs
UpdateNotifier.swift              The notification for it
OldVersionCleanup.swift           Offers once to retire a pre-rename copy
MenuBarIcon.swift                 The status item glyph, drawn in code
tools/make-icon.swift             Regenerates AppIcon.icns — the app icon is code, not a blob
tools/make-download-button.swift  Draws docs/download-button.png from the landing page's CSS
```

It is **event-driven**: `registerNotificationForKeys:keyboardID:block:` fires on
every brightness change, and a 1 Hz timer samples lux, which has no notification
of its own. Measured idle CPU is 0.0%.

Two details that are easy to get wrong if you touch them:

- **The ambient sensor is found by walking the IO registry for any node
  publishing `CurrentLux`**, not by class name — the class is machine-specific.
  The walk can also come back empty on a login-time launch, both because the
  property may not be published yet and because a recursive registry iterator is
  invalidated by any change to the tree it is walking. `find()` therefore checks
  `IOIteratorIsValid` and only reports "no sensor" from a walk that ran to
  completion, and the panel is rebuilt if a sensor turns up late.
- **The panel is absolutely framed at one fixed height**, so anything that adds
  a row reflows everything under it. The update notice reuses the version
  label's slot for exactly this reason.

## Build and test

```bash
./build-app.sh                  # ad-hoc signed, arm64, local use only
open "build/Dim Keys.app"
```

```bash
# Popover layout regression test — must print PASS
KBL_SELFTEST=1 .build/release/KeyboardBacklightLimiter
```

The self-test shows the popover against a real window and asserts that no
subview escapes the bounds and that the bottom row does not collide. It covers
both panel layouts, with and without an ambient sensor, the rebuild between
them, and the update-available state. The bottom row is positioned from measured
text, so rewording a button title is precisely the change that would silently
push the version label underneath it.

One caveat worth knowing before you run it: **launched from inside the `.app`
bundle it reads and writes your real preferences domain.** The bare
`.build/release` binary has no `Info.plist`, so it gets a throwaway domain and
cannot touch anything.

```bash
./release.sh                    # universal, Developer ID, hardened runtime, notarized, stapled
./release.sh --no-notarize      # packaging only, skips the Apple round trips
```

`release.sh` is what produces a shippable artifact; `build-app.sh` output is not
shippable, since notarization requires a secure timestamp and the hardened
runtime. Hardened Runtime does **not** break the private framework — library
validation permits it because `CoreBrightness` is Apple-signed, so no
`disable-library-validation` exemption is needed.

`CFBundleShortVersionString` is edited by hand in `Resources/Info.plist`.
`CFBundleVersion` is injected by `release.sh` from `git rev-list --count HEAD`,
because a hand-maintained build number does not error when it goes stale — it
just silently stops anyone from being offered the update.

## Known limitations

- **It depends on a private framework.** A future macOS release could rename or
  remove it. The app fails safely rather than misbehaving:
  `KeyboardBacklight.open()` returns nil and the panel reports that no keyboard
  backlight was found, with the menu bar item still there so you can quit.
- **Not distributable on the Mac App Store.** The app's entire function is a
  private framework and there is nothing public to port to, so this is an
  automatic rejection rather than a risk to manage.
- **macOS takes the backlight back when the app quits.** Verified with a
  flashlight: once the app is gone the keys track the light again and go off
  under a direct beam. The override appears to be tied to the client
  connection rather than to the value written, which would explain why nothing
  the app can write releases it but exiting does. That part is inference rather
  than measurement. `stop()` still restores the brightness captured before the
  first write, falling back to a mid-scale value when that was itself dark, but
  this is now only about the moment between exit and macOS picking it up.
- **The app overrides anything else writing the same property**, pulling an
  external write back to its own target within about half a second. That is the
  design working, but it puts System Settings › Keyboard › *"Turn keyboard
  backlight off after inactivity"* at risk if that timeout is implemented the
  same way. Unverified either way. If it does conflict, the fix is to watch
  `HIDIdleTime` and stop driving past the same threshold, not to weaken the
  write path.
- **Below macOS 26 is untested rather than unsupported.** The deployment target
  is 13.0 and the binary will launch there; nothing older has been exercised.

## Contributing

Issues and pull requests are welcome. Bug reports are much more useful with the
macOS version and the Mac model in them. A good deal of this app's behaviour is
hardware-specific. The numbers above were measured on an M5 Pro MacBook Pro,
and the app is confirmed working on an M4 MacBook Air.

Security issues: see [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
