# Model Pilot product status

**Updated:** 2026-10-17
**State:** Model Pilot QA candidate `0.1.13-localqa` is installed locally. It is unsigned and unpublished.

## Product decisions

- The supported installable product is a Windows 10/11 desktop application. Mobile is out of scope; existing macOS backend code does not make the Windows panel, tray or installer a supported macOS product.
- The panel and tray own everyday Start, Stop and Restart actions. Lifecycle CLI actions remain internal adapters, not the end-user workflow.
- Model recommendations remain powered by optional llmfit. Fit, download-size, speed and trained-context figures are estimates; a response check is not a model-quality evaluation.
- Existing GGUF files are registered in place. Import does not copy, move or delete source weights.
- The setup EXE installs the launcher/scripts per-user. Its uninstaller removes those files and shortcuts while preserving the downloaded stack and user data.
- Settings → Remove parts of the install is the explicit runtime/data reset. ComfyUI runtime, models, inputs, outputs and user settings are part of **Everything**. The model-weight checkbox deletes only weights inside the legacy LocalLLM installation directory; model folders selected elsewhere are preserved.
- No public release, tag or publication is authorized by this work.

## Implemented

- Refreshed the panel around Home, Models, Activity and Settings, with diagnostics and monitoring under More.
- Added first-run guidance, install progress, model recommendations/import, native folder selection and a real-completion response check.
- Folder scans hide registered GGUFs, flag model-ID conflicts, and report missing or unreadable folders as incomplete instead of implying that no files exist.
- The Home response-check copy says it proves text was returned, not that the answer is correct or useful.
- Full reset includes optional ComfyUI data. Its preview and confirmation state that external model folders are retained, even when install-local weights are opted into deletion.
- The Inno Setup uninstaller is scoped to installer-owned launcher files and shortcuts; runtime and user data remain available for a later reinstall.
- Activity cards now refresh from polled job state and disappear after a completed job. The ready-state Home hero and monitoring table are constrained to avoid page-level horizontal overflow.
- Added document language, accessible names/current navigation state, visible keyboard focus, contrast fixes, a named action-table column, and keyboard containment/return for dialogs.
- Privacy, network, dependency, signing and support-reporting boundaries are documented in `README.md`, `SECURITY.md` and `THIRD-PARTY.md`.
- GitHub release assets are checked against the SHA-256 digest exposed by the GitHub release API before the staged download is promoted; digest mismatches are discarded. Missing metadata warns and continues, so this is partial corruption detection, not publisher authentication.
- GitHub Actions are pinned to full commit SHAs. CI and release workflows use the same Inno Setup 6.7.3 pin; only the release job receives `contents: write`, while workflow defaults remain read-only.
- Tray status updates immediately, but a balloon now requires 15 seconds of continuous service failure and fires once per outage. Alerts are suppressed while a panel or tray lifecycle action is running.
- Home Restart/Stop buttons now follow the server job state. The Home buttons were manually marked busy on click but were omitted from polling's lifecycle-control sync, so a completed restart could leave the Home button spinning. Action responses now identify the exact job, and failed requests clear the optimistic mark and show an error.

## Verification on this Windows machine

