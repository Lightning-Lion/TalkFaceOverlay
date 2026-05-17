import SwiftUI
import RealityKit
import ARKit

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    
    @State private var faceTracker = FaceTracker()
    @State private var speechRecognizer = SpeechRecognizer()
    
    /// 持有root实体，在RealityView内外都能操作
    private let root = Entity()
    /// 字幕实体
    private let captionEntity: Entity = {
        let entity = Entity()
        entity.name = "caption"
        entity.components.set(ViewAttachmentComponent(
            rootView: CaptionView(text: "等待说话中…")
        ))
        entity.components.set(BillboardComponent())
        entity.isEnabled = false
        return entity
    }()
    
    var body: some View {
        RealityView { content in
            content.add(root)
            root.addChild(captionEntity)
            
            // 启动人脸追踪和语音识别
            Task { @MainActor in
                do {
                    try await faceTracker.run()
                } catch {
                    showError(error.localizedDescription)
                }
            }
            Task { @MainActor in
                do {
                    try await speechRecognizer.start()
                } catch {
                    showError(error.localizedDescription)
                }
            }
        }
        .onChange(of: faceTracker.facePosition) { _, newPosition in
            if let newPosition {
                // 将字幕放在下巴下方0.15米处
                var captionPosition = newPosition
                captionPosition.y -= 0.15
                captionEntity.position = captionPosition
                captionEntity.isEnabled = true
            } else {
                captionEntity.isEnabled = false
            }
        }
        .onChange(of: speechRecognizer.recognizedText) { _, newText in
            let displayText = newText ?? "等待说话中…"
            captionEntity.components.set(ViewAttachmentComponent(
                rootView: CaptionView(text: displayText)
            ))
            // 确保有人脸位置时才显示
            if faceTracker.facePosition != nil {
                captionEntity.isEnabled = true
            }
        }
        .onChange(of: faceTracker.error) { _, error in
            if let error { showError(error) }
        }
        .onChange(of: speechRecognizer.error) { _, error in
            if let error { showError(error) }
        }
    }
    
    // MARK: - 显示错误
    private func showError(_ message: String) {
        let errorEntity = Entity()
        errorEntity.name = "error"
        errorEntity.components.set(ViewAttachmentComponent(
            rootView: CaptionView(text: "⚠️ \(message)")
        ))
        errorEntity.components.set(BillboardComponent())
        errorEntity.position = SIMD3<Float>(0, 1.5, -2)
        root.addChild(errorEntity)
        
        // 3秒后移除错误提示
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            errorEntity.removeFromParent()
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
