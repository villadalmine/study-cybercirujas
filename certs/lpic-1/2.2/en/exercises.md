# Exercises: Interfaces and Desktops (Topic 2.2)

## Exercise 1: Identifying the Display Server

As a Platform Architect, you must first identify the underlying graphical stack before applying configuration or debugging.

1. Open a terminal in your graphical environment (or SSH into a VDI workstation).
2. Execute the following command to determine the active display server protocol:
   ```bash
   echo $XDG_SESSION_TYPE
   ```
3. Look at the running processes to confirm the compositor/X server process:
   ```bash
   ps aux | grep -E 'Xorg|wayland'
   ```

**Question 1.1:** What is the fundamental architectural difference between `Xorg` and `Wayland` when it comes to the display server and the compositor?
**Question 1.2:** If `echo $XDG_SESSION_TYPE` returns `wayland`, what role does `XWayland` play?

---

## Exercise 2: Managing Display Outputs with `xrandr`

You are configuring a headless server that occasionally runs GUI tools forwarded to an administrator's screen, and a local terminal kiosk setup. For the local kiosk running X11, you need to manage resolution.

1. Query the available displays and supported resolutions:
   ```bash
   xrandr --query
   ```
2. Identify the primary connected interface (e.g., `eDP1`, `DP-1`, `HDMI-1`).
3. Set the display resolution manually to `1920x1080`:
   ```bash
   xrandr --output <YOUR_INTERFACE> --mode 1920x1080
   ```

**Question 2.1:** What happens if you try to run `xrandr` in a pure Wayland session without `XWayland`?
**Question 2.2:** How can you make this X11 monitor configuration persistent across reboots without relying on desktop environment GUI tools?

---

## Exercise 3: Inspecting the Display Manager

The Display Manager is responsible for starting the X server (or Wayland compositor) and handling user authentication.

1. Check which Display Manager is currently active on your system:
   ```bash
   systemctl status display-manager.service
   ```
2. Inspect the configuration directory for LightDM (if installed/used) or GDM:
   ```bash
   cat /etc/lightdm/lightdm.conf 2>/dev/null || cat /etc/gdm3/custom.conf
   ```

**Question 3.1:** What configuration line in `lightdm.conf` enables auto-login for a specific user, bypassing the authentication prompt?
**Question 3.2:** If a system boots to a black screen after an update, which systemd journal command would you run to diagnose a failing Display Manager?

---

<details>
<summary><strong>Answers</strong></summary>

**Answer 1.1:** In X11, the X Server acts as a middleman between clients and the compositor. Clients send drawing requests to the X server, which sends them to the compositor to render. In Wayland, the compositor *is* the display server. Clients render their own buffers and pass them directly to the compositor, significantly reducing overhead and IPC latency.

**Answer 1.2:** `XWayland` acts as a compatibility layer. It runs a localized X server on top of Wayland, allowing legacy X11 applications that haven't been ported to Wayland to run seamlessly within the Wayland compositor.

**Answer 2.1:** `xrandr` is an X11-specific tool that interfaces with the RandR extension of the X server. In a pure Wayland environment, it will fail to connect to the display server. Wayland compositors have their own tools (e.g., `wlr-randr` for wlroots-based compositors) to handle display outputs.

**Answer 2.2:** You make the configuration persistent by creating an Xorg configuration file in `/etc/X11/xorg.conf.d/` (e.g., `10-monitor.conf`) and defining a `Monitor` section specifying the `PreferredMode`, along with linking it in a `Screen` section.

**Answer 3.1:** To enable auto-login in LightDM, you add or modify the `autologin-user=<username>` directive under the `[Seat:*]` section in the configuration file.

**Answer 3.2:** You would run `journalctl -u display-manager.service -e` (or specifically `-u gdm.service` / `-u lightdm.service`) to see the end of the logs for the Display Manager service, which usually captures X server fatal errors (like missing GPU drivers).
</details>