# Dependency update and release promotion

## Decision

Model Pilot automates discovery, review preparation, and an offline-test installer build. It does not
adopt runtime updates or publish a release automatically.

The updater may create or refresh one dependency-candidate pull request. It advances the next patch
version to a `-deps.<run>` prerelease and builds its installer artifact. A maintainer must run that
installer on trusted Windows/GPU hardware, then prepare the final version and create its tag.

This boundary is deliberate. Hosted GitHub runners can parse PowerShell, build the installer, and
validate upstream release metadata, but cannot prove model loading, GPU placement, VRAM headroom,
or real inference. In particular, a service health check is not evidence that llama-swap can proxy a
completion.

## Source of truth

`start.ps1` `$VER` is the sole source of pinned bootstrap component versions. Do not hand-edit
`supply-chain.json`: `tools/Sync-SupplyChainManifest.ps1` generates it from `$VER` and `VERSION`.
CI rejects drift between the pins and manifest.

The candidate workflow updates `$VER`, `VERSION`, and the generated manifest. Its version is the
next patch as a `-deps.<run>` prerelease. It never changes release notes, creates tags, or publishes
GitHub Releases.

## Automated path
1. The weekly `dependency-candidates` workflow queries each supported upstream release API.
2. It validates that required Windows distribution assets still exist for components that Model Pilot
   bootstraps.
3. If a newer candidate exists, it updates a single `automation/dependency-candidates` pull request
   with the next patch `-deps.<run>` version and labels it `dependencies` and `needs-runtime-test`.
4. The workflow explicitly dispatches the branch's `release artifacts` workflow because a
   `GITHUB_TOKEN`-authenticated push cannot trigger another workflow. It builds an installer,
   checksum, and manifest as a retained GitHub Actions artifact; it does not create a tag or
   GitHub Release.
5. Hosted CI validates parsing, documentation, installer compilation, manifest consistency, and
   upstream asset metadata.

A failed asset check leaves the current pin untouched and fails the workflow with the affected
component named.

## Current status

The automation is implemented and locally validated through script parsing, manifest consistency,
workflow YAML parsing, and a live upstream scan. The scan currently stops safely because
`llama.cpp v0.7.0` lacks the expected `llama-*-bin-win-cpu-x64.zip` asset. It creates no candidate
pull request and does not change current pins. Update the supported-asset matcher only after testing
the replacement Windows CPU and CUDA archives on real hardware.

## Human compatibility gate
Download the candidate artifact from its successful **release artifacts** workflow run and install it
on a disposable/test install on trusted Windows hardware. Prove:

1. `start.ps1 -Action check-config` succeeds.
2. The stack starts.
3. `start.ps1 -Action test-model -Id <known-good-model>` receives a real completion after a cold
   load.
4. Open WebUI receives a real reply.
5. Upgrade/rollback behavior is checked for changed components.

Do not run this gate from a fork-triggered workflow or a general-purpose self-hosted runner carrying
personal chats, credentials, or normal user model data.

## Publishing a product release
After offline acceptance:

1. Merge the dependency candidate pull request.
2. Open a release-preparation change that turns `X.Y.(Z+1)-deps.<run>` into `X.Y.(Z+1)`, updates
   release notes, and regenerates the manifest.
3. Merge that change after normal CI.
4. A maintainer creates the matching `vX.Y.Z` tag.
5. The tag workflow builds the installer, checksum, and manifest, then publishes the GitHub Release.
A merge to `master` is never a public release by itself.
