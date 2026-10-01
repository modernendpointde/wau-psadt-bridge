# Changelog

All notable changes to this project are documented in this file.

## [0.3.0] - 2026-10-01

### Added

- Read-only diagnostics that inspect an installation without repairing, starting, or changing it:
  - `diagnostics/Test-WauPsadtBridgeCatalog.ps1` validates a catalog file with the runtime rules and reports the effective values per entry. It needs no installed bridge.
  - `diagnostics/Get-WauPsadtBridgeStatus.ps1` reports campaign identity, target version, state, deadline, prompt count, next attempt, and last result, and keeps stored values apart from live observations.
  - `diagnostics/Test-WauPsadtBridgeHealth.ps1` checks bridge installation, template entry points, catalog, WAU handoff and backup, WAU version, Winget availability, and campaign health, and reports every check as `Pass`, `Fail`, or `Unknown`.
- Structured report objects through `-PassThru` and `ConvertTo-Json` for all three entry points.

### Changed

- Moved the read-only WAU compatibility rules (supported version, stock-file hash, and the WAU helper functions) into `wau/WauPsadt.BridgeContract.ps1`, shared by the installer and the diagnostics. Installed behavior is unchanged.

### Fixed

- A scheduled task that cannot be read is now reported as unverified instead of absent, so a failed task query no longer turns a healthy campaign into a recoverable orphan whose resources are removed. Only a structured object-not-found result counts as an absent task.

## [0.2.1] - 2026-09-19

### Changed

- Split the PSADT template framework into focused components for foundation helpers, runtime context, campaigns, scheduling, and shortcuts. Commands, configuration, catalog and campaign schemas, resource paths, task names, exit codes, and runtime behavior are unchanged.
- Reduced the WAU handoff script to catalog routing and handoff orchestration. Campaign contract and health evaluation moved to `WauPsadt.CampaignContract.ps1`, which the installer copies into WAU `functions\` and removes on uninstall.
- Replaced template assertions that depended on file layout with behavioral tests for the component contracts.

## [0.2.0] - 2026-09-11

### Added

- Optional per-application `ui.progress` and `ui.success` settings in the bridge catalog.
- Automated coverage for omitted UI settings, explicit Boolean values, invalid types, and unknown UI keys.

### Changed

- Validated per-application UI settings are carried into the campaign payload.
- `ui.progress` controls both silent and post-Welcome progress dialogs.
- `ui.success` controls the completion prompt after a successful upgrade.
- Missing UI settings preserve the existing behavior by defaulting to enabled.
- Welcome, deferral, restart, and process handling remain unchanged by the new UI settings.
- Invalid UI settings fail closed for the affected package without native WAU fallback.

## [0.1.1] - 2026-09-07

### Added

- Campaign health evaluation for active registry, staging, scheduled-task, state-file, and desktop-shortcut resources.
- Automated contract tests for healthy campaigns, recoverable orphaned campaigns, and foreign resource collisions.
- A public testing guide for automated checks and manual Windows integration testing.
- A GitHub Actions workflow that runs the PowerShell test suite on Windows.

### Changed

- Active campaigns are now skipped only after their complete resource contract has been validated.
- Catalog and campaign process definitions now require exact `Get-Process` names and reject wildcard characters.
- Campaign reconciliation logs distinguish healthy campaigns, recoverable orphaned campaigns, and unproven resource collisions.
- Unused active-campaign lookup code has been removed.

### Fixed

- Fully owned but incomplete campaigns are removed safely so that a fresh campaign can be created.
- Missing retry tasks no longer leave an application permanently blocked by an orphaned campaign.
- Empty package-level staging directories are removed after campaign completion.
- Bridge uninstallation removes empty staging parent directories while preserving non-empty campaign directories.

## [0.1.0] - 2026-09-03

### Added

- Initial public preview of WAU PSADT Bridge.
- Catalog-based handoff from Winget-AutoUpdate to PSAppDeployToolkit.
- Process-aware close-application prompts and silent updates when catalog processes are not running.
- Usage-day deferrals with scheduled retries and a final deadline.
- Desktop shortcuts for resuming deferred campaigns.
- Machine-scope Winget upgrade execution with installed-version postcondition validation.
- Campaign staging, registry state, scheduled-task ownership, cleanup, installation, reinstallation, and uninstallation.
- English and German user-interface message packs.
- Initial catalog entries for 7-Zip, Google Chrome, Mozilla Firefox, and Mozilla Firefox (DE).

[0.3.0]: https://github.com/modernendpointde/wau-psadt-bridge/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/modernendpointde/wau-psadt-bridge/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/modernendpointde/wau-psadt-bridge/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/modernendpointde/wau-psadt-bridge/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/modernendpointde/wau-psadt-bridge/releases/tag/v0.1.0
