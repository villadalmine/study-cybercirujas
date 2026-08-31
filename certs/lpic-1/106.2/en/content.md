# 106.2 — Graphical Desktops

**LPIC-1 · Exam 102-500 · Topic 106 (User Interfaces and Desktops)**
Objective scope: *awareness of major desktop environments* and *awareness of protocols used to access remote desktop sessions*.
Terms and utilities: `KDE`, `GNOME`, `Xfce`, `X11`, `XDMCP`, `VNC`, `Spice`, `RDP`.

This is an awareness-level objective in the exam, but the operational surface behind it — remote graphical sessions on bastion hosts, engineering workstations, hypervisor consoles and containerised desktops — is where a platform team actually gets paged. The material below treats the exam vocabulary as the entry point and then goes to the depth a Platform Architect needs to design, secure and debug that surface.

---

## 1. Motivation: the graphical session as a production workload

Most infrastructure engineers meet graphical Linux only twice: when a laptop's desktop breaks, and when something in the fleet *needs* pixels. The second case is the interesting one, and it is more common than "we run headless servers" suggests:

| Production driver | What is actually required | Why a TTY is not enough |
|---|---|---|
| **Hypervisor break-glass** | Console of a KVM guest whose network stack or `sshd` is dead | The guest cannot serve SSH; you need out-of-band framebuffer access before the OS is reachable |
| **Engineering / EDA / GIS workstations** | GPU-accelerated GUI apps run near the data, on a datacentre box, displayed remotely | Datasets are hundreds of GB; moving pixels is cheaper than moving data |
| **Regulated jump hosts** | A recorded, non-copy-paste desktop inside a segmented zone | Session must be brokered, audited and disposable; a raw shell bypasses the DLP boundary |
| **Vendor / appliance management UIs** | A browser inside the management VLAN | The UI is only reachable from an address that must never be on a laptop |
| **UI / end-to-end test farms** | Ephemeral X server + browser per CI job | Test targets real rendering, not a mocked DOM |
| **Kiosk & digital signage fleets** | Auto-login, single full-screen app, watchdog restart, no session chrome | The "desktop" *is* the product; a crashed compositor is an outage |

The architectural problem in all six rows is the same, and it is not "which desktop is prettiest":

> **A graphical session is a stateful, long-lived, multi-process workload with a hard dependency on a local device seat, an authentication cookie, an IPC bus and a display server socket — and you are asked to make it reachable across a network boundary without turning it into a lateral-movement path.**

Decompose that into the four decisions this objective actually maps to:

1. **Which display server protocol** the session speaks — X11 or Wayland. This decides whether "remote" is a protocol feature or a bolt-on.
2. **Which desktop environment** supplies the compositor, session manager and settings daemon — this decides the dependency surface, the memory floor and whether a remote server is built in.
3. **Which remote access protocol** carries the session — X11 forwarding, XDMCP, VNC, RDP or SPICE. This decides latency behaviour, session persistence, device redirection and encryption defaults.
4. **Which trust boundary** terminates the transport — SSH tunnel, TLS with a real certificate, mTLS ingress, or (the wrong answer) a plaintext port on `0.0.0.0`.

### 1.1 Anatomy of a graphical session (the layer map you debug against)

```
                    ┌───────────────────────────────────────────────┐
  seat0             │  logind (systemd-logind)                      │
  ├─ /dev/dri/card0 │   • allocates SESSION id, seat, VT            │
  ├─ /dev/input/*   │   • grants device access via /dev/dri + udev  │
  └─ VT tty1..N     │   • sets XDG_SESSION_TYPE / XDG_SESSION_CLASS │
                    └───────────────┬───────────────────────────────┘
                                    │ PAM (pam_systemd, pam_keyinit)
                    ┌───────────────▼───────────────┐
                    │ Display Manager               │  gdm / sddm / lightdm / xdm
                    │  greeter session (class=greeter)│  ← XDMCP lives here
                    └───────────────┬───────────────┘
                                    │ exec session script (/etc/X11/Xsession,
                                    │  ~/.xsession, or systemd --user target)
        ┌───────────────────────────▼──────────────────────────────┐
        │ Session bus (D-Bus)  +  systemd --user  +  XDG portals     │
        └───────────────────────────┬──────────────────────────────┘
                                    │
        ┌───────────────────────────▼──────────────────────────────┐
        │ Compositor / Window Manager                               │
        │   GNOME → mutter    KDE → kwin_x11|kwin_wayland           │
        │   Xfce  → xfwm4     minimal → i3/sway/openbox             │
        └───────────────────────────┬──────────────────────────────┘
                                    │  X11: unix:/tmp/.X11-unix/X0
                                    │  Wayland: $XDG_RUNTIME_DIR/wayland-0
        ┌───────────────────────────▼──────────────────────────────┐
        │ Toolkit clients (GTK, Qt) + XWayland for legacy X clients │
        └───────────────────────────────────────────────────────────┘
```

Every failure in section 7 is a break in exactly one of those arrows.

### 1.2 X11 vs Wayland — the decision that constrains every later one

| Property | X11 (Xorg) | Wayland |
|---|---|---|
| Network transparency | **Built into the protocol** — a client can connect to a remote display over TCP | **None** — the protocol is a local Unix socket only |
| Remote access strategy | `ssh -X`, XDMCP, or capture the framebuffer (`x11vnc`) | Compositor must *implement* a server (`gnome-remote-desktop`, `krdp`, `wayvnc`) or export via PipeWire portal |
| Input/screen capture by any client | Yes — any client can read the whole screen and all keystrokes | No — mediated by `xdg-desktop-portal` with user consent |
| Legacy app support | Native | Via **XWayland** (an X server rendering into a Wayland surface) |
| Per-monitor scaling / HDR | Poor (single global DPI in practice) | Native |
| Rootless / unprivileged startup | `Xorg` traditionally needed root or setuid (`Xwrapper.config`) | Compositor runs unprivileged, gets DRM/input via logind |
| Default in current distros | Legacy / fallback session | Default for GNOME and KDE Plasma 6 |

**Operational consequence:** `ssh -X` and `x11vnc` silently stop working the day the fleet flips to Wayland-by-default. A remote-desktop design written against X11 semantics is a migration liability; verify `XDG_SESSION_TYPE` before promising anything.

```console
$ echo "$XDG_SESSION_TYPE"
wayland
$ loginctl show-session "$XDG_SESSION_ID" -p Type -p Class -p Active -p Remote
Type=wayland
Class=user
Active=yes
Remote=no
```

---

## 2. Desktop environments: technical comparison

A "desktop environment" is a bundle of five replaceable components. Knowing the decomposition is what lets you build a 180 MB kiosk image instead of shipping a 2 GB one.

