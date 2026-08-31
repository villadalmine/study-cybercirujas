# 106.1 — Install and Configure X11

**LPIC-1 · Topic 106: User Interfaces and Desktops**
*(Note on exam mapping: topic 106 is examined in **102-500**, not 101-500. In the LPIC-1 v5.0 objective set, 106.1 carries a **weight of 2**. The syllabus record that produced this page reports weight 0.0, which is a metadata gap — study it at weight-2 depth.)*

---

## 1. Motivation: why a platform team still cares about X11

The instinctive reaction of an SRE to "X11" is that it belongs to the desktop team. That reaction is wrong in four production contexts that show up constantly:

**a) Headless GUI workloads in CI.** Browser automation (Selenium, Playwright, Cypress in non-headless mode), Electron packaging, PDF rendering via Qt/WebKit, ImageMagick with X delegates, and any legacy Java/Swing test harness require an X server to exist. They do not require a *screen*. The production answer is `Xvfb` or `Xorg` with the `dummy` driver inside a container, and the failure mode — `Error: Can't open display:` — is one of the most common CI outages in mixed-stack organizations.

**b) GPU nodes.** A CUDA node does not need X. A node doing OpenGL rendering, video transcoding with NVENC through an OpenGL pipeline, or remote visualization (ParaView, Blender render farms, CAD) does. Configuring `Xorg` on a GPU with **no monitor attached** requires `Option "AllowEmptyInitialConfiguration"` and an explicit `BusID` — without them the server exits with `no screens found` and the node silently fails scheduling.

**c) Remote engineering access.** X11 forwarding over SSH remains the lowest-friction way to run one graphical tool on a jump host. It is also a **security decision**: `ssh -Y` hands the remote host full keyboard and screen access to your local session. Knowing the difference between trusted and untrusted forwarding is an access-control control, not a convenience preference.

**d) Console-of-last-resort and kiosk fleets.** Digital signage, industrial HMIs, lab bench machines and ticketing terminals are Linux boxes whose entire purpose is one X client on one screen. They are managed like servers, configured with `xorg.conf.d` fragments from Ansible, and debugged over SSH by reading `~/.xsession-errors`.

### The architectural problem X11 poses

X11 was designed in 1984 for a network of terminals against a central host. Two design decisions from that era are now the central production trade-offs:

1. **Network transparency by default.** The protocol is a byte stream; the transport (UNIX socket, TCP, SSH tunnel) is interchangeable. This is why `DISPLAY=jump:0` works at all — and why the wire protocol is chatty enough that a naive round-trip over 100 ms RTT makes a menu unusable.
2. **No isolation between clients.** Every client connected to a display can read every other client's window contents, synthesize input events (`XTEST`), and record the input stream (`XRECORD`). There is no per-client permission model. A single compromised X client is a keylogger for the whole session. This — not performance — is the reason Wayland exists.

The platform decision you will actually be asked to make is therefore: *X11, Wayland, or a remote-display protocol on top of one of them* — and X11 keeps winning in exactly the cases where network transparency and 40 years of client compatibility matter more than isolation.

---

## 2. Architecture and internals

### 2.1 The inverted client/server model

The **X server runs where the hardware is** — the machine with the keyboard, mouse and screen. **X clients** are the applications (`xterm`, Firefox, a window manager). A remote application is a client connecting *back* to your local server. This inversion is the single most reliably misunderstood fact in the topic.

```
   ┌───────────────────── workstation ──────────────────────┐
   │                                                        │
   │   Xorg (the X SERVER)                                  │
   │     ├── DIX  — device-independent core, protocol,      │
   │     │         request dispatch, event delivery         │
   │     ├── DDX  — device-dependent: modesetting/intel/    │
   │     │         amdgpu/nvidia drivers → DRM/KMS          │
   │     ├── input: libinput → evdev → /dev/input/event*    │
   │     └── extensions: RandR, Composite, GLX, DRI3,       │
   │                     XTEST, XRECORD, SECURITY, XKB      │
   │        ▲            ▲                  ▲               │
   │        │ unix       │ unix             │ TCP :6000+N   │
   │  /tmp/.X11-unix/X0  │              (off by default)    │
   │        │            │                  │               │
   │   window manager  local clients    remote client       │
   │   (mutter/i3/…)   (firefox, …)     via ssh -X tunnel   │
   └────────────────────────────────────────────────────────┘
```

The **window manager** (i3, openbox, mutter, kwin) is just another client — it is what draws title bars and decides geometry. The **desktop environment** (GNOME, KDE Plasma, XFCE) is a WM plus panels, a file manager, settings daemons and a session manager. The **display manager** (GDM, LightDM, SDDM, XDM) is the graphical login: it starts the X server, authenticates via PAM, and then execs the session.

### 2.2 Display names, transports and ports

```
DISPLAY=hostname:displaynumber.screennumber
```

| Value | Transport | Notes |
|---|---|---|
| `:0` or `:0.0` | UNIX socket `/tmp/.X11-unix/X0` (and abstract socket `@/tmp/.X11-unix/X0`) | Local, fastest, no TCP stack |
| `unix:0` | UNIX socket, explicitly | Forces the socket even if a hostname would resolve |
| `localhost:10.0` | TCP `127.0.0.1:6010` | The shape of an SSH-forwarded display (`X11DisplayOffset 10`) |
| `10.0.0.5:0` | TCP `10.0.0.5:6000` | Requires the server started with `-listen tcp`; **cookie travels in clear** |
| `:1` on a second seat | `/tmp/.X11-unix/X1` | Second server instance, second VT |

