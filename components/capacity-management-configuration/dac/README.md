# Capacity dashboards as code

CUE dashboard-as-code for the Perses dashboards in this component. Requires `cue` >= 0.16.1 and `percli` >= 0.54.0.

```sh
cue mod tidy
percli dac setup --version 0.54.0   # first time only
percli dac build -f vm-capacity.cue
percli dac build -f capacity-exhaustion.cue
percli dac build -f vm-overcommit.cue
```

Each build writes `built/<name>_output.yaml`, a Perses `Dashboard`. The parent `kustomization.yaml` imports those files and applies `wrap-perses-dashboard.yaml` so GitOps ships `PersesDashboard` CRs in `openshift-operators`. Rebuild after editing a `.cue` file; kustomize picks up the new `built/` output on the next sync.

ListVariable `defaultValue` is flattened to a string by kustomize patches. The CUE SDK emits `{singleValue, sliceValues}`; the Perses operator only unmarshals a string or an array of strings.

Do not copy BarChart `groupBy` / `isStacked` / `orientation` into a dashboard. This cluster's Perses image ships BarChart 0.11.1, which rejects those fields. Stacked columns belong on TimeSeriesChart with `visual.display: bar` and `visual.stack: all`.
