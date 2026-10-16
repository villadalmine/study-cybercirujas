#!/bin/bash
# Exit 0 only when the lab's own verify mode says solved.
export I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes
export LAB_DISPOSABLE=yes
export STUDY_LAB=1
cd /opt/study-lab/democert-1.2 || exit 1
out=$(timeout 120 bash ./break_fix.sh verify 2>&1)
code=$?
echo "$out"
[ "$code" -eq 0 ]
