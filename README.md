# Tendon

Small macOS app for opening apps and windows quickly.

## Run

```sh
swift run Tendon
```

The app lives in the menu bar as `Tendon`. Press `Option+N` to show or hide it.

## Package as an app bundle

```sh
make package
open dist/Tendon.app
```

## Controls

- `Option+N`: show or hide Tendon
- Type to filter applications case-insensitively
- `Command+A`: select all text in the search field
- `Up` / `Down`: move selection
- `Control+N` / `Control+P`: move selection while typing
- `Enter`: launch the selected app
- `Esc`: hide Tendon
- Double-click an item to open it

Applications are scanned from `/Applications`, `/System/Applications`, and `~/Applications`.
Currently running regular apps are also included, even when they are outside those folders.
Windows for running apps are included as separate candidates when macOS exposes a window title.
Selecting a window focuses that window when Accessibility permission is granted.
On startup, Tendon checks its own Screen Recording and Accessibility status, then only
requests the missing permissions.
macOS may require Accessibility permission for window focusing and Screen Recording permission for
other apps' window titles. Screen Recording changes often require restarting Tendon.
If window titles do not appear, check System Settings -> Privacy & Security and make sure the
allowed item is the same app bundle you are launching. Rebuilding a locally signed app can make
macOS treat it as a new app for privacy permissions.

Matching results are ranked by local launch history: launch count first, then most recent launch,
then application name. History is stored at:

```text
~/Library/Application Support/Tendon/launch-history.json
```
