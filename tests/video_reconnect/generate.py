from pathlib import Path
import sys


root = Path(__file__).resolve().parents[2] / "Tracking Streamer"
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
connection = (root / "RobotVideoConnection.swift").read_text()
backoff = connection.split("struct RobotVideoReconnectBackoff {", 1)[1].split("@MainActor", 1)[0]
timing = (root / "RobotVideoTiming.swift").read_text().split("// Accessed under", 1)[0]
(output / "Production.swift").write_text(timing + "\nstruct RobotVideoReconnectBackoff {" + backoff)
