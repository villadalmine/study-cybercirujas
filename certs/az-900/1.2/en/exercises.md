# Exercises — 1.2 Describe the Benefits of Using Cloud Services

**Certification:** AZ-900 (exam version 2026-07-20) · **Exam weight:** 9.4
**Format:** hands-on. Every command below is real and runnable. Outputs shown are representative — the values your subscription returns are the authoritative ones, and part of the point of these exercises is that *the platform, not the marketing page, is the source of truth*.

> **Cost warning.** Blocks 2, 4 and 7 create billable resources (a VM Scale Set, storage accounts). Total cost if you finish in one sitting is under **USD 1**. Block 8 is the teardown — do not skip it. Blocks 1, 3 and 5 are read-only and free.
>
> **Permissions.** You need `Contributor` on a resource group plus `Resource Policy Contributor` and `User Access Administrator` (or `Owner`) at subscription scope for Block 6.

---

## Block 0 — Environment and the mental model you will test

**Goal:** get a reproducible shell, and fix the vocabulary before you measure anything.

The four benefits AZ-900 asks about are not slogans; each one is a *measurable platform property* with a knob you can turn:

| Benefit | The property being claimed | Where the platform exposes it |
|---|---|---|
| High availability | % of time the service answers | SLA tier, availability zones, fault/update domains |
| Scalability | capacity follows demand | vertical (SKU change) / horizontal (instance count) |
| Reliability & predictability | it survives failure *and* behaves the same tomorrow | redundancy options, SKU performance caps, budgets |
| Security & governance | non-compliant states are prevented, not just reported | Azure Policy effects, RBAC, Defender for Cloud |
| Manageability | the desired state is declared, not clicked | ARM/Bicep, autoscale, Monitor, Resource Health |

### Steps

1. Verify your tooling. Azure CLI 2.60+ is assumed; `jq` is used for JSON shaping.

   ```bash
   az version --output json | jq -r '."azure-cli"'
   jq --version
   ```

   ```
   2.67.0
   jq-1.7.1
   ```

2. Authenticate and pin the subscription explicitly. Never rely on the default — a wrong default subscription is the single most common cause of "my resources vanished".

   ```bash
   az login --only-show-errors >/dev/null
   az account list --query "[].{Name:name, Id:id, Default:isDefault}" --output table
   ```

   ```
   Name                      Id                                    Default
   ------------------------  ------------------------------------  ---------
   Visual Studio Enterprise  8f2c1b74-3d9a-4a1e-9f0b-2c7d5e6a1b33  True
   Production                1a0e6c52-77b4-4c1f-8e3d-90a4b2c11d55  False
   ```

3. Export the variables the rest of the exercises reuse. Using a single region with zone support is a hard requirement for Blocks 1, 2 and 4.

   ```bash
   export SUB=$(az account show --query id --output tsv)
   export LOC=eastus
   export RG=rg-az900-benefits
   az account set --subscription "$SUB"
   az group create --name "$RG" --location "$LOC" --tags course=az900 topic=1.2 owner="$USER" \
     --query "{name:name, location:location, state:properties.provisioningState}" --output json
   ```

   ```json
   {
     "name": "rg-az900-benefits",
     "location": "eastus",
     "state": "Succeeded"
   }
   ```

4. Confirm the resource providers you will need are registered in this subscription. An unregistered provider fails deployments with a message that looks like a permission error but is not.

   ```bash
   for p in Microsoft.Compute Microsoft.Storage Microsoft.Insights Microsoft.PolicyInsights Microsoft.ResourceHealth; do
     printf '%-28s %s\n' "$p" "$(az provider show --namespace $p --query registrationState --output tsv)"
   done
   ```

   ```
   Microsoft.Compute            Registered
   Microsoft.Storage            Registered
   Microsoft.Insights           Registered
   Microsoft.PolicyInsights     Registered
   Microsoft.ResourceHealth     NotRegistered
   ```

5. Register anything that came back `NotRegistered`. Registration is asynchronous and idempotent.

   ```bash
   az provider register --namespace Microsoft.ResourceHealth --wait
   az provider show --namespace Microsoft.ResourceHealth --query registrationState --output tsv
   ```

   ```
   Registered
   ```

#### Check your understanding

- **Q0.1** — You ran `az group create` twice with identical arguments and got `Succeeded` both times, with no error. What ARM property makes this safe, and why does the same guarantee *not* hold for `az vmss scale`?
- **Q0.2** — Resource provider registration is per-subscription, not per-resource-group. What does that tell you about where the provider's control-plane state lives in the Azure resource hierarchy?

---

## Block 1 — High availability: derive the SLA instead of quoting it

**Goal:** stop treating "99.99%" as a number you memorise. You will read zone topology out of the API, convert an SLA into a downtime budget, and compose a multi-service SLA — which is the calculation that actually decides architectures.

### Steps

