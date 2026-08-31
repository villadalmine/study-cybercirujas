# LPIC-1 103.2 — Process text streams using filters

**Exam:** 101-500 (LPIC-1, version 5.0) · **Objective:** 103.2 · **Weight:** 3.12

**Utilities in scope:** `bzcat`, `cat`, `cut`, `head`, `join`, `less`, `ls`, `md5sum`, `nl`, `od`, `paste`, `pr`, `sed`, `sha256sum`, `sha512sum`, `sort`, `split`, `tail`, `tr`, `uniq`, `wc`, `xzcat`, `zcat` — plus the adjacent whitespace filters `expand`/`unexpand`/`fmt` that older syllabus revisions listed and that still appear in real pipelines.

**Prerequisites:** a Linux shell with GNU coreutils ≥ 8.30, GNU sed ≥ 4.5, `gzip`, `bzip2`, `xz`. Verify with `sort --version | head -n 1`. Behaviour notes below marked *(GNU)* do not apply to BusyBox or the BSD/macOS toolchain.

**Reference sources**

- LPI, *Exam 101 Objectives (101-500)* — https://www.lpi.org/our-certifications/exam-101-objectives/
- GNU coreutils manual — https://www.gnu.org/software/coreutils/manual/coreutils.html
- GNU sed manual — https://www.gnu.org/software/sed/manual/sed.html
- POSIX.1-2017 Shell & Utilities — https://pubs.opengroup.org/onlinepubs/9699919799/utilities/contents.html
- GNU gzip manual — https://www.gnu.org/software/gzip/manual/gzip.html
- XZ Utils — https://tukaani.org/xz/
- `less` home page — https://www.greenwoodsoftware.com/less/

---

## Block 0 — Build the lab data set

Every later block uses these files. Do this one first.

1. Create and enter a scratch directory:

   ```bash
   mkdir -p ~/lpic1-103.2 && cd ~/lpic1-103.2
   ```

2. Create a colon-delimited record file. Note the header line and the deliberate duplicate salaries:

   ```bash
   cat > employees.txt <<'EOF'
   id:name:dept:salary:hired
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   1009:alvarez:ops:47500:2018-11-30
   1004:tanaka:qa:55000:2020-02-17
   1001:okoye:dev:73000:2017-05-09
   1006:silva:dev:61000:2022-09-23
   1003:novak:qa:49000:2019-08-05
   1008:haddad:ops:52000:2023-01-12
   1005:iversen:dev:68000:2016-04-28
   EOF
   ```

3. Create a space-delimited web log:

   ```bash
   cat > access.log <<'EOF'
   2026-08-20 10:11:02 GET /index.html 200 10.0.0.4
   2026-08-20 10:11:07 GET /style.css 200 10.0.0.4
   2026-08-20 10:12:44 GET /admin 403 10.0.0.9
   2026-08-20 10:13:01 POST /login 401 10.0.0.9
   2026-08-20 10:13:05 POST /login 401 10.0.0.9
   2026-08-20 10:13:09 POST /login 401 10.0.0.9
   2026-08-20 10:14:20 GET /index.html 200 10.0.0.7
   2026-08-20 10:15:00 GET /admin 403 10.0.0.9
   2026-08-20 10:16:31 GET /favicon.ico 404 10.0.0.7
   2026-08-20 10:17:02 GET /index.html 200 10.0.0.4
   EOF
   ```

4. Create two small lookup tables for `join`, plus a config file for `sed`:

   ```bash
   printf 'dev:okoye\nops:mora\nqa:tanaka\n' > dept-owner.txt
   printf 'dev:250000\nops:180000\nqa:120000\nsec:95000\n' > dept-budget.txt

   cat > config.conf <<'EOF'
   # main server config
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   # Listen 8080
   LogLevel warn
   EOF
   ```

5. Confirm the shapes:

   ```bash
   wc -l employees.txt access.log dept-owner.txt dept-budget.txt config.conf
   ```

   ```
   10 employees.txt
   10 access.log
    3 dept-owner.txt
    4 dept-budget.txt
    6 config.conf
   33 total
   ```

**Questions**

- **Q0.1** `employees.txt` has 10 lines but only 9 employees. Which downstream filters will silently corrupt their result because of that, and what is the standard one-command fix?
- **Q0.2** `wc -l` counts newline characters, not "lines". What does `wc -l` report for a file whose last line has no trailing newline, and which utility in this objective is the fastest way to *prove* the file is missing that newline?

---

## Block 1 — `cat`, `nl`, `od`: see the bytes, not the rendering

A filter pipeline can only be debugged if you can see what is actually in the stream. Terminals hide tabs, carriage returns, non-breaking spaces and BOMs. These three tools remove that ambiguity.

1. Reveal every non-printing character. `cat -A` is the portmanteau of `-v` (non-printing as `^X`/`M-X`), `-E` (`$` at end of line) and `-T` (tab as `^I`):

   ```bash
   printf 'a\tb\tc\n' > tabs.txt
   cat -A tabs.txt
   ```

   ```
   a^Ib^Ic$
   ```

2. Build a file with Windows line endings and diagnose it three different ways:

   ```bash
   printf 'alpha\r\nbeta\r\ngamma\r\n' > dos.txt
   file dos.txt
   cat -A dos.txt
   od -c dos.txt
   ```

   ```
   dos.txt: ASCII text, with CRLF line terminators
   ```
   ```
   alpha^M$
   beta^M$
   gamma^M$
   ```
   ```
   0000000   a   l   p   h   a  \r  \n   b   e   t   a  \r  \n   g   a   m
   0000020   m   a  \r  \n
   0000024
   ```

   Read the `od` output carefully: offsets are **octal** by default, 16 bytes per line, and the final line `0000024` is the total size (0o24 = 20 bytes).

3. Change the offset radix and the byte format. `-A d` gives decimal offsets, `-t x1` gives one-byte hex, `-A n` suppresses offsets entirely:

   ```bash
   od -A d -t x1z dos.txt
   printf 'A\tB\n' | od -An -tx1
   ```

   ```
   0000000 61 6c 70 68 61 0d 0a 62 65 74 61 0d 0a 67 61 6d  >alpha..beta..gam<
   0000016 6d 61 0d 0a                                      >ma..<
   0000020
   ```
   ```
    41 09 42 0a
   ```

4. Prove that byte count and character count differ under UTF-8:

   ```bash
   printf 'año\n' > utf8.txt
   od -An -tx1 utf8.txt
   wc -c utf8.txt
   wc -m utf8.txt
   ```

   ```
    61 c3 b1 6f 0a
   ```
   ```
   5 utf8.txt
   4 utf8.txt
   ```

5. Number lines. `nl` is not `cat -n`: by default `nl` uses body numbering style `t` (**t**ext — number only non-empty lines), a six-column right-justified number and a TAB separator:

   ```bash
   printf 'a\n\nb\n' | nl | cat -A
   printf 'a\n\nb\n' | cat -n | cat -A
   ```

   ```
        1^Ia$
          $
        2^Ib$
   ```
   ```
        1^Ia$
        2^I$
        3^Ib$
   ```

   `nl` pads the unnumbered line with seven blanks — the six-wide number field plus the one-character separator — so the text column stays aligned.

6. Drive `nl`'s formatting explicitly: `-b a` numbers **a**ll lines, `-n rz` is **r**ight-justified with leading **z**eros, `-w` sets the width, `-s` sets the separator:

   ```bash
   nl -b a -n rz -w 3 -s ': ' employees.txt | head -n 3
   ```

   ```
   001: id:name:dept:salary:hired
   002: 1007:mora:ops:52000:2019-03-14
   003: 1002:kim:dev:61000:2021-07-01
   ```

7. Concatenate and squeeze blank runs — the one job `cat` is genuinely for:

   ```bash
   printf 'x\n\n\n\ny\n' | cat -s
   ```

   ```
   x

   y
   ```

**Questions**

- **Q1.1** In step 2, `wc -l dos.txt` returns 3 and `wc -c dos.txt` returns 20. Reconcile those two numbers byte by byte.
- **Q1.2** `od -c` printed `\r` but `od -A d -t x1z` printed `0d`. Which representation would you use to hand a bug report to a developer, and why is `\r` ambiguous in a way `0d` is not?
- **Q1.3** Why does `wc -m utf8.txt` return 4 on your machine but could return 5 on a colleague's? Name the exact environment variable involved.
- **Q1.4** You must number *all* lines including blanks, with no leading zeros, in a script that must run on BusyBox. Which of `nl` or `cat -n` do you reach for, and what do you lose?
- **Q1.5** `cat file | grep pattern` is a well-known anti-pattern. Beyond style, name one *measurable* cost of the extra `cat` process in a pipeline over a 4 GB file.

---

## Block 2 — `head` and `tail`: bounded reads and live streams

1. Take the first three and last three lines:

   ```bash
   head -n 3 employees.txt
   tail -n 3 employees.txt
   ```

   ```
   id:name:dept:salary:hired
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   ```
   ```
   1003:novak:qa:49000:2019-08-05
   1008:haddad:ops:52000:2023-01-12
   1005:iversen:dev:68000:2016-04-28
   ```

2. The `+N` form of `tail` is the canonical header stripper. It means "start **at** line N", not "skip N lines":

   ```bash
   tail -n +2 employees.txt | head -n 2
   ```

   ```
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   ```

3. The negative form of `head` is the mirror image — "all but the last N" *(GNU)*:

   ```bash
   head -n -7 employees.txt
   ```

   ```
   id:name:dept:salary:hired
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   ```

4. Both tools also work in byte mode, which ignores line structure entirely:

   ```bash
   head -c 20 employees.txt; echo
   tail -c 11 employees.txt
   ```

   ```
   id:name:dept:salary:
   ```
   ```
   2016-04-28
   ```

