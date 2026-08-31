# LPIC-1 · Exam 101-500 · Objective 103.2 — Process text streams using filters

**Exam weight: 3.12** (≈5% of 101-500) · **Version 5.0** · Profile: SRE / Platform Architect

**Utilities in scope:** `bzcat`, `cat`, `cut`, `head`, `less`, `md5sum`, `nl`, `od`, `paste`, `sed`, `sha256sum`, `sha512sum`, `sort`, `split`, `tail`, `tr`, `uniq`, `wc`, `xzcat`, `zcat`

---

## 1. Motivation: the pipeline is a streaming data plane

Every observability stack eventually fails you at the worst possible moment. The Loki gateway is throttled, Elasticsearch is in a red state because a shard rebalance ate the disk, or the incident predates the retention window. What you always still have is a node, a shell, and a file descriptor.

The architectural property that matters is this: **a Unix filter is a bounded-memory streaming operator**. `grep`, `cut`, `tr`, `sed`, `head` and `wc` process an arbitrarily large input in O(1) resident memory, because they hold at most one record at a time. `sort` and `uniq` are the exceptions that prove the rule — `sort` is a blocking operator (it cannot emit its first byte until it has read its last), and `uniq` is a *windowed* operator with a window of exactly one line. Knowing which category a tool falls into is the difference between a triage command that returns in 400 ms on a 40 GB log and one that OOM-kills your node.

The production problem is concrete:

> A regional ingress tier is returning 5xx at 3% of requests. The log pipeline is 40 minutes behind. You have SSH to three nodes, each with 12 GB of rotated, xz-compressed `access.log.*`. You need: the top offending upstreams, the request-path cardinality, and a byte-exact confirmation that the config the node is running is the config the GitOps repo says it should be running — in under five minutes, without downloading anything.

That is Objective 103.2 end to end. Nothing in this topic is a toy: `sha256sum -c` is what stands between your cluster and a tampered artifact, `sort -u` on `LC_ALL=C` is what makes a diff of two 10-million-line inventories deterministic, and misunderstanding SIGPIPE is what makes your `head`-terminated pipeline log a spurious "broken pipe" alert every night at 02:00.

---

## 2. The mechanics underneath: what a filter actually is

### 2.1 The contract

A filter is a process that:

1. reads bytes from **file descriptor 0** (`stdin`) when no file operand is given,
2. writes results to **fd 1** (`stdout`),
3. writes diagnostics to **fd 2** (`stderr`), which is *not* part of the pipeline,
4. exits `0` on success.

The shell's `|` operator calls `pipe(2)`, `fork(2)`, and `dup2(2)` so that the write end of the kernel pipe becomes the left process's fd 1 and the read end becomes the right process's fd 0. **All stages start simultaneously.** A pipeline is concurrent, not sequential — this is why `cmd | head -1` can finish before `cmd` has produced 1% of its output.

### 2.2 The pipe buffer and backpressure

```
$ ulimit -p                      # pipe buffer in 512-byte blocks
8
$ cat /proc/sys/fs/pipe-max-size
1048576
```

The kernel pipe buffer defaults to **65536 bytes** (16 pages). When it is full, the writer blocks in `write(2)` — that is backpressure, and it is what keeps a `zcat huge.gz | sort` pipeline from materialising the decompressed stream in RAM. The consumer's speed governs the producer's speed. You can inspect it live:

```
$ zcat access.log.gz | sed 's/^/x/' | wc -l &
[1] 21847
$ ls -l /proc/21847/fd
total 0
lrwx------ 1 root root 64 Aug 26 03:12 0 -> 'pipe:[418822]'
lrwx------ 1 root root 64 Aug 26 03:12 1 -> 'pipe:[418823]'
lrwx------ 1 root root 64 Aug 26 03:12 2 -> /dev/pts/0
```

### 2.3 SIGPIPE, exit 141, and the phantom alert

When a downstream stage closes its read end, the upstream write gets `SIGPIPE`. The default disposition is termination, and the shell reports `128 + 13 = 141`.

```
$ zcat access.log.gz | head -n 3 > /dev/null
$ echo "${PIPESTATUS[@]}"
141 0
```

`zcat` "failed". It did not — it was told to stop. This is correct, desirable behaviour, and it is the single most common cause of false-positive failures in shell-based health checks:

```bash
set -o pipefail                 # now the pipeline's status is 141
zcat access.log.gz | head -n 3  # -> exit 141 -> your CronJob is marked Failed
```

The production-safe idiom is to scope `pipefail` or whitelist 141:

```bash
set -euo pipefail
head_safe() {
  local rc=0
  { zcat "$1" | head -n 3; } || rc=$?
  case "$rc" in 0|141) return 0 ;; *) return "$rc" ;; esac
}
```

### 2.4 Buffering: why your streaming pipeline shows nothing

glibc's stdio is **line-buffered when fd 1 is a TTY and fully buffered (4 KiB) when it is a pipe**. This silently breaks live tailing:

```
$ tail -F /var/log/nginx/access.log | cut -d' ' -f9 | uniq -c
# ...nothing for minutes, then a burst of 4 KiB
```

Fix it at the offending stage with `stdbuf`:

```
$ tail -F /var/log/nginx/access.log | stdbuf -oL cut -d' ' -f9 | uniq -c
      3 200
      1 502
```

`grep --line-buffered` and `sed -u` have built-in equivalents. `stdbuf` works by `LD_PRELOAD`ing `libstdbuf.so`, so it has no effect on statically linked binaries or on programs that set their own buffering (`dd`, `tee` are unaffected by design).

### 2.5 Locale: the invisible correctness bug

`sort`, `tr`, `uniq -i` and character classes are all locale-sensitive. Under `en_US.UTF-8`, GNU `sort` ignores punctuation and case in its collation; under `C`/`POSIX` it compares raw bytes.

```
$ printf 'Zebra\napple\n_lib\nApple\n' | LC_ALL=en_US.UTF-8 sort
apple
Apple
_lib
Zebra
$ printf 'Zebra\napple\n_lib\nApple\n' | LC_ALL=C sort
Apple
Zebra
_lib
apple
```

Consequences you will hit in production:

- `comm`, `join` and `uniq` require input sorted **in the same collation they were built with**. Mixing locales produces silently wrong set operations — no error, just missing rows.
- Byte-order (`LC_ALL=C`) is the only reproducible ordering across distros, container images and CI runners. **Every checksum-stable, diffable sort must pin `LC_ALL=C`.**
- `LC_ALL=C` is also 2–5× faster, because it skips `strcoll(3)` in favour of `memcmp(3)`.

---

## 3. The catalogue, with production framing

### 3.1 Concatenation and inspection: `cat`, `nl`, `od`

`cat` concatenates. Its useful flags for diagnosis:

```
$ cat -A config.env
API_URL=https://api.internal:8443$
TIMEOUT=30^M$
  DEBUG=1$
$
```

`-A` = `-vET`: `$` marks end-of-line, `^M` is CR (a Windows line ending that will make your config parser produce `"30\r"`), `^I` would mark a tab. `-s` squeezes blank lines, `-n` numbers all lines, `-b` numbers non-blank lines.

**Avoid the useless use of cat.** `cat file | grep x` forks an extra process and loses `grep`'s ability to name the file; write `grep x file` or `< file grep x`. The legitimate uses of `cat` are: concatenating ≥2 files, feeding stdin to a program that cannot open files, and `cat -A`.

`nl` is a numbering filter with sectioning semantics that `cat -n` lacks:

```
$ printf 'alpha\n\nbeta\n' | nl
     1  alpha

     2  beta
$ printf 'alpha\n\nbeta\n' | nl -b a -w 3 -s ': ' -n rz
001: alpha
002: 
003: beta
```

