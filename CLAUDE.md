# Claude development instructions

Read and follow [AGENTS.md](AGENTS.md) before changing app source, build scripts, GitHub Actions, or release feeds.

Mandatory: retain a discoverable runtime **Installed version + build** display for every app target. Run `python3 scripts/check_version_ui.py` before any release work. Never bypass the version contract; if a screen moves, update `version-ui-contract.json` and its evidence instead. Preserve the existing direct-to-main release workflow and unrelated app behavior.


## Diagnostic/reporting rule for Claude

Before implementing or changing any diagnostics or logs, follow the **Universal diagnostic copy and export contract** in `AGENTS.md`: verified Copy with visible feedback, native Share, native plain-text Files export, and complete selectable report. Avoid claiming these work until a signed-device paste and export check is complete.


## Universal diagnostic export contract

All generated diagnostic/log reports require verified Copy (read back clipboard where supported and show visible success/failure), independent native Share, native Save as plain `.txt` with system Files picker (`fileExporter` or `UIDocumentPickerViewController` on iOS), and selectable full report text fallback. No silent clipboard-only buttons. Include app/build, device/OS, actionable return/error codes and redact secrets. Verify cross-app paste, Share and Save on a signed device; otherwise mark unverified. Preserve other instructions.
