# 4.2 Cloud Native Community and Collaboration

## Open Source Software (OSS) as the Foundation of the Cloud Native Ecosystem

Practically the entire cloud native stack (Kubernetes, Prometheus, Envoy, containerd, etc.) is **open source**. Understanding OSS mechanisms is just as important for the KCNA as understanding the technology itself, because the exam evaluates how these projects are governed, maintained, and evolved.

Key points:

- **Common licenses** in the CNCF ecosystem:
  - **Apache License 2.0**: the most widely used (Kubernetes, containerd, Helm). Allows commercial use, modification, and redistribution, requires preserving copyright notices, and grants an explicit patent license.
  - **MIT**: very permissive, minimal restrictions.
  - **GPL/LGPL**: copyleft, less common in the core of the CNCF because it is less "business-friendly".
- Open source is not just "free code": it involves **collaborative development in public**, with an auditable change history and openly discussed decisions (issues, PRs, design docs).
- The sustainability of a project depends on its **community of contributors**, not just a single company. This is a central criterion that the CNCF requires for a project to advance in maturity.

```bash
# Check the license of a repo before using/contributing to it
curl -s https://api.github.com/repos/kubernetes/kubernetes/license | jq '.license.spdx_id'
# "Apache-2.0"
```

## Cloud Native Computing Foundation (CNCF)

The **CNCF** is the organization that hosts the most relevant cloud native open source projects. It is part of the **Linux Foundation** (a non-profit organization) and its stated mission is *"to make cloud native computing ubiquitous"*.

The CNCF does not write most of the code: it provides a neutral structure (legal, trademark, CI infrastructure, governance, events) so that projects and industry competitors can collaborate in a vendor-neutral space.

- Founded in 2015, together with the initial donation of **Kubernetes** by Google.
- Funded by corporate memberships (Platinum, Gold, Silver) and **End User** memberships (companies that use, not necessarily contribute code).
- Publishes the **CNCF Cloud Native Landscape**, an interactive map of projects and products organized by category (orchestration, observability, service mesh, storage, security, etc.).

```
https://landscape.cncf.io
```

## Project Maturity Levels

Every project that enters the CNCF goes through maturity levels, evaluated by the **TOC** (see below):

| Level | Meaning | Examples |
|---|---|---|
| **Sandbox** | Early stage, low risk, early experimentation | Backstage (before graduating), Keptn |
| **Incubating** | Real production adoption by several users, established governance and project practices | OpenTelemetry, Argo, Cilium |
| **Graduated** | Maximum maturity: broad adoption, diversity of maintainers/organizations, security audit performed, good governance practices (OpenSSF Best Practices) | Kubernetes, Prometheus, Envoy, containerd, CoreDNS, etcd, Helm, Fluentd, Vitess |
| **Archived** | The project is retired from the CNCF (lack of maintenance, replacement, etc.) | — |

Typical requirements for graduation include: at least two distinct organizations as main maintainers, demonstrable adoption, compliance with the Code of Conduct, and a third-party security audit.

```bash
# Check the status and category of a project in the landscape (via public API)
curl -s https://raw.githubusercontent.com/cncf/landscape/master/landscape.yml \
  | grep -A3 "name: Prometheus"
```

## CNCF Governance Structure

- **Governing Board (GB)**: representatives from member companies; handles budget, marketing, memberships, and business decisions. It does not decide on technical code.
- **Technical Oversight Committee (TOC)**: elected technical body that approves the inclusion of new projects and their progress between maturity levels (Sandbox → Incubating → Graduated).
- **TAGs (Technical Advisory Groups)**: cross-cutting thematic groups that advise the TOC. Examples: TAG App Delivery, TAG Security, TAG Observability, TAG Runtime, TAG Network, TAG Storage, TAG Contributor Strategy.
- **End User Community**: companies that *use* cloud native technology (not necessarily contributing code) and provide real adoption feedback (e.g., adoption case studies).

Within **individual projects** (like Kubernetes) there is a more granular structure of their own:

- **SIGs (Special Interest Groups)**: e.g., `sig-network`, `sig-storage`, `sig-apps`, `sig-node`, each responsible for a technical area of the project.
- **Working Groups**: temporary groups to resolve a specific topic across multiple SIGs.

