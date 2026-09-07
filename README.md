# Oma Aux

Oma Aux is a PipeWire patchbay for the Omarchy bar. It exposes application
playback, microphones, sink monitors, recording applications, hardware outputs,
and filter nodes as a simple routing matrix.

Select a source in the left column, then select destinations in the right
column. Oma Aux connects matching channel names such as `FL` and `FR`, with
fallbacks for mono and unnamed ports. Selecting an active destination removes
all links between that node pair.

## Requirements

- Omarchy Shell
- PipeWire
- `pw-dump`
- `pw-link`
- Python 3.10 or newer

These are present on a standard Omarchy installation.

## Current Scope

- Live node, port, and link discovery
- Audio-only filtering
- Sink monitor routing
- Stereo-aware node connections
- Connect and disconnect from the bar panel

PipeWire links do not carry an independent gain control. Per-link faders will
therefore require managed mixer or filter nodes and are intentionally outside
the first release.

## Command-Line Helper

The bundled helper can also inspect or change the graph directly:

```bash
bin/oma-aux snapshot
bin/oma-aux watch
bin/oma-aux toggle OUTPUT_NODE INPUT_NODE
bin/oma-aux connect OUTPUT_NODE INPUT_NODE
bin/oma-aux disconnect OUTPUT_NODE INPUT_NODE
```
