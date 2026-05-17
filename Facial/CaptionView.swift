import SwiftUI

// MARK: - CaptionView
/// 字幕视图
/// 带有glass背景的SwiftUI文本视图
/// 用于在人脸下巴下方显示语音识别字幕
struct CaptionView: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 36, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

#Preview {
    CaptionView(text: "你好世界")
}
