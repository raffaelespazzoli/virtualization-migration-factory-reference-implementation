#!/bin/bash

# This plugin checks if the ntp service is running under systemd.
# NOTE: This is only an example for systemd services.

readonly OK=0
readonly NONOK=1
readonly UNKNOWN=2

# Return success if we can read data from the block device
# if timeout -k 2s -s 9 1s dd iflag=direct if=/dev/ontap-san-test bs=4096 count=1 of=/dev/null; then
# if dd iflag=direct,nonblock if=/dev/ontap-san-test bs=4096 count=1 of=/dev/null; then
# if sg_read if=/dev/ontap-san-test bs=4096 count=1 time=2 blk_sgio=1; then
export device=$(chroot /node-root multipath -ll | grep "NETAPP,LUN" | awk '{print $2}' | shuf | head -n 1)
if chroot /node-root multipath -C $device; then
    echo "ontap-san-test is accessible"
    exit $OK
else
    echo "ontap-san-test is NOT accessible"
    exit $NONOK
fi