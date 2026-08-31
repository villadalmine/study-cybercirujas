# LPIC-1 — Topic 106.2: Graphical Desktops
## Guided Exercises

**Exam:** 101-500 / 102-500 (v5.0) · **Objective 106.2** · **Weight:** 0.0
**Scope of the objective:** awareness of the major desktop environments (KDE, GNOME, Xfce) and understanding of the protocols used to reach a remote graphical session (X11, XDMCP, VNC, Spice, RDP).

### Lab prerequisites

| Item | Requirement |
|---|---|
| Machines | Two Linux hosts on the same L2 segment. `station` (your workstation, with a running graphical session) and `srv` (the remote host). A VM pair is fine. |
| Privileges | `sudo` on both. |
| Packages you will install | `xfce4`, `x11-utils`/`xorg-x11-utils`, `wmctrl`, `tigervnc-standalone-server`, `x11vnc`, `xrdp`, `freerdp2-x11`/`freerdp`, `virt-viewer`, `xserver-xephyr`/`xorg-x11-server-Xephyr` |
| Firewall | You need to be able to open/close TCP 3389, 5900–5910 and UDP 177 on `srv`. |

Command output shown in this document is **representative** — version strings, PIDs, cookies and interface names will differ on your system. What must match is the *shape* of the output; where it does not, that is the diagnostic signal.

Throughout, `station$` and `srv$` mark which host runs the command.

---

## Block 1 — Identify the session: display server, session type, desktop environment

An enormous amount of 106.2 troubleshooting comes down to answering three questions correctly before touching anything: *which display server is running*, *which session type the login manager started*, and *which desktop environment sits on top of it*. They are three independent facts, and people routinely confuse them.

1. From a terminal **inside your graphical session**, ask logind what it thinks the session is:

```bash
station$ loginctl show-session auto -p Id -p Type -p Class -p Remote -p Display -p Active
```

```
Id=2
Type=wayland
Class=user
Remote=no
Display=
Active=yes
```

