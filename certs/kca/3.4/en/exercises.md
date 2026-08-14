# Exercises — 3.4 Installing Kyverno CLI

> **Scope.** These guided exercises cover *installing* and *validating* the Kyverno CLI (`kyverno` / `kubectl-kyverno`) across the four supported channels — Krew, direct release binary, Homebrew, and the container image — plus version compatibility and CLI self-inspection. The CLI is the tool you use to test, apply, and lint policies **outside a cluster** (local dev, CI/CD gates), so getting its installation and versioning right is foundational for every later topic.
>
> Official references used throughout:
> - Kyverno CLI install guide — https://kyverno.io/docs/kyverno-cli/install/
> - Kyverno CLI usage — https://kyverno.io/docs/kyverno-cli/usage/
> - GitHub releases (binaries + checksums) — https://github.com/kyverno/kyverno/releases
> - Krew plugin manager — https://krew.sigs.k8s.io/
> - Kyverno CLI container image — https://github.com/kyverno/kyverno/pkgs/container/kyverno-cli

---

## Exercise 1 — Install via Krew (the recommended path)

Krew is the official `kubectl` plugin manager. Installing the Kyverno CLI through Krew registers it as the `kubectl kyverno` subcommand, so it inherits your kubeconfig and shell completion automatically.

1. Confirm `kubectl` is on your `PATH` and record its version:

   ```bash
   kubectl version --client -o yaml | grep gitVersion
   ```

   Expected (values vary):

   ```yaml
     gitVersion: v1.30.2
   ```

2. Confirm Krew itself is installed (it is a prerequisite, **not** bundled with `kubectl`):

   ```bash
   kubectl krew version
   ```

   Expected:

   ```
   OPTION            VALUE
   GitTag            v0.4.4
   GitCommit         343e657
   IndexURI          https://github.com/kubernetes-sigs/krew-index.git
   BasePath          /home/student/.krew
   IndexPath         /home/student/.krew/index/default
   InstallPath       /home/student/.krew/store
   BinPath           /home/student/.krew/bin
   DetectedPlatform  linux/amd64
   ```

   If this errors with `unknown command "krew"`, install Krew first following https://krew.sigs.k8s.io/docs/user-guide/setup/install/ and ensure `${KREW_ROOT:-$HOME/.krew}/bin` is prepended to your `PATH`.

3. Update the plugin index and install the Kyverno plugin:

   ```bash
   kubectl krew update
   kubectl krew install kyverno
   ```

   Expected tail of output:

   ```
   Installing plugin: kyverno
   Installed plugin: kyverno
   \
    | Use this plugin:
    | 	kubectl kyverno
    | Documentation:
    | 	https://github.com/kyverno/kyverno
   /
   WARNING: You installed plugin "kyverno" from the krew-index plugin repository.
      These plugins are not audited for security by the Krew maintainers.
   ```

