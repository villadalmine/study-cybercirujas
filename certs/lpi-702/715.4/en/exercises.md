# LPI 702-100 (v1.0) Study Guide: Topic 715.4 - Use Simple Regular Expressions

**Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic:** 715.4 Use Simple Regular Expressions  
**Weight:** 3.33  
**Official Reference:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## Technical Deep-Dive & Architecture

### 1. Regex Engine Mechanics in BSD Unix
Modern BSD operating systems (FreeBSD, OpenBSD, NetBSD) process regular expressions using compile-and-execute engines based on POSIX specifications (`regex(3)` standard C library interface). Regular expression engines are categorized into two primary architectural models:

1. **Deterministic Finite Automata (DFA):**
   - Translates regular expressions into state transition tables.
   - Guarantees $O(N)$ execution time relative to input string length $N$.
   - Does not support backreferences (`\1`, `\2`) or lookaround assertions.
   - Standard BSD `grep` utilizes a primary fast DFA matcher to scan log files rapidly.

2. **Non-deterministic Finite Automata (NFA):**
   - Evaluates state pathways dynamically and uses **backtracking** when a branch fails to match.
   - Worst-case time complexity can escalate to exponential $O(2^N)$ (catastrophic backtracking) with improperly bounded quantifiers.
   - Evaluates standard POSIX Basic Regular Expressions (BRE) and Extended Regular Expressions (ERE) when advanced features (such as subexpression grouping and backreferencing) are invoked.

```
                     +---------------------------------------+
                     |         Input Text Stream             |
                     +---------------------------------------+
                                         |
                                         v
                     +---------------------------------------+
                     |       POSIX regex(3) Compiler         |
                     |  (Parse Pattern -> AST -> Automata)   |
                     +---------------------------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
         +---------------------------+       +---------------------------+
         |     DFA Fast Engine       |       |   NFA Backtracking Engine |
         |   (Literal / Fixed Set)   |       |  (Subexpressions / BRE)   |
         |   Linear Time: O(N)       |       |   Supports Backreferences |
         +---------------------------+       +---------------------------+
                       |                                   |
                       +-----------------+-----------------+
                                         |
                                         v
                     +---------------------------------------+
                     |      Matched Line / Output Buffer     |
                     +---------------------------------------+
```

### 2. POSIX Standards: Basic (BRE) vs. Extended (ERE) Metacharacters

POSIX standardizes two regex dialects across BSD core utilities (`grep`, `sed`, `awk`):

| Feature / Metacharacter | Basic Regular Expression (BRE) | Extended Regular Expression (ERE) |
| :--- | :--- | :--- |
| **Literal Characters** | `a-z`, `A-Z`, `0-9`, `_` | `a-z`, `A-Z`, `0-9`, `_` |
| **Any Single Character** | `.` | `.` |
| **Zero or More Repetitions**| `*` | `*` |
| **One or More Repetitions** | `\+` (BSD extension) | `+` |
| **Zero or One Repetition** | `\?` (BSD extension) | `?` |
| **Interval Quantifier** | `\{m,n\}` | `{m,n}` |
| **Group / Subexpression** | `\(` ... `\)` | `(` ... `)` |
| **Alternation (OR)** | `\|` (BSD extension) | `\|` |
| **Line Start Anchor** | `^` | `^` |
| **Line End Anchor** | `$` | `$` |
| **Word Boundary Anchor** | `\<`, `\>` or `[[:<:]]`, `[[:>:]]` | `\<`, `\>` or `[[:<:]]`, `[[:>:]]` |

> [!IMPORTANT]
> In **BRE** (used by default in standard BSD `grep` and `sed`), grouping parentheses `(` `)` and interval bounds `{` `}` are treated as literal characters unless escaped with a backslash (`\(` `\)`, `\{m,n\}`). In **ERE** (invoked with `grep -E` or `egrep`), these characters are metacharacters by default, and backslashes remove their special meaning.

