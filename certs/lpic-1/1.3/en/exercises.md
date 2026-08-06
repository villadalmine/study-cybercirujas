# Hands-On Exercises: GNU and Unix Commands

These exercises are designed to simulate real-world log analysis and text manipulation tasks that an SRE performs during an incident. You will need a Unix-like shell environment (Bash, Zsh) to complete them.

## Exercise 1: Finding the Needle in the Haystack

During a suspected DDoS attack or credential stuffing attempt, your first line of defense is quickly summarizing access patterns from raw logs.

### Steps:
1. Create a dummy log file named `access.log` with the following content:
   ```text
   192.168.1.10 - - [10/Oct/2026:13:55:36] "GET /api/login HTTP/1.1" 401
   10.0.0.5 - - [10/Oct/2026:13:55:37] "GET /api/status HTTP/1.1" 200
   192.168.1.10 - - [10/Oct/2026:13:55:38] "GET /api/login HTTP/1.1" 401
   172.16.0.4 - - [10/Oct/2026:13:55:39] "POST /api/data HTTP/1.1" 201
   192.168.1.10 - - [10/Oct/2026:13:55:40] "GET /api/login HTTP/1.1" 401
   10.0.0.5 - - [10/Oct/2026:13:55:41] "GET /api/status HTTP/1.1" 200
   ```
2. Use `awk` to print only the IP addresses (the first column).
   ```bash
   $ awk '{print $1}' access.log
   ```
3. Combine `sort` and `uniq -c` to count how many times each IP address appears in the log, then sort the output numerically in reverse order so the highest count is at the top.
   ```bash
   $ awk '{print $1}' access.log | sort | uniq -c | sort -nr
   ```
4. Modify your `awk` command to *only* print the IP address if the HTTP status code (column 9) is exactly "401". Run the full pipeline again.
   ```bash
   $ awk '$9 == "401" {print $1}' access.log | sort | uniq -c | sort -nr
   ```

**Questions for Verification:**
- Q1.1: Why do we have to pipe the output through `sort` *before* passing it to `uniq -c`?
- Q1.2: In the final command, what IP address was responsible for all the 401 errors, and how many were there?

---

## Exercise 2: Modifying Configurations in Place

SREs often need to update configuration values programmatically across many machines using configuration management or SSH loops. `sed` is the perfect tool for this.

### Steps:
1. Create a mock configuration file named `app.conf`:
   ```ini
   DEBUG_MODE=false
   MAX_CONNECTIONS=100
   TIMEOUT=30
   ```
2. You need to enable debug mode for a troubleshooting session. Use `sed` to replace `DEBUG_MODE=false` with `DEBUG_MODE=true` and print it to the screen (do not modify the file yet).
   ```bash
   $ sed 's/^DEBUG_MODE=.*/DEBUG_MODE=true/' app.conf
   ```
3. Now, modify the file **in-place**, but tell `sed` to create a backup copy with the extension `.bak` automatically.
   ```bash
   $ sed -i.bak 's/^DEBUG_MODE=.*/DEBUG_MODE=true/' app.conf
   ```
4. Verify the changes using `cat` and `ls`:
   ```bash
   $ cat app.conf
   $ ls app.conf*
   ```

**Questions for Verification:**
- Q2.1: What does the `^` symbol signify in the regular expression `^DEBUG_MODE=`?
- Q2.2: Why is it crucial to use the `.bak` suffix with the `-i` flag in production scripts?

<details>
<summary>Click here to reveal the answers</summary>

### Answers

- **A1.1**: The `uniq` command only collapses **adjacent** duplicate lines. If the data is not sorted first, identical IPs that appear in different parts of the log file will not be grouped together, leading to inaccurate counts.
- **A1.2**: `192.168.1.10` was responsible for all `401` errors, appearing 3 times.
- **A2.1**: The caret (`^`) is an anchor that specifies the match must occur at the **beginning** of the line. This ensures you don't accidentally replace a line like `# COMMENT_DEBUG_MODE=false`.
- **A2.2**: The `.bak` suffix creates a backup of the original file before modifying it. If the `sed` regular expression is flawed and corrupts the file, you can immediately restore the application by copying the `.bak` file over the broken one, minimizing downtime.

</details>