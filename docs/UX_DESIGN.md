# OCOS Desktop UX — Design Proposal

This document is a *plan*, not yet code. Review and tell me what to
trim, what to expand, and which item to start with.

## Hard constraints (the screen)

- **Tier-3 GPU + screen** is 160 × 50 cells. T2 is 80 × 25. T1 is 50 × 16
  and one-bit colour — we render text-only on T1, no decorative chrome.
- Cells are **monospace characters with fg+bg**, not pixels. UTF-8 box
  drawing (`│ ─ ┌ ┐ └ ┘ ┤ ├ ┬ ┴ ┼`) is our only real geometry.
- The compositor's `Buffer` already diff-flushes at frame end, so any
  "redraw the whole window" we do is cheap *if* we don't beat the CPU
  call budget per tick (T3: 1.5).
- Screen is grabbed by *clicking* on it in-game; touches arrive as
  `oc.signal.touch / drag / drop / scroll`. The mouse wheel and right
  click both work — every keyboard shortcut still has to exist as a
  fallback so a player without a mouse can use everything.

## What's there today

- `lib/ui/compositor` — single Buffer, root widget, event queue
  (`kbd.key`, `kbd.paste`, raw OC touch/drag/drop/scroll → typed
  events). One `compositor:run` loop renders dirty regions.
- Widgets: `label`, `button`, `input`, `checkbox`, `list`, `menu`,
  `window`, `clock`, `dock`, `wallpaper`, `terminal`, `textarea`.
- Apps: `desktop`, `files`, `terminal`, `edit`, `dmesg`, `inspect`,
  `settings`. Each `Main.lua(args, env, session)` attaches widgets to
  `session.compositor`.

## Gaps you flagged

1. **No way to log out, lock or shut down from the GUI.** Currently the
   compositor just owns the screen forever.
2. **Settings has no language picker** even though `lib.lang` already
   loads `de / en / ru / uk` from `/etc/locale/`.
3. **Terminal app needs polish** (scroll, copy/paste, focus, Ctrl-keys
   round-trip).
4. **Windows can't be moved, resized, minimised, multiplexed** — `window`
   is just a static frame.
5. **Desktop has no icons** — files-on-desktop, app shortcuts.
6. **No multi-page desktop** — when icons run out of space we need
   something other than a scrollbar (T2/T3 might be on a wall, no touch).
7. **Multi-user**: no user picker on login screen, no profile-per-user
   wallpaper / dock layout.

## Proposed architecture

### 1. Window manager (`lib/ui/wm.lua`)

A new layer between compositor and apps. Owns the **window list**, the
**focus stack**, and the **per-window state machine**.

```
WM = {
  windows = {},       -- ordered z-stack; top = front
  focus   = nil,      -- pid of focused window
  taskbar = nil,      -- the bar widget that lists open windows
}

Window = {
  id, title, owner_pid,
  body,               -- the app's widget tree
  bounds = { x, y, w, h },
  state  = "normal" | "maximised" | "minimised",
  saved  = { x, y, w, h },   -- restore target after un-maximise
  resizable, closable,
  on_close, on_focus, on_resize,
}
```

Public API:
- `wm.open(opts)` — open a new window; opts = title, body, w, h, app
- `wm.close(win)`, `wm.focus(win)`, `wm.minimise(win)`, `wm.maximise(win)`
- `wm.tile_left(win)`, `wm.tile_right(win)` — Win+← / Win+→ as fallback

### 2. Window chrome

```
┌─ Files ──────────────────────── _ ▣ × ─┐
│ /home/alex                              │
│ ▸ Documents/                            │
│ ▸ Downloads/                            │
│   notes.txt                            ↕│
│                                         │
└─────────────────────────────────────────┘ ↘
```

- 1-cell title bar with the title left-aligned, three buttons right:
  `_` minimise, `▣` maximise/restore, `×` close.
- 1-cell border on every side (focused: bright accent; unfocused: muted).
- Bottom-right `↘` is the resize grip (T3 mouse drag). Keyboard
  `Ctrl+Alt+arrows` resize when window is focused; `Ctrl+arrows` move.
- Click in body → focus (z-stack pulls window to front). Click on title
  → focus + start drag. Click `×` → close.

### 3. Taskbar (replaces or extends today's dock)

Bottom 1-cell strip. Two regions:
```
[ Files ▾ ][ Terminal ▾ ][ +... ]                  alex 14:32
```

- Each open window gets a chip with title + caret.
- Minimised windows stay in the chip strip (caret ▴ instead of ▾).
- Right side: clock + current user + `[…]` menu (logout / lock / shutdown).
- The launcher `[ +... ]` opens a popover with the apps we ship plus
  installed `pkg`s — same list the dock has today but composable.

### 4. Logout / lock / shutdown menu

The right-side `[…]` button on the taskbar opens:
```
┌────────────────┐
│ Lock screen    │   Win+L
│ Switch user…   │   Win+U
│ Log out        │
│ Restart        │
│ Shut down      │
└────────────────┘
```

- **Lock screen** asks for the current user's password to dismiss; the
  compositor stays running, all windows hidden under a black overlay.
- **Switch user** drops back to the login picker without rebooting; uid
  closes the current session, init starts the picker (or sessiond if
  GUI was started after sessiond).
- **Log out** = same as Switch user but no auto-reopen.
- **Restart / Shut down** = `computer.shutdown(true|false)`.

### 5. Login picker (multi-user)

