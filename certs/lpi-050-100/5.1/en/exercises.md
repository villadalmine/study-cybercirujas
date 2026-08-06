# Study Guide & Hands-on Lab: Topic 5.1 – Software Development Models

**Target Certification:** LPI Open Source Essentials (Exam 050-100)  
**Topic:** 5.1 Software Development Models  
**Exam Weight:** 7.5  
**Level:** Advanced SRE / Production Platform Architect  

---

## 1. Architectural Overview & Technical Mechanics

Software development models define the operational, organizational, and technological frameworks used to plan, build, test, release, and maintain software. In open-source and modern cloud-native environments, understanding these models is crucial for designing resilient continuous delivery pipelines, managing release risk, and aligning open-source software (OSS) governance with SRE reliability goals.

```
       +-------------------------------------------------------------------------+
       |                     SOFTWARE DEVELOPMENT SPECTRUM                       |
       +-------------------------------------------------------------------------+
       |                                                                         |
       |  [ Cathedral Model ] -------------> [ Agile / Scrum ] ----------> [ SRE / DevOps ]
       |  (Predictable, isolated,               (Iterative, sprint-            (Continuous, automated,
       |   centralized control)                 based delivery)                 GitOps, error budgets)
       |                                                                         |
       |  [ Waterfall Model ] -------------> [ Bazaar Model ] -----------> [ GitOps / CI/CD ]
       |  (Sequential phases,                   (Distributed, rapid             (Declarative state, automated
       |   rigid boundaries)                    peer review, open)              reconciliation loops)
       |                                                                         |
       +-------------------------------------------------------------------------+
```

### 1.1 The Classical & Open Source Paradigm Spectrum

#### 1. Cathedral vs. Bazaar (Eric S. Raymond)
* **The Cathedral Model:** Software is developed in isolation by a restricted group of developers between official public releases. Source code is guarded until major releases, review loops are centralized, and architectural control is strictly top-down.
* **The Bazaar Model:** Software is developed in public ("release early, release often"). Thousands of independent co-developers test, patch, and extend the codebase simultaneously. *Linus's Law:* "Given enough eyeballs, all bugs are shallow."

#### 2. Sequential (Waterfall) vs. Iterative (Agile / Scrum / Kanban)
* **Waterfall:** A sequential, stage-gated lifecycle (Requirements $\to$ Design $\to$ Implementation $\to$ Verification $\to$ Maintenance). High change cost, late validation, prone to integration hell.
* **Agile/Scrum:** Timeboxed iterations (sprints) producing increments of working software. Emphasizes user stories, velocity, retrospectives, and cross-functional teams.
* **Kanban:** Continuous flow model driven by explicit Work-In-Progress (WIP) limits. Optimizes lead time and throughput without fixed sprint boundaries.

#### 3. Continuous SRE & DevOps Integration
Modern software development models integrate Site Reliability Engineering (SRE) primitives into the lifecycle:
* **Continuous Integration (CI):** Developers merge code to main continuously; automated builds and tests run per commit.
* **Continuous Delivery/Deployment (CD):** Automated deployment to staging/production subject to quality gates or GitOps state reconciliation.
* **Shift-Left Security & Testing:** Static Application Security Testing (SAST), Software Bill of Materials (SBOM) scanning, and unit tests execute automatically prior to merge.

---

## 2. Production Trade-Off Matrix

| Model | Flexibility to Change | Feedback Loop Latency | Production Release Risk | Operational Overhead | Typical Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Waterfall** | Very Low | Months / Years | High (Big Bang) | Low initial, high post-release | Embedded systems, safety-critical hardware |
| **Cathedral (OSS)** | Low-Medium | Months | Medium | High gatekeeper triage burden | Core kernel sub-components, vendor core OS |
| **Bazaar (OSS)** | High | Hours / Days | Variable (Requires CI filtering) | High CI infrastructure cost | Kubernetes, Linux Kernel, CNCF ecosystem |
| **Agile / Scrum** | High | 1–3 Weeks | Medium (Sprint end deployments) | Medium (Scrum ceremonies) | Enterprise SaaS, application microservices |
| **Continuous DevOps / SRE** | Very High | Minutes / Hours | Low (Canary / Feature Flags) | High (Platform engineering effort) | Cloud-native platforms, high-scale web platforms |

