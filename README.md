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
