# Guided Exercises — Topic 3.2: Searching and Extracting Data from Files

**Certification:** LPI Linux Essentials (010-160, v1.6) · **Exam weight:** 3

Work through each block in a terminal. Type every command yourself — don't copy-paste — and observe the output before answering the questions.

---

## Exercise 1: Setting up a playground

To practice searching and extracting, you need something to search. Build a small lab with a few realistic text files.

1. Create a working directory and move into it:
   ```bash
   mkdir ~/search-lab
   cd ~/search-lab
   ```
2. Create a plain word list:
   ```bash
   cat > fruits.txt << EOF
   apple
   Banana
   cherry
   banana
   Apple
   date
   EOF
   ```
3. Create a colon-separated "user database", similar in shape to `/etc/passwd`:
   ```bash
   cat > users.txt << EOF
   ana:1001:developer
   bruno:1002:designer
   carla:1003:developer
   diego:1004:manager
   elena:1005:developer
   EOF
   ```
4. Create a small log file:
   ```bash
   cat > app.log << EOF
   2026-07-01 10:02 INFO  service started
   2026-07-01 10:05 ERROR disk almost full
   2026-07-01 10:07 INFO  user ana logged in
   2026-07-01 10:12 WARN  slow response time
   2026-07-01 10:15 ERROR connection refused
   2026-07-01 10:20 INFO  user bruno logged in
   EOF
   ```
5. Confirm everything is in place:
   ```bash
   ls -l
   cat fruits.txt users.txt app.log
   ```

**Questions**

- **1a.** `cat` is short for *concatenate*. Based on step 5, what does `cat` do when given more than one filename?
- **1b.** In step 2, `cat > fruits.txt << EOF` reads what you type and writes it into the file. Which character told the shell to send `cat`'s output into a file instead of onto the screen?

---

## Exercise 2: Viewing the right part of a file — head, tail, less

Real files (logs especially) are often too long to read whole. These tools show you just the slice you need.

1. Show only the first two lines of the log:
   ```bash
   head -n 2 app.log
   ```
2. Show only the last two lines:
   ```bash
   tail -n 2 app.log
   ```
   By default, `head` and `tail` show 10 lines; `-n` changes the count.
3. Watch a file as it grows — the classic way to monitor a live log. In this terminal run:
   ```bash
   tail -f app.log
   ```
   Open a **second** terminal and append a line:
   ```bash
   echo "2026-07-01 10:25 INFO  user carla logged in" >> ~/search-lab/app.log
   ```
   The new line appears in the first terminal immediately. Press `Ctrl+C` there to stop following.
4. Open a longer file in the pager and navigate it:
   ```bash
   less /etc/services
   ```
   Move with the arrow keys, `Space` (page down), `b` (page up). Type `/tcp` and press Enter to search forward; press `n` to jump to the next match. Press `q` to quit.

**Questions**

- **2a.** Which command shows the *beginning* of a file and which shows the *end*? What option controls how many lines?
- **2b.** What does `tail -f` do, and why is it especially useful with log files?
- **2c.** Inside `less`, how do you search for a word, jump to the next match, and quit?

---

## Exercise 3: Redirection — sending output where you want it

Every command has three standard streams: **stdin** (0, input), **stdout** (1, normal output), and **stderr** (2, error messages). The shell can redirect each of them.

1. Redirect stdout to a file, then check the result:
   ```bash
   ls -l > listing.txt
   cat listing.txt
   ```
2. See the difference between overwrite and append:
   ```bash
   echo "first line" > notes.txt
   echo "second line" > notes.txt
   cat notes.txt
   echo "third line" >> notes.txt
   cat notes.txt
   ```
3. Produce an error on purpose and observe that `>` does *not* capture it:
   ```bash
   ls nosuchfile > out.txt
   cat out.txt
   ```
   The error message still reached your screen — it traveled on stderr, not stdout.
4. Now redirect the error stream, and then both streams:
   ```bash
   ls nosuchfile 2> errors.txt
   cat errors.txt
   ls fruits.txt nosuchfile > all.txt 2>&1
   cat all.txt
   ```
5. Throw unwanted output away by sending it to the bit bucket:
   ```bash
   ls nosuchfile 2> /dev/null
   ```
6. Redirect a file *into* a command's stdin:
   ```bash
   wc -l < fruits.txt
   ```

**Questions**

- **3a.** What is the difference between `>` and `>>`?
- **3b.** In step 3, why did the error message appear on screen even though output was redirected with `>`?
- **3c.** What do `2>`, `2>&1`, and `/dev/null` each mean?
- **3d.** Notice that `wc -l < fruits.txt` prints a count but no filename, while `wc -l fruits.txt` prints both. Why might that be?

---

## Exercise 4: Pipes — connecting commands together

A pipe (`|`) connects one command's stdout to the next command's stdin, letting small tools combine into powerful one-liners.

