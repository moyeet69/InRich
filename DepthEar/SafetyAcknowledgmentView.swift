import SwiftUI

enum SafetyStatement {
    static let title = "Safety statement"

    static let paragraphs = [
        "DepthEar is an experimental research prototype. It is not a mobility aid.",
        "It does not replace a white cane, a guide dog, or orientation and mobility training. Do not use it instead of any of them.",
        "Do not rely on it to detect obstacles, drop-offs, stairs, curbs, traffic, or any other hazard. It senses only a narrow cone in front of the phone, only between 0.5 and 5 metres. It misses anything below or above that cone. It can misread glass, mirrors, dark or shiny surfaces and bright sunlight.",
        "It can fail at any moment without warning, including when the camera is covered, tracking is lost, the app is interrupted or the battery runs low. Silence does not mean the way is clear.",
        "It occupies your hearing, which you need to perceive traffic and your surroundings. Use open-ear or bone-conduction headphones, or AirPods in Transparency mode. Never use noise cancellation.",
        "Place names and directions come from Apple Maps, GPS and the compass. They can be wrong by tens of metres or by many degrees, especially indoors and near buildings, and the map may be out of date. Never use them to find a crossing, an entrance, a platform edge or the edge of a road.",
        "Use it only in a controlled, safe environment, together with your usual mobility aid, and preferably with a sighted person present.",
    ]

    static let acceptLabel = "I understand. This is not a mobility aid."
}

/// Shown on first launch; the app is unusable until it is accepted.
struct SafetyAcknowledgmentView: View {
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SafetyStatementText()
                Button(action: onAccept) {
                    Text(SafetyStatement.acceptLabel)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Confirms that you have read and accept this safety statement.")
            }
            .padding()
        }
    }
}

struct SafetyStatementText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SafetyStatement.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            ForEach(SafetyStatement.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
