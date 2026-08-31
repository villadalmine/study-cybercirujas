# 104.6 — Create and Change Hard and Symbolic Links

**Certification:** LPIC-1 (Exams 101-500 + 102-500), version 5.0
**Topic weight:** 3.12
**Level:** Advanced / Production SRE — Platform Architect

---

## 1. The architectural problem

Every production filesystem layout eventually has to answer one question: **when two paths must refer to the same bytes, which of the two paths owns them?**

The naive answer — copy the file — fails on three axes simultaneously:

1. **Consistency.** Two copies drift. A TLS certificate copied into three service directories is three certificates the moment one renewal succeeds and two fail.
2. **Space and time.** A 40 GB backup that is 99.4% identical to yesterday's is 40 GB of writes, 40 GB of disk, and 40 GB of read bandwidth on restore.
3. **Atomicity of change.** Overwriting a live file in place is not atomic. A reader can observe a half-written config. A deploy that copies a new release over the running one has a window measured in seconds where the application directory is neither the old release nor the new one.

Links are the kernel's answer. They are not a convenience feature — they are the primitive that the following production mechanisms are **built out of**, not merely decorated with:

| Mechanism | What the link actually does |
|---|---|
| `systemctl enable foo.service` | Creates `/etc/systemd/system/multi-user.target.wants/foo.service` → the unit file. "Enabled" *is* the symlink. |
| Debian/Ubuntu `update-alternatives` | Two-level symlink indirection: `/usr/bin/editor` → `/etc/alternatives/editor` → `/usr/bin/vim.basic` |
| Kubernetes ConfigMap/Secret volumes | kubelet writes a timestamped directory and swaps a `..data` symlink with `rename(2)`. That swap is the atomic config update. |
| `/var/log/containers/*.log` | Symlink farm pointing into `/var/log/pods/`, which points into the container runtime's log files. Every log shipper in the cluster depends on this chain. |
| `rsync --link-dest` snapshots | Unchanged files are **hard-linked** to the previous snapshot. 30 daily snapshots of a 40 GB tree can cost 41 GB total. |
| `/etc/localtime` | Symlink into `/usr/share/zoneinfo/…`. The timezone of the machine is a symlink target. |
| Blue/green release directories | `current` → `releases/<id>`, swapped with `rename(2)`. Rollback is one syscall. |
| `/dev/stdout` in containers | `/dev/stdout` → `/proc/self/fd/1`. Log-to-stdout in an image is implemented by symlinking the log file. |
| Deleted-but-open files | A file with link count 0 and an open descriptor still consumes disk. This is the single most common cause of "`df` says full, `du` says empty". |

Understanding links is therefore not a file-manipulation skill. It is how you reason about **atomic configuration change, snapshot economics, log pipelines, and disk-space accounting**.

---

## 2. Mechanics: the inode, the directory entry, and path resolution

### 2.1 A file has no name

On a POSIX filesystem, a file is an **inode**: a numbered record holding the mode bits, ownership, timestamps, size, link count, and the pointers to the data blocks. The inode contains **no name**.

A **directory** is a file whose contents are a table of `(name → inode number)` pairs. Those pairs are called **directory entries** (dentries, or *links*).

```
directory /srv/data              inode 1442093
+---------------------------+    +------------------------------+
| "report.log"   -> 1442093 |--->| mode  -rw-r--r--             |
| "report.bak"   -> 1442093 |--->| uid/gid 1000/1000            |
| "report.link"  -> 1442097 |-+  | nlink 2                      |
+---------------------------+ |  | size  4096                   |
                              |  | blocks -> [ data ]           |
                              |  +------------------------------+
                              |
                              +->  inode 1442097
                                  +------------------------------+
                                  | mode  lrwxrwxrwx             |
                                  | size  10                     |
                                  | data  "report.log"           |
                                  +------------------------------+
```

- `report.log` and `report.bak` are **two hard links to one inode**. Neither is "the original". `nlink` is 2.
- `report.link` is a **symbolic link**: a *different* inode, of type `S_IFLNK`, whose data is the literal string `report.log`.

### 2.2 What `unlink()` really means

`rm` does not delete files. It calls `unlink(2)`, which removes a directory entry and decrements the inode's link count. The kernel frees the data blocks only when **both** conditions hold:

```
nlink == 0   AND   no process holds an open file descriptor
```

This is why `rm huge.log` on a file that `nginx` still has open frees exactly zero bytes — and why `lsof +L1` exists (§6.5).

### 2.3 Path resolution and symlink following

When the VFS walks a path and hits a symlink component, it substitutes the link's target string and continues. Consequences that matter in production:

- **Relative symlink targets resolve from the directory containing the link**, not from the process's CWD. `ln -s ../conf/app.yaml /srv/app/current/app.yaml` resolves against `/srv/app/current/`, not against wherever you ran the command.
- Resolution is bounded. Linux caps nested symlink traversal at **40** (`MAXSYMLINKS`); exceeding it returns `ELOOP`.
- Resolution happens **in the mount namespace of the process doing the reading**. A symlink inside a container that points to `/var/log/pods/...` is dangling unless `/var/log/pods` is also mounted into that container. This is the #1 cause of empty log shippers in Kubernetes (§4.4).

### 2.4 Directory link counts

A directory's `nlink` is `2 + number_of_subdirectories`: one for its own name in the parent, one for its `.`, and one for each child's `..`.

```
$ stat -c '%h %n' /srv/app
5 /srv/app
$ ls -1d /srv/app/*/ | wc -l
3
```

`2 + 3 = 5`. This is a favourite exam question and a genuinely useful sanity check on a corrupted filesystem.

---

## 3. Hard links vs symbolic links vs the modern alternatives

### 3.1 The core comparison

| Property | Hard link | Symbolic link |
|---|---|---|
| Kind of object | Another directory entry for an existing inode | A new inode of type `S_IFLNK` holding a path string |
| Inode number | **Identical** to the target's | Its own, distinct |
| `ls -l` type char | `-` (indistinguishable from any other name) | `l` |
| Cross-filesystem | **No** — `EXDEV` | Yes |
| Can point to a directory | **No** — `EPERM` (only the kernel makes `.`/`..`) | Yes |
| Can dangle | No, by construction | **Yes** — the target is just a string |
| Survives target rename/move | **Yes** — it *is* the file | **No** — the string no longer resolves |
| Survives target deletion | Yes (data lives while `nlink > 0`) | No — becomes a broken link |
| Disk cost | One directory entry (~tens of bytes) | One inode; target string is inline if < 60 bytes on ext4 ("fast symlink"), otherwise one data block |
| `chmod`/`chown` effect | Affects **all** names — there is one inode | Affects the *target* unless `-h`/`--no-dereference` is used |
| Permissions of the link itself | N/A — the inode's permissions | Always `lrwxrwxrwx`, ignored by Linux (but **ownership matters**, see `fs.protected_symlinks`) |
| Size reported by `ls -l` | The file's size | Length in bytes of the target string |
| `du` accounting | Counted **once** per inode per traversal | Counted as the link inode (usually 0 blocks) |
| Unprivileged creation | Restricted by `fs.protected_hardlinks` | Unrestricted |
| Max count | ext4: 65 000; XFS: 2³²−1 | Unbounded |
| Backup semantics | `tar`/`rsync -H` must detect and re-link | Stored verbatim as a string |
| Failure mode when misused | Silent divergence of "copies" that are one file | `ENOENT` on a path that visibly exists in `ls` |

