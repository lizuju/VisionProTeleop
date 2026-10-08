from pathlib import Path
import sys


source = Path(__file__).resolve().parents[2] / "Tracking Streamer" / "RobotOperatorStatus.swift"
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
structs = source.read_text().split("@MainActor\nfinal class RobotOperatorStatus", 1)[0]
structs = "\n".join(line for line in structs.splitlines() if not line.startswith("import "))
(output / "Production.swift").write_text("import Foundation\n" + structs)