- Built `0.1.12-localqa` with Inno Setup 6.7.3. The official GitHub installer SHA-256 was `9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732`; Authenticode was valid for Pyrsys B.V. The compiler binary SHA-256 was `0a8757031b33777e4c9cbffee40f11a5062b36d25cbe144c1db73b6102b80ad7`.
- Final pre-rename candidate artifact: `installer/output/LocalLLM-Setup.exe`, 2,211,237 bytes, SHA-256 `b3e10fc1abda282550b7f183e74a4bde64698223bb7b4e8dc9c596b49eace488`. `installer/output/SHA256SUMS.txt` matches. The product version is `0.1.12-localqa`; Authenticode status is `NotSigned`.
- Built Model Pilot `0.1.13-localqa` with Inno Setup 6.7.3: `installer/output/Model-Pilot-Setup.exe`, 2,213,262 bytes, SHA-256 `64504bd8e24692193b9e19ec96644e2dd7ce3c4151a633e05a5a534b768e18f5`. `installer/output/SHA256SUMS.txt` matches; Authenticode status is `NotSigned`.
- Installed the Model Pilot candidate over the retained per-user installation. `ModelPilot.cmd` replaced `LocalLLM.cmd`; the Apps entry reads `Model Pilot version 0.1.13-localqa`; `llamaswap/config.yaml` and `.ui-settings.json` hashes were unchanged.
- A clean isolated install contained the new launcher and every required payload file, omitted `LocalLLM.cmd`, and its uninstaller removed the installer-owned directory. The installed panel's `check-ui` action passed.
- The installed `ModelPilot.cmd` started the panel, and `ModelPilot.cmd -RestartPanel` stopped and relaunched it successfully. The upgraded stack reached both health endpoints after `-Action deploy`. A real completion from `qwen2-5-0-5b-instruct-q4_k_m` returned `I am ready to assist you.` in 3.5 seconds.
- Same-profile reset smoke: stopped the installed stack, deleted the 4.3 GB `%LOCALAPPDATA%\LocalLLM` runtime, then installed and provisioned the candidate from scratch in 10m38s. The `C:\LocalLLM` checkout (33.2 GB) and its model weights remained. The fresh config started empty; the panel registered `qwen2-5-0-5b-instruct-q4_k_m` in place from `C:\LocalLLM\llama.cpp\models` without copying it, showed it in Models, and its real response check returned text in 2.5 seconds.
- The pre-rename candidate was installed per-user over the retained install. The registered version was `0.1.12-localqa`; installed `ui.ps1` and `tray.ps1` matched repository source. The installer upgrade left `llamaswap/config.yaml` and `.ui-settings.json` hashes unchanged.
- The installer manifest does not include the runtime WebUI database or model weights. Earlier retained-install checks measured six external GGUFs at 33,179,413,024 bytes and confirmed the open database metadata was unchanged.
- After the update, panel, router and chat health endpoints returned HTTP 200. Installed `-Action check-ui` passed; a real Qwen response check returned “I am ready to assist you.” in 2.4 seconds. This proves text returned, not answer accuracy.
- Second launch on the previous candidate kept one UI server and one titled app window (counts 1→1). Tray singleton behavior was confirmed; tray status changed on panel-driven Stop/Start. Native tray-menu Stop/Restart remains unverified: UI Automation surfaced similarly named browser dashboard controls instead of the native notification-area context menu.
- On `0.1.12-localqa`, a real Home Restart completed as job `restart-115622`; the Home control returned enabled without its busy state, and both services recovered. The log records successful health waits for llama-swap and open-webui.
- A temporary regression harness exercised the production tray alert functions: one failed probe did not notify; a controlled 16-second outage notified once and named llama-swap; an active lifecycle job suppressed the alert. The harness used a fake NotifyIcon, so native Windows balloon rendering was not separately forced.
- Existing weights were scanned from a chosen folder and registered without copy/move. Missing-folder and ACL-denied scans reported incomplete/unavailable. Reset preview and destructive confirmation were inspected without deleting production data; reset/uninstall behavior was also exercised in an isolated dummy install.
- The installed WebUI database remained the clean pre-account database. Earlier candidate cycles verified the first welcome action reaches **Create Admin Account** and removed QA accounts/chats before restoring this state.
- Keyboard-only traversal showed focus outlines. Dialog Tab/Shift+Tab stayed inside the modal; Enter on Cancel resolved cancellation and returned focus to the invoking control.
- axe-core 4.13 reported zero violations across Home, Models, Activity, Settings, Engine, Tools and Monitoring at a 520×360 CSS viewport. Home, Models and Engine each reported one incomplete check; the harness did not expose a rule detail for those incomplete results.
- At 520×360 CSS pixels, all seven sections had no page-level horizontal overflow. The ready-state Home hero also had no overflow at 1040×720 after the layout fix.
- `start.ps1 -Action check-ui`, PowerShell parser checks for `ui.ps1`, `start.ps1`, `platform.ps1` and `tray.ps1`, and local Inno Setup compilation passed.
- A live download of the llama-swap v244 Windows zip matched GitHub's API-published digest; controlled downloader fixtures proved valid hashes pass and mismatches discard both `.part` and sidecar files.

- Both GitHub workflow YAML files parsed with installed PyYAML. GitHub Actions jobs were not run because these local changes were not pushed; the authenticated GitHub API confirms the origin repository is private.
- `bench/test_consent.py` passed using the installed Python environment. Its deliberate Python grading task was skipped; the test restored the prior consent-file state.

## Remaining release risks

- A same-profile runtime wipe and reinstall passed, but no second Windows user profile or machine was available. This does not establish compatibility across Windows versions, accounts, GPUs or hardware.
- The candidate is unsigned. No unexpired code-signing certificate with a private key and code-signing usage was found in the current-user or local-machine certificate stores; SmartScreen/unknown-publisher experience remains unresolved.
- GitHub release downloads verify the API-published SHA-256 when available, but source archives and Node, PyPI/npm, Hugging Face, ComfyUI and other downloads are not covered. The API digest shares GitHub's trust boundary and is not a publisher signature; independent verification remains incomplete.
- The authenticated GitHub API confirms the origin repository is private and issue tracking is enabled for collaborators. The dedicated contact `modelpilot.app@gmail.com` is published for general support and private vulnerability reports; delivery and reply were verified from an external account. GitHub's private vulnerability-reporting endpoint remains unverified.
- Native Windows Forced Colors and screen-reader testing were unavailable. The browser automation engine rejected `forced-colors` emulation; the stylesheet includes a forced-colors rule, but that is not a native validation. True OS display scaling and a complete accessibility review remain open.
- Tray singleton and status monitoring were tested, but direct tray-menu Stop/Restart actions remain unverified. UI Automation exposed similarly named dashboard controls, not the native tray context menu; the three service endpoints remained healthy afterward.
- ComfyUI was not installed in the real user environment during this pass; full-reset deletion was verified using an isolated dummy runtime and reset preview, not real ComfyUI model data.
- No non-maintainer feedback or broad hardware compatibility testing has been collected.

## Next gates before public release

1. Obtain a trusted Authenticode signing certificate/private key, or explicitly decide whether to distribute an unsigned installer with the unknown-publisher warning.
2. Extend upstream integrity verification beyond GitHub release assets with independently trusted hashes/signatures where available; the current check is partial and does not cover package registries or source/model downloads.
3. Configure or verify GitHub private vulnerability reporting if it becomes available.
4. Test the tray menu actions, a real ComfyUI install/reset if that feature ships, native Windows high contrast and Narrator, and another user profile/machine when available.
5. Obtain non-maintainer feedback and publish only support claims backed by observed Windows/hardware coverage.
6. Push a `release/<semver>` or `version/<semver>` branch and verify its workflow artifact before release approval; only then push the matching `v<semver>` tag to publish a GitHub Release and compare its artifact/checksum with the local candidate.
