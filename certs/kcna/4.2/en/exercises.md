# Guided Exercises: Cloud Native Community and Collaboration (KCNA 4.2)

> Reference source: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

These exercises lead you to first-hand exploration of how the cloud native community is organized: the role of the CNCF, project maturity, governance models, the people involved, and open source licenses. They require no cluster or terminal — you use a browser and, in some cases, `git`/`curl`.

---

## Exercise 1: The CNCF Landscape

1. Open [landscape.cncf.io](https://landscape.cncf.io) in your browser.
2. Locate the **"Orchestration & Management"** category and within it the **"Scheduling & Orchestration"** subcategory.
3. Identify which is the only project marked as **Graduated** in that subcategory.
4. Change the top filter from "Card" to "Landscape" (or use the view toggle) and count how many main categories the full landscape has.
5. Filter by **"CNCF Graduated"** in the filter menu and note how many projects appear in total.

**Comprehension questions:**
- What is the difference between a project that appears in the landscape and a project that is a **CNCF project** (Sandbox, Incubating, or Graduated)?
- Why does the CNCF maintain such a broad landscape instead of listing only its own projects?

---

## Exercise 2: Project maturity levels

1. Go to the repository [github.com/cncf/toc](https://github.com/cncf/toc).
2. Open the file `process/graduation_criteria.md` (or search for it using the repo search if its location has changed).
3. Identify the three maturity levels defined by the CNCF: **Sandbox**, **Incubating**, and **Graduated**.
4. For each level, note at least one formal requirement (e.g., minimum number of committers from different organizations, documented adoption by at least 3 end users in production, passing a security audit, etc.).
5. Go back to [landscape.cncf.io](https://landscape.cncf.io), search for **Argo** and **etcd**, and determine at which maturity level each currently sits.

**Comprehension questions:**
- Which body within the CNCF is responsible for approving a project’s transition from one maturity level to another?
- Is a newly accepted Sandbox project already a "CNCF project" or not yet?

---

## Exercise 3: Governance of a real project

1. Open [github.com/kubernetes/community](https://github.com/kubernetes/community).
2. Find the `governance.md` file in the root of the repo and open it.
3. Identify what role the **Steering Committee** of Kubernetes plays.
4. Within the same repo, navigate to the `sig-list.md` file and count how many active **SIGs (Special Interest Groups)** are listed (e.g., sig-network, sig-storage, sig-cli).
5. Choose one SIG (e.g., `sig-node`) and locate its `README.md` to see its charter (scope of responsibility).

**Comprehension questions:**
- What is the difference between a SIG and a **Working Group** within Kubernetes governance?
- Why does a project of Kubernetes’ scale need to subdivide its community into SIGs instead of having a single decision‑making body?

---

## Exercise 4: People of the cloud native community

1. Go to [github.com/cncf/toc/blob/main/process/dei-glossary.md](https://github.com/cncf/toc) (or search for "personas" in any CNCF project’s documentation, e.g., in `CONTRIBUTING.md` of Kubernetes).
2. Open [kubernetes.io/community](https://kubernetes.io/community) and locate the section describing how to start contributing.
3. Based on what you read, distinguish at least three typical personas in a cloud native open source project: **end user**, **contributor**, and **maintainer**.
4. In the Kubernetes repo, find the `OWNERS` file of any subdirectory (e.g., `staging/src/k8s.io/api/OWNERS`) and observe the `approvers` and `reviewers` sections.

**Comprehension questions:**
- What difference in responsibility is there between a `reviewer` and an `approver` according to the `OWNERS` file?
- Can an end user become a maintainer without passing through the contributor role? Justify based on the typical flow you observed.

---

## Exercise 5: Open source licenses

1. Choose three CNCF project repositories: [github.com/kubernetes/kubernetes](https://github.com/kubernetes/kubernetes), [github.com/prometheus/prometheus](https://github.com/prometheus/prometheus), and [github.com/envoyproxy/envoy](https://github.com/envoyproxy/envoy).
2. In each, open the `LICENSE` file from the repository root.
3. Identify which license each project uses.
4. With `curl`, download the license file from one of them and count how many lines it has:
   ```bash
   curl -s https://raw.githubusercontent.com/kubernetes/kubernetes/master/LICENSE | wc -l
   ```
5. Look in that license for the clause related to **patent grant**.

**Comprehension questions:**
- Why does the CNCF require that all its Graduated and Incubating projects use the **Apache License 2.0** (or a compatible license) instead of leaving the choice free?
- What practical difference does a permissive license like Apache 2.0 have compared to a copyleft license like GPL, in the context of enterprise adoption?

---

## Exercise 6: Community events and certifications

1. Go to [community.cncf.io](https://community.cncf.io) or the events page on [cncf.io](https://www.cncf.io/).
2. Find information about **KubeCon + CloudNativeCon**, the flagship CNCF event.
3. Go to [training.linuxfoundation.org](https://training.linuxfoundation.org) and search for the list of cloud native certifications offered by the Linux Foundation in conjunction with the CNCF (e.g., KCNA, CKA, CKAD, CKS).
4. Identify which organization issues these certifications: the CNCF directly or the Linux Foundation?

**Comprehension questions:**
- What role does an event like KubeCon play in the community collaboration model, beyond being a conference?
- What institutional relationship exists between the CNCF and the Linux Foundation?

---

<details>
<summary><strong>View answers</strong></summary>

**Exercise 1**
- The landscape includes CNCF projects and also third‑party software (open source or commercial) relevant to the cloud native ecosystem, even if it is not owned or under CNCF governance. A "CNCF project" is specifically one that has been formally donated to the foundation and has an assigned maturity level (Sandbox, Incubating, Graduated).
- Because the landscape aims to help users and architects navigate the entire cloud native ecosystem, not just the foundation’s own catalog — it is a market reference tool, not a catalog of ownership.

**Exercise 2**
- The **TOC (Technical Oversight Committee)** is the body that evaluates and approves project maturity transitions (acceptance to Sandbox, promotion to Incubating, promotion to Graduated).
- Yes, it is already a CNCF project from the moment it is accepted into Sandbox, though with the lowest maturity and guarantees of the three levels.

**Exercise 3**
- A SIG (Special Interest Group) has a permanent, long‑term responsibility over an area of the project (e.g., sig-storage). A Working Group is temporary, created to solve a specific problem that usually spans multiple SIGs, and disbands after completing its goal.
- Because at that scale no single group can have the technical context needed to review changes across all areas (networking, storage, API machinery, etc.); dividing into SIGs allows domain experts to make informed decisions and distributes the review and maintenance load.

**Exercise 4**
- The `reviewer` can review and approve the technical quality of a change (`/lgtm`), but does not have authority to merge it. The `approver` has the final authority to approve the merge (`/approve`), taking responsibility for the impact of the change on that part of the code.
- Yes, it can, but typically follows a progression: first contributes (PRs, issues, reviews), gains trust and visibility in the relevant SIG, and eventually is proposed as reviewer and then approver/maintainer. Jumping directly from end user to maintainer without contributing would be atypical and does not follow the meritocratic flow used by these projects.

**Exercise 5**
- Because Apache 2.0 is a permissive license that includes an explicit patent grant, which gives legal certainty to companies that want to adopt and contribute without risk of patent litigation. Standardizing the license across all CNCF projects reduces legal friction for enterprise adopters and eases code combination between projects.
- Apache 2.0 allows using, modifying, and redistributing the code (even in closed commercial products) without the obligation to release the derived code. GPL is copyleft: any distributed derivative work must inherit the same license and release its source code. Companies generally prefer permissive licenses like Apache 2.0 because they are not forced to open their own code.

**Exercise 6**
- KubeCon + CloudNativeCon serves as an in‑person meeting point for the community: SIGs coordinate there, project graduation announcements are made, technical talks and contributor summits are held, and collaboration among maintainers, contributors, and end users who normally interact only asynchronously via GitHub/Slack is strengthened.
- The CNCF is a foundation under the umbrella of the Linux Foundation. The Linux Foundation is the legal entity that administers infrastructure, certification programs, and events, while the CNCF is the specific foundation focused on the cloud native ecosystem within that larger umbrella.

</details>