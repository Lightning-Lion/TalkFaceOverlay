import SwiftUI
import AVFoundation
import Speech

// MARK: - SpeechRecognizer
/// 实时语音识别器
/// 使用苹果系统自带的SFSpeechRecognizer进行语音转文字
@MainActor
@Observable
class SpeechRecognizer {
    /// 语言选择，影响截断策略
    enum Language: String, CaseIterable, Identifiable {
        case chinese
        case english
        
        var id: Self { self }
        
        var label: String {
            switch self {
            case .chinese: return "中文"
            case .english: return "English"
            }
        }
    }
    
    /// 当前识别语言
    var language: Language = .chinese {
        didSet {
            RemoteLogger.shared.log(
                "SpeechRecognizer.language 已设为 \(language.label) (old: \(oldValue.label))",
                category: "LangFlow")
        }
    }
    
    /// 当前识别的完整文本
    var transcribedText = ""
    /// 显示用的文本（按标点切分后的最后一句话，或"等待说话中…"）
    var displayText = "等待说话中…" {
        didSet {
            isCurrentlySpeaking = (displayText != "等待说话中…")
        }
    }
    /// 是否正在说话
    var isCurrentlySpeaking = false
    /// 是否正在监听
    var isListening: Bool = false
    /// 错误信息
    var error: String? = nil
    
    private var audioEngine: AVAudioEngine? = nil
    private var speechRecognizer: SFSpeechRecognizer? = nil
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? = nil
    private var recognitionTask: SFSpeechRecognitionTask? = nil
    
    func start() async throws {
        // 请求语音识别权限
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechAuth == .authorized else {
            throw SpeechRecognizerError.speechPermissionDenied
        }
        
        // 请求麦克风权限
        let micAuth = await AVAudioApplication.requestRecordPermission()
        guard micAuth else {
            throw SpeechRecognizerError.microphonePermissionDenied
        }
        
        // 使用当前系统语言
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechRecognizerError.recognizerUnavailable
        }
        self.speechRecognizer = recognizer
        
        try startRecording()
        displayText = "等待说话中…"
    }
    
    func stop() {
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }
    
    private func startRecording() throws {
        // 清理旧任务
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        
        let inputNode = audioEngine.inputNode
        
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = recognitionRequest
        recognitionRequest.shouldReportPartialResults = true
        
        guard let recognizer = speechRecognizer else {
            throw SpeechRecognizerError.recognizerUnavailable
        }
        
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                
                if let result {
                    let transcribed = result.bestTranscription.formattedString
                    self.transcribedText = transcribed
                    self.processTranscription(transcribed)
                    
                    // 如果识别完成（用户停顿），重新开始新一轮识别
                    if result.isFinal {
                        self.restartRecording()
                    }
                }
                
                if let error {
                    RemoteLogger.shared.log("语音识别错误: \(error.localizedDescription)", category: "Speech")
                    // 不设置error，因为可能是正常的结束，尝试重启
                    self.restartRecording()
                }
            }
        }
        
        // 配置音频引擎
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // 确保格式有效
        guard recordingFormat.sampleRate > 0 else {
            throw SpeechRecognizerError.invalidAudioFormat
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }
    
    private func restartRecording() {
        // 重新启动录音和识别
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        
        do {
            try startRecording()
        } catch {
            RemoteLogger.shared.log("重启语音识别失败: \(error.localizedDescription)", category: "Speech")
            self.isListening = false
        }
    }
    
    /// 处理识别文本：按逗号句号分句，显示最后一句话
    private func processTranscription(_ text: String) {
        // 用逗号、句号分割
        let separators: [Character] = ["。", "，", ".", ",", "！", "?", "！", "？", "\n"]
        let sentences = text.split(whereSeparator: { separators.contains($0) })
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        guard let lastSentence = sentences.last?.trimmingCharacters(in: .whitespaces) else {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                displayText = "等待说话中…"
            } else {
                // 还在说但没分句，显示完整内容
                displayText = truncateText(text)
            }
            return
        }
        
        displayText = truncateText(lastSentence)
    }
    
    /// 按容量分页截断：容量满后清空重来，不滑动
    private func truncateText(_ text: String) -> String {
        RemoteLogger.shared.log(
            "语言: \(language == .chinese ? "中文" : "English") | 输入长度: \(text.count) | 输入预览: \(String(text.prefix(30)))",
            category: "truncateText")
        
        switch language {
        case .chinese:
            let maxChars = 20
            let charCount = text.count
            
            if charCount <= maxChars {
                RemoteLogger.shared.log("中文无需截断: \(charCount)字 ≤ \(maxChars)字", category: "truncateText")
                return text
            }
            
            // 分页：满一页后清空，从余数位置开始新页
            let remainder = charCount % maxChars
            let startIndex = remainder == 0 ? charCount - maxChars : charCount - remainder
            let result = String(text[text.index(text.startIndex, offsetBy: startIndex)...])
            RemoteLogger.shared.log("中文分页: 原文\(charCount)字 → 余数\(remainder) → 取末尾\(charCount - startIndex)字 → \(result)", category: "truncateText")
            return result
            
        case .english:
            let maxWords = 8
            let words = text.split(separator: " ").map(String.init)
            let wordCount = words.count
            
            if wordCount <= maxWords {
                RemoteLogger.shared.log("英文无需截断: \(wordCount)词 ≤ \(maxWords)词", category: "truncateText")
                return text
            }
            
            // 分页：满一页后清空，从余数位置开始新页
            let remainder = wordCount % maxWords
            let startIndex = remainder == 0 ? wordCount - maxWords : wordCount - remainder
            let result = words[startIndex...].joined(separator: " ")
            RemoteLogger.shared.log("英文分页: 原文\(wordCount)词 → 余数\(remainder) → 取末尾\(wordCount - startIndex)词 → \(result)", category: "truncateText")
            return result
        }
    }
    
    enum SpeechRecognizerError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case recognizerUnavailable
        case invalidAudioFormat
        
        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                "语音识别权限未授予"
            case .microphonePermissionDenied:
                "麦克风权限未授予"
            case .recognizerUnavailable:
                "语音识别器不可用"
            case .invalidAudioFormat:
                "音频格式无效"
            }
        }
    }
}
