# Practical Exercises: Topic 1.1 (System Architecture)

### Exercise 1: Exploring Hardware and PCI Devices
System reliability starts with understanding the hardware abstraction layer. In this exercise, you will explore how Linux represents USB and PCI buses using standardized tools.

1. **Identify USB Topologies:** Connect an external USB device to your lab machine. Identify all USB devices connected to your system in a tree-like format using the `lsusb` command. Observe how the root hubs are structured.
2. **Filter PCI Devices:** Execute the `lspci` command. Use standard text processing commands (like `grep`) to filter the output of `lspci` and display only the Ethernet or Network controllers alongside the kernel modules they are currently using. Note the driver in use.
3. **Analyze System Interrupts:** Hardware devices notify the CPU using interrupts. List the system's IRQ (Interrupt ReQuest) assignments for CPU 0 using the `/proc/interrupts` file. Look specifically for the `timer` and `rtc0` interrupts.

**Questions:**
- What specific parameter tells the `lsusb` command to display the devices as a hierarchical tree?
- In the `/proc/interrupts` output, what type of controller or device typically handles timer interrupts for modern processors?
- Which flag can be passed to `lspci` to list both the device and the kernel driver in use?

---

### Exercise 2: Understanding and Manipulating Systemd Targets
Modern Linux distributions use `systemd` to manage the boot sequence and running services. Understanding how to transition between targets is critical for maintenance operations.

1. **Determine Default State:** Determine the current default systemd target that the system boots into by using the appropriate `systemctl` subcommand.
2. **List Active Units:** List all currently loaded and active target units running on the system to understand what milestones have been reached.
3. **Isolate Maintenance Mode:** Change the active state of the system into `rescue.target` without rebooting. This simulates dropping into a single-user or maintenance mode for critical troubleshooting. *Note: Ensure you run this in a safe lab environment as it will stop network services.*

**Questions:**
- What is the equivalent of the legacy SysVinit "Runlevel 3" in the systemd architecture?
- Which specific `systemctl` subcommand is used to transition to a new target immediately without rebooting?
- How does `rescue.target` differ from `emergency.target` in terms of filesystem mounting?

---

### Exercise 3: Udev Rules and Persistent Device Naming
Dynamic device naming can break automated mounting scripts in production. In this exercise, you will create a rule to statically identify a device.

1. **Monitor Udev Events:** Start monitoring udev kernel events in the terminal using `udevadm monitor --kernel --property --subsystem-match=block`. Plug in a USB flash drive or attach an iSCSI LUN, and watch the event log to capture its WWN or serial ID.
2. **Simulate an Event:** Run `udevadm test` against the `/sys/class/block/` path of a block device (e.g. `/sys/class/block/sda`) to see how systemd-udevd would evaluate its rules without actually applying them.

**Questions:**
- Where should an administrator place custom user-defined udev rules?
- What `ACTION` keyword is matched in a udev rule when a device is plugged in?

---

<details>
<summary>Answers</summary>

**Exercise 1 Answers:**
- The parameter `-t` tells `lsusb` to display the USB hierarchy as a tree (`lsusb -t`).
- Timer interrupts are typically handled by `IR-IO-APIC` or the Local APIC timer, frequently mapped to IRQ 0 in standard x86 architectures.
- The `-k` flag tells `lspci` to display the kernel modules handling each device (`lspci -k`).

**Exercise 2 Answers:**
- The systemd equivalent for Runlevel 3 (multi-user without graphical interface) is `multi-user.target`.
- The command `sudo systemctl isolate <target>` is used to change the active target immediately without rebooting.
- `rescue.target` mounts all local filesystems and starts basic essential services, whereas `emergency.target` only mounts the root filesystem as read-only and starts absolutely nothing else.

**Exercise 3 Answers:**
- Custom, user-defined udev rules should be placed in `/etc/udev/rules.d/`. (The `/usr/lib/udev/rules.d/` directory is reserved for system defaults and package managers).
- The `ACTION=="add"` keyword is matched when a new device is plugged into the system and discovered by the kernel.
</details>