1. List the physical regions that expose availability zones. `availabilityZoneMappings` is the authoritative signal; a region without it has no AZs, and no amount of architecture will get you 99.99% there.

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && availabilityZoneMappings != null].{Region:name, Display:displayName, Zones:length(availabilityZoneMappings)}" \
     --output table | head -15
   ```

   ```
   Region          Display              Zones
   --------------  -------------------  -------
   eastus          East US              3
   eastus2         East US 2            3
   westus2         West US 2            3
   westus3         West US 3            3
   northeurope     North Europe         3
   westeurope      West Europe          3
   brazilsouth     Brazil South         3
   southeastasia   Southeast Asia       3
   ```

2. Now inspect the mapping itself. This is the detail that surprises most people in production.

   ```bash
   az account list-locations \
     --query "[?name=='$LOC'].availabilityZoneMappings[]" --output table
   ```

   ```
   LogicalZone    PhysicalZone
   -------------  --------------
   1              eastus-az1
   2              eastus-az3
   3              eastus-az2
   ```

   Logical zone `1` in **your** subscription is not necessarily physical zone `1` in someone else's. Azure randomises the mapping per subscription so that customer deployments spread evenly across datacentres. Two subscriptions both deploying "zone 1" may land in different buildings — which is why cross-subscription zone alignment requires this API, not an assumption.

3. Confirm the VM SKU you intend to use is actually offered in all three zones. SKU availability is per zone, not per region.

   ```bash
   az vm list-skus --location "$LOC" --size Standard_D2s_v5 --resource-type virtualMachines \
     --query "[0].{Name:name, Zones:locationInfo[0].zones, Restrictions:restrictions[].reasonCode}" --output json
   ```

   ```json
   {
     "Name": "Standard_D2s_v5",
     "Zones": ["1", "2", "3"],
     "Restrictions": []
   }
   ```

   A non-empty `Restrictions` array containing `NotAvailableForSubscription` means the SKU exists in the region but your subscription cannot deploy it there — a capacity or quota restriction, and a very common cause of a "zone-redundant" design silently degrading to two zones.

4. Convert SLA percentages into a downtime budget. Percentages are not intuitive; minutes are.

   ```bash
   for sla in 99 99.9 99.95 99.99 99.999; do
     awk -v s="$sla" 'BEGIN {
       d = (100 - s) / 100
       printf "%-8s  %10.2f h/year  %10.2f min/month\n", s"%", d*8760, d*43800
     }'
   done
   ```

   ```
   99%           87.60 h/year      438.00 min/month
   99.9%          8.76 h/year       43.80 min/month
   99.95%         4.38 h/year       21.90 min/month
   99.99%         0.88 h/year        4.38 min/month
   99.999%        0.09 h/year        0.44 min/month
   ```

   The jump from 99.9% to 99.99% removes ~39 minutes of permitted monthly downtime. That is less than one careless deployment. This is why "four nines" is an *operational* commitment, not only an architectural one.

5. Compute a **composite SLA** for a serial dependency chain — a web tier that must call a database that must reach storage. Components in series *multiply*.

   ```bash
   awk 'BEGIN {
     web = 0.9995; db = 0.9999; storage = 0.999
     c = web * db * storage
     printf "Composite: %.6f%%   Downtime: %.2f h/year\n", c*100, (1-c)*8760
   }'
   ```

   ```
   Composite: 99.840065%   Downtime: 14.01 h/year
   ```

   Three healthy-looking SLAs produce a system worse than any of them. **Every dependency you add lowers the ceiling.**

6. Now compute the same storage tier deployed as two independent replicas behind a load balancer — components in *parallel*, where the system survives if either one lives.

   ```bash
   awk 'BEGIN {
     a = 0.999
     c = 1 - (1 - a) * (1 - a)
     printf "Redundant pair: %.6f%%   Downtime: %.2f min/year\n", c*100, (1-c)*525600
   }'
   ```

   ```
   Redundant pair: 99.999900%   Downtime: 0.53 min/year
   ```

   The arithmetic assumes the two replicas fail **independently**. If both sit in the same rack, share a power feed, or read the same corrupted control-plane record, the independence assumption collapses and the real number reverts toward 99.9%. Availability zones exist precisely to make that independence assumption defensible: separate power, cooling and networking, within a latency envelope that still allows synchronous replication.

7. Cross-check the deployment shapes and the SLA tier each one buys, straight from the SLA document ([Microsoft SLA for Online Services](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services)):

   | Deployment shape | VM connectivity SLA | Failure domain it survives |
   |---|---|---|
   | Single VM, Standard HDD OS/data disks | 95% | none |
   | Single VM, Standard SSD OS/data disks | 99.5% | none |
   | Single VM, Premium SSD or Ultra Disk | 99.9% | host reboot only (via live migration) |
   | 2+ VMs in an availability set | 99.95% | rack (fault domain) and host patching (update domain) |
   | 2+ VMs across 2+ availability zones | 99.99% | datacentre building |
   | Multi-region, active/active | not covered by a single SLA | regional outage |

#### Check your understanding

- **Q1.1** — Your subscription reports logical zone `2` maps to `eastus-az3`. A partner subscription deploys its database into its own logical zone `2`. Can you assume your VM and their database are in the same physical datacentre? What is the operational consequence if you assume wrongly, in both directions (assuming same when different, and different when same)?
- **Q1.2** — A single VM with Premium SSD gets 99.9%. Two such VMs in an availability set get 99.95%. Two in different zones get 99.99%. Explain, in terms of *which failure domain each shape eliminates*, why the availability set is worth only 0.05 percentage points more than the single VM while the zone spread is worth another 0.04.
- **Q1.3** — Recompute step 5 replacing the 99.9% storage tier with a 99.99% one. By how many hours per year does the composite improve? What does that tell you about where to spend effort in a chain of dependencies?
- **Q1.4** — A colleague claims "we're zone-redundant, so we're at 99.99%", but `az vm list-skus` shows the SKU restricted in zone 3 and the scale set has 2 instances that both landed in zone 1. Which specific field in the step-3 output would have caught this before production, and why does instance count alone not prove zone spread?

---

## Block 2 — Scalability: the autoscale control loop, and how it oscillates

**Goal:** build a real horizontal-scaling unit, attach an autoscale control loop to it, and understand the two knobs (thresholds and cooldown) that decide whether it stabilises or flaps.

### Steps

1. Create a Flexible-orchestration VM Scale Set spread across all three zones. Flexible is the current default orchestration mode and the one to use for new work — it manages VMs as first-class resources rather than opaque scale set instances.

   ```bash
   export VMSS=vmss-web-az900
   az vmss create \
     --resource-group "$RG" \
     --name "$VMSS" \
     --orchestration-mode Flexible \
     --platform-fault-domain-count 1 \
     --zones 1 2 3 \
     --image Ubuntu2204 \
     --vm-sku Standard_B2s \
     --instance-count 2 \
     --load-balancer "" \
     --generate-ssh-keys \
     --output none
   echo "created"
   ```

   ```
   created
   ```

   `--platform-fault-domain-count 1` is mandatory when you specify zones: within a zone, Azure already provides the fault isolation, so the fault-domain axis collapses to 1 and the zone becomes the failure boundary.

2. Confirm the instances actually landed in different zones. **This is the verification step people skip.**

   ```bash
   az vm list --resource-group "$RG" \
     --query "[?contains(name, 'vmss-web')].{Name:name, Zone:zones[0], Size:hardwareProfile.vmSize}" \
     --output table
   ```

   ```
   Name                  Zone    Size
   --------------------  ------  ------------
   vmss-web-az900_a1b2   1       Standard_B2s
   vmss-web-az900_c3d4   2       Standard_B2s
   ```

   Two instances, two distinct zones. If both showed `1`, the deployment is *not* zone-redundant regardless of what `--zones 1 2 3` requested.

3. Attach an autoscale setting. This creates the control loop: a metric source, thresholds, and bounds.

   ```bash
   az monitor autoscale create \
     --resource-group "$RG" \
     --resource "$VMSS" \
     --resource-type Microsoft.Compute/virtualMachineScaleSets \
     --name autoscale-web \
     --min-count 2 --max-count 10 --count 2 \
     --query "{name:name, enabled:enabled, default:profiles[0].capacity}" --output json
   ```

   ```json
   {
     "name": "autoscale-web",
     "enabled": true,
     "default": {
       "default": "2",
       "maximum": "10",
       "minimum": "2"
     }
   }
   ```

   `min-count 2` is the floor that preserves the 99.99% zone SLA. Setting it to 1 to save money silently drops you to a single-instance SLA during quiet hours — the exact hours when nobody is watching.

4. Add the scale-out rule.

   ```bash
   az monitor autoscale rule create \
     --resource-group "$RG" --autoscale-name autoscale-web \
     --condition "Percentage CPU > 70 avg 5m" \
     --scale out 2 --cooldown 5 \
     --output none
   echo "scale-out rule added"
   ```

   ```
   scale-out rule added
   ```

5. Add the scale-in rule — deliberately asymmetric.

   ```bash
   az monitor autoscale rule create \
     --resource-group "$RG" --autoscale-name autoscale-web \
     --condition "Percentage CPU < 25 avg 10m" \
     --scale in 1 --cooldown 10 \
     --output none
   az monitor autoscale show --resource-group "$RG" --name autoscale-web \
     --query "profiles[0].rules[].{Metric:metricTrigger.metricName, Op:metricTrigger.operator, Threshold:metricTrigger.threshold, Window:metricTrigger.timeWindow, Dir:scaleAction.direction, By:scaleAction.value, Cooldown:scaleAction.cooldown}" \
     --output table
   ```

   ```
   Metric          Op             Threshold  Window    Dir       By    Cooldown
   --------------  -----------  -----------  --------  --------  ----  ----------
   Percentage CPU  GreaterThan           70  PT5M      Increase  2     PT5M
   Percentage CPU  LessThan              25  PT10M     Decrease  1     PT10M
   ```

   Read the asymmetry carefully. Out: **+2 instances**, 70%, 5-minute window, 5-minute cooldown. In: **−1 instance**, 25%, 10-minute window, 10-minute cooldown. Scaling out is cheap and fast because being under-provisioned costs you users; scaling in is slow and cautious because being wrong costs you an outage. This is the standard production shape, and it is the correct answer to "why not use the same threshold both ways?"

6. Prove why symmetric thresholds oscillate. Suppose scale-out fires at CPU > 50% and scale-in at CPU < 50%, with 4 instances at 60% aggregate CPU:

   ```bash
   awk 'BEGIN {
     load = 4 * 60          # total CPU work units
     printf "4 instances @ %.0f%% -> scale OUT\n", load/4
     printf "5 instances @ %.0f%% -> scale IN\n",  load/5
     printf "4 instances @ %.0f%% -> scale OUT ... (flap)\n", load/4
   }'
   ```

   ```
   4 instances @ 60% -> scale OUT
   5 instances @ 48% -> scale IN
   4 instances @ 60% -> scale OUT ... (flap)
   ```

   The system never settles. Azure's autoscale engine has a built-in flapping guard — before scaling in, it estimates the post-scale-in metric and refuses the action if it would immediately trigger a scale-out. But relying on that guard instead of setting a real threshold gap is architecting by accident. The rule of thumb: the gap between thresholds must exceed the metric shift caused by one scaling step.

7. Add a **scheduled profile** for predictable load. Reactive autoscale always lags by at least the metric window; scheduled capacity does not.

   ```bash
   az monitor autoscale profile create \
     --resource-group "$RG" --autoscale-name autoscale-web \
     --name weekday-business-hours \
     --min-count 4 --max-count 20 --count 6 \
     --recurrence week mon tue wed thu fri \
     --start 08:00 --end 20:00 \
     --timezone "Argentina Standard Time" \
     --output none
   az monitor autoscale show --resource-group "$RG" --name autoscale-web \
     --query "profiles[].{Profile:name, Min:capacity.minimum, Default:capacity.default, Max:capacity.maximum}" --output table
   ```

   ```
   Profile                            Min    Default    Max
   ---------------------------------  -----  ---------  -----
   weekday-business-hours             4      6          20
   weekday-business-hours_e_*         2      2          10
   default                            2      2          10
   ```

   The CLI generates a paired "else" profile automatically so that outside the recurrence window the baseline applies. A batch job that starts at 08:00 sharp finds six warm instances instead of two cold ones plus five minutes of 5xx.

8. Contrast with **vertical** scaling. Resize a single VM and watch what it costs you.

   ```bash
   VM=$(az vm list -g "$RG" --query "[0].name" --output tsv)
   az vm show -g "$RG" -n "$VM" --query "hardwareProfile.vmSize" --output tsv
   ```

   ```
   Standard_B2s
   ```

   A resize to `Standard_D4s_v5` requires deallocating the VM: the guest OS stops, the ephemeral disk is discarded, the dynamic public IP is released. Vertical scaling is a **downtime event on a single instance**, bounded by the largest SKU in the family. Horizontal scaling is **online** and bounded only by quota. This is the core scalability trade-off the exam tests.

#### Check your understanding

- **Q2.1** — Your scale-out rule uses a 5-minute average window and a 5-minute cooldown, and instances take ~3 minutes to boot and pass health checks. What is the worst-case delay between the load actually arriving and the new capacity serving traffic? Which of those three intervals would you shorten first, and what does shortening it risk?
- **Q2.2** — `--min-count` is 2 to hold the zone-redundancy SLA. Finance asks you to set it to 1 overnight to halve compute cost. Quantify what they are actually buying and what they are giving up, using the SLA tiers from Block 1.
- **Q2.3** — Explain why the scale-in rule removes 1 instance but the scale-out rule adds 2. Give a failure scenario where a symmetric `−2 / +2` configuration causes a user-visible outage.
- **Q2.4** — A workload's load is entirely predictable: it triples every weekday at 08:00 and drops at 20:00. Which of the two profiles you configured (metric rules vs. scheduled) is doing the useful work, and why does keeping the metric rules *as well* still matter?
- **Q2.5** — In step 2, both instances could have landed in zone 1 despite `--zones 1 2 3`. Name a concrete platform condition that produces that result, and state which command from Block 1 detects it in advance.

---

## Block 3 — Cost predictability: query the real price list, not the calculator

**Goal:** the Azure Retail Prices API is public, unauthenticated, and machine-readable. Use it to see consumption, spot and reservation pricing side by side — which is what "cost predictability" concretely means.

### Steps

1. Pull the pay-as-you-go Linux price for one SKU in one region.

   ```bash
   curl -s "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode='USD'&\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'eastus'%20and%20armSkuName%20eq%20'Standard_D2s_v5'%20and%20priceType%20eq%20'Consumption'" \
     | jq -r '.Items[] | select(.productName | test("Windows") | not) | "\(.skuName)\t\(.retailPrice)\t\(.unitOfMeasure)"'
   ```

   ```
   D2s v5          0.096   1 Hour
   D2s v5 Low Priority     0.0096  1 Hour
   D2s v5 Spot     0.0096  1 Hour
   ```

   Spot is roughly **10% of on-demand** here — and carries a 30-second eviction notice with no SLA. That price difference is the market price of *predictability*.

2. Compare against the reserved-instance meters for the same SKU.

   ```bash
   curl -s "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode='USD'&\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'eastus'%20and%20armSkuName%20eq%20'Standard_D2s_v5'%20and%20priceType%20eq%20'Reservation'" \
     | jq -r '.Items[] | select(.productName | test("Windows") | not) | "\(.reservationTerm)\t\(.retailPrice)\t\(.unitOfMeasure)"'
   ```

   ```
   1 Year          701.28  1 Hour
   3 Years         1461.24 1 Hour
   ```

   Reservation meters are billed as a **lump sum for the whole term**, despite `unitOfMeasure` reading `1 Hour` — a well-known trap in this API. Normalise before comparing.

3. Normalise all three to an hourly rate and compute the actual saving.

   ```bash
   awk 'BEGIN {
     ondemand = 0.096
     y1 = 701.28  / 8760
     y3 = 1461.24 / (8760 * 3)
     spot = 0.0096
     printf "%-14s %8.5f  %7s  %s\n", "On-demand", ondemand, "-",    "no commitment, full SLA"
     printf "%-14s %8.5f  %6.1f%%  %s\n", "1-year RI", y1, (1-y1/ondemand)*100, "12-month commitment"
     printf "%-14s %8.5f  %6.1f%%  %s\n", "3-year RI", y3, (1-y3/ondemand)*100, "36-month commitment"
     printf "%-14s %8.5f  %6.1f%%  %s\n", "Spot",      spot, (1-spot/ondemand)*100, "evictable, NO SLA"
   }'
   ```

   ```
   On-demand       0.09600        -  no commitment, full SLA
   1-year RI       0.08006     16.6%  12-month commitment
   3-year RI       0.05560     42.1%  36-month commitment
   Spot            0.00960     90.0%  evictable, NO SLA
   ```

4. Find the break-even utilisation for the 1-year reservation. A reservation only pays if the resource actually runs.

   ```bash
   awk 'BEGIN {
     ondemand = 0.096; y1 = 701.28 / 8760
     printf "Break-even utilisation: %.1f%% of the year (%.0f h of 8760)\n", (y1/ondemand)*100, (y1/ondemand)*8760
   }'
   ```

   ```
   Break-even utilisation: 83.4% of the year (7305 h of 8760)
   ```

   Below ~83% uptime, the reservation loses money. This is why reservations suit steady-state baselines and never suit the autoscaled tier above the baseline — the correct pattern is *reserve the floor, burst on-demand or spot*.

5. Cross-region price comparison, since region choice is a first-class cost lever.

   ```bash
   for r in eastus westeurope brazilsouth japaneast; do
     price=$(curl -s "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode='USD'&\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'$r'%20and%20armSkuName%20eq%20'Standard_D2s_v5'%20and%20priceType%20eq%20'Consumption'" \
       | jq -r '[.Items[] | select(.skuName == "D2s v5")][0].retailPrice')
     printf '%-14s %s USD/h\n' "$r" "$price"
   done
   ```

   ```
   eastus         0.096 USD/h
   westeurope     0.107 USD/h
   brazilsouth    0.1728 USD/h
   japaneast      0.1408 USD/h
   ```

   The same SKU costs 80% more in Brazil South than in East US. Region selection is a trade among price, latency to users, data-residency law, and zone availability — and it is not reversible cheaply once data has landed.

#### Check your understanding

- **Q3.1** — The reservation meter reports `unitOfMeasure: "1 Hour"` with a value of `701.28`. Explain what that number actually represents and what a naïve dashboard that trusts `unitOfMeasure` would report as the annual cost of one reserved D2s v5.
- **Q3.2** — Break-even for the 1-year RI is 83.4% utilisation. Your dev/test VMs run 10 hours a day, 5 days a week. Compute their utilisation and state whether a reservation is correct for them. What Azure purchase option, if any, fits that pattern better?
- **Q3.3** — Spot is 90% cheaper with no SLA and a 30-second eviction notice. Give one workload that is a correct fit and one that is categorically wrong, and state the single workload property that decides it.
- **Q3.4** — You have an autoscale range of min 4 / max 20 instances, and telemetry shows you sit at 4–6 instances 95% of the time. How many instances would you reserve, and why is reserving all 20 actively worse than reserving none?
- **Q3.5** — Brazil South is 80% more expensive than East US for identical hardware. Name two reasons that are *not* "Azure charges what it wants", and one scenario where paying the premium is mandatory rather than optional.

---

## Block 4 — Reliability: redundancy tiers, and what "durability" does not mean

**Goal:** distinguish **durability** (will the bytes survive?) from **availability** (can I reach them right now?). They are different SLAs with different failure modes, and conflating them is the classic reliability mistake.

### Steps

1. Create three storage accounts with different replication tiers.

   ```bash
   SUFFIX=$(az group show -n "$RG" --query id --output tsv | md5sum | cut -c1-8)
   for sku in Standard_LRS Standard_ZRS Standard_GZRS; do
     name="st${SUFFIX}$(echo $sku | tr 'A-Z_' 'a-z' | cut -c10-13)"
     az storage account create --name "$name" --resource-group "$RG" --location "$LOC" \
       --sku "$sku" --kind StorageV2 --min-tls-version TLS1_2 \
       --allow-blob-public-access false --https-only true --output none
     echo "$name -> $sku"
   done
   ```

   ```
   st3f9a1c22lrs -> Standard_LRS
   st3f9a1c22zrs -> Standard_ZRS
   st3f9a1c22gzr -> Standard_GZRS
   ```

2. Read the replication configuration back from the platform.

   ```bash
   az storage account list --resource-group "$RG" \
     --query "[].{Name:name, Sku:sku.name, Tier:sku.tier, Primary:primaryLocation, Secondary:secondaryLocation, Status:statusOfPrimary}" \
     --output table
   ```

   ```
   Name           Sku             Tier      Primary    Secondary    Status
   -------------  --------------  --------  ---------  -----------  --------
   st3f9a1c22lrs  Standard_LRS    Standard  eastus                  available
   st3f9a1c22zrs  Standard_ZRS    Standard  eastus                  available
   st3f9a1c22gzr  Standard_GZRS   Standard  eastus     westus       available
   ```

   Only the geo-redundant account has a `secondaryLocation`. LRS and ZRS have no cross-region copy at all — a regional outage takes them offline entirely.

3. Map each tier to what it actually survives:

   | SKU | Copies | Spread across | Survives | Annual durability |
   |---|---|---|---|---|
   | `Standard_LRS` | 3 | one datacentre, separate racks | disk, node, rack failure | 11 nines |
   | `Standard_ZRS` | 3 | 3 availability zones, one region | loss of an entire datacentre | 12 nines |
   | `Standard_GRS` | 6 | 3 local + 3 in the paired region (async) | loss of a region | 16 nines |
   | `Standard_GZRS` | 6 | 3 zones + 3 in the paired region (async) | zone loss *and* region loss | 16 nines |
   | `Standard_RA_GRS` / `RA_GZRS` | 6 | as above, secondary readable | as above, plus read access during primary outage | 16 nines |

4. Discover the paired region programmatically rather than memorising the table.

   ```bash
   az account list-locations \
     --query "[?name=='$LOC'].{Region:name, Paired:metadata.pairedRegion[0].name, Geography:metadata.geographyGroup}" \
     --output table
   ```

   ```
   Region    Paired    Geography
   --------  --------  -----------
   eastus    westus    US
   ```

   Region pairs matter for two reasons beyond storage: platform updates are rolled out to only one region of a pair at a time, and recovery in a broad outage is prioritised for at least one region per pair. Note that some newer Azure regions ship **without** a pair and rely entirely on availability zones — check before designing around pairing.

5. Inspect the geo-replication lag on the geo-redundant account. Asynchronous replication means there is a real, measurable RPO.

   ```bash
   GZRS=$(az storage account list -g "$RG" --query "[?sku.name=='Standard_GZRS'].name | [0]" --output tsv)
   az storage account show --name "$GZRS" --resource-group "$RG" --expand geoReplicationStats \
     --query "geoReplicationStats.{Status:status, LastSync:lastSyncTime, CanFailover:canFailover}" --output json
   ```

   ```json
   {
     "Status": "Live",
     "LastSync": "2026-09-04T14:22:07+00:00",
     "CanFailover": true
   }
   ```

   `lastSyncTime` is the actual RPO boundary: every write committed to the primary *after* that timestamp is not yet at the secondary. If the primary is lost right now, those writes are gone. Geo-redundancy is **not** a synchronous mirror, and no amount of nines in the durability column changes that.

6. Read — do **not** run — the failover command, and understand its consequence.

   ```bash
   # az storage account failover --name "$GZRS" --resource-group "$RG" --failover-type Planned
   az storage account show --name "$GZRS" --resource-group "$RG" \
     --query "{failoverInProgress:failoverInProgress, allowedCopyScope:allowedCopyScope}" --output json
   ```

   ```json
   {
     "failoverInProgress": null,
     "allowedCopyScope": null
   }
   ```

   An **unplanned** failover promotes the secondary immediately, accepts the data loss implied by `lastSyncTime`, and **converts the account to LRS** — you land in the secondary region with no redundancy until you reconfigure. A **planned** failover (available on GZRS/GRS when the primary is healthy) replicates fully first, so RPO is zero, but it requires a healthy primary and therefore cannot be used during the outage you built it for. Both are account-wide and take hours to reverse.

7. Ask Azure Advisor what it thinks of your reliability posture. This is the free, always-on version of a reliability review.

   ```bash
   az advisor recommendation list --category HighAvailability \
     --query "[?contains(resourceMetadata.resourceId, '$RG')].{Impact:impact, Problem:shortDescription.problem}" \
     --output table
   ```

   ```
   Impact    Problem
   --------  ----------------------------------------------------------
   Medium    Use ZRS or GZRS for higher storage resiliency
   High      Enable virtual machine backup to protect against data loss
   ```

#### Check your understanding

- **Q4.1** — LRS advertises 11 nines of durability. A developer runs `DELETE` against the wrong container and 4 TB disappears. Did the storage account meet its durability SLA? Explain precisely what durability protects against, and name the two features that *do* protect against this scenario.
- **Q4.2** — Your GZRS account reports `lastSyncTime` 12 minutes in the past. The primary region is lost right now and you trigger an unplanned failover. State (a) the data loss window, (b) the redundancy tier you are running on immediately afterwards, and (c) the additional risk that creates.
- **Q4.3** — ZRS survives the loss of a whole datacentre and GRS survives the loss of a whole region, yet ZRS has *higher availability* for reads than GRS's secondary during normal operation. Reconcile those two facts.
- **Q4.4** — A regulator requires that data never leave the country, and the only in-country region has three availability zones but no paired region. Which replication SKU do you choose, what risk remains, and what compensating control addresses it?
- **Q4.5** — Planned failover has an RPO of zero but requires a healthy primary. Give a real scenario where planned failover is exactly the right tool, given it cannot be used during an unplanned regional outage.

---

## Block 5 — Performance predictability: SKU caps are contracts, not suggestions

**Goal:** cloud performance is predictable *because it is capped*. Find the caps, and see how a mismatch between VM cap and disk cap silently throttles a workload.

### Steps

1. Read the performance capabilities of a VM SKU. These numbers are the contract.

   ```bash
   az vm list-skus --location "$LOC" --size Standard_D2s_v5 --resource-type virtualMachines \
     --query "[0].capabilities[?name=='vCPUs' || name=='MemoryGB' || name=='MaxDataDiskCount' || name=='UncachedDiskIOPS' || name=='UncachedDiskBytesPerSecond' || name=='MaxNetworkInterfaces' || name=='PremiumIO'].{Capability:name, Value:value}" \
     --output table
   ```

   ```
   Capability                    Value
   ----------------------------  ----------
   MaxDataDiskCount              4
   MaxNetworkInterfaces          2
   MemoryGB                      8
   PremiumIO                     True
   UncachedDiskIOPS              3750
   UncachedDiskBytesPerSecond    85983232
   vCPUs                         2
   ```

   `UncachedDiskBytesPerSecond` of 85,983,232 is ~82 MiB/s. **That is the ceiling for all attached disks combined, regardless of how fast the disks are.**

2. Read the performance tiers of managed disks in the same region.

   ```bash
   az disk list-skus --location "$LOC" --resource-type disks \
     --query "[?name=='Premium_LRS'].capabilities[?name=='MaxIOpsReadWrite' || name=='MaxBandwidthMBps'] | [0]" \
     --output table 2>/dev/null || echo "(query per-size below)"
   ```

   Premium SSD v1 tiers are size-derived and fixed:

   | Tier | Size | Provisioned IOPS | Provisioned throughput |
   |---|---|---|---|
   | P6 | 64 GiB | 240 | 50 MB/s |
   | P10 | 128 GiB | 500 | 100 MB/s |
   | P20 | 512 GiB | 2,300 | 150 MB/s |
   | P30 | 1 TiB | 5,000 | 200 MB/s |
   | P40 | 2 TiB | 7,500 | 250 MB/s |

3. Compute the effective throughput of a D2s_v5 with one P30 attached. The binding constraint is whichever limit is lower.

   ```bash
   awk 'BEGIN {
     vm_iops = 3750; vm_mbps = 85983232 / 1048576
     disk_iops = 5000; disk_mbps = 200
     printf "VM cap    : %6d IOPS  %7.1f MiB/s\n", vm_iops, vm_mbps
     printf "Disk cap  : %6d IOPS  %7.1f MiB/s\n", disk_iops, disk_mbps
     printf "Effective : %6d IOPS  %7.1f MiB/s  <- min() of both\n", \
       (vm_iops < disk_iops ? vm_iops : disk_iops), (vm_mbps < disk_mbps ? vm_mbps : disk_mbps)
     printf "Wasted    : %6d IOPS  %7.1f MiB/s of provisioned disk you are paying for\n", \
       disk_iops - vm_iops, disk_mbps - vm_mbps
   }'
   ```

   ```
   VM cap    :   3750 IOPS     82.0 MiB/s
   Disk cap  :   5000 IOPS    200.0 MiB/s
   Effective :   3750 IOPS     82.0 MiB/s  <- min() of both
   Wasted    :   1250 IOPS    118.0 MiB/s of provisioned disk you are paying for
   ```

   You are paying P30 prices and receiving well under half the throughput, because the **VM** is the bottleneck. This is the single most common "the cloud is slow" ticket, and it is not a cloud problem — it is a SKU-pairing problem, visible in advance via the two commands above.

4. Confirm the same cap exists for networking, so you size the NIC path deliberately too.

   ```bash
   az vm list-skus --location "$LOC" --size Standard_D --resource-type virtualMachines \
     --query "[?starts_with(name,'Standard_D') && contains(name,'s_v5')].{SKU:name, vCPU:capabilities[?name=='vCPUs'].value|[0], IOPS:capabilities[?name=='UncachedDiskIOPS'].value|[0]}" \
     --output table | head -8
   ```

   ```
   SKU               vCPU    IOPS
   ----------------  ------  ------
   Standard_D2s_v5   2       3750
   Standard_D4s_v5   4       6400
   Standard_D8s_v5   8       12800
   Standard_D16s_v5  16      25600
   Standard_D32s_v5  32      51200
   ```

   Disk IOPS scale with the SKU size. If your bottleneck is I/O rather than CPU, the fix is a larger VM even when CPU is idle — an outcome that looks irrational until you have read this table.

5. Now the cost half of predictability: create a budget with alert thresholds, so spend has a control loop the way capacity does.

   ```bash
   cat > /tmp/budget.json <<'JSON'
   {
     "properties": {
       "category": "Cost",
       "amount": 50,
       "timeGrain": "Monthly",
       "timePeriod": { "startDate": "2026-09-01T00:00:00Z", "endDate": "2027-09-01T00:00:00Z" },
       "notifications": {
         "forecast-90": {
           "enabled": true,
           "operator": "GreaterThan",
           "threshold": 90,
           "thresholdType": "Forecasted",
           "contactEmails": ["you@example.com"],
           "contactRoles": ["Owner"]
         },
         "actual-100": {
           "enabled": true,
           "operator": "GreaterThan",
           "threshold": 100,
           "thresholdType": "Actual",
           "contactEmails": ["you@example.com"]
         }
       }
     }
   }
   JSON
   az rest --method put \
     --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Consumption/budgets/budget-az900?api-version=2021-10-01" \
     --body @/tmp/budget.json \
     --query "{name:name, amount:properties.amount, grain:properties.timeGrain}" --output json
   ```

   ```json
   {
     "name": "budget-az900",
     "amount": 50.0,
     "grain": "Monthly"
   }
   ```

   The two notification types are doing different jobs. `Forecasted > 90%` fires **before** the money is spent, based on the run-rate projection — that is the one that lets you act. `Actual > 100%` fires after the fact and is an audit record. A budget with only an actual-threshold alert is a smoke detector that rings the morning after.

6. Verify the budget is registered and readable.

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Consumption/budgets?api-version=2021-10-01" \
     --query "value[].{Name:name, Amount:properties.amount, Spent:properties.currentSpend.amount, Currency:properties.currentSpend.unit}" \
     --output table
   ```

   ```
   Name          Amount    Spent    Currency
   ------------  --------  -------  ----------
   budget-az900  50.0      1.87     USD
   ```

   Note what a budget is **not**: it does not stop spending. It notifies. Enforcement requires an action group wired to automation (a Logic App or runbook that deallocates resources), and that is a deliberate design decision — silently turning off production because a threshold tripped is usually worse than the overspend.

