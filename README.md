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
- **Photo Print:** point the phone at an object, tap where it sits on the surface, then tap its top. The app measures the height with LiDAR; tap **Take Photo & Print** to send one photo, that frame's LiDAR depth map and camera intrinsics, and the height to the print server. The server builds the full shape from the photo and fits it to the LiDAR depth of the visible side for true size and pose. Before printing, the app asks the server to check the shot; if the phone points more than 30° down, the background is cluttered or the object is cut off, it shows why with **Retake** or **Print Anyway**. If the check fails or takes over 45 s, it prints straight away.
- **Face Scan:** needs Face ID (the front TrueDepth camera). Hold the phone at arm's length, look straight at the screen, set the bust height (default 100 mm) and tap **Capture Face & Print**. The app sends the front-camera photo, its TrueDepth depth map, the camera and face poses and the ARKit face mesh with `mode=face`; the print server fills in the back of the head and returns a bust STL. Save the bust to keep it under **Face Prints** in My Scans, or share the STL. With **Settings → Face Scan → Turn-your-head capture** on (off by default; needs a print server with multi-view face support), tap **Start Face Scan**, look straight ahead, then slowly turn your head left and right as prompted: the app captures up to five views (front, about 30° and 60° each way) from the same AR session and uploads the extras as `view_count` plus `view_<i>_*` fields, so the server only has to guess the back of the head. **Print Now** prints with the views captured so far.
- **Object Scan:** follow the five-step guide to choose a matte, textured object and set up even light and a contrasting surface. Tap **Start Scanning**, **Continue**, fit the box snugly, then **Start Capture**. Stay about 30–60 cm away and circle slowly for three passes: chest height, lower near object height, then a rigid object flipped onto its side or a high angle. Follow the live coaching; **How to scan** reopens the guide. Tap **Finish** after three passes for better coverage. The model builds on the phone in a few minutes; keep the app open and the phone plugged in. **Skip** bypasses the guide, not device requirements.

## Printing a scan

Tap the printer icon on a scan in **My Scans**, or **Take Photo & Print** in Photo Print.
Printing runs as an app-wide job: you can close the photo screen, return Home, or start a
Room/Object scan while it works. A compact banner follows you across screens. Tap
**STL ready — Share** when finished to send the file to a slicer or *Save to Files*.

Set the server and token in **Settings** (gear icon on the home screen). The default server is `https://slesvci--3d-print-web.us-east.modal.run`, set by `PRINT_BASE_URL` in `project.yml`; the token (`PRINT_API_TOKEN`) is kept in the Keychain. The app calls:

```
POST {server}/print   multipart/form-data, Authorization: Bearer <token>
  mesh=<scan .usdz, metres>          (or photo=<jpeg> + height_mm=<number>)
  every photo also sends camera_transform=[16 floats, column-major camera-to-world, +Y up,
    camera x/y = the uploaded photo's pixel axes] and image_orientation (1 when already upright)
  with LiDAR depth it also sends, from the same frame (photo left in sensor orientation):
    depth=<float32 LE metres, row-major, NaN = no reading>  depth_width, depth_height
    depth_confidence=<uint8 0/1/2>   image_orientation=<EXIF 1|3|6|8>
    intrinsics={"fx","fy","cx","cy","width","height"} (photo pixels)
    object_points=[[u,v] base, [u,v] top] (measured points projected into the photo, pixels)
→ 200 model/stl  (X-Print-Report header); errors are JSON {"detail"}

Signed uploads (servers that have POST /print/uploads; others get the multipart POST above):
1. POST {server}/print/uploads   JSON, Authorization: Bearer <token>
     {"job_id": "<client uuid>", "files": {"photo": {"content_type", "size"}, ...}}
     (only the files the print has: mesh, photo, depth, depth_confidence, face_vertices)
   → 200 {"job_id", "expires_in", "uploads": {"photo": {"url", "method": "PUT", "headers"}, ...}}
2. PUT each file to its url with exactly those headers (background URLSession, no Bearer token);
   a 403 (expired URL) asks step 1 again for that file
3. POST {server}/print   job_id, uploaded=photo,depth,...  + the usual form fields, no file parts
   → the same NDJSON stream; 409 {"detail", "missing": [...]} re-uploads those files and resends

POST {server}/photo-check   before a Photo Print: photo=<upright jpeg> + camera_transform
→ 200 {"ok", "issues": [{"code": steep_angle|cluttered_background|cut_off, "message"}], "camera_pitch_deg", ...}
```

A cold start of the live server can take about 4 minutes, so the first print can be slow; the app waits up to 10 minutes per request.

For offline development, run the stub, which answers every valid request with a 20 mm cube:

```sh
python3 scripts/print_stub.py --token stub-token   # listens on port 8765
```

The stub streams stages over `--delay` seconds (default 12), flushing a heartbeat at least
every 2 seconds, and still supports legacy STL clients. Use `--fail-stage repair` for a
mid-stream error, or set the app's server URL to `http://127.0.0.1:8765/fail` to exercise
failure/Retry UI against the same stub instance. The stub also hands out signed upload
URLs on itself: `/expire` makes each job's first URL per file already expired, `/drop` makes the
first submit report a file missing (409), `/legacy` answers 405 to `/print/uploads`, `/deny` refuses every PUT with 403; modes combine,
e.g. `http://127.0.0.1:8765/expire-drop`. No second stub is required by the UI tests.
It keeps jobs in memory, supports replay/result routes and idempotent submissions, and
continues processing after a client disconnects. Restarting it clears its jobs.

Then set Settings to `http://localhost:8765` (simulator) or your Mac's address, e.g. `http://192.168.1.20:8765` (iPhone, allow local network access when asked), with token `stub-token`.

## Development

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); after changing `project.yml`, run `xcodegen generate` and commit the updated project.

Run the unit and UI tests on a simulator:

```sh
xcodebuild test -project LidarScanner.xcodeproj -scheme LidarScanner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Start `python3 scripts/print_stub.py --token stub-token` first: the Print UI tests send to it. To also test against the live server, add `TEST_RUNNER_PRINT_LIVE_URL=<server> TEST_RUNNER_PRINT_LIVE_TOKEN=<token>` before `xcodebuild`. The simulator has no LiDAR, so the UI tests cover navigation, the unsupported-device screens, the scan library and printing. They use the launch arguments in `LidarScanner/App/LaunchArguments.swift` to reset and seed sample scans. Scanning itself has to be tried on a device.
