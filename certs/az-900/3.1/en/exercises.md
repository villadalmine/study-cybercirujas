# AZ-900 — Topic 3.1: Describe cost management in Azure
## Guided Exercises

> **Exam weight:** 8.33 % · **Exam version:** 2026-07-20
> **Official skills measured:** [AZ-900 Study Guide](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900)
> — factors that affect cost · Pricing calculator vs. TCO Calculator · Microsoft Cost Management capabilities · the purpose of tags

---

### How to use this document

Every block is a sequence of commands you actually run, followed by **verification questions**. Answers are collapsed at the end. Do not read them first — the value of this topic is in seeing the meters, not in memorising a definition of "budget".

**Cost warning.** Blocks 1–3 and 8 cost **nothing** (public pricing APIs, no authentication). Blocks 4–7 create billable resources. If torn down inside an hour the total is a few cents, but **Block 9 is not optional** — an orphaned Standard public IPv4 and a 30 GiB managed disk quietly bill ~$6/month forever.

**Prerequisites**

```bash
az version --query '"azure-cli"' -o tsv     # >= 2.60.0
jq --version                                 # jq-1.6 or later
curl --version | head -1
az login
az account show --query '{sub:id, name:name, tenant:tenantId}' -o yaml
```

Required permissions: **Contributor** on a subscription (to create resources and a policy assignment) plus **Cost Management Reader** or higher on the subscription/billing scope. Free Trial and Azure for Students subscriptions can read Cost Analysis and create budgets, but cannot create *reservations* — Block 8 is read-only by design so it works on any offer.

Export the identifiers once; every later block reuses them:

```bash
export SUB_ID=$(az account show --query id -o tsv)
export RG=rg-az900-cost-lab
export LOC=eastus
export ALERT_EMAIL="you@example.com"     # replace
echo "$SUB_ID / $RG / $LOC"
```

---

## Block 1 — Read the price *before* you deploy: the Azure Retail Prices API

The Pricing Calculator is a UI over the same catalogue the billing engine uses. The machine-readable form of that catalogue is the **Azure Retail Prices API** — anonymous, unauthenticated, no subscription required. Learning to query it is what separates "I think a D2s v5 is about ten cents" from an auditable number.

1. Query the consumption price of one VM SKU in one region:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "currencyCode='USD'" \
  --data-urlencode "\$filter=serviceName eq 'Virtual Machines' \
      and armRegionName eq 'eastus' \
      and armSkuName eq 'Standard_D2s_v5' \
      and priceType eq 'Consumption'" \
  | jq '{Count, Items: [.Items[] | {meterName, productName, retailPrice, unitOfMeasure, type}]}'
```

Illustrative output (**prices change — yours will differ**):

```json
{
  "Count": 4,
  "Items": [
    { "meterName": "D2s v5",      "productName": "Virtual Machines Dv5 Series",
      "retailPrice": 0.096,  "unitOfMeasure": "1 Hour", "type": "Consumption" },
    { "meterName": "D2s v5 Spot", "productName": "Virtual Machines Dv5 Series",
      "retailPrice": 0.0106, "unitOfMeasure": "1 Hour", "type": "Consumption" },
    { "meterName": "D2s v5 Low Priority", "productName": "Virtual Machines Dv5 Series",
      "retailPrice": 0.0192, "unitOfMeasure": "1 Hour", "type": "Consumption" },
    { "meterName": "D2s v5",      "productName": "Virtual Machines Dv5 Series Windows",
      "retailPrice": 0.188,  "unitOfMeasure": "1 Hour", "type": "Consumption" }
  ]
}
```

2. Inspect the full shape of a single item — these field names are exactly what you will later see in Cost Analysis and in the usage CSV:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and priceType eq 'Consumption' and contains(productName, 'Windows') eq false" \
  | jq '.Items[0]'
```

Key fields: `meterId` (the billing primitive), `meterName`, `productName`, `skuName`, `armSkuName`, `serviceFamily`, `unitOfMeasure`, `retailPrice`, `unitPrice`, `tierMinimumUnits`, `effectiveStartDate`, `type`, `reservationTerm`.

3. Convert an hourly meter to a monthly figure the way the Pricing Calculator does — **730 hours** (365 × 24 ÷ 12):

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and meterName eq 'D2s v5' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | select(.productName | test("Windows") | not)
           | "\(.productName): $\(.retailPrice)/h  →  $\(.retailPrice * 730 | .*100 | round / 100)/month"'
