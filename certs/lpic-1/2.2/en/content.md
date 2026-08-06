# Topic 2.2: Interfaces and Desktops (LPIC-1)

## 1. Motivation and Production Architectural Problem

In traditional server environments, Graphical User Interfaces (GUIs) are typically avoided to reduce attack surfaces, minimize resource consumption, and ensure stability. However, as a Platform Architect or SRE, you will encounter scenarios requiring graphical interfaces: Virtual Desktop Infrastructure (VDI), bastion hosts for secure administrative browsing, kiosk systems, developer workstations, and scientific computing nodes running heavily visual applications. 

The core architectural problem lies in the secure, performant, and reliable delivery of graphical environments over network boundaries, as well as managing the underlying graphical stack (X11/Wayland) in a reproducible manner. Understanding the Linux graphics stack is critical when diagnosing high CPU usage from display managers, handling GPU driver incompatibilities, or setting up secure remote desktop access for engineering teams.

## 2. Technical Comparisons and Trade-offs

### Display Server Protocols: X11 vs. Wayland

The Linux graphical stack has been undergoing a long transition from the legacy X Window System (X11) to Wayland.

| Feature / Architecture | X11 (Xorg) | Wayland |
| :--- | :--- | :--- |
| **Architecture** | Client/Server model. The X server acts as a middleman between clients and the compositor/kernel. | Direct rendering. The compositor *is* the display server. Clients talk directly to the compositor. |
| **Security** | Weak isolation. Any X client can capture keystrokes (keylogging) or window contents of other clients. | Strong isolation. Clients cannot inherently access the buffers of other clients. |
| **Performance** | Higher overhead due to IPC and context switching between X server and compositor. | Lower overhead, zero-copy buffer sharing, no tearing by design. |
| **Network Transparency** | Native support for forwarding over SSH (`ssh -X` / `ssh -Y`). | No native network transparency (requires external protocols like Waypipe, VNC, or RDP). |
| **Legacy Support** | Universal legacy application support. | Uses XWayland as a compatibility layer for X11-only applications. |

### Desktop Environments (DE) vs. Window Managers (WM)

| Category | Examples | Use Case | Memory Footprint |
| :--- | :--- | :--- | :--- |
| **Full Desktop Environments** | GNOME, KDE Plasma | Developer workstations, standard user VDI. | Heavy (1GB+ baseline) |
| **Lightweight DEs** | XFCE, LXQt | Resource-constrained VMs, legacy hardware, remote thin clients. | Medium (300MB - 600MB) |
| **Tiling Window Managers** | i3, Sway (Wayland) | Power users, keyboard-centric workflows, highly customized kiosks. | Very Light (< 100MB) |

## 3. Infrastructure as Code: Desktop Configuration

For automated provisioning of a graphical kiosk or a developer VDI, you can use Ansible to configure the Display Manager (e.g., LightDM) and auto-login.

### Ansible Playbook: `vdi-setup.yaml`

```yaml
---
- name: Configure Linux Workstation VDI
  hosts: workstations
  become: yes
  tasks:
    - name: Install XFCE and LightDM
      apt:
        name:
          - xfce4
          - xfce4-goodies
          - lightdm
          - xserver-xorg
        state: present
        update_cache: yes

    - name: Ensure LightDM is the default display manager
      debconf:
        name: lightdm
        question: shared/default-x-display-manager
        value: lightdm
        vtype: select

    - name: Configure LightDM for Auto-login (Kiosk/VDI mode)
      copy:
        dest: /etc/lightdm/lightdm.conf.d/50-autologin.conf
        content: |
          [Seat:*]
          autologin-user=vdi-user
          autologin-user-timeout=0
          user-session=xfce
        owner: root
        group: root
        mode: '0644'
      notify: Restart LightDM

  handlers:
    - name: Restart LightDM
      systemd:
        name: lightdm
        state: restarted
```

### Xorg Configuration Example (`/etc/X11/xorg.conf.d/10-monitor.conf`)

While most modern Xorg servers auto-configure via `udev` and KMS (Kernel Mode Setting), explicit configurations are sometimes required for specific driver or monitor setups.

```text
Section "Monitor"
    Identifier  "DP-1"
    Option      "Primary" "true"
    Option      "PreferredMode" "1920x1080"
EndSection

Section "Device"
    Identifier  "Intel Graphics"
    Driver      "intel"
    Option      "TearFree" "true"
EndSection

Section "Screen"
    Identifier  "Default Screen"
    Device      "Intel Graphics"
    Monitor     "DP-1"
    DefaultDepth 24
EndSection
```

