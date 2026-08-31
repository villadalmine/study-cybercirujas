# LPIC-1 · 103.8 Basic file editing — Guided exercises

**Exam:** 101-500 (LPIC-1 v5.0) · **Topic:** 103.8 Basic file editing
**Objective coverage:** navigate a document using `vi`; understand and use `vi` modes; insert, edit, delete, copy and find text in `vi`; awareness of Emacs, nano and vim.

Everything below is meant to be typed. Each block ends with **Check your understanding** — answer before moving on. All answers are collapsed at the bottom.

## Notation used in this lab

| Notation | Meaning |
|---|---|
| `$ command` | typed at the shell prompt |
| `<Esc>`, `<Enter>` | those keys |
| `Ctrl-R` | hold Control, press `r` |
| `:wq<Enter>` | typed **inside** the editor, in command-line (ex) mode |
| `dd` | two keystrokes in normal mode — **not** a shell command |

Keystrokes in `vi` are case-sensitive and are **not** echoed to the screen in normal mode. If nothing seems to happen, you are probably in the wrong mode: press `<Esc>` twice and start again.

---

## Exercise 1 — Find out which editor you actually have

`vi` is a *name*, not a program. On a modern Linux box it is almost always a symlink or a stripped-down build of Vim, and the differences (multi-level undo, visual mode, arrow keys in insert mode) decide what works during the exam and on a production node.

1. Build the lab directory:

```bash
mkdir -p ~/lab-103.8 && cd ~/lab-103.8
```

2. Discover every editor present on the system:

```bash
command -v vi vim vim.tiny nano emacs ed 2>/dev/null
```

Typical output on a minimal Debian/Ubuntu install:

```text
/usr/bin/vi
/usr/bin/nano
/usr/bin/ed
```

3. Resolve what `vi` really is:

```bash
readlink -f "$(command -v vi)"
```

```text
/usr/bin/vim.tiny
```

On RHEL/Fedora/openSUSE you will usually see `/usr/bin/vi` (a real binary from the `vim-minimal` package). On Alpine and inside many container images it is `/bin/busybox`.

4. On Debian-family systems, inspect the alternatives entry that made that decision:

```bash
update-alternatives --display vi
```

```text
vi - auto mode
  link best version is /usr/bin/vim.tiny
  link currently points to /usr/bin/vim.tiny
  link vi is /usr/bin/vi
/usr/bin/vim.tiny - priority 15
```

5. Ask the binary what feature set it was compiled with:

```bash
vi --version 2>/dev/null | head -2
```

```text
VIM - Vi IMproved 9.1 (2024 Jan 02, compiled Mar 11 2024 12:00:00)
Tiny version without GUI.
```

(Version, dates and the `Tiny`/`Small`/`Normal`/`Huge` word vary per distro. A classic `nvi` binary does not understand `--version` at all and prints a usage line instead.)

6. Check which editor the rest of the system will launch on your behalf:

```bash
echo "VISUAL=$VISUAL EDITOR=$EDITOR"
```

```text
VISUAL= EDITOR=
```

Empty is normal — and it is why `crontab -e` on a fresh Debian box drops you into `nano`, while on RHEL it drops you into `vi`.

7. Create the pristine lab file and an untouched reference copy:

```bash
cat > svc.conf <<'EOF'
# svc.conf - edge service, staging
listen 0.0.0.0:8080
workers 4
worker_connections 1024
keepalive_timeout 65
client_max_body_size 1m

upstream api {
    server 10.0.2.11:9000 max_fails=3 fail_timeout=10s;
    server 10.0.2.12:9000 max_fails=3 fail_timeout=10s;
    server 10.0.2.13:9000 backup;
}

log_level info
access_log /var/log/svc/access.log
error_log /var/log/svc/error.log
metrics_port 9100
tls_cert /etc/svc/tls/tls.crt
tls_key /etc/svc/tls/tls.key
drain_timeout 30s
EOF
cp svc.conf svc.conf.orig
wc -lc svc.conf
```

```text
 20 477 svc.conf
```

Those two numbers — **20 lines, 477 bytes** — are your integrity check for the whole lab. Whenever an exercise says *restore the file*, run `cp svc.conf.orig svc.conf` and confirm `wc -lc` again.

**Check your understanding**

**Q1.** Why is `readlink -f "$(command -v vi)"` a more reliable answer to "which editor am I about to get?" than `which vi`?
**Q2.** A colleague says "just use `Ctrl-R` to redo". On which of the binaries you found above might that fail, and why?
**Q3.** `EDITOR` and `VISUAL` are both empty. Name two commands whose behaviour will still change if you export one of them.

---

## Exercise 2 — The three modes, and how to prove which one you are in

`vi` is modal. Every wasted minute in front of `vi` comes from being in a mode you did not expect.

1. Open the file and immediately turn on the mode indicator and line numbers:

```bash
vi svc.conf
```

Inside the editor:

```text
:set showmode number<Enter>
```

2. Press `i`. Look at the bottom-left corner:

```text
-- INSERT --
```

3. Type `# touched` then press `<Esc>`. The `-- INSERT --` indicator disappears — you are back in **normal** mode (also called *command mode*).

4. Press `:` — the cursor jumps to the bottom line, which now shows a single colon. This is **command-line mode** (also called *ex mode*, because these are the commands of the `ex` line editor that `vi` is a visual front-end for). Press `<Esc>` to abandon it without running anything.

5. Press `R`. The indicator now reads:

```text
-- REPLACE --
```

Type `XXX` — it overwrites characters instead of pushing them right. Press `<Esc>`.

6. Press `v` (Vim only; not in original `vi`):

```text
-- VISUAL --
```

Move with `l` a few times to extend the highlighted selection, then press `<Esc>`.

7. Undo everything you just did and confirm the file is untouched:

```text
:e!<Enter>
:q<Enter>
```

```bash
cmp svc.conf svc.conf.orig && echo IDENTICAL
```

```text
IDENTICAL
```

**Check your understanding**

