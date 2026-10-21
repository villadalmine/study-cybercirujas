# Changelog

## [0.5.0](https://github.com/villadalmine/study-cybercirujas/compare/v0.4.0...v0.5.0) (2026-10-21)


### Features

* **catalog:** freeze the CKA and CKAD v1.37 syllabi, hash the vendor document, reference v1.37 as upstream ([#194](https://github.com/villadalmine/study-cybercirujas/issues/194)) ([5799f2c](https://github.com/villadalmine/study-cybercirujas/commit/5799f2cde8b76e9095bc1351fed8e53a529b6493))
* **catalog:** switch CKA and CKAD to Kubernetes v1.37 ([#203](https://github.com/villadalmine/study-cybercirujas/issues/203)) ([fefffcb](https://github.com/villadalmine/study-cybercirujas/commit/fefffcb34f1d5863e4966958ec842c00956fe5a1))
* **cka:** bump the Kubernetes version in the CKA labs to 1.37, by script ([#213](https://github.com/villadalmine/study-cybercirujas/issues/213)) ([db37874](https://github.com/villadalmine/study-cybercirujas/commit/db37874ee2a1bf1c4958a8276885becf87180332))
* **cka:** bump the Kubernetes version in the CKA material to 1.37, by script ([#202](https://github.com/villadalmine/study-cybercirujas/issues/202)) ([0957ca7](https://github.com/villadalmine/study-cybercirujas/commit/0957ca7141391cae718f4d734b052be359ecf294))
* **ckad:** bump the Kubernetes version in the CKAD labs to 1.37, by script ([#214](https://github.com/villadalmine/study-cybercirujas/issues/214)) ([a2e6739](https://github.com/villadalmine/study-cybercirujas/commit/a2e67397f133bfce187e1ee95ee7a2bf653f761b))
* **labs:** the k8s runner image on Kubernetes 1.37 (kubectl v1.37.1, kindest/node v1.37.0) ([#204](https://github.com/villadalmine/study-cybercirujas/issues/204)) ([ce2ae28](https://github.com/villadalmine/study-cybercirujas/commit/ce2ae28cd8f4a150e31fe84e51a5b334700da051))
* **scripts:** curriculum_diff.py guard, an upgrade PR changes only planned files, sections and lines ([#193](https://github.com/villadalmine/study-cybercirujas/issues/193)) ([e296a7f](https://github.com/villadalmine/study-cybercirujas/commit/e296a7ff926e977b25877e5ef61bbd944a9141fa))
* **scripts:** upgrade_versions.py, the scripted version bump with its pins ([#201](https://github.com/villadalmine/study-cybercirujas/issues/201)) ([0db1788](https://github.com/villadalmine/study-cybercirujas/commit/0db1788a8182324a0175b82ef2878a4cde1d6170))


### Bug Fixes

* **tracker:** sync writes the upstream block only while the published version is ahead ([#219](https://github.com/villadalmine/study-cybercirujas/issues/219)) ([849a4ad](https://github.com/villadalmine/study-cybercirujas/commit/849a4adb28fecc9b2ca2e42b97c62605b40e55f4))


### Documentation

* **audit:** publish the self-audit rubric and a comparison script ([#212](https://github.com/villadalmine/study-cybercirujas/issues/212)) ([1f5bfd4](https://github.com/villadalmine/study-cybercirujas/commit/1f5bfd442ef5794e224db7fa377699d5ccf606e6))
* **upgrades:** the CKA & CKAD v1.37 upgrade plan, generated, with its proof and efficiency ([#195](https://github.com/villadalmine/study-cybercirujas/issues/195)) ([2f87e92](https://github.com/villadalmine/study-cybercirujas/commit/2f87e9220c03380403c180c1c7859931697b9b24))


### Internals

* **release:** human release notes from NEXT.md, generated Thanks, reset PR ([#205](https://github.com/villadalmine/study-cybercirujas/issues/205)) ([980f054](https://github.com/villadalmine/study-cybercirujas/commit/980f05494dfa2b2d3967f52723d0a6e68de27bc7))

## [0.4.0](https://github.com/villadalmine/study-cybercirujas/compare/v0.3.0...v0.4.0) (2026-10-20)


### Features

* **labs:** a goals field in lab.yaml, shown in the Killercoda intro and Fix step ([#198](https://github.com/villadalmine/study-cybercirujas/issues/198)) ([06c1947](https://github.com/villadalmine/study-cybercirujas/commit/06c19473cb4ac82d9f90ebd18789530ffc6eece8))
* **labs:** declare risky labs in lab.yaml and confirm before lab up ([#184](https://github.com/villadalmine/study-cybercirujas/issues/184)) ([8ba6749](https://github.com/villadalmine/study-cybercirujas/commit/8ba6749cc5c9c20bf0e07f3d661b1babbbc8e0e1))
* **labs:** Killercoda banner says who tested the scenario there and when ([#153](https://github.com/villadalmine/study-cybercirujas/issues/153)) ([3a9ef06](https://github.com/villadalmine/study-cybercirujas/commit/3a9ef064ab980d5338472b39eb53f73cb08abfc7))
* **scripts:** curriculum_diff.py diff, old vs new syllabus as machine-readable JSON ([#191](https://github.com/villadalmine/study-cybercirujas/issues/191)) ([121ef81](https://github.com/villadalmine/study-cybercirujas/commit/121ef815902cdeba411ee31a31fd8409b802f0b8))
* **scripts:** curriculum_diff.py extract, a deterministic syllabus snapshot from the CNCF PDFs ([#190](https://github.com/villadalmine/study-cybercirujas/issues/190)) ([f845475](https://github.com/villadalmine/study-cybercirujas/commit/f845475ce48577fedb401fd0a90ab6e28aa37170))
* **scripts:** curriculum_diff.py plan, one class per topic and the sections and lines in scope ([#192](https://github.com/villadalmine/study-cybercirujas/issues/192)) ([5f97e84](https://github.com/villadalmine/study-cybercirujas/commit/5f97e84b62612983c1d6ef4effbc8fda9a671030))


### Bug Fixes

* **api:** 404 responses no longer include server file paths ([#177](https://github.com/villadalmine/study-cybercirujas/issues/177)) ([63ec10d](https://github.com/villadalmine/study-cybercirujas/commit/63ec10d1a494b5dd9db741c8e09be3fb644c0ea9))
* **ci:** release-please labels, manual dispatch, drop version.txt, narrow App token ([#147](https://github.com/villadalmine/study-cybercirujas/issues/147)) ([2422093](https://github.com/villadalmine/study-cybercirujas/commit/2422093b5d4fa8a56d1b63e44cd149a514acc2a5))
* **deploy:** require a real TEACH_SECRET when rendering the Helm chart ([#175](https://github.com/villadalmine/study-cybercirujas/issues/175)) ([7400708](https://github.com/villadalmine/study-cybercirujas/commit/7400708796d1945ed787572cb575625ac50b7e3c))
* **deploy:** run the app image as non-root, pin its base by digest and keep .env out of the build ([#176](https://github.com/villadalmine/study-cybercirujas/issues/176)) ([63c0149](https://github.com/villadalmine/study-cybercirujas/commit/63c014915c87e07e9744b2daf8e1975a9eb6334d))
* **killercoda:** pin the measured environment (kubeadm 1.36.1, Cilium, containerd 2.2.1, local-path) ([#162](https://github.com/villadalmine/study-cybercirujas/issues/162)) ([2440c3e](https://github.com/villadalmine/study-cybercirujas/commit/2440c3e3dde1c1364964320e70c70bec68a1aa67))
* **killercoda:** validate versions and URLs from killercoda_envs.yaml against an allowlist ([#174](https://github.com/villadalmine/study-cybercirujas/issues/174)) ([998c52e](https://github.com/villadalmine/study-cybercirujas/commit/998c52e8b3f306e2f332bbfd5ad2f19e44766b6b))
* **labs:** a date no Killercoda schedule row covers is a clear error, not a bare StopIteration ([#158](https://github.com/villadalmine/study-cybercirujas/issues/158)) ([61965e1](https://github.com/villadalmine/study-cybercirujas/commit/61965e1500c5effe4173750245a58da0567ccc6a))
* **labs:** build the runner image locally and pin its base images by digest ([#171](https://github.com/villadalmine/study-cybercirujas/issues/171)) ([a674ab1](https://github.com/villadalmine/study-cybercirujas/commit/a674ab124bc7599a0f92576ea3eeba0922f4dcc6))
* **labs:** ckad 4.4 verify exits 1 while the lab is broken, and add a fix verb ([#149](https://github.com/villadalmine/study-cybercirujas/issues/149)) ([84e9352](https://github.com/villadalmine/study-cybercirujas/commit/84e935232bada3faa3075de2c4ba4ec6a506ac92))
* **labs:** ckad 5.2 check exits 1 while the lab is broken, and add a fix verb ([#152](https://github.com/villadalmine/study-cybercirujas/issues/152)) ([cc98534](https://github.com/villadalmine/study-cybercirujas/commit/cc985343882e14330e2f27a76a4878f21f2c10dc))
* **labs:** cks 5.3 verify exits 1 while the lab is broken, and add a fix verb ([#156](https://github.com/villadalmine/study-cybercirujas/issues/156)) ([637f69d](https://github.com/villadalmine/study-cybercirujas/commit/637f69d2183ee7900dfd0554a35f29dbcddaafd7))
* **labs:** cnpa 2.1 verify propagates its exit status, and add a fix verb ([#163](https://github.com/villadalmine/study-cybercirujas/issues/163)) ([48f2077](https://github.com/villadalmine/study-cybercirujas/commit/48f20774967d1be10ea8cd1c52bb4f968420fd78))
* **labs:** cnpa 2.5 gets real verify, fix and cleanup verbs (verify was a no-op that exited 0) ([#165](https://github.com/villadalmine/study-cybercirujas/issues/165)) ([2225228](https://github.com/villadalmine/study-cybercirujas/commit/22252281b44b9435b154308bbb325fe7121d7bba))
* **labs:** cnpa 6.1 gets real verify, fix and cleanup verbs (verify was a no-op that exited 0) ([#168](https://github.com/villadalmine/study-cybercirujas/issues/168)) ([635617d](https://github.com/villadalmine/study-cybercirujas/commit/635617d1f2d6f868299b1f4bb2956bf3c7502c8f))
* **labs:** cnpe 2.3 verify exits 1 while the Service is down, and add a fix verb ([#164](https://github.com/villadalmine/study-cybercirujas/issues/164)) ([4018555](https://github.com/villadalmine/study-cybercirujas/commit/401855520a924587a5fc194f18d89e9b2767c069))
* **labs:** kcna 2.3 verify watches for restarts so it fails while the probe is broken, and add a fix verb ([#161](https://github.com/villadalmine/study-cybercirujas/issues/161)) ([6b7ef01](https://github.com/villadalmine/study-cybercirujas/commit/6b7ef01af03cc51d010a2c8f37ec06faf2fee050))
* **labs:** kubectl labs no longer run their script on the host by default ([#172](https://github.com/villadalmine/study-cybercirujas/issues/172)) ([5b84d8d](https://github.com/villadalmine/study-cybercirujas/commit/5b84d8d79c802a8e20a521ea37fdfedb2069b107))
* **labs:** lpic-2 200.1 tells the student its two goals ([#199](https://github.com/villadalmine/study-cybercirujas/issues/199)) ([0b82048](https://github.com/villadalmine/study-cybercirujas/commit/0b82048e1fc459caffe5aa4b472f69f8760f97f2))
* **labs:** otca 2.4 verify exits 1 while the logs signal is dead, and add fix and cleanup verbs ([#169](https://github.com/villadalmine/study-cybercirujas/issues/169)) ([7ad2be0](https://github.com/villadalmine/study-cybercirujas/commit/7ad2be0f5b9d45ebcd46e27aaf9b15c6df272eb8))
* **web:** escape lab summaries and catalog text in the web UI ([#170](https://github.com/villadalmine/study-cybercirujas/issues/170)) ([7464613](https://github.com/villadalmine/study-cybercirujas/commit/7464613505747e8bcf4af05073abc3dadd2f8a98))


### Documentation

* add a FAQ on how the ecosystem works, and keep it current ([#188](https://github.com/villadalmine/study-cybercirujas/issues/188)) ([3be8482](https://github.com/villadalmine/study-cybercirujas/commit/3be848206643fc3ceb92ef3fcc2c703ab53a83b5))
* credit project contributors ([#146](https://github.com/villadalmine/study-cybercirujas/issues/146)) ([c27ed7e](https://github.com/villadalmine/study-cybercirujas/commit/c27ed7e8e644d3ae59a655b242a10f62d1e269f2))
* **deploy:** add docs/DEPLOY.md, a self-contained Helm operator guide, and make site-tag ([#181](https://github.com/villadalmine/study-cybercirujas/issues/181)) ([9676e5f](https://github.com/villadalmine/study-cybercirujas/commit/9676e5f1f22a60981009f41a170d125194c1d314))
* **graph:** describe the graph rule as it runs now (main refreshes, a PR warns) ([#157](https://github.com/villadalmine/study-cybercirujas/issues/157)) ([e7a619a](https://github.com/villadalmine/study-cybercirujas/commit/e7a619ab2ac40b608dd01fd3bd134adde1ec8f9b))


### Internals

* **api:** cache catalog.load(); per-client rate limit shipped off in the chart ([#173](https://github.com/villadalmine/study-cybercirujas/issues/173)) ([45b601c](https://github.com/villadalmine/study-cybercirujas/commit/45b601c69362a3308b9559b677f19b1e8385a705))
* **api:** remove the unused require_subscriber dependency ([#182](https://github.com/villadalmine/study-cybercirujas/issues/182)) ([8040a8c](https://github.com/villadalmine/study-cybercirujas/commit/8040a8cef938f9e9309db0c838fb5d11a7d727f5))
* **deploy:** smoke-test the Helm chart on kind on every change under deploy/ ([#183](https://github.com/villadalmine/study-cybercirujas/issues/183)) ([2423a3d](https://github.com/villadalmine/study-cybercirujas/commit/2423a3df68e76d1796c32ecfa67254e05ade59ed))
* **docker:** publish the image for linux/amd64 and linux/arm64, with actions pinned by SHA ([#185](https://github.com/villadalmine/study-cybercirujas/issues/185)) ([b1a8a06](https://github.com/villadalmine/study-cybercirujas/commit/b1a8a060126b628eb87dcf269db1fc6263d118df))
* keep release milestones in step with merged PRs, closed issues and releases ([#189](https://github.com/villadalmine/study-cybercirujas/issues/189)) ([a5f6849](https://github.com/villadalmine/study-cybercirujas/commit/a5f68497e2dd86c68f0e7854a151c4c08f1a3712))
* **killercoda:** pass github.base_ref through env, not into the script text ([#159](https://github.com/villadalmine/study-cybercirujas/issues/159)) ([9cfce48](https://github.com/villadalmine/study-cybercirujas/commit/9cfce48a600e97b8eca95947d9a997f21fafadf4))
* pin every GitHub Action to a full commit SHA ([#179](https://github.com/villadalmine/study-cybercirujas/issues/179)) ([cb454ea](https://github.com/villadalmine/study-cybercirujas/commit/cb454ea6fc75a16913d67862dc72470960fca12e))
* **release:** release-please runs only on main, also when dispatched by hand ([#155](https://github.com/villadalmine/study-cybercirujas/issues/155)) ([511e451](https://github.com/villadalmine/study-cybercirujas/commit/511e4519cc184707360d451a2f6d51f0ebb1ce2f))

## [0.3.0](https://github.com/villadalmine/study-cybercirujas/compare/v0.2.0...v0.3.0) (2026-10-16)


### Features

* **github:** issue forms open with triage:needed, new idea form, contact links ([#137](https://github.com/villadalmine/study-cybercirujas/issues/137)) ([0b5a28b](https://github.com/villadalmine/study-cybercirujas/commit/0b5a28b081a7ef216f02a47272222c1f760a1e17))


### Internals

* **release:** release-please opens a Release PR; CHANGELOG.md moves to docs/HISTORY.md ([#144](https://github.com/villadalmine/study-cybercirujas/issues/144)) ([72b6727](https://github.com/villadalmine/study-cybercirujas/commit/72b6727654e0848f31fcd5f36305d3261f93c0dc))
* **triage:** triage:needed for outside issues and PRs, stale in debug-only, response times ([#138](https://github.com/villadalmine/study-cybercirujas/issues/138)) ([6dc1b88](https://github.com/villadalmine/study-cybercirujas/commit/6dc1b88d461fb520fa666dd2dea2699a5fc8f21f))

## Changelog

What changed in each release of study-cybercirujas, one section per version. This file is written by
[release-please](https://github.com/googleapis/release-please) from the Conventional Commit titles of the
merged pull requests and is never edited by hand: see [CONTRIBUTING.md](CONTRIBUTING.md#releases).

The dated record from before the first release (up to 2026-10-16) is frozen in
[docs/HISTORY.md](docs/HISTORY.md).
