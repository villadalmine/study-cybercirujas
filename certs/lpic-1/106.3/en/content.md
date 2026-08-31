# 106.3 Accessibility

> **Exam:** LPIC-1 102-500 · **Topic 106:** User Interfaces and Desktops · **Objective 106.3:** Accessibility · **Official weight:** 1
>
> **Objective terms (v5.0):** Sticky/Repeat Keys · Slow/Bounce/Toggle Keys · Mouse Keys · High Contrast/Large Print Desktop Themes · Screen Reader · Braille Display · Screen Magnifier · On-Screen Keyboard · Gestures (used at login, e.g. GDM) · Orca · GOK · emacspeak

---

## 1. Motivation: accessibility as a production property, not a desktop preference

### 1.1 The architectural problem

Accessibility on Linux is usually taught as "check some boxes in Settings". That framing is wrong for anyone operating a fleet, and it produces three concrete production failures:

**Failure 1 — the state lives where configuration management cannot see it.**
A user's accessibility configuration is scattered across at least five independent stores with different lifetimes, different owners, and no common transaction:

| Store | Scope | Survives reboot? | Survives `setxkbmap`? | Managed by CM? |
|---|---|---|---|---|
| `dconf` user database (`~/.config/dconf/user`) | per-user, per-session | yes | yes | only via `system-db` layering |
| XKB AccessX controls (X server state) | per-X-server | **no** | **no** — silently reset | no |
| `/sys/accessibility/speakup/*` | per-boot, global | **no** | n/a | via `sysfs.d`/module options |
| `/etc/brltty.conf` + udev | global | yes | n/a | yes |
| `~/.config/speech-dispatcher/` | per-user | yes | n/a | rarely |

Ansible converges `/etc`. None of the above except `/etc/brltty.conf` lives there. This is why a11y settings are the single most common source of silent drift on managed desktop fleets: the image is compliant at build time and diverges within one login.

**Failure 2 — accessibility disappears exactly on the recovery path.**
The boot chain is `firmware → GRUB → initramfs → emergency shell → systemd → display manager → session`. Screen reading is available in the *last* stage on most distributions. Every stage before it — precisely the stages you reach when something is broken — is mute and non-braille unless deliberately engineered. An operator who depends on speech can administer a healthy machine and cannot administer a broken one. That is a single point of failure with a human in it.

**Failure 3 — nothing tests it.**
There is no `curl -f` for "the screen reader still speaks after the toolkit upgrade". A GTK4 migration, a Wayland default flip, a `NO_AT_BRIDGE=1` inherited from a container base image, or a Flatpak packaged without `--socket=accessibility` each break the entire assistive stack with a **zero-error, zero-log, exit-code-0** signature. The regression is discovered by a user, in production, usually during an incident.

### 1.2 Why this belongs in an SRE curriculum

* **Regulatory**: EN 301 549 (mandatory for EU public-sector procurement), Section 508 (US federal), and WCAG 2.2 as the referenced normative baseline. A non-conforming golden image is a procurement blocker, not a ticket.
* **Reliability**: define the *accessible boot path* as a tested, versioned property of the image, the same way you test that `sshd` comes up. If your DR runbook assumes a sighted operator at a physical console, your DR plan has an untested dependency.
* **Blast radius**: a11y configuration is delivered by the same mechanisms as everything else (dconf system databases, systemd units, udev, kernel cmdline). Getting it wrong — for example, locking a dconf key that a user must be able to toggle — is a *fleet-wide* denial of access to the machine for the affected users.

### 1.3 Servers have an accessibility surface too

For headless infrastructure the desktop stack is irrelevant; what matters is:

* the **Linux virtual console** (VT) — readable by `speakup`/`fenrir`/`brltty` through `/dev/vcsa*`;
* the **serial console** (`console=ttyS0,115200n8`) and BMC Serial-over-LAN — the only path that survives a dead GPU, and the path a remote braille terminal can consume;
* **ops tooling output** — respect `NO_COLOR`, never encode meaning in colour alone, keep `--json` output available for TUIs and screen readers.

---

## 2. Architecture of the Linux accessibility stack

Two stacks exist. They share almost nothing. Knowing which one you are in determines every debugging step.