| Component | GNOME | KDE Plasma | Xfce |
|---|---|---|---|
| Toolkit | GTK 4 (+GTK 3 legacy) | Qt 6 (Plasma 6) | GTK 3 (GTK 4 migration in progress) |
| Compositor / WM | `mutter` (X11 + Wayland in one binary) | `kwin_x11` / `kwin_wayland` | `xfwm4` (X11); Wayland preview via `labwc`/`wayfire` in 4.20 |
| Shell / panel | `gnome-shell` (JavaScript on top of mutter) | `plasmashell` (QML) | `xfce4-panel`, `xfdesktop` |
| Session manager | `gnome-session` → `systemd --user` units | `startplasma-x11` / `startplasma-wayland`, `ksmserver` | `xfce4-session` |
| Settings store | `dconf` / GSettings (binary DB, `gsettings` CLI) | `KConfig` INI files under `~/.config/*rc` (`kwriteconfig6`) | `xfconf` (XML under `~/.config/xfce4/xfconf/`) |
| Default display manager | `gdm` | `sddm` | `lightdm` |
| Built-in remote server | `gnome-remote-desktop` (**RDP**, incl. headless) | `krdp` (**RDP**, Plasma 6) | none — pair with TigerVNC or xrdp |

### 2.1 Trade-off matrix for fleet decisions

| Dimension | GNOME | KDE Plasma | Xfce |
|---|---|---|---|
| Idle RSS, fresh session (order of magnitude) | ~1.1–1.5 GB | ~0.9–1.3 GB | ~350–550 MB |
| Package closure (typical distro metapackage) | Largest | Large | Small |
| Wayland maturity | Highest (reference implementation) | High (Plasma 6 defaults to Wayland) | Experimental |
| Policy / lockdown story | **Strongest** — dconf system DB with `/etc/dconf/db/*.d/locks/`, mandatory keys | Kiosk framework (`kiosk` `[KDE Action Restrictions]` in `kdeglobals`) | Weakest — per-user xfconf, no mandatory-lock concept |
| Extensibility risk | GNOME Shell extensions break every release; a bad extension kills the shell | QML plasmoids are sandboxed from the compositor | Panel plugins are C, stable across releases |
| Fit: managed corporate desktop | ✅ dconf locks + GDM policy + built-in RDP | ⚠ workable, more surface to lock | ❌ no mandatory policy layer |
| Fit: containerised / VDI desktop | ❌ needs `systemd --user`, logind, D-Bus — awkward in a container | ⚠ heavy, but works | ✅ **best fit** — starts from a plain `xstartup` script, no logind needed |
| Fit: kiosk / signage | ⚠ heavy; use `gnome-kiosk` | ⚠ heavy | ✅ or drop the DE entirely for a bare WM |
| Fit: GPU workstation (remote) | ✅ RDP + H.264 via `gnome-remote-desktop` | ✅ RDP via `krdp` | ⚠ VNC only → no hardware video encode |

**Architect's rule:** the DE choice is driven by *policy* and *remote-server availability*, not by aesthetics. GNOME wins where you must enforce configuration; Xfce wins where the session must start from a shell script inside a container with no seat and no logind.

### 2.2 Inspecting what is actually running

```console
$ echo "$XDG_CURRENT_DESKTOP  $DESKTOP_SESSION"
GNOME  gnome

$ ps -eo comm,rss --sort=-rss | head -n 8
COMM              RSS
gnome-shell    412336
firefox        298104
gnome-softwar   96420
mutter-x11-fr   61208
gsd-color       38112
tracker-miner   35880
gnome-session-  22964
systemd          14204

$ systemctl --user list-units --type=target --state=active
  UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
  basic.target                loaded active active Basic System
  default.target              loaded active active Main User Target
  gnome-session-initialized.t loaded active active GNOME Session is initialized
  gnome-session-wayland.targe loaded active active GNOME Wayland Session
  graphical-session.target    loaded active active Current graphical user session
  sockets.target              loaded active active Sockets

$ systemctl get-default
graphical.target
```

Switching the boot target — the single most common "the server rebooted into a GUI and OOMed" fix:

```console
# systemctl set-default multi-user.target
Removed "/etc/systemd/system/default.target".
Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/multi-user.target.
# systemctl isolate multi-user.target
```

Listing installed session definitions (what a display manager offers in its menu):

```console
$ ls /usr/share/xsessions/ /usr/share/wayland-sessions/
/usr/share/wayland-sessions/:
gnome.desktop  plasma.desktop

/usr/share/xsessions/:
gnome-xorg.desktop  plasmax11.desktop  xfce.desktop

$ grep -E '^(Name|Exec|DesktopNames)=' /usr/share/xsessions/xfce.desktop
Name=Xfce Session
Exec=startxfce4
DesktopNames=XFCE
```

---

## 3. Remote desktop protocols: mechanics and trade-offs

### 3.1 X11 forwarding (the protocol-native path)

X11 is a **client/server protocol where the server owns the display and the client is the application** — the naming is inverted relative to every other protocol in this list. Because it is network-transparent, an application on host B can render on the X server of host A. Raw TCP transport listens on **port 6000 + display number**, but every modern Xorg starts with `-nolisten tcp`, so the practical transport is an SSH channel.

Authorisation is a per-display shared secret, **MIT-MAGIC-COOKIE-1**, stored in `~/.Xauthority` (or `$XAUTHORITY`).

```console
$ ss -lntp | grep -E ':600[0-9]'      # nothing: -nolisten tcp is the default
$ xauth list
workstation/unix:0  MIT-MAGIC-COOKIE-1  3a9f1e4c2b7d8e6f0a1b2c3d4e5f6a7b

$ ssh -X build-node-07
Last login: Tue Aug 25 09:14:02 2026 from 10.42.7.11
$ echo "$DISPLAY"
localhost:10.0
$ xauth list
build-node-07/unix:10  MIT-MAGIC-COOKIE-1  1f0c4e5a9b8d7c6e5f4a3b2c1d0e9f8a
$ xlsclients
build-node-07  xterm
$ xdpyinfo | sed -n '1,6p'
name of display:    localhost:10.0
version number:    11.0
vendor string:    The X.Org Foundation
vendor release number:    12101014
X.Org version: 21.1.14
maximum request size:  16777212 bytes
```

`-X` vs `-Y` is a security decision, not a compatibility toggle:

