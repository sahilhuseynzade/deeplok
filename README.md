# Deeplok

**Freedom-style distraction blocking for [Omarchy](https://omarchy.org).**
Block websites and apps with instant sessions, scheduled starts, recurring
weekly blocks — and an optional locked mode you can't cheat past.

> 󰦝 Lives in your bar. Click it to start a block, build blocklists, and
> manage schedules.

## Features

- **Blocklists** — named groups of websites (`youtube.com`) and apps
  (window class, e.g. `steam`, `discord`). Ships with a starter
  "Distractions" list.
- **Instant sessions** — pick lists, pick a duration (15m…12h), block now.
- **Scheduled sessions** — choose a date and time; the block starts on its
  own.
- **Recurring schedules** — days of the week plus a time range
  (`Mon–Fri 09:00–12:00`). Overnight ranges work (`22:00–06:00`).
- **Locked mode 󰌾** — a locked session or schedule cannot be ended,
  disabled, or weakened until its end time. Enforced by a root-owned
  helper, not just the UI: even killing the shell doesn't lift the block.
- **App blocking** — windows of blocked apps are closed the moment they
  appear, with a notification.

## Install

```bash
omarchy plugin add https://github.com/sahilhuseynzade/deeplok.git --enable
```

Then click the 󰦝 bar widget → **Install system helper** (authenticates
once via polkit). App blocking works without this step; website blocking
needs it.

## How it works

- The engine runs inside `omarchy-shell` as a plugin service. Every 5
  seconds it evaluates your sessions and schedules and reconciles the
  desired block set.
- **Websites** are blocked through a marked section in `/etc/hosts`
  (`0.0.0.0` + `::` entries, `www.` variants included), applied by a small
  root-owned helper at `/usr/local/lib/deeplok/deeplok-helper`. A sudoers
  drop-in (`/etc/sudoers.d/50-deeplok`) allows exactly three invocations —
  `apply`, `clear`, `status` — with no password, so scheduled blocks
  engage unattended (at 2 AM, with no dialog to click).
- **Apps** are matched against Wayland toplevel app ids (exact, or
  substring of 3+ chars) and politely closed via the compositor.
- **Locked mode** writes a lock ledger to `/etc/deeplok/lock.json`. While
  any entry is unexpired the helper refuses `clear`, refuses uninstall,
  and re-merges the locked domains into every `apply` — so editing state
  files or restarting the shell won't lift the block.
- State lives in `~/.config/omarchy/deeplok/state.json`.

## Honest limitations

- You have root on your own machine; a determined future-you can always
  edit `/etc/hosts` with `sudo`. Deeplok raises the friction (like
  Freedom does), it doesn't make bypass impossible.
- Browsers with **DNS-over-HTTPS** enabled bypass `/etc/hosts`. Disable
  DoH in the browser (or point it at the system resolver) for reliable
  blocking.
- Browsers cache DNS; an already-open tab may keep working for a bit.
  The helper flushes `systemd-resolved` on every change.
- If the shell isn't running when a block should end (e.g. you're logged
  out), the hosts entries stay until the shell next reconciles. Escape
  hatch after a lock expires: `sudo /usr/local/lib/deeplok/deeplok-helper
  clear`.

## Uninstall

Panel → **Uninstall system helper** (refused while a locked block is
running), then:

```bash
omarchy plugin remove shl.deeplok
```

## Development

```bash
node --test tests/            # pure-logic tests (lib/Model.js)
omarchy plugin validate .     # manifest checks
```

Layout: `Service.qml` (engine: timers, disk, processes), `Panel.qml` +
`BarWidget.qml` (UI), `lib/Model.js` (pure, tested logic),
`bin/deeplok-helper` (root side), `bin/deeplok-setup` (pkexec
install/uninstall).

## License

[MIT](LICENSE) · [deeplok.com](https://deeplok.com)
