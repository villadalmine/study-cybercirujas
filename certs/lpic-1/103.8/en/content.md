# LPIC-1 103.8 — Basic file editing

> **Exam:** 101-500 (LPIC-1, version 5.0) · **Topic:** 103.8 · **Weight:** 4.69
>
> **Official objective description:** *Candidates are required to be able to edit text files using `vi`. This objective includes `vi` navigation, basic `vi` modes, inserting, editing, deleting, copying and finding text. It also includes awareness of other common editors and setting the default editor.*
>
> **Key knowledge areas:** navigate a document using `vi` · understand and use `vi` modes · insert, edit, delete, copy and find text in `vi` · awareness of Emacs, nano and vim · configure the standard editor.
>
> **Terms and utilities:** `vi` · `/` · `?` · `h,j,k,l` · `i` · `o` · `a` · `c` · `d` · `p` · `y` · `dd` · `yy` · `ZZ` · `:w!` · `:q!` · `:e!` · `EDITOR`

---

## 1. Motivation: the architectural problem

### 1.1 The editor is the last tool standing

Every abstraction you build — Terraform, Ansible, Helm, GitOps controllers — eventually fails in a way that leaves you on a console with a shell and a filesystem. In that state the following are frequently **unavailable**: your dotfiles, your package manager, the network, `bash` completion, and any editor you personally like.

Concrete production situations where `vi` is not a preference but the only interface:

| Situation | Why nothing else is available |
|---|---|
| Node fails to boot; you land in `dracut`/`initramfs` emergency shell | The root filesystem is not mounted; only the initramfs binaries exist (BusyBox `vi`, sometimes nothing) |
| Serial/IPMI/iDRAC console after a bad `/etc/fstab` edit | No network, no SSH, no `scp`, 9600 baud, no scrollback |
| Rescue boot of a cloud VM (`systemd.unit=rescue.target`) | Chrooted into the broken root; only the base image is present |
| Minimal container image (`alpine`, `busybox`, `debian:slim`) | `vi` from BusyBox is present; `nano`, `less`, `git` are not |
| A hardened host where package installation is blocked by policy | You may not `apt install nano` on a PCI-scoped node |
| `sudoedit`, `visudo`, `vipw`, `crontab -e`, `systemctl edit`, `kubectl edit`, `git commit`, `git rebase -i` | These tools **spawn an editor for you**; if `$EDITOR` is unset, you get `vi` whether you like it or not |

The last row is the one that catches people who "never use vi": a large amount of standard Linux tooling is architected as *"serialize state to a temp file → invoke `$EDITOR` → validate → commit"*. If you cannot drive `vi`, you cannot drive `visudo`, and a botched `visudo` session can end privileged access to a fleet.

### 1.2 What "editing a file" actually is

An editor is not a magic mutation of bytes in place. Understanding the syscall-level model is what separates "I saved the file" from "I saved the file and the running service actually sees it".

There are exactly two write strategies, and their operational consequences are completely different:

```
Strategy A — "copy" (in-place truncate + rewrite)
  open(path, O_WRONLY|O_TRUNC)  →  write(...)  →  close()
  inode:      UNCHANGED
  hardlinks:  preserved
  bind mounts: still valid
  ACL/xattr/SELinux label: preserved
  atomicity:  NONE — a crash mid-write leaves a truncated file
  disk need:  transiently 2x if a backup copy is kept

Strategy B — "rename" (write new + atomic replace)
  open(path.tmp, O_CREAT|O_WRONLY) → write(...) → fsync() → rename(path.tmp, path)
  inode:      NEW
  hardlinks:  BROKEN (the other link still points at the old inode)
  bind mounts: STALE (a file bind mount follows the old inode forever)
  ACL/xattr/SELinux label: recreated from defaults unless explicitly copied
  atomicity:  full — readers see either the old file or the new file
  disk need:  transiently 2x
```

Vim implements both and selects between them with the `'backupcopy'` option (`yes` = strategy A, `no` = strategy B, `auto` = decide per file). This single option is responsible for an entire class of "I edited the config but nothing changed" incidents:

- A file bind-mounted into a container (`-v /etc/app/app.conf:/etc/app.conf`) is bound to the **inode**. Edit it with strategy B on the host and the container keeps reading the old bytes forever, until the container is recreated.
- `tail -f` (not `tail -F`) follows the old inode. Your log-shipping sidecar may do the same.
- `inotify` watchers registered with `IN_MODIFY` on the path see nothing; watchers need `IN_MOVE_SELF`/`IN_DELETE_SELF` and re-registration. This is why `systemd` `PathChanged=` and many config-reload hot-loops behave inconsistently across editors.
- A process that already has the file open (e.g. `sshd` holding `/etc/ssh/sshd_config`? it does not — but `rsyslogd`, `haproxy` in some modes, and anything with an mmap'd file does) keeps the old content until reopened.

### 1.3 The rule that must survive the exam

> **Hand-editing a file on a production node is always an incident, never a workflow.**

The declarative pipeline (git → CI → config management → node) is the *only* supported path to change. The editor exists for three legitimate purposes:

1. **Authoring** the source of truth in the repository, on your workstation.
2. **Break-glass**: restoring service when the pipeline itself is the thing that is broken.
3. **Mediated edits** where a tool wraps the editor with locking and validation (`visudo`, `vipw`, `crontab -e`, `systemctl edit`, `sudoedit`, `kubectl edit`).

Anything else is configuration drift that will be silently reverted by the next converge run — or, worse, will *not* be reverted and will become an undocumented snowflake.

---

## 2. Editor landscape and trade-offs

### 2.1 The `vi` lineage

```
ed (1969, Ken Thompson)              line editor, POSIX-mandated, works on a teletype
 └── ex (1976, Bill Joy)             ed + more powerful line commands
      └── vi (1976)                  "visual mode" of ex — a full-screen front end
           ├── nvi     (BSD, the "real" vi reimplementation)
           ├── elvis   (used by some minimal distros)
           ├── vim     (Vi IMproved, Bram Moolenaar, 1991) — the de facto vi on Linux
           │    ├── vim.tiny / vim-minimal   (what /usr/bin/vi usually is)
           │    └── neovim (fork, 2014)
           ├── busybox vi   (~2000 lines of C, embedded/initramfs/containers)
           └── toybox vi    (Android, minimal)
```

**Everything in the LPI objective is `ex`/`vi` core functionality present in every one of these.** That is deliberate: the exam tests the intersection, not vim's superset.

### 2.2 Editor comparison — trade-offs

| Property | `ed` | POSIX `vi` / `nvi` | `busybox vi` | `vim` (huge) | GNU `nano` | GNU Emacs |
|---|---|---|---|---|---|---|
| Typical size on disk | ~60 KB | ~400 KB | part of the ~1 MB busybox blob | ~3.5 MB + ~30 MB runtime | ~250 KB + ~1 MB | ~40 MB+ |
| Present in a minimal container | rarely | rarely | **yes** (alpine/busybox) | no | no | no |
| Present in initramfs / rescue | sometimes | sometimes | **yes** | no | no | no |
| Needs a working `terminfo` entry | **no** | yes | yes | yes | yes | yes |
| Usable over a broken/dumb terminal | **yes** | no | no | no | no | no |
| Modal | n/a (line-oriented) | yes | yes | yes | **no** | no |
| Multi-level undo | no | no (single `u`, `U` for line) | no (single `u`) | **yes** (`u` / `Ctrl-r`, persistent undo) | yes (`M-u`/`M-e`) | yes |
| Syntax highlighting | no | no | no | **yes** | yes (with `.nanorc`) | yes |
| Discoverable UI (on-screen key hints) | no | no | no | no | **yes** | partially |
| Scriptable non-interactively | **yes** (stdin script) | yes (`ex` mode, `-c`) | limited | yes (`-es -c`) | no | yes (`--batch`) |
| Recovery after crash | no | yes (`-r`) | no | **yes** (`.swp`, `-r`) | yes (`.save` emergency file) | yes (`#file#` autosave) |
| Writes swap/backup files next to the source (data-leak risk) | no | yes | no | **yes** | only on crash | yes |
| Learning cost | high | high | high | high | **very low** | very high |
| Guaranteed on any LPI-relevant system | POSIX-required | **POSIX-required** | no | no | no | no |

**Architectural reading of this table:** `nano` optimises for the *first* five minutes of a person's career; `vi` optimises for the *worst* five minutes of a system's life. Standardise on `nano` for humans if you like — but the recovery runbook must assume `vi`, because `nano` is not guaranteed to exist on the box you are trying to save.

### 2.3 Interactive editing vs. non-interactive mutation

Knowing when *not* to open an editor is a senior skill. For fleet-wide or repeatable change, the editor is the wrong tool:

| Method | Idempotent | Auditable | Atomic write | Validates | Use when |
|---|---|---|---|---|---|
| `vi` by hand | ❌ | ❌ (only shell history) | depends on `backupcopy` | ❌ | Break-glass, single host, once |
| `sed -i` | ❌ (regex may match 0 or N times) | partially | ⚠️ `sed -i` **replaces the inode** | ❌ | Quick one-off text surgery; never in a converge loop |
| `ex`/`vim -es -c` script | ❌ | partially | same as vim | ❌ | Scripted edits that need vi's motion grammar |
| `ansible.builtin.lineinfile` | ✅ | ✅ (playbook in git) | ✅ (writes temp + `atomic_move`) | via `validate:` | Fleet change to a *line* |
| `ansible.builtin.template` / `copy` | ✅ | ✅ | ✅ | via `validate:` | Fleet change to a *file* — the default choice |
| `kubectl apply -f` | ✅ | ✅ | server-side | ✅ (schema + admission) | Kubernetes objects — the default choice |
| `kubectl edit` | ❌ | ✅ (audit log records the PATCH) | server-side | ✅ | Break-glass on a live object |
| `kubectl patch` | ✅ | ✅ | server-side | ✅ | Scripted single-field change |

> **`sed -i` is not in-place.** It writes a temp file and renames it. It therefore has exactly the hardlink/bind-mount/inode consequences of strategy B in §1.2, plus it silently drops the original SELinux context on some systems. Use `sed -i` on files you own, not on `/etc` files that other subsystems track.

### 2.4 Which binary is `/usr/bin/vi`, really?

This matters, because `vim.tiny` silently lacks features you may be relying on (no multi-level undo, no visual mode, no syntax highlighting).

```
$ readlink -f "$(command -v vi)"
/usr/bin/vim.tiny

$ vi --version | head -n 5
VIM - Vi IMproved 9.1 (2024 Jan 02, compiled Jan 15 2026 09:12:41)
Included patches: 1-16
Modified by team+vim@tracker.debian.org
Compiled by team+vim@tracker.debian.org
Small version without GUI.  Features included (+) or excluded (-):

$ vi --version | grep -oE '[+-]multi_byte|[+-]persistent_undo|[+-]syntax|[+-]visual'
-persistent_undo
-syntax
+visual
```

On Red Hat–family systems `/usr/bin/vi` comes from `vim-minimal` and `/usr/bin/vim` from `vim-enhanced`:

```
$ rpm -qf /usr/bin/vi /usr/bin/vim
vim-minimal-9.1.083-1.el9.x86_64
vim-enhanced-9.1.083-1.el9.x86_64
```

On Debian-family systems the choice is mediated by the alternatives system:

```
$ update-alternatives --display editor
editor - auto mode
  link best version is /usr/bin/vim.basic
  link currently points to /usr/bin/vim.basic
  link editor is /usr/bin/editor
  slave editor.1.gz is /usr/share/man/man1/editor.1.gz
/bin/nano - priority 40
  slave editor.1.gz: /usr/share/man/man1/nano.1.gz
/usr/bin/vim.basic - priority 30
  slave editor.1.gz: /usr/share/man/man1/vim.1.gz
/usr/bin/vim.tiny - priority 15
  slave editor.1.gz: /usr/share/man/man1/vim.1.gz
```

Note the trap: `nano` has **priority 40**, higher than `vim.basic`'s 30. On a stock Debian with `nano` installed, `/usr/bin/editor` — and therefore the fallback for many tools — is `nano`, not `vi`. Setting the system-wide default is covered in §6.

### 2.5 `ed`: the one that always works

When `TERM` is wrong, the terminfo database is missing (extremely common in scratch containers), or the console is a genuine line device, full-screen editors abort. `ed` does not use terminfo at all.

```
$ TERM=unknown vim /etc/hosts
E558: Terminal entry not found in terminfo
'unknown' not known. Available builtin terminals are:
    builtin_riscos
    builtin_ansi
    builtin_dumb
    builtin_debug
defaulting to 'ansi'

$ TERM=unknown ed /etc/hosts
221
p
127.0.0.1	localhost
,n
1	127.0.0.1	localhost
2	::1	localhost ip6-localhost ip6-loopback
3	10.20.0.11	node-01.internal node-01
2a
10.20.0.12	node-02.internal node-02
.
w
267
q
```

`ed` is silent by default (`?` is its entire error vocabulary — `H` turns on verbose errors). It is unpleasant, and it is the difference between fixing a box and reimaging it.

---

## 3. `vi` architecture: the modal state machine

### 3.1 Modes

The single conceptual leap of `vi` is that **the keyboard is a command language, and typing text is a temporary sub-mode of that language**. Every key has a meaning that depends on the current mode.

```
                        ┌──────────────────────────────────────────┐
                        │            COMMAND MODE                  │
                        │        (a.k.a. "normal mode")            │
        Esc  ──────────►│  keys are operators, motions and counts  │◄────── Esc
         │              │  this is where vi STARTS                 │        │
         │              └───┬───────────────┬──────────────────┬───┘        │
         │      i I a A o O │               │ :                │ v V ^V     │
         │      c s S R     │               │                  │ (vim only) │
         │                  ▼               ▼                  ▼            │
   ┌─────┴────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
   │ REPLACE MODE │  │ INSERT MODE  │  │ EX / LAST-   │  │ VISUAL MODE  │───┘
   │  (R)         │  │ typed keys   │  │ LINE MODE    │  │ select a     │
   │              │  │ enter the    │  │ :w :q :s     │  │ region, then
   │              │  │ buffer       │  │ Enter runs it│  │ apply an
   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │ operator
          │  Esc            │  Esc            │ Enter/Esc└──────────────┘
          └─────────────────┴─────────────────┘
```

Operational consequences worth internalising:

- **`Esc` is idempotent and always safe.** When lost, press `Esc` twice. In command mode a stray `Esc` does nothing (older terminals beep). This is the recovery primitive.
- **`vi` starts in command mode.** Text typed by someone who assumes otherwise is executed as commands. `dd` deletes a line, `ZZ` saves and exits, `:q!` quits — a person "just typing" into a `visudo` session can and will corrupt `/etc/sudoers`.
- **Visual mode does not exist in POSIX `vi`.** It is a vim extension. The exam does not require it; production ergonomics do.

### 3.2 Buffer, file, swap, undo — four distinct objects

```
   ~/.vimrc / /etc/vim/vimrc            ┌───────────────────────────┐
   VIMINIT / EXINIT / .exrc  ──────────►│  vim process              │
                                        │                           │
   /etc/ssh/sshd_config  ──── read ────►│   BUFFER  (RAM)           │
        ^        ^                      │      │                    │
        │        │                      │      ├── every keystroke ─┼──► /etc/ssh/.sshd_config.swp
        │        │  :w  (write path,    │      │   (crash recovery, │      created at open,
        │        │      see §3.3)       │      │    fsync'd on idle)│      deleted on clean exit
        │        └──────────────────────┼──────┘                    │
        │                               │      └── undo tree ───────┼──► ~/.vim/undodir/... (vim only,
        │                               │                           │      if 'undofile' is on)
        └── :e!  (discard buffer, ──────┤   ~/.viminfo  ◄───────────┤      command history, registers,
             re-read from disk)         └───────────────────────────┘      marks, last search, and the
                                                                            first lines of yanked text
```

**Security consequence, and it is a real one:** open `/etc/shadow` in vim and a file named `/etc/.shadow.swp` appears, containing hashes, with the permissions of the *directory*'s default umask behaviour. Kill the session (SIGKILL, OOM, dropped SSH) and it stays there. `~/.viminfo` similarly persists yanked text — a copied private key ends up in a mode-0600 file in your home directory, which is then backed up, synced, and included in the next image.

The correct habit for secrets:

```
$ vim -n -i NONE /etc/shadow     # -n = no swapfile, -i NONE = no viminfo
```

Or make it structural (see the hardened `vimrc` in §7.1).

### 3.3 The write path in detail

```
$ stat -c 'inode=%i links=%h perms=%a owner=%U:%G' /etc/haproxy/haproxy.cfg
inode=1179842 links=1 perms=644 owner=root:root

$ sudo vim -c 'set backupcopy=no' -c 'normal Go# touched' -c 'wq' /etc/haproxy/haproxy.cfg

$ stat -c 'inode=%i links=%h perms=%a owner=%U:%G' /etc/haproxy/haproxy.cfg
inode=1179971 links=1 perms=644 owner=root:root      <-- INODE CHANGED
```

With `backupcopy=yes` the inode is stable:

```
$ sudo vim -c 'set backupcopy=yes' -c 'normal Go# touched again' -c 'wq' /etc/haproxy/haproxy.cfg

$ stat -c 'inode=%i links=%h' /etc/haproxy/haproxy.cfg
inode=1179971 links=1                                 <-- INODE PRESERVED
```

| `backupcopy` value | Mechanism | Inode | Hardlinks | Bind mount survives | Atomic | Use for |
|---|---|---|---|---|---|---|
| `yes` | truncate original, rewrite | preserved | preserved | ✅ | ❌ | Bind-mounted files, hardlinked files, files with ACLs/xattrs/immutable-adjacent semantics |
| `no` | write new, `rename(2)` over | **new** | **broken** | ❌ | ✅ | Large files on slow disks; when readers must never see a partial file |
| `auto` (default) | vim picks; leans to `no` when ownership/permissions can be preserved | usually new | usually broken | ⚠️ | usually | General authoring on a workstation |

**Rule of thumb for nodes:** `set backupcopy=yes` in the system `vimrc` of any host that bind-mounts config files into containers or uses hardlinked config trees. The lost atomicity is a smaller risk than the silent no-op.

### 3.4 The operator–motion grammar

`vi` is not a list of shortcuts to memorise; it is a tiny language. Almost every editing command is:

```
   [count]  operator  [count]  motion
      3        d         2        w        →  delete 6 words  (3 × 2)
                d                 $        →  delete to end of line
      5        y                 y         →  operator doubled = act on 5 whole lines
                c                 /ERROR⏎  →  change from cursor up to the next match of "ERROR"
                d                 G        →  delete from cursor to end of file
                >                 }        →  indent to end of paragraph  (vim/nvi)
```

| Component | Values (exam-relevant) |
|---|---|
| **Operators** | `d` delete · `c` change (delete + enter insert) · `y` yank (copy) · `>` `<` indent · `!` filter through an external command · `=` reindent (vim) |
| **Motions** | `h j k l` · `w W b B e E` · `0 ^ $` · `G gg` · `{ }` · `( )` · `f F t T` · `/ ?` · `%` |
| **Doubling** | `dd` `yy` `cc` `>>` — apply the operator to whole lines |
| **Counts** | any digits before the operator, before the motion, or both (they multiply) |

Learning the grammar means `d3w`, `y}`, `c/timeout⏎` and `!}sort` all come for free once you know `d`, `y`, `c` and `!`. Memorising a flashcard list does not scale; the grammar does.

---

## 4. The command reference the exam tests

### 4.1 Starting and stopping

| Command | Effect |
|---|---|
| `vi file` | Open `file` (creates it in the buffer if it does not exist; nothing is written until `:w`) |
| `vi +25 file` | Open at line 25 |
| `vi +/pattern file` | Open at the first line matching `pattern` |
| `vi -R file` / `view file` | Open read-only (buffer still modifiable; `:w!` can force a write) |
| `vim -M file` | Open non-modifiable (hard read-only) |
| `vi -r` | List recoverable swap files |
| `vi -r file` | Recover `file` from its swap file |
| `vim -n file` | No swap file |
| `vim -i NONE file` | No `viminfo` read/write |
| `vi file1 file2 file3` | Open several files; `:n` next, `:N`/`:prev` previous, `:rew` first, `:args` list |

### 4.2 Navigation (command mode)

| Key | Movement | Key | Movement |
|---|---|---|---|
| `h` | one character **left** | `0` | column 0 — start of line |
| `j` | one line **down** | `^` | first non-blank character of the line |
| `k` | one line **up** | `$` | end of line |
| `l` | one character **right** | `G` | last line of the file |
| `w` | start of next word (punctuation is a word) | `1G` or `gg` | first line of the file |
| `W` | start of next WORD (whitespace-delimited only) | `nG` or `:n` | go to line `n` |
| `b` / `B` | back one word / WORD | `H` `M` `L` | **H**igh / **M**iddle / **L**ow line of the screen |
| `e` / `E` | end of word / WORD | `Ctrl-f` / `Ctrl-b` | page **f**orward / **b**ackward |
| `f<c>` / `F<c>` | jump **to** next/previous `<c>` on the line | `Ctrl-d` / `Ctrl-u` | half page **d**own / **u**p |
| `t<c>` / `T<c>` | jump **till** just before/after `<c>` | `%` | jump to the matching `( ) [ ] { }` |
| `;` / `,` | repeat / reverse the last `f F t T` | `` `` `` | jump back to the previous position |
| `{` / `}` | previous / next blank-line-delimited paragraph | `Ctrl-g` | show filename, line number, modified flag |

> **Why `hjkl`?** Bill Joy wrote `vi` on an ADM-3A terminal whose keyboard had the arrow glyphs printed on those four keys, and which had no dedicated cursor keys. Arrow keys work in vim today, but `hjkl` is the only form guaranteed to work over a mangled terminal, in `busybox vi`, and inside `screen`/`tmux` with a broken `TERM`. Learn `hjkl`.

**Screen positioning (vim/nvi):** `zt` current line to top, `zz` to centre, `zb` to bottom. Invaluable when reviewing a config hunk on a 24-line console.

### 4.3 Entering insert mode

| Key | Where insertion begins |
|---|---|
| `i` | **before** the cursor |
| `I` | before the first non-blank character of the line |
| `a` | **after** the cursor (append) |
| `A` | at the end of the line |
| `o` | **open** a new line **below** the current one |
| `O` | open a new line **above** the current one |
| `s` | delete the character under the cursor, then insert |
| `S` or `cc` | delete the whole line, then insert |
| `C` or `c$` | delete to end of line, then insert |
| `R` | replace mode — overwrite characters until `Esc` |

Return to command mode with `Esc` (or `Ctrl-[`, which is the same byte, `0x1b` — useful on keyboards where `Esc` is far away or on a serial line that eats it).

### 4.4 Deleting, changing, copying, pasting

| Key(s) | Effect |
|---|---|
| `x` | delete the character **under** the cursor |
| `X` | delete the character **before** the cursor |
| `3x` | delete 3 characters |
| `dw` | delete from cursor to start of next word |
| `d$` or `D` | delete from cursor to end of line |
| `d0` | delete from cursor back to start of line |
| **`dd`** | **delete the whole current line** |
| `5dd` | delete 5 lines |
| `dG` | delete from the current line to end of file |
| `dgg` | delete from the current line to start of file |
| `d/ERROR⏎` | delete from the cursor up to the next match of `ERROR` |
| `cw` | change a word (delete it and enter insert mode) |
| `cc` | change the whole line |
| `r<c>` | replace the single character under the cursor with `<c>` — stays in command mode |
| **`yy`** or `Y` | **yank (copy) the current line** |
| `3yy` | yank 3 lines |
| `yw` / `y$` | yank a word / to end of line |
| **`p`** | **put (paste) after** the cursor — below the line for line-wise yanks |
| `P` | put **before** the cursor — above the line for line-wise yanks |
| `J` | join the next line onto the current one |
| `~` | toggle the case of the character under the cursor |
| `.` | **repeat the last change** — the single highest-leverage key in `vi` |

**Registers.** Every delete and yank goes into the unnamed register `""`. Named registers `"a` … `"z` are explicit; `"A` … `"Z` *append*. Deletions also fill the numbered ring `"1` … `"9`.

```
"ayy      yank the current line into register a
"Ayy      APPEND the current line to register a
"ap       put register a
"1p       put the most recent deletion  (then u and "2p for the one before, etc.)
"+yy      yank into the X11 clipboard   (vim compiled with +clipboard only)
```

> **The classic trap:** `dd` then move then `dd` then `p` pastes the *second* deletion, because the second `dd` overwrote the unnamed register. The first deletion is not lost — it is in `"1`. `"2p` recovers the one before that.

### 4.5 Searching and replacing

| Key(s) | Effect |
|---|---|
| **`/pattern⏎`** | search **forward** for `pattern` (a regular expression) |
| **`?pattern⏎`** | search **backward** for `pattern` |
| `n` | repeat the search **in the same direction** as the original |
| `N` | repeat the search in the **opposite** direction |
| `/⏎` | repeat the last search forward |
| `*` / `#` | search forward/backward for the word under the cursor (vim) |
| `:set ic` / `:set noic` | case-insensitive / case-sensitive search (`ignorecase`) |
| `/pattern\c` | case-insensitive for this search only (vim) |
| `:set hls` / `:noh` | highlight all matches / clear the highlight (vim) |

Searching wraps around the end of the file by default (`:set nowrapscan` to stop that) and reports:

```
search hit BOTTOM, continuing at TOP
```

**Substitution** — an `ex` command, and the reason `vi` beats a mouse for config work:

| Command | Effect |
|---|---|
| `:s/old/new/` | replace the **first** occurrence on the **current** line |
| `:s/old/new/g` | replace **all** occurrences on the current line |
| `:%s/old/new/g` | replace all occurrences in the **whole file** |
| `:%s/old/new/gc` | …asking for **c**onfirmation on each (`y`/`n`/`a`/`q`/`l`) |
| `:1,20s/old/new/g` | restrict to lines 1–20 |
| `:.,$s/old/new/g` | from the current line (`.`) to the last line (`$`) |
| `:g/^#/d` | **g**lobal: delete every line starting with `#` |
| `:g!/^#/d` or `:v/^#/d` | delete every line **not** starting with `#` |
| `:%s#/var/log#/srv/log#g` | any character can be the delimiter — use `#` or `,` when the pattern contains `/` |

```
:%s/PermitRootLogin yes/PermitRootLogin no/g
2 substitutions on 2 lines
```

### 4.6 Saving and quitting — the exam's literal terms

| Command | Effect |
|---|---|
| `:w` | **w**rite the buffer to the current file |
| `:w newfile` | write the buffer to `newfile` (the buffer stays attached to the original) |
| `:w >> other` | append the buffer to `other` |
| **`:w!`** | **force** write — attempt the write even when the buffer is marked read-only, or when the file is read-only but the *permissions on the file and directory still allow root/the owner to write*. It does **not** grant permissions you do not have. |
| `:q` | **q**uit — refuses if the buffer has unsaved changes (`E37: No write since last change`) |
| **`:q!`** | **quit, discarding all unsaved changes** |
| `:wq` | write and quit (writes even if unmodified — updates mtime) |
| `:x` | write **only if modified**, then quit (does not touch mtime needlessly) |
| **`ZZ`** | command-mode equivalent of `:x` — write if modified, then quit |
| `ZQ` | command-mode equivalent of `:q!` |
| `:qa!` / `:wqa` | quit / write all open buffers |
| **`:e!`** | **re-edit** — discard every unsaved change and reload the file from disk |
| `:e otherfile` | edit a different file in this session |
| `:r otherfile` | **r**ead `otherfile` in below the cursor |
| `:r !command` | read the **output of a shell command** in below the cursor |
| `:!command` | run a shell command, show the output, return |
| `:sh` / `Ctrl-z` | drop to a shell / suspend the editor (`fg` to return) |

> **`:x` vs `:wq`.** `:wq` always writes, so it always updates the mtime, so it triggers every `inotify` watcher, every `make`, every config-management "file changed" handler — even when you changed nothing. `:x` (and `ZZ`) writes only when the buffer is dirty. On a node running a reload-on-change watcher, `:wq` on an unmodified file causes a gratuitous service reload. Prefer `ZZ`/`:x`.

### 4.7 Undo

| Key | POSIX `vi` / `vim.tiny` | `vim` (full) |
|---|---|---|
| `u` | undo the **last change**; pressing it again **redoes** it (it toggles) | undo one step; repeatable through the whole undo history |
| `U` | restore the current line to its state before you started changing it | same |
| `Ctrl-r` | — | **redo** |
| `:earlier 10m` / `:later 5m` | — | move through the undo **tree** by time (vim) |

This difference bites in an emergency: on a rescue console with `vim.tiny` or `busybox vi`, `u` is a *toggle*, not a history. There is no way back beyond one change. `:e!` (reload from disk) is your real undo.

### 4.8 Visual mode and block editing (vim — not on the exam, essential in practice)

| Key | Effect |
|---|---|
| `v` | character-wise selection |
| `V` | line-wise selection |
| `Ctrl-v` | **block** (column) selection |
| after selecting: `d` `y` `c` `>` `<` `=` `u` `U` | apply the operator to the selection |

The single most useful production recipe — indent a YAML block by two spaces:

```
Ctrl-v      start block selection
j j j j     extend down over the lines
I           insert at the start of the block
<space><space>
Esc         the insertion is replicated to every selected line
```

And its inverse, commenting out a block:

```
Ctrl-v  jjjj  I  #  Esc
```

---

## 5. `nano` — awareness level

`nano` is modeless: keys type themselves, commands are `Ctrl` (`^`) and `Alt` (`M-`) chords, and the two bottom lines show the chords. The objective requires *awareness*, and production requires knowing the write-out/exit pair because that is where people lose work.

| Chord | Effect |
|---|---|
| `^G` | help |
| **`^O`** | **W**rite **O**ut (save) — prompts for the filename, `⏎` to confirm |
| **`^X`** | e**X**it — prompts `Save modified buffer?` → `Y`/`N`/`^C` |
| `^K` | cut the current line (into the cutbuffer) |
| `^U` | un-cut / paste the cutbuffer |
| `^W` | **W**here is — search |
| `^\` | replace |
| `^_` or `M-G` | go to line/column |
| `^C` | show current position |
| `^6` or `M-A` | set mark (start a selection) |
| `M-U` / `M-E` | undo / redo |
| `M-#` | toggle line numbers |
| `M-$` | toggle soft line wrapping |
| `^R` | insert another file into this buffer |
| `^T` | invoke spell/linter (configurable) |

```
$ nano -w /etc/hosts
```

`-w` disables hard wrapping. **Always use `-w` when editing configuration files** — nano historically wrapped long lines at the terminal width and physically inserted a newline, which will silently corrupt a long `sshd_config` `AllowUsers` line or a Kubernetes `command:` array. Modern nano defaults to no hard wrap, but the flag is free and the failure mode is expensive.

Persistent configuration lives in `/etc/nanorc` (system) and `~/.nanorc` (user) — see §7.2.

**Emacs, awareness level:** modeless, `Ctrl-x Ctrl-s` saves, `Ctrl-x Ctrl-c` exits, `Ctrl-g` cancels the current command. It is a Lisp environment with an editor attached; it is not present on servers by default and is not a realistic recovery tool.

---

## 6. Configuring the standard editor

### 6.1 `EDITOR` and `VISUAL`

The convention dates from teletypes: `EDITOR` names a **line editor** usable on any terminal; `VISUAL` names a **full-screen editor** requiring a capable terminal. Programs that need a full-screen editor prefer `VISUAL` and fall back to `EDITOR`; programs that only need a line editor use `EDITOR`.

In practice, on modern Linux, set **both** to the same value:

```bash
export VISUAL=vim
export EDITOR=vim
```

**Resolution order is program-specific.** Do not memorise a universal order — there isn't one. Memorise the *method* for determining it (§6.2). The common cases:

| Tool | Lookup order |
|---|---|
| `sudoedit` / `sudo -e` | `SUDO_EDITOR` → `VISUAL` → `EDITOR` → the `editor` setting in `sudoers` |
| `visudo` | the `editor` setting in `sudoers` (default `/usr/bin/vi`); the environment is consulted **only** if `env_editor` is enabled in `sudoers` |
| `crontab -e` | `VISUAL` / `EDITOR` (order varies by cron implementation) → compiled-in default (`/usr/bin/editor` on Debian, `/usr/bin/vi` on RHEL) |
| `git commit`, `git rebase -i` | `GIT_EDITOR` → `core.editor` → `VISUAL` → `EDITOR` → `vi` |
| `systemctl edit` | `SYSTEMD_EDITOR` → `EDITOR` → `VISUAL` → `editor`/`nano`/`vim`/`vi` |
| `kubectl edit` | `KUBE_EDITOR` → `EDITOR` → `vi` |
| `virsh edit` | `VISUAL` → `EDITOR` → `vi` |
| `vipw` / `vigr` | `VISUAL` → `EDITOR` → `vi` |
| `less` (`v` key) | `VISUAL` → `EDITOR` |
| Debian `/usr/bin/editor` | the `update-alternatives` link, independent of the environment |

### 6.2 Prove it instead of guessing

Never assume which variable a tool honours. Instrument it with a shim — this technique works for any `$EDITOR`-driven tool and takes fifteen seconds:

```
$ cat > /tmp/which-editor <<'EOF'
#!/bin/sh
echo "INVOKED AS: $0" >&2
echo "ARGV:       $*" >&2
echo "SUDO_EDITOR=${SUDO_EDITOR-<unset>}" >&2
echo "VISUAL=${VISUAL-<unset>}" >&2
echo "EDITOR=${EDITOR-<unset>}" >&2
exit 1
EOF
$ chmod +x /tmp/which-editor

$ VISUAL=/tmp/which-editor EDITOR=/bin/false crontab -e
INVOKED AS: /tmp/which-editor
ARGV:       /tmp/crontab.5vXn2q
SUDO_EDITOR=<unset>
VISUAL=/tmp/which-editor
EDITOR=/bin/false
crontab: "/tmp/which-editor" exited with status 1
crontab: edits left in /tmp/crontab.5vXn2q
```

That output settles the question on *this* system and *this* version, which is the only answer that matters during an incident. Note also the last line: `crontab` preserved your work in a temp file rather than discarding it — the same is true for `visudo` and `kubectl edit`.

An equivalent, lower-tech probe:

```
$ strace -f -e trace=execve -qq crontab -e 2>&1 | grep -m1 execve
execve("/usr/bin/editor", ["/usr/bin/editor", "/tmp/crontab.9KqLpM"], 0x7ffd... /* 24 vars */) = 0
```

### 6.3 Setting it: user, system, and fleet

**Per user** — `~/.bashrc` is wrong for this; login-shell files are right, because `sudo` and `cron` do not source `~/.bashrc`:

```
$ printf '\nexport VISUAL=vim\nexport EDITOR=vim\n' >> ~/.profile
$ . ~/.profile
$ echo "$EDITOR"
vim
```

**System-wide** — a drop-in, never an edit of `/etc/profile` itself (which package updates will overwrite):

```
$ sudo tee /etc/profile.d/99-editor.sh >/dev/null <<'EOF'
# Standard editor for interactive login shells (LPIC-1 103.8).
# Set both: VISUAL for full-screen-capable tools, EDITOR as the fallback.
export VISUAL=vim
export EDITOR=vim
EOF
$ sudo chmod 0644 /etc/profile.d/99-editor.sh
```

> `/etc/profile.d/*.sh` is sourced only by **login** shells. It does not affect `cron` jobs, `systemd` services, or non-login SSH command execution (`ssh host 'crontab -e'`). For those, set the variable in the unit (`Environment=`) or in the crontab itself (`EDITOR=/usr/bin/vim` as a crontab assignment line).

**Debian alternatives** — changes `/usr/bin/editor` for everyone, environment or not:

```
$ sudo update-alternatives --set editor /usr/bin/vim.basic
update-alternatives: using /usr/bin/vim.basic to provide /usr/bin/editor (editor) in manual mode

$ sudo update-alternatives --config editor
There are 4 choices for the alternative editor (providing /usr/bin/editor).

  Selection    Path                Priority   Status
------------------------------------------------------------
  0            /usr/bin/vim.basic   30        auto mode
  1            /bin/ed             -100       manual mode
  2            /bin/nano            40        manual mode
* 3            /usr/bin/vim.basic   30        manual mode
  4            /usr/bin/vim.tiny    15        manual mode

Press <enter> to keep the current choice[*], or type selection number:
```

**Red Hat family** — the `alternatives` command is the same tool; but note that on RHEL, `/usr/bin/vi` is a real file from `vim-minimal` and is not an alternative. Set `VISUAL`/`EDITOR` instead.

### 6.4 The mediated editors — locking and validation

These wrappers are the *reason* the `$EDITOR` indirection exists. Never bypass them.

| Wrapper | Protects | Locking | Validation on save |
|---|---|---|---|
| `visudo` | `/etc/sudoers`, `/etc/sudoers.d/*` | `.tmp` lock file; refuses concurrent edits | full parse; refuses to install a broken file |
| `visudo -c` | — | — | validate without editing (use this in CI) |
| `visudo -f /etc/sudoers.d/90-ops` | a drop-in | yes | yes |
| `vipw` / `vipw -s` | `/etc/passwd` / `/etc/shadow` | `/etc/passwd.lock` | consistency prompt |
| `vigr` / `vigr -s` | `/etc/group` / `/etc/gshadow` | `/etc/group.lock` | consistency prompt |
| `crontab -e` | `/var/spool/cron/crontabs/$USER` | yes | field syntax; refuses to install |
| `systemctl edit UNIT` | `/etc/systemd/system/UNIT.d/override.conf` | temp file | runs `daemon-reload` after a successful edit |
| `kubectl edit` | a live API object | optimistic concurrency (`resourceVersion`) | schema + admission webhooks server-side |
| `sudoedit file` | **any root-owned file** | temp copy | none — but the editor never runs as root |

**Why `sudoedit` and not `sudo vi`:** `sudo vi /etc/hosts` runs the *entire editor* as root. From inside it, `:!bash`, `:sh`, or `:r !cmd` give an interactive root shell — which defeats a `sudoers` rule that was meant to grant only file editing. `sudoedit` copies the file to a temp location, runs the editor **as the invoking user**, and copies it back as root. In `sudoers`, grant `sudoedit`, never `vi`:

```
# /etc/sudoers.d/90-ops  — installed with: visudo -f /etc/sudoers.d/90-ops
# WRONG: gives a full root shell via :!bash
# %ops ALL=(root) NOPASSWD: /usr/bin/vi /etc/haproxy/haproxy.cfg
#
# RIGHT: the editor runs unprivileged; only the file copy-back is privileged.
%ops ALL=(root) NOPASSWD: sudoedit /etc/haproxy/haproxy.cfg
Defaults!sudoedit  env_keep += "SUDO_EDITOR"
```

```
$ sudo -l | tail -n 2
User alice may run the following commands on node-01:
    (root) NOPASSWD: sudoedit /etc/haproxy/haproxy.cfg

$ sudoedit /etc/haproxy/haproxy.cfg
sudoedit: /etc/haproxy/haproxy.cfg unchanged
```

---

## 7. Infrastructure: complete, deployable manifests

### 7.1 Hardened system `vimrc`

Path: `/etc/vim/vimrc.local` (Debian/Ubuntu) or `/etc/vimrc` (RHEL/SUSE). Complete file, no elisions.

```vim
" ============================================================================
"  /etc/vim/vimrc.local  -- system-wide vim policy for production nodes
"  Managed by configuration management. Local edits will be reverted.
"
"  Design goals, in priority order:
"    1. Never silently corrupt a config file (indentation, line endings, EOL).
"    2. Never leak secrets to disk outside the file being edited.
"    3. Never break bind mounts, hardlinks or inode-based watchers.
"    4. Only then: ergonomics.
" ============================================================================

set nocompatible                " enable vim behaviour even when invoked as 'vi'

" ---------------------------------------------------------------------------
" 1. SAFE WRITES
" ---------------------------------------------------------------------------
" Preserve the inode on write. Required on any host that bind-mounts config
" files into containers, uses hardlinked config trees, or relies on inotify
" IN_MODIFY watchers. Costs atomicity; gains correctness. See :help backupcopy
set backupcopy=yes

set nobackup                    " no 'file~' litter in /etc
set nowritebackup               " do not create a temporary backup on write
set fileformats=unix,dos        " detect CRLF, but never CREATE it
set nofixendofline              " do not silently add a trailing newline to a
                                " file that legitimately lacks one (some
                                " binary-adjacent and checksummed files care)

" ---------------------------------------------------------------------------
" 2. SECRET HYGIENE
" ---------------------------------------------------------------------------
" Keep swap, undo and viminfo state out of the directory being edited, so that
" opening /etc/shadow does not create /etc/.shadow.swp.
set directory=/var/tmp/vim-swap//   " '//' = encode the full path in the name
set undodir=/var/tmp/vim-undo//
set viminfofile=NONE               " no ~/.viminfo at all on servers

" Belt and braces: no swap, no undo file, no viminfo for known-sensitive paths.
augroup secret_files
  autocmd!
  autocmd BufNewFile,BufReadPre
        \ /etc/shadow,/etc/gshadow,/etc/sudoers,/etc/sudoers.d/*,
        \*/secrets/*,*.key,*.pem,*id_rsa*,*id_ed25519*,*.kubeconfig,
        \*/.aws/credentials,*/.docker/config.json
        \ setlocal noswapfile noundofile nobackup nowritebackup viminfo=
augroup END

" ---------------------------------------------------------------------------
" 3. FILETYPE-CORRECT INDENTATION
" ---------------------------------------------------------------------------
syntax on
filetype plugin indent on

set expandtab                   " spaces, not tabs, by default
set tabstop=8                   " a literal TAB still renders as 8 columns
set softtabstop=2
set shiftwidth=2
set autoindent
set nosmartindent               " smartindent mangles YAML comments; off.

augroup filetype_indent
  autocmd!
  " YAML and JSON: 2 spaces, tabs are a syntax error in YAML.
  autocmd FileType yaml,yml,json,helm
        \ setlocal expandtab shiftwidth=2 softtabstop=2 indentkeys-=0# indentkeys-=<:>
  " Makefiles and crontabs REQUIRE literal tabs. Never expand them.
  autocmd FileType make,crontab setlocal noexpandtab shiftwidth=8 softtabstop=0
  autocmd BufRead,BufNewFile /tmp/crontab.* setlocal filetype=crontab noexpandtab
  " Go uses tabs.
  autocmd FileType go setlocal noexpandtab shiftwidth=8
  " Shell.
  autocmd FileType sh,bash setlocal expandtab shiftwidth=2 softtabstop=2
augroup END

" ---------------------------------------------------------------------------
" 4. MAKE INVISIBLE DAMAGE VISIBLE
" ---------------------------------------------------------------------------
set list
set listchars=tab:»·,trail:·,nbsp:␣,extends:›,precedes:‹
" Highlight trailing whitespace and hard tabs in YAML in red.
highlight default link ExtraWhitespace Error
augroup show_bad_whitespace
  autocmd!
  autocmd BufWinEnter * match ExtraWhitespace /\s\+$/
  autocmd FileType yaml,yml match ExtraWhitespace /\t\|\s\+$/
augroup END

set number
set ruler
set showcmd                     " show the pending operator/count in the corner
set laststatus=2
set statusline=%f\ %m%r%h%w\ [%{&ff}]\ [%Y]\ %=L%l/%L\ C%c\ %p%%

" ---------------------------------------------------------------------------
" 5. SEARCH
" ---------------------------------------------------------------------------
set incsearch
set hlsearch
set ignorecase
set smartcase                   " case-sensitive as soon as you type a capital

" ---------------------------------------------------------------------------
" 6. PASTE SAFETY
" ---------------------------------------------------------------------------
" Bracketed paste (vim >= 8.0 with a capable terminal) prevents autoindent
" from cascading a pasted YAML block into a staircase. F2 is the manual escape
" hatch for terminals that do not support it.
set pastetoggle=<F2>

" ---------------------------------------------------------------------------
" 7. MISC
" ---------------------------------------------------------------------------
set history=1000
set backspace=indent,eol,start
set mouse=                      " mouse OFF: it hijacks terminal text selection
set modeline                    " honour modelines...
set modelines=1                 " ...but only one, and see 'modelineexpr' off
set nomodelineexpr              " never evaluate expressions from a file
set encoding=utf-8
set scrolloff=3
set wildmenu
set wildmode=longest:full,full

" Write a root-owned file opened without privileges: :W
command! W execute 'w !sudo tee % > /dev/null' <bar> edit!
```

Create the state directories the file references — vim will fall back to the current directory (defeating the point) if they do not exist:

```
$ sudo install -d -m 1777 /var/tmp/vim-swap /var/tmp/vim-undo
$ ls -ld /var/tmp/vim-swap
drwxrwxrwt. 2 root root 4096 Aug 26 09:41 /var/tmp/vim-swap
```

### 7.2 `nanorc`

Path: `/etc/nanorc` (system) or `~/.nanorc` (user). Complete file.

```
## /etc/nanorc -- system-wide nano policy for production nodes
## Managed by configuration management.

## --- Never corrupt a config file ------------------------------------------
unset breaklonglines      # do NOT hard-wrap long lines (the classic corruptor)
set nonewlines            # do not add a missing final newline
set tabstospaces          # spaces by default...
set tabsize 2

## --- Visibility -----------------------------------------------------------
set linenumbers
set constantshow          # always show the cursor position
set indicator             # scrollbar-like position indicator
set whitespace "»·"       # render tabs and trailing spaces
set titlecolor bold,white,blue
set statuscolor bold,white,green
set errorcolor bold,white,red

## --- Behaviour ------------------------------------------------------------
set autoindent
set smarthome             # Home toggles between column 0 and first non-blank
set zap                   # a keystroke replaces the marked region
set positionlog           # reopen files at the last cursor position
set backupdir /var/tmp/nano-backup
set historylog

## --- Do not leak state for sensitive files --------------------------------
## nano has no per-file exclusion; edit secrets with:  nano -I -P /etc/shadow
##   -I : ignore nanorc,  -P : no position log

## --- Syntax highlighting --------------------------------------------------
include "/usr/share/nano/*.nanorc"
include "/usr/share/nano/extra/*.nanorc"
```

### 7.3 Ansible playbook — full, with validation

```yaml
---
# editors.yml — establish the standard editor and its policy on every node.
#
#   ansible-playbook -i inventory/prod editors.yml --check --diff
#   ansible-playbook -i inventory/prod editors.yml
#
# This playbook is the counterpart to the rule in section 1.3: the editor
# configuration itself is delivered declaratively, never hand-edited.
- name: Standard editor policy
  hosts: all
  become: true
  gather_facts: true

  vars:
    editor_binary: /usr/bin/vim
    vim_state_dirs:
      - /var/tmp/vim-swap
      - /var/tmp/vim-undo
    vimrc_path: >-
      {{ '/etc/vim/vimrc.local'
         if ansible_facts['os_family'] == 'Debian'
         else '/etc/vimrc' }}

  tasks:
    - name: Install the editor and its runtime
      ansible.builtin.package:
        name: "{{ editor_packages }}"
        state: present
      vars:
        editor_packages: >-
          {{ ['vim', 'nano']
             if ansible_facts['os_family'] == 'Debian'
             else ['vim-enhanced', 'nano'] }}

    - name: Create vim state directories outside the edited tree
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: root
        group: root
        mode: '1777'
      loop: "{{ vim_state_dirs }}"

    - name: Deploy the hardened system vimrc
      ansible.builtin.copy:
        src: files/vimrc.local
        dest: "{{ vimrc_path }}"
        owner: root
        group: root
        mode: '0644'
        backup: true
        # 'validate' runs BEFORE the file is moved into place. If vim cannot
        # source the candidate file, the task fails and the old file survives.
        validate: 'vim -u NONE -N -e -s -c "source %" -c "qa!"'

    - name: Deploy the hardened system nanorc
      ansible.builtin.copy:
        src: files/nanorc
        dest: /etc/nanorc
        owner: root
        group: root
        mode: '0644'
        backup: true

    - name: Export VISUAL and EDITOR for login shells
      ansible.builtin.copy:
        dest: /etc/profile.d/99-editor.sh
        owner: root
        group: root
        mode: '0644'
        content: |
          # Managed by Ansible (editors.yml). Do not edit by hand.
          export VISUAL={{ editor_binary }}
          export EDITOR={{ editor_binary }}

    - name: Point the Debian alternatives 'editor' link at vim
      community.general.alternatives:
        name: editor
        path: /usr/bin/vim.basic
      when: ansible_facts['os_family'] == 'Debian'

    - name: Force sudoedit/visudo to use vim, and forbid env_editor
      ansible.builtin.copy:
        dest: /etc/sudoers.d/10-editor
        owner: root
        group: root
        mode: '0440'
        content: |
          # Managed by Ansible (editors.yml). Do not edit by hand.
          # env_editor=off means visudo IGNORES $EDITOR from the environment,
          # so a user cannot make visudo run an arbitrary program as root.
          Defaults        editor = /usr/bin/vim
          Defaults        !env_editor
        # Never install a sudoers file without parsing it first. A broken
        # sudoers file locks every administrator out of the host.
        validate: 'visudo -cf %s'

    - name: Verify the environment actually resolves as intended
      ansible.builtin.shell:
        cmd: |
          set -euo pipefail
          . /etc/profile.d/99-editor.sh
          test "$EDITOR" = "{{ editor_binary }}"
          test "$VISUAL" = "{{ editor_binary }}"
          command -v "$EDITOR" >/dev/null
      changed_when: false
      args:
        executable: /bin/bash

    - name: Verify sudoers is parseable after our drop-in
      ansible.builtin.command:
        cmd: visudo -c
      changed_when: false
      register: sudoers_check

    - name: Show sudoers verification result
      ansible.builtin.debug:
        var: sudoers_check.stdout_lines
```

Run and expected output:

```
$ ansible-playbook -i inventory/prod editors.yml

PLAY [Standard editor policy] **************************************************

TASK [Gathering Facts] *********************************************************
ok: [node-01.internal]
ok: [node-02.internal]

TASK [Install the editor and its runtime] **************************************
ok: [node-01.internal]
changed: [node-02.internal]

TASK [Create vim state directories outside the edited tree] ********************
changed: [node-01.internal] => (item=/var/tmp/vim-swap)
changed: [node-01.internal] => (item=/var/tmp/vim-undo)
changed: [node-02.internal] => (item=/var/tmp/vim-swap)
changed: [node-02.internal] => (item=/var/tmp/vim-undo)

TASK [Deploy the hardened system vimrc] ****************************************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Deploy the hardened system nanorc] ***************************************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Export VISUAL and EDITOR for login shells] *******************************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Point the Debian alternatives 'editor' link at vim] **********************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Force sudoedit/visudo to use vim, and forbid env_editor] *****************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Verify the environment actually resolves as intended] ********************
ok: [node-01.internal]
ok: [node-02.internal]

TASK [Verify sudoers is parseable after our drop-in] ***************************
ok: [node-01.internal]
ok: [node-02.internal]

TASK [Show sudoers verification result] ****************************************
ok: [node-01.internal] => {
    "sudoers_check.stdout_lines": [
        "/etc/sudoers: parsed OK",
        "/etc/sudoers.d/10-editor: parsed OK",
        "/etc/sudoers.d/90-ops: parsed OK"
    ]
}

PLAY RECAP *********************************************************************
node-01.internal : ok=11   changed=6    unreachable=0    failed=0    skipped=0
node-02.internal : ok=11   changed=7    unreachable=0    failed=0    skipped=0
```

### 7.4 cloud-init — bake the policy into first boot

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Establishes the standard editor before any human can log in and drift.

package_update: true
packages:
  - vim
  - nano

write_files:
  - path: /etc/profile.d/99-editor.sh
    owner: root:root
    permissions: '0644'
    content: |
      # Managed by cloud-init. Do not edit by hand.
      export VISUAL=/usr/bin/vim
      export EDITOR=/usr/bin/vim

  - path: /etc/vim/vimrc.local
    owner: root:root
    permissions: '0644'
    content: |
      set nocompatible
      set backupcopy=yes
      set nobackup
      set nowritebackup
      set directory=/var/tmp/vim-swap//
      set undodir=/var/tmp/vim-undo//
      set viminfofile=NONE
      syntax on
      filetype plugin indent on
      set expandtab tabstop=8 softtabstop=2 shiftwidth=2 autoindent
      autocmd FileType make,crontab setlocal noexpandtab shiftwidth=8 softtabstop=0
      autocmd FileType yaml,yml setlocal expandtab shiftwidth=2 softtabstop=2
      set list listchars=tab:»·,trail:·,nbsp:␣
      set number ruler showcmd laststatus=2
      set incsearch hlsearch ignorecase smartcase
      set mouse=
      set pastetoggle=<F2>

  - path: /etc/sudoers.d/10-editor
    owner: root:root
    permissions: '0440'
    content: |
      Defaults        editor = /usr/bin/vim
      Defaults        !env_editor

runcmd:
  - [install, -d, -m, '1777', /var/tmp/vim-swap, /var/tmp/vim-undo]
  - [sh, -c, 'command -v update-alternatives >/dev/null && update-alternatives --set editor /usr/bin/vim.basic || true']
  # Fail the boot loudly rather than ship a host with a broken sudoers file.
  - [visudo, -c]
```

### 7.5 Kubernetes: an editor in a cluster that has none

Production images should contain no editor. When you must edit inside a running Pod, attach a debug container instead of installing tooling into the workload image.

```yaml
---
# 01-vimrc-configmap.yaml
# The editor policy, shipped as a ConfigMap so the debug toolbox is
# identical to the one on the nodes.
apiVersion: v1
kind: ConfigMap
metadata:
  name: toolbox-vimrc
  namespace: platform-debug
  labels:
    app.kubernetes.io/name: toolbox
    app.kubernetes.io/component: editor-policy
data:
  vimrc: |
    set nocompatible
    " Inside a container, config files are frequently bind-mounted from a
    " volume by inode. Preserving the inode is not optional here.
    set backupcopy=yes
    set nobackup nowritebackup
    set directory=/tmp//
    set undodir=/tmp//
    set viminfofile=NONE
    syntax on
    filetype plugin indent on
    set expandtab tabstop=8 softtabstop=2 shiftwidth=2 autoindent
    autocmd FileType yaml,yml setlocal expandtab shiftwidth=2 softtabstop=2
    autocmd FileType make,crontab setlocal noexpandtab shiftwidth=8 softtabstop=0
    set list listchars=tab:»·,trail:·,nbsp:␣
    set number ruler showcmd laststatus=2
    set incsearch hlsearch ignorecase smartcase
    set mouse=
    set pastetoggle=<F2>
---
# 02-toolbox-pod.yaml
# A long-lived debug Pod. Note the deliberate constraints: it is not
# privileged, it has no service account token, and it cannot schedule
# onto a node it was not sent to.
apiVersion: v1
kind: Pod
metadata:
  name: toolbox
  namespace: platform-debug
  labels:
    app.kubernetes.io/name: toolbox
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: toolbox
      image: debian:12-slim
      command: ["/bin/sleep", "infinity"]
      env:
        - name: EDITOR
          value: /usr/bin/vim
        - name: VISUAL
          value: /usr/bin/vim
        - name: KUBE_EDITOR
          value: /usr/bin/vim
        # Without a TERM the editor cannot start. See section 9.1.
        - name: TERM
          value: xterm-256color
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
        - name: vimrc
          mountPath: /etc/vim/vimrc.local
          subPath: vimrc
          readOnly: true
        - name: tmp
          mountPath: /tmp
        - name: work
          mountPath: /work
  volumes:
    - name: vimrc
      configMap:
        name: toolbox-vimrc
        items:
          - key: vimrc
            path: vimrc
    # A writable /tmp is mandatory: with readOnlyRootFilesystem the editor
    # has nowhere to place its swap file and will refuse to open a buffer.
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
    - name: work
      emptyDir:
        sizeLimit: 256Mi
---
# 03-netpol.yaml
# The toolbox can reach the API server and DNS. Nothing else, and nothing
# reaches it. A debug Pod is a lateral-movement asset if left unconstrained.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: toolbox-egress-only
  namespace: platform-debug
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: toolbox
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.96.0.1/32     # kubernetes.default.svc ClusterIP
      ports:
        - protocol: TCP
          port: 443
```

> **The `subPath` trap, which is exactly the inode problem of §1.2 in Kubernetes form:** a `configMap` volume mounted with `subPath` is bind-mounted **by inode**. When the ConfigMap is updated, the kubelet atomically swaps the projected directory's symlink — and the `subPath` mount keeps pointing at the old inode. The file inside the container **never** updates. Mount the whole directory (no `subPath`) if you need live updates, or roll the Pod. This is the same failure as editing a bind-mounted file with `backupcopy=no`.

Building the toolbox image, if you prefer a purpose-built one:

```dockerfile
# Dockerfile — platform debug toolbox.
# Deliberately NOT based on the application image: the application image
# must never contain an editor, a shell debugger or a packet capture tool.
FROM debian:12-slim

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        vim-nox \
        nano \
        ed \
        less \
        ncurses-base \
        ncurses-term \
        ca-certificates \
        procps \
        iproute2 \
        dnsutils \
        curl \
        jq \
        yamllint; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ncurses-term supplies the terminfo entries. Without it, TERM=xterm-256color
# makes vim abort with E558 inside the container. See section 9.1.
ENV TERM=xterm-256color \
    EDITOR=/usr/bin/vim \
    VISUAL=/usr/bin/vim \
    KUBE_EDITOR=/usr/bin/vim \
    LANG=C.UTF-8

COPY vimrc.local /etc/vim/vimrc.local

RUN install -d -m 1777 /var/tmp/vim-swap /var/tmp/vim-undo \
 && useradd --uid 65532 --create-home --shell /bin/bash toolbox

USER 65532:65532
WORKDIR /work
ENTRYPOINT ["/bin/sleep"]
CMD ["infinity"]
```

Deploy and use:

```
$ kubectl apply -f 01-vimrc-configmap.yaml -f 02-toolbox-pod.yaml -f 03-netpol.yaml
configmap/toolbox-vimrc created
pod/toolbox created
networkpolicy.networking.k8s.io/toolbox-egress-only created

$ kubectl -n platform-debug wait --for=condition=Ready pod/toolbox --timeout=60s
pod/toolbox condition met

$ kubectl -n platform-debug exec -it toolbox -- bash
toolbox@toolbox:/work$ echo "$TERM $EDITOR"
xterm-256color /usr/bin/vim
toolbox@toolbox:/work$ vim -c 'set backupcopy?' -c 'q'
  backupcopy=yes
```

For a Pod that is *already* running and has no editor, attach one without restarting it:

```
$ kubectl -n prod debug -it web-6f8d9c7b4-x2klm \
      --image=debian:12-slim \
      --target=web \
      --profile=general \
      -- bash
Targeting container "web". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-7wq4p.
If you don't see a command prompt, try pressing enter.
root@web-6f8d9c7b4-x2klm:/# ls /proc/1/root/etc/nginx/
conf.d  nginx.conf  mime.types
```

`--target` puts the debug container in the target's PID namespace, so `/proc/1/root/` is the application container's filesystem — you can read and, if it is writable, edit its files with an editor that was never in its image.

### 7.6 systemd: the correct way to change a unit

Never edit a vendor unit file under `/usr/lib/systemd/system/` — the next package update overwrites it, and your change vanishes at the worst possible moment.

```
$ sudo SYSTEMD_EDITOR=vim systemctl edit nginx.service
```

`systemctl` opens an empty override, and on save writes it and reloads:

```
$ sudo systemctl cat nginx.service | head -n 30
# /usr/lib/systemd/system/nginx.service
[Unit]
Description=A high performance web server and a reverse proxy server
After=network.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /run/nginx.pid
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target

# /etc/systemd/system/nginx.service.d/override.conf
[Service]
LimitNOFILE=65535
Restart=on-failure
RestartSec=5s
```

The complete override file that `systemctl edit` produced:

```ini
# /etc/systemd/system/nginx.service.d/override.conf
# Managed by configuration management; created via `systemctl edit nginx.service`.
[Service]
# The vendor unit does not raise the descriptor limit; at 20k concurrent
# connections nginx logs "worker_connections are not enough".
LimitNOFILE=65535
Restart=on-failure
RestartSec=5s
```

Verify without guessing:

```
$ systemd-analyze verify nginx.service && echo "unit OK"
unit OK

$ systemctl show nginx.service -p LimitNOFILE
LimitNOFILE=65535
```

### 7.7 CI: validate every hand-edited file before it reaches a node

```makefile
# Makefile — run in CI on every change to the config repository.
# The editor is allowed to produce anything; the pipeline is what decides
# whether it reaches a node.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := verify

YAML_FILES  := $(shell git ls-files '*.yml' '*.yaml')
SUDO_FILES  := $(shell git ls-files 'sudoers.d/*')
NGINX_FILES := $(shell git ls-files 'nginx/*.conf')
UNIT_FILES  := $(shell git ls-files 'systemd/*.service' 'systemd/*.timer')

.PHONY: verify
verify: whitespace lineendings yaml sudoers nginx sshd units
	@echo "ALL CHECKS PASSED"

.PHONY: whitespace
whitespace:
	@echo "==> hard tabs and trailing whitespace in YAML"
	@! grep -nP '\t' $(YAML_FILES) || { echo "FAIL: literal tab in YAML"; exit 1; }
	@! grep -nP ' +$$' $(YAML_FILES) || { echo "FAIL: trailing whitespace"; exit 1; }

.PHONY: lineendings
lineendings:
	@echo "==> CRLF line endings"
	@! grep -rlP '\r$$' $(YAML_FILES) $(NGINX_FILES) $(UNIT_FILES) \
		|| { echo "FAIL: CRLF found — run: sed -i 's/\r$$//' <file>"; exit 1; }

.PHONY: yaml
yaml:
	@echo "==> yamllint"
	@yamllint -s $(YAML_FILES)

.PHONY: sudoers
sudoers:
	@echo "==> visudo -c on every sudoers drop-in"
	@for f in $(SUDO_FILES); do \
		echo "    $$f"; \
		visudo -cqf "$$f" || exit 1; \
	done

.PHONY: nginx
nginx:
	@echo "==> nginx -t"
	@nginx -t -c $(CURDIR)/nginx/nginx.conf -p $(CURDIR)/nginx

.PHONY: sshd
sshd:
	@echo "==> sshd -t"
	@sshd -t -f $(CURDIR)/ssh/sshd_config

.PHONY: units
units:
	@echo "==> systemd-analyze verify"
	@systemd-analyze verify $(UNIT_FILES)
```

```
$ make verify
==> hard tabs and trailing whitespace in YAML
==> CRLF line endings
==> yamllint
==> visudo -c on every sudoers drop-in
    sudoers.d/10-editor
    sudoers.d/90-ops
==> nginx -t
nginx: the configuration file /srv/cfg/nginx/nginx.conf syntax is ok
nginx: configuration file /srv/cfg/nginx/nginx.conf test is successful
==> sshd -t
==> systemd-analyze verify
ALL CHECKS PASSED
```

---

## 8. Terminal walkthroughs

### 8.1 The first ninety seconds in `vi`

```
$ vi /srv/cfg/app/settings.conf
```

```
~
~
~
~
"/srv/cfg/app/settings.conf" [New] 0 lines, 0 characters
```

The `~` characters mark lines that do not exist. `[New]` means nothing has been written to disk yet. Now the exam's key sequence, annotated:

| You press | Mode after | What happens |
|---|---|---|
| `i` | INSERT | `-- INSERT --` appears on the last line |
| `listen_port = 8080⏎timeout = 30s` | INSERT | two lines enter the buffer |
| `Esc` | COMMAND | `-- INSERT --` disappears; cursor moves left one column |
| `gg` | COMMAND | cursor to line 1 |
| `yy` | COMMAND | line 1 copied into the unnamed register |
| `p` | COMMAND | the copy is put **below** the current line |
| `dd` | COMMAND | that duplicate is deleted again |
| `/timeout⏎` | COMMAND | cursor jumps to the `timeout` line |
| `cw` | INSERT | the word `timeout` is deleted, insert mode entered |
| `read_timeout` `Esc` | COMMAND | the word is replaced |
| `o` | INSERT | a new line **opens below**, insert mode entered |
| `max_conns = 512` `Esc` | COMMAND | third line added |
| `:w` | COMMAND | written to disk |
| `ZZ` | — | written (already clean) and exited |

```
$ cat /srv/cfg/app/settings.conf
listen_port = 8080
read_timeout = 30s
max_conns = 512
```

### 8.2 Editing `sshd_config` without locking yourself out

The single most consequential hand-edit on a Linux host. The procedure below is the one that does not end in a support ticket.

```
$ ssh alice@node-01.internal

# 1. Keep the current session open. Never close it until the new one works.

$ sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.$(date +%F-%H%M)
$ ls -l /etc/ssh/sshd_config*
-rw-r--r--. 1 root root 3908 Jul 14 11:02 /etc/ssh/sshd_config
-rw-r--r--. 1 root root 3908 Jul 14 11:02 /etc/ssh/sshd_config.2026-08-26-0947

# 2. Edit through sudoedit so the editor itself never runs as root.
$ sudoedit /etc/ssh/sshd_config
```

Inside the editor:

```
/PermitRootLogin⏎          jump to the directive
0                          go to column 0
:s/yes/no/⏎                substitute on this line only
1 substitution on 1 line
/PasswordAuthentication⏎
:s/yes/no/⏎
1 substitution on 1 line
Go⏎                        append a new line at the end of the file
ClientAliveInterval 60
ClientAliveCountMax 3
Esc
ZZ
```

```
sudoedit: /etc/ssh/sshd_config unchanged     <-- would appear only if nothing changed

# 3. Validate the syntax BEFORE restarting anything.
$ sudo sshd -t && echo "sshd config OK"
sshd config OK

# A broken file looks like this instead:
$ sudo sshd -t
/etc/ssh/sshd_config line 34: Unsupported option "PermitRootLogn"

# 4. Diff against the backup so you know exactly what changed.
$ sudo diff -u /etc/ssh/sshd_config.2026-08-26-0947 /etc/ssh/sshd_config
--- /etc/ssh/sshd_config.2026-08-26-0947	2026-07-14 11:02:41.000000000 +0000
+++ /etc/ssh/sshd_config	2026-08-26 09:52:18.412773901 +0000
@@ -31,10 +31,10 @@
 #LoginGraceTime 2m
-PermitRootLogin yes
+PermitRootLogin no
 #StrictModes yes
@@ -57,7 +57,7 @@
-PasswordAuthentication yes
+PasswordAuthentication no
@@ -119,3 +119,5 @@
 # override default of no subsystems
 Subsystem	sftp	/usr/lib/openssh/sftp-server
+
+ClientAliveInterval 60
+ClientAliveCountMax 3

# 5. Reload (not restart) — reload does not drop existing connections.
$ sudo systemctl reload sshd
$ systemctl is-active sshd
active

# 6. From ANOTHER terminal, prove a new login works.
$ ssh -o BatchMode=no alice@node-01.internal 'echo NEW SESSION OK'
NEW SESSION OK

# 7. Only now close the original session.
```

If step 6 fails, you still hold the session from step 1 and can `sudo cp -a` the backup back. That ordering — validate, diff, reload, prove, *then* release the lifeline — is the whole discipline.

### 8.3 `kubectl edit` round trip, including the failure path

```
$ export KUBE_EDITOR=vim
$ kubectl -n prod edit deployment/web
```

The editor opens with the live object plus a header:

```yaml
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "7"
  creationTimestamp: "2026-06-02T08:14:51Z"
  generation: 7
  name: web
  namespace: prod
  resourceVersion: "48192376"
  uid: 3f2a1c88-9b41-4f0e-9e0e-2b0e5c6a7d19
spec:
  replicas: 3
  ...
```

Change `replicas: 3` to `replicas: 5` (`/replicas⏎`, `f3`, `r5`, `ZZ`) and:

```
deployment.apps/web edited
```

Now the failure path — introduce a YAML indentation error (which is what happens when you paste into an editor with `autoindent` on and no bracketed paste):

```
$ kubectl -n prod edit deployment/web
error: unable to parse "/tmp/kubectl-edit-3142817649.yaml": error converting YAML to JSON: yaml: line 41: did not find expected key
Edit cancelled, no valid changes were saved.
```

And a semantically valid but API-invalid change:

```
$ kubectl -n prod edit deployment/web
The Deployment "web" is invalid: spec.template.spec.containers[0].resources.limits[memory]: Invalid value: "512": must be a quantity with a valid suffix
error: the server rejected our request due to an error in our request
A copy of your changes has been stored to "/tmp/kubectl-edit-2270441853.yaml"
error: Edit cancelled, no valid changes were saved.

$ vim /tmp/kubectl-edit-2270441853.yaml      # fix it, then:
$ kubectl -n prod apply -f /tmp/kubectl-edit-2270441853.yaml
deployment.apps/web configured
```

Note that `kubectl edit` uses optimistic concurrency: if the object changed on the server while your editor was open, the write is rejected with a `resourceVersion` conflict and your work is preserved in `/tmp`. The editor's slowness is therefore a *feature* of the safety model, not a flaw.

```
$ kubectl -n prod edit deployment/web
Error from server (Conflict): Operation cannot be fulfilled on deployments.apps "web": the object has been modified; please apply your changes to the latest version and try again
```

### 8.4 Recovering a crashed edit

Your SSH session dies mid-edit. The next person to open the file sees:

```
$ sudo vim /etc/haproxy/haproxy.cfg

E325: ATTENTION
Found a swap file by the name "/etc/haproxy/.haproxy.cfg.swp"
          owned by: root   dated: Tue Aug 26 09:31:04 2026
         file name: /etc/haproxy/haproxy.cfg
          modified: YES
         user name: root   host name: node-01
        process ID: 4711
While opening file "/etc/haproxy/haproxy.cfg"
             dated: Tue Aug 26 08:12:55 2026

(1) Another program may be editing the same file.  If this is the case,
    be careful not to end up with two different instances of the same
    file when making changes.  Quit, or continue with caution.
(2) An edit session for this file crashed.
    If this is the case, use ":recover" or "vim -r /etc/haproxy/haproxy.cfg"
    to recover the changes (see ":help recovery").
    If you did this already, delete the swap file "/etc/haproxy/.haproxy.cfg.swp"
    to avoid this message.

Swap file "/etc/haproxy/.haproxy.cfg.swp" already exists!
[O]pen Read-Only, (E)dit anyway, (R)ecover, (D)elete it, (Q)uit, (A)bort:
```

**Read the "process ID" line first.** If it says `(STILL RUNNING)`, a colleague is editing right now — press `O` (read-only) or `A` and go talk to them. If it does not, the session crashed and `R` is correct.

The safe recovery procedure never writes over the original:

```
$ sudo vim -r /etc/haproxy/haproxy.cfg
Using swap file "/etc/haproxy/.haproxy.cfg.swp"
Original file "/etc/haproxy/haproxy.cfg"
Recovery completed. Buffer contents equals file contents.
You may want to delete the .swp file now.

Press ENTER or type command to continue
```

Inside the recovered buffer, write to a *new* name and diff:

```
:w /tmp/haproxy.cfg.recovered
"/tmp/haproxy.cfg.recovered" [New] 214L, 6883C written
:q!
```

```
$ sudo diff -u /etc/haproxy/haproxy.cfg /tmp/haproxy.cfg.recovered
--- /etc/haproxy/haproxy.cfg	2026-08-26 08:12:55.000000000 +0000
+++ /tmp/haproxy.cfg.recovered	2026-08-26 09:58:33.102918440 +0000
@@ -188,6 +188,7 @@
 backend be_api
     balance roundrobin
     option httpchk GET /healthz
+    timeout server 45s
     server api-1 10.20.1.11:8080 check inter 2s fall 3 rise 2
     server api-2 10.20.1.12:8080 check inter 2s fall 3 rise 2

$ sudo haproxy -c -f /tmp/haproxy.cfg.recovered
Configuration file is valid

$ sudo cp -a /tmp/haproxy.cfg.recovered /etc/haproxy/haproxy.cfg
$ sudo rm -f /etc/haproxy/.haproxy.cfg.swp
$ sudo systemctl reload haproxy
```

List every orphaned swap file on a host — worth doing after any mass crash or OOM event, both to recover work and to find leaked secrets:

```
$ sudo vim -r
Swap files found:
   In current directory:
   -- none --
   In directory ~/tmp:
   -- none --
   In directory /var/tmp:
   -- none --
   In directory /tmp:
1.    /tmp/.settings.conf.swp
          owned by: alice   dated: Tue Aug 26 09:31:04 2026
         file name: /srv/cfg/app/settings.conf
          modified: YES
         user name: alice   host name: node-01
        process ID: 5210
```

```
$ sudo find /etc /srv /root /home -name '.*.sw[a-p]' -printf '%TY-%Tm-%Td %u %p\n' 2>/dev/null
2026-08-26 root /etc/haproxy/.haproxy.cfg.swp
2026-08-24 root /etc/.shadow.swp          <-- a leak; investigate and shred
```

### 8.5 "I opened it without sudo and now `:w` fails"

```
$ vim /etc/hosts
```

```
:w
E45: 'readonly' option is set (add ! to override)

:w!
"/etc/hosts" E212: Can't open file for writing
```

`:w!` overrode vim's own `readonly` flag but could not override the *filesystem permissions*. Two correct exits:

```
" A. Write through sudo without leaving the editor (the :W command from §7.1):
:w !sudo tee % > /dev/null
[sudo] password for alice:
Press ENTER or type command to continue

W12: Warning: File "/etc/hosts" has changed and the buffer was changed in Vim as well
See ":help W12" for more info.
[O]K, (L)oad File:
```

Answer `L`: the file on disk is now correct, so reloading it discards nothing. Or use `:e!` afterwards. If you answer `O`, your buffer stays marked modified and a later `:w` could overwrite with stale content.

```
" B. Save elsewhere, quit, install with sudo — slower but unambiguous:
:w /tmp/hosts.new
:q!
```

```
$ sudo install -m 0644 -o root -g root /tmp/hosts.new /etc/hosts
$ getent hosts node-02.internal
10.20.0.12      node-02.internal node-02
```

Option B is the one to use on a file with an SELinux context, because `install` preserves nothing and `restorecon` then fixes the label deterministically:

```
$ ls -Z /etc/hosts
system_u:object_r:net_conf_t:s0 /etc/hosts
$ sudo restorecon -v /etc/hosts
```

### 8.6 The YAML paste disaster and its fix

Paste a nested YAML block into `vi` with `autoindent` on and no bracketed paste, and every line accumulates the indentation of the one before it:

```yaml
spec:
  containers:
    - name: web
        image: nginx:1.27
          ports:
            - containerPort: 80
              resources:
                  limits:
                        cpu: 500m
```

```
$ yamllint -s pod.yaml
pod.yaml
  4:9       error    syntax error: mapping values are not allowed here (syntax)
```

**Prevention:** `:set paste` before pasting, `:set nopaste` after (or `F2` with the `pastetoggle` from §7.1). Modern vim on a bracketed-paste-capable terminal handles this automatically; `vim.tiny`, `busybox vi` and `nvi` do not.

**Repair, without retyping**, using visual block mode to strip the excess indentation:

```
:set paste                 " stop the bleeding for the next paste
gg                         " to the top
V G                        " visual-select the whole file
=                          " reindent (only useful with a filetype indent plugin)

" Or, deterministically, filter the block through an external formatter:
:%!yq -P 'sort_keys(..)' -
```

```
$ yamllint -s pod.yaml && kubectl apply --dry-run=server -f pod.yaml
pod/web created (server dry run)
```

The lesson generalises: **`vi` can pipe a buffer or a range through any external command** (`:%!cmd`, `:1,20!sort`, `!}fmt`). That turns every formatter, linter and text tool on the box into a `vi` command.

---

## 9. Verification and failure diagnosis

### 9.1 Symptom → cause → command

| Symptom | Most likely cause | Diagnosis / fix |
|---|---|---|
| `E558: Terminal entry not found in terminfo` | `TERM` names a terminal with no terminfo entry — endemic in minimal containers | `echo $TERM`; `infocmp $TERM >/dev/null`; install `ncurses-term`, or `TERM=vt100 vi file` |
| `Error opening terminal: xterm-256color.` (nano) | same | same; `TERM=vt100 nano file` |
| Editor opens but arrow keys insert `A B C D` | terminfo mismatch, or you are in insert mode in POSIX `vi` (which has no arrow-key handling in insert mode) | use `hjkl` in command mode; fix `TERM` |
| The screen is frozen; keystrokes do nothing, nothing crashed | you pressed `Ctrl-s` — XOFF software flow control | press `Ctrl-q` to resume. Prevent: `stty -ixon` in `~/.bashrc` |
| Terminal is garbled after a crashed editor | the editor died without restoring the terminal modes | `reset`, or `stty sane` then `Ctrl-j` (the terminal may not be echoing `⏎`) |
| `E37: No write since last change (add ! to override)` | you tried `:q` with unsaved changes | `:w` to save, or `:q!` to discard |
| `E45: 'readonly' option is set (add ! to override)` | vim's own read-only flag (opened with `-R`/`view`, or the file is not writable by you) | `:w!` — this overrides the *flag*, not the permissions |
| `E212: Can't open file for writing` | you genuinely lack write permission on the file **or the directory** | §8.5. Check `ls -ld $(dirname file)` — a rename-style write needs **directory** write permission |
| `E514: write error (file system full?)` | disk or inodes exhausted; buffer is **not** lost | `df -h .` and `df -i .`; free space, then `:w` again. Do **not** quit. |
| Editor exits instantly with `E138: All .../.viminfo* files exist, cannot write viminfo file!` | stale `.viminfo.tmp` files, usually after a crash | `rm -f ~/.viminfo.tmp*`, or `set viminfofile=NONE` |
| `E325: ATTENTION ... swap file already exists` | crashed session, or a concurrent editor | §8.4. Read the `process ID` line before choosing |
| Saved the file, but the service still uses the old config | you did not reload the service | `systemctl reload <unit>`; confirm with `systemctl show <unit> -p ExecMainStartTimestamp` |
| Saved the file, reloaded, and the service *still* sees old content — inside a container | inode replaced by a rename-style write; the file bind mount is stale | `stat -c %i` on host and in container; `set backupcopy=yes`; recreate the container |
| Saved the file and `tail -f` shows nothing new | `tail -f` follows the old inode | use `tail -F` (`--follow=name --retry`) |
| Config-reload watcher never fires | `inotify` watch on the path, inode replaced | same as above; or increase `fs.inotify.max_user_watches` if the watcher hit the limit: `sysctl fs.inotify.max_user_watches` |
| File shows `^M` at every line end, or `[dos]` in the status line | CRLF line endings from a Windows editor or a copy-paste | `:set ff=unix` then `:w`; or `sed -i 's/\r$//' file`; verify with `file` |
| A shell script fails with `bad interpreter: /bin/bash^M` | the same CRLF problem in the shebang | `file script.sh`; `dos2unix script.sh` |
| Indentation broke after pasting | `autoindent` cascade | §8.6; `:set paste` |
| `Makefile:12: *** missing separator.  Stop.` | your editor expanded the required leading TAB into spaces | `cat -A Makefile \| sed -n 12p` — a real tab shows as `^I`; `:set noexpandtab` |
| `crontab: errors in crontab file, can't install.` | invalid cron field | see §9.2 |
| `visudo` reports a syntax error | invalid sudoers directive | see §9.2 — **always** choose `e` to re-edit, never `Q` |
| Colleague's edits vanished | you both edited the same file; last write wins | use the locking wrappers (`visudo`, `vipw`, `crontab -e`); put configs in git |
| `/etc/.shadow.swp` exists | someone opened `/etc/shadow` in vim | `shred -u` it; deploy the `vimrc` from §7.1; audit `~/.viminfo` too |

