# Hands-On Exercises: Shells and Shell Scripting

These exercises simulate real-world SRE scenarios where strict shell scripting practices are required to prevent data loss or silent failures in production.

## Exercise 1: Enforcing Strict Mode and Error Handling

A junior engineer wrote a script to deploy an application, but they forgot to enforce error checking. Your task is to refactor the script.

### Steps:
1. Create a file named `deploy.sh`.
2. Add the following poorly written script to it:
   ```bash
   #!/bin/bash
   echo "Starting deployment..."
   cd /opt/production_app
   rm -rf cache/*
   echo "Deployment complete."
   ```
3. Run the script from your home directory: `bash deploy.sh`. Notice how it outputs "Deployment complete" even though the directory `/opt/production_app` probably doesn't exist on your system. **This is highly dangerous because the `rm -rf cache/*` command executed in your home directory instead!**
4. Edit the script and add the **Unofficial Bash Strict Mode** (`set -euo pipefail`) right after the shebang (`#!/bin/bash`).
5. Run the script again. Observe how the script now halts immediately when the `cd` command fails, preventing the dangerous `rm` command from executing.

**Questions for Verification:**
- Q1.1: Which specific flag in `set -euo pipefail` caused the script to halt when the `cd` command failed?
- Q1.2: What does the `-u` flag do, and why is it important in scripts that use variables like `rm -rf /var/log/${APP_NAME}/*`?

---

## Exercise 2: Advanced I/O Redirection and Process Substitution

Sometimes you need to process data streams without writing them to disk.

### Steps:
1. Create two text files with slightly different contents:
   ```bash
   $ echo -e "apple\nbanana\ncherry" > list1.txt
   $ echo -e "apple\nblueberry\ncherry" > list2.txt
   ```
2. Imagine these files are actually outputs of a long-running command. Use **process substitution** (`<()`) to compare the sorted output of two `echo` commands directly without creating files:
   ```bash
   $ diff -u <(echo -e "apple\nbanana\ncherry" | sort) <(echo -e "apple\nblueberry\ncherry" | sort)
   ```
3. Now, redirect the standard error (`stderr`) of a failing command to a file, while keeping standard output (`stdout`) on the screen.
   ```bash
   $ ls /root /tmp 2> error.log
   ```
4. Verify that `error.log` contains the permission denied error, while the contents of `/tmp` were printed to your terminal.

**Questions for Verification:**
- Q2.1: How would you redirect BOTH standard output and standard error to the same file (`all_output.log`)?
- Q2.2: Why is process substitution (`<()`) preferred over piping (`|`) when a command requires multiple file arguments (like `diff`)?

<details>
<summary>Click here to reveal the answers</summary>

### Answers

- **A1.1**: The `-e` (errexit) flag causes the shell to exit immediately if any command (like the `cd` command) returns a non-zero exit status (a failure).
- **A1.2**: The `-u` (nounset) flag treats unset variables as an error and exits immediately. If `APP_NAME` was accidentally empty/unset, `rm -rf /var/log/${APP_NAME}/*` would evaluate to `rm -rf /var/log//*`, deleting the entire `/var/log` directory. The `-u` flag prevents this catastrophe.
- **A2.1**: You can append `&> all_output.log` (in bash) or `> all_output.log 2>&1` (POSIX standard) to the end of the command.
- **A2.2**: The pipe (`|`) can only connect the standard output of *one* command to the standard input of *one* other command. Commands like `diff` require *two* distinct file inputs to compare. Process substitution `<()` acts like a temporary file descriptor, allowing you to pass the output of multiple commands as if they were files.

</details>