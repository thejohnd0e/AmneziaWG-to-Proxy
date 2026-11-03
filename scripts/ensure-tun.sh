#!/bin/sh

TUN_DEVICE="${TUN_DEVICE:-/dev/net/tun}"

if [ -c "$TUN_DEVICE" ]; then
    exit 0
fi

if [ -e "$TUN_DEVICE" ]; then
    echo "ERROR: $TUN_DEVICE exists but is not a character device" >&2
    exit 1
fi

if ! mkdir -p "$(dirname "$TUN_DEVICE")"; then
    echo "ERROR: Could not create $(dirname "$TUN_DEVICE")" >&2
    exit 1
fi

if ! mknod "$TUN_DEVICE" c 10 200 || ! chmod 600 "$TUN_DEVICE"; then
    echo "ERROR: Could not create TUN device at $TUN_DEVICE" >&2
    exit 1
fi
