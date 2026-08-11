# LPIC-3 305 (305-300) — Topic 353.1: Cloud Management Tools

## Guided Exercises

These exercises take you through managing an IaaS cloud with **OpenStack** and **Apache Libcloud**, mapped directly to the LPI 305-300 objective *353.1 Cloud Management Tools*. You will authenticate against the Identity service, publish an image, boot and network an instance, attach block storage, orchestrate a stack with Heat, and finally drive the same cloud programmatically through Libcloud.

**Reference lab environment.** Any OpenStack cloud with the unified `openstack` client (`python-openstackclient`) works. The commands and outputs below assume a single-node **DevStack** deployment (`stable/2024.1`, release name *Caracal*) reachable at `controller` (`10.0.0.11`), with the demo credentials sourced from a `clouds.yaml`. If you do not have a cloud, DevStack builds one on a throwaway VM: <https://docs.openstack.org/devstack/latest/>.

> Convention used throughout: `$` is an unprivileged shell prompt. IDs in sample output are truncated for readability — yours will differ. Every command is idempotent to re-run except where a step explicitly creates or deletes a resource.

---

### Exercise 1 — Authenticate and map the OpenStack service catalog

The whole cloud is a set of independent REST services glued together by **Keystone** (Identity). Before touching any resource you must obtain a token and discover which services and endpoints exist.

1. Create a `clouds.yaml` in `~/.config/openstack/` describing your credentials. This replaces sourcing an `openrc` file and lets you select a cloud with `--os-cloud`:

   ```yaml
   # ~/.config/openstack/clouds.yaml
   clouds:
     devstack:
       auth:
         auth_url: http://controller:5000/v3
         username: demo
         password: "secret"
         project_name: demo
         user_domain_name: Default
         project_domain_name: Default
       region_name: RegionOne
       identity_api_version: 3
       interface: public
   ```

2. Point every command at that cloud for the rest of the session:

   ```bash
   $ export OS_CLOUD=devstack
   ```

3. Prove your credentials work by issuing a scoped token. This is a call to Keystone's `POST /v3/auth/tokens`:

   ```bash
   $ openstack token issue
   ```

   Expected output (abbreviated):

   ```
   +------------+----------------------------------+
   | Field      | Value                            |
   +------------+----------------------------------+
   | expires    | 2026-08-11T13:44:07+0000         |
   | id         | gAAAAABm...                      |
   | project_id | 8f2c1e...                        |
   | user_id    | 4a91bd...                        |
   +------------+----------------------------------+
   ```

4. List the registered service types. Each row is one OpenStack project answering a distinct API:

   ```bash
   $ openstack service list
   ```

   ```
   +----------------------------------+-----------+----------------+
   | ID                               | Name      | Type           |
   +----------------------------------+-----------+----------------+
   | 5c1e...                          | keystone  | identity       |
   | 7a09...                          | glance    | image          |
   | 9b31...                          | nova      | compute        |
   | 2f88...                          | neutron   | network        |
   | c4d0...                          | cinder    | volumev3       |
   | e6a2...                          | heat      | orchestration  |
   | 1d7f...                          | swift     | object-store   |
   | 3b55...                          | placement | placement      |
   +----------------------------------+-----------+----------------+
   ```

5. Inspect the endpoints for one service to see the URL your client actually talks to. Note the `publicURL` versus the internal/admin interfaces:

   ```bash
   $ openstack endpoint list --service compute --interface public
   ```

   ```
   +------+-----------+--------------+--------------+---------+-----------+-------------------------------+
   | ID   | Region    | Service Name | Service Type | Enabled | Interface | URL                           |
   +------+-----------+--------------+--------------+---------+-----------+-------------------------------+
   | a1.. | RegionOne | nova         | compute      | True    | public    | http://controller:8774/v2.1   |
   +------+-----------+--------------+--------------+---------+-----------+-------------------------------+
   ```

6. Dump the catalog your token was scoped with — this is what the client caches to route every subsequent call:

   ```bash
   $ openstack catalog list
   ```