## Roles within an Open Source Community

It is common to find this progression (defined in `community/community-membership.md` in Kubernetes, taken as a reference by many CNCF projects):

1. **Member**: signed the CLA/DCO and had at least one accepted contribution.
2. **Reviewer**: can review (`/lgtm`) PRs in a specific area.
3. **Approver**: can approve (`/approve`) merges in a specific area.
4. **Maintainer**: overall responsibility for the project or subsystem (roadmap, releases, governance).

These roles are usually declared in an **`OWNERS`** file within the repo:

```yaml
# OWNERS (simplified example, Kubernetes style)
approvers:
  - alice
  - bob
reviewers:
  - carol
  - dave
```

### DCO (Developer Certificate of Origin)

Many CNCF projects (Kubernetes, containerd, Helm) require signing commits to certify that the author has the right to contribute that code:

```bash
git commit -s -m "fix: correct typo in kubelet flag description"
```

```
commit a1b2c3d
Author: Alice Dev <alice@example.com>
Date:   Wed Jul 16 10:00:00 2026 -0300

    fix: correct typo in kubelet flag description

    Signed-off-by: Alice Dev <alice@example.com>
```

A PR without `Signed-off-by:` is usually automatically rejected by a CI bot (e.g., the DCO GitHub App).

## Communication and Collaboration Channels

- **Slack**: `kubernetes.slack.com` (Kubernetes project) and `cloud-native.slack.com` (general CNCF), organized into channels by SIG/project/topic.
- **Mailing lists** (Google Groups): used for formal announcements, design discussions, and voting.
- **GitHub**: Issues (bugs/features), Discussions (questions), Pull Requests (code changes), all public and auditable.
- **Community meetings**: periodic video call meetings with public minutes (e.g., Google Docs linked from the SIG calendar).
- **KubeCon + CloudNativeCon**: the flagship event of the CNCF (held in North America, Europe, and Asia each year), where technical talks are presented, contributors coordinate, and in-person TOC/TAG meetings take place.

```bash
# Example of a typical contribution flow
git clone https://github.com/cncf/foo.git
cd foo
git checkout -b fix/typo-readme
# ... edit files ...
git commit -s -m "docs: fix typo in README"
git push origin fix/typo-readme
# then open a Pull Request from GitHub
```

## Code of Conduct

The CNCF requires that all its projects adopt a **Code of Conduct** (based on the *Contributor Covenant*), which defines expected behavior, reporting mechanisms, and consequences for violations. It is a governance requirement, not optional, for any project hosted by the foundation.

## Related Certifications (Linux Foundation / CNCF)

As part of the community strategy, the CNCF and the Linux Foundation offer certifications that validate knowledge and skills:

- **KCNA** (Kubernetes and Cloud Native Associate) — the certification for this very material.
- **KCSA** (Kubernetes and Cloud Native Security Associate).
- **CKA** (Certified Kubernetes Administrator), **CKAD** (Application Developer), **CKS** (Security Specialist).
- Certifications for other landscape projects (e.g., Prometheus Certified Associate, Istio Certified Associate).

These certifications are themselves a product of **community collaboration**: the curriculum is defined and updated publicly on GitHub, with open contributions from the community.

```
https://github.com/cncf/curriculum
```

## References

- CNCF Curriculum (KCNA) — https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- CNCF Charter and governance structure — https://github.com/cncf/foundation/blob/main/charter.md
- CNCF Cloud Native Landscape — https://landscape.cncf.io
- CNCF Project Graduation Criteria — https://github.com/cncf/toc/blob/main/process/graduation_criteria.md
- Kubernetes Community Membership — https://github.com/kubernetes/community/blob/master/community-membership.md
- CNCF Code of Conduct — https://github.com/cncf/foundation/blob/main/code-of-conduct.md
- Contributor Covenant — https://www.contributor-covenant.org
- CNCF Contribute — https://contribute.cncf.io
- KubeCon + CloudNativeCon — https://www.cncf.io/kubecon-cloudnativecon-events/