4. Invoke the freshly installed plugin:

   ```bash
   kubectl kyverno version
   ```

   Expected:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   ```

> **Questions**
> 1. After a Krew install, why is the command `kubectl kyverno` rather than `kyverno`? What naming convention makes this work?
> 2. `kubectl krew version` failed on a colleague's laptop even though `kubectl` works fine. What is the most likely cause, and what single fact does this reveal about Krew's relationship to `kubectl`?
> 3. The install printed a security `WARNING`. In one sentence, what is it actually telling you, and does it block the install?

---

## Exercise 2 — Install from a release binary with checksum verification

Krew is convenient, but CI runners and air-gapped environments often need a pinned, verifiable binary. Here you install a specific version straight from the GitHub release and **prove its integrity** before trusting it.

1. Choose an explicit version and detect your platform. Pin the version — never rely on "latest" in a pipeline:

   ```bash
   KV_VER="v1.13.4"
   OS=$(uname | tr '[:upper:]' '[:lower:]')          # linux | darwin
   ARCH=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/')   # x86_64 | arm64
   echo "$OS/$ARCH"
   ```

   Expected:

   ```
   linux/x86_64
   ```

2. Download the archive **and** the checksums file for that release:

   ```bash
   BASE="https://github.com/kyverno/kyverno/releases/download/${KV_VER}"
   curl -sSLO "${BASE}/kyverno-cli_${KV_VER}_${OS}_${ARCH}.tar.gz"
   curl -sSLO "${BASE}/checksums.txt"
   ls -1
   ```

   Expected:

   ```
   checksums.txt
   kyverno-cli_v1.13.4_linux_x86_64.tar.gz
   ```

3. Verify the archive's SHA-256 against the published checksum **before** extracting anything:

   ```bash
   sha256sum --ignore-missing -c checksums.txt
   ```

   Expected:

   ```
   kyverno-cli_v1.13.4_linux_x86_64.tar.gz: OK
   ```

   If this prints `FAILED`, **stop** — do not extract or run the binary.

4. Extract and install onto your `PATH`:

   ```bash
   tar -xvf "kyverno-cli_${KV_VER}_${OS}_${ARCH}.tar.gz"
   sudo install -m 0755 kyverno /usr/local/bin/kyverno
   ```

   Expected:

   ```
   LICENSE
   kyverno
   ```

5. Confirm the binary runs and reports the version you pinned:

   ```bash
   kyverno version
   ```

   Expected:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   ```

> **Questions**
> 1. Step 3 uses `sha256sum -c` **before** step 4 extracts the archive. Why is the ordering security-relevant — what class of attack does checking *before* extracting defend against that checking *after* would not?
> 2. What does the `--ignore-missing` flag accomplish given that `checksums.txt` lists assets for every OS/arch of the release?
> 3. When installed this way the binary is named `kyverno`, but the Krew install in Exercise 1 gave you `kubectl kyverno`. Are these the same executable content-wise? What is the only meaningful difference from the shell's perspective?

---

## Exercise 3 — Install via Homebrew

On macOS and Linux, Homebrew gives you a package-managed install with automatic upgrades.

1. Confirm Homebrew is present:

   ```bash
   brew --version
   ```

   Expected:

   ```
   Homebrew 4.3.9
   ```

2. Install the Kyverno CLI formula:

   ```bash
   brew install kyverno
   ```

   Expected tail:

   ```
   ==> Fetching kyverno
   ==> Pouring kyverno--1.13.4.arm64_sonoma.bottle.tar.gz
   🍺  /opt/homebrew/Cellar/kyverno/1.13.4: 6 files, 61.2MB
   ```

3. Verify and note where Homebrew placed the binary:

   ```bash
   kyverno version
   which kyverno
   ```

   Expected:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   /opt/homebrew/bin/kyverno
   ```

4. Later, upgrade to a newer release without touching your `PATH`:

   ```bash
   brew upgrade kyverno
   ```

> **Questions**
> 1. You have `kyverno` from Homebrew in `/opt/homebrew/bin` *and* a manually installed one in `/usr/local/bin` (from Exercise 2). Which one runs when you type `kyverno`, and what determines that?
> 2. Give one operational reason you might still prefer the pinned-binary method of Exercise 2 over `brew install` inside a CI pipeline.

---

## Exercise 4 — Run the CLI as a container image (no local install)

For ephemeral CI jobs you often want zero footprint on the runner. The CLI ships as an OCI image, so you can run it disposably.

1. Pull and run a pinned image tag, asking for the version:

   ```bash
   docker run --rm ghcr.io/kyverno/kyverno-cli:v1.13.4 version
   ```

   Expected:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   ```

2. To operate on local files (e.g. linting a policy), mount your working directory into the container. The image's entrypoint is the `kyverno` binary, so you pass subcommands directly:

   ```bash
   docker run --rm -v "$(pwd):/work" -w /work \
     ghcr.io/kyverno/kyverno-cli:v1.13.4 \
     apply require-labels.yaml --resource deploy.yaml
   ```

   Expected (shape of output — details depend on your files):

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   pass: 1, fail: 0, warn: 0, error: 0, skip: 0
   ```

> **Questions**
> 1. In step 2, why is the `-v "$(pwd):/work" -w /work` bind mount mandatory? What would `kyverno apply require-labels.yaml ...` see inside the container without it?
> 2. The image tag is `:v1.13.4`, not `:latest`. State the reproducibility argument for pinning the tag in a CI job.
> 3. The container's entrypoint is already `kyverno`, so you wrote `... kyverno-cli:v1.13.4 version` (no `kyverno` before `version`). What would happen if you *did* write `... kyverno-cli:v1.13.4 kyverno version`?

---

## Exercise 5 — Validate the install and match versions to the cluster

Installing the binary is only half the job; a KCA-level operator confirms the CLI's capabilities and its **compatibility** with the Kyverno controller running in the cluster.

1. Enumerate the top-level subcommands the CLI exposes:

   ```bash
   kyverno --help
   ```

   Expected (abridged — the command set is the point):

   ```
   Kubernetes Native Policy Management.

   Usage:
     kyverno [command]

   Available Commands:
     apply       Applies policies on resources.
     create      Provides a command-line interface to help with the creation of various Kyverno resources.
     docs        Generates reference documentation.
     fix         Provides a command-line interface to help with Kyverno resources.
     jp          Provides a command-line interface to JMESPath, enhanced with Kyverno specific custom functions.
     migrate     Migrates Kyverno resources from v1 to v2.
     oci         Pulls/pushes images that include policie(s) from/to an OCI registry.
     test        Run tests from a local filesystem.
     version     Shows current version of kyverno.

   Flags:
     -h, --help   help for kyverno
   ```

2. Record the CLI version in a way a script could parse:

   ```bash
   kyverno version | awk '/^Version:/ {print $2}'
   ```

   Expected:

   ```
   1.13.4
   ```

3. Compare it against the Kyverno controller deployed in your cluster (the CLI version should be **compatible with**, and typically match the minor of, the in-cluster release):

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   echo
   ```

   Expected:

   ```
   ghcr.io/kyverno/kyverno:v1.13.4
   ```

4. Sanity-check that a policy the CLI accepts locally is one the cluster's version also understands, by comparing the two minor versions:

   ```bash
   CLI_MINOR=$(kyverno version | awk '/^Version:/ {print $2}' | cut -d. -f1,2)
   CLUSTER_MINOR=$(kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}' \
     | sed 's/.*:v//' | cut -d. -f1,2)
   echo "CLI: ${CLI_MINOR}  Cluster: ${CLUSTER_MINOR}"
   [ "$CLI_MINOR" = "$CLUSTER_MINOR" ] && echo "MATCH" || echo "MISMATCH — review policy API compatibility"
   ```

   Expected:

   ```
   CLI: 1.13  Cluster: 1.13
   MATCH
   ```

> **Questions**
> 1. Which single subcommand from step 1 would you use in a CI gate to run a suite of policy assertions from a local directory *without any cluster*? Which one applies policies to resources and reports pass/fail?
> 2. Why does the KCA guidance emphasize matching the CLI's **minor** version to the in-cluster controller? Give a concrete failure that a mismatch can cause when writing policies.
> 3. In step 3 you read the image from the `kyverno-admission-controller` Deployment. Name one reason reading the *running image tag* is more trustworthy than assuming the version from a Helm `values.yaml` or the chart version.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
1. **Krew installs the plugin as a binary named `kubectl-kyverno`.** `kubectl` discovers any executable on `PATH` whose name starts with `kubectl-` and exposes the suffix as a subcommand (`kubectl-kyverno` → `kubectl kyverno`). This is the standard `kubectl` plugin mechanism, so the CLI automatically inherits your current kubeconfig/context.
2. Krew is **not part of `kubectl`** — it is a separately installed `kubectl` plugin (itself named `kubectl-krew`). `kubectl` working proves nothing about Krew. The colleague either never installed Krew or its `bin` directory (`$HOME/.krew/bin`) is not on `PATH`. The reveal: Krew is a *dependency you install first*, not a bundled feature.
3. The warning states that plugins in the krew-index are **community-contributed and not security-audited by the Krew maintainers** — you are trusting the plugin's publisher (here, the Kyverno project). It is informational and **does not block** the install; the plugin is installed regardless.

### Exercise 2
1. Verifying the checksum **before extraction** ensures you never unpack a tampered/corrupted archive. `tar -x` on a malicious archive can be dangerous in itself (path-traversal entries writing outside the target dir, symlink tricks) — and you certainly must not execute a binary you haven't authenticated. Checking *after* extraction means the untrusted archive has already been processed. Verify-then-extract keeps the untrusted bytes inert until proven intact.
2. `checksums.txt` contains one line per release asset (every OS/arch). `--ignore-missing` tells `sha256sum -c` to verify **only the files present in the current directory** and skip the many listed files you didn't download, instead of reporting them all as `FAILED`/missing. You still get an authoritative `OK`/`FAILED` for the one archive you have.
3. Byte-for-byte it is the **same compiled Kyverno CLI**. The only difference is invocation and discovery: named `kyverno` on `PATH` it is a standalone command; named `kubectl-kyverno` (as Krew installs it) `kubectl` surfaces it as the `kubectl kyverno` subcommand. Same functionality, different entry point.

### Exercise 3
1. Whichever directory appears **first in `PATH`** wins. If `/opt/homebrew/bin` precedes `/usr/local/bin`, the Homebrew build runs; otherwise the manual one does. Resolve ambiguity with `which -a kyverno` (lists all matches in order) and reorder `PATH` or remove the duplicate you don't want.
2. CI wants **deterministic, pinned, verifiable** artifacts. `brew install` resolves to the current formula version (which can move), depends on Homebrew being present on the runner, and adds package-manager overhead. The Exercise 2 method pins an exact release, verifies its SHA-256, and drops a single self-contained binary — reproducible and auditable across every pipeline run.

### Exercise 4
1. The bind mount makes your host files visible inside the container. Without `-v "$(pwd):/work" -w /work`, the container's filesystem does **not** contain `require-labels.yaml` or `deploy.yaml`, so `kyverno apply` would fail with a "file not found"/no-such-path error — the container starts from the image's filesystem, which knows nothing about your host working directory.
2. Pinning `:v1.13.4` guarantees every pipeline run executes the **exact same CLI build**, so a policy that passes today passes tomorrow for the same reason. `:latest` can silently change between runs, turning an unrelated CLI upgrade into a spurious pipeline pass/fail — a reproducibility and debuggability hazard.
3. The image's entrypoint is already the `kyverno` binary, so the arguments you pass are appended to it. Writing `... kyverno version` would run `kyverno kyverno version`, and `kyverno` is not a valid subcommand — the CLI would error with something like `unknown command "kyverno" for "kyverno"`. You pass only the subcommand (`version`, `apply`, `test`, …).

### Exercise 5
1. **`kyverno test`** runs a suite of declarative test assertions from a local filesystem with no cluster — ideal as a CI gate. **`kyverno apply`** applies policies to given resources and reports the `pass/fail/warn/error/skip` tally.
2. Kyverno's policy CRDs and JMESPath/custom-function surface **evolve across minor releases** — new fields, new rule types, changed defaults/validation. If the CLI is a *newer* minor than the cluster, `kyverno apply`/`test` may accept a policy locally that the older in-cluster controller rejects or silently ignores; if *older*, the CLI may fail to parse a policy the cluster runs fine. Concrete example: authoring a policy that uses a field or function introduced in v1.13 with a v1.11 CLI (or vice-versa) yields local "pass" but a cluster-side admission failure — false confidence. Matching the minor version keeps local validation faithful to cluster behavior.
3. The **running image tag is the ground truth** of what is actually admitting requests. A Helm `values.yaml` or chart version can be stale, overridden at deploy time (`--set image.tag=…`), or drift from what was truly rolled out (manual patches, rollbacks, image digests pinned elsewhere). Reading `.spec.template.spec.containers[0].image` on the live Deployment reflects the deployed reality, not the intended config.

</details>