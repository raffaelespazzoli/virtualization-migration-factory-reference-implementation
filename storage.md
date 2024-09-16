# Storage setup

In the environment ion which we tested this repo we had a NetApp storage appliance, so that is where we get our storage. You'll have to customize this setup for you particular environment. 
The CSI driver for NetApp is called trident we had to [deploy the operator](./components/trident-operator/) and [configure the storage classes](./components/trident-configuration/).

Notice that we used the following annotations:

- cluster default storage class: `storageclass.kubernetes.io/is-default-class: "true"`
- OpenShift Virtualization default storage class: `storageclass.kubevirt.io/is-default-virt-class: "true"`

The cluster default storage class is set on the NAS (NFS in NEtApp) and the OpenShift Virtualization default storage class is set on the SAN.

Many components of this setup require also object storage. For that we used Minio and deployed the [minio operator](./components/minio-operator/). Every time we need to deploy a bucket we will use the Minio Tenant helm chart to do so.

In your setup you'll have to discuss with your customer on how to procure object storage and replace the Minio Tenant-provided buckets with something else.

Components that use a object storage:

- [acm-observability](./components/acm-observability/)