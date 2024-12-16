set -e
podman build -t quay.io/raffaelespazzoli/fedora-gnome-vdi:41 .
mkdir -p output
podman run \
    --rm \
    -it \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v $(pwd)/output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --local \
    --type qcow2 \
    --rootfs xfs \
    --config /output/config.json \
    quay.io/raffaelespazzoli/fedora-gnome-vdi:41