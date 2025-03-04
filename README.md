# Virtualization Migration Factory Reference Implementation
A well-architected virtualization migration factory deployment aimed at making it easy for everyone to get started with this kinds of efforts.

## TL/DR Getting started 

You will have to customize the following before you can get started:

- The setup for the clusters you create. Here we have two clusters [etl6](./clusters/hub/overlays/cluster-etl6/) and [etl7](./clusters/hub/overlays/cluster-etl7/). This includes, BMHs, initial network configuration for the, VIPs, certificates, DNS entries. See more about it in the [cluster provisioning](#cluster-provisioning) section.
- The storage layer, this incudes defining CSI drivers and storage classes. See more [here](#storage-architecture) and [here](./storage.md)
- The additional network layer configurations. This includes defining NodeNetwworkConfiguraiotnPolicies (NNCP) and NodeNetworkAttachment (NAD) for the VMs. See more [here](#networking-architecture)

Once you have performed the above customization you can run the following:

```sh
export gitops_repo=<https://github.com/raffaelespazzoli/virtualization-migration-factory-reference-implementation.git #<your newly created repo>>
export cluster_name=hub #<your hub cluster name, typically "hub">
export cluster_base_domain=$(oc get ingress.config.openshift.io cluster --template={{.spec.domain}} | sed -e "s/^apps.//")
export platform_base_domain=${cluster_base_domain#*.}
oc apply -f .bootstrap/subscription.yaml
oc apply -f .bootstrap/cluster-rolebinding.yaml
sleep 60
envsubst < .bootstrap/argocd.yaml | oc apply -f -
sleep 30
envsubst < .bootstrap/root-application.yaml | oc apply -f -
```

## High-Level Architecture

This repository automates via gitops the deployment of the following architecture:

![well-architected migration factory](media/clusters.drawio.png)

We can see that we will have three clusters:

1. A Hub Cluster with ACM, AAP and MTV to managed the other clusters and coordinate migration waves
2. two managed cluster, called Prod1 and Prod2 with OpenShift Virtualization, OADP to run Virtual Machines.


## GitOps Approach

This repository uses the [CoP ArgoCD Model](https://github.com/redhat-cop/gitops-standards-repo-template) approach for controlling the configuration.
Each configuration folder that contains non-trivial configuration, will have a short readme explaining the configuration and pointing out the expected customization expected when running in a different environment.

## Cluster Provisioning

This repository uses a fully declarative cluster provisioning model. We use ACM and agent-based installer to achieve that.


blockers to full end-to-end automation:
https://issues.redhat.com/browse/ACM-2320
https://issues.redhat.com/browse/MGMT-18974

## Networking Architecture

This repository will configure the following networks:

1. node network. This network is realized with the bonding of two NICs fir HA.
2. storage network. Also this network is realized with the bonding of two NICs.
3. Virtual Machine network. This is where all of the VM networks (VLANs) will live. This network is on a single NIC for limitations due to the hardware available, but in a well-architected installation this network would also be build on a bond.

The networking setup will look similar to the following image:

![networking](media/networking.drawio.png)

With the exception that we didn't create a network dedicated to VLAN migration. When you customize this setup you can discuss with the customer whether this network is required.

## Storage Architecture

Typically customer attach their VMs to a SAN system. This repository assumes you have a SAN system and we used NetApp. You will have to customize this repository to use your customer's particular setup.

Storage can be setup using either a direct CSI driver or a SDS approach:

| Approach | Pros | Cons |
| :-------- | :------- | :------- |
| CSI Driver | - Kubernetes Native</br> - Can leverage the full SAN product capabilities | - CSI drivers not always ready (buggy, untested at scale, not having the features  needed for KubeVirt) </br> - Some SANs can only support a limited number of LUNs </br> - Some storage organizations do not want to give OCP credentials to provision LUNs |
| SDS | - Same behavior irrespective of the underlying SAN </br> - SDS solutions work typically well with KubeVirt | - Additional licensing costs </br> - Additional latency </br> - Write amplification: SDSs write the same data multiple times (ODF 3 times), increasing the storage needed on the SAN. This jeopardizes the migration business case |

CSI Driver architecture

![csi](media/csi.drawio.png)

SDS architecture

![sds](media/sds.drawio.png)

We will implement both of them as multiple storage systems can coexist, making easier for the implementer to pick the one suitable for a particular deployment.

The component that depend on storage will use the default storage class. So it is recommended to configure one before starting the deployment. As a reminder these annotation determine the default storage classes:

- cluster default storage class: `storageclass.kubernetes.io/is-default-class: "true"`
- OpenShift Virtualization default storage class: `storageclass.kubevirt.io/is-default-virt-class: "true"`

For more information about the storage setup for this particular repo see here.

## VM Backup and Restore


## Disaster Recovery


## Ansible Automation Platform


## MTV

