# Architecture

```
 ARKit (60 Hz, depth queue)                       CoreMotion (≈25 Hz, motion queue)
 DepthPipeline.process  ── every 2nd frame        HeadTracker.ingest
   cone + confidence + range filter                 latest sample, rate estimate,
   nearest sample → MedianFilter3D                  prediction self-check
   ──► DepthResult (world target, phone pose)       │
            │                                       │
            ▼                                       ▼
 SpatialController.tick  (100 Hz, control queue: every PHASE call happens here)
   q_world = q_anchor(phone heading at recenter) ⊗ predict(q_head, dt + age) ⊗ deadband
   rate    = RateMapping(distance)
            │
            ▼
 SpatialRenderer (PHASE): 1 PHASEListener, 1 PHASESource,
   push-stream pulse train (ClickTrainGenerator: soft tone or click), binaural, dry direct path
            │
            ▼
 Readout (5 Hz, incl. head compass bearing) ──► AppModel (main) ──► SwiftUI + VoiceOver announcements
                                                   │
 CoreLocation + MapKit POIs ──► PlaceGuide ◄───────┘  (which place the head points at)
                                   │
                                   ▼
                         SpeechAnnouncer (AVSpeechSynthesizer) ──► SpatialController.setDucked

 CameraPreview (ARSCNView) displays DepthPipeline's ARSession and reads
 DepthPipeline.overlayTarget at render rate for the marker.
```

Threads: the ARSession delegate queue, a CoreMotion OperationQueue, one serial control queue (timer + all PHASE calls), and main (UI only). Shared state crosses them through `Locked<T>`.

## Extension points

The protocols are in `DepthEar/ExtensionPoints.swift`. Each one currently has a no-op stub, and `// EXTENSION POINT` comments mark where it plugs in.

| Later feature | Protocol | Attaches at | Notes |
|---|---|---|---|
| Multi-target extraction | `TargetExtractor` | `DepthPipeline.process(_:)`, replacing the `nearestLiDARSample` / `nearestFeaturePoint` reduction | Synchronous, 30 Hz, on the depth queue. Must not retain `ARFrame`. Output `[SpatialTarget]` replaces `DepthResult.target`. |
| Multi-source sonification | `Sonifier` | `SpatialController.tick()`, replacing the `renderer.update(...)` call | Takes the same latency-compensated `ListenerPose`, so head tracking is shared by every source. One `PHASESource` per target, with a distinct timbre per class. |
| Object classification | `SemanticLabeler` | After `TargetExtractor`, off the 30 Hz path | Async. Writes `SpatialTarget.label`. Candidates: ARKit mesh classification, Vision, Core ML. |
| VLM scene description | `SceneDescriber` | On demand, from a UI action; never per frame | Async. Its result goes to `SpeechOutput`. |
| Speech output | `SpeechOutput` | Fed by `SceneDescriber` / `RouteGuide` / `PlaceGuide` | **Implemented** by `SpeechAnnouncer`. It ducks the cue to 30 % while speaking. |
| Route navigation | `RouteGuide` | `SpatialController.tick()`, as an extra `SpatialTarget` for the `Sonifier` | A waypoint is a separate, clearly distinct source, never mixed with obstacle cues. |

Kept as-is for later milestones:
- the world-anchoring and prediction path (`HeadTracker`, the `q_anchor ⊗ q_head` composition)
- the audio session rules (`AudioSessionConfig`)
- the safety acknowledgment