**Comprehension questions**

- **Q1.1** Which OpenStack component issues the token, and what two facts must a *scoped* token carry that an unscoped one does not?
- **Q1.2** Your `clouds.yaml` sets `interface: public`. What is the practical difference between the `public`, `internal`, and `admin` endpoint interfaces, and why does DevStack expose all three?
- **Q1.3** You run `openstack server list` and get `Unable to establish connection to http://controller:8774/...`. Keystone auth clearly succeeded because `openstack token issue` worked. What single piece of catalog data is the client using to reach Nova, and where would you look to confirm it is wrong?

---

### Exercise 2 — Publish a bootable image with Glance

**Glance** is the image registry. An instance boots from a Glance image copied into the hypervisor's ephemeral disk (or, later, cloned into a Cinder volume).

1. List existing images. On a fresh DevStack you will see the CirrOS test image:

   ```bash
   $ openstack image list
   ```

   ```
   +--------------------------------------+--------------------------+--------+
   | ID                                   | Name                     | Status |
   +--------------------------------------+--------------------------+--------+
   | b7f3c2a1-...                         | cirros-0.6.2-x86_64-disk | active |
   +--------------------------------------+--------------------------+--------+
   ```

2. Download a small cloud image to upload yourself:

   ```bash
   $ wget -q https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
   ```

3. Create the image in Glance, declaring its on-disk format and its container format. `qcow2` is the QEMU copy-on-write disk; `bare` means the disk is not wrapped in any extra container metadata:

   ```bash
   $ openstack image create \
       --disk-format qcow2 \
       --container-format bare \
       --file cirros-0.6.2-x86_64-disk.img \
       --public \
       cirros-custom
   ```

   ```
   +------------------+--------------------------------------------------------+
   | Field            | Value                                                  |
   +------------------+--------------------------------------------------------+
   | container_format | bare                                                   |
   | disk_format      | qcow2                                                  |
   | id               | 4d9a77e1-3c2b-4f0a-9a2e-1b8c7d6e5f40                   |
   | min_disk         | 0                                                      |
   | min_ram          | 0                                                      |
   | name             | cirros-custom                                          |
   | status           | active                                                 |
   | visibility       | public                                                 |
   +------------------+--------------------------------------------------------+
   ```

4. Attach searchable metadata (image *properties*). Schedulers and the CLI can filter on these:

   ```bash
   $ openstack image set --property os_distro=cirros --property hw_disk_bus=virtio cirros-custom
   ```

5. Confirm the properties and the computed checksum are stored:

   ```bash
   $ openstack image show cirros-custom -c name -c checksum -c properties
   ```

   ```
   +------------+----------------------------------------------------+
   | Field      | Value                                              |
   +------------+----------------------------------------------------+
   | checksum   | 0b3 b1a...                                         |
   | name       | cirros-custom                                      |
   | properties | hw_disk_bus='virtio', os_distro='cirros', ...      |
   +------------+----------------------------------------------------+
   ```

**Comprehension questions**

- **Q2.1** What is the difference between `--disk-format` and `--container-format`, and when would `container-format` be something other than `bare`?
- **Q2.2** You created the image with `--public`. Which OpenStack service decides whether the `demo` user is *allowed* to create a public image, and what is the usual outcome for a non-admin user?
- **Q2.3** `min_disk` and `min_ram` were both `0`. What breaks at boot time if you upload a 20 GB image but leave `min_disk` at `0`, and a user selects a flavor with a 10 GB root disk?

---

### Exercise 3 — Boot and inspect an instance with Nova

**Nova** is the compute service. Booting a server is a scheduling decision (`placement` picks a host) plus wiring of an image, a **flavor** (the CPU/RAM/disk sizing template), a network port, and optionally an SSH key.