```

4. Now open the [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/), add **Virtual Machines**, choose *East US / Linux / D2s v5 / Pay as you go / 730 hours*, and compare the monthly figure to what you just computed.

> ⚠️ **Check your understanding**
>
> **Q1.** The query in step 1 returned four rows for a *single* `armSkuName`. What are the four rows, and what does that tell you about the relationship between "a VM size" and "a billing meter"?
> **Q2.** `Standard_D2s_v5` Linux and `Standard_D2s_v5` Windows differ by roughly $0.092/hour. What is that delta, and which Azure program lets you remove it?
> **Q3.** The API needed no `az login`, no subscription, no API key. What does that tell you about *whose* prices these are, and in what situation would the numbers **not** match your invoice?
> **Q4.** Why 730 hours and not 720 (30 × 24)? What error does 720 introduce over a year?

---

## Block 2 — The factors that actually move an Azure bill

The exam asks you to "describe factors that can affect costs". Rather than reciting them, measure three of them.

### 2a. Region

5. Price the same SKU in five regions:

```bash
for R in eastus westeurope brazilsouth japaneast southafricanorth; do
  P=$(curl -sG 'https://prices.azure.com/api/retail/prices' \
        --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq '$R' \
            and meterName eq 'D2s v5' and priceType eq 'Consumption'" \
      | jq -r '[.Items[] | select(.productName | test("Windows") | not) | .retailPrice] | first // "n/a"')
  printf '%-18s %s USD/hour\n' "$R" "$P"
done
```

Illustrative output:

```
eastus             0.096 USD/hour
westeurope         0.1058 USD/hour
brazilsouth        0.1568 USD/hour
japaneast          0.128 USD/hour
southafricanorth   0.1244 USD/hour
```

### 2b. Bandwidth and billing zones

6. Outbound data transfer is metered; inbound is not. Look at the tier structure:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "currencyCode='USD'" \
  --data-urlencode "\$filter=serviceName eq 'Bandwidth' and armRegionName eq 'eastus' \
      and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.meterName, .tierMinimumUnits, .retailPrice, .unitOfMeasure] | @tsv' \
  | sort | head -20
```

Note the `tierMinimumUnits` column: a single meter can have several rows, each valid from a different cumulative volume. That is graduated tiered pricing — the first N GB at one rate, the next block at a lower rate. See [Bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) for the current free allowance (a monthly quantity of internet egress is free per billing account) and the zone map.

### 2c. Consumption model

7. Compare pay-as-you-go, spot, and dev/test rates for the same silicon:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus'" \
  | jq -r '.Items[] | [.type, .meterName, .productName, .retailPrice, (.reservationTerm // "-")] | @tsv' \
  | column -t
```

Illustrative output:

```
Consumption          D2s v5       Virtual Machines Dv5 Series          0.096    -
Consumption          D2s v5 Spot  Virtual Machines Dv5 Series          0.0106   -
DevTestConsumption   D2s v5       Virtual Machines Dv5 Series Windows  0.096    -
Reservation          D2s v5       Virtual Machines Dv5 Series          0.0605   1 Year
Reservation          D2s v5       Virtual Machines Dv5 Series          0.0389   3 Years
```

> ⚠️ **Check your understanding**
>
> **Q5.** Brazil South costs ~63 % more than East US for identical hardware. Name three cost drivers behind regional price variation, and one *non-cost* reason you would deploy to the expensive region anyway.
> **Q6.** A workload uploads 5 TB/month into Azure Blob Storage and serves 2 TB/month to the internet. Which direction generates a Bandwidth meter, and why is that asymmetry a deliberate commercial design?
> **Q7.** Spot is ~89 % cheaper. State the contract you accept in exchange, the two eviction policies, and one workload class for which spot is unusable.
> **Q8.** `DevTestConsumption` shows the *Windows* product at the same price as Linux consumption. What is being discounted, and what is the eligibility gate?
> **Q9.** List five factors affecting Azure cost that are **not** visible in the Retail Prices API at all.

---

## Block 3 — Pricing Calculator vs. TCO Calculator

These two tools are constantly confused on the exam because both output money. They answer different questions.

8. Build a Pricing Calculator estimate — [azure.microsoft.com/pricing/calculator](https://azure.microsoft.com/en-us/pricing/calculator/):
   1. Add **Virtual Machines** → East US, Linux, D2s v5, Pay as you go, 730 hours.
   2. Add **Managed Disks** → Standard SSD, E10 (128 GiB), 1 disk.
   3. Add **Bandwidth** → 500 GB outbound from Zone 1.
   4. Set **Support** → *Standard*.
   5. Change the region on the VM to *Brazil South* and watch the total move.
   6. Switch the VM to **1-year reserved** and then **3-year reserved**.
   7. Click **Export** (XLSX) and **Save**/**Share** the estimate.

9. Note the levers you just used: region, SKU/tier, quantity/hours, licensing (Azure Hybrid Benefit checkbox), term commitment, dev/test pricing, support tier, currency, and programs & offers.

10. The **TCO Calculator** answers a different question: *should we migrate at all?* Its inputs are your **on-premises** estate (physical/virtual servers, CPU/RAM, DB engines, storage TB by type, network bandwidth) plus assumption knobs — electricity price per kWh, IT labour cost, hardware refresh cycle, virtualisation ratio, datacentre facilities cost. Its output is a **multi-year on-prem vs. Azure comparison**, including cost categories Azure never invoices you for (power, cooling, floor space, hardware depreciation, staff hours).

    Microsoft has been folding this analysis into **Azure Migrate → Business case**, which does the same arithmetic driven by *discovered* inventory instead of typed estimates ([Business case calculations](https://learn.microsoft.com/en-us/azure/migrate/concepts-business-case-calculation)). Check the live entry point at [azure.microsoft.com/pricing/tco/calculator](https://azure.microsoft.com/en-us/pricing/tco/calculator/) — the conceptual distinction below is what the exam tests, regardless of which surface hosts it.

| | Pricing Calculator | TCO Calculator / Business case |
|---|---|---|
| Question answered | "What will *this Azure design* cost?" | "Is moving off our datacentre cheaper?" |
| Input | Azure services, SKUs, regions, quantities | On-prem servers, DBs, storage, network + cost assumptions |
| Output | Itemised monthly/annual Azure estimate | Multi-year TCO comparison, on-prem vs Azure |
| Includes power/cooling/labour/real estate | No | Yes (on-prem side) |
| Typical user | Architect sizing a solution | CFO/sponsor building a migration business case |
| Applies discounts | AHB, reservations, dev/test, offers | Same, plus modelled operational savings |
| Binding? | No — estimate only | No — model only |

> ⚠️ **Check your understanding**
>
> **Q10.** Your finance director asks: "Will Azure be cheaper than the datacentre lease we renew in March?" Which tool, and why is the other one structurally incapable of answering it?
> **Q11.** A Pricing Calculator estimate said $4,200/month; the first invoice was $5,600. Give four legitimate reasons that gap can appear even when the estimate was built correctly.
> **Q12.** Which cost categories does the TCO Calculator count on the on-premises side that never appear on any Azure invoice? Why does including them make Azure look better *and* make the comparison more honest?
> **Q13.** Neither calculator requires an Azure subscription. What does that imply about their relationship to your actual negotiated (EA/MCA/CSP) prices?

---

## Block 4 — Deploy a metered footprint and predict its standing cost

Cost data in the portal lags **8–24 hours**. Rather than wait, you will deploy, then *predict* the bill from the price catalogue, then reconcile in Block 7.

11. Create the resource group with tags applied at creation time:

```bash
az group create \
  --name "$RG" \
  --location "$LOC" \
  --tags costcenter=cc-1024 env=lab owner=az900-student project=cost-mgmt \
  -o table
```

12. Deploy a small Linux VM with an explicitly chosen disk SKU (never accept the default when you are studying cost):

```bash
az vm create \
  --resource-group "$RG" \
  --name vm-cost-lab \
  --image Ubuntu2404 \
  --size Standard_B2als_v2 \
  --storage-sku StandardSSD_LRS \
  --os-disk-size-gb 32 \
  --public-ip-sku Standard \
  --admin-username azureuser \
  --generate-ssh-keys \
  --tags costcenter=cc-1024 env=lab \
  -o table
```

13. Enumerate everything that was created on your behalf — this is the single most under-appreciated cost factor:

```bash
az resource list --resource-group "$RG" \
  --query "[].{name:name, type:type, tags:tags}" -o table
```

Expected: a `Microsoft.Compute/virtualMachines`, a `Microsoft.Compute/disks`, a `Microsoft.Network/networkInterfaces`, a `Microsoft.Network/publicIPAddresses`, a `Microsoft.Network/networkSecurityGroups`, and a `Microsoft.Network/virtualNetworks`. Six resources from one command; **three** of them are chargeable.

14. Deallocate the VM — the operation most people believe is "turning it off":

```bash
az vm deallocate --resource-group "$RG" --name vm-cost-lab
az vm get-instance-view --resource-group "$RG" --name vm-cost-lab \
  --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
```

```
VM deallocated
```

15. Now compute what a *deallocated* VM still costs per month, straight from the catalogue:

```bash
# Managed disk: 32 GiB Standard SSD == the E4 tier, billed per disk per month
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Storage' and armRegionName eq '$LOC' \
      and skuName eq 'E4 LRS' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.productName, .meterName, .retailPrice, .unitOfMeasure] | @tsv'

# Standard static public IPv4
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Virtual Network' and armRegionName eq '$LOC' \
      and contains(meterName, 'Standard Static Public IP') and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.meterName, .retailPrice, .unitOfMeasure] | @tsv'
```

Add the disk's monthly price to (public IP hourly × 730). That figure is your **standing cost**: what you pay for a machine that is doing nothing.

16. Contrast with a VM that is merely *stopped* from inside the guest OS:

```bash
az vm start --resource-group "$RG" --name vm-cost-lab
# ssh in and run `sudo shutdown -h now`, or simulate the resulting state:
az vm get-instance-view -g "$RG" -n vm-cost-lab \
  --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
az vm deallocate --resource-group "$RG" --name vm-cost-lab   # leave it deallocated
```

A guest-initiated shutdown leaves the VM in **Stopped (not deallocated)** — the compute reservation is still held and **still billed**. Only **Stopped (deallocated)** releases the compute meter.

> ⚠️ **Check your understanding**
>
> **Q14.** Six resources were created; three bill. Which three, and which three are free?
> **Q15.** Explain the billing difference between `Stopped` and `Stopped (deallocated)`, and give the exact CLI verb that produces each.
> **Q16.** After deallocation, which meters stop and which continue? Write the standing-cost formula in terms of the two prices you queried.
> **Q17.** Deleting the *VM* with `az vm delete` leaves the disk, NIC, public IP, NSG and VNet behind. What is the governance name for those leftovers, and which two Azure features would catch them automatically?
> **Q18.** You resize from `Standard_B2als_v2` to `Standard_D8s_v5` for a two-hour load test and forget to resize back. Which Cost Management feature detects this the fastest, and what is its detection latency?

---

## Block 5 — Tags: the mechanism that makes cost data *mean* something

A tag is a name/value pair attached to a resource, resource group, or subscription. Tags do nothing technically. Their entire purpose is to project a **business dimension** (cost centre, environment, owner, application, criticality) onto a bill that is otherwise organised by Azure's own taxonomy of meters and services.

17. Read the tags currently on your resources:

```bash
az resource list --resource-group "$RG" \
  --query "[].{name:name, type:type, costcenter:tags.costcenter, env:tags.env}" -o table
```

Notice: the **VNet, NIC, NSG and public IP have no tags**. They were created implicitly by `az vm create`, and `--tags` applied only to the VM. This is the first hard lesson.

18. The second hard lesson — **tags are not inherited**. The resource group carries `owner` and `project`; the resources do not:

```bash
az group show --name "$RG" --query tags -o json
az resource show --resource-group "$RG" --name vm-cost-lab \
  --resource-type Microsoft.Compute/virtualMachines --query tags -o json
```

19. Add a tag without destroying existing ones. `az resource tag --tags` **replaces** the whole tag set; `az tag update --operation Merge` does not:

```bash
NIC_ID=$(az network nic list -g "$RG" --query "[0].id" -o tsv)

# Merge: keeps whatever is there, adds/overwrites the listed keys
az tag update --resource-id "$NIC_ID" --operation Merge \
  --tags costcenter=cc-1024 env=lab -o json --query properties.tags

# Inspect the three operations
az tag update --help | grep -A4 -- '--operation'
```

`Merge` adds/updates listed keys · `Replace` discards everything not listed · `Delete` removes the listed keys.

20. Backfill every untagged resource in the group:

```bash
for ID in $(az resource list -g "$RG" --query "[].id" -o tsv); do
  az tag update --resource-id "$ID" --operation Merge \
    --tags costcenter=cc-1024 env=lab owner=az900-student >/dev/null
  echo "tagged: ${ID##*/}"
done

az resource list -g "$RG" \
  --query "[].{name:name, cc:tags.costcenter, env:tags.env}" -o table
```

21. **Enforce** tagging with Azure Policy instead of shell loops. Resolve the built-in definition by display name — never hard-code the GUID from a blog post:

```bash
INHERIT_ID=$(az policy definition list \
  --query "[?displayName=='Inherit a tag from the resource group'].id | [0]" -o tsv)
REQUIRE_ID=$(az policy definition list \
  --query "[?displayName=='Require a tag on resources'].id | [0]" -o tsv)
echo "$INHERIT_ID"; echo "$REQUIRE_ID"
```

22. Assign the inheritance policy. It uses the `modify` effect, so it needs a managed identity with **Tag Contributor** (or Contributor) rights on the scope:

```bash
az policy assignment create \
  --name "inherit-costcenter" \
  --display-name "Inherit costcenter from resource group" \
  --policy "$INHERIT_ID" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --params '{"tagName":{"value":"costcenter"}}' \
  --mi-system-assigned \
  --location "$LOC" \
  --role "Tag Contributor" \
  --identity-scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  -o table
```

23. `modify` acts on **create/update**, not retroactively. Force existing resources into compliance with a remediation task:

```bash
ASSIGN_ID=$(az policy assignment show --name inherit-costcenter \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" --query id -o tsv)

az policy remediation create \
  --name "rem-inherit-costcenter" \
  --policy-assignment "$ASSIGN_ID" \
  --resource-group "$RG" \
  -o table

az policy state list --resource-group "$RG" \
  --filter "PolicyAssignmentName eq 'inherit-costcenter'" \
  --query "[].{res:resourceId, state:complianceState}" -o table
```

Policy evaluation is not instantaneous — a full scan runs roughly every 24 hours, though assignment triggers an evaluation within ~30 minutes. See [Azure Policy built-ins](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies).

24. Learn the hard limits before you design a taxonomy ([Tag resources](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources)):

| Constraint | Value |
|---|---|
| Tags per resource / resource group / subscription | 50 |
| Tag **name** length | 512 characters (128 for storage accounts) |
| Tag **value** length | 256 characters |
| Characters forbidden in tag names | `<` `>` `%` `&` `\` `?` `/` |
| Inheritance from RG/subscription | **None** by default |
| Support across resource types | Not universal — check [tag support per type](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-support) |
| Case sensitivity | Names are case-insensitive for *operations*, case-preserving for *display*; values are case-sensitive |

25. Separately from ARM inheritance, **Cost Management has its own tag inheritance setting** that stamps subscription/resource-group tags onto the *cost records* of child resources, without touching the resources themselves. Portal: **Cost Management → Configuration → Tag inheritance**. See [Enable tag inheritance](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/enable-tag-inheritance) — including the important detail of which tag wins when a resource and its RG both define the same key, and the fact that it applies to usage from the current month onward, not historical data.

> ⚠️ **Check your understanding**
>
> **Q19.** Why does `az resource tag --tags env=prod` destroy your other tags while `az tag update --operation Merge --tags env=prod` does not?
> **Q20.** State the difference between the ARM-level "Inherit a tag from the resource group" policy and the Cost Management "Tag inheritance" setting. Which one changes the resource, which changes the *bill*, and when would you deliberately choose the second?
> **Q21.** The `modify` effect needs a managed identity and a role assignment; the `deny` and `audit` effects do not. Why?
> **Q22.** A team tags with `CostCenter=CC-1024`, another with `costcenter=cc-1024`. Which halves of those two pairs collide and which do not, and what does the resulting Cost Analysis grouping look like?
> **Q23.** Your CFO wants "cost per application" across 40 subscriptions. Explain why tags alone are insufficient and name the two other Cost Management scoping constructs you would combine with them.

---

## Block 6 — Budgets and alerts as code

A budget in Azure does **not** stop spending. It is a threshold that fires notifications, and optionally triggers an action group — which is where automated shutdown logic can live.

26. Write a complete, deployable subscription-scoped budget:

```bash
cat > budget-az900.json <<'JSON'
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "budgetName":   { "type": "string",  "defaultValue": "bdg-az900-cost-lab" },
    "amount":       { "type": "int",     "defaultValue": 50,
                      "metadata": { "description": "Monthly budget in billing currency." } },
    "startDate":    { "type": "string",
                      "metadata": { "description": "MUST be the first day of a month, e.g. 2026-09-01T00:00:00Z" } },
    "endDate":      { "type": "string",  "defaultValue": "2027-09-01T00:00:00Z" },
    "alertEmails":  { "type": "array" },
    "targetResourceGroup": { "type": "string", "defaultValue": "rg-az900-cost-lab" }
  },
  "resources": [
    {
      "type": "Microsoft.Consumption/budgets",
      "apiVersion": "2021-10-01",
      "name": "[parameters('budgetName')]",
      "properties": {
        "category": "Cost",
        "amount": "[parameters('amount')]",
        "timeGrain": "Monthly",
        "timePeriod": {
          "startDate": "[parameters('startDate')]",
          "endDate": "[parameters('endDate')]"
        },
        "filter": {
          "and": [
            {
              "dimensions": {
                "name": "ResourceGroupName",
                "operator": "In",
                "values": [ "[parameters('targetResourceGroup')]" ]
              }
            },
            {
              "tags": {
                "name": "costcenter",
                "operator": "In",
                "values": [ "cc-1024" ]
              }
            }
          ]
        },
        "notifications": {
          "Actual_GreaterThan_50_Percent": {
            "enabled": true,
            "operator": "GreaterThan",
            "threshold": 50,
            "thresholdType": "Actual",
            "contactEmails": "[parameters('alertEmails')]",
            "contactRoles": [ "Owner" ],
            "locale": "en-us"
          },
          "Actual_GreaterThan_90_Percent": {
            "enabled": true,
            "operator": "GreaterThan",
            "threshold": 90,
            "thresholdType": "Actual",
            "contactEmails": "[parameters('alertEmails')]",
            "locale": "en-us"
          },
          "Forecasted_GreaterThan_100_Percent": {
            "enabled": true,
            "operator": "GreaterThan",
            "threshold": 100,
            "thresholdType": "Forecasted",
            "contactEmails": "[parameters('alertEmails')]",
            "locale": "en-us"
          }
        }
      }
    }
  ],
  "outputs": {
    "budgetId": {
      "type": "string",
      "value": "[subscriptionResourceId('Microsoft.Consumption/budgets', parameters('budgetName'))]"
    }
  }
}
JSON
```

27. Deploy it. `startDate` must be the **first day of a month**:

```bash
START="$(date -u +%Y-%m-01T00:00:00Z)"

az deployment sub create \
  --name dep-budget-az900 \
  --location "$LOC" \
  --template-file budget-az900.json \
  --parameters startDate="$START" alertEmails="[\"$ALERT_EMAIL\"]" \
               targetResourceGroup="$RG" amount=50 \
  --query "properties.{state:provisioningState, budget:outputs.budgetId.value}" -o yaml
```

28. Verify, and read back the notification set:

```bash
az consumption budget list -o table

az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/bdg-az900-cost-lab?api-version=2021-10-01" \
  | jq '.properties | {amount, timeGrain, currentSpend, forecastSpend,
                        notifications: (.notifications | keys)}'
```

Illustrative output:

```json
{
  "amount": 50,
  "timeGrain": "Monthly",
  "currentSpend":  { "amount": 0.41, "unit": "USD" },
  "forecastSpend": { "amount": 3.87, "unit": "USD" },
  "notifications": [
    "Actual_GreaterThan_50_Percent",
    "Actual_GreaterThan_90_Percent",
    "Forecasted_GreaterThan_100_Percent"
  ]
}
```

29. Map the alert families Cost Management can raise ([Cost alerts](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/cost-mgt-alerts-monitor-usage-spending)):

| Alert type | Trigger | Available on |
|---|---|---|
| **Budget alert** | Actual or forecasted spend crosses a % threshold | Any scope with Cost Management |
| **Credit alert** | Azure Prepayment (monetary commitment) drops to 90 % / 100 % consumed | EA only, automatic |
| **Department spending quota alert** | Department spend hits a % of its quota | EA only |
| **Anomaly alert** | Daily usage deviates from the learned pattern | Subscription scope, scheduled, on by default |
| **Scheduled alert** | Emailed cost view on a cadence | Any scope, user-defined |

30. Wire a budget to an **action group** so it can *do* something rather than just email. Add `contactGroups` to a notification with the action group's resource ID; that action group can invoke a Logic App, an Automation runbook, or a webhook that deallocates non-production VMs.

> ⚠️ **Check your understanding**
>
> **Q24.** A budget of $50/month is breached on day 12. What does Azure do to your running resources? Justify the design.
> **Q25.** Distinguish an **Actual** threshold from a **Forecasted** threshold. Which one gives you time to react, and what is its failure mode in a subscription only three days old?
> **Q26.** The template's `filter` scopes the budget to one resource group **and** one tag value. If a resource in that RG lacks the `costcenter=cc-1024` tag, does its spend count against the budget? What does that imply about ordering Block 5 before Block 6?
> **Q27.** Which of the five alert types in step 29 require an Enterprise Agreement, and why can they not exist on a pay-as-you-go subscription?
> **Q28.** You want a budget breach to automatically deallocate all `env=lab` VMs. Name the chain of components, and state the one guarantee this design cannot make.

---

## Block 7 — Cost Analysis: scopes, dimensions, actual vs. amortized

31. Install the extension and confirm your scope:

```bash
az extension add --name costmanagement --upgrade
az extension show --name costmanagement --query version -o tsv
```

32. Query month-to-date cost grouped by resource group:

```bash
az costmanagement query \
  --type ActualCost \
  --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID" \
  --dataset-granularity None \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  --dataset-grouping name="ResourceGroupName" type="Dimension" \
  -o json | jq -r '.rows[] | @tsv'
```

> If this returns `400 BadRequest` complaining about the aggregation column, your scope is a legacy EA scope: replace `"name":"Cost"` with `"name":"PreTaxCost"`. MCA/PAYG scopes use `Cost`/`CostUSD`; EA scopes use `PreTaxCost`. This single difference causes more broken cost automation than any other detail.

33. Group by **tag** instead of by Azure's own taxonomy — this is the payoff for Block 5:

```bash
az costmanagement query \
  --type ActualCost \
  --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID" \
  --dataset-granularity None \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  --dataset-grouping name="costcenter" type="TagKey" \
  -o json | jq -r '.columns[].name as $c | .rows[] | @tsv'
```

34. Break the lab RG down by meter, daily:

```bash
az costmanagement query \
  --type ActualCost \
  --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --dataset-granularity Daily \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  --dataset-grouping name="Meter" type="Dimension" \
  -o json | jq -r '.rows[] | @tsv' | sort -k2
```

Illustrative output (`cost  date  meter  currency`):

```
0.0043  20260905  E4 LRS Disk                  USD
0.0201  20260905  Standard Static Public IP    USD
0.0089  20260905  B2als v2                     USD
```

Reconcile these against the standing cost you predicted in step 15.

35. Compare **ActualCost** with **AmortizedCost** — identical for you today, radically different in an organisation holding reservations:

```bash
for T in ActualCost AmortizedCost; do
  echo "== $T"
  az costmanagement query --type "$T" --timeframe MonthToDate \
    --scope "/subscriptions/$SUB_ID" --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    -o json | jq -r '.rows[][0]'
done
```

36. Understand the **scope hierarchy** — where you point Cost Management determines both what you see and who is allowed to see it ([Understand and work with scopes](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes)):

```
Billing account (EA enrollment / MCA billing account)
└── Department (EA)  |  Billing profile (MCA)
    └── Enrollment account (EA)  |  Invoice section (MCA)
        └── Management group
            └── Subscription
                └── Resource group
                    └── Resource
```

Billing scopes are governed by billing roles; ARM scopes (management group → resource) are governed by RBAC roles — **Cost Management Reader** and **Cost Management Contributor**. The two hierarchies are separate, which is why a subscription Owner can be blind to enrollment-level cost.

37. Set up a recurring **export** — the only correct mechanism for large or historical data, since the query API is rate-limited and truncates:

```bash
SA="stcost$RANDOM$RANDOM"
az storage account create -g "$RG" -n "$SA" -l "$LOC" --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false -o none
SA_ID=$(az storage account show -g "$RG" -n "$SA" --query id -o tsv)
az storage container create --account-name "$SA" --name costexports --auth-mode login -o none

az costmanagement export create \
  --name "exp-mtd-daily" \
  --type ActualCost \
  --scope "/subscriptions/$SUB_ID" \
  --storage-account-id "$SA_ID" \
  --storage-container "costexports" \
  --storage-directory "az900-lab" \
  --timeframe MonthToDate \
  --recurrence Daily \
  --recurrence-period from="$(date -u +%Y-%m-%dT00:00:00Z)" to="2027-01-01T00:00:00Z" \
  --schedule-status Active \
  -o table

az costmanagement export list --scope "/subscriptions/$SUB_ID" -o table
```

38. Finally, look at the free advice already waiting for you:

```bash
az advisor recommendation list --category Cost \
  --query "[].{impact:impact, problem:shortDescription.problem, res:impactedValue}" -o table
```

> ⚠️ **Check your understanding**
>
> **Q29.** Explain **ActualCost** vs **AmortizedCost** using a $10,000 3-year reservation purchased on 4 March. What does each view show for March, and which one should a team be charged back on?
> **Q30.** Cost data lags 8–24 hours and shows no tax. Give two operational consequences of the lag and one reconciliation consequence of the missing tax.
> **Q31.** A subscription **Owner** opens Cost Management and sees their subscription but not the enrollment total. Explain using the two-hierarchy model.
> **Q32.** When must you use an **export** rather than the query API, and why is a daily export to Blob Storage the standard pattern for FinOps pipelines?
> **Q33.** Microsoft Cost Management costs nothing to use for Azure usage. Why can Microsoft afford that, and what is the strategic argument for making cost visibility free?

---

## Block 8 — Reservations and savings plans: read-only break-even analysis

**Do not purchase anything.** Reservations are real commitments. This block is arithmetic on public data.

39. Pull all three price types for one SKU:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "api-version=2023-01-01-preview" \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and contains(productName, 'Windows') eq false" \
  | jq -r '.Items[] | [.type, (.reservationTerm // "-"), .meterName, .retailPrice, .unitOfMeasure] | @tsv' \
  | column -t
```

40. Compute the discount and the break-even utilisation:

```bash
PAYG=$(curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and meterName eq 'D2s v5' and priceType eq 'Consumption'" \
  | jq -r '[.Items[] | select(.productName | test("Windows") | not) | .retailPrice] | first')

RI3=$(curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and priceType eq 'Reservation' and reservationTerm eq '3 Years'" \
  | jq -r '[.Items[] | select(.productName | test("Windows") | not) | .retailPrice] | first')

echo "PAYG hourly : $PAYG"
echo "3-yr hourly : $RI3"
python3 - <<EOF
payg=$PAYG; ri=$RI3
print(f"discount        : {(1-ri/payg)*100:.1f}%")
print(f"break-even util : {(ri/payg)*100:.1f}% of the hours in the term")
print(f"3-yr PAYG cost  : \${payg*730*36:,.0f}")
print(f"3-yr RI cost    : \${ri*730*36:,.0f}")
EOF
```

41. Read what each commitment instrument actually locks you into:

| Instrument | You commit to | Flexibility | Best for |
|---|---|---|---|
| **Reservation** (1 or 3 yr) | A specific VM *series*, region, quantity | Instance-size flexibility within a series; exchange/refund policies apply | Steady, predictable, unchanging shape |
| **Savings plan for compute** (1 or 3 yr) | A fixed **$/hour** across compute services | Applies to VMs, App Service, Container Instances, across regions and series | Steady spend, changing shape |
| **Azure Hybrid Benefit** | Owning Windows Server / SQL Server licences with Software Assurance | Stackable with reservations | Existing licence estate |
| **Spot** | Nothing | Evictable at any time with 30 s notice | Interruptible, checkpointed batch |
| **Dev/Test pricing** | Eligible subscription offer | Non-production only, no SLA on the discount terms | Dev, test, QA |

References: [Reservations](https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations) · [Savings plan for compute](https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview) · [Azure Hybrid Benefit](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/hybrid-use-benefit-licensing)

> ⚠️ **Check your understanding**
>
> **Q34.** Your break-even came out around 40 %. State plainly what that percentage means and what happens if your real utilisation is 30 %.
> **Q35.** When is a **savings plan** the right instrument even though its headline discount is lower than a reservation's?
> **Q36.** Reservations and Azure Hybrid Benefit stack. Which cost component does each one address, and why can they combine without double-counting?
> **Q37.** A team buys a 3-year reservation for `Standard_D8s_v5` in East US and six months later re-architects onto AKS with `Standard_E16ds_v5` in West Europe. What are their options, and what is the underlying lesson about commitment horizon vs. architecture stability?

---

## Block 9 — Teardown, and the resources that survive it

Deleting a resource group is necessary but **not sufficient**. Subscription-scoped objects live outside it.

42. Delete the resource group:

```bash
az group delete --name "$RG" --yes --no-wait
az group wait --name "$RG" --deleted --timeout 1800
az group exists --name "$RG"      # -> false
```

43. Remove the subscription-scoped budget — the RG deletion did **not** touch it:

```bash
az consumption budget list -o table
az rest --method delete \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/bdg-az900-cost-lab?api-version=2021-10-01"
az consumption budget list -o table
```

44. Remove the policy assignment and its role assignment. Deleting the assignment orphans the managed identity's role grant, which is a real (if minor) security finding:

```bash
PRINCIPAL=$(az policy assignment show --name inherit-costcenter \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --query identity.principalId -o tsv 2>/dev/null || true)

az policy assignment delete --name inherit-costcenter \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" 2>/dev/null || true

# Sweep any role assignment left behind by a deleted identity
az role assignment list --all --query "[?principalName==null].{role:roleDefinitionName, scope:scope, id:id}" -o table
```

45. Sweep the whole subscription for orphans — make this a habit, not a lab step:

```bash
echo "== Unattached managed disks"
az disk list --query "[?diskState=='Unattached'].{name:name, rg:resourceGroup, gb:diskSizeGb, sku:sku.name}" -o table

echo "== Unassociated public IPs"
az network public-ip list --query "[?ipConfiguration==null].{name:name, rg:resourceGroup, sku:sku.name, alloc:publicIPAllocationMethod}" -o table

echo "== Unattached NICs"
az network nic list --query "[?virtualMachine==null].{name:name, rg:resourceGroup}" -o table

echo "== Empty resource groups"
for G in $(az group list --query "[].name" -o tsv); do
  [ "$(az resource list -g "$G" --query "length(@)" -o tsv)" = "0" ] && echo "empty: $G"
done
```

46. Confirm the spend closed out (allow 24 h for the last records to land):

```bash
az costmanagement query --type ActualCost --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID" --dataset-granularity Daily \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  -o json | jq -r '.rows[] | @tsv'
```

> ⚠️ **Check your understanding**
>
> **Q38.** Which of the objects you created survive `az group delete`, and what is the general rule that predicts this?
> **Q39.** The last cost records for a deleted resource can appear up to 24 hours *after* deletion. Why, and what does that mean for anyone verifying a cost incident is over?
> **Q40.** Turn step 45 into a policy: name the Azure services you would combine to detect and remediate orphaned disks and public IPs continuously, without a human running a shell loop.

---

<details>
<summary><strong>📘 Answers — expand only after completing the blocks</strong></summary>

### Block 1

**A1.** The four rows are four **meters**: Linux pay-as-you-go, Spot, Low Priority, and Windows. A VM *size* (`armSkuName`) is a hardware shape; a *meter* (`meterId` / `meterName`) is a billing primitive. One size maps to many meters, because price depends on the size **plus** OS licensing **plus** the consumption model. Your invoice is a list of meters and quantities, never a list of "VM sizes" — which is exactly why `Meter` is the most granular useful dimension in Cost Analysis, and why the same VM can appear under multiple line items.

**A2.** The delta is the **Windows Server licence** bundled into the pay-as-you-go rate (the compute portion is identical; only the licence differs). **Azure Hybrid Benefit** removes it: if you own Windows Server licences with active Software Assurance (or a subscription licence), you can apply them to Azure VMs and pay only the Linux-rate compute. The same mechanism exists for SQL Server, and it stacks with reservations because it addresses a different cost component.

**A3.** These are **retail / list prices** — public, unnegotiated, per currency and region. They will **not** match your invoice when: you are on an EA/MCA/CSP agreement with negotiated discounts; you hold reservations or a savings plan; Azure Hybrid Benefit applies; you use dev/test offers or sponsorship credits; free-tier allowances absorb the usage; or tax/currency conversion applies. Retail prices are the correct *upper bound* and the correct basis for comparing SKUs and regions — never the correct forecast of an enterprise bill.

**A4.** 730 = 365 × 24 ÷ 12 — the *average* hours in a month. Using 720 undercounts by 10 hours/month, i.e. **120 hours/year ≈ 1.4 %** of annual compute. At a $500k/year compute spend that is a $7,000 forecasting error, and it always errs in the optimistic direction. Note that Azure bills actual elapsed hours (prorated, and per-second for several services); 730 is a *planning* constant, not a billing rule.

### Block 2

**A5.** Regional price variation is driven by (1) **local energy and land costs** — power is the dominant datacentre operating expense; (2) **hardware import, tax and tariff regimes** plus local labour and compliance costs; (3) **datacentre maturity, scale and capacity utilisation** — newer, smaller regions amortise fixed costs over less demand; and (4) local competitive/market pricing. You would still pay the premium for **data residency and sovereignty**: if regulation requires customer data to remain in Brazil, or if end-user latency demands local presence, region choice is a compliance/architecture decision that cost does not get to override.

**A6.** Only the **2 TB outbound** generates a Bandwidth meter. Inbound (ingress) to Azure is free. The asymmetry is deliberate commercial design: free ingress removes the friction of *getting data in*, while metered egress prices *taking data out* — it lowers the barrier to adoption and raises the cost of leaving. Cost-aware architecture therefore keeps chatty traffic inside a region, uses Private Link and service endpoints to avoid internet paths, and puts a CDN in front of high-volume public content so most egress bills at CDN rates from cache rather than from origin. (Note that a monthly free allowance covers the first tranche of internet egress, and regulatory changes have made egress free when a customer is fully exiting a cloud provider — check current terms rather than assuming.)

**A7.** You accept that Azure may **evict** the VM at any time with roughly 30 seconds of notice when it needs the capacity back, or when your price cap is exceeded. There is **no SLA**. The two eviction policies are **Deallocate** (VM is stopped-deallocated; disks persist and keep billing; you can restart it later) and **Delete** (VM and its disks are removed). Spot is unusable for anything stateful and always-on: databases, domain controllers, any tier behind an SLA, and any long single-shot job that cannot checkpoint. It is ideal for CI/CD agents, batch rendering, and checkpointed ML training.

**A8.** `DevTestConsumption` discounts the **software licence**, not the compute — which is why the Windows product shows at the Linux consumption rate. The gate is the **subscription offer**: Enterprise Dev/Test or Pay-As-You-Go Dev/Test, available to Visual Studio subscribers, and contractually restricted to **non-production** workloads. Running production on a dev/test subscription is a licensing violation, not a clever optimisation.

**A9.** Not visible in the Retail Prices API: (1) your **negotiated EA/MCA/CSP discounts**; (2) **reservations and savings plans you already own**, and how they get applied; (3) **Azure Hybrid Benefit** eligibility from licences you hold; (4) **free-tier allowances** and consumed credits; (5) **support plan tier** (Developer / Standard / Professional Direct) — a flat monthly line on the invoice; (6) **Azure Marketplace third-party charges**, which follow the publisher's own terms; (7) **tax**; (8) **currency conversion** at the invoice date; and (9) the biggest one — **how much you will actually consume**.

### Block 3

**A10.** The **TCO Calculator** (or Azure Migrate's Business case). The Pricing Calculator is structurally incapable of answering it because it only models the Azure side of the ledger: it has no inputs for electricity, cooling, floor space, hardware depreciation, hypervisor licensing, or datacentre staff hours. Without an on-premises baseline there is nothing to compare against, so the Pricing Calculator can tell you what Azure will cost but never whether that is *cheaper*.

**A11.** Legitimate gaps: (1) **estimated vs actual consumption** — the estimate assumed 730 hours and autoscale ran more; (2) **resources nobody estimated** — implicitly created disks, public IPs, load balancers, backups, log ingestion, snapshots; (3) **data transfer** — egress and cross-zone/cross-region traffic are chronically under-modelled; (4) **tax, currency conversion, and the support plan**, none of which the calculator includes by default; (5) **Marketplace items** billed by third parties; and (6) **partial-month proration and non-linear tiers** where the estimate assumed a flat rate.

**A12.** Power, cooling, physical security, floor space and facilities, hardware purchase and depreciation, hardware refresh cycles, hypervisor and OS licensing, network equipment, backup infrastructure, and **IT labour** for racking, patching, and replacing failed hardware. Including them makes Azure look better because those costs are real but *invisible* — they sit in facilities and headcount budgets, not the IT line item. Including them is nevertheless more honest: a comparison that weighs an Azure invoice against only the on-prem hardware invoice is comparing a total cost against a partial one.

**A13.** Both are **marketing/planning tools built on the public retail catalogue**, entirely disconnected from your account. They cannot see your agreement, your existing commitments, your credits, or your consumption history. Treat their output as a *list-price upper bound* to be adjusted downward by your negotiated rate, then validated against actual Cost Management data once anything is running. Never hand a raw calculator export to finance as a forecast.

### Block 4

**A14.** **Billed:** the virtual machine (compute meter, only while running), the managed OS disk (per-disk-per-month, regardless of VM state), and the Standard public IPv4 address (hourly, regardless of VM state). **Free:** the virtual network, the network interface, and the network security group. The instructive part is that a single `az vm create` silently provisions two resources — the disk and the public IP — whose meters are **independent of whether the VM is running**.

**A15.** `Stopped` (guest-initiated, e.g. `shutdown -h now` inside the OS, or `az vm stop`) leaves the VM in **Stopped (not deallocated)**: the compute capacity is still reserved for you on a host, and **you are still billed the full compute rate**. `Stopped (deallocated)` — produced by `az vm deallocate` — releases the host allocation and stops the compute meter. This is the single most expensive misconception in Azure operations: a fleet "shut down for the weekend" from inside the guest costs exactly the same as a fleet left running.

**A16.** **Stops:** the compute meter (`B2als v2` hours). **Continues:** the managed disk meter (billed on provisioned tier, not consumed bytes — a 32 GiB Standard SSD bills as the E4 tier whether it holds 1 GiB or 31), the static public IPv4 meter, plus any attached data disks, snapshots, or backup vault storage. Standing cost formula:

```
monthly_standing = disk_price_per_month + (public_ip_price_per_hour × 730)
```

The lesson: deallocation is a partial saving, not a zero. To reach zero you must delete.

**A17.** They are **orphaned resources** (or "zombie"/"stranded" resources) — the single most common source of untracked cloud waste. Two features catch them: **Azure Advisor**, whose Cost category surfaces unattached disks, idle public IPs, idle load balancers and underutilised VMs; and **Azure Policy** with `audit`/`deny`/`deployIfNotExists` effects to flag or block them. A tag-driven **budget with an action group** is the third line of defence, and Cost Management's **anomaly alerts** are the fourth.

**A18.** **Anomaly alerts**, which run on a scheduled daily evaluation against the learned usage pattern of the subscription — so detection typically lands within about a day, bounded by the 8–24 hour cost-data latency. A budget's *forecasted* threshold can also catch it, but only once the projection crosses the limit, which for a small step change may take several days. Neither is real-time; if you need real-time, the control has to be preventive (Azure Policy denying oversized SKUs) rather than detective.

### Block 5

**A19.** They target different API semantics. `az resource tag --tags ...` issues a **PATCH/PUT of the resource with the supplied tag collection as the complete set** — anything not listed is gone. `az tag update --operation Merge` calls the dedicated **Tags API** with an explicit merge operation, so listed keys are added or overwritten and unlisted keys are left untouched. In automation, always use `Merge` unless you specifically intend to reset the tag set; `Replace` in a CI pipeline is how a whole organisation loses its `costcenter` tags in one run.

**A20.** The **Azure Policy** built-in ("Inherit a tag from the resource group") uses the `modify` effect to **write the tag onto the resource itself** — ARM metadata changes, the tag becomes visible to `az resource show`, to RBAC conditions, to automation, and to every downstream tool. The **Cost Management tag inheritance setting** does not touch resources at all; it stamps subscription/resource-group tags onto the **cost records** during ingestion, so grouping and budget filters see them. You would choose the second when you want cost allocation *without* mutating resources — for example when a resource type does not support tags, when a team owns the resources and you only own the billing scope, or when you lack (or do not want) the write permissions and managed identity that `modify` requires. Its limits matter: it applies from the current month forward, not retroactively, and a tag on the resource itself takes precedence over the inherited one.

**A21.** `audit` and `deny` are **evaluation-only** — they inspect the request payload and either record non-compliance or reject the write. They change nothing, so they need no permissions. `modify` (like `deployIfNotExists`) **mutates resources on your behalf**: Azure Policy must authenticate as something and write to ARM. That something is the assignment's **managed identity**, which therefore needs a role with tag-write rights (Tag Contributor, or Contributor) at the assignment scope. This is also why `modify` assignments require a `--location` — the managed identity is a regional object.

**A22.** Tag **names** are case-insensitive for operations, so `CostCenter` and `costcenter` are the **same key** — the second write updates the first rather than creating a sibling, and the stored casing is whichever was written most recently. Tag **values** are case-**sensitive**, so `CC-1024` and `cc-1024` are **two distinct values**. In Cost Analysis, grouping by `costcenter` therefore yields two separate buckets with the same money split between them — the classic symptom of ungoverned tagging. The fix is preventive: enforce an allowed-values policy on the value, not just a required-key policy.

**A23.** Tags alone are insufficient because they are **per-resource, optional, non-inherited, unenforced by default, and unsupported on some resource types** — so a tag-based view silently omits whatever was never tagged, and there is no way to distinguish "$0 spend" from "untagged". Combine them with (1) **management groups**, which give you an enforceable hierarchy above subscriptions where a single Azure Policy assignment governs everything beneath it, and (2) **subscription and resource-group boundaries** used deliberately as allocation units — one subscription per application or per environment makes allocation structural rather than convention-based. Add Cost Management **tag inheritance** so RG/subscription tags reach cost records, and the untagged residual shrinks to near zero.

### Block 6

**A24.** **Nothing.** A budget is purely a **notification and automation trigger** — Azure keeps running your workloads and keeps charging. The design is deliberate: an automatic hard stop on spend would be an automatic production outage, and the blast radius of "the finance threshold deleted our payment platform" vastly exceeds the blast radius of an overspend. Enforcement, when you want it, is opt-in and explicit: a budget notification → action group → Logic App / Automation runbook that you wrote and accepted the consequences of.

**A25.** An **Actual** threshold fires on cost already incurred — accurate, but by definition after the fact. A **Forecasted** threshold fires when Azure's projection of end-of-period spend crosses the limit — this is the one that gives you time to react, sometimes days. Its failure mode in a three-day-old subscription is that the forecast is built from a very short history: a one-off spike (a load test, an initial data migration) gets extrapolated across the whole month and produces a false alarm, while conversely a subscription with no history yet may not forecast at all. Forecast accuracy improves with usage history; treat early forecast alerts with suspicion.

**A26.** **No** — an untagged resource in that RG does **not** count. The `and` block requires *both* conditions: the resource group dimension **and** the `costcenter=cc-1024` tag. Anything untagged, or tagged with a different value, is invisible to this budget and its spend goes unmonitored. That is precisely why Block 5 comes before Block 6: **tag governance is a prerequisite for cost governance**, not a parallel nice-to-have. A budget filtered on tags that nobody enforces is a budget that silently under-reports, which is worse than no budget because it manufactures false confidence.

**A27.** **Credit alerts** and **department spending quota alerts** require an Enterprise Agreement. They cannot exist on pay-as-you-go because the constructs they monitor do not exist there: a credit alert tracks consumption of an **Azure Prepayment** (monetary commitment negotiated in the EA), and a department spending quota tracks a **department**, an EA-only organisational object between the enrollment and its accounts. Pay-as-you-go has no prepaid balance to draw down and no department hierarchy. Budget alerts, anomaly alerts and scheduled alerts work on any offer.

**A28.** The chain: **Budget** (with a tag/RG filter) → notification with `contactGroups` pointing at an **Action Group** → the action group invokes a **Logic App**, **Azure Automation runbook**, or **webhook/Azure Function** → that code authenticates with a managed identity holding Virtual Machine Contributor → enumerates VMs where `tags.env == 'lab'` → calls deallocate. The guarantee it **cannot** make is *timeliness*: the whole chain is driven by cost data that lags 8–24 hours, so by the time the budget fires, up to a day of overspend has already happened and cannot be undone. Budget-triggered automation is damage limitation, not prevention — prevention is Azure Policy denying the expensive SKU in the first place.

### Block 7

**A29.** **ActualCost** shows cash as it was charged: the full **$10,000 on 4 March**, and then $0 of reservation charge for the remaining 35 months — March's bill looks catastrophic and April's looks impossibly cheap. **AmortizedCost** spreads the purchase evenly across the 36-month term (~$278/month) and **attributes each slice to the resources that actually consumed the reservation**, so a VM covered by the reservation shows its amortised share instead of $0. Chargeback should use **AmortizedCost**: it is the only view where a team's reported cost reflects its consumption rather than the accident of which month the procurement paperwork cleared. Use ActualCost for cash-flow and invoice reconciliation, AmortizedCost for showback/chargeback and unit-economics.

**A30.** The **8–24 hour lag** means (1) you cannot use Cost Management as a real-time control — any runaway spend has already run for up to a day before an alert can possibly fire, so preventive controls (Policy, quotas, SKU restrictions) carry the real load; and (2) "today's cost" is always incomplete, so dashboards that compare a partial today against a complete yesterday manufacture a phantom downward trend — always compare complete days. The **missing tax** means Cost Management figures will never exactly equal the invoice total: reconciliation must be done against the pre-tax subtotal, and any automated invoice-matching that expects an exact equality will fail every month.

**A31.** Because **billing scopes and ARM scopes are two separate hierarchies with separate authorisation systems**. Subscription Owner is an **RBAC** role on an ARM scope — it grants full rights over that subscription and everything under it, and nothing above it. The enrollment/billing account, department and enrollment account (EA) or billing profile and invoice section (MCA) are **billing scopes**, governed by **billing roles** (Enterprise Administrator, Billing Account Owner, etc.) assigned in the billing portal. Being Owner of every subscription in an enrollment still does not make you an Enterprise Administrator. There is also an EA-level policy switch that can hide charges from subscription-scoped users entirely, so an Owner may not even see their own rates.

**A32.** Use an **export** when the data volume or time range exceeds what an interactive query can return: full historical reconciliation, all resources at daily granularity, multi-month analysis, or anything feeding a downstream system. The query API is rate-limited, latency-bound, and truncates large result sets — it is built for dashboards, not pipelines. A **daily export to Blob Storage** is the standard FinOps pattern because it is push-based (no polling, no rate limits), it lands immutable dated files that make the pipeline idempotent and replayable, it costs almost nothing in storage, and Blob is directly consumable by Synapse, Databricks, Fabric, Power BI, or any warehouse loader. For very large enrollments the Cost Details API with asynchronous report generation serves the same role.

**A33.** Microsoft can afford it because the compute and storage behind Cost Management are trivial relative to the consumption it reports on, and it is a **retention feature**: customers who cannot see their costs get surprise bills, and surprise bills drive migrations away. Strategically, free cost visibility (1) removes the excuse for not optimising, which paradoxically increases long-term spend because customers trust the platform enough to put more on it; (2) feeds Advisor recommendations that steer customers toward **reservations and savings plans** — commitments that lock in multi-year revenue; and (3) neutralises third-party cost-management vendors as a differentiator. Charging for the bill would be, in the plainest terms, a bad look.

### Block 8

**A34.** A **break-even utilisation of ~40 %** means the reservation costs the same as pay-as-you-go if the reserved capacity is actually used about 40 % of the hours in the term; above that you save, below it you lose. At **30 % real utilisation you are overpaying** — you have prepaid for capacity you are not consuming, and you would have been cheaper on demand. This is why reservation decisions must be driven by measured historical utilisation (Cost Management's reservation utilisation reports and Advisor's reservation recommendations, which analyse the last 7/30/60 days), never by an intention to "probably keep it running".

**A35.** A **savings plan** wins when your **spend is stable but its shape is not**. A reservation locks a specific VM series in a specific region, so re-architecting, migrating regions, or moving from VMs to App Service or Container Instances strands it. A savings plan commits to a **fixed $/hour of compute** and applies automatically across eligible compute services, series and regions — you keep the discount through the refactor. Choose the reservation's deeper discount only when the workload shape is genuinely frozen for the term; choose the savings plan when you are confident about the *amount* but not the *form*.

**A36.** They address different components of the same bill. A **reservation** discounts the **infrastructure/compute** portion — the cost of the hardware-hours. **Azure Hybrid Benefit** removes the **Windows Server (or SQL Server) licence** portion, because you are supplying the licence yourself from your own Software Assurance entitlement. Since a Windows pay-as-you-go rate is literally compute + licence, discounting one and removing the other cannot double-count. In practice you reserve the compute and apply AHB on top, which is why reserved Windows VMs with AHB are priced at the reserved *Linux* rate.

**A37.** Options, roughly in order of preference: (1) **instance-size flexibility** automatically applies the reservation's benefit to other sizes in the same series in the same region — useful if they stayed on Dsv5; (2) **exchange** the reservation for a different one (scope, region, series, term) — Microsoft's exchange policy for compute reservations has been restricted over time, so verify current terms before relying on it; (3) **trade in a reservation for a savings plan**, which is the escape hatch designed for exactly this scenario; (4) **refund/cancel**, subject to an early-termination fee and a per-billing-profile annual cap; (5) **re-scope** the reservation from single-subscription to shared, so any other workload in the enrollment can absorb the benefit. The lesson: **match the commitment horizon to the architecture's stability horizon.** A three-year commitment on a platform you are actively re-architecting is a bet against your own roadmap — prefer one-year terms, or a savings plan, whenever the shape of the estate is in motion.

### Block 9

**A38.** Surviving `az group delete`: the **subscription-scoped budget** (`Microsoft.Consumption/budgets` at subscription scope), any **policy assignment** at subscription or management-group scope, **role assignments**, **reservations and savings plans**, **support plans**, **management groups**, and any resource that was created in a *different* resource group (a Recovery Services vault holding this VM's backups, a Log Analytics workspace receiving its diagnostics, a snapshot taken into another RG). The general rule: **deleting a container deletes only what is inside it.** Anything whose scope is *above* the resource group, or whose home is a *different* resource group, is untouched — so teardown must be driven by scope, not by location.

**A39.** Usage records are generated by the metering pipeline, aggregated, rated, and only then surfaced in Cost Management — a process that runs on a lag of roughly 8–24 hours, and rating for some services (and Marketplace charges) lands later still. The final hours a resource lived are therefore reported *after* the resource no longer exists. For anyone verifying a cost incident is over, this means **a $0 reading today is not proof**: you must re-check the completed daily figures at least 24–48 hours after deletion, and confirm on the following invoice. It also means a post-mortem written the same day will systematically understate the incident's total cost.

**A40.** A continuous version of step 45: **Azure Policy** at management-group scope with an `audit` (or `deny`) effect on unattached disks and unassociated public IPs, giving you a persistent compliance view instead of a point-in-time script; **Azure Advisor** Cost recommendations as the managed detector for idle and underutilised resources; **Azure Resource Graph** as the query engine (a single KQL query across every subscription, which is what step 45's loop is a slow imitation of); **Azure Automation** or an **Azure Function** on a timer to act on the results, authenticated by a managed identity; **Azure Monitor alerts / action groups** to notify owners — routed by the `owner` tag, which is why the tag taxonomy from Block 5 is load-bearing here; and **resource locks** plus a grace period so remediation never deletes something a human is mid-way through building. Detect broadly, notify first, delete only after an ageing window.

</details>

---

## Sources

- [AZ-900 study guide — skills measured](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900)
- [What is Microsoft Cost Management and Billing?](https://learn.microsoft.com/en-us/azure/cost-management-billing/cost-management-billing-overview)
- [Understand and work with Cost Management scopes](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes)
- [Understand cost management data (latency, actual vs amortized)](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-cost-mgt-data)
- [Tutorial: create and manage budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Use cost alerts to monitor usage and spending](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/cost-mgt-alerts-monitor-usage-spending)
- [Create and manage exported data](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports)
- [Azure Retail Prices REST API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Use tags to organize your Azure resources](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources)
- [Tag support for Azure resources](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-support)
- [Group and allocate costs using tag inheritance](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/enable-tag-inheritance)
- [Azure Policy built-in policy definitions](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies)
- [Save money with Azure Reservations](https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations)
- [Azure savings plan for compute](https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview)
- [Azure Hybrid Benefit](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/hybrid-use-benefit-licensing)
- [Azure Spot Virtual Machines](https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms)
- [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/) · [TCO Calculator](https://azure.microsoft.com/en-us/pricing/tco/calculator/) · [Azure Migrate business case](https://learn.microsoft.com/en-us/azure/migrate/concepts-business-case-calculation)
- [Bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) · [Managed Disks pricing](https://azure.microsoft.com/en-us/pricing/details/managed-disks/)