# LPIC-1 · Exam 101-500 · Topic 103.7 — Search text files using regular expressions
## Guided lab exercises (weight 4.69)

> **Scope of this lab.** Objective 103.7 covers: creating simple regular expressions containing several notational elements, and using regular expression tools to perform searches through a filesystem or file content. Key files, terms and utilities: `grep`, `egrep`, `fgrep`, `sed`, `regex(7)`.
> Sections marked **[beyond exam]** are production technique, not exam material — do them anyway, they explain *why* the exam-scope answers are what they are.

**Conventions used below**

- `$` prefixes a command you type. Lines without `$` are the expected output.
- Every regex is written inside **single quotes**. This is not decoration — see Block 10.
- Outputs were produced with GNU grep ≥ 3.7 / GNU sed ≥ 4.8 under `LC_ALL=C`. On BusyBox, macOS or Toybox some GNU extensions are absent; those are flagged inline.

---

## Block 1 — Build the lab and make it deterministic

The single most common reason two people get different output from the same `grep` is the **locale**. Fix it before anything else.

1. Create an isolated working directory:

```bash
$ mkdir -p ~/lab-103.7 && cd ~/lab-103.7
```

2. Pin the locale for this shell session:

```bash
$ export LC_ALL=C
$ locale | head -3
LANG=
LC_CTYPE="C"
LC_NUMERIC="C"
```

3. Identify your tools and their feature sets:

```bash
$ grep --version | head -1
grep (GNU grep) 3.11

$ sed --version | head -1
sed (GNU sed) 4.9

$ grep -P 'x' /dev/null; echo "PCRE exit=$?"
PCRE exit=1
```

> If step 3 prints `grep: support for the -P option is not compiled into this --disable-perl-regexp binary`, your build has no PCRE. Every **[beyond exam]** `-P` step will be unavailable; nothing else in this lab depends on it.

4. Observe what `egrep` and `fgrep` do on a modern system:

```bash
$ echo 'abc' | egrep 'a|b'
egrep: warning: egrep is obsolescent; using grep -E
abc
```

5. Create the corpus. Use a **quoted** here-doc delimiter (`<<'EOF'`) so the shell does not expand `$`, backticks or backslashes:

```bash
$ cat > auth.log <<'EOF'
Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy from 10.0.3.14 port 51344 ssh2
Aug 20 10:14:07 web01 sshd[2213]: Failed password for invalid user admin from 203.0.113.9 port 40122 ssh2
Aug 20 10:15:31 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
Aug 20 10:15:33 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
Aug 20 10:16:01 db01 CRON[2301]: pam_unix(cron:session): session opened for user root by (uid=0)
Aug 20 10:21:44 web02 sshd[3120]: Accepted password for ana from 192.168.10.55 port 33210 ssh2
Aug 20 10:22:59 web02 sshd[3140]: Failed password for invalid user test from 198.51.100.77 port 51002 ssh2
Aug 20 11:02:10 db01 sshd[4001]: Connection closed by 10.0.3.14 port 51344 [preauth]
EOF

$ cat > passwd.txt <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sync:x:4:65534:sync:/bin:/bin/sync
sshd:x:110:65534::/run/sshd:/usr/sbin/nologin
ana:x:1000:1000:Ana Diaz,,,:/home/ana:/bin/bash
deploy:x:1001:1001:Deploy Bot,,,:/home/deploy:/bin/bash
pablo:x:1002:1002::/home/pablo:/bin/sh
svc-backup:x:998:998:Backup service:/var/lib/backup:/usr/sbin/nologin
EOF

$ cat > inventory.csv <<'EOF'
host,role,env,cpu,mem_gb,ip
web01,frontend,prod,8,16,10.0.3.11
web02,frontend,prod,8,16,10.0.3.12
db01,database,prod,16,64,10.0.3.21
db02,database,staging,8,32,10.0.4.21
cache01,cache,prod,4,8,10.0.3.31
build01,ci,dev,4,8,10.0.5.10
web03,frontend,staging,4,8,10.0.4.13
EOF

$ cat > access.log <<'EOF'
10.0.3.11 - - [20/Aug/2026:10:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
203.0.113.9 - - [20/Aug/2026:10:14:09 +0000] "GET /admin.php HTTP/1.1" 404 153
203.0.113.9 - - [20/Aug/2026:10:14:11 +0000] "POST /wp-login.php HTTP/1.1" 404 153
10.0.3.12 - - [20/Aug/2026:10:15:00 +0000] "GET /api/v1/users?id=42 HTTP/1.1" 200 1841
10.0.3.12 - - [20/Aug/2026:10:15:02 +0000] "GET /api/v2/users?id=42 HTTP/1.1" 200 1902
198.51.100.77 - - [20/Aug/2026:10:16:44 +0000] "GET /../../etc/passwd HTTP/1.1" 400 0
10.0.3.11 - - [20/Aug/2026:10:17:31 +0000] "GET /static/app.js HTTP/1.1" 304 0
10.0.3.21 - - [20/Aug/2026:10:19:05 +0000] "GET /metrics HTTP/1.1" 200 20481
EOF

$ cat > app.conf <<'EOF'
# Application configuration -- managed by hand
listen_addr = 0.0.0.0
listen_port = 8080
log_level   = debug
workers     = 4

[database]
host = db01.internal
port = 5432
user = appuser
password = s3cr3t-do-not-commit
sslmode = disable

[cache]
host = cache01.internal
port = 6379
ttl  = 300
EOF

$ cat > words.txt <<'EOF'
The the quick brown fox
this line has has a duplicated word
no duplicates in this one
level radar rotor stats
aa bb cc dd
EOF
```

6. Verify the corpus is intact — every later expected count depends on these numbers:

```bash
$ wc -l auth.log passwd.txt inventory.csv access.log app.conf words.txt
  8 auth.log
  9 passwd.txt
  8 inventory.csv
  8 access.log
 17 app.conf
  5 words.txt
 55 total
```

**Questions**

- **Q1.1** — You run `grep '[a-z]' file` on a machine set to `es_ES.UTF-8` and get more matches than a colleague running the identical command. Neither file nor grep version differ. What is the mechanism, and which two environment variables control it?
- **Q1.2** — Your distribution ships `egrep` and `fgrep`. What are the modern, portable replacements, and what does GNU grep ≥ 3.8 do when you invoke the old names?
- **Q1.3** — Why was `<<'EOF'` used instead of `<<EOF` in step 5? Name one file above that would have been silently corrupted otherwise.

---

## Block 2 — BRE vs ERE: the metacharacter split

This is the highest-yield concept in 103.7. `grep` (and `sed`) default to **Basic Regular Expressions**; `grep -E` / `sed -E` select **Extended Regular Expressions**. The alphabet of literals and metacharacters is *different* between them.

| Construct | BRE (`grep`, `sed`) | ERE (`grep -E`, `sed -E`) |
|---|---|---|
| Any single char | `.` | `.` |
| 0-or-more | `*` | `*` |
| 1-or-more | `\+` *(GNU ext.)* | `+` |
| 0-or-1 | `\?` *(GNU ext.)* | `?` |
| Interval | `\{n,m\}` | `{n,m}` |
| Grouping | `\(...\)` | `(...)` |
| Alternation | `\|` *(GNU ext.)* | `\|` → written `|` |
| Backreference | `\1`…`\9` *(POSIX)* | `\1`…`\9` *(GNU ext., not POSIX ERE)* |

1. Match the four-digit sshd PID in the log — first in ERE, then in BRE:

```bash
$ grep -cE 'sshd\[[0-9]{4}\]' auth.log
7

$ grep -c 'sshd\[[0-9]\{4\}\]' auth.log
7
```