#### Check your understanding

- **Q5.1** — A D2s_v5 with one P30 disk delivers 3,750 IOPS and 82 MiB/s. The team's fix is to upgrade the disk to P40. What will happen to measured throughput, and what is the correct fix?
- **Q5.2** — Capping is what makes cloud performance predictable, yet caps are also what makes it slow when mis-sized. Explain why an *uncapped* multi-tenant platform would be worse for every tenant, including the one that would have used the extra headroom.
- **Q5.3** — Your budget has `Forecasted > 90%` and `Actual > 100%` notifications. On the 9th of the month the forecast alert fires. What does that tell you that the actual-spend figure alone does not, and what is the first diagnostic command you would run?
- **Q5.4** — A budget does not stop spending. Design, in two or three sentences, an enforcement path for a *non-production* subscription, and state the specific reason you would not apply the same automation to production.
- **Q5.5** — Step 4 shows disk IOPS scaling linearly with vCPU count. Your database is at 20% CPU but pinned at its IOPS cap. What do you change, and why does this feel wrong to someone reasoning from on-premises sizing habits?

---

## Block 6 — Security and governance: prevention beats detection

**Goal:** the governance benefit is not "you can see violations". It is that a violating request never commits. You will build a `Deny` guardrail, observe the rejection, and see the difference between `Audit` and `Deny` in the control plane.

### Steps

1. Find the built-in policy definition by display name rather than hard-coding a GUID.

   ```bash
   ALLOWED_LOC_ID=$(az policy definition list \
     --query "[?displayName=='Allowed locations' && policyType=='BuiltIn'].id | [0]" --output tsv)
   echo "$ALLOWED_LOC_ID"
   ```

   ```
   /providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c
   ```

2. Inspect the definition before assigning it. Reading the `effect` and the parameter contract is the difference between governance and cargo cult.

   ```bash
   az policy definition show --name e56962a6-4747-49cd-b67b-bf8b01975c4c \
     --query "{effect:policyRule.then.effect, params:keys(parameters), mode:mode}" --output json
   ```

   ```json
   {
     "effect": "deny",
     "params": ["listOfAllowedLocations"],
     "mode": "Indexed"
   }
   ```

   `mode: Indexed` means the policy only evaluates resource types that support tags and location — resource groups themselves are excluded, which is why a separate "Allowed locations for resource groups" definition exists.

3. Assign it at resource-group scope, restricted to a region that is deliberately *not* your working region, so you can observe the denial.

   ```bash
   az policy assignment create \
     --name deny-wrong-region \
     --display-name "AZ900 lab: restrict deployments to westus2" \
     --scope "/subscriptions/$SUB/resourceGroups/$RG" \
     --policy "$ALLOWED_LOC_ID" \
     --params '{"listOfAllowedLocations":{"value":["westus2"]}}' \
     --query "{name:name, scope:scope, enforcement:enforcementMode}" --output json
   ```

   ```json
   {
     "name": "deny-wrong-region",
     "scope": "/subscriptions/8f2c1b74-3d9a-4a1e-9f0b-2c7d5e6a1b33/resourceGroups/rg-az900-benefits",
     "enforcement": "Default"
   }
   ```

   `enforcementMode: Default` means deny is live. `DoNotEnforce` would evaluate and report without blocking — the correct setting when you are rolling a new policy into an existing estate and need the compliance data before you break anyone's pipeline.

4. Wait for the assignment to propagate, then attempt a violating deployment.

   ```bash
   sleep 45
   az storage account create --name "stdenied$SUFFIX" --resource-group "$RG" \
     --location "$LOC" --sku Standard_LRS --kind StorageV2 --output none
   ```

   ```
   (RequestDisallowedByPolicy) Resource 'stdenied3f9a1c22' was disallowed by policy.
   Policy identifiers: '[{"policyAssignment":{"name":"AZ900 lab: restrict deployments to westus2",
   "id":"/subscriptions/8f2c.../providers/Microsoft.Authorization/policyAssignments/deny-wrong-region"},
   "policyDefinition":{"name":"Allowed locations",
   "id":"/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"}}]'
   Code: RequestDisallowedByPolicy
   ```

   Read what happened: **Azure Resource Manager rejected the request before any resource was created.** There is no partial resource, no cleanup, no drift window. The error names the exact assignment and definition — a self-documenting rejection an engineer can act on without opening a ticket.

5. Confirm the same request succeeds in the permitted region, proving the guardrail is a boundary rather than a blanket block.

   ```bash
   az storage account create --name "stallowed$SUFFIX" --resource-group "$RG" \
     --location westus2 --sku Standard_LRS --kind StorageV2 \
     --min-tls-version TLS1_2 --allow-blob-public-access false \
     --query "{name:name, location:primaryLocation}" --output json
   ```

   ```json
   {
     "name": "stallowed3f9a1c22",
     "location": "westus2"
   }
   ```

6. Now assign an **Audit** policy so you can compare the two effects on identical infrastructure.

   ```bash
   TLS_ID=$(az policy definition list \
     --query "[?contains(displayName,'Secure transfer to storage accounts') && policyType=='BuiltIn'].id | [0]" --output tsv)
   az policy assignment create \
     --name audit-secure-transfer \
     --scope "/subscriptions/$SUB/resourceGroups/$RG" \
     --policy "$TLS_ID" \
     --params '{"effect":{"value":"Audit"}}' \
     --output none
   echo "audit assignment created"
   ```

   ```
   audit assignment created
   ```

7. Trigger an on-demand compliance scan and read the result. Scans are otherwise evaluated roughly every 24 hours, or on resource change.

   ```bash
   az policy state trigger-scan --resource-group "$RG" --no-wait
   sleep 120
   az policy state summarize --resource-group "$RG" \
     --query "value[0].results.{NonCompliant:nonCompliantResources, Policies:nonCompliantPolicies}" --output json
   ```

   ```json
   {
     "NonCompliant": 0,
     "Policies": 0
   }
   ```

   Zero non-compliant, because every account you created set `--https-only true`. **This is the crucial contrast to internalise:** the Audit policy would have reported a violation *after* a bad account existed and was serving traffic over HTTP. The Deny policy meant the bad request never became a resource. Same governance engine, entirely different security posture.

8. Examine RBAC as the other half of governance — who may act, as opposed to what may exist.

   ```bash
   az role assignment list --resource-group "$RG" --include-inherited \
     --query "[].{Principal:principalName, Type:principalType, Role:roleDefinitionName, Scope:scope}" \
     --output table
   ```

   ```
   Principal              Type   Role         Scope
   ---------------------  -----  -----------  ------------------------------------------
   villadalmine@...       User   Owner        /subscriptions/8f2c1b74-...
   ```

9. Build a least-privilege custom role — the concrete expression of "governance", as opposed to handing out `Contributor`.

   ```bash
   cat > /tmp/role-vm-operator.json <<JSON
   {
     "Name": "AZ900 VM Restart Operator",
     "Description": "May start, stop and restart VMs. May not create, delete or resize them.",
     "Actions": [
       "Microsoft.Compute/virtualMachines/read",
       "Microsoft.Compute/virtualMachines/start/action",
       "Microsoft.Compute/virtualMachines/restart/action",
       "Microsoft.Compute/virtualMachines/deallocate/action",
       "Microsoft.Compute/virtualMachines/instanceView/read",
       "Microsoft.Resources/subscriptions/resourceGroups/read"
     ],
     "NotActions": [],
     "DataActions": [],
     "NotDataActions": [],
     "AssignableScopes": [ "/subscriptions/$SUB/resourceGroups/$RG" ]
   }
   JSON
   az role definition create --role-definition @/tmp/role-vm-operator.json \
     --query "{name:roleName, type:roleType, actions:length(permissions[0].actions)}" --output json
   ```

   ```json
   {
     "name": "AZ900 VM Restart Operator",
     "type": "CustomRole",
     "actions": 6
   }
   ```

   Note there is no `virtualMachines/write` and no `virtualMachines/delete`. An operator holding this role can recover a hung VM at 03:00 and cannot resize it, delete it, or attach a disk. RBAC answers *who*; Policy answers *what*. Both are evaluated by ARM on every request, and **deny always wins over allow**.

#### Check your understanding

- **Q6.1** — The same "Secure transfer" policy definition can be assigned with `Audit` or `Deny`. Describe the timeline of events for a developer creating an HTTP-only storage account under each effect, and identify the specific interval during which data is at risk under `Audit`.
- **Q6.2** — You are introducing a new naming-convention policy across 400 existing resources, most of which violate it. Which `enforcementMode` do you assign first, and what is the exact failure you are avoiding by not going straight to `Deny`?
- **Q6.3** — Policy assignment took ~45 seconds to become effective, and compliance scans run roughly every 24 hours unless triggered. Explain why those two latencies are so different, and which of them would concern you in a security review.
- **Q6.4** — A user has `Owner` at subscription scope, and a `Deny` policy at resource-group scope forbids the region they need. Can they deploy? Explain the ARM evaluation order that produces the answer, and how they would legitimately proceed.
- **Q6.5** — The custom role omits `Microsoft.Compute/virtualMachines/write`. An operator complains they cannot add a tag to a VM they can otherwise restart. Is this a bug in the role, and what is the minimum change that fixes it without granting resize or delete?

---

## Block 7 — Manageability: declare the state, preview the change, close the loop

**Goal:** manageability is two distinct things the exam separates. **Management *of* the cloud** — automating and configuring resources (templates, autoscale, monitoring). **Management *in* the cloud** — the interfaces you use (portal, CLI, PowerShell, Cloud Shell, ARM/Bicep, REST). You will exercise both, and see the preview-before-apply loop that makes declarative management safe.

### Steps

1. Write a complete, syntactically valid ARM template. This is the declarative artefact — the desired state, not the steps to reach it.

   ```bash
   cat > /tmp/storage.json <<'JSON'
   {
     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "parameters": {
       "storageAccountName": {
         "type": "string",
         "minLength": 3,
         "maxLength": 24,
         "metadata": { "description": "Globally unique, lowercase alphanumeric." }
       },
       "location": {
         "type": "string",
         "defaultValue": "[resourceGroup().location]"
       },
       "replication": {
         "type": "string",
         "defaultValue": "Standard_ZRS",
         "allowedValues": ["Standard_LRS", "Standard_ZRS", "Standard_GRS", "Standard_GZRS"],
         "metadata": { "description": "Redundancy tier. ZRS or better for production." }
       }
     },
     "variables": {
       "requiredTags": {
         "costCenter": "training",
         "env": "lab",
         "managedBy": "arm-template"
       }
     },
     "resources": [
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[parameters('storageAccountName')]",
         "location": "[parameters('location')]",
         "tags": "[variables('requiredTags')]",
         "sku": { "name": "[parameters('replication')]" },
         "kind": "StorageV2",
         "properties": {
           "accessTier": "Hot",
           "supportsHttpsTrafficOnly": true,
           "minimumTlsVersion": "TLS1_2",
           "allowBlobPublicAccess": false,
           "allowSharedKeyAccess": false,
           "networkAcls": {
             "defaultAction": "Deny",
             "bypass": "AzureServices"
           }
         }
       }
     ],
     "outputs": {
       "blobEndpoint": {
         "type": "string",
         "value": "[reference(resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))).primaryEndpoints.blob]"
       },
       "resourceId": {
         "type": "string",
         "value": "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
       }
     }
   }
   JSON
   python3 -c "import json,sys; json.load(open('/tmp/storage.json')); print('template parses')"
   ```

   ```
   template parses
   ```

2. Validate against ARM before deploying. Validation is a server-side schema and reference check, and it is free.

   ```bash
   az deployment group validate \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 \
     --query "{status:properties.provisioningState, errors:error}" --output json
   ```

   ```json
   {
     "status": "Succeeded",
     "errors": null
   }
   ```

3. Run **what-if**. This is the single most useful manageability feature in Azure and the one most people never turn on: it computes the delta between declared state and actual state before anything changes.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 \
     --result-format FullResourcePayload 2>&1 | head -30
   ```

   ```
   Note: The result may contain false positive predictions (noise).
   You can help us improve the accuracy of the result by opening an issue here: https://aka.ms/arm-template-what-if-issues

   Resource and property changes are indicated with these symbols:
     + Create
     ~ Modify
     - Delete
     = NoChange

   The deployment will update the following scope:

   Scope: /subscriptions/8f2c1b74-.../resourceGroups/rg-az900-benefits

     + Microsoft.Storage/storageAccounts/stdecl3f9a1c22 [2023-05-01]

         apiVersion:                            "2023-05-01"
         kind:                                  "StorageV2"
         location:                              "westus2"
         properties.accessTier:                 "Hot"
         properties.allowBlobPublicAccess:      false
         properties.allowSharedKeyAccess:       false
         properties.minimumTlsVersion:          "TLS1_2"
         properties.supportsHttpsTrafficOnly:   true
         sku.name:                              "Standard_ZRS"
         tags.costCenter:                       "training"

   Resource changes: 1 to create.
   ```

4. Deploy, then re-run what-if to see idempotency demonstrated rather than asserted.

   ```bash
   az deployment group create \
     --resource-group "$RG" --name declare-storage --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 \
     --query "properties.outputs.blobEndpoint.value" --output tsv

   az deployment group what-if \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 2>&1 | tail -5
   ```

   ```
   https://stdecl3f9a1c22.blob.core.windows.net/

     = Microsoft.Storage/storageAccounts/stdecl3f9a1c22

   Resource changes: no change.
   ```

   `no change` from the identical template is the definition of idempotency: the artefact describes an end state, so re-applying it is a no-op. The same template in a CI pipeline is safe to run on every commit.

5. Simulate configuration drift and let what-if detect it — the manageability loop closing on a manual change.

   ```bash
   az storage account update --name "stdecl$SUFFIX" --resource-group "$RG" \
     --set tags.costCenter=misc --output none
   az deployment group what-if \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 2>&1 | grep -A4 '~ Microsoft'
   ```

   ```
     ~ Microsoft.Storage/storageAccounts/stdecl3f9a1c22 [2023-05-01]
       ~ tags.costCenter: "misc" => "training"

   Resource changes: 1 to modify.
   ```

   Someone changed a tag in the portal; the template noticed, named the exact property, and showed both values. Detecting drift in an on-premises estate requires a configuration management system you have to run yourself. Here it is one free command against the platform's own record of state.

6. Read the control-plane audit trail. Every ARM operation in the subscription is recorded for 90 days without you enabling anything.

   ```bash
   az monitor activity-log list --resource-group "$RG" --offset 1h --max-events 8 \
     --query "[?operationName.value != 'Microsoft.Resources/deployments/write'].{Time:eventTimestamp, Operation:operationName.localizedValue, Status:status.value, Caller:caller}" \
     --output table
   ```

   ```
   Time                              Operation                                  Status     Caller
   --------------------------------  -----------------------------------------  ---------  --------------------
   2026-09-04T14:58:11.4021Z         Create/Update Storage Account              Succeeded  villadalmine@...
   2026-09-04T14:51:03.9117Z         Create/Update Storage Account              Failed     villadalmine@...
   2026-09-04T14:47:22.1980Z         Create policy assignment                   Succeeded  villadalmine@...
   2026-09-04T14:33:50.7714Z         Create or Update Virtual Machine Scale Set Succeeded  villadalmine@...
   ```

   The `Failed` entry at 14:51 is your policy denial from Block 6 — who tried, what, when, and that it was blocked. That is the governance audit trail, and it exists by default.

7. Query **Resource Health** — the platform's own opinion about whether your resource is working, distinct from your monitoring.

   ```bash
   VMID=$(az vm list -g "$RG" --query "[0].id" --output tsv)
   az rest --method get \
     --url "https://management.azure.com${VMID}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01" \
     --query "properties.{State:availabilityState, Summary:summary, Since:occuredTime, ReportedAt:reportedTime}" --output json
   ```

   ```json
   {
     "State": "Available",
     "Summary": "There aren't any known Azure platform problems affecting this virtual machine.",
     "Since": "2026-09-04T14:34:12Z",
     "ReportedAt": "2026-09-04T15:02:44Z"
   }
   ```

   The states are `Available`, `Unavailable`, `Degraded` and `Unknown`. This is the answer to the 03:00 question "is it me or is it Azure?" — and it is the diagnostic distinction that turns a two-hour investigation into a two-minute one.

8. Check Service Health for platform-wide events affecting the subscription.

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=properties/eventType%20eq%20'ServiceIssue'" \
     --query "value[:3].properties.{Type:eventType, Status:status, Title:title, Impact:impact[0].impactedRegions[0].impactedRegion}" --output table
   ```

   ```
   Type          Status     Title                                          Impact
   ------------  ---------  ---------------------------------------------  ---------
   ServiceIssue  Resolved   Storage - West Europe - Mitigated              westeurope
   ```

   Three distinct layers, and knowing which to look at is the diagnostic skill: **Service Health** = Azure-wide events touching your subscription. **Resource Health** = this specific resource. **Azure Monitor** = your telemetry about your application. A 500 error with Resource Health `Available` and no Service Health event is your bug.

#### Check your understanding

- **Q7.1** — Distinguish "management *of* the cloud" from "management *in* the cloud" and classify each of these: an ARM template, the Azure portal, an autoscale rule, Cloud Shell, a Monitor alert, `az` CLI.
- **Q7.2** — What-if on an unchanged template reported `no change`. Explain why this makes the template safe to run on every CI commit, and name one category of manual change that what-if will *not* flag as drift.
- **Q7.3** — Step 5 detected a tag someone changed in the portal. Deploying the template reverts it. Give a scenario where that auto-revert is exactly right and one where it destroys something valuable, and state the process control that separates the two.
- **Q7.4** — A user reports 500 errors. Resource Health says `Available` and there is no Service Health event for your region. What have you ruled out, what remains, and which of the three telemetry layers do you go to next?
- **Q7.5** — The activity log recorded the policy-denied storage account creation as `Failed` with the caller's identity. Why is a *rejected* request worth 90 days of retention, given no resource was ever created?

---

## Block 8 — Teardown

**Goal:** the deletion path is part of the benefit. On-premises, decommissioning is a project; here it is one idempotent call — but only if you know what lives outside the resource group.

### Steps

1. Inventory what is about to be destroyed. Never delete a resource group you have not listed first.

   ```bash
   az resource list --resource-group "$RG" \
     --query "[].{Name:name, Type:type, Location:location}" --output table
   ```

   ```
   Name                   Type                                             Location
   ---------------------  -----------------------------------------------  ----------
   vmss-web-az900         Microsoft.Compute/virtualMachineScaleSets        eastus
   vmss-web-az900_a1b2    Microsoft.Compute/virtualMachines                eastus
   vmss-web-az900_c3d4    Microsoft.Compute/virtualMachines                eastus
   st3f9a1c22lrs          Microsoft.Storage/storageAccounts                eastus
   st3f9a1c22zrs          Microsoft.Storage/storageAccounts                eastus
   st3f9a1c22gzr          Microsoft.Storage/storageAccounts                eastus
   stallowed3f9a1c22      Microsoft.Storage/storageAccounts                westus2
   stdecl3f9a1c22         Microsoft.Storage/storageAccounts                westus2
   ```

2. Delete the subscription-scoped custom role first — it is **not** inside the resource group and will survive the deletion, leaving an orphaned definition.

   ```bash
   az role definition delete --name "AZ900 VM Restart Operator"
   az role definition list --custom-role-only true --name "AZ900 VM Restart Operator" --output tsv | wc -l
   ```

   ```
   0
   ```

3. Delete the resource group. Policy assignments and the budget are scoped to it and go with it.

   ```bash
   az group delete --name "$RG" --yes --no-wait
   az group exists --name "$RG"
   ```

   ```
   true
   ```

   `true` immediately after issuing the delete is expected — `--no-wait` returned as soon as ARM accepted the request. Deletion is asynchronous and ARM computes the dependency order itself: NICs before VNets, disks before VMs.

4. Confirm completion a few minutes later, and verify nothing survived at subscription scope.

   ```bash
   sleep 300
   az group exists --name "$RG"
   az policy assignment list --query "[?contains(name,'az900') || contains(name,'deny-wrong-region')].name" --output tsv | wc -l
   ```

   ```
   false
   0
   ```

#### Check your understanding

- **Q8.1** — The custom role definition needed a separate delete but the policy assignments did not. State the general rule, and name two other object types that commonly survive a resource-group deletion.
- **Q8.2** — `az group delete` needed no dependency ordering from you. What component computes that order, and why is this specific capability an example of the manageability benefit rather than the availability one?
- **Q8.3** — An unplanned GZRS failover (Block 4) converts the account to LRS and takes hours to reverse, while an entire resource group deletes in minutes and cannot be reversed at all. Which one warrants a resource lock, which warrants a runbook, and why are those different controls?

---

## Answers

<details>
<summary><strong>Click to reveal all answers</strong></summary>

### Block 0

**A0.1** — ARM deployments are **declarative**: `az group create` submits a desired end state, and ARM reconciles reality to it. If the resource group already exists with those properties, the reconciliation is a no-op and returns `Succeeded`. `az vmss scale` is different because it sets an absolute instance count, not a relative one — running it twice with the same value *is* idempotent, but it is a control-plane action rather than a state declaration, so it does not merge with concurrent autoscale decisions. Two competing sources of truth for instance count (a manual scale and an active autoscale profile) will fight; the autoscale engine wins on its next evaluation.

**A0.2** — Provider registration is a property of the **subscription**, which sits above resource groups in the hierarchy (management group → subscription → resource group → resource). Registering `Microsoft.ResourceHealth` makes that resource type deployable in *every* resource group in the subscription. Practically: a template that works in one subscription can fail in another with an obscure "resource type not found" error purely because a provider was never registered there.

### Block 1

**A1.1** — **No.** The logical-to-physical zone mapping is randomised **per subscription**. Your logical `2` mapping to `eastus-az3` says nothing about their logical `2`. Consequences run both ways:
- *Assuming same when different*: you believe VM and database are co-located and budget for intra-zone latency (~sub-millisecond), but the traffic actually crosses zones (~1–2 ms) — a chatty workload doing thousands of round trips per request degrades measurably.
- *Assuming different when same*: you believe you have zone-level failure isolation between two tiers, but both live in the same physical building. A single datacentre event takes out both, and your "zone-redundant" architecture has the availability of a single-zone one.

The fix is to compare `availabilityZoneMappings` across both subscriptions and align on *physical* zones, which is exactly why Microsoft exposes that API.

**A1.2** — Each shape eliminates a different failure domain, and the sizes reflect how often each domain actually fails:
- Single VM on Premium SSD (99.9%): survives nothing structural. Azure can live-migrate around some host issues, but host failure, rack failure, and planned host maintenance all cause downtime.
- Availability set (99.95%): distributes across **fault domains** (independent racks — separate power and top-of-rack switch) and **update domains** (staggered host patching). This removes rack failure and, importantly, planned maintenance — the most *frequent* cause of single-VM downtime. The gain is only 0.05 points because both instances still share one datacentre's power, cooling and network entry.
- Availability zones (99.99%): eliminates the shared-datacentre correlation. The further 0.04 points is small in percentage terms but represents removing an entire *class* of correlated failure — flood, fire, power-grid, cooling failure — that no amount of intra-datacentre redundancy addresses.

The percentages compress because the underlying events get rarer as the domain gets larger. Rack failures are common and cheap to survive; datacentre losses are rare and expensive to survive.

**A1.3** — `0.9995 × 0.9999 × 0.9999 = 0.99930008` → 99.93%, or **6.13 h/year**, down from 14.01. An improvement of **~7.9 hours per year** from fixing the single weakest link. General principle: **in a serial chain the composite is dominated by the worst component.** Improving anything else yields far less. Before spending effort on the 99.99% database, find and fix the 99.9% storage tier. Corollary: adding *any* new dependency, however reliable, can only lower the composite — so removing a dependency is an availability improvement in itself.

**A1.4** — The `Zones` field from `az vm list-skus` output. An empty or partial list (e.g. `["1","2"]`), or a `Restrictions` entry with `NotAvailableForSubscription`, means the SKU cannot be placed in every zone.