### 9.2 The mediated editors failing safely

`crontab -e` with a bad schedule:

```
$ crontab -e
crontab: installing new crontab
"/tmp/crontab.9KqLpM":3: bad minute
errors in crontab file, can't install.
Do you want to retry the same edit? (y/n) y
```

Answering `y` reopens the editor with your text intact. Answering `n` prints where your work was left:

```
Do you want to retry the same edit? (y/n) n
crontab: edits left in /tmp/crontab.9KqLpM
```

`visudo` with a syntax error — the prompt that must never be answered `Q`:

```
$ sudo visudo -f /etc/sudoers.d/90-ops
>>> /etc/sudoers.d/90-ops: syntax error near line 4 <<<
What now?
Options are:
  (e)dit sudoers file again
  (x) exit without saving changes to sudoers file
  (Q) quit and save changes to sudoers file (DANGER!)

What now? e
```

> `Q` writes a file that `sudo` cannot parse. On the next `sudo` invocation every administrator on the host loses privilege escalation, and if `root` login is disabled and there is no console, the host is unrecoverable without a rescue boot. This is the single most expensive keystroke on this page.

Independent verification afterwards, always, from a **second** session that is already root:

```
$ sudo visudo -c
/etc/sudoers: parsed OK
/etc/sudoers.d/10-editor: parsed OK
/etc/sudoers.d/90-ops: parsed OK

$ sudo -l -U alice | tail -n 3
User alice may run the following commands on node-01:
    (root) NOPASSWD: sudoedit /etc/haproxy/haproxy.cfg
    (root) /usr/bin/systemctl reload nginx.service
```