### 3.2 The full sharing spectrum — what an architect actually chooses between

Hard links and symlinks are two of four ways to make one set of bytes reachable from two paths. Choosing the wrong one is a design defect, not a typo.

| | Hard link | Symbolic link | Reflink (CoW copy) | Bind mount |
|---|---|---|---|---|
| Command | `ln a b` | `ln -s a b` | `cp --reflink=always a b` | `mount --bind a b` |
| Filesystems | ext4, XFS, btrfs, … | all | XFS (reflink=1), btrfs, bcachefs | all |
| Cross-filesystem | no | yes | no | yes |
| Shares an inode | **yes** | no | **no** — separate inodes, shared extents | no (shows the same inode via a second mount) |
| Write to one path affects the other | **yes** — same data | yes (writes go to the target) | **no** — copy-on-write breaks sharing per block | yes |
| Space at creation | ~0 | ~0 | ~0 | ~0 |
| Survives reboot | yes | yes | yes | **no** — needs `/etc/fstab` or a `.mount` unit |
| Works on directories | no | yes | `cp -a --reflink` recurses | **yes**, natively |
| Typical use | dedup snapshots, package payloads | pointers to a chosen version | cheap writable clones of large datasets | exposing a path into a namespace/container |

**The architectural rule:** if the two paths must diverge on write, a hard link is wrong and a reflink is right. If one path must remain a *pointer to whichever version is current*, a symlink is right and a hard link cannot express it at all. If the sharing must cross a filesystem or a mount namespace, only symlinks and bind mounts qualify.

### 3.3 `ln` — the complete flag surface

| Flag | Long form | Effect |
|---|---|---|
| *(none)* | | Create a hard link |
| `-s` | `--symbolic` | Create a symbolic link |
| `-f` | `--force` | Remove an existing destination first |
| `-i` | `--interactive` | Prompt before removing an existing destination |
| `-n` | `--no-dereference` | If the destination is a **symlink to a directory**, treat it as a normal file instead of descending into it |
| `-T` | `--no-target-directory` | The destination is always the link name, never a directory to place the link inside |
| `-t DIR` | `--target-directory=DIR` | Place all links into `DIR` (useful with `xargs`/`find -exec`) |
| `-r` | `--relative` | Compute a symlink target relative to the link's own directory |
| `-b` | `--backup[=CONTROL]` | Back up an existing destination instead of losing it |
| `-v` | `--verbose` | Print each link created |
| `-L` | `--logical` | When hard-linking a symlink, link to its **referent** |
| `-P` | `--physical` | When hard-linking a symlink, link to the **symlink inode itself** (the default on Linux) |
| `-d`, `-F` | `--directory` | Attempt a hard link to a directory; returns `EPERM` on Linux even for root |

`-n` and `-T` are the two flags that separate a working deploy script from an outage. Without them, `ln -sf releases/new /srv/app/current` — where `current` is already a symlink to a directory — creates `/srv/app/current/new` and leaves production pointing at the old release, with no error.

---

## 4. Production patterns, with complete infrastructure

### 4.1 The atomic release pointer

The reason `current` is a symlink and not a directory is that **`rename(2)` is atomic and `cp -r` is not**. A reader either sees the old target or the new one, never a partial state.

`/usr/local/sbin/release.sh`:

```bash
#!/usr/bin/env bash
#
# Atomically repoint /srv/app/current at a prepared release directory.
# The only atomic replace primitive on POSIX is rename(2); `ln -sf` is
# implemented as unlink-then-symlink, which leaves a window in which the
# path does not exist at all and every in-flight open() returns ENOENT.
set -euo pipefail

APP_ROOT=/srv/app
RELEASE_ID=${1:?usage: release.sh <release-id>}
NEW_RELEASE="${APP_ROOT}/releases/${RELEASE_ID}"
CURRENT="${APP_ROOT}/current"
STAGING="${APP_ROOT}/.current.staging.$$"

[[ -d ${NEW_RELEASE} ]] || { echo "release ${RELEASE_ID} not found" >&2; exit 1; }

cleanup() { rm -f -- "${STAGING}"; }
trap cleanup EXIT

# 1. Build the new pointer under a name nobody reads.
#    -T guarantees the destination is the link name and never a directory
#    to place the link inside. No -f and no -n are needed precisely because
#    ${STAGING} is a fresh name: the footguns only exist when you overwrite.
#
#    The target is RELATIVE. An absolute target ("/srv/app/releases/...")
#    breaks the moment this tree is bind-mounted, chrooted, or rsynced into
#    a container image at a different prefix.
ln -sT "releases/${RELEASE_ID}" "${STAGING}"

# 2. rename(2) over the live pointer. Atomic. If ${CURRENT} was mistakenly
#    created as a real directory, this fails loudly with EISDIR instead of
#    silently nesting a link inside it.
mv -T "${STAGING}" "${CURRENT}"
trap - EXIT

# 3. Processes that already resolved the old path keep their open file
#    descriptors on the old inode until they reopen. The reload is what
#    makes the swap visible to a long-running server.
systemctl reload edge-proxy.service

# 4. Retention: keep the four newest releases plus the live one. Never
#    delete the resolved target, whatever its mtime says.
resolved=$(readlink -f -- "${CURRENT}")
find "${APP_ROOT}/releases" -mindepth 1 -maxdepth 1 -type d \
     ! -path "${resolved}" -printf '%T@ %p\n' \
  | sort -rn | tail -n +5 | cut -d' ' -f2- \
  | xargs -r -d '\n' rm -rf --

echo "current -> $(readlink -- "${CURRENT}")"
```

Verification:

```
$ sudo /usr/local/sbin/release.sh 2026-08-26T09-30-00Z
current -> releases/2026-08-26T09-30-00Z

$ ls -l /srv/app/current
lrwxrwxrwx 1 deploy deploy 29 Aug 26 09:30 /srv/app/current -> releases/2026-08-26T09-30-00Z

$ namei -l /srv/app/current/bin/edge-proxy
f: /srv/app/current/bin/edge-proxy
 drwxr-xr-x root   root   /
 drwxr-xr-x root   root   srv
 drwxr-xr-x deploy deploy app
 lrwxrwxrwx deploy deploy current -> releases/2026-08-26T09-30-00Z
 drwxr-xr-x deploy deploy releases
 drwxr-xr-x deploy deploy 2026-08-26T09-30-00Z
 drwxr-xr-x deploy deploy bin
 -rwxr-xr-x deploy deploy edge-proxy
```

`namei -l` (util-linux) walks every component and prints its type and permissions. It is the single best tool for "this path exists but I get `ENOENT`".

Rollback is the same script with the previous release ID — one `rename(2)`, sub-millisecond, no data movement.

### 4.2 Declaring links as infrastructure

