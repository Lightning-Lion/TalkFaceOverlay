import os
import SwiftUI
import ARKit
import RealityKit
import Vision
import CoreImage
import CoreVideo

// MARK: - FaceTracker
/// 双目人脸追踪器
/// 从左右眼相机画面中检测人脸，通过双目射线求交确定人脸3D位置
@MainActor
@Observable
class FaceTracker {
    /// 检测到的人脸世界坐标（下巴位置），nil表示未检测到
    var facePosition: SIMD3<Float>? = nil
    
    /// 错误信息
    var error: String? = nil
    
    private var arkitSession: ARKitSession? = nil
    private let worldTracking = WorldTrackingProvider()
    private var cameraFrameProvider: CameraFrameProvider? = nil
    private var task: Task<Void, Never>? = nil
    private let ciContext = CIContext(options: nil)
    
    /// 内外参（一次会话内固定）
    private var intrinsics: simd_float3x3? = nil
    private var leftExtrinsics: simd_float4x4? = nil
    private var rightExtrinsics: simd_float4x4? = nil
    private var resolution: CGSize? = nil
    
    /// 检测丢失保护时间
    private var lastDetectionTime: Date? = nil
    private let detectionRetentionInterval: TimeInterval = 1.0
    
    /// 检测下采样目标尺寸（从1080P到720P）
    private let maxDimension: CGFloat = 1280
    
    public init() {}
    
    // MARK: - 启动
    func run() async throws {
        let arkitSession = ARKitSession()
        let authorizationStatus = await arkitSession.requestAuthorization(for: [.cameraAccess])
        
        guard authorizationStatus[.cameraAccess] == .allowed else {
            throw FaceTrackerError.permissionDenied
        }
        
        let cameraFrameProvider = CameraFrameProvider()
        try await arkitSession.run([worldTracking, cameraFrameProvider])
        self.arkitSession = arkitSession
        self.cameraFrameProvider = cameraFrameProvider
        
        task = Task { @MainActor in
            do {
                try await observeCameraFrameUpdates(cameraFrameProvider: cameraFrameProvider)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
    
    func stop() {
        task?.cancel()
        task = nil
    }
    
    // MARK: - 相机帧流
    private func observeCameraFrameUpdates(cameraFrameProvider: CameraFrameProvider) async throws {
        let desiredFormat = Self.getCameraVideoFormat()
        
        guard let desiredFormat,
              let cameraFrameUpdates = cameraFrameProvider.cameraFrameUpdates(for: desiredFormat) else {
            throw FaceTrackerError.noSupportedFormat
        }
        
        for await cameraFrame in cameraFrameUpdates {
            guard !Task.isCancelled else { break }
            guard worldTracking.state == .running else { continue }
            guard cameraFrameProvider.state == .running else { continue }
            guard let leftSample = cameraFrame.sample(for: .left),
                  let rightSample = cameraFrame.sample(for: .right) else {
                continue
            }
            guard let head = getHead() else { continue }
            
            // 首帧时缓存内外参
            if intrinsics == nil {
                intrinsics = leftSample.parameters.intrinsics
                leftExtrinsics = leftSample.parameters.extrinsics
                rightExtrinsics = rightSample.parameters.extrinsics
                resolution = desiredFormat.frameSize
            }
            
            // 处理这一帧
            await processFrame(leftSample: leftSample, rightSample: rightSample, head: head)
        }
    }
    
    // MARK: - 帧处理
    private func processFrame(leftSample: CameraFrame.Sample, rightSample: CameraFrame.Sample, head: Transform) async {
        do {
            // 转为CGImage
            let leftImage = try await leftSample.buffer.toCGImage(context: ciContext)
            let rightImage = try await rightSample.buffer.toCGImage(context: ciContext)
            
            // 下采样
            let downsampledLeft = downsample(leftImage)
            let downsampledRight = downsample(rightImage)
            
            // 双目人脸检测（并行）
            async let leftFaces = detectFaces(in: downsampledLeft)
            async let rightFaces = detectFaces(in: downsampledRight)
            
            let leftObservations = try await leftFaces
            let rightObservations = try await rightFaces
            
            guard !leftObservations.isEmpty && !rightObservations.isEmpty else {
                // 检测丢失保护
                if let lastTime = lastDetectionTime,
                   Date().timeIntervalSince(lastTime) < detectionRetentionInterval {
                    return // 保留上一帧位置
                }
                facePosition = nil
                return
            }
            
            // 取每只眼检测到的第一个人脸（最显著的）
            let leftFace = leftObservations[0]
            let rightFace = rightObservations[0]
            
            // 计算下巴像素坐标（边界框底部中心）
            // Vision的NormalizedRect原点在左下角
            let leftChinNormalized = CGPoint(
                x: leftFace.boundingBox.origin.x + leftFace.boundingBox.width / 2,
                y: leftFace.boundingBox.origin.y // 底部=下巴
            )
            let rightChinNormalized = CGPoint(
                x: rightFace.boundingBox.origin.x + rightFace.boundingBox.width / 2,
                y: rightFace.boundingBox.origin.y
            )
            
            // 下采样后的图像尺寸
            let dsLeftSize = CGSize(width: downsampledLeft.width, height: downsampledLeft.height)
            let dsRightSize = CGSize(width: downsampledRight.width, height: downsampledRight.height)
            
            // 转为像素坐标（Vision坐标系：左下角原点 → 图像坐标系：左上角原点）
            let leftChinPixel = CGPoint(
                x: leftChinNormalized.x * dsLeftSize.width,
                y: (1 - leftChinNormalized.y) * dsLeftSize.height
            )
            let rightChinPixel = CGPoint(
                x: rightChinNormalized.x * dsRightSize.width,
                y: (1 - rightChinNormalized.y) * dsRightSize.height
            )
            
            // 将下采样后的像素坐标映射回原始分辨率
            let scaleX = CGFloat(leftImage.width) / dsLeftSize.width
            let scaleY = CGFloat(leftImage.height) / dsLeftSize.height
            let originalLeftChin = CGPoint(x: leftChinPixel.x * scaleX, y: leftChinPixel.y * scaleY)
            
            let scaleX2 = CGFloat(rightImage.width) / dsRightSize.width
            let scaleY2 = CGFloat(rightImage.height) / dsRightSize.height
            let originalRightChin = CGPoint(x: rightChinPixel.x * scaleX2, y: rightChinPixel.y * scaleY2)
            
            // 用内外参计算世界射线并求交
            guard let intrinsics, let leftExtrinsics, let rightExtrinsics, let resolution else { return }
            
            let leftRay = cameraPointToWorldRay(
                cameraPoint: originalLeftChin,
                intrinsics: intrinsics,
                extrinsics: leftExtrinsics,
                head: head,
                resolution: resolution
            )
            let rightRay = cameraPointToWorldRay(
                cameraPoint: originalRightChin,
                intrinsics: intrinsics,
                extrinsics: rightExtrinsics,
                head: head,
                resolution: resolution
            )
            
            // 双目射线求交
            if let position = closestPointBetweenRays(leftRay: leftRay, rightRay: rightRay) {
                facePosition = position
                lastDetectionTime = Date()
            }
        } catch {
            os_log("帧处理错误: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 人脸检测
    private func detectFaces(in image: CGImage) async throws -> [FaceObservation] {
        let request = DetectFaceRectanglesRequest()
        return try await request.perform(on: image)
    }
    
    // MARK: - 下采样
    private func downsample(_ image: CGImage) -> CGImage {
        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        
        guard originalWidth > maxDimension || originalHeight > maxDimension else {
            return image
        }
        
        let scale = maxDimension / max(originalWidth, originalHeight)
        let newWidth = Int(originalWidth * scale)
        let newHeight = Int(originalHeight * scale)
        
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }
    
    // MARK: - 像素坐标转世界射线
    /// 将相机画面中的像素坐标转换为世界坐标射线
    /// 参考VisionProKit的CameraToWorld实现
    private func cameraPointToWorldRay(
        cameraPoint: CGPoint,
        intrinsics: simd_float3x3,
        extrinsics: simd_float4x4,
        head: Transform,
        resolution: CGSize
    ) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        // 1. 从内参矩阵提取焦距和主点
        // Apple K矩阵转置约定: col0=(fx,0,cx), col1=(0,fy,cy), col2=(0,0,1)
        let fx = Double(intrinsics.columns.0.x)
        let fy = Double(intrinsics.columns.1.y)
        let cx = Double(intrinsics.columns.0.z)
        let cy = Double(intrinsics.columns.1.z)
        
        // 2. Y轴翻转（图像+Y向下 → 3D+Y向上）
        let pixelX = Double(cameraPoint.x)
        let pixelY = Double(resolution.height) - Double(cameraPoint.y)
        
        // 3. 反透视投影到z=-1归一化平面
        let cameraSpaceDirection = SIMD3<Double>(
            (pixelX - cx) / fx,
            (pixelY - cy) / fy,
            -1.0
        )
        
        // 4. 外参→相机在世界中的Pose
        // ARKit外参是View矩阵(Device→Camera_OpenCV)
        // 需要: ① R_x(π)·E 翻转Y/Z  ② 求逆得Pose(Camera→Device)  ③ deviceTransform * pose得世界Pose
        let rotationX = simd_double4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, -1, 0, 0),
            SIMD4(0, 0, -1, 0),
            SIMD4(0, 0, 0, 1)
        ))
        let rotated = rotationX * simd_double4x4(extrinsics)
        let cameraPoseLocal = rotated.inverse
        
        // cameraPose（世界）= deviceTransform * cameraPoseLocal
        let headMatrixDouble = simd_double4x4(head.matrix)
        let cameraPoseWorld = headMatrixDouble * cameraPoseLocal
        
        // 5. 相机空间方向→世界方向 (w=0只受旋转影响)
        let directionHomogeneous = cameraPoseWorld * SIMD4<Double>(cameraSpaceDirection, 0.0)
        let worldDirection = normalize(SIMD3<Double>(directionHomogeneous.x, directionHomogeneous.y, directionHomogeneous.z))
        
        // 6. 射线原点 = cameraPose.col3
        let worldOrigin = SIMD3<Double>(
            cameraPoseWorld.columns.3.x,
            cameraPoseWorld.columns.3.y,
            cameraPoseWorld.columns.3.z
        )
        
        return (origin: worldOrigin, direction: worldDirection)
    }
    
    // MARK: - 双目射线求交
    /// 计算两条射线最近点，返回中点作为人脸位置
    /// 从0.5米开始搜索，确保合理距离
    private func closestPointBetweenRays(
        leftRay: (origin: SIMD3<Double>, direction: SIMD3<Double>),
        rightRay: (origin: SIMD3<Double>, direction: SIMD3<Double>)
    ) -> SIMD3<Float>? {
        let p1 = leftRay.origin
        let d1 = leftRay.direction
        let p2 = rightRay.origin
        let d2 = rightRay.direction
        
        let w0 = p1 - p2
        let a = simd_dot(d1, d1)
        let b = simd_dot(d1, d2)
        let c = simd_dot(d2, d2)
        let d = simd_dot(d1, w0)
        let e = simd_dot(d2, w0)
        
        let denom = a * c - b * b
        guard abs(denom) > 1e-10 else {
            // 射线几乎平行，无法求交
            return nil
        }
        
        let t = (b * e - c * d) / denom
        let s = (a * e - b * d) / denom
        
        // t和s是从射线原点出发的距离
        // 确保交点在前方（t > 0, s > 0）且距离合理
        let minDistance: Double = 0.3
        let maxDistance: Double = 10.0
        guard t > minDistance && t < maxDistance && s > minDistance && s < maxDistance else {
            return nil
        }
        
        let closestOnLeft = p1 + t * d1
        let closestOnRight = p2 + s * d2
        let midpoint = (closestOnLeft + closestOnRight) / 2.0
        
        return SIMD3<Float>(Float(midpoint.x), Float(midpoint.y), Float(midpoint.z))
    }
    
    // MARK: - 辅助方法
    private func getHead() -> Transform? {
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return nil
        }
        return Transform(matrix: anchor.originFromAnchorTransform)
    }
    
    static func getCameraVideoFormat() -> CameraVideoFormat? {
        let cameraPositions: [CameraFrameProvider.CameraPosition] = [.left, .right]
        let formats = CameraVideoFormat
            .supportedVideoFormats(for: .main, cameraPositions: cameraPositions)
            .filter({ $0.cameraRectification == .mono })
        return formats.max { $0.frameSize.width * $0.frameSize.height < $1.frameSize.width * $1.frameSize.height }
    }
    
    enum FaceTrackerError: LocalizedError {
        case permissionDenied
        case noSupportedFormat
        
        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "摄像头权限未授予"
            case .noSupportedFormat:
                "没有支持的相机格式"
            }
        }
    }
}

// MARK: - simd_float4x4扩展
private extension simd_double4x4 {
    init(_ floatMatrix: simd_float4x4) {
        self.init(
            columns: (
                SIMD4(Double(floatMatrix.columns.0.x), Double(floatMatrix.columns.0.y), Double(floatMatrix.columns.0.z), Double(floatMatrix.columns.0.w)),
                SIMD4(Double(floatMatrix.columns.1.x), Double(floatMatrix.columns.1.y), Double(floatMatrix.columns.1.z), Double(floatMatrix.columns.1.w)),
                SIMD4(Double(floatMatrix.columns.2.x), Double(floatMatrix.columns.2.y), Double(floatMatrix.columns.2.z), Double(floatMatrix.columns.2.w)),
                SIMD4(Double(floatMatrix.columns.3.x), Double(floatMatrix.columns.3.y), Double(floatMatrix.columns.3.z), Double(floatMatrix.columns.3.w))
            )
        )
    }
}

// MARK: - CVReadOnlyPixelBuffer扩展
extension CVReadOnlyPixelBuffer {
    func toCGImage(context: CIContext) async throws -> CGImage {
        try await CVPixelBufferToCGImageHelper().convert(buffer: self, context: context)
    }
}

private actor CVPixelBufferToCGImageHelper {
    func convert(buffer: CVReadOnlyPixelBuffer, context: CIContext) throws -> CGImage {
        try buffer.withUnsafeBuffer { cvPixelBuffer in
            let ciImage = CIImage(cvPixelBuffer: cvPixelBuffer)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                throw CVPixelBufferToCGImageError.failedToCreateCGImage
            }
            return cgImage
        }
    }
}

private enum CVPixelBufferToCGImageError: Error {
    case failedToCreateCGImage
}