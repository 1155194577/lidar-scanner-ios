# LiDAR Scanner for iOS

An iPhone app that makes 3D scans with the LiDAR sensor and the camera. It has two modes:

| Mode | Framework | Output |
| --- | --- | --- |
| **Room Scan** | [RoomPlan](https://developer.apple.com/documentation/roomplan) | A parametric 3D model of a room: walls, doors, windows and furniture. |
| **Object Scan** | [Object Capture](https://developer.apple.com/documentation/realitykit/objectcapturesession) + on-device `PhotogrammetrySession` | A textured, photoreal 3D model of an object you walk around. |

Scans are saved as USDZ files under **My Scans**, where you can view them in 3D / AR (Quick Look), share them, or delete them. They also appear in the Files app under *On My iPhone > LiDAR Scanner > Scans*.

**Requirements:** an iPhone or iPad Pro with LiDAR (iPhone 12 Pro or newer) on iOS 17 or later. Object Scan also needs an A14 chip or newer. The app opens on other devices and the simulator, but scanning shows an "unavailable" screen there.

## Install on your iPhone with a free Apple ID

You need a Mac with Xcode 16 or newer. No paid developer account is needed.

1. Clone this repo and open `LidarScanner.xcodeproj` in Xcode.
2. In **Xcode > Settings > Accounts**, click **+** and sign in with your Apple ID.
3. Select the **LidarScanner** project, then the **LidarScanner** target > **Signing & Capabilities**. Keep *Automatically manage signing* on and set **Team** to *Your Name (Personal Team)*.
4. Change **Bundle Identifier** to something unique to you, e.g. `com.yourname.lidarscanner` (free teams can't use an identifier someone else has registered).
5. Connect your iPhone with a cable, unlock it and tap **Trust**. Choose it as the run destination in the Xcode toolbar.
6. On the iPhone, turn on **Settings > Privacy & Security > Developer Mode** and restart when asked (iOS 16+; the option appears after the phone has been connected to Xcode).
7. Press **Run** (⌘R). The first time, the iPhone blocks the app: go to **Settings > General > VPN & Device Management**, tap your Apple ID under *Developer App*, and tap **Trust**. Run again.

Apps signed with a free Personal Team expire after 7 days; reconnect the phone and press Run again to refresh it. Your scans are kept.

## Using it

- **Room Scan:** tap *Room Scan*, walk slowly around the room pointing the phone at walls, floor and furniture, tap **Done**, then **Save Scan**.
- **Object Scan:** put the object on a plain surface with room to walk around it. Tap **Continue**, fit the box around the object, tap **Start Capture** and circle it slowly. When the pass completes, do **Another Pass** (e.g. with the object flipped) or **Finish**. The model is then built on the phone, which takes a few minutes.

## Development

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); after changing `project.yml`, run `xcodegen generate` and commit the updated project.

Run the unit and UI tests on a simulator:

```sh
xcodebuild test -project LidarScanner.xcodeproj -scheme LidarScanner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

The simulator has no LiDAR, so the UI tests cover navigation, the unsupported-device screens and the scan library. They use the launch arguments in `LidarScanner/App/LaunchArguments.swift` to reset and seed sample scans. Scanning itself has to be tried on a device.