2. Now remove the escape from the opening bracket and observe the failure:

```bash
$ grep -c 'sshd[0-9]\{4\}' auth.log
0
```

3. Alternation, ERE and BRE:

```bash
$ grep -cE 'root|admin' auth.log
4

$ grep -c 'root\|admin' auth.log
4
```

4. The classic trap — alternation syntax used against the wrong dialect:

```bash
$ grep -c 'root|admin' auth.log
0
$ echo $?
1
```

5. Optional group. Find every account with an interactive POSIX shell:

```bash
$ grep -E ':/bin/(ba)?sh$' passwd.txt
root:x:0:0:root:/root:/bin/bash
ana:x:1000:1000:Ana Diaz,,,:/home/ana:/bin/bash
deploy:x:1001:1001:Deploy Bot,,,:/home/deploy:/bin/bash
pablo:x:1002:1002::/home/pablo:/bin/sh
```

6. The same in BRE, using GNU's escaped forms:

```bash
$ grep ':/bin/\(ba\)\?sh$' passwd.txt | wc -l
4
```

**Questions**

- **Q2.1** — In step 2, `sshd[0-9]\{4\}` returned 0 with exit status 1 and *no error message*. Explain precisely what that pattern asked for, character by character, and why nothing matched.
- **Q2.2** — In step 4, `grep` neither errored nor matched. What did the BRE engine understand `root|admin` to mean?
- **Q2.3** — Rewrite `grep -E '^(web|db)0[0-9],' inventory.csv` as a strict BRE, then predict how many lines it prints.
- **Q2.4** — Which two constructs in the BRE column of the table above are **GNU extensions** rather than POSIX BRE, and why does that matter when you write a script destined for an Alpine/BusyBox container?

---

## Block 3 — Anchors, word boundaries and whole-line matching

An unanchored pattern matches a *substring*. Most production `grep` bugs are unanchored patterns that matched something the author never considered.

1. Anchor to start of line:

```bash
$ grep -c '^Aug 20 10:1' auth.log
5
```

2. Anchor to end of line, and see the difference from the unanchored form:

```bash
$ grep -c 'sh' passwd.txt
5

$ grep -c 'sh$' passwd.txt
4
```

3. Identify the extra line the unanchored form pulled in:

```bash
$ grep -n 'sh' passwd.txt | grep -v 'sh$'
5:sshd:x:110:65534::/run/sshd:/usr/sbin/nologin
```

4. Word boundaries with `-w`. `port` appears three times in `app.conf`:

```bash
$ grep -n 'port' app.conf
3:listen_port = 8080
9:port = 5432
16:port = 6379

$ grep -nw 'port' app.conf
9:port = 5432
16:port = 6379
```

5. The GNU boundary operators do the same thing inside the pattern, so they compose with alternation:

```bash
$ grep -nE '\b(port|host)\b' app.conf
8:host = db01.internal
9:port = 5432
15:host = cache01.internal
16:port = 6379

$ grep -n '\<port\>' app.conf
9:port = 5432
16:port = 6379
```

6. Whole-line matching with `-x`, combined with literal matching:

```bash
$ grep -nFx '[cache]' app.conf
14:[cache]
```

7. Empty lines and comment lines — the canonical "effective configuration" filter:

```bash
$ grep -c '^$' app.conf
2

$ grep -cEv '^[[:space:]]*(#|$)' app.conf
14
```

**Questions**

- **Q3.1** — In step 4, why did `-w` exclude `listen_port` but keep `port = 5432`? Which exact character stopped the match, and what is grep's definition of a "word constituent"?
- **Q3.2** — In step 6, what would `grep -x '[cache]' app.conf` (no `-F`) have printed, and why?
- **Q3.3** — In step 7, `^[[:space:]]*(#|$)` was used instead of `^#`. Which real-world lines does the longer form catch that `^#` misses? Why is the `$` alternative necessary at all when the pattern already ends with `*`?
- **Q3.4** — Write a single `grep` that prints only lines of `passwd.txt` where the *username field itself* is exactly `bin` (and therefore does **not** print the `sshd` or `daemon` lines, whose home/shell fields contain `/bin`).

---

## Block 4 — Bracket expressions, character classes and locale

A bracket expression matches **exactly one** character. Inside it, almost all regex metacharacters lose their special meaning — `.`, `*`, `+`, `(`, `|` are literal. Only `^` (first position), `-` (range) and `]` (close) are special, and each has a positional escape rule.

1. POSIX character classes are locale-aware and portable; ASCII ranges are neither:

```bash
$ grep -oE '[[:digit:]]{4,5}' auth.log | head -4
2211
51344
2213
40122
```

2. Negated bracket expression — everything that is not a comma, to the end of line:

```bash
$ grep -oE '[^,]+$' inventory.csv
ip
10.0.3.11
10.0.3.12
10.0.3.21
10.0.4.21
10.0.3.31
10.0.5.10
10.0.4.13
```

3. Matching a literal `]` and a literal `[` — `]` must come **first**:

```bash
$ grep -o '[][]' app.conf
[
]
[
]
```

4. Matching a literal `-` — it must come first or last, or be escaped:

```bash
$ grep -nE '^[a-z_]+ *= *[a-z0-9.-]+$' app.conf | wc -l
12

$ grep -nE 'password = [a-z0-9-]+$' app.conf
11:password = s3cr3t-do-not-commit
```

5. Locale controls what `[[:alpha:]]` means. Prove it:

```bash
$ printf 'ñ\n' | LC_ALL=C grep -c '^[[:alpha:]]*$'
0

$ printf 'ñ\n' | LC_ALL=C.UTF-8 grep -c '^[[:alpha:]]*$'
1
```

> If `C.UTF-8` is unavailable, use any UTF-8 locale from `locale -a`, e.g. `es_ES.UTF-8`.

6. Case-insensitivity two ways — one portable, one relying on `-i`:

```bash
$ grep -cE '^[Aa]ug' auth.log
8

$ grep -ci '^aug' auth.log
8
```

**Questions**

- **Q4.1** — `[[:digit:]]` and `[0-9]` behaved identically in step 1 under `LC_ALL=C`. Name a concrete situation where they diverge, and state which one you should write in production code.
- **Q4.2** — Explain why `[][]` in step 3 is a well-formed bracket expression matching two characters, while `[[]]` is not the same thing. What does `[[]]` actually match?
- **Q4.3** — What does `[^,]` mean inside a bracket expression, and what does `^` mean *outside* one? Write a pattern that matches a line that is a single character which is **not** a `#`.
- **Q4.4** — In step 4, `[a-z0-9.-]` contains an unescaped `.` and a trailing `-`. Are either of them metacharacters here? Justify both.
- **Q4.5** — A colleague's cleanup script uses `grep '[A-z]'` to find "letters". Under `LC_ALL=C`, which non-letter ASCII characters does that range also match, and why?

---

## Block 5 — Quantifiers, greediness and `-o`

POSIX regular expressions are **leftmost-longest**: the match starts as early as possible and, from there, is as long as possible. There is no lazy/non-greedy quantifier in BRE or ERE — that is a PCRE feature.

1. See greediness bite, using a line with two quoted fields:

```bash
$ echo '"GET /a" 200 "-" "curl/8.5.0"' | grep -oE '".*"'
"GET /a" 200 "-" "curl/8.5.0"
```

2. The portable fix is a **negated bracket expression**, not a lazy quantifier:

```bash
$ echo '"GET /a" 200 "-" "curl/8.5.0"' | grep -oE '"[^"]*"'
"GET /a"
"-"
"curl/8.5.0"
```

