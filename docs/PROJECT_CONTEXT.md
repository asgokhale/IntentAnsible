# PROJECT CONTEXT — Intent-Driven Ansible Deployment Framework

> Purpose of this file: re-prime a new Claude chat fast when the previous one
> compacts or dies. Paste this + README.md + a fresh codebase dump as the first
> message. Git is the ground truth; this is a convenience memo. If they disagree,
> the code wins.

## What this project is
A data-driven Ansible engine that provisions + configures clusters (Kubernetes
or plain VMs) on Chameleon cloud (OpenStack) or bare metal. You change a
deployment by editing DATA (a spec + pipeline + vars), never by editing
playbooks. It replaces a ~900-line hand-written `playbook_master.yml` whose
step order and host-targeting were baked into the file structure.

## The core design principle (do not violate)
- **Mechanism vs. user data split.** The committed tree holds only mechanism:
  the engine, role logic, and `specs/examples/` templates. Everything with a
  real value the user supplies (usernames, packages, ports, IPs, keys, node
  counts, volume sizes, manifest paths) is USER DATA and lives under
  `mydeployments/<name>/` (gitignored), never in the committed tree.
- Claude ships MECHANISM only. The user owns INTENT (which steps, what order,
  what values).
- A node's type is its `roles:` list (data), NOT a hardcoded master/worker
  distinction. This exists specifically so "1 cluster, 0 masters, N plain VMs"
  is just a different spec, not a code fork. (Old system couldn't express that.)
- `requires:` on a pipeline step declares the user vars it needs; a single
  pre-flight pass reports ALL missing vars at once before anything runs. Roles
  stay pure logic — guards live on the pipeline step, not inside roles.
- `vars:` in a pipeline step carries NAMES of user vars; the framework looks
  them up and passes real values to the role. Same role reusable many times.

## The workflow (how we ship changes)
1. User raises a need (usually "port Play N from old master" or a fix).
2. Claude returns `framework-<thing>.tar.gz` containing ONLY Claude-owned paths
   (see FRAMEWORK_MANIFEST.txt).
3. User runs `./update_framework.sh <tarball>` — refuses any tarball touching
   `mydeployments/` or `inv/`, shows a diff, asks before copying.
4. User: `git status` → `git add -A` → `git commit` → `git push`.
5. `mydeployments/` is never in a tarball and never touched.

## How the engine runs
- `deploy.sh` = two ansible-playbook calls: generate_runner.yml (compiles the
  active pipeline → run_deployment.yml, one play per step) then run it. Can't be
  one call: import_playbook resolves at parse time.
- `--deployment <dir>` loads spec.yml, pipeline.yml, then vars/*.yml (alpha).
- Provision writes a self-contained inventory to inv/<run>/hosts.yml: each host
  carries ansible_host, key file, and ProxyCommand-through-bastion (bastion
  connects direct). Ansible NEVER reads ~/.ssh/config (uses -F /dev/null). This
  solved the old pain of hand-editing ~/.ssh/config + known_hosts on every IP
  change.
- Bastion = a node group with provision_order: 0 + floating_ip. Phase 0 comes
  up and is reachable before phase 1 (private nodes reached through it).

## Current deployment: "project name" (on cloud platform)
Single cluster, single control-plane (PG-M1), 10 med workers (PG-WM*), 8 xlarge
workers (PG-WX*), 1 registry (PG-REG1), 1 bastion (PG-BASTION, FIP
<floating IP redacted>). All nodes on ONE network (underlying network) — so
`default_ipv4.address` resolves to the single private NIC (multi-NIC address
ambiguity is NOT a live risk here). firewalld is OFF on the nodes.

## STATUS
### Working end-to-end on the Chameleon VM path (confirmed by user)
- Provisioning (VM create, bastion FIP, phased ordering, inventory capture)
- configure pipeline: copy_files, apt_upgrade/clean, reboot (others then
  bastion), apt_install, pip_install, docker_install, k8s_install
- docker_update_config: volume_provision + volume_mount + docker_data_root +
  registry_start + registry_docker_trust (registry volume = DockerImages1,
  200GB, /mnt/dockervol; registry container name <some name given to the
  container>) 
- k8s_cluster through cni_flannel + k8s_verify (FLANNEL WORKS, cluster forms)

### Being tested next (NEW work — NO oracle; old system never did NFS)
- Full touchstone workload over NFS-backed PVs:
  volume_provision + volume_mount (SECOND volume, on the MASTER, separate from
  the registry's docker volume) → nfs_server (master) → nfs_client (workers) →
  k8s_nfs_storage (PV+PVC from nfs_volumes) → k8s_apply_manifests (configmap +
  templated deployments/services).
- These roles ALREADY SHIPPED and are applied to the user's git repo:
  nfs_server, nfs_client, k8s_nfs_storage, k8s_apply_manifests, plus
  examples/k8s_manifests/ (EXAMPLE_vars.yml, EXAMPLE_pipeline_snippet.yml,
  touchstone *.yaml.j2). This is a WIRE + RUN step (add app_deploy to the real
  project pipeline + set vars), NOT a build step.

### Broader goal behind the NFS work
Get ALL FOUR CNIs (flannel, canal, calico, cilium) working on BOTH Chameleon
VMs and bare metal. Priority order: Chameleon VMs first; all four fully working.
Flannel + canal known-good historically; calico + cilium UNVERIFIED on VMs.

## KNOWN ISSUES / OPEN DECISIONS (from comparing new roles vs. old oracle)
1. **calico encapsulation**: old working playbook matched
   `encapsulation: VXLANCrossSubnet` and set it from `calico.encap`. New
   cni_calico defaults to "VXLAN" with a looser `\w+` regex. NEED old calico
   vars (calico.encap, calico.version, K8s.pod_cidr) to set faithful defaults.
   Most likely cause of "calico pods can't cross nodes on VMs."
2. **CNI firewall rules NOT ported** into a role (old
   playbook_set_cni_firewalld_rules.yml opened calico BGP/Typha/Wireguard +
   cali* interfaces, cilium 4240/4244/4245/4250/6081/9878/9879/51871+Geneve).
   Not urgent while firewalld is OFF on this project, but could be REQUIRED for
   calico/cilium 
   if firewalld is ever on.
3. **cilium incomplete**: new cni_cilium helm install passes no values. With
   --skip-phases=addon/kube-proxy (correctly set in k8s_init), cilium needs
   k8sServiceHost/k8sServicePort or it won't come up. Old cilium was also
   incomplete ("never verified historically") — so this is NEW work, not a port.
4. **k8s_nfs_storage discovers NFS server IP from k8s_control_plane group** —
   correct for single-master (master IS the NFS server). Would need a
   group parameter if the export ever moves off the master. OPEN: parameterize
   or leave hardwired?
5. **No taint role**: old system untainted the master so it could run pods. New
   framework has none. For this project (18 dedicated workers) the master
   SHOULD stay tainted (serves NFS, workloads land on workers). Confirm no
   pods-on-master expectation.
6. **/etc/hosts step (old Play 12) NOT ported** — flannel forms without it, so
   apparently not needed. Revisit only if a CNI proves otherwise.
7. **Post-CNI runtime restart (old Plays 13E/14E/14F) NOT ported** — flannel
   verifies without it. Revisit for calico/cilium if pods get stuck.

## Deferred (explicitly NOT urgent)
OVS bridges + VxLAN mesh, Kafka, Protobuf, Mininet, nginx ingress, per-team
namespaces/dirs, multi-cluster CIDR slicing. Roles exist in old system as an
oracle when we get to them.

## Run-path reminders for the NFS test
- app_deploy steps that DISCOVER IPs (k8s_nfs_storage, k8s_apply_manifests) must
  run with `-i inv/<projname>/hosts.yml` (private IPs), NOT local.ini.
- manifest_src_dir is a path on the CONTROL node (k8s_apply_manifests globs
  *.yaml.j2 there via delegate_to: localhost), not on the master.
- Consistency the framework CAN'T check: nfs_volumes subpaths ↔ PVC names the
  deployments claim ↔ container mountPaths. Verified consistent for touchstone:
  touchstone-db → touchstone-db-pvc mounted at /server/flask/database, etc.
- configmap (metric-definitions-config) is created before manifests are applied,
  so the streamlit subPath mount has it in time — as long as
  metric_definitions.json exists where configmap_files points.

## PAPER — Middleware 2026 Industry Track

### Meta
- Venue: ACM Middleware 2026, Industry Track (6 pages; refs + Limitations
  likely excluded — VERIFY on official CFP when posted; some length details
  came from cross-venue snippets, not confirmed Middleware CFP).
- Repo cited in paper: https://github.com/asgokhale/IntentAnsible
  (private now; public at submission; anonymized for review).
- LaTeX skeleton lives at: paper.tex (acmart sigconf, anonymous+review).
  Numbers are \newcommand placeholders at top of that file — fill once.

### Framing (decided)
- Blend of systems/design + experience report, weighted toward design.
- Predominantly quantitative results, some qualitative.

### Thesis (verbatim)
The high-value role of generative AI in operations is not to regenerate the
substrate but to capture operator intent and compile it into faithful,
deterministic orchestration of the existing, unmodified substrate — with
generation confined to design time and kept off the production path.

### Named contribution (approved)
An intent-compilation layer that re-expresses operator intent as deterministic
orchestration over unmodified, community-maintained middleware, keeping
generative AI at design time and off the production path.

### Three pillars
1. Investment preservation — middleware/OS is decades of hardened community
   investment; won't/shouldn't be regenerated. Framework adds ZERO lines to it.
2. Intent over generation — spec+pipeline+vars compiles deterministically; human
   states WHAT, fixed engine handles HOW (mechanism-vs-data split is the spine).
3. LLM judiciously, design-time not run-time — authoring cost amortizes over
   unlimited deterministic re-runs; runtime path has ZERO inference.

### Argument cautions (for review survival)
- Cost claim must be framed as "zero runtime inference / one-time authoring
  amortized," NOT "LLMs are cheap." Lead with determinism + reproducibility;
  cost follows.
- Do NOT claim the framework makes Kubernetes faster. Contribution is the
  intent-compilation layer + its guarantees. Metrics point at expressiveness
  and determinism, not substrate performance.
- Be candid on CNI maturity (flannel verified; canal/calico/cilium in progress).
  Candor strengthens an industry paper.

### Section map (see paper.tex for full scaffold)
1 Intro · 2 Motivation (uses AutomationNeeds.txt as field evidence) ·
3 Background (old monolith) · 4 Design (mechanism/data split, roles-list,
pipeline-as-data, self-contained conn, LLM-at-design-time + Fig 1) ·
5 Experience+Results (Tables 1–3) · 6 Related Work · 7 Conclusion · Limitations.

### Results tables — data to gather
- Table 1 (migration/expressiveness): old master+tasks/ LOC; engine mechanism
  LOC; # distinct deployments expressible from one engine (pangea, 4-VM
  zero-master, bare-metal, …); manual steps per redeploy old→new (→0).
  NOTE: Tables 1 & 2 counts are extractable from the codebase dumps already
  shared — can be computed before the NFS run finishes.
