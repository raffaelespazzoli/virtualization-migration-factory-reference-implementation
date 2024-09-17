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