1. Count how many entries are in your user database:
   ```bash
   cat users.txt | wc -l
   ```
   (The same result comes from `wc -l users.txt` — pipes shine when there are more steps.)
2. Sort the fruit list and look closely at the order:
   ```bash
   sort fruits.txt
   ```
   Depending on your locale, uppercase and lowercase may be grouped together or apart. Compare with a reversed sort:
   ```bash
   sort -r fruits.txt
   ```
3. Chain three commands: sort the fruits, then take only the first three of the sorted result:
   ```bash
   sort fruits.txt | head -n 3
   ```
4. Count words and characters, not just lines:
   ```bash
   wc app.log
   wc -w app.log
   wc -c app.log
   ```
   The three numbers from plain `wc` are lines, words, and bytes.
5. Combine a pipe with redirection — sorted output saved to a file:
   ```bash
   sort fruits.txt | tail -n 2 > last-fruits.txt
   cat last-fruits.txt
   ```

**Questions**

- **4a.** In your own words, what does the `|` operator do?
- **4b.** What three numbers does plain `wc file` print, in what order?
- **4c.** In step 5, data flowed through `sort`, then `tail`, then into a file. Which part of the line was a pipe and which part was a redirection?

---

## Exercise 5: Extracting columns with cut

`cut` slices each line into fields and keeps only the ones you ask for — ideal for structured files like `users.txt` or `/etc/passwd`.

1. Extract just the usernames (field 1, fields separated by `:`):
   ```bash
   cut -d ':' -f 1 users.txt
   ```
   `-d` sets the **d**elimiter, `-f` picks the **f**ield(s).
2. Extract two fields at once — name and role:
   ```bash
   cut -d ':' -f 1,3 users.txt
   ```
3. Apply it to a real system file — the login name and shell of every account:
   ```bash
   cut -d ':' -f 1,7 /etc/passwd
   ```
4. Build a pipeline: list every role in the file, sorted:
   ```bash
   cut -d ':' -f 3 users.txt | sort
   ```

**Questions**

- **5a.** What do the `-d` and `-f` options of `cut` mean?
- **5b.** What is the default delimiter of `cut` if you don't pass `-d`? (Try `cut -f 1 users.txt` and see what happens.)
- **5c.** Write a single pipeline that prints the usernames from `users.txt` in reverse alphabetical order.

---

## Exercise 6: Searching inside files with grep

`grep` prints the lines of a file that match a pattern — the everyday workhorse of log analysis and troubleshooting.

1. Find all error lines in the log:
   ```bash
   grep ERROR app.log
   ```
2. Search case-insensitively, and show line numbers:
   ```bash
   grep -i error app.log
   grep -n ERROR app.log
   ```
3. Invert the match — everything that is *not* an INFO line:
   ```bash
   grep -v INFO app.log
   ```
4. Count matches instead of printing them:
   ```bash
   grep -c ERROR app.log
   ```
5. Use grep at the end of a pipeline — which developers are in the user database?
   ```bash
   cut -d ':' -f 1,3 users.txt | grep developer
   ```
6. Try a pattern that matches nothing and note the (lack of) output:
   ```bash
   grep FATAL app.log
   ```

**Questions**

- **6a.** What do the grep options `-i`, `-v`, `-n`, and `-c` each do?
- **6b.** How many lines does `grep -v INFO app.log` print on the original six-line log, and which ones are they?
- **6c.** In step 5, why does grep work even though no filename was given to it?

---

## Exercise 7: Basic regular expressions

grep's patterns are **regular expressions** (regex) — a mini-language where some characters have special meanings: `.` matches any single character, `[...]` matches one character from a set, `*` means "the previous item, zero or more times", `^` anchors to the start of the line, and `$` anchors to the end.

1. Anchor to the start of a line — fruits that begin with lowercase `b`:
   ```bash
   grep '^b' fruits.txt
   ```
   Note that `Banana` is not matched. Quote your patterns (as here) so the shell doesn't interpret the special characters itself.
2. Anchor to the end — fruits ending in `e`:
   ```bash
   grep 'e$' fruits.txt
   ```
3. Use a character set — lines starting with `a` or `A`:
   ```bash
   grep '^[aA]' fruits.txt
   ```
4. Use the any-character dot — a `d`, then any two characters, then `e`:
   ```bash
   grep 'd..e' fruits.txt
   ```
5. Use `*` for repetition — `an` followed by zero or more `a`s, at the end of a line:
   ```bash
   grep 'ana*$' fruits.txt
   ```
