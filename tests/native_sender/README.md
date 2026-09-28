# Native sender regression

On macOS with the same Xcode toolchain used to build the app:

```sh
python3 tests/native_sender/generate.py
swift run --package-path tests/native_sender/.generated SenderCheck
```

The generated package pins SwiftProtobuf 1.33.3, matching the app lockfile. Its first run needs access to GitHub. Generated files and build output are ignored.

The generator extracts the actual sender loop and disconnect cleanup from `GRPCServer.swift`, source validity observers and packet serialization from `🥽AppModel.swift`, and the generated protobuf. The test replaces the writer with a recording/blocked writer and stubs unrelated marker/stylus providers. Production timing and validity branches remain intact. `production-source.json` records the input hashes.

The 29 checks cover heartbeat duplicate suppression, source timestamps, a 120 Hz cap, current data after a blocked write, short source invalidation events, diagnostic protobuf round trips, cancellation and new/old stream cleanup isolation. These checks do not measure wireless delivery or robot control.