```
┌─────────────────────────────── GRAPHICAL STACK ────────────────────────────────┐
│                                                                                │
│  Orca (screen reader, Python)     Magnifier (mutter/KWin)   OSK (shell/wvkbd)  │
│        │              │                      │                     │           │
│        │ AT-SPI2      │ BrlAPI               │ compositor API      │ input     │
│        ▼              ▼                      ▼                     ▼           │
│  ┌───────────────────────────┐   ┌────────┐          ┌────────────────────┐    │
│  │ at-spi2-registryd         │   │ brltty │          │ XTEST (X11) /      │    │
│  │ on the a11y D-Bus         │   │ (a2)   │          │ virtual-keyboard,  │    │
│  │ (org.a11y.Bus)            │   └────────┘          │ libei (Wayland)    │    │
│  └───────────▲───────────────┘                       └────────────────────┘    │
│              │ exposes accessible object tree                                  │
│   ┌──────────┴────────────┬──────────────────┬─────────────────┐               │
│   │ GTK4 (native AT-SPI)  │ GTK3 (atk-bridge)│ Qt5/6 (qspi)    │ Java (atk)    │
│   └───────────────────────┴──────────────────┴─────────────────┘               │
│              │ speech                                                          │
│              ▼                                                                 │
│   speech-dispatcher ──► sd_espeak-ng / sd_festival / sd_pico / RHVoice          │
│                    └──► PipeWire / PulseAudio / ALSA                            │
│                                                                                │
│  Keyboard/pointer filtering: XKB AccessX controls (X11) │ compositor (Wayland)  │
└────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────── CONSOLE STACK ─────────────────────────────────┐
│  speakup (kernel, drivers/accessibility/speakup since Linux 5.10)               │
│      ├── speakup_soft ──► /dev/softsynth ──► espeakup ──► espeak-ng ──► ALSA    │
│      └── speakup_<hw>  ──► hardware synth on a serial port                      │
│  fenrir / yasr (userspace)  ──► reads /dev/vcsa*  ──► speech-dispatcher         │
│  brltty (screen driver "lx") ──► /dev/vcsa*  ──► braille display over USB/BT    │
│  Rendering: setfont / vconsole.conf / fbcon=font:TER16x32                       │
└────────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 AT-SPI2 — the bus that everything graphical depends on

AT-SPI2 is a **D-Bus** protocol (the CORBA-based AT-SPI1 is long dead). Its address is published on a dedicated bus, discoverable in two ways:

* `org.a11y.Bus.GetAddress` on the session bus (canonical), and
* the `AT_SPI_BUS` property on the X11 root window (legacy, X11 only).

Toolkits register their widget trees on that bus. The registry daemon (`at-spi2-registryd`) brokers; Orca is just a client. Consequences that matter operationally:

* **It is session-scoped.** `ssh -X` forwards *rendering*, not the a11y bus. A remotely forwarded application is invisible to the local screen reader. Remote accessible desktops must run the whole stack server-side (VNC/RDP/xrdp) and stream audio back.
* **Sandboxes break it.** Flatpak needs `--socket=accessibility`; containers need the session bus socket bind-mounted and `NO_AT_BRIDGE` unset.
* **GTK3 is gated by a setting**, GTK4 is not:

| Toolkit | Bridge | Enable condition |
|---|---|---|
| GTK 2 | `gail` + `atk-bridge` module | `GTK_MODULES=gail:atk-bridge` |
| GTK 3 | `atk-bridge` | `org.gnome.desktop.interface toolkit-accessibility=true` (X11); disabled by `NO_AT_BRIDGE=1` |
| GTK 4 | native AT-SPI implementation | always on, no toggle |
| Qt 5 / Qt 6 | `libqspiaccessiblebridge` plugin | `QT_ACCESSIBILITY=1` (or `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`) |
| Java (Swing) | Java ATK Wrapper | `assistive_technologies=org.GNOME.Accessibility.AtkWrapper` in `accessibility.properties` |
| Electron/Chromium | auto-detects AT-SPI | `--force-renderer-accessibility` to force |

---

## 3. Technical comparatives and trade-offs

### 3.1 Screen readers

| Reader | Layer | Reads | Works pre-X? | Braille | Maintained | Production role |
|---|---|---|---|---|---|---|
| **Orca** | GUI, AT-SPI2 client | accessible object tree | no | via BrlAPI + liblouis | yes (GNOME) | the only complete GUI reader |
| **speakup + espeakup** | kernel + daemon | VT text buffer | **yes** (early, if built-in) | no | yes (mainline) | console/rescue; per-VT review |
| **fenrir** | userspace, `/dev/vcsa` | VT text buffer | after `local-fs` | yes (BrlAPI) | yes | modern console reader, scriptable |
| **yasr** | pty wrapper | one program's pty | yes | no | effectively dead | legacy/last resort |
| **BRLTTY** | daemon | VT (`lx`) or AT-SPI (`a2`) | yes | **primary purpose** | yes | braille everywhere + optional speech |
| **emacspeak** | application | Emacs buffers only | yes (in Emacs) | via BRLTTY | yes | "audio desktop" for Emacs-centric users |

**Trade-off that decides the design:** `speakup` reads the *text buffer*, so it works on a broken system, in single-user mode, and during a `fsck` — but it cannot describe a widget, a role, or a focus change. Orca understands semantics but requires a full session. A compliant workstation image needs **both**; neither substitutes for the other.

### 3.2 Speech synthesis back-ends

| Synth | speech-dispatcher module | Latency | Quality | Footprint | Offline | Notes |
|---|---|---|---|---|---|---|
| **espeak-ng** | `sd_espeak-ng` | lowest (formant) | robotic | ~5 MB | yes | default; the only one fast enough for rapid navigation |
| **Festival** | `sd_festival` | medium | better prosody | ~100 MB+ | yes | diphone/unit-selection voices |
| **Pico (SVOX)** | `sd_pico` | low | good, few languages | ~10 MB | yes | limited language set |
| **RHVoice** | `sd_rhvoice` | medium | very good | ~100 MB/voice | yes | strong ru/uk/other coverage |
| **Cloud TTS** | custom module | network RTT | best | n/a | **no** | disqualified: network dependency on the recovery path |

Experienced screen-reader users routinely run espeak-ng at 400–600 words/min; "better sounding" engines that add 200 ms of latency per utterance are actively worse for them. **Do not "upgrade" a user's synth without asking.**

### 3.3 X11 vs Wayland — capability matrix

| Capability | X11 | Wayland (GNOME/mutter) | Wayland (wlroots, e.g. sway) |
|---|---|---|---|
| AT-SPI2 object tree | yes | yes (D-Bus, compositor-independent) | yes, but few clients drive it |
| Screen reader key grabs | XGrabKey | mutter-provided | **no standard mechanism** |
| Synthetic input (OSK, mouse emulation) | XTEST | `virtual-keyboard-v1`, portals, **libei** | `virtual-keyboard-v1`/`wtype` |
| Screen magnification | external (`xzoom`, compositor) | compositor built-in | compositor-specific / absent |
| Screen capture for OCR-style tools | XGetImage (any client) | portal-mediated only | portal-mediated only |
| Sticky/Slow/Bounce/Mouse Keys | **XKB AccessX in the X server** | implemented by the compositor (same gsettings keys) | mostly absent |
| `xkbset`, `xdotool`, `xev` | work | **only for XWayland clients** | do not work |

**Architectural consequence:** X11 gave every client omnipotence, which is a security disaster and an accessibility convenience. Wayland closed the hole, and assistive tech had to be re-implemented *inside* compositors. Today GNOME on Wayland is a complete a11y platform; minimal wlroots compositors are not. `libei`/`xdg-desktop-portal` is the standard converging path for input emulation, but **if a user depends on a screen reader, GNOME (Wayland or X11) or Plasma is the supported choice — not a tiling wlroots compositor.**

### 3.4 On-screen keyboards

| OSK | Display server | Input method | Status | Use case |
|---|---|---|---|---|
| **GNOME Shell OSK** | X11 + Wayland | compositor-internal | maintained | default; touch and pointer-only users |
| **GOK** (GNOME On-screen Keyboard) | X11 | XTEST + AT-SPI scanning | **dead** (~2012), removed from distros | **exam term only** — knows switch-access scanning |
| **Caribou** | X11 + Wayland | XTEST/IM | deprecated, absorbed into Shell | legacy GNOME |
| **Onboard** | X11 | XTEST | unmaintained, dropped from recent Ubuntu | legacy Ubuntu images |
| **Florence** | X11 | XTEST | unmaintained | legacy |
| **xvkbd** | X11 | XTEST | maintained-ish | scripted key injection, kiosks |
| **Squeekboard** | Wayland | `zwp_input_method_v2` | maintained | Phosh / mobile |
| **wvkbd** | Wayland | `virtual-keyboard-v1` | maintained | wlroots kiosks |

> **Exam note:** GOK is in the v5.0 objectives and is not installable on any current distribution. Know what it *was*: an on-screen keyboard supporting **scanning** input (a single switch cycles through key groups) driven through AT-SPI.

### 3.5 Screen magnifiers

| Tool | Server | Modes | Colour effects | Notes |
|---|---|---|---|---|
| **GNOME magnifier** (mutter) | X11 + Wayland | full/half-screen, lens | invert, brightness, contrast, saturation, crosshairs | `org.gnome.desktop.a11y.magnifier` |
| **KWin zoom effect** | X11 + Wayland | full-screen, follows focus/pointer | invert via separate effect | `kwinrc [Plugins] zoomEnabled=true`, `Meta`+`+` |
| **KMagnifier (kmag)** | X11 (window) | window-based lens | limited | screenshot-style, not a live overlay under Wayland |
| **xzoom / xmag** | X11 only | window-based | xzoom: mirror/rotate | tiny, scriptable, no compositor needed |

### 3.6 Configuration delivery mechanisms — pick per key

| Mechanism | Applies to | Persistent | Enforceable | Right for |
|---|---|---|---|---|
| `gsettings`/`dconf` (user) | GNOME session | yes | no | user's own choice |
| `dconf` **system-db** + `dconf update` | all users, defaults | yes | optional (locks) | **fleet defaults** |
| `dconf` **locks** | all users | yes | **hard** | only true mandates |
| `xkbset` / `setxkbmap -option` | current X server | **no** | no | scripts, per-session hooks |
| `/etc/X11/xorg.conf.d/*.conf` | X server startup | yes | yes | XKB defaults, `XkbOptions` |
| `/etc/vconsole.conf`, `setfont` | VT rendering | yes | yes | large console fonts |
| kernel cmdline / `modprobe.d` | boot | yes | yes | `speakup`, `fbcon` font |
| systemd unit / udev | daemons, devices | yes | yes | `brltty`, `espeakup` |

---

## 4. Infrastructure: complete, unabridged manifests

### 4.1 dconf system database — fleet defaults

`/etc/dconf/profile/user`

```
user-db:user
system-db:local
```

`/etc/dconf/db/local.d/10-a11y-baseline`

```ini
# Fleet accessibility baseline.
# Managed by Ansible role `a11y_baseline` — edit the role, not this file.
# Rebuild after any change:  dconf update

[org/gnome/desktop/a11y]
# Always keep the Universal Access indicator visible in the top bar, even when
# no feature is active. Users cannot find what is not discoverable.
always-show-universal-access-status=true

[org/gnome/desktop/a11y/applications]
# Defaults only. Users MUST be able to change these; do not lock them.
screen-reader-enabled=false
screen-magnifier-enabled=false
screen-keyboard-enabled=false

[org/gnome/desktop/a11y/interface]
high-contrast=false
show-status-shapes=true

[org/gnome/desktop/a11y/keyboard]
# Master gate for the AccessX keyboard gestures (5x Shift -> Sticky Keys,
# hold Shift 8s -> Slow Keys). Locked ON below: a user who needs Sticky Keys
# may be unable to press the key combination that would enable it.
enable=true
# Do NOT auto-disable accessibility features after idle time.
timeout-enable=false
disable-timeout=120
feature-state-change-beep=true
stickykeys-enable=false
stickykeys-two-key-off=true
stickykeys-modifier-beep=true
slowkeys-enable=false
slowkeys-delay=300
slowkeys-beep-press=false
slowkeys-beep-accept=true
slowkeys-beep-reject=false
bouncekeys-enable=false
bouncekeys-delay=300
bouncekeys-beep-reject=true
mousekeys-enable=false
mousekeys-init-delay=160
mousekeys-max-speed=750
mousekeys-accel-time=1200
togglekeys-enable=false

[org/gnome/desktop/a11y/mouse]
dwell-click-enabled=false
dwell-mode='window'
dwell-threshold=10
dwell-time=1.2
secondary-click-enabled=false
secondary-click-time=1.2

[org/gnome/desktop/a11y/magnifier]
mag-factor=2.0
screen-position='full-screen'
lens-mode=false
scroll-at-edges=true
mouse-tracking='proportional'
focus-tracking='proportional'
caret-tracking='proportional'
invert-lightness=false
show-cross-hairs=true
cross-hairs-thickness=8
cross-hairs-length=4096
cross-hairs-opacity=0.5
cross-hairs-clip=false

[org/gnome/desktop/interface]
cursor-size=32
text-scaling-factor=1.0
cursor-blink=true
cursor-blink-time=1200
# Required for GTK3 applications to publish their object tree on AT-SPI.
toolkit-accessibility=true

[org/gnome/desktop/wm/preferences]
# Visual bell for users who cannot hear the audible one.
audible-bell=false
visual-bell=true
visual-bell-type='frame-flash'

[org/gnome/settings-daemon/plugins/media-keys]
screenreader=['<Alt><Super>s']
magnifier=['<Alt><Super>8']
magnifier-zoom-in=['<Alt><Super>equal']
magnifier-zoom-out=['<Alt><Super>minus']
on-screen-keyboard=['<Alt><Super>k']
```

`/etc/dconf/db/local.d/locks/10-a11y-locks`

```
# Lock ONLY the gates that must never be closed by accident or by a
# misapplied "hardening" profile. Every key that expresses a user's own
# need (screen reader on/off, magnification factor, sticky keys) stays
# writable. Locking those is a fleet-wide accessibility outage.
/org/gnome/desktop/a11y/keyboard/enable
/org/gnome/desktop/a11y/keyboard/timeout-enable
/org/gnome/desktop/a11y/always-show-universal-access-status
/org/gnome/desktop/interface/toolkit-accessibility
```

### 4.2 GDM greeter — accessibility before login

`/etc/dconf/profile/gdm`

```
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
```

`/etc/dconf/db/gdm.d/10-a11y-greeter`

```ini
# The login screen is a separate dconf database with its own profile.
# A user who cannot read the greeter never reaches their own settings.

[org/gnome/desktop/a11y]
always-show-universal-access-status=true

[org/gnome/desktop/a11y/applications]
screen-reader-enabled=false
screen-keyboard-enabled=true
screen-magnifier-enabled=false

[org/gnome/desktop/a11y/keyboard]
enable=true
timeout-enable=false

[org/gnome/desktop/a11y/interface]
high-contrast=true

[org/gnome/desktop/interface]
cursor-size=48
text-scaling-factor=1.25

[org/gnome/login-screen]
banner-message-enable=true
banner-message-text='Accessibility: Alt+Super+S screen reader · Alt+Super+8 magnifier'
```

### 4.3 Environment: toolkit bridges for every application family

`/etc/environment.d/90-accessibility.conf`

```ini
# Applied by systemd's user environment generator to every user session.
# GTK2 legacy applications:
GTK_MODULES=gail:atk-bridge
# Qt5/Qt6 accessibility bridge (qspiaccessiblebridge plugin):
QT_ACCESSIBILITY=1
QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
# Never set NO_AT_BRIDGE here. If a container base image sets it, unset it
# explicitly in the container entrypoint — it silently mutes the entire
# GTK accessible tree with no log line.
```

`/etc/java/accessibility.properties` (path is distro/JDK dependent, e.g. `$JAVA_HOME/conf/accessibility.properties`)

```properties
assistive_technologies=org.GNOME.Accessibility.AtkWrapper
screen_magnifier_present=true
```

### 4.4 Braille display: udev + systemd

`/etc/udev/rules.d/70-braille-display.rules`

```
# Start BRLTTY when the fleet-standard braille display is attached.
# The shipped brltty package also installs autodetection rules under
# /usr/lib/udev/rules.d/ ; this file is the explicit, auditable override.
#
# Discover the IDs first:  udevadm info -a -n /dev/bus/usb/001/00X | head -40
#
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
  ATTR{idVendor}=="0921", ATTR{idProduct}=="1200", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="brltty-console.service", \
  ENV{BRLTTY_BRAILLE_DRIVER}="ht"

ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
  ATTR{idVendor}=="0921", ATTR{idProduct}=="1200", \
  RUN+="/usr/bin/systemctl --no-block stop brltty-console.service"
```

`/etc/systemd/system/brltty-console.service`

```ini
[Unit]
Description=BRLTTY braille daemon (Linux console screen driver)
Documentation=https://brltty.app/doc/Manual-BRLTTY/English/BRLTTY.html
After=local-fs.target systemd-udevd.service
BindsTo=dev-bus-usb.device
StopWhenUnneeded=no

[Service]
Type=simple
# -n  do not fork (systemd owns the lifecycle)
# -e  log to stderr so journald captures everything
# -b  braille driver ("auto" autodetects; explicit is faster and deterministic)
# -d  device specifier: usb: | serial:/dev/ttyS0 | bluetooth:XX:XX:XX:XX:XX:XX
# -x  screen driver: lx = Linux VT via /dev/vcsa* ; a2 = AT-SPI2 (desktop)
# -t  text table   -c  contraction table (grade 2)
ExecStart=/usr/bin/brltty \
  --no-daemon \
  --standard-error \
  --log-level=notice \
  --braille-driver=ht \
  --braille-device=usb: \
  --screen-driver=lx \
  --text-table=en_US \
  --contraction-table=en-ueb-g2 \
  --api-parameters=Auth=/etc/brlapi.key
Restart=on-failure
RestartSec=3
# brltty needs /dev/vcsa* (console text buffer) and raw USB access.
DeviceAllow=char-vcs rw
DeviceAllow=char-usb_device rw
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/run /var/lib/brltty
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/espeakup.service.d/override.conf`

```ini
[Unit]
# espeakup bridges the kernel's /dev/softsynth (speakup_soft) to espeak-ng.
# Without speakup_soft loaded there is nothing to bridge.
After=systemd-modules-load.service
ConditionPathExists=/dev/softsynth

[Service]
ExecStart=
ExecStart=/usr/bin/espeakup --default-voice=en-us
Restart=on-failure
RestartSec=2
```

`/etc/modules-load.d/speakup.conf`

```
# Kernel console screen reader. In mainline since 5.10 (drivers/accessibility).
speakup
speakup_soft
```

`/etc/modprobe.d/speakup.conf`

```
# start=1 makes speakup begin reading immediately when the module loads.
options speakup_soft start=1
```

`/etc/sysctl.d/` is not the right place for speakup tuning — use a `tmpfiles` rule so the sysfs knobs are applied every boot:

`/etc/tmpfiles.d/speakup.conf`

```
#Type Path                                    Mode User Group Age Argument
w     /sys/accessibility/speakup/rate         -    -    -     -   6
w     /sys/accessibility/speakup/punc_level   -    -    -     -   2
w     /sys/accessibility/speakup/key_echo     -    -    -     -   1
```

### 4.5 Console rendering and boot-time cues

`/etc/vconsole.conf`

```
KEYMAP=us
FONT=ter-132n
FONT_MAP=8859-1
```

`/etc/default/grub` (relevant fragment)

```bash
# Audible cue that GRUB has started — for users who cannot see the menu.
GRUB_INIT_TUNE="480 440 1"
# Keep the menu visible long enough to be navigated with assistive tech.
GRUB_TIMEOUT=10
GRUB_TIMEOUT_STYLE=menu
# Large console font from the very first kernel message.
GRUB_CMDLINE_LINUX_DEFAULT="fbcon=font:TER16x32"
# Serial console in parallel: the only path a remote braille terminal can read.
GRUB_TERMINAL_INPUT="console serial"
GRUB_TERMINAL_OUTPUT="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
```

### 4.6 Ansible role — the whole thing

`roles/a11y_baseline/tasks/main.yml`

```yaml
---
- name: Fail early on unsupported OS families
  ansible.builtin.assert:
    that: ansible_os_family in ['RedHat', 'Debian']
    fail_msg: "a11y_baseline supports RedHat and Debian families only"

- name: Install console accessibility stack
  ansible.builtin.package:
    name: "{{ a11y_console_packages[ansible_os_family] }}"
    state: present
  vars:
    a11y_console_packages:
      RedHat: [brltty, espeakup, espeak-ng, kbd, terminus-fonts-console]
      Debian: [brltty, espeakup, espeak-ng, kbd, console-setup, fonts-terminus-otb]

- name: Install graphical accessibility stack
  ansible.builtin.package:
    name: "{{ a11y_gui_packages[ansible_os_family] }}"
    state: present
  when: a11y_graphical | bool
  vars:
    a11y_gui_packages:
      RedHat:
        - orca
        - speech-dispatcher
        - speech-dispatcher-espeak-ng
        - at-spi2-core
        - at-spi2-atk
        - gnome-themes-extra
        - liblouis
      Debian:
        - orca
        - speech-dispatcher
        - speech-dispatcher-espeak-ng
        - at-spi2-core
        - libatk-adaptor
        - gnome-themes-extra
        - liblouis-data

- name: Deploy dconf profiles
  ansible.builtin.copy:
    src: "profiles/{{ item }}"
    dest: "/etc/dconf/profile/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - user
    - gdm
  notify: dconf update

- name: Ensure dconf database directories exist
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop:
    - /etc/dconf/db/local.d
    - /etc/dconf/db/local.d/locks
    - /etc/dconf/db/gdm.d

- name: Deploy dconf keyfiles and locks
  ansible.builtin.copy:
    src: "db/{{ item }}"
    dest: "/etc/dconf/db/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - local.d/10-a11y-baseline
    - local.d/locks/10-a11y-locks
    - gdm.d/10-a11y-greeter
  notify: dconf update

- name: Deploy session environment for toolkit bridges
  ansible.builtin.copy:
    src: environment.d/90-accessibility.conf
    dest: /etc/environment.d/90-accessibility.conf
    owner: root
    group: root
    mode: "0644"

- name: Assert NO_AT_BRIDGE is not exported anywhere in /etc
  ansible.builtin.command:
    argv: [grep, -RIl, --exclude-dir=dconf, NO_AT_BRIDGE, /etc]
  register: no_at_bridge
  changed_when: false
  failed_when: false

- name: Fail if NO_AT_BRIDGE poisons the environment
  ansible.builtin.fail:
    msg: "NO_AT_BRIDGE found in: {{ no_at_bridge.stdout_lines | join(', ') }}"
  when: no_at_bridge.stdout | length > 0

- name: Configure kernel console screen reader
  ansible.builtin.copy:
    content: "{{ item.content }}"
    dest: "{{ item.dest }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - dest: /etc/modules-load.d/speakup.conf
      content: "speakup\nspeakup_soft\n"
    - dest: /etc/modprobe.d/speakup.conf
      content: "options speakup_soft start=1\n"
  notify: reload speakup

- name: Configure large console font
  ansible.builtin.copy:
    content: |
      KEYMAP={{ a11y_console_keymap }}
      FONT={{ a11y_console_font }}
      FONT_MAP=8859-1
    dest: /etc/vconsole.conf
    owner: root
    group: root
    mode: "0644"
  notify: apply vconsole

- name: Deploy braille udev rule
  ansible.builtin.template:
    src: 70-braille-display.rules.j2
    dest: /etc/udev/rules.d/70-braille-display.rules
    owner: root
    group: root
    mode: "0644"
  when: a11y_braille_enabled | bool
  notify: reload udev

- name: Deploy brltty console unit
  ansible.builtin.template:
    src: brltty-console.service.j2
    dest: /etc/systemd/system/brltty-console.service
    owner: root
    group: root
    mode: "0644"
  when: a11y_braille_enabled | bool
  notify: daemon reload

- name: Generate a BrlAPI authorisation key if absent
  ansible.builtin.shell:
    cmd: "set -o pipefail && head -c 32 /dev/urandom > /etc/brlapi.key"
    creates: /etc/brlapi.key
  when: a11y_braille_enabled | bool

- name: Restrict the BrlAPI key
  ansible.builtin.file:
    path: /etc/brlapi.key
    owner: root
    group: brlapi
    mode: "0640"
  when: a11y_braille_enabled | bool

- name: Enable espeakup where speech is required
  ansible.builtin.systemd_service:
    name: espeakup.service
    enabled: true
    state: started
  when: a11y_console_speech | bool

- name: Deploy the verification script
  ansible.builtin.copy:
    src: bin/a11y-verify.sh
    dest: /usr/local/bin/a11y-verify
    owner: root
    group: root
    mode: "0755"

- name: Run the verification script (fails the play on drift)
  ansible.builtin.command: /usr/local/bin/a11y-verify --strict
  register: a11y_verify
  changed_when: false
```

`roles/a11y_baseline/defaults/main.yml`

```yaml
---
a11y_graphical: true
a11y_braille_enabled: false
a11y_console_speech: false
a11y_console_font: ter-132n
a11y_console_keymap: us
a11y_braille_driver: ht
a11y_braille_vendor_id: "0921"
a11y_braille_product_id: "1200"
a11y_text_table: en_US
a11y_contraction_table: en-ueb-g2
```

`roles/a11y_baseline/handlers/main.yml`

```yaml
---
- name: dconf update
  ansible.builtin.command: /usr/bin/dconf update

- name: daemon reload
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: reload udev
  ansible.builtin.command: /usr/bin/udevadm control --reload-rules

- name: reload speakup
  ansible.builtin.command: /usr/sbin/modprobe -r speakup_soft speakup
  failed_when: false
  notify: load speakup

- name: load speakup
  ansible.builtin.command: /usr/sbin/modprobe speakup_soft

- name: apply vconsole
  ansible.builtin.systemd_service:
    name: systemd-vconsole-setup.service
    state: restarted
```

### 4.7 Fleet drift audit as a Kubernetes CronJob

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: a11y-audit-script
  namespace: platform-compliance
data:
  audit.sh: |
    #!/usr/bin/env bash
    # Fleet accessibility drift audit.
    # Exit 0 = compliant, 1 = drift, 2 = unreachable.
    set -euo pipefail
    HOST="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "audit@${HOST}" 'bash -s' <<'REMOTE' || exit 2
    set -uo pipefail
    rc=0
    emit() { printf '%-38s %s\n' "$1" "$2"; }

    # 1. dconf system database is compiled and newer than its sources.
    if [ ! -f /etc/dconf/db/local ]; then
      emit "dconf.local.compiled" "FAIL(missing)"; rc=1
    elif [ -n "$(find /etc/dconf/db/local.d -newer /etc/dconf/db/local 2>/dev/null)" ]; then
      emit "dconf.local.compiled" "FAIL(stale: run dconf update)"; rc=1
    else
      emit "dconf.local.compiled" "OK"
    fi

    # 2. The AccessX gate must be on and locked.
    gate=$(dconf read -d /org/gnome/desktop/a11y/keyboard/enable 2>/dev/null || echo unset)
    [ "$gate" = "true" ] && emit "a11y.keyboard.enable" "OK" \
      || { emit "a11y.keyboard.enable" "FAIL($gate)"; rc=1; }

    # 3. Idle auto-disable of a11y features must be off.
    to=$(dconf read -d /org/gnome/desktop/a11y/keyboard/timeout-enable 2>/dev/null || echo unset)
    [ "$to" = "false" ] && emit "a11y.keyboard.timeout-enable" "OK" \
      || { emit "a11y.keyboard.timeout-enable" "FAIL($to)"; rc=1; }

    # 4. No NO_AT_BRIDGE anywhere in the system environment.
    if grep -RIqs NO_AT_BRIDGE /etc/environment /etc/environment.d /etc/profile.d 2>/dev/null; then
      emit "env.NO_AT_BRIDGE" "FAIL(present)"; rc=1
    else
      emit "env.NO_AT_BRIDGE" "OK"
    fi

    # 5. Console screen-reader path present.
    if [ -c /dev/softsynth ]; then emit "speakup.softsynth" "OK"
    else emit "speakup.softsynth" "WARN(absent)"; fi

    # 6. Large console font actually applied.
    font=$(grep -E '^FONT=' /etc/vconsole.conf 2>/dev/null | cut -d= -f2)
    [ -n "${font:-}" ] && emit "vconsole.font" "OK($font)" \
      || { emit "vconsole.font" "FAIL(unset)"; rc=1; }

    exit "$rc"
    REMOTE
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: a11y-drift-audit
  namespace: platform-compliance
  labels:
    app.kubernetes.io/name: a11y-drift-audit
    app.kubernetes.io/component: compliance
spec:
  schedule: "17 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 7
  startingDeadlineSeconds: 600
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: audit
              image: registry.internal/platform/ssh-auditor:1.7.2
              imagePullPolicy: IfNotPresent
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -uo pipefail
                  fail=0
                  while read -r host; do
                    echo "=== ${host} ==="
                    if /scripts/audit.sh "${host}"; then
                      echo "result=compliant host=${host}"
                    else
                      echo "result=drift host=${host} rc=$?"
                      fail=1
                    fi
                  done < /inventory/workstations.txt
                  exit "${fail}"
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  cpu: 500m
                  memory: 256Mi
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: inventory
                  mountPath: /inventory
                  readOnly: true
                - name: ssh-key
                  mountPath: /home/audit/.ssh
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: scripts
              configMap:
                name: a11y-audit-script
                defaultMode: 0555
            - name: inventory
              configMap:
                name: fleet-inventory
            - name: ssh-key
              secret:
                secretName: a11y-audit-ssh-key
                defaultMode: 0400
            - name: tmp
              emptyDir:
                sizeLimit: 16Mi
```

---

## 5. CLI: real commands and expected output

### 5.1 Keyboard accessibility on X11 — XKB AccessX controls

```
$ xkbset q
Bell:                    on
Sticky Keys:             off
        Two Keys:        off
        Latch Lock:      off
Mouse Keys:              off
        Delay:           160
        Interval:        40
        Time to Max:     30
        Max Speed:       30
        Curve:           0
Access X Keys:           on
Access X Timeout:        0
        Timeout Mask:    -none-
        Timeout Values:  -none-
        Options Mask:    -none-
        Options Values:  -none-
Access X Feedback:       off
        Feedback Mask:   -none-
Slow Keys:               off
        Delay:           300
Bounce Keys:             off
        Delay:           300
Repeat Keys:             on
        Delay:           660
        Rate:            25
```

Enable Sticky Keys (modifiers latch instead of requiring simultaneous presses), disabling the "two keys pressed together turns it off" escape hatch:

```
$ xkbset sticky -twokey -latchlock
$ xkbset q | head -4
Bell:                    on
Sticky Keys:             on
        Two Keys:        off
        Latch Lock:      on
```

**The trap that costs an hour:** AccessX features expire on the AccessX timeout. If they turn themselves off after a couple of minutes, tell the X server not to expire them:

```
$ xkbset m            # Mouse Keys on
$ xkbset exp =m       # ...and do not let it expire
$ xkbset exp "=sticky" "=twokey" "=latchlock" "=bell"
```

Mouse Keys — move the pointer with the numeric keypad:

```
$ xkbset m 160 40 30 30 0
#          │   │  │  │  └─ curve (0 = linear acceleration)
#          │   │  │  └──── max speed (px per interval)
#          │   │  └─────── time to reach max speed (intervals)
#          │   └────────── interval between pointer moves (ms)
#          └────────────── initial delay before repeating (ms)
```

Slow Keys (ignore keys held for less than N ms — filters tremor-induced brushes) and Bounce Keys (ignore a repeat of the same key within N ms):

```
$ xkbset sl 400        # Slow Keys, 400 ms acceptance delay
$ xkbset bo 500        # Bounce Keys, 500 ms debounce
$ xkbset q | grep -A1 -E 'Slow|Bounce'
Slow Keys:               on
        Delay:           400
Bounce Keys:             on
        Delay:           500
```

Repeat Keys via the classic `xset` (delay before repeat, repeats per second):

```
$ xset r rate 660 25
$ xset q | grep -A2 'auto repeat delay'
  auto repeat delay:  660    repeat rate:  25
  auto repeating keys:  00feffffdffffbbf
                        fadfffefffedffff
```

Persist XKB options declaratively instead of scripting `xkbset` at login:

`/etc/X11/xorg.conf.d/50-accessx.conf`

```
Section "InputClass"
    Identifier   "AccessX keyboard defaults"
    MatchIsKeyboard "on"
    Option       "XkbLayout"  "us"
    Option       "XkbOptions" "grp:alt_shift_toggle,terminate:ctrl_alt_bksp"
EndSection
```

> **Critical:** any `setxkbmap` or `xkbcomp` reload **replaces the whole keymap and resets AccessX state**. A desktop applet, a hotplug event, or an input-method switch can therefore silently undo `xkbset`. This is the single most common "Sticky Keys turned itself off" root cause — and the architectural reason to configure via `org.gnome.desktop.a11y.keyboard` (re-applied by gnome-settings-daemon after every keymap change) rather than `xkbset` on a GNOME system.

### 5.2 The GNOME/GSettings surface

```
$ gsettings list-recursively org.gnome.desktop.a11y.keyboard
org.gnome.desktop.a11y.keyboard bouncekeys-beep-reject true
org.gnome.desktop.a11y.keyboard bouncekeys-delay 300
org.gnome.desktop.a11y.keyboard bouncekeys-enable false
org.gnome.desktop.a11y.keyboard disable-timeout 120
org.gnome.desktop.a11y.keyboard enable true
org.gnome.desktop.a11y.keyboard feature-state-change-beep true
org.gnome.desktop.a11y.keyboard mousekeys-accel-time 1200
org.gnome.desktop.a11y.keyboard mousekeys-enable false
org.gnome.desktop.a11y.keyboard mousekeys-init-delay 160
org.gnome.desktop.a11y.keyboard mousekeys-max-speed 750
org.gnome.desktop.a11y.keyboard slowkeys-beep-accept true
org.gnome.desktop.a11y.keyboard slowkeys-beep-press false
org.gnome.desktop.a11y.keyboard slowkeys-beep-reject false
org.gnome.desktop.a11y.keyboard slowkeys-delay 300
org.gnome.desktop.a11y.keyboard slowkeys-enable false
org.gnome.desktop.a11y.keyboard stickykeys-enable false
org.gnome.desktop.a11y.keyboard stickykeys-modifier-beep true
org.gnome.desktop.a11y.keyboard stickykeys-two-key-off true
org.gnome.desktop.a11y.keyboard timeout-enable false
org.gnome.desktop.a11y.keyboard togglekeys-enable false
```

Toggle the three "applications" features — these are what the Universal Access panel drives:

```
$ gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
$ gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled true
$ gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
$ gsettings get org.gnome.desktop.a11y.applications screen-reader-enabled
true
```

High contrast and large print — the "themes" half of the objective:

```
$ gsettings set org.gnome.desktop.a11y.interface high-contrast true
$ gsettings set org.gnome.desktop.interface text-scaling-factor 1.5
$ gsettings set org.gnome.desktop.interface cursor-size 48
$ gsettings get org.gnome.desktop.interface text-scaling-factor
1.5
```

On pre-42 GNOME the same effect was a GTK theme swap; know both forms:

```
$ gsettings set org.gnome.desktop.interface gtk-theme 'HighContrast'
$ gsettings set org.gnome.desktop.interface icon-theme 'HighContrast'
```

Magnifier:

```
$ gsettings set org.gnome.desktop.a11y.magnifier mag-factor 3.0
$ gsettings set org.gnome.desktop.a11y.magnifier lens-mode true
$ gsettings set org.gnome.desktop.a11y.magnifier mouse-tracking 'proportional'
$ gsettings set org.gnome.desktop.a11y.magnifier invert-lightness true
$ gsettings set org.gnome.desktop.a11y.magnifier show-cross-hairs true
```

Dwell click (click without pressing a button — for users who can move a pointer but not click):

```
$ gsettings set org.gnome.desktop.a11y.mouse dwell-click-enabled true
$ gsettings set org.gnome.desktop.a11y.mouse dwell-time 1.2
$ gsettings set org.gnome.desktop.a11y.mouse dwell-threshold 10
$ gsettings set org.gnome.desktop.a11y.mouse secondary-click-enabled true
```

Verify that a system-db lock is actually in force:

```
$ dconf update
$ gsettings writable org.gnome.desktop.a11y.keyboard enable
false
$ gsettings set org.gnome.desktop.a11y.keyboard enable false
(process:48211): dconf-WARNING **: 11:04:22.517: failed to commit changes to dconf: 
The operation is not permitted because the key is locked
```

### 5.3 AT-SPI2 bus — is the accessibility plumbing alive?

```
$ busctl --user list | grep -i a11y
org.a11y.Bus                       4821 at-spi-bus-laun dalmine :1.34  ...
org.a11y.atspi.Registry            4839 at-spi2-registr dalmine :1.41  ...

$ dbus-send --session --print-reply --dest=org.a11y.Bus \
    /org/a11y/bus org.a11y.Bus.GetAddress
method return time=1787050122.884413 sender=:1.34 -> destination=:1.212 serial=9 reply_serial=2
   string "unix:path=/run/user/1000/at-spi/bus_0,guid=6f0c9b2a1d4e7f8a3b5c6d70"

$ gsettings get org.gnome.desktop.interface toolkit-accessibility
true

$ ps -ef | grep -E 'at-spi|orca' | grep -v grep
dalmine    4821  4712  0 10:58 ?  00:00:00 /usr/libexec/at-spi-bus-launcher --launch-immediately
dalmine    4839  4821  0 10:58 ?  00:00:01 /usr/libexec/at-spi2-registryd --use-gnome-session
dalmine    5104  4712  1 11:01 ?  00:00:07 /usr/bin/python3 /usr/bin/orca
```

Confirm an individual application publishes an object tree (Accerciser is the GUI; `xdotool`-free, scriptable check via `python3-pyatspi`):

```
$ python3 -c 'import pyatspi; print([a.name for a in pyatspi.Registry.getDesktop(0)])'
['gnome-shell', 'gnome-terminal-server', 'firefox', 'nautilus']
```

An application missing from that list is invisible to every screen reader on the machine — that is the real definition of "not accessible".

### 5.4 Orca

```
$ orca --version
Orca 45.2

$ orca --replace &
[1] 5104

$ orca --help
Usage: orca [OPTION...]

  -h, --help                       Show this help message and exit
  -v, --version                    Version of Orca
  -s, --setup                      Set up user preferences (GUI version)
  -u, --user-prefs=DIRNAME         Use alternate directory for user preferences
  -e, --enable=SPEECH|BRAILLE|BRAILLE-MONITOR
  -d, --disable=SPEECH|BRAILLE|BRAILLE-MONITOR
  -p, --profile=NAME               Load profile
  -r, --replace                    Replace a currently running instance
  --debug                          Send debug output to debug-YYYY-MM-DD-HH:MM:SS.out
  --debug-file=FILE                Send debug output to the specified file
```

Default key bindings (**desktop layout**; the Orca modifier is `Insert`/`KP_Insert`, or `CapsLock` in the laptop layout):

| Binding | Action |
|---|---|
| `Orca` + `Space` | Preferences dialog |
| `Orca` + `H` | Learn mode (announces every key without acting on it) |
| `Orca` + `S` | Toggle speech |
| `Orca` + `Q` | Quit Orca |
| `KP_Add` | Say all (read from cursor to end) |
| `KP_5` | Flat review: read current line |
| `Alt`+`Super`+`S` | GNOME shortcut to toggle the screen reader on/off |

Capture a debug trace for a bug report — this is what upstream asks for:

```
$ orca --replace --debug-file=/tmp/orca-$(date +%F).out
$ tail -5 /tmp/orca-2026-08-27.out
DEBUG: script_manager.getScript: Firefox (pid 4977)
DEBUG: focus changed to: [document frame | LPI Objectives]
DEBUG: speech.speak: 'LPI Objectives, document frame'
DEBUG: braille.displayMessage: 'LPI Objectives doc frm'
```

### 5.5 Speech: speech-dispatcher and espeak-ng

```
$ spd-say -t male1 "Accessibility check on host $(hostname -s)"

$ spd-say -L
NAME                    LANGUAGE  VARIANT
Afrikaans               af        none
English (America)       en-US     none
English (Great Britain) en-GB     none
Spanish                 es        none
Spanish (Latin America) es-419    none
...

$ spd-say -O
OUTPUT MODULE
espeak-ng
festival
pico
dummy

$ spd-say -r 60 -p 20 "faster and higher pitched"

$ espeak-ng --version
eSpeak NG text-to-speech: 1.51  Data at: /usr/share/espeak-ng-data

$ espeak-ng -v en-us -s 300 "direct synthesis, bypassing speech dispatcher"

$ systemctl --user status speech-dispatcherd.service
● speech-dispatcherd.service - Speech-Dispatcher: Common interface to speech synthesis
     Loaded: loaded (/usr/lib/systemd/user/speech-dispatcherd.service; static)
     Active: active (running) since Thu 2026-08-27 11:02:41 -03; 12min ago
   Main PID: 5233 (speech-dispatch)
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/speech-dispatcherd.service
             ├─5233 /usr/bin/speech-dispatcher --spawn --communication-method unix_socket
             └─5241 sd_espeak-ng /etc/speech-dispatcher/modules/espeak-ng.conf
```

Key configuration files:

| Path | Purpose |
|---|---|
| `/etc/speech-dispatcher/speechd.conf` | system defaults: `DefaultModule`, `AudioOutputMethod`, `DefaultRate` |
| `/etc/speech-dispatcher/modules/*.conf` | per-synth module configuration |
| `~/.config/speech-dispatcher/speechd.conf` | per-user override (created by `spd-conf`) |
| `~/.cache/speech-dispatcher/log/speech-dispatcher.log` | the log to read when it goes silent |

### 5.6 Console screen reading: speakup + espeakup

```
$ sudo modprobe speakup_soft
$ lsmod | grep speakup
speakup_soft           16384  0
speakup               159744  1 speakup_soft

$ ls /sys/accessibility/speakup/
attrib_bleep  bleep_time  cursor_time  ex_num     keymap        punc_all
punc_some     say_control  silent      spell_delay  synth_direct
bell_pos      bleeps      delimiters   key_echo   no_interrupt  punc_level
reading_punc  repeats      say_word_ctl  soft      synth        version

$ cat /sys/accessibility/speakup/synth
soft
$ cat /sys/accessibility/speakup/version
Speakup v-3.1.6-dev
$ echo 6 | sudo tee /sys/accessibility/speakup/rate
6
$ echo 2 | sudo tee /sys/accessibility/speakup/punc_level
2

$ ls -l /dev/softsynth
crw-rw---- 1 root root 10, 26 Aug 27 11:14 /dev/softsynth

$ sudo systemctl enable --now espeakup.service
$ systemctl is-active espeakup.service
active
```

Reading control on the VT uses the **numeric keypad** as the review keys (`KP_8`/`KP_2` line up/down, `KP_5` current line, `KP_Enter` say-all, `KP_Ins`+`Q` silence). Speakup is per-VT: switching with `Chvt`/`Ctrl`+`Alt`+`F3` gives an independent review cursor.

Boot-time activation when speakup is built into the kernel:

```
$ sudo grubby --update-kernel=ALL --args="speakup.synth=soft"
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.11.9-200.fc41.x86_64 root=UUID=... rw \
  fbcon=font:TER16x32 speakup.synth=soft
```

### 5.7 Braille: BRLTTY and BrlAPI

```
$ brltty --version
BRLTTY 6.6 (Jan  1 2024)
Copyright (C) 1995-2024 by The BRLTTY Developers.
BRLTTY comes with ABSOLUTELY NO WARRANTY.

$ lsusb | grep -i -E 'braille|handy|baum|freedom'
Bus 001 Device 007: ID 0921:1200 Handy Tech Elektronik GmbH Braille Display

$ sudo brltty -n -e -l debug -b auto -d usb: -x lx -t en_US
brltty: BRLTTY 6.6 rev ...
brltty: Working Directory: /
brltty: Configuration File: /etc/brltty.conf
brltty: Tables Directory: /etc/brltty
brltty: Braille Driver: ht [HandyTech]
brltty: Braille Device: usb:
brltty: Detected HandyTech Active Braille 40 (serial 12345)
brltty: Text Table: en_US
brltty: Screen Driver: lx [Linux]
brltty: STARTED

$ systemctl status brltty-console.service
● brltty-console.service - BRLTTY braille daemon (Linux console screen driver)
     Loaded: loaded (/etc/systemd/system/brltty-console.service; enabled)
     Active: active (running) since Thu 2026-08-27 11:22:07 -03; 3min 41s ago
       Docs: https://brltty.app/doc/Manual-BRLTTY/English/BRLTTY.html
   Main PID: 6104 (brltty)
      Tasks: 4 (limit: 18956)
     CGroup: /system.slice/brltty-console.service
             └─6104 /usr/bin/brltty --no-daemon --standard-error ...

$ ss -lntp | grep 4101
LISTEN 0  8  127.0.0.1:4101  0.0.0.0:*  users:(("brltty",pid=6104,fd=9))
```

Key BRLTTY options for the exam and for real work:

| Option | Meaning |
|---|---|
| `-b`, `--braille-driver` | two-letter driver code (`ht`, `bm`, `al`, `fs`, `hw`, `pm`, `no`, `auto`) |
| `-d`, `--braille-device` | `usb:`, `serial:/dev/ttyS0`, `bluetooth:XX:XX:XX:XX:XX:XX` |
| `-x`, `--screen-driver` | `lx` (Linux VT via `/dev/vcsa*`) or `a2` (AT-SPI2, for desktops) |
| `-t`, `--text-table` | character→dot mapping, e.g. `en_US`, `es`, `de` |
| `-c`, `--contraction-table` | grade-2 contraction, e.g. `en-ueb-g2` |
| `-s`, `--speech-driver` | optional speech alongside braille (`sd` = speech-dispatcher, `es` = eSpeak) |
| `-n`, `-e`, `-l` | foreground, stderr logging, log level — the debugging triad |

Orca reaches the same display through **BrlAPI** (TCP `127.0.0.1:4101`, authenticated by `/etc/brlapi.key`) and does the contraction itself with **liblouis**. Braille therefore has two independent consumers: BRLTTY for the console, Orca for the desktop. They must not both drive the display at once.

### 5.8 Console rendering: large print without a GUI

```
$ setfont ter-132n
$ showconsolefont | head -3
Character count: 256
Font width     : 16
Font height    : 32

$ ls /usr/share/kbd/consolefonts/ | grep -E '^ter-1(16|24|32)'
ter-116b.psf.gz  ter-116n.psf.gz  ter-124b.psf.gz  ter-124n.psf.gz
ter-132b.psf.gz  ter-132n.psf.gz

$ sudo sed -i 's/^FONT=.*/FONT=ter-132n/' /etc/vconsole.conf
$ sudo systemctl restart systemd-vconsole-setup.service
$ journalctl -u systemd-vconsole-setup.service -n 3
systemd-vconsole-setup[7231]: /usr/bin/setfont succeeded.
systemd-vconsole-setup[7231]: /usr/bin/loadkeys succeeded.
```

Console key repeat (the VT equivalent of Repeat Keys):

```
$ sudo kbdrate -d 1000 -r 2.0
Typematic Rate set to 2.0 cps (delay = 1000 ms)
```

---

## 6. Verification and failure diagnosis

### 6.1 The verification script

`/usr/local/bin/a11y-verify`

```bash
#!/usr/bin/env bash
# Accessibility posture verification. Idempotent, read-only, no side effects.
#   exit 0 = all checks pass
#   exit 1 = at least one FAIL (with --strict, warnings also fail)
set -uo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1
rc=0
pass() { printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "${2:-}"; }
warn() { printf '  \033[33mWARN\033[0m  %-34s %s\n' "$1" "${2:-}"; \
         [[ $STRICT -eq 1 ]] && rc=1; return 0; }
