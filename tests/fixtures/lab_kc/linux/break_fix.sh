#!/usr/bin/env bash
case "${1:-break}" in
  break) echo broken > /tmp/demo-state; echo "SYMPTOM: demo is broken" ;;
  verify) [ "$(cat /tmp/demo-state)" = fixed ] && echo "SOLVED" || echo "not yet" ;;
  cleanup) rm -f /tmp/demo-state ;;
esac

# ==============================================
# SOLUTION (not executed)
# ==============================================
#   echo fixed > /tmp/demo-state
