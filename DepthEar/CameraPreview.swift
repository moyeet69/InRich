import ARKit
import SceneKit
import SwiftUI

/// Live camera from the running ARSession, with a marker on the current
/// target. For sighted testers and helpers; hidden from VoiceOver because the
/// readouts carry the same information.
///
/// The view only displays the session; DepthPipeline still owns and runs it,
/// and stays its delegate. The marker reads the target from a lock at render
/// rate, so it does not wait for the 5 Hz readout.
struct CameraPreview: UIViewRepresentable {
    let session: ARSession
    let target: Locked<SIMD3<Float>?>

    func makeCoordinator() -> Coordinator {
        Coordinator(target: target)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = false
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false
        view.scene.rootNode.addChildNode(context.coordinator.marker)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session { view.session = session }
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let marker: SCNNode
        private let target: Locked<SIMD3<Float>?>

        init(target: Locked<SIMD3<Float>?>) {
            self.target = target
            let sphere = SCNSphere(radius: 0.06)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.systemYellow
            material.transparency = 0.85
            material.readsFromDepthBuffer = false
            sphere.materials = [material]
            marker = SCNNode(geometry: sphere)
            marker.renderingOrder = 10
            marker.isHidden = true
            super.init()
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let position = target.get() else {
                marker.isHidden = true
                return
            }
            marker.isHidden = false
            marker.simdPosition = position
            // Near = red, far = green, so a helper can see what the rate means.
            if let camera = renderer.pointOfView?.simdWorldPosition {
                let distance = simd_distance(camera, position)
                let t = CGFloat(max(0, min(1, (distance - DepthRange.nearMeters) / (DepthRange.farMeters - DepthRange.nearMeters))))
                marker.geometry?.firstMaterial?.diffuse.contents = UIColor(hue: t * 0.33, saturation: 0.9, brightness: 1, alpha: 1)
            }
        }
    }
}
