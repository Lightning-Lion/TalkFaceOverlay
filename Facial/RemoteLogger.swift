import Foundation
import Network
import os

/// 远程日志器
/// 通过 UDP 将日志发送到 PC 上的 log_server.py 终端打印
/// 同时保留 os_log 写入系统控制台
final class RemoteLogger {
    static let shared = RemoteLogger()
    
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.facial.remoteLogger", qos: .utility)
    
    private var isReady = false
    private var sessionStarted = false
    private var pendingLogs: [String] = []
    
    private init() {
        self.host = NWEndpoint.Host("192.168.3.174")
        self.port = NWEndpoint.Port(integerLiteral: 9527)
        self.connection = NWConnection(host: host, port: port, using: .udp)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isReady = true
                // 发送会话启动信号（仅在首次连接就绪时发一次）
                if self?.sessionStarted == false {
                    self?.sessionStarted = true
                    self?.sendNow("[SESSION_START]")
                }
                // 发送缓存的日志
                let pending = self?.pendingLogs ?? []
                self?.pendingLogs.removeAll()
                for log in pending {
                    self?.sendNow(log)
                }
            case .failed(let error):
                os_log("[RemoteLogger] 连接失败: %@", error.localizedDescription)
                self?.isReady = false
            case .cancelled:
                self?.isReady = false
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    /// 发送一行日志（先在本地 os_log，再投递到远端）
    func log(_ message: String, category: String = "Facial") {
        // 本地 os_log
        os_log("[%@] %{public}@", type: .debug, category, message)
        
        let payload = "[\(category)] \(message)"
        
        queue.async { [weak self] in
            guard let self else { return }
            if isReady {
                sendNow(payload)
            } else {
                // 连接未就绪时缓存（最多缓存200条）
                if pendingLogs.count < 200 {
                    pendingLogs.append(payload)
                }
            }
        }
    }
    
    private func sendNow(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    
    deinit {
        connection.cancel()
    }
}