### 3. POSIX Bracket Expressions & Character Classes
Using ranges like `[a-z]` or `[0-9]` can introduce subtle bugs when locale settings (`LC_COLLATE`) differ from standard ASCII ordering. POSIX character classes ensure predictable, locale-independent evaluation:

- `[[:alnum:]]`: Alphanumeric characters (`[A-Za-z0-9]`)
- `[[:alpha:]]`: Alphabetic characters (`[A-Za-z]`)
- `[[:digit:]]`: Numeric characters (`[0-9]`)
- `[[:space:]]`: Whitespace characters (space, tab, newline, vertical tab, form feed)
- `[[:xdigit:]]`: Hexadecimal digits (`[0-9a-fA-F]`)
- `[[:punct:]]`: Punctuation characters (`!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`)

Negation inside character sets is declared using a caret immediately after the opening bracket:
- `[^0-9]`: Any character that is **not** a digit.
- `[^[:space:]]`: Any non-whitespace character.

### 4. Shell Globbing vs. Regular Expressions

A fundamental failure mode in SRE operations stems from confusing **Shell Globbing** (pathname expansion executed by standard BSD shells like `/bin/sh`, `/bin/csh`, or `/bin/zsh`) with **Regular Expressions** (string content parsing executed by `grep`, `sed`, or `awk`).

```
                    +------------------------------------------+
                    |   User Shell Command Execution Path      |
                    +------------------------------------------+
                                         |
                                         v
                    +------------------------------------------+
                    |           Phase 1: Shell Expansion       |
                    | Parses unquoted globs (*, ?, [...])      |
                    | against the local filesystem directory.  |
                    +------------------------------------------+
                                         |
                                         v
                    +------------------------------------------+
                    |      Phase 2: Process Invocation         |
                    | Passes expanded ARGV array to `grep`.   |
                    +------------------------------------------+
                                         |
                                         v
                    +------------------------------------------+
                    |            Phase 3: Regex Match          |
                    | `grep` compiles string argument into NFA |
                    | engine and reads file stream contents.   |
                    +------------------------------------------+
```

Key operational differences:

1. **Evaluation Timing:** Globs are evaluated by the shell *before* the command runs. Regular expressions are evaluated by the targeted process line-by-line *during* file reading.
2. **`*` Quantifier Meaning:**
   - Shell Globbing: `*` matches **zero or more arbitrary characters** in filenames (e.g., `*.log`).
   - Regular Expressions: `*` modifies the preceding token to match **zero or more occurrences** of that specific element (e.g., `a*` matches `""`, `"a"`, `"aa"`).
3. **`?` Character Meaning:**
   - Shell Globbing: `?` matches **exactly one character** (e.g., `file?.txt`).
   - Regular Expressions (ERE): `?` denotes **zero or one occurrence** of the preceding atom.

---

## Guided Production Exercises

### Environment Initialization
Execute the following block on a BSD host or standard POSIX terminal to generate the realistic multi-tenant enterprise audit log required for these exercises:

```bash
cat << 'EOF' > /tmp/sre_audit.log
2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
2026-08-06T14:00:02Z host-02 sysctl: kern.securelevel changed from 1 to 2
2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
2026-08-06T14:01:00Z host-02 pkg: upgraded nginx-1.24.0,1 to nginx-1.26.1,1
2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
2026-08-06T14:02:00Z host-04 kernel: arprequest: cannot find matching subnet for 172.16.0.5
2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
EOF
```

---

### Exercise 1: Basic Matching, Anchoring & Line Selection (BRE)

#### Objective
Master anchor operators (`^`, `$`) and line filter switches (`-v`, `-n`, `-c`) using Basic Regular Expressions to extract telemetry data accurately.

#### Steps to Execute

1. **Match lines starting with a specific timestamp hour:**
   Extract all log entries occurring during the `14:01` minute mark using the start-of-line anchor (`^`).

   ```bash
   grep '^2026-08-06T14:01' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:01:00Z host-02 pkg: upgraded nginx-1.24.0,1 to nginx-1.26.1,1
   2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
   ```

