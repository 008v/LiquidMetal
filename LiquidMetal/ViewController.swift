//
//  ViewController.swift
//  LiquidMetal
//
//  Created by WEI QIN on 2018/12/24.
//  Copyright © 2018 WEI QIN. All rights reserved.
//

import UIKit
import CoreMotion

class ViewController: UIViewController {

    let gravity: Float = 9.80665
    let ptmRatio: Float = 32.0
    let particleRadius: Float = 9.0
    var particleSystem: UnsafeMutableRawPointer!
    
    var device: MTLDevice!
    var pipelineState: MTLRenderPipelineState!
    var commandQueue: MTLCommandQueue!
    var metalLayer: CAMetalLayer!
    
    var particleCount: Int = 0
    var vertexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    
    let motionManager: CMMotionManager = CMMotionManager()
    
    deinit {
        LiquidFun.destroyWorld()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        LiquidFun.createWorld(withGravity: Vector2D(x: 0, y: -gravity))
        
        particleSystem = LiquidFun.createParticleSystem(withRadius: particleRadius / ptmRatio,
                                                        dampingStrength: 0.2,
                                                        gravityScale: 1,
                                                        density: 1.2);
        
        LiquidFun.setParticleLimitForSystem(particleSystem, maxParticles: 1500)
        
        let screenSize: CGSize = UIScreen.main.bounds.size
        let screenWidth = Float(screenSize.width)
        let screenHeight = Float(screenSize.height)
        
        LiquidFun.createParticleBox(forSystem: particleSystem,
                                    position: Vector2D(x: screenWidth * 0.5 / ptmRatio, y: screenHeight * 0.5 / ptmRatio),
                                    size: Size2D(width: 50 / ptmRatio, height: 50 / ptmRatio))
        
        LiquidFun.createEdgeBox(withOrigin: Vector2D(x: 0, y: 0), size: Size2D(width: screenWidth / ptmRatio, height: screenHeight / ptmRatio))
        
        createMetalLayer()
        
        refreshVertexBuffer()
        
        refreshUniformBuffer()
        
        buildRenderPipeline()
        
        render()
        
        let displayLink = CADisplayLink(target: self, selector: #selector(update(displayLink:)))
        displayLink.frameInterval = 1
        displayLink.add(to: RunLoop.current, forMode: .default)
        
        motionManager.startAccelerometerUpdates(to: OperationQueue(),
                                                withHandler: { (accelerometerData, error) -> Void in
                                                    let acceleration = accelerometerData!.acceleration
                                                    let gravityX = self.gravity * Float(acceleration.x)
                                                    let gravityY = self.gravity * Float(acceleration.y)
                                                    LiquidFun.setGravity(Vector2D(x: gravityX, y: gravityY))
        })
    }
    
    func printParticleInfo() {
        let count = Int(LiquidFun.particleCount(forSystem: particleSystem))
        print("There are \(count) particles present")
        
        let positions = LiquidFun.particlePositions(forSystem: particleSystem)
        
        for i in 0..<count {
            let position = positions.load(fromByteOffset: i * MemoryLayout<Vector2D>.size, as: Vector2D.self)
            print("particle: \(i) position: (\(position.x), \(position.y))")
        }
    }
    
    func createMetalLayer() {
        device = MTLCreateSystemDefaultDevice()
        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.frame = view.layer.frame
        view.layer.addSublayer(metalLayer)
    }
    
    func refreshVertexBuffer() {
        particleCount = Int(LiquidFun.particleCount(forSystem: particleSystem))
        let positions = LiquidFun.particlePositions(forSystem: particleSystem)
        let bufferSize = MemoryLayout<Vector2D>.stride * particleCount
        vertexBuffer = device.makeBuffer(bytes: UnsafeRawPointer(positions), length: bufferSize, options: .cpuCacheModeWriteCombined)
    }
    
    func refreshUniformBuffer() {
        
        let screenSize: CGSize = UIScreen.main.bounds.size
        let screenWidth = Float(screenSize.width)
        let screenHeight = Float(screenSize.height)
        let ndcMatrix = makeOrthographicMatrix(left: 0, right: screenWidth,
                                               bottom: 0, top: screenHeight,
                                               near: -1, far: 1)
        var radius = particleRadius
        var ratio = ptmRatio
        
        let floatSize = MemoryLayout<Float>.stride
        let float4x4ByteAlignment = floatSize * 4
        let float4x4Size = floatSize * 16
        let paddingBytesSize = float4x4ByteAlignment - floatSize * 2
        let uniformsStructSize = float4x4Size + floatSize * 2 + paddingBytesSize
        
        uniformBuffer = device.makeBuffer(length: uniformsStructSize, options: .cpuCacheModeWriteCombined)
        let bufferPointer = uniformBuffer.contents()
        memcpy(bufferPointer, ndcMatrix, float4x4Size)
        memcpy(bufferPointer + float4x4Size, &ratio, floatSize)
        memcpy(bufferPointer + float4x4Size + floatSize, &radius, floatSize)
    }
    
    func buildRenderPipeline() {
        
        let library = device.makeDefaultLibrary()
        let fragmentFunction = library?.makeFunction(name: "basic_fragment")
        let vertexFunction = library?.makeFunction(name: "particle_vertex")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }catch let pipelineError {
            print("Error occurred when creating render pipeline state: \(pipelineError)")
        }

        commandQueue = device.makeCommandQueue()
    }
    
    func render() {
        
        guard let drawable = metalLayer.nextDrawable() else {
            return
        }
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 104/255.0, 5/255.0, 1.0)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
           return
        }
        
        commandEncoder.setRenderPipelineState(pipelineState)
        commandEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        commandEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount, instanceCount: 1)
        commandEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    @objc func update(displayLink:CADisplayLink) {
        autoreleasepool {
            LiquidFun.worldStep(displayLink.duration, velocityIterations: 8, positionIterations: 3)
            self.refreshVertexBuffer()
            self.render()
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let touchLocation = touch.location(in: view)
            let position = Vector2D(x: Float(touchLocation.x) / ptmRatio,
                                    y: Float(view.bounds.height - touchLocation.y) / ptmRatio)
            let size = Size2D(width: 100 / ptmRatio, height: 100 / ptmRatio)
            LiquidFun.createParticleBox(forSystem: particleSystem, position: position, size: size)
        }
    }
}

extension ViewController {
    func makeOrthographicMatrix(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> [Float] {
        let ral = right + left
        let rsl = right - left
        let tab = top + bottom
        let tsb = top - bottom
        let fan = far + near
        let fsn = far - near
        
        return [2.0 / rsl, 0.0, 0.0, 0.0,
                0.0, 2.0 / tsb, 0.0, 0.0,
                0.0, 0.0, -2.0 / fsn, 0.0,
                -ral / rsl, -tab / tsb, -fan / fsn, 1.0]
    }
}

