# GarageKit

Swift client for **mvGarage**: Connect transport, `GarageEngine`, the
hold-to-open dial, and owner tools. The host supplies identity and a token
provider, and never logs in through the kit. Swift 6, iOS 26.

## Using it

- **`GarageConfig(baseURL:currentUserID:tokenProvider:holdToTrigger:motionDuration:appGroup:)`**
  is the injection seam.
- **`GarageEngine`** is `@MainActor @Observable`. The host calls `start()` when
  the garage screen is shown, `stop()` when it goes away, and `wipeLocalStore()`
  on sign-out (clears the local activity trail).
- **`GarageView(engine:appearance:)`** is the dial: hold to press, "Stop / press
  again" while the door moves, "Last used today at 3:30 PM", and a history sheet.
  It follows the host's light/dark scheme. `GarageAppearance` changes wording only.
- **`GarageOwnerView(engine:allowsAddingDevices:extra:)`** is the owner screen.
  Push it inside the host's navigation stack:
  - your doors: rename, online status, who has access (photo + name, end date),
    swipe to remove, **Share…** with a contact and an optional end date
  - the dial's motion time
  - **Add a device** (a new door; the token is shown once), unless
    `allowsAddingDevices` is false
  - any sections the host appends through `extra`

  Show its entry point only to owners (`engine.doors.contains(where: \.owned)`).
- `GarageTransport` is a protocol, so tests and previews can fake the server.
  `listContacts()` has a default that returns `[]`.

## Demo app

`Demo/GarageLab` (xcodegen: `cd Demo && xcodegen generate`) is a standalone
harness with a real mvServer login via MvAuth, against **Local** or
**Production**. It hosts the kit the way a production host does: `GarageView` in
a `NavigationStack`, with a toolbar gear that pushes `GarageOwnerView`.

## Development

- Tests: `xcodebuild test -scheme GarageKit -destination 'platform=iOS Simulator,name=…'` (27 tests).
- Generated code in `Sources/GarageKit/Generated` comes from mvGarage:
  `buf generate --template buf.gen.swift.yaml` (run in `../mvGarage`).
- Versions are tags (`0.2.0`); hosts pin "Up to Next Major".