2. **Match lines terminating with a specific word:**
   Filter all entries ending with `ssh2` using the end-of-line anchor (`$`).

   ```bash
   grep 'ssh2$' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   ```

3. **Invert match to isolate non-firewall events with line numbers:**
   Use `-v` to exclude packet filter (`pf:`) entries and `-n` to display line numbers for audit tracking.

   ```bash
   grep -v -n 'pf:' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2:2026-08-06T14:02Z host-02 sysctl: kern.securelevel changed from 1 to 2
   4:2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   5:2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   7:2026-08-06T14:01:00Z host-02 pkg: upgraded nginx-1.24.0,1 to nginx-1.26.1,1
   9:2026-08-06T14:02:00Z host-04 kernel: arprequest: cannot find matching subnet for 172.16.0.5
   10:2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

4. **Count total firewall blockage events:**
   Count lines matching the literal pattern `[BLOCK]`. Note that brackets must be escaped in BRE or included in a character class to avoid treating them as set delimiters.

   ```bash
   grep -c '\[BLOCK\]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   3
   ```

---

#### Verification Questions - Exercise 1

1. If you run the command `grep '^' /tmp/sre_audit.log`, what will be returned and why?
2. What is the technical difference between running `grep 'SYN' /tmp/sre_audit.log` versus `grep 'SYN$' /tmp/sre_audit.log`?
3. What occurs if a user executes `grep [BLOCK] /tmp/sre_audit.log` without single quotes or backslashes in a directory containing a file named `B`?

---

### Exercise 2: Character Sets, Negation & POSIX Classes

#### Objective
Utilize custom character ranges (`[...]`), negated sets (`[^...]`), and POSIX brackets (`[[:digit:]]`, `[[:alpha:]]`) to extract structured indicators of compromise (IOCs).

#### Steps to Execute

1. **Extract log lines originating from specific host instances:**
   Filter for `host-01` and `host-03` using a character set.

   ```bash
   grep 'host-0[13]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
   2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
   2026-08-06T14:02:05Z host-03 sshd[4825]: Accepted publickey for admin... -> host-03 lines
   ```

2. **Match non-internal source IP network traffic:**
   Find firewall log entries where the external IP address does **not** begin with `192.` or `10.`. Use a negated character class.

   ```bash
   grep 'src=[^1]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
   ```

3. **Isolate process identifiers using POSIX character classes:**
   Locate all lines containing `sshd` with its associated Process ID enclosed in brackets using `[[:digit:]]`.

   ```bash
   grep 'sshd\[[[:digit:]][[:digit:]][[:digit:]][[:digit:]]\]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

---

#### Verification Questions - Exercise 2

1. How does the regex `[^0-9]` differ fundamentally from `^0-9` when evaluated inside a BRE pattern engine?
2. What is the outcome of using the expression `[a-z]` under a non-C locale (e.g., `en_US.UTF-8`) versus using `[[:lower:]]`?
3. Write a regular expression using POSIX character classes to match any log line containing a 3-character protocol identifier (e.g., `tcp`, `udp`).

---

### Exercise 3: Extended Regular Expressions (ERE), Bounded Repetition & Word Boundaries

#### Objective
Leverage ERE (`grep -E`), explicit bounds (`{m,n}`), alternation (`|`), and word anchors (`\<`, `\>`) to analyze complex security patterns.

#### Steps to Execute

1. **Filter multiple protocol types using ERE Alternation:**
   Extract log lines detailing either `udp` or `icmp` events using `grep -E`.

   ```bash
   grep -E 'proto=(udp|icmp)' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
   ```

2. **Match exact IPv4 octet bounds with interval quantifiers:**
   Match IP addresses starting with `192.168.` followed by a 1-to-3 digit host address.

   ```bash
   grep -E '192\.168\.1\.[0-9]{1,3}' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

3. **Enforce exact word boundary matching:**
   Demonstrate the difference between matching the substring `port` and the exact word `port` bounded by BSD word anchors (`\<` and `\>`).

   ```bash
   grep -E '\<port\>' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
   2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

---