| Flag | X security extension | Consequence |
|---|---|---|
| `ssh -X` | **Untrusted** — client is restricted, screenshots/keylogging of other windows denied, connection expires after `ForwardX11Timeout` (default 20 min) | Some apps crash with `BadAccess`; safe against a hostile remote host |
| `ssh -Y` | **Trusted** — full access to your local display | A compromised remote host can read your entire screen and every keystroke. Never to an untrusted host. |
| `xhost +` | Disables authorisation entirely | Any host on the network can open windows and grab input. Treat as a P1 finding. |

**Latency model:** X11 is request/reply with many round trips per UI operation. Over a 100 ms RTT link a modern GTK/Qt app is unusable; over <5 ms LAN it is excellent, and it is the only option that gives true single-window (seamless) remoting without a whole desktop.

### 3.2 XDMCP — remote *login*, not remote *desktop*

**X Display Manager Control Protocol**, **UDP port 177**. Inverts the usual direction: a local X server asks a remote display manager for a login greeter, and the whole session then runs on the remote host, painting to the local X server over the X wire protocol.

Cardinal facts: **XDMCP is unencrypted, unauthenticated at the transport level, and X11-only** — it cannot serve a Wayland session. It is a legacy thin-client protocol. Enable it only inside an isolated management VLAN, or better, don't.

```ini
# /etc/gdm/custom.conf — GDM as an XDMCP server
[daemon]
WaylandEnable=false          # mandatory: XDMCP requires an Xorg session

[security]
DisallowTCP=false

[xdmcp]
Enable=true
Port=177
MaxSessions=8
MaxPending=4
DisplaysPerHost=2
```

```ini
# /etc/lightdm/lightdm.conf — LightDM equivalent
[XDMCPServer]
enabled=true
port=177
```

Client side:

```console
$ Xephyr -query dm.mgmt.internal -screen 1280x800 :3 &
$ X -broadcast :2                       # discover any DM on the local segment
$ X -indirect chooser.mgmt.internal :2  # ask a chooser host for a host list
```

```console
# ss -lnup | grep :177
udp   UNCONN 0  0     0.0.0.0:177    0.0.0.0:*    users:(("gdm",pid=1188,fd=9))
```

### 3.3 VNC — RFB, the framebuffer lowest common denominator

**Remote Framebuffer protocol.** Listens on **TCP 5900 + display number** (`:1` → 5901). It ships rectangles of pixels plus input events; it knows nothing about windows, so it is universal, simple and comparatively bandwidth-hungry.

Two deployment modes, and confusing them is the classic outage:

| Mode | Server | Semantics |
|---|---|---|
| **Virtual desktop** | `Xvnc` (TigerVNC), started by `vncserver` | Creates a **new, headless** X server. The physical console is untouched. Session survives client disconnect. This is the VDI mode. |
| **Screen scraping** | `x11vnc`, `wayvnc` | Attaches to an **existing** display (`:0`) and mirrors it. This is the remote-support mode. `x11vnc` cannot capture a Wayland session; `wayvnc` works only with wlroots compositors. |

Security types (RFB 3.8): `None`, `VncAuth` (challenge/response over a **password truncated to 8 characters** — weak, must never be exposed), `TLSVnc`/`TLSPlain` and `X509Vnc` (VeNCrypt). **The safe default is `-localhost` plus an SSH tunnel or a TLS-terminating reverse proxy.**

```ini
# /etc/tigervnc/vncserver.users  — maps display numbers to accounts
:1=sre-ops
:2=eda-tools
```

```ini
# ~/.vnc/config  — per-user session parameters
session=xfce
geometry=1920x1080
depth=24
localhost
alwaysshared
SecurityTypes=VncAuth
```

```console
$ vncpasswd
Password:
Verify:
Would you like to enter a view-only password (y/n)? n
$ ls -l ~/.vnc/passwd
-rw------- 1 sre-ops sre-ops 8 Aug 25 10:02 /home/sre-ops/.vnc/passwd

# systemctl enable --now vncserver@:1.service
Created symlink /etc/systemd/system/multi-user.target.wants/vncserver@:1.service → /usr/lib/systemd/system/vncserver@.service.

# systemctl status vncserver@:1.service --no-pager
● vncserver@:1.service - Remote desktop service (VNC)
     Loaded: loaded (/usr/lib/systemd/system/vncserver@.service; enabled)
     Active: active (running) since Tue 2026-08-25 10:03:11 -03; 12s ago
   Main PID: 4198 (vncsession)
      Tasks: 78 (limit: 18936)
     Memory: 412.7M
        CPU: 6.114s
     CGroup: /system.slice/system-vncserver.slice/vncserver@:1.service
             ├─4198 /usr/sbin/vncsession sre-ops :1
             ├─4211 /usr/bin/Xvnc :1 -auth /home/sre-ops/.Xauthority -desktop ...
             ├─4260 xfce4-session
             └─4288 xfwm4

$ ss -lntp | grep 590
tcp   LISTEN 0  5   127.0.0.1:5901   0.0.0.0:*   users:(("Xvnc",pid=4211,fd=8))
```

Connect over an SSH tunnel — the only acceptable exposure for `VncAuth`:

```console
$ ssh -N -L 5901:127.0.0.1:5901 sre-ops@vdi-01.mgmt.internal &
$ vncviewer 127.0.0.1:5901
TigerVNC Viewer 64-bit v1.14.1
Built on: 2026-03-04 09:11
Tue Aug 25 10:05:44 2026
 DecodeManager: Detected 8 CPU core(s)
 CConn:         Connected to host 127.0.0.1 port 5901
 CConnection:   Server supports RFB protocol version 3.8
 CConnection:   Using RFB protocol version 3.8
 CConnection:   Choosing security type VncAuth(2)
 CConn:         Using pixel format depth 24 (32bpp) little-endian rgb888
 CConn:         Enabling continuous updates
```

### 3.4 RDP — the one with real device redirection

**Remote Desktop Protocol**, **TCP 3389** (UDP 3389 for the optional low-latency transport). Unlike RFB it is a multiplexed **virtual channel** protocol: display, input, clipboard, audio in/out, drive redirection, printers, smartcards and USB each ride a separate channel. It negotiates TLS (and optionally NLA/CredSSP for pre-authentication) as part of the handshake, and supports hardware-accelerated H.264/AVC444 codecs.

Linux server implementations:

| Server | Backend | Notes |
|---|---|---|
| **xrdp** + `xorgxrdp` | Dedicated Xorg with the xrdp video driver | Session persistence, resize on reconnect, works with any DE |
| **xrdp** + `Xvnc` | xrdp front-end to a TigerVNC backend | Simpler, loses xorgxrdp features |
| **gnome-remote-desktop** | Wayland/PipeWire, GNOME native | Both "screen share" and **headless** modes; `grdctl` CLI |
| **krdp** | Plasma 6 native | Configured from System Settings → Remote Desktop |

