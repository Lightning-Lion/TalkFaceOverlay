import os
import SwiftUI
import AVFoundation
import Speech

// MARK: - SpeechRecognizer
/// 实时语音识别器
/// 使用苹果系统自带的SFSpeechRecognizer进行语音转文字
@MainActor
@Observable
class SpeechRecognizer {
    /// 当前识别到的文字，nil表示等待说话中
    var recognizedText: String? = nil
    
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
                    if transcribed.isEmpty {
                        self.recognizedText = nil
                    } else {
                        self.recognizedText = transcribed
                    }
                    
                    // 如果识别完成（用户停顿），重新开始新一轮识别
                    if result.isFinal {
                        self.restartRecording()
                    }
                }
                
                if let error {
                    os_log("语音识别错误: \(error.localizedDescription)")
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
            os_log("重启语音识别失败: \(error.localizedDescription)")
            self.isListening = false
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
