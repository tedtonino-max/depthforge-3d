import SceneKit
import UIKit

/// Visualizes the actual 3D object selection volume: a circle on the floor and
/// a light cylinder outline. It is deliberately independent of the scan mesh.
final class ObjectScanVolumeOverlay {
    private let root = SCNNode()
    private var isRecording = false

    func attach(to sceneRoot: SCNNode) {
        root.name = "DepthForgeObjectScanVolume"
        sceneRoot.addChildNode(root)
    }

    func reset() {
        root.childNodes.forEach { $0.removeFromParentNode() }
        currentVolume = nil
        isRecording = false
    }

    func setRecording(_ value: Bool) {
        isRecording = value
        guard let volume = currentVolume else { return }
        show(volume, isRecording: value)
    }

    func show(_ volume: ObjectScanVolume, isRecording: Bool) {
        reset()
        self.isRecording = isRecording
        root.position = SCNVector3(volume.x, volume.y, volume.z)
        let color = isRecording ? UIColor.systemGreen : UIColor.systemMint

        let floorRing = SCNNode(geometry: ring(radius: CGFloat(volume.radius), color: color, opacity: 0.96))
        floorRing.position.y = 0.012
        root.addChildNode(floorRing)

        let floorDisk = SCNCylinder(radius: CGFloat(volume.radius), height: 0.004)
        floorDisk.firstMaterial = translucentMaterial(color: color, opacity: isRecording ? 0.05 : 0.11)
        let diskNode = SCNNode(geometry: floorDisk)
        diskNode.position.y = 0.004
        root.addChildNode(diskNode)

        let topRing = SCNNode(geometry: ring(radius: CGFloat(volume.radius), color: color, opacity: 0.22))
        topRing.position.y = volume.height
        root.addChildNode(topRing)

        let r = volume.radius
        for (x, z) in [(r, r), (r, -r), (-r, r), (-r, -r)] {
            let post = SCNCylinder(radius: 0.003, height: CGFloat(volume.height))
            post.firstMaterial = translucentMaterial(color: color, opacity: 0.24)
            let node = SCNNode(geometry: post)
            node.position = SCNVector3(x, volume.height / 2, z)
            root.addChildNode(node)
        }
        currentVolume = volume
    }

    private var currentVolume: ObjectScanVolume?

    private func ring(radius: CGFloat, color: UIColor, opacity: CGFloat) -> SCNGeometry {
        let geometry = SCNTorus(ringRadius: radius, pipeRadius: 0.008)
        geometry.firstMaterial = translucentMaterial(color: color, opacity: opacity)
        return geometry
    }

    private func translucentMaterial(color: UIColor, opacity: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color.withAlphaComponent(opacity)
        material.emission.contents = color.withAlphaComponent(opacity * 0.7)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        return material
    }
}
