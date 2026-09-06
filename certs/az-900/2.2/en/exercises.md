# Guided Exercises — Topic 2.2: Describe Azure compute and networking services

**Certification:** AZ-900 — Microsoft Azure Fundamentals (exam version 2026-07-20)
**Exam weight of this domain area:** 9.62
**Estimated lab time:** 120–150 minutes
**Prerequisites:** an Azure subscription with Contributor rights, and either Azure Cloud Shell (Bash) or a local install of Azure CLI ≥ 2.60 plus `jq`.

---

## ⚠️ Cost and safety notice — read before step 1

These exercises create **billable resources**. The whole lab, run end to end and torn down in the same session, costs roughly **USD 0.50–1.50** in a pay-as-you-go subscription. Two rules:

1. Everything lands in **one resource group** (`rg-az900-lab`) so a single delete removes it all. This is not cosmetic — it is the resource-group lifecycle boundary you must understand for the exam.
2. Never leave a **VPN Gateway** or **ExpressRoute circuit** running. Those are billed per hour regardless of traffic and are the classic surprise-bill items. The exercises that touch them are deliberately **read-only**.

Run **Exercise 10 (cleanup)** the same day you start.

---

## Exercise 0 — Environment bootstrap and the region/zone substrate

Every compute or network decision in Azure starts with two choices you cannot change later without redeploying: **region** and **availability zone support**. Establish them first.

### Steps

1. Open Cloud Shell (Bash) or a local terminal, and confirm which subscription you are in:

   ```bash
   az account show --output table
   ```

   Expected:

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                  State    TenantId
   -----------------  ------------------------------------  -----------  --------------------  -------  ------------------------------------
   AzureCloud         72f988bf-86f1-41af-91ab-2d7cd011db47  True         Pay-As-You-Go         Enabled  72f988bf-86f1-41af-91ab-2d7cd011db47
   ```

2. Export the variables the rest of the lab reuses. The suffix keeps globally unique names (storage accounts, web apps) from colliding with other students:

   ```bash
   export RG=rg-az900-lab
   export LOC=eastus
   export SUFFIX=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
   echo "Resource group=$RG  Region=$LOC  Suffix=$SUFFIX"
   ```

3. Inspect the region catalogue, including each region's **paired region** — the fixed partner Azure uses for platform-managed replication and for staggered maintenance rollouts:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical'].{Region:name, Geography:metadata.geographyGroup, Paired:metadata.pairedRegion[0].name}" \
     --output table | head -20
   ```

   Expected (abridged):

   ```
   Region          Geography       Paired
   --------------  --------------  --------------
   eastus          US              westus
   eastus2         US              centralus
   westus          US              eastus
   northeurope     Europe          westeurope
   westeurope      Europe          northeurope
   brazilsouth     South America   southcentralus
   ```

4. Ask the platform which VM sizes are actually offered in your region **and in which zones**. This is the ground truth; capacity is per-size, per-zone, and it changes:

   ```bash
   az vm list-skus --location $LOC --size Standard_D2s_v5 --zone \
     --query "[].{Size:name, Zones:locationInfo[0].zones}" --output table
   ```

   Expected:

   ```
   Size              Zones
   ----------------  ---------------
   Standard_D2s_v5   ['1', '2', '3']
   ```

5. Create the resource group that will contain every resource in this lab:

   ```bash
   az group create --name $RG --location $LOC --output json
   ```

   Expected:

   ```json
   {
     "id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-az900-lab",
     "location": "eastus",
     "managedBy": null,
     "name": "rg-az900-lab",
     "properties": { "provisioningState": "Succeeded" },
     "tags": null,
     "type": "Microsoft.Resources/resourceGroups"
   }
   ```

### Comprehension check

- **Q1.** Step 5 gave the resource group a `location` of `eastus`. Does that mean every resource you place inside it must also live in `eastus`? What is the resource group's location actually storing?
- **Q2.** In step 4 the SKU reported zones `['1','2','3']`. Are those the same three physical datacenters for you and for another subscription in the same region? Why does this matter when you compare notes with a colleague?
- **Q3.** A team wants to survive the loss of an entire Azure region. Does the paired region from step 3 give them that automatically for a virtual machine they deploy?

