# DepthEar

> ## ⚠️ Before you test: protect your hearing of the real world
>
> This app occupies your ears. For a blind pedestrian, hearing is the main way of perceiving traffic and surroundings.
> **Test only with open-ear or bone-conduction headphones, or with AirPods in Transparency mode. Never test with Active Noise Cancellation on.**
> On AirPods Pro / Max: long-press the stem (or the noise-control button), or use Control Center, and choose **Transparency**.
> For the head-tracked path you need AirPods with an IMU (see below). Bone-conduction headsets have no IMU that iOS exposes, so they only work with the "follow the phone" fallback.
>
> DepthEar is an experimental prototype. It is **not a mobility aid** and does not replace a white cane, a guide dog, or orientation-and-mobility training. Test it in a controlled space, with your usual mobility aid, ideally with a sighted spotter.

One world-anchored, head-tracked, latency-compensated sound source at the nearest LiDAR return in the forward cone. Distance maps to pulse rate. On top of Milestone 1:
- **Soft tone.** The default cue is a gentle rounded tone. The sharp click is still available.
- **Volume control.** The cue is ducked under speech.
- **Camera view.** A marker sits on the detected surface, coloured red when it is near and green when it is far.
- **Place callouts.** Apple Maps names the place your head points at, and a **Where am I?** button speaks your address and the nearest places.

Multi-source sonification, classification, VLM description and routing are still protocols with no-op stubs (see [ARCHITECTURE.md](ARCHITECTURE.md)).

**Verification status.** The app **builds for iOS with Xcode 27.2 with no errors or warnings**. It has **not been run on an iPhone** by me. What was checked:
- The device build (`generic/platform=iOS`, iOS 17 deployment target).
- The orientation math, rate mapping, click timing and median filter were unit-tested on macOS.
- PHASE's local axes were read from the real framework on macOS.
- `project.pbxproj` and `Info.plist` pass `plutil -lint`, and every project object reference resolves.

Expect possible small fixes on first device build.

---

## 1. Xcode setup (free Apple ID)

1. Install Xcode 15 or later (Xcode 16/26 fine). Open **Xcode > Settings > Accounts**, press **+**, and add your Apple ID. A free "Personal Team" appears.
2. Open `DepthEar.xcodeproj`. No packages, no file wrangling: all 18 Swift files and `Info.plist` are already in the target.
3. Select the **DepthEar** target, then **Signing & Capabilities**:
   - Leave **Automatically manage signing** on.
   - **Team**: your Personal Team.
   - **Bundle Identifier**: `com.mohittimalsina.DepthEar` is preset. If Xcode says it is unavailable, change it to anything unique.
   - No capabilities need adding. ARKit, CoreMotion, PHASE and AVFoundation need no entitlements, so free provisioning works.
4. Connect the iPhone by cable, unlock it, and tap **Trust**. On iOS 16+ enable **Settings > Privacy & Security > Developer Mode** (the phone restarts).
5. Choose the iPhone as the run destination (not a Simulator: ARKit does not run there) and press **Run**.
6. First launch only: the iPhone refuses to open the app until you go to **Settings > General > VPN & Device Management > [your Apple ID] > Trust**.
7. Free provisioning expires after **7 days**. Press Run again to re-sign.

The Debug configuration is built with `-O`. The per-pixel depth loop must hold 30 Hz, and unoptimised Swift may not. Use the "Depth frame rate" readout to confirm.

## 2. Info.plist keys

They are already present in **`DepthEar/Info.plist`**. The target uses that file directly (`INFOPLIST_FILE = DepthEar/Info.plist`, `GENERATE_INFOPLIST_FILE = NO`). So the keys go in that file, **not** in the target's Info tab build settings.

| Key | Why |
|---|---|
| `NSCameraUsageDescription` | ARKit camera + LiDAR. Without it the app is killed when the session starts. |
| `NSLocationWhenInUseUsageDescription` | Core Location, for "Where am I?" and the place callouts. Without it the permission prompt never appears and location stays off. |
| `NSMotionUsageDescription` | `CMHeadphoneMotionManager`. **If it is missing, head-motion updates never arrive and nothing reports an error.** The app shows "No head-tracking data… check NSMotionUsageDescription" after 3 s of silence, because it cannot detect this case directly. |

To check in Xcode: select `Info.plist` in the navigator. The rows read "Privacy - Camera Usage Description", "Privacy - Location When In Use Usage Description" and "Privacy - Motion Usage Description". When asked, allow location **While Using the App** with **Precise Location on**.