TCP port = **6000 + display number**. Since X.Org 1.17 the server defaults to `-nolisten tcp`; TCP must be re-enabled explicitly (`Xorg :0 -listen tcp`, or `/etc/X11/xinit/xserverrc`, or the display manager's config). Treat re-enabling it as a security exception requiring justification.

### 2.3 Startup paths

There are exactly three ways an X server comes up, and they have different config surfaces:

| Path | Entry point | User config | Where output lands |
|---|---|---|---|
| Manual, from a VT | `startx` → `xinit` → `Xorg` + client script | `~/.xinitrc`, `~/.xserverrc` (falls back to `/etc/X11/xinit/xinitrc`) | The controlling TTY |
| Display manager | `display-manager.service` → GDM/LightDM/SDDM → `Xorg` → `Xsession` | `~/.xsession`, `~/.xsessionrc`, `/etc/X11/Xsession.d/*` | `~/.xsession-errors` |
| Headless/service | `Xvfb`, or `Xorg` under a systemd unit | server flags only | unit journal, `-logfile` |

`startx` passes anything after `--` to the server: `startx -- :1 vt8 -keeptty`.

`~/.xsession-errors` exists because the `Xsession` wrapper redirects the session's stdout/stderr into it (`exec >> "$ERRFILE" 2>&1`). It is the **first file to read** for "I log in and get bounced straight back to the greeter."

### 2.4 The configuration file

Modern X.Org autodetects nearly everything through KMS and libinput. `/etc/X11/xorg.conf` is now the exception, and the supported pattern is **drop-in fragments**:

Search order (later overrides earlier, all merged):

1. `/usr/share/X11/xorg.conf.d/*.conf` — vendor/package defaults, **do not edit**
2. `/etc/X11/xorg.conf.d/*.conf` — administrator drop-ins, **edit here**
3. `/etc/X11/xorg.conf` — monolithic legacy file
4. `/etc/xorg.conf`, `/etc/X11/xorg.conf-4`, … — historical fallbacks

Section types and what they own:

| Section | Owns | Typical production use |
|---|---|---|
| `ServerLayout` | Which Screens and InputDevices form the layout | Multi-GPU, multi-seat |
| `Files` | `FontPath`, `ModulePath` | Legacy core fonts |
| `Module` | Load/disable server modules | `Disable "dri"` on broken stacks |
| `InputDevice` | One static input device | Legacy; superseded by `InputClass` |
| `InputClass` | Rule-matched input config | **Keyboard layout, touchpad behaviour** |
| `Device` | The GPU: driver, `BusID`, driver options | Headless GPU, NVIDIA, `modesetting` |
| `Monitor` | `HorizSync`, `VertRefresh`, `Modeline`, `DPMS` | Forced modes, EDID-less panels |
| `Screen` | Device + Monitor + `SubSection "Display"` (depth, `Modes`, `Virtual`) | Virtual framebuffer size |
| `ServerFlags` | Global: `DontZap`, `AutoAddDevices`, `BlankTime` | Kiosk hardening |
| `Extensions` | Enable/disable protocol extensions | `Option "Composite" "Disable"` |

### 2.5 Authorization: who may connect

| Mechanism | Granularity | Wire safety | Verdict |
|---|---|---|---|
| `xhost +` | none — **everyone on the network** | none | Never. This is a remote-code-execution invitation |
| `xhost +hostname` | per host, **any user on it** | none | Only inside a trusted L2 segment, temporarily |
| `xhost +si:localuser:alice` | per local UID (server-interpreted) | n/a (local) | Correct way to let a local UID in |
| `MIT-MAGIC-COOKIE-1` | per-display 128-bit shared secret in `~/.Xauthority` | **plaintext over TCP** | Default; safe over UNIX socket or SSH |
| `XDM-AUTHORIZATION-1` | DES-based challenge | resistant to replay | Rare, XDMCP-era |
| SSH forwarding | per-connection, per-session cookie | encrypted | **The production answer** |

The cookie file is chosen by `$XAUTHORITY`, falling back to `~/.Xauthority`. Display managers frequently place it elsewhere (`/run/user/1000/gdm/Xauthority`), which is why `sudo` and `su` break X access: the environment carries `DISPLAY` but the new UID cannot read the cookie file.

### 2.6 SSH X11 forwarding, precisely

Server side (`/etc/ssh/sshd_config`): `X11Forwarding yes`, `X11DisplayOffset 10`, `X11UseLocalhost yes`. The `xauth` binary **must be installed on the server** — sshd calls it to create the proxy cookie. Client side: `ForwardX11`, `ForwardX11Trusted`, `ForwardX11Timeout` (default `20m`).

* `ssh -X` → **untrusted**. sshd generates a cookie constrained by the `SECURITY` extension and expiring after `ForwardX11Timeout`. Many apps break under it (`BadAccess` on `XRECORD`/`XTEST`, clipboard oddities).
* `ssh -Y` → **trusted**. The remote client has full access to your local display: it can screenshot your banking tab and inject keystrokes. Use it only toward hosts you would give your workstation password to.

### 2.7 Fonts

Two independent stacks coexist:

* **Core X font protocol** — server-side, bitmap/Type1, `FontPath` in `Section "Files"`, manipulated live with `xset +fp`/`xset fp rehash`, indexed by `mkfontdir`/`mkfontscale`. Legacy; needed by `xterm`, `xfontsel`, old Motif apps.
* **Xft/fontconfig** — client-side rendering with anti-aliasing, config in `/etc/fonts/`, `~/.config/fontconfig/fonts.conf`, cache built by `fc-cache -fv`, queried with `fc-list`/`fc-match`. Everything modern uses this.

A missing font path only produces `(WW)` warnings; a missing fontconfig font produces silently wrong glyph substitution — which is why PDF renders in CI come out in the wrong typeface without any error.

### 2.8 Wayland awareness (explicitly examinable)

Under Wayland the compositor **is** the display server: kernel KMS/DRM + input handling + window management + compositing collapse into one process (mutter, kwin_wayland, sway, weston). There is no network transparency and no `DISPLAY`; clients speak the Wayland protocol over `$WAYLAND_DISPLAY` in `$XDG_RUNTIME_DIR`. Legacy X clients run under **XWayland**, a rootless X server that presents itself as a normal `:0` and proxies surfaces into the compositor.

| Dimension | X11 (X.Org) | Wayland |
|---|---|---|
| Architecture | Server + WM + compositor as separate processes | Single compositor process |
| Client isolation | **None** — any client reads/injects anywhere | Enforced; capture/input need portals |
| Network transparency | Native (TCP / SSH tunnel) | None natively; `waypipe`, or RDP/VNC backends |
| Screen capture / automation | Trivial (`xwd`, `xdotool`, `import`) | Requires `xdg-desktop-portal` + PipeWire |
| Per-monitor scaling / mixed DPI | Poor (global DPI, RandR hacks) | First-class, per-output |
| Tear-free by design | No (needs a compositor) | Yes |
| Global hotkeys, screen lockers, IMEs | Mature | Protocol-dependent, still uneven |
| Accessibility (`AT-SPI`, screen readers) | Mature | Improving, gaps remain |
| NVIDIA proprietary support | Long-mature | Good since driver 495+/explicit sync, historically painful |
| Remote admin tooling (`x11vnc`, `ssh -X`) | Works everywhere | Compositor-specific |
| Kiosk/embedded footprint | Larger stack | Smaller (`weston`, `cage`) |

Check what you are actually running:

```
$ echo "$XDG_SESSION_TYPE"
wayland
$ loginctl show-session "$XDG_SESSION_ID" -p Type -p Remote -p Active
Type=wayland
Remote=no
Active=yes
```

Forcing X11 for a fleet that depends on X-only tooling: `WaylandEnable=false` in `/etc/gdm/custom.conf` (Debian/Ubuntu: `/etc/gdm3/daemon.conf`), or select "GNOME on Xorg" per session.

### 2.9 Headless server options

| Option | GPU accel | GLX | Resolution changes | Cost | Use case |
|---|---|---|---|---|---|
| `Xvfb` | No (software) | With `+extension GLX` and Mesa `llvmpipe`/`swrast` | Fixed at start (`-screen`) | Lowest | CI browser tests, PDF/render jobs |
| `Xorg` + `dummy` driver | No | Software | RandR-capable up to `Virtual` | Low | Headless desktop you will VNC into |
| `Xorg` + real GPU, no monitor | **Yes** | Hardware | Yes | Needs `BusID` + `AllowEmptyInitialConfiguration` | GPU render nodes, remote visualization |
| `Xephyr` / `Xnest` | Nested in an existing X | GLX on `Xephyr` | Resizable | Trivial | Debugging a WM/session without leaving your desktop |

### 2.10 Remote display protocols

| Protocol | Model | State on disconnect | Bandwidth on video | Clipboard/audio | Multi-user | GPU |
|---|---|---|---|---|---|---|
| X11 forwarding (`ssh -X/-Y`) | Per-application, synchronous | **Lost** — app dies with the tunnel | Poor (round-trip bound) | Clipboard yes, audio no | Per-user | Indirect GLX only |
| VNC (`x11vnc`, TigerVNC) | Framebuffer mirror | Persists (server-side session) | Moderate (Tight/ZRLE) | Clipboard yes, audio no | Per-display | Via virtualGL |
| RDP (`xrdp`, FreeRDP) | Semantic + bitmap hybrid | Persists, reconnect-friendly | Good (RemoteFX/H.264) | Clipboard, audio, drive redirection | Yes, per-session | Yes |
| NX / X2Go | X protocol compression + proxy | Suspend/resume sessions | Good | Yes | Yes | Limited |
| SPICE | VM-oriented | Persists (VM-side) | Good | Yes | VM-scoped | Yes |
| `waypipe` | Wayland over SSH | Lost with tunnel | Good (dmabuf-aware) | Partial | Per-user | Yes |

Rule of thumb for platform work: **`ssh -X` for one tool, VNC/RDP for a durable session, never `xhost +` for anything.**

---

## 3. Complete configurations and infrastructure

### 3.1 Keyboard layout drop-in — `/etc/X11/xorg.conf.d/00-keyboard.conf`

This is the exact file `localectl set-x11-keymap` writes; it is also the canonical "override one aspect of Xorg configuration" answer.

```
# Written by systemd-localed(8) or by configuration management.
# Keep in sync with /etc/vconsole.conf so console and X agree.
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "us,es"
        Option "XkbModel" "pc105"
        Option "XkbVariant" "intl,"
        Option "XkbOptions" "grp:alt_shift_toggle,terminate:ctrl_alt_bksp,compose:ralt"
EndSection
```

### 3.2 Touchpad and pointer — `/etc/X11/xorg.conf.d/40-libinput-touchpad.conf`

```
Section "InputClass"
        Identifier "libinput touchpad catchall"
        MatchIsTouchpad "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
        Option "Tapping" "on"
        Option "TappingButtonMap" "lrm"
        Option "NaturalScrolling" "true"
        Option "ScrollMethod" "twofinger"
        Option "DisableWhileTyping" "true"
        Option "AccelProfile" "adaptive"
        Option "AccelSpeed" "0.3"
EndSection

Section "InputClass"
        Identifier "libinput pointer catchall"
        MatchIsPointer "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
        # Flat profile: 1:1 motion, required for CAD and remote-desktop work
        Option "AccelProfile" "flat"
EndSection
```

### 3.3 Headless X on a real GPU — full `/etc/X11/xorg.conf`

For a rendering node with an NVIDIA card and **no monitor plugged in**. Without `AllowEmptyInitialConfiguration` the server aborts with `no screens found`.

```
Section "ServerLayout"
        Identifier     "headless-render"
        Screen      0  "Screen0" 0 0
        Option         "AutoAddDevices" "false"
        Option         "AutoAddGPU"     "false"
EndSection

Section "ServerFlags"
        Option         "DontVTSwitch"   "true"
        Option         "DontZap"        "true"
        Option         "AllowMouseOpenFail" "true"
        Option         "BlankTime"      "0"
        Option         "StandbyTime"    "0"
        Option         "SuspendTime"    "0"
        Option         "OffTime"        "0"
EndSection

Section "Files"
        ModulePath     "/usr/lib/xorg/modules"
        FontPath       "/usr/share/fonts/X11/misc"
        FontPath       "built-ins"
EndSection

Section "Module"
        Load           "glx"
        Load           "dri2"
EndSection

Section "Monitor"
        Identifier     "Monitor0"
        VendorName     "Unknown"
        ModelName      "Virtual"
        HorizSync       28.0 - 90.0
        VertRefresh     43.0 - 75.0
        # Generated by: cvt 1920 1080 60
        Modeline       "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
        Option         "DPMS" "false"
EndSection

Section "Device"
        Identifier     "Device0"
        Driver         "nvidia"
        VendorName     "NVIDIA Corporation"
        BusID          "PCI:1:0:0"
        Option         "AllowEmptyInitialConfiguration" "true"
        Option         "UseDisplayDevice" "none"
        Option         "ConnectedMonitor" "DFP-0"
        Option         "CustomEDID" "DFP-0:/etc/X11/edid.bin"
EndSection

Section "Screen"
        Identifier     "Screen0"
        Device         "Device0"
        Monitor        "Monitor0"
        DefaultDepth    24
        Option         "UseDisplayDevice" "none"
        SubSection     "Display"
                Depth       24
                Modes      "1920x1080_60.00"
                Virtual     3840 2160
        EndSubSection
EndSection

Section "Extensions"
        Option         "Composite" "Disable"
EndSection
```

### 3.4 Pure-software headless — `/etc/X11/xorg.conf.d/10-dummy.conf`

```
Section "Device"
        Identifier  "dummy-gpu"
        Driver      "dummy"
        # 256 MB is enough for 3840x2160x32 with room for pixmaps
        VideoRam    256000
EndSection

Section "Monitor"
        Identifier  "dummy-monitor"
        HorizSync    5.0 - 1000.0
        VertRefresh  5.0 - 200.0
        Modeline    "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
        Modeline    "3840x2160_60.00" 712.75 3840 4160 4576 5312 2160 2163 2168 2237 -hsync +vsync
EndSection

Section "Screen"
        Identifier  "dummy-screen"
        Device      "dummy-gpu"
        Monitor     "dummy-monitor"
        DefaultDepth 24
        SubSection  "Display"
                Depth   24
                Modes  "1920x1080_60.00" "3840x2160_60.00"
                Virtual 3840 2160
        EndSubSection
EndSection
```

### 3.5 Rootless X wrapper — `/etc/X11/Xwrapper.config`

```
# allowed_users: console | rootonly | anybody
# needs_root_rights: yes | no | auto   (auto = drop root when KMS allows it)
allowed_users=console
needs_root_rights=auto
```

With `needs_root_rights=auto` on a KMS driver, Xorg runs unprivileged and its log moves to `~/.local/share/xorg/Xorg.0.log`. Looking in `/var/log/Xorg.0.log` on such a system yields a stale file from the last root-run — a classic hour-wasting trap.

### 3.6 systemd template unit for a virtual display — `/etc/systemd/system/xvfb@.service`

```ini
[Unit]
Description=X Virtual Frame Buffer on display %i
Documentation=man:Xvfb(1)
After=network.target
StopWhenUnneeded=yes

[Service]
Type=simple
User=xvfb
Group=xvfb
Environment=XVFB_RES=1920x1080x24
ExecStart=/usr/bin/Xvfb :%i \
          -screen 0 ${XVFB_RES} \
          -nolisten tcp \
          -nolisten unix \
          -auth /run/xvfb/Xauthority.%i \
          -dpi 96 \
          +extension GLX +extension RANDR +extension RENDER \
          -noreset
ExecStartPre=/usr/bin/install -d -o xvfb -g xvfb -m 0750 /run/xvfb
Restart=on-failure
RestartSec=2s

# Hardening: this process needs no privileges at all
NoNewPrivileges=yes
PrivateTmp=no
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/run/xvfb /tmp/.X11-unix
PrivateDevices=yes
RestrictAddressFamilies=AF_UNIX
CapabilityBoundingSet=
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
```

Consumers declare `Requires=xvfb@99.service` and set `Environment=DISPLAY=:99`. `-noreset` is essential: without it the server resets (and wipes root-window state) whenever the last client disconnects, which breaks long-lived test grids.

### 3.7 Ansible role — deploy X11 policy to a kiosk/CI fleet

```yaml
---
# roles/x11_baseline/tasks/main.yml
- name: Install the minimal X stack
  ansible.builtin.package:
    name:
      - xserver-xorg-core
      - xserver-xorg-video-dummy
      - xserver-xorg-input-libinput
      - xvfb
      - x11-xserver-utils     # xset, xrandr, xhost
      - x11-utils             # xdpyinfo, xwininfo, xev
      - xauth
      - fonts-dejavu-core
    state: present

- name: Ensure the drop-in directory exists
  ansible.builtin.file:
    path: /etc/X11/xorg.conf.d
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Deploy keyboard layout drop-in
  ansible.builtin.template:
    src: 00-keyboard.conf.j2
    dest: /etc/X11/xorg.conf.d/00-keyboard.conf
    owner: root
    group: root
    mode: "0644"
    validate: /bin/true          # Xorg has no offline syntax checker; see verification below
  notify: restart display manager

- name: Deploy the dummy device drop-in on headless hosts
  ansible.builtin.copy:
    src: 10-dummy.conf
    dest: /etc/X11/xorg.conf.d/10-dummy.conf
    owner: root
    group: root
    mode: "0644"
  when: x11_headless | bool
  notify: restart display manager

- name: Forbid host-based X authorization fleet-wide
  ansible.builtin.copy:
    dest: /etc/profile.d/zz-no-xhost.sh
    owner: root
    group: root
    mode: "0644"
    content: |
      # Host-based X authorization grants every user on the peer host full
      # access to this display, including keystroke capture. Blocked by policy.
      xhost() {
          echo "xhost is disabled by policy; use xauth or ssh -X" >&2
          return 1
      }

- name: Console and X keymaps must agree
  ansible.builtin.command:
    cmd: >-
      localectl set-x11-keymap
      {{ x11_layout }} {{ x11_model }} {{ x11_variant | default('') }}
      {{ x11_options | default('') }}
  register: _localectl
  changed_when: _localectl.rc == 0
  when: x11_manage_keymap | bool

- name: Enable the virtual framebuffer on CI runners
  ansible.builtin.systemd:
    name: "xvfb@{{ x11_vfb_display }}.service"
    enabled: true
    state: started
    daemon_reload: true
  when: x11_role == 'ci-runner'

- name: Assert that the display actually answers
  ansible.builtin.command:
    cmd: "xdpyinfo -display :{{ x11_vfb_display }}"
  register: _xdpy
  changed_when: false
  failed_when: "'number of screens' not in _xdpy.stdout"
  when: x11_role == 'ci-runner'
```

```yaml
---
# roles/x11_baseline/defaults/main.yml
x11_headless: true
x11_manage_keymap: true
x11_layout: "us"
x11_model: "pc105"
x11_variant: ""
x11_options: "terminate:ctrl_alt_bksp"
x11_role: "ci-runner"
x11_vfb_display: 99
```

```yaml
---
# roles/x11_baseline/handlers/main.yml
- name: restart display manager
  ansible.builtin.systemd:
    name: display-manager.service
    state: restarted
  when:
    - not (x11_headless | bool)
    - x11_allow_session_restart | default(false) | bool
```

### 3.8 Kubernetes: GUI test runner with an Xvfb sidecar

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: xvfb-config
  namespace: ci
data:
  DISPLAY: ":99"
  SCREEN_GEOMETRY: "1920x1080x24"
  XAUTHORITY: "/tmp/.xauth/Xauthority"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: browser-grid
  namespace: ci
  labels:
    app.kubernetes.io/name: browser-grid
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: browser-grid
  template:
    metadata:
      labels:
        app.kubernetes.io/name: browser-grid
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      volumes:
        # The X server socket lives here; both containers must see it.
        - name: x11-socket
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
        - name: xauth
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
        # Chromium crashes with "Failed to move to new namespace" / tab
        # crashes when /dev/shm is the 64Mi container default.
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
      containers:
        - name: xvfb
          image: registry.example.com/ci/xvfb:1.21.1-r4
          imagePullPolicy: IfNotPresent
          command: ["/usr/bin/Xvfb"]
          args:
            - ":99"
            - "-screen"
            - "0"
            - "1920x1080x24"
            - "-nolisten"
            - "tcp"
            - "-dpi"
            - "96"
            - "+extension"
            - "GLX"
            - "+extension"
            - "RANDR"
            - "+extension"
            - "RENDER"
            - "-noreset"
          volumeMounts:
            - name: x11-socket
              mountPath: /tmp/.X11-unix
            - name: xauth
              mountPath: /tmp/.xauth
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          startupProbe:
            exec:
              command: ["/usr/bin/xdpyinfo", "-display", ":99"]
            initialDelaySeconds: 1
            periodSeconds: 2
            failureThreshold: 15
          livenessProbe:
            exec:
              command: ["/usr/bin/xdpyinfo", "-display", ":99"]
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

        - name: runner
          image: registry.example.com/ci/playwright:1.44.0
          envFrom:
            - configMapRef:
                name: xvfb-config
          env:
            - name: LIBGL_ALWAYS_SOFTWARE
              value: "1"
            - name: GALLIUM_DRIVER
              value: "llvmpipe"
          volumeMounts:
            - name: x11-socket
              mountPath: /tmp/.X11-unix
            - name: xauth
              mountPath: /tmp/.xauth
            - name: dshm
              mountPath: /dev/shm
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "2"
              memory: 4Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]

        # Debug-only: attach a VNC view of the virtual screen.
        # Keep replicas of this Deployment inside a private namespace.
        - name: x11vnc
          image: registry.example.com/ci/x11vnc:0.9.16-r2
          args:
            - "-display"
            - ":99"
            - "-forever"
            - "-shared"
            - "-localhost"
            - "-rfbport"
            - "5900"
            - "-nopw"
          ports:
            - name: vnc
              containerPort: 5900
          volumeMounts:
            - name: x11-socket
              mountPath: /tmp/.X11-unix
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