**`/etc/tmpfiles.d/edge-proxy.conf`** — systemd-tmpfiles creates these at boot and on `systemd-tmpfiles --create`, which makes the link layout reproducible on a freshly provisioned node:

```
#  Type  Path                                  Mode  User    Group   Age  Argument
   d     /srv/app                              0755  deploy  deploy  -    -
   d     /srv/app/releases                     0755  deploy  deploy  -    -
   d     /srv/app/shared                       0750  deploy  deploy  -    -
   d     /srv/app/shared/log                   0750  deploy  deploy  -    -

#  L  creates a symlink only if the path does not already exist.
#  L+ removes whatever is there first (file, directory, or wrong symlink)
#     and then creates the link. Use L+ for links you must own absolutely,
#     L for links an operator is allowed to override.
   L+    /srv/app/shared/config/upstream.conf  -     -       -       -    /etc/edge-proxy/upstream.conf
   L     /var/log/edge-proxy                   -     -       -       -    /srv/app/shared/log
```

```
$ sudo systemd-tmpfiles --create /etc/tmpfiles.d/edge-proxy.conf
$ ls -l /var/log/edge-proxy
lrwxrwxrwx 1 root root 20 Aug 26 09:31 /var/log/edge-proxy -> /srv/app/shared/log
```

**Ansible** — the same layout, converged rather than created:

```yaml
---
- name: Provision the release layout and its links
  hosts: edge_proxies
  become: true
  vars:
    app_root: /srv/app
    release_id: "2026-08-26T09-30-00Z"

  tasks:
    - name: Create the directory skeleton
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: deploy
        group: deploy
        mode: "0755"
      loop:
        - "{{ app_root }}"
        - "{{ app_root }}/releases/{{ release_id }}"
        - "{{ app_root }}/shared/config"

    # state: link is `ln -s`.
    #   force: true   == -f  (replace an existing destination)
    #   follow: false == -n  (do NOT descend into an existing dir-symlink)
    # Omitting follow: false is the Ansible spelling of the classic
    # `ln -sf` footgun: it creates app_root/current/<release_id>.
    - name: Point `current` at the release
      ansible.builtin.file:
        src: "releases/{{ release_id }}"
        dest: "{{ app_root }}/current"
        state: link
        force: true
        follow: false
        owner: deploy
        group: deploy
      notify: reload edge-proxy

    # state: hard requires an ABSOLUTE src, and both paths must live on the
    # same filesystem — Ansible surfaces EXDEV as a task failure, which is
    # the correct behaviour: a silent copy here would break the audit trail.
    - name: Keep the audit copy of the licence as a hard link, not a copy
      ansible.builtin.file:
        src: "{{ app_root }}/releases/{{ release_id }}/LICENCE"
        dest: "{{ app_root }}/shared/LICENCE"
        state: hard
        force: true

    # lineinfile/replace/blockinfile rewrite via a temporary file plus
    # rename(2). On a symlinked path that REPLACES the symlink with a
    # regular file unless follow: true is set. Same class of bug as `sed -i`.
    - name: Tune the worker count in the (symlinked) config
      ansible.builtin.lineinfile:
        path: "{{ app_root }}/shared/config/upstream.conf"
        regexp: '^worker_processes '
        line: 'worker_processes auto;'
        follow: true
      notify: reload edge-proxy

  handlers:
    - name: reload edge-proxy
      ansible.builtin.systemd_service:
        name: edge-proxy.service
        state: reloaded
```

### 4.3 Hard-linked snapshots: `rsync --link-dest`

This is the highest-leverage production use of hard links, and the one with the sharpest edge.

`/usr/local/sbin/snapshot.sh`:

```bash
#!/usr/bin/env bash
#
# Hard-linked snapshot rotation. Files unchanged since the previous
# snapshot become additional directory entries for the SAME inode, so a
# snapshot costs only the changed data plus one dentry per unchanged file.
#
# HARD REQUIREMENT: nothing may ever modify a snapshot file in place.
# A hard link is not a copy. An in-place write into today's snapshot
# rewrites the bytes that every previous snapshot also points at.
# rsync is safe here because it writes to a temporary file and rename(2)s
# it into place, which creates a NEW inode and leaves the old links intact.
set -euo pipefail

SRC=/srv/app/shared/
DEST_ROOT=/backup/edge-proxy
STAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
LATEST="${DEST_ROOT}/latest"

mkdir -p "${DEST_ROOT}"

link_dest=()
[[ -d ${LATEST} ]] && link_dest=(--link-dest="$(readlink -f -- "${LATEST}")")

rsync -aH --numeric-ids --delete \
      --info=stats2 \
      "${link_dest[@]}" \
      "${SRC}" "${DEST_ROOT}/${STAMP}/"

# Repoint `latest` atomically, exactly as in release.sh.
staging="${DEST_ROOT}/.latest.staging.$$"
ln -sT "${STAMP}" "${staging}"
mv -T "${staging}" "${LATEST}"

# Prune snapshots older than 30 days. rm only removes directory entries;
# the data survives as long as any other snapshot still links it.
find "${DEST_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +30 \
  -exec rm -rf -- {} +
```

`/etc/systemd/system/snapshot.service`:

```ini
[Unit]
Description=Hard-linked snapshot of /srv/app/shared
Documentation=man:rsync(1)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/snapshot.sh
Nice=10
IOSchedulingClass=idle
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/backup/edge-proxy
```

`/etc/systemd/system/snapshot.timer`:

```ini
[Unit]
Description=Daily hard-linked snapshot

[Timer]
OnCalendar=*-*-* 03:15:00 UTC
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
```

Enabling it is, itself, a symlink:

```
$ sudo systemctl enable --now snapshot.timer
Created symlink /etc/systemd/system/timers.target.wants/snapshot.timer → /etc/systemd/system/snapshot.timer.
```

The economics, measured:

```
$ sudo du -sh /backup/edge-proxy/2026-08-24T03-15-00Z
39G     /backup/edge-proxy/2026-08-24T03-15-00Z

$ sudo du -sh /backup/edge-proxy/2026-08-25T03-15-00Z
612M    /backup/edge-proxy/2026-08-25T03-15-00Z

$ sudo du -sh /backup/edge-proxy
40G     /backup/edge-proxy
```

The second snapshot appears to be 612 MB because **`du` counts each inode only once per traversal**, and only the changed files are new inodes. `du -s` over the whole root gives the true occupancy, 40 GB for two full snapshots. To see the *apparent* size instead:

```
$ sudo du -sh --count-links /backup/edge-proxy/2026-08-25T03-15-00Z
39G     /backup/edge-proxy/2026-08-25T03-15-00Z
```

The link count is the proof that sharing is happening:

```
$ stat -c 'nlink=%h  inode=%i  %n' /backup/edge-proxy/*/config/upstream.conf
nlink=2  inode=2621501  /backup/edge-proxy/2026-08-24T03-15-00Z/config/upstream.conf
nlink=2  inode=2621501  /backup/edge-proxy/2026-08-25T03-15-00Z/config/upstream.conf
```

Same inode, two names.

**The trade-off table for snapshot deduplication:**