**Q4.** Name the three modes required by the objective and state the single key that returns you to normal mode from each of them.
**Q5.** You press `dd` expecting to delete a line and instead the literal text `dd` appears in the buffer. What happened, and what are the two keystrokes that fix it?
**Q6.** What is the difference between `:e!` and `u`?
**Q7.** `Ctrl-[` produces the same effect as `<Esc>`. Why does that matter on a remote console or a keyboard with a distant/absent Escape key?

---

## Exercise 3 — Navigation: moving without arrow keys

Arrow keys are not guaranteed. On a serial console, in `vi` compatible mode, or through a broken `TERM`, the arrow keys emit escape sequences that land you in insert mode with `A`/`B`/`C`/`D` scattered through the file. `h j k l` always work.

1. Restore and open:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

```text
:set number<Enter>
```

2. Character and line motions — from line 1, press:

```text
j j j        (down to line 4)
l l l l      (right four characters)
k            (up to line 3)
h            (left one character)
```

3. Word motions. Press `0` (start of line), then:

| Key | Motion |
|---|---|
| `w` | forward to start of next word |
| `b` | back to start of previous word |
| `e` | forward to end of current/next word |
| `W` `B` `E` | same, but a "word" is any run of non-blanks (so `10.0.2.11:9000` is **one** WORD) |

Go to line 9 (`9G`), press `0`, then `w w w` — you stop at `server`, `10`, `.`. Now press `0` and `W W` — you stop at `server`, then at the whole `10.0.2.11:9000`.

4. Line-anchored motions:

| Key | Motion |
|---|---|
| `0` | column 1 |
| `^` | first non-blank character (useful on the indented `server` lines) |
| `$` | end of line |

On line 9, compare `0` and `^`: `0` lands on the leading space, `^` lands on the `s` of `server`.

5. File and line motions:

```text
gg      first line          (Vim; classic vi uses 1G)
G       last line (20)
17G     line 17
:17<Enter>   same thing, ex style
```

6. Screen motions — enlarge or shrink your terminal to see them work:

| Key | Motion |
|---|---|
| `H` | **H**igh — top line of the screen |
| `M` | **M**iddle of the screen |
| `L` | **L**ow — bottom line of the screen |
| `Ctrl-F` / `Ctrl-B` | **F**orward / **B**ack one full screen |
| `Ctrl-D` / `Ctrl-U` | **D**own / **U**p half a screen |

7. Structural motions. Put the cursor on the `{` of line 8 and press `%`:

```text
   8 upstream api {
...
  12 }
```

The cursor jumps to the matching `}` on line 12. Press `%` again to jump back. Now press `{` and `}` to move by paragraph (blank-line-delimited blocks): from line 9, `{` lands on the blank line 7, `}` lands on the blank line 13.

8. Leave without saving:

```text
:q<Enter>
```

**Check your understanding**

**Q8.** Give two ways to jump to line 17 and one way to jump to the last line of a file of unknown length.
**Q9.** On the line `    server 10.0.2.11:9000 backup;`, how many times must you press `w` to reach `backup`, versus `W`? Explain the rule.
**Q10.** You must check that a 4000-line JSON-ish config has balanced braces around one block. Which single keystroke answers that fastest, and what does it tell you if the cursor does not move?
**Q11.** `Ctrl-D` versus `Ctrl-F`: which one is safer for reading a log file you are scanning visually, and why?

---

## Exercise 4 — Entering insert mode on purpose

Six different keys enter insert mode. Choosing the right one removes a whole positioning step.

1. Restore and open:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Press `3G` (line `workers 4`), then `$`. Now compare:

| Key | Where you start typing |
|---|---|
| `i` | **i**nsert *before* the cursor |
| `a` | **a**ppend *after* the cursor |
| `I` | insert before the **first non-blank** character of the line |
| `A` | append at the **end of the line** |
| `o` | **o**pen a new line *below* and insert |
| `O` | open a new line *above* and insert |

3. With the cursor on line 3, press `A`, type ` # tuned 2026-08-20`, press `<Esc>`. Line 3 becomes:

```text
    3 workers 4 # tuned 2026-08-20
```

4. Press `o`, type `worker_rlimit_nofile 65535`, press `<Esc>`. The new text is line 4, and everything below shifted down by one.

5. Press `I`, type `# `, press `<Esc>` — the line you just created is now commented out.

6. Counts work with insert commands. Press `G` (last line), then:

```text
3o---<Esc>
```

Three identical `---` lines are appended. This is the *count prefix*, and it generalises to almost every normal-mode command.

7. Discard everything:

```text
:q!<Enter>
```

**Check your understanding**

**Q12.** The cursor is in column 1 of an indented line. You need to add text at the start of the *code*, not at the start of the *indentation*. Which key?
**Q13.** What exactly does `5O` do?
**Q14.** You typed `A` at the end of a session and got a beep and no `-- INSERT --`. What is the most likely cause?

---

## Exercise 5 — Delete, change, yank, put: the operator + motion grammar

`d`, `c` and `y` are **operators**. An operator alone does nothing; it waits for a motion. `operator + motion` is the whole language:

```
[count] operator [count] motion
```

Doubling the operator (`dd`, `cc`, `yy`) applies it to the whole line.

1. Restore and open:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

```text
:set number<Enter>
```

2. **Character deletes.** Go to line 3 (`3G`), `$`, then press `x` — the `4` disappears. Press `u` to undo. Press `3x` on `workers` from column 1 — `wor` is gone. Undo with `u`. (`X` deletes *backwards*.)

3. **Delete with a motion.** On line 9, press `^` then:

| Command | Effect |
|---|---|
| `dw` | delete the word `server ` |
| `d$` or `D` | delete from cursor to end of line |
| `d0` | delete from cursor back to column 1 |
| `d%` | with the cursor on `{` of line 8: delete the whole brace-matched block |

Try `dw`, look at the result, press `u`. Then press `D`, look, press `u`.

4. **Line deletes and counts.** Press `9G` then `3dd`:

```text
3 fewer lines
```

Lines 9–11 (the three `server` lines) are gone. Press `u`.

5. **Change.** `c` is *delete then enter insert mode*. On line 14 (`log_level info`), press `$` then `b` (start of `info`), then:

```text
cwdebug<Esc>
```

```text
   14 log_level debug
```

`cc` changes the whole line keeping the indentation; `C` changes from cursor to end of line.

