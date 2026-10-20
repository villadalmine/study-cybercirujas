# AZ-900 2.2 lab: Describe Azure compute and networking services

> **Warning: this lab does more than break a throwaway container.**
>
> - It creates real cloud resources that cost money until you delete them.
> - It exposes something on a public IP address while it runs.
>
> Creates real, billable Azure resources in your subscription (a VNet, two NSGs, a Standard public IP and a B1s VM running nginx), and the VM answers on that public IP while the lab exists. Use a sandbox or free-credit subscription and run `break_fix.sh teardown` when you finish: until then it keeps costing money.

The lab is `break_fix.sh` (its header explains the faults and the verbs) and `lab.yaml`, which declares this warning under `safety:`. `teach lab up az-900 2.2` prints it and asks for confirmation before anything starts.