### 9.3 Verifying an edit actually took effect

Never trust "I saved it". Prove it at four levels — the file, the syntax, the process, the behaviour:

```
# 1. FILE: did the bytes change, and is the inode the one everyone else uses?
$ stat -c 'inode=%i links=%h size=%s mtime=%y perms=%a %U:%G' /etc/nginx/nginx.conf
inode=2621451 links=1 size=2247 mtime=2026-08-26 10:14:03.882014210 +0000 perms=644 root:root

$ sudo diff -u /etc/nginx/nginx.conf.2026-08-26-1010 /etc/nginx/nginx.conf
--- /etc/nginx/nginx.conf.2026-08-26-1010	2026-08-26 10:10:11.000000000 +0000
+++ /etc/nginx/nginx.conf	2026-08-26 10:14:03.882014210 +0000
@@ -14,6 +14,7 @@
 events {
-    worker_connections 768;
+    worker_connections 8192;
 }

$ sudo md5sum /etc/nginx/nginx.conf
7c0a2f1a5e2b8d4c9f0e1a3b5c7d9e11  /etc/nginx/nginx.conf

# 2. SYNTAX: does the consumer accept the file?
$ sudo nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

# 3. PROCESS: is the running process using this inode, and did it reload?
$ sudo lsof -p "$(cat /run/nginx.pid)" 2>/dev/null | grep nginx.conf
nginx   1842 root    9r   REG  253,0    2247  2621451 /etc/nginx/nginx.conf

$ sudo systemctl reload nginx
$ systemctl show nginx -p ActiveState -p ExecMainStartTimestamp
ActiveState=active
ExecMainStartTimestamp=Tue 2026-08-26 10:14:41 UTC

# 4. BEHAVIOUR: does the system now do the thing you edited it to do?
$ sudo cat /proc/"$(cat /run/nginx.pid)"/limits | grep 'open files'
Max open files            65535                65535                files

$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/healthz
200
```