6. Combine anchors to find empty lines (there shouldn't be any — add one to `fruits.txt` with `echo "" >> fruits.txt` and rerun):
   ```bash
   grep -c '^$' fruits.txt
   ```
7. Match a literal dot by escaping it. First see the problem, then the fix:
   ```bash
   echo "version 2.5 released" > release.txt
   echo "version 245 released" >> release.txt
   grep '2.5' release.txt
   grep '2\.5' release.txt
   ```

**Questions**

- **7a.** What do `^`, `$`, `.`, `[...]`, and `*` each mean in a regular expression?
- **7b.** In step 7, why did `grep '2.5'` match *both* lines, and how did `2\.5` fix it?
- **7c.** Which of these lines match the pattern `^[bB]anana$`: `banana`, `Banana`, `bananas`, `a banana`?
- **7d.** Why should regex patterns be wrapped in single quotes on the command line?

---

## Exercise 8: Putting it all together, then cleaning up

1. A realistic mini-task: from the log, extract the timestamps (first two fields, space-separated) of every ERROR, sorted:
   ```bash
   grep ERROR app.log | cut -d ' ' -f 1,2 | sort
   ```
2. Count how many distinct severities appear — extract field 3, sort it, inspect visually:
   ```bash
   cut -d ' ' -f 3 app.log | sort
   ```
3. Remove the lab:
   ```bash
   cd ~
   rm -r ~/search-lab
   ```

**Questions**

- **8a.** Describe, stage by stage, what flows through the pipeline in step 1.
- **8b.** Using only tools from this topic, how would you count the number of accounts on your system whose shell is `/bin/bash`? (Hint: `/etc/passwd`, `grep`, `wc`.)

---

<details>
<summary><strong>Answers</strong></summary>

- **1a.** `cat` reads each file in order and writes their contents to standard output one after another — it concatenates them into a single stream.
- **1b.** The `>` character. It redirects the command's standard output into the named file instead of to the terminal.

- **2a.** `head` shows the beginning, `tail` shows the end; both default to 10 lines and take `-n <count>` to change that.
- **2b.** `tail -f` keeps the file open and prints new lines as they are appended ("follow" mode). Logs grow continuously, so it lets you watch events in real time.
- **2c.** Type `/pattern` and Enter to search forward, `n` for the next match, and `q` to quit.

- **3a.** `>` truncates the target file and writes from scratch (overwrite); `>>` appends to the end, preserving existing content.
- **3b.** `>` redirects only stdout (stream 1). Error messages travel on stderr (stream 2), which was still connected to the terminal, so the message appeared on screen and `out.txt` stayed empty.
- **3c.** `2>` redirects stderr to a file; `2>&1` redirects stderr to wherever stdout is currently going, so both streams end up together; `/dev/null` is a special device that discards everything written to it.
- **3d.** With `< fruits.txt`, the shell opens the file and feeds it to `wc` on stdin — `wc` never sees a filename, so it can't print one. With `wc -l fruits.txt`, `wc` opens the file itself and knows its name.

- **4a.** `|` connects the standard output of the command on its left to the standard input of the command on its right, so data flows between them without a temporary file.
- **4b.** Lines, then words, then bytes.
- **4c.** `sort fruits.txt | tail -n 2` is the pipe (command to command); `> last-fruits.txt` is the redirection (command to file).

- **5a.** `-d` sets the field delimiter (the character that separates columns); `-f` selects which field number(s) to output.
- **5b.** The default delimiter is the Tab character. Since `users.txt` contains no tabs, `cut -f 1 users.txt` prints each whole line unchanged.
- **5c.** `cut -d ':' -f 1 users.txt | sort -r`

- **6a.** `-i` ignores case, `-v` inverts the match (prints non-matching lines), `-n` prefixes each match with its line number, `-c` prints only the count of matching lines.
- **6b.** Three lines: the two ERROR lines and the WARN line — every line that does not contain `INFO`.
- **6c.** With no filename, grep reads standard input; the pipe feeds it the output of `cut`. This is what makes grep composable in pipelines.

- **7a.** `^` anchors the match to the start of the line; `$` anchors to the end; `.` matches any single character; `[...]` matches exactly one character from the listed set; `*` repeats the previous item zero or more times.
- **7b.** In a regex, `.` means "any character", so `2.5` matched both `2.5` and `245`. Escaping it as `2\.5` strips the special meaning, making it match only a literal dot.
- **7c.** Only `banana` and `Banana`. The anchors require the whole line to be exactly `banana` or `Banana`; `bananas` has an extra character after the `a`, and `a banana` has text before the `b`.
- **7d.** Characters like `*`, `$`, and `[` are also special to the shell (globbing, variables). Single quotes deliver the pattern to grep untouched; unquoted, the shell might expand or mangle it first.

- **8a.** `grep ERROR app.log` keeps only the two lines containing `ERROR`; `cut -d ' ' -f 1,2` trims each of those lines down to its date and time fields; `sort` orders the resulting timestamps; the final result prints to the terminal.
- **8b.** `grep '/bin/bash$' /etc/passwd | wc -l` — or equivalently `grep -c '/bin/bash$' /etc/passwd`. Anchoring with `$` avoids matching the string somewhere in the middle of a line.

</details>

---

**Reference:** LPI Learning Materials, Linux Essentials Topic 3.2 — *Searching and Extracting Data from Files*: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/