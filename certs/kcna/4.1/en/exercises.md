# Guided Exercises — 4.1 Cloud Native Ecosystem and Principles

*Reference source: [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)*

---

## Exercise 1 — The Definition of Cloud Native and Its Pillars

1. Write down (on paper or in a text editor) your own definition of "cloud native" before reading anything else, in a single sentence.
2. Now identify, within that definition, whether you mentioned any of these four elements: **containers**, **microservices**, **immutable infrastructure**, **declarative APIs**. Mark which ones you included and which you did not.
3. Take an application you know (for example, a traditional monolithic application deployed on a VM) and list, point by point, what would change in its architecture, its deployment process, and its scaling method if you migrated it to a cloud native approach.
4. Compare your list from step 3 against the four pillars from step 2. Mark which pillar addresses each change you identified.

> **Question 1.1:** According to the CNCF approach, why is "using containers" alone not enough to say a system is "cloud native"?
>
> **Question 1.2:** Given a system that stores hardcoded network configuration inside the container image and requires manual SSH to apply changes, which cloud native pillar is being violated and why?

---

## Exercise 2 — Exploring the CNCF Landscape

1. Go to [landscape.cncf.io](https://landscape.cncf.io) (you can do it from any browser; no account required).
2. Locate the **"Orchestration & Management"** category and within it the **"Scheduling & Orchestration"** subcategory. Write down three projects that appear there besides Kubernetes.
3. Switch to the **"App Definition and Development"** category and write down one project from the **"Database"** subcategory and one from **"Streaming & Messaging"**.
4. Enable the filter that distinguishes **CNCF hosted** projects from projects that are only listed as part of the landscape without being hosted by the CNCF (look at the icon/distinctive border the site uses). Write down one example of each type.
5. Count, roughly, how many main categories the full landscape has (without going into subcategories).

> **Question 2.1:** What is the difference between a project that the CNCF "hosts" (CNCF hosted project) and one that is simply listed in the landscape?
>
> **Question 2.2:** How does the landscape help an organization that is evaluating which tools to adopt, beyond being a simple catalog?

---

## Exercise 3 — Maturity Levels of a CNCF Project

1. Choose three CNCF projects that you know or that you saw in Exercise 2 (for example: Kubernetes, Envoy, something you noted as "recently added" or less known).
2. For each one, look on the landscape itself or on the [official CNCF projects list](https://www.cncf.io/projects/) for its status: **Sandbox**, **Incubating**, or **Graduated**.
3. For each project, write down an indicator that justifies that level: number of known adopters, time since it entered the CNCF, whether it has an audited security process (relevant especially for Graduated).
4. Order the three projects from lowest to highest maturity based on what you found.

> **Question 3.1:** Which CNCF governing body is responsible for approving a project's move from one maturity level to another?
>
> **Question 3.2:** An infrastructure team asks you if they can put a project that is in **Sandbox** state into critical production. What do you answer and why, in terms of risk and expectations of that stage?
>
> **Question 3.3:** What key difference separates an **Incubating** project from a **Graduated** one in terms of stability and adoption expectations?

---

## Exercise 4 — Walking the Cloud Native Trail Map

1. Find the **Cloud Native Trail Map** diagram, published by the CNCF, which proposes a sequence of recommended steps to adopt cloud native practices.
2. List, in order, the first four steps of the Trail Map (typically: containerization, CI/CD, orchestration & application definition, observability & analysis).
3. For each of those four steps, write a concrete example of a CNCF tool or project that covers it (e.g., containerization → a container runtime).
4. Imagine your team still deploys binaries directly on VMs without containers or automated pipeline. Point out which would be the first step of the Trail Map they should tackle and justify why that one and not another later in the map.

> **Question 4.1:** Why does the Trail Map place observability (logging, monitoring, tracing) as a step after orchestration and not as the first?
>
> **Question 4.2:** What practical problem does the Trail Map aim to avoid by suggesting a recommended adoption order instead of letting each organization start wherever they want?

---

## Exercise 5 — Governance and Roles in the CNCF Community

1. Identify which umbrella organization hosts the CNCF (hint: it is a non-profit foundation dedicated to sustaining open source projects).
2. List three different roles that a person or company can have within the ecosystem of a CNCF project: **end user**, **contributor**, **maintainer**.
3. Look up what the CNCF **Technical Oversight Committee (TOC)** is and write down, in one sentence, its main function.
4. Look up what a **Special Interest Group (SIG)** is within the Kubernetes community and write down one example of a SIG (e.g., SIG-Networking, SIG-Storage).
5. Review what the **CNCF End User Community** is and why it exists as a separate group from project maintainers.

> **Question 5.1:** What is the difference between being a *contributor* and a *maintainer* of an open source project within the CNCF?
>
> **Question 5.2:** Why does the CNCF benefit from maintaining a formal channel (the End User Community) separate from just listening to companies that develop the projects?
>
> **Question 5.3:** What kind of decisions fall under the TOC's scope and not an individual SIG's?

---

## Exercise 6 — Architectural Principles Applied to a Case

1. Take the following scenario: a company has a monolithic application that is updated by editing files directly on the production server, with no infrastructure versioning or deployment pipeline.
2. Rewrite the scenario applying the **immutable infrastructure** principle: how would the update process change?
3. Rewrite the scenario applying the **declarative APIs** principle: instead of running commands step by step to configure the system, how would the desired state be expressed?
4. Propose how to split the monolith into at least two **microservices**, identifying a reasonable responsibility boundary between them.
5. Add a **service mesh** to the resulting design and explain what new problem (not related to business logic) it solves when multiple microservices communicate with each other.

> **Question 6.1:** Why is "editing a configuration file directly on the production server" the opposite of the immutable infrastructure principle?
>
> **Question 6.2:** What concrete advantage does describing the desired state (declarative) have over describing the sequence of commands to reach it (imperative), especially when a step fails midway?
>
> **Question 6.3:** If two microservices need to communicate securely with automatic retries on network failures, which component of the cloud native architecture typically handles that without each microservice having to implement it on its own?

---

<details>
<summary><strong>See answers</strong></summary>

**1.1** — Because "cloud native" is not a single technology but a complete architectural approach. A system can be containerized and still be fragile, hard to scale, or difficult to operate if it does not also adopt microservices (to decouple components), immutable infrastructure (for predictable deployments), and declarative APIs (to manage state reproducibly). Containers are an enabler, not the goal itself.

**1.2** — It violates the **immutable infrastructure** principle. That principle proposes that, when a change is needed, the entire artifact is replaced (a new image, a new deployment) instead of modifying a running component. Doing manual SSH to tweak configuration introduces drift between instances, makes the change non-reproducible, and breaks traceability of which version is actually running.

**2.1** — A **CNCF hosted** project has been formally donated to the foundation, follows its governance (TOC, maturity levels, IP and trademark policies) and receives CNCF support (CI infrastructure, marketing, events). A project that is only **listed** in the landscape is simply part of the cloud native ecosystem recognized by the CNCF as relevant, but maintains its own independent governance and does not go through the sandbox/incubating/graduated process.

**2.2** — Beyond cataloging, the landscape helps an organization compare alternatives within the same category (e.g., different service mesh options), understand how mature and adopted a project is before betting on it, and visualize how pieces fit together within a complete cloud native architecture.

**3.1** — The **Technical Oversight Committee (TOC)**.

**3.2** — You explain that **Sandbox** is the entry stage: they are experimental projects with very variable scope and quality, no guarantees of continuity, and no formal security or governance review. It is not a stage intended for critical production; it is better reserved for proofs of concept or evaluation, and to wait until the project advances to Incubating (or better, Graduated) before depending on it in a sensitive production environment.

**3.3** — **Incubating** indicates that the project has demonstrated real adoption by multiple users in production and a certain level of governance, but still does not meet the most demanding criteria for sustainability, contributor diversity, and security processes. **Graduated** implies it has passed an independent security audit, has well-established governance and a contributor community (not dependent on a single company) and broad, proven adoption — it is the highest confidence level within the CNCF.

**4.1** — Because to observe (log, monitor, trace) a distributed system effectively, you first need that system to be containerized and orchestrated consistently: orchestration gives you a uniform point from which to collect metrics and logs from all components. Instrumenting observability before having that orderly base produces fragmented data that is hard to correlate.

**4.2** — It aims to prevent organizations from jumping directly to advanced tools (e.g., service mesh or complex security policies) without first solving the fundamentals (containerization, CI/CD, basic orchestration). Skipping steps usually creates fragile systems that are hard to debug and have a much steeper adoption curve than necessary.

**5.1** — The **Linux Foundation**.

**5.2** — A **contributor** is anyone who contributes code, documentation, or any other work to the project on an occasional or recurring basis. A **maintainer** additionally has review and approval responsibility for changes, defines the technical direction of the project, and typically has elevated permissions on the repository — it is a trusted role usually earned through sustained contributions over time.

**5.3** — Because companies that develop a project have different incentives from those who operate it day to day in production. The End User Community gives the CNCF a direct source of feedback on real adoption problems, use cases, and priorities, without that feedback being filtered by vendors' commercial interests.

**5.4 (Question 5.3)** — The TOC defines cross-cutting foundation policies: general governance, criteria and process for moving between maturity levels (Sandbox → Incubating → Graduated), acceptance of new projects, and resolution of conflicts between overlapping projects. A SIG, on the other hand, handles technical decisions within a specific area of a particular project (e.g., the design of the storage layer in Kubernetes).

**6.1** — Because immutable infrastructure means that once an artifact (image, VM, configuration) is deployed, it is not modified in place: any change is made by creating a new version of the artifact and replacing the old one. Editing a file directly on the production server creates an instance that no longer matches any versioned artifact, causing drift and loss of reproducibility.

**6.2** — The declarative approach tells the system "this is the state I want," and the system itself (the controller or orchestrator) continuously reconciles reality against that desired state, automatically retrying on partial failures. The imperative approach, on the other hand, if it fails midway through a sequence of commands, can leave the system in an inconsistent intermediate state that must be diagnosed and corrected manually.

**6.3** — A **service mesh**. It handles cross-cutting concerns of inter-service communication (mTLS, retries, load balancing, circuit breaking, traffic observability) through a sidecar proxy, without each microservice having to implement that logic in its own code.

</details>