Instance count proves nothing about zone spread because zone placement is a **placement request, not a guarantee under constraint**. With `--zones 1 2 3` and 2 instances, Azure distributes across the *available* zones; if capacity or a SKU restriction rules out zones 2 and 3, both instances land in zone 1 and the deployment still reports success. The only proof is querying the actual `zones` property on the deployed instances — Block 2 step 2. This is why "verify placement, do not assume it" is the operational rule.

### Block 2

**A2.1** — Worst case is roughly **13 minutes**: up to 5 minutes for the metric window to fill with high-CPU samples (a spike at minute 0 does not push a 5-minute *average* over 70% until it has dominated the window), ~1 minute for the autoscale engine's evaluation interval and the scale action to be issued, plus ~3 minutes for instance provisioning, boot and health-probe pass. The 5-minute cooldown then applies to the *next* action, not this one.

Shorten the **metric window** first — it is the largest and the cheapest to change. The risk is sensitivity to transient spikes: a 60-second window will scale out for a garbage-collection pause or a batch job that would have resolved on its own, costing money and, if paired with an aggressive scale-in rule, causing flapping. The usual compromise is a 2–3 minute window with a scale-out threshold low enough (55–60%) that you begin provisioning before the tier is actually saturated. Provisioning time is attacked separately — with pre-baked images or pre-warmed instances — not by tuning autoscale.

**A2.2** — They are buying one B2s instance-hour per off-peak hour, roughly **USD 0.04/hour** at list price, so about **USD 15/month** if off-peak is 12 h/day.

They are giving up the entire zone-redundancy SLA. At `min-count 1` there is one instance in one zone, which is the single-VM tier — **99.9%** on Premium SSD, or 99.5% on Standard SSD. That is a move from 4.38 to 43.8 minutes of permitted monthly downtime, a **10x increase in downtime budget**, in exchange for USD 15. Worse, it applies precisely overnight, when detection and response are slowest and a single instance failure means a full outage rather than degraded capacity. The correct framing for the conversation is not "reliability vs cost" but "USD 15/month vs 39 extra minutes of unmonitored monthly outage risk."

**A2.3** — The asymmetry encodes the asymmetric cost of being wrong. Being under-provisioned causes user-visible errors and lost revenue; being over-provisioned costs a few instance-hours. So: scale out fast and generously, scale in slowly and conservatively.

Failure scenario for symmetric `−2 / +2`: a tier is running 4 instances at 24% CPU. The scale-in rule fires and removes 2, leaving 2 instances at ~48%. Traffic then rises 40% — normal daily variation — putting the 2 remaining instances at ~67%, below a 70% scale-out threshold, so nothing happens. A single instance then fails or gets patched, and the last one absorbs 100% of traffic, saturates, and starts timing out. The aggressive scale-in removed the headroom that would have absorbed both the traffic rise and the instance loss. Removing 1 at a time keeps the step size smaller than the buffer you rely on.

**A2.4** — The **scheduled profile** is doing the useful work. It provisions capacity at 08:00 by the clock, with no lag — reactive autoscale cannot start until the load has already arrived and filled a metric window, so the first 5–13 minutes of the spike hit an under-provisioned tier.

Keeping the metric rules matters because the schedule encodes what you *predicted*, and the metric rules handle what actually happens: a marketing campaign, a retry storm, a dependency slowdown that inflates request duration, or a public holiday when the predicted load never arrives. The scheduled profile in step 7 has its own `min 4 / max 20` with metric rules still active inside it — so the schedule sets the *floor and ceiling* while the rules move within them. Schedule for the known, react to the unknown.

**A2.5** — Concrete platform conditions producing single-zone placement: (1) **capacity constraint** — the requested SKU has no available capacity in zones 2 and 3 at that moment, and Azure satisfies the deployment from the zone that can serve it; (2) **SKU zone restriction** — the SKU is simply not offered in those zones for your subscription, shown as `NotAvailableForSubscription` in `restrictions`; (3) **quota exhaustion** in the regional vCPU family.

The detection command is `az vm list-skus --location $LOC --size <SKU> --resource-type virtualMachines --query "[0].{Zones:locationInfo[0].zones, Restrictions:restrictions}"` from Block 1 step 3, run *before* deployment. After deployment, `az vm list --query "[].zones"` from Block 2 step 2 confirms what actually happened. Use both: the first predicts, the second verifies.

### Block 3

**A3.1** — `701.28` is the **total price of a 1-year reservation for one D2s v5**, paid up front or amortised monthly over the term. It is not an hourly rate; the `unitOfMeasure: "1 Hour"` field is inherited from the meter schema and is misleading for reservation-type records — the discriminator is `type: "Reservation"` plus the `reservationTerm` field.

A dashboard trusting `unitOfMeasure` would multiply 701.28 × 8760 hours and report **USD 6,143,213 per year** for one small VM — an error of roughly four orders of magnitude. The correct normalisation is `retailPrice ÷ (8760 × years)`. Always branch on `type` and `reservationTerm` before doing arithmetic on this API.

**A3.2** — 10 h/day × 5 days = 50 h/week, versus 168 h in a week → **29.8% utilisation**, far below the 83.4% break-even. A reservation would cost roughly 2.8x more than simply paying on-demand. **A reservation is wrong for this workload.**

Better fits, in order of preference: (1) **auto-shutdown / scheduled start-stop** (`az vm auto-shutdown`, or a Logic App / Automation runbook) so you pay on-demand for only the 50 hours — this is the biggest lever and it composes with everything else; (2) **Azure Dev/Test pricing** if the subscription qualifies, which removes the Windows/SQL licence component and discounts many meters; (3) **Spot instances** if the work tolerates eviction, which most dev/test does. An **Azure savings plan for compute** is more flexible than a reservation (it commits to hourly spend rather than a specific SKU) but still assumes a sustained baseline, so it does not rescue a 30%-utilisation workload either.

**A3.3** — Correct fit: **batch video transcoding**, CI build agents, Monte Carlo simulation, or any embarrassingly parallel batch job with checkpointing. If an instance is evicted mid-job, the work item returns to the queue and another worker picks it up; total throughput drops, correctness does not.

Categorically wrong: **the primary node of a stateful database**, a payment-processing API, or a session-holding web tier. Eviction with 30 seconds' notice means in-flight transactions die and, for a stateful primary, potentially unreplicated writes are lost.

The deciding property is **interruptibility** — specifically, whether the work is checkpointed or re-queueable such that losing an instance mid-task costs *time* rather than *correctness*. If losing a worker means redoing work, spot is fine. If it means losing data or failing a user request that cannot be transparently retried, it is not.

**A3.4** — Reserve **4** — the observed floor and the autoscale `min-count`. Those 4 instances run 100% of the time by construction, so they are far above the 83.4% break-even and capture the full discount. Instances 5 through 20 run intermittently; they should be on-demand (or spot, if the tier tolerates it).

Reserving all 20 is worse than reserving none because a reservation is **paid whether or not the capacity is used**. Sixteen of them would sit at ~5% utilisation, costing full 1-year reservation price for almost no consumption — you would pay roughly 4x the necessary amount and have locked it in for 12 months. Reserving none merely forgoes a 16.6% discount on the baseline; reserving everything actively wastes money you cannot recover. Reservations do auto-apply to any matching running instance in scope, so under-reserving degrades gracefully while over-reserving does not.

**A3.5** — Two legitimate reasons: (1) **input cost differences** — electricity, land, construction, labour, network transit and local taxes vary enormously by country; South American power and connectivity cost substantially more per unit than North American. (2) **scale and utilisation** — East US is one of Azure's largest regions with enormous hardware volume and high sustained utilisation, so fixed costs amortise across far more billable hours; a smaller region carries more idle capacity per customer. A third factor is **import duties and regulatory compliance cost** on hardware in some jurisdictions.

Mandatory premium: **data-residency law**. If Brazilian regulation (LGPD in specific sectors, or financial-sector rules) requires personal data to remain within national borders, deploying to East US is not a cost optimisation — it is a compliance violation. The same applies to EU GDPR-driven residency requirements, public-sector sovereign-cloud mandates, and healthcare data rules. In those cases the price differential is not a decision variable at all.

### Block 4

**A4.1** — **Yes, the SLA was met.** Durability measures the probability that Azure loses your data through *infrastructure* failure — disk corruption, drive death, node loss, bit rot. Eleven nines means an expected annual loss probability of 0.000000001% for a given object. It says nothing about authorised API calls. The `DELETE` came from a credentialed principal, was authorised by RBAC, and Azure executed it correctly by replicating the deletion to all three copies within milliseconds. **Replication propagates mistakes exactly as faithfully as it propagates data.**

The two protections that actually address this:
- **Soft delete** for blobs and containers (`az storage account blob-service-properties update --enable-delete-retention true --delete-retention-days 30`), which retains deleted data for a retention window and allows undelete.
- **Point-in-time restore** for block blobs, and **blob versioning**, which keep prior versions so an overwrite or delete is recoverable.

Beyond those, **immutability policies** (WORM / legal hold) for regulatory data, **resource locks** (`CanNotDelete`) against deleting the account itself, and a genuine **backup** in a separate account with separate credentials — because a compromised credential can disable soft delete. Redundancy is not backup: redundancy protects against the platform failing, backup protects against you failing.

**A4.2** — (a) **12 minutes of data loss** — every write acknowledged to the client after `lastSyncTime` exists only in the lost primary. Those transactions are gone, and clients that received a 200 response for them will not know.
(b) The account is now **LRS in the former secondary region** (West US). Unplanned failover promotes the secondary and converts the redundancy tier down.
(c) The additional risk: you are now running **single-region, single-datacentre** during an active incident, at exactly the moment load is being redirected onto you and the platform may still be unstable. A second failure — even a routine one — has no redundancy to absorb it. Re-establishing geo-redundancy means reconfiguring the account to GRS/GZRS and waiting for a full initial replication of the whole dataset, which for a large account takes hours to days. Plan the recovery of your recovery posture, not just the failover.

**A4.3** — They measure different things.
- **Durability vs. availability**: GRS's extra copies are in another *region*, reached asynchronously. Those copies raise the probability that the bytes survive catastrophe (16 nines vs 12) but do nothing for read latency or read availability at the primary during normal operation.
- **The GRS secondary is not readable at all** unless the account is specifically **RA-GRS**. Plain GRS's secondary exists only as a failover target; a client cannot read from it, so it contributes zero to normal-operation availability.
- **ZRS serves reads from three zones synchronously.** All three copies are live, consistent, and in the request path. Losing one zone means requests are served from the other two with no failover, no data loss, and no operator action — availability is preserved *transparently*.

So: ZRS buys **higher availability with zero RPO within a region**; GRS buys **survival of the region's loss, with a non-zero RPO and a manual, disruptive failover**. GZRS is the combination, which is why it is the default recommendation for production data that must survive both.

**A4.4** — Choose **`Standard_ZRS`** (or `Premium_ZRS` for latency-sensitive workloads). It is the strongest redundancy available without leaving the country: three synchronous copies across three availability zones, surviving the loss of an entire datacentre with zero RPO.

The remaining risk is **loss of the entire region** — a country-scale event, or an Azure-wide regional control-plane failure. ZRS has no copy outside that region, so such an event means total unavailability and potentially total data loss.

Compensating controls: (1) **Azure Backup or a scheduled export to a second storage account in the same region but a different account and subscription**, which at minimum protects against account-level accidents and credential compromise even though it shares the regional fate; (2) **an offline or off-Azure backup held within national borders** — a second cloud provider's in-country region, or on-premises tape/object storage — which is usually the only control that genuinely addresses regional loss under a residency constraint; (3) an explicitly documented and business-signed-off **RPO/RTO for the regional-loss scenario**, since the risk cannot be engineered away, only accepted knowingly. Also confirm whether the regulation forbids data leaving the country or merely requires it to be *stored* in-country — some frameworks permit an encrypted backup abroad where the keys remain domestic, which changes the answer entirely.

**A4.5** — **A planned migration between regions.** Concretely: you are relocating a workload from East US to West US for latency or cost reasons, and you need to move the storage account's data with zero loss. The primary is healthy, so you initiate a planned failover; Azure fully replicates all outstanding writes, then promotes the secondary. RPO is zero and no transaction is lost.

