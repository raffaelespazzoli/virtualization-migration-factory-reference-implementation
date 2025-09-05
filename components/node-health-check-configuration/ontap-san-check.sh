#!/bin/bash

# This plugin checks if the ntp service is running under systemd.
# NOTE: This is only an example for systemd services.

readonly OK=0
readonly NONOK=1
readonly UNKNOWN=2

# Return success if we can read data from the block device
export device=$(chroot /node-root multipath -ll | grep "NETAPP,LUN" | awk '{print $2}' | shuf | head -n 1)
if chroot /node-root multipath -C $device; then
    echo "ontap-san-test is accessible"
    exit $OK
else
    echo "ontap-san-test is NOT accessible"
    exit $NONOK
fi