Level 4 is the only one that means anything to a user. Levels 1–3 are how you find out *why* level 4 failed.

The one-line check for the inode class of bug, host vs. container:

```
$ stat -c %i /srv/app/config/app.conf
2621789
$ docker exec app stat -c %i /etc/app.conf
2621451                              <-- MISMATCH: the bind mount is stale
```

```
$ docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}' app
/srv/app/config/app.conf -> /etc/app.conf (bind)
```

Fix: edit with `backupcopy=yes` (or `sed`-free in-place `cat > file`), and recreate the container to re-establish the mount.

### 9.4 Guided drills

Work these on a throwaway VM or container. Each has a checkable outcome.

**Drill 1 — modes and the exam keys.** Create a 20-line file with `seq 20 > /tmp/d1.txt`. Using only `vi /tmp/d1.txt` and only command-mode keys: (a) go to line 12 with `12G`; (b) yank three lines with `3yy`; (c) put them at the end with `G` then `p`; (d) delete lines 5–7 with `5G` then `3dd`; (e) change the word on line 1 with `cw`; (f) save and exit with `ZZ`. Verify: `wc -l /tmp/d1.txt` must print `20` (23 − 3).

**Drill 2 — search and substitute.** `cp /etc/services /tmp/d2.txt`. In `vi`: find the first occurrence of `tcp` with `/tcp⏎`; step through with `n`; search backward with `?udp⏎`; replace every `udp` with `UDP` in lines 1–100 with `:1,100s/udp/UDP/g`; then discard everything with `:e!` and confirm the file is unchanged with `diff /etc/services /tmp/d2.txt`.