fail() { printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "${2:-}"; rc=1; }

echo "== Console layer =="
[[ -c /dev/vcsa1 ]] && pass "/dev/vcsa1"      "console text buffer readable" \
                    || fail "/dev/vcsa1"      "missing — no console screen reading"
lsmod | grep -q '^speakup' && pass "speakup module" "$(cat /sys/accessibility/speakup/version 2>/dev/null)" \
                           || warn "speakup module" "not loaded"
[[ -c /dev/softsynth ]]   && pass "/dev/softsynth"  "software synth endpoint present" \
                          || warn "/dev/softsynth"  "speakup_soft not loaded"
systemctl is-active --quiet espeakup.service && pass "espeakup.service" "active" \
                                             || warn "espeakup.service" "inactive"
f=$(grep -E '^FONT=' /etc/vconsole.conf 2>/dev/null | cut -d= -f2)
[[ -n $f ]] && pass "vconsole FONT" "$f" || fail "vconsole FONT" "unset"

echo "== Braille layer =="
command -v brltty >/dev/null && pass "brltty binary" "$(brltty --version | head -1)" \
                             || warn "brltty binary" "not installed"
if systemctl is-active --quiet brltty-console.service; then
  pass "brltty-console.service" "active"
  ss -lnt 2>/dev/null | grep -q ':4101' && pass "BrlAPI :4101" "listening" \
                                        || warn "BrlAPI :4101" "not listening"
