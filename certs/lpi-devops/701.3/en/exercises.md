# 701.3 Source Code Management — Guided Exercises

**Exam:** LPI DevOps Tools Engineer, 701-100, version 2.0.0
**Topic weight:** 10
**Objective reference:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

These exercises are hands-on. Every step is meant to be executed in a real shell; the expected output is shown so you can tell "worked" from "looked like it worked". Object hashes on your machine **will differ** from the ones printed here — a commit hash includes the author, the committer and both timestamps, so no two people produce the same commit ID from the same file. Blob hashes, however, are content-only and *will* match exactly.

**Environment required**

- A Linux host with `git` ≥ 2.34 (`gpg.format=ssh` and `git switch`/`git restore` as stable commands) and OpenSSH ≥ 8.2.
- No network access is needed for any exercise. Exercise 7 builds its own "server" as a bare repository on the local filesystem; Exercise 9 explains the one command that would reach a real forge and how to read its output.

---

## Exercise 0 — Build an isolated sandbox

You are about to change global Git configuration on purpose. Do not do that to your real account. Git 2.32+ honours `GIT_CONFIG_GLOBAL`, which lets you redirect `~/.gitconfig` to a throwaway file for the whole session.

### Steps

1. Create the sandbox and pin an isolated global config:

```bash
mkdir -p /tmp/lpi-701.3 && cd /tmp/lpi-701.3
export GIT_CONFIG_GLOBAL=/tmp/lpi-701.3/gitconfig
export GIT_CONFIG_SYSTEM=/dev/null
touch "$GIT_CONFIG_GLOBAL"
git --version
```

```
git version 2.47.1
```

2. Set the identity and the defaults every production repository should have:

```bash
git config --global user.name  "Ada Lovelace"
git config --global user.email "ada@example.com"
git config --global init.defaultBranch main
git config --global core.editor "vi"
git config --global pull.ff only
git config --global merge.conflictstyle zdiff3
git config --global rerere.enabled true
```

3. Inspect where each setting actually comes from:

```bash
git config --list --show-origin --show-scope | head -n 12
```

```
global	file:/tmp/lpi-701.3/gitconfig	user.name=Ada Lovelace
global	file:/tmp/lpi-701.3/gitconfig	user.email=ada@example.com
global	file:/tmp/lpi-701.3/gitconfig	init.defaultbranch=main
global	file:/tmp/lpi-701.3/gitconfig	core.editor=vi
global	file:/tmp/lpi-701.3/gitconfig	pull.ff=only
global	file:/tmp/lpi-701.3/gitconfig	merge.conflictstyle=zdiff3
global	file:/tmp/lpi-701.3/gitconfig	rerere.enabled=true
```

4. Look at the file Git just wrote:

```bash
cat "$GIT_CONFIG_GLOBAL"
```

```ini
[user]
	name = Ada Lovelace
	email = ada@example.com
[init]
	defaultBranch = main
[core]
	editor = vi
[pull]
	ff = only
[merge]
	conflictstyle = zdiff3
[rerere]
	enabled = true
```

### Verification questions

- **Q0.1** Git reads configuration from four scopes. Name them in the order they are applied, and say which one wins when the same key is set in several.
- **Q0.2** `init.defaultbranch` is printed lowercase even though you typed `init.defaultBranch`. Which part of a config key is case-sensitive and which is not?
- **Q0.3** What failure does `pull.ff = only` convert from a silent event into a loud one?
- **Q0.4** A repository must be committed under a work identity while the machine's global identity is personal. Which single command sets that, and which file does it write?

---

## Exercise 1 — The object database: what a repository *is*

Git is a content-addressable object store with a version-control UI on top. Everything in this exercise uses plumbing commands, because the porcelain hides exactly the part the exam asks about.

### Steps

1. Create the repository and look at the skeleton Git lays down:

```bash
cd /tmp/lpi-701.3
git init app
cd app
find .git -maxdepth 1 | sort
```

```
.git
.git/HEAD
.git/config
.git/description
.git/hooks
.git/info
.git/objects
.git/refs
```

2. Read `HEAD` before any commit exists:

```bash
cat .git/HEAD
ls .git/refs/heads
git status --short --branch
```

```
ref: refs/heads/main
## No commits yet on main
```

Note that `.git/refs/heads` is **empty**. `HEAD` points at a branch that does not exist yet — that is what "unborn branch" means.

3. Hash content without touching the repository, then with:

```bash
echo "hello world" | git hash-object --stdin
echo "hello world" | git hash-object --stdin -w
git count-objects -v
```

```
3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
count: 1
size: 4
in-pack: 0
packs: 0
size-pack: 0
prune-packable: 0
garbage: 0
size-garbage: 0
```

This hash is identical on every machine on earth. It is `sha1("blob 12\0hello world\n")`.

4. Find the loose object on disk and read it back:

```bash
find .git/objects -type f
git cat-file -t 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
git cat-file -s 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
git cat-file -p 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
```

```
.git/objects/3b/18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
blob
12
hello world
```

5. Build a real commit and walk the graph downwards from it:

```bash
mkdir -p src
echo "hello world" > src/greet.txt
git add src/greet.txt
git commit -m "feat: add greeting"
git cat-file -p HEAD
```

```
tree 9f6b2c1a4e0d5f3b8a7c6e2d1f0a9b8c7d6e5f4a
author Ada Lovelace <ada@example.com> 1789700000 +0000
committer Ada Lovelace <ada@example.com> 1789700000 +0000

feat: add greeting
```

6. Descend through the trees to the blob you created in step 3:

```bash
git cat-file -p HEAD^{tree}
git cat-file -p HEAD:src
git cat-file -p HEAD:src/greet.txt
```

```
040000 tree 2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f	src
100644 blob 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7	greet.txt
hello world
```

7. Confirm what a branch really is, and count the objects the commit produced:

```bash
cat .git/refs/heads/main
git rev-parse HEAD
git count-objects -v | head -n 2
```

```
7a1f0c9d2b3e4f5a6b7c8d9e0f1a2b3c4d5e6f70
7a1f0c9d2b3e4f5a6b7c8d9e0f1a2b3c4d5e6f70
count: 4
size: 16
```

### Verification questions

- **Q1.1** Name the four Git object types and state, for each, what it stores.
- **Q1.2** In step 6 the blob `3b18e5…` appears with the name `greet.txt`, yet in step 3 you created it from stdin with no filename at all, and the hash is the same. Where is the filename stored, and what practical consequence does that have for a repository containing the same 10 MB file under five different paths?
- **Q1.3** After one commit of one file, `count: 4`. Which four objects are they?
- **Q1.4** `.git/refs/heads/main` contains 40 hex characters and nothing else. Explain in one sentence why "creating a branch in Git is cheap" is a statement about this file.
- **Q1.5** `git cat-file -p HEAD` prints a commit that contains no `parent` line. What does that tell you about this commit, and how many `parent` lines would a merge commit of two branches have?
- **Q1.6** What is the difference between `git hash-object --stdin` and `git hash-object --stdin -w`, and why does the exam care?

---

## Exercise 2 — The three trees: working tree, index, HEAD

Almost every confusing Git message is a statement about the *difference between two of these three*. This exercise makes each difference visible.

### Steps

1. Modify the tracked file and add an untracked one:

```bash
cd /tmp/lpi-701.3/app
printf 'hello world\ngoodbye world\n' > src/greet.txt
echo "*.log" > notes.tmp
git status --short --branch
```

```
## main
 M src/greet.txt
?? notes.tmp
```

Read the two status columns: the **left** column is `HEAD → index`, the **right** column is `index → working tree`. The space then `M` means "staged: nothing, unstaged: modified".

2. Stage it and watch the columns swap:

```bash
git add src/greet.txt
git status --short
```

```
M  src/greet.txt
?? notes.tmp
```

3. Modify it again *after* staging — now all three trees disagree:

```bash
echo "third line" >> src/greet.txt
git status --short
```

```
MM src/greet.txt
?? notes.tmp
```

4. Ask each diff explicitly:

```bash
git diff --stat            # index  -> working tree
git diff --cached --stat   # HEAD   -> index
git diff HEAD --stat       # HEAD   -> working tree
```

```
 src/greet.txt | 1 +
 1 file changed, 1 insertion(+)
 src/greet.txt | 1 +
 1 file changed, 1 insertion(+)
 src/greet.txt | 2 ++
 1 file changed, 2 insertions(+)
```

5. Look at the index as a data structure, not as a concept:

```bash
git ls-files --stage
```

```
100644 5f1c9a0b3d2e4f6a8b7c9d0e1f2a3b4c5d6e7f80 0	src/greet.txt
```

Stage number `0` means "not conflicted". You will see stages 1, 2 and 3 in Exercise 4.

6. Stage selectively with hunk-level control — the habit that keeps a commit reviewable:

```bash
git reset                      # unstage everything, keep the working tree
git add --patch src/greet.txt
```

Git shows one hunk at a time and prompts:

```
Stage this hunk [y,n,q,a,d,s,e,?]?
```

Answer `s` to split the hunk when it contains unrelated changes, `y` to stage, `n` to skip, `q` to stop.

7. Write real ignore rules, including a negation, and prove which rule matched:

```bash
cat > .gitignore <<'EOF'
# build artefacts
*.log
*.tmp
/dist/
!important.tmp
EOF
touch important.tmp debug.log
mkdir dist && touch dist/app.bin
git status --short --ignored
git check-ignore -v debug.log important.tmp dist/app.bin
```

```
 M src/greet.txt
?? .gitignore
?? important.tmp
!! debug.log
!! dist/
.gitignore:2:*.log	debug.log
.gitignore:5:!important.tmp	important.tmp
.gitignore:4:/dist/	dist/app.bin
```

8. Prove the limit of `.gitignore` — it only governs **untracked** files:

```bash
git add -f notes.tmp && git commit -q -m "chore: add notes.tmp by mistake"
echo "still tracked" >> notes.tmp
git status --short
```

```
 M notes.tmp
```

9. Untrack it without deleting it, then move a tracked file:

