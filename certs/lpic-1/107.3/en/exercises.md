# 107.3 — Localisation and Internationalisation

## Guided Exercises

**Target:** LPIC-1, Exam 102-500, Objective 107.3 — *Localisation and internationalisation*.

### Lab prerequisites

- A Linux system where you have `sudo`. A throwaway VM or container is strongly recommended: several steps change system-wide locale and timezone state.
- Packages: `glibc` (always present), `coreutils`, `bsdmainutils`/`util-linux` (for `hexdump`), `tzdata`, and — on systemd systems — `systemd` (for `timedatectl` / `localectl`).
- Take a snapshot of the original state before you start; you will restore it at the end:

```bash
$ mkdir -p ~/107.3-lab && cd ~/107.3-lab
$ locale > locale.before
$ readlink -f /etc/localtime > tz.before
$ cat tz.before
/usr/share/zoneinfo/Europe/Madrid
```

> Throughout, `$` marks a command run as your normal user and `#` marks a command run as root. Outputs are representative — exact strings vary with distribution, glibc version and the set of locales installed on your machine. Where a value is genuinely machine-specific this is flagged.

---

## Exercise 1 — Reading the current locale state

**Goal:** distinguish the *categories* of a locale, and learn to tell which of them was set explicitly and which was inherited.

1. Print the effective locale configuration:

```bash
$ locale
LANG=en_US.UTF-8
LANGUAGE=
LC_CTYPE="en_US.UTF-8"
LC_NUMERIC="en_US.UTF-8"
LC_TIME="en_US.UTF-8"
LC_COLLATE="en_US.UTF-8"
LC_MONETARY="en_US.UTF-8"
LC_MESSAGES="en_US.UTF-8"
LC_PAPER="en_US.UTF-8"
LC_NAME="en_US.UTF-8"
LC_ADDRESS="en_US.UTF-8"
LC_TELEPHONE="en_US.UTF-8"
LC_MEASUREMENT="en_US.UTF-8"
LC_IDENTIFICATION="en_US.UTF-8"
LC_ALL=
```

2. Note carefully that every `LC_*` value above is **inside double quotes**. Now set one category explicitly and look again:

```bash
$ export LC_TIME=C
$ locale | grep -E 'LANG=|LC_TIME|LC_CTYPE|LC_ALL'
LANG=en_US.UTF-8
LC_CTYPE="en_US.UTF-8"
LC_TIME=C
LC_ALL=
```

3. Inspect the *contents* of a category with `-k` (keyword) instead of just its name:

```bash
$ locale -k LC_NUMERIC
decimal_point="."
thousands_sep=","
grouping=3;3
numeric-decimal-point-wc=46
numeric-thousands-sep-wc=44
numeric-codeset="UTF-8"

$ LC_ALL=de_DE.UTF-8 locale -k LC_NUMERIC | head -3
decimal_point=","
thousands_sep="."
grouping=3;3
```

4. Query a single keyword instead of a whole category — this is the scriptable form:

```bash
$ locale decimal_point
.
$ LC_ALL=de_DE.UTF-8 locale abday
So;Mo;Di;Mi;Do;Fr;Sa
$ locale charmap
UTF-8
```

5. Undo step 2 before continuing:

```bash
$ unset LC_TIME
```

**Questions**

- **Q1.1** — In the output of `locale`, what is the difference in meaning between `LC_TIME="en_US.UTF-8"` and `LC_TIME=en_US.UTF-8`?
- **Q1.2** — Decompose `en_US.UTF-8` into its parts and name each one. What would `ca_ES.UTF-8@valencia` add?
- **Q1.3** — Which category governs each of the following: the alphabetical order used by `sort`; the currency symbol printed by an application; whether `tr '[:upper:]' '[:lower:]'` knows that `É` lowercases to `é`; the language of `ls`'s error messages?
- **Q1.4** — `locale charmap` returned `UTF-8`. Which single category determined that answer?

---

## Exercise 2 — Precedence: `LC_ALL` > `LC_*` > `LANG`, and where `LANGUAGE` fits

**Goal:** internalise the three-level override chain and the special, message-only role of `LANGUAGE`.

1. Establish a known baseline and observe the date format:

```bash
$ export LANG=en_US.UTF-8
$ unset LC_ALL LANGUAGE
$ date
Thu Aug 27 02:15:44 PM CEST 2026
```

2. Override **one** category. `LANG` still supplies every other category:

```bash
$ LC_TIME=de_DE.UTF-8 date
Do 27 Aug 2026 14:15:51 CEST
```

3. Now override **everything** with `LC_ALL` and confirm it wins over the more specific `LC_TIME`:

```bash
$ LC_ALL=C LC_TIME=de_DE.UTF-8 date
Thu Aug 27 14:16:02 CEST 2026
```

4. Watch `LC_ALL` flatten the whole report:

```bash
$ LC_ALL=C locale | head -4
LANG=en_US.UTF-8
LANGUAGE=
LC_CTYPE="C"
LC_NUMERIC="C"
```

5. Explore `LANGUAGE`, which is a GNU gettext extension and **not** a POSIX category. It takes a colon-separated *list* of fallback languages, and it only affects translated messages:

```bash
$ LANGUAGE=de:fr:en LC_ALL=en_US.UTF-8 ls /nonexistent
ls: Zugriff auf '/nonexistent' nicht möglich: Datei oder Verzeichnis nicht gefunden

$ LANGUAGE=de:fr:en LC_ALL=en_US.UTF-8 date
Thu Aug 27 02:16:30 PM CEST 2026
```

6. Now demonstrate the rule that trips people up in scripts — `LANGUAGE` is ignored entirely when the message locale is `C` or `POSIX`:

```bash
$ LANGUAGE=de LC_ALL=C ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory
```

**Questions**

- **Q2.1** — State the precedence order for a single category such as `LC_TIME`, from strongest to weakest.
- **Q2.2** — In step 5, the *messages* became German but the *date format* stayed American. Explain precisely why.
- **Q2.3** — Why is setting `LC_ALL` permanently in `/etc/environment` or `~/.bashrc` considered bad practice, while using it as a one-shot prefix (`LC_ALL=C somecommand`) is considered good practice?
- **Q2.4** — A script needs French messages if available, otherwise Spanish, otherwise English. Which variable expresses that, and with what value?

---

## Exercise 3 — Observing what a locale actually changes

**Goal:** see collation, numeric formatting and time formatting change under your hands, so that locale-dependent bugs become recognisable.

1. Collation — the single most consequential difference between `C` and any natural-language locale:

```bash
$ printf 'apple\nBanana\ncherry\nApricot\n' > words.txt

$ LC_ALL=C sort words.txt
Apricot
Banana
apple
cherry

$ LC_ALL=en_US.UTF-8 sort words.txt
apple
Apricot
Banana
cherry
```

2. Numeric formatting — thousands grouping and the decimal separator:

```bash
$ LC_ALL=C          printf "%'d\n" 1234567
1234567
$ LC_ALL=en_US.UTF-8 printf "%'d\n" 1234567
1,234,567
$ LC_ALL=de_DE.UTF-8 printf "%'d\n" 1234567
1.234.567

$ LC_ALL=en_US.UTF-8 printf "%.2f\n" 3.5
3.50
$ LC_ALL=de_DE.UTF-8 printf "%.2f\n" 3.5
3,50
```

3. Time formatting — including the abbreviated month name that so many log parsers depend on:

```bash
$ LC_ALL=C           date +'%A %d %B %Y — %x %X'
Thursday 27 August 2026 — 08/27/26 14:17:20
$ LC_ALL=es_ES.UTF-8 date +'%A %d %B %Y — %x %X'
jueves 27 agosto 2026 — 27/08/26 14:17:22
$ LC_ALL=C date +%b ; LC_ALL=es_ES.UTF-8 date +%b
Aug
ago
```

4. Character classification (`LC_CTYPE`) — whether the system knows a byte sequence is a letter at all:

```bash
$ printf 'ÁÉÍÓÚ\n' | LC_ALL=en_US.UTF-8 tr '[:upper:]' '[:lower:]'
áéíóú
$ printf 'ÁÉÍÓÚ\n' | LC_ALL=C tr '[:upper:]' '[:lower:]'
ÁÉÍÓÚ
```

5. Measure the practical impact on a script that parses output:

```bash
$ LC_ALL=es_ES.UTF-8 ls -l /etc/hosts
-rw-r--r-- 1 root root 219 ago  3 11:04 /etc/hosts
$ LC_ALL=C ls -l /etc/hosts
-rw-r--r-- 1 root root 219 Aug  3 11:04 /etc/hosts
```

**Questions**

- **Q3.1** — In step 1, `C` placed `Apricot` before `apple`, but `en_US.UTF-8` placed `apple` before `Apricot`. What ordering rule does each locale apply?
- **Q3.2** — A cron job pipes `ls -l` into `awk` and matches on `"Aug"`. It works on your laptop and fails on a colleague's. Give the cause and the one-line fix.
- **Q3.3** — A CSV export produced under `de_DE.UTF-8` contains the value `1.234,56`. Two problems will hit the downstream importer. Name both, and name the two categories responsible.
- **Q3.4** — Why does `LC_ALL=C` make `tr '[:upper:]' '[:lower:]'` stop working on accented characters? Is this a bug in `tr`?

---

## Exercise 4 — Which locales exist, and how to create one

**Goal:** distinguish *supported* locale definitions from *generated/installed* locales, and generate one on both major distribution families.

1. List the locales currently available on the system, and count them:

```bash
$ locale -a
C
C.utf8
POSIX
en_US.utf8
$ locale -a | wc -l
4
```

2. Note the spelling. glibc reports the *normalised* form. Confirm both spellings are accepted:

```bash
$ LC_ALL=en_US.UTF-8 date +%b
Aug
$ LC_ALL=en_US.utf8 date +%b
Aug
```

3. Try a locale that is *defined* but not *generated*, and read the error precisely:

```bash
$ LC_ALL=fr_FR.UTF-8 date
bash: warning: setlocale: LC_ALL: cannot change locale (fr_FR.UTF-8): No such file or directory
Thu Aug 27 02:18:03 PM CEST 2026
```

4. Look at the raw ingredients from which locales are built:

```bash
$ ls /usr/share/i18n/locales | head -5
aa_DJ
aa_ER
aa_ET
af_ZA
agr_PE
$ ls /usr/share/i18n/charmaps | head -5
ANSI_X3.110-1983.gz
ANSI_X3.4-1968.gz
ARMSCII-8.gz
ASCII.gz
BIG5.gz
$ grep -c '' /usr/share/i18n/SUPPORTED
496
```

5. Generate the locale. **Debian/Ubuntu path** — uncomment the line in `/etc/locale.gen` and run the generator:

```bash
# sed -i 's/^# *\(fr_FR.UTF-8 UTF-8\)/\1/' /etc/locale.gen
# grep '^fr_FR' /etc/locale.gen
fr_FR.UTF-8 UTF-8
# locale-gen
Generating locales (this might take a while)...
  en_US.UTF-8... done
  fr_FR.UTF-8... done
Generation complete.
```

6. **Direct / RHEL-Fedora path** — build a single locale with `localedef`, or install the language pack:

```bash
# localedef -i fr_FR -f UTF-8 fr_FR.UTF-8
# localedef --list-archive | head -3
en_US.utf8
fr_FR.utf8

# dnf install -y glibc-langpack-fr        # Fedora/RHEL equivalent
```

7. Verify, then set the system-wide default. **systemd systems** write `/etc/locale.conf`:

```bash
$ locale -a | grep fr
fr_FR.utf8

$ localectl status
   System Locale: LANG=en_US.UTF-8
       VC Keymap: us
      X11 Layout: us

# localectl set-locale LANG=fr_FR.UTF-8
$ cat /etc/locale.conf
LANG=fr_FR.UTF-8
```

8. **Debian** additionally maintains `/etc/default/locale`, driven by `update-locale`:

```bash
# update-locale LANG=fr_FR.UTF-8
# cat /etc/default/locale
LANG=fr_FR.UTF-8
```

9. Restore your original default before continuing:

```bash
# localectl set-locale LANG=en_US.UTF-8
```

**Questions**

- **Q4.1** — `/usr/share/i18n/locales/fr_FR` exists on a freshly installed system, yet `LC_ALL=fr_FR.UTF-8 date` fails. Explain the distinction the system is making.
- **Q4.2** — What are the two arguments `localedef -i` and `-f` take, and what does each contribute to the finished locale?
- **Q4.3** — `/etc/locale.gen` contains `fr_FR.UTF-8 UTF-8`. Why does the charmap appear twice on that line, and are the two occurrences the same thing?
- **Q4.4** — What is the difference in scope between `/etc/locale.conf` and `~/.bashrc` for setting `LANG`? Which one affects a graphical login session and a `systemd` service unit?
- **Q4.5** — `C.UTF-8` appears in `locale -a`. How does it differ from both `C` and `en_US.UTF-8`, and why is it a good default for containers?

---

## Exercise 5 — Character encodings: ASCII, ISO-8859, Unicode, UTF-8

**Goal:** see, at byte level, that "the same text" occupies different bytes in different encodings, and that the encoding is not stored in the file.

1. Create a UTF-8 file and inspect its bytes:

```bash
$ printf 'ma\xc3\xb1ana\n' > utf8.txt
$ cat utf8.txt
mañana
$ file utf8.txt
utf8.txt: Unicode text, UTF-8 text
$ hexdump -C utf8.txt
00000000  6d 61 c3 b1 61 6e 61 0a                           |ma..ana.|
00000008
```

2. Contrast the *byte* count with the *character* count. This only works if `LC_CTYPE` is a UTF-8 locale:

```bash
$ LC_ALL=en_US.UTF-8 wc -c -m utf8.txt
 8  7 utf8.txt
$ LC_ALL=C wc -c -m utf8.txt
 8  8 utf8.txt
```

3. Convert to ISO-8859-1 (Latin-1) and compare:

```bash
$ iconv -f UTF-8 -t ISO-8859-1 utf8.txt > latin1.txt
$ hexdump -C latin1.txt
00000000  6d 61 f1 61 6e 61 0a                              |ma.ana.|
00000007
$ file latin1.txt
latin1.txt: ISO-8859 text
$ wc -c latin1.txt
7 latin1.txt
```

4. Now display the Latin-1 file in a UTF-8 terminal — this is *mojibake*, reproduced deliberately:

```bash
$ cat latin1.txt
ma?ana
```

5. Prove that the file itself carries no encoding label — you must supply it:

```bash
$ iconv -f ISO-8859-1 -t UTF-8 latin1.txt
mañana
$ iconv -f ISO-8859-5 -t UTF-8 latin1.txt
maёana
```

6. Look at a character that Latin-1 cannot hold at all:

```bash
$ printf '10 \xe2\x82\xac\n' > euro.txt
$ cat euro.txt
10 €
$ hexdump -C euro.txt
00000000  31 30 20 e2 82 ac 0a                              |10 ....|
00000007

$ iconv -f UTF-8 -t ISO-8859-1 euro.txt > /dev/null
iconv: cannot convert
$ echo $?
1

$ iconv -f UTF-8 -t ISO-8859-15 euro.txt | hexdump -C
00000000  31 30 20 a4 0a                                    |10 ..|
00000005
```

> The exact diagnostic wording differs between glibc versions and libc implementations (`illegal input sequence at position N` is also common). What is portable is the **non-zero exit status** — that is what a script must test.

7. Browse the encodings your `iconv` knows:

```bash
$ iconv -l | wc -l
1173
$ iconv -l | grep -i '^UTF'
UTF-7//
UTF-8//
UTF-16//
UTF-16BE//
UTF-16LE//
UTF-32//
$ locale -m | grep -iE '^(ASCII|ISO-8859-1|UTF-8)$'
ANSI_X3.4-1968
ISO-8859-1
UTF-8
```

**Questions**

- **Q5.1** — `mañana` is 6 characters. Why is `utf8.txt` 8 bytes and `latin1.txt` 7 bytes (both including the newline)?
- **Q5.2** — In step 2, `wc -m` returned 8 under `LC_ALL=C` and 7 under `en_US.UTF-8`, for the identical file. Explain.
- **Q5.3** — Bytes `6d 61` are identical in both files. What property of UTF-8 guarantees this for every ASCII character, and why did that property matter so much for adoption?
- **Q5.4** — Step 5 decoded the same 7 bytes as `mañana` and as `maёana` without either command reporting an error. What does this tell you about the reliability of `file` for encoding detection?
- **Q5.5** — Step 6 succeeded with ISO-8859-15 and failed with ISO-8859-1. What is the one practical difference between those two charsets that this demonstrates?
- **Q5.6** — Distinguish, in one sentence each: *Unicode*, *code point*, *UTF-8*, *UTF-16*.

---

## Exercise 6 — Lossy conversion: `//TRANSLIT`, `//IGNORE` and `-c`

**Goal:** learn the three ways `iconv` can be told to proceed past an unconvertible character, and what each one costs.

1. Establish the baseline failure:

```bash
$ printf 'caf\xc3\xa9 10 \xe2\x82\xac\n' > mixed.txt
$ cat mixed.txt
café 10 €
$ iconv -f UTF-8 -t ASCII mixed.txt
iconv: cannot convert
$ echo $?
1
```

2. Ask for transliteration — a best-effort replacement in the target charset:

```bash
$ LC_ALL=en_US.UTF-8 iconv -f UTF-8 -t ASCII//TRANSLIT mixed.txt
cafe 10 EUR
$ echo $?
0
```

3. Run the *same* command with the locale removed, and compare the result carefully:

```bash
$ LC_ALL=C iconv -f UTF-8 -t ASCII//TRANSLIT mixed.txt
caf? 10 EUR
```

4. Ask for the offending characters to be discarded instead:

```bash
$ iconv -f UTF-8 -t ASCII//IGNORE mixed.txt
caf 10 
iconv: cannot convert
$ echo $?
1

$ iconv -c -f UTF-8 -t ASCII mixed.txt
caf 10 
$ echo $?
1
```

5. Confirm what "discard" really cost you:

```bash
$ iconv -c -f UTF-8 -t ASCII mixed.txt | hexdump -C
00000000  63 61 66 20 31 30 20 0a                           |caf 10 .|
00000008
```

6. A realistic repair workflow — normalise a directory of legacy files in place, safely:

```bash
$ for f in *.txt; do
>   if iconv -f ISO-8859-1 -t UTF-8 "$f" -o "$f.new"; then
>     mv -- "$f.new" "$f"
>   else
>     echo "FAILED: $f" >&2; rm -f -- "$f.new"
>   fi
> done
```

**Questions**

- **Q6.1** — Steps 2 and 3 ran an identical `iconv` command and produced different output. Which environment variable caused the difference, and why does transliteration depend on it?
- **Q6.2** — `//TRANSLIT` turned `é` into `e` and `€` into `EUR`. Is this conversion reversible? What does that imply about using it on data you intend to keep?
- **Q6.3** — Both `//IGNORE` and `-c` dropped characters. What is the observable difference between them, and which is more dangerous inside a shell script?
- **Q6.4** — In step 6, why is the output written to `"$f.new"` and moved only on success, rather than redirecting straight onto `"$f"`?
- **Q6.5** — What single conversion target would have avoided the whole problem, and why is it not always available?

---

## Exercise 7 — The timezone database and `/etc/localtime`

**Goal:** map the on-disk timezone machinery and change the system timezone by both the modern and the classic method.

1. Explore the IANA timezone database as shipped:

```bash
$ ls /usr/share/zoneinfo/ | head -12
Africa
America
Antarctica
Arctic
Asia
Atlantic
Australia
Etc
Europe
Indian
Pacific
UTC
$ ls /usr/share/zoneinfo/America/Argentina/
Buenos_Aires  Catamarca  ComodRivadavia  Cordoba  Jujuy  La_Rioja  Mendoza
Rio_Gallegos  Salta  San_Juan  San_Luis  Tucuman  Ushuaia
$ file /usr/share/zoneinfo/Europe/Madrid
/usr/share/zoneinfo/Europe/Madrid: timezone data, version 2, 5 gmt time flags, \
5 std time flags, no leap seconds, 15 transition times, 5 abbreviation chars
```

2. Identify the system timezone through the two files that define it:

```bash
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug  3 11:02 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
$ cat /etc/timezone            # Debian family only
Europe/Madrid
$ date +'%Z %z'
CEST +0200
```

3. Read the full clock/timezone state on a systemd system:

```bash
$ timedatectl
               Local time: Thu 2026-08-27 14:20:11 CEST
           Universal time: Thu 2026-08-27 12:20:11 UTC
                 RTC time: Thu 2026-08-27 12:20:11
                Time zone: Europe/Madrid (CEST, +0200)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

4. Find a timezone name, then change the system timezone the modern way:

```bash
$ timedatectl list-timezones | grep -i tokyo
Asia/Tokyo

# timedatectl set-timezone Asia/Tokyo
$ date
Thu Aug 27 09:20:33 PM JST 2026
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 30 Aug 27 21:20 /etc/localtime -> ../usr/share/zoneinfo/Asia/Tokyo
```

5. Do the same thing the classic, systemd-free way:

```bash
# ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
# echo 'Europe/Madrid' > /etc/timezone        # Debian family
$ date +'%Z %z'
CEST +0200
```

6. Use the interactive helper — and observe that it changes nothing:

```bash
$ tzselect
Please identify a location so that time zone rules can be set correctly.
Please select a continent, ocean, "coord", "TZ" or "time":
 1) Africa
 ...
#? 8
...
You can make this change permanent for yourself by appending the line
	TZ='Asia/Tokyo'; export TZ
to the file '.profile' in your home directory; then log out and log in again.

Here is that TZ value again, this time on standard output so that you
can use the /usr/bin/tzselect command in shell scripts:
Asia/Tokyo

$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug 27 14:21 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
```

**Questions**

- **Q7.1** — What exactly is `/etc/localtime`, in terms of file type and content? Why is a symlink preferred over a copy?
- **Q7.2** — `/etc/timezone` and `/etc/localtime` both name the timezone. What is the format of each, and which one does the C library actually consult when a program calls `localtime()`?
- **Q7.3** — After step 4, `date` printed `JST` even though nothing about the hardware clock changed. What did change?
- **Q7.4** — `tzselect` completed and printed `Asia/Tokyo`, but the system timezone stayed on `Europe/Madrid`. What is `tzselect` for, then?
- **Q7.5** — Why are timezones named `America/Argentina/Buenos_Aires` (a place) rather than `ART` or `UTC-3` (an offset)?

---

## Exercise 8 — The `TZ` variable and per-process timezones

**Goal:** override the timezone for one process without touching the system, and master the POSIX `TZ` sign convention.

1. Override per command, per user, and confirm it does not leak:

```bash
$ date
Thu Aug 27 02:22:05 PM CEST 2026
$ TZ='Asia/Tokyo' date
Thu Aug 27 09:22:05 PM JST 2026
$ TZ='UTC' date
Thu Aug 27 12:22:05 PM UTC 2026
$ date
Thu Aug 27 02:22:06 PM CEST 2026
```

2. Show that the *instant* never changed — only its rendering:

```bash
$ TZ='Asia/Tokyo' date +%s ; TZ='UTC' date +%s ; date +%s
1787833330
1787833330
1787833330
```

3. Compare several offices at one instant — the classic operational use:

```bash
$ NOW=$(date +%s)
$ for z in UTC Europe/Madrid America/New_York Asia/Tokyo Australia/Sydney; do
>   printf '%-22s %s\n' "$z" "$(TZ=$z date -d "@$NOW" +'%F %T %Z')"
> done
UTC                    2026-08-27 12:22:10 UTC
Europe/Madrid          2026-08-27 14:22:10 CEST
America/New_York       2026-08-27 08:22:10 EDT
Asia/Tokyo             2026-08-27 21:22:10 JST
Australia/Sydney       2026-08-27 22:22:10 AEST
```

4. Now the POSIX `TZ` string form, which encodes the rules inline instead of naming a zone. **Read the offsets carefully:**

```bash
$ TZ='UTC' date +'%H:%M %Z'
12:22 UTC
$ TZ='XXX-3' date +'%H:%M %Z'
15:22 XXX
$ TZ='XXX3' date +'%H:%M %Z'
09:22 XXX
```

5. A full POSIX string with a DST rule — standard name/offset, DST name, then the transition dates:

```bash
$ TZ='EST5EDT,M3.2.0,M11.1.0' date +'%F %T %Z %z'
2026-08-27 08:22:15 EDT -0400
```

6. Note the colon form, which tells glibc to treat the value as a path:

```bash
$ TZ=':/usr/share/zoneinfo/Asia/Kolkata' date +'%H:%M %Z'
17:52 IST
```

7. Persist a timezone for one user only, without root:

```bash
$ echo "export TZ='Asia/Tokyo'" >> ~/.profile
```

8. Inspect the transition rules the database holds, and locate this year's DST changes:

```bash
$ zdump -v Europe/Madrid | grep 2026
Europe/Madrid  Sun Mar 29 00:59:59 2026 UT = Sun Mar 29 01:59:59 2026 CET isdst=0 gmtoff=3600
Europe/Madrid  Sun Mar 29 01:00:00 2026 UT = Sun Mar 29 03:00:00 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 00:59:59 2026 UT = Sun Oct 25 02:59:59 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 01:00:00 2026 UT = Sun Oct 25 02:00:00 2026 CET isdst=0 gmtoff=3600

$ zdump Asia/Kolkata
Asia/Kolkata  Thu Aug 27 17:52:20 2026 IST
```

9. Remove the line you added in step 7 before continuing.

**Questions**

- **Q8.1** — In step 2, three different wall-clock renderings produced one identical number. What is that number counting, and why is it timezone-independent?
- **Q8.2** — `TZ='XXX-3'` produced a clock *ahead* of UTC and `TZ='XXX3'` produced one *behind*. State the POSIX sign rule that explains this, and say why it is the opposite of the `+02:00` you see in an ISO 8601 timestamp.
- **Q8.3** — Decode `EST5EDT,M3.2.0,M11.1.0` field by field.
- **Q8.4** — On 2026-10-25 the local clock in Madrid reads `02:30`. Using the `zdump` output, explain why that is not enough information to identify an instant. What happens instead at 02:30 on 2026-03-29?
- **Q8.5** — Give two situations where setting `TZ` for a single process is the correct answer and changing `/etc/localtime` would be wrong.

---

## Exercise 9 — Hardware clock, UTC, and diagnosing a mixed system

**Goal:** connect the RTC to the system clock, and understand the `UTC` vs `LOCAL` decision recorded in `/etc/adjtime`.

1. Read the hardware clock and compare it to the system clock:

```bash
# hwclock --show
2026-08-27 14:23:40.512345+02:00
$ date
Thu Aug 27 02:23:41 PM CEST 2026
```

2. Inspect how the system has been told to interpret the RTC:

```bash
$ cat /etc/adjtime
0.000000 1756290000 0.000000
0
UTC
$ timedatectl | grep 'RTC in local TZ'
          RTC in local TZ: no
```

3. Observe the same fact from the other direction:

```bash
$ timedatectl | grep -E 'RTC time|Universal time'
           Universal time: Thu 2026-08-27 12:23:45 UTC
                 RTC time: Thu 2026-08-27 12:23:45
```

4. Simulate the dual-boot scenario, then undo it immediately:

```bash
# timedatectl set-local-rtc 1
Warning: The system is configured to read the RTC time in the local time zone.
         This mode cannot be fully supported. It will create various problems
         with time zone changes and daylight saving time adjustments. ...
$ tail -1 /etc/adjtime
LOCAL

# timedatectl set-local-rtc 0
$ tail -1 /etc/adjtime
UTC
```

5. Manual synchronisation in both directions, for systems without `timedatectl`:

```bash
# hwclock --hctosys        # hardware clock  ->  system clock
# hwclock --systohc        # system clock    ->  hardware clock
```

**Questions**

- **Q9.1** — What are the two distinct clocks in play here, and which one survives a power cut?
- **Q9.2** — The last line of `/etc/adjtime` is `UTC`. What breaks if that line says `LOCAL` and the machine is in Madrid?
- **Q9.3** — Why does storing the RTC in UTC make DST transitions a non-event, while storing it in local time does not?
- **Q9.4** — Distinguish `hwclock --hctosys` from `hwclock --systohc` and give one situation for each.

---

## Exercise 10 — Diagnosing locale failures across SSH

**Goal:** recognise and fix the single most common locale complaint in production — the warning that appears only after logging into a remote host.

1. Reproduce the symptom. On the *client*, set a locale that the *server* does not have generated:

```bash
$ LC_ALL=fr_FR.UTF-8 ssh user@server 'perl -e "print qq(ok\n)"'
perl: warning: Setting locale failed.
perl: warning: Please check that your locale settings:
	LANGUAGE = (unset),
	LC_ALL = "fr_FR.UTF-8",
	LANG = "en_US.UTF-8"
    are supported and installed on your system.
perl: warning: Falling back to the standard locale ("C").
ok
```

2. Find the mechanism that transported the variable. On the **client**:

```bash
$ grep -rn 'SendEnv' /etc/ssh/ssh_config /etc/ssh/ssh_config.d/ 2>/dev/null
/etc/ssh/ssh_config:52:    SendEnv LANG LC_*
```

3. And on the **server**:

```bash
$ grep -rn 'AcceptEnv' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null
/etc/ssh/sshd_config:117:AcceptEnv LANG LC_*
```

4. Confirm what actually arrives at the far end:

```bash
$ LC_ALL=fr_FR.UTF-8 ssh user@server 'locale 2>/dev/null | grep -E "LANG=|LC_ALL"'
LANG=en_US.UTF-8
LC_ALL=fr_FR.UTF-8
$ ssh user@server 'locale -a | grep -c fr_FR'
0
```

5. Apply the correct fix — generate the locale **on the server**:

```bash
server# sed -i 's/^# *\(fr_FR.UTF-8 UTF-8\)/\1/' /etc/locale.gen && locale-gen
server# locale -a | grep fr_FR
fr_FR.utf8
$ LC_ALL=fr_FR.UTF-8 ssh user@server 'date'
jeu. 27 août 2026 14:25:02 CEST
```

6. Apply the alternative fix when you cannot modify the server — stop the client from forwarding:

```bash
$ ssh -o SendEnv=  user@server 'date'
Thu Aug 27 02:25:10 PM CEST 2026
```

7. Finally, harden a script against every locale on earth:

```bash
$ cat > /tmp/report.sh <<'EOF'
#!/bin/bash
export LC_ALL=C.UTF-8            # stable parsing, still UTF-8 aware
ls -l --time-style=long-iso /etc/hosts | awk '{print $6, $7, $9}'
EOF
$ chmod +x /tmp/report.sh
$ LANG=es_ES.UTF-8 /tmp/report.sh
2026-08-03 11:04 /etc/hosts
```

8. Restore your lab machine:

```bash
$ diff <(locale) locale.before
# ln -sf "$(cat ~/107.3-lab/tz.before)" /etc/localtime
```

**Questions**

- **Q10.1** — Nothing on the server was misconfigured, and nothing on the client was misconfigured. Where does the fault actually live?
- **Q10.2** — Which two directives, in which two files, form the pair that transports locale variables over SSH?
- **Q10.3** — Rank the three possible fixes (generate the locale on the server / remove `SendEnv` on the client / remove `AcceptEnv` on the server) by blast radius, and say which you would choose on a fleet of 300 servers.
- **Q10.4** — Step 7 sets `LC_ALL=C.UTF-8` rather than `LC_ALL=C`. What does the script gain, and what does it keep?
- **Q10.5** — `--time-style=long-iso` was added in step 7. Which category does that neutralise, and why is doing so more robust than relying on `LC_ALL` alone?

---

## References

- LPI, *Exam 101 Objectives* (LPIC-1 v5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI, *Exam 102 Objectives* (LPIC-1 v5.0), objective 107.3 — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- GNU C Library Manual, *Locales and Internationalization* — <https://www.gnu.org/software/libc/manual/html_node/Locales.html>
- GNU C Library Manual, *Specifying the Time Zone with `TZ`* — <https://www.gnu.org/software/libc/manual/html_node/TZ-Variable.html>
- GNU gettext Manual, *The `LANGUAGE` variable* — <https://www.gnu.org/software/gettext/manual/html_node/The-LANGUAGE-variable.html>
- Linux man-pages: `locale(1)`, `locale(5)`, `locale(7)`, `localedef(1)`, `iconv(1)`, `tzselect(8)`, `zdump(8)`, `hwclock(8)` — <https://man7.org/linux/man-pages/>
- IANA, *Time Zone Database* and *Theory and pragmatics of the tz code and data* — <https://www.iana.org/time-zones> and <https://data.iana.org/time-zones/theory.html>
- systemd project, `timedatectl(1)`, `localectl(1)`, `locale.conf(5)` — <https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html>
- The Unicode Consortium, *The Unicode Standard* — <https://www.unicode.org/versions/latest/>
- IETF RFC 3629, *UTF-8, a transformation format of ISO 10646* — <https://www.rfc-editor.org/rfc/rfc3629>
- Debian Reference, *Localization* — <https://www.debian.org/doc/manuals/debian-reference/ch08.en.html>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — The quotes indicate *provenance*, not value. `locale` prints a category **quoted** when its value is inherited — from `LC_ALL` if that is set, otherwise from `LANG`, otherwise the built-in `POSIX` default. It prints the value **unquoted** when that category's own environment variable (`LC_TIME` here) is set explicitly. So `LC_TIME="en_US.UTF-8"` means "nobody set `LC_TIME`; it follows `LANG`", while `LC_TIME=en_US.UTF-8` means "`LC_TIME` is set in this environment". `LANG` and `LC_ALL` themselves are always printed raw.

**A1.2** — `en` is the ISO 639 **language** code; `US` is the ISO 3166 **territory/country** code; `UTF-8` after the dot is the **codeset** (character encoding). A trailing `@valencia` is the optional **modifier**, selecting a variant of the same language/territory pair — here the Valencian orthographic variant of Catalan in Spain. The general form is `language[_TERRITORY][.codeset][@modifier]`.

**A1.3** —
- alphabetical order used by `sort` → `LC_COLLATE`
- currency symbol → `LC_MONETARY`
- knowing `É` ↔ `é` → `LC_CTYPE`
- language of error messages → `LC_MESSAGES`

**A1.4** — `LC_CTYPE`. The codeset in effect is a property of the character-classification category, which is why `LC_CTYPE` is the one category you must keep UTF-8 even when you force everything else to `C`.

### Exercise 2

**A2.1** — `LC_ALL` (overrides everything) → the specific `LC_TIME` variable → `LANG` (the fallback for every unset category) → the built-in `POSIX`/`C` default if none is set.

**A2.2** — `LANGUAGE` is a GNU gettext extension, not a POSIX locale category. It influences **only** the selection of translated message catalogues — the same thing `LC_MESSAGES` governs. Date field ordering, month names and separators come from `LC_TIME`, which `LANGUAGE` does not touch. `LC_ALL=en_US.UTF-8` set `LC_TIME` to American, and `LANGUAGE=de:fr:en` redirected only the message lookup.

**A2.3** — Because `LC_ALL` is an unconditional override: once it is exported, no user, script or application can adjust a single category any more — setting `LC_TIME` or `LANG` silently has no effect, which makes the resulting misbehaviour very hard to diagnose. The persistent default belongs in `LANG` (plus specific `LC_*` variables where needed). As a one-shot prefix, `LC_ALL=C cmd` is exactly right: it guarantees a deterministic environment for that single process and disappears afterwards.

**A2.4** — `LANGUAGE`, set to a colon-separated priority list: `export LANGUAGE=fr:es:en`. Note this requires `LC_MESSAGES` (or `LANG`) to be something other than `C`/`POSIX`, or `LANGUAGE` is ignored entirely.

### Exercise 3

**A3.1** — The `C` locale collates by **raw byte value**, so every uppercase ASCII letter (0x41–0x5A) sorts before every lowercase one (0x61–0x7A): `Apricot`, `Banana`, then `apple`, `cherry`. `en_US.UTF-8` collates by the locale's **linguistic rules** (glibc's ISO 14651 tables): letters are compared alphabetically first, with case used only as a lower-priority tiebreaker, so `apple` < `Apricot` (`app` < `apr`) < `Banana` < `cherry`.

**A3.2** — The colleague's `LC_TIME` (or `LANG`) is not English, so `ls` prints a localised month abbreviation (`ago`, `août`, `авг`) that never matches `"Aug"`. Fix: force a stable locale for that command — `LC_ALL=C ls -l ...` — or, better, stop parsing `ls` and use `ls -l --time-style=long-iso` / `stat -c '%y'`, which emit a locale-independent numeric date.

**A3.3** — (1) The decimal separator is a comma, so an importer expecting `1234.56` will misread or reject it. (2) The thousands separator is a period, and in a comma-delimited file a grouped number can also break the field count if quoting is imperfect. Both come from `LC_NUMERIC` (and `LC_MONETARY` for currency-formatted values specifically).

**A3.4** — `tr` asks the C library which characters belong to the `upper` and `lower` classes and how they map, and that mapping lives in `LC_CTYPE`. The `C` locale's character set is ASCII-only, so `Á` is not a member of `[:upper:]` there and has no case mapping — `tr` correctly passes it through untouched. It is not a bug: `tr` is faithfully implementing the locale it was given. (A second consequence: under `LC_ALL=C`, `tr` also operates on single bytes, so multibyte UTF-8 sequences are not even seen as characters.)

### Exercise 4

**A4.1** — `/usr/share/i18n/locales/fr_FR` is the **source definition** — a human-readable specification of the locale's rules. It is not usable at runtime. It must be **compiled** against a charmap into the binary form the C library loads (into `/usr/lib/locale/`, or into the `locale-archive`). `locale -a` lists compiled/installed locales; the source tree lists what *could* be built. `locale-gen` and `localedef` bridge the two.

**A4.2** — `-i` names the **input locale definition** (a file under `/usr/share/i18n/locales`, e.g. `fr_FR`) supplying the language/territory rules: collation, month names, number and currency formats. `-f` names the **charmap** (from `/usr/share/i18n/charmaps`, e.g. `UTF-8`) supplying the character encoding. Together they produce the compiled locale, conventionally named `fr_FR.UTF-8`.

**A4.3** — They are two different fields. The first token, `fr_FR.UTF-8`, is the **name** the finished locale will have (what users put in `LANG`); the second, `UTF-8`, is the **charmap** to compile it against — i.e. `localedef -f UTF-8`. They usually agree, but they need not: `en_US ISO-8859-1` is a valid line producing a locale simply named `en_US`.

**A4.4** — `~/.bashrc` applies only to interactive non-login `bash` shells of one user; it does not affect a graphical session started by a display manager, a `systemd` service, a `cron` job, or programs launched from a desktop menu. `/etc/locale.conf` (read by systemd and applied to the whole system environment, including service units and the graphical session) is the correct place for a system-wide default; on Debian, `/etc/default/locale` plays the same role via PAM's `pam_env`. For a per-user default that also covers graphical logins, `~/.profile` or `~/.config/environment.d/*.conf` is more appropriate than `~/.bashrc`.

**A4.5** — `C.UTF-8` keeps the `C` locale's deterministic, culture-neutral behaviour — byte-order collation, `.` as decimal point, English untranslated messages, ISO-style output — but sets the codeset to UTF-8 so `LC_CTYPE` correctly recognises multibyte characters. `C` is ASCII-only; `en_US.UTF-8` is UTF-8 but imposes American conventions and requires the locale to have been generated. For containers `C.UTF-8` is ideal: it is built into glibc (no `locale-gen` step, no extra image size), it produces stable machine-parsable output, and it does not mangle non-ASCII data.

### Exercise 5

**A5.1** — UTF-8 is variable-width: `m`, `a`, `n`, `a` are 1 byte each, but `ñ` (U+00F1) needs 2 bytes (`c3 b1`). So 5 ASCII letters + 1 two-byte letter + newline = 8 bytes. ISO-8859-1 is a fixed single-byte encoding in which `ñ` is one byte (`f1`), giving 6 + newline = 7 bytes.

**A5.2** — `wc -m` counts **characters**, and what constitutes a character is decided by `LC_CTYPE`. Under `en_US.UTF-8` the library decodes `c3 b1` as one character → 7. Under `C` the codeset is single-byte ASCII, so every byte is one character → 8, the same as `wc -c`. The file never changed; the interpretation did.

**A5.3** — UTF-8 encodes every code point U+0000–U+007F as a single byte with the identical value, and guarantees that no byte of a multibyte sequence ever falls in that range (continuation and lead bytes all have the high bit set). Consequently any pure-ASCII file is already valid UTF-8, byte for byte, and ASCII-based tools that scan for `/`, `\0`, `\n` or `:` keep working unmodified on UTF-8 data. That backwards compatibility — absent in UTF-16 — is why UTF-8 could be adopted incrementally by Unix rather than requiring a flag day.

**A5.4** — Encoding is **not stored in the file**; a text file is just bytes, and the encoding is metadata the reader must supply out of band. `file` only *guesses*, from heuristics about which byte patterns are plausible. Byte `f1` is legal in ISO-8859-1 (`ñ`), in ISO-8859-5 (`ё`), in ISO-8859-2 (`ń`) and in dozens of other single-byte charsets, and nothing in the file distinguishes them. `file` is a useful hint, never an authority. (UTF-8 is the partial exception: its multibyte structure is self-validating, so `file` can distinguish "valid UTF-8" from "not UTF-8" with high confidence — but even then it cannot tell you *which* single-byte charset a non-UTF-8 file uses.)

**A5.5** — ISO-8859-15 (Latin-9) is a revision of ISO-8859-1 (Latin-1) that replaces eight rarely used characters — most notably the generic currency sign `¤` at 0xA4 — with characters Western Europe needed after 1999: the euro sign `€` (now at 0xA4), plus `Š š Ž ž Œ œ Ÿ`. Latin-1 predates the euro and simply has no code point for it, so the conversion cannot succeed. This is the general lesson: a legacy single-byte charset has only 256 slots, and conversion into one fails whenever the source uses a character outside that repertoire.

**A5.6** —
- **Unicode** — the standard that assigns a unique number and set of properties to every character in every writing system; it is a *character set*, not a file format.
- **Code point** — one such number, written `U+00F1`; it is an abstract identity, independent of any byte representation.
- **UTF-8** — a variable-width *encoding* of Unicode code points into 1–4 bytes, ASCII-compatible, byte-order independent; the de facto standard on Linux and the web.
- **UTF-16** — a variable-width encoding into 1 or 2 sixteen-bit units (surrogate pairs above U+FFFF); not ASCII-compatible, requires a byte-order convention (BE/LE, hence the BOM); used internally by Windows and the JVM.

### Exercise 6

**A6.1** — `LC_ALL` (specifically `LC_CTYPE`). glibc's transliteration consults the **locale's transliteration tables**, which live in the locale definition. The `C` locale has essentially none, so glibc falls back to the default replacement character `?` for `é`. A full UTF-8 locale supplies the rule `é → e`. (`€ → EUR` came through in both cases because that mapping is in glibc's built-in default transliteration table rather than a locale-specific one.) Practical consequence: `//TRANSLIT` is not deterministic across environments unless you pin the locale.

**A6.2** — No. `cafe` and `EUR` cannot be mapped back to `café` and `€` — the information is gone, and the transformation is not even injective (`e`, `é`, `è`, `ê` all become `e`). Therefore `//TRANSLIT` is acceptable for producing a *derived*, display-only or index-only artefact (an ASCII slug, a filename, a legacy-system feed) but must never be used on data you intend to keep as the record of truth.

**A6.3** — Both discard the unconvertible characters, so both lose data. The observable difference in glibc is the **diagnostic**: `//IGNORE` still reports the failure on stderr and the command still exits non-zero, whereas `-c` suppresses the message. `-c` is the more dangerous one in a script, because a silent partial conversion looks exactly like a successful one on stdout — and neither form should be trusted without checking `$?` and comparing character counts. (Exit-status behaviour has varied across glibc releases; always verify on your target system rather than assuming.)

**A6.4** — Two reasons. First, `iconv -f ... "$f" > "$f"` truncates `$f` to zero length *before* `iconv` opens it for reading, destroying the input — the classic shell redirection trap. Second, even with a correct read, writing in place means a mid-stream conversion failure leaves a half-converted file with no original to fall back on. Converting to a temporary file and `mv`-ing only on success makes the operation atomic and idempotent: a failed run leaves the source untouched and can be re-run safely. (`iconv -o` avoids the first trap but not the second.)

**A6.5** — Converting **to UTF-8** rather than to ASCII or a legacy single-byte charset. UTF-8 can represent every Unicode code point, so no character is ever unconvertible and no lossy fallback is needed. It is not always available because the *consumer* may be fixed: a legacy mainframe feed, a fixed-width EBCDIC interface, an old device that only accepts ASCII, or a protocol field defined as single-byte. When you cannot change the consumer, `//TRANSLIT` under a pinned locale is the least-bad option — and the loss should be logged.

### Exercise 7

**A7.1** — `/etc/localtime` is (or points to) a **binary TZif file** — compiled timezone data listing historical and future UTC-offset transitions, DST flags and zone abbreviations for one location. The C library reads it whenever a program converts between UTC and local time. A symlink into `/usr/share/zoneinfo/` is preferred because the zone then stays automatically correct when the `tzdata` package is updated (governments change DST rules several times a year); a copy silently freezes stale rules. It also makes the current zone self-documenting: `ls -l /etc/localtime` names it, whereas a copy tells you nothing.

**A7.2** — `/etc/timezone` is a one-line **plain-text** file containing the zone name (`Europe/Madrid`); it is a Debian-family convention and is purely informational metadata for packaging tools. `/etc/localtime` is the **binary TZif data**, and it is the one glibc actually reads for `localtime()`. If they disagree, the *behaviour* follows `/etc/localtime` while *tools that report the zone* may follow `/etc/timezone` — which is exactly how a machine ends up reporting one zone and using another. Keep them in sync; `timedatectl set-timezone` and `dpkg-reconfigure tzdata` do so for you.

**A7.3** — Only the mapping used to render an instant as wall-clock text. The system clock continued counting the same seconds since the Unix epoch, and the RTC was not touched. Changing the symlink changed which TZif file glibc loads, hence which UTC offset and abbreviation are applied at display time.

**A7.4** — `tzselect` is a **read-only discovery aid**. It walks you through continent → country → region and prints the correct IANA zone name, deliberately changing nothing, so it is safe to run as an unprivileged user. You then apply that name yourself — `timedatectl set-timezone "$(tzselect)"`, or by writing the symlink. Its final "this time on standard output" block exists precisely so it can be used in scripts.

**A7.5** — Because the offset is not a stable property of a place. `Europe/Madrid` is UTC+1 in winter and UTC+2 in summer, and both the DST rules and the base offset have changed repeatedly over the last century — Argentina alone has a dozen distinct zone histories, which is why `America/Argentina/` has thirteen entries. A *place-based* identifier lets the tzdata package encode the full transition history, so timestamps in the past render correctly and future ones update automatically when a legislature changes the rules. An offset-based name would be frozen and wrong half the year. Abbreviations like `IST` or `CST` are worse still: they are ambiguous across countries and are output-only, never valid input.

### Exercise 8

**A8.1** — `date +%s` prints **Unix time**: seconds elapsed since 1970-01-01 00:00:00 UTC. It identifies an *instant*, and instants are absolute — the same moment everywhere on Earth. Timezones only affect how that instant is rendered as year/month/day/hour. This is why every log, database timestamp and inter-system exchange should carry UTC or Unix time, converting to local only at the presentation layer.

**A8.2** — In a POSIX `TZ` string, the offset is **the value that must be added to local time to obtain UTC** — the opposite orientation from ISO 8601's `±hh:mm`, which is the value added to UTC to obtain local time. So `XXX-3` means "local − (−3) = UTC", i.e. local is UTC+3 (ahead); `XXX3` means local is UTC−3 (behind). This sign inversion is the classic `TZ` trap; the safe habit is to use IANA zone names (`TZ='Europe/Madrid'`) and reserve POSIX strings for the rare case where no zone name applies.

**A8.3** —
- `EST` — abbreviation for standard time.
- `5` — standard time is UTC−5 (add 5 to local to get UTC).
- `EDT` — abbreviation for daylight time. No number follows, so the offset defaults to standard minus one hour, i.e. UTC−4.
- `M3.2.0` — DST starts on Month 3 (March), week 2, day 0 (Sunday) → the second Sunday of March. Default time 02:00 local.
- `M11.1.0` — DST ends on the first Sunday of November, default 02:00 local.

**A8.4** — `zdump` shows that at 01:00 UTC on 2026-10-25 Madrid steps back from CEST (+0200) to CET (+0100). The wall clock therefore runs 02:00→02:59 twice: once at UTC 00:00–00:59 as CEST, once at UTC 01:00–01:59 as CET. Local time `02:30` on that date is **ambiguous** — it names two distinct instants an hour apart, and only the offset or `isdst` flag disambiguates. The March transition is the mirror image: at 01:00 UTC the clock jumps 02:00→03:00, so local times from 02:00 to 02:59 on 2026-03-29 **do not exist**; a program asked to parse `02:30` there must either reject it or normalise it (GNU `date` normalises). Both cases are why stored timestamps should be UTC and why "local time + date" is never a valid primary key.

**A8.5** — Any of:
- Generating a report or invoice that must be rendered in a customer's or branch office's timezone, while the server itself stays on UTC.
- Reproducing a bug that only manifests in a particular zone (DST boundary, half-hour offset like `Asia/Kolkata`, a zone that crossed the date line).
- Running a batch job whose schedule is defined in a business timezone on a UTC-configured host.
- Comparing log timestamps from a remote system that reports local time.

In all of these the *system* timezone must remain what operations and logging depend on; changing `/etc/localtime` would silently rewrite the rendering of every other service on the box, including the system journal and cron's interpretation of schedules.

### Exercise 9

**A9.1** — The **hardware clock** (RTC / CMOS clock), a battery-backed counter on the motherboard that keeps running while the machine is powered off; and the **system clock**, maintained by the kernel in memory, seeded from the RTC at boot and thereafter disciplined by NTP. Only the RTC survives a power cut.

**A9.2** — The RTC's stored value is then interpreted as Madrid wall-clock time rather than UTC, and the kernel applies the timezone offset at boot to derive UTC. Concrete breakage: if that assumption is wrong the system clock is off by the current offset (1–2 hours), which cascades into TLS certificate validation failures, Kerberos ticket rejection, `make` rebuilding everything or nothing, and log timestamps that do not correlate across hosts. Even when the setting *matches* reality, DST transitions become an active problem — see A9.3.

**A9.3** — UTC has no DST; it advances monotonically. An RTC in UTC therefore needs no adjustment when the clocks change — only the display mapping changes. An RTC in local time must physically be rewritten at each transition, and that creates two failure modes the system cannot resolve on its own: during the autumn overlap the stored value is **ambiguous** (the same local hour occurs twice, so a machine booted in that window cannot tell which), and a machine powered off across a transition has no opportunity to make the adjustment at all. This is why `timedatectl set-local-rtc 1` prints an explicit warning that the mode "cannot be fully supported"; the only real justification is a dual-boot with an older Windows installation that assumes local time.

**A9.4** — `hwclock --hctosys` copies **hardware → system**: use it at boot on a machine with no network/NTP, or after replacing the RTC battery and setting the RTC from firmware. `hwclock --systohc` copies **system → hardware**: use it after correcting the system clock (manually or via NTP) so the good value survives the next power cycle — traditionally run at shutdown. Systems running `systemd-timesyncd` or `chronyd` normally handle `--systohc` automatically.

### Exercise 10

**A10.1** — In the **combination**, not in either endpoint. The client legitimately declares its locale; the server legitimately does not have every locale on earth generated. SSH's `SendEnv`/`AcceptEnv` pair joins them, and the mismatch surfaces only on the server, at process start, when `setlocale()` fails and the library falls back to `C`. Nothing is broken in isolation — which is exactly why the report is usually "it only happens when I SSH in".

**A10.2** — `SendEnv LANG LC_*` in the **client's** `/etc/ssh/ssh_config` (or `~/.ssh/config`), and `AcceptEnv LANG LC_*` in the **server's** `/etc/ssh/sshd_config`. Both are required: the client must offer the variables and the server must accept them.

**A10.3** — Smallest blast radius first:
1. **Generate the locale on the server** — affects only that host, fixes the problem properly for every user, and leaves everyone's locale working as intended. Correct in principle.
2. **Remove `SendEnv` on the client** — affects only that one client, but breaks the client's locale on *every* server it connects to, including ones where it worked.
3. **Remove `AcceptEnv` on the server** — affects every user of that server, silently downgrading them all to the server's default locale.

On 300 servers, do not do any of these by hand. Standardise the fleet's locale set through configuration management (Ansible/Puppet/image build) — generating `en_US.UTF-8` plus `C.UTF-8` everywhere, or, in a containerised fleet, standardising on `C.UTF-8` which needs no generation at all. The per-host fix is right; doing it 300 times manually is not.

**A10.4** — It **gains** determinism: byte-order collation, `.` as the decimal separator, English untranslated messages, and locale-independent formatting, so `awk`'s field positions and any string matching behave identically on every machine the script lands on. It **keeps** UTF-8 character handling, so filenames, log lines and user data containing non-ASCII characters are still processed as characters rather than mangled into individual bytes — the thing plain `LC_ALL=C` would sacrifice.

**A10.5** — It neutralises `LC_TIME`. Relying on `LC_ALL` alone is more fragile because it depends on the environment surviving intact all the way to the child process — a wrapper, a `sudo` with `env_reset`, a `systemd` unit's `Environment=`, an SSH-forwarded `LC_*`, or a `cron` job's minimal environment can each override or drop it. `--time-style=long-iso` asks `ls` for an unambiguous `YYYY-MM-DD HH:MM` format directly, so the output is correct regardless of what locale actually reaches the process. Belt and braces: set the locale *and* request explicit formats, and where possible avoid parsing human-oriented output altogether (`stat -c`, `find -printf`, `date -u +%s`).

</details>