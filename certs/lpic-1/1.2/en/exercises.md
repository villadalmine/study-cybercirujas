# Hands-On Exercises: Linux Installation and Package Management

These exercises will guide you through standard package management tasks on both Debian-based (`dpkg`/`apt`) and RPM-based (`rpm`/`dnf`) systems. We assume you have a lab environment with `root` or `sudo` access.

## Exercise 1: Advanced Package Information and Dependency Trees

In this exercise, we will inspect package dependencies without installing them, which is critical for diagnosing package conflicts on production servers.

### Steps:
1. On a Debian/Ubuntu system, download the `.deb` file for `curl` without installing it:
   ```bash
   $ apt-get download curl
   ```
2. Inspect the metadata of the downloaded `.deb` file (replace `<version>` with the actual filename):
   ```bash
   $ dpkg -I curl_<version>.deb
   ```
3. On an RPM-based system (CentOS/Fedora/RHEL), query the dependencies of the `httpd` package directly from the remote repository without downloading it:
   ```bash
   $ dnf repoquery --requires httpd
   ```

**Questions for Verification:**
- Q1.1: Which `dpkg` flag is used to show the control data (metadata) of an uninstalled `.deb` archive?
- Q1.2: How does `dnf repoquery` differ from `rpm -q` when checking package dependencies?

---

## Exercise 2: Simulating and Troubleshooting Installations

A common SRE task is verifying what a package manager will do *before* applying the changes, especially in highly-available environments.

### Steps:
1. On a Debian-based system, simulate the installation of the `nginx` package to see what dependencies would be installed, but don't actually install them:
   ```bash
   $ apt-get install -s nginx
   ```
2. Deliberately break a package by removing one of its installed files. For example, on a Debian system where `curl` is installed:
   ```bash
   $ sudo rm /usr/bin/curl
   ```
3. Verify that the package is broken using `dpkg`:
   ```bash
   $ dpkg -V curl
   ```
4. Reinstall the broken package to restore the missing binary:
   ```bash
   $ sudo apt-get install --reinstall curl
   ```

**Questions for Verification:**
- Q2.1: Why is the `-s` (or `--dry-run`) flag critical when running package upgrades on a production database server?
- Q2.2: Which command on RPM-based systems verifies the integrity of all installed files for a package?

<details>
<summary>Click here to reveal the answers</summary>

### Answers

- **A1.1**: The `-I` or `--info` flag. It extracts and displays the control information from the `.deb` archive without installing it.
- **A1.2**: `dnf repoquery` interrogates the remote repositories (high-level metadata) and can check dependencies for uninstalled packages. `rpm -q` only queries the local RPM database for packages that are already installed.
- **A2.1**: The `-s` flag allows you to preview which packages will be upgraded, installed, or removed. This prevents accidental removals of critical dependencies (like removing a production database package because a new library conflicts with it).
- **A2.2**: `rpm -V <package_name>` verifies the integrity of an installed package by comparing file sizes, permissions, types, owners, groups, MD5 checksums, and modification times against the RPM database.

</details>