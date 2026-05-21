import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
    
    /// 语言选择（中文 / English），影响语音字幕截断策略
    var speechLanguage: SpeechRecognizer.Language = .chinese {
        didSet {
            RemoteLogger.shared.log(
                "AppModel.speechLanguage 从 \(oldValue.label) 变更为 \(speechLanguage.label)",
                category: "LangFlow")
        }
    }
}