#### Verification Questions - Exercise 3

1. Why does the command `grep 'proto=(udp|icmp)' /tmp/sre_audit.log` (without `-E`) fail to return matches on a standard BSD system?
2. What BSD POSIX word boundary syntax is equivalent to `\<` and `\>`?
3. Explain the difference in execution between `grep -E 'go*d'` and `grep -E 'go+d'` when parsing strings such as `"gd"`, `"god"`, and `"good"`.

---

### Exercise 4: Stream Transformation & Parsing via `sed` and `awk`

#### Objective
Apply regular expressions within non-interactive stream editor (`sed`) and tabular pattern scanner (`awk`) pipelines.

#### Steps to Execute

1. **Extract and reformat IP addresses using `sed` capture groups (BRE):**
   Parse `sshd` log entries and extract only the source IP address using subexpression capture groups (`\(` ... `\)`).

   ```bash
   sed -n 's/.*from \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/SRC_IP: \1/p' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   SRC_IP: 192.168.1.120
   SRC_IP: 192.168.1.50
   SRC_IP: 192.168.1.200
   ```

2. **Filter and print specific fields using `awk` regex conditional matching:**
   Use `awk` to match lines containing `[BLOCK]` and print the timestamp (field 1) and host name (field 2).

   ```bash
   awk '/\[BLOCK\]/ {print $1, $2, $5}' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:05Z host-01 src=45.33.32.156
   2026-08-06T14:00:22Z host-01 src=192.168.1.188
   2026-08-06T14:01:30Z host-01 src=10.0.0.50
   ```

---

#### Verification Questions - Exercise 4

1. In the `sed` substitution command `s/pattern/replacement/p`, what is the function of the trailing `/p` flag when paired with the `-n` option?
2. How does `awk` handle regular expression evaluation when using the `~` operator (e.g., `$5 ~ /src=192/`) versus plain pattern matching `/src=192/`?

---

## Production Diagnostics & Performance Optimization

### 1. High-Throughput Log Search via Locale Optimization (`LC_ALL=C`)
In multi-gigabyte production log parsing pipelines on BSD hosts, default UTF-8 locale settings force `grep` to inspect character byte sequences to determine multi-byte Unicode boundaries.

To optimize throughput for standard ASCII log files, explicitly override the locale to the binary `C` (POSIX) locale:

```bash
# Standard UTF-8 processing (slower, multibyte lookup overhead)
time grep -E 'src=192\.168\.[0-9]{1,3}\.[0-9]{1,3}' /var/log/security.log

# Production SRE High-Speed Execution (up to 10x - 100x performance gain)
time LC_ALL=C grep -E 'src=192\.168\.[0-9]{1,3}\.[0-9]{1,3}' /var/log/security.log
```

**Technical Reason:** `LC_ALL=C` bypasses complex `mbrtowc` multibyte translation tables, enabling BSD `grep` to perform direct, single-byte memory scans using raw `memchr` and string instruction primitives.

### 2. BSD `grep` vs. GNU `grep` Flag Differences
System administrators migrating across Linux and BSD environments must recognize syntax constraints:

- BSD `grep` utilizes `[[:<:]]` and `[[:>:]]` or `\<` and `\>` for word boundaries.
- GNU extensions like `\s` (whitespace) or `\d` (digit) are non-standard in POSIX BRE/ERE. Production scripts designed for portability across FreeBSD, OpenBSD, and Linux must use POSIX character classes (`[[:space:]]`, `[[:digit:]]`) rather than Perl-compatible shims (`\s`, `\d`).

---

## Verification Answer Key

<details>
<summary>Click to expand Answer Key</summary>

### Exercise 1 Answers

1. **Question:** If you run `grep '^' /tmp/sre_audit.log`, what will be returned and why?  
   **Answer:** Every line in the file will be returned. The caret `^` anchors the search to the start of the line. Since every line has a beginning position (even an empty line), every line matches.