5. Print an arbitrary line range by composing the two. Line 5 only:

   ```bash
   head -n 5 employees.txt | tail -n 1
   sed -n '5p' employees.txt
   ```

   Both print `1004:tanaka:qa:55000:2020-02-17`. The `sed` form is one process; the `head|tail` form is two but stops reading early, which matters on huge files.

6. Follow a live file. Open a second terminal for the writer:

   ```bash
   # terminal A
   tail -f /tmp/live.log
   ```
   ```bash
   # terminal B
   for i in 1 2 3; do echo "event $i"; sleep 2; done >> /tmp/live.log
   ```

   Stop with `Ctrl-C`. Now repeat with a rotation in the middle:

   ```bash
   # terminal A
   tail -f /tmp/live.log        # then, in terminal B:
   ```
   ```bash
   # terminal B
   mv /tmp/live.log /tmp/live.log.1 && echo "after rotate" > /tmp/live.log
   ```

   `tail -f` shows nothing further — it holds the *inode*, which is now `live.log.1`. Repeat the whole test with `tail -F` (equivalent to `--follow=name --retry`) and the new line appears, preceded by:

   ```
   tail: /tmp/live.log: file truncated
   ```
   or
   ```
   tail: '/tmp/live.log' has become inaccessible: No such file or directory
   tail: '/tmp/live.log' has appeared;  following new file
   ```

7. Multiple files get headers automatically; suppress or force them with `-q` / `-v`:

   ```bash
   tail -n 1 -q employees.txt access.log
   ```

   ```
   1005:iversen:dev:68000:2016-04-28
   2026-08-20 10:17:02 GET /index.html 200 10.0.0.4
   ```

**Questions**

- **Q2.1** `tail -n 3` and `tail -n +3` differ. State precisely what each returns for a 10-line file.
- **Q2.2** Why must `tail -n 5` on a *pipe* behave differently internally from `tail -n 5` on a *regular file*? What does it do in each case, and what is the memory implication?
- **Q2.3** You are watching an application log that logrotate rotates hourly with `copytruncate` disabled. Which of `-f` or `-F` do you use, and what exactly goes wrong with the other one?
- **Q2.4** `head -c 20` on a UTF-8 file can produce output that no terminal renders correctly. Explain the failure mode and name a safer alternative for character-oriented truncation.
- **Q2.5** Rewrite "print lines 40 through 45 of a 90 GB file" using only tools from this objective, and justify the ordering of the pipeline for I/O efficiency.

---

## Block 3 — `cut`, `paste`, `tr`: columns and character sets

1. `cut` in **field** mode (`-f`) with an explicit delimiter (`-d`). The default delimiter is TAB:

   ```bash
   cut -d: -f2,3 employees.txt
   ```

   ```
   name:dept
   mora:ops
   kim:dev
   alvarez:ops
   tanaka:qa
   okoye:dev
   silva:dev
   novak:qa
   haddad:ops
   iversen:dev
   ```

2. Prove that `cut` **cannot reorder** fields — the field list is a set, not a sequence:

   ```bash
   cut -d: -f3,2 employees.txt | head -n 2
   ```

   ```
   name:dept
   mora:ops
   ```

3. Change the output separator and use an open-ended range:

   ```bash
   cut -d: -f2,4 --output-delimiter=' -> ' employees.txt | head -n 3
   cut -d: -f3- employees.txt | head -n 2
   ```

   ```
   name -> salary
   mora -> 52000
   kim -> 61000
   ```
   ```
   dept:salary:hired
   ops:52000:2019-03-14
   ```

4. `cut` in **character** (`-c`) and **byte** (`-b`) mode. On the UTF-8 file the difference is visible:

   ```bash
   cut -c1-2 utf8.txt
   cut -b1-2 utf8.txt | od -An -tx1
   ```

   ```
   añ
   ```
   ```
    61 c3 0a
   ```

   `-b1-2` sliced a multi-byte sequence in half and produced an invalid UTF-8 byte.

5. `cut` treats **every** delimiter as significant — it has no "squeeze" mode. Aligned, space-padded output must be normalised first with `tr -s`:

   ```bash
   ls -l /etc | head -n 4 | cut -d' ' -f5,9          # garbage: runs of spaces
   ls -l /etc | head -n 4 | tr -s ' ' | cut -d' ' -f5,9
   ```

   The first command yields mostly empty fields; the second yields `size name` pairs (exact values are system-dependent).

6. `paste` is the transpose of `cut` — it joins files column-wise:

   ```bash
   cut -d: -f2 employees.txt | tail -n +2 > names.txt
   cut -d: -f4 employees.txt | tail -n +2 > salaries.txt
   paste -d: names.txt salaries.txt | head -n 3
   ```

   ```
   mora:52000
   kim:61000
   alvarez:47500
   ```

7. `paste -s` (**s**erial) flattens a stream into one line — the idiomatic "join lines with a comma":

   ```bash
   cut -d: -f2 employees.txt | tail -n +2 | paste -sd,
   ```

   ```
   mora,kim,alvarez,tanaka,okoye,silva,novak,haddad,iversen
   ```

8. `paste` with repeated `-` reads stdin once per placeholder, reshaping a stream into fixed-width rows:

   ```bash
   seq 1 6 | paste - - -
   ```

   ```
   1	2	3
   4	5	6
   ```

9. `tr` translates, deletes and squeezes **characters** — never strings, and it reads only stdin:

   ```bash
   tr 'a-z' 'A-Z' < names.txt | paste -sd,
   tr '[:lower:]' '[:upper:]' < names.txt | head -n 1
   ```

   ```
   MORA,KIM,ALVAREZ,TANAKA,OKOYE,SILVA,NOVAK,HADDAD,IVERSEN
   ```
   ```
   MORA
   ```

10. Delete (`-d`), squeeze (`-s`) and complement (`-c`):

    ```bash
    tr -d '\r' < dos.txt | od -c | head -n 1
    echo 'a    b        c' | tr -s ' '
    echo 'user=admin;host=web01' | tr -c '[:alnum:]' '\n' | tr -s '\n'
    ```

    ```
    0000000   a   l   p   h   a  \n   b   e   t   a  \n   g   a   m   m   a
    ```
    ```
    a b c
    ```
    ```
    user
    admin
    host
    web01
    ```

11. Observe the asymmetric-set rule: when SET2 is shorter than SET1, GNU `tr` pads SET2 by repeating its last character. `-t` (truncate) disables that:

    ```bash
    echo 'abcde' | tr 'abcde' 'xy'
    echo 'abcde' | tr -t 'abcde' 'xy'
    ```

    ```
    xyyyy
    ```
    ```
    xycde
    ```

**Questions**

- **Q3.1** You need fields 3 and 1 of `/etc/passwd`, printed as `uid username`. Show why `cut -d: -f3,1` fails and give a correct one-liner using only tools from this objective.
- **Q3.2** Explain in one sentence why `cut -d' '` is the wrong tool for `ls -l` output but the right tool for `access.log`.
- **Q3.3** `tr -d '\n' < file` and `paste -sd '' file` both remove newlines. Name one observable difference in the result.
- **Q3.4** `tr 'a-z' 'A-Z'` and `tr '[:lower:]' '[:upper:]'` give the same result for ASCII. Under `LANG=de_DE.UTF-8` and input `ä`, do they still agree? Explain what GNU `tr` actually operates on.
- **Q3.5** Write the shortest correct CRLF→LF conversion of `dos.txt` in place, using a tool from this objective, and explain why `sed -i 's/\r//' dos.txt` is a portability trap.

---

## Block 4 — `sort`: keys, collation, stability

`sort` is the highest-leverage and most misunderstood filter in the objective. It is an external merge sort: it fills an in-memory buffer, spills sorted runs to `$TMPDIR`, and merges them — which is why it sorts inputs larger than RAM but fails when `/tmp` is small.

1. Default sort is a full-line lexicographic comparison under the current locale:

   ```bash
   tail -n +2 employees.txt | sort | head -n 3
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1002:kim:dev:61000:2021-07-01
   1003:novak:qa:49000:2019-08-05
   ```

2. Restrict the comparison to a key. `-k4,4n` means "from the start of field 4 to the end of field 4, numeric". The `,4` terminator is not optional decoration — omitting it makes the key run to end of line:

   ```bash
   tail -n +2 employees.txt | sort -t: -k4,4n
   ```

   ```
   1009:alvarez:ops:47500:2018-11-30
   1003:novak:qa:49000:2019-08-05
   1007:mora:ops:52000:2019-03-14
   1008:haddad:ops:52000:2023-01-12
   1004:tanaka:qa:55000:2020-02-17
   1002:kim:dev:61000:2021-07-01
   1006:silva:dev:61000:2022-09-23
   1005:iversen:dev:68000:2016-04-28
   1001:okoye:dev:73000:2017-05-09
   ```

3. Demonstrate the consequence of an unterminated key:

   ```bash
   tail -n +2 employees.txt | sort -t: -k4n | head -n 3
   ```

   The key is now `52000:2019-03-14`; leading-numeric parsing stops at the `:`, so ties are broken by the rest of the *numeric* prefix only, and the ordering of the 52000/61000 pairs becomes an accident of the trailing text rather than a stated intention.

4. Now the stability trap. Compare these two:

   ```bash
   tail -n +2 employees.txt | sort -t: -k4,4nr
   tail -n +2 employees.txt | sort -t: -k4,4nr -s
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1005:iversen:dev:68000:2016-04-28
   1006:silva:dev:61000:2022-09-23
   1002:kim:dev:61000:2021-07-01
   1004:tanaka:qa:55000:2020-02-17
   1008:haddad:ops:52000:2023-01-12
   1007:mora:ops:52000:2019-03-14
   1003:novak:qa:49000:2019-08-05
   1009:alvarez:ops:47500:2018-11-30
   ```
   ```
   1001:okoye:dev:73000:2017-05-09
   1005:iversen:dev:68000:2016-04-28
   1002:kim:dev:61000:2021-07-01
   1006:silva:dev:61000:2022-09-23
   1004:tanaka:qa:55000:2020-02-17
   1007:mora:ops:52000:2019-03-14
   1008:haddad:ops:52000:2023-01-12
   1003:novak:qa:49000:2019-08-05
   1009:alvarez:ops:47500:2018-11-30
   ```

   The tied pairs swap. The coreutils manual states it exactly: when all keys compare equal, `sort` falls back to comparing entire lines *"as if no ordering options other than `--reverse` (`-r`) were specified"*. `-r` therefore reverses the tiebreaker too. `-s` (`--stable`) disables the fallback and preserves input order.

5. Multi-key sorts: department ascending, then salary descending. Note that `r` here is a **per-key** modifier, not the global `-r`:

   ```bash
   tail -n +2 employees.txt | sort -t: -k3,3 -k4,4nr
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1005:iversen:dev:68000:2016-04-28
   1002:kim:dev:61000:2021-07-01
   1006:silva:dev:61000:2022-09-23
   1007:mora:ops:52000:2019-03-14
   1008:haddad:ops:52000:2023-01-12
   1009:alvarez:ops:47500:2018-11-30
   1004:tanaka:qa:55000:2020-02-17
   1003:novak:qa:49000:2019-08-05
   ```

6. Locale collation changes the answer, not just the presentation:

   ```bash
   printf 'b\nA\na\nB\n' > case.txt
   LC_ALL=C sort case.txt | paste -sd' '
   LC_ALL=en_US.UTF-8 sort case.txt | paste -sd' '
   ```

   ```
   A B a b
   ```
   ```
   a A b B
   ```

   For any pipeline whose output is compared, checksummed, diffed or fed to `uniq`, pin `LC_ALL=C`. It is also the fastest path — no collation table lookups.

7. The specialised comparison modes, each with a distinct failure domain:

   ```bash
   printf '10\n9\n1000\n' | sort -n     | paste -sd' '   # numeric
   printf '1K\n1G\n1M\n'   | sort -h     | paste -sd' '   # human-readable suffixes
   printf 'v1.10\nv1.9\nv1.2\n' | sort -V | paste -sd' '  # version strings
   printf '0.1\n0.09\n0.11\n' | sort -g  | paste -sd' '   # general numeric (floats/exponents)
   ```

   ```
   9 10 1000
   ```
   ```
   1K 1M 1G
   ```
   ```
   v1.2 v1.9 v1.10
   ```
   ```
   0.09 0.1 0.11
   ```

8. Deduplicate at sort time, check sortedness without sorting, and handle NUL-delimited records:

   ```bash
   tail -n +2 employees.txt | sort -t: -k3,3 -u | cut -d: -f3 | paste -sd' '
   sort -c employees.txt ; echo "exit=$?"
   ```

   ```
   dev ops qa
   ```
   ```
   sort: employees.txt:3: disorder: 1002:kim:dev:61000:2021-07-01
   exit=1
   ```

   `-c` is the cheap precondition check before a `join` or a `uniq`; `-C` is the same test silently, via exit status only. `-z` switches to NUL-terminated records for filenames that may contain newlines.

**Questions**

- **Q4.1** Explain, in terms of the coreutils last-resort comparison rule, why `sort -k4,4nr` and `sort -k4,4nr -s` produced different orderings for the two 61000 rows.
- **Q4.2** `sort -k2` and `sort -k2,2` are different commands. Give a concrete two-line input where they produce different output.
- **Q4.3** A nightly job does `sort data.txt > data.sorted` and compares the SHA-256 against yesterday's. It started failing after a base-image upgrade, with identical input. Give the most likely cause and the one-token fix.
- **Q4.4** Why does `sort -n` on `1K 1M 1G` produce a useless ordering, and which flag is correct? What does `sort -n` actually do with the `K`?
- **Q4.5** `sort` on a 200 GB file dies with `sort: write failed: /tmp/sortXXXX: No space left on device`. Name two flags that address this without adding disk.
- **Q4.6** Why is `sort -u` not always interchangeable with `sort | uniq`? Consider `sort -k3,3 -u`.

---

## Block 5 — `uniq`: adjacency, counting, field skipping

`uniq` compares **adjacent** lines only. This is not a limitation to work around; it is what makes `uniq` O(1) in memory and able to process an infinite stream.

1. Demonstrate the adjacency rule directly:

   ```bash
   cut -d' ' -f4 access.log | uniq -c
   ```

   ```
         1 /index.html
         1 /style.css
         1 /admin
         3 /login
         1 /index.html
         1 /admin
         1 /favicon.ico
         1 /index.html
   ```

   `/index.html` appears three times in the file but never twice in a row, so it is counted three separate times.

2. The canonical `sort | uniq -c | sort -rn` frequency idiom:

   ```bash
   cut -d' ' -f6 access.log | sort | uniq -c | sort -rn
   ```

   ```
         5 10.0.0.9
         3 10.0.0.4
         2 10.0.0.7
   ```

   The count field is printed with `%7lu ` — a fixed seven-column right-justified number followed by one space. The trailing `sort -rn` works because numeric sort skips leading blanks.

3. Select duplicates only (`-d`), unique-only (`-u`), and every copy of every repeated line (`-D`):

   ```bash
   cut -d' ' -f3,4 access.log | sort | uniq -cd
   cut -d' ' -f3,4 access.log | sort | uniq -u
   ```

   ```
         2 GET /admin
         3 GET /index.html
         3 POST /login
   ```
   ```
   GET /favicon.ico
   GET /style.css
   ```

4. Group all copies with blank-line separators — useful when you must see the differing tail of near-duplicate records:

   ```bash
   cut -d' ' -f3,4 access.log | sort | uniq --all-repeated=separate
   ```

   ```
   GET /admin
   GET /admin

   GET /index.html
   GET /index.html
   GET /index.html

   POST /login
   POST /login
   POST /login
   ```

5. Compare only part of each line. `-f N` skips the first N **fields** (whitespace-delimited, non-configurable), `-s N` skips N **characters** after that, `-w N` limits the comparison to N characters:

   ```bash
   uniq -f 2 -c access.log
   ```

   ```
         1 2026-08-20 10:11:02 GET /index.html 200 10.0.0.4
         1 2026-08-20 10:11:07 GET /style.css 200 10.0.0.4
         1 2026-08-20 10:12:44 GET /admin 403 10.0.0.9
         3 2026-08-20 10:13:01 POST /login 401 10.0.0.9
         1 2026-08-20 10:14:20 GET /index.html 200 10.0.0.7
         1 2026-08-20 10:15:00 GET /admin 403 10.0.0.9
         1 2026-08-20 10:16:31 GET /favicon.ico 404 10.0.0.7
         1 2026-08-20 10:17:02 GET /index.html 200 10.0.0.4
   ```

   The three identical `POST /login 401` lines collapsed even though their timestamps differ, because fields 1 and 2 were excluded from the comparison. The **first** line of each group is the one printed.

6. Same idea by character prefix — collapse a log by the hour, ignoring minutes:

   ```bash
   cut -c1-13 access.log | uniq -c
   ```

   ```
        10 2026-08-20 10
   ```

7. Case-insensitive comparison and NUL-delimited input:

   ```bash
   printf 'Error\nERROR\nerror\nwarn\n' | uniq -ci
   ```

   ```
         3 Error
         1 warn
   ```

**Questions**

- **Q5.1** In step 5, the three `POST /login` lines collapsed into one whose timestamp is `10:13:01`. Which of the three timestamps is that, and what is the general rule?
- **Q5.2** Why must `sort` precede `uniq` in the frequency idiom, and give one realistic case where you deliberately *omit* the sort.
- **Q5.3** `uniq -f` counts fields as runs of blanks. Your data is colon-delimited. What is the standard workaround using only tools from this objective?
- **Q5.4** `sort -u` and `sort | uniq` are equivalent here. Rewrite the "count occurrences" pipeline to use `sort -u` and explain why it cannot work.
- **Q5.5** You are deduplicating a 400 GB log stream arriving on stdin, where duplicates are *not* adjacent. Explain why `sort | uniq` is the wrong architecture and what property of the data you would need to make `uniq` alone viable.

---

## Block 6 — `sed`: the stream editor as a filter

Within 103.2 `sed` is a filter, not a scripting language. Focus on addresses, `s///`, `d`, `p` with `-n`, and `-i`.

1. Substitution replaces the **first** match per line unless `g` is given. Note the metacharacter trap — an unescaped `.` matches any character:

   ```bash
   sed 's/old.example.com/new.example.com/' config.conf | sed -n '3p'
   sed 's/old\.example\.com/new.example.com/' config.conf | sed -n '3p'
   ```

   Both print `ServerName new.example.com` here, but only the second is correct — the first would also rewrite `oldXexampleYcom`.

2. Occurrence selectors: `N` for the Nth match, `Ng` for the Nth onward, `g` for all:

   ```bash
   echo 'a:b:c:d' | sed 's/:/-/'
   echo 'a:b:c:d' | sed 's/:/-/2'
   echo 'a:b:c:d' | sed 's/:/-/2g'
   echo 'a:b:c:d' | sed 's/:/-/g'
   ```

   ```
   a-b:c:d
   a:b-c:d
   a:b-c-d
   a-b-c-d
   ```

3. Any character may be the delimiter. Use it whenever the pattern contains slashes:

   ```bash
   sed 's|/var/www/html|/srv/www|' config.conf | sed -n '4p'
   ```

   ```
   DocumentRoot /srv/www
   ```