3. Apply it to the real log to extract request lines:

```bash
$ grep -oE '"[^"]*"' access.log | head -3
"GET /healthz HTTP/1.1"
"GET /admin.php HTTP/1.1"
"POST /wp-login.php HTTP/1.1"
```

4. Interval quantifiers — extract HTTP status codes and rank them:

```bash
$ grep -oE '" [0-9]{3} ' access.log | tr -d '" ' | sort | uniq -c | sort -rn
      4 200
      2 404
      1 400
      1 304
```

> Ties (`400` vs `304`) are ordered by `sort`'s whole-line last-resort comparison, which is reversed by `-r`. Add `-s` or a `-k` key if you need a stable, documented order.

5. Filter to client and server errors only:

```bash
$ grep -nE '" [45][0-9]{2} ' access.log
2:203.0.113.9 - - [20/Aug/2026:10:14:09 +0000] "GET /admin.php HTTP/1.1" 404 153
3:203.0.113.9 - - [20/Aug/2026:10:14:11 +0000] "POST /wp-login.php HTTP/1.1" 404 153
6:198.51.100.77 - - [20/Aug/2026:10:16:44 +0000] "GET /../../etc/passwd HTTP/1.1" 400 0
```

6. The naive IP regex everyone writes, and why it is wrong:

```bash
$ echo '999.1.1.1 203.0.113.9' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'
999.1.1.1
203.0.113.9
```

7. The octet-correct version, anchored with word boundaries:

```bash
$ echo '999.1.1.1 203.0.113.9' | \
    grep -oE '\b((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b'
203.0.113.9
```

8. Rank source addresses in the auth log:

```bash
$ grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' auth.log | sort | uniq -c | sort -rn
      3 203.0.113.9
      2 10.0.3.14
      1 198.51.100.77
      1 192.168.10.55
```

9. `-c` counts *lines*, `-o | wc -l` counts *matches*. They are not the same number:

```bash
$ echo 'error error error' | grep -c 'error'
1
$ echo 'error error error' | grep -o 'error' | wc -l
3
```

**Questions**

- **Q5.1** — In step 1 the pattern `".*"` swallowed the whole line. Walk through the leftmost-longest rule and state exactly where the match began and ended.
- **Q5.2** — PCRE would let you write `".*?"`. Why is `"[^"]*"` the *better* engineering choice even where `grep -P` is available? Give a correctness reason and a performance reason.
- **Q5.3** — Without the two `\b` in step 7, the pattern still matches something inside `999.1.1.1`. What exactly, and why does the boundary assertion suppress it?
- **Q5.4** — Your monitoring script reports "17 errors" using `grep -c 'ERROR' app.log`. A postmortem shows 23 errors occurred. Explain the discrepancy and give the corrected command.
- **Q5.5** — Convert `[0-9]{1,3}` into valid BRE, and into a form that uses no interval quantifier at all.

---

## Block 6 — Filesystem search: recursion, file lists, exit codes

1. Build a small tree:

```bash
$ mkdir -p site/etc site/bin site/logs
$ cp app.conf site/etc/app.conf
$ cat > site/bin/deploy.sh <<'EOF'
#!/bin/sh
API_TOKEN="tok_live_9f3ac"
curl -H "Authorization: Bearer $API_TOKEN" https://api.example.com/v1/ping
EOF
$ printf 'ok\nok\nerror: connection refused\n' > site/logs/run.log
```

2. Recursive search with filename and line number:

```bash
$ grep -rn 'password' site/
site/etc/app.conf:11:password = s3cr3t-do-not-commit
```

3. List only the *files* that contain a secret-looking string, case-insensitively, sorted for determinism:

```bash
$ grep -rliE 'password|token|secret' site/ | sort
site/bin/deploy.sh
site/etc/app.conf
```

> Without `sort`, the order is the filesystem's `readdir` order — never rely on it in a script.

4. Invert the file list with `-L` — files that do **not** contain the pattern:

```bash
$ grep -rL 'error' site/ | sort
site/bin/deploy.sh
site/etc/app.conf
```

5. Restrict recursion by filename glob:

```bash
$ grep -rn --include='*.conf' 'host' site/
site/etc/app.conf:8:host = db01.internal
site/etc/app.conf:15:host = cache01.internal

$ grep -rn --exclude-dir=logs 'ok' site/ | wc -l
0
```

6. Learn the three exit codes — this is what makes `grep` usable in `if`:

```bash
$ grep -q 'listen_port' app.conf; echo $?
0
$ grep -q 'listen_sock' app.conf; echo $?
1
$ grep -q 'anything' /nonexistent.conf; echo $?
grep: /nonexistent.conf: No such file or directory
2
$ grep -qs 'anything' /nonexistent.conf; echo $?
2
```

7. Use it the way production scripts should:

```bash
$ if grep -qE '^password *=' app.conf; then
>   echo "FAIL: plaintext credential in app.conf"
> fi
FAIL: plaintext credential in app.conf
```

8. `-F` disables the regex engine entirely — the pattern becomes a fixed string:

```bash
$ echo '10x0y3z11' | grep -c '10.0.3.11'
1
$ echo '10x0y3z11' | grep -cF '10.0.3.11'
0
```

9. `-c` with multiple files reports per file, including zeros:

```bash
$ grep -c 'prod' inventory.csv access.log
inventory.csv:4
access.log:0
```

10. **[beyond exam]** Safe handoff to `xargs` when filenames may contain spaces or newlines:

```bash
$ grep -rlZ 'password' site/ | xargs -0 -r ls -l
-rw-r--r--. 1 user user 253 Aug 26 09:12 site/etc/app.conf
```

**Questions**

- **Q6.1** — State grep's three exit statuses and their meanings. Why does `grep -q pattern file && do_something` behave *incorrectly* if `file` might not exist, and what do you add to fix it?
- **Q6.2** — In step 8, `grep '10.0.3.11'` matched `10x0y3z11`. Give the two ways to make that search literal, and say which one you would use inside a script that receives the string from a variable.
- **Q6.3** — What is the difference between `-l` and `-L`? What is the difference between `-h` and `-H`, and when does grep add filename prefixes without being asked?
- **Q6.4** — You run `grep -r 'password' /etc` and get `Binary file /etc/some.db matches` plus a screen of unreadable bytes from another file. Name the option that reports binaries as text, and the option that skips them entirely.
- **Q6.5** — Why is `grep -rlZ ... | xargs -0` preferable to `grep -rl ... | xargs`? Construct a filename that breaks the second form.

---

## Block 7 — Context, multiple patterns and reporting

1. Context lines — before, after, and both:

```bash
$ grep -B1 -A1 'Connection closed' auth.log
Aug 20 10:22:59 web02 sshd[3140]: Failed password for invalid user test from 198.51.100.77 port 51002 ssh2
Aug 20 11:02:10 db01 sshd[4001]: Connection closed by 10.0.3.14 port 51344 [preauth]
```

2. Note the separator characters when `-n` is combined with context:

```bash
$ grep -C1 -n 'CRON' auth.log
4-Aug 20 10:15:33 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
5:Aug 20 10:16:01 db01 CRON[2301]: pam_unix(cron:session): session opened for user root by (uid=0)
6-Aug 20 10:21:44 web02 sshd[3120]: Accepted password for ana from 192.168.10.55 port 33210 ssh2
```

3. Stop after N matches — essential on multi-gigabyte logs:

```bash
$ grep -m2 -n 'Failed password' auth.log
2:Aug 20 10:14:07 web01 sshd[2213]: Failed password for invalid user admin from 203.0.113.9 port 40122 ssh2
3:Aug 20 10:15:31 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
```