**Drill 3 — the write-permission wall.** As a non-root user, `vi /etc/hosts`, add a line, and try `:w`, then `:w!`. Observe `E45` then `E212`. Recover with `:w !sudo tee % > /dev/null` and then `:e!`. Verify with `getent hosts <name>`.

**Drill 4 — swap recovery.** Open `/tmp/d1.txt` in `vim`, make a change, do **not** save, and kill the process from another terminal with `pkill -9 vim`. Reopen the file, read the `E325` banner, and recover with `vim -r`. Verify the recovered content with `diff`.

**Drill 5 — the inode trap.** `touch /tmp/bind-src; sudo mount --bind /tmp/bind-src /tmp/bind-dst` (create `/tmp/bind-dst` first). Edit `/tmp/bind-src` with `vim -c 'set backupcopy=no'` and observe that `/tmp/bind-dst` does not change. Repeat with `backupcopy=yes` and observe that it does. Clean up with `sudo umount /tmp/bind-dst`.

**Drill 6 — `$EDITOR` resolution.** Using the shim from §6.2, determine on your system which variable is honoured by `crontab -e`, `git commit`, `systemctl edit` and `sudoedit`. Write the answers down; they are distribution-specific.

**Drill 7 — the sudoers near-miss.** In a **disposable** VM, `sudo visudo -f /etc/sudoers.d/99-test`, enter `%test ALL=(ALL) NOPASSWDD: ALL` (note the typo), save, and practise answering `e` at the `What now?` prompt. Then fix it and confirm with `visudo -c`. Never do this drill on a host you care about.