```bash
git rm --cached notes.tmp
git status --short
git mv src/greet.txt src/greeting.txt
git status --short
```

```
D  notes.tmp
?? notes.tmp
D  notes.tmp
R  src/greet.txt -> src/greeting.txt
```

Compare with `git rm notes.tmp`, which would have removed the file from disk as well.

10. Commit the state and clean the sandbox:

```bash
git add -A
git commit -q -m "chore: add ignore rules, untrack notes.tmp, rename greeting"
git clean -nd
```

```
Would remove dist/
```

`-n` is a dry run. `git clean -fd` deletes; `git clean -fdx` deletes ignored files too, and is the command that removes a `.env` that was never committed.

### Verification questions

- **Q2.1** `MM src/greet.txt` — describe the content of the file in each of the three trees at that moment.
- **Q2.2** You ran `git add file`, then edited the file again, then ran `git commit -m "..."` without `-a`. Which version lands in the commit?
- **Q2.3** A colleague added `secrets.env` to `.gitignore` but `git status` still reports it as modified on every change. Diagnose it, and give the exact command that fixes it while keeping their local copy of the file.
- **Q2.4** `git check-ignore -v` printed `.gitignore:5:!important.tmp`. State the ordering rule that makes a negation work, and explain why `!dist/app.bin` would **not** re-include that file given rule `/dist/`.
- **Q2.5** What does the leading `/` in `/dist/` change compared to writing `dist/`?
- **Q2.6** Git has no "rename" object type, yet `git status` printed `R src/greet.txt -> src/greeting.txt`. How does Git know?
- **Q2.7** Which command discards *staged but uncommitted* changes without touching the working tree, and which discards working-tree changes without touching the index? Give both the `git restore` form and the older `git reset` / `git checkout` form.

---

## Exercise 3 — Reading history like an operator

In an incident you do not read history, you query it.

### Steps

1. Build a history worth querying:

```bash
cd /tmp/lpi-701.3/app
for i in 1 2 3; do
  echo "line $i" >> src/greeting.txt
  git commit -q -am "feat: add line $i"
done
echo 'TIMEOUT = 30' > src/config.py
git add src/config.py && git commit -q -m "feat: introduce TIMEOUT"
sed -i 's/TIMEOUT = 30/TIMEOUT = 5/' src/config.py
git commit -q -am "perf: lower TIMEOUT to 5"
```

2. The one log invocation worth memorising:

```bash
git log --oneline --graph --decorate --all
```

```
* 1d4e7a9 (HEAD -> main) perf: lower TIMEOUT to 5
* 0c3b6f8 feat: introduce TIMEOUT
* 9b2a5e7 feat: add line 3
* 8a1f4d6 feat: add line 2
* 7f0e3c5 feat: add line 1
* 6e9d2b4 chore: add ignore rules, untrack notes.tmp, rename greeting
* 5d8c1a3 chore: add notes.tmp by mistake
* 7a1f0c9 feat: add greeting
```

3. Custom formatting, which is what you pipe into a report:

```bash
git log --pretty=format:'%h %ad %an %s' --date=short -n 3
```

```
1d4e7a9 2026-09-18 Ada Lovelace perf: lower TIMEOUT to 5
0c3b6f8 2026-09-18 Ada Lovelace feat: introduce TIMEOUT
9b2a5e7 2026-09-18 Ada Lovelace feat: add line 3
```

4. The pickaxe — "which commit changed the number of occurrences of this string?":

```bash
git log --oneline -S 'TIMEOUT = 30'
git log --oneline -G 'TIMEOUT'
```

```
0c3b6f8 feat: introduce TIMEOUT
1d4e7a9 perf: lower TIMEOUT to 5
0c3b6f8 feat: introduce TIMEOUT
```

5. Follow a file across its rename, and attribute a single line:

```bash
git log --oneline --follow -- src/greeting.txt
git blame -L 1,2 -- src/greeting.txt
```

```
9b2a5e7 feat: add line 3
8a1f4d6 feat: add line 2
7f0e3c5 feat: add line 1
6e9d2b4 chore: add ignore rules, untrack notes.tmp, rename greeting
7a1f0c9 feat: add greeting
7a1f0c9 (Ada Lovelace 2026-09-18 00:00:00 +0000 1) hello world
6e9d2b4 (Ada Lovelace 2026-09-18 00:00:00 +0000 2) goodbye world
```

6. Ranges and revision syntax — the part that gets misread on the exam:

```bash
git log --oneline 7f0e3c5..9b2a5e7      # exclusive of the left side
git rev-parse --short HEAD~2 HEAD^ 'HEAD@{1}'
git diff --stat HEAD~3 HEAD
```

```
9b2a5e7 feat: add line 3
8a1f4d6 feat: add line 2
9b2a5e7
0c3b6f8
0c3b6f8
 src/config.py   | 1 +
 src/greeting.txt | 1 +
 2 files changed, 2 insertions(+)
```

7. Attribution and volume, for a release note:

```bash
git shortlog -sn --no-merges
git log --oneline --since='1 day ago' --author='Ada' | wc -l
```

```
     8	Ada Lovelace
8
```

### Verification questions

- **Q3.1** Explain the difference between `git log A..B` and `git log A...B`, and between `git diff A..B` and `git diff A...B`.
- **Q3.2** What is the difference between `HEAD^`, `HEAD~`, `HEAD^2` and `HEAD~2`? For which kind of commit does `HEAD^2` even resolve?
- **Q3.3** `-S 'TIMEOUT = 30'` returned one commit; `-G 'TIMEOUT'` returned two. Explain precisely what each option matches.
- **Q3.4** Why does `git log -- src/greeting.txt` stop at `6e9d2b4` while `git log --follow -- src/greeting.txt` continues past it?
- **Q3.5** `HEAD@{1}` and `HEAD~1` resolved to different commits here in general. What are the two different things they name, and which one can reach a commit that is on no branch at all?
- **Q3.6** You know a test passes at `7f0e3c5` and fails at `HEAD`. Write the three-command sequence that makes Git find the first bad commit automatically with a script `./run-test.sh`.

---

## Exercise 4 — Branches, merges and conflict resolution

### Steps

1. Create a branch and see that "create a branch" is a 41-byte write:

```bash
cd /tmp/lpi-701.3/app
git switch -c feature/tls
cat .git/HEAD
cat .git/refs/heads/feature/tls
git branch -vv
```

```
ref: refs/heads/feature/tls
1d4e7a9...
  main          1d4e7a9 perf: lower TIMEOUT to 5
* feature/tls   1d4e7a9 perf: lower TIMEOUT to 5
```

2. Commit on the branch, then merge back with the default policy:

```bash
echo 'TLS_MIN_VERSION = "1.2"' >> src/config.py
git commit -q -am "feat(tls): require TLS 1.2"
git switch main
git merge feature/tls
```

```
Updating 1d4e7a9..4b7c2e1
Fast-forward
 src/config.py | 1 +
 1 file changed, 1 insertion(+)
```

No merge commit was created: `main` had not moved, so Git just advanced the pointer.

3. Redo it with the policy most release workflows actually want:

```bash
git reset --hard 1d4e7a9
git merge --no-ff feature/tls -m "Merge branch 'feature/tls'"
git log --oneline --graph -n 4
git cat-file -p HEAD | head -n 3
```

```
*   e2f5a80 (HEAD -> main) Merge branch 'feature/tls'
|\
| * 4b7c2e1 (feature/tls) feat(tls): require TLS 1.2
|/
* 1d4e7a9 perf: lower TIMEOUT to 5
tree 3a6b9c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b
parent 1d4e7a9c8b7a6f5e4d3c2b1a0f9e8d7c6b5a4f3e
parent 4b7c2e1d0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c
```

Two `parent` lines. That is the entire definition of a merge commit.

4. Now manufacture a genuine conflict:

```bash
git switch -c fix/timeout main
sed -i 's/TIMEOUT = 5/TIMEOUT = 15/' src/config.py
git commit -q -am "fix: raise TIMEOUT to 15 for slow upstreams"

git switch main
sed -i 's/TIMEOUT = 5/TIMEOUT = 2/' src/config.py
git commit -q -am "perf: cut TIMEOUT to 2"

git merge fix/timeout
```

```
Auto-merging src/config.py
CONFLICT (content): Merge conflict in src/config.py
Automatic merge failed; fix conflicts and then commit the result.
```

5. Inspect the conflict as data, not as text:

```bash
git status --short
git diff --name-only --diff-filter=U
git ls-files --stage src/config.py
```

```
UU src/config.py
src/config.py
100644 8c1d0a9b7e6f5d4c3b2a1908f7e6d5c4b3a29180 1	src/config.py
100644 6b0c9f8a7d6e5c4b3a29180f7e6d5c4b3a291807 2	src/config.py
100644 4a9b8e7c6d5f4a3b2019f8e7d6c5b4a39281706f 3	src/config.py
```

Stage 1 is the merge base, stage 2 is **ours** (`main`), stage 3 is **theirs** (`fix/timeout`).

6. Read the conflict markers — with `merge.conflictstyle=zdiff3` from Exercise 0 the base is shown too:

```bash
cat src/config.py
```

```
<<<<<<< HEAD
TIMEOUT = 2
||||||| 1d4e7a9
TIMEOUT = 5
=======
TIMEOUT = 15
>>>>>>> fix/timeout
TLS_MIN_VERSION = "1.2"
```

7. Resolve deliberately, then finish the merge:

```bash
git show :1:src/config.py     # base
git show :2:src/config.py     # ours
git show :3:src/config.py     # theirs
sed -i '1,6c\TIMEOUT = 15' src/config.py
git add src/config.py
git ls-files --stage src/config.py
git commit --no-edit
```

```
100644 4a9b8e7c6d5f4a3b2019f8e7d6c5b4a39281706f 0	src/config.py
[main 5c8d1e2] Merge branch 'fix/timeout'
```

Once staged, the three conflicted stages collapse back to stage `0`. That is what "`git add` marks a conflict resolved" means mechanically.

8. Practise the escape hatch and the bulk shortcuts:

```bash
git switch -c conflict/demo 1d4e7a9
sed -i 's/TIMEOUT = 5/TIMEOUT = 99/' src/config.py
git commit -q -am "chore: demo conflict"
git switch main
git merge conflict/demo
git checkout --ours -- src/config.py   # keep main's version wholesale
git merge --abort
git status --short
```

```
Auto-merging src/config.py
CONFLICT (content): Merge conflict in src/config.py
Automatic merge failed; fix conflicts and then commit the result.
```

(`git status --short` prints nothing: `--abort` restored the pre-merge state, including the working tree.)

9. Clean up merged branches the way a release engineer does:

```bash
git branch --merged main
git branch -d feature/tls fix/timeout
git branch -D conflict/demo
```

```
  feature/tls
  fix/timeout
* main
Deleted branch feature/tls (was 4b7c2e1).
Deleted branch fix/timeout (was 3e9f7b2).
Deleted branch conflict/demo (was 2a8e6c4).
```

### Verification questions

- **Q4.1** Why did step 2 fast-forward while step 3 could be forced to create a merge commit? State the precise condition under which Git fast-forwards.
- **Q4.2** A team requires that every feature arrive as one identifiable merge in `main`. Which merge option enforces that, and which two config keys make it the default for a repository?
- **Q4.3** In a conflicted index, what do stages 1, 2 and 3 hold? During a `git merge`, which branch is "ours"? During a `git rebase`, which branch is "ours" — and why is that the opposite of what most people expect?
- **Q4.4** `git checkout --ours -- file` and `git merge -X ours` sound alike and are not. Explain the difference and when each is correct.
- **Q4.5** You resolved a conflict by editing the file but forgot to run `git add`. What does `git commit` do, and what exactly does `git add` change in the index?
- **Q4.6** `git branch -d` refused to delete a branch; `git branch -D` deleted it. What does `-d` check, and after a `-D` on a branch with unmerged work, is the work gone? How would you recover it?
- **Q4.7** You enabled `rerere.enabled=true` in Exercise 0. What does it do, and why does it matter on a long-lived branch that is rebased daily?

---

## Exercise 5 — Rebase, cherry-pick and rewriting history safely

### Steps

1. Set up a branch that has fallen behind:

```bash
cd /tmp/lpi-701.3/app
git switch -c feature/metrics
echo 'METRICS_PORT = 9090' >> src/config.py
git commit -q -am "feat(metrics): expose port 9090"
echo 'METRICS_PATH = "/metrics"' >> src/config.py
git commit -q -am "feat(metrics): set scrape path"

git switch main
echo 'LOG_LEVEL = "info"' >> src/logging.py
git add src/logging.py && git commit -q -m "feat(log): add log level"
git log --oneline --graph --all -n 5
```

```
* 7d2c9f1 (HEAD -> main) feat(log): add log level
| * 9e4a1b8 (feature/metrics) feat(metrics): set scrape path
| * 6c1f8d3 feat(metrics): expose port 9090
|/
* 5c8d1e2 Merge branch 'fix/timeout'
```

2. Rebase, and record the hashes before and after:

```bash
git switch feature/metrics
git log --oneline -n 2
git rebase main
git log --oneline -n 3
cat .git/ORIG_HEAD
```

```
9e4a1b8 feat(metrics): set scrape path
6c1f8d3 feat(metrics): expose port 9090
Successfully rebased and updated refs/heads/feature/metrics.
b3f7a02 (HEAD -> feature/metrics) feat(metrics): set scrape path
a91c5e4 feat(metrics): expose port 9090
7d2c9f1 (main) feat(log): add log level
9e4a1b8...
```

The commit messages and diffs are identical; **the hashes changed**. Rebase does not move commits, it replays them as new objects.

3. Interactive rebase with autosquash — the workflow for "review asked for a fix in commit 2 of 5":

```bash
echo 'METRICS_PORT = 9091' >> src/config.py
git commit -q --fixup a91c5e4
git log --oneline -n 3
GIT_SEQUENCE_EDITOR=cat git rebase -i --autosquash main
```

```
d0e8b41 (HEAD -> feature/metrics) fixup! feat(metrics): expose port 9090
b3f7a02 feat(metrics): set scrape path
a91c5e4 feat(metrics): expose port 9090
pick a91c5e4 feat(metrics): expose port 9090
fixup d0e8b41 fixup! feat(metrics): expose port 9090
pick b3f7a02 feat(metrics): set scrape path
```

`GIT_SEQUENCE_EDITOR=cat` prints the todo list instead of opening an editor, then the rebase proceeds with that plan. Re-run without it to edit interactively; the verbs are `pick`, `reword`, `edit`, `squash`, `fixup`, `drop`, `exec`.

4. Transplant a range onto a different base with `--onto`:

```bash
git switch -c feature/dash feature/metrics
echo 'DASH_URL = "http://localhost:3000"' >> src/config.py
git commit -q -am "feat(dash): add dashboard URL"
git rebase --onto main feature/metrics feature/dash
git log --oneline --graph --all -n 4
```

```
* 4f6b0d7 (HEAD -> feature/dash) feat(dash): add dashboard URL
* 7d2c9f1 (main) feat(log): add log level
* 5c8d1e2 Merge branch 'fix/timeout'
```

Read it as: *take the commits in `feature/metrics..feature/dash` and replay them on `main`.*

5. Cherry-pick a single fix onto a release branch, with traceability:

```bash
git switch -c release/1.0 5c8d1e2
git cherry-pick -x 7d2c9f1
git log -n 1 --format='%H%n%n%B'
```

```
[release/1.0 8b5d3a6] feat(log): add log level
c1e0a7f4b3d2856907e1f2a3b4c5d6e7f8091a2b

feat(log): add log level

(cherry picked from commit 7d2c9f1e0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d)
```

6. Break history on purpose and recover it with the reflog:

```bash
git switch feature/dash
git reset --hard HEAD~1
git log --oneline -n 1
git reflog -n 4
git reset --hard 'HEAD@{1}'
git log --oneline -n 1
```

```
7d2c9f1 feat(log): add log level
7d2c9f1 HEAD@{0}: reset: moving to HEAD~1
4f6b0d7 HEAD@{1}: rebase (finish): returning to refs/heads/feature/dash
4f6b0d7 HEAD@{2}: rebase (pick): feat(dash): add dashboard URL
7d2c9f1 HEAD@{3}: checkout: moving from feature/metrics to feature/dash
4f6b0d7 (HEAD -> feature/dash) feat(dash): add dashboard URL
```

7. See what the reflog is protecting you from:

```bash
git fsck --unreachable --no-reflogs | head -n 3
```

```
unreachable commit 9e4a1b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f21
unreachable commit 6c1f8d3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e
unreachable commit d0e8b41f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b
```

Those are the pre-rebase commits. They survive until `git gc` prunes them — by default 90 days for reachable-from-reflog objects, 2 weeks for unreachable ones (`gc.reflogExpire`, `gc.pruneExpire`).

### Verification questions

- **Q5.1** State the golden rule of rebasing, and describe concretely what happens to a colleague who had already fetched `feature/metrics` before you rebased it.
- **Q5.2** Merge and rebase both integrate `main` into a feature branch. Give one argument for each that is about *operations*, not aesthetics — for example bisecting, reverting, and reading `git log --graph` six months later.
- **Q5.3** In an interactive rebase todo list, what is the difference between `squash` and `fixup`? And between `reword` and `edit`?
- **Q5.4** `git commit --fixup <sha>` plus `git rebase -i --autosquash` replaced a manual reorder. What does `--fixup` actually write into the commit message, and which config key makes `--autosquash` the default?
- **Q5.5** Decompose `git rebase --onto main feature/metrics feature/dash` into its three arguments and say, in English, which commits get replayed and where they land.
- **Q5.6** Why does `-x` on a cherry-pick matter for a release branch, and why is `cherry-pick` the wrong tool for bringing 40 commits from `main` into `release/1.0`?
- **Q5.7** `git reflog` recovered a commit that `git log` could not show. Explain why, and name the two conditions under which the reflog will *not* save you.

---

## Exercise 6 — Undoing: reset, restore, revert, stash

### Steps

1. Build the reference state:

```bash
cd /tmp/lpi-701.3/app
git switch main
echo 'DEBUG = True' >> src/config.py
git commit -q -am "chore: enable DEBUG (mistake)"
git log --oneline -n 2
```

```
c7a2e91 (HEAD -> main) chore: enable DEBUG (mistake)
7d2c9f1 feat(log): add log level
```

2. Compare the three resets, one at a time, resetting back in between:

```bash
git reset --soft HEAD~1   && git status --short && git reset --hard c7a2e91 -q
git reset --mixed HEAD~1  && git status --short && git reset --hard c7a2e91 -q
git reset --hard HEAD~1   && git status --short
```

```
M  src/config.py
 M src/config.py
```

The third prints nothing: `--hard` discarded the change entirely. Fill in this table from what you just observed:

| Mode | HEAD | Index | Working tree |
|---|---|---|---|
| `--soft` | moves | unchanged | unchanged |
| `--mixed` (default) | moves | reset to HEAD | unchanged |
| `--hard` | moves | reset to HEAD | **reset to HEAD** |

3. Restore the commit and undo it the way you are allowed to on a shared branch:

```bash
git reset --hard c7a2e91 -q
git revert --no-edit HEAD
git log --oneline -n 3
git diff HEAD~2 HEAD
```

```
f3b8c40 (HEAD -> main) Revert "chore: enable DEBUG (mistake)"
c7a2e91 chore: enable DEBUG (mistake)
7d2c9f1 feat(log): add log level
```

`git diff HEAD~2 HEAD` prints nothing — the tree is identical, and both commits remain in history.

4. Revert a *merge*, which needs a parent number:

```bash
git revert -m 1 5c8d1e2 --no-edit
git log --oneline -n 1
```

```
a0d5f27 (HEAD -> main) Revert "Merge branch 'fix/timeout'"
```

Without `-m`, Git refuses: `error: commit 5c8d1e2 is a merge but no -m option was given.`

