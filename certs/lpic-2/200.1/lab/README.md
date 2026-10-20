# LPIC-2 200.1 lab: Measure and Troubleshoot Resource Usage

A Debian 12 box with systemd and two faults planted on purpose. You find both by measuring
(`uptime`, `vmstat`, `top`, `ps`, `pstree`, `df`, `du`, `lsof`), not by guessing.

## Goals

1. The CPU is busy on an idle box. Find the process and stop it for good. Killing the PID is not enough: something restarts it, so look at its parent and the systemd unit.
2. The disk shows used space that du can't find. Find who still holds the deleted file and release it.

**Solved means:** Check passes when the systemd unit behind the CPU burner is stopped and disabled, no worker process of it is left, and no process holds a deleted file under the spool directory /var/tmp/lab-200.1.

## Run it

```
study-lab run lpic-2 200.1      # environment + break; prints the symptom
study-lab hint lpic-2 200.1     # one hint at a time (-n 4 for all)
study-lab check lpic-2 200.1    # SOLVED when both goals are met
study-lab down lpic-2 200.1     # cleanup + remove the container
```

The lab is `break_fix.sh` (its header explains the faults and the verbs; the solution is commented
out at the end) and `lab.yaml`, which declares the goals above under `goals:`. The Killercoda
scenario shows the same goals in its intro and in the Fix step.
