#!/bin/bash

# This plugin checks if the ntp service is running under systemd.
# NOTE: This is only an example for systemd services.

readonly OK=0
readonly NONOK=1
readonly UNKNOWN=2

# Return success if the link is up
if ip link show bond0 | grep "state UP" | grep ,UP | grep ,LOWER_UP && exit 0 || exit 1; then
    echo "bond0 is up"
    exit $OK
else
    echo "bond0 is down"
    exit $NONOK
fi