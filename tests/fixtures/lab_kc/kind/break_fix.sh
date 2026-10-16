#!/usr/bin/env bash
case "${1:-break}" in
  break) echo broken > /tmp/demo2; echo "SYMPTOM: demo is broken" ;;
  verify) [ "$(cat /tmp/demo2)" = fixed ] && echo "SOLVED" || echo "not yet" ;;
  cleanup) rm -f /tmp/demo2 ;;
esac

# ==============================================
# SOLUTION (not executed)
# ==============================================
#   echo fixed > /tmp/demo2
