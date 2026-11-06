import Foundation

/// The measurements that don't need a music file, in one run, so an iPad can do them too. Muted.
public enum DeviceBench {
    public static func run(log: (String) -> Void) throws {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        log("BENCH device: \(machine())")
        log("BENCH output: \(LiveApple.outputDescription)")
        for block in [256, 512, 1024] {
            log("BENCH cpu " + Bench.engineCPU(blockFrames: block, seconds: 25).row)
            log("BENCH cpu " + (try Bench.appleCPU(blockFrames: block, seconds: 25)).row)
        }
        for (from, to) in [(1.0, 1.08), (1.08, 1.0)] {
            let result = Bench.engineSpeedResponse(from: from, to: to)
            log("BENCH speed \(Bench.engineName) \(from) to \(to): " + (result.map { String(format: "%.1f ms", $0) } ?? "no reading"))
            let apple = try Bench.appleSpeedResponse(from: from, to: to)
            log("BENCH speed Apple \(from) to \(to): " + (apple.map { String(format: "%.1f ms", $0) } ?? "no reading"))
        }
        for tempo in [0.92, 1.0, 1.08] {
            log("BENCH jump " + Bench.engineJump(tempo: tempo).row)
        }
        try runLive(log: log)
        log("BENCH done")
    }

    public static func runLive(log: (String) -> Void) throws {
        log("BENCH output: \(LiveApple.outputDescription)")
        for tempo in [0.84, 0.92, 1.0, 1.08, 1.16] { log("BENCH live delay " + (try LiveApple.delay(tempo: tempo)).row) }
        for tempo in [0.92, 1.0, 1.08] { log("BENCH live jump " + (try LiveApple.jump(tempo: tempo)).row) }
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &name, &size, nil, 0)
        return String(cString: name)
    }
}
