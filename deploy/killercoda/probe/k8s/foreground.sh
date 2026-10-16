#!/bin/bash
echo 'Probing...'
bash /root/probe.sh 2>&1 | tee /root/probe.out
