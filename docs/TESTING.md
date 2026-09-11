# Testing

This document describes the automated checks and manual integration tests used for WAU PSADT Bridge.

## Automated tests

### Prerequisites

- PowerShell 7
- A local checkout of the repository

The automated tests do not require an installed copy of Winget-AutoUpdate or PSAppDeployToolkit.

Run the complete test suite from the repository root:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

A successful run ends with:

```text
All tests passed (7).
```

The suite covers:

- Bridge installer and uninstaller contracts
- WAU handoff and catalog validation
- Campaign JSON and per-application UI validation
- Campaign health and ownership classification
- Deferral schedule calculation
- Campaign lifecycle and staging cleanup
- Shared mutex and update serialization behavior

The automated tests validate script contracts and isolated lifecycle behavior. They do not launch the PSAppDeployToolkit user interface, execute a real Winget upgrade, or create production scheduled tasks.

## Continuous integration

GitHub Actions runs the complete PowerShell test suite on a Windows runner for:

- Pushes to `main`
- Version tags
- Pull requests
- Manually triggered workflow runs

The workflow does not publish releases, modify repository contents, or require repository secrets.

## Manual integration testing

Manual integration testing must be performed on a disposable Windows test device or virtual-machine snapshot.

### Prerequisites

- Windows x64
- Winget-AutoUpdate 2.12.0 installed from the MSI package
- Administrator access
- At least one outdated application listed in `catalog/apps.json`
- A snapshot or equivalent rollback method

### Installation and campaign lifecycle

1. Install WAU PSADT Bridge.
2. Start the Winget-AutoUpdate scheduled task.
3. Confirm that an eligible catalog application is handed off to PSAppDeployToolkit.
4. Defer the update from the PSAppDeployToolkit welcome dialog.
5. Confirm that the campaign registry state, staging directory, retry task, and desktop shortcut exist.
6. Start the campaign from the desktop shortcut.
7. Complete the application update.

Expected result:

- The application reaches the campaign target version or a newer version.
- The campaign registry state is removed.
- The campaign retry and cleanup tasks are removed.
- The desktop shortcut is removed.
- The owned version staging directory is removed.
- Empty package and staging parent directories are removed.

### Recoverable orphaned campaign

1. Create and defer a campaign.
2. Remove only the retry task that belongs to that campaign.
3. Start the Winget-AutoUpdate scheduled task again.

Expected result:

- The WAU log reports a recoverable orphaned campaign.
- Only resources proven to belong to the campaign are removed.
- A new complete campaign can be created.

### Foreign resource protection

1. Create and defer a campaign.
2. Replace the campaign retry task action with a different harmless command.
3. Start the Winget-AutoUpdate scheduled task again.

Expected result:

- The WAU log reports that the campaign cannot be reconciled.
- The task, staging directory, registry state, state file, and desktop shortcut remain unchanged.
- Native WAU processing does not update the affected catalog application.

Restore the test device snapshot after completing this test.

### Invalid process definition

1. Add a wildcard process name such as `chrome*` to a catalog entry.
2. Start the Winget-AutoUpdate scheduled task.

Expected result:

- The catalog entry is rejected.
- No bridge campaign is created for the application.
- Native WAU processing does not update the affected catalog application.

Restore an exact process name before continuing.

### Per-application UI settings

1. Choose a catalog application for which Winget offers an upgrade.
2. Remove its complete `ui` object, close its configured processes, and start the Winget-AutoUpdate scheduled task.
3. Confirm that progress and completion prompts remain enabled by default when exactly one interactive user is active.
4. Restore an older application version or the test snapshot.
5. Set both `ui.progress` and `ui.success` to `false`, start one configured process, and run the task again.
6. Confirm that Welcome and deferral still operate, the staged campaign contains both Boolean values, and neither progress nor completion is shown when the campaign resumes.
7. Replace one Boolean with a string, then repeat with an unknown UI key.

Expected result:

- Missing UI settings preserve the existing enabled behavior.
- Explicit `false` values suppress only the corresponding progress or completion prompt.
- Welcome, deferral, deadline, restart, and process handling remain unchanged.
- Invalid types and unknown keys reject only the affected catalog entry.
- Native WAU processing does not update an application whose catalog entry is invalid.

Restore the shipped catalog before continuing.

### Uninstallation

1. Ensure that no campaign update is currently running.
2. Uninstall WAU PSADT Bridge.
3. Inspect the WAU installation and the bridge installation directory.

Expected result:

- The original supported WAU `Update-App.ps1` is restored.
- Bridge-managed files are removed.
- Non-empty campaign staging directories are preserved.
- Empty staging parent directories are removed.
- WAU scheduled tasks remain unchanged.