```ini
# /etc/xrdp/xrdp.ini  (excerpt — transport and security)
[Globals]
port=3389
use_vsock=false
security_layer=negotiate
crypt_level=high
certificate=/etc/xrdp/cert.pem
key_file=/etc/xrdp/key.pem
ssl_protocols=TLSv1.2, TLSv1.3
tls_ciphers=HIGH:!aNULL:!MD5
max_bpp=32
new_cursors=true
allow_channels=true
allow_multimon=true
bitmap_compression=true
bulk_compression=true

[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
ip=127.0.0.1
port=-1
code=20
```

```ini
# /etc/xrdp/sesman.ini  (excerpt — session lifecycle)
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=true
UserWindowManager=startwm.sh
DefaultWindowManager=startwm.sh

[Security]
AllowRootLogin=false
MaxLoginRetry=3
TerminalServerUsers=tsusers
TerminalServerAdmins=tsadmins
AlwaysGroupCheck=true
RestrictOutboundClipboard=all

[Sessions]
X11DisplayOffset=10
MaxSessions=50
KillDisconnected=false
DisconnectedTimeLimit=3600
IdleTimeLimit=7200
```

`xorgxrdp` needs an unprivileged Xorg to be startable by a non-console user:

```ini
# /etc/X11/Xwrapper.config
allowed_users=anybody
needs_root_rights=yes
```

Client side (FreeRDP 3):

```console
$ xfreerdp3 /v:vdi-01.mgmt.internal /u:sre-ops /d: \
    /size:1920x1080 /dynamic-resolution /gfx:AVC444 \
    +clipboard /sound:sys:pulse /drive:transfer,/home/dalmine/xfer \
    /cert:tofu
[10:22:04:118] [21874:00005572] [INFO][com.freerdp.core] - freerdp_connect:freerdp_set_last_error_ex resetting error state
[10:22:04:341] [21874:00005572] [INFO][com.freerdp.crypto] - creating certificate store at /home/dalmine/.config/freerdp/certs
[10:22:04:512] [21874:00005572] [INFO][com.freerdp.core] - ARM/AVC444 gfx pipeline negotiated
[10:22:05:007] [21874:00005572] [INFO][com.freerdp.client.common.cmdline] - Connected to vdi-01.mgmt.internal:3389
```

GNOME headless RDP (Wayland-native, no X11 anywhere in the path):

```console
$ grdctl rdp set-tls-cert ~/.local/share/gnome-remote-desktop/rdp-tls.crt
$ grdctl rdp set-tls-key  ~/.local/share/gnome-remote-desktop/rdp-tls.key
$ grdctl rdp set-credentials sre-ops
Password:
$ grdctl rdp enable
$ systemctl --user enable --now gnome-remote-desktop.service
$ grdctl status
RDP:
	Status: enabled
	TLS certificate: /home/sre-ops/.local/share/gnome-remote-desktop/rdp-tls.crt
	TLS key: /home/sre-ops/.local/share/gnome-remote-desktop/rdp-tls.key
	View-only: no
	Username: sre-ops
	Password: ●●●●●●●●
```

### 3.5 SPICE — the hypervisor console protocol

**Simple Protocol for Independent Computing Environments**, developed for QEMU/KVM. Structurally different from the others: **SPICE is implemented by the hypervisor, not by anything inside the guest.** The server is `spice-server` linked into the QEMU process; it therefore works before the guest kernel boots, through a guest kernel panic, and across guest reboots. Default TCP **5900+** (libvirt allocates with `autoport`), plus an optional TLS port.

An optional in-guest agent (`spice-vdagent` + `spice-vdagentd`, over a `virtio-serial` channel named `com.redhat.spice.0`) adds the quality-of-life layer: clipboard sharing, automatic guest resolution matching the client window, seamless mouse (no pointer grab), and file drag-and-drop. Without the agent SPICE still works — you just get a grabbed pointer and a fixed resolution.

Distinctive capabilities: multi-monitor from one connection, **USB device redirection** from client to guest, video-stream detection with MJPEG/H.264 compression, and audio via the `playback`/`record` channels.

```console
$ virsh list --all
 Id   Name        State
---------------------------
 3    ci-runner   running
 -    win-golden  shut off

$ virsh domdisplay ci-runner
spice://127.0.0.1:5901

$ virsh dumpxml ci-runner | sed -n '/<graphics/,/<\/graphics>/p'
    <graphics type='spice' port='5901' tlsPort='5902' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
      <image compression='auto_glz'/>
      <streaming mode='filter'/>
      <clipboard copypaste='yes'/>
      <mouse mode='client'/>
    </graphics>

$ remote-viewer --spice-debug spice://127.0.0.1:5901
(remote-viewer:9214): GSpice-DEBUG: channel-main.c:1234 main-1:0: agent connected
(remote-viewer:9214): GSpice-DEBUG: channel-display.c:2011 display-2:0: display channel ready
```

Guest side:

```console
$ systemctl status spice-vdagentd --no-pager
● spice-vdagentd.service - Agent daemon for Spice guests
     Loaded: loaded (/usr/lib/systemd/system/spice-vdagentd.service; enabled)
     Active: active (running) since Tue 2026-08-25 09:58:44 -03; 31min ago
   Main PID: 771 (spice-vdagentd)
$ ls -l /dev/virtio-ports/
lrwxrwxrwx 1 root root 11 Aug 25 09:58 com.redhat.spice.0 -> ../vport1p1
```

### 3.6 Consolidated protocol trade-off matrix

