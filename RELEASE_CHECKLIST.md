# Model Pilot release checklist

Use this gate for every public release. A green build is not proof that the Windows end-user flow works; record the tag, installer hash, test machine/profile and outcomes for manual checks. A local QA candidate is not a public release.

## Local candidate verified on this machine

- [x] Build `0.1.12-localqa` with Inno Setup 6.7.3. The compiler installer came from the official release, had a valid Pyrsys B.V. Authenticode signature and matched its recorded SHA-256; temporary compiler and QA artifacts are removed.
- [x] Build `0.1.13-localqa` with Inno Setup 6.7.3: `Model-Pilot-Setup.exe`, 2,213,262 bytes, SHA-256 `64504bd8e24692193b9e19ec96644e2dd7ce3c4151a633e05a5a534b768e18f5`. `SHA256SUMS.txt` matches. The candidate is unsigned and unpublished.
- [x] Upgrade the retained per-user installation to Model Pilot. `ModelPilot.cmd` replaced the legacy launcher; `config.yaml` and `.ui-settings.json` hashes were unchanged; Apps lists `Model Pilot version 0.1.13-localqa`.
- [x] Install the candidate into an isolated directory; confirm the payload excludes `LocalLLM.cmd` and the uninstaller removes only the installer-owned files.
- [x] Start the upgraded stack and request a real response from `qwen2-5-0-5b-instruct-q4_k_m`; both service health endpoints returned 200 and the model returned text in 3.5 seconds.
- [x] Wipe and reprovision this account's `%LOCALAPPDATA%\LocalLLM` runtime while retaining the `C:\LocalLLM` checkout and model weights. Clean bootstrap reached both services in 10m38s; the panel registered an existing GGUF in place and a real completion returned text in 2.5 seconds.
- [x] Upgrade the retained per-user installation; product version changed to `0.1.12-localqa`, and installed `ui.ps1` and `tray.ps1` matched repository source.
- [x] Verify the installer upgrade left `llamaswap/config.yaml` and `.ui-settings.json` hashes unchanged. The installer owns no runtime database or model-weight files.
- [x] The updated install retained HTTP 200 from panel, router and chat health endpoints. A full-stack Home Restart completed and both services recovered.
- [x] Run the installed `0.1.12-localqa` panel syntax check and request a real Qwen completion; it returned text in 2.4 seconds, not an accuracy/quality result.
- [x] Re-launch the final LocalLLM-branded candidate from `LocalLLM.cmd`: one UI server and one titled app window remained (1→1).
- [x] Interrupt a controlled model download at 262,144/1,048,576 bytes; confirm no final GGUF appeared and the panel classified it only as a partial download. Resume used an HTTP Range request, matched the expected hash and removed staging files.
- [x] Scan/register selected-folder GGUFs in place; verify native folder selection and explicit missing/ACL-denied scan errors.
- [x] Review reset preview without confirming a destructive reset; exercise reset/uninstall retention logic against isolated dummy data. No production GGUFs were deleted.
- [x] Keyboard smoke: native focus is visible; dialog focus stays contained, Enter activates the focused Cancel button, and close returns focus to the caller.
- [x] axe-core 4.13 reported zero violations across Home, Models, Activity, Settings, Engine, Tools and Monitoring. Some views still have one incomplete automated check; this is not a complete accessibility audit.
- [x] Check all seven sections at a 520×360 CSS viewport and the ready-state Home hero at 1040×720; neither produced page-level horizontal overflow.
- [x] Review `README.md`, `SECURITY.md` and `THIRD-PARTY.md` for network, privacy, licensing, support and trust disclosures.
- [x] Check GitHub release downloads against API-published SHA-256 where available: a live llama-swap v244 zip matched its digest, controlled valid/mismatched fixtures passed, and missing digests warn without blocking.
- [x] Pin GitHub Actions to upstream commit SHAs, align the CI compiler version to Inno Setup 6.7.3, and restrict release write permission to the release job. Both workflow files parse locally; CI execution remains unverified.
- [x] Run `bench/test_consent.py` on this machine; it passed and restored the prior consent-file state without executing generated model code.
- [x] Reproduce and fix the Home Restart spinner: job `restart-115622` completed, the Home control returned enabled without its busy state, and both services answered health checks.
- [x] Tray alert regression smoke: a transient probe was suppressed, a controlled sustained outage produced one service-specific alert, and an active lifecycle job suppressed alerts. The harness used a fake NotifyIcon; native balloon rendering was not forced.

## Known same-machine limits

- [ ] Activate tray-menu Stop and Restart directly. UI Automation surfaced similarly named browser dashboard controls instead of the native notification-area context menu; no direct tray action was validated. The router, chat and panel endpoints remained healthy afterward.
- [ ] Run native Windows Narrator and Forced Colors checks. Browser automation rejected forced-colors emulation; stylesheet coverage is not a substitute for a Windows accessibility check.
- [ ] Test a disposable Windows user profile, another machine, additional GPUs/Windows builds, ComfyUI with real data, and obtain non-maintainer feedback. A same-profile runtime wipe passed but does not substitute for a new account or machine.

## Automated release build

- [x] Push `release/v0.1.13` and download its `model-pilot-0.1.13` workflow artifact. Run [#39040488629](https://github.com/hgaaditya/modelpilot/actions/runs/39040488629) passed; its 2,213,370-byte installer matched `SHA256SUMS.txt` (`19260e31568d7a7b8c247f09aa1c16ede7d90ca97b65ca977f3c77e3089178f7`).
- [x] Open pull request [#1](https://github.com/hgaaditya/modelpilot/pull/1) and pass all six hosted `check` jobs: docs, benchmark consent, platform boundary, Windows/macOS PowerShell parse and lint, and Windows installer compilation.
- [ ] Obtain explicit release approval and push the matching `v<semver>` tag. Branch builds upload artifacts only; a tag creates the GitHub Release.
- [ ] Confirm the tagged workflow passes script parsing, panel JavaScript syntax validation and installer compilation.
- [ ] Inspect release page, product version, notes and attachments. Never describe an unsigned installer as publisher-signed.

## Before broad public distribution

- [ ] Resolve Authenticode signing or explicitly accept the unknown-publisher/SmartScreen experience. No eligible code-signing certificate with a private key was found in the current-user or local-machine certificate stores.
- [ ] Extend independent hash/signature verification to source archives, Node.js, package registries, model providers and other upstream downloads. GitHub's release API digest is useful corruption detection, not an independent publisher identity.
- [x] Test the dedicated `modelpilot.app@gmail.com` contact from an external account for general support and private vulnerability reports; delivery and reply succeeded.
- [ ] Configure GitHub private vulnerability reporting if it becomes available. The repository is currently private, issues are collaborator-only, and the GitHub endpoint previously returned 404.
- [ ] Review installed/upstream package licence notices and each selected model's usage terms. `THIRD-PARTY.md` is an inventory, not a complete licence audit.
- [ ] Publish only Windows/hardware support claims supported by testing; a single maintainer PC is not compatibility coverage.

## Current local artifact and evidence

The current candidate is `0.1.13-localqa`, `installer/output/Model-Pilot-Setup.exe`, 2,213,262 bytes, SHA-256 `64504bd8e24692193b9e19ec96644e2dd7ce3c4151a633e05a5a534b768e18f5`; `installer/output/SHA256SUMS.txt` matches. It is unsigned and unpublished. The earlier `LocalLLM-Setup.exe` remains only as pre-rename evidence. No second Windows machine or disposable user profile was available. See [STATUS.md](STATUS.md) for the detailed test record, privacy boundaries and open release risks.