## 3. Making AirPods the active output

Head tracking needs AirPods with motion sensors: **AirPods Pro (1st/2nd gen), AirPods (3rd gen and later), AirPods Max**. AirPods 1st/2nd gen have no head-tracking IMU.

1. Put the AirPods in your ears. Wait for the connection tone.
2. Open Control Center. Long-press the music tile, tap the AirPlay/route icon, and choose the AirPods. With VoiceOver: open Control Center, find "AirPlay" in the Now Playing controls, double-tap, and choose the AirPods.
3. In the same Control Center volume long-press menu, set **Spatial Audio** to **Off** (see §5.1).
4. Set noise control to **Transparency**.
5. In DepthEar, the readout **Audio output** must name your AirPods with ", Bluetooth". Otherwise a warning says which device is active instead.

If AirPods drop to the **hands-free** profile (any app using the microphone), binaural quality collapses. The app warns about this.

## 4. Using it

1. Hold the phone upright against your chest, camera facing forward, roughly level (a lanyard or chest mount is best). Landscape is also fine and gives a wider horizontal field (see §5.6).
2. **Start**. The app recenters automatically once both depth and head data are live.
3. Face straight ahead, level your head, and press the big **Recenter** button. With VoiceOver, a **two-finger double-tap anywhere** does the same (Magic Tap). Do this whenever the source seems to sit off to one side while you face it: yaw drifts.
4. Walk. Pulses come from the nearest surface in the cone. Faster means closer: about 1 Hz at 5 m, 15 Hz at 0.5 m. Silence means nothing medium/high-confidence within 0.5–5 m in the cone, **or a failure**. The warnings list says which.

Readouts (5 Hz, all VoiceOver-labelled, directions spoken as left/right/up/down, never colour or position alone):
- target distance, head-relative azimuth and elevation, click rate
- depth frame rate, depth source, samples in cone
- head-tracking status and sample rate, predicted head pose, prediction horizon
- prediction self-check, audio output
- facing direction (compass), the mapped place you are pointing at, the number of places nearby, and location accuracy

### 4.1 Camera view

While running, the top of the screen shows the camera:
- A coloured ball sits on the surface being sonified: red near, green far.
- A **+** marks the centre of the cone.
- A small panel shows distance, pulse rate, head compass bearing and the place being pointed at.

It is for sighted helpers and testers, and VoiceOver skips it because the readouts carry the same information. Turn it off in Tunables → *Show camera view* to save battery.

### 4.2 Places and "Where am I?"

- **Walking or standing.** The motion sensor (`CMMotionActivityManager`, falling back to GPS speed) detects which you are doing. It says "Walking." or "Stopped." when that changes, a few seconds late.
- **While walking: left and right.** It speaks the nearest mapped place on each side within 60 m, for example "Left: Blue Bottle, cafe, about 20 metres. Right: Chase Bank, about 15 metres." It speaks only when a side changes, at most every 6 s. "Left" and "right" are relative to your direction of travel: the GPS course, or the phone's direction while GPS is unsure.
- **When standing: head turns.** Turn your head and hold still for under a second. It speaks what is there and where it is relative to your body, for example "On your left: Blue Bottle, cafe, about 40 metres". Head-turn callouts are off while walking, so the two kinds of callout don't talk over each other.
- **Street.** It says "Now on Main St." when the street changes. The street is looked up at most every 15 s and only after you move 15 m. Near a corner it can name the cross street.
- **Every 5 minutes** (Tunables, 1–30 minutes or off), it speaks the full summary below. Short callouts wait behind it instead of cutting it off.
- **Where am I?** This button speaks:
  - the street you're on, a nearby address and how accurate the location fix is
  - whether you are walking or standing
  - what is on your left and right
  - the compass direction you face
  - what is ahead
  - the nearest mapped place, as a clock position (12 = ahead, 3 = right)
- **Ducking.** While speech plays, the cue drops to 30 % volume rather than stopping.

How the direction is worked out:
- ARKit runs with `worldAlignment = .gravityAndHeading`, so its world −z axis points to true north. The head's world orientation (`q_anchor ⊗ q_head`) then converts directly to a compass bearing.
- Places come from `MKLocalPointsOfInterestRequest` within 300 m. The search reruns after you move 75 m or after 3 minutes.
- The place picked is the one closest to your line of sight, within ±15°. The window is wider for places nearer than about 75 m, and nearer places are favoured.

