# AZ-900 2.4 lab: Describe Azure identity, access, and security

> **Warning: this lab does more than break a throwaway container.**
>
> - It changes files or settings of the machine it runs on.
>
> Moves your Azure CLI profile and token cache out of ~/.azure, rewrites ~/.azure/config, edits /etc/hosts and adds a blackhole route on the machine it runs on. Run it only on a disposable VM, never on your own workstation; `break_fix.sh --restore` puts the files back.

The lab is `break_fix.sh` (its header explains the faults and the verbs) and `lab.yaml`, which declares this warning under `safety:`. `teach lab up az-900 2.4` prints it and asks for confirmation before anything starts.