2. **Question:** What is the technical difference between `grep 'SYN' /tmp/sre_audit.log` vs `grep 'SYN$' /tmp/sre_audit.log`?  
   **Answer:** `grep 'SYN'` matches the literal character sequence "SYN" anywhere within a line (e.g., `SYN_SENT`, `SYN-ACK`, or at the end of a line). `grep 'SYN$'` strictly matches lines where "SYN" occurs as the final three characters before the newline.

3. **Question:** What occurs if a user executes `grep [BLOCK] /tmp/sre_audit.log` without single quotes or backslashes in a directory containing a file named `B`?  
   **Answer:** The BSD shell performs glob expansion on unquoted `[BLOCK]` *before* executing `grep`. If a file named `B` exists in the current working directory, the shell expands `[BLOCK]` (which matches one character among B, L, O, C, K) to `B`. `grep` then executes as `grep B /tmp/sre_audit.log`, searching for lines containing the letter 'B' instead of searching for the literal string "[BLOCK]".

---

### Exercise 2 Answers

1. **Question:** How does `[^0-9]` differ fundamentally from `^0-9` inside a BRE pattern engine?  
   **Answer:** `[^0-9]` uses `^` as the first character inside brackets to denote set **negation**, matching any single character that is *not* a digit. `^0-9` uses `^` outside of brackets as a **line-start anchor**, attempting to match a line that literally begins with "0-9".

2. **Question:** What is the outcome of using `[a-z]` under a non-C locale (e.g., `en_US.UTF-8`) versus `[[:lower:]]`?  
   **Answer:** Under non-C collation rules, `[a-z]` can match uppercase characters depending on dictionary sorting order (e.g., `a, A, b, B... z`). `[[:lower:]]` explicitly forces the POSIX regex engine to reference the locale's lowercase character set property, guaranteeing isolation of lowercase alphabetic characters.

3. **Question:** Write a regular expression using POSIX character classes to match any log line containing a 3-character protocol identifier (e.g., `tcp`, `udp`).  
   **Answer:** `proto=[[:alpha:]]{3}` (when evaluated with ERE) or `proto=[[:alpha:]]\{3\}` (when evaluated with BRE). Alternatively: `proto=[[:lower:]][[:lower:]][[:lower:]]`.

---

### Exercise 3 Answers

1. **Question:** Why does `grep 'proto=(udp|icmp)' /tmp/sre_audit.log` (without `-E`) fail to return matches on a standard BSD system?  
   **Answer:** Standard `grep` defaults to Basic Regular Expressions (BRE). In BRE, unescaped `(` `)` and `|` are treated as literal characters. To treat them as metacharacters for grouping and alternation under BRE, they must be escaped (`\(` `\)`, `\|`), or the command must enable Extended Regular Expressions using `grep -E`.

2. **Question:** What BSD POSIX word boundary syntax is equivalent to `\<` and `\>`?  
   **Answer:** `[[:<:]]` (start of word) and `[[:>:]]` (end of word).

3. **Question:** Explain the difference in execution between `grep -E 'go*d'` and `grep -E 'go+d'`.  
   **Answer:** The `*` quantifier matches **zero or more** occurrences of 'o'. Thus, `go*d` matches `"gd"`, `"god"`, and `"good"`. The `+` quantifier matches **one or more** occurrences of 'o'. Thus, `go+d` matches `"god"` and `"good"`, but fails to match `"gd"`.

---

### Exercise 4 Answers

1. **Question:** In `sed -n 's/pattern/replacement/p'`, what is the function of `/p` when paired with `-n`?  
   **Answer:** The `-n` flag suppresses `sed`'s default behavior of printing every line in the input buffer to stdout. The trailing `/p` flag instructs `sed` to print *only* lines where a successful regex substitution occurred.

2. **Question:** How does `awk` handle evaluation when using `$5 ~ /src=192/` versus `/src=192/`?  
   **Answer:** `/src=192/` evaluates the regex against the **entire record** (`$0`, the entire line). `$5 ~ /src=192/` restricts regex evaluation specifically to the contents of **field 5**, returning true only if field 5 matches the pattern.

</details>