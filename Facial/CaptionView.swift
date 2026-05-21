import SwiftUI

// MARK: - CaptionView
/// 字幕视图
/// 带有glass背景的SwiftUI文本视图
/// 用于在人脸下巴下方显示语音识别字幕

@Observable
class CaptionViewModel {
    var text: String
    init(text: String) {
        self.text = text
    }
}

struct CaptionView: View {
    @State
    var mod:CaptionViewModel
    
    private var text:String {
        mod.text
    }
    
    var body: some View {
        ContinuousText(text: text)
            .font(.system(size: 36, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .glassBackgroundEffect(in: .capsule)
    }
}

// 普通的Text，字数增加的实际，容器尺寸是离散跳变的
// 如果有background、glass，就会看到背景是离散跳变变大的
// 我在字数增加的时候，容器尺寸是连续变化的
struct ContinuousText: View {
    let text:String
    
    @State
    private var textContainerWidth:CGFloat = 10
    
    @State
    private var textContainerHeight:CGFloat = 10
    
    var body: some View {
        // 连续变化尺寸
        Color.clear
            .frame(width: textContainerWidth, height: textContainerHeight, alignment: .center)
            .background {
                // 让文本视觉正常，不会在容器尺寸不足时出现省略号
                let animation:SwiftUI.Animation = .smooth
                Text(text)
                    .contentTransition(.numericText())
                    .fixedSize()
                    .readSize { size in
                        print(size)
                        // 动画化改变容器尺寸
                        withAnimation(animation) {
                            textContainerWidth = size.width
                            textContainerHeight = size.height
                        }
                    }
                    .animation(animation, value: text)
                    // 我在背景，也点不到，无障碍由上层的负责
                    .accessibilityHidden(true)
            }
            .overlay {
                // 响应触摸、无障碍
                Text(text)
                    .foregroundStyle(.clear)
                    .textSelection(.enabled)
            }
    }
}


// MARK: GeometryReader
extension View {
    public
    func readPosition(in coordinateSpace:CoordinateSpace = .global,onChange: @escaping (CGRect) -> Void) -> some View {
        background(
            GeometryReader { geometryProxy in
                Color.clear
                    .preference(key: PositionPreferenceKey.self, value: geometryProxy.frame(in: coordinateSpace))
            }
        )
        .onPreferenceChange(PositionPreferenceKey.self, perform: onChange)
    }
}

extension View {
    public
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { geometryProxy in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: geometryProxy.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self, perform: onChange)
    }
}
private struct SizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
}
private struct PositionPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {}
}
