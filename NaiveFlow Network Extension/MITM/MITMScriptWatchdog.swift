import Darwin
import Foundation
import JavaScriptCore

nonisolated enum MITMScriptWatchdog {
    static let hardCapSeconds: TimeInterval = 30

    // JavaScriptCore's execution limit interrupts the VM itself. A Swift task
    // cannot cancel a synchronous JS evaluation on the script executor.
    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (
        JSContextGroupRef, Double, TerminateCallback?, UnsafeMutableRawPointer?
    ) -> Void

    private static let setLimit: SetLimit? = {
        guard let framework = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY),
              let symbol = dlsym(framework, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    static var isAvailable: Bool { setLimit != nil }

    static func arm(context: JSContext, seconds: TimeInterval) {
        setLimit?(JSContextGetGroup(context.jsGlobalContextRef), min(hardCapSeconds, max(0.001, seconds)), nil, nil)
    }
}