5. `git restore` — the modern, unambiguous replacement for overloaded `checkout`:

```bash
echo 'OOPS = 1' >> src/config.py
git add src/config.py
echo 'OOPS = 2' >> src/config.py
git restore --staged src/config.py   # index  <- HEAD ; working tree untouched
git status --short
git restore src/config.py            # working <- index
git status --short
```

```
 M src/config.py
```

(The second `git status --short` prints nothing.)

6. Stash, including untracked files, and inspect before applying:

```bash
echo 'WIP = True' >> src/config.py
echo 'scratch' > scratch.txt
git stash push -u -m "wip: config experiment"
git status --short
git stash list
git stash show -p 'stash@{0}' | head -n 8
```

```
stash@{0}: On main: wip: config experiment
diff --git a/src/config.py b/src/config.py
index 4a9b8e7..7c3d1f0 100644
--- a/src/config.py
+++ b/src/config.py
@@ -4,3 +4,4 @@ TLS_MIN_VERSION = "1.2"
 METRICS_PATH = "/metrics"
+WIP = True
```

(The `git status --short` between them prints nothing — the working tree is clean.)

7. Apply versus pop, and the stash's real nature:

```bash
git stash apply 'stash@{0}'
git stash list
git status --short
git stash drop 'stash@{0}'
git cat-file -p 'stash@{0}' 2>&1 | head -n 1
```

```
stash@{0}: On main: wip: config experiment
 M src/config.py
?? scratch.txt
Dropped stash@{0} (b6e1d84...)
fatal: ambiguous argument 'stash@{0}': unknown revision
```

8. Clean up and confirm:

```bash
git checkout -- src/config.py && rm -f scratch.txt
git status --short --branch
```

```
## main
```

### Verification questions

- **Q6.1** You committed to `main` and already pushed. Explain why `git reset --hard HEAD~1` followed by a force-push is the wrong answer, and what `git revert` does instead.
- **Q6.2** You committed to a local branch 30 seconds ago and have not pushed. Which reset mode lets you keep the changes staged so you can immediately recommit with a better message — and what single command would have been simpler still?
- **Q6.3** `git reset --hard` discarded uncommitted work in step 2. Is that recoverable from the reflog? Justify your answer in terms of what the reflog records.
- **Q6.4** Why does reverting a merge commit require `-m 1`, and what does the number refer to? What is the well-known consequence of reverting a merge and later trying to re-merge the same branch?
- **Q6.5** Give the `git restore` equivalent of `git reset HEAD -- file` and of `git checkout -- file`, and say why the new commands are considered safer.
- **Q6.6** `git stash push` without `-u` leaves untracked files in the working tree. Name the failure this causes when you then `git switch` to another branch and run a build.
- **Q6.7** After `git stash drop`, `git cat-file -p 'stash@{0}'` fails. What kind of object was the stash entry, and where was the ref stored?

---

## Exercise 7 — Remotes, refspecs and tags

You will build a "server" locally. A bare repository is exactly what a forge stores — no working tree, just the object database and refs.

### Steps

1. Create the bare repository and clone it:

```bash
cd /tmp/lpi-701.3
git init --bare origin.git
ls origin.git
git clone origin.git work
cd work
```

```
HEAD  config  description  hooks  info  objects  refs
Cloning into 'work'...
warning: You appear to have cloned an empty repository.
```

2. Push the work from the `app` repository into it, then inspect the wiring:

```bash
cd /tmp/lpi-701.3/work
git remote add app /tmp/lpi-701.3/app
git fetch app
git switch -c main app/main
git push -u origin main
git remote -v
git branch -vv
```

```
 * [new branch]      main       -> app/main
branch 'main' set up to track 'origin/main'.
app	/tmp/lpi-701.3/app (fetch)
app	/tmp/lpi-701.3/app (push)
origin	/tmp/lpi-701.3/origin.git (fetch)
origin	/tmp/lpi-701.3/origin.git (push)
* main 3f2a1b9 [origin/main] Revert "Merge branch 'fix/timeout'"
```

3. Read the refspec Git wrote for you:

```bash
git config --get-regexp '^remote\.origin\.'
git config --get branch.main.merge
ls .git/refs/remotes/origin
cat .git/packed-refs 2>/dev/null | head -n 3
```

```
remote.origin.url /tmp/lpi-701.3/origin.git
remote.origin.fetch +refs/heads/*:refs/remotes/origin/*
refs/heads/main
main
```

`+refs/heads/*:refs/remotes/origin/*` reads: *fetch every branch on the remote into my `refs/remotes/origin/` namespace, and allow non-fast-forward updates there (`+`).*

4. Ask the remote what it knows, without touching your refs:

```bash
git ls-remote origin
git remote show origin
```

```
3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a	HEAD
3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a	refs/heads/main
* remote origin
  Fetch URL: /tmp/lpi-701.3/origin.git
  Push  URL: /tmp/lpi-701.3/origin.git
  HEAD branch: main
  Remote branch:
    main tracked
  Local branch configured for 'git pull':
    main merges with remote main
  Local ref configured for 'git push':
    main pushes to main (up to date)
```

5. Simulate a second developer, so the remote moves under you:

```bash
cd /tmp/lpi-701.3
git clone -q origin.git other
cd other
echo 'FEATURE_FLAG = "on"' >> src/config.py
git commit -q -am "feat: add feature flag"
git push -q origin main
```

6. Back in `work`, see the difference between **fetch** and **pull**:

```bash
cd /tmp/lpi-701.3/work
git fetch origin
git status --short --branch
git log --oneline HEAD..@{u}
git rev-list --left-right --count HEAD...@{u}
```

```
 * branch            main       -> FETCH_HEAD
   3f2a1b9..8e7d6c5  main       -> origin/main
## main...origin/main [behind 1]
8e7d6c5 feat: add feature flag
0	1
```

`fetch` updated `origin/main` and changed **nothing** in your working tree. `0 1` means: 0 commits only you have, 1 commit only the remote has.

7. Integrate, with both policies:

```bash
git merge --ff-only origin/main
git log --oneline -n 1
```

```
Updating 3f2a1b9..8e7d6c5
Fast-forward
8e7d6c5 (HEAD -> main, origin/main) feat: add feature flag
```

`git pull` is exactly `git fetch` plus this second step. With `pull.ff=only` from Exercise 0, a divergence stops instead of silently producing a merge commit; `git pull --rebase` replays your local commits on top instead.

8. Produce a real non-fast-forward rejection:

```bash
cd /tmp/lpi-701.3/other
echo 'REGION = "eu-west-1"' >> src/config.py
git commit -q -am "feat: pin region"
git push -q origin main

cd /tmp/lpi-701.3/work
echo 'REGION = "us-east-1"' >> src/config.py
git commit -q -am "feat: pin region differently"
git push origin main
```

```
To /tmp/lpi-701.3/origin.git
 ! [rejected]        main -> main (fetch first)
error: failed to push some refs to '/tmp/lpi-701.3/origin.git'
hint: Updates were rejected because the remote contains work that you do
hint: not have locally. This is usually caused by another repository pushing
hint: to the same ref.
```

9. Resolve it correctly — rebase your commit on top, then push:

```bash
git pull --rebase origin main
# resolve the conflict in src/config.py, keeping one REGION line
git add src/config.py && git rebase --continue
git push origin main
```

10. See why `--force-with-lease` exists:

```bash
git commit -q --amend -m "feat: pin region (amended)"
git push --force-with-lease origin main
```

```
 + 9a1b2c3...d4e5f60 main -> main (forced update)
```

`--force-with-lease` refuses the push if `origin/main` is not at the value you last fetched — i.e. if someone pushed in the meantime. `--force` overwrites their work without asking. On a shared branch, prefer neither.

11. Tags — the two kinds are not interchangeable:

```bash
git tag v0.9.0
git tag -a v1.0.0 -m "Release 1.0.0: TLS 1.2 minimum, metrics endpoint"
git cat-file -t v0.9.0
git cat-file -t v1.0.0
git cat-file -p v1.0.0
```

```
commit
tag
object d4e5f60a1b2c3d4e5f60718293a4b5c6d7e8f901
type commit
tag v1.0.0
tagger Ada Lovelace <ada@example.com> 1789700000 +0000

Release 1.0.0: TLS 1.2 minimum, metrics endpoint
```

The lightweight tag *is* the commit hash. The annotated tag is a **fourth object type** carrying tagger, date, message, and optionally a signature.

12. Publish tags — they are not pushed by default:

```bash
git push origin main
git ls-remote --tags origin
git push --follow-tags origin main
git ls-remote --tags origin
git describe --tags
```

```
d4e5f60...	refs/tags/v1.0.0
d4e5f60...	refs/tags/v1.0.0^{}
v1.0.0
```

`--follow-tags` pushed only the **annotated** tag reachable from what you pushed; `v0.9.0` stayed local. The `^{}` line is the peeled ref: the commit the tag object points to.

13. Downstream, that tag is the release trigger. A pipeline consumes it like this:

```yaml
stages:
  - test
  - release

test:
  stage: test
  script:
    - make test

release:
  stage: release
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v[0-9]+\.[0-9]+\.[0-9]+$/'
  script:
    - 'echo "publishing $CI_COMMIT_TAG"'
    - make publish
```

14. Prune references to branches that no longer exist upstream:

```bash
cd /tmp/lpi-701.3/other
git push origin --delete main 2>/dev/null || true
cd /tmp/lpi-701.3/work
git fetch --prune origin
git branch -r
```

### Verification questions

