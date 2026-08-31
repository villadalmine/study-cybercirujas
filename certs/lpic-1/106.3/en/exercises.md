# LPIC-1 — Topic 106.3: Accessibility
## Guided Exercises (Exam 102-500, version 5.0)

> **Scope of the objective.** *Accessibility* covers the assistive technologies a Linux desktop and a Linux text console expose: visual settings and themes, screen magnifier, screen reader, braille display, desktop keyboard accessibility (AccessX: Sticky/Slow/Bounce/Toggle/Repeat/Mouse Keys), gestures, on-screen keyboard and text-to-speech.
> Official objective list: <https://www.lpi.org/our-certifications/exam-102-objectives/> (the 101 objective list referenced in the syllabus header covers topics 101–104; 106.x lives in the 102-500 list).

### Before you start

These exercises **change the state of a running desktop session**. Run them in a disposable VM or a live image, or be ready to revert — every block ends with an explicit rollback step.

Packages used across the exercises (names for Debian/Ubuntu, then Fedora/RHEL):

```bash
# Debian / Ubuntu
sudo apt install x11-xserver-utils xkbset xinput xdotool xvkbd onboard \
     at-spi2-core python3-pyatspi accerciser espeak-ng festival \
     speech-dispatcher speech-dispatcher-espeak-ng orca brltty brltty-x11 \
     kbd console-setup xzoom

# Fedora / RHEL
sudo dnf install xorg-x11-server-utils xkbset xinput xdotool xvkbd onboard \
     at-spi2-core accerciser espeak-ng festival \
     speech-dispatcher speech-dispatcher-espeak orca brltty brltty-at-spi2 \
     kbd
```

Anything that starts with `x` (`xset`, `xkbset`, `xvkbd`, `xdotool`, `xprop`, `xev`) speaks the X11 protocol. Under a Wayland session those tools either fail or only affect XWayland clients — Block 1 makes you determine which world you are in **before** you draw conclusions from them.

---

## Block 1 — Reconnaissance: which accessibility stack am I actually running?

**Objective:** establish the display server, the toolkit bridge and the inventory of installed assistive technologies, so that later failures are attributed to the right layer.

1. Identify the session type and the seat:

   ```bash
   echo "$XDG_SESSION_TYPE"
   loginctl show-session "$(loginctl show-user "$USER" -p Display --value)" \
       -p Id -p Type -p Class -p Remote -p Active
   ```

   ```
   x11
   Id=2
   Type=x11
   Class=user
   Remote=no
   Active=yes
   ```

2. Identify the desktop environment, because the GSettings keys used in Blocks 4 and 5 are GNOME schemas:

   ```bash
   echo "$XDG_CURRENT_DESKTOP" "$DESKTOP_SESSION"
   ```

3. List the accessibility-related processes that are already running:

   ```bash
   ps -ef | grep -E 'at-spi|orca|brltty|onboard|speech-dispatcher' | grep -v grep
   ```

   ```
   user  1531  1  0 09:12 ?  00:00:00 /usr/libexec/at-spi-bus-launcher
   user  1540  1  0 09:12 ?  00:00:00 /usr/libexec/at-spi2-registryd --use-gnome-session
   ```

4. Inventory what is installed but not running:

   ```bash
   for b in orca brltty xbrlapi onboard xvkbd espeak-ng espeak festival \
            spd-say accerciser xzoom kmag setfont setterm kbdrate xkbset; do
       printf '%-12s %s\n' "$b" "$(command -v "$b" || echo '-- not installed --')"
   done
   ```

5. Check whether the GNOME accessibility schemas exist on this machine (they ship with `gsettings-desktop-schemas`, independently of whether GNOME Shell is running):

   ```bash
   gsettings list-schemas | grep -i a11y | sort
   ```

   ```
   org.gnome.desktop.a11y
   org.gnome.desktop.a11y.applications
   org.gnome.desktop.a11y.interface
   org.gnome.desktop.a11y.keyboard
   org.gnome.desktop.a11y.magnifier
   org.gnome.desktop.a11y.mouse
   ```

6. Record a baseline of everything you are about to modify, so you can diff later:

   ```bash
   mkdir -p ~/a11y-lab
   gsettings list-recursively org.gnome.desktop.a11y            > ~/a11y-lab/base-a11y.txt
   gsettings list-recursively org.gnome.desktop.a11y.keyboard  >> ~/a11y-lab/base-a11y.txt
   gsettings list-recursively org.gnome.desktop.a11y.magnifier >> ~/a11y-lab/base-a11y.txt
   gsettings list-recursively org.gnome.desktop.interface      >> ~/a11y-lab/base-a11y.txt
   dconf dump /org/gnome/desktop/a11y/ > ~/a11y-lab/base-a11y.dconf
   [ "$XDG_SESSION_TYPE" = x11 ] && xkbset q > ~/a11y-lab/base-xkb.txt
   wc -l ~/a11y-lab/*
   ```

**Check your understanding**

- **Q1.1** You run `xkbset q` and get `Can't open display`. Give two distinct root causes and the command that distinguishes them.
- **Q1.2** `at-spi2-registryd` is running but `at-spi-bus-launcher` is not. What is broken, and what does each of those two processes do?
- **Q1.3** Why does `gsettings list-schemas | grep a11y` return results on a machine running KDE Plasma with no GNOME session installed?
- **Q1.4** Which of the tools in step 4 are useless in a pure Wayland session, and which one of them still works because it does not touch the display server at all?

---

## Block 2 — The AT-SPI2 accessibility bus

**Objective:** understand the transport every GUI screen reader, magnifier tracker and on-screen keyboard depends on. AT-SPI2 (Assistive Technology Service Provider Interface, v2) is a **D-Bus** protocol: applications export their widget tree as accessible objects, and assistive tools consume it. Reference: <https://www.freedesktop.org/wiki/Accessibility/AT-SPI2/>

1. Ask the session bus where the accessibility bus lives:

   ```bash
   gdbus call --session --dest org.a11y.Bus \
              --object-path /org/a11y/bus \
              --method org.a11y.Bus.GetAddress
   ```

   ```
   ('unix:path=/run/user/1000/at-spi/bus_0,guid=1f3c...',)
   ```

2. Under X11, the same address is published as a property on the root window — this is the fallback path used by toolkits that cannot reach the session bus:

   ```bash
   xprop -root AT_SPI_BUS
   ```

   ```
   AT_SPI_BUS(STRING) = "unix:path=/run/user/1000/at-spi/bus_0,guid=1f3c..."
   ```

3. Read the master toolkit switch. This key is what actually makes GTK and Qt applications load their accessibility bridges:

   ```bash
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   gsettings set org.gnome.desktop.interface toolkit-accessibility true
   ```

4. Start a GTK application **with** and **without** the bridge and compare. `NO_AT_BRIDGE=1` is the GTK escape hatch; `QT_ACCESSIBILITY=1` is the Qt equivalent:

   ```bash
   gedit &                       # or gnome-text-editor / any GTK app
   NO_AT_BRIDGE=1 gedit &
   ```

5. Enumerate the applications currently visible on the accessibility bus:

   ```bash
   python3 - <<'PY'
   import pyatspi
   for app in pyatspi.Registry.getDesktop(0):
       print(f"{app.name:<28} role={app.getRoleName():<20} children={app.childCount}")
   PY
   ```

   ```
   gedit                        role=application         children=1
   gnome-shell                  role=application         children=3
   ```

   The application launched with `NO_AT_BRIDGE=1` is absent from that list.

6. Watch the bus traffic while you move focus between widgets — this is exactly what Orca subscribes to:

   ```bash
   dbus-monitor --address "$(busctl --user call org.a11y.Bus /org/a11y/bus \
        org.a11y.Bus GetAddress | cut -d'"' -f2)" \
        "type='signal',interface='org.a11y.atspi.Event.Object'" | head -40
   ```

7. Inspect the same tree interactively:

   ```bash
   accerciser &
   ```

8. Restore the original value of `toolkit-accessibility` from your baseline file if you changed it.

**Check your understanding**

- **Q2.1** Why does AT-SPI2 use a *separate* D-Bus daemon instead of the ordinary session bus?
- **Q2.2** An application appears on screen but Orca announces nothing and it is missing from the `pyatspi` listing. List three independent causes, ordered from most to least likely.
- **Q2.3** What is the practical difference between `toolkit-accessibility=false` and `NO_AT_BRIDGE=1`?
- **Q2.4** A user reports that accessibility works in GTK applications but not in a Qt one. Which environment variable do you check first, and why is the GTK side unaffected by it?

---

## Block 3 — AccessX: keyboard accessibility in X11

**Objective:** drive Sticky Keys, Slow Keys, Bounce Keys, Toggle Keys, Repeat Keys and Mouse Keys directly through the XKB extension, below the desktop's settings GUI. `xkbset` manipulates `XkbSetControls`; `xset` manipulates the core keyboard controls.