`-localhost` on `x11vnc` plus no Service for port 5900 means the debug view is reachable only through `kubectl port-forward` — the pod never exposes an unauthenticated framebuffer on the cluster network.

### 3.9 Minimal Xvfb image

```dockerfile
FROM debian:12-slim

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xvfb \
        x11-utils \
        xauth \
        libgl1-mesa-dri \
        libglx-mesa0 \
        fonts-dejavu-core \
        fonts-liberation; \
    rm -rf /var/lib/apt/lists/*; \
    install -d -m 1777 /tmp/.X11-unix

RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin xvfb
USER 1000:1000

ENV DISPLAY=:99
ENTRYPOINT ["/usr/bin/Xvfb"]
CMD [":99", "-screen", "0", "1920x1080x24", "-nolisten", "tcp", "-noreset"]
```

---

## 4. Command line: real invocations and real output

### 4.1 Identify the session and the server

```
$ echo "$DISPLAY $XAUTHORITY $XDG_SESSION_TYPE"
:0 /run/user/1000/gdm/Xauthority x11

$ loginctl list-sessions
SESSION  UID USER     SEAT  TTY
      2 1000 dalmine  seat0 tty2
      c1  120 gdm      seat0 tty1

2 sessions listed.

$ loginctl show-session 2 -p Type -p Class -p Active -p Display
Type=x11
Class=user
Active=yes
Display=:0

$ systemctl status display-manager.service --no-pager | head -4
● gdm.service - GNOME Display Manager
     Loaded: loaded (/usr/lib/systemd/system/gdm.service; enabled; preset: enabled)
     Active: active (running) since Wed 2026-08-26 08:11:44 -03; 6h 2min ago
   Main PID: 1188 (gdm)
```

