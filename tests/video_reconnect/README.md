# Video reconnect regression

Run with the same Xcode Swift toolchain used to build the app:

```sh
python3 tests/video_reconnect/generate.py /tmp/r1-video-reconnect
swiftc /tmp/r1-video-reconnect/Production.swift tests/video_reconnect/Tests.swift -o /tmp/r1-video-reconnect/checks
/tmp/r1-video-reconnect/checks
```

The generator extracts the production reconnect state and source freshness gate. Tests use deterministic source/arrival times, covering progressive retry delays, sustained recovery, repeated and invalid frames, source epoch changes, and gaps. No device, networking, or robot is needed. These checks do not measure real wireless recovery times.