- Table 2 (determinism/LLM): runtime LLM invocations = 0; # roles ported at
  design time; runtime = 2 ansible-playbook calls; re-run VM duplication = 0.
- Table 3 (Chameleon bring-up, pangea): wall-clock per phase; flannel verified;
  NFS/touchstone row comes from the CURRENT test run — capture timestamps.

### Related work to position against
IaC/GitOps (Terraform, Helm, Ansible, Kustomize) — declarative but
human-owned, no intent-compilation, no preservation stance. LLM code-gen
(Claude Code, Copilot) — generate artifacts humans then own/debug. We sit
between: deterministic like IaC, intent-capturing like LLM tools, neither
regenerating substrate nor putting inference on the hot path.

### Open paper TODOs
- [ ] Compute Table 1 & 2 counts from the dumps.
- [ ] Capture Table 3 wall-clock + NFS/touchstone result from current run.
- [ ] Verify Middleware 2026 industry CFP: page accounting + Limitations rule.
- [ ] Draft Figure 1 (design-time-dashed vs. runtime-solid).
- [ ] Write abstract last.

## PAPER — Generality section (TAO/CIAO)

Scope decided: DESIGN-LEVEL gesture only, "doable + how," ~1 page. NOT a
verified second system. Goal: defuse "is this just Kubernetes?".

