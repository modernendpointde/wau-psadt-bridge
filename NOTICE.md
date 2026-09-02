# Third-party notices

This repository includes third-party components.

## PSAppDeployToolkit

- Location: `template/PSAppDeployToolkit/`
- Project: https://github.com/PSAppDeployToolkit/PSAppDeployToolkit
- License: GNU Lesser General Public License v3.0 (`licenses/PSAppDeployToolkit-LGPL-3.0.txt`, also `template/PSAppDeployToolkit/COPYING.Lesser`)
- Version: 4.1.8

The following files outside that directory are unmodified copies of PSADT 4.1.8 assets:

- `template/Assets/AppIcon.png`
- `template/Assets/AppIconDark.png`
- `template/Assets/Banner.Classic.png`

`template/Config/config.psd1` is derived from the PSAppDeployToolkit 4.1.8 configuration file and is distributed under the same LGPL-3.0 terms.

`template/Assets/AppIcon.ico` is a project file used by the public-desktop shortcut.

## Winget-AutoUpdate

- Project: https://github.com/Romanitho/Winget-AutoUpdate
- License: MIT (`licenses/Winget-AutoUpdate-MIT.txt`)
- Copyright: Copyright (c) 2022 Romanitho
- Version tested: 2.12.0

`wau/Update-App.ps1` is derived from WAU 2.12.0 `Sources/Winget-AutoUpdate/functions/Update-App.ps1`. `wau/Submit-WauPsadtUpdate.ps1` is the bridge handoff copied into an existing WAU install.