6. **Yank and put.** `y` copies. `p` pastes **after** the cursor (or **below** the line, for a line-wise yank); `P` pastes before/above.

Press `9G`, then `yy`, then `p`:

```text
    9     server 10.0.2.11:9000 max_fails=3 fail_timeout=10s;
   10     server 10.0.2.11:9000 max_fails=3 fail_timeout=10s;
```

Now edit the duplicate into a new backend: with the cursor on line 10, press `f1` … or simply `^`, `W`, then `cw10.0.2.14:9000<Esc>`.

7. **The unnamed register is shared.** Press `dd` on any line, then move elsewhere and press `p` — the deleted line reappears there. **Deleting is cutting.** This is how you move a line: `dd` then `p`.

8. **Repeat.** Press `.` to repeat the last change. Delete a word with `dw`, move to another word, press `.` — deleted again. Combined with a count: `3.` repeats it three times.

9. Save to a scratch name and quit, so you can compare later:

```text
:w /tmp/svc.edited.conf<Enter>
:q!<Enter>
```

```bash
diff svc.conf.orig /tmp/svc.edited.conf | head
```

**Check your understanding**

**Q15.** Write the single command that deletes from the cursor to the end of the file, and the one that deletes from the cursor to the beginning.
**Q16.** What is the difference between `dw` and `cw` in terms of the mode you end up in, and why does that matter when you follow it with `.`?
**Q17.** You need to move 12 lines from the middle of a file to the end. Give a normal-mode sequence and an ex-mode one-liner.
**Q18.** After `dd`, you press `p` twice. How many copies of the line exist, and where?

---

## Exercise 6 — Registers: recovering something you deleted three deletes ago

The unnamed register holds only the last cut. `vi` also has 26 named registers (`a`–`z`) and 9 numbered ones (`"1`–`"9`) holding the last nine **line-wise** deletes. This is the difference between "I lost that block" and "I got it back".

1. Restore and open:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Yank the whole `upstream` block into named register `a`. Press `8G`, then:

```text
"a5yy
```

(`"a` selects the register, `5yy` yanks five lines into it.)

3. Now do three unrelated line deletes: `1G`, `dd`; `1G`, `dd`; `1G`, `dd`. The unnamed register now holds only the third one.

4. Recover the *first* of those deletes:

```text
G
"1p
```

The most recent delete is in `"1`; press `u` and try `"2p`, `"3p` to walk back through the history.

5. Paste your saved block, untouched by all that deleting:

```text
G
"ap
```

The five-line `upstream` block reappears at the end of the file.

6. Inspect the registers (Vim; not available in classic `vi`):

```text
:registers<Enter>
```

```text
Type Name Content
  l  ""   # svc.conf - edge service, staging^J
  l  "1   # svc.conf - edge service, staging^J
  l  "2   listen 0.0.0.0:8080^J
  l  "3   workers 4^J
  l  "a   upstream api {^J    server 10.0.2.11:9000 ...
```

7. Discard: `:q!<Enter>`.

**Check your understanding**

**Q19.** What is stored in `"1` versus `"a`, and which one survives further deletions?
**Q20.** `"Ayy` (capital A) does something different from `"ayy`. What?
**Q21.** You deleted a *word* (not a line) four deletes ago. Will `"4p` bring it back? Explain.

---

## Exercise 7 — Finding text: `/`, `?`, and editing at scale with `ex`

1. Restore and open:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

```text
:set number ignorecase hlsearch<Enter>
```

(`hlsearch` and `incsearch` are Vim additions; `ignorecase` exists in `vi` too, abbreviated `:set ic`.)

2. **Search forward** with `/`:

```text
/timeout<Enter>
```

The cursor lands on `keepalive_timeout` (line 5). Press `n` for the next match (line 9), `n` again (line 10), `n` again (line 20 `drain_timeout`), and once more:

```text
search hit BOTTOM, continuing at TOP
```

Searches wrap by default (`:set nowrapscan` disables it). `N` reverses direction.

3. **Search backward** with `?`:

```text
?server<Enter>
```

then `n` (which now moves *backwards*, in the direction of the original search) and `N` (forwards).

4. A pattern that does not exist:

```text
/nosuchkey<Enter>
```

```text
E486: Pattern not found: nosuchkey
```

5. **Regular expressions** are BRE-style. Anchors and classes work:

```text
/^tls_<Enter>          first line starting with tls_
/[0-9]\{4\}$<Enter>    line ending in four digits (9100)
/\<api\><Enter>        the word api, not "rapid" or "apiserver"
```

6. **Search-driven substitution**, the real workhorse. Re-address the whole upstream pool:

```text
:%s/10\.0\.2\./10.0.3./g<Enter>
```

```text
3 substitutions on 3 lines
```

The range `%` means "every line"; `g` means "every occurrence on the line, not just the first". Add `c` to confirm each one:

```text
:%s/timeout/TIMEOUT/gc<Enter>
```

```text
replace with TIMEOUT (y/n/a/q/l/^E/^Y)?
```

Press `q` to abort. Undo the address change with `u`.

7. **Ranged ex commands.** Ranges accept line numbers, `.` (current line), `$` (last line), `%` (all), and `/pattern/`:

```text
:9,11d<Enter>          delete lines 9 to 11
u
:5t$<Enter>            copy line 5 to the end of the file
:5m$<Enter>            move line 5 to the end of the file
u
u
:1,12w /tmp/head.conf<Enter>   write only lines 1-12 to another file
```

8. **`:g` — apply a command to every matching line.** This is the one that scales to a 200 000-line log:

```text
:g/^$/d<Enter>
```

```text
2 fewer lines
```

Every blank line is gone. Undo with `u`, then try the inverse:

```text
:v/^tls_/d<Enter>
```

Everything **not** matching `^tls_` is deleted (`:v` is `:g!`). Undo with `u`.

9. Discard: `:q!<Enter>`.

**Check your understanding**

**Q22.** Give the exact command to replace every occurrence of `info` with `warn` in the whole file, asking for confirmation each time.
**Q23.** Why must `10.0.2.` be written `10\.0\.2\.` on the left side of `:s`, but not on the right side?
**Q24.** After `/error`, you press `n` five times and end up *above* where you started. What happened, and which setting turns that off?
**Q25.** Write one command that deletes every line containing `DEBUG` from the buffer, and one that keeps only those lines.

---

## Exercise 8 — Undo, redo and the compatibility trap

1. Restore and open:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Make three separate changes: `1G` `dd`; `1G` `dd`; `1G` `dd`.

3. Press `u`. Vim reports something like:

```text
1 more line; before #3  4 seconds ago
```

4. Press `u` twice more. If all three deletes come back, you have **multi-level undo**. Now press `Ctrl-R` three times — the deletes are redone.

5. Test the classic-`vi` behaviour deliberately:

```text
:set compatible<Enter>
```

Delete a line with `dd`, press `u` (it comes back), press `u` again — in compatible mode `u` **toggles**: the line is deleted again. This is the historical `vi` behaviour and it is what you get on a truly minimal system.

```text
:set nocompatible<Enter>
```

6. `U` (capital) is a different command in both: it undoes *all recent changes on the last line you touched*. Go to line 5, press `x` four times, then press `U` — the line is restored in one step.

7. Confirm which setting your editor actually starts with:

```text
:set compatible?<Enter>
```

```text
nocompatible
```

8. Discard: `:q!<Enter>`.

**Check your understanding**

**Q26.** Distinguish `u`, `U` and `Ctrl-R`.
**Q27.** You are on an unfamiliar embedded system, you press `u` twice, and your second undo re-applies the change. What does that tell you about the editor, and how should you adapt your editing habits for the rest of the session?

---

## Exercise 9 — Writing and quitting: every combination the objective names

This is the block most often failed under exam time pressure. Do it until it is muscle memory.

1. Restore and open:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Make a change (`1G`, `dd`), then attempt a plain quit:

```text
:q<Enter>
```

```text
E37: No write since last change (add ! to override)
```

3. Now the full table. Try each one on a fresh copy:

| Command | Meaning |
|---|---|
| `:w` | write the buffer to its file, stay in the editor |
| `:w <file>` | write the buffer to *another* file, keep editing the original |
| `:w!` | force the write (read-only buffer, or restrictive permissions you can override) |
| `:q` | quit — refuses if there are unsaved changes |
| `:q!` | quit and **throw the changes away** |
| `:wq` | write (always, even if unmodified) and quit |
| `:x` | write **only if modified**, then quit |
| `ZZ` | same as `:x`, from normal mode, no colon |
| `ZQ` | same as `:q!` (Vim only) |
| `:wqa` / `:qa!` | apply to *all* open buffers (Vim) |

4. Prove that `:wq` and `:x` are not identical:

```bash
cp svc.conf.orig svc.conf
stat -c '%y' svc.conf
vi svc.conf     # change nothing; type :wq<Enter>
stat -c '%y' svc.conf
cp svc.conf.orig svc.conf
stat -c '%y' svc.conf
vi svc.conf     # change nothing; type :x<Enter>
stat -c '%y' svc.conf
```

`:wq` updates the modification time even with no changes; `:x` does not. On a host where `make`, Ansible's `creates:`, or a config-watcher triggers off mtime, that difference is a spurious service reload.

5. Read-only handling. Open the file deliberately read-only:

```bash
vi -R svc.conf      # same as the `view` command
```

Try to type `x`:

```text
W10: Warning: Changing a readonly file
```

Then:

```text
:w<Enter>
```

```text
E45: 'readonly' option is set (add ! to override)
```

```text
:w!<Enter>
```

Observe whether it succeeds. Then quit and repeat the same test on a file you do **not** own:

```bash
sudo cp svc.conf /etc/svc-lab.conf 2>/dev/null || true
vi /etc/svc-lab.conf    # try x, then :w!, then :q!
```

```text
E212: Can't open file for writing
```

6. Clean up: `sudo rm -f /etc/svc-lab.conf`

**Check your understanding**

**Q28.** You opened `/etc/fstab` with `vi` (not `sudo vi`), made careful edits, and only now notice `E45`. Describe two ways to keep your work, and say which one is correct on a production host.
**Q29.** Why did `:w!` succeed on a mode-`0400` file you own, but fail with `E212` on a root-owned file? Which permission is actually decisive?
**Q30.** You need to keep the original and save the edits elsewhere. Give the command.

---

## Exercise 10 — Swap files and crash recovery

A `vi` session that dies (SSH drop, OOM kill, power loss) usually leaves a recoverable swap file. Knowing this is the difference between redoing 40 minutes of work and pressing `R`.

1. Restore and open the file, make a change, and **leave the editor running**:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

Inside: `1G`, `O`, type `# emergency change, incident INC-4471`, `<Esc>`. Do **not** save.

2. From a second terminal, look at the directory and at the process:

```bash
cd ~/lab-103.8 && ls -a
```

```text
.  ..  .svc.conf.swp  svc.conf  svc.conf.orig
```

```bash
pgrep -a 'vi|vim'
```

```text
4711 vi svc.conf
```

3. Simulate the crash:

```bash
kill -9 4711        # use the PID you actually saw
```

4. Back in the first terminal, reopen the file:

```bash
vi svc.conf
```

```text
E325: ATTENTION
Found a swap file by the name ".svc.conf.swp"
          owned by: alice   dated: Wed Aug 26 09:41:12 2026
         file name: ~alice/lab-103.8/svc.conf
          modified: YES
         user name: alice   host name: node01
        process ID: 4711 (still running)
While opening file "svc.conf"
             dated: Wed Aug 26 09:40:58 2026
...
Swap file ".svc.conf.swp" already exists!
[O]pen Read-Only, (E)dit anyway, (R)ecover, (D)elete it, (Q)uit, (A)bort:
```

5. Press `R`. Your unsaved line is back. Save it, then **delete the swap file yourself** — recovery does not remove it:

```text
:w<Enter>
:q<Enter>
```

```bash
ls -a; rm -f .svc.conf.swp
```

6. Recover non-interactively (the way you would on a host where the file is already open elsewhere):

```bash
vi -r svc.conf
```

7. Awareness: classic `nvi` does not use a dot-swap file next to the document; it keeps recovery data under `/var/tmp/vi.recover/` and mails the owner a "vi recovery" message. `busybox vi` has no recovery at all.

**Check your understanding**

**Q31.** The swap dialog says `process ID: 4711 (still running)`. What must you *not* choose, and what should you do first?
**Q32.** After a successful `R` and `:w`, why does the swap file still need to be removed?
**Q33.** You are editing on a read-only root filesystem and `vi` complains it cannot create a swap file. Which setting lets you continue, and what do you lose?

---

## Exercise 11 — Editing production files without breaking them

This is where the objective meets real operations. Everything below is verifiable with `stat`.

1. Set up an inode/hardlink experiment:

```bash
cd ~/lab-103.8
cp svc.conf.orig target.conf
ln target.conf hardlink.conf
ln -s target.conf symlink.conf
stat -c '%n inode=%i links=%h mode=%a' target.conf hardlink.conf
```

```text
target.conf inode=1310721 links=2 mode=644
hardlink.conf inode=1310721 links=2 mode=644
```

2. Edit with the **copy** strategy (write in place):

```bash
vi target.conf
```

```text
:set backupcopy=yes<Enter>
:set backupcopy?<Enter>          confirm it took
A # touched<Esc>
:wq<Enter>
```

```bash
stat -c '%n inode=%i links=%h' target.conf hardlink.conf
```

The inode is unchanged and `links=2` — the hardlink still sees your edit.

3. Now the **rename** strategy:

```bash
vi target.conf
```

```text
:set backupcopy=no<Enter>
A # again<Esc>
:wq<Enter>
```

```bash
stat -c '%n inode=%i links=%h' target.conf hardlink.conf
grep -c touched hardlink.conf
```

The inode of `target.conf` changed, `links=1`, and `hardlink.conf` is now a *different file* frozen at the old content.

4. Repeat step 3 against the **symlink**:

```bash
vi symlink.conf     # :set backupcopy=no, edit, :wq
ls -l symlink.conf
```

With `backupcopy=no`, the symlink is replaced by a regular file. This is exactly how people destroy `/etc/resolv.conf → ../run/systemd/resolve/stub-resolv.conf`, or a `/etc/alternatives` link, with a "harmless" edit.

5. Check the default your editor uses, and where it came from:

```bash
vi target.conf
```

```text
:verbose set backupcopy?<Enter>
:q<Enter>
```

6. **Never `sudo vi` a system file if `sudoedit` exists.** Compare the two:

```bash
sudo -e /etc/hosts        # same as: sudoedit /etc/hosts
```

`sudoedit` copies the file to a temporary path, runs **your** editor as **your** user (via `SUDO_EDITOR`, then `VISUAL`, then `EDITOR`), and copies the result back with the original ownership and mode. `sudo vi` runs the whole editor as root — and `:!bash` inside it is an unlogged root shell, which is why a sudoers rule granting `sudo vi` grants full root.

7. The editor-aware system commands:

```bash
export EDITOR=vi
crontab -e        # edits a temp copy; installs and syntax-checks on exit
sudo visudo       # locks /etc/sudoers, validates before installing
sudo visudo -c    # validate only
sudo visudo -f /etc/sudoers.d/90-lab   # correct way to edit a drop-in
```

Deliberately break the syntax inside `visudo` (type a bare word `garbage` on its own line) and exit:

```text
>>> /etc/sudoers: syntax error near line 25 <<<
What now?
Options are:
  (e)dit sudoers file again
  e(x)it without saving changes to sudoers file
  (Q)uit and save changes to sudoers file (DANGER!)
```

Press `x`. This validation is the entire reason `visudo` exists — a broken `/etc/sudoers` locks every user out of `sudo`.

8. Bash can hand the current command line to your editor. Type a long command, do **not** press Enter, then press `Ctrl-x Ctrl-e`: it opens in `$VISUAL`/`$EDITOR`; saving and quitting executes it.

9. Clean up:

```bash
rm -f target.conf hardlink.conf symlink.conf
sudo rm -f /etc/sudoers.d/90-lab
```

**Check your understanding**

**Q34.** In one sentence each, state what `backupcopy=yes` and `backupcopy=no` do to the file's inode, and give a production scenario where the wrong choice causes an outage.
**Q35.** A sudoers rule reads `alice ALL=(root) NOPASSWD: /usr/bin/vi /etc/nginx/nginx.conf`. Why is this equivalent to giving alice full root, and what is the correct rule?
**Q36.** Why is `crontab -e` preferable to editing `/var/spool/cron/crontabs/alice` directly with `vi`?

---

## Exercise 12 — Editing YAML/JSON the way you will actually have to

Two `vi` settings account for most mangled Kubernetes manifests.

1. Create a manifest and open it:

```bash
cat > deploy.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: edge
          image: registry.local/edge:1.4.2
EOF
vi deploy.yaml
```

2. Make tabs and trailing whitespace visible — YAML forbids tabs for indentation, and they are invisible otherwise:

```text
:set list<Enter>
:set listchars=tab:>-,trail:·<Enter>
```

Insert a literal tab somewhere with `o<Tab>foo<Esc>` and watch `>---` appear. Undo it.

3. Configure sane indentation, then test the paste trap. With `autoindent` on, paste a multi-line block from your clipboard into the terminal:

```text
:set expandtab shiftwidth=2 tabstop=2 autoindent<Enter>
```

The pasted block "staircases" — each line is indented by the previous line's indent *plus* its own. The fix:

```text
:set paste<Enter>
```

paste again (clean this time), then:

```text
:set nopaste<Enter>
```

4. Strip trailing whitespace across the file and confirm:

```text
:%s/\s\+$//e<Enter>
:wq<Enter>
```

```bash
grep -nP '\s+$' deploy.yaml || echo "no trailing whitespace"
```

```text
no trailing whitespace
```

5. Filter the buffer through an external command. Reopen and try:

```text
:r !date -u +%FT%TZ<Enter>       insert command output at the cursor
:r /etc/hostname<Enter>          insert a file at the cursor
:14,20!sort<Enter>               sort a line range in place
:%!grep -v '^#'<Enter>           replace the buffer with the filter's output
u                                 undo the filter
:!ls -l %<Enter>                 run a shell command, % = current file name
```

6. Binary awareness:

```bash
vi -b /bin/true
```

```text
:%!xxd<Enter>        render as hex
:%!xxd -r<Enter>     convert back
:q!<Enter>
```

Never save a binary opened without `-b`: without it, `vi` can normalise line endings and add a trailing newline, corrupting the file.

**Check your understanding**

**Q37.** What exactly goes wrong when you paste indented YAML into `vi` with `autoindent` enabled, and which two commands bracket the paste?
**Q38.** `:%!sort` and `:r !sort` both involve an external `sort`. What is the difference in effect?
**Q39.** Why does `:set list` matter specifically for YAML and `Makefile` editing?

---

## Exercise 13 — Awareness: nano, Emacs, and the rest of the family

The objective requires *awareness* of the alternatives. You should be able to open, save and exit each without help.

1. **nano** — the on-screen shortcut bar is the documentation. `^` means Control, `M-` means Alt/Meta.

```bash
nano -w svc.conf
```

| Keys | Action |
|---|---|
| `Ctrl-O` | write **O**ut (save) — it prompts for the filename, confirm with `Enter` |
| `Ctrl-X` | exit (prompts to save if modified) |
| `Ctrl-W` | **W**here is — search |
| `Ctrl-\` | search and replace |
| `Ctrl-K` | cut the current line |
| `Ctrl-U` | uncut (paste) |
| `Ctrl-G` | help |
| `Ctrl-C` | show the cursor position |
| `Alt-U` / `Alt-E` | undo / redo |

The `-w` flag disables hard line wrapping. On older nano versions, wrapping was **on** by default and silently split long lines in config files — a genuine cause of broken `/etc` files. Save a copy as `/tmp/nano-test.conf` with `Ctrl-O`, change the filename at the prompt, then `Ctrl-X`.

2. **Emacs** — modeless, chorded. `C-x` means Control-x; `M-x` means Alt-x.

```bash
emacs -nw svc.conf     # -nw = no window, run in the terminal
```

| Keys | Action |
|---|---|
| `C-x C-s` | save |
| `C-x C-c` | exit |
| `C-g` | cancel the current command (your `<Esc>`) |
| `C-k` | kill (cut) to end of line |
| `C-y` | yank (paste) |
| `C-s` / `C-r` | incremental search forward / backward |
| `C-_` or `C-x u` | undo |
| `C-x C-f` | open another file |

If `emacs` is not installed, that is itself the exam-relevant fact: `vi` is the only editor guaranteed present on a POSIX system.

3. **The rest of the family**, in one line each:

- `vim` — Vi IMproved: multi-level undo, visual mode, syntax highlighting, `:help`.
- `vi` — on most distros a symlink or minimal build of `vim`; sometimes `nvi` or `elvis`.
- `busybox vi` — a tiny subset found in Alpine/initramfs/containers; no swap file, no `:g`.
- `ed` — the line editor `vi` grew out of; still the only editor guaranteed to work over a 300-baud link or in a broken-`TERM` rescue shell.
- `sed` — the *stream* editor: same command language, non-interactive.

4. Run the built-in tutorial once — it is 25 minutes and it is the most efficient preparation for this objective:

```bash
vimtutor
```

**Check your understanding**

**Q40.** Give the save-and-exit keystrokes for `vi`, `nano` and Emacs.
**Q41.** You SSH into a container to fix a config and `vi` behaves oddly — no `u` history, `:set` mostly ignored, no `:g`. What are you probably running, and what is the safest way to make the change?
**Q42.** Why does the LPI objective insist on `vi` rather than allowing nano everywhere?

---

## Reference: the keys named by objective 103.8

| Key | Mode | Action |
|---|---|---|
| `h` `j` `k` `l` | normal | left, down, up, right |
| `i` `a` `o` | normal → insert | insert before cursor / append after cursor / open line below |
| `c` | normal (operator) | change (delete + insert), needs a motion: `cw`, `cc`, `C` |
| `d` | normal (operator) | delete, needs a motion: `dw`, `d$`, `dd`, `D` |
| `y` | normal (operator) | yank (copy), needs a motion: `yw`, `yy` |
| `dd` | normal | delete the current line (into the unnamed register) |
| `p` | normal | put after the cursor / below the line (`P` = before/above) |
| `/` | normal → search | search forward (`n` next, `N` previous) |
| `?` | normal → search | search backward |
| `ZZ` | normal | write if modified, then quit |
| `:w!` | command-line | force write |
| `:q!` | command-line | quit, discarding changes |
| `:!cmd` | command-line | run a shell command without leaving the editor |

---

## Answers

<details>
<summary><b>Click to reveal the answers to Q1–Q42</b></summary>

**A1.** `which vi` reports the first `vi` in `$PATH`, which is almost always a symlink (`/usr/bin/vi`) or an alternatives link. `readlink -f` resolves the entire chain of symlinks to the real binary, so it tells you whether you are about to run `vim.tiny`, a full `vim`, `nvi`, or `busybox`. Those differ in features that matter mid-edit (undo depth, visual mode, `:g`).

**A2.** `Ctrl-R` (redo) is a Vim addition. It does not exist in classic `vi`/`nvi`, and it is unavailable in `busybox vi`. It also behaves uselessly in Vim when `compatible` is set, because `u` then toggles rather than stepping back through an undo tree. Test with `:set compatible?` before relying on it.

**A3.** Any of: `crontab -e`, `visudo`, `sudoedit`/`sudo -e`, `git commit` (via `core.editor`, which falls back to `$EDITOR`), `systemctl edit`, `bash`'s `Ctrl-x Ctrl-e` (`edit-and-execute-command`), `less` with `v`. `VISUAL` is consulted before `EDITOR` by most of them; `sudoedit` checks `SUDO_EDITOR` first.

**A4.** *Normal (command) mode* — the mode you start in, where keys are commands; reached from anywhere with `<Esc>`. *Insert mode* — text you type is inserted; leave with `<Esc>`. *Command-line (ex) mode* — entered with `:` (also `/` and `?`), commands typed at the bottom line; leave with `<Esc>` or by pressing `<Enter>` to execute.

**A5.** You were in insert mode, so `dd` was literal text. Press `<Esc>` to return to normal mode, then `u` to undo the two inserted characters (or `x` twice). Then re-issue `dd`.

**A6.** `u` undoes one change at a time inside the current editing session, keeping the buffer's undo history. `:e!` discards **all** unsaved changes by re-reading the file from disk — it is a full reset to the last saved state, and it is not itself undoable.

**A7.** `Ctrl-[` sends the same control character (0x1B, ESC) as the Escape key. On serial consoles, IPMI/KVM viewers, some terminal emulators, and keyboards where Escape is remapped or far from the home row, `Ctrl-[` is faster and always available. It also avoids ambiguity with terminals that use a timeout to distinguish a lone `<Esc>` from an escape sequence.

**A8.** Line 17: `17G` (normal mode) or `:17<Enter>` (ex mode). Last line: `G` with no count (or `:$<Enter>`).

**A9.** `w` treats punctuation as word separators, so `10.0.2.11:9000` is many "words" — you would press `w` roughly a dozen times. `W` uses whitespace-delimited WORDs, so two presses (`server`, then the address) put you on `backup`. Rule: lowercase motions respect punctuation boundaries; uppercase ones only respect blanks.

**A10.** `%` — place the cursor on the opening `{` and press `%`. If the cursor jumps to a `}`, the braces are balanced up to that point and you can see exactly where the block ends. If the cursor does not move, there is no matching bracket — the block is unbalanced (or the cursor was not on a bracket to begin with).

**A11.** `Ctrl-D` scrolls half a screen, so half of the previously visible text stays on screen and gives you visual continuity — you cannot skip a line by accident. `Ctrl-F` advances a full screen and, if you blink or the terminal is small, content can pass without ever being read comfortably.

**A12.** `I` — insert before the first non-blank character. `i` in column 1 would insert *before the indentation*.

**A13.** It opens **five** new empty lines above the current line and leaves you in insert mode; whatever you type is repeated on each of the five lines when you press `<Esc>`.

**A14.** You were already in insert mode when you pressed `A`, so it was inserted as literal text — or the buffer is read-only (`vi -R` / `view` / no write permission), in which case Vim beeps and shows `W10: Warning: Changing a readonly file`. Check the bottom line and press `<Esc>`.

**A15.** To end of file: `dG`. To beginning of file: `dgg` (Vim) or `d1G` (works everywhere).

**A16.** `dw` deletes and leaves you in **normal** mode; `cw` deletes and leaves you in **insert** mode. That matters for `.` because the repeat command replays the *entire* change including the typed text: `.` after `cw` re-types the replacement word on the next target, which is what makes `cw` + `n` + `.` the fastest manual rename loop in `vi`.

**A17.** Normal mode: put the cursor on the first line, press `12dd`, press `G`, press `p`. Ex mode, in one command: `:.,+11m$` (or `:15,26m$` with explicit line numbers).

**A18.** Three copies exist: the original was cut into the unnamed register and removed from the buffer, then `p` put it back once and `p` again put a second copy below the first. The register still holds the line, so a third `p` would make a fourth.

**A19.** `"1` holds the most recent **line-wise delete**, and it shifts down the chain (`"1`→`"2`→…→`"9`) with every new line delete, so it is destroyed after nine more deletes. `"a` is a named register you wrote to explicitly; nothing overwrites it except another explicit write to `"a` (or exiting the editor — registers are session state unless `viminfo`/`shada` persists them).

**A20.** Lowercase `"a` **overwrites** register `a`. Uppercase `"A` **appends** to it. That is how you collect scattered lines from all over a file into one register before pasting them as a block.

**A21.** No. The numbered registers `"1`–`"9` only receive **line-wise** deletes (and deletes spanning more than one line). Small, within-line deletes such as `dw` or `x` go to the "small delete" register `"-` and to `""`, and only the most recent one survives. If you need a word later, yank it to a named register explicitly.

**A22.** `:%s/info/warn/gc<Enter>` — `%` = all lines, `g` = all occurrences per line, `c` = confirm each.

**A23.** On the left side, `.` is a regular-expression metacharacter matching *any* character, so unescaped `10.0.2.` would also match `10x0y2z`. Escaping it as `\.` forces a literal dot. The right side is a *replacement string*, not a pattern — `.` there has no special meaning (the characters that do are `&`, `\1`–`\9`, `~` and `\`).

**A24.** The search wrapped: after the last match in the file it continued from the top, printing `search hit BOTTOM, continuing at TOP`. Disable with `:set nowrapscan` (`:set nows`), which makes the search fail with `E385: search hit BOTTOM without match` instead of silently looping.

**A25.** Delete matching lines: `:g/DEBUG/d`. Keep only matching lines: `:v/DEBUG/d` (equivalently `:g!/DEBUG/d`).

**A26.** `u` undoes the last change (repeatable in Vim's `nocompatible` mode, a toggle in classic `vi`). `U` undoes **all** recent changes made to the last line you edited, as a single operation — and `U` itself is undoable with `u`. `Ctrl-R` redoes what `u` undid; it is a Vim feature only.

**A27.** It is behaving as classic `vi` (or Vim with `compatible` set): `u` is a single-level toggle, not a history. Adapt by making small, verifiable changes and saving frequently — for anything larger, save a checkpoint copy first (`:w /tmp/file.bak`) or use `:e!` to reset to the last save, because there is no undo history to walk back through.

**A28.** (1) `:w /tmp/fstab.new`, quit, then `sudo cp /tmp/fstab.new /etc/fstab` — but that risks losing ownership/mode/SELinux context. (2) `:w !sudo tee %` writes the buffer to `sudo tee`, but it triggers a password prompt inside the editor, does not work in `vim.tiny`, and leaves the buffer marked as modified. The correct production practice is to have opened it with `sudoedit /etc/fstab` in the first place, which preserves ownership and mode and never runs the editor as root.

**A29.** For a mode-`0400` file you own, `:w!` can still succeed because Vim can either temporarily change the mode (you own the file, so `chmod` is permitted) or write a new file in the directory and rename it — and you have write permission on the *directory*. For a root-owned file, neither is possible: you cannot `chmod` it and you cannot create files in `/etc`, so the write fails with `E212`. The decisive permission is write access to the **containing directory**, plus ownership — not the file's own mode bits.

**A30.** `:w /path/to/newfile` — writes the buffer under a new name and leaves the original on disk untouched. (Note that you keep editing the original file; use `:saveas` in Vim if you want the buffer to switch to the new name.)

**A31.** Do **not** choose `(R)ecover` or `(E)dit anyway` — another live process is editing the same file, and two writers will overwrite each other. Choose `(O)pen Read-Only` or `(Q)uit`, find the other session (`pgrep -a vim`, `who`, or reattach the `tmux`/`screen` session), and let it save and exit first.

**A32.** The swap file is not deleted by the recovery itself — Vim leaves it deliberately, so a failed or partial recovery can be retried. Until you remove it, every subsequent open of that file shows the `E325 ATTENTION` prompt, which trains people to hit `(E)dit anyway` reflexively and eventually lose real work.

**A33.** `:set noswapfile` (or start with `vim -n`) lets you edit without a swap file. You lose crash recovery entirely — if the session dies, unsaved changes are gone — and you lose the multi-user "file already being edited" warning. Alternatively, point swap elsewhere with `:set directory=/tmp` or `--cmd 'set dir=/dev/shm'`.

**A34.** `backupcopy=yes` copies the original aside and then overwrites the original file in place, so the **inode, hardlinks, ownership, mode and extended attributes are preserved**. `backupcopy=no` renames the original out of the way and writes a brand-new file, so the file gets a **new inode**, hardlinks are broken and symlinks are replaced by regular files. Production failure: editing a file that is bind-mounted into a container (Kubernetes projects a specific inode; the container keeps seeing the old content), editing a hardlinked config, or editing `/etc/resolv.conf` which is a symlink into `/run` — the symlink is destroyed and the resolver stops being updated.

**A35.** Inside `vi` you can type `:!/bin/bash`, `:shell`, or `:r !cmd`. Because `sudo` runs the whole editor as root, that shell is a root shell — the rule grants unrestricted root, and the shell escape is not logged as a sudo command. Also, `vi` can `:w` to *any* path, not just the one named in the rule. The correct rule uses `sudoedit`, which runs the editor unprivileged: `alice ALL=(root) NOPASSWD: sudoedit /etc/nginx/nginx.conf`.

**A36.** `crontab -e` edits a private temporary copy, invokes your `$VISUAL`/`$EDITOR`, **parses the result before installing it**, refuses to install a syntactically invalid crontab, and installs the file with the correct ownership, mode and location while holding a lock. Editing the spool file directly bypasses the syntax check and the locking, can leave a wrong owner or mode (which makes `cron` ignore the file), and races with `crontab` running concurrently.

**A37.** With `autoindent` on, `vi` cannot tell pasted keystrokes from typed ones, so it adds its own indentation to each incoming line *on top of* the indentation already present in the pasted text — producing an ever-widening staircase, which in YAML changes the document structure. Bracket the paste with `:set paste` before and `:set nopaste` after (in modern Vim you can also use bracketed paste or `"+p` from a register, which are not affected).

**A38.** `:%!sort` **filters** the buffer: the whole buffer is fed to `sort` on stdin and *replaced* by its output. `:r !sort` **reads** the command's output and inserts it at the cursor, leaving the existing buffer content in place — and here `sort` would have no input, so it would hang waiting on stdin.

**A39.** Both formats treat tabs and spaces as semantically different, and neither is visible on screen. YAML forbids tab characters for indentation outright; a `Makefile` requires a real tab at the start of a recipe line and fails with `missing separator` if it is spaces. `:set list` (with `listchars`) renders tabs, trailing blanks and end-of-line explicitly, turning an invisible bug into a visible one.

**A40.** `vi`: `<Esc>` then `ZZ` (or `:wq<Enter>` / `:x<Enter>`). `nano`: `Ctrl-O`, `Enter` to confirm the filename, then `Ctrl-X`. Emacs: `C-x C-s` then `C-x C-c`.

**A41.** You are almost certainly running `busybox vi` (typical of Alpine images and initramfs), which implements only a small subset of `vi`. The safest approach is not to edit in place at all: change the file in the image/manifest/ConfigMap that produced it and redeploy. If you must patch live, make the change with a non-interactive tool whose result you can verify (`sed -i`, or `cat > file <<'EOF'` writing the full intended content), and diff it afterwards — containers are meant to be replaced, not edited.

**A42.** `vi` is the only screen editor mandated by POSIX, so it is present on essentially every UNIX-like system, including minimal installs, rescue environments, appliances and vendor images where nano and Emacs are not installed and no package manager is reachable. An administrator who can only use nano is blocked exactly when it matters most — during recovery. That is also why `ed` awareness has value: it works even when the terminal type is unusable.

</details>

---

## Sources

- LPI, *Exam 101 Objectives (LPIC-1 version 5.0)*, objective 103.8 — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- The Open Group, *POSIX.1-2017, `vi` utility* (the behaviour every implementation must provide) — <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html>
- Vim project documentation (`:help` as published online): motions <https://vimhelp.org/motion.txt.html>, changing text <https://vimhelp.org/change.txt.html>, recovery <https://vimhelp.org/recover.txt.html>, options including `'backupcopy'`, `'compatible'` and `'paste'` <https://vimhelp.org/options.txt.html>
- GNU nano, *nano(1) manual page* — <https://www.nano-editor.org/dist/latest/nano.1.html>
- GNU Emacs, *Emacs Manual — Basic Editing Commands* — <https://www.gnu.org/software/emacs/manual/html_node/emacs/Basic.html>
- Sudo project, *sudoedit / sudo(8)* — <https://www.sudo.ws/docs/man/sudo.man/> — and *visudo(8)* — <https://www.sudo.ws/docs/man/visudo.man/>
- Linux man-pages project, *crontab(1)* — <https://man7.org/linux/man-pages/man1/crontab.1.html>
- Debian, *update-alternatives(1)* (how `/usr/bin/vi` is resolved on Debian-family systems) — <https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html>