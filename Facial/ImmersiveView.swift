import SwiftUI
import RealityKit
import ARKit

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    
    @State private var faceTracker = FaceTracker()
    @State private var speechRecognizer = SpeechRecognizer()
    
    /// 持有root实体，在RealityView内外都能操作
    private let root = Entity()
    /// 瞬时跟踪实体
    private let instantTrackingEntity = Entity()
    /// 字幕实体（平滑跟踪）
    private let captionModAndEntity: (CaptionViewModel,Entity) = {
        let mod = CaptionViewModel(text: "等待说话中…")
        let entity = Entity()
        entity.name = "caption"
        entity.components.set(ViewAttachmentComponent(
            rootView: CaptionView(mod: mod)
        ))
        entity.components.set(BillboardComponent())
        entity.isEnabled = false
        return (mod, entity)
    }()
    private var captionMod: CaptionViewModel {
        captionModAndEntity.0
    }
    private var captionEntity: Entity {
        captionModAndEntity.1
    }
    
    var body: some View {
        RealityView { content in
            content.add(root)
            root.addChild(instantTrackingEntity)
            root.addChild(captionEntity)
            
            // 为跟随实体添加阻尼跟随组件
            captionEntity.components[DampingFollowComponent.self] = DampingFollowComponent(
                target: instantTrackingEntity
            )
            
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
            DampingFollowSystem.registerSystem()
        }
        .onChange(of: faceTracker.facePosition) { _, newPosition in
            if let newPosition {
                // 将字幕放在下巴下方0.15米处
                var captionPosition = newPosition
                captionPosition.y -= 0.15
                instantTrackingEntity.position = captionPosition
                captionEntity.isEnabled = true
            } else {
                captionEntity.isEnabled = false
            }
        }
        .onChange(of: speechRecognizer.recognizedText) { _, newText in
            let displayText = newText ?? "等待说话中…"
            // 更新文本
            captionMod.text = displayText
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
            rootView: CaptionView(mod: CaptionViewModel(text: "⚠️ \(message)"))
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