- **Q7.1** Explain the refspec `+refs/heads/*:refs/remotes/origin/*` term by term: the `+`, the left side, the right side.
- **Q7.2** What exactly does `git fetch` change, and what does it deliberately not change? Give one production scenario where fetching first and integrating later is the difference between an outage and a non-event.
- **Q7.3** `origin/main`, `refs/remotes/origin/main` and `@{u}` — what is the relationship between these three names? Can you commit onto `origin/main`?
- **Q7.4** The push in step 8 was rejected with `(fetch first)`. State the invariant the server is enforcing, and list the three ways to proceed, ordered from safest to most destructive.
- **Q7.5** What does `--force-with-lease` compare, and in what situation does it still allow an overwrite that costs somebody their commits?
- **Q7.6** Name three concrete behaviours that differ between a lightweight tag and an annotated tag (hint: object type, `git describe`, signing, `--follow-tags`).
- **Q7.7** A colleague pushed `v1.0.0`, then moved it to a different commit and force-pushed the tag. Your clone still resolves `v1.0.0` to the old commit after `git fetch`. Why, and which option makes the update happen?
- **Q7.8** A bare repository has no working tree. Why is that a requirement for a push target rather than an optimisation?

---

## Exercise 8 — Submodules

A submodule is a pointer from one repository to *one specific commit* of another. Everything confusing about submodules follows from that one sentence.

### Steps

1. Build a dependency repository and add it as a submodule:

```bash
cd /tmp/lpi-701.3
git init -q --bare libgreet.git
git clone -q libgreet.git libgreet && cd libgreet
echo 'def greet(): return "hi"' > greet.py
git add greet.py && git commit -q -m "feat: initial greet"
git push -q origin main

cd /tmp/lpi-701.3/work
git submodule add ../libgreet.git vendor/libgreet
git status --short
```

```
Cloning into '/tmp/lpi-701.3/work/vendor/libgreet'...
A  .gitmodules
A  vendor/libgreet
```

2. Read what was recorded — this is the crux of the whole topic:

```bash
cat .gitmodules
git ls-files --stage vendor/libgreet
git commit -q -m "chore: vendor libgreet as a submodule"
git cat-file -p HEAD^{tree} | grep libgreet
```

```ini
[submodule "vendor/libgreet"]
	path = vendor/libgreet
	url = ../libgreet.git
```

```
160000 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b 0	vendor/libgreet
160000 commit 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b	vendor/libgreet
```

Mode `160000` is a **gitlink**: a tree entry whose target is a commit in another repository. The superproject stores no files from `libgreet` at all.

3. Confirm the submodule has its own `.git` — and that it is not a directory:

```bash
cat vendor/libgreet/.git
git -C vendor/libgreet status --short --branch
```

```
gitdir: ../../.git/modules/vendor/libgreet
## HEAD (no branch)
```

The submodule checkout is at a **detached HEAD**, because the superproject pins a commit, not a branch.

4. Prove that a plain clone does not get the content:

```bash
cd /tmp/lpi-701.3
git clone -q work fresh
ls fresh/vendor/libgreet
git -C fresh submodule status
```

```
-6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet
```

The directory is empty and the leading `-` means "not initialised". This is the single most common submodule incident: a build that works locally and fails in CI with "file not found".

5. The two ways to get it right:

```bash
git -C fresh submodule update --init --recursive
git -C fresh submodule status
rm -rf fresh
git clone -q --recurse-submodules work fresh2
git -C fresh2 submodule status
```

```
 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet (heads/main)
 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet (heads/main)
```

6. Advance the dependency and update the pointer deliberately:

```bash
cd /tmp/lpi-701.3/libgreet
echo 'def farewell(): return "bye"' >> greet.py
git commit -q -am "feat: add farewell"
git push -q origin main

cd /tmp/lpi-701.3/work
git submodule update --remote vendor/libgreet
git status --short
git diff --submodule=log
```

```
 M vendor/libgreet
Submodule vendor/libgreet 6a2b0c9..b7c3d1e:
  > feat: add farewell
```

7. Commit the *pointer move*, which is a commit in the superproject:

```bash
git add vendor/libgreet
git commit -q -m "chore(deps): bump libgreet to b7c3d1e"
git show --stat HEAD
```

```
 vendor/libgreet | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
```

One line changed: the gitlink.

8. Remove a submodule completely — three places, and people always forget one:

```bash
git submodule deinit -f vendor/libgreet
git rm -f vendor/libgreet
rm -rf .git/modules/vendor/libgreet
git commit -q -m "chore(deps): drop libgreet"
cat .gitmodules 2>/dev/null; echo "exit=$?"
```

```
exit=0
```

`git rm` removed the `.gitmodules` entry and the gitlink; `deinit` cleared `.git/config`; the `rm -rf` cleared the internal clone.

### Verification questions

- **Q8.1** What does file mode `160000` mean in a tree, and what is stored in the superproject for the submodule's file contents?
- **Q8.2** Why is a submodule checkout normally on a detached HEAD? What goes wrong if a developer commits inside the submodule while detached and does not notice?
- **Q8.3** `.gitmodules` is committed, but the submodule URL also appears in `.git/config`. Which one does `git submodule update` use, and which command copies one into the other?
- **Q8.4** CI checks out your repository and the build fails with a missing vendored file. Give the two commands that fix it, and say which one you would put in the pipeline and why.
- **Q8.5** `git submodule update` and `git submodule update --remote` do opposite things. Describe each precisely.
- **Q8.6** After bumping the submodule, `git show --stat` reports one changed line. Explain to a reviewer what that line is and how they should review the change.
- **Q8.7** Name the three locations that must be cleaned to remove a submodule, and the symptom of forgetting `.git/modules/<path>`.

---

## Exercise 9 — SSH key management

Objective 701.3 includes awareness of SSH key management, because every push to a real forge goes through it.

### Steps

1. Create a modern key pair with a comment that identifies the machine:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "ada@laptop-2026-09" -f ~/.ssh/id_ed25519_demo
ls -l ~/.ssh/id_ed25519_demo*
```

```
Generating public/private ed25519 key pair.
Enter passphrase for "/home/ada/.ssh/id_ed25519_demo" (empty for no passphrase):
Your identification has been saved in /home/ada/.ssh/id_ed25519_demo
Your public key has been saved in /home/ada/.ssh/id_ed25519_demo.pub
-rw------- 1 ada ada  464 Sep 18 10:02 /home/ada/.ssh/id_ed25519_demo
-rw-r--r-- 1 ada ada  100 Sep 18 10:02 /home/ada/.ssh/id_ed25519_demo.pub
```

Use a passphrase. Permissions `600` on the private key and `700` on `~/.ssh` are enforced by OpenSSH, not advisory.

2. Inspect both halves:

```bash
cat ~/.ssh/id_ed25519_demo.pub
ssh-keygen -lf ~/.ssh/id_ed25519_demo.pub
head -n 1 ~/.ssh/id_ed25519_demo
```

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4qK0v0h7f2Zt9xQ6r3sN1mJpL8cW5yT2dX0aB3eF4g ada@laptop-2026-09
256 SHA256:9xL2k8Qv7rT0mN4pZ1sD6bY3cW5eR8uI0aF2hJ7gK9M ada@laptop-2026-09 (ED25519)
-----BEGIN OPENSSH PRIVATE KEY-----
```

Only the `.pub` line is uploaded to the forge. The fingerprint is what you compare over a second channel.

3. Start an agent and load the key so the passphrase is typed once:

```bash
eval "$(ssh-agent -s)"
ssh-add -t 8h ~/.ssh/id_ed25519_demo
ssh-add -l
```

```
Agent pid 48213
Enter passphrase for /home/ada/.ssh/id_ed25519_demo:
Identity added: /home/ada/.ssh/id_ed25519_demo (ada@laptop-2026-09)
Lifetime set to 28800 seconds
256 SHA256:9xL2k8Qv7rT0mN4pZ1sD6bY3cW5eR8uI0aF2hJ7gK9M ada@laptop-2026-09 (ED25519)
```

`eval` matters: `ssh-agent -s` only *prints* the `SSH_AUTH_SOCK` and `SSH_AGENT_PID` exports; without `eval` your shell never learns them.

4. Bind the key to a host explicitly, so a multi-account machine stays predictable:

```bash
cat >> ~/.ssh/config <<'EOF'

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_demo
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
chmod 600 ~/.ssh/config
```

`IdentitiesOnly yes` stops SSH from offering every agent key in turn — the cause of `Too many authentication failures` on hosts with `MaxAuthTries 6`.

5. Test authentication (this is the one networked command; skip it offline):

```bash
ssh -T git@github.com
```

```
Hi ada! You've successfully authenticated, but GitHub does not provide shell access.
```

Exit status is `1` and that is success for this host. If it fails, `ssh -vT git@github.com` shows which key was offered and why it was refused.

6. Understand the host-key side of trust:

```bash
ssh-keygen -F github.com
ssh-keygen -lf ~/.ssh/known_hosts | head -n 2
```

Compare the printed fingerprint against the one the provider publishes on its own documentation site **before** accepting it the first time. `ssh-keygen -R github.com` removes a stale entry after a documented host-key rotation — and only then.

7. Switch a repository from HTTPS to SSH:

```bash
cd /tmp/lpi-701.3/work
git remote set-url origin git@github.com:ada/app.git
git remote -v
git remote set-url origin /tmp/lpi-701.3/origin.git   # restore the sandbox
```

8. Use the same key to sign commits — no GPG required, Git ≥ 2.34:

```bash
cd /tmp/lpi-701.3/work
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519_demo.pub
git config commit.gpgsign true
printf '%s %s\n' "ada@example.com" "$(cat ~/.ssh/id_ed25519_demo.pub)" > ~/.ssh/allowed_signers
git config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
echo 'SIGNED = True' >> src/config.py
git commit -q -am "chore: signed commit"
git log --show-signature -n 1 --format='%H %G? %GS'
```

```
e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4 G ada@example.com
```

`%G?` returns `G` (good), `B` (bad), `U` (good, untrusted) or `N` (none).

### Verification questions

- **Q9.1** Which of the two files `ssh-keygen` produced goes on the server, and what is the consequence of uploading the wrong one?
- **Q9.2** Why does `ssh-agent -s` need `eval`? What breaks if you run it without?
- **Q9.3** What problem does a passphrase solve that file permissions do not, and what problem does `ssh-add -t 8h` solve that a passphrase alone does not?
- **Q9.4** Explain `IdentitiesOnly yes`. Describe the failure it prevents on a laptop with six keys loaded in the agent.
- **Q9.5** `ssh -T git@github.com` succeeded but exited `1`. Why is that not a bug, and what does it imply for a shell script that runs it with `set -e`?
- **Q9.6** Distinguish the *host key* from the *user key*: which one lives in `known_hosts`, which attack does each defend against, and what does a sudden `REMOTE HOST IDENTIFICATION HAS CHANGED` warning mean?
- **Q9.7** Agent forwarding (`ssh -A`) is convenient and is generally discouraged for production bastions. State the threat, and name the safer alternative built into OpenSSH.
- **Q9.8** In step 8, a commit was signed without GPG. Which three config keys made that work, and what does `git log --show-signature` report if `allowedSignersFile` is not set?

---

## Exercise 10 — Capstone: enforce the policy on the server

Client-side discipline is a suggestion. The bare repository is where a rule becomes a rule.

### Steps

1. Install a `pre-receive` hook that refuses non-fast-forward updates to `main`:

```bash
cd /tmp/lpi-701.3/origin.git
cat > hooks/pre-receive <<'EOF'
#!/bin/sh
# Reject force-pushes and deletions on protected branches.
protected="refs/heads/main"
zero="0000000000000000000000000000000000000000"

while read -r oldrev newrev refname; do
    [ "$refname" = "$protected" ] || continue

    if [ "$newrev" = "$zero" ]; then
        echo "policy: refusing to delete $refname" >&2
        exit 1
    fi

    if [ "$oldrev" != "$zero" ] && \
       [ "$(git merge-base "$oldrev" "$newrev")" != "$oldrev" ]; then
        echo "policy: non-fast-forward push to $refname rejected" >&2
        exit 1
    fi
done
exit 0
EOF
chmod +x hooks/pre-receive
```

2. Try to violate it:

```bash
cd /tmp/lpi-701.3/work
git commit -q --amend -m "chore: signed commit (amended again)"
git push --force-with-lease origin main
```

```
remote: policy: non-fast-forward push to refs/heads/main rejected
To /tmp/lpi-701.3/origin.git
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to '/tmp/lpi-701.3/origin.git'
```

`--force-with-lease` passed its own check — your `origin/main` was current — and the server still refused. That is the point.

3. Try to delete the branch:

```bash
git push origin --delete main
```

```
remote: policy: refusing to delete refs/heads/main
 ! [remote rejected] main (pre-receive hook declined)
```

4. Add a client-side guard, and note where hooks live when they must be shared:

```bash
cd /tmp/lpi-701.3/work
mkdir -p .githooks
cat > .githooks/pre-commit <<'EOF'
#!/bin/sh
# Block obvious secrets from entering the index.
if git diff --cached -U0 | grep -nE '^\+.*(AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH) PRIVATE KEY)'; then
    echo "pre-commit: possible credential in staged changes" >&2
    exit 1
fi
EOF
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
echo 'AWS_KEY = "AKIAIOSFODNN7EXAMPLE"' >> src/config.py
git commit -am "chore: add key"
```

```
1:+AWS_KEY = "AKIAIOSFODNN7EXAMPLE"
pre-commit: possible credential in staged changes
```

5. Clean up:

```bash
git restore --staged src/config.py && git restore src/config.py
git config --unset core.hooksPath
```

### Verification questions

- **Q10.1** Why can't `.git/hooks/pre-commit` be distributed by committing it, and which config key solves that? What is the hard limit on a client-side hook as a security control?
- **Q10.2** `pre-receive` runs once; `update` runs once per ref. Which one would you use for a policy that must accept some refs of a push and reject others, and what does "atomic push" change about that?
- **Q10.3** In the hook, what does `git merge-base "$oldrev" "$newrev"` returning exactly `$oldrev` prove?
- **Q10.4** What does an all-zeros `newrev` signal, and what does an all-zeros `oldrev` signal?
- **Q10.5** The `pre-commit` hook blocked the commit — but the key had already been staged and the developer can bypass the hook. Name the flag that bypasses it, and state what must happen if a credential reaches a pushed commit (note: `git revert` is **not** sufficient — explain why).

---

<details>
<summary><strong>Answers</strong> — open only after attempting every question</summary>

### Exercise 0

**A0.1** In order of application: **system** (`/etc/gitconfig`, `--system`), **global** (`~/.gitconfig` or `$XDG_CONFIG_HOME/git/config`, `--global`), **local** (`.git/config`, `--local`), and **worktree** (`.git/config.worktree`, `--worktree`, only with `extensions.worktreeConfig`). The **most specific wins** — local overrides global overrides system. Command-line `-c key=value` beats all of them.

**A0.2** The **section** and the **key** are case-insensitive (Git normalises them to lowercase when printing); the **subsection** name — the quoted part, e.g. `remote "Origin"` or `submodule "vendor/libgreet"` — and the **value** are case-sensitive.

**A0.3** A **divergence**. Without it, `git pull` on a branch that has both local and remote commits silently creates a merge commit ("Merge branch 'main' of …"). With `pull.ff=only`, the pull fails and you must choose consciously: `--rebase` or an explicit merge.

**A0.4** `git config --local user.email "ada@corp.example"` run inside the repository; it writes `.git/config`. (`git config --global user.useConfigOnly true` plus per-repo identities makes Git refuse to guess an identity at all, which is the production-grade version.)

### Exercise 1

**A1.1**
- **blob** — file contents, with no name and no permissions.
- **tree** — a directory listing: mode, type, hash and name for each entry.
- **commit** — one tree hash, zero or more parents, author, committer, message.
- **tag** (annotated) — a target object hash, its type, a tag name, tagger and message, optionally a signature.

**A1.2** The filename lives in the **tree**, not the blob. The blob's identity is `sha1("blob <bytesize>\0<content>")`. Consequence: the same 10 MB file at five paths is stored **once** in the object database; five tree entries point at one blob. Git deduplicates content globally and for free.

**A1.3** One blob (`greet.txt`'s content), two trees (the `src` directory and the root tree), one commit. Blob + tree + tree + commit = 4.

**A1.4** A branch is a file containing one 40-character object ID. Creating one writes 41 bytes and copies nothing; deleting one removes 41 bytes. Branching cost is independent of repository size or history length.

**A1.5** No `parent` line means it is the **root commit** — the first commit in the history. A merge of two branches has **two** `parent` lines (an octopus merge of N branches has N).

**A1.6** Without `-w` Git only computes and prints the hash — a pure function, nothing is written. With `-w` it also writes the object into `.git/objects`. It matters because it demonstrates that content addressing is deterministic and independent of the repository: the hash is a property of the bytes, not of the commit you eventually make.

### Exercise 2

**A2.1** HEAD: `hello world\n`. Index: `hello world\ngoodbye world\n` (staged in step 2). Working tree: `hello world\ngoodbye world\nthird line\n`. Left column `M` = HEAD differs from index; right column `M` = index differs from working tree.

**A2.2** The version that was in the index at `git add` time — the **first** edit. `git commit` builds a tree from the index, never from the working tree. `git commit -a` would have staged the tracked changes first and captured both.

**A2.3** `.gitignore` is consulted only for **untracked** paths. `secrets.env` is already tracked, so the ignore rule is inert. Fix: `git rm --cached secrets.env && git commit -m "chore: untrack secrets.env"`. The file stays on disk and is ignored from then on. (It remains in history — see A10.5.)

**A2.4** The **last matching pattern decides**. A negation only works if some earlier pattern matched the file and no later pattern re-excludes it. `!dist/app.bin` fails against `/dist/` because Git does not descend into an excluded **directory** at all, so the file is never tested. To re-include, you must un-exclude the directory first: `/dist/` → `/dist/*` plus `!/dist/app.bin`, or `!/dist/` then `/dist/*`.

**A2.5** A leading `/` anchors the pattern to the directory containing the `.gitignore`. `/dist/` matches only a top-level `dist`; `dist/` matches `dist` at **any** depth, including `src/vendor/dist`.

**A2.6** Git computes renames at read time by **content similarity**, comparing the deleted and added blobs (default threshold 50%, `-M<n>` to tune, `--find-renames`). Nothing about the rename is stored in the commit — a rename is a delete plus an add in the tree.

**A2.7** Staged-only: `git restore --staged <file>` (old: `git reset HEAD -- <file>`). Working-tree-only: `git restore <file>` (old: `git checkout -- <file>`). Both: `git restore --staged --worktree <file>`.

### Exercise 3

**A3.1** For `git log`: `A..B` = commits reachable from B but not from A (the "what's new in B" set); `A...B` = the **symmetric difference**, commits reachable from either but not both (add `--left-right` to label them). For `git diff` the meanings are nearly reversed: `A..B` (and plain `A B`) diffs the two endpoint trees; `A...B` diffs **B against the merge base** of A and B — which is what a pull request shows.

**A3.2** `^` and `~` are the same when there is one parent. `^N` selects the **N-th parent** of a merge commit; `~N` walks **N generations** up the first-parent line. So `HEAD~2` = `HEAD^^`, and `HEAD^2` is the second parent — it resolves only for a **merge commit**.

**A3.3** `-S<string>` matches commits where the **number of occurrences** of the string changed (added or removed) — it finds where a symbol was introduced or deleted. `-G<regex>` matches commits whose **diff text** contains a line matching the regex — including a line that merely moved or was reindented. Hence two hits for `-G 'TIMEOUT'`: both the introduction and the value change touched a line containing it.

**A3.4** Without `--follow`, Git filters history by the path as it exists now, and history for that exact path begins at the rename commit. `--follow` restarts path-limiting at the rename by detecting the similar blob on the other side, continuing under the old name.

**A3.5** `HEAD~1` is a **graph** reference: the first parent of the current commit, computed from the commit objects, identical on every clone. `HEAD@{1}` is a **reflog** reference: where `HEAD` pointed one move ago, local to your repository and absent from a fresh clone. Only the reflog form can name a commit that no branch or tag reaches — which is why it is the recovery tool.

**A3.6**
```
git bisect start HEAD 7f0e3c5
git bisect run ./run-test.sh
git bisect reset
```
(`HEAD` is the known-bad, `7f0e3c5` the known-good. `run` expects exit 0 = good, 1–124 = bad, 125 = skip.)

### Exercise 4

**A4.1** Git fast-forwards when the target commit is a **descendant** of the current one — i.e. `git merge-base --is-ancestor HEAD <target>` holds, so the current commit is already an ancestor and no new content must be combined. In step 2, `main` had not advanced since the branch point. In step 3 `--no-ff` overrides the optimisation and forces a merge commit anyway.

**A4.2** `git merge --no-ff`. Defaults: `git config merge.ff false` (never fast-forward a merge) and `git config pull.ff only` on the consuming side; `git config branch.main.mergeOptions --no-ff` scopes it to one branch. On a forge, the equivalent is the "merge commit" strategy with fast-forward disabled.

**A4.3** Stage 1 = the **merge base** (common ancestor), stage 2 = **ours**, stage 3 = **theirs**. During `git merge`, "ours" is the branch you are on. During `git rebase`, "ours" is the **upstream** you are replaying onto and "theirs" is **your own commit being replayed** — because rebase checks out the upstream and applies your commits on top of it, so from Git's point of view your work is the incoming side.

**A4.4** `git checkout --ours -- file` operates **during a conflict on one file**: it takes stage 2 wholesale for that path, discarding the other side's changes to it. `git merge -X ours` is a merge **strategy option** applied to the whole merge: it resolves every conflicting hunk in favour of the current branch while still merging non-conflicting changes from the other side. (Neither is `git merge -s ours`, which produces a merge commit whose tree is identical to yours, discarding the other branch's content entirely — used to mark a branch as merged.)