---

## 3. Hands-on Guided Exercises

---

### Exercise 1: Simulating Cathedral vs. Bazaar Git Release Workflows

In this exercise, you will construct two distinct Git workflow strategies in a repository: a **Cathedral release flow** (strict release branches, gatekeeping) and a **Bazaar continuous contribution flow** (fork-and-pull, rapid automated validation).

#### Step 1.1: Initialize the Lab Environment and Cathedral Repository Structure
Run the following commands in your shell to simulate a centralized Cathedral release flow.

```bash
mkdir -p ~/dev-models-lab/cathedral-repo
cd ~/dev-models-lab/cathedral-repo
git init -b main
git config user.name "Cathedral Maintainer"
git config user.email "maintainer@cathedral.org"

# Create core application code
cat << 'EOF' > app.py
VERSION = "1.0.0-cathedral"

def core_function():
    return "Stable core functionality validated by release committee."

if __name__ == "__main__":
    print(f"App Version: {VERSION}")
    print(core_function())
EOF

git add app.py
git commit -m "feat: initial cathedral core release 1.0.0"
git tag -a v1.0.0 -m "Official Cathedral Release 1.0.0"
```

Expected Output:
```text
[main (root-commit) a1b2c3d] feat: initial cathedral core release 1.0.0
 1 file changed, 8 insertions(+)
 create mode 100644 app.py
```

#### Step 1.2: Simulate Isolated Cathedral Development Branching
In the Cathedral model, feature additions are kept isolated in private staging branches for long cycles before merging to `main`.

```bash
# Create long-lived release staging branch
git checkout -b release/2.0.0-staging

cat << 'EOF' > app.py
VERSION = "2.0.0-cathedral"

def core_function():
    return "Stable core functionality validated by release committee."

def new_isolated_feature():
    return "Feature developed internally after 12 months of planning."

if __name__ == "__main__":
    print(f"App Version: {VERSION}")
    print(core_function())
    print(new_isolated_feature())
EOF

git commit -am "feat: internal development for release 2.0.0"
```

#### Step 1.3: Initialize the Bazaar Continuous Pipeline Model
Now, create a separate repository representing the Bazaar model: continuous peer commits, feature toggling, and automated semantic versioning.

```bash
mkdir -p ~/dev-models-lab/bazaar-repo
cd ~/dev-models-lab/bazaar-repo
git init -b main
git config user.name "Bazaar Developer"
git config user.email "dev@bazaar.community"

cat << 'EOF' > app.py
import os

VERSION = "1.1.0-bazaar"

def get_feature_flags():
    return os.getenv("ENABLE_EXPERIMENTAL_BAZAAR", "false").lower() == "true"

def core_function():
    status = "Core functionality"
    if get_feature_flags():
        status += " [EXPERIMENTAL BAZAAR PATCH ENABLED]"
    return status

if __name__ == "__main__":
    print(f"Bazaar Build Version: {VERSION}")
    print(core_function())
EOF

git add app.py
git commit -m "feat(core): initial bazaar deployment with feature flags"
```

Expected Output:
```text
[main (root-commit) e5f6g7h] feat(core): initial bazaar deployment with feature flags
 1 file changed, 16 insertions(+)
 create mode 100644 app.py
```

#### Step 1.4: Execute Automated Bazaar Feature Toggling
Verify how Bazaar-style software relies on runtime configuration toggling rather than long branch isolation to test new code in production safely.

```bash
python3 app.py
ENABLE_EXPERIMENTAL_BAZAAR=true python3 app.py
```

Expected Output:
```text
Bazaar Build Version: 1.1.0-bazaar
Core functionality
Bazaar Build Version: 1.1.0-bazaar
Core functionality [EXPERIMENTAL BAZAAR PATCH ENABLED]
```

