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