**A4.5** `git commit` aborts: `error: Committing is not possible because you have unmerged files.` `git add` replaces the three conflicted stages (1/2/3) for that path with a single **stage 0** entry containing your resolved content — that collapse *is* the resolution record.

**A4.6** `-d` refuses unless the branch is fully merged into its upstream or into the current HEAD, so no work is lost. `-D` skips the check. The work is **not** gone: the commits are unreachable but still in the object database, recoverable via `git reflog` or `git fsck --lost-found` until garbage collection prunes them (default: 30 days for unreachable objects entering a pack, 2 weeks for loose ones).

**A4.7** `rerere` = *reuse recorded resolution*. Git records the conflict hunks and how you resolved them, and replays the resolution automatically the next time the identical conflict appears. On a long-lived branch rebased daily onto a moving `main`, the same conflict recurs every day; rerere turns it into a one-time cost.

### Exercise 5

**A5.1** **Never rebase commits that others have based work on** — in practice, never rebase a branch that has been pushed and that someone else may have fetched. A colleague who fetched the old `feature/metrics` now has commits `6c1f8d3`/`9e4a1b8` while the remote has `a91c5e4`/`b3f7a02`, with identical content and different identities. Their next `git pull` merges the two lineages and every commit appears twice.

**A5.2** *Merge:* preserves the true integration graph, so `git log --first-parent main` reads as one line per feature, reverting a feature is one `git revert -m 1`, and no commit ever changes identity — an already-tested commit stays tested. *Rebase:* produces a linear history, so `git bisect` halves a clean sequence with no merge commits whose builds were never run in that exact combination, `git log` order matches causality, and each commit in review is a complete, independently buildable state.

**A5.3** `squash` keeps the commit's message and opens an editor to combine it with the previous one; `fixup` discards the commit's message entirely and keeps only the previous one's. `reword` changes only the message, without stopping the rebase to let you touch files; `edit` pauses the rebase with the commit applied, so you can amend content, split it, or run commands, then `git rebase --continue`.

**A5.4** It writes a message of exactly `fixup! <subject of the target commit>`. `git config rebase.autosquash true` makes `--autosquash` the default for interactive rebases (Git also honours `--autosquash` for `squash!` and `amend!` prefixes produced by `--squash`/`--fixup=amend:`).

**A5.5** `--onto main` = the **new base**. `feature/metrics` = the **upstream**, i.e. the exclusive lower bound. `feature/dash` = the **branch** to move. Replayed set: `feature/metrics..feature/dash`, exactly the one commit `feat(dash): add dashboard URL`. It lands on top of `main`, and `feature/dash` is repointed there. Without `--onto`, the metrics commits would have come along too.

**A5.6** `-x` appends `(cherry picked from commit <sha>)` to the message, so a release branch commit is traceable to its origin on `main` — essential when auditing what shipped in a hotfix. For 40 commits, cherry-picking produces 40 new commits with new hashes and no recorded relationship: Git cannot tell that `release/1.0` contains `main`'s work, so future merges will conflict repeatedly. Merge (or rebase the release branch) instead.

**A5.7** `git log` walks the commit graph from refs; the old commit was reachable from no ref after `reset --hard`, so it is invisible to `log`. The reflog is a per-repository journal of every value each ref (and `HEAD`) has held, independent of reachability. It will **not** save you when: (a) the work was never committed — the reflog records ref movements, not working-tree states; and (b) the entry has expired and been garbage-collected, or you are in a **fresh clone** / a bare repository where your reflog does not exist (bare repos have `core.logAllRefUpdates` off by default).

### Exercise 6

**A6.1** `reset --hard` + force-push rewrites the published branch: everyone who pulled the old tip now has a divergent history, CI pipelines keyed to those hashes break, and anyone who pushes in between has their work overwritten. `git revert` creates a **new** commit whose diff is the inverse of the bad one. History only grows, the push is a fast-forward, and the record of what happened — the mistake and its correction — remains auditable.

**A6.2** `git reset --soft HEAD~1` leaves the changes staged, ready for `git commit` with a new message. Simpler still: `git commit --amend -m "better message"`.

**A6.3** **No, not from the reflog.** The reflog records where refs pointed, so it can restore any **committed** state. Uncommitted working-tree and index content was never an object reachable from a ref. (A narrow exception: content that was `git add`-ed becomes a blob, so `git fsck --lost-found` can sometimes recover staged-then-discarded content — but not the file names.)

**A6.4** A merge commit has two parents, so "the inverse of this commit" is ambiguous — Git needs to know which parent's line represents "mainline". `-m 1` selects the first parent (on `main`, the branch you merged **into**), so the revert undoes everything that came from the other side. Consequence: the revert makes the merge base look already-integrated, so re-merging the same branch later brings in **nothing** — the feature silently stays missing. The fix is to revert the revert (or rebase the branch onto the new tip) before re-merging.

**A6.5** `git reset HEAD -- file` → `git restore --staged file`. `git checkout -- file` → `git restore file`. Safer because the verbs are disjoint: `git switch` changes branches, `git restore` changes file contents, whereas `git checkout` did both and the meaning depended on whether the argument happened to be a branch name or a path — a real source of data loss with an ambiguous name.

**A6.6** Untracked files stay in the working tree across `git switch`, so they contaminate the other branch's build: a stale generated file, a leftover module, or a config the branch does not expect gets picked up by the build system and produces a result that matches neither branch. `git stash push -u` (or `-a` to include ignored files) puts them in the stash too.

**A6.7** A stash entry is a **commit object** — in fact a merge commit with two or three parents (HEAD, a commit holding the index state, and with `-u` a third holding the untracked files). The ref was `refs/stash`, with previous entries kept in that ref's **reflog** — which is why the numbering is `stash@{0}`, `stash@{1}` and so on.

### Exercise 7

**A7.1** `+` = allow **non-fast-forward** updates to the destination (necessary because an upstream branch can legitimately be force-pushed, and your remote-tracking ref must follow). Left side `refs/heads/*` = the **source** pattern, every branch on the remote. Right side `refs/remotes/origin/*` = the **destination** in your local ref namespace. The `*` on both sides binds positionally: `refs/heads/main` → `refs/remotes/origin/main`.

**A7.2** `git fetch` downloads new objects and updates remote-tracking refs (`refs/remotes/origin/*`), `FETCH_HEAD`, and tags per policy. It does **not** touch your branches, your index, your working tree, or `HEAD`. Scenario: mid-incident you want to know what changed upstream before deciding anything. `git fetch && git log --oneline HEAD..@{u}` answers that with zero risk; a reflexive `git pull` would have started a merge or a rebase on a dirty tree in the middle of the incident.

**A7.3** `origin/main` is the short form; `refs/remotes/origin/main` is the full ref it resolves to; `@{u}` (`@{upstream}`) resolves to whatever ref is configured as the current branch's upstream (`branch.main.remote` + `branch.main.merge`) — usually but not necessarily `origin/main`. You **cannot** commit onto `origin/main`: checking it out detaches HEAD, because it is a local cache of the remote's state, updated only by fetch/push.

**A7.4** The invariant: a ref update on the server must be a **fast-forward** — the old value must be an ancestor of the new one — so no commit that was reachable becomes unreachable. Options, safest first: (1) `git pull --rebase` (or fetch + rebase) then push — your work is preserved and the result is a fast-forward; (2) fetch + merge then push — same guarantee, extra merge commit; (3) `git push --force-with-lease` — rewrites the remote branch, permitted only if nobody pushed since your last fetch; (4) `git push --force` — unconditional overwrite, potential data loss.

**A7.5** It compares the remote-tracking ref you hold (`refs/remotes/origin/main`) with the ref's actual current value on the server, and refuses if they differ. It still permits an overwrite if **you** ran `git fetch` after their push without looking — the fetch silently refreshed your lease. `--force-with-lease=main:<expected-sha>` with an explicit hash closes that hole. It also protects nothing against a push that happens between your check and the server's update if the remote lacks ref-transaction atomicity.

**A7.6** (1) **Object type**: lightweight is a ref pointing straight at a commit; annotated creates a real tag object with tagger, date, message and optional signature. (2) `git describe` considers only annotated tags by default (`--tags` includes lightweight ones). (3) Only annotated (or `-s` signed) tags can be **GPG/SSH-signed** and verified with `git tag -v`. (4) `git push --follow-tags` pushes only annotated tags. (5) `git cat-file -t` returns `commit` vs `tag`.

**A7.7** Git deliberately does **not** update an existing tag ref on fetch — tags are meant to be immutable, and silently moving one under a user would change what a release refers to. Force the update with `git fetch --tags --force` or `git fetch origin 'refs/tags/*:refs/tags/*' --force`. The correct process is to not move published tags: cut `v1.0.1` instead.

**A7.8** A push updates refs and, in a non-bare repository, would leave `HEAD`'s branch pointing at a commit while the working tree and index still reflect the old one — the repository would report the whole diff as uncommitted deletions/modifications, and the developer working there would be silently sabotaged. Git therefore refuses by default (`receive.denyCurrentBranch=refuse`). A bare repository has no working tree and no checked-out branch, so there is nothing to desynchronise.

### Exercise 8

**A8.1** Mode `160000` is a **gitlink**: a tree entry of type `commit`, naming a commit object that lives in a *different* repository. The superproject stores **nothing** of the submodule's file contents — no blobs, no trees — only that 40-character commit ID plus the `.gitmodules` entry telling Git where to clone it from.

**A8.2** Because the superproject pins a **commit**, not a branch; checking out a branch would let the submodule drift silently. If a developer commits while detached and then runs `git submodule update` (or switches superproject branches), HEAD moves to the pinned commit and their commit becomes unreachable in the submodule — recoverable only through the submodule's reflog, and invisible to everyone else because it was never pushed.

**A8.3** `git submodule update` uses **`.git/config`** (`submodule.<name>.url`), which is populated from `.gitmodules` by `git submodule init` (or `update --init`). `git submodule sync` re-copies the URL from `.gitmodules` into `.git/config` — the command you need after the upstream URL changes.

**A8.4** `git submodule update --init --recursive` after the checkout, or `git clone --recurse-submodules` in the first place. In a pipeline, prefer the explicit `submodule update --init --recursive` step (or the platform's `GIT_SUBMODULE_STRATEGY: recursive` / `submodules: recursive`), because the checkout is usually performed by the CI runner and you cannot control its clone flags — and the explicit step also fixes an incremental workspace where the clone already exists.

**A8.5** `git submodule update` checks the submodule out at **the commit the superproject records** — it enforces the pin, and is what you run after pulling. `git submodule update --remote` fetches the submodule's configured branch (`submodule.<name>.branch` in `.gitmodules`, default `HEAD`/`main`) and moves the working checkout to its **latest** commit, leaving the superproject's gitlink modified for you to review and commit — it is a dependency *bump*, not a sync.

**A8.6** The changed line is the **gitlink**: the old and new commit IDs of the dependency. Reviewing "one line changed" is meaningless on its own; the reviewer must inspect the range of commits between them, with `git diff --submodule=log` (subject lines) or `git diff --submodule=diff` (full diff), and should have `git config diff.submodule log` set so this is the default.

**A8.7** (1) The working tree checkout and `.gitmodules` entry and the gitlink — removed by `git rm <path>`; (2) `submodule.<name>.*` in `.git/config` — removed by `git submodule deinit`; (3) the internal clone at `.git/modules/<path>` — must be removed manually. Forgetting (3) means a later `git submodule add` at the same path fails with `A git directory for '<path>' is found locally with remote(s): …`, and the old repository is silently reused.

### Exercise 9

**A9.1** The **public** key (`.pub`) goes to the server. Uploading the private key discloses the secret entirely: anyone with it authenticates as you, and it must be considered compromised — revoke it everywhere and generate a new pair. (The private key is also useless as an `authorized_keys` line; the failure is silent authentication refusal plus a leaked credential.)

**A9.2** `ssh-agent -s` starts the agent and **prints** shell commands (`SSH_AUTH_SOCK=…; export SSH_AUTH_SOCK; SSH_AGENT_PID=…; export SSH_AGENT_PID;`) on stdout. Without `eval`, those lines are just displayed; your shell never sets the variables, so `ssh-add` and `ssh` cannot find the agent socket — `Could not open a connection to your authentication agent` — while an orphaned agent process keeps running.

**A9.3** The passphrase encrypts the private key **at rest**, so a stolen backup, a snapshot, or a laptop theft does not yield a usable credential — file permissions protect only against other users on a running system. `ssh-add -t 8h` bounds the window **in memory**: after the lifetime the agent drops the key, so a machine left unlocked or an attacker with access to the agent socket loses the credential at the end of the working day rather than at the next reboot.

**A9.4** With `IdentitiesOnly yes`, SSH offers **only** the keys named by `IdentityFile`/`CertificateFile` for that host, instead of every identity the agent holds plus the default filenames. Without it, a laptop with six agent keys offers them one at a time; a server with `MaxAuthTries 6` closes the connection with `Too many authentication failures` before the correct key is ever tried — and on a multi-account forge you authenticate as the wrong account.

**A9.5** The host's forced command prints the greeting and exits non-zero because no shell session is granted — `-T` disables PTY allocation and there is nothing to run. Successful *authentication* is what the message reports. Under `set -e`, the script aborts on a successful check, so test the message instead: `ssh -T git@github.com 2>&1 | grep -q 'successfully authenticated'` (or guard with `|| true` and inspect the output).

**A9.6** The **host key** identifies the *server* and is pinned in `~/.ssh/known_hosts`; it defends against a **man-in-the-middle** — without it you would hand your credentials to whatever answers on port 22. The **user key** identifies *you* and lives in `~/.ssh/id_*` (private) and the server's `authorized_keys` (public); it defends against impersonation of you. `REMOTE HOST IDENTIFICATION HAS CHANGED` means the presented host key differs from the pinned one: either a legitimate, announced rotation or a rebuilt server — or an active interception. Verify out of band against the provider's published fingerprint before running `ssh-keygen -R`.

**A9.7** With `ssh -A`, the remote host can use your agent socket for as long as you are connected: **root, or anyone who can read the forwarded socket on the bastion, can authenticate as you to any host your keys open** — without ever obtaining the key. Safer alternative: `ProxyJump` (`ssh -J bastion target`, or `ProxyJump bastion` in `~/.ssh/config`), which tunnels the connection through the bastion while the authentication happens end-to-end from your workstation; the bastion never sees your agent. (If forwarding is unavoidable, confine it with `ssh-add -c` for per-use confirmation.)

**A9.8** `gpg.format = ssh`, `user.signingkey = <path to the .pub>` and `commit.gpgsign = true` (plus `gpg.ssh.allowedSignersFile` for verification). Without `allowedSignersFile`, the signature is present and cryptographically valid but Git has no list mapping keys to identities, so `git log --show-signature` reports `No principal matched.` and `%G?` yields `U` — good signature, unknown signer — rather than `G`.

### Exercise 10

**A10.1** `.git/hooks/` is **not** part of the repository content — it is never committed, cloned or pushed, by design: a repository that could ship executable code that runs on clone would be a remote-code-execution vector. `git config core.hooksPath <dir>` points Git at a committed directory, so the hooks travel with the repo, but **every developer must still opt in** by setting that config (or running a bootstrap script). The hard limit: any client-side hook is advisory — it can be bypassed with `--no-verify`, removed, or simply not configured. Only server-side hooks (or the forge's protected-branch rules) enforce anything.

**A10.2** `update` — it runs once per ref with that ref's old and new values and can reject exactly one while others succeed. `pre-receive` sees the whole push and can only accept or reject all of it. An **atomic push** (`git push --atomic`, or a server configured with `receive.atomic`) changes this: all ref updates succeed or all fail together, so a per-ref `update` rejection aborts the entire push anyway.

**A10.3** That `$oldrev` is an **ancestor** of `$newrev` — the merge base of the two is the old tip itself — which is precisely the definition of a **fast-forward**. If the merge base is anything else, the new tip does not contain the old one and commits would become unreachable. (`git merge-base --is-ancestor "$oldrev" "$newrev"` expresses the same test directly via exit status.)

**A10.4** An all-zeros `newrev` means the ref is being **deleted**. An all-zeros `oldrev` means the ref is being **created** and did not exist before — which is why the hook skips the fast-forward test in that case.

**A10.5** `--no-verify` (`git commit --no-verify`, `git push --no-verify`) bypasses client-side hooks. If a credential reaches a pushed commit, `git revert` is **not** sufficient: the revert adds a new commit, and the secret remains in the old commit, in the object database, in every clone, and in the forge's web UI and API — often permanently, since forges keep unreachable objects. The correct response is, in order: **rotate/revoke the credential immediately** (this is the only step that actually mitigates), then purge it from history (`git filter-repo`, or the forge's own history-rewrite/support process) and force-push, then have every clone re-clone, and ask the forge to garbage-collect and to purge cached views.

</details>

---

## Sources

- LPI, *DevOps Tools Engineer — Exam 701 Objectives (version 2.0.0)*, objective 701.3 Source Code Management: <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Git project documentation — `git-config`, `git-hash-object`, `git-cat-file`, `git-add`, `git-reset`, `git-restore`, `git-merge`, `git-rebase`, `git-cherry-pick`, `git-revert`, `git-stash`, `git-remote`, `git-push`, `git-fetch`, `git-tag`, `git-submodule`, `gitignore`, `gitrevisions`, `githooks`: <https://git-scm.com/docs>
- Git project book, *Pro Git*, chapters 7 (Git Tools) and 10 (Git Internals): <https://git-scm.com/book/en/v2>
- Git `--force-with-lease` semantics, `git push` documentation: <https://git-scm.com/docs/git-push#Documentation/git-push.txt---force-with-leaseltrefnamegt>
- OpenSSH project manual pages — `ssh-keygen(1)`, `ssh-agent(1)`, `ssh-add(1)`, `ssh_config(5)`: <https://man.openbsd.org/ssh-keygen.1>, <https://man.openbsd.org/ssh-agent.1>, <https://man.openbsd.org/ssh-add.1>, <https://man.openbsd.org/ssh_config.5>
- Git SSH commit signing (`gpg.format=ssh`, `gpg.ssh.allowedSignersFile`), `git-config` documentation: <https://git-scm.com/docs/git-config#Documentation/git-config.txt-gpgformat>