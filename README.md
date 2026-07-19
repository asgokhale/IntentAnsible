# Generic Ansible deployment framework

Provision and configure clusters (Kubernetes or otherwise) on Chameleon cloud
or bare metal, driven entirely by a per-environment **spec** file. You change a
deployment by editing data, not by editing playbooks.

> Status: structural logic is tested on localhost; real-cloud provisioning has
> been partially exercised on Chameleon (VM creation + bastion floating IP
> confirmed working). The full provision->configure path is not yet proven
> end-to-end. See "What is and isn't tested" before trusting it on a live run.


## Core idea

- A **spec** (one per environment) describes its nodes (`node_groups`), how
  Ansible reaches them (`deploy_conn`), and topology. A node's type is its
  `roles` list (data) -- not a hard-coded master/worker distinction.
- A **pipeline** is an ordered list of steps; each step runs a role against
  hosts selected by role (e.g. `role:k8s_worker`) or the `all_provisioned`
  group. Your real pipeline is YOUR data -- it lives in `mydeployments/`
  (gitignored), copied from a shipped example. It is not framework.
- `deploy.sh` compiles the active pipeline into one play per step and runs it.
  You never edit the generated runner or the playbooks -- only the spec.


## Layout

    deploy.sh                     run this; --deployment <dir> loads a deployment
    generate_runner.yml           compiles pipeline -> run_deployment.yml
    run_deployment.yml            GENERATED each run (one play per step); do not edit
    group_vars/all/               shared framework vars (currently none; user data
                                    lives per-deployment, see below)
    roles/                        the actual logic (one role per former child playbook)
    tasks/                        spec validation + inventory building
    templates/                    generated-runner + generated-inventory templates
    specs/examples/               TEMPLATES (overwritten on update)
      example-deployment/            a COMPLETE example deployment to copy:
        spec.yml                      nodes, connection, topology
        pipeline.yml                  ordered steps
        vars/                         per-role user data
          control.yml                   local_user, remote_cloud_user
          packages.yml                  apt_packages
          firewall.yml                  firewall_rules
    mydeployments/                YOUR deployments (gitignored, never touched):
      <name>/                       one dir per deployment, mirroring the sample
        spec.yml  pipeline.yml  vars/*.yml
    inv/                          generated inventories (ansible_host etc.)
    local.ini                     local inventory: the control node (localhost)
    FRAMEWORK_MANIFEST.txt        which files are framework vs yours
    update_framework.sh           apply a framework update without touching your data

Principle: **anything with a real value you supply -- usernames, packages,
ports, IPs, keys, node counts -- is USER DATA and lives under
`mydeployments/<name>/`, never in the committed tree.** The committed tree holds
only mechanism (engine, role logic) and `specs/examples/` templates.


## Quick start

    # one-time: create your deployment from the sample, then edit it
    git init && git add -A && git commit -m "baseline"
    cp -r specs/examples/example-deployment mydeployments/foo
    #   edit mydeployments/foo/spec.yml      (bastion IP, keys, lease IDs, networks)
    #   edit mydeployments/foo/pipeline.yml  (your step order)
    #   edit mydeployments/foo/vars/*.yml    (control user, packages, firewall ports)

    # provision only (first run): create VMs, write inventory, then STOP
    ./deploy.sh --deployment mydeployments/foo -i local.ini \
        -e active_pipeline=provision_only -e inventory_out_dir=inv/foo

    #   -> inspect inv/foo/hosts.yml: confirm captured IPs are the private
    #      addresses your configure steps expect.

    # configure later (reads the generated inventory; no cloud query)
    ./deploy.sh --deployment mydeployments/foo -i inv/foo/hosts.yml \
        -e active_pipeline=configure

    # or, once trusted: provision + configure in one go
    ./deploy.sh --deployment mydeployments/foo -i local.ini \
        -e active_pipeline=full

`--deployment <dir>` loads, in order: `spec.yml`, `pipeline.yml`, then
`vars/*.yml` (alphabetical). Later files override earlier. Power users can skip
`--deployment` and pass explicit `-e @<file>` flags instead (or mix both).

Notes:
- Everything under your deployment dir is YOUR data (gitignored). The committed
  `specs/examples/example-deployment/` is the template you copied from.
- Run from inside your OpenStack venv (the openstacksdk must match the
  openstack.cloud collection, or server creation fails with obscure errors).
- `-i local.ini` points Ansible at the local control node for provisioning
  (the VMs don't exist yet). The CONFIGURE step instead uses the generated
  `inv/<run>/hosts.yml`.
- `deploy.sh` is two ansible-playbook calls (generate, then run). They can't be
  one command: import_playbook resolves at parse time, so a runner generated
  mid-run can't be imported in the same run.
- Missing a required var (packages, firewall ports)? The run fails early with a
  message telling you exactly which file to copy from the sample.

### Re-running is safe (resume)
Re-running provisioning does NOT duplicate VMs. Creation uses openstack
`state: present`, idempotent on name: existing nodes are reused, missing ones
created -- so a failed or partial run just RESUMES on re-run. You need not
delete anything first. Each run prints a pre-flight summary:

    WILL CREATE: [...nodes that don't exist yet...]
    ALREADY EXIST (reuse): [...nodes already present...]

Matching is by NAME only: if a VM exists but you changed its flavor/image in the
spec, the existing one is left as-is. To replace specific nodes, force-recreate
(delete + remake) them, leaving everything else reused:

    ./deploy.sh --deployment mydeployments/foo -i local.ini \
        -e active_pipeline=provision_only \
        -e 'force_recreate=["PG-WM3","PG-M1"]'


## Writing a spec

A node group is CLOUD (VMs created, IPs discovered) or BARE-METAL (machines
already exist, IPs supplied):

    node_groups:
      - name: workers              # CLOUD
        count: 48
        roles: [k8s_worker]        # -> joins the k8s_worker group
        flavor: <lease-id>         # Chameleon reservation lease id
        key: S26_CLUSTER           # OpenStack KEYPAIR NAME (for key_name:)
        networks: [net1, net2, net3, net4]
        security_groups: [default, ENABLE_SSH]
        name_pattern: "NW-C{cluster}-W{role_i}"
        # optional: ssh_key_file: ~/.ssh/other.pem  (local .pem override)
        # optional: shard_by: none  (flat numbering instead of per-cluster)

      - name: lab                  # BARE METAL
        roles: [k8s_control_plane]
        static_hosts:
          - { name: lab-cp1, ip: 192.168.50.11 }

Key points:
- `count` + `name_pattern` = cloud; `static_hosts` = bare metal.
- Workers spread across clusters round-robin: `count: 48`, `clusters: 4` -> 12
  per cluster. Use a multiple of `clusters` for an even split.
- Two groups can share a role (e.g. m1.medium + m1.xlarge workers both
  `roles: [k8s_worker]`) -- give them DISTINCT name_patterns so names don't
  collide; both land in the same `k8s_worker` group. Add a second tag (e.g.
  `roles: [k8s_worker, k8s_xlarge]`) only if some step must target just one kind.
- `key` (OpenStack keypair NAME) and the SSH key FILE are different. The SSH
  file defaults from `deploy_conn.default_node_key`, overridable per group with
  `ssh_key_file`. (The bastion auto-defaults its SSH file from
  `deploy_conn.bastion.key` -- see below.)
- `role_i` = a node's index WITHIN its group, per cluster (resets per group).

### The bastion node group
The bastion is just a node group with two extra fields:

    - name: bastion
      count: 1
      roles: [bastion]
      provision_order: 0             # created + reachable BEFORE all others
      floating_ip: 129.114.26.64     # claims THIS pre-allocated public IP
      key: example-bastion-keypair             # openstack keypair NAME
      networks: [example-net]
      security_groups: [default, ENABLE_SSH]
      name_pattern: "PG-BASTION"
      shard_by: none

How it works:
- `provision_order` groups nodes into phases; phase 0 is fully created AND
  reachable before phase 1, so the bastion is up before the private nodes that
  depend on it. Default order is 1, so other groups need no change.
- `floating_ip`: only nodes that set it get a public IP (everyone else stays
  private, auto_ip off). `reuse_ips` claims a pre-existing floating IP rather
  than allocating a new one.
- The generated inventory reaches the BASTION directly on its floating IP with
  NO proxy; every other host jumps THROUGH the bastion. This is automatic from
  membership in the `bastion` group.
- The bastion's SSH key auto-defaults from `deploy_conn.bastion.key`, so you
  don't set `ssh_key_file` on it. `deploy_conn.bastion.host` must equal the
  bastion's `floating_ip` (private nodes' proxy uses `deploy_conn.bastion.host`).


## Declaring required inputs (`requires:`)

A pipeline step can declare the user vars it needs:

    - { step: apt_install, target: "role:k8s_worker", requires: [apt_packages] }
    - { step: firewall,    target: "role:k8s_worker", requires: [firewall_rules] }

Before anything runs, a single pre-flight pass checks EVERY required var for
EVERY step in the active pipeline and reports ALL missing ones at once -- so you
fix your inputs in one pass, not one failed step at a time. Steps with no
`requires:` are not checked. Roles themselves carry no guard code; the
declaration lives on the pipeline step, keeping roles pure logic.

When you port a new step that needs a user-supplied value, add `requires: [that_var]`
to its pipeline line -- do NOT add assert/guard tasks inside the role.


## Repeated steps and step ids

If the same role runs more than once (e.g. two `reboot` steps, or several
`copy_files`), give each an optional `id:` so the selectors can tell them apart:

    - { id: reboot_private, step: reboot, target: "role:k8s_control_plane,k8s_worker" }
    - { id: reboot_bastion, step: reboot, target: "role:bastion" }

`id` defaults to the step (role) name when omitted, so single-use steps need no
id. `start_at`/`only_steps`/`list_steps` all match on id.

Reboot ordering note: reboot the bastion LAST, as its own step. Rebooting it
earlier would cut off every node reached THROUGH it. Private nodes reboot first
(via the working bastion); the bastion reboots last and is reached directly.


## Running part of a pipeline (`start_at` / `only_steps` / `list_steps`)

For iterating or resuming, you can run a subset of the active pipeline:

    -e start_at=apt_upgrade        # run from this step to the END (skip earlier)
    -e 'only_steps=["apt_clean"]'  # run ONLY these steps
    -e list_steps=true             # print the (filtered) steps and exit; generate nothing

Example -- you already copied files, now resume at the upgrade:

    ./deploy.sh --deployment mydeployments/foo -i inv/foo/hosts.yml \
        -e active_pipeline=configure -e start_at=apt_upgrade

IMPORTANT: start_at/only_steps do NOT check the requires: of skipped steps, and
do NOT supply state that skipped steps would have produced. They assume the
earlier steps already ran. Safe for independent steps (apt, copies); for steps
that consume earlier steps' output (e.g. a k8s join token), don't skip the
producer.


## Passing parameters to a step (`vars:`)

A step can hand parameters to its role via `vars:`. The uniform rule:
**every value in `vars:` is the NAME of one of your variables -- the framework
looks it up and passes the real value to the role.** You never write `{{ }}`
in the pipeline; you just name your vars.

    # pipeline (names only):
    - { step: copy_files, target: "role:k8s_worker",
        vars: { copy_set: my_bash_files, copy_base_dir: my_src_dir },
        requires: [my_bash_files, my_src_dir] }

    # your vars/ file (the real values):
    my_src_dir: "/home/{{ local_user }}/files"
    my_bash_files:
      - { src: ".bash_aliases", dest: "/home/{{ remote_cloud_user }}/.bash_aliases" }

Because each step names its OWN vars, you can invoke the same role many times
with different inputs (e.g. several `copy_files` steps at different points, each
naming a different list and base dir) with no collisions -- give each its own
uniquely named vars. Roles receive plain values and need no lookup logic; the
framework does that plumbing.


## Connection model (your ~/.ssh/config is never touched)

Ansible reaches nodes self-contained, from the spec's `deploy_conn:` block. The
generated inventory writes, per host: `ansible_host`, the SSH key file, and
`ansible_ssh_common_args` (a ProxyCommand through the bastion -- except the
bastion itself, which connects directly). Ansible never reads or writes
`~/.ssh/config` or any `config_*` file; those stay yours for interactive use.
The connection var is `deploy_conn` (not `connection`, which Ansible reserves).


## Multiple environments

Each deployment is a directory under `mydeployments/<name>/` holding its own
`spec.yml`, `pipeline.yml`, and `vars/`. Select one with
`--deployment mydeployments/<name>`. Add a new environment by copying the sample
to a new directory and editing it -- nothing else changes.

Everything in a deployment directory is YOUR data (gitignored): the spec
(platform.cloud, deploy_conn, node_groups, topology), the pipeline (step order),
and the role vars (control user, packages, firewall ports). The committed tree
holds only the engine, the roles, and `specs/examples/example-deployment/` as the
template to copy.

Bare metal differs structurally: `setup: bm` gates out provisioning (node
provision step has `when_setup: vm`), `platform.name != chameleon` skips the
firewalld step, and nodes use `static_hosts`. Run with
`active_pipeline=configure` against reachable machines.

Tip: give each environment a distinct name_pattern prefix (NW- / P2- / PG-) so
host names never collide if two inventories load together.


## Protecting your edits across framework updates

`specs/examples/` is overwritten by updates; `mydeployments/` is never in a
framework tarball. See FRAMEWORK_MANIFEST.txt for the ownership list.

When applying a framework-only update from Claude:

    git status                                  # confirm clean tree
    ./update_framework.sh framework-update.tar.gz
        # refuses any tarball containing mydeployments/ or inv/
        # shows a diff and asks before copying
    git diff                                    # confirm nothing in mydeployments/

git is the real safety net: commit before applying an update, and any unwanted
change is `git checkout -- <file>` away.


## What is and isn't tested

TESTED on localhost (logic only): node model -> role groups; round-robin
cluster distribution; naming (incl. two-worker-flavor, no collision); both spec
modes (cloud/bare-metal); provisioning PHASE ordering and per-phase host
selection; connection-address computation (bastion direct vs proxied); IP
capture PARSING against a mocked openstack shape; consolidated inventory
write + read-back; pipeline -> one-play-per-step generation and execution (mock
roles); resume/force-recreate set math; the safe-update mechanism.

PARTIALLY PROVEN on real Chameleon: VM creation, and bastion creation with a
pre-allocated floating IP.

NOT yet proven end-to-end: reaching private nodes THROUGH the bastion
(phase-1 wait + configure); whether real IPs arrive in the exact shape the
capture code expects; the real role bodies (apt, k8s, ...) on real VMs;
openstack idempotency/delete behavior under force-recreate.

### First-run checklist on Chameleon
1. Run from inside your OpenStack venv; confirm `openstack server list` works.
2. Run `active_pipeline=provision_only`. Watch the pre-flight summary.
3. When it finishes, open `inv/<run>/hosts.yml`; confirm each `ansible_host` is
   the expected private IP (not NO_IP_CAPTURED), and the bastion shows its
   floating IP with no ProxyCommand.
4. Sanity-check reachability: `ansible -i inv/<run>/hosts.yml <a-host> -m ping`.
5. Then run `configure` (or `full` next time).


## Not yet built (future work)
- Real role bodies: node_provision, apt_upgrade, reboot, apt_install, firewall,
  and copy_files are implemented; remaining domain steps (docker, k8s, ...) are
  ported the same mechanical way (paste task body into roles/<name>/tasks/main.yml,
  add a pipeline line, add requires:/vars: if it needs inputs).
- `vm_creation_limit` batching for large provisions (serial at the provision play).
- OS/arch heterogeneity (per-OS vars inside roles, keyed on gathered facts).
- Inter-step data passing (e.g. k8s join token from control plane to workers) --
  solved per-role when you flesh out the real bodies, not by the framework.


## Kubernetes cluster bring-up

The k8s stack is split into clean, single-purpose roles so nothing is tangled:

Runtime foundation:
- `cri_config` -- configures containerd (systemd cgroup driver; registry
  config_path -> certs.d). Restart via handler (once, on change).
- `registry_trust` -- tells containerd on every cluster node to pull from your
  private registry. The registry address is DISCOVERED from the inventory
  (the docker_registry group's IP) -- nothing hardcoded.

Cluster formation (CNI-agnostic):
- `k8s_init` -- runs `kubeadm init` on the primary control-plane. It reads this
  cluster's CNI requirements from a central table `cni_params[cni]`, so there is
  NO per-CNI branching. Pick a CNI with a single var: `cni: flannel`.
- `k8s_join_capture` -- captures the join command to disk-backed state on the
  control node (inv/<name>/state/). Workers read it from there -- replaces the
  legacy fetch-down/copy-up file dance.
- `k8s_join_workers` -- each worker runs the captured join command.
- `k8s_verify` -- waits for all nodes to reach Ready.

Pluggable CNI (apply-only roles): `cni_flannel`, `cni_canal`, `cni_calico`,
`cni_cilium`. Swap ONE pipeline line to change CNI. Set `cni:` to match.
Status: flannel and canal are known-good; calico and cilium are provided but
UNVERIFIED on VM clusters (calico: iterate on `calico_encapsulation`, VXLAN for
cloud VMs; cilium: never verified historically).

Adding a CNI later = one entry in `cni_params` (in k8s_init/defaults) + one
`cni_<name>` apply-role. The init step never changes.

Multi-cluster note: the current roles assume a single cluster (all control-plane
nodes form it, all workers join). The "which cluster is this node in" decision is
isolated to the primary-node selection -- the seam to generalize for multi-cluster
(C1/C2 naming, per-cluster CIDR slicing) later.


### Cluster prep + registry roles
- `swapoff` -- disables swap (runtime `swapoff -a` AND comments swap in /etc/fstab
  so it stays off across reboots). kubeadm requires swap off. Run on all cluster
  nodes before k8s_init.
- `registry_start` -- starts the private registry container (registry:latest) on
  the docker_registry node. Vars: registry_image, registry_port,
  registry_container_name.

### Full k8s_cluster pipeline order
`k8s_cluster` is just a named pipeline (a label under `pipelines:`, like
`configure`). Select it with `-e active_pipeline=k8s_cluster`. Correct order:

    registry_start (registry node)
    swapoff, cri_config, registry_trust (all cluster nodes -- prep)
    k8s_init -> k8s_join_capture -> k8s_join_workers (form cluster)
    cni_<chosen> -> k8s_verify (network + check)

Deferred / separate concerns (not in the cluster pipeline): the Chameleon volume
create/attach/format/mount + docker data-root move (a registry disk-space
optimization), and the registry-node daemon.json (only needed where you docker
push). These are independent role-sets to add later, kept out of cluster
bring-up so a volume issue can't masquerade as a cluster failure.


## Composing pipelines (`include`)

A pipeline can compose others instead of duplicating steps. Interleave
`{ include: <pipeline_name> }` entries with normal steps; the framework flattens
them (in order) before running:

    pipelines:
      provision_only:
        - { step: node_provision, target: local, when_setup: vm }
      configure:
        - { step: apt_upgrade, target: "role:k8s_worker" }
        # ...
      k8s_cluster:
        - { step: registry_start, target: "role:docker_registry" }
        # ...
      full:                      # compose the phases, no duplication
        - { include: provision_only }
        - { include: configure }
        - { include: k8s_cluster }

Run any phase alone (`-e active_pipeline=configure`) or all of them
(`-e active_pipeline=full`). Includes may nest one level, may interleave with
normal steps, and an unknown include name fails immediately with a clear error.
Selecting a pipeline name that doesn't exist also fails with the list of
available pipelines.


## Persistent volume for the registry (optional)

For a registry node with small root disk, attach a persistent volume and move
docker's storage onto it. Two decoupled roles:

- `volume_provision` -- NEUTRAL name; creates + attaches the volume. The
  provider mechanics live behind a `platform.name` dispatch (today: chameleon/
  OpenStack via tasks/openstack.yml). Adding a provider = add tasks/<provider>.yml;
  pipelines still just say `volume_provision`. User vars: `volume_size_gb`
  (required, e.g. 200), optional `volume_type` (ceph-hdd/ceph-ssd).
- `volume_mount` -- GENERIC (no cloud API): safely partitions/formats/mounts the
  attached device leaving docker configuration to the separate docker_config role. User vars:
  `volume_mount_name` (dir under /mnt), `volume_size_gb` (a loose size sanity
  check). The device is AUTO-DETECTED as the single unpartitioned, non-root,
  non-removable disk (you can't know the device name in advance -- it's created
  during the run), then verified to be ~the expected size (GB/GiB-agnostic).
  SAFETY: refuses unless exactly one such empty disk is found. A re-run over an
  already-formatted volume finds ZERO empty disks (it now has a partition) and
  reports nothing to do -- your data is never wiped. Override: `volume_force=true`
  + `volume_device`.
  The docker daemon.json write MERGES (keeps insecure-registries, adds data-root).

Example pipeline (registry node only), run BEFORE registry_start:

    - { step: volume_provision, target: "local" }
    - { step: volume_mount,     target: "role:docker_registry", gather_facts: true }

Needs collections: community.general (parted/filesystem), ansible.posix (mount).


## Configuring the docker daemon (`docker_config`)

`docker_config` applies settings to /etc/docker/daemon.json, MERGING into any
existing file so you can invoke it multiple times at different pipeline stages
without clobbering earlier settings. It's generic -- it doesn't know about
volumes or registries; you tell it what to set.

Uniform vars rule: name a settings var in the pipeline; define the dict in vars.

    # in your vars:
    dockervol_dataroot: { data-root: /mnt/dockervol }
    registry_insecure:  { insecure-registries: ["REGISTRY_IP:5000"] }

    # in your pipeline, at the appropriate stages:
    - { step: volume_mount,   target: "role:docker_registry", gather_facts: true }
    - { step: docker_config,  target: "role:docker_registry",
        vars: { docker_daemon_settings: dockervol_dataroot } }     # data-root AFTER mount
    - { step: registry_start, target: "role:docker_registry" }
    - { step: docker_config,  target: "role:docker_registry",
        vars: { docker_daemon_settings: registry_insecure } }      # insecure-reg AFTER start

This keeps concerns cleanly separated: volume_mount does storage only,
registry_start runs the container, and docker_config (invoked as needed) owns
daemon.json. Multiple docker_config calls layer their settings via merge.


## Registry trust for docker (`registry_docker_trust`)

The docker-daemon analog of `registry_trust` (which handles containerd). Adds the
private registry to docker's `insecure-registries` in daemon.json, so
`docker push`/`pull` against the insecure registry works. The registry ADDRESS is
DISCOVERED from the `docker_registry` inventory group -- you supply nothing.

    - { step: registry_docker_trust, target: "role:docker_registry" }

Design note: docker daemon.json is configured by TWO roles by concern --
`docker_config` for settings you supply explicitly (data-root, cgroup driver,
log driver, ...) and `registry_docker_trust` for the one setting whose value must
be discovered (insecure-registries <- registry IP from inventory). Both MERGE, so
they coexist in one daemon.json. Put container-name and image choices on
`registry_start`.


## Pointing docker at a volume (`docker_data_root`)

To put docker's storage on a mounted volume, use `docker_data_root`. You supply
a plain ABSOLUTE PATH; the role owns the docker-specific detail (that this sets
daemon.json `data-root`). You never type `data-root`.

    # vars:
    docker_data_root_path: /mnt/dockervol      # a path you know; NOT docker jargon

    # pipeline (after volume_mount, before registry_start/pulls):
    - { step: docker_data_root, target: "role:docker_registry",
        requires: [docker_data_root_path] }

Separation of concerns (four roles, each owning the right knowledge):
- `volume_mount`        -- storage only; mounts a volume, knows nothing about docker
                           (reusable for data/logs/anything).
- `docker_data_root`    -- "docker stores here": takes a plain path, hides the
                           data-root key.
- `registry_docker_trust` -- insecure-registries; registry IP DISCOVERED from
                           inventory (user supplies nothing).
- `docker_config`       -- generic daemon.json settings the user chooses explicitly
                           (cgroup driver, log driver, ...).
All four MERGE into daemon.json, so they coexist.


## CAUTION: reusing a volume that was a docker data-root

Persistent volumes remember everything. If you reattach a volume that was
previously docker's `data-root` and then point docker at it (via
`docker_data_root`), docker reads the container/image metadata stored on the
volume and **automatically restarts any containers whose definitions are saved
there** (those with `restart_policy: always`). Your old images AND old
containers come back to life.

This is usually WELCOME (you recover your registry and images without
rebuilding). But note:

- An old registry container may auto-start and claim the registry port under its
  ORIGINAL name (e.g. `PangeaRegistry`), even though you never supplied that name
  this time -- it came from the volume's metadata.
- `registry_start` (remove-then-recreate by name) will then collide on the port
  unless you tell it the real name. Set:

      registry_container_name: PangeaRegistry   # match the resurrected container

  Or remove the old container once (`docker rm -f <name>`) and let the framework
  create its default (`private_registry`).

Steps that only touch daemon.json (`docker_data_root`, `registry_docker_trust`,
`docker_config`) don't depend on the container name and work regardless.


## Deploying workloads with templated manifests (`k8s_apply_manifests`)

Workload manifests often hardcode the registry IP in image lines
(`192.168.3.46:5000/touchstone/...`). Since the registry IP changes per
deployment, templatize it: rename the manifest to `*.yaml.j2` and replace the IP
with `{{ registry_endpoint }}`:

    image: {{ registry_endpoint }}/touchstone/src-server-flask-core:latest

`k8s_apply_manifests` discovers the registry endpoint from the `docker_registry`
inventory group (same as registry_docker_trust), renders every `*.yaml.j2` in
your manifest dir, and applies them to the cluster (on the primary control-plane,
using the venv python that has the kubernetes lib).

    # vars:
    manifest_src_dir: mydeployments/pangea/manifests   # your *.yaml.j2 files

    # pipeline (after the cluster + registry are up):
    - { step: k8s_apply_manifests, target: "role:k8s_control_plane",
        gather_facts: true, requires: [manifest_src_dir] }

Templatize ONLY what varies per deployment (the registry IP). Leave stable values
(replicas, resource limits, ports) literal for readability -- add more variables
only if those genuinely change between deployments.


## NFS-backed app storage + workload deployment

Full chain to run a workload that needs shared persistent storage (docker-compose
volumes -> k8s NFS PVs). Two IPs are DISCOVERED (registry, nfs server); you supply
the storage shape and manifests. ORDER: volume -> nfs -> storage -> workloads.

Roles:
- `nfs_server` (on master) -- exports the mounted app volume; creates per-volume
  subdirs from nfs_volumes.
- `nfs_client` (on workers) -- installs nfs-common so kubelet can mount NFS PVs.
- `k8s_nfs_storage` (primary CP) -- generates static PV+PVC pairs from the
  nfs_volumes list (NFS IP discovered) and applies them.
- `k8s_apply_manifests` (primary CP) -- creates configmaps from files, renders
  *.yaml.j2 with discovered registry_endpoint + nfs_server_ip, applies them.

User contract (see examples/k8s_manifests/EXAMPLE_vars.yml):
- nfs_export_base (e.g. /mnt/touchstone), nfs_volumes [{name,subpath,size}...],
  manifest_src_dir, optional configmap_files [{name,file}...].
- The SECOND app-data volume (on the master) is separate from the docker volume;
  provision/mount it with volume_provision + volume_mount targeting the master.

In your manifests, replace hardcoded IPs: registry -> {{ registry_endpoint }},
nfs/master -> {{ nfs_server_ip }}. Templated examples of the touchstone
deployments/services live in examples/k8s_manifests/.

CONSISTENCY the framework can't check: nfs_volumes subpaths, the PVC names your
deployments claim, and the container mountPaths must all agree.

CONFIGMAP note: NFS PVs mount DIRECTORIES, not single files. To inject one file
(e.g. metric_definitions.json) use a configmap + subPath mount (see the
client-streamlit example). configmap_files creates these from your file.