Expect these to be wrong often:
- GPS is good to about 5–20 m outdoors and much worse indoors. A warning appears above 30 m.
- The compass alignment is fixed when the AR session starts. It can be off by 10° or more near steel, cars or electronics. If directions seem rotated, **Stop and Start again** while standing away from metal.
- AirPods yaw drifts. **Recenter** often.
- Map data can be out of date, and the pin for a large building may sit at its centre rather than its door.

## 5. Where the spec could not be followed literally, and what I am unsure of

### 5.1 Suppressing system spatialization: there is no iOS API for it
I checked the iOS SDK headers. The only explicit bypass, `AVAudioSession.setIntendedSpatialExperience(.bypassed)`, is `API_AVAILABLE(visionos(1.0)) API_UNAVAILABLE(ios…)`. **No AVAudioSession property on iOS disables system spatialization.** What the app does (`AudioSessionConfig.swift`):

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
try session.setSupportsMultichannelContent(false)
try? session.setPreferredIOBufferDuration(0.005)
try session.setActive(true)
// and in SpatialRenderer:
engine.outputSpatializationMode = .alwaysUseBinaural
if #available(iOS 18.0, *) { listener.automaticHeadTrackingFlags = [] }
```

- `.playback` keeps AirPods on A2DP. Never use `.playAndRecord`: it forces the hands-free profile.
- `.mixWithOthers` stops the app becoming the Now Playing app. As far as I can tell, the per-app Spatial Audio mode (Off / Fixed / Head Tracked) in Control Center applies to Now Playing audio. **This is observed behaviour, not documented. I am not certain it prevents re-spatialization.**
- `setSupportsMultichannelContent(false)` says the app supplies no multichannel content. It is a hint and the default value.
- `outputSpatializationMode = .alwaysUseBinaural` makes PHASE produce the HRTF-rendered stereo itself.
- `automaticHeadTrackingFlags = []` (iOS 18+) stops PHASE from applying its own head rotation on top of ours. That would be a second, uncompensated head-tracking path.

**What you must do manually:** set Control Center > (long-press volume) > Spatial Audio to **Off** while DepthEar is in front. The app warns whenever the route reports `isSpatialAudioEnabled`. That flag only means "available and turned on in Settings", not "currently applied to this app", so treat the warning as a reminder.
**How to verify:** with the source straight ahead, turn your head 90°. With correct rendering, the clicks move to the side opposite your turn and stay there. With system re-spatialization, the image smears, collapses toward the head, or follows your head.

### 5.2 PHASE listener orientation does not take a quaternion
`PHASEObject` exposes only `transform: simd_float4x4` (orthonormal basis, uniform scale). There is no quaternion property. CoreMotion's `CMQuaternion` (double, x/y/z/w) is converted to `simd_quatd`, predicted, remapped to ARKit axes (`HeadTracker.headFrame`), composed with the heading anchor, and turned into a rotation matrix (`SpatialRenderer.update`).
PHASE's local axes are read at runtime from `PHASEObject.right/up/forward`. On macOS they are right = +X, up = +Y, forward = −Z, the same as ARKit, so the correction matrix is the identity. I assume iOS matches, and the code adapts if it doesn't.

### 5.3 CoreMotion headphone axes are undocumented
I assume the headphone body frame is x = right, y = forward, z = up (pitch about x, roll about y, yaw about z), so ARKit (x, y, z) = (x, z, −y). Yaw is the most likely to be right. The pitch/roll signs could be flipped.
**Test:** watch "Head pose (predicted)". Turn right: it should say "yaw … right". Nod down: it should say "pitch … down". If pitch reads backwards, turn on **Tunables > Flip headphone horizontal axes**. If yaw reads backwards, the axis guess is wrong in a way the toggle does not cover; tell me what you see.

### 5.4 Prediction is done on the quaternion, which is the same formula generalized
CoreMotion's `rotationRate` is body-frame angular velocity, **not** the derivatives of yaw/pitch/roll. So `psi_hat = psi + psi_dot·dt` is applied as `q_hat = q ⊗ exp(½·ω·dt)`. With your head level, this is exactly your per-axis formula on all three axes. With your head pitched it stays correct, where a per-axis Euler version would leak yaw into roll.

The prediction horizon is **dt + sample age** (age capped at 100 ms). AirPods deliver roughly 25 samples/s, so each sample is up to 40 ms old when the 100 Hz loop uses it. dt itself is the slider (0–300 ms, default 150).
**Self-check:** "Prediction check" compares the predictor against "hold last sample" on real data while you turn your head faster than 30°/s. Below 100% means prediction is helping. If it reads well above 100% while turning, CoreMotion's quaternion uses the opposite composition convention. The fix is one line in `HeadTracker.pose`: use `simd_quatd.rotation(...).inverse * sample.attitude` instead of `sample.attitude * simd_quatd.rotation(...)`, and the same in `ingest`.

### 5.5 Deadband: what I took it to mean
Head **yaw and pitch** within ±deadband (default 2°) of the recentered pose snap to exactly 0. This suppresses IMU jitter while you face forward. Outside the band the angle passes through unchanged (no offset), so there is a ≤2° step at the edge. Roll is not deadbanded.

### 5.6 A ±60° cone is wider than the camera can see
The LiDAR depth map covers the wide camera's field of view: about ±25° horizontally in portrait, about ±32° in landscape. The cone test runs at ±60° as specified, but nothing outside the field of view can ever pass it. Covering ±60° would need ARKit scene reconstruction (a mesh remembered from earlier views). That is a Milestone 2 option.
The cone is **gravity-referenced**: azimuth is measured in the horizontal plane from the phone's heading, and elevation from the horizon, so tilting the phone does not tilt the cone. If the phone points more than ~72° up or down, there is no heading and the app goes silent.

### 5.7 Wall vs doorway: expect to need a narrow cone
"Nearest return in a wide cone" tends to lock onto the door jamb or the side wall rather than tell you the opening is ahead. Try a cone half-width of 5–10° and sweep the phone, or your body, across the doorway. The tunable exists for this.

### 5.8 AirPods stem press: not possible without hijacking media controls
Stem presses reach an app only through `MPRemoteCommandCenter`. That requires becoming the Now Playing app, which takes over play/pause for everything, and it conflicts with §5.1. The iOS 17 AirPods mute gesture needs an active recording session, which forces the hands-free profile. Not implemented. Instead:
- a 200-pt full-width Recenter button
- **VoiceOver Magic Tap** (two-finger double-tap anywhere)

A possible later option is an App Intent bound to the Action Button or Back Tap. That needs the AppIntents framework, which is outside the allowed framework list.

### 5.9 Other uncertainties
- `isDeviceMotionAvailable` most likely reports whether the *iPhone* supports headphone motion, not whether capable AirPods are connected. Connection is shown from the delegate callbacks plus a 0.5 s "data arriving" check.
- `CMDeviceMotion.timestamp` may be the AirPods' capture time or the phone's receipt time; Apple doesn't say. That affects how much of the sensing latency the sample-age term covers. The perceptual tuning step (§6.3) absorbs the rest.
- PHASE does not document which thread may set object transforms. All PHASE calls run on one serial queue.
- On phones without LiDAR the app falls back to ARKit feature points. These are sparse and missing on blank walls, so it cannot reliably tell a plain wall from an opening.
- The ARKit heading alignment is not exposed with an accuracy value, so the app cannot warn when the compass is poorly calibrated.
- `AVSpeechSynthesizer` and VoiceOver can speak over each other. With VoiceOver on, the synthesizer uses your VoiceOver voice and rate.
- Listener position is the phone's position, about 40 cm below your ears. Targets therefore read slightly higher than they would from your head; this is not compensated.

## 6. Measuring your end-to-end audio latency

The two devices' clocks are not synchronized, so differencing two logs would be meaningless. Instead, one recording captures both a physical reference event and the AirPods output. The reference is the sound of your fingernail hitting the glass, which is the same instant the touch begins.

### 6.1 Setup
- A second device that records audio and lets you read times to 1 ms: a laptop with Audacity, or a phone with a waveform-editor app. Quiet room.
- **Turn off Automatic Ear Detection** (Settings > [your AirPods] > Automatic Ear Detection). Otherwise, taking the AirPods out routes audio to the iPhone speaker.
- Lay one AirPod with its speaker against the recording mic (≤ 2 cm). Lay the iPhone flat with its screen ≤ 10 cm from the same mic. 10 cm of air adds 0.3 ms.
- Control Center: output = AirPods, Spatial Audio Off.

### 6.2 Procedure
1. In DepthEar, stop sonification. Open **Latency test**. Audio starts and the screen shows a large "Click pad". It is a direct-touch area, so it works with VoiceOver on.
2. Start recording. Tap the pad sharply with a fingernail or pen tip, about once per second, 20 times.
3. In the editor, for each tap, measure from the onset of the tap transient to the onset of the AirPods click. Take the median: **Δ_bt**.
4. Baseline for touch-processing delay: disconnect the AirPods (output = iPhone speaker). Repeat steps 2–3 with the phone's speaker near the mic: **Δ_spk**. The screen's "System-reported output latency" for the built-in speaker is trustworthy (a few ms): **L_spk**.
5. Touch-to-app delay: τ = Δ_spk − L_spk.
6. **Bluetooth path latency: dt_audio = Δ_bt − τ.** Set **Tunables > Latency compensation** to this value.

The test click is a one-shot PHASE sound event through the same spatial mixer and Bluetooth link. It does not pass through the click-train buffer queue, which adds up to ~85 ms to distance changes but never to head rotation. So it measures what head rotation experiences, assuming a PHASE event start and a listener-transform change take effect on the same engine update.

### 6.3 Perceptual fine-tune (accounts for sensing latency)
§6.2 measures the output side only.
1. Stand 1.5 m from a wall edge or pillar with a cone half-width of ~10°, and recenter.
2. Close your eyes and turn your head side to side, ±30° at about 1–2 Hz.
   - If the click **drags along with your head** (lags), increase dt.
   - If it **swings ahead of your turn** (overshoot), decrease dt.

Step in 10 ms. Repeat per AirPods model and iPhone; codec and radio conditions shift it.

## 7. Tunables

All tunables are adjusted at runtime and persist across launches. This update resets saved values to the defaults once.

The **soft tone** is a low 330 Hz tone with one faint overtone. It has a 15 ms rounded attack, a 90 ms bell-like fade and a faint puff of noise at the start. It has about 1/35 of the click's high-frequency content, so it is gentle for long listening, but up/down and front/back cues are weaker. Use **sharp click** when you need the most precise direction.

Pulse rates by default (logarithmic): 6/s at 0.5 m, 3/s at 1 m, 1.7/s at 2 m and 1.1/s at 3 m. Beyond 3 m there is silence (*Silent beyond*). These defaults are deliberately calmer than the Milestone 1 spec of 15 Hz to 1 Hz linear; set them back in Tunables if you need that spec.

| Tunable | Range | Default |
|---|---|---|
| Sound | soft tone / sharp click | soft tone |
| Volume | 0.05–1 | 0.35 |
| Silent beyond | 1–5 m (5 = always sound) | 3 m |
| Head-turn callouts when standing | on/off | on |
| Left and right while walking | on/off | on |
| Announce street changes | on/off | on |
| Location summary interval | off, 1–30 min | 5 min |
| Show camera view | on/off | on |
| Latency compensation (dt) | 0–300 ms | 150 ms |
| Center deadband | 0–10° | 2° |
| Flip headphone horizontal axes | on/off | off |
| Rate at 0.5 m | 1–30 Hz | 6 Hz |
| Rate at 5 m | 0.2–10 Hz | 0.7 Hz |
| Rate curve | linear / logarithmic | logarithmic |
| Median filter window | 1–15 frames (at 30 Hz) | 5 |
| Cone half-width (azimuth) | 5–90° | 60° |
| Cone half-height (elevation) | 2–45° | 15° |

The logarithmic curve is a power law: log(rate) is linear in log(distance). With the defaults this is rate ∝ d^−1.18 (2.9 Hz at 2 m vs 10.3 Hz linear), so most of the change happens close in. The VoiceOver swipe up/down adjusts each slider by exactly one step.

## 8. Depth pipeline summary

- `ARWorldTrackingConfiguration`, `worldAlignment = .gravityAndHeading` (north-aligned, for place callouts), `frameSemantics = .smoothedSceneDepth` (LiDAR only).
- ARKit delivers 60 Hz on a background delegate queue. Every second frame is processed (30 Hz). Nothing per-pixel touches the main thread.
- Per depth pixel (256×192):
  1. Drop `.low` confidence.
  2. Unproject with intrinsics rescaled to the depth map.
  3. Test the gravity-referenced cone (±az, ±el).
  4. Test range 0.5–5.0 m, as Euclidean distance from the camera.
  5. Keep the nearest.

  This costs about 12 multiply-adds per pixel, with no trig or square roots.
- A component-wise median over the last N world positions rejects speckle. It holds through short dropouts and goes silent after N empty frames.
