import SwiftUI

@main
struct VisionProTeleopApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var imageData = ImageData()
    @StateObject private var appModel = 🥽AppModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                startServer()
            case .background:
                GRPCServerManager.shared.stopServer()
            default:
                break
            }
        }
        
        // Hand tracking view (existing)
        ImmersiveSpace(id: "immersiveSpace") {
            🌐RealityView(model: appModel)
        }
        
        // Video streaming view (new)
        ImmersiveSpace(id: "videoStreamSpace") {
            ImmersiveView()
                .environmentObject(imageData)
        }
        
        // MuJoCo streaming view (new)
        ImmersiveSpace(id: "mujocoStreamSpace") {
            MuJoCoStreamingView()
        }
        
        // Combined streaming view (Video + Audio + MuJoCo Sim)
        ImmersiveSpace(id: "combinedStreamSpace") {
            CombinedStreamingView()
                .environmentObject(imageData)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
    
    init() {
        UserDefaults.standard.set(true, forKey: "dontShowSignInAgain")
        UserDefaults.standard.set(true, forKey: "dontShowIOSPromoAgain")
        dlog("🚀 [DEBUG] VisionProTeleopApp.init() - App launching...")
        🧑HeadTrackingComponent.registerComponent()
        🧑HeadTrackingSystem.registerSystem()
        
    }
}