### 4.2 Inspect the display

```
$ xdpyinfo | head -20
name of display:    :0
version number:    11.0
vendor string:    The X.Org Foundation
vendor release number:    12101011
X.Org version: 21.1.11
maximum request size:  16777212 bytes
motion buffer size:  256
bitmap unit, bit order, padding:    32, LSBFirst, 32
image byte order:    LSBFirst
number of supported pixmap formats:    7
supported pixmap formats:
    depth 1, bits_per_pixel 1, scanline_pad 32
    depth 4, bits_per_pixel 8, scanline_pad 32
    depth 8, bits_per_pixel 8, scanline_pad 32
    depth 15, bits_per_pixel 16, scanline_pad 32
    depth 16, bits_per_pixel 16, scanline_pad 32
    depth 24, bits_per_pixel 32, scanline_pad 32
    depth 32, bits_per_pixel 32, scanline_pad 32
keycode range:    minimum 8, maximum 255
focus:  window 0x4000007, revert to Parent

$ xdpyinfo | grep -E 'dimensions|resolution|depth of root'
  dimensions:    3840x1080 pixels (1016x286 millimeters)
  resolution:    96x96 dots per inch
  depth of root window:    24 planes

$ xdpyinfo -queryExtensions | grep -E '^(RANDR|GLX|Composite|XTEST|SECURITY|DRI3|XKEYBOARD)'
RANDR  (opcode: 140, base event: 89, base error: 147)
GLX  (opcode: 152, base event: 95, base error: 158)
Composite  (opcode: 142)
XTEST  (opcode: 130)
SECURITY  (opcode: 137, base event: 96, base error: 166)
DRI3  (opcode: 149)
XKEYBOARD  (opcode: 135, base event: 85, base error: 137)
```

