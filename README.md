# LiDAR Scanner for iOS

An iPhone app that makes 3D scans with the LiDAR sensor and the camera. It has two modes:

| Mode | Framework | Output |
| --- | --- | --- |
| **Room Scan** | [RoomPlan](https://developer.apple.com/documentation/roomplan) | A parametric 3D model of a room: walls, doors, windows and furniture. |
| **Object Scan** | [Object Capture](https://developer.apple.com/documentation/realitykit/objectcapturesession) + on-device `PhotogrammetrySession` | A textured, photoreal 3D model of an object you walk around. |

Scans are saved as USDZ files under **My Scans**, where you can view them in 3D / AR (Quick Look), share them, print them, or delete them. They also appear in the Files app under *On My iPhone > LiDAR Scanner > Scans*.

To save an STL, open the share menu next to a room or object scan, choose **Export as STL**, and pick a location in Files. The conversion runs on the phone and keeps the original USDZ. The STL uses millimeter coordinates and contains geometry only, without textures or printability repairs; a captured mesh may need cleanup before printing.

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
- **Photo Print:** point the phone at an object, tap where it sits on the surface, then tap its top. The app measures the height with LiDAR; tap **Take Photo & Print** to send one photo plus that height to the print server, which builds the model from the photo and scales it to the measured height.
- **Face Scan:** needs Face ID (the front TrueDepth camera). Hold the phone at arm's length, look straight at the screen, set the bust height (default 100 mm) and tap **Capture Face & Print**. The app sends the front-camera photo, its TrueDepth depth map, the camera and face poses and the ARKit face mesh with `mode=face`; the print server fills in the back of the head and returns a bust STL. Save the bust to keep it under **Face Prints** in My Scans, or share the STL.
- **Object Scan:** put the object on a plain surface with room to walk around it. Tap **Continue**, fit the box around the object, tap **Start Capture** and circle it slowly. When the pass completes, do **Another Pass** (e.g. with the object flipped) or **Finish**. The model is then built on the phone, which takes a few minutes.

## Printing a scan

Tap the printer icon on a scan in **My Scans**. When the print server returns an STL, tap **Save to Scan** to keep it with the original scan or **Share STL** to send it to a slicer app (or *Save to Files*). Tap the scan to find and share its saved STL later. Saving another print for that scan replaces the previous STL. For **Photo Print**, **Save to My Scans** adds a separate entry under **Photo Prints**.

Set the server and token in **Settings** (gear icon on the home screen). The default server is `https://slesvci--3d-print-web.us-east.modal.run`, set by `PRINT_BASE_URL` in `project.yml`; the token (`PRINT_API_TOKEN`) is kept in the Keychain. The app calls:

```
POST {server}/print   multipart/form-data, Authorization: Bearer <token>
  mesh=<scan .usdz, metres>          (or photo=<jpeg> + height_mm=<number>)
→ 200 model/stl  (X-Print-Report header); errors are JSON {"detail"}
```

A cold start of the live server takes about 2 minutes, so the first print can be slow.

For offline development, run the stub, which answers every valid request with a 20 mm cube:

```sh
python3 scripts/print_stub.py --token stub-token   # listens on port 8765
```

Then set Settings to `http://localhost:8765` (simulator) or your Mac's address, e.g. `http://192.168.1.20:8765` (iPhone, allow local network access when asked), with token `stub-token`.

## Development

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); after changing `project.yml`, run `xcodegen generate` and commit the updated project.

Run the unit and UI tests on a simulator:

```sh
xcodebuild test -project LidarScanner.xcodeproj -scheme LidarScanner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Start `python3 scripts/print_stub.py --token stub-token` first: the Print UI tests send to it. To also test against the live server, add `TEST_RUNNER_PRINT_LIVE_URL=<server> TEST_RUNNER_PRINT_LIVE_TOKEN=<token>` before `xcodebuild`. The simulator has no LiDAR, so the UI tests cover navigation, the unsupported-device screens, the scan library and printing. They use the launch arguments in `LidarScanner/App/LaunchArguments.swift` to reset and seed sample scans. Scanning itself has to be tried on a device.
