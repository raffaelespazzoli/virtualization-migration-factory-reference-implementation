# VM capacity dashboard

CUE dashboard-as-code for the single "how many VMs fit" panel. Requires `cue` >= 0.16.1 and `percli` >= 0.54.0.

```sh
cue mod tidy
percli dac setup --version 0.54.0   # first time only
percli dac build -f vm-capacity.cue
```

The build writes `built/vm-capacity_output.yaml`, a Perses `Dashboard`. The GitOps resource is the parent `perses-dashboard.yaml`, which wraps that spec as a `PersesDashboard` in `openshift-operators`.

When copying the spec, flatten each ListVariable `defaultValue` to a string. The CUE SDK emits `{singleValue, sliceValues}` because that is the Go struct; the Perses operator only unmarshals a string or an array of strings. Leftover object form fails reconcile with `unable to unmarshal defaultValue`.

Do not copy BarChart `groupBy` / `isStacked` / `orientation` into the GitOps CR. This cluster's Perses image ships BarChart 0.11.1, which rejects those fields. Stacked columns belong on TimeSeriesChart with `visual.display: bar` and `visual.stack: all`.
