# Dependency update and release promotion

## Decision

Model Pilot automates **discovery and review preparation**, not runtime adoption or public release.

The updater may create or refresh one dependency-candidate pull request. A maintainer must review,
perform a real completion test on trusted Windows/GPU hardware, and merge it. A separate,
maintainer-created product tag publishes an installer release.

This boundary is deliberate. Hosted GitHub runners can parse PowerShell, build the installer, and
validate upstream release metadata, but cannot prove model loading, GPU placement, VRAM headroom,
or real inference. In particular, a service health check is not evidence that llama-swap can proxy a
completion.

## Source of truth

`start.ps1` `$VER` is the sole source of pinned bootstrap component versions. Do not hand-edit
`supply-chain.json`: `tools/Sync-SupplyChainManifest.ps1` generates it from `$VER` and `VERSION`.
CI rejects drift between the pins and manifest.

The candidate workflow updates only `$VER` and the generated manifest. It never changes `VERSION`,elease notes, tags, or GitHub Releases.

## Automated path

1. The weekly `dependency-candidates` workflow queries each supported upstream release API.
2. It validates that required Windows distribution assets still exist for components that Model Pilot
   bootstraps.
3. If a newer candidate exists, it updates a single `automation/dependency-candidates` pull request
   and labels it `dependencies` and `needs-runtime-test`.
4. Hosted CI validates parsing, documentation, installer compilation, manifest consistency, and
   upstream asset metadata.

A failed asset check leaves the current pin untouched and fails the workflow with the affected
component named.

## Human compatibility gate

Before merging a candidate PR, use a disposable/test install on trusted Windows hardware and prove:

1. `start.ps1 -Action check-config` succeeds.
2. The stack starts.
3. `start.ps1 -Action test-model -Id <known-good-model>` receives a real completion after a cold
   load.
4. Open WebUI receives a real reply.
5. Upgrade/rollback behavior is checked for changed components.

Do not run this gate from a fork-triggered workflow or a general-purpose self-hosted runner carrying
personal chats, credentials, or normal user model data.

## Publishing a product release

After a candidate is accepted and merged:

1. Open a release-preparation change that updates `VERSION` and release notes; regenerate the
   manifest.
2. Merge that change after normal CI.
3. A maintainer creates `vX.Y.Z`.
4. The tag workflow builds the installer, checksum, and manifest, then publishes the GitHub Release.

A merge to `master` is never a public release by itself.