1. List flavors — these are the fixed sizing templates a tenant may choose from:

   ```bash
   $ openstack flavor list
   ```

   ```
   +----+-----------+-------+------+-----------+-------+-----------+
   | ID | Name      |   RAM | Disk | Ephemeral | VCPUs | Is Public |
   +----+-----------+-------+------+-----------+-------+-----------+
   | 1  | m1.tiny   |   512 |    1 |         0 |     1 | True      |
   | 2  | m1.small  |  2048 |   20 |         0 |     1 | True      |
   | 3  | m1.medium |  4096 |   40 |         0 |     2 | True      |
   +----+-----------+-------+------+-----------+-------+-----------+
   ```

2. Create an SSH keypair so you can reach the instance. Nova stores only the public key and injects it via the metadata service / cloud-init:

   ```bash
   $ openstack keypair create labkey > ~/labkey.pem && chmod 600 ~/labkey.pem
   ```

3. Identify the tenant network to attach to (created in Exercise 4 if absent; DevStack ships a `private` network):

   ```bash
   $ openstack network list
   ```

4. Boot the server. `--wait` blocks until Nova reports `ACTIVE`:

   ```bash
   $ openstack server create \
       --flavor m1.small \
       --image cirros-custom \
       --network private \
       --key-name labkey \
       --wait \
       web01
   ```

   ```
   +-------------------------+-----------------------------------------------+
   | Field                   | Value                                         |
   +-------------------------+-----------------------------------------------+
   | OS-EXT-STS:power_state  | Running                                       |
   | OS-EXT-STS:vm_state     | active                                        |
   | addresses               | private=10.0.5.14                             |
   | flavor                  | m1.small (2)                                  |
   | id                      | 7c2e6b9a-2f1d-4c88-b0a3-9e1f2a7c4d55          |
   | image                   | cirros-custom (4d9a77e1-...)                  |
   | key_name                | labkey                                        |
   | status                  | ACTIVE                                         |
   +-------------------------+-----------------------------------------------+
   ```

5. Read the console log to confirm the OS actually booted (this is Nova reading the hypervisor serial console, invaluable when SSH fails):

   ```bash
   $ openstack console log show web01 | tail -n 5
   ```

   ```
   === cirros: current=0.6.2 ...
   login as 'cirros' user. default password: 'gocubsgo'.
   web01 login:
   ```

6. Show the placement decision and the port that Neutron handed to this instance:

   ```bash
   $ openstack server show web01 -c OS-EXT-SRV-ATTR:host -c addresses
   $ openstack port list --server web01
   ```

**Comprehension questions**

- **Q3.1** Trace the four services involved from the moment you run `openstack server create` until the VM is `ACTIVE`. Name each and state its one job in the flow.
- **Q3.2** The instance came up but you cannot SSH in, yet `openstack console log show` shows a login prompt. Is this more likely a Nova problem or a Neutron problem? Justify it.
- **Q3.3** Why does Nova store only the *public* half of the keypair, and by what mechanism does the running CirrOS instance retrieve it during first boot?

---

### Exercise 4 — Build tenant networking with Neutron

**Neutron** provides networks, subnets, routers, and floating IPs. A private tenant network reaches the outside world through a router that has its gateway set on the provider/external network.

1. Create an isolated tenant network and a subnet with a DHCP range:

   ```bash
   $ openstack network create lab-net
   $ openstack subnet create lab-subnet \
       --network lab-net \
       --subnet-range 192.168.50.0/24 \
       --gateway 192.168.50.1 \
       --dns-nameserver 1.1.1.1
   ```

   ```
   +----------------------+--------------------------------------+
   | Field                | Value                                |
   +----------------------+--------------------------------------+
   | allocation_pools     | 192.168.50.2-192.168.50.254          |
   | cidr                 | 192.168.50.0/24                      |
   | enable_dhcp          | True                                 |
   | gateway_ip           | 192.168.50.1                         |
   | network_id           | 2b7c...                              |
   +----------------------+--------------------------------------+
   ```

2. Create a router and attach the tenant subnet to it as an internal interface:

   ```bash
   $ openstack router create lab-router
   $ openstack router add subnet lab-router lab-subnet
   ```