*Source: [Azure regions and availability zones](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview) · [Azure region pairs](https://learn.microsoft.com/en-us/azure/reliability/regions-paired)*

---

## Exercise 1 — Deploy a virtual machine and enumerate the resources it requires

The exam objective *"describe the resources required for virtual machines"* is best learned by deploying one with a single command and then counting what the platform silently created on your behalf.

### Steps

1. Create a Linux VM. `--generate-ssh-keys` writes a key pair to `~/.ssh/` if one is not already there:

   ```bash
   az vm create \
     --resource-group $RG \
     --name vm-web-01 \
     --image Ubuntu2204 \
     --size Standard_B1s \
     --admin-username azureuser \
     --generate-ssh-keys \
     --public-ip-sku Standard \
     --nsg-rule SSH \
     --output json
   ```

   Expected (roughly 45–90 seconds):

   ```json
   {
     "fqdns": "",
     "id": "/subscriptions/.../resourceGroups/rg-az900-lab/providers/Microsoft.Compute/virtualMachines/vm-web-01",
     "location": "eastus",
     "macAddress": "00-0D-3A-1B-2C-3D",
     "powerState": "VM running",
     "privateIpAddress": "10.0.0.4",
     "publicIpAddress": "20.121.44.17",
     "resourceGroup": "rg-az900-lab",
     "zones": ""
   }
   ```

2. Now list what one `az vm create` produced:

   ```bash
   az resource list --resource-group $RG \
     --query "[].{Name:name, Type:type}" --output table
   ```

   Expected:

   ```
   Name                Type
   ------------------  -----------------------------------------
   vm-web-01           Microsoft.Compute/virtualMachines
   vm-web-01_OsDisk_1  Microsoft.Compute/disks
   vm-web-01VMNic      Microsoft.Network/networkInterfaces
   vm-web-01NSG        Microsoft.Network/networkSecurityGroups
   vm-web-01PublicIP   Microsoft.Network/publicIPAddresses
   vm-web-01VNET       Microsoft.Network/virtualNetworks
   ```

   Six resources for one VM. Memorise this list — it *is* the answer to "what resources does a VM require".

3. Inspect the compute shape and the disk that backs it:

   ```bash
   az vm show -g $RG -n vm-web-01 \
     --query "{Size:hardwareProfile.vmSize, Image:storageProfile.imageReference.sku, OsDiskType:storageProfile.osDisk.managedDisk.storageAccountType, OsDiskGB:storageProfile.osDisk.diskSizeGb, DataDisks:length(storageProfile.dataDisks)}" \
     --output json
   ```

   Expected:

   ```json
   {
     "DataDisks": 0,
     "Image": "22_04-lts-gen2",
     "OsDiskGB": 30,
     "OsDiskType": "Premium_LRS",
     "Size": "Standard_B1s"
   }
   ```

4. Attach a managed data disk — the durable storage tier a production workload actually writes to:

   ```bash
   az vm disk attach -g $RG --vm-name vm-web-01 \
     --name disk-data-01 --new --size-gb 32 --sku StandardSSD_LRS
   ```

   Verify:

   ```bash
   az vm show -g $RG -n vm-web-01 \
     --query "storageProfile.dataDisks[].{Name:name, Lun:lun, GB:diskSizeGb, Sku:managedDisk.storageAccountType}" -o table
   ```

   Expected:

   ```
   Name          Lun    GB    Sku
   ------------  -----  ----  ---------------
   disk-data-01  0      32    StandardSSD_LRS
   ```

5. Connect and look at what the guest OS sees. Note the **temporary disk**, which exists on the host's local SSD:

   ```bash
   az ssh vm -g $RG -n vm-web-01 -- 'lsblk; echo "---"; df -h /mnt'
   ```

   Expected (abridged):

   ```
   NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   sda       8:0    0    4G  0 disk
   └─sda1    8:1    0    4G  0 part /mnt
   sdb       8:16   0   32G  0 disk
   sdc       8:32   0   30G  0 disk
   ├─sdc1    8:33   0 29.9G  0 part /
   ---
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/sda1       3.9G   28K  3.7G   1% /mnt
   ```

   If `az ssh` is unavailable, use `ssh azureuser@<publicIpAddress>` with the IP from step 1.

6. Deallocate the VM and watch the difference between "stopped" and "deallocated":

   ```bash
   az vm deallocate -g $RG -n vm-web-01
   az vm get-instance-view -g $RG -n vm-web-01 \
     --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
   ```

   Expected:

   ```
   VM deallocated
   ```

   Restart it for the next exercise:

   ```bash
   az vm start -g $RG -n vm-web-01
   ```

### Comprehension check

- **Q4.** Of the six resources in step 2, which ones keep costing money while the VM is deallocated, and which one stops?
- **Q5.** In step 5 the guest saw three block devices. Which one must never hold data you care about, and what event destroys its contents?
- **Q6.** Step 1 created a VNet named `vm-web-01VNET` that you never asked for. What address space did it get, and why is accepting that default a problem in a real organisation?
- **Q7.** A colleague says "I shut the VM down from inside the OS with `sudo shutdown -h now`, so I'm not paying for it." Correct them precisely.
- **Q8.** The OS disk came back as `Premium_LRS` and the data disk you created as `StandardSSD_LRS`. Name the four managed-disk types available and state which one you would pick for a latency-sensitive database.

*Source: [Virtual machines in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/overview) · [Azure managed disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types) · [States and billing status of Azure VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing)*

---

## Exercise 2 — Availability sets, availability zones, and Virtual Machine Scale Sets

Three different answers to "how does this stay up", with three different failure domains and three different SLAs.

### Steps

1. Create an **availability set** and inspect its fault/update domain configuration:

   ```bash
   az vm availability-set create \
     -g $RG -n avset-web \
     --platform-fault-domain-count 2 \
     --platform-update-domain-count 5
   ```

   ```bash
   az vm availability-set show -g $RG -n avset-web \
     --query "{Name:name, FaultDomains:platformFaultDomainCount, UpdateDomains:platformUpdateDomainCount, Members:length(virtualMachines)}" -o json
   ```

   Expected:

   ```json
   {
     "FaultDomains": 2,
     "Members": 0,
     "Name": "avset-web",
     "UpdateDomains": 5
   }
   ```

2. Create a **Virtual Machine Scale Set** spread across all three availability zones. This is the modern pattern; it supersedes availability sets for new designs:

   ```bash
   az vmss create \
     -g $RG -n vmss-web \
     --image Ubuntu2204 \
     --vm-sku Standard_B1s \
     --instance-count 2 \
     --zones 1 2 3 \
     --orchestration-mode Flexible \
     --admin-username azureuser \
     --generate-ssh-keys \
     --upgrade-policy-mode Automatic \
     --output none
   ```

   This takes 2–4 minutes.

3. See where the instances actually landed:

   ```bash
   az vmss list-instances -g $RG -n vmss-web \
     --query "[].{Instance:instanceId, Zone:zones[0], State:provisioningState}" -o table
   ```

   Expected:

   ```
   Instance                              Zone    State
   ------------------------------------  ------  ---------
   vmss-web_a1b2c3                       1       Succeeded
   vmss-web_d4e5f6                       2       Succeeded
   ```

4. Attach an autoscale rule — the property that makes a scale set different from "some VMs I made by hand":

   ```bash
   az monitor autoscale create \
     -g $RG --resource vmss-web \
     --resource-type Microsoft.Compute/virtualMachineScaleSets \
     --name autoscale-vmss-web \
     --min-count 2 --max-count 6 --count 2 \
     --output none

   az monitor autoscale rule create \
     -g $RG --autoscale-name autoscale-vmss-web \
     --condition "Percentage CPU > 70 avg 5m" --scale out 1

   az monitor autoscale rule create \
     -g $RG --autoscale-name autoscale-vmss-web \
     --condition "Percentage CPU < 30 avg 10m" --scale in 1
   ```

   Confirm:

   ```bash
   az monitor autoscale show -g $RG -n autoscale-vmss-web \
     --query "profiles[0].{Min:capacity.minimum, Max:capacity.maximum, Default:capacity.default, Rules:length(rules)}" -o json
   ```

   Expected:

   ```json
   { "Default": "2", "Max": "6", "Min": "2", "Rules": 2 }
   ```

5. Manually override the capacity, to observe that scaling is a single declarative property:

   ```bash
   az vmss scale -g $RG -n vmss-web --new-capacity 3 --output none
   az vmss list-instances -g $RG -n vmss-web --query "length(@)" -o tsv
   ```

   Expected:

   ```
   3
   ```

6. Scale back down to keep the bill small:

   ```bash
   az vmss scale -g $RG -n vmss-web --new-capacity 2 --output none
   ```

### Comprehension check

- **Q9.** Distinguish, in one sentence each, what a **fault domain** protects against and what an **update domain** protects against.
- **Q10.** Your two VMs are in an availability set in `eastus`. A flood takes the entire `eastus` region offline. Are your VMs up? Now answer the same question for two VMs in availability zones 1 and 2.
- **Q11.** Match each configuration to its published composite SLA: (a) a single VM with all Premium SSD disks, (b) two or more VMs in the same availability set, (c) two or more VMs across two availability zones.
- **Q12.** Step 2 used `--orchestration-mode Flexible`. Contrast Flexible with Uniform orchestration in terms of what the platform manages for you.
- **Q13.** Step 4 created a rule "scale out when CPU > 70% averaged over 5 minutes". Is this vertical scaling or horizontal scaling? Give the Azure operation that would be the *other* kind for this workload.
- **Q14.** Why is `--min-count 2` a deliberate choice rather than `1`, given the answer to Q11?

*Source: [Availability options for Azure VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/availability) · [Virtual Machine Scale Sets overview](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview) · [SLA for Virtual Machines](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services)*

---

## Exercise 3 — Azure Virtual Desktop: the control plane without the session hosts

Azure Virtual Desktop (AVD) is a **desktop and app virtualization service**, not a VM SKU. Its control plane objects — host pool, application group, workspace — cost nothing; only the session-host VMs do. That lets you build the whole topology for free.

### Steps

1. Add the CLI extension:

   ```bash
   az extension add --name desktopvirtualization --upgrade
   az extension show --name desktopvirtualization --query "{Name:name, Version:version}" -o table
   ```

2. Create a **pooled** host pool — the multi-user model where many users share a set of session hosts:

   ```bash
   az desktopvirtualization hostpool create \
     -g $RG -n hp-az900 --location $LOC \
     --host-pool-type Pooled \
     --load-balancer-type BreadthFirst \
     --preferred-app-group-type Desktop \
     --max-session-limit 10 \
     --output json
   ```

   Expected (abridged):

   ```json
   {
     "hostPoolType": "Pooled",
     "loadBalancerType": "BreadthFirst",
     "maxSessionLimit": 10,
     "name": "hp-az900",
     "preferredAppGroupType": "Desktop",
     "type": "Microsoft.DesktopVirtualization/hostpools"
   }
   ```

3. Create the desktop application group and a workspace, then bind them:

   ```bash
   HP_ID=$(az desktopvirtualization hostpool show -g $RG -n hp-az900 --query id -o tsv)

   az desktopvirtualization applicationgroup create \
     -g $RG -n ag-desktop-az900 --location $LOC \
     --application-group-type Desktop \
     --host-pool-arm-path "$HP_ID" --output none

   AG_ID=$(az desktopvirtualization applicationgroup show -g $RG -n ag-desktop-az900 --query id -o tsv)

   az desktopvirtualization workspace create \
     -g $RG -n ws-az900 --location $LOC \
     --application-group-references "$AG_ID" --output none
   ```

4. Confirm the topology, and confirm there are **zero session hosts** — which is why this costs nothing:

   ```bash
   az desktopvirtualization workspace show -g $RG -n ws-az900 \
     --query "{Workspace:name, AppGroups:length(applicationGroupReferences)}" -o json
   az desktopvirtualization sessionhost list -g $RG --host-pool-name hp-az900 --query "length(@)" -o tsv
   ```

   Expected:

   ```json
   { "AppGroups": 1, "Workspace": "ws-az900" }
   ```
   ```
   0
   ```

### Comprehension check

- **Q15.** You just built a host pool, an application group and a workspace and were charged nothing. What exactly *is* billed in an AVD deployment?
- **Q16.** Contrast a **Pooled** host pool with a **Personal** host pool, and give one business scenario that forces Personal.
- **Q17.** AVD lets ten users share one session host. Which Windows client editions support that multi-session behaviour, and why can't you get it from a stock Windows 11 Pro image?
- **Q18.** Where does the user's data live in a well-designed AVD pooled deployment, given that the user is not guaranteed the same session host tomorrow?

*Source: [What is Azure Virtual Desktop?](https://learn.microsoft.com/en-us/azure/virtual-desktop/overview)*

---

## Exercise 4 — Application hosting: App Service, Container Instances, Container Apps, Functions

Four hosting models, deployed side by side. Watch how much infrastructure each one asks you to name.

### Steps

1. **App Service (PaaS web app).** First the plan — the compute the app runs on — then the app:

   ```bash
   az appservice plan create -g $RG -n plan-az900 --sku B1 --is-linux --output none

   az webapp create -g $RG --plan plan-az900 \
     -n web-az900-$SUFFIX --runtime "PYTHON:3.12" --output none

   az webapp show -g $RG -n web-az900-$SUFFIX \
     --query "{App:name, Host:defaultHostName, State:state, Https:httpsOnly}" -o json
   ```

   Expected:

   ```json
   {
     "App": "web-az900-4f2a",
     "Host": "web-az900-4f2a.azurewebsites.net",
     "Https": false,
     "State": "Running"
   }
   ```

2. Verify the platform is serving it, and harden the obvious default:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" https://web-az900-$SUFFIX.azurewebsites.net
   az webapp update -g $RG -n web-az900-$SUFFIX --https-only true --output none
   ```

   Expected:

   ```
   200
   ```

3. **Azure Container Instances (ACI).** A single container, no orchestrator, no plan to size:

   ```bash
   az container create \
     -g $RG -n aci-hello \
     --image mcr.microsoft.com/azuredocs/aci-helloworld \
     --os-type Linux --cpu 1 --memory 1.5 \
     --ports 80 --ip-address Public \
     --dns-name-label aci-az900-$SUFFIX \
     --restart-policy OnFailure \
     --output none

   az container show -g $RG -n aci-hello \
     --query "{FQDN:ipAddress.fqdn, IP:ipAddress.ip, State:instanceView.state, CPU:containers[0].resources.requests.cpu, MemGB:containers[0].resources.requests.memoryInGb}" -o json
   ```

   Expected:

   ```json
   {
     "CPU": 1.0,
     "FQDN": "aci-az900-4f2a.eastus.azurecontainer.io",
     "IP": "20.121.98.203",
     "MemGB": 1.5,
     "State": "Running"
   }
   ```

4. Read the container's logs straight from the platform — there is no host to SSH into:

   ```bash
   az container logs -g $RG -n aci-hello
   curl -s -o /dev/null -w "%{http_code}\n" http://aci-az900-$SUFFIX.$LOC.azurecontainer.io
   ```

   Expected:

   ```
   listening on port 80
   200
   ```

5. **Azure Functions (serverless / FaaS).** A Function App needs a storage account for its own state — triggers, checkpoints, and the function payload:

   ```bash
   az storage account create -g $RG -n stfn${SUFFIX}az900 \
     --sku Standard_LRS --kind StorageV2 --output none

   az functionapp create -g $RG -n fn-az900-$SUFFIX \
     --storage-account stfn${SUFFIX}az900 \
     --consumption-plan-location $LOC \
     --runtime python --runtime-version 3.12 \
     --functions-version 4 --os-type Linux \
     --output none

   az functionapp show -g $RG -n fn-az900-$SUFFIX \
     --query "{App:name, Host:defaultHostName, Sku:sku, State:state}" -o json
   ```

   Expected:

   ```json
   {
     "App": "fn-az900-4f2a",
     "Host": "fn-az900-4f2a.azurewebsites.net",
     "Sku": "Dynamic",
     "State": "Running"
   }
   ```

   `"Sku": "Dynamic"` is the Consumption plan — the tier that scales to zero.

6. Compare what each model made you specify. Count the parameters you supplied in steps 1, 3 and 5, and compare against Exercise 1 step 1:

   ```bash
   az resource list -g $RG --query "[].{Name:name, Type:type}" -o table
   ```

### Comprehension check

- **Q19.** Rank the four models — VM, App Service, Container Instances, Functions — from most to least infrastructure the *customer* is responsible for. Which service-model label (IaaS / PaaS / FaaS / SaaS) applies to each?
- **Q20.** In step 1 you created an App Service **plan** and then an **app**. What is the billing relationship between them, and what happens to cost if you deploy five more apps into `plan-az900`?
- **Q21.** ACI in step 3 never asked you for a VM size, a VNet, or a disk. What did it ask for instead, and what is the billing unit?
- **Q22.** Step 5 forced a storage account onto the Function App. Why does a "serverless" service need durable storage of its own?
- **Q23.** A batch job runs for 25 minutes. Explain why the Consumption plan is the wrong host for it, and name two alternatives that fix it.
- **Q24.** A team has three containers that must communicate, scale independently, and scale to zero at night, and they do not want to operate Kubernetes. Which Azure service fits — ACI, Azure Container Apps, or AKS? Justify against the other two.

*Source: [App Service overview](https://learn.microsoft.com/en-us/azure/app-service/overview) · [Container Instances overview](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-overview) · [Azure Functions hosting options](https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale) · [Azure Container Apps overview](https://learn.microsoft.com/en-us/azure/container-apps/overview)*

---

## Exercise 5 — Virtual networks, subnets, and the addresses Azure takes from you

### Steps

1. Build a hub VNet with an explicit address space and one subnet:

   ```bash
   az network vnet create \
     -g $RG -n vnet-hub \
     --address-prefixes 10.10.0.0/16 \
     --subnet-name snet-app --subnet-prefixes 10.10.1.0/24 \
     --output none

   az network vnet show -g $RG -n vnet-hub \
     --query "{VNet:name, Space:addressSpace.addressPrefixes, Subnets:subnets[].{Name:name,Prefix:addressPrefix}}" -o json
   ```

   Expected:

   ```json
   {
     "Space": ["10.10.0.0/16"],
     "Subnets": [{ "Name": "snet-app", "Prefix": "10.10.1.0/24" }],
     "VNet": "vnet-hub"
   }
   ```

2. Add a second subnet — segmentation inside one VNet:

   ```bash
   az network vnet subnet create \
     -g $RG --vnet-name vnet-hub -n snet-data \
     --address-prefixes 10.10.2.0/24 --output none
   ```

3. Ask Azure how many addresses that `/24` really gives you:

   ```bash
   az network vnet subnet show -g $RG --vnet-name vnet-hub -n snet-data \
     --query "{Prefix:addressPrefix, Available:availableIpAddressCount}" -o json
   ```

   Expected:

   ```json
   { "Available": 251, "Prefix": "10.10.2.0/24" }
   ```

   256 addresses in the CIDR block, 251 usable. Five are gone before you deploy anything.

4. Try to create a subnet that overlaps an existing one, and read the error carefully — this is the single most common VNet design mistake:

   ```bash
   az network vnet subnet create \
     -g $RG --vnet-name vnet-hub -n snet-bad \
     --address-prefixes 10.10.2.128/25
   ```

   Expected:

   ```
   (NetcfgSubnetRangesOverlap) Subnet 'snet-bad' is not valid because its IP address
   range overlaps with that of an existing subnet in virtual network 'vnet-hub'.
   Code: NetcfgSubnetRangesOverlap
   ```

5. Create a Network Security Group, attach it to the app subnet, and add an explicit rule:

   ```bash
   az network nsg create -g $RG -n nsg-app --output none

   az network nsg rule create \
     -g $RG --nsg-name nsg-app -n allow-https-inbound \
     --priority 100 --direction Inbound --access Allow \
     --protocol Tcp --source-address-prefixes Internet \
     --destination-port-ranges 443 --output none

   az network vnet subnet update \
     -g $RG --vnet-name vnet-hub -n snet-app \
     --network-security-group nsg-app --output none
   ```

6. Read the **default rules** Azure applies whether or not you write any:

   ```bash
   az network nsg show -g $RG -n nsg-app \
     --query "defaultSecurityRules[].{Priority:priority, Name:name, Direction:direction, Access:access, Src:sourceAddressPrefix, Dst:destinationAddressPrefix}" -o table
   ```

   Expected:

   ```
   Priority    Name                                  Direction    Access    Src               Dst
   ----------  ------------------------------------  -----------  --------  ----------------  ----------------
   65000       AllowVnetInBound                      Inbound      Allow     VirtualNetwork    VirtualNetwork
   65001       AllowAzureLoadBalancerInBound         Inbound      Allow     AzureLoadBalancer  *
   65500       DenyAllInBound                        Inbound      Deny      *                 *
   65000       AllowVnetOutBound                     Outbound     Allow     VirtualNetwork    VirtualNetwork
   65001       AllowInternetOutBound                 Outbound     Allow     *                 Internet
   65500       DenyAllOutBound                       Outbound     Deny      *                 *
   ```

### Comprehension check

- **Q25.** Step 3 reported 251 usable addresses in a `/24`. List the five addresses Azure reserves in every subnet and what each is for.
- **Q26.** What is the smallest and the largest IPv4 subnet Azure will accept? If a subnet must hold 12 VMs, what is the smallest prefix that works?
- **Q27.** In step 6, rule 65500 is `DenyAllInBound` and rule 65001 is `AllowInternetOutBound`. State the default posture of a brand-new NSG for inbound and for outbound traffic, and explain how priority ordering produces it.
- **Q28.** You attached `nsg-app` to a subnet. Where else can an NSG be attached, and what is the evaluation order when both are present for inbound traffic?
- **Q29.** Two departments each independently chose `10.0.0.0/16` for their VNet. What operation becomes impossible, and what is the fix?
- **Q30.** Is a virtual network a regional resource or a global one? Can a single subnet span two regions?

*Source: [Azure Virtual Network overview](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview) · [Network security groups](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview)*

---

## Exercise 6 — VNet peering and its non-transitivity

### Steps

1. Create a second and third VNet with non-overlapping spaces:

   ```bash
   az network vnet create -g $RG -n vnet-spoke-a \
     --address-prefixes 10.20.0.0/16 \
     --subnet-name snet-workload --subnet-prefixes 10.20.1.0/24 --output none

   az network vnet create -g $RG -n vnet-spoke-b \
     --address-prefixes 10.30.0.0/16 \
     --subnet-name snet-workload --subnet-prefixes 10.30.1.0/24 --output none
   ```

2. Peer hub → spoke-a, and **only that direction**, then read the state:

   ```bash
   az network vnet peering create \
     -g $RG -n hub-to-spoke-a --vnet-name vnet-hub \
     --remote-vnet vnet-spoke-a --allow-vnet-access --output none

   az network vnet peering list -g $RG --vnet-name vnet-hub \
     --query "[].{Name:name, State:peeringState, Sync:peeringSyncLevel}" -o table
   ```

   Expected:

   ```
   Name             State       Sync
   ---------------  ----------  ----------------
   hub-to-spoke-a   Initiated   RemoteNotInSync
   ```

   `Initiated`, not `Connected`. A peering is two objects, one per VNet.

3. Create the return link and re-read:

   ```bash
   az network vnet peering create \
     -g $RG -n spoke-a-to-hub --vnet-name vnet-spoke-a \
     --remote-vnet vnet-hub --allow-vnet-access --output none

   az network vnet peering list -g $RG --vnet-name vnet-hub \
     --query "[].{Name:name, State:peeringState}" -o table
   ```

   Expected:

   ```
   Name             State
   ---------------  ---------
   hub-to-spoke-a   Connected
   ```

4. Complete the hub-and-spoke by peering hub ↔ spoke-b as well:

   ```bash
   az network vnet peering create -g $RG -n hub-to-spoke-b \
     --vnet-name vnet-hub --remote-vnet vnet-spoke-b --allow-vnet-access --output none
   az network vnet peering create -g $RG -n spoke-b-to-hub \
     --vnet-name vnet-spoke-b --remote-vnet vnet-hub --allow-vnet-access --output none
   ```

5. Now inspect the **effective routes** on the VM's NIC. This is the diagnostic that answers "can A reach B" without guessing:

   ```bash
   NIC=$(az vm show -g $RG -n vm-web-01 --query "networkProfile.networkInterfaces[0].id" -o tsv)
   az network nic show-effective-route-table --ids $NIC -o table
   ```

   Expected (abridged — `vm-web-01` is still on its own default VNet from Exercise 1, so it sees no peering routes):

   ```
   Source    State    Address Prefix    Next Hop Type    Next Hop IP
   --------  -------  ----------------  ---------------  -------------
   Default   Active   10.0.0.0/16       VnetLocal
   Default   Active   0.0.0.0/0         Internet
   ```

6. List spoke-a's peerings to confirm what it can and cannot see:

   ```bash
   az network vnet peering list -g $RG --vnet-name vnet-spoke-a \
     --query "[].{Name:name, Remote:remoteVirtualNetwork.id, State:peeringState}" -o json \
     | jq -r '.[] | "\(.Name)  ->  \(.Remote | split("/") | last)  [\(.State)]"'
   ```

   Expected:

   ```
   spoke-a-to-hub  ->  vnet-hub  [Connected]
   ```

   One peering. Nothing pointing at `vnet-spoke-b`.

### Comprehension check

- **Q31.** After step 4, can a VM in `vnet-spoke-a` reach a VM in `vnet-spoke-b`? State the property of VNet peering that decides this.
- **Q32.** Name two ways to make spoke-to-spoke traffic work in a hub-and-spoke topology.
- **Q33.** Step 2 produced `Initiated` rather than `Connected`. Explain what that state means operationally and what a real outage caused by it would look like.
- **Q34.** Does peering traffic between two VNets in the same region traverse the public internet? What about two VNets in different regions (global peering)?
- **Q35.** Peering has no bandwidth cap and adds no latency-inducing appliance. How is it billed, and what is the practical consequence for a cross-region design?
- **Q36.** In step 5, why did `vm-web-01` show no routes to `10.20.0.0/16` even though the peerings are `Connected`?

*Source: [Virtual network peering](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview) · [Hub-and-spoke network topology](https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke)*

---

## Exercise 7 — Azure DNS: public zones and private zones

Azure DNS is **hosting**, not registration. Public zones answer the internet; private zones answer only linked VNets.

### Steps

1. Create a public DNS zone. You do not need to own the domain to create the zone — you need to own it to delegate to it:

   ```bash
   az network dns zone create -g $RG -n az900lab-$SUFFIX.example --output none

   az network dns zone show -g $RG -n az900lab-$SUFFIX.example \
     --query "{Zone:name, NameServers:nameServers, Records:numberOfRecordSets}" -o json
   ```

   Expected:

   ```json
   {
     "NameServers": [
       "ns1-04.azure-dns.com.",
       "ns2-04.azure-dns.net.",
       "ns3-04.azure-dns.org.",
       "ns4-04.azure-dns.info."
     ],
     "Records": 2,
     "Zone": "az900lab-4f2a.example"
   }
   ```

   Four name servers across four TLDs — that is the resilience design.

2. Add an A record and query Azure's own name server directly:

   ```bash
   az network dns record-set a add-record \
     -g $RG -z az900lab-$SUFFIX.example -n www -a 203.0.113.10 --output none

   NS=$(az network dns zone show -g $RG -n az900lab-$SUFFIX.example --query "nameServers[0]" -o tsv)
   dig @${NS%.} www.az900lab-$SUFFIX.example A +short
   ```

   Expected:

   ```
   203.0.113.10
   ```

   Now query it the normal way, without naming the server:

   ```bash
   dig www.az900lab-$SUFFIX.example A +short
   ```

   Expected:

   ```
   (empty)
   ```

3. Create a **private** DNS zone and link it to the hub VNet with auto-registration on:

   ```bash
   az network private-dns zone create -g $RG -n internal.az900.lab --output none

   az network private-dns link vnet create \
     -g $RG -z internal.az900.lab -n link-hub \
     -v vnet-hub -e true --output none

   az network private-dns link vnet list -g $RG -z internal.az900.lab \
     --query "[].{Link:name, Registration:registrationEnabled, State:virtualNetworkLinkState}" -o table
   ```

   Expected:

   ```
   Link      Registration    State
   --------  --------------  ---------
   link-hub  True            Completed
   ```

4. Add a manual record in the private zone:

   ```bash
   az network private-dns record-set a add-record \
     -g $RG -z internal.az900.lab -n db01 -a 10.10.2.20 --output none

   az network private-dns record-set list -g $RG -z internal.az900.lab \
     --query "[].{Name:name, Type:type, TTL:ttl}" -o table
   ```

   Expected:

   ```
   Name    Type                                             TTL
   ------  -----------------------------------------------  -----
   @       Microsoft.Network/privateDnsZones/SOA            3600
   db01    Microsoft.Network/privateDnsZones/A              3600
   ```

5. From your workstation, try to resolve the private record:

   ```bash
   dig db01.internal.az900.lab A +short
   ```

   Expected:

   ```
   (empty)
   ```

### Comprehension check

- **Q37.** Step 2 resolved when you asked Azure's name server directly but returned nothing from your normal resolver. What single step is missing, and where is it performed?
- **Q38.** Can you buy `contoso.com` in the Azure DNS blade? If not, which Azure offering registers a domain?
- **Q39.** Step 3 used `-e true` (registration enabled). What does that flag automate, and what is the limit on how many VNets in a private zone may have it turned on?
- **Q40.** Step 5 returned nothing from your workstation, but a VM inside `vnet-hub` would resolve `db01`. What resolver does that VM use, and at what well-known address does Azure expose it?
- **Q41.** Give the operational reason to use a private DNS zone rather than editing `/etc/hosts` on every VM.

*Source: [Azure DNS overview](https://learn.microsoft.com/en-us/azure/dns/dns-overview) · [Azure Private DNS overview](https://learn.microsoft.com/en-us/azure/dns/private-dns-overview)*

---

## Exercise 8 — Public endpoints, private endpoints, and Azure Private Link

This is the objective *"define public and private endpoints"*. You will take one PaaS service from internet-reachable to VNet-only and watch DNS change underneath it.

### Steps

1. Create a storage account. By default its blob service has a **public endpoint** with a public DNS name:

   ```bash
   az storage account create \
     -g $RG -n stpe${SUFFIX}az900 \
     --sku Standard_LRS --kind StorageV2 \
     --allow-blob-public-access false --output none

   az storage account show -g $RG -n stpe${SUFFIX}az900 \
     --query "{Name:name, Blob:primaryEndpoints.blob, PublicAccess:publicNetworkAccess}" -o json
   ```

   Expected:

   ```json
   {
     "Blob": "https://stpe4f2aaz900.blob.core.windows.net/",
     "Name": "stpe4f2aaz900",
     "PublicAccess": "Enabled"
   }
   ```

2. Resolve that name **before** any private endpoint exists — record the answer:

   ```bash
   dig stpe${SUFFIX}az900.blob.core.windows.net +short
   ```

   Expected:

   ```
   blob.bl2prdstr01a.store.core.windows.net.
   20.60.241.129
   ```

   A public IP. Anyone on the internet can reach this TCP endpoint; only authorization stops them.

3. Create the private DNS zone that Private Link requires, and link it to the VNet:

   ```bash
   az network private-dns zone create -g $RG -n privatelink.blob.core.windows.net --output none

   az network private-dns link vnet create \
     -g $RG -z privatelink.blob.core.windows.net \
     -n link-hub-blob -v vnet-hub -e false --output none
   ```

4. Create the **private endpoint** — a NIC in your subnet, with a private IP, bound to the `blob` sub-resource of that storage account:

   ```bash
   SA_ID=$(az storage account show -g $RG -n stpe${SUFFIX}az900 --query id -o tsv)

   az network private-endpoint create \
     -g $RG -n pe-blob \
     --vnet-name vnet-hub --subnet snet-data \
     --private-connection-resource-id "$SA_ID" \
     --group-id blob \
     --connection-name pe-blob-conn \
     --output none

   az network private-endpoint show -g $RG -n pe-blob \
     --query "{PE:name, Subnet:subnet.id, IP:customDnsConfigs[0].ipAddresses[0], FQDN:customDnsConfigs[0].fqdn, Status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o json
   ```

   Expected:

   ```json
   {
     "FQDN": "stpe4f2aaz900.blob.core.windows.net",
     "IP": "10.10.2.4",
     "PE": "pe-blob",
     "Status": "Approved",
     "Subnet": ".../virtualNetworks/vnet-hub/subnets/snet-data"
   }
   ```

   `10.10.2.4` — an address out of `snet-data`, the third usable IP in the subnet.

5. Wire the endpoint into the private DNS zone so the name resolves privately inside the VNet:

   ```bash
   az network private-endpoint dns-zone-group create \
     -g $RG --endpoint-name pe-blob -n zg-blob \
     --private-dns-zone privatelink.blob.core.windows.net \
     --zone-name blob --output none

   az network private-dns record-set a list -g $RG -z privatelink.blob.core.windows.net \
     --query "[].{Record:name, IP:aRecords[0].ipv4Address}" -o table
   ```

   Expected:

   ```
   Record          IP
   --------------  ---------
   stpe4f2aaz900   10.10.2.4
   ```

   Azure created that A record automatically from the endpoint's NIC.

6. Turn off the public endpoint entirely:

   ```bash
   az storage account update -g $RG -n stpe${SUFFIX}az900 \
     --public-network-access Disabled --output none

   az storage account show -g $RG -n stpe${SUFFIX}az900 \
     --query "{PublicAccess:publicNetworkAccess, DefaultAction:networkRuleSet.defaultAction}" -o json
   ```

   Expected:

   ```json
   { "DefaultAction": "Allow", "PublicAccess": "Disabled" }
   ```

7. Prove it from outside the VNet:

   ```bash
   az storage container list --account-name stpe${SUFFIX}az900 --auth-mode login -o table
   ```

   Expected:

   ```
   (AuthorizationFailure) This request is not authorized to perform this operation.
   RequestId: ...
   ```

   or, depending on client, a connection-level failure. From the internet the door is closed.

8. Resolve the name from *inside* the VNet and compare against step 2:

   ```bash
   az ssh vm -g $RG -n vm-web-01 -- "getent hosts stpe${SUFFIX}az900.blob.core.windows.net"
   ```

   > **Note:** `vm-web-01` lives in its own auto-created `vm-web-01VNET`, not in `vnet-hub`, so it will still resolve the *public* IP. That is the point of the next question. To see the private answer, deploy a VM into `snet-app` (which is inside `vnet-hub`) and repeat.

### Comprehension check

- **Q42.** Define, in one sentence each, a **public endpoint** and a **private endpoint**.
- **Q43.** In step 4 the private endpoint consumed `10.10.2.4` from `snet-data`. Which Azure resource type actually holds that IP, and what does that imply for subnet sizing when you deploy 40 private endpoints?
- **Q44.** Step 5 created an A record in `privatelink.blob.core.windows.net`, but applications keep using `stpe....blob.core.windows.net`. Trace the DNS resolution chain that makes the unchanged application name return a private IP inside the VNet.
- **Q45.** Step 8 came back with a public IP even though the private endpoint exists and is `Approved`. Why — and what is the general rule this illustrates about the scope of a private endpoint?
- **Q46.** Distinguish a **service endpoint** from a **private endpoint**. Which one gives the PaaS resource an IP inside your address space, and which one still uses the service's public IP?
- **Q47.** After step 6, a partner organisation in a different tenant needs read access to this storage account over a private connection. Is that possible with Private Link, and what does the `Approved` status in step 4 hint at?

*Source: [What is Azure Private Link?](https://learn.microsoft.com/en-us/azure/private-link/private-link-overview) · [Private endpoint overview](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview) · [Private endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)*

---

## Exercise 9 — Hybrid connectivity: VPN Gateway and ExpressRoute (read-only)

**Do not deploy a gateway.** A VPN Gateway takes 30–45 minutes to provision and bills per hour from the moment it exists. Everything below is free inspection of real API data.

### Steps

1. List the ExpressRoute providers and peering locations available to you. This is a live query against the Azure control plane:

   ```bash
   az network express-route list-service-providers \
     --query "[?contains(peeringLocations, 'Washington DC')].{Provider:name, Locations:peeringLocations, Bandwidths:bandwidthsOffered[].offerName}" \
     -o json | jq -r '.[] | "\(.Provider): \(.Bandwidths | join(", "))"' | head -10
   ```

   Expected (abridged — varies by region):

   ```
   Equinix: 50Mbps, 100Mbps, 200Mbps, 500Mbps, 1Gbps, 2Gbps, 5Gbps, 10Gbps
   Megaport: 50Mbps, 100Mbps, 200Mbps, 500Mbps, 1Gbps, 2Gbps, 5Gbps, 10Gbps
   Verizon: 50Mbps, 100Mbps, 200Mbps, 500Mbps, 1Gbps, 2Gbps, 5Gbps, 10Gbps
   ```

2. Pull real VPN Gateway pricing from the public Retail Prices API — no authentication needed:

   ```bash
   curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'VPN%20Gateway'%20and%20armRegionName%20eq%20'eastus'%20and%20priceType%20eq%20'Consumption'" \
     | jq -r '.Items[] | "\(.skuName)\t\(.meterName)\t\(.retailPrice) \(.currencyCode)/\(.unitOfMeasure)"' \
     | sort -u | head -12
   ```

   Expected (abridged; prices change):

   ```
   Basic     Basic Gateway       0.036 USD/1 Hour
   VpnGw1    VpnGw1 Gateway      0.19  USD/1 Hour
   VpnGw2    VpnGw2 Gateway      0.49  USD/1 Hour
   VpnGw3    VpnGw3 Gateway      1.25  USD/1 Hour
   VpnGw5    VpnGw5 Gateway      4.10  USD/1 Hour
   ```

3. Do the arithmetic that decides real architectures:

   ```bash
   echo "VpnGw1 monthly floor: $(echo '0.19 * 730' | bc) USD — before any data transfer"
   ```

   Expected:

   ```
   VpnGw1 monthly floor: 138.70 USD — before any data transfer
   ```

4. Study — **do not run** — the commands a real deployment would use. Note the subnet name is not a convention, it is a hard requirement:

   ```bash
   # DO NOT RUN — reference only. Provisions in 30-45 min, bills per hour.
   az network vnet subnet create \
     -g $RG --vnet-name vnet-hub -n GatewaySubnet \
     --address-prefixes 10.10.255.0/27

   az network public-ip create -g $RG -n pip-vpngw --sku Standard --allocation-method Static

   az network vnet-gateway create \
     -g $RG -n vpngw-hub \
     --vnet vnet-hub --public-ip-address pip-vpngw \
     --gateway-type Vpn --vpn-type RouteBased \
     --sku VpnGw1 --generation Generation2
   ```

5. Confirm no gateway exists in your resource group, so you are not being billed:

   ```bash
   az network vnet-gateway list -g $RG --query "length(@)" -o tsv
   ```

   Expected:

   ```
   0
   ```

### Comprehension check

- **Q48.** State the single most important architectural difference between a Site-to-Site VPN Gateway connection and an ExpressRoute circuit, in terms of the path the packets take.
- **Q49.** The gateway subnet in step 4 is named `GatewaySubnet`. What happens if you name it `snet-gateway` instead?
- **Q50.** Name the three VPN Gateway connection types and, for each, the scenario it serves.
- **Q51.** Compare maximum bandwidth: VPN Gateway (highest SKU) versus a standard ExpressRoute circuit versus ExpressRoute Direct.
- **Q52.** A finance company requires that traffic between its datacenter and Azure never traverse the public internet, and needs a bandwidth SLA. Which option do you specify, and what is the one thing an ExpressRoute circuit alone does *not* give them that they must add separately?
- **Q53.** Given step 3's USD 138.70/month floor for the smallest production VPN SKU, what would you tell a team whose only need is administrative SSH access to three VMs?

*Source: [VPN Gateway overview](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways) · [ExpressRoute overview](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-introduction) · [About gateway SKUs](https://learn.microsoft.com/en-us/azure/vpn-gateway/about-gateway-skus)*

---

## Exercise 10 — Teardown (mandatory)

### Steps

1. Take a final inventory of what you built, and note the count:

   ```bash
   az resource list -g $RG --query "length(@)" -o tsv
   az resource list -g $RG --query "[].{Name:name, Type:type, Location:location}" -o table
   ```

2. Delete the entire resource group. Everything created in this lab disappears with it:

   ```bash
   az group delete --name $RG --yes --no-wait
   ```

3. Confirm the deletion is under way:

   ```bash
   az group show -n $RG --query "properties.provisioningState" -o tsv
   ```

   Expected:

   ```
   Deleting
   ```

   And a few minutes later:

   ```
   (ResourceGroupNotFound) Resource group 'rg-az900-lab' could not be found.
   ```

4. Verify nothing survived at subscription scope:

   ```bash
   az resource list --query "[?resourceGroup=='rg-az900-lab'] | length(@)" -o tsv
   ```

   Expected:

   ```
   0
   ```

### Comprehension check

- **Q54.** Deleting one resource group removed a VM, a scale set, a web app, containers, VNets, peerings, DNS zones and a private endpoint. What does this tell you about the resource group as an organisational construct, and what is the one guardrail you would apply in production to prevent this exact command?
- **Q55.** Peerings are two objects, one in each VNet. When you deleted `vnet-hub`, what happened to `spoke-a-to-hub` — which lived in a VNet that was also in the group? Would the answer differ if `vnet-spoke-a` had been in a *different* resource group?

*Source: [Azure Resource Manager overview](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview) · [Lock resources to prevent changes](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources)*

---

<details>
<summary><strong>▶ Answers</strong></summary>

### Exercise 0

**A1.** No. A resource group's location stores only the **metadata** for the group — the record of which resources belong to it. Resources inside may live in any region. The location matters for one reason: if that region's Resource Manager metadata store is unavailable, you cannot *manage* (create, update, delete, tag) resources in that group, even though the resources themselves keep running normally in their own regions.

**A2.** No. Availability zone identifiers are **logical per subscription**. Zone "1" in your subscription and zone "1" in your colleague's subscription may map to different physical datacenters. Azure exposes a `physicalZone` mapping (`az rest` against the `locations` API with `ListAvailabilityZoneMappings`) precisely because comparing zone numbers across subscriptions is otherwise meaningless. Practically: never coordinate a multi-subscription deployment by zone number alone.

**A3.** No. Region pairing gives you (a) staggered platform maintenance — Azure does not update both regions of a pair simultaneously, (b) prioritised recovery order in a broad outage, and (c) a target for services with built-in geo-replication such as GRS storage. It does **not** replicate your VM. Cross-region VM resilience requires an explicit service — Azure Site Recovery, or an active/active deployment you design.

### Exercise 1

**A4.** Still billed while deallocated: the **OS disk**, the **data disk**, and the **Standard SKU public IP** (Standard public IPs are static and billed whether attached or not). Free either way: the **VNet**, the **NIC**, and the **NSG**. Stops being billed: the **VM compute** — the vCPU/RAM charge, which is the largest line item. This is why "deallocate" is the cost-saving verb and "stop" is not.

**A5.** `/dev/sda1`, mounted at `/mnt` (on Windows, the `D:` drive). This is the **temporary disk** — local SSD attached to the physical host, not a managed disk. It is wiped on deallocation, on host maintenance, on resize, and on any live-migration event. Use it for swap, scratch, and page files only. Note also that some VM series (`Dv5`, `Ev5`) ship with **no** temp disk at all; the `d`-suffixed variants (`Ddv5`, `Edv5`) are the ones that have it.

**A6.** It got `10.0.0.0/16` with a `10.0.0.0/24` subnet — the CLI default. The problem is **address-space collision**: `10.0.0.0/16` is the most-typed CIDR in the world. The moment you need to peer this VNet to another team's VNet, or to an on-premises range, the overlap blocks it, and VNet address space cannot be changed while resources with those IPs exist. Real organisations allocate CIDR blocks centrally from an IPAM before any VNet is created.

**A7.** A guest-OS shutdown puts the VM in the **Stopped** state, not **Stopped (deallocated)**. In `Stopped`, the VM still holds its allocation on a physical host — reserved vCPU and RAM — and Azure continues to bill compute. Only `az vm deallocate` (or "Stop" in the portal, which calls deallocate) releases the host allocation and stops the compute charge. Side effect worth knowing: deallocation also releases a *dynamic* public IP and the temp disk.

**A8.** The four types are **Standard HDD**, **Standard SSD**, **Premium SSD** (and **Premium SSD v2**), and **Ultra Disk**. For a latency-sensitive database, choose **Ultra Disk** when you need sub-millisecond latency with independently tunable IOPS and throughput, or **Premium SSD v2** as the cost-effective modern default — it decouples capacity from performance, unlike Premium SSD v1 where IOPS are tied to disk size. Note that Premium SSD/Ultra on *all* disks is also what qualifies a single-instance VM for the 99.9% SLA.

### Exercise 2

**A9.** A **fault domain** is a group of hardware sharing a common power source and network switch — it protects against a rack-level hardware failure. An **update domain** is a group that Azure reboots together during planned platform maintenance — it protects against your entire fleet going down at once during a host OS patch.

**A10.** Availability set: **down**. An availability set exists entirely inside a single datacenter; both fault and update domains are racks within one facility. Availability zones 1 and 2: also **down** — zones protect against a datacenter failure *within* a region, not against loss of the region itself. Regional loss requires a multi-region design.

**A11.** (a) single VM with all Premium SSD → **99.9%**; (b) two or more VMs in an availability set → **99.95%**; (c) two or more VMs across two availability zones → **99.99%**. (For contrast: single VM on Standard SSD is 99.5%, on Standard HDD 99%.)

**A12.** **Uniform** orchestration treats instances as identical, platform-managed clones from one model — you get maximum scale (up to 1,000 instances) and automatic OS upgrades, but the instances are not first-class VM objects. **Flexible** orchestration gives you real `Microsoft.Compute/virtualMachines` resources that you can attach to individually, mix sizes within the set, and manage with standard VM tooling, while still getting scale-set semantics like autoscale and fault-domain spreading. Flexible is the recommended default for new deployments.

**A13.** Horizontal scaling — **scaling out**, adding instances. The vertical equivalent would be **resizing** the VM SKU, e.g. `az vmss update --set virtualMachineProfile.hardwareProfile.vmSize=Standard_B2s`, which changes each instance's capacity rather than the instance count. Vertical scaling requires a restart and has a hard ceiling at the largest SKU; horizontal scaling does not.

**A14.** Because the 99.95%/99.99% SLAs require **two or more instances**. A minimum of 1 would let autoscale drain the set down to a single instance during quiet hours, silently dropping the deployment to the single-VM SLA at exactly the moment nobody is watching. Minimum-instance-count is an availability control, not just a cost control.

### Exercise 3

**A15.** The **session-host VMs** (compute + disks), any **storage** for FSLogix user profiles, **networking** egress, and the **Windows licensing** — which is included at no extra cost if users have an eligible Microsoft 365 E3/E5/A3/A5/F3/Business Premium or Windows E3/E5 licence, otherwise it is a per-user access charge. The AVD control plane — brokering, gateway, diagnostics, host pools, app groups, workspaces — is **free**.

**A16.** **Pooled**: many users share a set of session hosts, each user gets whatever host the load balancer picks, sessions are non-persistent. Highest density, lowest cost per user. **Personal**: each user is permanently assigned one dedicated session host. Forced by scenarios such as developers who install their own tooling, workloads requiring local admin rights, GPU/CAD workstations, or any regulated case where user-installed software must persist and be individually auditable.

**A17.** **Windows 11 Enterprise multi-session** and **Windows 10 Enterprise multi-session** — SKUs that exist only for AVD. Stock Windows 11 Pro enforces a single interactive session; the multi-session editions carry the licensing and kernel configuration that permit concurrent interactive sessions on one OS instance, which is what makes pooled host pools economically viable.

**A18.** In **profile containers** — FSLogix VHD/VHDX files stored on a network share (Azure Files, or Azure NetApp Files for high-scale) and mounted at logon onto whichever session host the user lands on. This is what makes non-persistent hosts feel persistent. Storing user data on the session host's local disk in a pooled deployment loses it as soon as the host is recycled.

### Exercise 4

**A19.** Most → least customer responsibility: **Virtual Machine (IaaS)** — you own OS, patching, runtime, middleware, app. **Container Instances (PaaS/CaaS)** — you own the container image and app; Microsoft owns the host and runtime. **App Service (PaaS)** — you own the app code and configuration; Microsoft owns OS, runtime patching, and scaling infrastructure. **Functions (FaaS/serverless)** — you own only the function body and its trigger binding. SaaS does not appear here; it would be a finished application like Microsoft 365, where you own only your data and identities.

**A20.** You are billed for the **plan**, not the app. The plan is the reserved compute (a B1 Linux instance here); apps are logical tenants on it. Deploying five more apps into `plan-az900` costs **nothing additional** — but all six now contend for the same CPU and RAM. This is the standard App Service cost lever and the standard App Service noisy-neighbour trap.

**A21.** It asked for the **container image**, **CPU cores**, **memory in GB**, exposed **ports**, an optional **DNS name label**, and a **restart policy**. Billing is **per-second**, based on the vCPU-seconds and GB-seconds requested from container start to stop. There is no idle instance to pay for and no host to patch — which makes ACI ideal for short-lived, bursty, or task-shaped workloads.

**A22.** The Consumption-plan Function App is stateless compute that can be torn down entirely, so its durable state lives elsewhere. The storage account holds: the function code package itself (via `WEBSITE_RUN_FROM_PACKAGE`), trigger metadata and **lease/checkpoint blobs** that coordinate which instance owns which partition, timer-trigger schedule state, and the Durable Functions task hub if used. Delete that storage account and the Function App stops working.

**A23.** The Consumption plan has a default `functionTimeout` of 5 minutes and a **hard maximum of 10 minutes** — a 25-minute job is killed mid-run. Fixes: (1) the **Premium plan** (Elastic Premium), which allows unbounded timeout plus pre-warmed instances and VNet integration; (2) the **Dedicated (App Service) plan**, where the function runs on compute you already pay for; (3) architecturally better — decompose into **Durable Functions** so each activity finishes inside the limit and the orchestrator handles the long-running coordination. (The newer **Flex Consumption** plan also raises the timeout while retaining scale-to-zero.)

**A24.** **Azure Container Apps.** ACI is wrong: it has no built-in service discovery between containers, no scale-to-zero autoscaling, and no revision/traffic-splitting model — you would be hand-building an orchestrator. AKS would work but hands the team a Kubernetes control plane, node pools, upgrades, and CNI to operate, which is exactly what they excluded. Container Apps is built on AKS + KEDA + Dapr + Envoy but hides all of it: it gives HTTP and event-driven autoscaling **including scale to zero**, per-app independent scaling, built-in service discovery, and revision-based traffic splitting.

### Exercise 5

**A25.** In every Azure subnet, five addresses are reserved: **`x.x.x.0`** — network address; **`x.x.x.1`** — the default gateway; **`x.x.x.2`** and **`x.x.x.3`** — reserved to map the Azure DNS IPs into the VNet space; **`x.x.x.255`** (the last address of the block) — network broadcast address. Hence a `/24` yields 251, not 254 as classic subnetting would suggest.

**A26.** Smallest supported IPv4 subnet: **`/29`** (8 addresses, 3 usable after the 5 reservations). Largest: **`/2`**. For 12 VMs you need ≥ 12 usable, so `/28` gives 16 − 5 = 11 → not enough; **`/27`** gives 32 − 5 = 27 usable → this is the smallest that works. Note the trap: the naive answer `/28` fails precisely because of Azure's five reservations.

**A27.** Default posture: **all inbound traffic from outside the VNet is denied**; **all outbound traffic, including to the internet, is allowed**. The mechanism is priority ordering — NSG rules are evaluated lowest priority number first, and the first match wins. `AllowVnetInBound` (65000) permits intra-VNet traffic, `AllowAzureLoadBalancerInBound` (65001) permits health probes, then `DenyAllInBound` (65500) catches everything else. Your custom rules use priorities 100–4096, so they are always evaluated before the defaults and can override them.

**A28.** An NSG can also be attached to a **network interface (NIC)**. When both exist, **inbound** traffic is evaluated at the **subnet NSG first, then the NIC NSG** — the packet must be allowed by both. Outbound is the reverse: **NIC NSG first, then subnet NSG**. This is why a "correct" NIC rule can still be silently blocked by a subnet rule, and why `az network nic list-effective-nsg` exists — it shows the merged, actually-applied result rather than either rule set in isolation.

**A29.** **VNet peering** becomes impossible — Azure rejects a peering whose address spaces overlap, because routing would be ambiguous. So does any hybrid connection where both ranges must be reachable from on-premises. The fix is to **re-address one VNet**, which means redeploying every resource holding an IP in the conflicting range; address space cannot be changed under live resources. The prevention is centralised IP address management before the first VNet is created.

**A30.** A virtual network is a **regional** resource — it is scoped to exactly one region (and one subscription). A subnet is a subdivision of that VNet and therefore also cannot span regions. A VNet *can* span all availability zones within its region, which is why zone-redundant deployments share a single VNet. To connect VNets across regions you use **global VNet peering**.

### Exercise 6

**A31.** **No.** VNet peering is **non-transitive**. Spoke-a is peered to the hub and spoke-b is peered to the hub, but that does not create a route between the spokes — peering installs routes only for the *directly* peered VNet's address space. Traffic from `10.20.1.0/24` to `10.30.1.0/24` has no next hop and is dropped.

**A32.** (1) **Direct peering** between spoke-a and spoke-b — simple, but the number of peerings grows as n(n−1)/2 and becomes unmanageable past a handful of spokes. (2) **A network virtual appliance or Azure Firewall in the hub**, combined with user-defined routes (UDRs) in each spoke pointing the other spoke's prefix at the hub appliance, plus `--allow-forwarded-traffic` on the peerings. This is the standard hub-and-spoke pattern and gives you a central inspection point. (**Azure Virtual WAN** is the managed version of option 2.)

**A33.** `Initiated` means this side of the peering exists but the reciprocal peering on the remote VNet does not — it is a half-open link, and **no traffic flows**. Operationally this is a classic outage: an engineer creates one peering, sees "the peering is there" in the portal, and cannot understand why connectivity fails. The state only becomes `Connected` when both peering objects exist and reference each other. Same failure mode appears as `Disconnected` if someone later deletes one side.

**A34.** Neither traverses the public internet. Same-region peering keeps traffic on the **Azure datacenter network**; global peering (different regions) keeps it on the **Microsoft global backbone**. In both cases traffic is private, and no gateway, appliance, or encryption tunnel is involved. Traffic between peered VNets is *not* encrypted by the platform by default, however — global peering traffic is encrypted at the physical layer between Microsoft datacenters, but if you need application-visible encryption you provide it yourself (TLS, or the newer VNet encryption feature on supported SKUs).

**A35.** Billed on **data transferred in and out** of each peered VNet — both directions are charged. Same-region peering is inexpensive; **global (cross-region) peering costs substantially more per GB**, with rates varying by the zone-pair of the regions involved. Consequence: a chatty cross-region hub-and-spoke can quietly generate a large bandwidth bill. Design so that high-volume, latency-sensitive traffic stays within a region, and let cross-region traffic be control-plane-shaped rather than data-plane-shaped.

**A36.** Because `vm-web-01` is not in `vnet-hub`. Exercise 1 auto-created `vm-web-01VNET` (`10.0.0.0/16`) for that VM, and the peerings you built connect `vnet-hub` to the spokes. Peering routes are installed only into the VNets party to the peering. This is the exact same class of mistake as A45 — an Azure networking feature is scoped to a specific VNet, and resources outside it are unaffected no matter how correct the configuration looks in the portal.

### Exercise 7

**A37.** **Delegation.** Azure DNS is now authoritative for the zone, but nothing on the internet knows that. You must go to the **domain registrar** where the domain is registered and replace its NS records with the four `nameServers` values Azure returned in step 1. Until that delegation exists at the parent zone, public resolvers follow the old NS records and never reach Azure. Note where this is done: at the registrar, *outside* Azure.

**A38.** **No** — Azure DNS hosts zones and answers queries; it is not a registrar. To register a domain from within Azure you use **App Service Domains** (which registers through a partner registrar and can auto-create the Azure DNS zone with delegation already configured). The distinction between *registering* a name and *hosting* its zone is a common exam trap.

**A39.** With registration enabled, VMs deployed into that linked VNet get their **A records created and removed automatically** in the private zone as they are created and deleted — no manual record management, and stale records disappear on VM deletion. The limit: **only one VNet per private DNS zone may have auto-registration enabled**. Additional VNets can be linked for *resolution* (`-e false`), which is exactly what you did in Exercise 8 step 3 — those VNets can resolve names in the zone but do not register their own VMs into it.

**A40.** The VM uses **Azure-provided DNS** (the "Azure DNS default" recursive resolver), reachable at the well-known virtual IP **`168.63.129.16`**. That address is a special Azure platform IP, identical in every VNet in every region, that also serves DHCP, the health probe for load balancers, and the VM agent's communication channel. When a VNet is linked to a private DNS zone, the resolver at `168.63.129.16` answers for that zone's records; queries from outside the linked VNets never reach it.

**A41.** **Scale and correctness under change.** `/etc/hosts` is a per-VM file: adding a service means editing every VM, and changing an IP means finding every stale copy. A private DNS zone is a single authoritative source, automatically consumed by every linked VNet, and with auto-registration it stays correct as VMs come and go — no configuration management run required. It also works for services that are not VMs at all (private endpoints, as Exercise 8 shows), which `/etc/hosts` on a VM cannot help with when the client is a PaaS service.

### Exercise 8

**A42.** A **public endpoint** is a service's publicly routable IP address and DNS name, reachable from anywhere on the internet — access is governed only by authentication/authorization and any IP firewall rules, not by network placement. A **private endpoint** is a network interface with a **private IP address from your own VNet subnet**, which maps to a specific instance of a PaaS service via Azure Private Link, so the service becomes reachable as though it were a resource inside your network.

**A43.** The IP belongs to a **network interface (`Microsoft.Network/networkInterfaces`)** that Azure creates and attaches to the private endpoint. Each private endpoint consumes exactly one private IP from the subnet. So 40 private endpoints consume 40 addresses on top of the 5 platform reservations — a `/26` (64 addresses, 59 usable) is comfortable, a `/27` (27 usable) is not. Subnet sizing for private-endpoint subnets must be planned against the *count of PaaS services*, not the count of VMs, and the subnet cannot be resized upward once neighbours occupy the adjacent space.

**A44.** The chain: the application resolves `stpe....blob.core.windows.net`; Azure's public DNS returns a **CNAME** pointing to `stpe....privatelink.blob.core.windows.net`. Outside the VNet, that name resolves onward through public DNS to the service's public IP. Inside the VNet, the linked **private DNS zone `privatelink.blob.core.windows.net`** is authoritative for that suffix, so the resolver at `168.63.129.16` answers from the A record the DNS zone group created — `10.10.2.4`. The application connection string never changes; only the answer does, and it changes based on *where the query comes from*. This CNAME-to-privatelink indirection is the whole mechanism, and misconfigured DNS is the number-one cause of broken private endpoints.

**A45.** Because `vm-web-01` lives in `vm-web-01VNET`, not in `vnet-hub`, and only `vnet-hub` is linked to the `privatelink.blob.core.windows.net` private DNS zone. The general rule: **a private endpoint's private IP is reachable, and its private DNS answer is served, only from networks that have a route to that subnet and a link to that DNS zone** — the VNet containing the endpoint, VNets peered to it, and on-premises networks connected via VPN/ExpressRoute with DNS forwarding configured. Creating a private endpoint does not make it globally visible; you must extend both *routing* and *DNS* to every network that needs it.

**A46.** A **service endpoint** extends your VNet's identity to the PaaS service over the Azure backbone: traffic leaves your subnet, stays off the public internet, and the service sees it arriving from a known VNet/subnet — but the destination is still the service's **public IP**, and the service still has a public endpoint. A **private endpoint** allocates an IP **inside your address space** and lets you disable the public endpoint entirely. Other differences that matter: service endpoints are free, per-service, and do not work from on-premises; private endpoints cost money, are per-*resource-instance* and per-sub-resource (`blob` vs `file` vs `table` are separate endpoints), and *do* work from on-premises over VPN/ExpressRoute. Private endpoint is the direction Microsoft recommends for new designs.

**A47.** **Yes** — this is a first-class Private Link scenario. The partner creates a private endpoint in *their* VNet, in *their* tenant, targeting your storage account by resource ID (or by alias). Because it is cross-tenant, the connection arrives in `Pending` state and **you must explicitly approve it** (`az network private-endpoint-connection approve`). That is what the `Approved` status in step 4 was showing: your own endpoint was auto-approved because you had write permission on the storage account. The approval workflow is the security boundary that makes cross-tenant Private Link safe — the consumer can request, but only the resource owner can grant.

### Exercise 9

**A48.** **VPN Gateway** builds an encrypted IPsec/IKE tunnel **over the public internet** — the packets traverse ISP networks, protected by encryption, with best-effort latency and no bandwidth guarantee. **ExpressRoute** is a **private circuit through a connectivity provider directly into the Microsoft global network** — the packets never touch the public internet at all, and the circuit carries a bandwidth commitment and an availability SLA.

**A49.** Gateway creation **fails**. `GatewaySubnet` is a reserved, case-sensitive name that Azure Resource Manager matches literally; the VPN/ExpressRoute gateway service will not deploy into a subnet with any other name. Two further constraints: do not attach an NSG to `GatewaySubnet` (it breaks the gateway's control-plane traffic), and size it at least `/27` (`/29` is the bare minimum but leaves no room for ExpressRoute coexistence or future gateway features).

**A50.** (1) **Site-to-Site (S2S)** — connects an entire on-premises network to a VNet via an on-premises VPN device with a public IP; the standard hybrid-datacenter pattern. (2) **Point-to-Site (P2S)** — connects an individual client machine to a VNet, no on-premises device required; for remote developers and administrators. (3) **VNet-to-VNet** — connects two VNets through their gateways; largely superseded by VNet peering, which is faster and cheaper, but still relevant when the VNets are in different subscriptions/tenants with organisational constraints, or when you specifically want an encrypted tunnel.

**A51.** **VPN Gateway**: up to **10 Gbps** aggregate on the highest SKU (VpnGw5/VpnGw5AZ), though a single IPsec tunnel is capped well below that — around 1–1.25 Gbps — so reaching the aggregate requires multiple tunnels. **Standard ExpressRoute circuit**: **50 Mbps to 10 Gbps**, provisioned as a fixed committed bandwidth. **ExpressRoute Direct**: **10 Gbps or 100 Gbps** port pairs, connecting directly into Microsoft's network without a service provider in the path.

**A52.** Specify **ExpressRoute** — it is the only option meeting "never traverses the public internet" plus a bandwidth SLA. What it does not give them is **encryption**. An ExpressRoute circuit is private but not encrypted at the IP layer; a private circuit is not the same as a confidential one. If the compliance requirement includes encryption in transit, add either **MACsec** on ExpressRoute Direct (layer 2), or a **Site-to-Site VPN tunnel running over the ExpressRoute private peering** (layer 3). A second common answer: ExpressRoute alone is a single point of failure unless you provision a redundant circuit or configure a VPN Gateway as a documented failover path.

**A53.** Do not deploy a gateway. For administrative access to a handful of VMs, use **Azure Bastion** (managed, browser/native RDP-SSH over TLS with no public IP on the VMs, roughly USD 0.19/hour for the Basic SKU plus outbound data — and it removes the public IPs, which is a security improvement, not just a cost one) or, cheaper still, **Point-to-Site VPN** on a Basic gateway if a full tunnel really is needed. Better yet, ask whether interactive SSH is required at all: `az ssh`/Run Command, Azure Automation, and immutable-image deployment pipelines remove the requirement rather than paying USD 1,664/year to satisfy it. The general principle: a Site-to-Site gateway is justified by *network* integration — reaching many private resources from many on-premises clients — not by administrative access to a few hosts.

### Exercise 10

**A54.** The resource group is the **lifecycle and management boundary** in Azure Resource Manager: resources grouped together are meant to be created, updated, permissioned, and destroyed as a unit. Deleting the group is a single, non-recoverable operation across every resource inside it, regardless of type or region. The production guardrail is a **resource lock** — `az lock create --lock-type CanNotDelete` (or `ReadOnly`) at the resource-group scope, which causes the delete to be rejected until someone with `Microsoft.Authorization/locks/delete` permission explicitly removes it. Locks are inherited by child resources and apply to *all* users including subscription owners, which is exactly the point: they defend against authorised-but-mistaken actions, which RBAC by design does not. Pair it with **Azure Policy** for prevention at scale and **deleteLock**-aware pipeline steps so automation does not fight the guardrail.

**A55.** When you deleted the resource group, both `vnet-hub` and `vnet-spoke-a` were inside it, so both VNets and both peering objects were removed together. Had `vnet-spoke-a` been in a **different resource group**, deleting `vnet-hub`'s group would have destroyed `vnet-hub` and its `hub-to-spoke-a` peering, while `spoke-a-to-hub` would survive as an **orphaned peering in `Disconnected` state** — pointing at a VNet that no longer exists. It stays there, non-functional, until deleted explicitly. This is a real cleanup hazard in hub-and-spoke estates where the hub and spokes are deliberately in separate resource groups (or separate subscriptions) for RBAC reasons: deleting one side leaves visible-but-dead configuration on the other.

</details>

---

## References

All URLs verified against Microsoft Learn official documentation.

- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Virtual machines in Azure — https://learn.microsoft.com/en-us/azure/virtual-machines/overview
- Azure managed disk types — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types
- States and billing status of Azure VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing
- Availability options for Azure VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Virtual Machine Scale Sets overview — https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview
- Regions and availability zones — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Azure region pairs — https://learn.microsoft.com/en-us/azure/reliability/regions-paired
- What is Azure Virtual Desktop? — https://learn.microsoft.com/en-us/azure/virtual-desktop/overview
- App Service overview — https://learn.microsoft.com/en-us/azure/app-service/overview
- Container Instances overview — https://learn.microsoft.com/en-us/azure/container-instances/container-instances-overview
- Azure Container Apps overview — https://learn.microsoft.com/en-us/azure/container-apps/overview
- Azure Functions scale and hosting — https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Azure Virtual Network overview — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview
- Network security groups — https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Virtual network peering — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
- Hub-and-spoke network topology — https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke
- Azure DNS overview — https://learn.microsoft.com/en-us/azure/dns/dns-overview
- Azure Private DNS overview — https://learn.microsoft.com/en-us/azure/dns/private-dns-overview
- What is Azure Private Link? — https://learn.microsoft.com/en-us/azure/private-link/private-link-overview
- Private endpoint overview — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview
- Private endpoint DNS configuration — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
- VPN Gateway overview — https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways
- About VPN Gateway SKUs — https://learn.microsoft.com/en-us/azure/vpn-gateway/about-gateway-skus
- ExpressRoute overview — https://learn.microsoft.com/en-us/azure/expressroute/expressroute-introduction
- Azure Bastion overview — https://learn.microsoft.com/en-us/azure/bastion/bastion-overview
- Azure Resource Manager overview — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Lock resources to prevent changes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Azure Retail Prices API — https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices