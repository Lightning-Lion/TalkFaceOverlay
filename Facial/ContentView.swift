import SwiftUI
import RealityKit

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Facial")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("双目人脸追踪 + 实时语音字幕")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Picker("语言", selection: Bindable(appModel).speechLanguage) {
                ForEach(SpeechRecognizer.Language.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            
            ToggleImmersiveSpaceButton()
        }
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