| Flag | Meaning | Values |
|---|---|---|
| `-b` | which body lines to number | `a` all, `t` non-empty (default), `n` none, `pREGEX` matching |
| `-n` | number format | `ln` left, `rn` right (default), `rz` right zero-padded |
| `-w` | number width | default `6` |
| `-s` | separator | default `\t` |
| `-v` | first number | default `1` |
| `-i` | increment | default `1` |

`od` (octal dump) is the tool you reach for when a file "looks identical" but behaves differently. **In practice you almost always want `-c` or `-A x -t x1z`:**

```
$ printf 'GET /health\xc2\xa0HTTP/1.1\r\n' | od -c
0000000   G   E   T       /   h   e   a   l   t   h 302 240   H   T   T
0000020   P   /   1   .   1  \r  \n
0000027
$ printf 'GET /health\xc2\xa0HTTP/1.1\r\n' | od -A x -t x1z -v
000000 47 45 54 20 2f 68 65 61 6c 74 68 c2 a0 48 54 54  >GET /health..HTT<
000010 50 2f 31 2e 31 0d 0a                             >P/1.1..<
000017
```

`c2 a0` is U+00A0 NO-BREAK SPACE — copy-pasted from a wiki into a manifest, invisible in every editor, and the reason your health check 404s. `-v` disables the `*` run-compression; without it, long runs of identical bytes are collapsed and offsets get confusing.

| `od` option | Effect |
|---|---|
| `-c` | printable chars + C escapes (the fastest human read) |
| `-t x1` / `-t x2` / `-t x4` | hex, 1/2/4 bytes per unit |
| `-t d1`, `-t u1`, `-t o1` | signed/unsigned decimal, octal |
| `-A d\|o\|x\|n` | address radix; `n` suppresses offsets |
| `-z` | append the ASCII gutter |
| `-N BYTES`, `-j BYTES` | read only N bytes / skip first N |
| `-v` | do not compress duplicate lines |

### 3.2 Column extraction: `cut` and `paste`

`cut` is the cheapest field extractor there is — a single pass, no regex engine, no field splitting on runs.

```
$ cut -d: -f1,7 /etc/passwd | head -n 4
root:/bin/bash
daemon:/usr/sbin/nologin
bin:/usr/sbin/nologin
sys:/usr/sbin/nologin
$ cut -d: -f3 --output-delimiter=' | ' -f1,3 /etc/passwd | head -n 2
root | 0
daemon | 1
$ echo 'kube-apiserver-node01' | cut -c1-14
kube-apiserver
$ cut -d: -f1 --complement /etc/passwd | head -n 1
x:0:0:root:/root:/bin/bash
```

**The trap the exam and production both exploit:** `cut -d' '` treats *each* space as a delimiter, so runs of spaces create empty fields. `ls -l` and `ps` output are therefore not `cut`-able directly:

```
$ ls -l /etc/hosts | cut -d' ' -f5
                      # empty — field 5 is one of the padding spaces
$ ls -l /etc/hosts | tr -s ' ' | cut -d' ' -f5
221
```

`tr -s ' '` (squeeze) is the canonical pre-normaliser. Tab-delimited data has no such problem, which is why `-d$'\t'` (the `cut` default) is safe.

| Selector | Unit | Multibyte-safe? |
|---|---|---|
| `-b LIST` | bytes | no — splits UTF-8 sequences |
| `-c LIST` | characters | yes in a UTF-8 locale |
| `-f LIST` | delimiter-separated fields | n/a |

`LIST` accepts `N`, `N-`, `-M`, `N-M`, and comma lists. **Order is ignored**: `cut -f3,1` emits fields 1 then 3. If you need reordering, `cut` is the wrong tool.

`paste` is `cut`'s inverse — a column-wise merge:

```
$ cut -d: -f1 /etc/passwd | head -3 > /tmp/u
$ cut -d: -f7 /etc/passwd | head -3 > /tmp/s
$ paste -d' -> ' /tmp/u /tmp/s
root -> /bin/bash
daemon -> /usr/sbin/nologin
bin -> /usr/sbin/nologin
```

The delimiter list cycles per column. `-s` (serial) transposes a column into a row — the idiom for turning a file list into a CSV argument:

```
$ kubectl get ns -o name | cut -d/ -f2 | paste -sd,
default,kube-system,kube-public,ingress-nginx,observability
$ paste -sd'\n\n' /tmp/u        # cycle delimiters to double-space
```

### 3.3 Windowing: `head`, `tail`, `less`

```
$ head -n 5 /var/log/syslog
$ head -c 512 /boot/vmlinuz | od -A d -t x1 | head -n 2
0000000 4d 5a ea 07 00 c0 07 8c c8 8e d8 8e c0 8e d0 31
0000016 e4 8e d4 fb fc be 40 00 ac 20 c0 74 09 b4 0e bb
$ tail -n 20 /var/log/nginx/error.log
$ tail -n +100 access.log        # from line 100 to EOF (note the +)
$ head -n -5 report.txt          # all but the LAST 5 lines (GNU only)
```

| Form | `head` | `tail` |
|---|---|---|
| `-n N` | first N lines | last N lines |
| `-n +N` | (GNU) all but last N is `-n -N` | from line N onward |
| `-n -N` | all but the last N lines | (GNU) all but the first N is `-n +N` |
| `-c N` | first N bytes | last N bytes |
| `-q` / `-v` | suppress / force filename headers | same |

`head -n -N` and `tail -n +N` both require buffering or seeking — `tail -n +N` streams, `head -n -N` must hold an N-line ring buffer.

**`tail -f` vs `tail -F` is an SRE-grade distinction:**

- `-f` follows the **inode**. When logrotate renames `access.log` → `access.log.1` and creates a new file, `-f` keeps reading the now-invisible old inode. Your dashboard goes quiet and nobody notices for six hours.
- `-F` = `--follow=name --retry`. It re-`open(2)`s by path when it detects rotation or truncation, and waits for the file to reappear.

```
$ tail -F /var/log/nginx/access.log
tail: '/var/log/nginx/access.log' has become inaccessible: No such file or directory
tail: '/var/log/nginx/access.log' has appeared;  following new file
10.42.0.7 - - [26/Aug/2026:03:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
```

Two more flags that matter in supervisors and sidecars:

```
$ tail -F --pid=$(pidof nginx) /var/log/nginx/error.log   # exit when nginx dies
$ tail -f -s 5 /var/log/audit/audit.log                   # poll interval (inotify is used when available)
```

On a node with many followed files you can exhaust `fs.inotify.max_user_watches`; GNU tail falls back to polling and logs `inotify cannot be used, reverting to polling`.

`less` is a pager, not a filter, but it is in the objective and it is where triage actually happens:

| Key | Action |
|---|---|
| `/pat` `?pat` | search forward / backward |
| `n` `N` | next / previous match |
| `&pat` | **display only matching lines** (a live grep inside the pager) |
| `F` | follow mode, equivalent to `tail -f`; `Ctrl-C` exits back to paging |
| `g` `G` | first / last line |
| `-N` | show line numbers |
| `-S` | chop long lines instead of wrapping |
| `-X` | do not clear the screen on exit |
| `+F`, `+G`, `+/pat` | start in follow / at EOF / at first match |
| `q` | quit |

```
$ less +F /var/log/nginx/access.log
$ zcat access.log.4.gz | less -SN
```

`less` is not restricted to seekable input, so it works mid-pipeline; `LESSOPEN` lets it decompress transparently (`less access.log.gz` on most distros already works via `lesspipe`).

### 3.4 Ordering and deduplication: `sort` and `uniq`

`sort` is the only blocking operator in this objective. It reads everything, spills to `TMPDIR` when the in-memory buffer is exceeded, and merges runs.

```
$ sort -t: -k3,3n /etc/passwd | tail -n 3
sshd:x:74:74:Privilege-separated SSH:/var/empty/sshd:/sbin/nologin
prometheus:x:65534:65534::/var/lib/prometheus:/sbin/nologin
nobody:x:65534:65534:Kernel Overflow User:/:/sbin/nologin
$ du -sh /var/log/* | sort -h | tail -n 3
124M    /var/log/journal
1.2G    /var/log/nginx
3.4G    /var/log/containers
$ printf 'v1.10.0\nv1.9.3\nv1.2.0\n' | sort -V
v1.2.0
v1.9.3
v1.10.0
```

**Key syntax is the part people get wrong.** `-k F[.C][OPTS][,F[.C][OPTS]]`. If you omit the end field, the key runs *to the end of the line* — so `-k3n` on `/etc/passwd` sorts on "field 3 through end of line, interpreted numerically", which is not what you meant. **Always write a closed key: `-k3,3n`.**

| Option | Meaning | Notes |
|---|---|---|
| `-t CHAR` | field separator | default: transition from non-blank to blank; leading blanks belong to the *following* field |
| `-k F1,F2` | sort key range | per-key modifiers `n g h V r f b d i` override globals |
| `-n` | numeric | leading blanks/sign/digits only; `1e3` is not numeric |
| `-g` | general numeric (`strtod`) | handles `1e3`, `inf`; slower, float-precision loss |
| `-h` | human numeric | `1K < 1M < 1G`; matches `du -h`, `ls -lh` |
| `-V` | version sort | `1.10 > 1.9` |
| `-M` | month sort | locale-dependent |
| `-r` | reverse | |
| `-u` | output only the first of an equal-key run | **compares keys, not whole lines** |
| `-s` | stable | disables the last-resort whole-line comparison |
| `-b` | ignore leading blanks | must be per-key to be reliable |
| `-f` | fold case | |
| `-z` | NUL-terminated records | pairs with `find -print0` |
| `-c` / `-C` | check sortedness (exit 1 if not) | `-C` is silent |
| `-m` | merge already-sorted inputs | O(n) instead of O(n log n) |
| `-S SIZE` | memory buffer (`-S 2G`, `-S 50%`) | |
| `-T DIR` | temp directory for spills | |
| `--parallel=N` | worker threads | default = core count |
| `--compress-program=zstd` | compress spill files | huge win on large sorts with slow disks |

The `-u` subtlety, which bites in deduplication jobs:

```
$ printf 'a 1\na 2\nb 1\n' | sort -k1,1 -u
a 1
b 1
```

Only the *key* was compared, so `a 2` was discarded. Use `sort -u` without `-k`, or `sort | uniq`, when you mean "distinct lines".

`uniq` collapses **adjacent** duplicates only. It is a one-line-window filter, which is exactly why it is O(1) memory and why it requires sorted input:

```
$ printf 'a\nb\na\n' | uniq
a
b
a
$ printf 'a\nb\na\n' | sort | uniq -c
      2 a
      1 b
```

| Option | Meaning |
|---|---|
| `-c` | prefix each run with its count (`%7d ` — right-aligned in 7 columns) |
| `-d` | only lines that repeat (one per group) |
| `-D` | *all* lines from repeated groups |
| `-u` | only lines that occur exactly once |
| `-i` | case-insensitive |
| `-f N` | skip the first N fields when comparing |
| `-s N` | skip the first N characters when comparing |
| `-w N` | compare at most N characters |
| `-z` | NUL-terminated |

`-f`/`-s`/`-w` are what make `uniq` usable on timestamped logs, where the prefix differs but the message does not:

```
$ cut -d' ' -f1-3 --complement /var/log/syslog | sort | uniq -c | sort -rn | head -n 5
   4127 kernel: [UFW BLOCK] IN=eth0 OUT= MAC=...
    918 systemd[1]: Started Session c2 of user deploy.
    311 kubelet[1442]: E0826 03:14:02.118 pod_workers.go:190] Error syncing pod
     44 sshd[2288]: Failed password for invalid user admin from 45.83.64.7
      9 nginx[901]: upstream timed out (110: Connection timed out)
```

**`sort | uniq -c | sort -rn | head` is the top-N idiom.** Commit it to muscle memory; it answers "what is flooding my logs" in every incident.

### 3.5 Counting: `wc`

```
$ wc /etc/services
 11473  62139 692252 /etc/services
$ wc -l /var/log/nginx/access.log
2841903 /var/log/nginx/access.log
$ printf 'no trailing newline' | wc -l
0
$ printf 'no trailing newline' | wc -c
19
```

| Flag | Counts |
|---|---|
| `-l` | **newline characters** (not "lines") |
| `-w` | whitespace-delimited words |
| `-c` | bytes |
| `-m` | characters (locale-aware; differs from `-c` on UTF-8) |
| `-L` | length of the longest line (display width) |

`wc -l` counting newlines rather than lines is a real defect source: a truncated log whose final record lacks `\n` is undercounted by one, and a pipeline that reports `0` records for a single-record file will silently skip processing. When exactness matters, `grep -c ''` counts lines including an unterminated last one.

`-m` vs `-c` is the UTF-8 check:

```
$ printf 'año\n' | wc -c -m
4 5      # -m=4 chars, -c=5 bytes  (output order is line,word,char,byte per POSIX)
```

### 3.6 Character-level transformation: `tr`

`tr` translates, squeezes and deletes **characters** — never strings. It reads only from stdin (no file operands).

```
$ echo 'Prod-Cluster-EU' | tr 'A-Z' 'a-z'
prod-cluster-eu
$ echo 'Prod-Cluster-EU' | tr '[:upper:]' '[:lower:]'      # locale-correct form
prod-cluster-eu
$ cat -A config.env | head -n 1
TIMEOUT=30^M$
$ tr -d '\r' < config.env > config.env.fixed
$ ls -l | tr -s ' ' | cut -d' ' -f5,9
221 hosts
$ head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' ; echo
7fQx2LmZ9pKdR4vT
$ echo 'a:b:c' | tr ':' '\n'
a
b
c
```

| Flag | Effect |
|---|---|
| `-d SET1` | delete every character in SET1 |
| `-s SET` | squeeze repeated adjacent characters in SET to one |
| `-c` / `-C` | complement SET1 (operate on everything *not* in it) |
| `-t` | truncate SET1 to the length of SET2 |

Character classes: `[:alpha:] [:digit:] [:alnum:] [:space:] [:blank:] [:upper:] [:lower:] [:punct:] [:print:] [:graph:] [:cntrl:] [:xdigit:]`. Escapes: `\n \r \t \\ \NNN` (octal). Ranges: `a-z`, `\000-\037`.

**Sizing rules:** if SET2 is shorter than SET1, GNU `tr` pads SET2 with its last character (POSIX says undefined; `-t` truncates SET1 instead). `[:upper:]`→`[:lower:]` is the only class-to-class mapping guaranteed to work.

**What `tr` cannot do:** replace `"foo"` with `"bar"`. `tr foo bar` maps f→b, o→a, o→r. For string replacement you need `sed`. And `tr -d` on multibyte characters operates on bytes in most implementations, so `tr -d 'ñ'` can corrupt UTF-8 — use `sed 's/ñ//g'` instead.

Sanitising untrusted log text before it reaches a terminal (defensive: prevents ANSI-escape injection into your scrollback):

```
$ tr -d '\000-\010\013\014\016-\037\177' < untrusted.log | less
```

### 3.7 The stream editor: `sed`

`sed` reads one line into the **pattern space**, applies the script, prints the pattern space unless `-n`, and repeats. A separate **hold space** persists across cycles. That is the entire execution model.

```
$ sed 's/upstream/backend/' error.log | head -n 1
2026/08/26 03:14:02 [error] 901#901: *18 backend timed out
$ sed 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/REDACTED/g' access.log | head -n 1
REDACTED - - [26/Aug/2026:03:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
$ sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/REDACTED/g' access.log | head -n 1
REDACTED - - [26/Aug/2026:03:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
```

**Addresses** select which lines a command applies to:

| Address | Selects |
|---|---|
| `5` | line 5 |
| `5,10` | lines 5–10 |
| `5,+3` | line 5 and the next 3 |
| `0~3` | every 3rd line (GNU step form) |
| `$` | last line |
| `/regex/` | matching lines |
| `/start/,/end/` | from first `start` to next `end` (re-triggerable) |
| `/regex/!` | negation |
| `5,$` | line 5 to EOF |

**Commands:**

| Command | Effect |
|---|---|
| `s/RE/REPL/FLAGS` | substitute; flags `g` (all), `N` (Nth), `p` (print), `i` (ignore case), `w FILE` |
| `d` | delete pattern space, start next cycle |
| `p` | print pattern space (pair with `-n`) |
| `q [EXIT]` | quit, optionally with an exit code |
| `a TEXT` / `i TEXT` / `c TEXT` | append after / insert before / change the line |
| `y/abc/xyz/` | transliterate (a `tr` for one line) |
| `n` / `N` | read next line (replacing / appending to pattern space) |
| `h H g G x` | hold-space: copy to / append to / copy from / append from / exchange |
| `=` | print the current line number |
| `r FILE` / `R FILE` | read whole file / one line of it |
| `{ ...; ... }` | group commands under one address |

In the replacement, `&` is the whole match, `\1`–`\9` are capture groups, and GNU adds `\U \L \u \l \E` for case conversion:

```
$ echo 'pod-frontend-7d9' | sed -E 's/^pod-(\w+)-.*/\U\1/'
FRONTEND
```

**Performance flags that matter at scale.** `sed` reads to EOF by default. On a 40 GB file, `sed -n '2000000p'` reads all 40 GB. Add `q`:

```
$ time sed -n '2000000p' huge.log
...
real    0m11.402s
$ time sed -n '2000000{p;q}' huge.log
...
real    0m0.318s
```

**`-i` is not an in-place write.** GNU `sed -i` creates a temp file in the same directory, writes it, and `rename(2)`s over the original. Implications you must plan for in production:

- The **inode changes**. Any process holding the old fd (`tail -f`, a running daemon) keeps reading the old content.
- **Hard links are broken** — the other names still point to the old inode.
- **Bind-mounted single files inside containers fail**: `sed: cannot rename /etc/nginx/nginx.conf: Device or resource busy`, because the mount target cannot be replaced. Write to a temp path and `cat > file` instead.
- SELinux contexts and non-default ACLs may not be preserved. `--follow-symlinks` is required if the target is a symlink, otherwise the symlink is replaced by a regular file.

```
$ sed -i.bak 's/worker_processes 1;/worker_processes auto;/' /etc/nginx/nginx.conf
$ ls /etc/nginx/nginx.conf*
/etc/nginx/nginx.conf  /etc/nginx/nginx.conf.bak
```

Always take the `.bak` on a live config, and always validate before reload (`nginx -t`).

### 3.8 Splitting: `split`

```
$ split -l 500000 -d -a 3 --additional-suffix=.log access.log chunk_
$ ls
chunk_000.log  chunk_001.log  chunk_002.log  chunk_003.log  chunk_004.log  chunk_005.log
$ wc -l chunk_*.log | tail -n 1
2841903 total
```

| Option | Effect |
|---|---|
| `-l N` | N lines per output file |
| `-b SIZE` | N bytes per file (`10M`, `1G`, `512K`) |
| `-C SIZE` | at most SIZE bytes, but never split a line |
| `-n N` | exactly N files (byte-split; may split lines) |
| `-n l/N` | N files, line-aligned |
| `-n r/N` | round-robin lines across N files |
| `-n l/K/N` | write only chunk K of N to stdout — no temp files |
| `-d` / `-x` | numeric / hex suffixes |
| `-a N` | suffix length (default 2 → 676 files with alpha suffixes) |
| `--additional-suffix=.ext` | keep the extension |
| `--filter='CMD'` | pipe each chunk through CMD instead of writing it |
| `-u` | unbuffered (for splitting a live stream) |

Two production patterns worth memorising:

```
# Parallel-process a huge log without ever writing chunks to disk
$ split -n l/8 --filter='sort -u > /tmp/part_$FILE' access.log part_

# Split and compress on the fly (no intermediate uncompressed files)
$ split -b 1G --filter='xz -T0 -c > $FILE.xz' backup.tar backup.part_

# Extract exactly the 3rd eighth of a file, streaming
$ split -n l/3/8 access.log | wc -l
355238
```

Suffix exhaustion is a real failure: `split -l 1000` on a 700 000-line file with the default `-a 2` dies with `split: output file suffixes exhausted` after `zz`. GNU auto-increases the suffix length when `-a` is not given, but scripts that pin `-a 2` will break as data grows.

### 3.9 Integrity: `md5sum`, `sha256sum`, `sha512sum`

```
$ sha256sum kubectl
b2e2f6cbbecb70f5cba0ba97b7e64ae7d61f9c7e60b0e88bea25ecfa1f7f9b3f  kubectl
$ sha256sum kubectl > kubectl.sha256
$ sha256sum -c kubectl.sha256
kubectl: OK
$ printf 'x' >> kubectl
$ sha256sum -c kubectl.sha256
kubectl: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
$ echo $?
1
```

The two-space separator is significant: **two spaces = binary/text mode, space-asterisk (` *`) = binary mode**. GNU coreutils treats both identically on Linux (no CRLF translation), but a file generated on Windows with ` *` will still verify correctly.

| Option | Effect |
|---|---|
| `-c FILE` | verify checksums listed in FILE |
| `--status` | no output; **communicate result via exit code only** |
| `--quiet` | print only failures |
| `--ignore-missing` | do not fail on absent files (verify a subset of a big manifest) |
| `--strict` | exit non-zero on malformed lines in the checksum file |
| `--tag` | emit BSD-style `SHA256 (file) = hash` |
| `-b` / `-t` | binary / text mode marker |
| `-z` | NUL-terminated output (safe for filenames with newlines) |

Exit codes for `-c`: `0` all matched; `1` at least one mismatch, missing file, or unreadable file; `2` usage error or a checksum file with no valid lines. `--strict` promotes malformed lines to failure — **use it in CI**, otherwise a truncated manifest verifies "successfully" against zero files.

```
$ sha256sum --status -c SHA256SUMS --strict || { echo "SUPPLY CHAIN FAILURE"; exit 1; }
```

| Algorithm | Digest | Speed (relative) | Collision resistance | Use it for |
|---|---|---|---|---|
| `md5sum` | 128-bit | fastest | **broken** (practical chosen-prefix collisions, 2009/2019) | accidental-corruption detection only, legacy vendor manifests |
| `sha1sum` | 160-bit | fast | **broken** (SHAttered 2017, chosen-prefix 2020) | legacy git object IDs; never for new integrity gates |
| `sha256sum` | 256-bit | fast (hardware `sha_ni` on modern x86) | current standard | **default for artifacts, images, IaC bundles** |
| `sha512sum` | 512-bit | often faster than SHA-256 on 64-bit CPUs *without* SHA extensions | current standard | large files on non-`sha_ni` hardware, FIPS-mandated pipelines |
| `sha512sum -a 224/256` (`sha224sum`, `shasum -a`) | truncated | as SHA-512 | current standard | when a shorter digest is required |

Check whether your CPU accelerates SHA-256:

```
$ grep -o -m1 'sha_ni' /proc/cpuinfo
sha_ni
$ openssl speed -evp sha256 2>/dev/null | tail -n 2
```

**Critical security framing:** a checksum proves *integrity*, not *authenticity*. If the attacker can rewrite the artifact, they can rewrite `SHA256SUMS` alongside it. The hash file must be delivered over a separate trust channel — a detached GPG signature (`gpg --verify SHA256SUMS.asc SHA256SUMS`), a sigstore/cosign attestation, or a pinned digest in a Git-signed manifest. `sha256sum -c` is the *last* link in that chain, not the whole chain.

### 3.10 Compressed streams: `zcat`, `bzcat`, `xzcat`

All three are decompress-to-stdout filters, so they slot into a pipeline without ever writing a plaintext temp file — which matters when the log is 12 GB and `/tmp` is 2 GB.

```
$ zcat /var/log/nginx/access.log.2.gz | wc -l
1204817
$ xzcat /var/log/nginx/access.log.9.xz | cut -d' ' -f9 | sort | uniq -c | sort -rn
 982411 200
  41209 304
   3877 502
    118 499
$ zcat access.log.*.gz | ...       # zcat concatenates multiple members/files
$ bzcat backup-2026-08.tar.bz2 | tar -tvf - | head -n 3
```

`zcat` is `gunzip -c`. Note that GNU `zcat` also handles `.Z` (compress) files; it does **not** handle `.bz2` or `.xz`. There is a matching family for each: `zless`/`bzless`/`xzless`, `zgrep`/`bzgrep`/`xzgrep`, `zdiff`, `zmore`.

| Format | Decompressor | Typical ratio (text logs) | Decompression speed | Compression cost | Streaming-friendly | Notes |
|---|---|---|---|---|---|---|
| `.gz` (DEFLATE) | `zcat` | ~4–6× | very fast | low | yes | universal; `pigz` parallelises compression, decompression is single-threaded |
| `.bz2` (BWT) | `bzcat` | ~5–7× | **slow** | high | yes (block-based) | largely superseded; `lbzip2`/`pbzip2` parallelise |
| `.xz` (LZMA2) | `xzcat` | ~7–10× | moderate | very high | yes | best ratio; `xz -T0` for parallel compress; high decompression RAM at `-9` |
| `.zst` | `zstdcat` | ~5–7× | **fastest** | low–moderate | yes | not in the LPIC-1 objective, but the current default in systemd-journald, Btrfs and container registries |

For log archival the practical rule is: `zstd -19 --long` or `xz -6` for cold archives you rarely read, `gzip`/`zstd -3` for the hot rotation window you grep daily. Cold-storage `xz -9` can cost 700 MB of RAM to *decompress* — an unpleasant discovery on a 1 GB memory-limited container.

---

## 4. Comparative decision tables

### 4.1 Which filter for which job

| Job | Reach for | Why not the alternative |
|---|---|---|
| Extract fixed-delimiter fields | `cut -d: -f1,7` | `sed`/`awk` cost a regex engine per line |
| Extract fields separated by *runs* of whitespace | `tr -s ' ' \| cut` | `cut` cannot collapse runs |
| Reorder or compute on fields | `awk` (out of exam scope) | `cut` ignores selector order |
| Replace a string | `sed 's/a/b/g'` | `tr` maps characters, not strings |
| Delete/squeeze/translate characters | `tr` | `sed` is ~5–10× slower for the same work |
| First/last N records | `head` / `tail` | `sed -n '1,10p'` reads to EOF unless you add `q` |
| Distinct values | `sort -u` | `uniq` alone only sees adjacent duplicates |
| Frequency ranking | `sort \| uniq -c \| sort -rn` | there is no single-pass coreutils alternative |
| Count records | `wc -l` | `grep -c ''` if the last line may lack `\n` |
| Byte-level diagnosis | `od -c` | every editor hides the bytes that are causing the bug |
| Chunk a huge file | `split -n l/N` | manual `head`/`tail` slicing is O(n²) |
| Integrity gate | `sha256sum -c --strict --status` | `md5sum` is not collision-resistant |

### 4.2 Memory and blocking behaviour

| Tool | Resident memory | Blocking? | First byte out |
|---|---|---|---|
| `cat`, `tr`, `cut`, `nl`, `sed` (no hold-space accumulation) | O(1) — one line/buffer | no | immediately |
| `head -n N` | O(1) | no | immediately; exits early → SIGPIPE upstream |
| `tail -n N` | O(N lines) ring buffer, or seek if seekable | yes | after EOF |
| `uniq` | O(1) — one-line window | no | immediately |
| `wc` | O(1) | yes (must count all) | after EOF |
| `sort` | O(n), spills to `-T` past `-S` | **yes** | after EOF |
| `sort -m` | O(number of inputs) | no | immediately |
| `split` | O(1) | no | immediately |
| `sha256sum` | O(1) | yes | after EOF |
| `zcat`/`xzcat`/`bzcat` | O(window/block) | no | immediately |

The operational consequence: **push `head`, `cut`, `grep` and `tr` as far left in the pipeline as possible, and `sort` as far right as possible.** Reducing the cardinality before the blocking operator is the single highest-leverage optimisation in shell data processing.

### 4.3 Measuring it yourself

Don't take ratios on faith — the harness below is reproducible on your own hardware, and the ordering, not the absolute numbers, is the lesson:

```bash
#!/usr/bin/env bash
# bench-filters.sh — quantify pipeline ordering and locale on YOUR node
set -euo pipefail
LOG=${1:?usage: bench-filters.sh <access.log>}

echo "== filter first, sort last =="
time (cut -d' ' -f7 "$LOG" | sort | uniq -c | sort -rn | head -20 >/dev/null)

echo "== sort first (anti-pattern) =="
time (sort "$LOG" | cut -d' ' -f7 | uniq -c | sort -rn | head -20 >/dev/null)

echo "== UTF-8 collation =="
time (LC_ALL=en_US.UTF-8 sort "$LOG" >/dev/null)

echo "== byte collation =="
time (LC_ALL=C sort "$LOG" >/dev/null)

echo "== sort tuned =="
time (LC_ALL=C sort -S 25% --parallel="$(nproc)" --compress-program=zstd "$LOG" >/dev/null)
```

Expect the filter-first ordering to dominate by roughly the ratio of full-line width to extracted-field width, and `LC_ALL=C` to cut sort wall-time by a factor of about 2–5 on a UTF-8 system. Record the actual numbers for your fleet; they become the justification when someone asks why the triage runbook pins `LC_ALL=C`.

---

## 5. Production infrastructure

### 5.1 Kubernetes: log-triage CronJob (complete manifests)

This runs entirely on the tools in this objective — no `awk`, no external binaries — against a mounted node log directory, and writes a compact digest an on-call engineer can read in fifteen seconds.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ops-triage
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-triage
  namespace: ops-triage
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-triage-scripts
  namespace: ops-triage
data:
  triage.sh: |
    #!/usr/bin/env bash
    # Streaming ingress-log triage. Bounded memory, no temp files outside $TMPDIR.
    set -euo pipefail
    export LC_ALL=C                 # byte collation: deterministic + fast

    LOG_DIR=${LOG_DIR:-/var/log/nginx}
    OUT_DIR=${OUT_DIR:-/reports}
    TOP_N=${TOP_N:-20}
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    REPORT="${OUT_DIR}/triage-${STAMP}.txt"

    # Decompress by extension; plain files pass through cat.
    stream() {
      local f
      for f in "$LOG_DIR"/access.log "$LOG_DIR"/access.log.*; do
        [ -e "$f" ] || continue
        case "$f" in
          *.gz)  zcat  -- "$f" ;;
          *.bz2) bzcat -- "$f" ;;
          *.xz)  xzcat -- "$f" ;;
          *)     cat   -- "$f" ;;
        esac
      done
    }

    # Combined log format field map (space-separated):
    #   1 remote_addr  4 [time_local  6 "request_method  7 request_uri  9 status
    {
      printf '=== ingress triage %s ===\n\n' "$STAMP"

      printf -- '--- total requests ---\n'
      stream | wc -l

      printf -- '\n--- status code distribution ---\n'
      stream | cut -d' ' -f9 | sort | uniq -c | sort -rn

      printf -- '\n--- top %s client addresses ---\n' "$TOP_N"
      stream | cut -d' ' -f1 | sort | uniq -c | sort -rn | head -n "$TOP_N"

      printf -- '\n--- top %s paths returning 5xx ---\n' "$TOP_N"
      stream \
        | sed -n '/" 5[0-9][0-9] /p' \
        | cut -d' ' -f7 \
        | sed 's/?.*$//' \
        | sort | uniq -c | sort -rn | head -n "$TOP_N"

      printf -- '\n--- requests per minute (last window) ---\n'
      stream | cut -d' ' -f4 | cut -c2-18 | uniq -c | tail -n 15

      printf -- '\n--- longest request lines (possible injection / overflow) ---\n'
      stream | wc -L
    } > "$REPORT"

    # Integrity anchor for the report itself: it will be shipped off-node.
    sha256sum "$REPORT" > "${REPORT}.sha256"
    sha256sum -c --strict --status "${REPORT}.sha256"

    printf 'report written: %s (%s bytes)\n' "$REPORT" "$(wc -c < "$REPORT")"
    head -n 40 "$REPORT"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: triage-reports
  namespace: ops-triage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ingress-log-triage
  namespace: ops-triage
