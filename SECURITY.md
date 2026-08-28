# Security Policy

## Supported versions

This is a small single-purpose app with no release branches. Fixes go into the
next release; older ones are not patched.

| Version | Supported |
|---|---|
| 1.1.x (latest release) | ✅ |
| Anything older | ❌ — update first |

If you are running an older build, please reproduce the issue on the
[latest release](https://github.com/dmartoon/MacBook-Keyboard-Backlight-Limiter/releases/latest)
before reporting it.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting: go to the
[Security tab](https://github.com/dmartoon/MacBook-Keyboard-Backlight-Limiter/security)
and choose **Report a vulnerability**. That gives us a private thread, and it is
the only channel that keeps the details out of public view until there is a fix.

Please include:

- the app version (shown in the corner of the panel) and your macOS version
- your Mac model
- what happens, and the shortest way to make it happen

This is a spare-time project, so expect a first reply within about a week. If
the report is valid, the fix ships in the next release and the advisory credits
you unless you would rather it did not. There is no bounty.

## What the app actually does

Useful context for judging whether something is a real finding:

- It runs **unprivileged**, as a normal user-level menu bar app. There is no
  privileged helper, no `SMJobBless` daemon, and no installer script. Root would
  not help it anyway — the keyboard backlight gate is entitlement-based.
- It writes keyboard brightness through the private `CoreBrightness` framework
  and reads ambient lux from the IO registry. It touches nothing else on the
  system.
- It makes **one kind of network request**: an unauthenticated GET to
  `api.github.com` asking for the latest release tag, at most once an hour. No
  telemetry, no analytics, no account, nothing about you or your machine is
  sent, and nothing is ever downloaded or installed automatically — an available
  update turns into a link you click.
- It opens no ports and accepts no input from anything but its own UI.
- The only thing it stores is a handful of preferences in
  `com.martun.KeyboardBacklightLimiter` (brightness ceiling, sensitivity, icon
  visibility, update-check timestamps). No personal data.
- Released builds are signed with a Developer ID, built with the Hardened
  Runtime, and notarized and stapled by Apple.

## Out of scope

These are known and documented, not vulnerabilities:

- **Use of a private Apple framework.** There is no public API for keyboard
  backlight control on macOS. If a future macOS removes it, the app reports that
  no backlight was found rather than misbehaving.
- **Gatekeeper blocking a build you compiled yourself.** `build-app.sh` produces
  an ad-hoc signed local build on purpose; only `release.sh` output is signed for
  distribution.
- **The app overriding other writers of the keyboard brightness property.** That
  is the design: it computes the whole curve because a single write permanently
  disengages macOS's own auto-brightness.
