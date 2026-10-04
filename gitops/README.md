# GitOps

Everything in this directory is intended to be reconciled by Flux CD after the base cluster is available.

Recommended order (when wired up):

1. cert-manager
2. Flux CD bootstrap (GitRepository + Kustomization for `flux/`)
3. monitoring/logging
4. applications