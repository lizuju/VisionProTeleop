from pathlib import Path
import shutil, hashlib, json
root=Path(__file__).resolve().parents[2]
out=Path(__file__).resolve().parent / '.generated'
src=out/'Sources/SenderCheck'; src.mkdir(parents=True,exist_ok=True)
app=(root/'Tracking Streamer/🥽AppModel.swift').read_text()
grpc=(root/'Tracking Streamer/GRPCServer.swift').read_text()
def function(text, marker):
    start=text.index(marker); opening=text.index('{',start); depth=1; end=opening+1
    while depth:
        depth += (text[end]=='{')-(text[end]=='}'); end+=1
    return text[start:end]
prefix='import Foundation\nimport Combine\nimport QuartzCore\nimport simd\nimport SwiftProtobuf\n'
tracking=app[app.index('struct Skeleton {'):app.index('struct BenchmarkEvent {')]
dm=app[app.index('    var latestHandTrackingData:'):app.index('    @Published var grpcServerReady:')]
fill=function(app,'func fill_handUpdate()')
matrix=function(app,'func createMatrix4x4(')
loop=grpc[grpc.index('        var lastUpdate: Handtracking_HandUpdate?'):grpc.rindex('\n    }\n}')]
code=prefix+tracking+'class DataManager { static let shared = DataManager()\n'+dm+'var pythonLibraryVersionCode = 0; var webrtcServerInfo: String?; var webrtcGeneration = 0; var pythonCalibrationActive = false\n}\n'
code+='@MainActor\n'+fill+'\n'+matrix+'\n'
code+='func getMarkerMatrices() -> [Handtracking_Matrix4x4]? { nil }\nfunc getStylusMatrices() -> [Handtracking_Matrix4x4]? { nil }\nfunc dlog(_ value: String) {}\n'
code+='class BenchmarkEventDispatcher { static let shared = BenchmarkEventDispatcher(); func clear() {} }\nfunc runStream(_ response: TestWriter, streamID: UUID) async {\n let isWebRTCInfoOnly = false\n'+loop+'}\n'
(src/'Production.swift').write_text(code)
shutil.copy2(root/'Tracking Streamer/Proto/handtracking.pb.swift',src/'handtracking.pb.swift')
(out/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SenderCheck", platforms: [.macOS(.v15)], dependencies: [.package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.33.3")], targets: [.executableTarget(name: "SenderCheck", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")], swiftSettings: [.swiftLanguageMode(.v5)])])
''')
(out/'production-source.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'Tracking Streamer/GRPCServer.swift',root/'Tracking Streamer/🥽AppModel.swift',root/'Tracking Streamer/Proto/handtracking.pb.swift']},indent=2))

shutil.copy2(Path(__file__).resolve().parent/'Tests.swift',src/'Tests.swift')