## 4. CLI Commands and Terminal Outputs

### 4.1 Checking Display Server Protocol
To determine whether an environment is running X11 or Wayland, inspect the `XDG_SESSION_TYPE` environment variable.

```bash
$ echo $XDG_SESSION_TYPE
wayland
```

### 4.2 Querying Connected Displays with `xrandr` (X11)
`xrandr` interfaces with the RandR (Resize and Rotate) extension to configure outputs.

```bash
$ xrandr --query
Screen 0: minimum 8 x 8, current 1920 x 1080, maximum 32767 x 32767
eDP1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 310mm x 170mm
   1920x1080     60.01*+  59.93  
DP1 disconnected (normal left inverted right x axis y axis)
HDMI1 disconnected (normal left inverted right x axis y axis)
```

Setting resolution manually:
```bash
$ xrandr --output eDP1 --mode 1920x1080 --rate 60.00
```

### 4.3 Forwarding X11 over SSH
Securely forward individual graphical applications to a remote client. Ensure `X11Forwarding yes` is set in the server's `/etc/ssh/sshd_config`.

```bash
# Connect with trusted X11 forwarding
$ ssh -Y user@bastion.internal.local
# Launch application; window renders on local machine
$ virt-manager &
```

### 4.4 Managing Display Managers
The Display Manager handles user authentication and session instantiation.

```bash
$ systemctl status gdm.service
● gdm.service - GNOME Display Manager
     Loaded: loaded (/lib/systemd/system/gdm.service; enabled; vendor preset: enabled)
     Active: active (running) since Wed 2026-08-05 10:00:00 UTC; 2 days ago
   Main PID: 1205 (gdm3)
      Tasks: 3 (limit: 18880)
     Memory: 5.6M
```

## 5. Troubleshooting and Fault Diagnosis

### Scenario A: X Server Fails to Start (Black Screen or Console Fallback)
**Symptoms:** The system boots, but the graphical target fails, dropping the user to a `tty`.
**Diagnosis:**
1. Check the Display Manager logs via systemd.
   ```bash
   $ journalctl -u lightdm.service -e
   ```
2. Inspect the Xorg log for fatal errors (`EE`).
   ```bash
   $ grep "(EE)" /var/log/Xorg.0.log
   [    15.201] (EE) open /dev/dri/card0: No such file or directory
   [    15.201] (EE) Screen 0 deleted because of no matching config section.
   ```
**Resolution:** This often indicates a missing or incompatible GPU driver (e.g., missing `nouveau` or proprietary NVIDIA modules). Verify kernel modules: `lsmod | grep -E 'nvidia|nouveau|amdgpu|i915'`. Ensure proper firmware is installed (e.g., `linux-firmware`).

### Scenario B: High CPU Usage in Xorg/Wayland Compositor
**Symptoms:** `top` or `htop` shows `Xorg` or `gnome-shell`/`kwin_wayland` consuming >90% CPU continuously.
**Diagnosis:**
1. Identify if a specific application is causing a redraw loop. Under X11, use `xrestop` to analyze resource usage per client.
   ```bash
   $ xrestop
   ```
2. If it's a global issue, check if hardware acceleration is disabled (rendering via software pipeline like `llvmpipe`).
   ```bash
   $ glxinfo -B | grep "OpenGL renderer"
   OpenGL renderer string: llvmpipe (LLVM 12.0.0, 256 bits)
   ```
**Resolution:** Software rendering uses massive CPU. Ensure Mesa drivers (`libgl1-mesa-dri`) are installed and the GPU is correctly mapped in `/dev/dri/`.

### Scenario C: Accessibility Features Causing Unexpected Input
**Symptoms:** Keystrokes repeat slowly (Bounce Keys) or modifier keys "stick" (Sticky Keys), making administration difficult.
**Diagnosis & Resolution:**
Accessibility daemons might have been triggered accidentally (e.g., holding Shift for 8 seconds).
Disable accessibility daemons (like `at-spi2-registryd`) or reset GNOME accessibility settings:
```bash
$ gsettings set org.gnome.desktop.a11y.keyboard stickykeys-enable false
$ gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-enable false
```

## 6. References

- X.Org Foundation Documentation: https://www.x.org/wiki/
- Wayland Architecture: https://wayland.freedesktop.org/architecture.html
- ArchWiki - Xorg: https://wiki.archlinux.org/title/Xorg
- ArchWiki - Wayland: https://wiki.archlinux.org/title/Wayland
- LPIC-1 Exam Objectives (Version 5.0): https://www.lpi.org/our-certifications/exam-101-objectives/