---

## 10. Exam quick-recall

The objective's literal term list, with the one-line answer each demands:

| Term | Answer |
|---|---|
| `vi` | The POSIX-mandated visual editor; on Linux almost always a build of `vim`. Starts in **command mode**. |
| `/` | Search **forward** for a pattern. |
| `?` | Search **backward** for a pattern. |
| `h` `j` `k` `l` | Left, down, up, right — one character/line at a time, in command mode. |
| `i` | Insert **before** the cursor. (`a` = after, `o` = open line below.) |
| `o` | **Open** a new line **below** the current one and enter insert mode. (`O` = above.) |
| `a` | **Append** — insert **after** the cursor. (`A` = at end of line.) |
| `c` | **Change** operator: delete the region a motion covers, then enter insert mode. `cw`, `cc`, `c$`. |
| `d` | **Delete** operator: `dw`, `d$`, `dG`. |
| `p` | **Put** (paste) the register **after** the cursor / **below** the line. (`P` = before/above.) |
| `y` | **Yank** (copy) operator: `yw`, `y$`. |
| `dd` | Delete the **whole current line**. `5dd` deletes five. |
| `yy` | Yank the **whole current line**. `3yy` yanks three. |
| `ZZ` | Write **if modified** and quit (same as `:x`). `ZQ` = `:q!`. |
| `:w!` | Force write, overriding vim's read-only flag — **not** filesystem permissions. |
| `:q!` | Quit, **discarding** all unsaved changes. |
| `:e!` | Re-edit: discard all unsaved changes and **reload the file from disk**. |
| `EDITOR` | The environment variable naming the default editor; `VISUAL` is its full-screen counterpart and usually takes precedence. Debian additionally exposes `/usr/bin/editor` via `update-alternatives`. |

