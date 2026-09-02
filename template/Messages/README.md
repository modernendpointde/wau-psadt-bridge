# Culture packs

Add a language by copying `en-US.psd1` to `<culture>.psd1`, where `<culture>`
is a valid BCP-47 tag such as `fr-FR`, `pl-PL`, `ja-JP` or `ar-SA`.

Set `Metadata.Culture` to the filename culture, translate every value under
`Messages`, and keep the placeholders defined by `message-contract.json`.
Set `TextDirection` to `ltr` or `rtl`. Save packs as UTF-8 with BOM. Windows
PowerShell 5.1 otherwise reads them as the ANSI code page and umlauts break in
the UI. Packs are imported as data (`Import-PowerShellDataFile`); executable
expressions are rejected.

Resolution order is explicit culture, or the interactive user’s Windows display
language when `Culture` is `Auto` (not the SYSTEM process culture), then parent
culture, configured default culture, then the mandatory `en-US` pack. Every
pack in the directory is validated during preflight, even if it is not selected.

Right-to-left metadata is carried by the resource contract. Visual RTL behavior
must be validated on a Windows target.

The template ships `en-US` and `de-DE`.
