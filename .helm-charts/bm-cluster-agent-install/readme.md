# bm-cluster-agent-install

This helm chart will create a cluster using the agent-installer approach in ACM (TODO Link).
It is assumed that BaremetalHosts and possible NMStateConfig CRs are created separately.

Also a pull secret must be made available in the namespace with the name `pullsecret-{{.Release.Name}}`.