Three distinctions that are asked in different words every time:

1. **`:w!` does not make you root.** It overrides the editor's own read-only marker. Permission is enforced by the kernel.
2. **`:q!` discards the buffer; `:e!` discards the buffer and reloads.** After `:q!` you are back in the shell; after `:e!` you are still editing.
3. **`ZZ` writes only if modified; `:wq` always writes.** On a host with change-triggered automation, that difference is a spurious service reload.

---

## Referencias

**Certification objective**

- LPI — Exam 101-500 Objectives (Topic 103.8, *Basic file editing*): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — LPIC-1 certification overview: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**Standards**

- The Open Group — POSIX.1-2017, `vi`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html>
- The Open Group — POSIX.1-2017, `ex`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/ex.html>
- The Open Group — POSIX.1-2017, `ed`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/ed.html>

**Editors**

- Vim — official site and documentation index: <https://www.vim.org/docs.php>
- Vim — user manual (`usr_toc`), the canonical HTML rendering of `:help`: <https://vimhelp.org/usr_toc.txt.html>
- Vim — `:help backupcopy` (write strategy and inode semantics): <https://vimhelp.org/options.txt.html#%27backupcopy%27>
- Vim — `:help recovery` (swap files, `-r`, `:recover`): <https://vimhelp.org/recover.txt.html>
- Vim — `vim(1)` manual page (Debian): <https://manpages.debian.org/stable/vim/vim.1.en.html>
- GNU nano — documentation index: <https://www.nano-editor.org/docs.php>
- GNU nano — `nano(1)`: <https://www.nano-editor.org/dist/latest/nano.html>
- GNU nano — `nanorc(5)`: <https://www.nano-editor.org/dist/latest/nanorc.5.html>
- GNU Emacs — reference manuals: <https://www.gnu.org/software/emacs/manual/>
- BusyBox — command reference (includes `vi`): <https://busybox.net/downloads/BusyBox.html>

**Mediated editing, locking and validation**

- Sudo — `sudo(8)` / `sudoedit`: <https://www.sudo.ws/docs/man/sudo.man/>
- Sudo — `visudo(8)`: <https://www.sudo.ws/docs/man/visudo.man/>
- Sudo — `sudoers(5)` (`editor`, `env_editor`, `SUDO_EDITOR`): <https://www.sudo.ws/docs/man/sudoers.man/>
- `vipw(8)` / `vigr(8)`: <https://man7.org/linux/man-pages/man8/vipw.8.html>
- `crontab(1)`: <https://man7.org/linux/man-pages/man1/crontab.1.html>
- systemd — `systemctl(1)`, `edit` verb: <https://www.freedesktop.org/software/systemd/man/latest/systemctl.html>
- systemd — environment variables, including `$SYSTEMD_EDITOR`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.html>
- Debian — `update-alternatives(1)`: <https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html>

**System interfaces referenced in the write-path analysis**

- `rename(2)` — atomic replacement semantics: <https://man7.org/linux/man-pages/man2/rename.2.html>
- `inotify(7)` — why watchers miss inode replacement: <https://man7.org/linux/man-pages/man7/inotify.7.html>
- `terminfo(5)` — terminal capability database: <https://man7.org/linux/man-pages/man5/terminfo.5.html>
- GNU coreutils — `stty` invocation (`-ixon`, `sane`): <https://www.gnu.org/software/coreutils/manual/html_node/stty-invocation.html>
- OpenSSH — `sshd(8)`, including `-t` configuration test: <https://man.openbsd.org/sshd.8>

**Infrastructure tooling used in the manifests**

- Kubernetes — `kubectl edit`: <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_edit/>
- Kubernetes — debugging a running Pod with ephemeral containers: <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/>
- Kubernetes — ConfigMaps, including `subPath` update behaviour: <https://kubernetes.io/docs/concepts/configuration/configmap/>
- Ansible — `ansible.builtin.copy` (`validate`, atomic move): <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/copy_module.html>
- Ansible — `ansible.builtin.lineinfile`: <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/lineinfile_module.html>
- cloud-init — module and example reference: <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>
- yamllint — configuration and rules: <https://yamllint.readthedocs.io/>