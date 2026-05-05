# Installing OCOS

OCOS runs anywhere the OpenComputers mod (or its faithful emulators)
runs. It does **not** require a custom EEPROM — the stock OC BIOS
already locates `/init.lua` on any attached filesystem, and that's all
we need. Install boils down to "put OCOS files on a disk and tell the
machine to boot from that disk".

This document covers four paths:

1. [Real Minecraft + OpenComputers](#real-minecraft--opencomputers-mod)
2. [Ocelot Desktop emulator](#ocelot-desktop-emulator) — recommended for
   end-to-end visual testing without booting Minecraft.
3. [ocvm (CLI emulator)](#ocvm-cli-emulator) — fastest dev loop;
   used by `tools/test-boot.sh`.
4. [Manual / loot-disk install](#manual--loot-disk-install) — when you
   want to drop OCOS files on a floppy or a host-mounted folder
   directly.

The installer that all on-VM paths use is
`dist/ocos-installer.lua` — a self-contained Lua chunk that bundles every
OCOS source file as a long-string and writes it onto a target disk. Run
`tools/build-installer.py` to regenerate it after editing `src/`.

## Hardware checklist

OCOS targets OpenComputers 1.7.5 or newer (Lua 5.3 architecture). A
typical machine that boots OCOS comfortably:

| Item | Tier | Notes |
| ---- | ---- | ----- |
| CPU  | T2 (Lua 5.3) | T3 recommended for the GUI compositor |
| RAM  | 384 KiB ×2 | 768 KiB total is enough for everything except large `Edit` buffers |
| GPU  | T3 | T2 works but the dock + status bar will be cramped |
| Screen | T3 | T2 fine |
| Keyboard | any |
| Disk | ≥ 1 MiB | OCOS source is ~280 KiB; leaves room for /var/log + a few apps |
| EEPROM | stock OC `bios.lua` | no custom firmware needed |
| Optional | data card, internet card, modem | unlock crypto / pkg install / networking |

Capability enforcement is **off by default** so a freshly-flashed
machine boots straight into a root shell. Flip
`/etc/security.cfg`'s `enforce` to `true` after you've created users.

---

## Real Minecraft + OpenComputers mod

1. Place the machine, drop the components above into the case, attach a
   screen + keyboard. Insert a stock `EEPROM (Lua BIOS)` (the default
   one shipped by the mod). Power on.
2. Insert an OpenOS floppy (or another Lua OS that has `wget` and a
   shell) and let the machine boot from it.
3. From the OpenOS shell:

   ```sh
   wget https://raw.githubusercontent.com/AlexMelanFromRingo/OCOS/main/dist/ocos-installer.lua /tmp/ocos.lua
   /tmp/ocos.lua            # or: lua /tmp/ocos.lua
   ```

   The installer picks the only writable disk that isn't OpenOS, copies
   every OCOS file, and sets that disk as the new boot address. If you
   have several writable disks, pass an address prefix:

   ```sh
   /tmp/ocos.lua 88895671
   ```

4. Eject the OpenOS floppy and reboot the machine. The stock BIOS will
   now boot from your OCOS disk and you should see `OCOS 0.1.0` followed
   by the dock.

If you don't have an internet card, see
[Manual / loot-disk install](#manual--loot-disk-install).

## Ocelot Desktop emulator

[Ocelot Desktop](https://gitlab.com/cc-ru/ocelot/ocelot-desktop) (Java,
Scala, LWJGL) is the closest thing to running OpenComputers without
Minecraft. Same API surface, same screen rendering, full
double-buffering. If OCOS works in Ocelot, it works in MC.

1. **Get Ocelot.** Clone the GitLab repo and run its build (the README
   covers the gradle target). You end up with a launcher script that
   opens a window with a virtual machine inside.
2. **Configure a machine.** Through the Ocelot UI, create a new VM
   with: T3 GPU, T3 screen, keyboard, T2 CPU (Lua 5.3 arch), 768 KiB
   RAM, an EEPROM with the stock OC BIOS, and at least one writable
   filesystem.
3. **Install OCOS.** You have two practical paths:
   * **Network install.** Add an internet card to the VM, boot
     OpenOS, and run the wget pipeline from the [real-MC section](#real-minecraft--opencomputers-mod).
   * **Host folder install.** Ocelot can expose a host directory as a
     readonly filesystem (it's how loot disks work). Point one at
     `<OCOS-checkout>/dist/`, boot OpenOS, then
     ```sh
     /mnt/<host-floppy-addr>/ocos-installer.lua
     ```
     does the rest.
4. **Boot OCOS.** Reboot the VM; the stock BIOS finds `/init.lua` on
   the freshly-installed disk and OCOS comes up.

For the absolute shortest dev loop in Ocelot, mount
`<OCOS-checkout>/src/` itself as a *bootable* readonly disk — that
mirrors what `tools/run-emu.sh` does for ocvm. The stock BIOS will boot
straight from it without any installation step. The drawback is that
`/var`, `/etc/passwd`, and other writes go to a separate writable disk
that gets auto-mounted under `/mnt/<addr>/`.

## ocvm (CLI emulator)

[ocvm](https://github.com/payonel/ocvm) is the C++ emulator OCOS uses in
its CI loop. It's the fastest way to iterate on the kernel, but it
reports `0×0` for the GPU when stdout isn't a real terminal, so the GUI
isn't visible. Selftests run cleanly because they exercise the kernel
without rendering.

1. Build ocvm once: `(cd reference/ocvm && make lua=lua5.3)`.
2. Run the boot self-test (recommended sanity check after any change):

   ```sh
   tools/test-boot.sh
   ```
3. Boot interactively (in a real terminal):

   ```sh
   tools/run-emu.sh
   ```

   ocvm uses the OCOS source tree (`src/`) as a readonly boot
   filesystem and keeps state for the writable disk under
   `emulator/instance/<addr>/`.

## Manual / loot-disk install

Use this when you don't have an internet card, you're working on a
totally offline machine, or you just want to skip the installer.

1. Copy the contents of `src/` (the **contents**, not the `src/`
   directory itself) onto a writable filesystem. The result must look
   like:
   ```
   <fs root>/
     init.lua
     sys/...
     bin/...
     apps/...
     etc/...
     home/
   ```
2. From the host running Ocelot/MC: drop those files into the VM's
   writable-disk directory, or use Ocelot's "loot floppy from host
   folder" feature pointing at the same tree.
3. Insert the disk, boot the machine. Stock BIOS finds `/init.lua` and
   OCOS starts.

If your floppy is too small (< 280 KiB), use a hard drive instead — a
T1 HDD has 1 MiB of space, plenty for OCOS.

## After first boot

* `help` — list everything the shell can do.
* `useradd <name>` — create a user. Edit `/etc/security.cfg` to flip
  `enforce = true` once at least one user exists; the kernel will then
  consult capabilities at every `vfs.open` write and `exec.exec` spawn.
* `svc start uid` — start the GUI compositor (default service set is
  `logd` + `sessiond`; on a real OC machine with a known-size screen,
  enable `uid` in `/etc/services/uid.cfg` to autostart instead).
* `dmesg` — kernel log. `cat /var/log/audit.log` — security events.
* `pkg install <id>` — package manager (registries are configured in
  `/etc/registries.cfg`; nothing is shipped pointing at any
  third-party server).

## Troubleshooting

* **"no bootable medium found"** — the stock BIOS didn't find
  `/init.lua` on any filesystem. Check the disk's contents and that the
  EEPROM's boot data points at the right address (`eeprom -d` in
  OpenOS, or just leave it blank and the BIOS will scan).
* **Screen stays blank, computer beeps SOS** — kernel panicked. Reboot
  into OpenOS, mount the OCOS disk, and read `/panic.log` (written by
  `sys/k/panic.lua`) and `/var/log/dmesg.log` (written by `logd`).
* **`pkg install` says "no internet"** — the VM has no internet card,
  or the host has disabled HTTP. Pass a local directory to
  `pkg install` instead.