1. Dump the current AccessX state and keep it in view in a second terminal:

   ```bash
   xkbset q
   ```

   ```
   Bell Settings:
       On - AudibleBell      On - Bell (Global)
   Sticky Keys:
       Off - StickyKeys
       Off - TwoKeys         Off - LatchLock
   Mouse Keys:
       Off - MouseKeys       Off - MouseKeysAccel
        Delay: 160    Interval: 40    Time to Max: 30
        Max Speed: 10   Curve: 0
   Access X Keys:
       Off - AccessXKeys
   Access X Timeout:
        Timeout: 0    ...
   Slow Keys:
       Off - SlowKeys
        Delay: 300
   Bounce Keys:
       Off - BounceKeys
        Delay: 300
   ```

   *(Output abridged; field order varies slightly between versions.)*

2. Enable **Sticky Keys** and test it. Sticky Keys latches a modifier so that `Ctrl`+`Alt`+`Del` can be typed one key at a time:

   ```bash
   xkbset sticky -twokey -latchlock
   xkbset q | grep -A2 'Sticky'
   ```

   Now press `Ctrl`, release it, then press `T` in a terminal-capable application. The modifier applied even though it was not held.

   * `-twokey` disables "pressing two keys at once turns Sticky Keys off".
   * `-latchlock` disables "pressing a modifier twice locks it".

3. Enable the **AccessX key sequences**, which let a user turn features on without a mouse:

   ```bash
   xkbset a
   ```

   Now: press `Shift` five times in a row → Sticky Keys toggles. Hold `Shift` for eight seconds → Slow Keys toggles.

4. Deal with the **AccessX timeout**, the classic trap: AccessX features are switched off automatically after a period of inactivity. Declare which features must survive the timeout:

   ```bash
   xkbset exp '=sticky' '=twokey' '=latchlock' '=mousekeys' '=accessx'
   xkbset q | grep -A6 'Timeout'
   man 1 xkbset      # confirm the exact expiry syntax of your version
   ```

5. **Slow Keys** — a key must be held for *N* milliseconds before it registers, which filters unintended brushes against the keyboard. Set a deliberately obvious 800 ms and type:

   ```bash
   xkbset sl 800
   xkbset q | grep -A2 'Slow'
   # ...type something, notice the lag...
   xkbset -sl
   ```

6. **Bounce Keys** (a.k.a. debounce) — a repeated press of the *same* key is ignored for *N* ms, which filters tremor:

   ```bash
   xkbset bo 700
   # hammer the "a" key: only the first press per 700 ms registers
   xkbset -bo
   ```

7. **Mouse Keys** — drive the pointer from the numeric keypad:

   ```bash
   xkbset m
   xkbset ma 60 10 10 20 5     # delay interval time_to_max max_speed curve
   xkbset exp '=mousekeys' '=mousekeysaccel'
   ```

   With NumLock in the appropriate state: `8/2/4/6` move the pointer, `5` clicks, `+` double-clicks, `/ * -` select the left/middle/right button.

8. **Repeat Keys** — auto-repeat is a core X control, not an AccessX one. Slow the repeat down for a user who cannot release keys quickly:

   ```bash
   xset q | sed -n '/Keyboard Control/,/^$/p'
   xset r rate 1000 8          # 1000 ms delay, 8 repeats/second
   xset -r 36                  # disable auto-repeat for keycode 36 (Return) only
   xset r 36                   # re-enable it
   ```

   Find a keycode with `xev -event keyboard | grep keycode`.

9. **Toggle Keys** — an audible beep when a locking modifier changes state. In X this is the AccessX feedback group; the desktop-level switch is covered in Block 4:

   ```bash
   xkbset bell               # ensure the bell is on
   xset b 100 1000 100       # volume% pitch(Hz) duration(ms)
   xkbset q | grep -A4 'Feedback'
   ```

10. Roll everything back:

    ```bash
    xkbset -sticky -twokey -latchlock -m -ma -sl -bo -a
    xset r rate 660 25
    xkbset q | diff -u ~/a11y-lab/base-xkb.txt - || echo "state differs — inspect above"
    ```

**Check your understanding**

- **Q3.1** Distinguish Slow Keys from Bounce Keys in one sentence each, and give the disability each one addresses.
- **Q3.2** A user enables Mouse Keys with `xkbset m`, it works, and ~2 minutes later it stops. What happened and what is the fix?
- **Q3.3** Why is Repeat Keys configured with `xset` while Sticky Keys is configured with `xkbset`?
- **Q3.4** Sticky Keys is on, and the user complains that it "randomly turns itself off". Which two `xkbset` sub-options are responsible, and how do you neutralise them?
- **Q3.5** With Sticky Keys enabled but `latchlock` on, what happens if the user presses `Shift` twice?
- **Q3.6** You need per-keycode auto-repeat suppression for a single stuck key. Which command, and how do you obtain the keycode?

---

## Block 4 — GSettings/dconf: the desktop-level accessibility tree

**Objective:** configure the same features through the layer the GUI Settings panel uses, and observe the relationship between the two layers. `gsettings` is the CLI front end to dconf; `org.gnome.desktop.a11y.*` is where the desktop stores accessibility state.

1. Open a watcher in a second terminal and leave it running for the whole block:

   ```bash
   dconf watch /org/gnome/desktop/a11y/
   ```

2. Enumerate the keyboard accessibility keys and their current values:

   ```bash
   gsettings list-recursively org.gnome.desktop.a11y.keyboard | sort
   ```

   ```
   org.gnome.desktop.a11y.keyboard bouncekeys-beep-reject false
   org.gnome.desktop.a11y.keyboard bouncekeys-delay 300
   org.gnome.desktop.a11y.keyboard bouncekeys-enable false
   org.gnome.desktop.a11y.keyboard enable false
   org.gnome.desktop.a11y.keyboard mousekeys-accel-time 1200
   org.gnome.desktop.a11y.keyboard mousekeys-enable false
   org.gnome.desktop.a11y.keyboard mousekeys-init-delay 160
   org.gnome.desktop.a11y.keyboard mousekeys-max-speed 750
   org.gnome.desktop.a11y.keyboard slowkeys-beep-accept false
   org.gnome.desktop.a11y.keyboard slowkeys-delay 300
   org.gnome.desktop.a11y.keyboard slowkeys-enable false
   org.gnome.desktop.a11y.keyboard stickykeys-enable false
   org.gnome.desktop.a11y.keyboard stickykeys-modifier-beep true
   org.gnome.desktop.a11y.keyboard stickykeys-two-key-off true
   org.gnome.desktop.a11y.keyboard togglekeys-enable false
   ```

3. Turn on the master AccessX switch and Sticky Keys through the desktop layer, then verify that the X layer changed underneath:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard enable true
   gsettings set org.gnome.desktop.a11y.keyboard stickykeys-enable true
   xkbset q | grep -A2 'Sticky'
   ```

4. Configure Slow Keys and Bounce Keys with audible feedback:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard slowkeys-enable true
   gsettings set org.gnome.desktop.a11y.keyboard slowkeys-delay 500
   gsettings set org.gnome.desktop.a11y.keyboard slowkeys-beep-accept true
   gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-enable true
   gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-delay 500
   gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-beep-reject true
   ```

5. Enable **Toggle Keys** — the beep on Caps/Num/Scroll Lock — which has no direct `xkbset` sub-command:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard togglekeys-enable true
   ```

6. Turn on the three assistive applications from the CLI. These are the exact keys the Settings → Accessibility panel writes:

   ```bash
   gsettings list-keys org.gnome.desktop.a11y.applications
   gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
   gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled true
   gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
   ```

7. Show the accessibility menu in the top bar so the state is visible without the CLI:

   ```bash
   gsettings set org.gnome.desktop.a11y always-show-universal-access-status true
   ```

8. Explore the pointer/click-assist schema (dwell click and secondary-click delay), which is the "gestures" side of the objective on a desktop:

   ```bash
   gsettings list-recursively org.gnome.desktop.a11y.mouse
   gsettings set org.gnome.desktop.a11y.mouse dwell-click-enabled true
   gsettings set org.gnome.desktop.a11y.mouse dwell-time 1.2
   gsettings set org.gnome.desktop.a11y.mouse secondary-click-enabled true
   gsettings set org.gnome.desktop.a11y.mouse secondary-click-time 1.5
   ```

9. Reset a single key, then a whole schema:

   ```bash
   gsettings reset org.gnome.desktop.a11y.keyboard slowkeys-delay
   gsettings reset-recursively org.gnome.desktop.a11y.keyboard
   ```

10. Restore the full baseline captured in Block 1:

    ```bash
    dconf load /org/gnome/desktop/a11y/ < ~/a11y-lab/base-a11y.dconf
    dconf dump  /org/gnome/desktop/a11y/ | diff -u ~/a11y-lab/base-a11y.dconf - \
        && echo "a11y tree restored"
    ```

**Check your understanding**

- **Q4.1** You set `stickykeys-enable true` but `xkbset q` still shows `Off - StickyKeys`. Name the most likely cause and the key that fixes it.
- **Q4.2** What is the relationship between `gsettings` and `dconf`, and where does the value physically live?
- **Q4.3** `dconf watch /org/gnome/desktop/a11y/` prints nothing while you click the Accessibility panel toggles. What does that tell you about the running session?
- **Q4.4** Which is authoritative at runtime — the GSettings key or the XKB control — and what happens to your `xkbset` change when the settings daemon restarts?
- **Q4.5** How would you apply `stickykeys-enable=true` to *every* user on a machine, not just yourself?

---

## Block 5 — Visual accessibility: contrast, large print, cursor, magnifier

**Objective:** configure high-contrast and large-print themes, cursor size and the screen magnifier, and understand the difference between scaling text and scaling the whole output.

1. Inspect the interface schema, which holds the theme and font settings:

   ```bash
   gsettings list-recursively org.gnome.desktop.interface | \
       grep -E 'theme|font|cursor|scaling'
   ```

   ```
   org.gnome.desktop.interface cursor-size 24
   org.gnome.desktop.interface cursor-theme 'Adwaita'
   org.gnome.desktop.interface font-name 'Cantarell 11'
   org.gnome.desktop.interface gtk-theme 'Adwaita'
   org.gnome.desktop.interface icon-theme 'Adwaita'
   org.gnome.desktop.interface text-scaling-factor 1.0
   ```

2. Enable **High Contrast**. Modern GNOME has a dedicated key; older releases switch the theme name. Check which one your system offers and use it:

   ```bash
   gsettings list-keys org.gnome.desktop.a11y.interface
   # if 'high-contrast' is listed:
   gsettings set org.gnome.desktop.a11y.interface high-contrast true
   # legacy / non-GNOME-Shell path:
   gsettings set org.gnome.desktop.interface gtk-theme  'HighContrast'
   gsettings set org.gnome.desktop.interface icon-theme 'HighContrast'
   ```

   Confirm the theme is actually installed before blaming the key:

   ```bash
   ls -d /usr/share/themes/HighContrast* /usr/share/icons/HighContrast* 2>/dev/null
   ```

3. Enable **Large Print**. `text-scaling-factor` is the accessibility control; it scales all text without changing layout metrics:

   ```bash
   gsettings set org.gnome.desktop.interface text-scaling-factor 1.5
   # compare against changing the font itself:
   gsettings set org.gnome.desktop.interface font-name 'Cantarell 16'
   ```

4. Enlarge the pointer, which is a separate axis from text size:

   ```bash
   gsettings set org.gnome.desktop.interface cursor-size 48
   gsettings set org.gnome.desktop.a11y.interface show-status-shapes true 2>/dev/null
   ```

5. Configure the **screen magnifier** before switching it on:

   ```bash
   gsettings list-recursively org.gnome.desktop.a11y.magnifier | sort | head -20
   gsettings set org.gnome.desktop.a11y.magnifier mag-factor 3.0
   gsettings set org.gnome.desktop.a11y.magnifier screen-position 'full-screen'
   gsettings set org.gnome.desktop.a11y.magnifier mouse-tracking 'proportional'
   gsettings set org.gnome.desktop.a11y.magnifier cross-hairs-length 4096
   gsettings set org.gnome.desktop.a11y.magnifier show-cross-hairs true
   gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled true
   ```

6. Try lens mode, which magnifies only around the pointer:

   ```bash
   gsettings set org.gnome.desktop.a11y.magnifier lens-mode true
   gsettings set org.gnome.desktop.a11y.magnifier screen-position 'centered'
   ```

7. Apply a colour-inversion effect for users with light sensitivity:

   ```bash
   gsettings set org.gnome.desktop.a11y.magnifier invert-lightness true
   gsettings set org.gnome.desktop.a11y.magnifier contrast-red   0.5
   gsettings set org.gnome.desktop.a11y.magnifier brightness-red 0.2
   ```

8. Compare with the standalone X magnifiers, which are independent of the desktop:

   ```bash
   xzoom -mag 4 &        # continuously magnified follow-the-pointer window
   xmag &                # one-shot snapshot magnifier
   kmag &                # KDE magnifier
   ```

9. Roll back:

   ```bash
   gsettings reset-recursively org.gnome.desktop.a11y.magnifier
   gsettings reset org.gnome.desktop.interface text-scaling-factor
   gsettings reset org.gnome.desktop.interface cursor-size
   gsettings reset org.gnome.desktop.interface gtk-theme
   gsettings reset org.gnome.desktop.interface icon-theme
   gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled false
   ```

**Check your understanding**

- **Q5.1** `text-scaling-factor 1.5` versus `font-name 'Cantarell 16'` versus the display `scaling-factor` — what does each one actually scale, and which one is the accessibility control?
- **Q5.2** You set `gtk-theme 'HighContrast'` and nothing changes. Give the first two things you check.
- **Q5.3** Why does a screen magnifier need to know about the AT-SPI bus at all, given that it only enlarges pixels?
- **Q5.4** What is the functional difference between `screen-position 'full-screen'` and `lens-mode true`?
- **Q5.5** A user needs magnification but the desktop's magnifier is unavailable (minimal WM, no GNOME Shell). Name two alternatives and their limitation.

---

## Block 6 — Text-to-speech: espeak-ng, Festival and Speech Dispatcher

**Objective:** build the speech stack from the bottom up — synthesizer, then the Speech Dispatcher abstraction layer that Orca and other clients actually talk to.

1. Verify audio output first; a silent speech stack is usually a silent *audio* stack:

   ```bash
   speaker-test -t sine -f 440 -l 1 -c 2
   aplay -l
   ```

2. Speak directly with **espeak-ng**, a formant synthesizer: small, fast, ~100 languages, robotic:

   ```bash
   espeak-ng "The quick brown fox jumps over the lazy dog"
   espeak-ng -v en-gb -s 130 -p 40 -a 200 "Rate one thirty, pitch forty, amplitude two hundred"
   espeak-ng -v es -s 160 "Prueba de síntesis de voz en español"
   ```

   * `-v` voice/language, `-s` words per minute, `-p` pitch 0–99, `-a` amplitude 0–200.

3. Enumerate voices and render to a file instead of the sound card:

   ```bash
   espeak-ng --voices | head -12
   ```

   ```
   Pty Language Age/Gender VoiceName          File                 Other Languages
    5  af       --/M      Afrikaans          gmw/af
    5  en-gb    --/M      english            gmw/en
    5  en-us    --/M      english-us         gmw/en-US
   ```

   ```bash
   espeak-ng -v en-us -w /tmp/sample.wav "Written to a wave file"
   aplay /tmp/sample.wav
   espeak-ng --stdout "Piped through standard output" | aplay -q
   ```

4. Inspect the phoneme layer — useful when diagnosing mispronunciation reports:

   ```bash
   espeak-ng -x -q "Linux accessibility"
   espeak-ng --ipa -q "Linux accessibility"
   ```

5. Speak with **Festival**, a concatenative/unit-selection engine: larger, slower, more natural:

   ```bash
   echo "Festival speech synthesis system" | festival --tts
   festival -b '(SayText "Batch mode invocation")'
   echo "Rendered offline" | text2wave -o /tmp/festival.wav && aplay /tmp/festival.wav
   ```

6. Now the abstraction layer. **Speech Dispatcher** (`speechd`) multiplexes several clients onto one synthesizer and arbitrates priorities. List its output modules:

   ```bash
   spd-say -O
   ```

   ```
   Output modules:
   espeak-ng
   espeak-ng-mbrola-generic
   festival
   ```

7. Speak through it, and observe that the client never names a synthesizer:

   ```bash
   spd-say "Hello from speech dispatcher"
   spd-say -o festival -r -30 -p 20 "Festival module, slower and lower"
   spd-say -l es "Mensaje en español"
   spd-say -L | head
   spd-say -C                      # cancel everything currently speaking
   ```

8. Set the default module and voice system-wide, then per user:

   ```bash
   grep -nE '^\s*(DefaultModule|DefaultLanguage|DefaultVoiceType|AudioOutputMethod)' \
        /etc/speech-dispatcher/speechd.conf
   ```

   ```
   77:DefaultModule espeak-ng
   84:DefaultLanguage "en"
   112:DefaultVoiceType  "MALE1"
   198:AudioOutputMethod "pulse"
   ```

   ```bash
   spd-conf                        # creates ~/.config/speech-dispatcher/ and self-tests
   ls ~/.config/speech-dispatcher/
   ```

9. Diagnose a mute stack methodically:

   ```bash
   systemctl --user status speech-dispatcher.service
   ls -l /etc/speech-dispatcher/modules/
   spd-say -o espeak-ng "module test" || echo "module invocation failed"
   journalctl --user -u speech-dispatcher -n 30 --no-pager
   ```

10. Clean up:

    ```bash
    spd-say -C
    rm -f /tmp/sample.wav /tmp/festival.wav
    ```

**Check your understanding**

- **Q6.1** Why does Orca talk to Speech Dispatcher instead of calling `espeak-ng` directly? Give two concrete benefits.
- **Q6.2** `espeak-ng "test"` is audible but `spd-say "test"` is silent. Name three checks, in order.
- **Q6.3** State the architectural difference between espeak-ng and Festival, and the situation in which each is the correct choice.
- **Q6.4** Which file sets the default synthesizer for all users, and which file overrides it for one user?
- **Q6.5** What does `espeak-ng -x -q` produce and when would you actually use it in a support case?

---

## Block 7 — Orca, the GNOME screen reader

**Objective:** start, configure and troubleshoot Orca, and place it correctly in the stack: Orca consumes **AT-SPI2** (Block 2) and emits through **Speech Dispatcher** (Block 6) and/or **BrlAPI** (Block 8).

1. Confirm the prerequisites before launching anything:

   ```bash
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   pgrep -a at-spi2-registryd
   spd-say "speech backend alive"
   ```

2. Start Orca in the foreground with logging visible, so failures are not silent:

   ```bash
   orca --replace --debug-file=/tmp/orca-debug &
   sleep 3
   pgrep -a orca
   ```

   *(`--replace` kills an existing instance; without it a second launch simply exits.)*

3. Open the preferences dialog. From the keyboard, this is `Orca modifier`+`Space`:

   ```bash
   orca --setup &
   ```

   The **Orca modifier** is `Insert` in the *desktop* keyboard layout and `CapsLock` in the *laptop* layout — set this in Preferences → Keyboard, because every other Orca shortcut is built on it.

4. Exercise the core commands in a text editor (`Orca` below means the modifier key):

   | Keys | Action |
   |---|---|
   | `Orca`+`Space` | Preferences |
   | `Orca`+`H` | Learn mode (announces keys instead of acting) — `Esc` to leave |
   | `Orca`+`KP_Add` | Say all (read the whole document) |
   | `Orca`+`KP_Enter` | Where am I (context: window, widget, selection) |
   | `Orca`+`S` | Toggle speech |
   | `Orca`+`F11` | Toggle table-reading mode |
   | `Orca`+`Q` | Quit Orca |

5. Inspect the persisted configuration. Modern Orca stores JSON under XDG data:

   ```bash
   ls -l ~/.local/share/orca/
   python3 -m json.tool ~/.local/share/orca/user-settings.conf | head -30
   ```

   ```
   {
       "general": {
           "speechServerFactory": "orca.speechdispatcherfactory",
           "enableSpeech": true,
           "enableBraille": false,
           "keyboardLayout": 1,
           "verbalizePunctuationStyle": 1
   ...
   ```

6. Make Orca start automatically for this user — the desktop-native way and the generic way:

   ```bash
   gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
   # generic XDG autostart, works under any desktop:
   mkdir -p ~/.config/autostart
   cp /usr/share/applications/orca.desktop ~/.config/autostart/ 2>/dev/null || \
   cat > ~/.config/autostart/orca.desktop <<'EOF'
   [Desktop Entry]
   Type=Application
   Name=Orca Screen Reader
   Exec=orca
   X-GNOME-Autostart-Phase=Applications
   EOF
   ```

7. Verify the toggle shortcut works without a mouse: `Super`+`Alt`+`S` toggles the screen reader in GNOME. Confirm the binding:

   ```bash
   gsettings get org.gnome.settings-daemon.plugins.media-keys screenreader
   ```

8. Troubleshoot a silent Orca by walking the stack downwards:

   ```bash
   grep -iE 'error|traceback|exception' /tmp/orca-debug* | head
   pgrep -a at-spi2-registryd || echo "AT-SPI registry not running -> nothing to read"
   spd-say "dispatcher"          || echo "speech backend broken -> Orca has no voice"
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   ```

9. Stop Orca and undo the autostart:

   ```bash
   orca --quit || pkill -f '/usr/bin/orca'
   rm -f ~/.config/autostart/orca.desktop
   gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false
   ```

**Check your understanding**

- **Q7.1** Orca is running, `at-spi2-registryd` is running, `spd-say` works, and Orca still says nothing when you focus widgets. What single setting is the prime suspect?
- **Q7.2** Why does Orca offer two keyboard layouts, and what is the practical consequence of choosing "laptop"?
- **Q7.3** Name the three interfaces Orca sits between, one per direction.
- **Q7.4** What does `orca --replace` solve that `orca` alone does not?
- **Q7.5** The objective list also mentions GOK and emacspeak. What is each, and why would you not deploy GOK on a current system?

---

## Block 8 — Braille: BRLTTY, BrlAPI and xbrlapi

**Objective:** configure a refreshable braille display end to end. BRLTTY is a **daemon** that renders screen content to a braille device; it drives the Linux text console natively and reaches graphical applications through AT-SPI2. Reference: <https://brltty.app/>

1. Establish what is installed and which drivers the binary supports:

   ```bash
   brltty --version
   brltty --help | head -40
   ls /usr/lib/brltty/libbrl*.so 2>/dev/null || ls /usr/lib*/brltty/libbrl*.so
   ```

   ```
   ...libbrlxal.so  libbrlxbm.so  libbrlxbn.so  libbrlxeu.so  libbrlxfs.so
   libbrlxht.so  libbrlxpm.so  libbrlxsk.so  libbrlxvo.so ...
   ```

   Each `libbrl<XX>.so` is a two-letter braille driver code (`ht` = Handy Tech, `pm` = Papenmeier, `bm` = Baum, `al` = Alva, …). `auto` probes them.

2. Read the main configuration file. Every directive here has a matching command-line option:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/brltty.conf
   ```

   ```
   braille-driver      auto
   braille-device      usb:
   text-table          en_US
   ```

3. Understand the four driver axes BRLTTY exposes, then set them explicitly:

   | Axis | Option | Example values |
   |---|---|---|
   | Braille driver (the hardware) | `-b` / `braille-driver` | `auto`, `ht`, `al`, `pm`, `no` |
   | Braille device (the transport) | `-d` / `braille-device` | `usb:`, `serial:/dev/ttyS0`, `bluetooth:AA:BB:…` |
   | Text table (character → dot pattern) | `-t` / `text-table` | `en_US`, `es`, `de`, `auto` |
   | Screen driver (where text comes from) | `-x` / `screen-driver` | `lx` (Linux console), `a2` (AT-SPI2) |

   ```bash
   sudo cp /etc/brltty.conf /etc/brltty.conf.bak
   sudo tee -a /etc/brltty.conf >/dev/null <<'EOF'
   braille-driver      auto
   braille-device      usb:
   text-table          en_US
   contraction-table   en-us-g2
   api-parameters      Auth=/etc/brlapi.key
   EOF
   ```

4. Run BRLTTY in the foreground with debug logging — the only reliable way to see device probing:

   ```bash
   sudo systemctl stop brltty
   sudo brltty -n -e -l debug -b auto -d usb: -t en_US
   ```

   * `-n` do not fork into the background, `-e` log to stderr, `-l debug` maximum verbosity.
   * With no display attached you will see the probe fail — that failure text *is* the exercise: read which drivers were tried and on which device.

5. Inspect the service and the udev-driven activation. BRLTTY is normally started by udev when a known display is plugged in, not at boot:

   ```bash
   systemctl status brltty.service
   systemctl list-units 'brltty*'
   grep -h -m5 'brltty' /usr/lib/udev/rules.d/*brltty*.rules
   udevadm monitor --udev --subsystem-match=usb    # then plug the display in
   ```

6. Simulate a display without hardware. The `xw` driver renders a braille window on screen, letting you validate tables and layout:

   ```bash
   sudo brltty -n -e -l info -b xw -d none -t en_US
   ```

7. Explore the table tooling — `.ttb` are text tables, `.ctb` contraction tables, `.ktb` key tables:

   ```bash
   ls /etc/brltty/Text/ | head
   ls /etc/brltty/Contraction/ | head
   brltty-ttb -h 2>&1 | head -5      # text table compiler/converter
   brltty-ktb -h 2>&1 | head -5      # key table lister
   ```

8. Configure **BrlAPI**, the client protocol that lets other programs (Orca, editors) write to the display through BRLTTY instead of fighting it for the device:

   ```bash
   sudo ls -l /etc/brlapi.key
   sudo setfacl -m u:"$USER":r /etc/brlapi.key   # or add yourself to the brlapi group
   getent group brlapi
   ```

9. Bridge the graphical session. `xbrlapi` reports the X focus to BRLTTY so the display follows the active window:

   ```bash
   xbrlapi --quiet &
   pgrep -a xbrlapi
   ```

   For a GNOME/AT-SPI session, the equivalent is running BRLTTY with the AT-SPI2 screen driver:

   ```bash
   sudo brltty -n -e -b xw -d none -x a2
   ```

10. Enable braille output in Orca and confirm the two are talking:

    ```bash
    python3 -c "import brlapi; b=brlapi.Connection(); print(b.driverName, b.displaySize)"
    ```

    ```
    b'XWindow' (40, 1)
    ```

11. Restore:

    ```bash
    sudo pkill -f 'brltty -n'; pkill xbrlapi
    sudo mv /etc/brltty.conf.bak /etc/brltty.conf
    sudo systemctl start brltty
    ```

**Check your understanding**

- **Q8.1** Why does BRLTTY need a *screen driver* at all, and what changes between `lx` and `a2`?
- **Q8.2** A braille display works on the text console but shows nothing in the GNOME session. Give the two possible fixes.
- **Q8.3** What is BrlAPI, and what concrete problem does it solve that direct device access does not?
- **Q8.4** Explain the difference between a text table and a contraction table, and why `en-us-g2` is not a language setting.
- **Q8.5** `systemctl status brltty` shows the service inactive, yet the user's display works. How?
- **Q8.6** You are debugging a display that is never detected. Write the exact command you run first and justify each flag.

---

## Block 9 — On-screen keyboards and pointer alternatives

**Objective:** provide text entry and pointing for a user who cannot use a physical keyboard or mouse.

1. Launch **Onboard**, the maintained GTK on-screen keyboard, and inspect its settings schema:

   ```bash
   onboard &
   gsettings list-schemas | grep -i onboard
   gsettings set org.onboard layout '/usr/share/onboard/layouts/Full Keyboard.onboard'
   gsettings set org.onboard theme  '/usr/share/onboard/themes/HighContrast.theme'
   gsettings set org.onboard.window transparent-background false
   ```

2. Turn on the desktop's built-in on-screen keyboard, which is what the objective's "screen keyboard" toggle refers to on GNOME:

   ```bash
   gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
   ```

3. Use **xvkbd**, the minimal X virtual keyboard, and — more usefully — its scripting mode, which injects keystrokes via the XTEST extension:

   ```bash
   xvkbd -no-jump-pointer &
   xvkbd -text 'ls -l\n'            # types into the focused window
   xvkbd -window Terminal -text 'echo injected\n'
   ```

4. Compare with `xdotool`, the general-purpose XTEST driver used to script assistive input:

   ```bash
   xdotool getactivewindow getwindowname
   xdotool type --delay 120 'typed by xdotool'
   xdotool key ctrl+alt+t
   xdotool mousemove 400 300 click 1
   ```

5. Re-enable **Mouse Keys** from Block 3 and combine it with dwell click from Block 4 to produce a fully keyboard-driven pointer:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard mousekeys-enable true
   gsettings set org.gnome.desktop.a11y.keyboard mousekeys-max-speed 400
   gsettings set org.gnome.desktop.a11y.keyboard mousekeys-init-delay 200
   gsettings set org.gnome.desktop.a11y.mouse dwell-click-enabled true
   ```

6. Inspect **gestures / pointer devices** at the input-driver level, where tap-to-click, drag-lock and left-handed mode live:

   ```bash
   xinput list
   xinput list-props "$(xinput list --name-only | grep -i -m1 touchpad)"
   ```

   ```
   Device 'SynPS/2 Synaptics TouchPad':
       libinput Tapping Enabled (322):  1
       libinput Tapping Drag Lock Enabled (326):  0
       libinput Left Handed Enabled (300):  0
       libinput Accel Speed (293):  0.000000
   ```

   ```bash
   gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
   gsettings set org.gnome.desktop.peripherals.mouse left-handed true
   gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'flat'
   ```

7. Roll back:

   ```bash
   pkill onboard; pkill xvkbd
   gsettings reset org.gnome.desktop.peripherals.mouse left-handed
   gsettings reset-recursively org.gnome.desktop.a11y.mouse
   gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled false
   ```

**Check your understanding**

- **Q9.1** How does an on-screen keyboard deliver a keystroke to an application that believes it came from hardware?
- **Q9.2** GOK is named in the LPI objectives. What replaced it, and what should you actually install today?
- **Q9.3** A user can move the pointer with Mouse Keys but cannot click. Name two independent ways to give them a click.
- **Q9.4** Why does `xvkbd -text` fail to reach a Wayland-native application while still working against an XWayland one?

---

## Block 10 — Accessibility of the text console

**Objective:** apply the same four axes — contrast, size, keyboard timing, speech — to a system with no X server at all. This is the part candidates most often skip and the part that matters on a headless server.

1. Switch to a text console (`Ctrl`+`Alt`+`F3`) and identify the current console font and keymap:

   ```bash
   setfont -O /tmp/current-font.psf 2>/dev/null; ls -l /tmp/current-font.psf
   cat /etc/vconsole.conf 2>/dev/null            # systemd distributions
   cat /etc/default/console-setup 2>/dev/null    # Debian/Ubuntu
   ```

   ```
   KEYMAP=us
   FONT=eurlatgr
   ```

2. Apply a **large-print console font**. Terminus ships sizes up to 32 pixels, in bold variants:

   ```bash
   ls /usr/share/kbd/consolefonts/ 2>/dev/null || ls /usr/share/consolefonts/
   sudo setfont ter-v32b            # 32-px bold Terminus
   sudo setfont ter-v16n            # back to something normal
   ```

3. Make it persistent — the mechanism differs by distribution family:

   ```bash
   # systemd (Fedora, RHEL, Arch, openSUSE)
   sudo sed -i 's/^FONT=.*/FONT=ter-v32b/' /etc/vconsole.conf || \
       echo 'FONT=ter-v32b' | sudo tee -a /etc/vconsole.conf

   # Debian / Ubuntu
   sudo sed -i -e 's/^FONTFACE=.*/FONTFACE="Terminus"/' \
               -e 's/^FONTSIZE=.*/FONTSIZE="16x32"/' /etc/default/console-setup
   sudo setupcon
   ```

4. Adjust **console contrast and colours** with `setterm`, and stop the console blanking on a user who reads slowly:

   ```bash
   setterm --foreground yellow --background black --store
   setterm --bold on
   setterm --blank 0 --powersave off
   setterm --cursor on
   setterm --default          # revert
   ```

5. Adjust **console key repeat**, the console counterpart of `xset r rate`:

   ```bash
   kbdrate                       # show current
   sudo kbdrate -d 1000 -r 5     # 1000 ms delay, 5 repeats/second
   sudo kbdrate -d 250 -r 30     # typical default
   ```

6. Inspect and modify the **console keymap**, which is where a key can be remapped for a one-handed user:

   ```bash
   dumpkeys | head -20
   dumpkeys --keys-only | grep -i 'keycode  58'      # CapsLock
   sudo loadkeys <<'EOF'
   keycode 58 = Control
   EOF
   sudo loadkeys us                                   # restore
   ```

7. Control the keyboard LEDs, which is how Toggle-Keys-style feedback is done without a desktop:

   ```bash
   setleds -v
   sudo setleds +num -caps
   ```

8. Set up **Speakup**, the in-kernel console screen reader, bridged to Speech Dispatcher by `speechd-up`:

   ```bash
   sudo modprobe speakup_soft
   ls /sys/accessibility/speakup/
   ls -l /dev/softsynth
   sudo systemctl start speechd-up 2>/dev/null || sudo speechd-up
   ```

   ```
   attributes  characters  i18n  keymap  soft  ...
   punc_level  rate  version  vol  synth  pitch
   ```

   ```bash
   cat /sys/accessibility/speakup/synth
   echo 5 | sudo tee /sys/accessibility/speakup/rate
   ```

   To load it at boot instead: append `speakup.synth=soft` to the kernel command line.

9. Point BRLTTY at the console explicitly, which is its native and simplest mode:

   ```bash
   sudo brltty -n -e -l info -b xw -d none -x lx -t en_US
   ```

10. Roll back:

    ```bash
    setterm --default; sudo kbdrate -d 250 -r 30; sudo setfont ter-v16n
    sudo modprobe -r speakup_soft 2>/dev/null
    ```

**Check your understanding**

- **Q10.1** A blind administrator must use a headless server over a serial console. Which two of the tools in this block are relevant, and which are useless?
- **Q10.2** Which file makes a console font survive a reboot on a systemd distribution, and which one on Debian?
- **Q10.3** What is the console equivalent of `xset r rate 660 25`, and why can it not be run by an unprivileged user?
- **Q10.4** Speakup is a kernel module while Orca is a Python program. What follows from that difference in terms of *when* each can start speaking?
- **Q10.5** `setterm --store` — what exactly does it store, and how long does it survive?

---

## Block 11 — Diagnostic drill: a broken accessibility stack

**Objective:** you are handed a workstation with the report *"the screen reader stopped working after the upgrade"*. Work the stack top-down and produce a verdict at each layer.

1. **Layer 0 — session.** Is the tooling you are about to use even applicable?

   ```bash
   echo "$XDG_SESSION_TYPE"; echo "$XDG_CURRENT_DESKTOP"
   ```

2. **Layer 1 — the assistive application.** Is it running, and does it log anything?

   ```bash
   pgrep -a orca || echo 'VERDICT: Orca is not running'
   orca --replace --debug-file=/tmp/orca-diag &
   sleep 4; grep -icE 'error|exception' /tmp/orca-diag*
   ```

3. **Layer 2 — the desktop switch.** Does the desktop think the screen reader should be on?

   ```bash
   gsettings get org.gnome.desktop.a11y.applications screen-reader-enabled
   ```

4. **Layer 3 — the toolkit bridge.** Are applications exporting anything to read?

   ```bash
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   env | grep -E 'NO_AT_BRIDGE|GTK_MODULES|QT_ACCESSIBILITY'
   ```

5. **Layer 4 — the accessibility bus.** Is the transport alive and reachable?

   ```bash
   pgrep -a at-spi2-registryd at-spi-bus-launcher
   gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
              --method org.a11y.Bus.GetAddress
   python3 -c "import pyatspi; print(pyatspi.Registry.getDesktop(0).childCount, 'apps on the bus')"
   ```

6. **Layer 5 — the output backend.** Can anything make sound or drive the display?

   ```bash
   spd-say "backend test" || echo 'VERDICT: speech-dispatcher path is broken'
   espeak-ng "synthesizer test" || echo 'VERDICT: synthesizer itself is broken'
   speaker-test -t sine -f 440 -l 1 || echo 'VERDICT: audio device is broken'
   ```

7. **Layer 6 — input side.** Are AccessX features fighting the user rather than helping?

   ```bash
   xkbset q | grep -E 'On - (SlowKeys|BounceKeys|StickyKeys|MouseKeys)'
   gsettings list-recursively org.gnome.desktop.a11y.keyboard | grep 'true$'
   ```

8. Write the verdict as a single line naming the **lowest** layer that failed, then fix only that layer and re-test upward.

**Check your understanding**

- **Q11.1** Why is top-down the wrong order for *fixing* even though it is a reasonable order for *observing*?
- **Q11.2** Layer 4 reports 0 applications on the bus but the desktop is full of windows. Which layer is genuinely at fault?
- **Q11.3** The user says "the keyboard has become unusable" one day after you enabled accessibility features. Which single command reproduces the most likely cause?
- **Q11.4** Everything in layers 0–5 passes and Orca is still silent. Name the two remaining suspects.

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1

**Q1.1** Either (a) `DISPLAY` is unset or wrong — you are on a text console, in an SSH session without X forwarding, or in a systemd service with a clean environment; or (b) you are in a **Wayland** session, where no X server is listening for `xkbset` in the way it expects (only XWayland is, and it does not accept AccessX control from arbitrary clients the way a classic X server does). Distinguish with `echo "$XDG_SESSION_TYPE"` — `x11` versus `wayland` — cross-checked with `echo $DISPLAY`. If the type is `x11` and `DISPLAY` is empty, it is (a); if the type is `wayland`, it is (b).

**Q1.2** The **bus launcher** is broken. `at-spi-bus-launcher` starts and owns the private accessibility D-Bus daemon and publishes its address (`org.a11y.Bus.GetAddress`, plus the `AT_SPI_BUS` root-window property under X). `at-spi2-registryd` is the *registry* that runs **on** that bus: applications register their accessible trees with it and assistive tools discover applications through it. A registry with no bus underneath it has no transport, so no application can register and no screen reader can discover anything.

**Q1.3** Because the schemas ship in the `gsettings-desktop-schemas` package, which is a dependency of many non-GNOME components (GTK applications, `at-spi2-core`, Orca itself). The schema being *installed* only means the key can be read and written; it says nothing about whether any process is listening for changes. On Plasma, writing `org.gnome.desktop.a11y.keyboard stickykeys-enable true` will change the stored value and change nothing on screen, because `gnome-settings-daemon` is not running to act on it.

**Q1.4** Useless (or degraded to XWayland-only) under Wayland: `xkbset`, `xvkbd`, `xdotool`, `xzoom`, `xmag`, `xbrlapi`, and the X-specific parts of `xset`/`xprop`/`xev`. Still fully functional because it never touches the display server: **`espeak-ng`** (likewise `festival` and `spd-say` — they only need an audio device). `setfont`, `setterm` and `kbdrate` are also unaffected, but they act on the text console rather than the graphical session.

### Block 2

**Q2.1** Isolation, volume and lifetime. Accessibility traffic is high-frequency — every focus change, caret move and text insertion generates signals — and putting that on the shared session bus would both flood it and expose every application's widget tree to any session-bus client. A dedicated bus also lets the accessibility stack exist in contexts that have no ordinary session bus (a login greeter, for instance), and lets it be started and stopped independently of the rest of the session.

**Q2.2** In order of likelihood: (1) the application's toolkit bridge is not loaded — `toolkit-accessibility` is false, or `NO_AT_BRIDGE=1` is set in its environment; (2) the toolkit has no AT-SPI support at all — a pure X11/SDL/Electron-with-accessibility-disabled application draws pixels and exports nothing; (3) the bus itself is unreachable from that process — it was launched from a different session, a container or a systemd unit with a scrubbed environment, so it cannot resolve `org.a11y.Bus`.

**Q2.3** `toolkit-accessibility=false` is a *policy* setting read from dconf at toolkit initialisation; it applies to newly started applications in that session and can be flipped centrally. `NO_AT_BRIDGE=1` is a per-process *environment override* that unconditionally prevents GTK from loading the ATK bridge, regardless of the GSettings value, and it only affects the processes that inherit it. In practice: the GSettings key is how you configure a desktop; the environment variable is how you exclude one application or work around a bridge that crashes.

**Q2.4** `QT_ACCESSIBILITY=1` (and on some builds `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`). GTK is unaffected because the two toolkits carry independent bridge implementations: GTK3/4 build the ATK/AT-SPI bridge in and gate it on `toolkit-accessibility`/`NO_AT_BRIDGE`, while Qt gates its own bridge on the `QT_ACCESSIBILITY` variable. Same bus, two separate client implementations, two separate switches.

### Block 3

**Q3.1** **Slow Keys**: a key must be held down for a configured delay before the press is accepted — it discards keys brushed accidentally in passing, and serves users with poor motor precision or tremor who often graze neighbouring keys. **Bounce Keys**: after a key is accepted, further presses *of that same key* are ignored for a configured interval — it discards involuntary repeats from tremor or spasticity.

**Q3.2** The **AccessX timeout** expired. XKB turns AccessX features off automatically after a period without keyboard/pointer activity, so an accidentally enabled feature cannot lock a user out. The fix is `xkbset exp` — declare the features that must retain their state when the timeout fires (e.g. `xkbset exp '=mousekeys' '=mousekeysaccel'`), or set the timeout so it never triggers. Verify the exact syntax with `man 1 xkbset`, then confirm the result in the *Access X Timeout* block of `xkbset q`.

**Q3.3** Because they live in different parts of the X protocol. Auto-repeat delay and rate are **core keyboard controls**, present since X11R1 and manipulated by `xset r rate`. Sticky/Slow/Bounce/Mouse Keys are **AccessX controls**, defined by the XKB extension and manipulated through `XkbSetControls`, for which `xkbset` is the CLI front end. `xset` predates XKB and was never extended to cover it.

**Q3.4** `twokey` ("pressing two keys simultaneously disables Sticky Keys") and `latchlock`. The user is inadvertently pressing two keys at once, which is precisely the input pattern Sticky Keys exists to avoid, so the safety valve fires constantly. Neutralise with `xkbset sticky -twokey -latchlock`; at the desktop layer the equivalent is `gsettings set org.gnome.desktop.a11y.keyboard stickykeys-two-key-off false`.

**Q3.5** With `latchlock` enabled, the first press *latches* the modifier for the next keystroke only; the second press *locks* it until it is pressed a third time to release. That is what allows typing a run of capitals without holding Shift. With `-latchlock` the second press simply cancels the latch.

**Q3.6** `xset -r <keycode>` disables auto-repeat for that keycode alone (`xset r <keycode>` re-enables it). Obtain the keycode by running `xev -event keyboard`, pressing the key, and reading the `keycode NN` field from the `KeyPress` event — or `xmodmap -pke | grep -i <keysym>`.

### Block 4

**Q4.1** The **master switch** `org.gnome.desktop.a11y.keyboard enable` is `false`. It gates the entire AccessX group: with it off, the individual `*-enable` keys are stored but never pushed down to XKB. Set `gsettings set org.gnome.desktop.a11y.keyboard enable true`. (Second candidate, if that is already true: no settings daemon is running to translate the key into an `XkbSetControls` call — see Q4.3.)

**Q4.2** `gsettings` is the command-line front end to the **GSettings** API; **dconf** is the backend that GSettings uses on Linux. The value is stored in a binary, memory-mapped database at `~/.config/dconf/user` for per-user settings, with system-wide defaults compiled from `/etc/dconf/db/*.d/` into `/etc/dconf/db/*`. The *schema* — key names, types, defaults, ranges — is a separate compiled file at `/usr/share/glib-2.0/schemas/gschemas.compiled`. Writing a key that has no schema fails; that is why `gsettings` refuses unknown keys while `dconf write` does not.

**Q4.3** That no process is writing those keys — the panel you are clicking is not backed by GSettings, or `gnome-settings-daemon` / GNOME Shell is not running (you are on a different desktop that stores its accessibility settings elsewhere, e.g. Plasma in `~/.config/kaccessrc`). It confirms the GNOME schema path is a dead end on that machine.

**Q4.4** At the level of the X server, the **XKB control is authoritative** — it is the actual runtime state, and `xkbset` writes it directly. The GSettings key is the *desired* state, and the settings daemon reconciles the two. Consequently, when `gnome-settings-daemon` starts, restarts, or observes a change on the a11y schema, it re-applies its own view and **overwrites your `xkbset` change**. That is why manual `xkbset` tuning is stable on a bare window manager and transient under a full desktop.

**Q4.5** With a **dconf system database**: create `/etc/dconf/db/local.d/00-a11y` containing

```ini
[org/gnome/desktop/a11y/keyboard]
enable=true
stickykeys-enable=true
```

ensure `/etc/dconf/profile/user` contains `user-db:user` followed by `system-db:local`, then run `sudo dconf update`. Add a matching `/etc/dconf/db/local.d/locks/a11y` file listing the key paths if the setting must be mandatory rather than a default.

### Block 5

**Q5.1** `text-scaling-factor` multiplies the size of **all text** across the desktop while leaving widget geometry, icons and the window manager unchanged — this is the accessibility control ("Large Text"). `font-name 'Cantarell 16'` changes only the **default interface font**, so applications that specify their own font are unaffected and text scaling elsewhere is inconsistent. A display `scaling-factor` (HiDPI) is an **integer multiplier for the whole rendered output** — text, icons, widgets, cursors — intended for pixel-density correction, not for low vision, and it typically only accepts whole numbers.

**Q5.2** (1) Is the theme actually installed — `ls -d /usr/share/themes/HighContrast`? The key stores an arbitrary string and reports no error for a nonexistent theme. (2) Is anything reading the key — is `gnome-settings-daemon`/GNOME Shell running, and does your GNOME version instead expect `org.gnome.desktop.a11y.interface high-contrast`? Check with `gsettings list-keys org.gnome.desktop.a11y.interface` and `dconf watch`.

**Q5.3** Because useful magnification must **follow the point of interest**, not just the pointer. To keep the caret, the focused widget or the item a screen reader is currently announcing inside the magnified viewport, the magnifier subscribes to AT-SPI focus and caret-moved events — the same event stream Orca consumes. Without AT-SPI it can only do mouse tracking, which is why `xzoom` is strictly less useful than the desktop magnifier for a keyboard user.

**Q5.4** `full-screen` magnifies the entire display: the whole screen becomes a zoomed viewport that pans as the focus moves, and no unmagnified context remains. `lens-mode` renders a magnified **window that follows the pointer** over an otherwise unmagnified desktop, preserving surrounding context at normal size. Full-screen suits severe low vision; lens mode suits users who need occasional enlargement while retaining spatial orientation.

**Q5.5** `xzoom` (continuous, follows the pointer) and `xmag` (one-shot snapshot magnification); `kmag` if KDE libraries are acceptable. The limitation is that they are pure X pixel magnifiers with no AT-SPI integration: they track the mouse only, so keyboard focus and caret movement do not pull the viewport, and under Wayland they either fail or see only XWayland surfaces.

### Block 6

**Q6.1** (1) **Arbitration and priority**: several clients (Orca, a notification daemon, a terminal reader) can request speech at once; Speech Dispatcher queues, interrupts and prioritises messages (`important`, `message`, `text`, `notification`, `progress`) so an urgent alert cuts through a long document reading. (2) **Synthesizer independence**: Orca requests "speak this, at this rate, in this language" and Speech Dispatcher routes it to whichever output module the system is configured for — espeak-ng, Festival, a commercial engine — so switching voices requires no change in Orca. Secondary benefits: consistent per-user rate/pitch/volume settings across all clients, and one process owning the audio device instead of many.

**Q6.2** (1) Is the Speech Dispatcher daemon running and reachable — `systemctl --user status speech-dispatcher`, plus `journalctl --user -u speech-dispatcher`. (2) Is a valid output module configured and loadable — `spd-say -O` to list, `DefaultModule` in `/etc/speech-dispatcher/speechd.conf` and any `~/.config/speech-dispatcher/speechd.conf` override, and `ls /etc/speech-dispatcher/modules/`. (3) Is the audio output method correct — `AudioOutputMethod` (`pulse`, `alsa`, `pipewire`) may point at a subsystem this session does not use, which is the classic case where the synthesizer works standalone but the daemon is mute.

**Q6.3** **espeak-ng** is a *formant* synthesizer: it generates speech from an acoustic model of the vocal tract, so it is tiny (a few MB), extremely fast, supports ~100 languages, and is intelligible at very high speaking rates — but it sounds robotic. **Festival** is a *concatenative / unit-selection* system: it stitches together recorded speech fragments, so it needs large voice databases, is slower, covers few languages, and sounds far more natural. Choose espeak-ng for a screen reader, where latency and high-rate intelligibility dominate and experienced users prefer it; choose Festival for prepared audio, announcements or anything a sighted user will listen to at normal speed.

**Q6.4** System-wide: `/etc/speech-dispatcher/speechd.conf` (`DefaultModule`). Per user: `~/.config/speech-dispatcher/speechd.conf`, generated and validated by `spd-conf`. The user file is read after the system file and overrides it.

**Q6.5** `-x` prints the **phoneme representation** espeak-ng derived from the text (`--ipa` prints it in IPA), and `-q` suppresses the audio. You use it when a user reports that a specific word, acronym, name or unit is mispronounced: the phoneme dump tells you whether the pronunciation rules, the dictionary entry, or the language selection is at fault — and it gives you the exact phoneme string to put in a custom dictionary entry.

### Block 7

**Q7.1** `org.gnome.desktop.interface toolkit-accessibility` is `false` (or the applications you are focusing were launched with `NO_AT_BRIDGE=1`). Every other component is alive, but the applications are exporting nothing to the bus, so Orca has nothing to announce. The confirming test is the `pyatspi` enumeration from Block 2: an empty or near-empty desktop list proves the bridge, not Orca, is the problem.

**Q7.2** Because the *desktop* layout uses the **numeric keypad** heavily — `KP_Add` for Say All, `KP_Enter` for Where Am I, the keypad cluster for flat review — and a laptop has no keypad. The laptop layout remaps those commands onto the main key block and changes the **Orca modifier from `Insert` to `CapsLock`**. The practical consequence of choosing laptop: `CapsLock` stops toggling capitals in the normal way, which surprises users who share the machine, and every printed keybinding reference written for the desktop layout no longer applies.

**Q7.3** Upstream, it consumes the desktop through **AT-SPI2 over D-Bus** (what is on screen, what has focus, what the caret is doing). Downstream, it emits through **Speech Dispatcher** (speech) and **BrlAPI** (braille), plus magnification cues on the third side. Its own configuration and keybindings sit in between.

**Q7.4** Orca is a singleton: launching a second instance while one is running normally just exits, and if a previous instance is wedged or half-dead you get no screen reader and no error the user can perceive. `--replace` terminates the existing instance and takes over the AT-SPI and Speech Dispatcher connections, which is why it is the correct way to restart Orca after a configuration change.

**Q7.5** **GOK** (GNOME On-screen Keyboard) was a dynamic, scanning on-screen keyboard for users who could operate only a switch or a pointer; it is unmaintained and dropped from current distributions — install **Onboard** (or the GNOME Shell built-in on-screen keyboard) instead. **emacspeak** is a "speech-enabled audio desktop": a set of Emacs extensions that speaks Emacs buffers directly, giving a complete self-voicing environment for editing, mail, shell and browsing without any AT-SPI involvement — it remains in active use and is a legitimate deployment today.

### Block 8

**Q8.1** BRLTTY renders **text**, not pixels, so it needs a source of text plus a cursor position — that is the screen driver's job. `lx` reads the Linux virtual console directly (through `/dev/vcsa*`), giving the exact character cell grid and cursor location of a text console. `a2` obtains the content of graphical applications through **AT-SPI2**, reconstructing a text view of the focused widget. The braille driver and device are unchanged; only where the text comes from differs.

**Q8.2** Either (a) run `xbrlapi` in the graphical session, so X focus information is reported to BRLTTY and the display follows the active window; or (b) run BRLTTY with the AT-SPI2 screen driver (`-x a2` / `screen-driver a2` in `brltty.conf`) and let a screen reader such as Orca drive braille output over BrlAPI. Under Wayland only the second path is viable.

**Q8.3** BrlAPI is the **client/server protocol** BRLTTY exposes so that other programs can write to the braille display and read its keys without touching the hardware. The problem it solves is exclusive device access: only one process can own a serial/USB braille display, so without BrlAPI, Orca and BRLTTY would contend for the port and one of them would fail. With BrlAPI, BRLTTY owns the device and multiplexes; Orca, editors and custom tools become clients. Authentication is by the shared secret in `/etc/brlapi.key`, which is why your user must be able to read that file.

**Q8.4** A **text table** (`.ttb`) is a one-to-one mapping from characters to 8-dot braille cell patterns — it is what makes `é` or `ñ` come out correctly for a given language and braille standard. A **contraction table** (`.ctb`) implements *grade 2* braille, where common words and letter groups are compressed into fewer cells (`and`, `the`, `-ing` each become a single cell). `en-us-g2` is therefore not a language selection but a **contraction-system** selection: it says "US English, grade 2 contracted". A user who reads uncontracted braille needs the text table but no contraction table, and forcing one on them makes the output unreadable.

**Q8.5** Because BRLTTY is normally started by **udev** when a recognised display is plugged in, not by the persistent `brltty.service`. The udev rules under `/usr/lib/udev/rules.d/` (typically `90-brltty.rules`) match the display's USB vendor/product ID and instantiate a templated unit such as `brltty@<device>.service`. `systemctl list-units 'brltty*'` reveals the instance; `systemctl status brltty.service` alone does not.

**Q8.6** `sudo brltty -n -e -l debug -b auto -d usb: -t en_US`, after stopping the packaged service. `-n` keeps it in the foreground so it does not detach and hide its output; `-e` sends the log to stderr where you can read it live instead of into syslog; `-l debug` raises verbosity so every driver probe and every byte of the handshake appears; `-b auto` makes it try each compiled-in braille driver in turn, and the log then tells you which drivers were attempted and how each failed; `-d usb:` fixes the transport so a failure is unambiguously "no display found on USB" rather than a fallback to some other port.

### Block 9

**Q9.1** Through the **XTEST extension** (X11) — the client asks the X server to synthesise a key or button event, and the server injects it into the normal event stream, so the receiving application cannot distinguish it from real hardware input. `xvkbd -text`, `xdotool type` and Onboard's key output all work this way. The alternative, used by some tools and required under Wayland, is a **kernel-level virtual input device** created through `uinput`, which injects at the evdev layer below the display server.

**Q9.2** GOK is unmaintained and no longer packaged by current distributions. Its role was taken over by **Onboard** (a full-featured GTK on-screen keyboard with word prediction, scanning modes and themes), by **Caribou** (the GNOME Shell integration, itself now largely superseded), and today by the **GNOME Shell built-in on-screen keyboard**, enabled with `org.gnome.desktop.a11y.applications screen-keyboard-enabled`. Install Onboard, or use the desktop's built-in keyboard. Know GOK's name for the exam; do not deploy it.

**Q9.3** (1) The Mouse Keys click keys themselves: `5` on the keypad clicks, `+` double-clicks, and `/ * -` select which button `5` will press — the feature is probably working and the user simply has NumLock in the wrong state or has not been taught the keys. (2) **Dwell click** — `org.gnome.desktop.a11y.mouse dwell-click-enabled true` with a `dwell-time` — which clicks automatically after the pointer rests. A third option is a hardware switch or `xdotool click 1` bound to an accessible key.

**Q9.4** Because Wayland deliberately removes the ability of one client to inject input into another: there is no XTEST-equivalent global injection path, and each client only receives events routed to it by the compositor. An XWayland application still runs against a real X server (the XWayland server), so `xvkbd`/`xdotool` can use XTEST against it — but only for X clients, and only within that XWayland instance. Wayland-native on-screen keyboards work instead through compositor-side protocols (`virtual-keyboard`, `input-method`) or through `uinput` below the compositor.

### Block 10

**Q10.1** Relevant: **BRLTTY** (with a braille display; it works natively on the console and on serial devices) and **Speakup** with `speechd-up` if the machine has an audio device — though on a truly headless serial console, braille or a remote SSH session with Orca on the *client* is the realistic answer. Useless: `setfont`, `setterm --foreground`, and anything visual, because they address low vision rather than blindness — and on a serial console the font is rendered by the terminal emulator at the other end, not by the kernel, so `setfont` has no effect at all.

**Q10.2** systemd distributions: `/etc/vconsole.conf` (`FONT=`, and `KEYMAP=` for the keymap), applied by `systemd-vconsole-setup`. Debian/Ubuntu: `/etc/default/console-setup` (`FONTFACE=`, `FONTSIZE=`), applied by `setupcon` and the `console-setup` service.

**Q10.3** `kbdrate -d <delay_ms> -r <rate_per_second>`. It requires privilege because it is not a request to a userspace server but an **ioctl against the keyboard device / kernel console driver** (`KDKBDREP` on the console), altering a global kernel setting that affects every user of every virtual console — unlike `xset`, which changes state inside one X server owned by one session.

**Q10.4** Speakup is compiled into or loaded by the **kernel**, so it can speak from very early boot — during initramfs, at the LUKS passphrase prompt, at a rescue shell, and on a system that never starts a graphical session. Orca is a Python program that depends on a running session bus, AT-SPI2 and Speech Dispatcher, so it can only speak once the desktop session is up. For a blind administrator this is decisive: Speakup (or BRLTTY) covers boot, recovery and single-user mode; Orca covers only the desktop.

**Q10.5** `--store` saves the **current foreground and background colour of the console** as the values that will be restored by a `setterm --default` or a `reset`. It is a runtime property of the kernel console, so it survives until reboot but **not across a reboot** — persisting console colours requires putting the `setterm` call in a startup file such as `/etc/profile.d/` or a systemd unit.

### Block 11

**Q11.1** Because the layers are dependent, not independent: a failure at a low layer makes every layer above it *appear* broken, so a top-down fix repairs symptoms. If the accessibility bus is dead, Orca's log is full of errors, `pyatspi` is empty and `spd-say` may look irrelevant — "fixing" Orca by reinstalling it changes nothing. Observing top-down is efficient because the user's report starts there and each layer's failure is visible; fixing must proceed **bottom-up**, repairing the lowest failing layer and then re-testing upward, because that repair may resolve everything above it at once.

**Q11.2** Layer 3, the **toolkit bridge** — `toolkit-accessibility` is false, or the applications were started with `NO_AT_BRIDGE=1` / without `QT_ACCESSIBILITY=1`. Layer 4 is healthy: the bus answered `GetAddress` and the registry is running. The bus being reachable and empty means no application chose to register, which is a client-side decision made at toolkit initialisation.

**Q11.3** `xkbset q` (or `gsettings list-recursively org.gnome.desktop.a11y.keyboard`). The near-certain cause is **Slow Keys** — enabled deliberately or by accidentally holding `Shift` for eight seconds with AccessX key sequences active — which makes every keystroke require a hold before it registers and reads exactly like a broken keyboard. Bounce Keys with a large delay produces the same report from the other direction. Clear with `xkbset -sl -bo` and then correct the desktop-layer keys so the settings daemon does not re-apply them.

**Q11.4** (1) **Orca's own configuration**: speech disabled in `~/.local/share/orca/user-settings.conf` (`enableSpeech: false`), a verbosity/punctuation profile that suppresses output, or the wrong `speechServerFactory`. (2) **Audio routing at the session level**: Speech Dispatcher and Orca are alive but the stream is going to a muted sink, a different output device, or a PulseAudio/PipeWire instance the Orca process cannot reach — `spd-say` succeeding from your interactive shell does not prove Orca's process has the same audio environment, particularly when Orca was started by the session's autostart with a different environment.

</details>

---

### Objective mapping

| Key knowledge area (106.3) | Covered in | Primary commands / files |
|---|---|---|
| Visual settings and themes (High Contrast, Large Print) | Block 5 | `gsettings org.gnome.desktop.interface`, `org.gnome.desktop.a11y.interface`, `setterm`, `setfont` |
| Screen magnifier | Block 5 | `org.gnome.desktop.a11y.magnifier`, `xzoom`, `xmag`, `kmag` |
| Screen reader | Blocks 2, 7, 10 | `orca`, `at-spi2-registryd`, Speakup, `emacspeak` |
| Braille display | Block 8 | `brltty`, `/etc/brltty.conf`, BrlAPI, `xbrlapi` |
| Desktop keyboard accessibility (AccessX, Sticky/Slow/Bounce/Toggle/Repeat/Mouse Keys) | Blocks 3, 4 | `xkbset`, `xset`, `org.gnome.desktop.a11y.keyboard` |
| Gestures / pointer assistance | Blocks 4, 9 | `org.gnome.desktop.a11y.mouse`, `xinput`, `org.gnome.desktop.peripherals.*` |
| On-screen keyboard | Block 9 | `onboard`, `xvkbd`, GNOME Shell OSK (GOK is historical) |
| Text-to-speech | Block 6 | `espeak-ng`, `festival`, `spd-say`, `/etc/speech-dispatcher/speechd.conf` |

### Sources

- LPI, *Exam 102-500 Objectives* (LPIC-1 version 5.0) — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI, *Exam 101-500 Objectives* (LPIC-1 version 5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- freedesktop.org, *AT-SPI2 accessibility framework* — <https://www.freedesktop.org/wiki/Accessibility/AT-SPI2/>
- GNOME, *Orca Screen Reader documentation* — <https://help.gnome.org/users/orca/stable/>
- GNOME, *Universal Access / Accessibility settings* — <https://help.gnome.org/users/gnome-help/stable/a11y.html>
- BRLTTY project, *BRLTTY Manual and BrlAPI reference* — <https://brltty.app/documentation.html>
- Brailcom, *Speech Dispatcher documentation* — <https://freebsoft.org/speechd>
- eSpeak NG project — <https://github.com/espeak-ng/espeak-ng/blob/master/docs/guide.md>
- The Festival Speech Synthesis System — <https://www.cstr.ed.ac.uk/projects/festival/>
- Linux kernel, *Speakup User's Guide* — <https://www.kernel.org/doc/html/latest/admin-guide/spkguide.html>
- X.Org, *XKB — The X Keyboard Extension* — <https://www.x.org/releases/current/doc/kbproto/xkbproto.html>