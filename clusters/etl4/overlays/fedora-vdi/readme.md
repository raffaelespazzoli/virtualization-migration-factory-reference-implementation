
ldap config based on: https://www.server-world.info/en/note?os=Fedora_40&p=openldap&f=3
gnome config based on:

```sh
sudo podman build -t quay.io/raffaelespazzoli/fedora-gnome-vdi:41 .
mkdir -p output
sudo podman run \
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
    quay.io/raffaelespazzoli/fedora-gnome-vdi:41
```    