---

#### Verification Questions – Exercise 1

1. **Question 1.1:** Which primary risk of the Cathedral development model does the Bazaar model directly address by introducing frequent releases and broad public peer review?
   * A) High infrastructure costs during CI/CD execution.
   * B) "Integration Hell" caused by long-lived isolated development branches breaking compatibility upon merge.
   * C) Inability to enforce strict copyright and open-source license compliance.
   * D) Over-reliance on runtime feature flags causing technical debt.

2. **Question 1.2:** In the Bazaar model, how does feature flag implementation preserve site reliability while allowing continuous deployment ("release early, release often")?
   * A) It replaces unit testing by catching exceptions at runtime.
   * B) It decouples code deployment from feature activation, allowing instant rollback without re-deploying artifacts.
   * C) It forces code to compile into separate binaries for Cathedral and Bazaar releases.
   * D) It automatically converts Waterfall documentation into Agile user stories.

---

### Exercise 2: Implementing CI/CD Quality Gates & Release Automation for Agile/SRE Models

Modern software development models enforce compliance, security, and quality gates dynamically using continuous integration pipelines. In this exercise, you will define a syntactically valid GitHub Actions workflow manifest that automates semantic version checks, unit testing, and automated deployment conditions.

#### Step 2.1: Define the Declarative CI Pipeline Manifest
Create the directory structure and workflow file inside `~/dev-models-lab/bazaar-repo/.github/workflows/ci.yml`.

```bash
mkdir -p ~/dev-models-lab/bazaar-repo/.github/workflows
cd ~/dev-models-lab/bazaar-repo

cat << 'EOF' > .github/workflows/ci.yml
name: Bazaar Software Model CI/CD Pipeline

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  quality-gate:
    name: Code Verification & SAST Gate
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Python Environment
        uses: actions/setup-python@v5
        with:
          python-version: '3.10'

      - name: Run Syntax and Style Verification
        run: |
          python -m py_compile app.py
          echo "Syntax verification passed."

      - name: Execute Automated Unit Tests
        run: |
          python -c "import app; assert 'Core functionality' in app.core_function()"
          echo "Unit tests passed successfully."

  cd-release:
    name: Continuous Deployment Gate
    needs: quality-gate
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - name: Simulate Production Artifact Bundle
        run: |
          echo "Packaging application for automated production release..."
          tar -czf release-artifact.tar.gz app.py
          sha256sum release-artifact.tar.gz > release-artifact.tar.gz.sha256
          echo "Artifact created successfully:"
          cat release-artifact.tar.gz.sha256
EOF
```

#### Step 2.2: Validate and Test the Pipeline Logic Locally
Simulate the pipeline's execution steps using local Python tools.

```bash
python3 -m py_compile app.py
python3 -c "import app; assert 'Core functionality' in app.core_function()"
tar -czf release-artifact.tar.gz app.py
sha256sum release-artifact.tar.gz
```

Expected Output:
```text
<hash-value>  release-artifact.tar.gz
```

---

#### Verification Questions – Exercise 2

1. **Question 2.1:** In an SRE-driven continuous integration pipeline, what is the role of the `needs: quality-gate` directive in the deployment job definition?
   * A) It allows the deployment job to execute concurrently with the quality gate to improve velocity.
   * B) It acts as a hard pipeline dependency, ensuring no artifact is built or deployed if verification tests fail.
   * C) It mandates manual human approval before the job executes.
   * D) It converts Agile sprint backlogs into Kanban WIP limits.

2. **Question 2.2:** How does the shift-left testing philosophy in modern CI pipelines alter the cost of bug remediation compared to traditional Waterfall testing?
   * A) It increases remediation cost by requiring complex pipeline infrastructure.
   * B) It keeps costs constant regardless of when the bug is discovered.
   * C) It drastically reduces remediation cost by detecting defects during early integration rather than post-release production outages.
   * D) It eliminates the need for post-production observability and monitoring.

---

### Exercise 3: Simulating Agile Velocity and Kanban Flow Bottlenecks

In SRE and Platform Engineering, software development delivery metrics (DORA metrics) are used to measure the efficiency of development models. The four core metrics are:
1. **Deployment Frequency (DF)**
2. **Lead Time for Changes (LTC)**
3. **Change Failure Rate (CFR)**
4. **Time to Restore Service (TTRS)**

In this exercise, you will run a diagnostic script that analyzes Git commit logs to calculate lead time and deployment frequency metrics.

#### Step 3.1: Create a Simulation Script for DORA Metric Calculation
Create a Python script that parses commit timestamps to calculate **Lead Time for Changes** across releases.

```bash
cd ~/dev-models-lab

cat << 'EOF' > dora_metrics.py
import json
import subprocess
from datetime import datetime

def parse_git_commits():
    # Fetch commit hashes and commit timestamps
    cmd = ["git", "log", "--format=%H|%at|%s"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    lines = result.stdout.strip().split("\n")
    
    commits = []
    for line in lines:
        if not line:
            continue
        h, ts, msg = line.split("|", 2)
        commits.append({
            "hash": h[:7],
            "timestamp": int(ts),
            "date": datetime.fromtimestamp(int(ts)).strftime('%Y-%m-%d %H:%M:%S'),
            "message": msg
        })
    return commits

def calculate_lead_time(commits):
    if len(commits) < 2:
        return 0.0
    # Lead time between oldest commit in window and newest commit
    newest = commits[0]["timestamp"]
    oldest = commits[-1]["timestamp"]
    return (newest - oldest) / 3600.0  # Hours

if __name__ == "__main__":
    import os
    os.chdir(os.path.expanduser("~/dev-models-lab/bazaar-repo"))
    commits = parse_git_commits()
    lt_hours = calculate_lead_time(commits)
    
    metrics = {
        "total_commits": len(commits),
        "lead_time_hours": round(lt_hours, 4),
        "deployment_frequency_rating": "Elite" if len(commits) > 0 else "Low",
        "recent_commits": commits
    }
    
    print(json.dumps(metrics, indent=2))
EOF
```

#### Step 3.2: Execute DORA Diagnostic Metric Extraction
Run the script to analyze the `bazaar-repo` history.

```bash
python3 dora_metrics.py
```

Expected Output:
```json
{
  "total_commits": 1,
  "lead_time_hours": 0.0,
  "deployment_frequency_rating": "Elite",
  "recent_commits": [
    {
      "hash": "...",
      "timestamp": 1700000000,
      "date": "...",
      "message": "feat(core): initial bazaar deployment with feature flags"
    }
  ]
}
```

---

#### Verification Questions – Exercise 3

1. **Question 3.1:** Which DORA metric directly measures the velocity of a development team's pipeline from code commit to running in production?
   * A) Time to Restore Service (TTRS)
   * B) Change Failure Rate (CFR)
   * C) Lead Time for Changes (LTC)
   * D) Work In Progress (WIP) Limit

2. **Question 3.2:** If a team transitioning from Waterfall to DevOps experiences a high Change Failure Rate (CFR > 40%) despite high Deployment Frequency, what is the primary architectural deficiency in their pipeline?
   * A) Insufficient sprint retrospective meetings.
   * B) Lack of automated testing, canary validation, and production quality gates.
   * C) Over-use of open-source Bazaar governance models.
   * D) Using Git branches instead of subversion repositories.

---

## 4. References & Official Sources

* **LPI Open Source Essentials Exam Objectives:**  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **The Cathedral and the Bazaar (Eric S. Raymond):**  
  [https://www.catb.org/~esr/writings/cathedral-bazaar/cathedral-bazaar/](https://www.catb.org/~esr/writings/cathedral-bazaar/cathedral-bazaar/)
* **DORA (DevOps Research and Assessment) Metrics:**  
  [https://dora.dev/quickss/](https://dora.dev/quickss/)
* **CNCF Continuous Delivery Landscape & Best Practices:**  
  [https://www.cncf.io/reports/continuous-delivery-landscape/](https://www.cncf.io/reports/continuous-delivery-landscape/)

---

## 5. Verification Answers & Detailed Technical Explanations

<details>
<summary>Click here to expand Solutions and Detailed Explanations</summary>

### Exercise 1 Solutions

* **Question 1.1: Correct Answer: B**
  * **Technical Justification:** In the Cathedral model, code remains in isolated long-lived development branches for long periods. Merging these massive diffs back into `main` causes severe code drift and "Integration Hell." The Bazaar model solves this by releasing early and often, merging small increments continuously to resolve conflicts immediately.
  * **Incorrect Options Analysis:**
    * A is incorrect because Bazaar models often increase CI runs due to frequent commits.
    * C is incorrect because open-source licensing compliance requires explicit scanners (e.g., FOSSology), independent of branching model.
    * D is incorrect because feature flags are an operational deployment technique, not a inherent flaw of the Bazaar model.

* **Question 1.2: Correct Answer: B**
  * **Technical Justification:** Feature flags separate the action of *deploying code* from *releasing functionality* to users. Code can be pushed to production continuously in a disabled state. If an anomaly occurs, SREs can flip the flag to off instantly via configuration without triggering a multi-minute container build or deployment pipeline.
  * **Incorrect Options Analysis:**
    * A is incorrect because feature flags do not replace automated unit testing.
    * C is incorrect because feature flags dynamically alter runtime execution paths within the same compiled artifact.
    * D is incorrect because feature flags do not interact with documentation transformation.

---

### Exercise 2 Solutions

* **Question 2.1: Correct Answer: B**
  * **Technical Justification:** In GitHub Actions and standard CI/CD DAG engines, the `needs:` attribute defines a dependency node. The `cd-release` job will remain blocked until the `quality-gate` job completes with an exit code of `0` (success). If unit tests or SAST scanners fail, the release job is automatically skipped.
  * **Incorrect Options Analysis:**
    * A is incorrect because `needs:` forces sequential execution, not concurrency.
    * C is incorrect because manual approval in GitHub Actions is governed by environment protection rules (`environment:`), not `needs:`.
    * D is incorrect because CI job syntax does not manipulate project management methodologies.

* **Question 2.2: Correct Answer: C**
  * **Technical Justification:** The "Shift-Left" paradigm moves security checks, syntax validation, and unit tests to the earliest stages of the software lifecycle (developer workstations and PR checks). Fixing a bug during PR creation costs minimal developer time; discovering the same bug during a production outage involves incident response teams, customer impact, and hotfix overhead.
  * **Incorrect Options Analysis:**
    * A is incorrect because automated testing drastically lowers overall engineering cost compared to manual QA and incident handling.
    * B is incorrect because defect cost increases exponentially as code moves closer to production.
    * D is incorrect because shift-left testing complements, but does not replace, production observability.

---

### Exercise 3 Solutions

* **Question 3.1: Correct Answer: C**
  * **Technical Justification:** Lead Time for Changes (LTC) measures the precise duration elapsed from the time a commit is committed to the version control repository until that code is running in a production environment.
  * **Incorrect Options Analysis:**
    * A (TTRS) measures recovery time after an outage occurs.
    * B (CFR) measures the percentage of deployments that cause production failures.
    * D (WIP) is a Kanban flow constraint metric, not a DORA velocity metric.

* **Question 3.2: Correct Answer: B**
  * **Technical Justification:** Deploying rapidly without adequate quality gates (automated regression tests, SAST scanning, canary release strategies, automated health check rollbacks) leads to frequent production breakage, reflected directly as a high Change Failure Rate. High Deployment Frequency must be balanced by automated verification gates to maintain SRE error budgets.
  * **Incorrect Options Analysis:**
    * A is incorrect because sprint retrospectives do not mechanically intercept defective deployment artifacts.
    * C is incorrect because Bazaar governance models can achieve high reliability when combined with automated CI pipelines.
    * D is incorrect because version control tool selection (Git vs SVN) does not inherently fix defective application logic.

</details>