Other valid cases: **rehearsing your DR runbook** (proving the failover path works, that DNS and connection strings follow, and that applications reconnect — before you have to do it under pressure); and **proactively evacuating a region ahead of an announced event** such as a Service Health advisory for planned maintenance or a forecast natural disaster, where you still have a healthy primary and time to act. Planned failover is a *migration and rehearsal* tool; unplanned failover is the emergency one. Confusing them is how teams discover during an outage that their runbook was never tested.

### Block 5

**A5.1** — **Throughput will not change at all.** The measured 3,750 IOPS and 82 MiB/s are the *VM's* `UncachedDiskIOPS` and `UncachedDiskBytesPerSecond` caps. A P40 raises the disk's provisioned limits to 7,500 IOPS / 250 MB/s, but the VM already could not consume the P30's 5,000 / 200. The bottleneck is unchanged; the bill goes up.

The correct fix is to **resize the VM** to one whose disk caps exceed the disk's provisioned performance — `Standard_D8s_v5` (12,800 IOPS) or larger, per the table in step 4. Then the P30 becomes the binding constraint and you get its full 5,000 IOPS. The general rule: **check `min(VM cap, disk cap)` before provisioning either**, and match them. If CPU is idle after the resize, that is not waste — you bought the VM for its I/O envelope, and on Azure the I/O envelope is sold bundled with vCPUs.

A secondary option, if resizing is unacceptable, is **host caching** (`--caching ReadOnly` on the data disk) — cached IOPS use a separate, larger budget (`CachedDiskIOPS`) and are served from local NVMe/RAM on the host. That helps read-heavy workloads with a working set that fits the cache and does nothing for write-heavy ones.

**A5.2** — An uncapped multi-tenant platform makes performance a function of **what your neighbours are doing**, which is the noisy-neighbour problem. Concretely:
- **Nobody can size capacity.** You cannot load-test meaningfully, because today's result depends on other tenants' load today. Capacity planning becomes guesswork and every incident review ends in "it was slower that day".
- **No SLA is possible.** A performance guarantee requires the platform to control the variables; if any tenant can consume unbounded I/O, the platform cannot promise anything to anyone.
- **The tenant who would have used the headroom is also hurt**, which is the counterintuitive part. They get bursts of extra performance sometimes and not others — so they must architect for the *worst* case they have observed, which is the same as the capped case, while having none of the predictability. They cannot safely design to the good case, so the headroom is unusable even when present. Meanwhile their own bursts make everyone else's numbers unpredictable, inviting retaliatory over-provisioning across the platform.

Capping converts a variable you cannot control into a constant you can design around. That is precisely the "predictability" benefit: performance you can *reason about* is worth more than performance that is occasionally higher. The escape valve for genuine burst needs is an explicit, priced one — burstable B-series with credits, or Ultra Disks with independently provisioned IOPS — where the burst is a product feature with defined limits rather than an accident of neighbour behaviour.

**A5.3** — A forecast alert on the 9th tells you the **run rate**, not the total. Actual spend at that point might be USD 15 of a USD 50 budget — entirely unalarming in isolation — but the forecast extrapolates the recent daily rate across the remaining 21 days and projects a month-end total above USD 45. In other words: *something changed recently and, if it continues, you will overshoot.* Actual-spend alerts cannot tell you this, because by the time actual crosses 100% the money is spent and the month is over.

First diagnostic: get the **daily cost trend broken down by resource**, to find what started and when.

```bash
az costmanagement query --type ActualCost \
  --scope "/subscriptions/$SUB/resourceGroups/$RG" \
  --timeframe MonthToDate --dataset-granularity Daily \
  --dataset-aggregation '{"cost":{"name":"PreTaxCost","function":"Sum"}}' \
  --dataset-grouping name=ResourceId type=Dimension
```

The shape you are looking for is a step change — a flat daily cost that jumps on a specific date — which points at the deployment, scale event or forgotten resource that caused it. Cross-reference that date against `az monitor activity-log list` to find the change that did it. Common culprits: an autoscale `max-count` reached and held, a VM left running after a test, a premium disk attached and never detached, or egress from a misconfigured backup job.

**A5.4** — **Enforcement path for non-production:** wire the budget's notification to an **action group** that triggers an Azure Automation runbook or Logic App; at the 100% actual threshold the runbook enumerates resources in the subscription tagged `env=dev` and deallocates VMs, scales App Service plans to the free/shared tier, and posts to the team channel with what it stopped. Budgets themselves only notify, so the automation is what converts a notification into a control. Pair it with the milder 90%-forecast notification going to humans first, so someone has a chance to intervene before the automation acts.

**Why not in production:** the automation cannot distinguish "runaway cost from a bug" from "legitimate cost from a traffic spike" — and a traffic spike is exactly when a budget threshold trips and exactly when you least want capacity removed. Auto-deallocating production turns a cost problem, which is recoverable with a credit-card and a conversation, into an outage, which is not. The overspend is bounded and reversible; the outage is unbounded in reputational and revenue terms. In production the budget alert should page a human, and the enforcement should be architectural — reservation coverage, autoscale `max-count` ceilings, and quota limits that cap the blast radius *before* spend rather than reacting after it.

**A5.5** — **Resize the VM to a larger SKU**, even though CPU is idle — for example `Standard_D2s_v5` → `Standard_D8s_v5`, taking `UncachedDiskIOPS` from 3,750 to 12,800. Alternatively move to a storage-optimised family (Lsv3) whose I/O caps are high relative to vCPU count, if the workload is genuinely I/O-bound and CPU-light.

This feels wrong from on-premises habit because there, CPU, RAM, storage controller and disks are **independently purchasable**. If a server was I/O-bound you added an HBA, more spindles or an SSD tier, and left the CPU alone — buying CPU you would not use was obviously wasteful.

In Azure the VM SKU is a **bundle**: vCPUs, memory, network bandwidth, NIC count, and disk IOPS/throughput scale together as one purchasable unit. You cannot buy the I/O envelope separately, so the only lever for more I/O is a bigger bundle. The mental correction is to stop thinking of the SKU as "a CPU count" and start thinking of it as "a performance envelope across five dimensions", then size on whichever dimension binds. Two partial escapes exist — **Ultra Disk** and **Premium SSD v2** let you provision IOPS and throughput independently of capacity, and host caching uses a separate budget — but the VM-level cap still bounds everything, so the resize is usually still required.

### Block 6

**A6.1** — **Under `Audit`:** the developer's `create` request is authorised by RBAC and executes. The storage account exists, HTTP-only, and is immediately reachable. The developer wires an application to it and data begins flowing in cleartext. Up to 24 hours later (or sooner if a scan is triggered, or on the resource-change evaluation) the compliance state flips to non-compliant. Someone must notice the dashboard, identify the owner, open a ticket, and get it remediated — realistically hours to weeks. **The window of exposure runs from resource creation until manual remediation completes**, and every byte transmitted in that window travelled unencrypted over the network. Nothing about `Audit` shortens that window; it only records it.

**Under `Deny`:** ARM evaluates the policy during request admission, *before* the resource provider is invoked. The request returns `RequestDisallowedByPolicy` in a few seconds. **No resource exists, no data ever flows, and the exposure window is zero.** The developer gets an immediate, specific error naming the policy, fixes the template, and moves on — usually within the same working minute.

The interval at risk under `Audit` is: *creation time → detection → triage → remediation*, of which the detection component alone can be 24 hours. `Deny` collapses the whole interval to nothing by moving enforcement from *after the fact* to *admission control*. This is the core of the governance benefit: prevention is not merely faster detection, it eliminates the failure state entirely.

**A6.2** — Assign with **`enforcementMode: DoNotEnforce`** first (`--enforcement-mode DoNotEnforce`). The policy evaluates every resource and populates the full compliance report, but no request is blocked.

The exact failure being avoided: with `Deny` and `enforcementMode: Default`, the policy does **not** delete or modify the 400 existing violating resources — deny is admission control, so pre-existing resources are simply reported non-compliant and keep running. But every subsequent **write** to them is blocked. That means the next routine `PUT` from a CI pipeline, an autoscale operation, a tag update, a certificate rotation, or any ARM template redeployment fails with `RequestDisallowedByPolicy`. You have not broken the resources; you have broken the ability to *manage* them, across 400 resources and every team that owns them, simultaneously and without warning. Recovery means either removing the assignment under pressure or racing to remediate 400 resources while their owners cannot deploy.

The safe rollout: (1) assign `DoNotEnforce` and collect the compliance report; (2) publish the list of violators to owners with a deadline; (3) remediate — with a `Modify`/`DeployIfNotExists` policy and a remediation task where the fix is mechanical; (4) confirm compliance is at or near 100%; (5) flip to `Default` so the policy prevents *new* violations. Optionally use `notScopes` or a policy exemption with an expiry date for the stragglers, so the exception is tracked and time-bounded rather than silently permanent.

**A6.3** — They are different because they serve different purposes at different layers:

- **Assignment propagation (~30 seconds to a few minutes)** is a *control-plane distribution* problem. ARM must push the new assignment to every regional policy-evaluation front-end that might receive a request for that scope. It is short because it is on the admission path: once propagated, the policy is evaluated **synchronously on every incoming write request**, so there is no further delay — enforcement is immediate and continuous from that point on.

- **Compliance scan (~24 hours)** is a *background reconciliation* sweep across every existing resource in scope, evaluating each against every applicable assignment. It is expensive and runs on a slow cycle because it is a reporting function, not an enforcement one. It also runs on resource change and can be triggered on demand (`az policy state trigger-scan`).

**Which should concern a security reviewer: the 24-hour scan latency — but only for `Audit`-effect policies.** For `Deny` policies the scan latency is nearly irrelevant, because enforcement happens at admission and the scan merely reports on resources that predate the assignment. For `Audit` policies the scan latency *is* the detection latency, and a control whose mean time to detect is measured in hours is a weak control. That asymmetry is itself the argument for preferring `Deny` wherever the business can tolerate it: it makes the slow path stop mattering.

**A6.4** — **No, they cannot deploy.** Azure Policy and RBAC are independent gates evaluated by ARM on every request, and both must pass:

1. **Authentication** — who are you?
2. **RBAC authorisation** — does this principal have an `Action` permitting this operation at this scope? `Owner` grants `*`, so this passes.
3. **Policy evaluation** — does any applicable assignment `Deny` this request? The resource-group assignment matches, so this **fails**.

Policy is deliberately **not** overridable by RBAC role, and `Owner` confers no policy exemption. This is the design intent: policy expresses organisational rules that hold regardless of individual privilege, so a compromised or careless Owner account cannot deploy into a forbidden jurisdiction. Deny is also evaluated last and wins over everything.

Legitimate ways forward, in order of preference:
- **Deploy to a permitted region** — usually the policy is right and the request is wrong.
- **Request a policy exemption** (`az policy exemption create`) for the specific resource or scope, with a category (`Waiver` or `Mitigated`), a justification, and an **expiry date**. This creates an auditable, time-bounded exception.
- **Amend the assignment's parameters** to add the region, if the business requirement has genuinely changed — a change to the rule itself, reviewed as such.
- **Use `notScopes`** to carve out a specific child scope, if a whole resource group legitimately sits outside the rule.

What they should *not* do is delete the assignment. That silently removes the guardrail for everyone, leaves no record of why, and is the single most common way a governance control quietly disappears from an estate.

**A6.5** — **Not a bug — it is the role working as designed, though the design may be too tight for the operator's actual job.**

Tagging a VM is a `Microsoft.Compute/virtualMachines/write` operation: ARM has no separate "tag-only" action on the resource itself, because tags live in the resource's own definition and updating them is a `PUT`/`PATCH` on the resource. Since `write` also permits resizing, changing the OS profile, attaching disks and altering the network profile, granting it would give away exactly what the role was built to withhold.

The minimum change that fixes it without granting resize or delete: assign the built-in **`Tag Contributor`** role alongside the custom role, scoped to the same resource group. `Tag Contributor` grants `Microsoft.Resources/tags/*` — the tags *sub-resource* action — which permits reading and writing tags on any resource in scope while granting no other permission on the resources themselves. It cannot resize, cannot delete, cannot read resource properties beyond what the other role allows.

Adding `Microsoft.Resources/tags/*` directly to the custom role's `Actions` array achieves the same result in one role rather than two, and is preferable if you want a single assignable role. Either way, the thing *not* to do is add `Microsoft.Compute/virtualMachines/write` — that single action silently converts a restart operator into something very close to a Contributor over VMs. When a least-privilege role is one action short, check whether a sub-resource action or a narrow built-in role covers the gap before widening the broad one.