3. Set the router's external gateway on the provider network so tenant traffic can be SNAT'd outbound:

   ```bash
   $ openstack router set lab-router --external-gateway public
   ```

4. Allocate a floating IP from the external pool and associate it with `web01` for inbound reachability (DNAT):

   ```bash
   $ openstack floating ip create public
   ```

   ```
   +---------------------+--------------------------------------+
   | Field               | Value                                |
   +---------------------+--------------------------------------+
   | floating_ip_address | 172.24.4.87                          |
   | id                  | f1a9...                              |
   | status              | DOWN                                 |
   +---------------------+--------------------------------------+
   ```

   ```bash
   $ openstack server add floating ip web01 172.24.4.87
   ```

5. Open ICMP and SSH in the default **security group** (a Neutron stateful firewall applied at the port), then verify reachability:

   ```bash
   $ openstack security group rule create --proto icmp default
   $ openstack security group rule create --proto tcp --dst-port 22 default
   $ ping -c1 172.24.4.87
   $ ssh -i ~/labkey.pem cirros@172.24.4.87
   ```

**Comprehension questions**

- **Q4.1** Distinguish a *network*, a *subnet*, and a *port* in Neutron's data model. Which one does a security group actually bind to?
- **Q4.2** A floating IP performs which NAT operation for inbound traffic, and which distinct NAT operation does the router's external gateway perform for outbound traffic from an instance that has *no* floating IP?
- **Q4.3** You associated the floating IP and the security group allows ICMP, but ping still fails. Name two independent Neutron-layer causes to check before blaming the instance OS.

---

### Exercise 5 — Attach persistent block storage with Cinder

**Cinder** provides block volumes whose lifecycle is independent of any instance. An instance's ephemeral root disk dies with the instance; a Cinder volume survives.

1. Create a 10 GB volume:

   ```bash
   $ openstack volume create --size 10 data-vol
   ```

   ```
   +---------------------+--------------------------------------+
   | Field               | Value                                |
   +---------------------+--------------------------------------+
   | id                  | 9d21c4e8-...                         |
   | name                | data-vol                             |
   | size                | 10                                   |
   | status              | available                            |
   | volume_type         | lvmdriver-1                          |
   +---------------------+--------------------------------------+
   ```

2. Attach it to the running instance. Nova asks Cinder to export the volume and hot-plugs it onto the guest:

   ```bash
   $ openstack server add volume web01 data-vol --device /dev/vdb
   ```

3. Confirm the attachment from the control plane:

   ```bash
   $ openstack volume show data-vol -c status -c attachments
   ```

   ```
   +-------------+-------------------------------------------------------------+
   | Field       | Value                                                       |
   +-------------+-------------------------------------------------------------+
   | attachments | [{'server_id': '7c2e6b9a-...', 'device': '/dev/vdb', ...}]  |
   | status      | in-use                                                      |
   +-------------+-------------------------------------------------------------+
   ```

4. Inside the guest, prove the block device appeared, then format and mount it:

   ```bash
   $ ssh -i ~/labkey.pem cirros@172.24.4.87
   $ sudo fdisk -l /dev/vdb          # 10 GiB unpartitioned disk
   $ sudo mkfs.ext4 /dev/vdb
   $ sudo mount /dev/vdb /mnt && df -h /mnt
   ```

5. Take a point-in-time snapshot (a Cinder snapshot, not a Glance image) for backup/branching:

   ```bash
   $ openstack volume snapshot create --volume data-vol data-vol-snap-1
   ```

**Comprehension questions**

- **Q5.1** What is the fundamental durability difference between an instance's ephemeral root disk and a Cinder volume, and which flag on `server create` blurs that line by booting *from* a volume?
- **Q5.2** After attaching the volume, `openstack volume show` reports `status: in-use` but inside the guest `/dev/vdb` never appears. The control plane clearly believes the attach succeeded — where in the stack is the fault, and what is one diagnostic command?
- **Q5.3** Why can you generally not attach a single `available` volume to two instances at once, and what Cinder feature relaxes this — with what caveat placed on the *guest*?

---

### Exercise 6 — Orchestrate a full stack with Heat

**Heat** is the orchestration engine. A **HOT** (Heat Orchestration Template) declares resources and their dependencies; Heat creates, updates, and deletes them as one atomic **stack**, computing order from references.

1. Write a HOT template that provisions a network, subnet, and server together:

   ```yaml
   # lab-stack.yaml
   heat_template_version: 2021-04-16

   description: >
     LPIC-3 353.1 demo stack: private network + subnet + one server.

   parameters:
     image:
       type: string
       default: cirros-custom
     flavor:
       type: string
       default: m1.small
     public_net:
       type: string
       default: public

   resources:
     stack_net:
       type: OS::Neutron::Net
       properties:
         name: heat-net

     stack_subnet:
       type: OS::Neutron::Subnet
       properties:
         network: { get_resource: stack_net }
         cidr: 192.168.60.0/24
         dns_nameservers: [1.1.1.1]

     stack_server:
       type: OS::Nova::Server
       properties:
         name: heat-web01
         image: { get_param: image }
         flavor: { get_param: flavor }
         networks:
           - network: { get_resource: stack_net }

   outputs:
     server_ip:
       description: Fixed IP of the provisioned server
       value: { get_attr: [stack_server, first_address] }
   ```

2. Validate the template *before* deploying — Heat checks schema and resource types without creating anything:

   ```bash
   $ openstack orchestration template validate -t lab-stack.yaml
   ```

3. Create the stack, overriding one parameter on the command line:

   ```bash
   $ openstack stack create -t lab-stack.yaml --parameter flavor=m1.tiny lab-stack --wait
   ```

   ```
   2026-08-11 13:20:41 [stack_net]: CREATE_IN_PROGRESS  state changed
   2026-08-11 13:20:46 [stack_subnet]: CREATE_COMPLETE  state changed
   2026-08-11 13:21:02 [stack_server]: CREATE_COMPLETE  state changed
   +---------------------+--------------------------------------+
   | id                  | 5e8b3a11-...                        |
   | stack_name          | lab-stack                            |
   | stack_status        | CREATE_COMPLETE                      |
   +---------------------+--------------------------------------+
   ```

4. Read the declared output — Heat computed the server's IP after Nova assigned it:

   ```bash
   $ openstack stack output show lab-stack server_ip
   ```

5. Perform a declarative update: change `flavor` back to `m1.small` in the template and let Heat reconcile only what changed:

   ```bash
   $ openstack stack update -t lab-stack.yaml lab-stack --wait
   ```

6. Tear the whole thing down as one unit (Heat deletes in reverse dependency order):

   ```bash
   $ openstack stack delete lab-stack --yes
   ```

**Comprehension questions**

- **Q6.1** Nowhere in the template did you state "create the network *before* the server." How does Heat determine that ordering, and which intrinsic function is the signal?
- **Q6.2** What is the difference between `get_resource`, `get_param`, and `get_attr`, and at which moment in the stack lifecycle is each one resolved?
- **Q6.3** You change the `image` property of `stack_server` and run `stack update`. Some property changes trigger an in-place update and others force a *replacement* of the resource. Which behavior is likely here, and why does that distinction matter to a running production workload?

---

### Exercise 7 — Drive the same cloud with Apache Libcloud

**Apache Libcloud** is a Python abstraction library that presents *one* API across 50+ cloud providers, including OpenStack. It is the LPI objective's answer to "manage many clouds from one codebase." Here you reproduce Exercise 3's boot using Libcloud's OpenStack compute driver.

1. Install the library in a virtualenv:

   ```bash
   $ python3 -m venv ~/lc && source ~/lc/bin/activate
   (lc) $ pip install "apache-libcloud>=3.8.0"
   ```

2. Instantiate the OpenStack driver against Keystone v3. Note the `ex_force_*` keyword arguments — Libcloud exposes provider-specific auth details as `ex_` extensions:

   ```python
   # lc_boot.py
   from libcloud.compute.types import Provider
   from libcloud.compute.providers import get_driver

   OpenStack = get_driver(Provider.OPENSTACK)

   driver = OpenStack(
       "demo",                                   # username
       "secret",                                 # password / api_key
       ex_force_auth_url="http://controller:5000",
       ex_force_auth_version="3.x_password",
       ex_domain_name="Default",
       ex_tenant_name="demo",
       ex_force_service_region="RegionOne",
   )
   ```

3. List sizes (flavors) and images through Libcloud's *normalized* objects — `NodeSize` and `NodeImage`, identical in shape regardless of provider:

   ```python
   sizes = driver.list_sizes()
   images = driver.list_images()

   size = next(s for s in sizes if s.name == "m1.small")
   image = next(i for i in images if i.name == "cirros-custom")

   print(size.id, size.ram, size.disk, size.vcpus)
   print(image.id, image.name)
   ```

4. Create a node (instance). Networks are passed as an `ex_` extension because they are OpenStack-specific:

   ```python
   networks = driver.ex_list_networks()
   net = next(n for n in networks if n.name == "private")

   node = driver.create_node(
       name="lc-web01",
       size=size,
       image=image,
       networks=[net],
   )
   print("created:", node.id, node.state)
   ```

5. Wait until the node is running and print its addresses using the portable state enum:

   ```python
   from libcloud.compute.types import NodeState

   node = driver.wait_until_running([node])[0][0]
   print(node.state, node.private_ips, node.public_ips)
   assert node.state == NodeState.RUNNING
   ```

6. Run it, then confirm from the CLI that Libcloud and the `openstack` client are looking at the *same* cloud state:

   ```bash
   (lc) $ python3 lc_boot.py
   (lc) $ openstack server list --name lc-web01
   ```

7. Destroy the node through Libcloud to close the loop:

   ```python
   driver.destroy_node(node)
   ```

**Comprehension questions**

- **Q7.1** Libcloud calls a flavor a `NodeSize` and an instance a `Node`. What is the design purpose of this renaming, and what do you *lose* by working through it rather than the native `openstack` client?
- **Q7.2** Why are `create_node`'s `size`, `image`, and `name` plain arguments, while `networks` had to be passed via `ex_list_networks()` / the `networks` extension? What does the `ex_` prefix convention communicate about portability?
- **Q7.3** You point the same script at AWS EC2 by swapping only `get_driver(Provider.EC2)` and the credentials. `list_nodes()` and `create_node()` keep working, but your `ex_list_networks()` call breaks. Explain precisely why, in terms of Libcloud's "base API vs. extension" contract.

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1 — Keystone & the catalog**

- **A1.1** **Keystone** (the Identity service) issues the token via `POST /v3/auth/tokens`. A *scoped* token additionally carries a **project (and/or domain) scope** and the **service catalog + role assignments** valid for that scope. An unscoped token proves *who you are* but authorizes no project resources and contains no catalog, so it cannot be used to call Nova/Neutron/etc.
- **A1.2** They are three separate URLs for the same service, meant for different network paths: **public** = the tenant-facing endpoint (often behind a load balancer / floating IP), **internal** = the same API over the management/backplane network (avoids the public hop for service-to-service traffic), **admin** = historically a privileged port (matters mostly for the deprecated Keystone v2 admin API; in v3 it is usually identical to public). DevStack registers all three so lab tooling can exercise each interface even though they resolve to the same host.
- **A1.3** The client routed to Nova using the **compute endpoint URL from the service catalog** embedded in your scoped token. Confirm it with `openstack endpoint list --service compute` (or `openstack catalog show compute`); a wrong/unreachable URL there — stale hostname, wrong port `8774`, or a service registered but its process down — produces exactly that connection error even though Keystone auth succeeded.

**Exercise 2 — Glance**

- **A2.1** `--disk-format` describes the **virtual disk's on-disk layout** the hypervisor must understand (`qcow2`, `raw`, `vmdk`, `vdi`, `qed`, `iso`). `--container-format` describes any **wrapper/metadata envelope around that disk** (`bare` = none). It is *not* `bare` for formats that bundle disk+metadata, e.g. `ovf`/`ova` (a VM description plus disks) or `docker`/`ami`-style bundles.
- **A2.2** **Keystone** authorization — driven by Glance's policy (RBAC) — decides it. Creating a **public** image normally requires an admin role; a plain `demo` user typically gets `403 Forbidden` (or the image is silently created as `private`/`shared`), because a public image is visible to every tenant in the cloud.
- **A2.3** Nova's scheduler will **reject the boot** (no valid host / flavor too small) or the guest will fail because the root disk cannot hold the image. `min_disk` is the *contract* that a flavor's root disk must be at least that many GB to boot this image; leaving it `0` removes the guard, so a user can pair a 20 GB image with a 10 GB flavor and hit a disk-too-small failure at build time.

**Exercise 3 — Nova**

- **A3.1** (1) **Keystone** authenticates the request and validates the token/scope. (2) **Glance** supplies the image the root disk is built from. (3) **Placement + Nova scheduler** select a compute host that satisfies the flavor's CPU/RAM/disk. (4) **Neutron** creates/binds a port and hands the instance its network/IP; the Nova compute agent then boots the domain on the hypervisor and it goes `ACTIVE`.
- **A3.2** More likely a **Neutron** problem. The console login prompt proves the guest OS booted and the image/flavor/hypervisor path (Nova/Glance) is healthy; failure to reach it over the network points at security group rules, the floating IP association, subnet routing, or port binding — all Neutron.
- **A3.3** Storing only the public key means the **private key never touches the cloud control plane**, so a compromised Nova/DB cannot leak it. The instance retrieves the public key at first boot from the **metadata service** (`http://169.254.169.254/…`) — or config-drive — which **cloud-init** reads and writes into `~/.ssh/authorized_keys`.

**Exercise 4 — Neutron**

- **A4.1** A **network** is an isolated L2 broadcast domain; a **subnet** is an L3 IP range (CIDR + gateway + DHCP pool + DNS) layered onto a network; a **port** is a virtual NIC attachment point on a network, holding a MAC and one or more fixed IPs. A **security group binds to the port** (via the instance's port), not to the network or subnet.
- **A4.2** The floating IP performs **DNAT** (destination NAT) inbound — external `172.24.4.87` → the instance's fixed IP. The router's external gateway performs **SNAT** (source NAT / PAT) outbound — many tenant fixed IPs share the gateway's external address so instances *without* a floating IP can still reach the internet.
- **A4.3** Any two of: the router has **no external gateway set** (or the subnet was never `router add subnet`'d, so there is no route out); the **floating IP is not associated** (still `DOWN`) or associated to the wrong port; the **security group rule has the wrong direction/ethertype** (ingress vs egress, IPv4 vs IPv6); or **port security / allowed-address-pairs** dropping the traffic. Each is a control-plane cause independent of the guest OS.

**Exercise 5 — Cinder**

- **A5.1** The **ephemeral root disk is deleted when the instance is deleted** (it lives in Nova's local/instance storage); a **Cinder volume persists independently** and can be reattached elsewhere. `openstack server create --boot-from-volume <size>` (or `--volume <id>`) blurs the line by making the root disk itself a Cinder volume that outlives the instance.
- **A5.2** The **guest side / attach hot-plug** is at fault — Cinder and Nova recorded the attachment, but the virtio-blk device did not surface in the VM. Diagnose from inside with `dmesg | grep -i vd` (or `lsblk`) to see if the kernel enumerated a new disk; on the host, check the Nova compute log and `virsh domblklist <instance>` to confirm the block device was actually plugged into the domain.
- **A5.3** A volume defaults to **single-attach** because a normal filesystem (ext4/xfs) assumes exclusive block ownership; two writers would corrupt it. Cinder's **multi-attach** volume type relaxes this, but the caveat is on the guest: you must run a **cluster-aware / shared-disk filesystem or coordinator** (e.g. GFS2, OCFS2, or an application that arbitrates access) — plain ext4 will still corrupt.

**Exercise 6 — Heat**

- **A6.1** Heat builds a **dependency graph** by scanning intrinsic functions that reference other resources. Seeing `network: { get_resource: stack_net }` inside the subnet/server tells Heat those resources depend on `stack_net`, so it creates `stack_net` first and deletes it last. `get_resource` (and any cross-resource reference, or an explicit `depends_on`) is the ordering signal.
- **A6.2** `get_param` resolves a **template input parameter** at stack create/update time (before resources exist). `get_resource` returns the **physical ID of another resource in this stack** and thus forces creation ordering. `get_attr` reads a **runtime attribute of an already-created resource** (e.g. an assigned IP) and can only resolve *after* that resource reaches CREATE_COMPLETE.
- **A6.3** Changing `image` almost always forces a **replacement** — a server's boot image is not mutable in place, so Heat deletes the old server and creates a new one, meaning **new instance, new IP/data loss** unless the disk is on a persistent volume. The in-place-vs-replace distinction is critical in production because a "small template edit" can silently destroy and recreate a live workload; review the update plan (`stack update --dry-run` / preview) before applying.

**Exercise 7 — Libcloud**

- **A7.1** The renaming exists to give a **provider-agnostic vocabulary**: `NodeSize`, `NodeImage`, `Node`, `NodeState` mean the same thing on OpenStack, EC2, GCE, etc., so one codebase drives many clouds. What you lose is access to the **long tail of provider-specific features** — anything not in Libcloud's base model is either exposed only through `ex_` extensions or not at all, whereas the native `openstack` client exposes every OpenStack-specific capability and up-to-date microversions.
- **A7.2** `size`, `image`, and `name` are part of Libcloud's **portable base compute API** — every provider has an equivalent, so they are first-class arguments. Networks are **not uniformly modeled across providers**, so OpenStack networking is surfaced through `ex_list_networks()` and the `networks` extension. The **`ex_` prefix marks provider-specific, non-portable** surface: relying on it means your code no longer moves cleanly to another driver.
- **A7.3** `list_nodes()` and `create_node()` belong to the **portable base `NodeDriver` API** that every driver implements, so they keep working on EC2. `ex_list_networks()` is an **OpenStack-driver extension**; the EC2 driver does not implement that method (EC2 models networking as VPCs/subnets via different `ex_` calls), so the attribute does not exist and the call raises. That is the base-API-vs-extension contract: only the non-`ex_` surface is guaranteed across drivers.

</details>

---

### Sources

- LPI — *Exam 305-300 Objectives* (Objective 353.1, Cloud Management Tools): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- OpenStack — *Logical architecture / Get started*: <https://docs.openstack.org/install-guide/get-started-logical-architecture.html>
- OpenStack — *`python-openstackclient` command reference*: <https://docs.openstack.org/python-openstackclient/latest/>
- Keystone (Identity) — *Administrator & concepts*: <https://docs.openstack.org/keystone/latest/>
- Glance (Image) — *User & admin guides*: <https://docs.openstack.org/glance/latest/>
- Nova (Compute): <https://docs.openstack.org/nova/latest/>
- Neutron (Networking): <https://docs.openstack.org/neutron/latest/>
- Cinder (Block Storage): <https://docs.openstack.org/cinder/latest/>
- Heat (Orchestration) — *HOT specification & template guide*: <https://docs.openstack.org/heat/latest/template_guide/hot_spec.html>
- Apache Libcloud — *Compute base API & OpenStack driver*: <https://libcloud.readthedocs.io/en/stable/compute/drivers/openstack.html>
- CirrOS test image (lab asset): <https://download.cirros-cloud.net/>