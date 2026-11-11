# Dependency update and release promotion

## Decision

Model Pilot automates discovery, review preparation, and offline-test installer builds. A normal
branch merge never publishes a product release. After a maintainer completes the hardware gate, they
start the protected **publish Model Pilot release** workflow from `master`; its explicit approval
builds the installer, creates the matching version tag, and publishes the GitHub Release.

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

Before using the publish workflow, a repository administrator creates the `production-release`
GitHub Environment, restricts it to `master`, and configures the required reviewers. That environment
is the approval button: a workflow run waits there until a reviewer approves it.

After offline acceptance:

1. Merge the dependency candidate pull request, if the release includes one.
2. Open a release-preparation change that turns `X.Y.(Z+1)-deps.<run>` into `X.Y.(Z+1)`, updates
   release notes, and regenerates the manifest.
3. Merge that change to `master` after normal CI.
4. In **Actions**, run **publish Model Pilot release** on `master`.
5. Approve the waiting `production-release` environment deployment.

The workflow refuses a non-`master` ref, a prerelease `VERSION`, a mismatched manifest, missing
versioned release notes, or an existing tag. After approval it builds the installer and checksum,
uploads a retained workflow artifact, creates `vX.Y.Z` on the approved commit, and publishes the
GitHub Release with the installer, checksum, and supply-chain manifest.