4. `&` is the whole match; `\1`…`\9` are capture groups. BRE requires `\(` `\)`; `-E` switches to ERE:

   ```bash
   sed -n 's/^\(LogLevel\) warn$/\1 debug/p' config.conf
   sed -E -n 's/^(Listen) ([0-9]+)$/\1 \2 # was \2/p' config.conf
   sed -n 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/[&]/p' employees.txt | head -n 1
   ```

   ```
   LogLevel debug
   ```
   ```
   Listen 80 # was 80
   ```
   ```
   1007:mora:ops:52000:[2019-03-14]
   ```

5. `-n` plus `p` turns `sed` into a selector. Line addresses, regex addresses, ranges, last line, and step addresses *(GNU)*:

   ```bash
   sed -n '2,4p' config.conf
   sed -n '/^Listen/p' config.conf
   sed -n '$p' config.conf
   sed -n '$=' config.conf
   sed -n '0~3p' employees.txt | cut -d: -f2
   ```

   ```
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   ```
   ```
   Listen 80
   ```
   ```
   LogLevel warn
   ```
   ```
   6
   ```
   ```
   kim
   silva
   iversen
   ```

6. Deletion, negation, and early exit. `q` after the range makes `sed` stop reading — the difference between scanning 6 lines and scanning 60 million:

   ```bash
   sed '/^#/d' config.conf
   sed -n '/^#/!p' config.conf
   sed -n '2,4{p}; 4q' employees.txt | cut -d: -f2
   ```

   ```
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   LogLevel warn
   ```
   ```
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   LogLevel warn
   ```
   ```
   mora
   kim
   alvarez
   ```

7. Combine expressions with `-e`, or a semicolon-separated script:

   ```bash
   sed -e '/^#/d' -e 's/warn/debug/' config.conf | tail -n 1
   sed '/^#/d; s/warn/debug/' config.conf | tail -n 1
   ```

   ```
   LogLevel debug
   ```

8. In-place editing with a backup suffix. `-i` is not atomic in the "safe" sense — `sed` writes a temp file and renames, so ownership and SELinux context can change. Always take the `.bak`:

   ```bash
   cp config.conf config.orig
   sed -i.bak 's/^LogLevel warn$/LogLevel debug/' config.conf
   diff config.conf.bak config.conf
   ```

   ```
   6c6
   < LogLevel warn
   ---
   > LogLevel debug
   ```

9. `y` transliterates like `tr`, and `l` is `sed`'s own `cat -A`:

   ```bash
   echo 'abc' | sed 'y/abc/xyz/'
   printf 'a\tb\n' | sed -n l
   ```

   ```
   xyz
   ```
   ```
   a\tb$
   ```

**Questions**

- **Q6.1** `sed 's/8080/80/' config.conf` changes the commented-out line. Write an address-constrained version that only edits lines not starting with `#`.
- **Q6.2** What is the difference between `sed '/^#/d'` and `sed -n '/^#/!p'`? Is there any input for which they differ?
- **Q6.3** `sed -n '5000000p' huge.log` and `sed -n '5000000{p;q}' huge.log` return the same line. Explain the runtime difference and estimate it for a 60 M-line file.
- **Q6.4** `sed -i` on a file inside a bind-mounted container volume sometimes fails with `Device or resource busy`. Explain the mechanism in terms of what `-i` actually does to the inode.
- **Q6.5** You must replace `/etc/nginx/conf.d` with `/opt/nginx/conf.d`. Write the `s` command twice — once with `/` as delimiter and once with `|` — and say which you would put in a playbook.

---

## Block 7 — `join`: relational merge on a common key

`join` is a merge join, not a hash join: both inputs **must** be sorted on the join field under the same collation, and it holds only one group in memory. That is why it scales to files larger than RAM and why it silently produces wrong output on unsorted input.

1. Baseline inner join on field 1, colon-delimited:

   ```bash
   join -t: dept-owner.txt dept-budget.txt
   ```

   ```
   dev:okoye:250000
   ops:mora:180000
   qa:tanaka:120000
   ```

   The join field is emitted once, first — the default output format is `0,1.2,1.3,…,2.2,2.3,…`.

2. Show the silent-failure mode. Break the sort order of one file:

   ```bash
   printf 'qa:tanaka\ndev:okoye\nops:mora\n' > unsorted-owner.txt
   join -t: unsorted-owner.txt dept-budget.txt
   ```

   ```
   join: unsorted-owner.txt:2: is not sorted: dev:okoye
   qa:tanaka:120000
   ```

   `join` warns but keeps going, and `dev` and `ops` are lost. In a script, this must be a hard failure — always `sort` the inputs, or precede the join with `sort -C`.

3. The correct defensive form, using process substitution:

   ```bash
   join -t: \
     <(sort -t: -k1,1 unsorted-owner.txt) \
     <(sort -t: -k1,1 dept-budget.txt)
   ```

   ```
   dev:okoye:250000
   ops:mora:180000
   qa:tanaka:120000
   ```

4. Outer joins: `-a N` emits unpairable lines from file N, `-e` supplies a filler, `-o` names the output fields (`0` = join field, `N.M` = field M of file N):

   ```bash
   join -t: -a 2 -e MISSING -o 0,1.2,2.2 dept-owner.txt dept-budget.txt
   ```

   ```
   dev:okoye:250000
   ops:mora:180000
   qa:tanaka:120000
   sec:MISSING:95000
   ```

5. Anti-join — find keys present in one file only. `-v N` is the complement of `-a N`:

   ```bash
   join -t: -v 2 -o 0,2.2 dept-owner.txt dept-budget.txt
   ```

   ```
   sec:95000
   ```

6. Join on a non-first field. `-1` and `-2` select the join field per file:

   ```bash
   sort -t: -k3,3 <(tail -n +2 employees.txt) > emp-by-dept.txt
   join -t: -1 3 -2 1 -o 1.2,1.4,2.2 emp-by-dept.txt dept-budget.txt
   ```

   ```
   okoye:73000:250000
   kim:61000:250000
   silva:61000:250000
   iversen:68000:250000
   mora:52000:180000
   alvarez:47500:180000
   haddad:52000:180000
   tanaka:55000:120000
   novak:49000:120000
   ```

   (Line order within a department follows the stable `sort -k3,3`, i.e. original file order.)

7. Case and collation must match between the sort and the join:

   ```bash
   join -t: --check-order <(sort -t: -k1,1 dept-owner.txt) <(LC_ALL=C sort -t: -k1,1 dept-budget.txt) >/dev/null; echo "exit=$?"
   ```

   Mixed-locale sorts are the most common real-world cause of a join that "loses rows in production but works on my laptop".

**Questions**

- **Q7.1** `join` printed a warning *and* exit status 0 in step 2 on some coreutils versions. Why is that dangerous in a `set -e` script, and what flag makes the disorder fatal?
- **Q7.2** Both inputs are sorted with `sort` under `en_US.UTF-8`, but `join` still drops rows. Give the two most likely causes.
- **Q7.3** Explain the `-o` field spec `0,1.2,2.2` field by field, and say what `-e` does when `-o` is *absent*.
- **Q7.4** Write the command that lists departments in `dept-owner.txt` with no budget entry.
- **Q7.5** Why does `join` scale to inputs larger than memory while a naive in-memory lookup does not? Name the algorithm class and its precondition.

---

## Block 8 — `split`, `wc`, and the checksum family

1. Counting modes. `wc` reports lines/words/bytes by default; `-m` counts characters, `-L` the longest line length:

   ```bash
   wc employees.txt
   wc -L employees.txt
   wc -l < employees.txt
   ```

   ```
    10  10 315 employees.txt
   ```
   ```
   33 employees.txt
   ```
   ```
   10
   ```

   (GNU `wc` sizes its columns from the file, so padding widths vary; the numbers do not.) Word count is 10 because the records contain no whitespace — each line is one "word". Use `wc -l < file` when the filename in the output would break downstream parsing.

2. Split by line count, with zero-padded numeric suffixes and a real extension:

   ```bash
   seq 1 100 > numbers.txt
   split -l 30 -d --additional-suffix=.part numbers.txt chunk_
   wc -l chunk_*.part
   ```

   ```
    30 chunk_00.part
    30 chunk_01.part
    30 chunk_02.part
    10 chunk_03.part
   100 total
   ```

3. Split by size and by count. `-n l/N` splits into N files **on line boundaries**; plain `-n N` splits by byte size and will cut a line in half; `-n r/N` distributes round-robin:

   ```bash
   rm -f chunk_*.part
   split -n l/3 -d numbers.txt lines_
   wc -l lines_*
   split -b 100 -d numbers.txt bytes_
   head -c 40 bytes_01 | od -c | head -n 2
   ```

   ```
    34 lines_00
    33 lines_01
    33 lines_02
   100 total
   ```

4. Verify a round trip with a cryptographic checksum. This is the production pattern for chunked transfers:

   ```bash
   sha256sum numbers.txt > numbers.sha256
   cat lines_0* > rebuilt.txt
   sed 's/  numbers\.txt$/  rebuilt.txt/' numbers.sha256 | sha256sum -c
   ```

   ```
   rebuilt.txt: OK
   ```

5. Understand the checksum file format. Two spaces separate hash from filename in text mode; a space plus `*` marks binary mode:

   ```bash
   sha256sum numbers.txt
   sha256sum -b numbers.txt
   md5sum numbers.txt
   ```

   ```
   d8f... (64 hex chars)  numbers.txt
   ```
   ```
   d8f... (64 hex chars) *numbers.txt
   ```
   ```
   ... (32 hex chars)  numbers.txt
   ```

   Hash lengths are fixed and are the fastest way to identify an unlabelled digest: 32 hex chars = MD5, 64 = SHA-256, 128 = SHA-512.

6. Verification modes and their exit statuses:

   ```bash
   sha256sum -c --quiet numbers.sha256; echo "exit=$?"
   echo "corrupt" >> numbers.txt
   sha256sum -c --status numbers.sha256; echo "exit=$?"
   sed -i '$d' numbers.txt
   ```

   ```
   exit=0
   ```
   ```
   exit=1
   ```

   `--quiet` suppresses `OK` lines but still reports failures; `--status` suppresses all output and communicates only through the exit status — the correct form inside a conditional.

7. Checksums read stdin, which makes them composable with any filter:

   ```bash
   tail -n +2 employees.txt | sort | sha256sum
   tail -n +2 employees.txt | LC_ALL=C sort | sha256sum
   ```

   Two different digests are possible from the same input, for the reason established in Block 4.

**Questions**

- **Q8.1** `wc employees.txt` reported 10 words for 10 lines. Explain, and predict `wc -w access.log`.
- **Q8.2** `split -n 3 file` and `split -n l/3 file` differ. For a line-oriented log, which is correct and what precisely goes wrong with the other?
- **Q8.3** You split a file into 250 chunks with `split -d`. `cat x* > rebuilt` produces a corrupt file. Name the mechanism and the flag that prevents it.
- **Q8.4** Both `md5sum` and `sha256sum` detect accidental corruption. State the one threat model where `md5sum` is unacceptable and `sha256sum` is not.
- **Q8.5** Why does `sha256sum -c --status` belong in an `if` statement while `sha256sum -c` belongs in an interactive terminal?
- **Q8.6** Two teams checksum "the same" sorted file and get different digests. Give the single most likely cause and the fix.

---

## Block 9 — Compressed streams: `zcat`, `bzcat`, `xzcat`

These are not "unzip then read"; they are **stream** decompressors that write to stdout and never touch the source file. That is what makes early-exit pipelines cheap.

1. Produce the three archive formats, keeping the originals:

   ```bash
   gzip  -k -f numbers.txt
   bzip2 -k -f numbers.txt
   xz    -k -f numbers.txt
   ls -l numbers.txt*
   ```

   `-k` (`--keep`) requires gzip ≥ 1.6; on older systems use `gzip -c numbers.txt > numbers.txt.gz`.

2. Read each without materialising a temp file:

   ```bash
   zcat  numbers.txt.gz  | tail -n 3 | paste -sd' '
   bzcat numbers.txt.bz2 | wc -l
   xzcat numbers.txt.xz  | head -n 2 | paste -sd' '
   ```

   ```
   98 99 100
   ```
   ```
   100
   ```
   ```
   1 2
   ```

3. Confirm the early-exit property. Decompression stops as soon as `head` closes the pipe:

   ```bash
   seq 1 20000000 | gzip > big.gz
   time zcat big.gz | head -n 5
   time zcat big.gz > /dev/null
   ```

   The first completes in milliseconds; the second decompresses the whole archive. `head` exits, the write end of the pipe breaks, `zcat` receives `SIGPIPE` and dies.

4. `zcat -f` passes non-gzip input through unchanged, which lets one pipeline handle mixed inputs:

   ```bash
   zcat -f numbers.txt numbers.txt.gz | wc -l
   ```

   ```
   200
   ```

5. Full stack over a compressed log — the pattern you will actually run in production:

   ```bash
   gzip -c access.log > access.log.gz
   zcat access.log.gz | sed -n '/ 40[13] /p' | cut -d' ' -f6 | sort | uniq -c | sort -rn
   ```

   ```
         5 10.0.0.9
   ```

6. Know the companions: `zless`, `zgrep`, `zdiff`, `bzless`, `xzless`. And know the identification tools — the extension can lie:

   ```bash
   file numbers.txt.gz numbers.txt.bz2 numbers.txt.xz
   ```

   ```
   numbers.txt.gz:  gzip compressed data, was "numbers.txt", ...
   numbers.txt.bz2: bzip2 compressed data, block size = 900k
   numbers.txt.xz:  XZ compressed data, checksum CRC64
   ```

**Questions**

- **Q9.1** `zcat huge.gz | head -n 5` returns instantly on a 40 GB archive while `gunzip huge.gz && head -n 5 huge` takes minutes. Explain the two distinct reasons.
- **Q9.2** Why can `zcat` seek to line 5 cheaply but not to line 5,000,000 cheaply? What property of the DEFLATE stream forces this?
- **Q9.3** A log-shipping script fails on hosts where `bzip2` is not installed but works elsewhere. Which utility in this objective is *not* part of coreutils, and what does that imply for minimal container images?
- **Q9.4** Give the one-liner that counts total lines across `app.log`, `app.log.1` and `app.log.2.gz` in a single pass.
- **Q9.5** `zcat file.Z` works on some systems and fails on others. What is `.Z`, and what does that tell you about `zcat`'s implementation?

---

## Block 10 — `pr`, `less`, whitespace filters, and pipeline diagnostics

1. `pr` paginates for printing. `-t` omits headers and trailers, `-n` numbers lines (5 digits + TAB by default), `-w` sets page width:

   ```bash
   pr -t -n -w 40 employees.txt | head -n 3
   ```

   ```
       1	id:name:dept:salary:hired
       2	1007:mora:ops:52000:2019-03-14
       3	1002:kim:dev:61000:2021-07-01
   ```

2. `pr -m` merges files side by side into columns — the only tool in the objective that does this:

   ```bash
   pr -m -t -w 40 dept-owner.txt dept-budget.txt
   ```

   ```
   dev:okoye           dev:250000
   ops:mora            ops:180000
   qa:tanaka           qa:120000
                       sec:95000
   ```

   (Column padding is derived from `-w` divided by the column count; adjust `-w` and re-run to see it move.)

3. `pr -N` reflows a single file into N columns down-then-across:

   ```bash
   seq 1 12 | pr -4 -t -w 40
   ```

   ```
   1		4		7		10
   2		5		8		11
   3		6		9		12
   ```

4. Whitespace normalisation. `expand` converts tabs to spaces; `unexpand -a` converts runs of spaces back to tabs; without `-a` it only touches leading whitespace:

   ```bash
   expand -t 4 tabs.txt | cat -A
   expand tabs.txt | cat -A
   expand -t 4 tabs.txt | unexpand -a -t 4 | cat -A
   ```

   ```
   a   b   c$
   ```
   ```
   a       b       c$
   ```
   ```
   a^Ib^Ic$
   ```

5. `fmt` reflows prose to a target width. It is not a greedy wrapper — it optimises line breaks across the paragraph, so verify rather than predict:

   ```bash
   cat > notes.txt <<'EOF'
   The sort utility reads lines, compares them with the current locale
   collation, and writes them in order. It buffers in memory and spills to
   temporary files when the input exceeds the buffer, which is why it can
   sort inputs larger than RAM.
   EOF
   fmt -w 40 notes.txt | wc -L
   fmt -w 40 -s notes.txt | head -n 3
   ```

   `wc -L` must report a value ≤ 40. `-s` splits long lines but never joins short ones — the right choice for reflowing code comments without merging paragraphs.

6. `less` — interactive, but a filter's most important consumer. Run `less employees.txt` and exercise:

   | Key | Effect |
   |---|---|
   | `space` / `b` | page forward / back |
   | `g` / `G` | first line / last line |
   | `/ops` then `n` / `N` | search forward, next / previous match |
   | `?ops` | search backward |
   | `-N` `Enter` | toggle line numbers |
   | `-S` `Enter` | toggle line chopping instead of wrapping |
   | `&dev` `Enter` | show **only** matching lines; `&` `Enter` clears the filter |
   | `F` | follow mode, like `tail -f`; `Ctrl-C` returns to normal |
   | `=` | current position and file stats |
   | `q` | quit |

   Then compare live-follow behaviour:

   ```bash
   less +F /var/log/syslog      # or /var/log/messages
   ```

7. **SIGPIPE and pipeline exit status.** This is the diagnostic skill that separates a working pipeline from a correct one:

   ```bash
   seq 1 1000000 | head -n 5 > /dev/null
   echo "${PIPESTATUS[@]}"
   ```

   ```
   141 0
   ```

   141 = 128 + 13 = killed by `SIGPIPE`. That is normal and expected. Now:

   ```bash
   set -o pipefail
   seq 1 1000000 | head -n 5 > /dev/null; echo "exit=$?"
   set +o pipefail
   ```

   ```
   exit=141
   ```

   `pipefail` turns a healthy early exit into a script failure. Under `set -euo pipefail`, any pipeline ending in `head` is a latent bug.

8. **Buffering.** libc uses line buffering to a TTY and 4 KB block buffering to a pipe. A long pipeline therefore appears to hang:

   ```bash
   tail -f /tmp/live.log | cut -d' ' -f2 | tr 'a-z' 'A-Z'
   ```

   Fix it by forcing line buffering on the intermediate stages:

   ```bash
   tail -f /tmp/live.log | stdbuf -oL cut -d' ' -f2 | stdbuf -oL tr 'a-z' 'A-Z'
   ```

   `sed` has `-u` (`--unbuffered`) built in; `grep` has `--line-buffered`.

9. **`tee`** forks a stream so you can inspect an intermediate stage without rerunning:

   ```bash
   tail -n +2 employees.txt \
     | tee /tmp/stage1.txt \
     | cut -d: -f3 \
     | tee /tmp/stage2.txt \
     | sort | uniq -c
   wc -l /tmp/stage1.txt /tmp/stage2.txt
   ```

   ```
         4 dev
         3 ops
         2 qa
   ```
   ```
    9 /tmp/stage1.txt
    9 /tmp/stage2.txt
   18 total
   ```

**Questions**

- **Q10.1** `echo "${PIPESTATUS[@]}"` printed `141 0`. Decode 141 and say whether this pipeline succeeded.
- **Q10.2** Your CI runs `set -euo pipefail`. A step doing `zcat huge.gz | head -n 100 > sample.txt` fails intermittently. Diagnose it and give two different fixes.
- **Q10.3** `tail -f app.log | cut -d' ' -f5` prints nothing for minutes, then a burst. Name the mechanism, the buffer size involved, and the fix.
- **Q10.4** `expand` and `unexpand -a` are described as inverses. Give a concrete input where `unexpand -a -t 4 | expand -t 4` does **not** return the original.
- **Q10.5** In `less`, what does `&pattern` do that `/pattern` does not, and why does that matter on a 2 GB log?
- **Q10.6** Why is `less` preferable to `more` for a file being actively written, and why is `less +F` preferable to `tail -f` when you need to scroll back?

---

## Capstone — three production pipelines

Solve each using only utilities from this objective. No `awk`, no `grep`, no `perl`.

1. **Headcount per department, formatted as `dept:count`, most-staffed first.**

   ```bash
   tail -n +2 employees.txt \
     | cut -d: -f3 \
     | sort \
     | uniq -c \
     | sort -rn \
     | sed 's/^ *\([0-9][0-9]*\) \(.*\)$/\2:\1/'
   ```

   ```
   dev:4
   ops:3
   qa:2
   ```

2. **Top earner per department, one record per department.**

   ```bash
   tail -n +2 employees.txt \
     | sort -t: -k3,3 -k4,4nr \
     | sort -t: -k3,3 -u
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1007:mora:ops:52000:2019-03-14
   1004:tanaka:qa:55000:2020-02-17
   ```

3. **Client IPs with three or more authentication failures (HTTP 401/403), from the gzipped log.**

   ```bash
   zcat access.log.gz \
     | sed -n '/ 40[13] /p' \
     | cut -d' ' -f6 \
     | sort \
     | uniq -c \
     | sed -n 's/^ *\([3-9][0-9]*\|[0-9]\{2,\}\) \(.*\)$/\2 (\1 failures)/p'
   ```

   ```
   10.0.0.9 (5 failures)
   ```

**Questions**

- **QC.1** In capstone 2, why does the second `sort -t: -k3,3 -u` keep the *highest-paid* row of each department rather than an arbitrary one? Which property of GNU `sort` is load-bearing, and what would break the pipeline?
- **QC.2** Capstone 2 produces a deterministic result for `ops` even though `mora` and `haddad` both earn 52000. Trace the tiebreak.
- **QC.3** Rewrite capstone 1 so the output is `count dept` separated by a single space, without `sed`.
- **QC.4** Capstone 3's threshold logic lives in a regex. State the fragility this introduces and describe a `sort`-based approach that does not encode the threshold in a pattern.
- **QC.5** Add `LC_ALL=C` to all three capstones. For which one does it change the output, and why?

---

## Cleanup

```bash
cd ~ && rm -rf ~/lpic1-103.2 /tmp/live.log /tmp/live.log.1 /tmp/stage1.txt /tmp/stage2.txt
```

---

<details>
<summary><strong>Answers</strong></summary>

### Block 0

**A0.1** — Any filter that treats every line as data: `sort` (the header sorts into the middle or, with `-k4,4n`, to the top because `salary` parses as numeric 0), `uniq -c` (counts a phantom record), `wc -l` (off by one), and `join` (the header is an unmatched key). The standard fix is `tail -n +2 file`, which starts output at line 2. A shorter idiom for the same job is `sed 1d file`.

**A0.2** — `wc -l` counts newline characters, so a file whose last line lacks a trailing newline reports one less than the visible line count. Prove it with `tail -c 1 file | od -c` — if the last byte is not `\n`, the output shows the character rather than `\n`. `cat -A file | tail -n 1` is equally conclusive: a final line with no `$` at the end is unterminated.

### Block 1

**A1.1** — Three lines × (5 or 4 or 5 content bytes + `\r` + `\n`): `alpha`(5)+2 = 7, `beta`(4)+2 = 6, `gamma`(5)+2 = 7 → 20 bytes. `wc -l` counts only the three `\n` bytes; the three `\r` bytes are ordinary data that inflate `-c` without affecting `-l`.

**A1.2** — Send `0d`. `\r` is `od`'s *rendering* of byte 0x0D, and the same two-character sequence `\` `r` could also be a literal backslash followed by `r` in the source data — `od -c` prints a literal backslash as `\\`, but readers routinely miss that. The hex form is unambiguous by construction: one byte, one two-digit value. `od -A d -t x1z` is the best of both — hex bytes plus an ASCII gutter for orientation.

**A1.3** — The locale, specifically `LC_ALL`/`LC_CTYPE`/`LANG`. Under a UTF-8 `LC_CTYPE`, `wc -m` decodes multibyte sequences and counts `ñ` as one character → 4. Under `LC_ALL=C` the character set is single-byte, so every byte is a character and `wc -m` equals `wc -c` → 5.

**A1.4** — `cat -n`. It numbers every line unconditionally, uses no leading zeros, and is present in BusyBox, while BusyBox `nl` is either absent or a stub. What you lose is `nl`'s formatting control: no `-w` width, no `-s` separator, no `-n rz`/`ln`, no `-b` body style, no logical page sections (`\:\:\:`) for header/body/footer numbering.

**A1.5** — Any of: an extra process plus an extra pipe means one additional full copy of all 4 GB through kernel pipe buffers (two context switches per 64 KB rather than one); `grep` loses the ability to `mmap`/seek the regular file and to report the filename; and `grep`'s own optimisations that depend on knowing the input size are disabled. The measurable one is throughput — the copy through the pipe is real CPU and real memory bandwidth.

### Block 2

**A2.1** — For a 10-line file, `tail -n 3` prints lines 8, 9, 10 (the last three). `tail -n +3` prints lines 3 through 10 (starting **at** line 3, eight lines).

**A2.2** — On a regular file `tail` can `lseek` to near the end and read backwards until it has found N newlines, touching only the tail of the file — O(N) memory, O(N) I/O regardless of file size. On a pipe there is no seek, so `tail` must read the entire stream and keep a rolling buffer of the last N lines in memory — O(total input) I/O and O(N lines × line length) memory. `tail -n 5` on a pipe is cheap; `tail -n 5000000` on a pipe can OOM.

**A2.3** — Use `-F`. With `-f`, `tail` keeps the open file descriptor, which follows the *inode*; after `mv app.log app.log.1`, that inode is now the rotated file, so you silently watch a file nothing writes to any more. `-F` (= `--follow=name --retry`) re-opens by path, notices the replacement, and reports `has become inaccessible` / `has appeared; following new file`.

**A2.4** — `head -c` counts bytes and will happily cut a multi-byte UTF-8 sequence in the middle, leaving a truncated sequence that renders as `�` or nothing at all, and that breaks any downstream consumer validating UTF-8. Safer alternatives: `head -n N` (line-oriented, always lands on a boundary) or `cut -c1-N` (character-oriented under a UTF-8 locale). If a hard byte cap is required, truncate with `head -c` then repair with `iconv -c -f UTF-8 -t UTF-8`.

**A2.5** — `head -n 45 huge.file | tail -n 6`. `head` stops reading after 45 lines and exits, sending `SIGPIPE` upstream, so only the first ~45 lines are ever read from disk — the remaining 90 GB is never touched. The reverse order, `tail -n +40 huge.file | head -n 6`, is correct but reads the whole file. Single-process equivalent with the same early exit: `sed -n '40,45p;45q' huge.file`.

### Block 3

**A3.1** — `cut -d: -f3,1` prints `username:uid` — `cut` sorts and deduplicates the field list and always emits fields in file order, so the request to reorder is ignored. Correct with `paste`:

```bash
paste -d' ' <(cut -d: -f3 /etc/passwd) <(cut -d: -f1 /etc/passwd)
```

**A3.2** — `ls -l` pads columns with *variable-length runs* of spaces to align them, so the Nth space-delimited field is not the Nth column; `access.log` uses exactly one space as a true delimiter, so field position and column position coincide. (Normalise `ls -l` first with `tr -s ' '`.)

**A3.3** — `tr -d '\n'` removes the final newline too, leaving output with no line terminator, so the shell prompt lands on the same line and the result is not a valid text file. `paste -sd ''` joins the lines into one record but still terminates that record with a newline.

**A3.4** — They can disagree. GNU `tr` is byte-oriented: it does not decode multibyte characters, so `[:lower:]`/`[:upper:]` expand to the single-byte members of those classes in the current locale, and `ä` (two bytes in UTF-8: `c3 a4`) is not mapped by either form. `tr 'a-z' 'A-Z'` additionally interprets `a-z` as an ASCII byte range, so it never touches non-ASCII. Neither form is a correct Unicode case-folder; use `sed 's/.*/\U&/'` *(GNU)* or a locale-aware tool for that.

**A3.5** — `tr -d '\r' < dos.txt > unix.txt && mv unix.txt dos.txt` (`tr` cannot edit in place because it only reads stdin and writes stdout — redirecting to the same file would truncate it before reading). `sed -i 's/\r//' dos.txt` is a trap because `\r` as an escape for CR inside a regex is a GNU extension: POSIX/BSD `sed` interprets `\r` as a literal `r` and would delete every letter `r` in the file. The portable `sed` form uses a literal CR: `sed -i "s/$(printf '\r')//" dos.txt`.

### Block 4

**A4.1** — With `-k4,4n`, the two 61000 rows have equal keys. Because `-s` was not given, GNU `sort` falls back to comparing the entire lines — and the manual specifies that this last-resort comparison behaves *"as if no ordering options other than `--reverse` were specified"*. `-r` was specified, so the fallback is reversed: `1006:silva…` sorts before `1002:kim…`. Adding `-s` disables the fallback entirely and the merge sort's stability preserves input order, so `kim` (2nd in the file) precedes `silva` (6th).