| | **X11 forwarding** | **XDMCP** | **VNC (RFB)** | **RDP** | **SPICE** |
|---|---|---|---|---|---|
| Default port | 6000+N TCP (over SSH ch.) | **177/UDP** | **5900+N TCP** | **3389 TCP/UDP** | 5900+ TCP (libvirt-assigned) |
| Unit of transfer | Drawing primitives | Login + drawing primitives | Framebuffer rectangles | Multiplexed virtual channels | Channels + guest video stream |
| Remotes a *single window* | ✅ **only one that does** | ❌ | ❌ | ❌ (RemoteApp is Windows-only) | ❌ |
| Encryption by default | ✅ (inherits SSH) | ❌ **none** | ❌ (VncAuth only; TLS via VeNCrypt) | ✅ TLS negotiated | ⚠ optional TLS port |
| Authentication strength | SSH keys + Xauth cookie | DM's PAM, transport in clear | **8-char** password (VncAuth) | PAM/NLA, full-length credentials | Ticket / SASL / TLS |
| Session survives disconnect | ❌ dies with the SSH channel | ❌ dies with the X server | ✅ (Xvnc mode) | ✅ (xrdp keeps sesman session) | ✅ (tied to VM, not client) |
| Works before guest OS boots | ❌ | ❌ | ❌ | ❌ | ✅ **only one that does** |
| Works on a Wayland session | ⚠ X clients only, via XWayland | ❌ **X11 only** | ⚠ needs `wayvnc`/portal | ✅ `gnome-remote-desktop`, `krdp` | ✅ (hypervisor-level, guest-agnostic) |
| Clipboard | ✅ (X selections) | ✅ | ⚠ text only, often flaky | ✅ text + files | ✅ with `spice-vdagent` |
| Audio redirection | ❌ | ❌ | ❌ | ✅ | ✅ |
| USB / drive redirection | ❌ | ❌ | ❌ | ✅ drives, printers, smartcards | ✅ **USB passthrough** |
| Multi-monitor | ✅ (local X server's monitors) | ✅ | ⚠ one framebuffer | ✅ | ✅ |
| Hardware video encode | ❌ | ❌ | ❌ | ✅ H.264/AVC444 | ✅ H.264/MJPEG |
| Tolerance to 100 ms RTT | ❌ **worst** (chatty round trips) | ❌ | ⚠ acceptable | ✅ **best** | ✅ |
| Bandwidth, idle desktop | very low | very low | low–moderate | low | low |
| Bandwidth, full-screen video | ❌ unusable | ❌ unusable | high (10–40 Mbps) | moderate (3–8 Mbps) | moderate (3–8 Mbps) |
| Primary production use | Single GUI tool from a build host | Legacy thin clients (avoid) | Headless VDI, CI test farms | Managed desktops, GPU workstations | KVM console, break-glass |

---

## 4. Reference architectures and complete infrastructure manifests

### 4.1 Hardened per-user VNC on a bastion (loopback + SSH only)

```ini
# /etc/systemd/system/vncserver@.service.d/hardening.conf
# Drop-in over the distribution unit: bind loopback only, cap resources,
# and make the session die cleanly when the user's tunnel goes away.
[Service]
# Resource containment: a runaway browser must not take the bastion down.
MemoryMax=3G
MemoryHigh=2500M
CPUQuota=200%
TasksMax=512

# Filesystem and privilege containment.
NoNewPrivileges=true
PrivateTmp=false
ProtectSystem=strict
ReadWritePaths=/home /run /tmp/.X11-unix /var/log
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Never leave a zombie desktop burning RAM for a week.
RuntimeMaxSec=12h
Restart=on-failure
RestartSec=5s
```

```ini
# /etc/ssh/sshd_config.d/50-remote-desktop.conf
# The only path to 5901..5910 is an authenticated SSH tunnel.
X11Forwarding no
AllowTcpForwarding local
PermitOpen 127.0.0.1:5901 127.0.0.1:5902 127.0.0.1:5903
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 4
```

```console
# firewall-cmd --permanent --add-service=ssh
success
# firewall-cmd --permanent --remove-port=5901-5910/tcp
success
# firewall-cmd --reload
success
# firewall-cmd --list-all
public (active)
  target: default
  services: ssh
  ports:
  protocols:
```

### 4.2 Containerised Xfce desktop on Kubernetes (Xvnc + noVNC sidecar)

The pattern: `Xvnc` binds **127.0.0.1** inside the pod; a `websockify` sidecar in the same network namespace bridges it to HTTP/WebSocket; the Ingress terminates TLS and enforces authentication. No VNC password ever crosses the network as the primary control.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: remote-desktops
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: xfce-session
  namespace: remote-desktops
data:
  xstartup: |
    #!/bin/sh
    # TigerVNC executes this as the session leader for display :1.
    # A bare `startxfce4` inherits a stale session manager and yields the
    # classic grey screen; unset both handles before exec'ing the DE.
    unset SESSION_MANAGER
    unset DBUS_SESSION_BUS_ADDRESS
    export XDG_SESSION_TYPE=x11
    export XDG_CURRENT_DESKTOP=XFCE
    export XDG_RUNTIME_DIR=/tmp/runtime-student
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    exec dbus-launch --exit-with-session startxfce4
  vnc-config: |
    session=xfce
    geometry=1920x1080
    depth=24
    localhost
    alwaysshared
    SecurityTypes=None
    AcceptCutText=1
    SendCutText=1
    AcceptSetDesktopSize=1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: home-student
  namespace: remote-desktops
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xfce-desktop
  namespace: remote-desktops
  labels:
    app.kubernetes.io/name: xfce-desktop
    app.kubernetes.io/component: vdi
spec:
  replicas: 1
  strategy:
    type: Recreate          # a desktop session is stateful; never roll two at once
  selector:
    matchLabels:
      app.kubernetes.io/name: xfce-desktop
  template:
    metadata:
      labels:
        app.kubernetes.io/name: xfce-desktop
        app.kubernetes.io/component: vdi
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: seed-home
          image: registry.internal/vdi/xfce-vnc:1.14.1
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              mkdir -p /home/student/.vnc
              install -m 0755 /config/xstartup   /home/student/.vnc/xstartup
              install -m 0644 /config/vnc-config /home/student/.vnc/config
              echo "seeded $(date -u +%FT%TZ)"
          volumeMounts:
            - name: home
              mountPath: /home/student
            - name: session-config
              mountPath: /config
              readOnly: true
      containers:
        - name: desktop
          image: registry.internal/vdi/xfce-vnc:1.14.1
          command:
            - /usr/bin/Xvnc
          args:
            - ":1"
            - "-geometry=1920x1080"
            - "-depth=24"
            - "-localhost=1"
            - "-SecurityTypes=None"
            - "-AlwaysShared=1"
            - "-AcceptSetDesktopSize=1"
            - "-desktop=xfce-vdi"
            - "-xstartup=/home/student/.vnc/xstartup"
          env:
            - name: HOME
              value: /home/student
            - name: USER
              value: student
            - name: XDG_RUNTIME_DIR
              value: /tmp/runtime-student
          ports:
            - name: rfb
              containerPort: 5901
              protocol: TCP
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
          startupProbe:
            tcpSocket:
              port: 5901
            periodSeconds: 5
            failureThreshold: 24
          livenessProbe:
            tcpSocket:
              port: 5901
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: home
              mountPath: /home/student
            - name: x11-socket
              mountPath: /tmp/.X11-unix
            - name: runtime
              mountPath: /tmp/runtime-student
            - name: dshm
              mountPath: /dev/shm
        - name: novnc
          image: registry.internal/vdi/novnc:1.5.0
          command:
            - /usr/bin/websockify
          args:
            - "--web=/usr/share/novnc"
            - "--heartbeat=30"
            - "0.0.0.0:6080"
            - "127.0.0.1:5901"       # same pod = same netns = loopback reachable
          ports:
            - name: http
              containerPort: 6080
              protocol: TCP
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /vnc.html
              port: 6080
            periodSeconds: 10
      volumes:
        - name: home
          persistentVolumeClaim:
            claimName: home-student
        - name: session-config
          configMap:
            name: xfce-session
            defaultMode: 0755
        - name: x11-socket
          emptyDir: {}
        - name: runtime
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi      # browsers crash with the 64 MB default /dev/shm
---
apiVersion: v1
kind: Service
metadata:
  name: xfce-desktop
  namespace: remote-desktops
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: xfce-desktop
  ports:
    - name: http
      port: 80
      targetPort: 6080
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: xfce-desktop
  namespace: remote-desktops
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: xfce-desktop
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 6080
          protocol: TCP
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - to:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - port: 443
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: xfce-desktop
  namespace: remote-desktops
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/auth-url: "https://auth.internal/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://auth.internal/oauth2/start?rd=$escaped_request_uri"
    cert-manager.io/cluster-issuer: internal-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["desktop.vdi.internal"]
      secretName: xfce-desktop-tls
  rules:
    - host: desktop.vdi.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: xfce-desktop
                port:
                  number: 80
```

```console
$ kubectl -n remote-desktops rollout status deploy/xfce-desktop
Waiting for deployment "xfce-desktop" rollout to finish: 0 of 1 updated replicas are available...
deployment "xfce-desktop" successfully rolled out

$ kubectl -n remote-desktops get pod -l app.kubernetes.io/name=xfce-desktop -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE
xfce-desktop-6c9f7b4d8c-2vqkp   2/2     Running   0          71s   10.42.3.87   node-04

$ kubectl -n remote-desktops exec deploy/xfce-desktop -c desktop -- ss -lntp
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      5        127.0.0.1:5901        0.0.0.0:*     users:(("Xvnc",pid=1,fd=7))
LISTEN 0      5        0.0.0.0:6080          0.0.0.0:*     users:(("websockify",pid=1,fd=3))

$ kubectl -n remote-desktops exec deploy/xfce-desktop -c desktop -- xlsclients -display :1
xfce-desktop  xfce4-panel
xfce-desktop  xfdesktop
xfce-desktop  xfwm4
```

### 4.3 SPICE console for a KVM guest (libvirt domain fragment)

```xml
<!-- virsh edit ci-runner : TLS-only SPICE, agent channel, USB redirection -->
<domain type='kvm'>
  <name>ci-runner</name>
  <memory unit='GiB'>8</memory>
  <vcpu placement='static'>4</vcpu>
  <devices>

    <graphics type='spice' autoport='yes' listen='127.0.0.1'
              defaultMode='secure' passwd='rotated-by-vault'
              passwdValidTo='2026-08-25T14:00:00'>
      <listen type='address' address='127.0.0.1'/>
      <channel name='main'    mode='secure'/>
      <channel name='display' mode='secure'/>
      <channel name='inputs'  mode='secure'/>
      <channel name='cursor'  mode='secure'/>
      <channel name='playback' mode='secure'/>
      <channel name='record'   mode='secure'/>
      <image compression='auto_glz'/>
      <jpeg compression='auto'/>
      <zlib compression='auto'/>
      <playback compression='on'/>
      <streaming mode='filter'/>
      <clipboard copypaste='no'/>       <!-- DLP: no exfiltration via clipboard -->
      <filetransfer enable='no'/>
      <mouse mode='client'/>
    </graphics>

    <video>
      <model type='virtio' heads='2' primary='yes'>
        <acceleration accel3d='no'/>
      </model>
    </video>

    <!-- guest agent channel: clipboard, resolution matching, seamless mouse -->
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>

    <!-- USB redirection: two slots over the SPICE channel -->
    <controller type='usb' index='0' model='qemu-xhci' ports='8'/>
    <redirdev bus='usb' type='spicevmc'/>
    <redirdev bus='usb' type='spicevmc'/>
    <redirfilter>
      <usbdev class='0x0b' allow='yes'/>   <!-- smartcard readers only -->
      <usbdev allow='no'/>
    </redirfilter>

  </devices>
</domain>
```

```console
# virsh define /etc/libvirt/qemu/ci-runner.xml
Domain 'ci-runner' defined from /etc/libvirt/qemu/ci-runner.xml
# virsh start ci-runner
Domain 'ci-runner' started
$ virsh domdisplay --type spice ci-runner
spice://127.0.0.1?tls-port=5902
$ ssh -N -L 5902:127.0.0.1:5902 kvm-host-02 &
$ remote-viewer "spice://127.0.0.1?tls-port=5902" \
    --spice-ca-file=/etc/pki/libvirt-spice/ca-cert.pem
```

---

## 5. Verification and failure diagnosis

### 5.1 Baseline verification sequence

```console
$ loginctl list-sessions
SESSION  UID USER    SEAT  LEADER CLASS   TTY  STATE  IDLE SINCE
      3 1000 sre-ops seat0   1854 user    tty2 active no   -
      7 1000 sre-ops -       4198 user    -    active no   -
     c1   42 gdm     seat0   1201 greeter tty1 active no   -

3 sessions listed.

$ loginctl show-session 7 -p Type -p Remote -p Service -p Scope
Type=x11
Remote=no
Service=vncsession
Scope=session-7.scope

$ loginctl seat-status seat0
seat0
	Sessions: *3 c1
	 Devices:
		 ├─/sys/devices/pci0000:00/0000:00:02.0/drm/card1
		 ├─/sys/devices/.../input/input4  (AT Translated Set 2 keyboard)
		 └─/sys/devices/.../input/input12 (SynPS/2 Synaptics TouchPad)

$ ss -lntup | grep -E ':(177|3389|5900|5901|6000|6080)\b'
udp  UNCONN 0 0    0.0.0.0:177   0.0.0.0:*  users:(("gdm",pid=1188,fd=9))
tcp  LISTEN 0 5  127.0.0.1:5901  0.0.0.0:*  users:(("Xvnc",pid=4211,fd=8))
tcp  LISTEN 0 2    0.0.0.0:3389  0.0.0.0:*  users:(("xrdp",pid=1180,fd=11))

$ xrandr --query
Screen 0: minimum 32 x 32, current 1920 x 1080, maximum 32768 x 32768
VNC-0 connected primary 1920x1080+0+0 0mm x 0mm
   1920x1080     60.00*+
   1280x800      60.00
   1024x768      60.00

$ glxinfo -B | grep -E 'renderer|OpenGL version'
OpenGL renderer string: llvmpipe (LLVM 19.1.0, 256 bits)
OpenGL version string: 4.5 (Compatibility Profile) Mesa 25.1.4
```

`llvmpipe` on a machine with a GPU is itself a finding: rendering is on the CPU, so the desktop will be slow and the CPU quota will be eaten by the compositor.

### 5.2 Failure triage table

| Symptom | Most probable cause | Confirming command | Fix |
|---|---|---|---|
| `Error: Can't open display:` (empty) | `DISPLAY` not set | `echo "[$DISPLAY]"` | `export DISPLAY=:0` locally, or reconnect with `ssh -X` |
| `X11 forwarding request failed on channel 0` | `X11Forwarding no` on the server, **or** `xauth` binary not installed on the server | `sshd -T \| grep -i x11`; `command -v xauth` | Enable `X11Forwarding yes`, install `xorg-x11-xauth`, `systemctl reload sshd` |
| `ssh -X` works, `DISPLAY` set, still `Can't open display` | Missing/stale cookie in `~/.Xauthority`, or `$HOME` not writable (full disk, NFS root-squash) | `xauth list`; `touch ~/.Xauthority` | `rm ~/.Xauthority && exec ssh -X ...`; fix quota/permissions |
| Forwarding works for `xterm`, fails for a GUI app with `BadAccess` | Untrusted forwarding (`-X`) + X SECURITY extension | run under `ssh -Y` to confirm | Prefer VNC/RDP; use `-Y` only toward a trusted host |
| X11 forwarding dies after ~20 minutes | `ForwardX11Timeout` expiry on untrusted forwarding | `sshd -T \| grep -i forwardx11timeout` | Raise the timeout, or move to a persistent protocol (VNC/RDP) |
| Wayland session: `ssh -X` works only for some apps | GTK/Qt apps preferring the Wayland backend; only XWayland clients forward | `echo $WAYLAND_DISPLAY`; `wayland-info \| head` | `GDK_BACKEND=x11` / `QT_QPA_PLATFORM=xcb`, or use RDP |
| **VNC: grey screen with an X cursor, no panel** | `~/.vnc/xstartup` not executable, or it never `exec`s a WM | `ls -l ~/.vnc/xstartup`; `tail ~/.vnc/*.log` | `chmod +x`; end the script with `exec dbus-launch --exit-with-session startxfce4` |
| **VNC: black screen, session exits instantly** | DE missing in the image, or D-Bus not started | `grep -iE 'error\|fatal' ~/.vnc/host:1.log` | Install the DE metapackage; wrap with `dbus-launch` |
| `vncserver` exits: *A VNC server is already running as :1* | Stale lock/socket from an unclean kill | `ls /tmp/.X11-unix /tmp/.X1-lock` | `vncserver -kill :1`; if it persists, remove `/tmp/.X1-lock` and `/tmp/.X11-unix/X1` |
| VNC connects from localhost, times out remotely | `-localhost` (correct) or a firewall drop | `ss -lntp \| grep 5901`; `nc -zv host 5901` | Keep `-localhost`; reach it via `ssh -L`. Never open VncAuth to a routed network |
| **xrdp: blue login screen, then instant disconnect** | Xorg cannot start unprivileged, or a session already exists for that user | `journalctl -u xrdp-sesman -n 50` | Set `allowed_users=anybody` in `/etc/X11/Xwrapper.config`; reconnect to the existing session |
| xrdp: connects but the desktop is empty | `startwm.sh` doesn't launch a DE | `cat /etc/xrdp/startwm.sh`; `~/.xsession-errors` | Append `exec startxfce4` (or the DE launcher) to `startwm.sh` |
| xrdp: polkit prompts every login ("Authentication required to create a color profile") | polkit rules deny non-console (`auth_admin`) actions | `pkaction --action-id org.freedesktop.color-manager.create-device` | Add a polkit rule allowing that action for the RDP users group |
| RDP client aborts at TLS negotiation | Expired/self-signed `/etc/xrdp/cert.pem`, or protocol mismatch | `openssl x509 -in /etc/xrdp/cert.pem -noout -dates` | Reissue the cert; align `ssl_protocols`; client `/cert:tofu` only for lab use |
| **XDMCP: "XDMCP fatal error: Session declined"** | `MaxSessions`/`DisplaysPerHost` reached, or host not in the DM ACL | `journalctl -u gdm -n 100`; `/etc/X11/xdm/Xaccess` | Raise the limits; add the host to `Xaccess` |
| XDMCP: no response at all | UDP/177 filtered, or the DM is running Wayland | `ss -lnup \| grep :177`; `nc -zvu dm-host 177` | Open UDP/177 in the management VLAN; set `WaylandEnable=false` |
| **SPICE: no clipboard, pointer is grabbed, fixed resolution** | `spice-vdagent` not running in the guest, or the virtio channel is missing | `systemctl status spice-vdagentd`; `ls /dev/virtio-ports/` | Install `spice-vdagent`; add the `com.redhat.spice.0` channel to the domain XML |
| SPICE: `Could not connect to 127.0.0.1:5900` | `listen='127.0.0.1'` (by design) and no tunnel; or `autoport` moved the port | `virsh domdisplay <vm>` | Use the port `domdisplay` reports; tunnel with `ssh -L` |
| Desktop is slow, CPU pinned by the compositor | Software rendering (`llvmpipe`) | `glxinfo -B \| grep renderer` | Install the GPU driver; for VNC/xrdp accept CPU rendering and reduce depth/geometry |
| Browser tabs crash inside the container desktop | Default 64 MB `/dev/shm` | `df -h /dev/shm` | `emptyDir: {medium: Memory, sizeLimit: 1Gi}` mounted at `/dev/shm` |
| Server boots into a GUI and OOMs | `default.target` is `graphical.target` | `systemctl get-default` | `systemctl set-default multi-user.target` |

### 5.3 Log locations that answer the question

```console
$ ls -l ~/.vnc/*.log
-rw-r--r-- 1 sre-ops sre-ops 4821 Aug 25 10:03 /home/sre-ops/.vnc/vdi-01:1.log

$ tail -n 6 ~/.vnc/vdi-01:1.log
Xvnc TigerVNC 1.14.1 - built Mar  4 2026 09:11:22
Copyright (C) 1999-2025 TigerVNC Team and many others (see README.rst)
 vncext:      VNC extension running!
 vncext:      Listening for VNC connections on local interface(s), port 5901
 vncext:      created VNC server for screen 0
/home/sre-ops/.vnc/xstartup: line 8: startxfce4: command not found   ← root cause

# journalctl -u xrdp-sesman -n 8 --no-pager
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [INFO ] Access permitted for user: sre-ops
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [INFO ] starting Xorg session...
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [ERROR] X server for display 10 startup timeout
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [ERROR] another Xserver might already be active on display 10

$ tail -n 3 ~/.xsession-errors
dbus-update-activation-environment: setting DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
xfce4-session: cannot open display
Xsession: unable to launch "startxfce4" X session

# journalctl -b -u gdm --no-pager | tail -n 4
Aug 25 09:57:41 vdi-01 gdm[1188]: Gdm: GdmDisplay: Session never registered, failing
Aug 25 09:57:41 vdi-01 gdm[1188]: Gdm: Failed to start Wayland display, falling back to X11

$ ls -l ~/.local/share/xorg/Xorg.0.log /var/log/Xorg.0.log 2>/dev/null
-rw-r--r-- 1 sre-ops sre-ops 42118 Aug 25 09:57 /home/sre-ops/.local/share/xorg/Xorg.0.log
```

Rootless Xorg writes to `~/.local/share/xorg/Xorg.N.log`; only a root-started X server writes `/var/log/Xorg.N.log`. Looking in the wrong one is the most common reason "there are no logs".

### 5.4 Security verification checklist

```console
$ xhost
access control enabled, only authorized clients can connect      # required state

$ sshd -T | grep -iE 'x11forwarding|x11uselocalhost|forwardx11timeout'
x11forwarding no
x11uselocalhost yes

$ ss -lntp | awk '$4 ~ /0\.0\.0\.0:(59[0-9][0-9]|177)/ {print "EXPOSED:", $4, $6}'
                                                     # empty output = pass

$ nmap -sV -p 177,3389,5900-5910,6000-6010 vdi-01.mgmt.internal
Starting Nmap 7.98 ( https://nmap.org ) at 2026-08-25 11:02 -03
Nmap scan report for vdi-01.mgmt.internal (10.42.7.31)
Host is up (0.00042s latency).
Not shown: 20 filtered tcp ports (no-response)
PORT     STATE SERVICE       VERSION
3389/tcp open  ms-wbt-server xrdp
```

| Control | Verification | Expected |
|---|---|---|
| No X11 TCP listener | `ss -lntp \| grep :600` | empty (`-nolisten tcp`) |
| X authorisation on | `xhost` | "access control enabled" |
| No plaintext VNC on a routed IP | `ss -lntp \| grep 590` | bound to `127.0.0.1` only |
| XDMCP off unless justified | `ss -lnup \| grep :177` | empty |
| RDP presents a managed certificate | `openssl s_client -connect host:3389 -starttls rdp` | CA-issued, unexpired |
| Clipboard/drive redirection scoped | `grep -i clipboard /etc/xrdp/sesman.ini` | `RestrictOutboundClipboard=all` where DLP applies |
| Session TTL enforced | `grep -i TimeLimit /etc/xrdp/sesman.ini` | `DisconnectedTimeLimit` / `IdleTimeLimit` set |

---

## 6. Exam-critical facts (memorise these)

| Fact | Value |
|---|---|
| X11 TCP port for display `:N` | **6000 + N** |
| XDMCP port and transport | **177/UDP** |
| VNC port for display `:N` | **5900 + N** (`:1` → 5901) |
| RDP port | **3389** (TCP, optionally UDP) |
| SPICE port | 5900+ , assigned by libvirt (`autoport='yes'`) |
| X11 authorisation cookie type / file | `MIT-MAGIC-COOKIE-1` in `~/.Xauthority` (`xauth`) |
| Trusted vs untrusted SSH X11 forwarding | `ssh -Y` trusted, `ssh -X` untrusted |
| GNOME compositor / DM / settings store | `mutter` / `gdm` / `dconf` |
| KDE Plasma compositor / DM / settings store | `kwin` / `sddm` / KConfig files |
| Xfce WM / DM / settings store | `xfwm4` / `lightdm` / `xfconf` |
| Protocol with no built-in encryption at all | **XDMCP** |
| Protocol that works before the guest OS boots | **SPICE** |
| Protocol that can remote a single window | **X11 forwarding** |
| Protocols with USB/device redirection | **RDP** (drives, printers, smartcards) and **SPICE** (USB) |
| SPICE guest agent (clipboard, resolution, mouse) | `spice-vdagent` / `spice-vdagentd` |
| Switch text-mode vs graphical boot | `systemctl set-default multi-user.target` / `graphical.target` |

---

## 7. References

- LPI — LPIC-1 Exam 102-500 objectives (Topic 106: User Interfaces and Desktops): https://www.lpi.org/our-certifications/exam-102-objectives/
- LPI — LPIC-1 Exam 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
- X.Org Foundation — Xorg server documentation: https://www.x.org/wiki/
- X.Org — `Xserver(1)` and `Xsecurity(7)` manual pages: https://www.x.org/releases/current/doc/man/man1/Xserver.1.xhtml
- X.Org — X Display Manager Control Protocol (XDMCP) specification: https://www.x.org/releases/current/doc/xorgdocs/specs/XDMCP/xdmcp.html
- Wayland — protocol and architecture documentation: https://wayland.freedesktop.org/docs/html/
- freedesktop.org — XDG Desktop Portal (screen capture / remote desktop on Wayland): https://flatpak.github.io/xdg-desktop-portal/docs/
- GNOME — Project documentation and system administration guide: https://help.gnome.org/admin/system-admin-guide/stable/
- GNOME — `gnome-remote-desktop` (RDP server, headless mode): https://gitlab.gnome.org/GNOME/gnome-remote-desktop
- KDE — Plasma desktop documentation: https://docs.kde.org/
- KDE — KRdp (Plasma RDP server): https://invent.kde.org/plasma/krdp
- Xfce — Official documentation: https://docs.xfce.org/
- TigerVNC — Project documentation and `vncserver`/`Xvnc` manual pages: https://tigervnc.org/
- The RFB Protocol specification (community-maintained): https://github.com/rfbproto/rfbproto
- xrdp — Official documentation and configuration reference: https://github.com/neutrinolabs/xrdp/wiki
- FreeRDP — Client and server documentation: https://www.freerdp.com/
- Microsoft — `[MS-RDPBCGR]` Remote Desktop Protocol basic connectivity and graphics remoting: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/
- SPICE — Protocol and user manual: https://www.spice-space.org/documentation.html
- libvirt — Domain XML `<graphics>` element reference: https://libvirt.org/formatdomain.html#graphical-framebuffers
- systemd — `systemd-logind(8)` and `loginctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-logind.service.html
- OpenSSH — `ssh_config(5)` / `sshd_config(5)` X11 forwarding options: https://man.openbsd.org/sshd_config
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- noVNC / websockify — Project documentation: https://novnc.com/info.html