| Approach | Space | Restore cost | In-place-write hazard | Filesystem requirement |
|---|---|---|---|---|
| Full copies | O(n × size) | trivial | none | any |
| `rsync --link-dest` (hard links) | O(size + n × delta) | trivial (each snapshot is a complete tree) | **severe** — an in-place write corrupts every snapshot sharing the inode | any POSIX fs, same fs for src and link-dest |
| Reflink copies (`cp --reflink`) | O(size + n × delta) | trivial | **none** — CoW breaks sharing on write | XFS with `reflink=1`, btrfs, bcachefs |
| Filesystem snapshots (LVM, btrfs, ZFS) | O(size + delta) | needs a mount/clone step | none | LVM thin, btrfs, ZFS |
| Content-addressed store (restic, borg) | O(size + dedup delta) | needs the tool to reassemble | none | any |

If the filesystem supports reflinks, prefer them: they buy the same space savings without the shared-inode hazard. Hard-linked snapshots remain the correct answer on plain ext4, where they are the only option.

### 4.4 Kubernetes: symlinks are the config-update mechanism

**`edge-proxy.yaml`** — full manifest:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: edge-proxy-config
  namespace: prod
data:
  upstream.conf: |
    upstream api {
        server api-a.prod.svc.cluster.local:8080 max_fails=3 fail_timeout=5s;
        server api-b.prod.svc.cluster.local:8080 max_fails=3 fail_timeout=5s;
        keepalive 32;
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-proxy
  namespace: prod
  labels:
    app.kubernetes.io/name: edge-proxy
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: edge-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: edge-proxy
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        fsGroup: 101
      containers:
        - name: edge-proxy
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            # CORRECT: mount the DIRECTORY.
            #
            # kubelet materialises the ConfigMap as:
            #   ..2026_08_26_09_20_11.418327755/   <- real files, timestamped dir
            #   ..data -> ..2026_08_26_09_20_11.418327755
            #   upstream.conf -> ..data/upstream.conf
            #
            # On update it writes a NEW timestamped directory and swaps the
            # ..data symlink with rename(2). Because the swap is atomic, the
            # container never observes a partially written config, and the
            # per-key symlinks need no changes at all.
            - name: config
              mountPath: /etc/edge
              readOnly: true

            # WRONG — kept as the counter-example. subPath resolves the path
            # ONCE, at mount time, and bind-mounts the resulting inode into
            # the container. kubelet later swaps ..data; the bind mount still
            # references the old timestamped inode. The container keeps the
            # stale config forever, with no error anywhere.
            #
            # - name: config
            #   mountPath: /etc/edge/upstream.conf
            #   subPath: upstream.conf

          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 128Mi
      volumes:
        - name: config
          configMap:
            name: edge-proxy-config
            defaultMode: 0444
```

The layout, observed from inside the pod:

```
$ kubectl -n prod exec deploy/edge-proxy -- ls -la /etc/edge
total 0
drwxrwxrwt 3 root root 100 Aug 26 09:20 .
drwxr-xr-x 1 root root  30 Aug 26 09:19 ..
drwxr-xr-x 2 root root  60 Aug 26 09:20 ..2026_08_26_09_20_11.418327755
lrwxrwxrwx 1 root root  31 Aug 26 09:20 ..data -> ..2026_08_26_09_20_11.418327755
lrwxrwxrwx 1 root root  20 Aug 26 09:20 upstream.conf -> ..data/upstream.conf
```

After `kubectl apply` of a changed ConfigMap, the swap is visible as a new timestamped directory and a rewritten `..data`:

```
$ kubectl -n prod exec deploy/edge-proxy -- ls -la /etc/edge
total 0
drwxrwxrwt 3 root root 100 Aug 26 10:04 .
drwxr-xr-x 1 root root  30 Aug 26 09:19 ..
drwxr-xr-x 2 root root  60 Aug 26 10:04 ..2026_08_26_10_04_52.913004118
lrwxrwxrwx 1 root root  31 Aug 26 10:04 ..data -> ..2026_08_26_10_04_52.913004118
lrwxrwxrwx 1 root root  20 Aug 26 09:20 upstream.conf -> ..data/upstream.conf
```

Note that `upstream.conf` itself was never touched — its mtime is unchanged. **An application that watches `upstream.conf` with `inotify` sees nothing.** To detect the update you must watch the directory for the `..data` rename, not the file. This is a direct, practical consequence of §2.3 and it catches experienced engineers.

**The log-shipper symlink chain.** On every node:

```
$ ls -l /var/log/containers/ | head -2
total 0
lrwxrwxrwx 1 root root 100 Aug 26 08:03 edge-proxy-7d9c5b6f4c-2xk8n_prod_edge-proxy-3f2a.log -> /var/log/pods/prod_edge-proxy-7d9c5b6f4c-2xk8n_1f4b0a52-9c3d-4a11-8e77-2b6f1a9d0c3e/edge-proxy/0.log
```

A collector that mounts only `/var/log/containers` sees a directory full of **dangling symlinks**, because `/var/log/pods` does not exist in its mount namespace. It reports no errors and ships no logs. The manifest must mount every hop:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-shipper
  namespace: observability
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: log-shipper
  template:
    metadata:
      labels:
        app.kubernetes.io/name: log-shipper
    spec:
      serviceAccountName: log-shipper
      tolerations:
        - operator: Exists
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          securityContext:
            readOnlyRootFilesystem: true
          volumeMounts:
            # Hop 1: the symlink farm itself.
            - name: varlog-containers
              mountPath: /var/log/containers
              readOnly: true
            # Hop 2: what those symlinks point at. Omitting this mount is
            # the classic "collector runs, ships nothing" outage — symlink
            # resolution happens in the READER's mount namespace.
            - name: varlog-pods
              mountPath: /var/log/pods
              readOnly: true
            # Hop 3: on nodes where /var/log/pods/... is itself a symlink
            # into the runtime's own log store.
            - name: containerd-logs
              mountPath: /var/lib/containerd
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc
              readOnly: true
            # Offsets must survive a restart, so they go on the host.
            - name: shipper-state
              mountPath: /var/lib/fluent-bit
          resources:
            requests:
              cpu: 50m
              memory: 96Mi
            limits:
              memory: 256Mi
      volumes:
        - name: varlog-containers
          hostPath:
            path: /var/log/containers
            type: Directory
        - name: varlog-pods
          hostPath:
            path: /var/log/pods
            type: Directory
        - name: containerd-logs
          hostPath:
            path: /var/lib/containerd
            type: DirectoryOrCreate
        - name: shipper-state
          hostPath:
            path: /var/lib/fluent-bit
            type: DirectoryOrCreate
        - name: config
          configMap:
            name: log-shipper-config
```

Diagnosis from inside the collector — this one command tells you immediately whether the chain is intact:

```
$ kubectl -n observability exec ds/log-shipper -- \
    find /var/log/containers -xtype l | head -3
```

Empty output means every symlink resolves. Any output at all is the outage.

### 4.5 Container logs: `/dev/stdout` is a symlink

```dockerfile
FROM nginx:1.27-alpine

# A container's logs must reach the runtime's stdout/stderr, not a file in
# the writable layer (which nothing collects and nothing rotates). These
# two symlinks ARE the entire mechanism: nginx open()s the log path, the
# kernel resolves it to /dev/stdout -> /proc/self/fd/1 -> the runtime pipe.
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 8080
USER 101
```

```
$ docker run --rm nginx:1.27-alpine ls -l /dev/stdout /proc/self/fd/1
lrwxrwxrwx 1 root root 15 Aug 26 09:44 /dev/stdout -> /proc/self/fd/1
lrwxrwxrwx 1 root root 64 Aug 26 09:44 /proc/self/fd/1 -> pipe:[41822]
```

`/proc/<pid>/fd/*` are **magic symlinks**: the kernel synthesises them, and `readlink` on them returns the object the descriptor refers to, including `pipe:[…]`, `socket:[…]`, or a path with a trailing `(deleted)`.

### 4.6 `update-alternatives`: two-level indirection as an API

```
$ ls -l /usr/bin/editor /etc/alternatives/editor
lrwxrwxrwx 1 root root 24 Aug  1 11:02 /usr/bin/editor -> /etc/alternatives/editor
lrwxrwxrwx 1 root root 18 Aug  1 11:02 /etc/alternatives/editor -> /usr/bin/vim.basic

$ sudo update-alternatives --set editor /usr/bin/nano
update-alternatives: using /usr/bin/nano to provide /usr/bin/editor (editor) in manual mode

$ readlink -f /usr/bin/editor
/usr/bin/nano
```

Two levels, not one, because the **package manager** owns `/usr/bin/editor` (it must be able to recreate it) while the **administrator's choice** lives in `/etc/alternatives/`, which is configuration and survives upgrades. This is a reusable design: a stable public path, a swappable policy layer, and the implementation. `/etc/localtime` follows the same pattern:

```
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 52 Aug 20 10:11 /etc/localtime -> ../usr/share/zoneinfo/America/Argentina/Buenos_Aires
```

---

## 5. Command reference with real output

### 5.1 Creating and inspecting

```
$ cd /srv/data
$ printf 'checksum=ok\n' > report.log

$ ln report.log report.bak            # hard link
$ ln -s report.log report.symlink     # symbolic link

$ ls -li
total 8
1442093 -rw-r--r-- 2 sre sre 12 Aug 26 09:14 report.bak
1442093 -rw-r--r-- 2 sre sre 12 Aug 26 09:14 report.log
1442097 lrwxrwxrwx 1 sre sre 10 Aug 26 09:16 report.symlink -> report.log
```

Read the columns: `report.bak` and `report.log` share inode `1442093` and both show link count **2**. The symlink has its own inode, link count 1, and size **10** — the byte length of the string `report.log`.

```
$ stat report.log
  File: report.log
  Size: 12              Blocks: 8          IO Block: 4096   regular file
Device: 253,0   Inode: 1442093     Links: 2
Access: (0644/-rw-r--r--)  Uid: ( 1000/     sre)   Gid: ( 1000/     sre)
Access: 2026-08-26 09:14:02.113445120 +0000
Modify: 2026-08-26 09:14:02.113445120 +0000
Change: 2026-08-26 09:15:47.885120044 +0000
 Birth: 2026-08-26 09:12:11.004112000 +0000
```

Creating the hard link updated **ctime** (the inode changed: `nlink` went from 1 to 2) but not mtime — the *data* was untouched. This distinction is exam material and forensics material both.

`stat` on a symlink needs `-L` to reach the target:

```
$ stat -c '%F %i %s' report.symlink
symbolic link 1442097 10
$ stat -L -c '%F %i %s' report.symlink
regular file 1442093 12
```

### 5.2 Proving identity and finding every name of an inode

```
$ find /srv/data -samefile report.log
/srv/data/report.log
/srv/data/report.bak

$ find /srv -xdev -inum 1442093
/srv/data/report.log
/srv/data/report.bak
```

`-samefile` is the correct tool: it handles the "which filesystem" question for you. `-inum` is only meaningful within one filesystem, hence `-xdev`. On ext4 you can also ask the filesystem directly, without a tree walk:

```
$ sudo debugfs -R "ncheck 1442093" /dev/mapper/vg0-srv 2>/dev/null
Inode   Pathname
1442093 /data/report.log
1442093 /data/report.bak
```

Audit every multiply-linked regular file on a filesystem:

```
$ sudo find / -xdev -type f -links +1 -printf '%n %i %p\n' | sort -rn | head -5
3 2621501 /backup/edge-proxy/2026-08-24T03-15-00Z/config/upstream.conf
3 2621501 /backup/edge-proxy/2026-08-25T03-15-00Z/config/upstream.conf
3 2621501 /backup/edge-proxy/2026-08-26T03-15-00Z/config/upstream.conf
2 1442093 /srv/data/report.bak
2 1442093 /srv/data/report.log
```

### 5.3 Resolving: `readlink` vs `realpath`

```
$ readlink report.symlink
report.log

$ readlink -f report.symlink
/srv/data/report.log

$ readlink -f /srv/app/current/bin/edge-proxy
/srv/app/releases/2026-08-26T09-30-00Z/bin/edge-proxy

$ realpath --relative-to=/srv/app /srv/app/releases/2026-08-26T09-30-00Z/bin
releases/2026-08-26T09-30-00Z/bin
```

| Option | `readlink` / `realpath` behaviour |
|---|---|
| *(bare `readlink`)* | Print the target string, one level, no canonicalisation. Fails on a non-symlink. |
| `-f` / `--canonicalize` | Follow every link recursively; **all but the last** component must exist |
| `-e` / `--canonicalize-existing` | Follow recursively; **every** component must exist |
| `-m` / `--canonicalize-missing` | Follow recursively; **no** component need exist |

Use `readlink -e` in scripts when a missing target must be an error, and `readlink -f` when you are computing the path of something you are about to create.

### 5.4 The `-n` / `-T` footgun, demonstrated

```
$ ls -l /srv/app/current
lrwxrwxrwx 1 deploy deploy 29 Aug 26 09:30 /srv/app/current -> releases/2026-08-26T09-30-00Z

$ cd /srv/app
$ sudo ln -sf releases/2026-08-26T11-00-00Z current      # WRONG
$ ls -l current/
lrwxrwxrwx 1 root root 29 Aug 26 11:02 2026-08-26T11-00-00Z -> releases/2026-08-26T11-00-00Z
...
$ readlink current
releases/2026-08-26T09-30-00Z
```

`ln -sf` **dereferenced** `current`, found a directory, and dropped the new link *inside* it. Production is still on the old release, `ln` exited 0, and the deploy pipeline reported success. With `-n`:

```
$ sudo ln -sfn releases/2026-08-26T11-00-00Z current
$ readlink current
releases/2026-08-26T11-00-00Z
```

`-T` is stricter still and is what belongs in a script — it refuses the directory interpretation entirely instead of depending on what the destination happens to be at that moment.

### 5.5 Relative vs absolute symlink targets

```
$ ln -s /srv/app/shared/config/upstream.conf /srv/app/current/upstream.conf   # absolute
$ ln -sr /srv/app/shared/config/upstream.conf /srv/app/current/upstream.conf  # relative
$ readlink /srv/app/current/upstream.conf
../shared/config/upstream.conf
```

| | Absolute target | Relative target |
|---|---|---|
| Survives moving the whole tree | **no** | **yes** |
| Survives `chroot` / container bind-mount at a different prefix | **no** | **yes** |
| Survives moving only the link | yes | no |
| Correct inside an image build / `rsync`ed tree | rarely | usually |
| Correct for a system-wide reference (`/etc/localtime`) | usually — but note Debian uses `../usr/share/...` | |

**Rule:** targets *within* the same managed tree are relative (`ln -sr`); targets crossing into a different administrative domain are absolute.

### 5.6 Hard-linking a symlink: `-L` vs `-P`

```
$ ln report.symlink hard-to-link            # default = -P on Linux
$ ls -li report.symlink hard-to-link
1442097 lrwxrwxrwx 2 sre sre 10 Aug 26 09:16 hard-to-link -> report.log
1442097 lrwxrwxrwx 2 sre sre 10 Aug 26 09:16 report.symlink -> report.log

$ ln -L report.symlink hard-to-target
$ ls -li hard-to-target
1442093 -rw-r--r-- 3 sre sre 12 Aug 26 09:14 hard-to-target
```

`-P` (the Linux default) hard-links the **symlink inode**: you get a second name for the pointer. `-L` follows it and hard-links the **referent**. POSIX leaves the default implementation-defined, so always confirm with `ls -li` rather than trusting the platform.

### 5.7 Copying: what `cp`, `tar` and `rsync` do to links

```
$ cp report.symlink copy-followed          # default: dereferences
$ cp -d report.symlink copy-preserved      # -d == --no-dereference --preserve=links
$ ls -li copy-followed copy-preserved
1442310 -rw-r--r-- 1 sre sre 12 Aug 26 09:50 copy-followed
1442311 lrwxrwxrwx 1 sre sre 10 Aug 26 09:50 copy-preserved -> report.log
```

| Tool / flag | Symbolic links | Hard links |
|---|---|---|
| `cp SRC DST` | **dereferenced** — you get a copy of the target | broken into independent copies |
| `cp -d` | preserved as links | preserved (`--preserve=links`) |
| `cp -a` | preserved (implies `-dR --preserve=all`) | preserved |
| `cp -L` | explicitly dereference | — |
| `cp -P` | explicitly never dereference | — |
| `cp -l` | — | create hard links instead of copying |
| `cp -s` | create symlinks instead of copying (absolute paths) | — |
| `cp --reflink=always` | — | CoW clone; **separate inode**, shared extents |
| `tar -cf` | stored as links | detected and stored as links |
| `tar -h` / `--dereference` | stored as the target's content | — |
| `tar --hard-dereference` | — | stored as full independent copies |
| `rsync -a` | preserved (`-l` implied) | **broken into copies** unless `-H` |
| `rsync -H` | — | preserved, at the cost of an in-memory inode map |
| `rsync -L` | transformed into the referent file | — |
| `rsync --safe-links` | drops links pointing outside the tree | — |

The `rsync -a` row is the expensive surprise: `-a` does **not** imply `-H`. Mirroring a hard-linked snapshot store without `-H` expands it to its full apparent size — the 40 GB store from §4.3 becomes 39 GB × the number of snapshots.

### 5.8 The limits

```
$ stat -f -c '%T' /srv/data
ext2/ext3
$ stat -c '%h' base
65000
$ ln base link.extra
ln: failed to create hard link 'link.extra' => 'base': Too many links
```

| Filesystem | Max hard links per inode | Notes |
|---|---|---|
| ext4 | 65 000 | `EXT4_LINK_MAX`; the `dir_nlink` feature lifts the limit for directories only |
| XFS | 2³²−1 | effectively unbounded for practical workloads |
| Btrfs | very large, but constrained per directory | the `extended_iref` feature raises the historical ~200-per-directory ceiling |
| tmpfs | very large | |
| FAT / exFAT / NTFS-3g (default) | **none** — no hard links | link creation returns `EPERM`/`EOPNOTSUPP` |
| NFS | server-dependent | unlink of an open file triggers *silly rename* to `.nfsXXXX` |

Cross-device attempts fail unambiguously:

```
$ ln /srv/data/report.log /tmp/report.log
ln: failed to create hard link '/tmp/report.log' => '/srv/data/report.log': Invalid cross-device link

$ stat -c '%d %n' /srv/data/report.log /tmp
64768 /srv/data/report.log
27 /tmp
```

Different device numbers, therefore different filesystems, therefore `EXDEV`. A symlink is the only option.

### 5.9 Ownership and permissions

```
$ chmod 600 report.bak
$ ls -l report.log report.bak
-rw------- 2 sre sre 12 Aug 26 09:14 report.bak
-rw------- 2 sre sre 12 Aug 26 09:14 report.log
```

One inode, one mode. `chmod` through *any* hard link changes the file for *every* name. There is no such thing as per-name permissions.

```
$ sudo chown root:root report.symlink        # follows the link!
$ ls -l report.log report.symlink
-rw------- 2 root root 12 Aug 26 09:14 report.log
lrwxrwxrwx 1  sre  sre 10 Aug 26 09:16 report.symlink -> report.log

$ sudo chown -h root:root report.symlink     # changes the LINK
$ ls -l report.symlink
lrwxrwxrwx 1 root root 10 Aug 26 09:16 report.symlink -> report.log
```

Symlink permission bits are always `lrwxrwxrwx` and Linux ignores them entirely. Symlink **ownership**, however, is load-bearing: it is what `fs.protected_symlinks` checks (§7).

---

## 6. Verification and failure diagnosis

### 6.1 The triage table

| Symptom / error | Root cause | First command |
|---|---|---|
| `Invalid cross-device link` (`EXDEV`) | Hard link across filesystems | `stat -c '%d %n' src dst_dir` |
| `Operation not permitted` (`EPERM`) on `ln` | Hard link to a directory, or `fs.protected_hardlinks` denied it | `sysctl fs.protected_hardlinks`; `stat -c %F target` |
| `Too many links` (`EMLINK`) | Inode link count at the filesystem maximum | `stat -c %h target` |
| `Too many levels of symbolic links` (`ELOOP`) | Symlink cycle, or > 40 nested hops | `namei -l PATH` |
| `No such file or directory` on a path `ls` clearly shows | Dangling symlink, or a relative target resolved from the link's directory | `namei -l PATH`; `find DIR -xtype l` |
| `Is a directory` / `Not a directory` from `mv -T` | The "symlink" is really a directory | `stat -c %F PATH` |
| `df` reports full, `du` reports far less | Deleted files still held open | `lsof +L1` |
| `du` reports far less than expected | Hard links counted once per traversal | `du --count-links` |
| Config edit "didn't take effect" | `sed -i` replaced the symlink with a regular file | `ls -l /path/to/config` |
| ConfigMap change never reaches the pod | `subPath` mount bypasses the `..data` symlink | `kubectl exec -- ls -la MOUNTPATH` |
| Log shipper runs, ships nothing | Symlink chain unresolvable in the collector's mount namespace | `kubectl exec -- find /var/log/containers -xtype l` |
| An old backup "changed by itself" | In-place write into a hard-linked snapshot | `stat -c %h FILE` across snapshots |
| Editing a file broke its hard link | Editor rewrote via temp file + rename | `stat -c '%h %i' FILE` before/after |

### 6.2 Finding broken symlinks

```
$ find /srv/app -xtype l -printf '%p -> %l\n'
/srv/app/shared/config/tls.pem -> /etc/letsencrypt/live/edge.example.net/fullchain.pem
```

`-xtype l` under the default `-P` policy matches exactly the symlinks that fail to resolve. The portable equivalent, when `-xtype` is unavailable:

```
$ find /srv/app -type l ! -exec test -e {} \; -print
```

Cluster-wide, as a scheduled check:

```
$ sudo find / -xdev -xtype l -printf '%p -> %l\n' 2>/dev/null | tee /var/log/dangling-links.txt | wc -l
7
```

Beware the false positive: a symlink whose target lives in a filesystem not mounted at scan time is reported as broken and is not.

### 6.3 Diagnosing `ELOOP`

```
$ ln -s a b
$ ln -s b a
$ cat a
cat: a: Too many levels of symbolic links

$ namei -l a
f: a
lrwxrwxrwx sre sre   a -> b
lrwxrwxrwx sre sre   b -> a
           ...       a -> b
namei: too many levels of symbolic links: a
```

Also produced by a self-referential path like `ln -s . loop` traversed as `loop/loop/loop/...`, and by chains longer than 40 hops that contain no actual cycle.

### 6.4 `df` vs `du`, resolved properly

```
$ df -h /var/log
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg0-varlog     20G   19G  158M  99% /var/log

$ sudo du -sh /var/log
1.9G    /var/log
```

A 17 GB gap. Two candidate causes, and one command distinguishes them:

```
$ sudo lsof +L1
COMMAND    PID     USER   FD   TYPE DEVICE   SIZE/OFF NLINK    NODE NAME
nginx    14122 www-data    5w   REG  253,3 16106127360     0 1442311 /var/log/nginx/access.log (deleted)
```

`NLINK 0` with an open descriptor: the file was `rm`'d (or rotated with `create` while nginx held it open) and the kernel is holding 16 GB until the descriptor closes. The fix is to make the process release the descriptor, not to delete anything else:

```
$ sudo systemctl reload nginx        # nginx reopens its logs on SIGUSR1/HUP
$ df -h /var/log
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg0-varlog     20G  2.0G   17G  11% /var/log
```

If `lsof +L1` is empty, the remaining explanation is hard links: `du` counts each inode once, so a tree full of hard-linked snapshots legitimately reports less than `df`. Confirm with `du -s --count-links`.

Truncating the descriptor is the emergency valve when a reload is not possible:

```
$ sudo truncate -s 0 /proc/14122/fd/5
```

`/proc/<pid>/fd/5` is a magic symlink to the deleted inode; writing through it reaches the file that has no name.

### 6.5 The `sed -i` / editor hazard

`sed -i`, `perl -i`, `vim` with the default `backupcopy`, `ansible.builtin.lineinfile`, and most "edit in place" tooling do **not** edit in place. They write a temporary file and `rename(2)` it over the destination. That creates a **new inode**, which:

- **replaces a symlink with a regular file**, and
- **breaks a hard link**, silently detaching the file from its other names.

```
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Aug 20 10:11 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf

$ sudo sed -i 's/^nameserver .*/nameserver 10.0.0.53/' /etc/resolv.conf

$ ls -l /etc/resolv.conf
-rw-r--r-- 1 root root 78 Aug 26 09:41 /etc/resolv.conf
```

The symlink is gone. `systemd-resolved` now maintains a file nothing reads, and the next `systemd-tmpfiles`/package run may or may not restore the link. The correct invocation:

```
$ sudo sed --follow-symlinks -i 's/^nameserver .*/nameserver 10.0.0.53/' /etc/resolv.conf
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Aug 20 10:11 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
```

For hard links, the equivalent proof:

```
$ stat -c '%h %i' /srv/data/report.log
2 1442093
$ sed -i 's/ok/degraded/' /srv/data/report.log
$ stat -c '%h %i' /srv/data/report.log /srv/data/report.bak
1 1442401 /srv/data/report.log
1 1442093 /srv/data/report.bak
```

Different inodes, both with `nlink` 1 — the link is broken and `report.bak` still holds the old content. In `vim`, `:set backupcopy=yes` forces truncate-and-rewrite of the original inode, preserving both symlinks and hard links, at the cost of a window where the file is truncated.

### 6.6 The verification checklist

Run these after any change involving links, before declaring the change done:

```bash
# 1. The link points where you think it points, through every hop.
namei -l /srv/app/current/bin/edge-proxy

# 2. Nothing in the managed tree dangles.
find /srv/app -xtype l -printf 'DANGLING: %p -> %l\n'

# 3. The intended sharing exists (hard links) or does not (independent copies).
stat -c 'nlink=%h inode=%i %n' /srv/app/shared/LICENCE /srv/app/releases/*/LICENCE

# 4. The path a service will actually open resolves, as that service's user.
sudo -u deploy readlink -e /srv/app/current/bin/edge-proxy || echo 'UNRESOLVABLE'

# 5. Space accounting is what you expect.
du -sh --count-links /backup/edge-proxy/latest   # apparent
du -sh              /backup/edge-proxy           # actual

# 6. No deleted-but-open files are hiding capacity.
sudo lsof +L1 | awk 'NR==1 || $NF ~ /deleted/'

# 7. The link survives a reboot (it is declared, not hand-made).
systemd-analyze verify /etc/systemd/system/snapshot.timer
sudo systemd-tmpfiles --create --dry-run /etc/tmpfiles.d/edge-proxy.conf
```

---

## 7. Security: links are a privilege-escalation surface

Two classic attack shapes, and the two sysctls that close them.

**Symlink attack (TOCTOU).** A privileged process is induced to write to `/tmp/predictable-name`, which an attacker has pre-created as a symlink to `/etc/shadow`. The privileged write follows the link.

**Hard-link attack.** An attacker hard-links a file they cannot read (say `/etc/shadow`) into a directory they control. Later, a privileged process — a backup job, a `chmod -R`, a cleanup script — operates on the attacker's directory and changes the mode or ownership of that inode. Because a hard link *is* the file, the change lands on `/etc/shadow`.

```
$ sysctl fs.protected_symlinks fs.protected_hardlinks fs.protected_regular fs.protected_fifos
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 1
```

| Sysctl | Effect when set to 1 | Error when denied |
|---|---|---|
| `fs.protected_symlinks` | In world-writable **sticky** directories (`/tmp`, `/var/tmp`, `/dev/shm`), a symlink is followed only when the follower is the symlink's owner or the directory's owner | `EACCES` |
| `fs.protected_hardlinks` | A hard link to a file may be created only by its owner, or by a user with read **and** write access to it, and only for regular non-setuid/setgid files (`CAP_FOWNER` exempt) | `EPERM` |
| `fs.protected_regular` | `O_CREAT` opens of existing regular files in world-writable sticky directories are refused when the file is owned by someone else | `EACCES` |
| `fs.protected_fifos` | Same protection for FIFOs | `EACCES` |

Observed refusal:

```
$ ln /etc/shadow /tmp/s
ln: failed to create hard link '/tmp/s' => '/etc/shadow': Operation not permitted
```

Persist the settings — this is the correct declarative form:

`/etc/sysctl.d/60-fs-hardening.conf`:

```
# Mitigate symlink/hardlink TOCTOU escalation in world-writable directories.
# See Documentation/admin-guide/sysctl/fs.rst in the kernel tree.
fs.protected_symlinks  = 1
fs.protected_hardlinks = 1
fs.protected_regular   = 2
fs.protected_fifos     = 1
```

```
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-fs-hardening.conf ...
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 1
```

Two operational consequences worth planning for:

- `fs.protected_hardlinks=1` breaks hard-linked backup jobs that run as a non-root user over files owned by services. Run the snapshot job with `CAP_FOWNER`/root, or place the source and destination under one ownership.
- Symlinks that escape a container build context become dangling inside the resulting image. Audit with `find / -xdev -xtype l` as a final image-build step.

---

## 8. Exam-focused summary

**The commands the objective names:** `ln`, `ln -s`, plus `ls`, `find`, `cp`, `rm`, `mv`, `stat`, `readlink`.

**The facts most often tested:**

1. A hard link and its target are **the same file**; `ls -li` shows the same inode number and a link count ≥ 2.
2. Hard links **cannot cross filesystems** and **cannot point to directories**.
3. A symbolic link is a **separate file** whose content is a path; `ls -l` shows type `l`, the `-> target` suffix, and a size equal to the target string's length.
4. Deleting the target of a symlink leaves a **broken link**; deleting one hard link leaves the data intact while any other link remains.
5. A directory's link count is **2 + number of subdirectories**.
6. `ln target linkname` — target first, always. With one argument, the link is created in the current directory with the target's basename.
7. `ln -s` with a **relative** target resolves from the **link's** directory, not the shell's CWD.
8. `cp` follows symlinks by default; `cp -d`/`-a`/`-P` preserve them.
9. `chmod`/`chown` on a symlink affect the **target**; `-h` (`chown -h`, `chmod` has no such option) affects the link.
10. `rm` on a symlink removes the link, never the target. A trailing slash (`rm dirlink/`) is the classic way to get this wrong.

**The five commands to have in muscle memory:**

```bash
ln target linkname               # hard link
ln -s target linkname            # symbolic link
ln -sfn newtarget existinglink   # safely repoint an existing directory symlink
ls -li                           # inode number + link count + link target
find DIR -xtype l                # every broken symlink beneath DIR
```

**Traps to expect:**

- `ln -sf newtarget existing_dir_symlink` **without** `-n` creates the link *inside* the directory and exits 0.
- `du` under-reports hard-linked trees; `df` does not.
- `rsync -a` does **not** preserve hard links; `-H` does.
- `sed -i` on a symlinked config replaces the symlink.
- The link count column in `ls -l` is the **second** field, not the first.

---

## 9. References

**LPI — certification objectives**

- LPIC-1 Exam 101 objectives (version 5.0), objective 104.6 — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPIC-1 certification overview — <https://www.lpi.org/our-certifications/lpic-1-overview/>

**Linux man-pages project — syscalls and file semantics**

- `link(2)` — <https://man7.org/linux/man-pages/man2/link.2.html>
- `symlink(2)` — <https://man7.org/linux/man-pages/man2/symlink.2.html>
- `unlink(2)` — <https://man7.org/linux/man-pages/man2/unlink.2.html>
- `rename(2)` (atomic replace) — <https://man7.org/linux/man-pages/man2/rename.2.html>
- `readlink(2)` — <https://man7.org/linux/man-pages/man2/readlink.2.html>
- `stat(2)` (`st_nlink`, `st_ino`, `st_dev`) — <https://man7.org/linux/man-pages/man2/stat.2.html>
- `symlink(7)` — symlink handling and following semantics — <https://man7.org/linux/man-pages/man7/symlink.7.html>
- `path_resolution(7)` — <https://man7.org/linux/man-pages/man7/path_resolution.7.html>
- `inode(7)` — <https://man7.org/linux/man-pages/man7/inode.7.html>
- `proc(5)` — `/proc/[pid]/fd` magic symlinks — <https://man7.org/linux/man-pages/man5/proc.5.html>
- `namei(1)` — <https://man7.org/linux/man-pages/man1/namei.1.html>

**GNU coreutils — the tools themselves**

- `ln` invocation — <https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html>
- `cp` invocation (`-a`, `-d`, `-l`, `-s`, `--reflink`, `--preserve=links`) — <https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html>
- `du` invocation (`--count-links`) — <https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html>
- `readlink` invocation — <https://www.gnu.org/software/coreutils/manual/html_node/readlink-invocation.html>
- `realpath` invocation — <https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html>

**Kernel documentation**

- `fs` sysctl reference — `protected_symlinks`, `protected_hardlinks`, `protected_regular`, `protected_fifos` — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html>
- ext4 filesystem documentation — <https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html>
- Overlay filesystem — <https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html>

**POSIX / The Open Group Base Specifications, Issue 8**

- `ln` utility — <https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ln.html>
- `link()` — <https://pubs.opengroup.org/onlinepubs/9799919799/functions/link.html>
- `symlink()` — <https://pubs.opengroup.org/onlinepubs/9799919799/functions/symlink.html>

**Standards and system tooling**

- Filesystem Hierarchy Standard 3.0 — <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- `systemd.unit(5)` — unit enablement via symlinks — <https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html>
- `tmpfiles.d(5)` — the `L` and `L+` line types — <https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html>
- `update-alternatives(1)`, Debian — <https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html>
- `rsync(1)` — `-H`, `-L`, `--link-dest`, `--safe-links` — <https://download.samba.org/pub/rsync/rsync.1>
- GNU `tar` manual — hard link and dereference handling — <https://www.gnu.org/software/tar/manual/html_node/dereference.html>
- GNU `sed` manual — `--follow-symlinks` — <https://www.gnu.org/software/sed/manual/sed.html>
- `lsof(8)` — `+L` for link-count selection — <https://man7.org/linux/man-pages/man8/lsof.8.html>

**Kubernetes and containers**

- ConfigMaps — mounted-volume update semantics — <https://kubernetes.io/docs/concepts/configuration/configmap/>
- Volumes — `subPath` and the absence of automatic updates — <https://kubernetes.io/docs/concepts/storage/volumes/>
- System and container logging architecture — <https://kubernetes.io/docs/concepts/cluster-administration/logging/>
- Dockerfile reference — `COPY` and link handling — <https://docs.docker.com/reference/dockerfile/>

**Ansible**

- `ansible.builtin.file` — `state: link`, `state: hard`, `follow`, `force` — <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html>
- `ansible.builtin.lineinfile` — the `follow` parameter — <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/lineinfile_module.html>