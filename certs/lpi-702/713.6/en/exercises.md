# LPI-702 (Exam 702-100, Version 1.0)
## Topic 713.6: Manage Printing and Print Jobs
**Weight:** 1.67  
**Official Reference:** [LPI BSD Specialist Certification Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

### Deep Technical Context & Architectural Overview

The BSD printing architecture relies on either the traditional Line Printer Daemon (`lpd(8)`) operating over the Berkeley LPR protocol ([RFC 1179](https://datatracker.ietf.org/doc/html/rfc1179)) or modern print spooling infrastructures such as CUPS (Common UNIX Printing System) utilizing IPP (Internet Printing Protocol).

#### 1. The Traditional BSD LPD Architecture & Mechanics

```
                      +-------------------+
                      |      user         |
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |  lpr(1) utility   |
                      +---------+---------+
                                |
               Reads /etc/printcap & creates spool files
                                |
                                v
               +----------------------------------+
               | Spool Dir: /var/spool/output/lp  |
               |  - Data file:    dfA001hostname  |
               |  - Control file: cfA001hostname  |
               |  - Lock file:    lock            |
               +----------------+-----------------+
                                |
                                v
                      +-------------------+
                      |      lpd(8)       |
                      +---------+---------+
                                |
                Executes Input/Output Filters
                                |
                                v
            +---------------------------------------+
            |  if (input filter) / of (out filter) |
            |    Translates text/PostScript to RAW   |
            +-------------------+-------------------+
                                |
             +------------------+------------------+
             |                                     |
      Local Device                          Remote LPD Server
  (e.g., /dev/lpt0, /dev/ulpt0)              (RFC 1179 Port 515)
```

1. **Client Job Submission (`lpr(1)`):**
   When a user executes `lpr -P printer_name file.ps`, `lpr` reads `/etc/printcap` to resolve spool directory paths (`sd`) and remote destination definitions (`rm`/`rp`). It writes two temporary spool files into the target spool directory:
   - **Data File (`dfA<jobid><hostname>`):** Contains the raw print payload (PostScript, plain text, PCL, etc.).
   - **Control File (`cfA<jobid><hostname>`):** Contains metadata instructions such as the job owner (`P`), job name (`J`), classification (`C`), format specification (`f` for plain text, `l` for binary/raw, `p` for formatted text), and target data file reference (`U`/`N`).

2. **Daemon Processing (`lpd(8)`):**
   `lpd` detects new `cf*` files via `kqueue(2)` or periodic spool scans. It opens a lock file (`lock`) in the spool directory to prevent concurrent worker threads from processing the same queue.
   - For local physical output: `lpd` pipes the payload through the input filter (`if`) or output filter (`of`) defined in `/etc/printcap` to handle page framing, linefeed conversion (`LF` to `CR+LF`), or rasterization.
   - For remote printing: `lpd` establishes a TCP connection to port **515** on the target print server, initiating the RFC 1179 handshake.

3. **Queue Control (`lpc(8)`):**
   `lpc` modifies queue state flags by writing state control files (`status`) inside the spool directory or communicating with `lpd` via UNIX domain sockets (`/var/run/printer`).
   - `disable`: Blocks `lpr` from spooling new `cf*`/`df*` files.
   - `stop`: Halts `lpd` from dequeuing and sending existing jobs to the filter/device.
   - `enable` / `start`: Re-activates spooling and processing respectively.

---

#### 2. Deep Dive: `/etc/printcap` Capability Schema

The `/etc/printcap` file uses a colon-separated capability syntax (`cap=value` or Boolean flags `:flag:`).

| Capability | Type | Technical Description & Production Impact |
| :--- | :--- | :--- |
| `lp` | String | Character device node for direct physical attachment (e.g., `/dev/lpt0`, `/dev/unlpt0`). If set to empty (`lp=`), the queue is designated as remote or network-bound. |
| `sd` | Path | Spool directory path (e.g., `/var/spool/output/lp1`). Must exist with `0770` permissions and ownership `daemon:daemon` or `root:daemon`. |
| `rm` | String | Remote host domain name or IP address for RFC 1179 network printing. |
| `rp` | String | Remote queue/printer name on the target RFC 1179 print server. |
| `if` | Path | Absolute path to the **Input Filter** executable. Filters input once per print job. Receives standard input from `df*` and outputs transformed stream to `lp`. |
| `of` | Path | Absolute path to the **Output Filter** executable. Used for banner generation and multiplexed job handling. Runs persistently across banner/data boundaries. |
| `lf` | Path | Log file for daemon error messages associated with the queue (e.g., `/var/log/lpd-errs`). |
| `af` | Path | Accounting log file path for tracking user page counts. |
| `mx` | Numeric | Maximum job file size in 512-byte blocks. Set `mx#0` to allow unlimited job sizes in production. |
| `sh` | Flag | Suppress Header. Disables printing of default banner/cover pages (`:sh:`). |
| `rg` | String | Restricted Group. Restricts `lpr` usage for this queue to users in the specified system group. |

---

### Guided Practical Exercises

#### Exercise 1: Advanced `/etc/printcap` Configuration, Custom Filtering, and Daemon Initialization

##### Objective
Construct a production-grade, syntactically valid `/etc/printcap` entry featuring an input filter (`if`) for plain-text-to-PostScript translation, configure strict directory permissions, and initialize `lpd(8)`.

##### Execution Steps

1. Create the spool directory and log files with strict system permissions for daemon execution:
```bash
sudo mkdir -p /var/spool/output/acct_print
sudo touch /var/log/lpd-acct_print.log /var/log/lpd-acct_audit.log
sudo chown -R daemon:daemon /var/spool/output/acct_print
sudo chmod 0770 /var/spool/output/acct_print
sudo chown daemon:daemon /var/log/lpd-acct_print.log /var/log/lpd-acct_audit.log
sudo chmod 0640 /var/log/lpd-acct_print.log /var/log/lpd-acct_audit.log
```

2. Create a custom shell input filter `/usr/local/libexec/ps_filter.sh` to sanitize text and prepend a timestamped banner line:
```bash
sudo mkdir -p /usr/local/libexec
cat << 'EOF' | sudo tee /usr/local/libexec/ps_filter.sh > /dev/null
#!/bin/bin/sh
# Input filter: Read stdin, append audit info, send to device/output stream
LOGGER="/usr/bin/logger -t lpd_filter"
$LOGGER "Processing job submission..."
# Accounting log entry: append user timestamp
echo "$(date '+%Y-%m-%d %H:%M:%S') - Printed job" >> /var/log/lpd-acct_audit.log
# Pass standard input directly to standard output
cat
exit 0
EOF
sudo chmod 0755 /usr/local/libexec/ps_filter.sh
```

3. Configure `/etc/printcap` defining both a primary queue and an alias queue:
```bash
cat << 'EOF' | sudo tee -a /etc/printcap > /dev/null
# Production Accounting Printer Configuration
acct_print|ap|Accounting HP LaserJet:\
	:lp=/dev/null:\
	:sd=/var/spool/output/acct_print:\
	:lf=/var/log/lpd-acct_print.log:\
	:af=/var/log/lpd-acct_audit.log:\
	:if=/usr/local/libexec/ps_filter.sh:\
	:mx#0:\
	:sh:
EOF
```

4. Verify `/etc/printcap` syntax and check daemon readiness using `lpc`:
```bash
sudo lpc status acct_print
```

**Expected Output:**
```
acct_print:
	queuing is enabled
	printing is enabled
	no entries in spool area
	daemon present
```

5. Enable `lpd` in `/etc/rc.conf` and start the service:
```bash
sudo sysrc lpd_enable="YES"
sudo service lpd restart
```

**Expected Output:**
```
lpd_enable: NO -> YES
Stopping lpd.
Starting lpd.
```

---

##### Verification Questions - Block 1

**Question 1.1:** In an `/etc/printcap` entry, what is the operational difference between setting `:mx#0:` versus omitting the `mx` capability entirely?  
**Question 1.2:** If the permissions of `/var/spool/output/acct_print` are set to `0777` (world-writable), what security vulnerability and operational anomaly can occur within the BSD `lpd` spooling subsystem?

---

#### Exercise 2: Low-Level Spool Analysis, File Lifecycle, and Queue Management via `lpc`

##### Objective
Simulate print job queuing, pause processing using `lpc`, dissect control (`cf*`) and data (`df*`) files, analyze the spool locking mechanism, and manage jobs using `lpq` and `lprm`.

##### Execution Steps

1. Stop the printer queue processing (dequeuing) while keeping job submission (queuing) enabled:
```bash
sudo lpc stop acct_print
```

**Expected Output:**
```
acct_print:
	printing disabled
```

2. Submit a print job to the stopped queue using `lpr(1)` with custom metadata flags (`-J` for job name, `-C` for classification):
```bash
echo "CONFIDENTIAL FINANCIAL REPORT - Q3" | lpr -Pacct_print -J "q3_report.txt" -C "FINANCE"
```

3. List the spool directory contents to observe the generated `cf*`, `df*`, and lock status files:
```bash
sudo ls -l /var/spool/output/acct_print
```

**Expected Output:**
```
total 8
-rw-r-----  1 daemon  daemon   122 Aug  6 20:50 cfA001hostname
-rw-r-----  1 daemon  daemon    35 Aug  6 20:50 dfA001hostname
-rw-r--r--  1 daemon  daemon    33 Aug  6 20:50 status
```

4. Inspect the raw contents of the Control File (`cfA*`):
```bash
sudo cat /var/spool/output/acct_print/cfA*
```

**Expected Output:**
```
Hhostname
Pusername
Jq3_report.txt
CFINANCE
Lusername
fdfA001hostname
UdfA001hostname
Nq3_report.txt
```

5. Query the active print queue status using `lpq(1)`:
```bash
lpq -Pacct_print
```

**Expected Output:**
```
Rank   Owner      Job  Files                                 Total Size
1st    username   1    q3_report.txt                         35 bytes
```

6. Cancel the queued print job using `lprm(1)` specifying the Job ID:
```bash
lprm -Pacct_print 1
```

**Expected Output:**
```
dfA001hostname dequeued
cfA001hostname dequeued
```

7. Re-enable printer queue processing:
```bash
sudo lpc start acct_print
```

**Expected Output:**
```
acct_print:
	printing enabled
	daemon started
```

---

##### Verification Questions - Block 2

**Question 2.1:** What do the control lines `H`, `P`, `J`, `C`, and `f` represent inside a BSD LPD control file (`cfA*`)?  
**Question 2.2:** If an administrator issues `lpc disable acct_print`, what is the exact system behavior when a non-root user executes `lpr -Pacct_print test.txt`?

---

#### Exercise 3: Network Printing (RFC 1179 / IPP), CUPS Integration, and Diagnostics

##### Objective
Configure a remote network printer queue using RFC 1179 syntax, inspect network communications using `tcpdump`, and perform cross-platform spool administration using `lpadmin` and `lpstat`.

##### Execution Steps

1. Add a remote network printer configuration to `/etc/printcap` pointing to an enterprise print server or jetdirect gateway (`rm` = remote machine, `rp` = remote printer):
```bash
cat << 'EOF' | sudo tee -a /etc/printcap > /dev/null

# Remote RFC 1179 Network Printer Queue
net_laser|Remote Network HP LaserJet:\
	:lp=:\
	:rm=192.168.100.50:\
	:rp=raw:\
	:sd=/var/spool/output/net_laser:\
	:lf=/var/log/lpd-errs:\
	:mx#0:\
	:sh:
EOF
```

2. Create the remote spool directory and assign correct permissions:
```bash
sudo mkdir -p /var/spool/output/net_laser
sudo chown daemon:daemon /var/spool/output/net_laser
sudo chmod 0770 /var/spool/output/net_laser
```

3. Simulate CUPS administration using standard IPP/CUPS commands (`lpadmin`, `lpstat`). Check existing IPP destinations:
```bash
lpstat -p -d
```

**Expected Output:**
```
no system default destination
system host printer status: idle
```

4. Configure a CUPS IPP queue programmatically using `lpadmin`:
```bash
sudo lpadmin -p Enterprise_Color -E -v ipp://192.168.100.55/ipp/print -m raw
sudo lpadmin -d Enterprise_Color
```

5. Verify default destination and queue status with `lpstat`:
```bash
lpstat -s
```

**Expected Output:**
```
system default destination: Enterprise_Color
device for Enterprise_Color: ipp://192.168.100.55/ipp/print
```

6. Perform live network diagnostic capture on LPD (port 515) or IPP (port 631) using `tcpdump`:
```bash
sudo tcpdump -ni lo0 port 515 or port 631 -c 5
```

---

##### Verification Questions - Block 3

**Question 3.1:** What is the primary difference between how legacy `lpd(8)` processes remote print jobs via `:rm:`/`:rp:` versus how CUPS routes jobs via IPP URI specifications (`ipp://`)?  
**Question 3.2:** If `lpq` reports `warning: net_laser: connection refused` when submitting a job to a remote printer configured with `:rm=192.168.100.50:`, what diagnostic steps and commands should be executed to isolate the root cause?

---

<details>
<summary>Answers & Comprehensive Explanations</summary>

### Answers & Comprehensive Explanations

#### Block 1 Answers

**Answer 1.1:**
- **`:mx#0:`**: Sets the maximum print file size limit to **unlimited** (0 blocks). This is mandatory for production graphics, CAD files, or large PDF streams.
- **Omitting `mx`**: Defaults to a default maximum file size limit of **1000 blocks** (approx. 500 KB). Any print job exceeding this threshold submitted via `lpr` will be truncated or rejected with a `file too large` spool error.

**Answer 1.2:**
- **Security & Integrity Risks:** Setting spool directory permissions to `0777` allows unprivileged local users to inspect, modify, or delete `df*` and `cf*` files owned by other users, violating confidentiality.
- **Operational Anomalies:** `lpd(8)` enforces internal sanity checks on spool directory ownership and permissions. If world-writable or owned by an unprivileged user, `lpd` may refuse to process jobs in that queue, logging `unsecure spool directory` errors to the log file defined in `:lf:`. Spool directories must strictly adhere to `0770` or `0750` ownership (`daemon:daemon` or `root:daemon`).

---

#### Block 2 Answers

**Answer 2.1:**
Control file fields in `cfA*` dictate execution parameters for `lpd`:
- `H`: **Host name** of the client machine submitting the job.
- `P`: **Person/User ID** of the job submitter (used for accounting and ownership validation).
- `J`: **Job Name** string displayed in `lpq` and banner pages.
- `C`: **Class / Classification** string printed on banner cover sheets (e.g., `FINANCE`, `TOP SECRET`).
- `f`: **File format specification** indicating that the target data file (`dfA*`) is a plain text file to be processed through the standard input filter (`if`).

**Answer 2.2:**
- `lpc disable acct_print` explicitly sets the **queuing flag** to disabled in the queue's `status` file.
- When a user runs `lpr -Pacct_print test.txt`, `lpr` attempts to copy files into `/var/spool/output/acct_print`. Upon reading the status file, `lpr` fails immediately and prints an error to `stderr`: `lpr: acct_print: queuing is disabled`. No `cf*` or `df*` files are created.

---

#### Block 3 Answers

**Answer 3.1:**
- **Legacy `lpd` (`rm`/`rp`):** Acts as a pass-through spooler. It transfers raw or pre-filtered control/data files across TCP port 515 using the RFC 1179 stream protocol. It lacks dynamic capability querying, bidirectional state feedback (e.g., precise ink levels or media jams), and native encryption.
- **CUPS / IPP (`ipp://`):** Uses an HTTP/1.1-based protocol (port 631). IPP supports complex job attribute queries, authentication (TLS/Kerberos), PPD (PostScript Printer Description) driver rendering pipelines on client or server sides, and rich status reporting (page counts, detailed error states).

**Answer 3.2:**
To diagnose `connection refused` on RFC 1179 network printing:
1. **Verify Transport Reachability & Open Ports:** Execute `nc -zv 192.168.100.50 515` or `telnet 192.168.100.50 515` to determine if the target daemon is listening and accepting TCP connections on port 515.
2. **Inspect Firewall / Packet Filter Policies:** Run `sudo pfctl -sr` (PF on FreeBSD/OpenBSD) or check external network security groups to ensure outbound TCP port 515 traffic is permitted.
3. **Trace Network Routes:** Run `traceroute 192.168.100.50` to rule out routing loops or gateway failures.
4. **Check Local Spool Logs:** Inspect `/var/log/lpd-errs` (or the specific `:lf:` path) for socket binding or privilege errors (e.g., `lpd` failing to bind to a low-numbered source port `< 1024` as required by strict RFC 1179 implementations).

</details>