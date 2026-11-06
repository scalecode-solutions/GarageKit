# GarageKit

Swift client for **mvGarage**: Connect transport, `GarageEngine`, and the
hold-to-open trigger UI. The host supplies identity and a token provider, and
never logs in through the kit. Mirrors TraxKit's shape.

- `GarageConfig(baseURL:currentUserID:tokenProvider:holdToTrigger:)` is the injection seam.
- `GarageEngine` is `@MainActor @Observable`. The host calls `start()` on sign-in, `stop()` when going away, and `wipeLocalStore()` on sign-out (clears the local activity trail).
- `GarageView(engine:)` is the drop-in UI.
- `Demo/GarageLab` is a standalone harness app (real mvServer login via MvAuth).

Generated code in `Sources/GarageKit/Generated` comes from mvGarage:
`buf generate --template buf.gen.swift.yaml` (run in ../mvGarage).