spec:
  schedule: "*/30 * * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 900
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels:
            app.kubernetes.io/name: ingress-log-triage
        spec:
          restartPolicy: Never
          serviceAccountName: log-triage
          nodeSelector:
            node-role.kubernetes.io/ingress: "true"
          tolerations:
            - key: node-role.kubernetes.io/ingress
              operator: Exists
              effect: NoSchedule
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: triage
              image: debian:12-slim
              command: ["/bin/bash", "/scripts/triage.sh"]
              env:
                - name: LOG_DIR
                  value: /var/log/nginx
                - name: OUT_DIR
                  value: /reports
                - name: TOP_N
                  value: "20"
                - name: TMPDIR
                  value: /scratch
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 200m
                  memory: 128Mi
                limits:
                  cpu: "2"
                  memory: 512Mi
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: nginx-logs
                  mountPath: /var/log/nginx
                  readOnly: true
                - name: reports
                  mountPath: /reports
                - name: scratch
                  mountPath: /scratch
          volumes:
            - name: scripts
              configMap:
                name: log-triage-scripts
                defaultMode: 0555
            - name: nginx-logs
              hostPath:
                path: /var/log/nginx
                type: Directory
            - name: reports
              persistentVolumeClaim:
                claimName: triage-reports
            - name: scratch
              emptyDir:
                sizeLimit: 1Gi
```

The design decisions worth defending in a review:

- **`memory: 512Mi` is sufficient for arbitrarily large logs** because every stage except `sort` is O(1), and `sort`'s spill directory is the `emptyDir` at `/scratch` via `TMPDIR`. Without `TMPDIR`, `sort` would spill into `/tmp` on a `readOnlyRootFilesystem` and fail with `sort: cannot create temporary file in '/tmp': Read-only file system`.
- **`LC_ALL=C` is exported once at the top** — it makes the report reproducible across base images with different default locales, so the `sha256sum` anchor is meaningful.
- **`concurrencyPolicy: Forbid` + `activeDeadlineSeconds`** prevents pileup when a rotation makes a run unusually long.
- **`stream()` re-reads the logs for each section.** That is a deliberate trade: five passes over compressed data cost CPU but keep memory flat. If I/O dominates, replace it with a single pass into a `split -n r/5 --filter=...` fan-out.

Deploy and verify:

```
$ kubectl apply -f log-triage.yaml
namespace/ops-triage created
serviceaccount/log-triage created
configmap/log-triage-scripts created
persistentvolumeclaim/triage-reports created
cronjob.batch/ingress-log-triage created
$ kubectl -n ops-triage create job --from=cronjob/ingress-log-triage triage-manual-01
job.batch/triage-manual-01 created
$ kubectl -n ops-triage logs job/triage-manual-01 | head -n 20
report written: /reports/triage-20260826T031402Z.txt (3184 bytes)
=== ingress triage 20260826T031402Z ===

--- total requests ---
2841903

--- status code distribution ---
2705118 200
 112899 304
  20447 502
   2891 499
    548 404

--- top 20 client addresses ---
  84120 10.42.3.19
  61044 10.42.1.7
  ...
```

### 5.2 systemd: artifact integrity audit

```ini
# /etc/systemd/system/artifact-integrity.service
[Unit]
Description=Verify checksums of deployed platform artifacts
Documentation=https://www.gnu.org/software/coreutils/manual/html_node/sha256sum-invocation.html
After=local-fs.target

[Service]
Type=oneshot
User=integrity
Group=integrity
Environment=LC_ALL=C
WorkingDirectory=/opt/platform
ExecStart=/usr/local/sbin/verify-artifacts.sh
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
ReadOnlyPaths=/opt/platform
ReadWritePaths=/var/lib/integrity
CapabilityBoundingSet=
SystemCallFilter=@system-service
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/artifact-integrity.timer
[Unit]
Description=Hourly platform artifact integrity audit

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-artifacts.sh
set -euo pipefail
export LC_ALL=C

MANIFEST=/opt/platform/SHA256SUMS
STATE=/var/lib/integrity
mkdir -p "$STATE"

# 1. The manifest itself must be authentic, not merely present.
if ! gpg --batch --verify "${MANIFEST}.asc" "$MANIFEST" 2>/dev/null; then
  echo "FATAL: manifest signature invalid or missing" >&2
  exit 2
fi

# 2. Structural sanity before trusting it: every line must be <64 hex><2 spaces><path>.
bad=$(sed -n '/^[0-9a-f]\{64\}  ./!p' "$MANIFEST" | wc -l)
if [ "$bad" -ne 0 ]; then
  echo "FATAL: ${bad} malformed line(s) in ${MANIFEST}" >&2
  sed -n '/^[0-9a-f]\{64\}  ./!{=;p}' "$MANIFEST" >&2
  exit 2
fi
echo "manifest: $(wc -l < "$MANIFEST") entries, signature OK"

# 3. Verify. --strict turns malformed lines into failures; we already checked, belt and braces.
rc=0
sha256sum -c --strict --quiet "$MANIFEST" > "${STATE}/failures.txt" 2>&1 || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "integrity: all artifacts match"
  : > "${STATE}/failures.txt"
  exit 0
fi

echo "integrity: FAILURES DETECTED" >&2
# Report the drifted paths, one per line, deduplicated and sorted.
cut -d: -f1 "${STATE}/failures.txt" | sort -u | sed 's/^/  drifted: /' >&2
exit 1
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now artifact-integrity.timer
Created symlink /etc/systemd/system/timers.target.wants/artifact-integrity.timer → /etc/systemd/system/artifact-integrity.timer.
$ systemctl list-timers artifact-integrity.timer
NEXT                         LEFT       LAST                         PASSED    UNIT                      ACTIVATES
Wed 2026-08-26 04:11:37 UTC  57min left Wed 2026-08-26 03:09:12 UTC  4min ago  artifact-integrity.timer  artifact-integrity.service
$ journalctl -u artifact-integrity.service -n 5 --no-pager
Aug 26 03:09:12 node01 verify-artifacts.sh[3812]: manifest: 148 entries, signature OK
Aug 26 03:09:13 node01 verify-artifacts.sh[3812]: integrity: all artifacts match
Aug 26 03:09:13 node01 systemd[1]: artifact-integrity.service: Deactivated successfully.
```

### 5.3 CI: release-artifact verification gate

```yaml
# .gitlab-ci.yml
stages:
  - verify

verify-release-artifacts:
  stage: verify
  image: debian:12-slim
  variables:
    LC_ALL: "C"
    UPSTREAM: "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64"
  before_script:
    - apt-get update -qq && apt-get install -y -qq curl coreutils xz-utils ca-certificates
  script:
    - set -euo pipefail
    - curl -fsSLO "${UPSTREAM}/kubectl"
    - curl -fsSL  "${UPSTREAM}/kubectl.sha256" -o kubectl.upstream.sha256
    # Upstream publishes a bare digest; build a coreutils-format manifest from it.
    - printf '%s  %s\n' "$(tr -d '[:space:]' < kubectl.upstream.sha256)" kubectl > SHA256SUMS
    - cat SHA256SUMS
    - sha256sum -c --strict --status SHA256SUMS
    - echo "kubectl digest verified"
    # Fail loudly if the digest is not the one pinned in the repo.
    - cut -d' ' -f1 SHA256SUMS > got.txt
    - tr -d '[:space:]' < .pinned-kubectl-sha256 > want.txt
    - printf '\n' >> want.txt
    - diff -u want.txt got.txt || { echo "PIN MISMATCH — refusing to ship"; exit 1; }
  artifacts:
    when: always
    paths:
      - SHA256SUMS
    expire_in: 30 days
  rules:
    - if: $CI_COMMIT_TAG
```

```yaml
# .github/workflows/verify-artifacts.yml
name: verify-artifacts
on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  checksums:
    runs-on: ubuntu-24.04
    env:
      LC_ALL: C
    steps:
      - uses: actions/checkout@v4

      - name: Verify bundled artifact checksums
        run: |
          set -euo pipefail
          test -s dist/SHA256SUMS || { echo "empty or missing manifest"; exit 2; }
          # Reject anything that is not exactly <64 hex><2 spaces><path>
          if sed -n '/^[0-9a-f]\{64\}  ./!p' dist/SHA256SUMS | grep -q .; then
            echo "malformed manifest lines:"
            sed -n '/^[0-9a-f]\{64\}  ./!{=;p}' dist/SHA256SUMS
            exit 2
          fi
          echo "entries: $(wc -l < dist/SHA256SUMS)"
          cd dist && sha256sum -c --strict SHA256SUMS

      - name: Detect duplicate digests (build non-determinism smell)
        run: |
          set -euo pipefail
          cut -d' ' -f1 dist/SHA256SUMS | sort | uniq -d > dupes.txt
          if [ -s dupes.txt ]; then
            echo "identical content under multiple names:"
            while read -r h; do
              sed -n "/^${h}  /p" dist/SHA256SUMS
            done < dupes.txt
          fi
```

---

## 6. Verification and failure diagnosis

### 6.1 Symptom → cause → command

| Symptom | Likely cause | Diagnostic |
|---|---|---|
| Pipeline exits `141` | SIGPIPE from `head`/`q` closing the read end | `echo "${PIPESTATUS[@]}"`; whitelist 141 or drop `pipefail` for that pipeline |
| Config parses but value is wrong (`"30\r"`) | CRLF line endings | `cat -A file`, `od -c file \| head`; fix with `tr -d '\r'` or `sed -i 's/\r$//'` |
| Path 404s though it "looks right" | non-ASCII homoglyph or NBSP | `od -A x -t x1z` — look for `c2 a0`, `e2 80 9c` (smart quote) |
| `uniq` shows duplicates | input not sorted, or sorted in a different locale | `sort -c file`; re-sort both sides with `LC_ALL=C` |
| `comm`/`join` returns nothing sensible | mismatched collation between the two inputs | `LC_ALL=C sort -c` each input |
| `sort -k3n` gives wrong order | unclosed key ran to end of line, or leading blanks | use `-k3,3n`; add `-b` per key: `-k3,3bn` |
| `cut -d' '` yields empty fields | runs of spaces = empty fields | pre-normalise: `tr -s ' '` |
| `sort` dies: `cannot create temporary file` | read-only rootfs or full `/tmp` | set `TMPDIR` or `sort -T /scratch`; check `df -h /tmp` |
| `sort` OOM-kills the container | default `-S` too large for the cgroup limit | pin `sort -S 200M`; GNU sort does not read cgroup limits |
| `tail -f` goes silent after midnight | logrotate replaced the inode | switch to `tail -F`; verify with `stat -c '%i %n' file` before/after |
| Live pipeline emits nothing, then bursts | 4 KiB block buffering on a pipe | `stdbuf -oL`, `sed -u`, `grep --line-buffered` |
| `sed -i` fails `Device or resource busy` | single-file bind mount (container) | write temp + `cat > target`, or mount the directory |
| `sed -i` edited the file but the daemon sees old content | inode replaced; daemon holds old fd | reload the service; `ls -i` before/after |
| `sed -i` broke a hard link / symlink | rename semantics | use `--follow-symlinks`; re-link afterwards |
| `sha256sum -c` says OK but nothing was checked | manifest empty or all lines malformed | add `--strict`; assert `wc -l` > 0 first |
| `split: output file suffixes exhausted` | `-a` too small for the data volume | raise `-a`, or drop `-a` and let GNU auto-extend |
| `wc -l` reports one fewer than expected | file lacks a trailing newline | `tail -c1 file \| od -c`; use `grep -c ''` |
| `tr` corrupts accented characters | `tr` is byte-oriented for multibyte input | use `sed 's/x//g'` or `iconv` |
| `sort` output differs between CI and laptop | `LC_ALL`/`LANG` differ | pin `LC_ALL=C` in the job environment |
| Huge file, `sed -n 'Np'` takes minutes | `sed` reads to EOF | `sed -n 'N{p;q}'` |
| Pipeline is CPU-bound on one core | single-threaded `sort` / `gzip` | `sort --parallel`, `pigz`, `xz -T0`, or `split --filter` fan-out |

### 6.2 A verification ladder for any filter pipeline

Run these in order before trusting a pipeline you just wrote against production data:

```bash
# 1. Does the input contain what you think it contains?
$ head -n 3 access.log | od -c | head -n 6

# 2. Is the record count what you expect, including an unterminated last line?
$ wc -l access.log ; grep -c '' access.log
2841903 access.log
2841903

# 3. Does each stage preserve cardinality as intended? Add wc -l between stages.
$ cut -d' ' -f7 access.log | wc -l
2841903
$ cut -d' ' -f7 access.log | sort -u | wc -l
14822

# 4. Is the field index actually the field you want? Verify on one line, visibly.
$ head -n 1 access.log | tr ' ' '\n' | nl | head -n 10
     1  10.42.0.7
     2  -
     3  -
     4  [26/Aug/2026:03:14:02
     5  +0000]
     6  "GET
     7  /healthz
     8  HTTP/1.1"
     9  200
    10  2

# 5. Is your sort assumption valid before uniq/comm/join?
$ cut -d' ' -f7 access.log | sort | sort -c && echo "sorted OK"
sorted OK

# 6. Are stage exit codes clean, not just the last one?
$ zcat access.log.gz | cut -d' ' -f9 | sort | uniq -c > /dev/null
$ echo "${PIPESTATUS[@]}"
0 0 0 0

# 7. Is the result reproducible? Same input, same bytes out.
$ for i in 1 2; do LC_ALL=C sort -u access.log | sha256sum; done
a1f0...  -
a1f0...  -
```

Step 4 — `tr ' ' '\n' | nl` to enumerate fields — is worth internalising. It converts "I think status is field 9" into a fact in one command, and it has caught more off-by-one field bugs than any amount of staring at log lines.

### 6.3 Diagnosing a stalled pipeline

```
$ zcat huge.gz | sort -S 4G | uniq -c > out.txt &
[1] 4417
$ jobs -l
[1]+  4417 Running                 zcat huge.gz | sort -S 4G | uniq -c > out.txt &
$ ps -o pid,stat,wchan:20,cmd --ppid $$ --forest
  PID STAT WCHAN                CMD
 4417 S    pipe_read            zcat huge.gz
 4418 D    io_schedule          sort -S 4G
 4419 S    pipe_read            uniq -c
```

`STAT S` + `WCHAN pipe_read` on the *last* stage means it is starved — the blocking `sort` upstream has not produced anything yet, which is expected. `STAT D` + `io_schedule` on `sort` means it is spilling to disk; check where and how much:

```
$ ls -lh /tmp/sort*
-rw------- 1 root root 1.9G Aug 26 03:21 /tmp/sortAbC123
$ df -h /tmp
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3   50G   48G  1.4G  98% /tmp
```

That is your stall. `sort -T /mnt/scratch --compress-program=zstd -S 25%` fixes it. If the *first* stage is in `pipe_write` and the last is doing real work, you have simple backpressure and the pipeline is healthy — just slow.

---

## 7. Practice: work these until they are reflex

1. Produce the top 15 source IPs from a set of rotated, mixed-compression access logs, without writing any uncompressed data to disk.
2. Given `/etc/passwd`, list the usernames of all accounts with UID ≥ 1000, sorted by UID descending, as a single comma-separated line.
3. Find every byte in a config file that is not printable ASCII, with its offset.
4. Split a 10 GB log into exactly 16 line-aligned pieces, compressing each with `xz` on the fly and never materialising a plaintext chunk.
5. Verify a downloaded artifact against a bare upstream digest (no filename, no two-space separator) using `sha256sum -c`.
6. Redact all IPv4 addresses and all `Authorization: Bearer …` values from a log before handing it to a vendor.
7. Report how many *distinct* request paths returned 502, and the single most frequent one, in one pipeline.
8. Prove that two 5-million-line inventory files contain the same set of hostnames, on two machines with different default locales.

Reference solutions:

```bash
# 1
for f in access.log.*; do case $f in *.gz) zcat "$f";; *.xz) xzcat "$f";; *.bz2) bzcat "$f";; *) cat "$f";; esac; done \
  | cut -d' ' -f1 | LC_ALL=C sort | uniq -c | sort -rn | head -n 15

# 2
cut -d: -f1,3 /etc/passwd | sed -n '/:[0-9]\{4,\}$/p' | sort -t: -k2,2rn | cut -d: -f1 | paste -sd,

# 3
od -A d -c -v config.env | sed -n '/[0-9]\{3\}/p'
# or, byte-exact:
tr -d '\11\12\40-\176' < config.env | od -c

# 4
split -n l/16 --filter='xz -T2 -c > $FILE.xz' --additional-suffix=.log huge.log part_

# 5
printf '%s  %s\n' "$(tr -d '[:space:]' < kubectl.sha256)" kubectl | sha256sum -c --strict -

# 6
sed -E -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g' \
       -e 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\1<REDACTED>/g' app.log

# 7
sed -n '/" 502 /p' access.log | cut -d' ' -f7 | sed 's/?.*$//' \
  | LC_ALL=C sort | uniq -c | sort -rn | { tee /dev/stderr | wc -l; } 2>/tmp/top | head -n 1 /tmp/top
# simpler, two passes:
sed -n '/" 502 /p' access.log | cut -d' ' -f7 | sed 's/?.*$//' | LC_ALL=C sort -u | wc -l
sed -n '/" 502 /p' access.log | cut -d' ' -f7 | sed 's/?.*$//' | LC_ALL=C sort | uniq -c | sort -rn | head -n 1

# 8
cut -d, -f1 inventory-a.csv | LC_ALL=C sort -u | sha256sum
cut -d, -f1 inventory-b.csv | LC_ALL=C sort -u | sha256sum
# identical digests prove identical sets; LC_ALL=C makes it locale-independent
```

---

## 8. Exam-focused notes

Beyond the production framing, the 101-500 exam tests these specific discriminations:

- `head -n 5` vs `head -5` — both work in GNU, only `-n 5` is POSIX-portable. Expect `-n`.
- `tail -n +5` starts **at** line 5; `tail -n 5` shows the **last** 5. The `+` is the whole question.
- `cut -c` vs `-b` vs `-f`, and the fact that `cut` cannot handle repeated delimiters.
- `uniq` requires **sorted** input — this is the single most-tested fact in the objective.
- `sort -u` vs `uniq`: `sort -u` does not need pre-sorted input; `uniq` does.
- `tr` takes **no file arguments** — it is stdin-only.
- `wc -l` counts newlines; the default `wc` output order is lines, words, bytes.
- `nl` numbers only non-empty lines by default; `cat -n` numbers all.
- `od` defaults to **octal words** (`-t o2`), which surprises everyone — that is why `-c`/`-t x1` are always specified.
- `zcat` handles `.gz` and `.Z` only; `.bz2` needs `bzcat`, `.xz` needs `xzcat`.
- `split` default: 1000 lines per file, suffix `aa`, `ab`, …, prefix `x`.
- `sed` without `-n` prints every line; `-n` plus `p` is the "print only matches" idiom.
- `md5sum -c` reads a checksum **file**, and the format is `<digest><two spaces><filename>`.

---

## References

- LPI — Exam 101-500 Objectives (v5.0), Topic 103.2: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification Overview: https://www.lpi.org/our-certifications/lpic-1-overview/
- GNU Coreutils Manual — Output of entire files (`cat`, `nl`, `od`): https://www.gnu.org/software/coreutils/manual/html_node/Output-of-entire-files.html
- GNU Coreutils Manual — Output of parts of files (`head`, `tail`, `split`): https://www.gnu.org/software/coreutils/manual/html_node/Output-of-parts-of-files.html
- GNU Coreutils Manual — Operating on fields (`cut`, `paste`): https://www.gnu.org/software/coreutils/manual/html_node/Operating-on-fields.html
- GNU Coreutils Manual — `sort` invocation: https://www.gnu.org/software/coreutils/manual/html_node/sort-invocation.html
- GNU Coreutils Manual — `uniq` invocation: https://www.gnu.org/software/coreutils/manual/html_node/uniq-invocation.html
- GNU Coreutils Manual — `tr` invocation: https://www.gnu.org/software/coreutils/manual/html_node/tr-invocation.html
- GNU Coreutils Manual — `wc` invocation: https://www.gnu.org/software/coreutils/manual/html_node/wc-invocation.html
- GNU Coreutils Manual — `od` invocation: https://www.gnu.org/software/coreutils/manual/html_node/od-invocation.html
- GNU Coreutils Manual — `split` invocation: https://www.gnu.org/software/coreutils/manual/html_node/split-invocation.html
- GNU Coreutils Manual — `sha2` utilities (`sha256sum`, `sha512sum`): https://www.gnu.org/software/coreutils/manual/html_node/sha2-utilities.html
- GNU Coreutils Manual — `md5sum` invocation: https://www.gnu.org/software/coreutils/manual/html_node/md5sum-invocation.html
- GNU Coreutils Manual — `stdbuf` invocation: https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html
- GNU `sed` Manual — Execution cycle, addresses, commands: https://www.gnu.org/software/sed/manual/sed.html
- GNU `gzip` Manual (`zcat`, `zless`, `zgrep`): https://www.gnu.org/software/gzip/manual/gzip.html
- `less` — Home page and manual: https://www.greenwoodsoftware.com/less/
- XZ Utils — project page and `xzcat` documentation: https://tukaani.org/xz/
- bzip2 — project page and `bzcat` documentation: https://sourceware.org/bzip2/
- Linux man-pages — `pipe(7)`: https://man7.org/linux/man-pages/man7/pipe.7.html
- Linux man-pages — `signal(7)` (SIGPIPE semantics): https://man7.org/linux/man-pages/man7/signal.7.html
- Linux man-pages — `locale(7)` and `strcoll(3)`: https://man7.org/linux/man-pages/man7/locale.7.html
- Linux man-pages — `inotify(7)` (`tail -F` behaviour and watch limits): https://man7.org/linux/man-pages/man7/inotify.7.html
- POSIX.1-2024 Shell & Utilities — `cut`, `sort`, `uniq`, `tr`, `sed`, `wc`, `head`, `tail`, `od`, `paste`, `split`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/contents.html
- NIST FIPS 180-4 — Secure Hash Standard (SHA-256/384/512): https://csrc.nist.gov/pubs/fips/180-4/upd1/final
- NIST Policy on Hash Functions (MD5/SHA-1 deprecation): https://csrc.nist.gov/projects/hash-functions
- Kubernetes — CronJob (`batch/v1`): https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- systemd — `systemd.timer(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- systemd — `systemd.exec(5)` sandboxing directives: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- nginx — `log_module` / combined log format: https://nginx.org/en/docs/http/ngx_http_log_module.html