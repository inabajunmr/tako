# TakoLauncher

Small macOS launcher app.

## Run

```sh
swift run TakoLauncher
```

The app lives in the menu bar as `Tako`. Press `Option+N` to show or hide the launcher.

## Package as an app bundle

```sh
make package
open dist/TakoLauncher.app
```

## Controls

- `Option+N`: show or hide the launcher
- Type to filter applications case-insensitively
- `Command+A`: select all text in the search field
- `Up` / `Down`: move selection
- `Control+N` / `Control+P`: move selection while typing
- `Enter`: launch the selected app
- `Esc`: hide the launcher
- Double-click an app to launch it

Applications are scanned from `/Applications`, `/System/Applications`, and `~/Applications`.
Currently running regular apps are also included, even when they are outside those folders.
Windows for running apps are included as separate candidates when macOS exposes a window title.
Selecting a window focuses that window when Accessibility permission is granted.
On startup, TakoLauncher checks its own Screen Recording and Accessibility status, then only
requests the missing permissions.
If window titles do not appear, use `Tako` -> `Request Accessibility Permission`, then
`Tako` -> `Request Screen Recording Permission`.
Use `Tako` -> `Show Window Permission Status` to see what permissions macOS reports and how many
window titles are currently visible to the app.
macOS may require Accessibility permission for window focusing and Screen Recording permission for
other apps' window titles. Screen Recording changes often require restarting TakoLauncher.
If the status still says `not granted`, make sure the allowed item in System Settings is the same
app shown by `Bundle path` in the status dialog. Rebuilding a locally signed app can make macOS
treat it as a new app for privacy permissions.

Matching results are ranked by local launch history: launch count first, then most recent launch,
then application name. History is stored at:

```text
~/Library/Application Support/TakoLauncher/launch-history.json
```
