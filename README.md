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

Matching results are ranked by local launch history: launch count first, then most recent launch,
then application name. History is stored at:

```text
~/Library/Application Support/TakoLauncher/launch-history.json
```