else
  warn "brltty-console.service" "inactive (no display attached?)"
fi

echo "== Graphical layer =="
if [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
  busctl --user list 2>/dev/null | grep -q org.a11y.Bus \
    && pass "org.a11y.Bus" "registered" || fail "org.a11y.Bus" "AT-SPI bus absent"
  pgrep -x at-spi2-registryd >/dev/null \
    && pass "at-spi2-registryd" "running" || fail "at-spi2-registryd" "not running"
  [[ "$(gsettings get org.gnome.desktop.interface toolkit-accessibility 2>/dev/null)" == "true" ]] \
    && pass "toolkit-accessibility" "true" || fail "toolkit-accessibility" "false — GTK3 apps mute"
  [[ -z ${NO_AT_BRIDGE:-} ]] && pass "NO_AT_BRIDGE" "unset" \
                             || fail "NO_AT_BRIDGE" "set to '${NO_AT_BRIDGE}' — bridge disabled"
  [[ "$(gsettings get org.gnome.desktop.a11y.keyboard enable 2>/dev/null)" == "true" ]] \
    && pass "a11y.keyboard.enable" "true" || fail "a11y.keyboard.enable" "AccessX gestures off"
  [[ "$(gsettings get org.gnome.desktop.a11y.keyboard timeout-enable 2>/dev/null)" == "false" ]] \
    && pass "a11y idle auto-disable" "off" || fail "a11y idle auto-disable" "features expire on idle"
  command -v orca >/dev/null && pass "orca" "$(orca --version 2>&1 | head -1)" \
                             || warn "orca" "not installed"
  spd-say -O 2>/dev/null | grep -q . && pass "speech-dispatcher modules" \
      "$(spd-say -O 2>/dev/null | tail -n +2 | tr '\n' ' ')" \
    || fail "speech-dispatcher modules" "none available"
else
  warn "graphical layer" "no DISPLAY/WAYLAND_DISPLAY — headless, skipped"
fi

echo "== dconf policy =="
if [[ -f /etc/dconf/db/local ]]; then
  if [[ -n "$(find /etc/dconf/db/local.d -newer /etc/dconf/db/local 2>/dev/null)" ]]; then
    fail "dconf db/local" "stale — run: dconf update"
  else
    pass "dconf db/local" "compiled and current"
  fi
else
  fail "dconf db/local" "not compiled"
fi

exit "$rc"
```

Expected clean run:

```
$ a11y-verify
== Console layer ==
  PASS  /dev/vcsa1                         console text buffer readable
  PASS  speakup module                     Speakup v-3.1.6-dev
  PASS  /dev/softsynth                     software synth endpoint present
  PASS  espeakup.service                   active
  PASS  vconsole FONT                      ter-132n
== Braille layer ==
  PASS  brltty binary                      BRLTTY 6.6 (Jan  1 2024)
  PASS  brltty-console.service             active
  PASS  BrlAPI :4101                       listening
== Graphical layer ==
  PASS  org.a11y.Bus                       registered
  PASS  at-spi2-registryd                  running
  PASS  toolkit-accessibility              true
  PASS  NO_AT_BRIDGE                       unset
  PASS  a11y.keyboard.enable               true
  PASS  a11y idle auto-disable             off
  PASS  orca                               Orca 45.2
  PASS  speech-dispatcher modules          espeak-ng festival pico dummy
== dconf policy ==
  PASS  dconf db/local                     compiled and current
$ echo $?
0
```

### 6.2 Symptom → root cause → command

| Symptom | Most likely cause | Confirming command | Fix |
|---|---|---|---|
| Orca starts, says nothing at all | speech-dispatcher dead or wrong audio sink | `spd-say test` | check `~/.cache/speech-dispatcher/log/`; set `AudioOutputMethod "pulse"` in `speechd.conf` |
| Orca speaks in GNOME apps, silent in one app | that toolkit's bridge is off | `python3 -c 'import pyatspi; print([a.name for a in pyatspi.Registry.getDesktop(0)])'` | `QT_ACCESSIBILITY=1`; Java `accessibility.properties`; Chromium `--force-renderer-accessibility` |
| **Every** GTK3 app is invisible to Orca | `toolkit-accessibility=false` or `NO_AT_BRIDGE=1` | `gsettings get org.gnome.desktop.interface toolkit-accessibility`; `env \| grep NO_AT` | set the gsetting true; purge `NO_AT_BRIDGE` from images/entrypoints |
| Nothing accessible inside a Flatpak app | missing sandbox permission | `flatpak info --show-permissions <app>` | `flatpak override --socket=accessibility <app>` |
| Sticky Keys turns itself off after ~2 min | AccessX timeout expiry | `xkbset q \| grep -A2 Timeout` | `xkbset exp "=sticky"`, or `timeout-enable=false` in dconf |
| Sticky Keys resets when the keyboard layout changes | `setxkbmap` reloads the keymap and clears AccessX | `xev -event keyboard` after a layout switch | configure via `org.gnome.desktop.a11y.keyboard`, not `xkbset` |
| The 5×Shift / hold-Shift gestures do nothing | master gate off | `gsettings get org.gnome.desktop.a11y.keyboard enable` | set `true` (and lock it) |
| Braille display not detected | udev rule / permissions / wrong driver | `udevadm monitor --udev`; `sudo brltty -n -e -l debug -b auto -d usb:` | correct `idVendor`/`idProduct`, reload rules, pick the right `-b` |
| Braille works on VT, dead on the desktop | wrong screen driver | check `--screen-driver` | `-x a2` for AT-SPI2, or let Orca own the display via BrlAPI |
| Orca cannot open the braille display | BRLTTY already holds it, or BrlAPI auth | `ss -lntp \| grep 4101`; `ls -l /etc/brlapi.key` | one consumer only; add the user to the `brlapi` group |
| `xkbset`/`xdotool` "have no effect" | session is Wayland | `echo $XDG_SESSION_TYPE` | use gsettings / compositor APIs; X tools only affect XWayland |
| Magnifier keys do nothing on sway/wlroots | no compositor magnifier implementation | `echo $XDG_SESSION_TYPE`, compositor docs | use GNOME/Plasma for a11y-critical users |
| Login screen has no accessibility at all | greeter uses the `gdm` dconf database, not `local` | `cat /etc/dconf/profile/gdm` | populate `/etc/dconf/db/gdm.d/` + `dconf update` |
| Settings apply for root, not for users | forgot `dconf update`, or wrong profile | `ls -l /etc/dconf/db/local*` and compare mtimes | `dconf update`; verify `/etc/dconf/profile/user` lists `system-db:local` |
| Console speech works, nothing in initramfs / rescue | speakup+espeakup not in the initramfs | `lsinitrd \| grep -E 'speakup\|espeak'` | accept the gap and provide serial/BMC access, or build a custom initramfs |
| Screen reader silent over `ssh -X` | AT-SPI is session-local; X11 forwards pixels only | `dbus-send ... org.a11y.Bus.GetAddress` on the remote host | run the whole session remotely (VNC/RDP) with audio forwarding |

### 6.3 Diagnostic decision tree — "the screen reader is silent"

```
Screen reader silent
├─ Graphical session?
│  ├─ NO → console layer
│  │   ├─ /dev/softsynth missing?      → modprobe speakup_soft
│  │   ├─ espeakup inactive?           → systemctl start espeakup
│  │   ├─ silent flag set?             → echo 0 > /sys/accessibility/speakup/silent
│  │   └─ no audio device?             → aplay -l ; check the codec/HDMI sink
│  └─ YES
│     ├─ `spd-say test` audible?
│     │   ├─ NO  → speech-dispatcher / audio problem  (STOP — not an a11y problem)
│     │   └─ YES → the object tree is the problem, continue
│     ├─ org.a11y.Bus registered?      → NO: at-spi2-core missing / bus-launcher crashed
│     ├─ App present in getDesktop(0)? → NO: toolkit bridge off for that app
│     │                                        (NO_AT_BRIDGE / QT_ACCESSIBILITY /
│     │                                         toolkit-accessibility / Flatpak socket)
│     └─ App present but no focus events?
│         └─ compositor not delivering focus  → Wayland on an unsupported compositor
```

### 6.4 What this ladder does **not** prove

Every check above verifies that the *machinery* is present and wired. None of them verifies that the resulting experience is usable: correct reading order, meaningful widget labels, sufficient contrast ratio, or a keyboard path to every function. Those require WCAG/EN 301 549 evaluation with a real assistive-technology user. Treat automated a11y verification exactly like a health check — necessary, cheap, continuously run, and never a substitute for the actual test.

---

## 7. Exam-focused summary

**Memorise the mapping from feature name to mechanism:**

| Feature | What it does | X11 / console mechanism | GNOME key |
|---|---|---|---|
| **Sticky Keys** | modifiers latch; no simultaneous press needed | `xkbset sticky` | `stickykeys-enable` |
| **Repeat Keys** | auto-repeat delay and rate | `xset r rate D R` / `kbdrate` | `org.gnome.desktop.peripherals.keyboard repeat-interval` |
| **Slow Keys** | ignore keys held < N ms | `xkbset sl N` | `slowkeys-enable` / `slowkeys-delay` |
| **Bounce Keys** | ignore repeated same key within N ms | `xkbset bo N` | `bouncekeys-enable` / `bouncekeys-delay` |
| **Toggle Keys** | beep when Caps/Num/Scroll Lock changes | AccessX feedback | `togglekeys-enable` |
| **Mouse Keys** | move the pointer with the numeric keypad | `xkbset m` | `mousekeys-enable` |
| **Gestures** | 5×Shift → Sticky; hold Shift 8 s → Slow | AccessX gestures | gated by `a11y.keyboard enable` |
| **High Contrast / Large Print** | themes and text scaling | GTK theme | `a11y.interface high-contrast`, `interface text-scaling-factor` |
| **Screen Reader** | speaks the UI | Orca (GUI) / speakup (VT) | `a11y.applications screen-reader-enabled` |
| **Screen Magnifier** | zooms a region | mutter / KWin / `xzoom` | `a11y.applications screen-magnifier-enabled` |
| **On-Screen Keyboard** | pointer/touch text entry | GNOME OSK, GOK (dead), `xvkbd` | `a11y.applications screen-keyboard-enabled` |
| **Braille Display** | tactile output | BRLTTY (+ BrlAPI for Orca) | driven by `brltty`/Orca, not gsettings |

**Names you must be able to place:** Orca (GUI screen reader), GOK (obsolete on-screen keyboard with scanning), emacspeak (Emacs audio desktop), BRLTTY (braille daemon), speakup (kernel console reader), espeakup (bridges `speakup_soft` to espeak-ng), speech-dispatcher (TTS multiplexer), AT-SPI2 (D-Bus accessibility bus), liblouis (braille translation tables), `xkbset` (AccessX control), `gsettings`/`dconf` (GNOME settings).

---

## 8. Referencias

**Certification**

* LPI — Exam 101-500 Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
* LPI — Exam 102-500 Objectives (Topic 106.3 lives here): https://www.lpi.org/our-certifications/exam-102-objectives/
* LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Accessibility infrastructure**

* Orca screen reader — user guide: https://help.gnome.org/users/orca/stable/
* Orca — source and issue tracker: https://gitlab.gnome.org/GNOME/orca
* AT-SPI2 core: https://gitlab.gnome.org/GNOME/at-spi2-core
* BRLTTY — official site and manual: https://brltty.app/ · https://brltty.app/doc/Manual-BRLTTY/English/BRLTTY.html
* Speakup — kernel user guide: https://www.kernel.org/doc/html/latest/admin-guide/spkguide.html
* Speech Dispatcher: https://freebsoft.org/speechd
* eSpeak NG: https://github.com/espeak-ng/espeak-ng
* liblouis (braille translation): https://liblouis.io/

**Toolkits and display servers**

* GTK 4 accessibility overview: https://docs.gtk.org/gtk4/section-accessibility.html
* Qt accessibility: https://doc.qt.io/qt-6/accessible.html
* X Keyboard Extension protocol (AccessX controls): https://www.x.org/releases/current/doc/kbproto/xkbproto.html
* `xkbset`: https://github.com/stephenmontgomerysmith/xkbset
* libei (emerging Wayland input-emulation layer): https://libinput.pages.freedesktop.org/libei/
* Flatpak sandbox permissions (`--socket=accessibility`): https://docs.flatpak.org/en/latest/sandbox-permissions.html

**Fleet configuration**

* GNOME System Administration Guide (dconf profiles, system databases, locks): https://help.gnome.org/admin/system-admin-guide/stable/
* `vconsole.conf(5)`: https://www.freedesktop.org/software/systemd/man/vconsole.conf.html
* `udev(7)` rules: https://www.freedesktop.org/software/systemd/man/udev.html
* GNU GRUB manual (serial terminal, `GRUB_INIT_TUNE`, fonts): https://www.gnu.org/software/grub/manual/grub/grub.html
* Debian Installation Guide — accessibility during installation: https://www.debian.org/releases/stable/amd64/

**Standards and compliance**

* WCAG 2.2: https://www.w3.org/TR/WCAG22/
* EN 301 549 (ETSI): https://www.etsi.org/deliver/etsi_en/301500_301599/301549/
* Section 508: https://www.section508.gov/
* `NO_COLOR` convention for CLI output: https://no-color.org/