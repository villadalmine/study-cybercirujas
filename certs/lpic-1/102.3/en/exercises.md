# 102.3 — Manage Shared Libraries: Guided Exercises

**LPIC-1 / Exam 101-500, Topic 102.3 — weight 1.56**
Objective coverage: identify shared libraries, understand the system library search path, load shared libraries, `ldd`, `ldconfig`, `/etc/ld.so.conf`, `LD_LIBRARY_PATH`.

---

## Lab environment

These exercises are written against **Debian 12 / Ubuntu 24.04 on x86_64** (multiarch paths). Where RHEL/Fedora/openSUSE differ, the difference is called out — knowing *which* paths are distro convention and which are hard-coded into `ld.so` is itself an exam-level distinction.

Prepare the box:

```bash
sudo apt-get install -y build-essential binutils file    # Debian/Ubuntu
# sudo dnf install -y gcc binutils file glibc-devel      # RHEL/Fedora
mkdir -p ~/lab-102.3 && cd ~/lab-102.3
```

> **Safety.** Exercises 7 and 8 modify `/etc/ld.so.conf.d/` and deliberately break a link. Run them on a disposable VM, a container (`docker run -it --rm debian:12 bash`), or accept that you must run the documented rollback. **Never** experiment with `LD_PRELOAD`, `/etc/ld.so.preload`, or a moved `libc.so.6` on a machine you cannot reinstall.

---

## Block 1 — Static vs. dynamic: what is actually linked

The whole topic exists because of one design decision: a binary can carry its library code inside itself (static) or ask the kernel to load it at runtime (dynamic). Everything else — the cache, the search path, `ldconfig` — is plumbing for the second case.

### Steps

1. Identify the linkage type of a normal system binary:

   ```bash
   file /bin/ls
   ```

   Expected output:

   ```
   /bin/ls: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked,
   interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=..., for GNU/Linux 3.2.0, stripped
   ```

2. Now compile the same trivial program twice, once each way:

   ```bash
   cd ~/lab-102.3
   printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' > hi.c
   gcc hi.c -o hi-dynamic
   gcc -static hi.c -o hi-static
   ```

3. Compare them:

   ```bash
   ls -l hi-dynamic hi-static
   file hi-dynamic hi-static
   ```

   Expected output (sizes vary by glibc version):

   ```
   -rwxr-xr-x 1 user user   16040 Aug 25 10:12 hi-dynamic
   -rwxr-xr-x 1 user user  916312 Aug 25 10:12 hi-static

   hi-dynamic: ELF 64-bit LSB pie executable, x86-64, ..., dynamically linked,
               interpreter /lib64/ld-linux-x86-64.so.2, ...
   hi-static:  ELF 64-bit LSB executable, x86-64, ..., statically linked, ...
   ```

4. Ask the dynamic linker what each one needs:

   ```bash
   ldd hi-dynamic
   ldd hi-static
   ```

   Expected output:

   ```
   	linux-vdso.so.1 (0x00007ffd4b1fe000)
   	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f0e2a000000)
   	/lib64/ld-linux-x86-64.so.2 (0x00007f0e2a2b1000)

   	not a dynamic executable
   ```

5. Inspect the ELF program header that names the loader itself:

   ```bash
   readelf -l hi-dynamic | grep -A1 INTERP
   ```

   Expected output:

   ```
     INTERP         0x0000000000000318 0x0000000000000318 0x0000000000000318
                    0x000000000000001c 0x000000000000001c  R      0x1
       [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
   ```

### Check your understanding

- **Q1.1** — `hi-static` is ~57× larger than `hi-dynamic`. Where did the extra ~900 KB come from, and why is the dynamic one still able to run?
- **Q1.2** — `ldd hi-static` prints `not a dynamic executable`. Is that an error?
- **Q1.3** — What is `linux-vdso.so.1`, and why does `ls -l` on that path fail?
- **Q1.4** — `/lib64/ld-linux-x86-64.so.2` appears in `ldd` output *without* a `=>` arrow. What does that tell you about how it was found?
- **Q1.5** — Name one operational advantage of static linking and one of dynamic linking, in production terms (not "smaller/bigger").

---

## Block 2 — Reading the dynamic section directly

`ldd` is convenient and, on untrusted binaries, unsafe: on glibc it may run the binary via the loader to resolve dependencies. `readelf` and `objdump` only *read* the file. Build the habit now.

### Steps

1. List the declared dependencies of `/bin/ls` without executing anything:

   ```bash
   readelf -d /bin/ls | grep NEEDED
   ```

   Expected output (Debian 12):

   ```
    0x0000000000000001 (NEEDED)             Shared library: [libselinux.so.1]
    0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
   ```

2. Do the same with `objdump`:

   ```bash
   objdump -p /bin/ls | grep -E 'NEEDED|SONAME|RPATH|RUNPATH'
   ```

3. Now look at a *library* and find its SONAME:

   ```bash
   objdump -p /lib/x86_64-linux-gnu/libc.so.6 | grep SONAME
   ```

   Expected output:

   ```
     SONAME               libc.so.6
   ```

4. Compare the recursive view against the declared view:

   ```bash
   readelf -d /bin/ls | grep -c NEEDED     # direct dependencies only
   ldd /bin/ls | wc -l                     # transitive closure + vdso + loader
   ```

   Expected output:

   ```
   2
   5
   ```

5. Check for unresolved symbols (a failure mode `ldd` alone hides):

   ```bash
   ldd -r /bin/ls
   ```

   A clean binary prints the same list with no `undefined symbol:` lines.

6. List the symbols a library *exports*:

   ```bash
   nm -D --defined-only /lib/x86_64-linux-gnu/libc.so.6 | grep -w ' T printf'
   ```

   Expected output:

   ```
   0000000000060c50 T printf@@GLIBC_2.2.5
   ```

### Check your understanding

- **Q2.1** — `readelf -d /bin/ls` shows 2 `NEEDED` entries but `ldd` shows 5 lines. Account for every extra line.
- **Q2.2** — Why is running `ldd ./suspicious-binary` on a file you downloaded a security problem, and what do you run instead?
- **Q2.3** — What is the difference between a library's *SONAME* and its *file name on disk*? Which one does the linker record in the executable?
- **Q2.4** — `printf@@GLIBC_2.2.5` — what are the `@@` and the version tag for?
- **Q2.5** — A binary shows `RUNPATH  $ORIGIN/../lib`. What does `$ORIGIN` expand to, and why do vendors ship software this way?

---

## Block 3 — The cache: `ldconfig -p` and `/etc/ld.so.cache`

Scanning every directory in the search path on every `exec()` would be unacceptably slow. glibc precomputes a hash table of `SONAME → path` in `/etc/ld.so.cache`. `ldconfig` builds it; the loader reads it.

### Steps

1. Look at the cache header and its size:

   ```bash
   ldconfig -p | head -5
   ls -lh /etc/ld.so.cache
   file /etc/ld.so.cache
   ```

   Expected output:

   ```
   1187 libs found in cache `/etc/ld.so.cache'
   	libzstd.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libzstd.so.1
   	libz.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libz.so.1
   	libuuid.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libuuid.so.1
   	libudev.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libudev.so.1

   -rw-r--r-- 1 root root 79K Aug 20 09:31 /etc/ld.so.cache
   /etc/ld.so.cache: data
   ```

2. Query the cache for one specific library — this is the everyday use of `ldconfig -p`:

   ```bash
   ldconfig -p | grep -w libssl.so.3
   ```

   Expected output:

   ```
   	libssl.so.3 (libc6,x86-64) => /lib/x86_64-linux-gnu/libssl.so.3
   ```

3. Read the configuration that feeds the cache:

   ```bash
   cat /etc/ld.so.conf
   ls /etc/ld.so.conf.d/
   cat /etc/ld.so.conf.d/*.conf
   ```

   Expected output (Debian 12):

   ```
   include /etc/ld.so.conf.d/*.conf

   libc.conf  x86_64-linux-gnu.conf

   # libc default configuration
   /usr/local/lib
   # Multiarch support
   /usr/local/lib/x86_64-linux-gnu
   /lib/x86_64-linux-gnu
   /usr/lib/x86_64-linux-gnu
   ```

   On RHEL 9 you will instead see `include ld.so.conf.d/*.conf` and files such as `kernel-*.conf`, with `/lib64` and `/usr/lib64` **absent** — because they are compiled into `ld.so` as trusted directories.

4. Watch `ldconfig` do its work, directory by directory, **without** writing anything:

   ```bash
   sudo ldconfig -v -N -X 2>/dev/null | head -12
   ```

   Expected output:

   ```
   /usr/local/lib:
   /lib/x86_64-linux-gnu:
   	libnss_files.so.2 -> libnss_files.so.2
   	libpcre2-8.so.0 -> libpcre2-8.so.0.11.2
   	libselinux.so.1 -> libselinux.so.1
   ...
   ```

5. Confirm that a plain `ldconfig` run is idempotent:

   ```bash
   sudo cp /etc/ld.so.cache /tmp/cache.before
   sudo ldconfig
   cmp /tmp/cache.before /etc/ld.so.cache && echo "identical"
   ```

### Check your understanding

- **Q3.1** — `file /etc/ld.so.cache` says `data`. Why is it not a text file, and what happens if you edit it with `vim`?
- **Q3.2** — In step 4, what do `-N` and `-X` each suppress? Why is `-N -X` the safe way to preview?
- **Q3.3** — In the `ldconfig -v` output, the line `libpcre2-8.so.0 -> libpcre2-8.so.0.11.2` describes an action. Which of the three library names is on the left, which on the right, and who created the symlink?
- **Q3.4** — `/lib64` does not appear in `/etc/ld.so.conf.d/*.conf` on RHEL. Why are libraries there still found?
- **Q3.5** — You installed a package by hand into `/opt/acme/lib`. What is the *correct* persistent way to make its libraries visible system-wide, in two commands?

---

## Block 4 — Build a shared library and meet its three names

Every shared library has three names, and confusing them is the single most common source of "it built but won't run".

| Name | Example | Who uses it | Who creates it |
|---|---|---|---|
| **Real name** | `libgreet.so.1.0.0` | nobody directly | the compiler/`make install` |
| **SONAME** | `libgreet.so.1` | the *runtime* loader | `ldconfig` (symlink) |
| **Linker name** | `libgreet.so` | `gcc -lgreet` at *build* time | the `-dev`/`-devel` package |

### Steps

1. Write the library source:

   ```bash
   cd ~/lab-102.3
   cat > greet.c <<'EOF'
   #include <stdio.h>

   void greet(const char *who)
   {
           printf("hello, %s (libgreet v1)\n", who);
   }
   EOF
   ```

2. Compile position-independent code and link it as a shared object, **declaring the SONAME explicitly**:

   ```bash
   gcc -fPIC -Wall -c greet.c -o greet.o
   gcc -shared -Wl,-soname,libgreet.so.1 -o libgreet.so.1.0.0 greet.o
   ```

3. Verify the SONAME is baked into the file:

   ```bash
   objdump -p libgreet.so.1.0.0 | grep SONAME
   file libgreet.so.1.0.0
   ```

   Expected output:

   ```
     SONAME               libgreet.so.1

   libgreet.so.1.0.0: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV),
   dynamically linked, BuildID[sha1]=..., not stripped
   ```

4. Let `ldconfig` create the SONAME symlink for you, in this directory only:

   ```bash
   ldconfig -n .
   ls -l libgreet*
   ```

   Expected output:

   ```
   lrwxrwxrwx 1 user user    17 Aug 25 10:40 libgreet.so.1 -> libgreet.so.1.0.0
   -rwxr-xr-x 1 user user 15920 Aug 25 10:39 libgreet.so.1.0.0
   ```

5. Add the linker name by hand (this is what a `-dev` package ships):

   ```bash
   ln -sf libgreet.so.1 libgreet.so
   ```

6. Write and link a consumer:

   ```bash
   cat > main.c <<'EOF'
   void greet(const char *who);

   int main(void)
   {
           greet("LPIC-1");
           return 0;
   }
   EOF
   gcc main.c -L. -lgreet -o hello
   ```

7. Confirm what the *executable* recorded, then try to run it:

   ```bash
   readelf -d hello | grep NEEDED
   ./hello
   ```

   Expected output:

   ```
    0x0000000000000001 (NEEDED)             Shared library: [libgreet.so.1]
    0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]

   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   ```

8. Diagnose it the way you would in production:

   ```bash
   ldd ./hello
   ```

   Expected output:

   ```
   	linux-vdso.so.1 (0x00007ffc9f7f6000)
   	libgreet.so.1 => not found
   	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f4b1c000000)
   	/lib64/ld-linux-x86-64.so.2 (0x00007f4b1c2a4000)
   ```

### Check your understanding

- **Q4.1** — You linked with `-lgreet`, which resolved `libgreet.so` (the linker name), yet `readelf -d hello` records `libgreet.so.1`. Explain the mechanism that turned one into the other.
- **Q4.2** — Why is `-fPIC` required for the library but not for `main.c`?
- **Q4.3** — The library file is sitting in the *current directory* and you ran `./hello` from that same directory. Why is it still `not found`?
- **Q4.4** — What exactly did `ldconfig -n .` do, and how does `-n` differ from a bare `ldconfig`?
- **Q4.5** — If you had omitted `-Wl,-soname,libgreet.so.1`, what would `readelf -d hello | grep NEEDED` have shown, and why is that a latent production bug?

---

## Block 5 — `LD_LIBRARY_PATH` and the real search order

### Steps

1. Make the previous binary work with an environment variable:

   ```bash
   cd ~/lab-102.3
   LD_LIBRARY_PATH=$PWD ./hello
   ```

   Expected output:

   ```
   hello, LPIC-1 (libgreet v1)
   ```

2. Confirm it is per-process, not persistent:

   ```bash
   ./hello
   ```

   Expected output:

   ```
   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   ```

3. Export it and observe that `ldd` obeys it too:

   ```bash
   export LD_LIBRARY_PATH=$PWD
   ldd ./hello | grep greet
   ```

   Expected output:

   ```
   	libgreet.so.1 => /home/user/lab-102.3/libgreet.so.1 (0x00007f3a5c9f0000)
   ```

4. Trace the actual search with `LD_DEBUG` — this is the tool that ends arguments about search order:

   ```bash
   LD_DEBUG=libs ./hello 2>&1 | head -20
   ```

   Expected output (abridged):

   ```
        4711:	find library=libgreet.so.1 [0]; searching
        4711:	 search path=/home/user/lab-102.3		(LD_LIBRARY_PATH)
        4711:	  trying file=/home/user/lab-102.3/libgreet.so.1
        4711:
        4711:	find library=libc.so.6 [0]; searching
        4711:	 search path=/home/user/lab-102.3		(LD_LIBRARY_PATH)
        4711:	  trying file=/home/user/lab-102.3/libc.so.6
        4711:	 search cache=/etc/ld.so.cache
        4711:	  trying file=/lib/x86_64-linux-gnu/libc.so.6
   ```

5. See the full menu of debug channels:

   ```bash
   LD_DEBUG=help ./hello
   ```

6. Prove that `LD_LIBRARY_PATH` is stripped for privileged binaries:

   ```bash
   ls -l /usr/bin/passwd            # note the 's' in the mode
   LD_DEBUG=libs /usr/bin/passwd --help 2>&1 | head -3
   ```

   Expected output:

   ```
   -rwsr-xr-x 1 root root 68208 Mar 23  2023 /usr/bin/passwd
   ```

   …and **no** `LD_DEBUG` trace at all: the loader ignores these variables for set-user-ID binaries.

7. Clean up before the next block:

   ```bash
   unset LD_LIBRARY_PATH
   ```

### The authoritative order

For each `NEEDED` SONAME, glibc's `ld.so` searches, in this order:

1. `DT_RPATH` in the object — **only if** `DT_RUNPATH` is absent (deprecated).
2. `LD_LIBRARY_PATH` — ignored entirely for set-user-ID / set-group-ID / capability-bearing binaries.
3. `DT_RUNPATH` in the object.
4. `/etc/ld.so.cache` — unless the object was linked with `-z nodeflib`.
5. The trusted default directories: `/lib`, `/usr/lib` (plus `/lib64`, `/usr/lib64` on 64-bit).

### Check your understanding

- **Q5.1** — Put these in search order and state the one conditional relationship between two of them: `LD_LIBRARY_PATH`, `DT_RUNPATH`, `/etc/ld.so.cache`, `DT_RPATH`, `/lib`.
- **Q5.2** — In step 4's trace, why does the loader try `/home/user/lab-102.3/libc.so.6` and fail, before finding the real `libc.so.6`?
- **Q5.3** — Why does the loader ignore `LD_LIBRARY_PATH` for `/usr/bin/passwd`? Describe the attack it prevents.
- **Q5.4** — A colleague fixes a missing-library error by adding `export LD_LIBRARY_PATH=/opt/app/lib` to `/etc/profile`. Give three concrete reasons this is the wrong fix, and state the right one.
- **Q5.5** — `LD_LIBRARY_PATH` is set to `/a:/b` and `/etc/ld.so.cache` maps `libfoo.so.1` to `/usr/lib/libfoo.so.1`. A copy also exists in `/b`. Which one loads?

---

## Block 6 — Installing the library properly, and the ABI break

### Steps

1. Install the library where a locally built package belongs, per the FHS:

   ```bash
   cd ~/lab-102.3
   sudo install -m 0755 libgreet.so.1.0.0 /usr/local/lib/
   sudo ldconfig
   ```

2. Verify that `ldconfig` created the SONAME symlink and cached the entry:

   ```bash
   ls -l /usr/local/lib/libgreet*
   ldconfig -p | grep greet
   ```

   Expected output:

   ```
   lrwxrwxrwx 1 root root    17 Aug 25 11:02 /usr/local/lib/libgreet.so.1 -> libgreet.so.1.0.0
   -rwxr-xr-x 1 root root 15920 Aug 25 11:02 /usr/local/lib/libgreet.so.1.0.0

   	libgreet.so.1 (libc6,x86-64) => /usr/local/lib/libgreet.so.1
   ```

   > If nothing appears, your distribution does not include `/usr/local/lib` in the search path. Add it: `echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/local.conf && sudo ldconfig`.

3. Run the binary with no environment tricks:

   ```bash
   ./hello
   ldd ./hello | grep greet
   ```

   Expected output:

   ```
   hello, LPIC-1 (libgreet v1)
   	libgreet.so.1 => /usr/local/lib/libgreet.so.1 (0x00007f1b2c9f0000)
   ```

4. Ship a **compatible** update — same SONAME, new real name:

   ```bash
   sed -i 's/libgreet v1/libgreet v1.1/' greet.c
   gcc -fPIC -c greet.c -o greet.o
   gcc -shared -Wl,-soname,libgreet.so.1 -o libgreet.so.1.1.0 greet.o
   sudo install -m 0755 libgreet.so.1.1.0 /usr/local/lib/
   sudo ldconfig
   ls -l /usr/local/lib/libgreet.so.1
   ./hello
   ```

   Expected output:

   ```
   lrwxrwxrwx 1 root root 17 Aug 25 11:08 /usr/local/lib/libgreet.so.1 -> libgreet.so.1.1.0
   hello, LPIC-1 (libgreet v1.1)
   ```

   The binary was **not** recompiled. That is the point of the SONAME.

5. Now ship an **incompatible** update — the function signature changes, so the SONAME must change:

   ```bash
   cat > greet.c <<'EOF'
   #include <stdio.h>

   void greet(const char *who, int times)
   {
           for (int i = 0; i < times; i++)
                   printf("hello, %s (libgreet v2)\n", who);
   }
   EOF
   gcc -fPIC -c greet.c -o greet.o
   gcc -shared -Wl,-soname,libgreet.so.2 -o libgreet.so.2.0.0 greet.o
   sudo install -m 0755 libgreet.so.2.0.0 /usr/local/lib/
   sudo ldconfig
   ls -l /usr/local/lib/libgreet*
   ./hello
   ```

   Expected output:

   ```
   lrwxrwxrwx 1 root root    17 ... /usr/local/lib/libgreet.so.1 -> libgreet.so.1.1.0
   lrwxrwxrwx 1 root root    17 ... /usr/local/lib/libgreet.so.2 -> libgreet.so.2.0.0
   -rwxr-xr-x 1 root root 15920 ... /usr/local/lib/libgreet.so.1.0.0
   -rwxr-xr-x 1 root root 15928 ... /usr/local/lib/libgreet.so.1.1.0
   -rwxr-xr-x 1 root root 16040 ... /usr/local/lib/libgreet.so.2.0.0

   hello, LPIC-1 (libgreet v1.1)
   ```

6. Confirm both majors coexist in the cache:

   ```bash
   ldconfig -p | grep greet
   ```

   Expected output:

   ```
   	libgreet.so.2 (libc6,x86-64) => /usr/local/lib/libgreet.so.2
   	libgreet.so.1 (libc6,x86-64) => /usr/local/lib/libgreet.so.1
   ```

### Check your understanding

- **Q6.1** — In step 4, `./hello` picked up new behaviour without being relinked. Trace the exact chain of names that made that possible.
- **Q6.2** — In step 5 the old binary still prints `v1.1`. Is that a bug or the designed outcome? What would have happened if the developer had reused SONAME `libgreet.so.1` for the v2 code?
- **Q6.3** — `ldconfig` created `libgreet.so.1` and `libgreet.so.2` but never `libgreet.so`. Why does it refuse to, and what breaks as a result?
- **Q6.4** — You have `libgreet.so.1.0.0` and `libgreet.so.1.1.0` in the same directory, both with SONAME `libgreet.so.1`. Which one does `ldconfig` point the symlink at, and by what rule?
- **Q6.5** — Map this to a real package: `libssl.so.3` vs `libssl.so.1.1`. Why could a distribution ship both simultaneously, and what does that mean for `dpkg`/`rpm` package naming?

---

## Block 7 — Diagnosing failures: the four canonical errors

### Steps

1. **Error A — missing library.** Hide the v1 chain and run the old binary:

   ```bash
   sudo mv /usr/local/lib/libgreet.so.1.1.0 /root/
   sudo ldconfig
   ./hello
   ldd ./hello | grep greet
   ```

   Expected output:

   ```
   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   	libgreet.so.1 => not found
   ```

2. **Error B — stale cache.** Restore the file but *do not* rebuild the cache:

   ```bash
   sudo mv /root/libgreet.so.1.1.0 /usr/local/lib/
   ./hello
   ```

   Expected output — still failing, because the SONAME symlink and cache entry are gone:

   ```
   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   ```

   Then:

   ```bash
   sudo ldconfig
   ./hello
   ```

   ```
   hello, LPIC-1 (libgreet v1.1)
   ```

3. **Error C — wrong architecture.** Ask the cache what it knows about the ABI tag:

   ```bash
   ldconfig -p | grep -c 'libc6,x86-64'
   ldconfig -p | grep -c 'libc6)'      # 32-bit entries, if any
   ```

   A 32-bit library in a 64-bit search path produces:

   ```
   ./app: error while loading shared libraries: libfoo.so.1: wrong ELF class: ELFCLASS32
   ```

4. **Error D — undefined symbol.** Force the mismatch that `ldd` alone will not show:

   ```bash
   cd ~/lab-102.3
   gcc main.c -L/usr/local/lib -l:libgreet.so.2 -o hello2
   readelf -d hello2 | grep NEEDED
   ./hello2
   ```

   The v2 library exports `greet(const char *, int)`; `main.c` calls it with one argument. C has no name mangling, so it links and runs — with a garbage second argument. Now make the failure explicit:

   ```bash
   printf 'void nosuchfunc(void);\nint main(void){nosuchfunc();return 0;}\n' > bad.c
   gcc bad.c -L/usr/local/lib -l:libgreet.so.2 -o bad 2>&1 | tail -2
   ```

   Expected output:

   ```
   /usr/bin/ld: /tmp/ccXXXX.o: in function `main':
   bad.c:(.text+0xa): undefined reference to `nosuchfunc'
   ```

   At *runtime*, the equivalent (from a lazily-bound plugin) looks like:

   ```
   symbol lookup error: ./plugin.so: undefined symbol: nosuchfunc
   ```

   `ldd -r` is what catches it before you ship.

5. Force eager binding to surface every missing symbol at start-up rather than at first call:

   ```bash
   LD_BIND_NOW=1 ./hello
   ```

### Check your understanding

- **Q7.1** — In step 2 the file was back on disk in the right directory, yet the program still failed. Name the two things that were missing and the one command that recreated both.
- **Q7.2** — Distinguish these two messages precisely: `error while loading shared libraries: ... cannot open shared object file` vs. `symbol lookup error: ... undefined symbol`. At which stage does each occur?
- **Q7.3** — What does `wrong ELF class: ELFCLASS32` mean, and what is the fix?
- **Q7.4** — What does the `(libc6,x86-64)` tag in `ldconfig -p` output encode, and why does the cache need it?
- **Q7.5** — Why does `LD_BIND_NOW=1` turn a latent crash-at-hour-3 into a fail-at-start, and when is that the behaviour you want?

---

## Block 8 — Interposition: `LD_PRELOAD` and `/etc/ld.so.preload`

`LD_PRELOAD` loads objects *before* every other dependency, so their symbols win. It is a legitimate debugging tool, a legitimate packaging workaround, and a classic rootkit technique — all with the same mechanism.

### Steps

1. Write an interposing library that replaces `greet`:

   ```bash
   cd ~/lab-102.3
   cat > fake.c <<'EOF'
   #include <stdio.h>

   void greet(const char *who)
   {
           printf("INTERPOSED: %s\n", who);
   }
   EOF
   gcc -fPIC -shared -o libfake.so fake.c
   ```

2. Run the original binary with the preload:

   ```bash
   ./hello
   LD_PRELOAD=$PWD/libfake.so ./hello
   ```

   Expected output:

   ```
   hello, LPIC-1 (libgreet v1.1)
   INTERPOSED: LPIC-1
   ```

3. Confirm the load order:

   ```bash
   LD_PRELOAD=$PWD/libfake.so ldd ./hello
   ```

   Expected output:

   ```
   	linux-vdso.so.1 (0x00007ffe4b3f9000)
   	/home/user/lab-102.3/libfake.so (0x00007f8c2d1f0000)
   	libgreet.so.1 => /usr/local/lib/libgreet.so.1 (0x00007f8c2d1e0000)
   	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f8c2ce00000)
   	/lib64/ld-linux-x86-64.so.2 (0x00007f8c2d201000)
   ```

4. Inspect — **do not create** — the system-wide equivalent:

   ```bash
   ls -l /etc/ld.so.preload 2>&1
   ```

   Expected output on a healthy system:

   ```
   ls: cannot access '/etc/ld.so.preload': No such file or directory
   ```

5. Verify the setuid protection applies here too:

   ```bash
   LD_PRELOAD=$PWD/libfake.so /usr/bin/passwd --help >/dev/null; echo "exit=$?"
   ```

   The preload is silently discarded; `passwd` runs normally.

### Check your understanding

- **Q8.1** — In step 3, `libfake.so` appears *above* `libgreet.so.1` and with no `=>` arrow. Explain both details.
- **Q8.2** — Why is the existence of `/etc/ld.so.preload` on a production host a P1 security finding, and what is the standard triage step?
- **Q8.3** — `LD_PRELOAD` is ignored for setuid binaries, but a library listed in `/etc/ld.so.preload` is **not** (with restrictions). What is the security reasoning behind that asymmetry?
- **Q8.4** — Name one entirely legitimate production use of `LD_PRELOAD`.
- **Q8.5** — Your interposing `greet` never calls the real one. How would you write a *wrapper* that logs and then delegates? Name the glibc function required.

---

## Block 9 — Recovery and cross-distro reality

### Steps

1. Rebuild the cache into an alternate file, leaving the live one untouched:

   ```bash
   sudo ldconfig -C /tmp/test.cache
   ls -lh /tmp/test.cache
   ldconfig -p -C /tmp/test.cache | head -2
   ```

2. Operate on a chroot or container root filesystem from the host — the standard rescue move:

   ```bash
   sudo ldconfig -r /mnt/broken-system
   ```

   This treats `/mnt/broken-system` as `/`, reading its `/etc/ld.so.conf` and writing its `/etc/ld.so.cache`.

3. Confirm the glibc version two independent ways:

   ```bash
   ldd --version | head -1
   getconf GNU_LIBC_VERSION
   /lib/x86_64-linux-gnu/libc.so.6
   ```

   Expected output:

   ```
   ldd (Debian GLIBC 2.36-9+deb12u7) 2.36
   glibc 2.36
   GNU C Library (Debian GLIBC 2.36-9+deb12u7) stable release version 2.36.
   ...
   ```

   > `libc.so.6` is one of the rare shared objects that is also directly executable.

4. Locate a *statically linked* shell now, before you need it:

   ```bash
   file /bin/busybox 2>/dev/null || echo "busybox not installed"
   file /usr/bin/sash 2>/dev/null || echo "sash not installed"
   ```

   If neither exists, install `busybox-static`. A box whose `libc.so.6` symlink is broken cannot run `ls`, `mv`, `ln`, or `ldconfig` — every one of them is dynamically linked.

5. Observe the non-glibc case:

   ```bash
   docker run --rm alpine:3.20 sh -c 'ldconfig -p 2>&1 | head -2; ls /etc/ld-musl-x86_64.path; cat /etc/ld-musl-x86_64.path'
   ```

   Alpine uses **musl**, which has no `/etc/ld.so.cache` and no `/etc/ld.so.conf.d/`; the search path is the single file `/etc/ld-musl-<arch>.path`.

### Check your understanding

- **Q9.1** — `ldconfig -r /mnt/broken-system` vs. `chroot /mnt/broken-system ldconfig`. What can the first do that the second cannot?
- **Q9.2** — A sysadmin runs `mv /lib/x86_64-linux-gnu/libc.so.6 /tmp/` over SSH. The session survives, but every new command fails. Why does the *existing* shell keep working, and how do you recover?
- **Q9.3** — Why is a statically linked shell the mandatory rescue tool for library breakage, and where does the initramfs fit in?
- **Q9.4** — You are debugging a container image built `FROM alpine`. Your notes say "run `ldconfig -p`". Why does that advice fail, and what replaces it?
- **Q9.5** — Which `ldconfig` option would you use to rebuild the cache into a non-default location for testing, without touching `/etc/ld.so.cache`?

---

## Command reference

| Command | Purpose |
|---|---|
| `ldd <file>` | Print shared-object dependencies (transitive). May execute the target — untrusted files: use `readelf`/`objdump`. |
| `ldd -r <file>` | Also resolve data and function relocations; reports undefined symbols. |
| `ldd -v <file>` | Verbose: version-symbol information. |
| `ldd --version` | glibc version. |
| `ldconfig` | Rebuild `/etc/ld.so.cache` and refresh SONAME symlinks. Run after installing any library. |
| `ldconfig -p` | Print the current cache contents. **Query, never rebuild.** |
| `ldconfig -v` | Verbose: show each directory and each symlink created. |
| `ldconfig -n <dir>` | Process only `<dir>`; do **not** rebuild the cache, do **not** scan trusted dirs. |
| `ldconfig -N` | Do not rebuild the cache (symlinks only). |
| `ldconfig -X` | Do not update symlinks (cache only). |
| `ldconfig -f <conf>` | Use `<conf>` instead of `/etc/ld.so.conf`. |
| `ldconfig -C <cache>` | Write to `<cache>` instead of `/etc/ld.so.cache`. |
| `ldconfig -r <root>` | Chroot to `<root>` first — offline/rescue operation. |
| `readelf -d <file>` | Dynamic section: `NEEDED`, `SONAME`, `RPATH`, `RUNPATH`. Never executes. |
| `objdump -p <file>` | Same information, different formatting. |
| `nm -D <lib>` | Dynamic symbol table of a shared object. |
| `file <file>` | `dynamically linked` vs `statically linked`; ELF class and architecture. |

| Path / variable | Role |
|---|---|
| `/etc/ld.so.conf` | Top-level search-path config; almost always just an `include` line. |
| `/etc/ld.so.conf.d/*.conf` | One directory per line; where packages and admins add paths. |
| `/etc/ld.so.cache` | Binary `SONAME → path` index, generated by `ldconfig`. Never edit. |
| `/etc/ld.so.preload` | System-wide preload list. Absent by default; presence is a red flag. |
| `LD_LIBRARY_PATH` | Colon-separated extra search dirs. Per-process, debugging only, ignored for setuid. |
| `LD_PRELOAD` | Objects loaded first; their symbols take precedence. |
| `LD_DEBUG=libs\|symbols\|bindings\|all` | Trace loader behaviour to stderr. |
| `LD_DEBUG_OUTPUT=<prefix>` | Send that trace to `<prefix>.<pid>` instead of stderr. |
| `LD_BIND_NOW=1` | Resolve all symbols at start-up instead of lazily. |
| `/lib`, `/usr/lib`, `/lib64`, `/usr/lib64` | Trusted defaults compiled into `ld.so`. |
| `/usr/local/lib` | FHS location for locally built libraries. |

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1

**A1.1** — The static binary contains a copy of every libc routine it references (`puts`, plus the whole start-up, locale, and malloc machinery pulled in transitively) copied out of `/usr/lib/x86_64-linux-gnu/libc.a` at link time. The dynamic binary contains only *references*: the `NEEDED` entry `libc.so.6` plus PLT/GOT stubs. It runs because the kernel, seeing the `INTERP` program header, loads `/lib64/ld-linux-x86-64.so.2` first; that loader maps `libc.so.6` into the process address space and fixes up the stubs before transferring control to `main`.

**A1.2** — No. It is the correct and expected answer for a static binary: there are no run-time dependencies to list, so there is nothing for `ldd` to report. `ldd` returns a non-zero exit status, but the binary is healthy.

**A1.3** — The **virtual dynamic shared object**. It is injected into every process by the kernel, not read from disk, so it has no file. It exports fast user-space implementations of a few syscalls (`gettimeofday`, `clock_gettime`, `getcpu`) that avoid a kernel-mode transition. `ls -l` fails because the path does not exist in any filesystem.

**A1.4** — A `=>` means "this SONAME was resolved to that path by searching". The loader's own path is not searched for — it is hard-coded as an absolute path in the executable's `INTERP` program header, so `ldd` prints it verbatim with only its load address.

**A1.5** — Static: no runtime dependency on the host's library versions, so the binary is self-contained and immune to "works on my box" library skew — the reason Go binaries and rescue tools are built this way. Dynamic: a security fix in `libc` or `libssl` is applied once, to one file, and every process that restarts picks it up — with static linking you must rebuild and redeploy every consumer. Dynamic also lets many processes share one read-only copy of the library's text pages in physical RAM.

### Block 2

**A2.1** — Two `NEEDED` entries → 2 lines (`libselinux.so.1`, `libc.so.6`). Plus `linux-vdso.so.1` (kernel-injected, not a real dependency). Plus `/lib64/ld-linux-x86-64.so.2` (the interpreter itself). Plus `libpcre2-8.so.0` — a *transitive* dependency, pulled in by `libselinux.so.1`, not by `ls`. Total 5. `readelf` shows direct dependencies; `ldd` shows the whole closure.

**A2.2** — glibc's `ldd` resolves dependencies by invoking the dynamic loader on the target, and in some code paths it executes the binary itself with special environment variables. A crafted ELF file can therefore run arbitrary code as you, simply because you inspected it. Use `readelf -d` or `objdump -p`, which only parse the file.

**A2.3** — The SONAME is the identity string recorded *inside* the `.so` (`DT_SONAME`) and is normally `lib<name>.so.<major>`. The file name on disk is usually the full version, `lib<name>.so.<major>.<minor>.<patch>`. At link time `ld` copies the dependency's **SONAME** — not its file name — into the executable's `DT_NEEDED` entry. That indirection is what allows a minor-version upgrade of the library without relinking anything.

**A2.4** — `@@` marks the *default* version of a symbol when multiple versioned definitions exist (`@` marks a non-default, compatibility one). `GLIBC_2.2.5` is the symbol-version node. This is glibc's symbol versioning: a single `libc.so.6` can export several ABI-incompatible implementations of the same function name, so binaries built against old glibc keep working while new binaries get the new behaviour — no SONAME bump required.

**A2.5** — `$ORIGIN` is expanded by the loader to the directory containing the object being loaded. Vendors use it to ship relocatable trees (`/opt/vendor/bin/app` finding `/opt/vendor/lib/`) that work regardless of install prefix and without polluting the system search path or requiring `LD_LIBRARY_PATH`.

### Block 3

**A3.1** — It is a binary hash table, designed for the loader to `mmap()` and probe in constant time; parsing text on every `exec()` would be far too slow. Editing it with an editor corrupts the structure; the loader will then fail to find libraries system-wide. The fix is always `ldconfig`, which regenerates it from `/etc/ld.so.conf*` and the trusted directories.

**A3.2** — `-N` suppresses rebuilding the cache; `-X` suppresses updating the symlinks. Together they leave `ldconfig` with nothing to write, so it walks the configured directories and reports what it *would* do — a genuine dry run.

**A3.3** — Left is the **SONAME** (`libpcre2-8.so.0`), right is the **real name** on disk (`libpcre2-8.so.0.11.2`). `ldconfig` created that symlink: it reads `DT_SONAME` out of each `.so` it finds and links the SONAME to the file. The **linker name** (`libpcre2-8.so`, no version) is absent — it comes from the `-dev` package, not from `ldconfig`.

**A3.4** — Because `/lib`, `/usr/lib`, `/lib64` and `/usr/lib64` are *trusted default directories* compiled into `ld.so` and always processed by `ldconfig`. Listing them in `ld.so.conf` would be redundant. Debian lists `/lib/x86_64-linux-gnu` explicitly only because multiarch paths are **not** among the compiled-in defaults.

**A3.5** —
```bash
echo /opt/acme/lib | sudo tee /etc/ld.so.conf.d/acme.conf
sudo ldconfig
```
Verify with `ldconfig -p | grep acme`. Adding a file under `/etc/ld.so.conf.d/` is preferred over editing `/etc/ld.so.conf` because package upgrades may replace the latter.

### Block 4

**A4.1** — `gcc -L. -lgreet` made `ld` open `./libgreet.so`, which is a symlink chain to `libgreet.so.1.0.0`. `ld` read the `DT_SONAME` field out of that file — `libgreet.so.1` — and wrote **that string**, not the path or the file name, into `hello`'s `DT_NEEDED`. The build-time name and the run-time name are deliberately different.

**A4.2** — Shared-library code is mapped at an arbitrary address that differs per process, so every internal reference must be relative to the program counter rather than absolute; `-fPIC` tells the compiler to generate that code and route external data access through the GOT. `main.c` is compiled for an executable — on modern toolchains it is typically PIE by default anyway, but it is not subject to being mapped at an unpredictable base by a *third party*, so the flag is not required from you.

**A4.3** — The current working directory is not in the loader's search order. `.` is not `DT_RPATH`, not in `LD_LIBRARY_PATH`, not in `/etc/ld.so.cache`, and not a trusted default. This is deliberate: if `.` were searched, dropping a malicious `libc.so.6` into a shared directory would hijack every program run from there.

**A4.4** — `-n` restricts `ldconfig` to exactly the directories named on the command line and, crucially, does **not** rebuild `/etc/ld.so.cache` and does not process the trusted default directories. It only created the SONAME symlink `libgreet.so.1 → libgreet.so.1.0.0`. A bare `ldconfig` reads `/etc/ld.so.conf*` plus the trusted dirs, creates symlinks in all of them, and rewrites the cache.

**A4.5** — Without `DT_SONAME`, `ld` falls back to recording the *path it was given* — here `libgreet.so`. `hello` would then depend on the unversioned linker name. That name is owned by the development package and is repointed at every new major version, so the day `libgreet.so` starts pointing at the v2 ABI, your unrecompiled binary silently loads incompatible code and crashes or corrupts memory. The SONAME exists precisely to make that impossible.

### Block 5

**A5.1** — `DT_RPATH` → `LD_LIBRARY_PATH` → `DT_RUNPATH` → `/etc/ld.so.cache` → trusted defaults (`/lib`, `/usr/lib`, `/lib64`, `/usr/lib64`). The conditional: **`DT_RPATH` is honoured only when `DT_RUNPATH` is absent.** If the object has `DT_RUNPATH`, `DT_RPATH` is ignored entirely — which is what makes `RUNPATH` overridable by `LD_LIBRARY_PATH` and `RPATH` not.

**A5.2** — The loader applies the same ordered search to *every* `NEEDED` name. `LD_LIBRARY_PATH` sits ahead of the cache, so the lab directory is probed first for `libc.so.6` too. The `trying file=` line that finds nothing is a miss, and the loader falls through to `search cache=/etc/ld.so.cache`. This is also the cost argument against a long `LD_LIBRARY_PATH`: every entry is a failed `stat()` for every library of every process.

**A5.3** — `passwd` is set-user-ID root. If `LD_LIBRARY_PATH` were honoured, any unprivileged user could point it at a directory containing a hostile `libc.so.6` (or `libcrypt.so.1`) whose constructor runs `execve("/bin/sh")` — instant root. glibc therefore purges `LD_LIBRARY_PATH`, `LD_PRELOAD` (for unprivileged paths), `LD_AUDIT` and friends whenever the process is running with elevated privilege (`AT_SECURE` is set in the auxiliary vector).

**A5.4** — (1) It applies globally to every process on the box, so it can shadow a system library for unrelated software — a `libssl.so.3` in `/opt/app/lib` will be loaded by anything that starts a login shell. (2) It costs a failed lookup per entry per library per process. (3) It is fragile and invisible: it does not apply to services started by systemd (which does not source `/etc/profile`), so the app works interactively and fails as a unit — the worst possible failure signature. The right fix is `/etc/ld.so.conf.d/app.conf` + `ldconfig`, or building the app with `-Wl,-rpath,'$ORIGIN/../lib'` so the dependency is recorded in the binary.

**A5.5** — `/b/libfoo.so.1`. `LD_LIBRARY_PATH` is searched before `/etc/ld.so.cache`, and within `LD_LIBRARY_PATH` the entries are tried left to right — `/a` first (miss), then `/b` (hit). The cache is never consulted.

### Block 6

**A6.1** — `hello`'s `DT_NEEDED` says `libgreet.so.1`. The cache maps that SONAME to `/usr/local/lib/libgreet.so.1`. That path is a symlink, and `ldconfig` repointed it from `libgreet.so.1.0.0` to `libgreet.so.1.1.0` because the new file also declares `DT_SONAME libgreet.so.1`. Four names, one indirection each: NEEDED → cache entry → symlink → real file.

**A6.2** — Designed outcome. `hello` asks for SONAME `libgreet.so.1`, and the v1 chain is still installed and still correct for it. Had the developer reused SONAME `libgreet.so.1` for the v2 code, `ldconfig` would have repointed `libgreet.so.1` at the v2 file, and `hello` would call a two-argument function with one argument on the stack — undefined behaviour, typically a garbage loop count or a segfault, with no error message from the loader.

**A6.3** — `ldconfig` derives its symlinks from `DT_SONAME`, and no library declares an unversioned SONAME. The linker name is a *build-time* artifact with no runtime meaning, so it is out of `ldconfig`'s scope by design — it is created by the `-dev`/`-devel` package (or `make install`). Without it, `gcc -lgreet` fails with `cannot find -lgreet`; runtime is unaffected.

**A6.4** — `libgreet.so.1.1.0`. When several files claim the same SONAME, `ldconfig` picks the one it considers newest by comparing the version suffixes numerically, field by field — `1.1.0` beats `1.0.0`. It is not modification time and not alphabetical order (alphabetically, `1.1.0` < `1.0.0` is false, but `1.10.0` vs `1.9.0` is exactly where a string sort would give the wrong answer and the numeric rule saves you).

**A6.5** — OpenSSL 3.0 broke ABI with 1.1.x, so the SONAME changed from `libssl.so.1.1` to `libssl.so.3`. Because the SONAMEs differ, the two files do not collide and both can be installed at once, letting old binaries keep running during a migration. Distributions encode this in the package name — Debian ships `libssl1.1` and `libssl3` as separate co-installable binary packages, with a single `libssl-dev` providing the (mutually exclusive) linker name. That naming convention — package name carries the SONAME major — exists precisely so `dpkg`/`rpm` can express "these two do not conflict".

### Block 7

**A7.1** — Missing: (1) the SONAME symlink `/usr/local/lib/libgreet.so.1`, removed by the `ldconfig` run in step 1 when its target vanished; (2) the cache entry mapping `libgreet.so.1` to that path. `sudo ldconfig` recreated both in one pass. This is the single most common real-world cause of "I definitely installed the library and it still says not found".

**A7.2** — `cannot open shared object file` is emitted by the **dynamic loader before `main()` runs**: an entire `NEEDED` object could not be located anywhere in the search path. `undefined symbol` means the object *was* found and mapped, but a specific symbol it references does not exist in any loaded object — a version/ABI mismatch, not a missing file. With lazy binding it can surface arbitrarily late, at the moment of first call.

**A7.3** — The loader found a file with the right SONAME but the wrong ELF class: a 32-bit (`ELFCLASS32`) object where a 64-bit process needs `ELFCLASS64`. Usually a 32-bit library landed in a 64-bit path, or `LD_LIBRARY_PATH` points at a 32-bit tree. Fix: install the correct-architecture package (`:i386` / `.i686` for genuinely 32-bit consumers) and keep the trees separate — `/usr/lib32` vs `/usr/lib64`, or Debian's `i386-linux-gnu` vs `x86_64-linux-gnu`.

**A7.4** — The ABI and machine type of that entry: `libc6` means the glibc 2.x ABI, `x86-64` the machine. The cache holds entries for *all* installed architectures at once, so the loader must be able to skip entries it cannot use — otherwise a 32-bit `libfoo.so.1` would satisfy a 64-bit process's lookup and fail at map time.

**A7.5** — By default glibc binds function symbols lazily: the first call to each function goes through the PLT and triggers resolution then. A symbol that is missing from a rarely used code path therefore stays invisible until that path executes — possibly in production, at 03:00. `LD_BIND_NOW=1` (or linking with `-Wl,-z,now`) resolves everything at start-up, converting that into an immediate, obvious start-up failure. You want it for anything where a crash mid-request is worse than a crash at deploy — and it is a hardening prerequisite for full RELRO, since it lets the GOT be made read-only after relocation.

### Block 8

**A8.1** — Preloaded objects are placed at the front of the global symbol lookup scope, ahead of all `NEEDED` dependencies, which is why they can interpose. `ldd` prints them in that scope order. There is no `=>` because you supplied an absolute path — the loader had nothing to search for, exactly as with the `INTERP` line.

**A8.2** — `/etc/ld.so.preload` injects a library into *every* dynamically linked process on the system, including processes started by root. It is the canonical userland-rootkit persistence mechanism: the preloaded object hooks `readdir`, `open`, and `getdents` to hide files and processes from `ls`, `ps`, and `find`. Triage: read the file with a **statically linked** tool (`busybox cat /etc/ld.so.preload`) so the rootkit cannot filter your view, capture the named `.so` for forensics, and treat the host as compromised — do not "clean" it in place.

**A8.3** — `LD_PRELOAD` comes from the *unprivileged caller's environment*, so honouring it for a setuid binary hands the attacker code execution in a privileged process. `/etc/ld.so.preload` is a root-owned file — only root can write it — so its contents are already trusted at the same level as the binaries themselves. (glibc still restricts which libraries a secure-mode process will preload from it: they must be in the trusted directories and, historically, setuid.) The asymmetry is simply about who controls the input.

**A8.4** — Any of: `libeatmydata` (stub out `fsync` to speed up test suites); `fakeroot` (intercept `chown`/`stat` so a non-root user can build packages); `libfaketime` (test date-rollover behaviour); `jemalloc`/`tcmalloc` (swap the allocator without recompiling); `ltrace`-style call tracing; injecting a fixed `gethostbyname` in a test harness; forcing a bug-fixed `libstdc++` symbol into a vendor binary you cannot rebuild.

**A8.5** — Use `dlsym(RTLD_NEXT, "greet")` (with `#define _GNU_SOURCE` and `-ldl` on older glibc) to obtain the *next* definition of `greet` in the lookup scope — i.e. the real one — then call it after logging:

```c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

void greet(const char *who)
{
        static void (*real)(const char *);
        if (!real)
                real = dlsym(RTLD_NEXT, "greet");
        fprintf(stderr, "[trace] greet(\"%s\")\n", who);
        real(who);
}
```

`RTLD_NEXT` is what makes the difference between a wrapper and a replacement.

### Block 9

**A9.1** — `ldconfig -r` does the `chroot()` itself using the **host's** `ldconfig` binary and the host's libraries. `chroot /mnt/... ldconfig` requires the target's `/usr/sbin/ldconfig` **and** every library that binary depends on to be intact inside the chroot — which is precisely what is broken in the scenario where you need it. `-r` also works when the target is a different distribution or a partially unpacked root.

**A9.2** — The already-running shell has `libc.so.6` mapped into its address space; on Linux an inode stays alive while it is mapped or open, and `mv` within the same filesystem only changes a directory entry — the mapping is unaffected. Every *new* `execve()` needs to open the path by name, and that path is gone. Recovery: use shell built-ins (`echo`, `cd`) and a statically linked binary, e.g. `busybox mv /tmp/libc.so.6 /lib/x86_64-linux-gnu/`. If no static tool exists, reboot into the initramfs or rescue media and repair from there. This is also the reason `ldconfig` on Debian installs libraries with `install`/atomic rename rather than delete-then-copy.

**A9.3** — Every ordinary command — `ls`, `cp`, `mv`, `ln`, `ldconfig`, even `/bin/sh` — is dynamically linked against `libc.so.6`. If that file is missing, moved, or its SONAME symlink is broken, none of them can start, so you cannot use the system to repair the system. A statically linked shell (`busybox-static`, `sash`) carries its own libc and runs regardless. The initramfs is the same idea one layer down: a self-contained root with its own `/lib` and a static or fully-provisioned `busybox`, which is why booting to an initramfs rescue prompt works even when the real root's libraries are destroyed.

**A9.4** — Alpine uses **musl**, not glibc. musl's dynamic loader (`/lib/ld-musl-x86_64.so.1`) has no cache file at all; there is nothing for `ldconfig` to build, and Alpine's `ldconfig` is a minimal stub. The search path is the plain-text `/etc/ld-musl-x86_64.path`, one directory per line, read directly at load time. Replace `ldconfig -p` with `cat /etc/ld-musl-x86_64.path`, and replace `ldd` with `ldd` (musl's own, which is the loader invoked as `ld-musl-x86_64.so.1 --list <file>`) or, better, `readelf -d`. Note also that a glibc-built binary will not run on Alpine at all — different loader path in `INTERP`, producing `no such file or directory` on a file that plainly exists.

**A9.5** — `ldconfig -C <file>`, e.g. `sudo ldconfig -C /tmp/test.cache`. Pair it with `ldconfig -p -C /tmp/test.cache` to read it back, and with `-f <conf>` if you also want to test an alternative configuration file without touching `/etc/ld.so.conf`.

</details>

---

## Sources

- LPI — *Exam 101-500 Objectives*, Topic 102.3 "Manage shared libraries": <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `ld.so(8)` — dynamic linker/loader, search order and environment variables: <https://man7.org/linux/man-pages/man8/ld.so.8.html>
- `ldconfig(8)` — configure dynamic linker run-time bindings: <https://man7.org/linux/man-pages/man8/ldconfig.8.html>
- `ldd(1)` — print shared object dependencies, including the security note on execution: <https://man7.org/linux/man-pages/man1/ldd.1.html>
- `dlopen(3)` / `dlsym(3)` — `RTLD_NEXT` and runtime loading: <https://man7.org/linux/man-pages/man3/dlsym.3.html>
- The GNU C Library manual — *Dynamic Linker*: <https://www.gnu.org/software/libc/manual/html_node/Dynamic-Linker.html>
- Filesystem Hierarchy Standard 3.0, §3.8 `/lib`, §4.5 `/usr/lib`, §4.9 `/usr/local`: <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- GNU Libtool manual — *Library interface versions* (SONAME and versioning policy): <https://www.gnu.org/software/libtool/manual/html_node/Versioning.html>
- musl libc — dynamic linking and `/etc/ld-musl-$ARCH.path`: <https://wiki.musl-libc.org/functional-differences-from-glibc.html>