### 4.3 Outputs and modes with RandR

```
$ xrandr --query
Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 344mm x 194mm
   1920x1080     60.02*+  60.01    59.97    59.96    59.93
   1680x1050     59.95    59.88
   1280x1024     60.02
   1024x768      60.04    60.00
HDMI-1 connected 1920x1080+1920+0 (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1080     60.00*+  50.00    59.94
   1680x1050     59.88
   1280x720      60.00    50.00    59.94
DP-1 disconnected (normal left inverted right x axis y axis)
DP-2 disconnected (normal left inverted right x axis y axis)

$ xrandr --output HDMI-1 --mode 1920x1080 --rate 60 --right-of eDP-1 --primary

$ xrandr --output HDMI-1 --off
```

Adding a mode the EDID never advertised (typical with KVM switches and long HDMI runs):

```
$ cvt 2560 1440 60
# 2560x1440 59.96 Hz (CVT 3.69M9) hsync: 89.52 kHz; pclk: 312.25 MHz
Modeline "2560x1440_60.00"  312.25  2560 2752 3024 3488  1440 1443 1448 1493 -hsync +vsync

$ xrandr --newmode "2560x1440_60.00" 312.25 2560 2752 3024 3488 1440 1443 1448 1493 -hsync +vsync
$ xrandr --addmode DP-1 "2560x1440_60.00"
$ xrandr --output DP-1 --mode "2560x1440_60.00"
```

### 4.4 Server preferences: `xset`

```
$ xset q
Keyboard Control:
  auto repeat:  on    key click percent:  0    LED mask:  00000002
  XKB indicators:
    00: Caps Lock:   off    01: Num Lock:    on     02: Scroll Lock: off
  auto repeat delay:  500    repeat rate:  33
  bell percent:  50    bell pitch:  400    bell duration:  100
Pointer Control:
  acceleration:  2/1    threshold:  4
Screen Saver:
  prefer blanking:  yes    allow exposures:  yes
  timeout:  600    cycle:  600
Colors:
  default colormap:  0x20    BlackPixel:  0x0    WhitePixel:  0xffffff
Font Path:
  /usr/share/fonts/X11/misc,/usr/share/fonts/X11/Type1,built-ins
DPMS (Display Power Management Signaling):
  Standby: 600    Suspend: 900    Off: 1200
  DPMS is Enabled
  Monitor is On

# Kiosk/signage: never blank the panel
$ xset s off -dpms
$ xset s noblank

# Add a legacy core font directory at runtime
$ xset +fp /usr/share/fonts/X11/100dpi
$ xset fp rehash
```

### 4.5 Authorization

```
$ xauth list
workstation/unix:0  MIT-MAGIC-COOKIE-1  8f4c0b2e1a9d47f3b5c6e8d0a1234567
workstation/unix:10 MIT-MAGIC-COOKIE-1  b71ee9c4a05f3d82e6114c7fa9930bc2

$ xauth -f /run/user/1000/gdm/Xauthority list
workstation/unix:0  MIT-MAGIC-COOKIE-1  8f4c0b2e1a9d47f3b5c6e8d0a1234567

# Hand the cookie for :0 to another local account, safely
$ xauth extract - "$DISPLAY" | sudo -u builder env XAUTHORITY=/home/builder/.Xauthority xauth merge -
$ sudo -u builder env DISPLAY=:0 XAUTHORITY=/home/builder/.Xauthority xdpyinfo | head -1
name of display:    :0

# Mint a fresh, time-limited, untrusted cookie
$ xauth generate :0 . untrusted timeout 600

# Remove a stale entry after a server restart
$ xauth remove :0

# Host-based access — shown for completeness; do not use
$ xhost
access control enabled, only authorized clients can connect
$ xhost +si:localuser:builder
localuser:builder being added to access control list
```

### 4.6 Input devices and keymap

```
$ xinput list
⎡ Virtual core pointer                        id=2    [master pointer  (3)]
⎜   ↳ Virtual core XTEST pointer              id=4    [slave  pointer  (2)]
⎜   ↳ SynPS/2 Synaptics TouchPad              id=12   [slave  pointer  (2)]
⎜   ↳ Logitech USB Receiver Mouse             id=15   [slave  pointer  (2)]
⎣ Virtual core keyboard                       id=3    [master keyboard (2)]
    ↳ Virtual core XTEST keyboard             id=5    [slave  keyboard (3)]
    ↳ AT Translated Set 2 keyboard            id=11   [slave  keyboard (3)]
    ↳ Video Bus                               id=8    [slave  keyboard (3)]

$ xinput list-props 12 | head -12
Device 'SynPS/2 Synaptics TouchPad':
        Device Enabled (191):   1
        Coordinate Transformation Matrix (193): 1.000000, 0.000000, 0.000000, 0.000000, 1.000000, 0.000000, 0.000000, 0.000000, 1.000000
        libinput Tapping Enabled (330): 1
        libinput Tapping Enabled Default (331):  0
        libinput Natural Scrolling Enabled (334): 1
        libinput Accel Speed (338): 0.300000
        libinput Accel Profile Enabled (342): 1, 0

$ setxkbmap -query
rules:      evdev
model:      pc105
layout:     us,es
variant:    intl,
options:    grp:alt_shift_toggle,terminate:ctrl_alt_bksp

$ localectl status
   System Locale: LANG=en_US.UTF-8
       VC Keymap: us
      X11 Layout: us,es
       X11 Model: pc105
     X11 Variant: intl,
     X11 Options: grp:alt_shift_toggle,terminate:ctrl_alt_bksp

$ sudo localectl set-x11-keymap us,es pc105 intl, grp:alt_shift_toggle
$ cat /etc/X11/xorg.conf.d/00-keyboard.conf
# Written by systemd-localed(8), read by systemd-localed and Xorg. It's
# probably wise not to edit this file manually. Use localectl(1) to
# instruct systemd-localed to update it.
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "us,es"
        Option "XkbModel" "pc105"
        Option "XkbVariant" "intl,"
        Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
```

