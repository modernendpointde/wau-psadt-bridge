# WAU PSADT Bridge template

Golden copy installed to `C:\Program Files\WauPsadtBridge\Template\`.
The WAU bridge copies this tree into a short-lived working copy under
`C:\Program Files\WauPsadtBridge\Work\<guid>\`, writes
`WauBridge.Campaign.json`, and runs `install.ps1`. That campaign file is required.
Deferred campaigns are then copied to the persistent Stage path.

This template upgrades catalog apps with Winget through PSADT: close-apps,
deferral, deadline, progress, and completion UI. It does not install from
`Files/`, uninstall, or repair.

PSAppDeployToolkit remains unmodified third-party code.

Component wiring, load order, configuration, lifecycles, state, Windows
resources and troubleshooting: [TECHNICAL-REFERENCE.md](TECHNICAL-REFERENCE.md).

## Runtime overlay

`WauBridge.Campaign.json` supplies `PackageId`, `DisplayName`, target version and
process names. `App/WauBridge.Config.ps1` is policy only (retry, UX flags,
localization). `Config/config.psd1` holds PSADT dialog timeout and company name.
Task names, StageRoot, and registry paths are derived at runtime.

After load:

- Detection and upgrade use `PackageId` as the exact Winget ID.
- When a catalog process is running: Welcome, then `Retry.Days` usage days at
  `Retry.TimesPerDay` random times in `HoursStart`–`HoursEnd`. The first Welcome
  is today’s slot. The last random time is the deadline.
- After the deadline, if Welcome was already shown: `CloseCountdownSeconds`.
- `Localization.Culture` is `Auto`, fallback `en-US`.

Add catalog IDs in `catalog/apps.json`. Do not edit `Framework/` or vendored
PSADT files for an app.

## Framework map

- `WauBridge.ps1` is the loader.
- `WauBridge.Compatibility.ps1` owns staging, scheduled tasks, registry state,
  shortcuts and cleanup.
- `WauBridge.Core.ps1` defines paths, culture/timezone helpers and normalized
  action results.
- `WauBridge.Validation.ps1` owns aggregate preflight.
- `WauBridge.Localization.ps1` discovers and validates culture packs.
- `WauBridge.Deferral.ps1` calculates deadlines and reminder times from Config.
- `WauBridge.Detection.ps1` separates presence, version and target evidence.
- `WauBridge.Actions.ps1` owns lifecycle result/progress contracts.
- `WauBridge.Winget.ps1` runs `winget export` / `winget upgrade`.
- `WauBridge.CampaignJson.ps1` loads `WauBridge.Campaign.json`.

## Safety boundaries

- Staging never uses `/MIR` and checks Robocopy exit codes.
- Recursive cleanup requires a matching ownership marker and contained path.
- Foreign tasks and shortcuts are left in place; registration throws.
- Task action, principal, run level, settings, triggers and campaign ownership
  are validated before reuse.
- State is schema-versioned, atomically replaced and corrupt data is
  quarantined.
