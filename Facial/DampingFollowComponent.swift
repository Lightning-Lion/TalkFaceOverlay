import RealityKit
import CoreGraphics

// MARK: 阻尼跟随，就像手机上拖动小窗的手感
// 一个常见的用法是先使用CustomHeadAnchor，是急切跟随用户头部姿态的
// 然后使用我这个阻尼跟随，来阻尼跟随用户头部

// 定义阻尼跟随组件，存储所有必要的跟随数据
struct DampingFollowComponent: Component {
    // 要跟随的目标实体
    weak var target: Entity?
    init(target: Entity) {
        self.target = target
    }
}

// 定义阻尼跟随系统，处理所有带有DampingFollowComponent的实体
struct DampingFollowSystem: System {
    // 系统需要查询所有带有DampingFollowComponent的实体
    private static let query = EntityQuery(where: .has(DampingFollowComponent.self))
    
    init(scene: Scene) {}
    
    // 每帧更新
    func update(context: SceneUpdateContext) {
        // 获取所有需要处理的实体
        let entities = context.entities(matching: Self.query, updatingSystemWhen: .rendering)
        
        for entity in entities {
            guard var followComponent = entity.components[DampingFollowComponent.self],
                  let target = followComponent.target else { continue }
            
            let targetPlace:simd_float4x4 = target.transformMatrix(relativeTo: nil)
            
            //1秒的duration就有damping follow的感觉了
            entity.move(to: targetPlace, relativeTo: nil, duration: 1, timingFunction: .easeInOut)
            
            // 更新组件
            entity.components[DampingFollowComponent.self] = followComponent
        }
    }
}

// 用法：
//    // 创建一个目标实体（例如一个立方体）
//    let targetEntity = ModelEntity(mesh: .generateBox(size: 0.1), materials: [SimpleMaterial(color: .red, isMetallic: false)])
//    targetEntity.position = [0, 0, -1] // 初始位置在前方1米处
//    arView.scene.addEntity(targetEntity)
//
//    // 创建一个跟随实体（例如一个相机）
//    let followerEntity = Entity()
//    followerEntity.camera = PerspectiveCameraComponent(fieldOfViewInDegrees: 60, nearPlane: 0.1, farPlane: 100)
//    arView.scene.addEntity(followerEntity)
//
//    // 设置AR视图的主相机为跟随实体
//    arView.cameraTransform = Transform(matrix: followerEntity.transform.matrix)
//
//    // 为跟随实体添加阻尼跟随组件
//    followerEntity.components[DampingFollowComponent.self] = DampingFollowComponent(
//        target: targetEntity,
//        positionDamping: 2.5,
//        rotationDamping: 3.0,
//        positionOffset: [0, 0.5, -1], // 在目标上方0.5米，前方1米
//        rotationOffset: simd_quatf(angle: .pi/12, axis: [1, 0, 0]) // 稍微向下看
//    )
//
//    // 可以添加一些动画让目标移动，测试跟随效果
//    animateTarget(targetEntity)
