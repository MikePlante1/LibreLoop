# LibreLoop

FreeStyle Libre 3 CGMManager plugin for [Loop](https://github.com/LoopKit/Loop), built on the reverse-engineered Libre 3 protocol via [LibreCRKit](https://github.com/airedev326/LibreCRKit).

## Status

Early scaffold. Plugin registers with Loop and surfaces "FreeStyle Libre 3" in the CGM picker. Pairing, BLE session management, and glucose ingestion are not yet implemented.

## Structure

- `LibreLoop/` — Core framework. CGMManager, state persistence, BLE session coordinator.
- `LibreLoopUI/` — UI framework. SwiftUI onboarding and status screen.
- `LibreLoopPlugin/` — Plugin bundle (`.loopplugin`) loaded dynamically by Loop.
- `LibreLoopTests/` — Unit tests.
- `Scripts/generate_project.rb` — Regenerates `LibreLoop.xcodeproj` from scratch.

## License

MIT