**A4.2** — `-k2` means "from the start of field 2 to end of line"; `-k2,2` means "field 2 only". Input:

```
b 2 z
b 2 a
```

`sort -k2,2` sees equal keys for both lines; `sort -k2` compares `2 z` against `2 a` and puts the `a` line first. Any file where field 2 ties but later fields differ will distinguish them.

**A4.3** — The base image changed the default locale (typically from `C`/`POSIX` to `C.UTF-8` or a glibc locale, or vice versa), so `sort` now uses a different collation and produces a different byte-for-byte ordering of the same lines. The fix is one token: `LC_ALL=C sort data.txt > data.sorted`. Pin the locale in every checksummed pipeline.

**A4.4** — `sort -n` parses a leading number and stops at the first non-numeric byte, so `1K`, `1M` and `1G` all compare as the number 1; the order among them then falls to the last-resort whole-line comparison, giving `1G 1K 1M`. The correct flag is `-h` (`--human-numeric-sort`), which understands the SI/IEC suffixes K, M, G, T, P, E, Z, Y. It exists precisely so that `du -h | sort -h` works.

**A4.5** — `-T DIR` (`--temporary-directory`) to spill somewhere with space, and `--compress-program=gzip` (or `zstd`) to compress the temporary runs. `-S SIZE` (`--buffer-size`) raising the in-memory buffer reduces the number of spilled runs and is the third lever. `--parallel=N` affects speed, not space.

**A4.6** — `sort -u` applies uniqueness to the **key**, not the whole line. `sort -k3,3 -u` keeps one line per distinct field 3 and discards the rest, which is a group-by, not a deduplication. `sort | uniq` always compares the full line. They coincide only when no `-k` is given. (Capstone 2 depends on exactly this difference.)

### Block 5

**A5.1** — `10:13:01`, the first of the three. `uniq` always emits the **first** line of each run of adjacent equal lines; the lines that were suppressed are simply discarded, so any field excluded from the comparison shows the first record's value. If you need the last, reverse the stream with `tac` first.

**A5.2** — `uniq` only collapses *adjacent* equal lines, so unless the input is already grouped, identical records scattered through the file are counted separately (step 1 demonstrates this). Deliberate omission: when the input is a **sorted or naturally grouped** stream — a sorted log, `zcat`-ed time-ordered records, or output of a previous `sort` — sorting again is wasted work; and when the stream is unbounded (`tail -f`), `sort` cannot be used at all because it must see EOF, so `uniq` alone on adjacent duplicates is the only option.

**A5.3** — `uniq -f` is hard-wired to blank-delimited fields with no `-t` equivalent. Translate the delimiter into a blank, run `uniq`, and translate back: `tr ':' ' ' < file | uniq -f 2 | tr ' ' ':'`. This is safe only when the data contains no spaces — otherwise pre-extract the comparison key with `cut` and rejoin with `paste`.

**A5.4** — `sort -u` discards duplicates during the sort, so by the time `uniq -c` runs there is exactly one copy of each line and every count is 1:

```bash
cut -d' ' -f6 access.log | sort -u | uniq -c
```
```
      1 10.0.0.4
      1 10.0.0.7
      1 10.0.0.9
```

Counting requires the duplicates to survive into `uniq`; the deduplication must be `uniq`'s job, not `sort`'s.

**A5.5** — `sort` must buffer the entire input (spilling to `$TMPDIR`) before it can emit its first line, so it needs ~400 GB of scratch space and adds unbounded latency — fatal for a streaming pipeline. `uniq` alone becomes viable only if duplicates are guaranteed **adjacent** in the stream — e.g. the producer emits records grouped by key, or duplicates are retransmissions that arrive back-to-back within a bounded window. Otherwise the correct architecture is a bounded-memory probabilistic filter or a keyed store, not a coreutils pipeline.

### Block 6

**A6.1** — Address the substitution to lines that do not begin with `#`:

```bash
sed '/^#/! s/8080/80/' config.conf
```

The `!` negates the preceding address, so `s` runs only on non-comment lines. (Note the space after `!` is optional in GNU sed but required by some implementations.)

**A6.2** — For the sample file they are identical: `d` deletes matching lines from the default output stream, `-n` plus `!p` prints only non-matching lines. They differ when the script has other output commands or when the input's last line is unterminated — and critically, `-n '/^#/!p'` will emit nothing at all if you forget `-n` is required, whereas `d` works with default output. They also differ under `-i` combined with additional print commands, where `-n` suppresses the implicit copy of every line. In practice: use `d` for "remove these", `-n …p` for "keep only these".

**A6.3** — Without `q`, `sed` reads and evaluates all 60 M lines even though the last 55 M produce no output — it has no way to know the address will not match again. With `{p;q}` it exits immediately after line 5,000,000, reading ~8% of the file. On a 60 M-line, multi-GB log the difference is roughly 12× less I/O and CPU — typically minutes versus seconds. `q` also propagates `SIGPIPE` upstream, so a `zcat` feeding it stops decompressing too.

**A6.4** — `sed -i` does not edit the file in place. It writes the result to a temporary file in the same directory and then `rename(2)`s it over the target. The rename allocates a **new inode**, so anything holding the old inode (a running process with the file open, a bind mount of the *file* rather than its directory, a hard link) keeps seeing the old content — and on a bind-mounted single file the kernel refuses the rename with `EBUSY`. The workaround is to write through the existing inode: `sed 's/…/…/' f > /tmp/f && cat /tmp/f > f`.

**A6.5** —

```bash
sed 's/\/etc\/nginx\/conf\.d/\/opt\/nginx\/conf.d/'
sed 's|/etc/nginx/conf\.d|/opt/nginx/conf.d|'
```

Put the second in the playbook. The escaped form is unreadable and each escaped slash is a place to introduce a typo that silently changes the pattern; the alternate delimiter eliminates the class of error entirely. Note that `.` still needs escaping in the *pattern* (not the replacement) in both forms.

### Block 7

**A7.1** — `join` reports disorder on stderr but, in the historical default, still exits 0 for the run — so `set -e` does not trigger and the script proceeds with a silently truncated result set, which is worse than a crash: the data looks plausible. `--check-order` makes an out-of-order input a fatal error with a non-zero exit. (`--nocheck-order` is the opposite and should never appear in production.) The robust pattern is to sort both inputs yourself inside process substitutions.

**A7.2** — (1) Different collations between the two sorts — one file sorted under `en_US.UTF-8` and the other under `C`, or one sorted before a locale change; glibc collation ignores punctuation and case in ways `join`'s byte comparison does not. (2) Trailing whitespace or a CR from a CRLF file attached to the join key, so `dev` and `dev\r` never match. Both are diagnosed with `join -t: --check-order` plus `cat -A` on the key column.

**A7.3** — `0` = the join field itself; `1.2` = field 2 of the first file; `2.2` = field 2 of the second file. Without `-o`, `-e` still applies but only to fields that `-a` caused to be unpairable — and with the default output format those fields are simply absent rather than filled, so `-e` is effectively inert unless `-o` names them explicitly. That is why `-a` and `-e` are almost always written together with `-o`.

**A7.4** —

```bash
join -t: -v 1 dept-owner.txt dept-budget.txt
```

For this data set the result is empty (every owner department has a budget). Adding a row such as `sre:patel` to `dept-owner.txt`, re-sorting, and rerunning yields `sre:patel`.

**A7.5** — `join` is a **sort-merge join**. Its precondition is that both inputs are sorted on the join key under the same collation; given that, it advances two cursors in lockstep and only ever holds the current key's group in memory, so peak memory is proportional to the largest group, not to file size. A hash join must build an in-memory hash table of one entire input before probing, so its memory is proportional to that input — which is why `join` handles inputs larger than RAM and a naive lookup does not.

### Block 8

**A8.1** — `wc -w` counts whitespace-delimited tokens. Every line of `employees.txt` is a single colon-delimited string with no spaces or tabs, so each line is exactly one word → 10 words for 10 lines. `access.log` has 6 space-separated tokens per line × 10 lines = **60 words**.

**A8.2** — `-n l/3` is correct for a log. Plain `-n 3` divides the file into three equal **byte** ranges and cuts wherever the byte boundary falls, so one line is split across two chunks; each chunk then contains a truncated record at its head or tail, which breaks any per-chunk parsing and silently corrupts counts. `-n l/3` shifts each boundary forward to the next newline, so chunks are unequal in bytes but every chunk contains whole lines. (Concatenating the byte chunks back together still reproduces the original exactly — the corruption is only per-chunk.)

**A8.3** — GNU `split` auto-extends the suffix length when it exhausts the current width: with `-d` and the default `-a 2`, it uses `00`–`89`, then rolls into `9000`–`9899`, and so on. `cat x*` then orders `x9000` before `x90` lexically, so the chunks are concatenated out of order. Fix by fixing the width up front — `split -d -a 4` — or by using `cat $(ls -v x*)`. The same auto-extension exists with alphabetic suffixes (`…yz`, `zaaa`).

**A8.4** — Adversarial integrity. MD5 has practical collision attacks: an attacker can construct two different files with the same MD5 digest, so an MD5 manifest cannot prove that a downloaded artifact is the one the publisher signed. For detecting accidental corruption (bit rot, truncated transfer) MD5 is still adequate and faster. Anywhere the threat model includes a malicious party — package verification, release artifacts, supply chain — use `sha256sum` or `sha512sum`.

**A8.5** — `--status` prints nothing at all and communicates only through the exit status, which is exactly what a conditional consumes; without it, `sha256sum -c` writes `file: OK` or `file: FAILED` to stdout, polluting the script's own output and interleaving with logs. Interactively you want that per-file report, plus the summary line naming how many checksums did not match. `--quiet` is the middle ground: silent on success, loud on failure.