4. Multiple patterns with `-e` (also the way to pass a pattern beginning with `-`):

```bash
$ grep -c -e 'Accepted' -e 'Connection closed' auth.log
3
```

5. Patterns from a file with `-f` — one pattern per line:

```bash
$ printf 'Accepted\nConnection closed\n' > patterns.txt
$ grep -nf patterns.txt auth.log
1:Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy from 10.0.3.14 port 51344 ssh2
6:Aug 20 10:21:44 web02 sshd[3120]: Accepted password for ana from 192.168.10.55 port 33210 ssh2
8:Aug 20 11:02:10 db01 sshd[4001]: Connection closed by 10.0.3.14 port 51344 [preauth]
```

6. Invert with `-v`, and combine with `-c`:

```bash
$ grep -cv -e '^#' -e '^$' app.conf
14
```

7. Chain greps to express logical AND (grep has no AND operator):

```bash
$ grep 'frontend' inventory.csv | grep -c 'prod'
2
```

8. Colour output, and the trap it sets:

```bash
$ grep --color=always -E 'v[12]' access.log | head -2 | cat -A | grep -o '\^\[\[[0-9;]*m' | head -3
^[[01;31m
^[[K
^[[01;31m
```

**Questions**

- **Q7.1** — In step 2, line 5 was printed with `5:` and lines 4 and 6 with `4-` / `6-`. What does each separator mean, and what third separator appears between non-adjacent context groups?
- **Q7.2** — `-m2` stopped after two matches. On a 40 GB log, what does grep do with the remainder of the file, and why does this matter more than the match count itself?
- **Q7.3** — Give two different ways to search for the literal string `-v` with grep, without grep interpreting it as an option.
- **Q7.4** — grep has `-e` (OR) but no AND. Give two distinct ways to require that a line contain *both* `frontend` and `prod`, one using a pipeline and one using a single ERE.
- **Q7.5** — A CI job pipes `grep --color=always` into a file and later parses it, and the parse fails. Explain, and state which of `--color=auto`, `--color=always`, `--color=never` belongs in a script.

---

## Block 8 — `sed` as a search-and-report tool

`sed` is in the 103.7 objective for a reason: it accepts **addresses** that are regular expressions, so it can select lines grep cannot (ranges, line numbers, "from pattern A until pattern B").

1. `sed -n` + `p` is grep:

```bash
$ sed -n '/Failed password/p' auth.log | wc -l
4
```

2. Numeric and mixed addressing — grep has no equivalent:

```bash
$ sed -n '2,4p' auth.log | wc -l
3

$ sed -n '/CRON/,$p' auth.log | wc -l
4
```

3. Regex-to-regex ranges — extract one section of an INI file:

```bash
$ sed -n '/^\[database\]/,/^$/p' app.conf
[database]
host = db01.internal
port = 5432
user = appuser
password = s3cr3t-do-not-commit
sslmode = disable

```

4. Report line numbers with `=`:

```bash
$ sed -n '/Failed/=' auth.log
2
3
4
7

$ sed -n '$=' auth.log
8
```

5. Group commands per address:

```bash
$ sed -n '/^\[/{=;p}' app.conf
7
[database]
14
[cache]
```

6. Substitution with capture groups — the field-extraction idiom. `-n` plus the `p` **flag** prints only lines that actually substituted:

```bash
$ sed -nE 's/^([^:]+):[^:]*:[0-9]+:[^:]*:[^:]*:[^:]*:(.*)$/\1 -> \2/p' passwd.txt
root -> /bin/bash
daemon -> /usr/sbin/nologin
bin -> /usr/sbin/nologin
sync -> /bin/sync
sshd -> /usr/sbin/nologin
ana -> /bin/bash
deploy -> /bin/bash
pablo -> /bin/sh
svc-backup -> /usr/sbin/nologin
```

7. `&` is the whole match; the `g` flag and a numeric flag select occurrences:

```bash
$ sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<&>/g' auth.log | head -1
Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy from <10.0.3.14> port 51344 ssh2

$ echo 'a a a a' | sed 's/a/X/2'
a X a a
$ echo 'a a a a' | sed 's/a/X/2g'
a X X X
```

8. Change the delimiter when the pattern contains slashes:

```bash
$ sed -n 's|/usr/sbin/nologin|/sbin/nologin|p' passwd.txt | wc -l
4
```

9. Deletion is the inverse of `-n p`:

```bash
$ sed '/^#/d; /^$/d' app.conf | wc -l
14
```

10. In-place editing with a backup — never do this without `.bak` the first time:

```bash
$ sed -i.bak 's/^log_level\( *\)= debug/log_level\1= info/' app.conf
$ grep -n 'log_level' app.conf app.conf.bak
app.conf:4:log_level   = info
app.conf.bak:4:log_level   = debug
```

11. Transliteration with `y` (character-for-character, no regex):

```bash
$ echo 'prod-web-01' | sed 'y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/'
PROD-WEB-01
```

12. Restore the file for later blocks:

```bash
$ mv app.conf.bak app.conf
```

**Questions**

- **Q8.1** — `sed -n '/^\[database\]/,/^$/p'` printed 7 lines including a trailing empty one. What are the exact semantics of a `/re1/,/re2/` range — in particular, is the closing line included, and what happens if `re2` never matches?
- **Q8.2** — In step 6, both `-n` and the trailing `p` flag were used. Describe what the command prints if you drop `-n`, and what it prints if you drop the `p` flag.
- **Q8.3** — `s/a/X/2` and `s/a/X/2g` gave different results. State the rule for a numeric flag, and for a numeric flag combined with `g`.
- **Q8.4** — Why did step 8 change the `s` delimiter to `|`? Write the same substitution using `/` as the delimiter.
- **Q8.5** — `sed -i` is not an in-place write: describe what GNU sed actually does to the inode, and explain what happens if the target path is a **symlink** into `/etc`. Which flag changes that behaviour?
- **Q8.6** — Rewrite step 6's ERE as a BRE (`sed -n '...p'` with no `-E`).

---

## Block 9 — Real diagnostics

1. Backreferences find *repetition*, which no other construct can express. Find doubled words:

```bash
$ grep -nE '\b([a-z]+) \1\b' words.txt
2:this line has has a duplicated word

$ grep -niE '\b([a-z]+) \1\b' words.txt
1:The the quick brown fox
2:this line has has a duplicated word
```

2. Backreferences are POSIX in **BRE**, and only a GNU extension in ERE. Both forms below find five-letter palindromes:

```bash
$ grep -oE '\b(.)(.).\2\1\b' words.txt
level
radar
rotor
stats

$ grep -o '\<\(.\)\(.\).\2\1\>' words.txt | wc -l
4
```

3. CRLF line endings — the single most common "but my regex is correct!" incident:

```bash
$ printf 'listen_port = 8080\r\nlog_level = info\r\n' > windows.txt
$ grep -c 'info$' windows.txt
0
```

4. Diagnose it with `sed -n l`, which renders non-printables unambiguously:

```bash
$ sed -n l windows.txt
listen_port = 8080\r$
log_level = info\r$
```

5. Confirm the diagnosis, then repair:

```bash
$ grep -c $'info\r$' windows.txt
1
$ sed -i 's/\r$//' windows.txt
$ grep -c 'info$' windows.txt
1
```

6. **[beyond exam]** PCRE lookbehind and `\K` extract without capture groups:

```bash
$ grep -oP '(?<=port )\d+' auth.log | sort -n | head -3
33210
40122
40188

$ grep -oP 'from \K[\d.]+' auth.log | sort -u
10.0.3.14
192.168.10.55
198.51.100.77
203.0.113.9
```

7. **[beyond exam]** Catastrophic backtracking, and why the POSIX engine is immune to it:

```bash
$ printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab\n' | timeout 5 grep -cE '^(a+)+$'
0

$ printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab\n' | timeout 5 grep -cP '^(a+)+$'
```

The `-E` run returns instantly. The `-P` run either burns 5 seconds and is killed (`echo $?` → `124`) or aborts with `grep: exceeded PCRE's backtracking limit`. Either outcome proves the point.

8. **[beyond exam]** Locale as a performance knob on large inputs:

```bash
$ yes 'Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy' | head -2000000 > big.log
$ time LC_ALL=en_US.UTF-8 grep -c 'sshd\[[0-9]*\]' big.log
$ time LC_ALL=C grep -c 'sshd\[[0-9]*\]' big.log
```

9. **[beyond exam]** Many literal patterns at once — `grep -F -f` builds one Aho–Corasick automaton and scans in a single pass:

```bash
$ grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' auth.log | sort -u > known-ips.txt
$ grep -cFf known-ips.txt access.log
6
```

**Questions**

- **Q9.1** — Why can `\b([a-z]+) \1\b` not be rewritten without a backreference? What formal class of pattern does this place it outside of?
- **Q9.2** — In step 3, `grep -c 'info$'` returned 0 on a file whose last visible characters are `info`. Explain what `$` anchors to and what character sat between `info` and the anchor.
- **Q9.3** — `sed -n l` is the diagnostic of choice here. Name two alternative commands that reveal the same thing, and say what advantage `sed -n l` has over `cat -A`.
- **Q9.4** — GNU grep's `-E`/`-G` engine is immune to catastrophic backtracking; `-P` is not. What is the architectural difference, and what capability do you give up in exchange for that immunity?
- **Q9.5** — In step 6, `\K` and `(?<=...)` do a similar job. Why can neither be replaced by a plain capture group when using `grep -o`? Which non-grep tool would you reach for instead if you need the captured group only?

---

## Block 10 — Quoting, globs, and the traps the exam actually asks about

**Globs are not regular expressions.** The shell's `*` means "any string"; the regex `*` means "zero or more of the preceding element". They share characters and share nothing else.

| Meaning | Shell glob | Regex |
|---|---|---|
| Any single character | `?` | `.` |
| Any string (incl. empty) | `*` | `.*` |
| One char from a set | `[abc]` | `[abc]` |
| Zero or more `a` | — | `a*` |
| Anchored by nature? | yes (whole name) | no (substring) |

1. See both engines side by side on the same directory:

```bash
$ ls *.conf
app.conf
$ ls | grep '\.conf$'
app.conf
$ ls | grep '.conf$'
app.conf
```

2. Prove that step 1's third command was matching by accident:

```bash
$ touch xconf
$ ls | grep '.conf$'
app.conf
xconf
$ ls | grep '\.conf$'
app.conf
$ rm xconf
```

3. Quoting: the shell expands before grep ever sees the pattern:

```bash
$ echo 'HOME is $HOME' > quoting.txt
$ grep '$HOME' quoting.txt
HOME is $HOME
$ grep "$HOME" quoting.txt
$ echo $?
1
```

4. A pattern containing a space **must** be quoted or it becomes two arguments:

```bash
$ grep -c 'Failed password' auth.log
4
$ grep -c Failed password auth.log
grep: password: No such file or directory
auth.log:4
```

5. `find` uses globs for `-name` and regexes for `-regex`:

```bash
$ find site -name '*.conf'
site/etc/app.conf
$ find site -regex '.*/[a-z]*\.sh'
site/bin/deploy.sh
```

6. Recursive grep versus `find -exec` — both are correct; only one scales:

```bash
$ grep -rl 'host' site/ | sort
site/etc/app.conf
$ find site -type f -exec grep -l 'host' {} + | sort
site/etc/app.conf
```

7. Clean up:

```bash
$ cd ~ && rm -rf ~/lab-103.7
```

**Questions**

- **Q10.1** — Explain, in terms of who interprets what, why `ls *.conf` and `ls | grep '\.conf$'` can return different results even in the same directory. Name two cases where they diverge.
- **Q10.2** — In step 3, `grep "$HOME" quoting.txt` matched nothing and exited 1. What pattern did grep actually receive? Why is single-quoting the default discipline for regex arguments?
- **Q10.3** — Translate the glob `data?.[ct]sv` into an equivalent anchored ERE for `grep`.
- **Q10.4** — In step 4, grep printed an error *and* a result, and would have exited 2. Explain what the shell passed as `argv` and which element grep took as the pattern.
- **Q10.5** — When is `find ... -exec grep ... {} +` strictly better than `grep -r`? Name one behavioural difference beyond argument-list length.

---

## Answers

<details>
<summary><strong>Click to expand — full answers with reasoning</strong></summary>

### Block 1

**A1.1** — Range expressions such as `[a-z]` are resolved against the locale's **collation order**, not against ASCII codepoints. Under `LC_ALL=C` the order is byte value, so `[a-z]` is exactly the 26 lowercase ASCII letters. Under a UTF-8 locale with dictionary-style collation the range can span accented letters and, on some glibc versions, uppercase letters interleaved with lowercase. The controlling variables are **`LC_COLLATE`** (range/collation semantics) and **`LC_CTYPE`** (character classification, i.e. what `[[:alpha:]]` and multibyte decoding mean). `LC_ALL` overrides both; `LANG` is the fallback for both. The production rule: `export LC_ALL=C` at the top of any script whose regexes must be reproducible, or use POSIX classes instead of ranges.

**A1.2** — `grep -E` replaces `egrep`; `grep -F` replaces `fgrep`. Both wrapper scripts have been deprecated for decades and were made *noisy* in GNU grep 3.8 (2022): invoking them prints `egrep: warning: egrep is obsolescent; using grep -E` to stderr and then runs the correct grep. The warning goes to **stderr**, so it does not corrupt a pipeline's data — but it does pollute CI logs and will trip any test that asserts on empty stderr. GNU has announced eventual removal. LPI still lists `egrep`/`fgrep` as key utilities for 103.7, so know both the old names and their replacements.

**A1.3** — With an unquoted delimiter (`<<EOF`) the shell performs parameter expansion, command substitution and backslash processing on the here-doc body before writing it. **`site/bin/deploy.sh`** — written in Block 6 — contains `$API_TOKEN`, which would have expanded to the empty string, producing `Bearer ` and silently destroying the exercise. `app.conf` would also be at risk if it contained `$` or backticks. Quoting the delimiter (`<<'EOF'`) makes the body a literal.

### Block 2

**A2.1** — `sshd[0-9]\{4\}` asks for: the four literal characters `s`,`s`,`h`,`d`; then a **bracket expression** `[0-9]` matching exactly one digit; repeated `\{4\}` times — i.e. four digits. So the pattern means "`sshd` followed immediately by four digits". In the log, `sshd` is followed by a literal `[`, which is not a digit, so no line matches. grep exits 1 and prints nothing: a pattern that is *syntactically valid but semantically wrong* produces silence, not an error. To match a literal `[` you must escape it (`\[`) or place it in a bracket expression (`[[]`). The closing `]` needs no escape outside a bracket expression, but escaping it (`\]`) is harmless and symmetric.

**A2.2** — In BRE, `|` is **not** a metacharacter — it is an ordinary literal. `root|admin` therefore means the nine-character literal string `root|admin`, which appears nowhere in the file. Nothing errors because the pattern is perfectly legal BRE. To get alternation in BRE you must use the GNU extension `\|`; POSIX BRE has no alternation at all.

**A2.3** — BRE form: `grep '^\(web\|db\)0[0-9],' inventory.csv`. It prints **6** lines — `web01`, `web02`, `db01`, `db02`, `web03` is 5… plus none other, so recount: `web01`, `web02`, `db01`, `db02`, `web03` = **5** lines. (`cache01` and `build01` fail the `^\(web\|db\)` prefix; the header `host,...` fails too.) Note both `\(...\)` and `\|` are needed, and both are GNU extensions in BRE.

**A2.4** — `\+`, `\?` and `\|` are **GNU extensions to BRE** — POSIX BRE defines only `.`, `*`, `[...]`, `^`, `$`, `\(...\)`, `\{n,m\}` and `\1`–`\9`. BusyBox grep implements a reduced regex set and Alpine images ship BusyBox by default, so a script using `\+` or `\|` can work on your Debian workstation and fail — or, worse, match the literal characters — inside the container. The portable answer is to use `grep -E` and write `+`, `?`, `|` unescaped: ERE is POSIX and universally implemented.

### Block 3

**A3.1** — grep's `-w` requires that the match be preceded and followed by a **non-word-constituent character (or the line boundary)**. A word constituent is a letter, a digit, or the underscore `_`. In `listen_port`, the character immediately before `port` is `_`, which *is* a word constituent, so the match is rejected. In `port = 5432`, `port` is at the start of the line (a boundary) and followed by a space (non-constituent), so it is accepted. The underscore rule catches people out constantly — `-w` will not isolate a component of a snake_case identifier.

**A3.2** — `grep -x '[cache]'` would print **nothing** (exit 1). Without `-F`, `[cache]` is a bracket expression matching exactly **one** character from the set `{c,a,h,e}`, and `-x` demands the whole line be that single character. The literal line `[cache]` is seven characters, so no match. The alternatives are `grep -Fx '[cache]'`, or an escaped regex: `grep -x '\[cache\]'`.

**A3.3** — `^[[:space:]]*(#|$)` catches **indented comments** (`    # note`) and **whitespace-only lines** (a line of spaces or tabs), both of which `^#` and `^$` respectively miss. The `$` alternative is required because `[[:space:]]*` can match zero characters and then must be followed by *something*: without the alternation the pattern would need a `#`, so a blank line would not match. `(#|$)` says "after optional leading whitespace, either a comment marker or end of line".

**A3.4** — `grep '^bin:' passwd.txt`. Anchoring at `^` and terminating at the field separator `:` restricts the match to the first field. `grep -w 'bin'` would *not* work — it matches `/bin` and `/usr/sbin` occurrences on the `daemon`, `sync` and `sshd` lines, because `/` is a non-word character and therefore a valid boundary.

### Block 4

**A4.1** — They diverge in any locale whose digit set is larger than ASCII, and more importantly they diverge in *intent*: `[[:digit:]]` is defined by `LC_CTYPE` classification, while `[0-9]` is a **range**, resolved by `LC_COLLATE`. In a locale with non-byte-order collation, `[0-9]` can pick up unexpected characters that collate between `0` and `9`, and in some locales/implementations `[[:digit:]]` also matches non-ASCII decimal digits. Production rule: use POSIX classes (`[[:digit:]]`, `[[:alpha:]]`, `[[:space:]]`, `[[:alnum:]]`) — they express what you mean and survive a locale change. If you truly need ASCII-only, use POSIX classes **and** set `LC_ALL=C`.

**A4.2** — Inside a bracket expression, `]` loses its special meaning if it is the **first character** after `[` (or after a leading `^`). So `[][]` parses as: open bracket, literal `]`, literal `[`, close bracket — a set of two characters. `[[]]` parses as `[[]` (a set containing only the literal `[`) followed by a literal `]` **outside** the bracket expression — so it matches the two-character sequence `[]`, not "either bracket". This positional rule is why you can never escape `]` with a backslash inside a bracket expression portably: POSIX defines backslash as an *ordinary character* inside brackets.

**A4.3** — Inside a bracket expression and in first position, `^` **negates** the set: `[^,]` matches any single character that is not a comma. Outside a bracket expression, `^` is the **start-of-line anchor**. In any other position inside the brackets it is a literal `^`. A line that is a single non-`#` character: `grep '^[^#]$'`.

**A4.4** — Neither is a metacharacter here. Inside a bracket expression, `.` has no special meaning at all — it is simply the literal dot character, so escaping it (`[a-z0-9\.-]`) would actually *add* a backslash to the set, which is a bug. The `-` is special only *between* two endpoints; in **last position** (as here) it can only be literal, so `[a-z0-9.-]` is the set {lowercase letters, digits, `.`, `-`}. `-` in first position is likewise literal.

**A4.5** — `[A-z]` spans ASCII 65 (`A`) through 122 (`z`), which includes the six punctuation characters between `Z` (90) and `a` (97): **`[`, `\`, `]`, `^`, `_`, `` ` ``**. It is a classic off-by-range bug. The correct forms are `[A-Za-z]` or, better, `[[:alpha:]]`.

### Block 5

**A5.1** — Leftmost-longest: the engine finds the earliest position at which *any* match is possible — offset 0, the first `"`. From that start it takes the **longest** match, so `.*` consumes as far as it can while still allowing a final `"` — the last `"` on the line, at the end of `curl/8.5.0"`. The match therefore spans offset 0 to end of line. `-o` prints exactly that span. Note POSIX specifies leftmost-longest for the *overall* match; it is not the "greedy backtracking" of PCRE, but the visible effect here is the same.

**A5.2** — **Correctness:** `[^"]*` is a hard constraint — the match physically cannot cross a `"`. `.*?` is only a *preference*; on backtracking, a lazy quantifier will happily expand past a quote if that lets the overall pattern succeed, producing surprising matches on malformed input. **Performance:** `"[^"]*"` compiles to a deterministic automaton with no backtracking (linear time, and it works in `-E`/`-G` on every POSIX grep). `".*?"` requires the PCRE backtracking engine, is not available in `-E`, and is not portable to BusyBox or macOS grep.

**A5.3** — Without boundaries the engine can start at offset 1 of `999.1.1.1`: `[1-9]?[0-9]` matches `99`, then `\.` matches `.`, then `1`, `.`, `1`, `.`, `1` — yielding the bogus match `99.1.1.1`. `\b` requires a word/non-word transition at the match edges; between the first and second `9` both characters are word constituents, so no boundary exists there and the start position is rejected. At offset 0 the pattern genuinely fails (`999` cannot be an octet under this alternation), so the whole token is skipped.

**A5.4** — `grep -c` counts **matching lines**, not matches. Six of the errors shared a line with another error (e.g. a stack-trace line containing `ERROR` twice, or several errors concatenated). Corrected: `grep -o 'ERROR' app.log | wc -l`, which prints one line per match. If the pattern can match an empty string, prefer `grep -o` with a pattern that cannot.

**A5.5** — BRE: `[0-9]\{1,3\}`. Without any interval quantifier: `[0-9][0-9]\{0,1\}[0-9]\{0,1\}` still uses intervals, so the interval-free form is `[0-9][0-9]\?[0-9]\?` in GNU BRE, or in strict POSIX BRE with no extensions: `[0-9]\([0-9]\([0-9]\)*\)*` is wrong (unbounded) — the correct interval-free POSIX form is the alternation `[0-9][0-9][0-9]\|[0-9][0-9]\|[0-9]` with the longest alternative first, or in ERE `[0-9][0-9][0-9]|[0-9][0-9]|[0-9]`. This is precisely why interval quantifiers exist.

### Block 6

**A6.1** — `0` = at least one line selected; `1` = no lines selected, no error; `2` = an error occurred (unreadable file, invalid regex, missing file). `grep -q p f && do_something` is wrong for a missing file only if you assumed "non-zero means not found" — the real hazard is the inverse form `grep -q p f || alert`, which fires the alert on both "not found" (1) and "file missing" (2), masking a genuine infrastructure failure. Distinguish explicitly:
```bash
grep -q 'p' f; rc=$?
case $rc in 0) found;; 1) not_found;; *) echo "grep error" >&2; exit 2;; esac
```
`-s` suppresses the *message* for nonexistent/unreadable files but does **not** change the exit status — a very common misconception.

**A6.2** — (a) `grep -F '10.0.3.11'` — disables the regex engine entirely. (b) `grep '10\.0\.3\.11'` — escape each metacharacter. For a string coming from a **variable**, always use `-F` (ideally `grep -F -- "$needle"`): hand-escaping an arbitrary variable is an injection bug waiting to happen, since you cannot know which metacharacters it contains.

**A6.3** — `-l` prints the name of each file with at least one match and stops reading that file; `-L` prints the names of files with **no** match. `-H` forces the `filename:` prefix, `-h` suppresses it. grep adds the prefix automatically whenever it is given more than one file operand, or whenever `-r`/`-R` is used — including when the recursion happens to find only one file, which is why scripts that parse `grep -r` output must not assume the prefix is absent.

**A6.4** — `--binary-files=text` (or its short synonym `-a`) treats binary content as text and prints the matching lines. `-I` (capital i) is shorthand for `--binary-files=without-match` and skips binaries entirely — the right choice for a source-tree secret scan. Note grep decides "binary" by looking for NUL bytes or invalid encoding in the first buffer, so a UTF-16 text file is treated as binary.

**A6.5** — `-Z` (with `-l`) terminates each filename with a NUL byte instead of a newline, and `xargs -0` splits on NUL. Since NUL is the one byte that cannot appear in a POSIX filename, this is the only lossless pipeline. Breaking input for the second form: `touch $'site/etc/my\nfile.conf'` — the embedded newline makes plain `xargs` see two filenames, `site/etc/my` and `file.conf`, neither of which exists. Filenames containing spaces or quotes break it too. Add `-r` (`--no-run-if-empty`) so `xargs` does not run the command with zero arguments when grep finds nothing.

### Block 7

**A7.1** — `:` separates the line number (or filename) from a line that **matched**; `-` separates it from a **context** line supplied by `-A`/`-B`/`-C`. When two match groups are separated by lines that were not printed, grep emits a group separator line consisting of `--`. That `--` is why `grep -C` output cannot be fed naively into another parser; `--no-group-separator` suppresses it.

**A7.2** — With `-m2`, grep stops reading as soon as the second match is output (after finishing any trailing `-A` context), so the remaining ~40 GB is never read from disk. The point is **I/O and time**, not output volume: `grep 'x' huge.log | head -2` still reads the whole file until the SIGPIPE arrives, and on a slow or network filesystem that is the difference between milliseconds and minutes. `-m` also changes the exit status semantics usefully: it exits 0 immediately.

**A7.3** — (a) `grep -e '-v' file` — `-e` explicitly introduces a pattern. (b) `grep -- '-v' file` — `--` terminates option parsing. A third, if the pattern is literal: `grep -F -e '-v' file`.

**A7.4** — Pipeline: `grep 'frontend' inventory.csv | grep 'prod'`. Single ERE with an order-independent form: `grep -E 'frontend.*prod|prod.*frontend' inventory.csv`. If order on the line is guaranteed (as in this CSV), `grep -E 'frontend,prod'` suffices. The pipeline is clearer and cheaper for two terms; the ERE matters when you need a single pass over a huge file. (PCRE lookahead — `grep -P '(?=.*frontend)(?=.*prod)'` — is the concise version, but non-portable.)

**A7.5** — `--color=always` injects ANSI escape sequences (`ESC[01;31m`, `ESC[K`, `ESC[m`) into the *data stream*, so the downstream parser sees `\033[01;31mERROR\033[m` instead of `ERROR` and its own patterns fail to match. `--color=auto` — the value used by the distro's `alias grep='grep --color=auto'` — colours only when stdout is a terminal, which is why the problem is invisible interactively and appears only in CI. In a script, pass `--color=never` explicitly, or better, avoid inheriting the alias by calling `command grep` or `/usr/bin/grep`. Use `--color=always` only when deliberately piping to a pager with `less -R`.

### Block 8

**A8.1** — `/re1/,/re2/` selects from the first line matching `re1` **through** the next line matching `re2`, inclusive on both ends. Crucially, the search for `re2` begins on the line *after* the `re1` match, so a range whose two regexes match the same line still spans at least two lines. If `re2` never matches, the range runs to **end of file** — a silent, dangerous behaviour when the closing delimiter is optional (an INI section at the end of a file with no trailing blank line will swallow everything). The trailing empty line in the output is the `/^$/` line itself, included by the inclusive rule.

**A8.2** — Without `-n`: sed's automatic printing is back on, so every line is printed once by the auto-print *and* a second time by the `p` flag if it substituted — matching lines appear twice, non-matching once. Without the `p` flag (but with `-n`): sed prints **nothing at all**, because `-n` disables auto-print and no command requests output. The `-n` + `s///p` pair is the sed idiom for "print only transformed lines"; it is the direct analogue of `grep -o`.

**A8.3** — A numeric flag `N` replaces **only the Nth** occurrence on the line, leaving all others intact. `Ng` replaces the Nth occurrence **and every occurrence after it**. Plain `g` replaces all. This is a GNU extension for the combined `Ng` form; the bare numeric flag is POSIX.

**A8.4** — The pattern and replacement both contain `/`, which is the default delimiter; using `/` would require escaping every one of them. `sed` lets any character follow `s` as the delimiter, so `|` (or `#`, `,`, `%`) removes the escaping entirely. With `/`: `sed -n 's/\/usr\/sbin\/nologin/\/sbin\/nologin/p' passwd.txt` — the "leaning toothpick" problem. Note that when you change the delimiter, that character must then be escaped if it appears in the pattern.

**A8.5** — GNU `sed -i` writes the result to a **temporary file in the same directory**, then `rename(2)`s it over the target. The inode changes: the original inode is unlinked, so any open file descriptor, hard link, or process holding the old file keeps the *old* content, and file ownership/permissions are re-derived rather than preserved. If the target is a **symlink**, the rename replaces the symlink itself with a regular file — `/etc/resolv.conf` → `/run/systemd/resolve/stub-resolv.conf` is the canonical way people destroy a system with `sed -i`. `--follow-symlinks` makes GNU sed resolve the link and edit the real target. Always use `sed -i.bak` the first time, and prefer `sed ... > tmp && mv tmp file` when you need to control ownership.

**A8.6** — `sed -n 's/^\([^:]*\):[^:]*:[0-9]*:[^:]*:[^:]*:[^:]*:\(.*\)$/\1 -> \2/p' passwd.txt`. Every `(` `)` becomes `\(` `\)`; `+` becomes `*` with a preceding mandatory element, or use GNU's `\+`. Backreferences `\1`/`\2` are written identically in both dialects — they are POSIX in BRE and a GNU extension in ERE.

### Block 9

**A9.1** — `\1` demands that the second occurrence be **the same string** the group captured, which requires the engine to remember unbounded input. A pure regular expression (in the formal, finite-automaton sense) has only finite memory, so the language "some word, a space, then that same word" is not regular — it is the classic `ww` language, provably outside the regular class (pumping lemma). Backreferences therefore push the pattern language beyond regular, which is exactly why they force a backtracking implementation and why POSIX places them in BRE, where the implementation was already required to backtrack. It is also why grep's fast DFA path is disabled for patterns containing them.

**A9.2** — `$` anchors to the **end of the logical line**, i.e. the position immediately before the `\n` that grep stripped. The file has DOS line endings, so the byte sequence is `info` `\r` `\n`; grep strips only the `\n`, leaving a carriage return (0x0D) as the final character of the line. `info$` therefore fails because `info` is followed by `\r`, not by end-of-line. `$'info\r$'` succeeds because ANSI-C quoting inserts a real CR into the pattern.

**A9.3** — `cat -A` (or `cat -v -E -T`) shows `^M$` at the end of each line; `od -c file | head` shows the raw `\r \n` byte pairs; `file windows.txt` reports `ASCII text, with CRLF line terminators`. `sed -n l` has the advantage of using regex-style escapes (`\r`, `\t`, `\\`) rather than caret notation, and of wrapping long lines at a configurable width (`sed -n 'l 0'` disables wrapping) — so the output is directly readable as something you could paste back into a pattern. `file` is the fastest first check.

**A9.4** — GNU grep's POSIX engine compiles the pattern to a **DFA/NFA simulation** that tracks a *set* of active states in parallel and never backtracks, giving O(n·m) worst case and no dependence on input pathology. PCRE uses a **recursive backtracking** engine that explores alternatives one at a time, which on `^(a+)+$` against `aaaa…b` explores exponentially many partitions before failing. The capabilities you give up for DFA immunity are exactly the non-regular ones: lookahead/lookbehind, lazy quantifiers, atomic groups, `\K`, recursion, and (efficient) backreferences. This is a genuine engineering trade-off, not a defect: choose `-E` for untrusted input, `-P` only for trusted patterns on trusted data, and consider RE2-based tools (`ripgrep`) when you want both.

**A9.5** — `grep -o` prints **the whole match**, not a capture group — grep has no `--only-group`. So a capture group cannot narrow the output; you must move the unwanted text out of the match itself, which is precisely what a zero-width lookbehind `(?<=from )` or a match reset `\K` does. If you need capture groups, use `sed -nE 's/.../\1/p`' (portable, POSIX, in the exam objective), or `perl -nle 'print $1 if /from (\S+)/'` for arbitrary group extraction. For structured data, use the format-aware tool (`awk`, `jq`, `yq`) rather than a regex.

### Block 10

**A10.1** — `ls *.conf`: the **shell** expands the glob against directory entries and passes the resulting filenames to `ls`, which never sees a pattern. `ls | grep '\.conf$'`: **`ls`** lists everything, and **grep** filters its stdout as text. Divergences: (1) **Dotfiles** — a glob does not match a leading `.` unless `dotglob` is set, so `.hidden.conf` is invisible to `*.conf` but is listed and matched by the grep form. (2) **No matches** — with no matching file, bash leaves `*.conf` literal and `ls` errors with `No such file or directory` (unless `nullglob`/`failglob` is set), whereas the grep form simply exits 1 silently. (3) **Filenames with newlines** break the grep form, which is one of several reasons `ls | grep` should not drive scripts — use `find` or a glob.

**A10.2** — Double quotes permit parameter expansion, so the shell expanded `$HOME` and grep received the pattern `/home/dalmine` (or whatever your home is). That string does not appear in `quoting.txt`, hence no match and exit 1. Single quotes suppress every form of shell expansion, so grep receives the regex byte-for-byte. This matters far beyond `$`: `*`, `?`, `[`, `]`, `\`, backticks and whitespace are all shell-significant and all regex-significant, and the two interpretations differ. **Discipline: single-quote every regex; if you must interpolate a variable, interpolate it into a `-F` pattern, not a regex.**

**A10.3** — `grep -E '^data.\.[ct]sv$'`. Mapping: glob `?` → regex `.`; glob `.` → regex `\.`; glob `[ct]` → regex `[ct]` (identical); and because a glob is implicitly anchored to the whole filename, `^` and `$` must be added explicitly — a regex is a substring search by default. (`grep -Ex 'data.\.[ct]sv'` is equivalent.)

**A10.4** — The shell performed word splitting on the unquoted argument, so grep's `argv` was `["grep", "-c", "Failed", "password", "auth.log"]`. grep takes the first non-option operand as the **pattern** — `Failed` — and treats everything after it as file operands: `password` (nonexistent → error to stderr, exit status 2 pending) and `auth.log` (readable → `auth.log:4`, and the filename prefix appears because there is now more than one file operand). The final exit status is **2**, because an error dominates. The lesson: an unquoted multi-word pattern silently changes the meaning of the whole command line.

**A10.5** — `find ... -exec grep ... {} +` is strictly better when you need `find`'s predicates: `-type f` (skip devices, FIFOs and sockets that `grep -r` will happily block on), `-mtime`, `-size`, `-user`, `-prune` for complex directory exclusions, or `-xdev` to stay on one filesystem. Behavioural differences beyond argument length: (1) `grep -r` follows symlinks given on the command line but not those found during traversal, while `-R` follows all — `find` gives you explicit control with `-L`/`-P`; (2) with `+`, `find` may invoke grep **multiple times**, so `-m` limits, `-c` totals and exit statuses apply per invocation, and the `--` group separators restart; (3) `grep -r` reports its own traversal errors, whereas `find` reports them, which changes what appears on stderr and in what order. For pure "search this tree", `grep -r --include=` is simpler and faster; for "search files matching these attributes", use `find`.

</details>

---

## Objective self-check

Before moving on, you should be able to do each of these without help:

- [ ] State from memory which of `+ ? { } ( ) |` require a backslash in BRE and which do not in ERE.
- [ ] Explain why `grep '10.0.3.11'` is not a search for an IP address.
- [ ] Anchor a pattern to line start, line end, whole line and whole word — and say why `-w` treats `_` as part of a word.
- [ ] Write a bracket expression containing a literal `]`, a literal `-` and a literal `^`.
- [ ] Predict the output of `grep -c` versus `grep -o | wc -l` on a line with repeated matches.
- [ ] Recite grep's three exit statuses and use them in an `if`.
- [ ] Use `sed -n` with a numeric address, a regex address and a `/re1/,/re2/` range.
- [ ] Extract a field with `sed -nE 's/.../\1/p'`.
- [ ] Diagnose a failed `$` anchor caused by CRLF line endings.
- [ ] Explain the difference between a shell glob and a regular expression, with an example of each divergence.

## Official sources

- LPI — Exam 101-500 Objectives (topic 103.7): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU grep manual (regular expressions, options, exit status): <https://www.gnu.org/software/grep/manual/grep.html>
- GNU sed manual (addresses, `s` command, `-i`, `l` command): <https://www.gnu.org/software/sed/manual/sed.html>
- `regex(7)` — POSIX regular expressions on Linux: <https://man7.org/linux/man-pages/man7/regex.7.html>
- `grep(1)`: <https://man7.org/linux/man-pages/man1/grep.1.html>
- `glob(7)` — shell pattern matching, for the glob-vs-regex distinction: <https://man7.org/linux/man-pages/man7/glob.7.html>
- POSIX.1-2017, Base Definitions Chapter 9 — Regular Expressions (normative BRE/ERE definitions): <https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html>
- PCRE2 pattern syntax (for the `-P` sections): <https://www.pcre.org/current/doc/html/pcre2syntax.html>