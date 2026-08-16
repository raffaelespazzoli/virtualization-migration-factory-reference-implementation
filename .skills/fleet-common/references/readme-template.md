# Component Readme Template

Use this template when generating or updating a component's `readme.md`. Adapt section depth and content to the component's complexity — a simple standalone component may skip sections that don't apply.

---

# {Component Display Name}

{One-paragraph description of what this component does and why it exists in the fleet.}

## Upstream Project

- **Product:** {Product name, e.g. "Red Hat Advanced Cluster Management" or "NetApp Astra Trident"}
- **Documentation:** {Link to official docs}
- **Operator:** {Operator package name from OperatorPolicy, if applicable}
- **Channel:** {Subscription channel}
- **Source:** {Catalog source}

## Lifecycle Parts

| Part | Sync-Wave | Purpose |
|------|-----------|---------|
| `{name}-operator` | {wave} | {What it deploys} |
| `{name}-instance` | {wave} | {What CR it creates} |
| `{name}-configuration` | {wave} | {What it configures} |

## Configuration

{Description of key configuration choices made in this repo. What CRs are created, what values are set, what is commented-out/available as options.}

## Cluster Deployment

| Cluster | Source |
|---------|--------|
| {cluster-name} | {group or cluster-specific} |

## Dependencies

{Other components this one depends on, and components that depend on it. Explain the ordering relationship.}

## Customization Points

{What cluster-level overlays typically customize about this component. Reference existing overlays as examples.}

---

## Template Usage Notes

- Omit **Upstream Project** for non-operator components that don't come from a catalog
- Omit **Lifecycle Parts** table for standalone components with no suffixed siblings
- **Configuration** is always required — it's the primary value of the readme
- **Dependencies** should mention sync-wave ordering rationale when it deviates from defaults
- Keep the readme factual and current with the repo state; link to upstream docs for deep-dive information rather than duplicating it