### Block 7

**A7.1** — **Management *of* the cloud** = automating, configuring and operating the resources themselves — the things you build so the environment runs without manual intervention. **Management *in* the cloud** = the interfaces and tools through which you interact with Azure — the surfaces you touch.

| Item | Category | Reasoning |
|---|---|---|
| ARM template | **of** the cloud | Declares and automates resource configuration; the artefact defines what exists |
| Azure portal | **in** the cloud | A web interface for interacting with Azure |
| Autoscale rule | **of** the cloud | Automatic resource management responding to demand, with no operator involved |
| Cloud Shell | **in** the cloud | A browser-hosted shell interface |
| Monitor alert | **of** the cloud | Configured monitoring and automated response to resource conditions |
| `az` CLI | **in** the cloud | A command-line interface for interacting with Azure |

The dividing question: *is this a thing that manages resources on my behalf (of), or a thing I use to manage resources myself (in)?* Autoscale keeps working when everyone is asleep; the portal does nothing unless someone is clicking it.

**A7.2** — `no change` on re-application is **idempotency**, and it makes CI safe because the template describes a *desired end state* rather than a sequence of actions. Running it on every commit converges reality to the declaration: if reality already matches, nothing happens; if it has drifted, only the drifted properties change. There is no "already exists" error to special-case, no need to branch on whether this is a first deployment or the hundredth, and no risk of a re-run duplicating resources. That property is what allows a pipeline to run `deployment group create` unconditionally on merge to main.

**What what-if will not flag: data-plane state.** What-if compares ARM control-plane properties only. It will not detect blobs added or deleted inside a storage account, rows in a database, files on a VM's disk, secrets rotated inside Key Vault's data plane, or configuration changed *inside* the guest OS. It also has documented blind spots on the control plane: properties the resource provider computes or defaults server-side can produce false positives or be omitted entirely, resources created outside the template in the same resource group are simply not evaluated (what-if in `Incremental` mode reports only on resources the template declares), and child resources managed by other means may not appear. The warning printed in the output — "the result may contain false positive predictions (noise)" — is Microsoft acknowledging exactly this.

**A7.3** — **Auto-revert is exactly right when:** the template is the single source of truth and the manual change was unauthorised or accidental. Someone hand-edited a production storage account in the portal to set `allowBlobPublicAccess: true` while debugging, and forgot to undo it. Reverting closes a security hole, restores the reviewed configuration, and does so without anyone needing to remember. This is the intended operating model — infrastructure-as-code with continuous reconciliation.

**Auto-revert destroys something valuable when:** an on-call engineer made a deliberate emergency change at 03:00 — scaled a tier up during an incident, opened a firewall rule to restore a partner integration, raised a throttling limit to absorb a traffic surge — and the next CI run silently reverts it while the incident is still open. The pipeline "successfully" reintroduces the outage, and because the revert looks like a routine green deployment, nobody connects the two for hours.

**The process control that separates them: every emergency change must be written back into the template before the next deployment runs, and the pipeline must be pausable.** Concretely — (1) the incident runbook's final step is "port the fix to the template and open a PR", treated as part of resolution, not follow-up; (2) a documented break-glass mechanism to disable auto-deploy for a named resource group during an active incident, with the re-enable as an explicit checklist item; (3) **what-if run in the pipeline with the diff posted for review** before apply, so a human sees "reverting `maxCount: 40 → 20`" and asks why; and (4) resource locks or policy exemptions for the genuinely-manual-by-design cases. The underlying principle: drift detection is only safe when there is a fast, low-friction path for legitimate changes to become declared changes. If updating the template is slow or bureaucratic, engineers will bypass it under pressure and the reconciliation loop becomes a weapon.

**A7.4** — **What you have ruled out:** an Azure-wide or regional platform incident (no Service Health event for your region and services), and a problem with that specific resource's underlying host, network or storage as the platform sees it (Resource Health `Available` means Azure's own health model finds nothing wrong with the VM — it is running, reachable at the infrastructure layer, and not affected by host maintenance or hardware fault).

**What remains — everything above the infrastructure line:** application code raising unhandled exceptions; a dependency failing (database connection pool exhausted, a downstream API timing out, an expired certificate or credential); resource exhaustion inside the guest (disk full, out of memory, thread-pool starvation) which the platform cannot see; misconfiguration (a bad connection string from a recent deploy, a wrong feature flag); an NSG or firewall rule blocking a dependency; DNS resolution failure; or a hit performance cap — a saturated disk IOPS limit from Block 5 causing request timeouts that surface as 500s. Note that Resource Health reports on the *platform's* view: a VM can be `Available` while the application inside it is completely dead.

**Where to go next: Azure Monitor** — specifically Application Insights if instrumented. Start with the failures view to get the exception type and stack trace, then the dependency map to see which downstream call is slow or failing, then the request-duration distribution to distinguish "everything is slow" (resource or dependency saturation) from "one endpoint is broken" (a code path). In parallel, check the activity log for a deployment or configuration change immediately preceding the first error — a change correlating with the incident start is the highest-yield lead in practice. If Application Insights is absent, go to VM guest metrics and the guest OS logs. The three-layer discipline is what makes this fast: two of the three layers have already been cleared in seconds, so the search space is now bounded to your own stack.

**A7.5** — A rejected request is a **security and governance signal**, and the fact that no resource was created is precisely what makes it interesting:

- **Attempted-violation telemetry.** A pattern of `RequestDisallowedByPolicy` from one principal may indicate a compromised credential probing what it can do, an insider testing boundaries, or — far more often and equally worth knowing — a team whose deployment pipeline is misconfigured and repeatedly trying something the organisation forbids. Both need action; neither leaves any other trace.
- **Proof the control worked.** Auditors and compliance frameworks ask you to *demonstrate* that a control is effective, not merely that it is configured. A log of blocked requests, with timestamps, identities and the specific policy that blocked them, is that evidence. "The policy is assigned" is a configuration claim; "here are 47 requests it denied last quarter" is an operational one.
- **Attribution for incident reconstruction.** During a security investigation the question "what did this principal *try* to do?" matters as much as what it succeeded in doing. Successful actions leave resources; failed ones leave only the log. Discarding failures would leave a reconstruction with half the picture, and specifically the half that reveals intent.
- **Blocked-work diagnostics.** When someone says "my deployment doesn't work", the activity log names the exact assignment and definition that stopped them, turning a support conversation into a lookup.

More generally: the activity log records **control-plane intent**, not just control-plane outcomes. Filtering to successes only would make it a record of what happened rather than a record of what was attempted — and security is largely the study of what was attempted. Ninety days is the free default retention; for compliance regimes requiring longer, export to a Log Analytics workspace or a storage account with an immutability policy.

### Block 8

**A8.1** — **The general rule: a resource-group deletion removes exactly the objects whose ARM resource ID contains that resource group.** Anything scoped *above* the resource group — at subscription, management-group, or tenant level — survives, because it was never a child of the group. Policy assignments in this lab were created with `--scope /subscriptions/.../resourceGroups/$RG`, so their IDs are inside the group and they go with it. The custom role definition's ID is `/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/...` — subscription-scoped, regardless of what its `AssignableScopes` says — so it persists as an orphan.

Two other commonly-orphaned object types:
- **Role assignments** created at subscription or management-group scope. (Role assignments *scoped to the deleted resource group* are cleaned up, but ones granting access to a principal at subscription scope obviously remain — and if the principal itself was a system-assigned managed identity on a deleted resource, you are left with assignments referencing a nonexistent object ID, which show as unknown identities in `az role assignment list`.)
- **Microsoft Entra ID objects** — app registrations, service principals, and user-assigned managed identities that lived in a *different* resource group. Entra objects are tenant-scoped and entirely outside the ARM resource-group lifecycle.

Others worth checking: subscription- or management-group-scoped **policy assignments, initiatives and exemptions**; **diagnostic settings** on subscription-level activity logs; **budgets and cost alerts** at subscription scope; **soft-deleted Key Vaults and storage accounts**, which are retained (and keep their globally unique names reserved) for the retention period even after the group is gone, and which must be purged explicitly; and **Recovery Services vault backup items**, which block group deletion outright until the vault's protection is stopped with data deleted.

**A8.2** — **Azure Resource Manager computes the order.** ARM builds a dependency graph from the resource relationships it already tracks — a NIC references a subnet, a subnet belongs to a VNet, a VM references NICs and disks — and deletes leaves before their parents, parallelising wherever the graph permits. The same graph engine that orders *creation* from `dependsOn` and implicit references orders *deletion* by traversing it in reverse.

This is **manageability**, not availability, because availability is about a service staying reachable during failure, whereas this is about the *operational effort required to manage the system's lifecycle*. Concretely: on-premises, decommissioning is a project — someone must know that the load balancer references the VIP, that the VIP is bound to the NIC, that the storage LUN is masked to this initiator, and get the order right or leave orphaned entries in three systems. That knowledge lives in people's heads and in a wiki page that is out of date. Here the platform holds the dependency graph as authoritative state and executes the teardown correctly with one command and no expertise on your part.

The same property is what makes the whole environment cheap to *recreate*: because ARM knows the graph, a template can rebuild the entire estate in the right order. Reproducible teardown and reproducible build-up are the same capability viewed from two directions, and together they are what makes ephemeral environments — a full stack per pull request, destroyed on merge — practical at all. That is manageability's real payoff: it changes what workflows are economically possible, not just how long a task takes.

**A8.3** — **The resource group deletion warrants a resource lock.** It is instantaneous relative to human reaction time, fully irreversible, and triggered by a single command that is easy to run against the wrong `$RG` — the failure mode is a *mistake*, and the control for mistakes is to make the action impossible without a deliberate second step. `az lock create --lock-type CanNotDelete --resource-group $RG` means the delete fails until someone explicitly removes the lock, which forces a moment of conscious intent and, in an audited environment, leaves a record of who removed it and when. Locks are the right tool for high-blast-radius, low-frequency, no-undo operations.

**The GZRS failover warrants a runbook.** It is not a mistake to avoid — it is a *correct action taken under pressure*, during an incident, by someone who may be tired and working outside their normal expertise. The risks are not "someone might do it accidentally" but "someone will do it and get the surrounding steps wrong": failing to record `lastSyncTime` before triggering, not knowing that the account drops to LRS afterwards, forgetting to update connection strings and DNS, and having no plan to restore geo-redundancy afterwards. A lock here would be actively harmful, adding friction to an emergency action that must happen fast. What is needed is a tested, written procedure covering preconditions, the exact commands, the expected data-loss window, downstream reconfiguration, and the recovery-of-redundancy steps.

**Why the controls differ:** the distinguishing question is *whether the action should ever happen in normal operation*. Locks prevent actions that should not happen — they add friction, and friction is only acceptable where the action is genuinely undesirable. Runbooks guide actions that **should** happen but are rare, complex and consequential — they remove uncertainty without adding delay. Applying the wrong control is a real failure mode in both directions: locking the failover delays disaster recovery, and writing a runbook for resource-group deletion documents a mistake instead of preventing it. In practice, mature environments use both together on the same system for different operations — locked deletion, runbooked failover.

</details>

---

## Sources

- [AZ-900 Study Guide — Microsoft Certified: Azure Fundamentals](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900)
- [Describe the benefits of using cloud services (training module)](https://learn.microsoft.com/en-us/training/modules/describe-benefits-use-cloud-services/)
- [SLA for Online Services — Microsoft Product Terms](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services)
- [Azure availability zones overview](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview)
- [Azure region pairs](https://learn.microsoft.com/en-us/azure/reliability/regions-paired)
- [Azure Storage redundancy](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy)
- [Storage account failover](https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance)
- [Overview of autoscale in Azure](https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-overview)
- [Virtual Machine Scale Sets orchestration modes](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes)
- [Azure managed disk types and performance tiers](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types)
- [Azure Retail Prices REST API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Create and manage Azure budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Azure Policy overview](https://learn.microsoft.com/en-us/azure/governance/policy/overview)
- [Understand Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects)
- [Azure RBAC overview](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview)
- [ARM template deployment what-if](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if)
- [Azure Resource Health overview](https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview)
- [Azure Monitor activity log](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log)
- [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/)
- [Lock resources to prevent unexpected changes](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources)