# Cluster Creation


The objective is to create clusters as much as possible in a declarative way.
In ACM this is possible by using the agent install in a similar way to what ZTP.
These are the logical steps

1. create [support for infraenvs](./components/acm-configuration/) and serving ISOs
2. create infraenv ([etl6 example](./clusters/hub/overlays/cluster-etl6/kustomization.yaml) and [bm cluster creation helm chart](.helm-charts/bm-cluster-agent-install/templates/infra-env.yaml))
3. create baremetal hosts inventory [etl6 example](./clusters/hub/overlays/cluster-etl6)
4. allow for the hosts to be discovered, this creates the Agents relative to the hosts.
6. create the cluster ([etl6 example](./clusters/hub/overlays/cluster-etl6/kustomization.yaml) and [bm cluster creation helm chart](.helm-charts/bm-cluster-agent-install/templates/agent-cluster-install.yaml))
7. register the cluster to ACM ([etl6 example](./clusters/hub/overlays/cluster-etl6/kustomization.yaml) and [registration helm chart](.helm-charts/cluster-registration/)


# Cluster Creation Process

```mermaid
---
title: Cluster Creation
---
flowchart TD
  cluster-registration --> gitops-boostrap-policy
  subgraph "hub cluster"
    cluster_folder(glb00xx ) -- creates --> cluster-registration(cluster-registration 
      helm chart that registers the cluster to ACM and triggers policies)
    cluster_folder(glb00xx ) -- creates --> cluster-creation(cluster-creation 
      helm chart that creates: DNSRecords, Certificates, InfraEnv, BMHs, NMState and cluster creation) 
  end    
  subgraph "managed cluster"
    subgraph "regisration"
        gitops-boostrap-policy(gitops-boostrap-policy creates: IDMS,ITMS, ContentSource, CatalogSource, so the cluster can pull images
        Deploys ArgoCD Operator
        Deploys ArgoCD instance
        Deploys Root AppOfApp
        Propagate_secrets: github credentials and certs
        Propagate_vault_secrets: secrets are copied from infra-secrets to destination namespace)    
    end
    gitops-boostrap-policy --> dell
    gitops-boostrap-policy --> pure
    gitops-boostrap-policy --> openshift-logging
    gitops-boostrap-policy --> otel
    gitops-boostrap-policy --> cert-manager
    gitops-boostrap-policy --> nmstate
    gitops-boostrap-policy --> vault-secret
    gitops-boostrap-policy --> compliance
    gitops-boostrap-policy --> update-service
    gitops-boostrap-policy --> virtualization
    gitops-boostrap-policy --> descheduler
    gitops-boostrap-policy --> node-health-check
    gitops-boostrap-policy --> MTC
    subgraph "syncwave5"
        dell
        pure
        openshift-logging
        otel
        cert-manager
        nmstate
        vault-secret
        compliance
        update_service
        virtualization
        descheduler
        node-health-check
        MTC
    end
    otel --> otel-configuration
    vault-secret-configuration --> otel-configuration
    openshift-logging --> logging-configuration
    vault-secret-configuration --> logging-configuration
    nmstate --> nmstate-instance
    vault-secret --> vault-secret-configuration
    compliance --> compliance-configuration
    subgraph "syncwave6"
        otel-configuration
        logging-configuration
        nmstate-instance
        vault-secret-configuration(vault-secret-configuration: secrets are pulled from Vault to infra-secrets namespace)
        compliance-configuration
    end
    pure --> pure-instance
    vault-secret-configuration --> pure-instance
    pure-instance --> pure-storage
    subgraph "syncwave7"        
        pure-instance
        pure-storage
    end
    virtualization --> virtualization-instance
    descheduler --> descheduler-configuration
    MTC --> MTC-configuration
    nmstate-instance --> nmstate-configuration
    node-health-check --> node-health-check-configuration
    vault-secret-configuration --> node-health-check-configuration
    subgraph "syncwave15"
        virtualization-instance
        descheduler-configuration
        MTC-configuration
        nmstate-configuration
        node-health-check-configuration
    end
    vault-secret-configuration --> openshift-configuration
    subgraph " syncwave16"
        openshift-configuration(openshift-configuration: configures monitoring, alertmanager, authentication, RBAC, certificates)
    end     
    virtualization-instance --> virtualizaiton-configuration
    subgraph " syncwave20"
        virtualizaiton-configuration
    end                
  end

```

```
---
title: Cluster Creation
---
flowchart TD
  venafi-auth-policy-configuration --> cert-manager-application
  cluster-registration --> openshift-gitops-operator
  github-auth-policy-configuration --> openshift-gitops-operator
  secured-cluster-policy --> acs-secured-configuration
  subgraph "on the ACM cluster"

 
    venafi-auth-policy-configuration(venafi-auth-policy-configuration 
      ACM policy that sends the venafi credentials to the managed clusters)
    github-auth-policy-configuration(github-auth-policy-configuration 
      ACM policy that sends the github credentials to the managed clusters)
    secured-cluster-policy(secured-cluster-policy 
      ACM policy that sends the ACS bundle to the managed clusters)
  end
  subgraph "on the Managed cluster"
    openshift-gitops-operator --> cert-manager-operator
    cert-manager-operator --> cert-manager-application(cert-manager-application
     runs a job to turn the venafi credentials into venafi token, 
     then configures the venafi cert issuer)
    cert-manager-application --> ingress-controller-configuration(ingress-controller-configuration 
      installs 53 cert on the cluster ingress)
    cert-manager-application --> openshift-api-certs-application(openshift-api-certs-application 
      installs 53 cert for the OCP API)
    openshift-api-certs-application --> vault-config-operator  
    vault-config-operator --> vault-configuration(vault-configuration 
      configures access to vault to extract infra secrets) 
    nmstate-operator --> nmstate-configuration(nmstate-configuration 
      allows access to storage network)
    namespace-config-operator --> namespace-configuration(namespace-configuration  
    deploys ESO secret store to infra namespaces)
    vault-configuration --> namespace-configuration
    external-secret-operator --> namespace-configuration
    powerflex-csm-operator --> powerflex-csm-configuration(powerflex-csm-configuration
      deploys CSI storage class for the cluster)
    namespace-configuration --> powerflex-csm-configuration
    nmstate-configuration --> powerflex-csm-configuration
    acs-operator --> acs-secured-configuration(acs-secured-configuration 
      registers the cluster to ACS)  
  end