**A8.6** — Different locales at sort time. `sort` under `en_US.UTF-8` and under `C` produce different byte orderings of the same lines, hence different digests. The fix is to pin the collation in the pipeline: `LC_ALL=C sort file | sha256sum`. Second-order causes to rule out: CRLF vs LF line endings, and a trailing-newline difference introduced by an editor.

### Block 9

**A9.1** — (1) `zcat` streams: it decompresses incrementally and writes to stdout, so `head` gets its 5 lines from the first few KB of compressed data. `gunzip huge.gz` must decompress all 40 GB *and* write it to disk before `head` even starts. (2) When `head` exits it closes the read end of the pipe; `zcat`'s next `write(2)` raises `SIGPIPE` and the process dies, so decompression *stops* rather than merely being ignored. `gunzip` to a file additionally requires ~40 GB of free space that `zcat` never touches.

**A9.2** — DEFLATE is a stateful stream: the LZ77 sliding window means byte N's decoding depends on the preceding 32 KB of already-decompressed output, and Huffman codes are bit-aligned with no byte-addressable restart points. There is no index from output offset to compressed offset. Line 5 lies within the first block, so a few KB suffice; line 5,000,000 requires decompressing everything before it. Formats that support random access add explicit block boundaries plus an index — `bgzip`/BGZF, `zstd --long` with a seek table, or `xz` with `--block-size`.

**A9.3** — `bzcat` is not part of GNU coreutils; it ships with `bzip2` (as does `bzip2recover`, `bzless`, `bzgrep`). Likewise `xzcat` comes from XZ Utils and `zcat` from GNU gzip. Only `cat`, `cut`, `sort`, `uniq`, `head`, `tail`, `wc`, `split`, `join`, `paste`, `tr`, `nl`, `od`, `pr`, `md5sum`, `sha*sum` and `expand`/`unexpand`/`fmt` are coreutils. In a minimal container (`distroless`, `alpine` with BusyBox, `scratch` + coreutils) any of the three decompressors may be missing, so a shipping script must probe with `command -v bzcat` and fail with a clear message rather than a `command not found` in the middle of a pipeline.

**A9.4** —

```bash
zcat -f app.log app.log.1 app.log.2.gz | wc -l
```

`-f` (`--force`) makes `zcat` copy non-gzip inputs through unchanged instead of erroring, so mixed compressed and plain inputs work in a single invocation and a single pass.

**A9.5** — `.Z` is the output of the historical `compress(1)` utility, which uses LZW rather than DEFLATE. GNU `zcat` is `gzip -cd` and gzip retains LZW decompression support, so it reads `.Z`, `.z` and `.gz` alike. Systems where it fails are running BusyBox `zcat` or a build without LZW support, or have `zcat` symlinked to `zstdcat`. The lesson: `zcat` is not a single specification — check what `zcat --version` reports before relying on its input format coverage.

### Block 10

**A10.1** — 141 = 128 + 13; a shell reports a signal-terminated child as 128 + signal number, and signal 13 is `SIGPIPE`. So `seq` was killed by `SIGPIPE` when `head` closed the pipe, and `head` exited 0. The pipeline **succeeded** — the 141 is the expected, healthy consequence of `head`'s early exit, not an error. `$?` alone would have reported 0 (the status of the last command); only `PIPESTATUS` exposes the 141.

**A10.2** — Under `pipefail` the pipeline's status is the rightmost non-zero status, so `zcat`'s `SIGPIPE` death (141) becomes the pipeline's status and `set -e` aborts the step. It is intermittent because on small archives `zcat` sometimes finishes writing before `head` closes the pipe, exiting 0. Two fixes: (a) scope the option off around that command — `set +o pipefail; zcat huge.gz | head -n 100 > sample.txt; set -o pipefail`; (b) remove the early close by having a single process do the truncation — `zcat huge.gz | sed -n '1,100p;100q' > sample.txt` still has the same issue, so the robust form is `zcat huge.gz 2>/dev/null | { head -n 100 > sample.txt; cat > /dev/null; }`, or simply tolerate the status explicitly: `... || [ "${PIPESTATUS[0]}" -eq 141 ]`.

**A10.3** — stdio full buffering. When `cut`'s stdout is a pipe rather than a TTY, libc switches from line buffering to block buffering with a default 4096-byte buffer, so nothing is flushed until 4 KB has accumulated — hence silence, then a burst. Fix with `stdbuf -oL cut -d' ' -f5` (or `stdbuf -o0` for unbuffered). Tools with their own flag: `sed -u`, `grep --line-buffered`, `awk` with `fflush()`. Note `stdbuf` cannot affect a program that sets its own buffering, which is why it does not work on `tee` or on statically linked binaries.

**A10.4** — Any line where a run of spaces does not begin at a tab stop, or where spaces are semantically significant. Example: `printf 'ab  cd\n'` with `-t 4`. `unexpand -a -t 4` converts the two spaces at columns 2–3 into a tab reaching column 4, and `expand -t 4` converts that tab back into two spaces — this one round-trips. But `printf 'a b\n'` is untouched by `unexpand -a` (a single space is never converted), while `printf 'x\t y\n' | expand -t 4 | unexpand -a -t 4` collapses the tab-plus-space run differently than the original. The general statement: `expand` is injective but `unexpand -a` is not — it maps many distinct space patterns onto the same tab pattern, so the composition is lossy for any whitespace that does not align exactly with tab stops.

**A10.5** — `/pattern` searches and jumps to the next match, leaving all the surrounding non-matching lines on screen; `&pattern` **filters** the display to show only matching lines, like an interactive `grep` you can toggle off with a bare `&`. On a 2 GB log this matters because you can iteratively narrow (`&error`, then `/timeout` within the filtered view) without leaving the pager, without re-reading the file, and without losing your position — whereas piping to `grep` means re-reading 2 GB for every refinement.

**A10.6** — `more` reads and buffers forward only; on a file being appended to it cannot easily incorporate new content and cannot scroll back past what it has already displayed. `less` reads lazily, keeps the whole file addressable, and supports backward movement, search in both directions, and `F` follow mode. `less +F` beats `tail -f` because a single `Ctrl-C` drops you out of follow mode into a full pager positioned at the point of interest, where you can scroll back, search, and then press `F` to resume following — with `tail -f` the scrollback is the terminal's, is bounded, and is not searchable.

### Capstone

**AC.1** — The load-bearing property is that GNU `sort`'s merge sort is **stable when `-u` is in effect**: with `-u`, the comparison returns as soon as the keys are decided, the whole-line last-resort fallback is skipped, and equal-key lines therefore retain input order — so the first line of each `dept` group in the incoming (salary-descending) order is the one kept. What would break it: adding `-r` to the second sort (reverses the group ordering), replacing `sort -u` with `sort | uniq` (compares whole lines, so nothing dedups), or reordering the two sorts (the salary ordering must exist *before* the dedup consumes it). Adding `-k4,4` to the second sort would also break it by changing the uniqueness key.

**AC.2** — First sort, `-k3,3 -k4,4nr`: both `ops` rows tie on dept and on salary (52000). The `r` modifier is attached to key 4 only, so the **global** reverse flag is not set. The last-resort whole-line comparison therefore runs forward, and `1007:mora:…` < `1008:haddad:…` byte-wise, so `mora` is emitted first. The second sort, `-k3,3 -u`, keeps the first `ops` line it sees, which is `mora`. Had the first sort been written `sort -t: -k3,3 -k4,4n -r`, the global `-r` would reverse the fallback and `haddad` would win.

**AC.3** — Strip `uniq -c`'s seven-column padding with `tr`:

```bash
tail -n +2 employees.txt | cut -d: -f3 | sort | uniq -c | sort -rn | tr -s ' ' | cut -c2-
```

`tr -s ' '` collapses the leading run to a single space; `cut -c2-` drops it. Equivalent without `cut`: pipe through `tr -s ' '` and accept the single leading space, or use `sort -rn | tr -s ' ' | sed 's/^ //'` if `sed` is permitted.

**AC.4** — The regex `\([3-9][0-9]*\|[0-9]\{2,\}\)` encodes "≥ 3" as a *lexical* property of the decimal representation, so it must enumerate every digit shape that satisfies the threshold. Changing the threshold to 7 or 25 means rewriting the alternation, and an off-by-one is invisible until it silently drops a real attacker. The robust approach keeps the numeric comparison numeric: sort by count descending and cut the list where it stops mattering —

```bash
zcat access.log.gz | sed -n '/ 40[13] /p' | cut -d' ' -f6 | sort | uniq -c | sort -rn
```

— then take the leading rows (`head`), or, for a genuine threshold, generate the boundary line and use `sort` to place it: append a synthetic `      3 ---THRESHOLD---` record before `sort -rn` and `sed -n '1,/THRESHOLD/p'` to cut there. The general principle: never re-encode arithmetic as pattern matching in a filter pipeline.

**AC.5** — Capstone **3** is the one at risk, and only via `sort`'s collation of IPv4 strings; with this data set (a single result) the visible output is unchanged. Capstone 1 sorts numerically (`-rn`), which is locale-independent for ASCII digits. Capstone 2's `-k3,3` compares the lowercase ASCII department names `dev`/`ops`/`qa`, which collate identically under `C` and `en_US.UTF-8`. Capstone 3 sorts IP address strings lexically; glibc collation ignores punctuation at the primary level, so `10.0.0.9` and `100.0.9` can order differently than under `C`, and any mixed-case or non-ASCII field would diverge outright. The correct habit is to set `LC_ALL=C` on **all three** regardless — it is faster, it is deterministic, and it makes the checksummed output reproducible across hosts, as established in Block 4 and Block 8.

</details>