### 4.7 Rendering stack

```
$ glxinfo -B
name of display: :0
display: :0  screen: 0
direct rendering: Yes
Extended renderer info (GLX_MESA_query_renderer):
    Vendor: Intel (0x8086)
    Device: Mesa Intel(R) UHD Graphics 620 (KBL GT2) (0x5917)
    Version: 23.2.1
    Accelerated: yes
    Video memory: 15774MB
    Unified memory: yes
    Preferred profile: core (0x1)
    Max core profile version: 4.6
    Max compat profile version: 4.6
OpenGL vendor string: Intel
OpenGL renderer string: Mesa Intel(R) UHD Graphics 620 (KBL GT2)
OpenGL core profile version string: 4.6 (Core Profile) Mesa 23.2.1-1

# Software fallback inside a container without /dev/dri
$ LIBGL_ALWAYS_SOFTWARE=1 glxinfo -B | grep -E 'renderer|direct'
direct rendering: Yes
OpenGL renderer string: llvmpipe (LLVM 15.0.6, 256 bits)
```

### 4.8 Sockets, listeners, clients

```
$ ls -l /tmp/.X11-unix/
total 0
srwxrwxrwx. 1 root root 0 Aug 26 08:11 X0
srwxrwxrwx. 1 ci   ci   0 Aug 26 09:03 X99

$ ss -ltnp | grep -E ':60[0-9][0-9]'
LISTEN 0  128  127.0.0.1:6010  0.0.0.0:*  users:(("sshd",pid=48211,fd=9))

$ sudo lsof /tmp/.X11-unix/X0 | head -5
COMMAND    PID    USER   FD   TYPE             DEVICE SIZE/OFF     NODE NAME
Xorg      1402     ci    1u  unix 0x0000000012a4f100      0t0    31245 /tmp/.X11-unix/X0
firefox   3311 dalmine   38u  unix 0x0000000018bb2c40      0t0    41902 /tmp/.X11-unix/X0

$ xlsclients -l | head -8
Window 0x2c00003:
  Machine:  workstation
  Name:  Alacritty
  Icon Name:  Alacritty
  Class:  Alacritty
Window 0x3200005:
  Machine:  workstation
  Name:  Mozilla Firefox
```

### 4.9 Headless verification end to end

```
$ Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp -noreset &
[1] 20144

$ DISPLAY=:99 xdpyinfo | grep -E 'name of display|dimensions|depths'
name of display:    :99
  dimensions:    1920x1080 pixels (487x274 millimeters)
  depths (7):    24, 1, 4, 8, 15, 16, 32

$ DISPLAY=:99 xrandr --query
Screen 0: minimum 1920 x 1080, current 1920 x 1080, maximum 1920 x 1080
default connected 1920x1080+0+0 0mm x 0mm
   1920x1080     0.00*

$ xvfb-run -a --server-args="-screen 0 1280x1024x24 -nolisten tcp" \
      /opt/app/run-ui-tests.sh
Running 42 tests using 4 workers
  42 passed (1.4m)

$ DISPLAY=:99 xwd -root -silent | convert xwd:- /tmp/screen.png
$ identify /tmp/screen.png
/tmp/screen.png PNG 1920x1080 1920x1080+0+0 8-bit sRGB 12.4KB 0.000u 0:00.000
```

### 4.10 Forwarding

```
$ ssh -X ops@buildhost 'echo $DISPLAY; xdpyinfo | head -1'
localhost:10.0
name of display:    localhost:10.0

$ ssh -v -X ops@buildhost xterm 2>&1 | grep -i x11
debug1: Requesting X11 forwarding with authentication spoofing.
debug1: Requesting authentication agent forwarding.

# Verbose sshd side, when it fails:
$ sudo journalctl -u sshd -n 5 --no-pager
Aug 26 14:02:11 buildhost sshd[52011]: error: Failed to allocate internet-domain X11 display socket.
```

---

## 5. Verification and failure diagnosis

### 5.1 Validate a configuration change *before* it costs you the session

X.Org has **no offline syntax checker**. Restarting the display manager to test an `xorg.conf.d` fragment risks locking out every logged-in user. The safe procedure:

```
# 1. Parse-check by starting a throwaway server on a spare VT and display
$ sudo Xorg :3 vt9 -config /etc/X11/xorg.conf -configdir /etc/X11/xorg.conf.d \
        -logfile /tmp/Xorg.3.log -novtswitch -noreset &

# 2. Prove it came up
$ DISPLAY=:3 xdpyinfo | head -1
name of display:    :3

# 3. Read only the interesting lines
$ grep -E '\((EE|WW)\)' /tmp/Xorg.3.log
[   112.884] (WW) The directory "/usr/share/fonts/X11/cyrillic" does not exist.
[   112.884] (WW) Warning, couldn't open module "nv"

# 4. Tear it down
$ sudo pkill -f 'Xorg :3'
```

Legacy generator, still examinable — it must run with **no X server active** and as root, and it writes to the current directory:

```
$ sudo systemctl isolate multi-user.target
$ sudo Xorg -configure
Number of created screens does not match number of detected devices.
  Configuration failed.
$ ls -l /root/xorg.conf.new
```

(`Xorg -configure` failing on a modern KMS system is normal, not a fault — hand-write a drop-in instead.)

### 5.2 Reading the log

Location depends on whether Xorg runs as root:

| Situation | Log path |
|---|---|
| Root-run Xorg (legacy, or `needs_root_rights=yes`) | `/var/log/Xorg.<display>.log` |
| Rootless Xorg (modern default) | `~/.local/share/xorg/Xorg.<display>.log` |
| Under a display manager, pre-login | `/var/log/Xorg.0.log` or the greeter user's home |
| Under systemd unit / container | unit journal or `-logfile` target |

Line markers:

| Marker | Meaning |
|---|---|
| `(--)` | Probed from hardware |
| `(**)` | From the configuration file |
| `(==)` | Default value |
| `(++)` | From the command line |
| `(II)` | Informational |
| `(WW)` | Warning — usually survivable |
| `(EE)` | **Error** — start here |
| `(NI)` | Not implemented |
| `(??)` | Unknown |

Fast triage:

```
$ grep -E '\(EE\)' ~/.local/share/xorg/Xorg.0.log
[    32.398] (EE) Failed to load module "nvidia" (module does not exist, 0)
[    33.021] (EE) No devices detected.
[    33.022] (EE) Screen(s) found, but none have a usable configuration.
[    33.022] (EE) Fatal server error:
[    33.022] (EE) no screens found(EE)
[    33.022] (EE) Please consult the The X.Org Foundation support at http://wiki.x.org
[    33.022] (EE) Please also check the log file at "/home/ci/.local/share/xorg/Xorg.0.log"

$ grep -E 'Loading|LoadModule' ~/.local/share/xorg/Xorg.0.log | tail -6
[    31.902] (II) LoadModule: "modesetting"
[    31.903] (II) Loading /usr/lib/xorg/modules/drivers/modesetting_drv.so
[    31.910] (II) LoadModule: "libinput"
[    31.911] (II) Loading /usr/lib/xorg/modules/input/libinput_drv.so
```

### 5.3 The `Can't open display` decision tree

Every X connection failure produces one of five distinguishable messages. Match the message, not the symptom.

| Message | Root cause | Fix |
|---|---|---|
| `Error: Can't open display:` (empty) | `DISPLAY` is unset | `export DISPLAY=:0` — and find out why the session env is missing (cron, systemd unit, `su -`) |
| `Can't open display: :0` with a running server | The client cannot reach the socket (namespace, `PrivateTmp=yes`, container without the socket mounted) | Mount `/tmp/.X11-unix`; drop `PrivateTmp` |
| `Authorization required, but no authorization protocol specified` | No cookie found — `XAUTHORITY` unset or unreadable by this UID | `export XAUTHORITY=/run/user/$(id -u)/gdm/Xauthority`, or `xauth merge` for the target user |
| `Invalid MIT-MAGIC-COOKIE-1 key` | A cookie exists but is stale (server restarted) or belongs to another display | `xauth remove :0 && xauth generate :0 .` |
| `X11 connection rejected because of wrong authentication` | SSH forwarding path is broken | See 5.5 |
| `connect /tmp/.X11-unix/X0: Connection refused` | No server on that display number | `pgrep -a Xorg\|Xvfb`; check the unit |

Diagnostic sequence:

```
$ echo "DISPLAY=[$DISPLAY] XAUTHORITY=[$XAUTHORITY]"
DISPLAY=[:0] XAUTHORITY=[]

$ pgrep -a 'Xorg|Xwayland|Xvfb'
1402 /usr/lib/xorg/Xorg vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority -background none -noreset -keeptty -novtswitch -verbose 3

# The -auth argument on the running server IS the authoritative cookie path
$ export XAUTHORITY=/run/user/1000/gdm/Xauthority
$ xdpyinfo | head -1
name of display:    :0
```

### 5.4 `sudo` and `su` lose the display

```
$ sudo xclock
No protocol specified
Error: Can't open display: :0
```

The environment kept `DISPLAY` but root cannot read your cookie file (or `env_reset` dropped `XAUTHORITY` entirely). Three correct fixes, in order of preference:

```
# 1) Don't run GUI apps as root. Use pkexec / polkit for the privileged action only.
$ pkexec /usr/sbin/gparted

# 2) Pass the cookie explicitly, one command, no persistent grant
$ sudo env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" xclock

# 3) Allow the target local UID at the server, then revoke
$ xhost +si:localuser:root
localuser:root being added to access control list
$ sudo xclock
$ xhost -si:localuser:root
```

`xhost +local:` or `xhost +` "fix" the symptom by disabling access control entirely — flag this in code review.

### 5.5 SSH X11 forwarding failure ladder

Test each rung; the first failure is the cause.

```
# Rung 1 — is forwarding on at the server?
$ ssh ops@buildhost 'sudo sshd -T | grep -Ei "x11forwarding|x11displayoffset|x11uselocalhost"'
x11forwarding yes
x11displayoffset 10
x11uselocalhost yes

# Rung 2 — is xauth installed on the server? sshd shells out to it.
$ ssh ops@buildhost 'command -v xauth || echo MISSING'
/usr/bin/xauth

# Rung 3 — did the client actually request forwarding?
$ ssh -X -v ops@buildhost true 2>&1 | grep -i 'X11 forwarding'
debug1: Requesting X11 forwarding with authentication spoofing.

# Rung 4 — is DISPLAY set inside the remote session?
$ ssh -X ops@buildhost 'echo ${DISPLAY:-UNSET}'
localhost:10.0

# Rung 5 — does the remote proxy have a cookie?
$ ssh -X ops@buildhost 'xauth list'
buildhost/unix:10  MIT-MAGIC-COOKIE-1  4bd11a95e30fc7268a5f0912de37cc41

# Rung 6 — does a client actually connect?
$ ssh -X ops@buildhost 'xdpyinfo | head -1'
name of display:    localhost:10.0
```

Failure signatures:

| Symptom | Cause |
|---|---|
| `DISPLAY` is UNSET, sshd log says `Failed to allocate internet-domain X11 display socket` | `AddressFamily inet6`/IPv6 disabled mismatch, or ports 6010+ already taken; also seen when `X11UseLocalhost no` and no address to bind |
| Forwarding works for 20 minutes then dies | `ForwardX11Timeout` (default `20m`) expired the untrusted cookie — use `ssh -Y` deliberately, or raise the timeout |
| `BadAccess (attempt to access private resource denied)` from a specific app | Untrusted mode (`-X`) blocking `XTEST`/`XRECORD`/`Composite` — the app needs `-Y` |
| Works as your user, fails after `sudo -i` on the remote | Same cookie-ownership problem as 5.4, on the far side |

### 5.6 The session starts and immediately dies

```
$ tail -30 ~/.xsession-errors
/etc/X11/Xsession.d/40x11-common_xsessionrc: line 8: /home/dalmine/.xsessionrc: Permission denied
localuser:dalmine being added to access control list
openConnection: connect: No such file or directory
cannot connect to brltty at :0
gnome-session-binary[4102]: WARNING: Could not parse desktop file custom.desktop
gnome-session-binary[4102]: CRITICAL: We failed, but the fail whale is dead. Sorry....
```

Checklist:

1. `~/.xsession-errors` — session-level scripts and DE crashes.
2. `journalctl -b -u gdm` (or `lightdm`/`sddm`) — greeter and PAM failures.
3. `journalctl -b _COMM=gnome-shell` — compositor crashes.
4. `ls -ld ~ ~/.Xauthority ~/.config` — a home directory owned by the wrong UID, or full, breaks login in exactly this way.
5. `df -h ~ && quota -s` — a full `$HOME` cannot write `.Xauthority`; login loops silently.
6. Reproduce with a minimal session: `startx /usr/bin/xterm -- :2 vt9` — if bare `xterm` works, the fault is in the DE, not in X.

### 5.7 No screens / wrong resolution

```
$ grep -E 'Output|EDID|Modeline|no screens' ~/.local/share/xorg/Xorg.0.log | head
[    31.940] (II) modeset(0): Output HDMI-1 has no monitor section
[    31.941] (II) modeset(0): EDID for output HDMI-1
[    31.941] (II) modeset(0): Manufacturer: DEL  Model: a0f9  Serial#: 1178867256
[    31.942] (II) modeset(0): Printing probed modes for output HDMI-1
[    31.942] (II) modeset(0): Modeline "1920x1080"x60.0  148.50 ...

# Read the raw EDID when the log is unhelpful
$ sudo find /sys/class/drm -name edid -exec sh -c 'echo "== $1"; wc -c < "$1"' _ {} \;
== /sys/class/drm/card0-eDP-1/edid
256
== /sys/class/drm/card0-HDMI-A-1/edid
0

# Zero bytes = no EDID (KVM, long cable, dead adapter). Force a mode:
$ xrandr --newmode "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
$ xrandr --addmode HDMI-1 "1920x1080_60.00"
```

Permanent form: a `Monitor` section with `Option "CustomEDID" "HDMI-1:/etc/X11/edid.bin"` on the `Device`, or explicit `Modeline` + `Modes` in `Screen`.

### 5.8 Container-specific failures

| Symptom | Cause | Fix |
|---|---|---|
| `Can't open display :99` from the app container, Xvfb healthy | `/tmp/.X11-unix` not shared between containers | Shared `emptyDir` mounted at `/tmp/.X11-unix` in both |
| Chromium tabs crash, `Failed to move to new namespace` / `SIGBUS` | `/dev/shm` is the 64 Mi default | `emptyDir: {medium: Memory, sizeLimit: 2Gi}` at `/dev/shm` |
| `Xlib: extension "GLX" missing on display ":99"` | Xvfb started without `+extension GLX`, or no Mesa in the image | Add the flag *and* `libgl1-mesa-dri`; set `LIBGL_ALWAYS_SOFTWARE=1` |
| Tests pass locally, blank screenshots in CI | Server reset when the last client exited | `-noreset` |
| Fonts render as boxes | No fonts in the image | Install `fonts-dejavu-core` + `fontconfig`, run `fc-cache -f` |
| Server dies after the first job | Xvfb as PID 1 with no signal handling | Run it under an init (`tini`) or as a sidecar with a probe |

### 5.9 Verification checklist — a change is done when all of these pass

```
$ grep -c '(EE)' ~/.local/share/xorg/Xorg.0.log          # → 0
0
$ xdpyinfo >/dev/null && echo "display OK"
display OK
$ xrandr --query | grep -c ' connected '                 # matches expected outputs
2
$ setxkbmap -query | grep -E 'layout|variant'            # matches policy
layout:     us,es
variant:    intl,
$ localectl status | grep -E 'VC Keymap|X11 Layout'      # console and X agree
       VC Keymap: us
     X11 Layout: us,es
$ xhost | head -1                                        # access control must be ENABLED
access control enabled, only authorized clients can connect
$ xset q | grep -A2 '^DPMS'                              # power policy as intended
  Standby: 0    Suspend: 0    Off: 0
  DPMS is Disabled
$ glxinfo -B | grep -E 'direct rendering|renderer'       # accel path as intended
direct rendering: Yes
OpenGL renderer string: Mesa Intel(R) UHD Graphics 620 (KBL GT2)
$ ss -ltn | grep -c ':6000'                              # → 0: no TCP listener
0
```

The last check is the one that matters for security review: **an X server listening on `6000/tcp` is a network-reachable keylogger** unless it is firewalled and cookie-protected, and the cookie crosses the wire in plaintext regardless.

---

## 6. Exam alignment (LPIC-1 v5.0, objective 106.1)

| Objective knowledge area | Where it is covered here |
|---|---|
| Basic understanding of X11 architecture | §2.1, §2.2 — inverted client/server, DIX/DDX, WM vs DE vs DM |
| Understanding of the X Window configuration file | §2.4, §3.1–§3.4 — section types, search order |
| Overwrite specific aspects of Xorg configuration (e.g. keyboard layout) | §3.1, §4.6 — `InputClass`, `localectl set-x11-keymap`, `setxkbmap` |
| Components of desktop environments (display managers, window managers) | §2.1, §2.3, §4.1 |
| Awareness of Wayland | §2.8 — compositor model, XWayland, `XDG_SESSION_TYPE` |

**Terms and utilities to have at your fingertips:** `/etc/X11/xorg.conf`, `/etc/X11/xorg.conf.d/`, `~/.xsession-errors`, `xhost`, `xauth`, `X`, `DISPLAY`.

---

## Referencias

**LPI — objectives**
- LPIC-1 Exam 101-500 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102-500 objectives (topic 106 lives here) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**X.Org Foundation — upstream documentation and manual pages**
- X.Org project — https://www.x.org/wiki/
- `Xorg(1)` — https://www.x.org/releases/current/doc/man/man1/Xorg.1.xhtml
- `xorg.conf(5)` — https://www.x.org/releases/current/doc/man/man5/xorg.conf.5.xhtml
- `Xserver(1)` (common server options, `-nolisten`, `-auth`) — https://www.x.org/releases/current/doc/man/man1/Xserver.1.xhtml
- `xinit(1)` — https://www.x.org/releases/current/doc/man/man1/xinit.1.xhtml
- `startx(1)` — https://www.x.org/releases/current/doc/man/man1/startx.1.xhtml
- `xauth(1)` — https://www.x.org/releases/current/doc/man/man1/xauth.1.xhtml
- `xhost(1)` — https://www.x.org/releases/current/doc/man/man1/xhost.1.xhtml
- `Xsecurity(7)` (authorization mechanisms) — https://www.x.org/releases/current/doc/man/man7/Xsecurity.7.xhtml
- `Xvfb(1)` — https://www.x.org/releases/current/doc/man/man1/Xvfb.1.xhtml
- `Xephyr(1)` — https://www.x.org/releases/current/doc/man/man1/Xephyr.1.xhtml
- `xrandr(1)` — https://www.x.org/releases/current/doc/man/man1/xrandr.1.xhtml
- `xset(1)` — https://www.x.org/releases/current/doc/man/man1/xset.1.xhtml
- `xdpyinfo(1)` — https://www.x.org/releases/current/doc/man/man1/xdpyinfo.1.xhtml
- X Window System Protocol, version 11 — https://www.x.org/releases/current/doc/xproto/x11protocol.html
- `xorg.conf.d` driver man pages index — https://www.x.org/releases/current/doc/man/

**freedesktop.org**
- Wayland protocol documentation — https://wayland.freedesktop.org/docs/html/
- XWayland — https://wayland.freedesktop.org/xserver.html
- libinput documentation — https://wayland.freedesktop.org/libinput/doc/latest/
- XKeyboardConfig (`xkeyboard-config`) — https://www.freedesktop.org/wiki/Software/XKeyboardConfig/
- fontconfig — https://www.freedesktop.org/wiki/Software/fontconfig/
- `localectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/localectl.html
- `systemd-logind.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-logind.service.html
- `loginctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/loginctl.html
- XDG Base Directory Specification — https://specifications.freedesktop.org/basedir-spec/latest/

**OpenSSH**
- `sshd_config(5)` — https://man.openbsd.org/sshd_config
- `ssh_config(5)` — https://man.openbsd.org/ssh_config
- `ssh(1)` — https://man.openbsd.org/ssh

**Graphics stack**
- Linux kernel DRM/KMS documentation — https://docs.kernel.org/gpu/drm-kms.html
- Mesa 3D documentation — https://docs.mesa3d.org/
- NVIDIA Linux driver README (headless, `AllowEmptyInitialConfiguration`) — https://download.nvidia.com/XFree86/Linux-x86_64/latest/README/

**Desktop and display managers**
- GNOME Display Manager (GDM) — https://help.gnome.org/admin/gdm/stable/
- LightDM — https://github.com/canonical/lightdm
- SDDM — https://github.com/sddm/sddm

**Kubernetes**
- `emptyDir` volumes (memory-backed `/dev/shm`) — https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Pod probes — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes
- Pod security context — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/