`Type=` is the authoritative answer: `x11`, `wayland` or `tty`. (`Display=` here is logind's own bookkeeping field, not `$DISPLAY`; it is frequently empty.)

2. Now ask the session's own environment:

```bash
station$ echo "type=$XDG_SESSION_TYPE  desktop=$XDG_CURRENT_DESKTOP  session=$DESKTOP_SESSION"
station$ echo "DISPLAY=$DISPLAY  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
```

```
type=wayland  desktop=GNOME  session=gnome
DISPLAY=:0  WAYLAND_DISPLAY=wayland-0
```

3. Find the processes that actually implement the desktop:

```bash
station$ ps -eo pid,comm --sort=comm | grep -E 'gnome-shell|mutter|plasmashell|kwin|xfwm4|xfdesktop|Xorg|Xwayland'
```

```
   1893 Xwayland
   1721 gnome-shell
```

4. Enumerate every session the login manager can offer, and read one of them:

```bash
station$ ls /usr/share/xsessions/ /usr/share/wayland-sessions/
station$ cat /usr/share/xsessions/xfce.desktop
```

```
/usr/share/wayland-sessions/:
gnome.desktop  plasmawayland.desktop

/usr/share/xsessions/:
gnome-xorg.desktop  plasmax11.desktop  xfce.desktop

[Desktop Entry]
Version=1.0
Name=Xfce Session
Comment=Use this session to run Xfce as your desktop environment
Exec=startxfce4
Icon=
Type=Application
DesktopNames=XFCE
```

5. Confirm what the window manager reports about itself (X11 sessions and Xwayland only):

```bash
station$ wmctrl -m
```

```
Name: GNOME Shell
Class: N/A
PID: N/A
Window manager's "showing the desktop" mode: N/A
```

**Check your understanding — Block 1**

1.1 `$XDG_SESSION_TYPE` says `wayland`, yet `echo $DISPLAY` prints `:0` and `xterm` starts normally. Explain, precisely, what is serving that `:0`.
1.2 Which of these three values is set by the *session `.desktop` file* rather than by logind: `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `XDG_VTNR`?
1.3 You are connected over plain SSH with no X forwarding. `loginctl show-session auto -p Type` returns `Type=tty` and `$XDG_CURRENT_DESKTOP` is empty, even though a user is physically logged into GNOME on the console. Why, and how do you inspect *that* session instead?
1.4 What is the functional difference between the directories `/usr/share/xsessions/` and `/usr/share/wayland-sessions/`?

---

## Block 2 — The display manager: what starts the desktop

1. Identify the running display manager (DM) through the canonical alias:

```bash
srv$ systemctl status display-manager --no-pager | head -3
srv$ ls -l /etc/systemd/system/display-manager.service
```

```
● gdm.service - GNOME Display Manager
     Loaded: loaded (/usr/lib/systemd/system/gdm.service; enabled; preset: disabled)
     Active: active (running) since Tue 2026-08-25 09:12:44 -03; 1 day 4h ago

lrwxrwxrwx. 1 root root 36 Aug 12 18:03 /etc/systemd/system/display-manager.service -> /usr/lib/systemd/system/gdm.service
```

That symlink **is** the mechanism. There is no `display-manager.service` unit file; the distribution creates a symlink to whichever DM is selected, and `graphical.target` pulls in the alias.

2. Confirm the boot target that decides whether a DM starts at all:

```bash
srv$ systemctl get-default
srv$ systemctl list-dependencies graphical.target --no-pager | head -8
```

```
graphical.target
graphical.target
● ├─display-manager.service
● ├─gdm.service
● └─multi-user.target
```

3. Switch runlevels/targets without rebooting, and observe:

```bash
srv$ sudo systemctl isolate multi-user.target     # DM stops, graphical sessions die
srv$ systemctl is-active display-manager
srv$ sudo systemctl isolate graphical.target      # DM comes back
```

```
inactive
```

4. Change the default DM. Install a second one and repoint the alias:

```bash
srv$ sudo apt-get install -y lightdm        # Debian/Ubuntu: offers an interactive chooser
srv$ sudo dpkg-reconfigure lightdm
```

On Fedora/RHEL/openSUSE there is no debconf chooser — you manipulate the units directly:

```bash
srv$ sudo systemctl disable gdm
srv$ sudo systemctl enable sddm            # recreates the display-manager.service symlink
srv$ ls -l /etc/systemd/system/display-manager.service
```

5. Make the default a text boot, then start a desktop by hand from the console — the no-DM path:

```bash
srv$ sudo systemctl set-default multi-user.target
srv$ cat ~/.xinitrc
srv$ startx
```

```
exec startxfce4
```

**Check your understanding — Block 2**

2.1 You edited `/etc/systemd/system/display-manager.service` by hand to point at SDDM, then ran `apt-get upgrade`, and after reboot GDM came back. What is the supported way to make the choice stick on Debian?
2.2 `systemctl get-default` returns `graphical.target` but the machine boots to a text login. Give three distinct causes, in the order you would test them.
2.3 What does `startx` use to decide which desktop to run, and how does that differ from what a display manager uses?
2.4 A user reports "the desktop restarted and I lost my work." `systemctl status display-manager` shows an uptime of 4 minutes. Which single log command shows you why?

---

## Block 3 — KDE Plasma, GNOME and Xfce: the same roles, different implementations

A desktop environment is not a monolith; it is a fixed set of roles filled by different programs. Learn the role map once and every DE becomes readable.

1. Install Xfce alongside your current desktop so you can compare (this is safe; it only adds a session):

```bash
srv$ sudo apt-get install -y xfce4 xfce4-goodies       # Debian/Ubuntu
srv$ sudo dnf group install -y "Xfce Desktop"          # Fedora
```

2. Log out, select **Xfce Session** in the greeter, log back in, and map the running components to their roles:

```bash
srv$ ps -eo comm= --sort=comm | grep -E 'xfwm4|xfdesktop|xfce4-panel|xfsettingsd|Thunar|xfce4-session'
```

```
Thunar
xfce4-panel
xfce4-session
xfdesktop
xfsettingsd
xfwm4
```

3. Read and change a setting through each DE's native configuration system. Xfce uses **Xfconf** (XML under `~/.config/xfce4/xfconf/`):

```bash
srv$ xfconf-query -c xfwm4 -l -v | head -5
srv$ xfconf-query -c xfwm4 -p /general/theme -s Default-hdpi
```

```
/general/activate_action        bring
/general/borderless_maximize    true
/general/box_move               false
/general/button_layout          O|SHMC
/general/click_to_focus         true
```

GNOME uses **GSettings** over the **dconf** binary database (`~/.config/dconf/user`):

```bash
srv$ gsettings get org.gnome.desktop.interface color-scheme
srv$ gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
srv$ gsettings list-recursively org.gnome.desktop.wm.preferences | head -4
```

```
'default'
org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
org.gnome.desktop.wm.preferences audible-bell false
org.gnome.desktop.wm.preferences button-layout 'appmenu:close'
org.gnome.desktop.wm.preferences focus-mode 'click'
```

KDE Plasma uses **KConfig**, plain INI files under `~/.config/*rc`:

```bash
srv$ kreadconfig5 --file kdeglobals --group General --key ColorScheme
srv$ kwriteconfig5 --file kwinrc --group Windows --key FocusPolicy FocusFollowsMouse
srv$ qdbus org.kde.KWin /KWin reconfigure         # make KWin re-read kwinrc live
```

4. Build the role map by inspection:

| Role | GNOME | KDE Plasma | Xfce |
|---|---|---|---|
| Compositor / window manager | Mutter (inside `gnome-shell` on Wayland) | KWin (`kwin_wayland` / `kwin_x11`) | `xfwm4` (X11 only) |
| Shell / panel | `gnome-shell` | `plasmashell` | `xfce4-panel` + `xfdesktop` |
| Session manager | `gnome-session` | `startplasma-*` / `ksmserver` | `xfce4-session` |
| File manager | Nautilus (GNOME Files) | Dolphin | Thunar |
| Settings store | GSettings → dconf | KConfig → `~/.config/*rc` | Xfconf → XML |
| Widget toolkit | GTK | Qt | GTK |
| Display manager usually shipped | GDM | SDDM | LightDM |

5. Verify the toolkit claim empirically:

```bash
srv$ ldd $(which dolphin) 2>/dev/null | grep -c libQt
srv$ ldd $(which thunar)  | grep -c libgtk
```

**Check your understanding — Block 3**

3.1 In a GNOME **Wayland** session, `ps` shows no separate window-manager process. Where did Mutter go, and what changes about crash behaviour compared with an X11 session running `metacity`?
3.2 A user's GNOME setting will not persist across reboots. `gsettings set` succeeds and `gsettings get` reflects the change immediately. Which file would you check for integrity, and which command dumps the whole database as text?
3.3 Xfce and GNOME both use GTK. Name two concrete reasons a GNOME application can still look and behave wrong under Xfce.
3.4 You must apply a KDE setting to 400 workstations from a shell script, with no user logged in. Which of `kwriteconfig5`, `gsettings` or `xfconf-query` is *inherently* the least problematic in that scenario, and why?

---

## Block 4 — X11 as a network protocol: `$DISPLAY`, X authority, SSH forwarding

X11 is the only one of the five protocols in this objective that is *natively* network-transparent at the level of individual windows. Everything else ships pixels of a whole screen.

1. Decompose the display specification. The syntax is `hostname:displaynumber.screennumber`:

```bash
station$ echo $DISPLAY
station$ xdpyinfo | head -6
```

```
:0
name of display:    :0
version number:    11.0
vendor string:    The X.Org Foundation
vendor release number:    12401007
X.Org version: 24.1.7
maximum request size:  16777212 bytes
```

An empty hostname means a **UNIX-domain socket** — look at it:

```bash
station$ ls -l /tmp/.X11-unix/
```

```
srwxrwxrwx. 1 root root 0 Aug 25 09:12 X0
```

2. Inspect the access-control credential. X11 authorisation is a shared secret, the **MIT-MAGIC-COOKIE-1**, stored in the file named by `$XAUTHORITY`:

```bash
station$ echo $XAUTHORITY
station$ xauth list
```

```
/run/user/1000/.mutter-Xwaylandauth.T2K9J2
station/unix:0  MIT-MAGIC-COOKIE-1  9f2a41c7b8de05631aa47c9e2b0d5f88
```

3. Look at the *other*, coarser access-control mechanism, host-based:

```bash
station$ xhost
```

```
access control enabled, only authorized clients can connect
SI:localuser:alice
```

4. Verify that no X server is listening on TCP — the modern default:

```bash
station$ ss -ltnp | grep -E ':60[0-9][0-9]'
station$ ps -eo args= | grep -o '\-nolisten tcp'
```

```
-nolisten tcp
```

An empty first result is correct and expected. TCP 6000+N is disabled because raw X11 on the wire is unencrypted and unauthenticated beyond the cookie.

5. Now do it the supported way: tunnel X11 inside SSH. On `srv`, confirm the server side:

```bash
srv$ sudo sshd -T | grep -E '^x11(forwarding|displayoffset|uselocalhost)'
```

```
x11forwarding yes
x11displayoffset 10
x11uselocalhost yes
```

If `x11forwarding` is `no`, set `X11Forwarding yes` in `/etc/ssh/sshd_config` and `sudo systemctl reload sshd`.

6. Connect and observe the forwarded display being created:

```bash
station$ ssh -X alice@srv
srv$ echo $DISPLAY
srv$ xauth list
srv$ ss -ltnp | grep 6010
srv$ xeyes &
```

```
localhost:10.0
srv/unix:10  MIT-MAGIC-COOKIE-1  4b1c7e93aa0f2d6851ce33907b4ad2f1
LISTEN 0  128  127.0.0.1:6010  0.0.0.0:*  users:(("sshd",pid=4471,fd=9))
```

`xeyes` runs on `srv`, draws on `station`. Note that the cookie on `srv` is a *proxy* cookie minted by sshd, not your real one — sshd substitutes it on every forwarded connection.

7. Compare trusted and untrusted forwarding:

```bash
station$ ssh -X  alice@srv 'xdotool key --window $(xdotool getactivewindow) a' ; echo "untrusted rc=$?"
station$ ssh -Y  alice@srv 'xdotool key --window $(xdotool getactivewindow) a' ; echo "trusted   rc=$?"
```

`-X` (untrusted) engages the X11 SECURITY extension, which blocks operations such as reading other clients' windows, global keyboard grabs and clipboard snooping. `-Y` (`ForwardX11Trusted yes`) disables those restrictions — the remote application gains full control of your local display.

8. Reproduce the two classic failures deliberately:

```bash
srv$ DISPLAY= xeyes
srv$ XAUTHORITY=/dev/null xeyes
```

```
Error: Can't open display:
No protocol specified
Error: Can't open display: localhost:10.0
```

**Check your understanding — Block 4**

4.1 In `$DISPLAY=srv.example.com:2.1`, what does each of the three fields select, and which TCP port would a direct (non-tunnelled) connection use?
4.2 Distinguish precisely the failure `Can't open display:` from `No protocol specified / Can't open display: localhost:10.0`. Which one is an authorisation problem?
4.3 `xhost +` is a very common "fix" found on the internet. State exactly what it permits and why it is unacceptable on a multi-user or network-reachable host.
4.4 With `ssh -X`, on which machine does the X **client** run, and on which machine does the X **server** run? Justify the answer in terms of who owns the display hardware.
4.5 You need to run a remote GUI application that requires a global keyboard grab (a password manager). `-X` breaks it. What are your two options and what is the security consequence of each?
4.6 A user in a Wayland GNOME session runs `ssh -X srv` and remote GUI apps work fine. Which local component is accepting those X11 connections?

---

## Block 5 — XDMCP: brokering whole sessions to an X terminal

XDMCP (X Display Manager Control Protocol) inverts the SSH-forwarding topology. The **client machine runs the X server**, then asks a remote display manager over **UDP 177** to send it a login greeter and run the entire session remotely. It is the classic thin-client / X-terminal protocol and it is **entirely unencrypted**.

1. Enable XDMCP on `srv`. With LightDM:

```bash
srv$ sudo tee /etc/lightdm/lightdm.conf.d/50-xdmcp.conf >/dev/null <<'EOF'
[XDMCPServer]
enabled=true
port=177
EOF
srv$ sudo systemctl restart lightdm
```

With GDM, the equivalent lives in `/etc/gdm3/custom.conf` (Debian) or `/etc/gdm/custom.conf` (Fedora):

```ini
[xdmcp]
Enable=true

[security]
DisallowTCP=false
```

2. Verify the listener and open the port. XDMCP is **UDP**, so `ss -ltn` will never show it:

```bash
srv$ sudo ss -lunp | grep :177
srv$ sudo firewall-cmd --add-service=xdmcp --permanent && sudo firewall-cmd --reload
```

```
UNCONN 0  0  0.0.0.0:177  0.0.0.0:*  users:(("lightdm",pid=1177,fd=13))
```

3. From `station`, connect a nested X server to it — the safe way to test without leaving your desktop:

```bash
station$ Xephyr :3 -query srv -screen 1280x800 -once
```

A window opens containing the remote greeter. Log in; the whole desktop runs on `srv`, rendered on `station`.

4. The historical bare-metal form, from a text console (VT 8), where the client machine is a dedicated X terminal:

```bash
station$ sudo X -query srv :3 vt8
```

5. Ask the network who is offering sessions (broadcast query):

```bash
station$ Xephyr :3 -broadcast -screen 1024x768 -once
```

6. Now prove the security claim. While logged in through the Xephyr session, capture traffic on `srv`:

```bash
srv$ sudo tcpdump -i any -A 'port 177 or portrange 6000-6010' -c 20
```

You will see readable protocol data. Keystrokes traverse the X11 stream on TCP 6000+N in cleartext; XDMCP itself only brokers the session.

7. Clean up — leave it disabled:

```bash
srv$ sudo rm /etc/lightdm/lightdm.conf.d/50-xdmcp.conf
srv$ sudo systemctl restart lightdm
srv$ sudo firewall-cmd --remove-service=xdmcp --permanent && sudo firewall-cmd --reload
```

**Check your understanding — Block 5**

5.1 In an XDMCP session, which host runs the X server, which runs the display manager, and which runs `gnome-shell`?
5.2 XDMCP uses UDP 177, but disabling it is not enough to secure the setup. Which *other* ports must also be considered, and what carries the user's keystrokes?
5.3 `ss -ltnp | grep 177` returns nothing on a correctly configured XDMCP server. Why is that not a fault, and what is the correct command?
5.4 Enabling `[xdmcp] Enable=true` in GDM has no effect and the greeter never appears remotely. Name two structural reasons this happens on a current distribution.
5.5 Contrast XDMCP with `ssh -X` in terms of (a) what is remoted, (b) confidentiality, (c) which side needs an X server.

---

## Block 6 — VNC: remoting a framebuffer with RFB

VNC (Virtual Network Computing) speaks **RFB** (Remote Framebuffer, RFC 6143). It is display-server agnostic and pixel-oriented: it ships rectangles of screen, not drawing commands. Two deployment modes matter, and confusing them is the single most common VNC mistake.

### 6a — Virtual session mode (a *new*, headless desktop)

1. Install TigerVNC and set a password:

```bash
srv$ sudo dnf install -y tigervnc-server        # or: apt-get install tigervnc-standalone-server
srv$ vncpasswd
```

```
Password:
Verify:
Would you like to enter a view-only password (y/n)? n
```

2. Configure the per-user session:

```bash
srv$ cat > ~/.vnc/config <<'EOF'
geometry=1280x800
depth=24
localhost
session=xfce
EOF
srv$ chmod 600 ~/.vnc/passwd
```

3. Map display numbers to users (TigerVNC ≥ 1.11 systemd model) and start it:

```bash
srv$ echo ':1=alice' | sudo tee -a /etc/tigervnc/vncserver.users
srv$ sudo systemctl enable --now vncserver@:1
srv$ systemctl status vncserver@:1 --no-pager | head -4
```

4. Confirm the port arithmetic. **Port = 5900 + display number**:

```bash
srv$ ss -ltnp | grep 590
```

```
LISTEN 0 5 127.0.0.1:5901 0.0.0.0:* users:(("Xvnc",pid=5231,fd=8))
```

`:1` → 5901. Bound to loopback because of `localhost` in `~/.vnc/config`.

5. Reach it from `station` through an SSH tunnel — the correct way to expose VNC:

```bash
station$ ssh -f -N -L 5901:localhost:5901 alice@srv
station$ vncviewer localhost:5901
```

6. Inspect the session startup script and its log when something goes wrong:

```bash
srv$ cat ~/.vnc/xstartup
srv$ tail -20 ~/.vnc/srv:1.log
```

```
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
```

A blank grey screen with an X cursor means `xstartup` ran but started **no window manager**.

### 6b — Mirror mode (share the *existing* console session)

7. `Xvnc` creates a brand-new desktop nobody is sitting at. To take over display `:0`, you need `x11vnc`:

```bash
srv$ sudo dnf install -y x11vnc
srv$ x11vnc -storepasswd ~/.vnc/x11vnc.pass
srv$ x11vnc -display :0 -auth guess -localhost -rfbauth ~/.vnc/x11vnc.pass -forever
```

```
The X11 display :0 is being shared on port 5900
```

8. Now try the same on a **Wayland** session:

```bash
srv$ loginctl show-session auto -p Type
srv$ x11vnc -display :0 -auth guess
```

```
Type=wayland
XOpenDisplay("​:0") failed.
Xlib: connection to ":0" refused by server
```

This is not a bug. `x11vnc` scrapes an X11 root window; a Wayland compositor does not expose one. The supported replacement is the compositor's own screen-sharing backend (`gnome-remote-desktop`, KDE's `krfb`/RDP server), which uses PipeWire.

**Check your understanding — Block 6**

6.1 A user asks for "VNC so I can see what is on the screen in the office." You configure `vncserver@:1`, they connect, and they see a fresh empty desktop instead of the office screen. What did you get wrong, and what do you deploy instead?
6.2 Compute the TCP port for VNC display `:4`. What listens on 5800 on some legacy setups?
6.3 The VNC password file is `~/.vnc/passwd`. Two facts about it are exam-relevant and security-relevant. State both.
6.4 `systemctl status vncserver@:1` reports active, but `vncviewer srv:5901` from another host times out while `vncviewer localhost:5901` on `srv` works. Give the two most likely causes and the command that discriminates between them.
6.5 Why is an SSH tunnel considered mandatory for VNC over an untrusted network, given that VNC does have a password?
6.6 Explain, in protocol terms, why RFB works identically against a Linux, Windows or macOS server while X11 forwarding does not.

---

## Block 7 — RDP: xrdp, FreeRDP and the modern Wayland path

RDP (Remote Desktop Protocol) is Microsoft's protocol, listening on **TCP 3389**. On Linux it is the best performer over high-latency links and the only one of the five with mature device redirection (drives, printers, smart cards, audio, clipboard) built into the protocol itself.

1. Install and inspect the server:

```bash
srv$ sudo dnf install -y xrdp        # or: apt-get install xrdp
srv$ sudo systemctl enable --now xrdp
srv$ systemctl status xrdp xrdp-sesman --no-pager | grep -E 'Active|●'
srv$ ss -ltnp | grep 3389
```

```
LISTEN 0 2 0.0.0.0:3389 0.0.0.0:* users:(("xrdp",pid=6104,fd=11))
```

Two units, two roles: `xrdp` terminates the protocol on 3389; `xrdp-sesman` is the session manager that authenticates via PAM and spawns the desktop.

2. Read the key configuration:

```bash
srv$ grep -vE '^\s*(#|$)' /etc/xrdp/xrdp.ini | head -20
srv$ cat /etc/xrdp/startwm.sh | tail -8
```

```
[Globals]
ini_version=1
port=3389
security_layer=negotiate
crypt_level=high
certificate=
key_file=
...
[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
port=-1
code=20
```

3. Pin the desktop that RDP sessions get:

```bash
srv$ echo 'startxfce4' | sudo tee /etc/xrdp/startwm.sh.d/50-xfce.sh   # distro-dependent
srv$ echo 'xfce4-session' > ~/.xsession
srv$ sudo systemctl restart xrdp
```

4. Open the firewall and connect from `station`:

```bash
srv$ sudo firewall-cmd --add-port=3389/tcp --permanent && sudo firewall-cmd --reload
station$ xfreerdp /v:srv /u:alice /dynamic-resolution +clipboard /cert:ignore
```

With FreeRDP 3 the binary is `xfreerdp3` and flags are namespaced:

```bash
station$ xfreerdp3 /v:srv /u:alice /dynamic-resolution +clipboard /sound /drive:home,/home/alice
```

5. Prove device redirection actually works — inside the RDP session on `srv`:

```bash
srv$ ls ~/thinclient_drives/home | head
```

6. Use the Wayland-native alternative. GNOME ships its own RDP server (`gnome-remote-desktop`), which is the supported way to share a Wayland session:

```bash
srv$ grdctl status
srv$ grdctl rdp enable
srv$ grdctl rdp set-credentials alice 'S3cret!'
srv$ grdctl rdp disable-view-only
srv$ systemctl --user enable --now gnome-remote-desktop
srv$ ss -ltnp | grep 3389
```

Note this is a **user** unit for a headless/session share, and it collides with `xrdp` on 3389 — run one or the other.

7. Diagnose the "blue screen then disconnect" failure, which is xrdp's signature error:

```bash
srv$ sudo journalctl -u xrdp-sesman -n 30 --no-pager
srv$ tail -20 ~/.xorgxrdp.10.log
srv$ tail -20 /var/log/xrdp-sesman.log
```

**Check your understanding — Block 7**

7.1 `xrdp` and `xrdp-sesman` are separate services. What does each one do, and which of the two authenticates the user?
7.2 Which TCP port is RDP, and what happens if you enable both `xrdp` and `gnome-remote-desktop` on the same host?
7.3 Name two capabilities RDP provides natively that plain VNC (RFB) does not.
7.4 An RDP login succeeds, then the session drops back to the login box after two seconds. Which two log files do you read first?
7.5 Your `srv` runs GNOME on Wayland and you must give a Windows user access to the *currently logged-in* desktop. Which of `x11vnc`, `xrdp` with the Xorg backend, or `gnome-remote-desktop` is the correct answer, and why are the other two wrong?

---

## Block 8 — SPICE: the virtual-machine console protocol

SPICE (Simple Protocol for Independent Computing Environments) is not a general remote-desktop protocol for physical machines. It is designed for **virtual machines**: the hypervisor exposes the guest's emulated graphics device, and a multi-channel protocol carries display, input, audio, USB redirection and clipboard, each on its own channel.

1. Start a QEMU guest with a SPICE display bound to loopback:

```bash
srv$ qemu-system-x86_64 -enable-kvm -m 2048 -hda /var/lib/libvirt/images/test.qcow2 \
    -vga qxl \
    -spice port=5930,addr=127.0.0.1,disable-ticketing=on \
    -device virtio-serial-pci \
    -chardev spicevmc,id=spicechannel0,name=vdagent \
    -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0
```

2. Verify the listener and connect:

```bash
srv$ ss -ltnp | grep 5930
srv$ remote-viewer spice://127.0.0.1:5930
```

```
LISTEN 0 1 127.0.0.1:5930 0.0.0.0:* users:(("qemu-system-x86",pid=7712,fd=17))
```

3. In the libvirt-managed case, do not guess the URI — ask:

```bash
srv$ virsh list --all
srv$ virsh domdisplay win11
srv$ virsh dumpxml win11 | grep -A3 '<graphics'
```

```
spice://127.0.0.1:5900

    <graphics type='spice' port='5900' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
      <image compression='off'/>
    </graphics>
```

4. Reach a loopback-bound SPICE console from `station` — the same tunnelling discipline as VNC, or `virt-viewer`'s built-in transport:

```bash
station$ remote-viewer --spice-debug spice://srv:5930           # only if listen is 0.0.0.0
station$ virt-viewer --connect qemu+ssh://alice@srv/system win11
```

5. Install the guest agent **inside the guest** and observe what it unlocks:

```bash
guest$ sudo dnf install -y spice-vdagent
guest$ sudo systemctl enable --now spice-vdagentd
guest$ systemctl status spice-vdagentd --no-pager | head -3
```

Without `spice-vdagent` there is no clipboard sharing, no automatic guest-resolution matching when you resize the viewer window, and no smooth mouse-mode switching. This is the single most-asked SPICE support question.

6. Compare with the same VM exposed over VNC instead:

```bash
srv$ virsh dumpxml win11 | sed 's|type=.spice.|type="vnc"|' > /tmp/win11-vnc.xml
```

The VNC console gives you the same framebuffer but loses USB redirection, multi-monitor and audio.

**Check your understanding — Block 8**

8.1 SPICE and VNC can both act as a QEMU display. State three capabilities SPICE has that the QEMU VNC display does not.
8.2 What is the role of `spice-vdagent`, on which side of the connection does it run, and name two symptoms of its absence.
8.3 `virsh domdisplay vm1` prints `spice://127.0.0.1:5900`, yet `remote-viewer spice://srv:5900` from another host fails to connect. Explain, and give the two possible remedies.
8.4 Why is SPICE an odd choice for remoting a physical workstation's desktop?
8.5 `disable-ticketing=on` appears in the QEMU command line above. What did it disable, and why must it never appear on a non-loopback listener?

---

## Block 9 — Choosing the protocol, and a diagnostic drill

1. Build the decision table yourself before reading it. For each protocol fill in: default port and transport, what unit of work is remoted, whether it is encrypted by default, and whether it can attach to an already-running local session.

```bash
station$ printf '%-8s %-14s %-22s %-12s %s\n' PROTO PORT UNIT ENCRYPTED ATTACH-TO-:0
```

| Protocol | Default port | What is remoted | Encrypted by default | Can attach to a running local session |
|---|---|---|---|---|
| **X11** (direct) | TCP 6000+N | Individual windows (drawing commands) | No | n/a — the client draws on your display |
| **X11 over SSH** | TCP 22 | Individual windows | **Yes** (SSH) | n/a |
| **XDMCP** | **UDP 177** (+ X11 on TCP 6000+N) | A whole new session; client supplies the X server | No | No — always a new session |
| **VNC / RFB** | TCP 5900+N | Framebuffer rectangles | No (password only; TLS via extensions) | Only with `x11vnc`, and only on X11 |
| **RDP** | TCP 3389 | Framebuffer + device/audio/clipboard channels | **Yes** (TLS/CredSSP) | Yes (`gnome-remote-desktop`, xrdp with a mirror backend) |
| **SPICE** | TCP 5900+ (site-defined, e.g. 5930) | VM display + multi-channel devices | Optional TLS | n/a — it attaches to a *guest*, not a host session |

2. Diagnostic drill. For each symptom, write the *first* command you run, then verify against the answers.

```
A. "Remote GUI over ssh -X does nothing: Error: Can't open display:"
B. "VNC viewer says 'connection refused' from the LAN, works on the server itself."
C. "xrdp accepts the password then throws me back to the login box."
D. "SPICE viewer connects but the clipboard does not work and resizing does nothing."
E. "x11vnc exits with 'XOpenDisplay failed' on a freshly installed workstation."
F. "The XDMCP greeter never appears; tcpdump on the server shows no traffic at all."
```

3. Run the universal first sweep on `srv` and read it as a whole:

```bash
srv$ ss -ltnp | grep -E ':(3389|59[0-9][0-9]|60[0-9][0-9])'
srv$ sudo ss -lunp | grep :177
srv$ sudo firewall-cmd --list-all | grep -E 'ports|services'
srv$ loginctl list-sessions
srv$ journalctl -b -u display-manager -u xrdp -u xrdp-sesman -p warning --no-pager | tail -20
```

**Check your understanding — Block 9**

9.1 Answer the six drill items A–F with the single most informative first command for each.
9.2 A branch office connects over a 180 ms satellite link and needs a full desktop with local printing. Rank X11-over-SSH, VNC and RDP for this case and justify the ranking on protocol grounds, not on preference.
9.3 Which two of the five protocols do **not** create a new session but attach to an existing display, and under exactly which conditions?
9.4 Only one protocol in this objective transports drawing primitives rather than pixels. Which one, and what is the practical consequence for bandwidth on a mostly-static screen versus a video playback?

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1

**1.1** `Xwayland` is serving `:0`. In a Wayland session the compositor (Mutter, KWin) starts a rootless X server, Xwayland, that presents itself as an ordinary X display so that legacy X11 clients keep working. Those clients talk X11 to Xwayland, which translates their surfaces into Wayland surfaces for the compositor. `$DISPLAY` is therefore set even though the session type is `wayland`.

**1.2** `XDG_CURRENT_DESKTOP`. It comes from the `DesktopNames=` key of the session's `.desktop` file (or is exported by the session startup script). `XDG_SESSION_TYPE` and `XDG_VTNR` are set by `systemd-logind` / PAM when the session is created.

**1.3** Your SSH login is its own logind session, of class `user` and type `tty`; `auto` resolves to *that* session, not the console one. Environment variables are per-process, so you cannot see the console session's `XDG_CURRENT_DESKTOP` from your shell at all. Inspect the other session explicitly:

```bash
loginctl list-sessions
loginctl show-session 2 -p Type -p Class -p Desktop -p Active -p Name
loginctl user-status alice
```

**1.4** They are the catalogues the display manager reads to build its session chooser. Entries in `/usr/share/xsessions/` are started under an Xorg display server; entries in `/usr/share/wayland-sessions/` are started as native Wayland compositors. Same file format, different execution environment.

### Block 2

**2.1** The symlink is generated. On Debian the selection is recorded in `/etc/X11/default-display-manager` (holding the full path of the DM binary) and applied by the DM packages' postinst scripts; the supported interface is `sudo dpkg-reconfigure gdm3` (or any installed DM), which rewrites that file *and* the symlink. Hand-editing the symlink is overwritten on the next package operation.

**2.2** In order of cost to test:
1. The display manager is masked or failed — `systemctl status display-manager; systemctl is-enabled display-manager`.
2. No DM is installed at all, so `graphical.target` reaches without pulling one in — `ls -l /etc/systemd/system/display-manager.service`.
3. A kernel command-line override is forcing the target — `cat /proc/cmdline` looking for `systemd.unit=multi-user.target`, `3`, or `nomodeset`/a broken GPU driver preventing the DM from starting (`journalctl -b -u display-manager`).

**2.3** `startx` runs `~/.xinitrc`, falling back to `/etc/X11/xinit/xinitrc`; the desktop is whatever that script `exec`s, and there is no chooser. A display manager reads the `.desktop` files under `/usr/share/xsessions/` and `/usr/share/wayland-sessions/`, presents them in a greeter, and runs the selected entry's `Exec=` line — with the user's last choice usually cached (e.g. in `~/.dmrc` or by AccountsService).

**2.4** `journalctl -b -u display-manager --no-pager` (add `-u gdm`/`-u sddm` if the alias is ambiguous). A crash of the compositor or the greeter is logged there together with the restart.

### Block 3

**3.1** Mutter is no longer a separate process: in a Wayland session `gnome-shell` links Mutter in as a library and *is* the compositor, window manager and shell in one address space. Consequence: there is no independent WM to restart. Under X11 you can kill and restart `metacity`/`mutter` and keep your applications and session; under Wayland, if `gnome-shell` dies the compositor dies, every client loses its connection, and the whole graphical session goes down.

**3.2** `~/.config/dconf/user` — a single binary GVDB database; corruption loses everything at once and `gsettings` may still appear to work against an in-memory copy. Dump it as text with `dconf dump /` (and reload with `dconf load /`). Check write permission and free space on `$HOME`.

**3.3** Any two of: (a) GNOME apps rely on `gnome-settings-daemon`/`xdg-desktop-portal-gnome` for theming, portals and file dialogs, and those are not running under Xfce, so `xdg-desktop-portal-gtk` must be present instead; (b) they use GSettings/dconf schemas that Xfce's Xfconf never writes, so appearance, fonts and DPI settings diverge; (c) client-side decorations (GTK headerbars) are drawn by the app, not by `xfwm4`, giving inconsistent titlebars; (d) `XDG_CURRENT_DESKTOP=XFCE` makes some GNOME apps disable shell integration.

**3.4** `kwriteconfig5`. KConfig's backing store is plain INI text under `~/.config/`, so it can be written safely with any tool — `sed`, a config-management module, or a skeleton file in `/etc/skel/` — with no daemon running and no session. `gsettings` needs a running dconf/D-Bus session bus to write (scripting it for another user requires `dbus-run-session` or writing a system-wide dconf profile plus `dconf update`), and `xfconf-query` needs the `xfconfd` D-Bus service in the target session.

### Block 4

**4.1** `srv.example.com` is the host running the **X server**; `2` is the display number, selecting which X server on that host; `1` is the screen number within that display (a multi-head arrangement exposed as separate screens). A direct TCP connection would use **6002** (6000 + display number).

**4.2** `Can't open display:` with nothing after the colon means `$DISPLAY` is unset or empty — the client does not know *where* to connect. `No protocol specified / Can't open display: localhost:10.0` means the client found the display and reached it, but the X server rejected the connection: it is an **authorisation** failure — a missing, unreadable or stale `MIT-MAGIC-COOKIE-1`, i.e. `$XAUTHORITY` pointing at the wrong file (typical after `sudo` or `su`).

**4.3** `xhost +` disables host-based access control entirely: **any** client, from any host that can reach the X server's socket or TCP port, may connect without presenting a cookie. Such a client can read every window's contents, take screenshots, inject synthetic keystrokes into any window, and log the keyboard globally. On a multi-user or network-reachable host that is a complete compromise of the desktop session. Use `xhost +SI:localuser:<name>` or, better, copy the cookie with `xauth`.

**4.4** The X **client** (the application, e.g. `xeyes`) runs on the **remote** host `srv`. The X **server** runs on **`station`**, your local machine. The terminology is inverted relative to intuition because the X server is the process that *owns and serves the display hardware* — keyboard, mouse and screen — to applications that request drawing services from it.

**4.5** Option 1: `ssh -Y` (or `ForwardX11Trusted yes`), which disables the SECURITY extension restrictions — the remote application then has unrestricted access to your local display, including reading other windows and logging all keystrokes, so it is only acceptable when you fully trust the remote host and everyone with root on it. Option 2: do not forward X11 at all — use a full-session protocol (RDP/VNC) so the application's grabs happen on the remote display, and only pixels cross the network. Option 2 is the safer answer.

**4.6** Xwayland. `sshd` on `srv` opens `localhost:10`, and the X11 traffic is tunnelled back to `station`'s `$DISPLAY=:0`, which in a Wayland GNOME session is served by Xwayland inside `gnome-shell`.

### Block 5

**5.1** The X server runs on the **client/terminal** machine (the one in front of the user). The display manager runs on the **server** and answers the XDMCP query. `gnome-shell` — and every other application — also runs on the **server**; only rendering output and input events cross the network.

**5.2** TCP **6000+N** on the client machine, because the remote applications connect back to the client's X server. XDMCP on UDP 177 only brokers the session — the actual keystrokes, window contents and clipboard travel over the unencrypted X11 stream on 6000+N. Additionally the X server must be started *without* `-nolisten tcp` for this to work at all, which reopens the port that modern distributions deliberately close.

**5.3** XDMCP is a **UDP** protocol; `ss -ltn` lists only listening TCP sockets. The correct command is `sudo ss -lunp | grep :177` (or `sudo ss -ulpn sport = :177`).

**5.4** Any two of: (a) the session is Wayland-based — a Wayland compositor cannot be exported over XDMCP at all, and GDM must be forced to Xorg (`WaylandEnable=false` in `custom.conf`); (b) current GDM builds ship with XDMCP support removed or disabled, and SDDM has never implemented it — LightDM is the practical option; (c) `[security] DisallowTCP=false` was not set, so the X side of the connection is refused; (d) the firewall drops UDP 177.

**5.5** (a) XDMCP remotes an entire session including the login greeter; `ssh -X` remotes individual applications into an already-running local session. (b) XDMCP is cleartext end to end; `ssh -X` is encrypted inside the SSH channel. (c) Both require an X server on the **client** side — but with XDMCP that X server must additionally accept inbound TCP connections from the server, whereas with SSH the tunnel makes every connection appear to originate from localhost.

### Block 6

**6.1** You deployed **virtual session mode**: `Xvnc` (via `vncserver@:1`) starts a brand-new, headless X server unrelated to the physical console. To *mirror* the screen that is physically on display `:0` you need a screen-scraping server — `x11vnc -display :0` for an X11 session, or the compositor's own sharing backend (`gnome-remote-desktop`, `krfb`) for a Wayland session.

**6.2** 5900 + 4 = **5904**. Port 5800+N historically served the built-in Java/HTTP VNC applet (`vncviewer` in a browser) shipped by some VNC servers.

**6.3** (a) The password is stored **obfuscated with a fixed, publicly known DES key, not hashed** — anyone who reads the file can recover the plaintext (`vncpwd`-type tools do it in a second), so it must be mode `0600` and owned by the user. (b) The VNC password is limited to **8 characters** in the classic VNC authentication scheme; longer input is silently truncated. It is an access token for one desktop, not a user account credential, and it does not authenticate the *server* to you.

**6.4** Cause 1: the server is bound to loopback only (`localhost` in `~/.vnc/config`, or `-localhost`). Cause 2: a firewall is dropping 5901. Discriminate with `ss -ltnp | grep 5901` on `srv` — if the local address is `127.0.0.1:5901` it is the binding; if it is `0.0.0.0:5901` the socket is open to the network and the problem is the firewall (`sudo firewall-cmd --list-ports` / `sudo iptables -L -n`).

**6.5** The VNC password authenticates the *connection* via a challenge–response handshake, but classic RFB then transmits the framebuffer, keystrokes and clipboard **in cleartext**. Everything the user types — including sudo and application passwords — is readable on the wire, and the stream can be modified in transit. The password is also recoverable from `~/.vnc/passwd` and capped at 8 characters. SSH (or a VNC build with TLS/VeNCrypt) supplies the confidentiality, integrity and server authentication that RFB does not.

**6.6** RFB is defined entirely in terms of **framebuffer rectangles and input events** — pixels in, keys and pointer events out. It makes no assumption about the windowing system producing those pixels, so any platform that can capture a framebuffer can implement the server side. X11 forwarding, by contrast, tunnels the **X protocol itself**: the remote application must be an X client linked against Xlib/XCB, and the local side must be an X server implementing the same extensions and, for anything non-trivial, matching fonts and rendering extensions.

### Block 7

**7.1** `xrdp` is the protocol front end: it listens on TCP 3389, negotiates the security layer (TLS/RDP), and multiplexes the RDP channels. `xrdp-sesman` is the session manager: it **authenticates the user** (through PAM), then creates or reconnects the backing X session (`Xorg` + `xorgxrdp`, or `Xvnc`) and runs `startwm.sh`. Authentication is `xrdp-sesman`'s job.

**7.2** **TCP 3389.** Both bind the same port, so whichever starts second fails with `Address already in use` — you get an inactive service and a "connection refused" from the client. Run exactly one RDP server per host.

**7.3** Any two of: native **device redirection** (local drives, printers, smart cards, serial ports), **audio** redirection in both directions, **TLS/CredSSP encryption and server certificate authentication** as part of the protocol, **dynamic resolution** resizing, multi-monitor support, and bitmap/RemoteFX codec compression tuned for high-latency links.

**7.4** `/var/log/xrdp-sesman.log` (or `journalctl -u xrdp-sesman`) for the authentication and session-spawn failure, and the per-session X log `~/.xorgxrdp.<display>.log` (e.g. `~/.xorgxrdp.10.log`) or `~/.xsession-errors` for a desktop that starts and immediately exits — most often because `startwm.sh` finds no window manager, or a PolicyKit/`~/.Xauthority` ownership problem after the user was created by a different mechanism.

**7.5** **`gnome-remote-desktop`.** It is the only one of the three that can share a live Wayland session: it obtains the screen content through the compositor's PipeWire screencast API and injects input through the compositor, and it speaks RDP so a stock Windows client connects with no extra software. `x11vnc` is wrong because it scrapes an X11 root window that does not exist under Wayland. `xrdp` with the Xorg/`xorgxrdp` backend is wrong because it creates a *new* X session rather than attaching to the running Wayland one, so the Windows user would see a different desktop.

### Block 8

**8.1** Any three of: **USB device redirection** from client to guest; **multi-monitor** guest displays; bidirectional **audio** channels; **bidirectional clipboard** and automatic guest resolution matching via `spice-vdagent`; video-stream detection with lossy codecs for moving regions; smart-card redirection; a multi-channel design allowing per-channel TLS and compression.

**8.2** `spice-vdagent` (plus the `spice-vdagentd` daemon) runs **inside the guest**, communicating with the client through a virtio-serial channel. Symptoms of its absence: the clipboard does not transfer between host/client and guest; resizing the viewer window does not change the guest's resolution; the mouse stays in "server mode" with a visible offset or trapped pointer instead of client mouse mode; drag-and-drop of files does not work.

**8.3** The SPICE server is bound to `127.0.0.1` on the hypervisor, so it accepts no connections from other hosts. Remedies: (1) leave the binding on loopback and tunnel — `ssh -L 5900:localhost:5900 alice@srv` then `remote-viewer spice://localhost:5900`, or simply `virt-viewer --connect qemu+ssh://alice@srv/system vm1`, which does the tunnelling for you; (2) change the libvirt domain XML `<graphics listen>` to `0.0.0.0`, open the port, **and** configure a ticket/password plus TLS — never expose a `disable-ticketing` console.

**8.4** SPICE's server side is implemented by the **hypervisor** (QEMU) around an emulated graphics device (QXL/virtio-gpu); it renders a guest's virtual display, not a physical machine's session. There is no supported SPICE server that attaches to a running Xorg or Wayland session on bare metal, and its advanced features (USB redirection, resolution matching) depend on the virtio channels and guest agent that only exist in a VM. For a physical workstation, RDP or VNC is the appropriate choice.

**8.5** It disabled the SPICE **ticket** — the connection password — so any client that can reach the port gets an unauthenticated console session with full keyboard and mouse control of the guest, equivalent to physical access. It is tolerable only because the listener is `addr=127.0.0.1`. On any non-loopback listener it hands the VM to the network; set a ticket (`-spice port=5930,password-secret=...` / `virsh` `<graphics passwd=...>` with a short `passwdValidTo`) and enable TLS.

### Block 9

**9.1**
- **A** — `echo $DISPLAY` on the remote host. Empty means forwarding never happened; then check `sshd -T | grep x11forwarding` on the server and that `xauth` is installed there.
- **B** — `ss -ltnp | grep 5901` on the server: `127.0.0.1:5901` is a binding problem, `0.0.0.0:5901` is a firewall problem.
- **C** — `sudo journalctl -u xrdp-sesman -n 30` (then `~/.xorgxrdp.10.log`).
- **D** — `systemctl status spice-vdagentd` **inside the guest**.
- **E** — `loginctl show-session auto -p Type`; `Type=wayland` explains it, and `x11vnc` is simply the wrong tool.
- **F** — `sudo ss -lunp | grep :177` on the server: nothing listening means XDMCP is not enabled (or the DM does not support it), not a network problem. If it is listening, check the firewall for UDP 177.

**9.2** **RDP first**, then **VNC**, then **X11-over-SSH last**. X11 is the worst possible choice on a high-latency link because the protocol is **round-trip intensive** — clients make synchronous requests to the server for many operations, so each one costs 180 ms and the interface becomes unusable regardless of bandwidth; it also has no printing redirection. VNC is latency-tolerant (it pushes framebuffer updates asynchronously) but has no printer redirection, weak compression compared with RDP, and no native encryption. RDP wins on all three counts: asynchronous, aggressively compressed with codecs designed for WAN use, natively encrypted, and it carries printer and drive redirection as protocol channels.

**9.3** **X11** and **VNC**. X11 does not create a session at all — a forwarded application draws into the X server you are already running, so "attaching" is inherent, but it applies to individual windows, not to a whole existing session. VNC attaches to an existing display only in mirror mode, i.e. with `x11vnc -display :0` and only when that display is a real **X11** server (not Xwayland-under-a-compositor, where no shareable root window exists). RDP can also attach, but only through a compositor-integrated implementation such as `gnome-remote-desktop`, not through stock `xrdp`. XDMCP and SPICE always target a new session and a VM guest respectively.

**9.4** **X11.** It transports drawing primitives and window-system requests (with pixmaps and images only when the client sends them). Consequence: on a mostly-static screen with simple widgets, X11 uses far less bandwidth than any framebuffer protocol, because nothing is transmitted at all when nothing changes and a redraw costs a few hundred bytes of requests. During video playback the relationship inverts badly — modern toolkits push fully rendered client-side pixmaps, so X11 ends up shipping raw or barely-compressed frames with no video codec, while VNC, RDP and SPICE apply motion-aware compression and detect video regions.

</details>

---

### Sources

- LPI — Exam 101-500 Objectives (v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Exam 102-500 Objectives (v5.0): https://www.lpi.org/our-certifications/exam-102-objectives/
- X.Org Foundation — `Xserver(1)`, `Xsecurity(7)`, `xauth(1)`, `xhost(1)`: https://www.x.org/releases/current/doc/man/
- X.Org Foundation — XDMCP specification: https://www.x.org/releases/current/doc/xorg-docs/xdmcp/xdmcp.html
- freedesktop.org — Desktop Entry Specification: https://specifications.freedesktop.org/desktop-entry-spec/latest/
- freedesktop.org — Wayland and Xwayland: https://wayland.freedesktop.org/xserver.html
- systemd — `loginctl(1)` and `systemd-logind.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/loginctl.html
- OpenSSH — `ssh(1)` / `sshd_config(5)`, X11 forwarding: https://man.openbsd.org/ssh
- IETF RFC 6143 — The Remote Framebuffer Protocol: https://www.rfc-editor.org/rfc/rfc6143
- TigerVNC — documentation and `vncserver`/`Xvnc` manuals: https://tigervnc.org/doc/
- xrdp — project documentation: https://github.com/neutrinolabs/xrdp/wiki
- FreeRDP — command-line reference: https://github.com/FreeRDP/FreeRDP/wiki/CommandLineInterface
- SPICE — protocol and `spice-vdagent`: https://www.spice-space.org/documentation.html
- QEMU — display device and SPICE options: https://www.qemu.org/docs/master/system/invocation.html
- libvirt — Graphical framebuffer devices in the domain XML: https://libvirt.org/formatdomain.html#graphical-framebuffers
- GNOME — `gnome-remote-desktop` / `grdctl`: https://gitlab.gnome.org/GNOME/gnome-remote-desktop
- GNOME — GSettings and dconf: https://help.gnome.org/admin/system-admin-guide/stable/dconf.html.en
- KDE — KConfig and `kwriteconfig`: https://develop.kde.org/docs/features/configuration/
- Xfce — Xfconf documentation: https://docs.xfce.org/xfce/xfconf/start