Three-tier claim (honest, decreasing verification / increasing reach):
1. Verified: K8s on Chameleon (primary evidence).
2. Transfers unchanged to TAO: build-as-role, topology+ordered service
   bring-up (provision_order for Naming Svc / DAnCE ExecMgr+NodeManagers),
   investment-preservation applies even more forcefully.
3. Domain-specific extension for CIAO component assembly: our SAME compilation
   pattern one layer up — intent -> generates a D&C .cdp plan -> hands off to
   UNMODIFIED DAnCE (do NOT replace D&C; emit its native artifact, exactly as
   pipeline -> run_deployment.yml -> unmodified Ansible).

Key honesty boundaries (keep in paper): bring-up not runtime lifecycle;
not claiming general/validated .cdp generation — one small correct
source->sink connection shown end-to-end as existence-of-path.

Section lives in paper.tex as \section{Generality Beyond Kubernetes} with
Fig (intent sketch -> .cdp fragment). Slots marked <slot:...> for AG to fill
with TAO/D&C specifics (service names, MPC/build details, actual .cdp XML).
Worked example = highest ROI, zero cluster time.

TODO: AG fills the intent->.cdp worked example (2 components, 1 connection).

## Added support to override default ansible.cfg that was causing issues

Framework now ships its own ansible.cfg, selected via ANSIBLE_CONFIG in
deploy.sh, bypassing ~/.ansible.cfg. Disables host_key_checking and known_hosts
consultation — structurally closes AutomationNeeds #1 (stale bastion host
key). User override via ANSIBLE_CONFIG_OVERRIDE env var. Root cause of the
multi-turn connection saga was a stale known_hosts entry after bastion
recreation, not ControlMaster. 

## RESOLVED + VALIDATED: containerd root relocation for build-heavy nodes
- CORRECTION to earlier note: overlayfs storage driver does NOT mean
  data-root relocation suffices. Modern Docker's default builder (BuildKit)
  stores build layers under CONTAINERD's root (/var/lib/containerd),
  regardless of docker's Storage Driver. So build-heavy nodes need BOTH
  docker data-root AND containerd root relocated onto the volume.
- Fix: cri_config gained optional containerd_root_path (relocates containerd
  `root` in config.toml after regeneration). Set per-node via pipeline vars.
- Validated on PG-NODE1: docker compose build drove /mnt/dockervol/containerd
  to 3G+ while root disk stayed flat at 9.1G. Confirmed working.
- Also fixed: cri_config restarts containerd, which left docker inactive on
  docker nodes -> added docker-restart-if-present (guarded by dockerd binary
  presence) so docker comes back automatically. k8s-only nodes skip it.
- Paper lesson: relocating container storage requires moving every storage
  sink, and which sinks exist depends on the builder -- BuildKit uses
  containerd's store even when the reported storage driver is overlayfs.
  
  