When `users.list()` is non-empty, sessiond / uid show:
```
┌─────────────────────── OCOS 0.2.4 ───────────────────────┐
│                                                          │
│         (alex)            (root)            (+ new)      │
│         ▔▔▔▔▔            ▔▔▔▔▔▔                          │
│      avatar bg         avatar bg                         │
│                                                          │
│   Password: ___________________________ [ Enter ]        │
└──────────────────────────────────────────────────────────┘
```

- Avatars are 8×4 cell tiles painted from per-user `~/.profile/avatar`
  (a tiny OCBM bitmap — same compositor primitive as wallpapers).
- Tab cycles between users. Enter on the focused user opens the
  password field. ↓/↑ navigate.
- "+ new" calls `useradd` interactively.

### 6. Desktop with icons + paged scroll

Workspace area between status bar and taskbar. Rendered as a **grid of
icon cells**:

```
┌──────────────── desktop (page 1 / 3) ──◀──▶─┐
│  ┌──┐    ┌──┐    ┌──┐    ┌──┐    ┌──┐       │
│  │📁 │    │📁 │    │📄 │    │ 🖼 │    │ 🌐 │       │
│  └──┘    └──┘    └──┘    └──┘    └──┘       │
│  Docs    Pics    notes   wall    chat       │
│                                              │
│  ┌──┐    ┌──┐                                │
│  │📦 │    │ ⚙ │                                │
│  └──┘    └──┘                                │
│  pkg     Settings                            │
└──────────────────────────────────────────────┘
```

- Each icon: 4 wide × 3 tall (frame + glyph + label). Glyphs are
  single-character UTF-8 (📁 📄 🖼 🌐 ⚙ 📦 …) coloured by file type.
- Source: `~/Desktop/` directory. Anything in it shows as an icon.
  `.lua`, `.txt`, etc. open with the right app via `/etc/mailcap.cfg`.
- **Paged**, not scrolled: when the grid overflows, we paint a fixed
  number of pages and add `◀ ▶` arrows in the top-right that the user
  clicks (or PgUp/PgDn) to navigate. No reliance on touch-scroll.
- Right-click on empty desktop → context menu (New file, New folder,
  Change wallpaper, Settings).

### 7. Settings — language + others

`/apps/settings.app/Main.lua` already has theme picker. Add tabs:
```
[ Appearance ] [ Language ] [ Users ] [ System ] [ About ]
```

- **Appearance**: theme list (already present), wallpaper picker.
- **Language**: list of locales from `vfs.list("/etc/locale")`. Click →
  `lang.set("uk")`, then `ipc.publish("ui.lang.changed")` so widgets
  re-translate themselves.
- **Users**: lists `/etc/passwd`, lets admin add / remove / promote
  users. Edit own password.
- **System**: enforce toggle, autostart toggle for uid, shutdown
  behaviour.
- **About**: version, hostname, hardware tier.

### 8. Terminal app polish

- Use the new `term/console` scrollback (1000 lines) directly so the
  GUI terminal can scroll like the TTY can.
- Right-click in terminal → context menu (Copy / Paste / Clear /
  New tab).
- **Tabs** within the terminal window — one shell per tab, click to
  switch, `+` button to spawn another.

## Implementation order (one slice at a time)

I propose we land features in this order. Each one is its own commit
that you sign off on before I touch the next:

| # | Slice                                  | Touches                               | Risk |
|---|-----------------------------------------|---------------------------------------|------|
| 1 | Boot menu (already done in v0.2.4)      | init.svc                              | low  |
| 2 | WM core: window list, focus, z-stack    | new lib/ui/wm.lua                     | med  |
| 3 | Window chrome (close/min/max buttons)   | widgets/window.lua                    | low  |
| 4 | Move/resize via mouse + keyboard        | wm.lua + window.lua                   | med  |
| 5 | Taskbar with open-window chips          | desktop.app                           | low  |
| 6 | Logout / shutdown menu in taskbar       | desktop.app + wm.lua                  | low  |
| 7 | Settings: Language tab                   | settings.app + lang module            | low  |
| 8 | Terminal: scrollback + Copy/Paste menu  | terminal.app                          | med  |
| 9 | Desktop icons reading from ~/Desktop    | desktop.app + new icon widget         | med  |
| 10| Paged desktop with ◀ ▶ navigation       | desktop.app                           | low  |
| 11| Login picker (multi-user)                | sessiond + new picker.app             | high |
| 12| Lock screen                              | new lock.app + wm.lua                 | med  |

Total: ~11 slices for a "complete" desktop. We're at #1.

## What I want from you before I touch slice #2

- **Approve the WM data model** — windows have `{title, body, bounds,
  state, saved}` and the WM owns the z-stack. Anything you'd add?
- **Visual style**: I drew chrome with `┌─┐│└┘`. Want a different style
  (double-line `╔═╗`, dotted `┌╌┐`, no border, …)?
- **Keyboard shortcuts**: I propose Win+L lock, Win+U switch user,
  Alt+Tab focus next, Ctrl+W close, Ctrl+Alt+arrows resize,
  Ctrl+arrows move. Push back if any of these clash with what you use.
- **Desktop directory**: `~/Desktop/` as the source. OK with that?
  (Some OSes use a separate `xdg-user-dirs` config.)
- **Icon glyphs**: OK to use the UTF-8 emoji set above, or do you want
  ASCII-only / Material-style (`▥` for files, `▣` for folders)?

Once you confirm those, I implement slice #2 and we keep going.
