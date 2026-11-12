//
//  MITMScriptEngine.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/9/26.
//

import Foundation
import JavaScriptCore
import Synchronization
import UserNotifications

nonisolated private let logger = NaiveFlowLogger(category: "MITMScriptEngine")

nonisolated private let mitmScriptSuspendedBodyBytes = Atomic<Int>(0)

nonisolated private let mitmScriptGlobalFetchCount = Atomic<Int>(0)

nonisolated private let mitmScriptRuleSetNames = Mutex<[UUID: String]>([:])

actor MITMScriptEngine {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        JSCConcurrencyBridge.shared.executor.asUnownedSerialExecutor()
    }

    typealias Message = HTTPMessage

    struct SynthesizedResponse: Sendable {
        let status: Int
        let headers: [(name: String, value: String)]
        let body: Data
    }

    enum Outcome {
        case modified(Message)
        case done(Message)
        case exit
        case respond(SynthesizedResponse)
    }

    struct FrameContext {
        let phase: MITMPhase
        let method: String?
        let url: String?
        let originalURL: String?
        let status: Int?
        let headers: [(name: String, value: String)]
        let frameIndex: Int
        let isLast: Bool
        let ruleSetID: UUID?
    }

    fileprivate enum Directive: Sendable {
        case done
        case exit
        case respond(SynthesizedResponse)
    }

    final class ScriptRun: @unchecked Sendable {
        private static let idSequence = Atomic<UInt64>(0)

        let id = ScriptRun.idSequence.wrappingAdd(1, ordering: .relaxed).newValue
        let startedAt = MonotonicClock.now

        let scope: UUID?
        let allowsHTTP: Bool
        let dialect: MITMScriptDialect
        let context: JSContext

        fileprivate var directive: Directive?
        fileprivate let original: Message?
        fileprivate var surgeDoneMessage: Message?
        fileprivate var continuation: CheckedContinuation<Outcome, Never>?
        fileprivate var inFlightFetches = 0
        fileprivate var totalFetches = 0
        fileprivate var isDelivered = false

        fileprivate var isEvaluating = false
        fileprivate var isClosed = false
        fileprivate var pinnedBodyBytes = 0
        fileprivate let memoryReservation = TransientMemoryReservation()
        fileprivate var watchdogDisarm: AsyncInbox<Void>?


        fileprivate var isFormattingException = false

        fileprivate var pendingFetches: [Int: PendingFetch] = [:]
        private var nextFetchID = 0

        fileprivate func claimFetchID() -> Int {
            nextFetchID += 1
            return nextFetchID
        }

        var logPrefix: String {
            guard let scope, let name = mitmScriptRuleSetNames.withLock({ $0[scope] }) else { return "[Script]" }
            return "[Script] \(name)"
        }

        fileprivate init(scope: UUID?, allowsHTTP: Bool, context: JSContext, original: Message?, dialect: MITMScriptDialect) {
            self.scope = scope
            self.allowsHTTP = allowsHTTP
            self.context = context
            self.original = original
            self.dialect = dialect
        }

        fileprivate func teardown() {
            // The lease follows ScriptRun's actual lifetime, including late fetch callbacks.
            isClosed = true
            for fetch in pendingFetches.values { fetch.task?.cancel() }
            pendingFetches.removeAll()
            context.exception = nil
            context.exceptionHandler = nil
        }
    }

    fileprivate struct PendingFetch {
        let resolve: JSValue?
        let reject: JSValue?
        var task: Task<Void, Never>?
    }

    private static let sharedVirtualMachine = JSVirtualMachine()!

    private var liveRuns: [UInt64: ScriptRun] = [:]

    // MARK: - Watchdog task tree

    private struct WatchdogJob: Sendable {
        let id: UInt64
        let disarm: AsyncInbox<Void>
    }
    private let watchdogJobs: AsyncStream<WatchdogJob>
    private nonisolated let watchdogJobContinuation: AsyncStream<WatchdogJob>.Continuation
    private var watchdogRoot: Task<Void, Never>?

    private static let maxSuspendedBodyBytes: Int = 16 * 1024 * 1024

    private static let maxLiveRuns = 32

    // MARK: NaiveFlow.http caps

    private static let httpDefaultTimeout: TimeInterval = 10
    private static let httpMaxTimeout: TimeInterval = 30
    private static let httpMaxConcurrentPerInvocation = 4
    private static let httpMaxTotalPerInvocation = 16
    private static let httpMaxResponseBytes = 4 * 1024 * 1024
    private static let httpMaxConcurrentGlobal = 32

    private static let invocationIdleTimeout: TimeInterval = httpMaxTimeout + 30

    private static let invocationAbsoluteTimeout: TimeInterval = invocationIdleTimeout * 3

    init() {
        (self.watchdogJobs, self.watchdogJobContinuation) = AsyncStream.makeStream(of: WatchdogJob.self)
    }

    static func warmVirtualMachine() {
        JSCConcurrencyBridge.shared.enqueue { _ = warmedVirtualMachine }
    }

    private static let warmedVirtualMachine: Bool = {
        let engine = MITMScriptEngine()
        let run = engine.makeRun(scope: nil, allowsHTTP: false, original: nil)
        run.teardown()
        withExtendedLifetime(engine) {}
        return true
    }()

    // MARK: - Run construction

    nonisolated private func makeRun(scope: UUID?, allowsHTTP: Bool, original: Message?, dialect: MITMScriptDialect = .surge) -> ScriptRun {
        let context = JSContext(virtualMachine: Self.sharedVirtualMachine)!
        let run = ScriptRun(scope: scope, allowsHTTP: allowsHTTP, context: context, original: original, dialect: dialect)
        configureContext(context, for: run)
        return run
    }

    nonisolated private func configureContext(_ context: JSContext, for run: ScriptRun) {
        context.exceptionHandler = { [weak run] context, exception in
            defer { context?.exception = exception }
            guard let run else { return }
            if run.isFormattingException {
                logger.warning("\(run.logPrefix): Uncaught exception")
                return
            }
            run.isFormattingException = true
            defer { run.isFormattingException = false }
            logger.warning("\(run.logPrefix): \(exception.map(Self.describe) ?? "Uncaught exception")")
        }
        switch run.dialect {
        case .surge:
            if let message = run.original {
                installSurgeGlobals(context: context, for: run, message: message)
            }
        case .quantumultX:
            if let message = run.original {
                installQXGlobals(context: context, for: run, message: message)
            }
        }
    }

    // MARK: - Watchdog tree driver

    private func runWatchdogTree() async {
        await withDiscardingTaskGroup { group in
            for await job in watchdogJobs {
                group.addTask { await self.runWatchdog(id: job.id, disarm: job.disarm) }
            }
            group.cancelAll()
        }
    }

    private func runWatchdog(id: UInt64, disarm: AsyncInbox<Void>) async {
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(seconds: Self.invocationIdleTimeout, precision: .relaxed)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                _ = try? await disarm.next()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard timedOut else { return }
        guard let run = liveRuns[id], !run.isDelivered, let original = run.original else { return }
        logger.warning("\(run.logPrefix): HTTP script timed out")
        deliver(.modified(original), for: run)
    }

    private func dropRuns(notIn activeIDs: Set<UUID>) {
        for run in Array(liveRuns.values) {
            guard let scope = run.scope, !activeIDs.contains(scope) else { continue }
            if !run.isDelivered, let original = run.original {
                deliver(.modified(original), for: run)
            } else {
                liveRuns.removeValue(forKey: run.id)
                run.teardown()
            }
        }
    }

    @inline(__always)
    private func runUserScript<T>(_ label: String, _ body: () -> T) -> T {
        MITMScriptWatchdog.begin(label)
        defer { MITMScriptWatchdog.end() }
        return body()
    }

    private func finalize(_ run: ScriptRun, original: Message, updated: Message) -> Outcome {
        let hadException = run.context.exception != nil
        run.context.exception = nil
        if let directive = run.directive {
            return outcome(forDirective: directive, original: original, updated: updated)
        }
        if hadException {
            return .modified(original)
        }
        return .modified(updated)
    }

    private func outcome(forDirective directive: Directive, original: Message, updated: Message) -> Outcome {
        switch directive {
        case .done: return .done(updated)
        case .exit: return .exit
        case .respond(let response):
            if original.phase == .httpRequest {
                return .respond(response)
            }
            logger.warning("[Script] $done response synthesis unavailable in response phase")
            return .modified(updated)
        }
    }

    // MARK: - Script

    private final class CancelHandle: Sendable {
        let state = Mutex<(runID: UInt64?, isCancelled: Bool)>((runID: nil, isCancelled: false))
    }

    func applyAsync(
        _ message: Message,
        source: String,
        dialect: MITMScriptDialect = .surge
    ) async -> Outcome {
        let cancelHandle = CancelHandle()
        return await withTaskCancellationHandler {
            await JSCConcurrencyBridge.shared.runParked { (continuation: CheckedContinuation<Outcome, Never>) in
                self.runApply(message, source: source, dialect: dialect, continuation: continuation, cancelHandle: cancelHandle)
            }
        } onCancel: {
            JSCConcurrencyBridge.shared.enqueue { [self] in
                self.assumeIsolated { $0.cancelRun(cancelHandle) }
            }
        }
    }

    private func cancelRun(_ cancelHandle: CancelHandle) {
        let runID = cancelHandle.state.withLock { state -> UInt64? in
            state.isCancelled = true
            return state.runID
        }
        guard let runID, let run = liveRuns[runID], !run.isDelivered, let original = run.original else { return }
        deliver(.modified(original), for: run)
    }

    private func runApply(
        _ message: Message,
        source: String,
        dialect: MITMScriptDialect,
        continuation: CheckedContinuation<Outcome, Never>,
        cancelHandle: CancelHandle
    ) {
        let bodyBytes = message.body.count
        let pinned = Self.suspendedBodyBytes()
        if pinned + bodyBytes > Self.maxSuspendedBodyBytes {
            logger.warning("[Script] Suspended body budget exceeded")
            continuation.resume(returning: .modified(message))
            return
        }
        if liveRuns.count >= Self.maxLiveRuns {
            logger.warning("[Script] Too many concurrent scripts")
            continuation.resume(returning: .modified(message))
            return
        }

        let run = makeRun(scope: message.ruleSetID, allowsHTTP: true, original: message, dialect: dialect)
        run.continuation = continuation
        // Account for native/JS body copies before creating JS representations.
        guard run.memoryReservation.resize(bodyBytes * 4 + 256 * 1024) else {
            logger.warning("[Script] Shared MITM memory budget exceeded")
            deliver(.modified(message), for: run)
            return
        }

        liveRuns[run.id] = run
        run.pinnedBodyBytes = bodyBytes
        Self.addSuspendedBodyBytes(bodyBytes)
        armWatchdog(for: run)
        let cancelled = cancelHandle.state.withLock { state -> Bool in
            state.runID = run.id
            return state.isCancelled
        }
        if cancelled { deliver(.modified(message), for: run); return }
        run.isEvaluating = true
        runUserScript(source) {
            let wrapped = "(function(){\n\"use strict\";\n\(source)\n})()"
            run.context.evaluateScript(wrapped)
        }
        run.isEvaluating = false
        if run.directive != nil || run.context.exception != nil {
            finishForeignRun(run)
        }
        // Async Surge/QX scripts complete through $done or the existing watchdog.
    }

    private func finishForeignRun(_ run: ScriptRun) {
        guard !run.isDelivered, let original = run.original else { return }
        deliver(finalize(run, original: original, updated: run.surgeDoneMessage ?? original), for: run)
    }

    private func deliver(_ outcome: Outcome, for run: ScriptRun) {
        guard !run.isDelivered else { return }
        run.isDelivered = true
        run.watchdogDisarm?.finish()
        run.watchdogDisarm = nil
        liveRuns.removeValue(forKey: run.id)
        if run.pinnedBodyBytes > 0 {
            Self.addSuspendedBodyBytes(-run.pinnedBodyBytes)
            run.pinnedBodyBytes = 0
        }
        let continuation = run.continuation
        run.continuation = nil
        run.teardown()
        continuation?.resume(returning: outcome)
    }

    private func armWatchdog(for run: ScriptRun) {
        if watchdogRoot == nil {
            watchdogRoot = Task { await self.runWatchdogTree() }
        }
        run.watchdogDisarm?.finish()
        let disarm = AsyncInbox<Void>(capacity: 1)
        run.watchdogDisarm = disarm
        watchdogJobContinuation.yield(WatchdogJob(id: run.id, disarm: disarm))
    }

    private static func suspendedBodyBytes() -> Int {
        mitmScriptSuspendedBodyBytes.load(ordering: .relaxed)
    }

    private static func addSuspendedBodyBytes(_ delta: Int) {
        mitmScriptSuspendedBodyBytes.wrappingAdd(delta, ordering: .relaxed)
    }

    // MARK: - Script diagnostics

    private static let wrapperLineCount = 2

    private static func describe(_ exception: JSValue) -> String {
        let message = exception.toString() ?? "Uncaught exception"
        guard let line = exception.objectForKeyedSubscript("line"), line.isNumber else { return message }
        let sourceLine = Int(line.toInt32()) - wrapperLineCount
        return sourceLine > 0 ? "line \(sourceLine): \(message)" : message
    }

    private static func validatedArrayLength(_ value: JSValue, maxLength: Int) -> Int? {
        guard let lengthValue = value.objectForKeyedSubscript("length"), lengthValue.isNumber else {
            return nil
        }
        let raw = lengthValue.toDouble()
        guard raw.isFinite, raw >= 0, raw <= Double(maxLength) else { return nil }
        return Int(raw)
    }

    private static func headersFromValue(_ value: JSValue) -> [(name: String, value: String)]? {
        guard value.isArray else { return nil }
        guard let length = Self.validatedArrayLength(value, maxLength: 100_000) else {
            logger.warning("[Script] Invalid ctx.headers")
            return nil
        }
        if length == 0 { return [] }
        var result: [(name: String, value: String)] = []
        result.reserveCapacity(length)
        for index in 0..<length {
            guard let entry = value.objectAtIndexedSubscript(index),
                  entry.isArray,
                  let entryLength = entry.objectForKeyedSubscript("length")?.toInt32(),
                  entryLength == 2
            else {
                logger.warning("[Script] Invalid ctx.headers entry")
                continue
            }
            guard let nameElement = entry.objectAtIndexedSubscript(0),
                  let valueElement = entry.objectAtIndexedSubscript(1),
                  !nameElement.isUndefined, !nameElement.isNull,
                  !valueElement.isUndefined, !valueElement.isNull,
                  let name = nameElement.toString(),
                  let value = valueElement.toString()
            else {
                logger.warning("[Script] Invalid ctx.headers entry")
                continue
            }
            guard HTTPHeader.isValidName(name) else {
                logger.warning("[Script] Invalid header name: \(name)")
                continue
            }
            guard HTTPHeader.isValidValue(value) else {
                logger.warning("[Script] Invalid header value: \(name)")
                continue
            }
            result.append((name: name, value: value))
        }
        if result.isEmpty {
            logger.warning("[Script] Script headers have no valid entries")
            return nil
        }
        return result
    }

    // MARK: - Surge / Quantumult X globals

    nonisolated private func installSurgeGlobals(context: JSContext, for run: ScriptRun, message: Message) {
        context.globalObject.setObject(makeSurgeDoneBlock(for: run), forKeyedSubscript: "$done" as NSString)
        context.globalObject.setObject(makeSurgeRequest(message, in: context), forKeyedSubscript: "$request" as NSString)
        context.globalObject.setObject(makeSurgeResponse(message, in: context), forKeyedSubscript: "$response" as NSString)
        context.globalObject.setObject(makeSurgeHTTPClient(in: context, for: run), forKeyedSubscript: "$httpClient" as NSString)
        context.globalObject.setObject(makeSurgePersistentStore(in: context, scope: run.scope), forKeyedSubscript: "$persistentStore" as NSString)
        context.globalObject.setObject(makeSurgeNotification(in: context), forKeyedSubscript: "$notification" as NSString)
    }

    /// Quantumult X globals: `$done` / `$request` / `$response` plus `$task.fetch`.
    nonisolated private func installQXGlobals(context: JSContext, for run: ScriptRun, message: Message) {
        context.globalObject.setObject(makeSurgeDoneBlock(for: run), forKeyedSubscript: "$done" as NSString)
        context.globalObject.setObject(makeSurgeRequest(message, in: context), forKeyedSubscript: "$request" as NSString)
        context.globalObject.setObject(makeSurgeResponse(message, in: context), forKeyedSubscript: "$response" as NSString)
        context.globalObject.setObject(makeQXTask(in: context, for: run), forKeyedSubscript: "$task" as NSString)
        context.globalObject.setObject(makeQXPrefs(in: context, scope: run.scope), forKeyedSubscript: "$prefs" as NSString)
        let notifyBlock: @convention(block) (String, String, String) -> Void = { title, subtitle, body in
            Self.postScriptNotification(title: title, subtitle: subtitle, body: body)
        }
        context.globalObject.setObject(notifyBlock, forKeyedSubscript: "$notify" as NSString)
    }

    nonisolated private func makeSurgeDoneBlock(for run: ScriptRun) -> @convention(block) (JSValue) -> Void {
        return { [weak self, weak run] argument in
            guard let run, !run.isDelivered, run.directive == nil, let original = run.original else { return }
            if argument.isObject, !argument.isUndefined, !argument.isNull {
                if let responseValue = argument.objectForKeyedSubscript("response"),
                   !responseValue.isUndefined, !responseValue.isNull, responseValue.isObject {
                    run.directive = .respond(Self.synthesizedResponse(from: responseValue))
                } else {
                    run.surgeDoneMessage = Self.applySurgeEdits(argument, to: original)
                    run.directive = .done
                }
            } else {
                run.directive = .done
            }
            if !run.isEvaluating {
                self?.assumeIsolated { $0.finishForeignRun(run) }
            }
        }
    }

    /// Quantumult X `$task.fetch({url, method, headers, body})` → Promise whose
    /// resolve value is `{status, statusCode, headers, body}` and whose reject
    /// value is `{error}`.
    nonisolated private func makeQXTask(in context: JSContext, for run: ScriptRun) -> JSValue {
        let task = JSValue(newObjectIn: context)!
        let fetchBlock: @convention(block) (JSValue) -> JSValue = { [weak self, weak run] specValue in
            let context = JSContext.current()!
            guard let self, let run else { return Self.rejected("$task.fetch: invocation released", in: context) }
            let urlValue: JSValue = specValue.objectForKeyedSubscript("url") ?? JSValue(undefinedIn: context)
            let promise = self.assumeIsolated { $0.startHTTP(run: run, defaultMethod: "GET", urlValue: urlValue, optionsValue: specValue) }
            return Self.wrapQXFetch(promise, in: context)
        }
        task.setObject(fetchBlock, forKeyedSubscript: "fetch" as NSString)
        return task
    }

    nonisolated private static func wrapQXFetch(_ promise: JSValue, in context: JSContext) -> JSValue {
        let wrapped = JSValue(newPromiseIn: context, fromExecutor: { resolve, reject in
            let onFulfilled: @convention(block) (JSValue) -> Void = { response in
                let context = JSContext.current()!
                resolve?.call(withArguments: [Self.makeQXResponse(response, in: context)])
            }
            let onRejected: @convention(block) (JSValue) -> Void = { error in
                let context = JSContext.current()!
                let qxError = JSValue(newObjectIn: context)!
                qxError.setObject(error.toString() ?? "request failed", forKeyedSubscript: "error" as NSString)
                reject?.call(withArguments: [qxError])
            }
            promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])
        })
        return wrapped ?? Self.rejected("$task.fetch: could not create Promise", in: context)
    }

    nonisolated private static func makeQXResponse(_ response: JSValue, in context: JSContext) -> JSValue {
        let qxResponse = JSValue(newObjectIn: context)!
        if let status = response.objectForKeyedSubscript("status"), !status.isUndefined, !status.isNull {
            qxResponse.setObject(status, forKeyedSubscript: "status" as NSString)
            qxResponse.setObject(status, forKeyedSubscript: "statusCode" as NSString)
        }
        let headersObject = JSValue(newObjectIn: context)!
        if let headersValue = response.objectForKeyedSubscript("headers"),
           let pairs = headersValue.toArray() as? [[String]] {
            for pair in pairs where pair.count == 2 {
                headersObject.setObject(pair[1], forKeyedSubscript: pair[0] as NSString)
            }
        }
        qxResponse.setObject(headersObject, forKeyedSubscript: "headers" as NSString)
        let bodyString: String
        if let bodyValue = response.objectForKeyedSubscript("body"),
           let data = Self.bytesFromValue(bodyValue, in: context) {
            bodyString = String(data: data, encoding: .utf8) ?? ""
        } else {
            bodyString = ""
        }
        qxResponse.setObject(bodyString, forKeyedSubscript: "body" as NSString)
        return qxResponse
    }

    /// Surge `$persistentStore` with `read(key)` / `write(value, key)` string
    /// semantics, backed by the per-scope on-disk store.
    nonisolated private func makeSurgePersistentStore(in context: JSContext, scope: UUID?) -> JSValue {
        let store = JSValue(newObjectIn: context)!
        let readBlock: @convention(block) (String) -> JSValue = { key in
            let context = JSContext.current()!
            guard let scope,
                  let bytes = MITMScriptStore.shared.value(forKey: key, scope: scope, onDisk: true),
                  let string = String(data: bytes, encoding: .utf8)
            else { return JSValue(nullIn: context) }
            return JSValue(object: string, in: context)
        }
        let writeBlock: @convention(block) (String, String) -> Void = { value, key in
            guard let scope else { return }
            try? MITMScriptStore.shared.setValue(value.data(using: .utf8) ?? Data(), forKey: key, scope: scope, onDisk: true)
        }
        store.setObject(readBlock, forKeyedSubscript: "read" as NSString)
        store.setObject(writeBlock, forKeyedSubscript: "write" as NSString)
        return store
    }

    /// Quantumult X `$prefs` with `valueForKey` / `setValueForKey` /
    /// `removeValueForKey` / `removeAllValues`, backed by the same on-disk store.
    nonisolated private func makeQXPrefs(in context: JSContext, scope: UUID?) -> JSValue {
        let prefs = JSValue(newObjectIn: context)!
        let valueForKeyBlock: @convention(block) (String) -> JSValue = { key in
            let context = JSContext.current()!
            guard let scope,
                  let bytes = MITMScriptStore.shared.value(forKey: key, scope: scope, onDisk: true),
                  let string = String(data: bytes, encoding: .utf8)
            else { return JSValue(nullIn: context) }
            return JSValue(object: string, in: context)
        }
        let setValueForKeyBlock: @convention(block) (String, String) -> Void = { value, key in
            guard let scope else { return }
            try? MITMScriptStore.shared.setValue(value.data(using: .utf8) ?? Data(), forKey: key, scope: scope, onDisk: true)
        }
        let removeValueForKeyBlock: @convention(block) (String) -> Void = { key in
            guard let scope else { return }
            MITMScriptStore.shared.removeValue(forKey: key, scope: scope, onDisk: true)
        }
        let removeAllValuesBlock: @convention(block) () -> Void = {
            guard let scope else { return }
            for key in MITMScriptStore.shared.keys(scope: scope, onDisk: true) {
                MITMScriptStore.shared.removeValue(forKey: key, scope: scope, onDisk: true)
            }
        }
        prefs.setObject(valueForKeyBlock, forKeyedSubscript: "valueForKey" as NSString)
        prefs.setObject(setValueForKeyBlock, forKeyedSubscript: "setValueForKey" as NSString)
        prefs.setObject(removeValueForKeyBlock, forKeyedSubscript: "removeValueForKey" as NSString)
        prefs.setObject(removeAllValuesBlock, forKeyedSubscript: "removeAllValues" as NSString)
        return prefs
    }

    /// Surge `$notification.post(title, subtitle, body)`.
    nonisolated private func makeSurgeNotification(in context: JSContext) -> JSValue {
        let notification = JSValue(newObjectIn: context)!
        let postBlock: @convention(block) (String, String, String) -> Void = { title, subtitle, body in
            Self.postScriptNotification(title: title, subtitle: subtitle, body: body)
        }
        notification.setObject(postBlock, forKeyedSubscript: "post" as NSString)
        return notification
    }

    /// Posts a local notification from the Network Extension. Authorization is
    /// requested by the host app; without it the request is silently dropped by
    /// the system.
    nonisolated private static func postScriptNotification(title: String, subtitle: String, body: String) {
        #if !os(tvOS)
        // tvOS exposes UNMutableNotificationContent but none of title/subtitle/
        // body/sound, so the script notification is a no-op there.
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Surge-style `$httpClient` with callback signatures
    /// `get(url, cb)` / `post(url, body, cb)`, where `cb(error, response, data)`.
    /// It rides the existing `NaiveFlow.http` Promise and adapts it to callbacks.
    nonisolated private func makeSurgeHTTPClient(in context: JSContext, for run: ScriptRun) -> JSValue {
        let client = JSValue(newObjectIn: context)!

        let getBlock: @convention(block) (JSValue, JSValue) -> Void = { [weak self, weak run] urlValue, callbackValue in
            let context = JSContext.current()!
            guard let self, let run else { return }
            guard let urlString = Self.surgeURLString(from: urlValue), !urlString.isEmpty else {
                Self.invokeSurgeCallback(callbackValue, response: nil, error: Self.error("$httpClient: invalid URL", in: context), in: context)
                return
            }
            let urlJS = JSValue(object: urlString, in: context)!
            let options = Self.surgeOptions(from: urlValue, in: context)
            let promise = self.assumeIsolated { $0.startHTTP(run: run, defaultMethod: "GET", urlValue: urlJS, optionsValue: options) }
            Self.attachSurgeCallback(promise, to: callbackValue, in: context)
        }
        let postBlock: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self, weak run] urlValue, bodyValue, callbackValue in
            let context = JSContext.current()!
            guard let self, let run else { return }
            guard let urlString = Self.surgeURLString(from: urlValue), !urlString.isEmpty else {
                Self.invokeSurgeCallback(callbackValue, response: nil, error: Self.error("$httpClient: invalid URL", in: context), in: context)
                return
            }
            let urlJS = JSValue(object: urlString, in: context)!
            var options = Self.surgeOptions(from: urlValue, in: context)
            if !bodyValue.isUndefined, !bodyValue.isNull {
                options.setObject(bodyValue, forKeyedSubscript: "body" as NSString)
            }
            let promise = self.assumeIsolated { $0.startHTTP(run: run, defaultMethod: "POST", urlValue: urlJS, optionsValue: options) }
            Self.attachSurgeCallback(promise, to: callbackValue, in: context)
        }

        client.setObject(getBlock, forKeyedSubscript: "get" as NSString)
        client.setObject(postBlock, forKeyedSubscript: "post" as NSString)
        return client
    }

    nonisolated private static func surgeURLString(from value: JSValue) -> String? {
        if value.isString { return value.toString() }
        if value.isObject, let url = value.objectForKeyedSubscript("url"), url.isString {
            return url.toString()
        }
        return nil
    }

    nonisolated private static func surgeOptions(from value: JSValue, in context: JSContext) -> JSValue {
        value.isObject ? value : JSValue(nullIn: context)!
    }

    nonisolated private static func attachSurgeCallback(_ promise: JSValue, to callback: JSValue, in context: JSContext) {
        let onFulfilled: @convention(block) (JSValue) -> Void = { response in
            let context = JSContext.current()!
            Self.invokeSurgeCallback(callback, response: response, error: nil, in: context)
        }
        let onRejected: @convention(block) (JSValue) -> Void = { error in
            let context = JSContext.current()!
            Self.invokeSurgeCallback(callback, response: nil, error: error, in: context)
        }
        promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])
    }

    nonisolated private static func invokeSurgeCallback(_ callback: JSValue, response: JSValue?, error: JSValue?, in context: JSContext) {
        if let response {
            let surgeResponse = JSValue(newObjectIn: context)!
            if let status = response.objectForKeyedSubscript("status"), !status.isUndefined, !status.isNull {
                surgeResponse.setObject(status, forKeyedSubscript: "status" as NSString)
            }
            let headersObject = JSValue(newObjectIn: context)!
            if let headersValue = response.objectForKeyedSubscript("headers"),
               let pairs = headersValue.toArray() as? [[String]] {
                for pair in pairs where pair.count == 2 {
                    headersObject.setObject(pair[1], forKeyedSubscript: pair[0] as NSString)
                }
            }
            surgeResponse.setObject(headersObject, forKeyedSubscript: "headers" as NSString)
            let dataString: String
            if let bodyValue = response.objectForKeyedSubscript("body"),
               let data = Self.bytesFromValue(bodyValue, in: context) {
                dataString = String(data: data, encoding: .utf8) ?? ""
            } else {
                dataString = ""
            }
            callback.call(withArguments: [JSValue(nullIn: context), surgeResponse, dataString])
        } else {
            callback.call(withArguments: [error ?? Self.error("$httpClient: request failed", in: context), JSValue(nullIn: context), JSValue(nullIn: context)])
        }
    }

    /// Applies Surge `$done({...})` fields (url / status / headers / body) to the
    /// message. `response` is handled separately as a synthesized response.
    nonisolated private static func applySurgeEdits(_ argument: JSValue, to message: Message) -> Message {
        var updated = message
        if let url = argument.objectForKeyedSubscript("url"), url.isString {
            updated.url = url.toString()
        }
        if let status = argument.objectForKeyedSubscript("status"), status.isNumber {
            updated.status = Int(status.toInt32())
        }
        if let headersValue = argument.objectForKeyedSubscript("headers"),
           !headersValue.isUndefined, !headersValue.isNull,
           let parsed = Self.headersFromValue(headersValue) {
            updated.headers = parsed
        }
        if let bodyValue = argument.objectForKeyedSubscript("body"),
           !bodyValue.isUndefined, !bodyValue.isNull {
            let context = JSContext.current()!
            if let body = Self.bytesFromValue(bodyValue, in: context) {
                updated.body = body
            }
        }
        return updated
    }

    nonisolated private func makeSurgeRequest(_ message: Message, in context: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: context)!
        object.setObject(message.url as Any, forKeyedSubscript: "url" as NSString)
        object.setObject(message.method as Any, forKeyedSubscript: "method" as NSString)
        let headers = JSValue(newObjectIn: context)!
        for header in message.headers {
            headers.setObject(header.value, forKeyedSubscript: header.name as NSString)
        }
        object.setObject(headers, forKeyedSubscript: "headers" as NSString)
        object.setObject(String(data: message.body, encoding: .utf8) ?? "", forKeyedSubscript: "body" as NSString)
        return object
    }

    nonisolated private func makeSurgeResponse(_ message: Message, in context: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: context)!
        object.setObject(message.status as Any, forKeyedSubscript: "status" as NSString)
        let headers = JSValue(newObjectIn: context)!
        for header in message.headers {
            headers.setObject(header.value, forKeyedSubscript: header.name as NSString)
        }
        object.setObject(headers, forKeyedSubscript: "headers" as NSString)
        object.setObject(String(data: message.body, encoding: .utf8) ?? "", forKeyedSubscript: "body" as NSString)
        return object
    }

    private static func synthesizedResponse(from spec: JSValue) -> SynthesizedResponse {
        guard !spec.isUndefined, !spec.isNull else {
            return SynthesizedResponse(status: 200, headers: [], body: Data())
        }
        let status: Int
        if let statusValue = spec.objectForKeyedSubscript("status"),
           statusValue.isNumber {
            let statusDouble = statusValue.toDouble()
            let raw = Int(exactly: statusDouble) ?? -1
            if (100...599).contains(raw) {
                status = raw
            } else {
                logger.warning("[Script] NaiveFlow.respond: Invalid status: \(statusDouble)")
                status = 200
            }
        } else {
            status = 200
        }
        var headers: [(name: String, value: String)] = []
        if let headersValue = spec.objectForKeyedSubscript("headers"),
           !headersValue.isUndefined, !headersValue.isNull,
           let parsed = Self.headersFromValue(headersValue) {
            headers = parsed
        }
        let body: Data
        if let bodyValue = spec.objectForKeyedSubscript("body"),
           !bodyValue.isUndefined, !bodyValue.isNull {
            let context = JSContext.current()!
            body = Self.bytesFromValue(bodyValue, in: context) ?? Data()
        } else {
            body = Data()
        }
        return SynthesizedResponse(status: status, headers: headers, body: body)
    }

    // MARK: - NaiveFlow.http

    private func startHTTP(run: ScriptRun, defaultMethod: String, urlValue: JSValue, optionsValue: JSValue) -> JSValue {
        let context = run.context
        guard run.allowsHTTP else {
            return Self.rejected(
                "HTTP requests are only available inside a buffered Surge or Quantumult X script.",
                in: context
            )
        }
        guard !urlValue.isUndefined, !urlValue.isNull,
              let urlString = urlValue.toString(),
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            return Self.rejected("NaiveFlow.http: expected an absolute http(s) URL", in: context)
        }
        if run.totalFetches >= Self.httpMaxTotalPerInvocation {
            return Self.rejected("NaiveFlow.http: per-invocation request cap (\(Self.httpMaxTotalPerInvocation)) reached", in: context)
        }
        if run.inFlightFetches >= Self.httpMaxConcurrentPerInvocation {
            return Self.rejected("NaiveFlow.http: too many concurrent requests in this invocation (max \(Self.httpMaxConcurrentPerInvocation))", in: context)
        }
        if Self.globalFetchCount() >= Self.httpMaxConcurrentGlobal {
            return Self.rejected("NaiveFlow.http: global concurrent request cap (\(Self.httpMaxConcurrentGlobal)) reached", in: context)
        }

        let options: JSValue? = optionsValue.isObject ? optionsValue : nil
        var request = URLRequest(url: url)
        let method = (options?.objectForKeyedSubscript("method"))
            .flatMap { $0.isString ? $0.toString() : nil }?
            .uppercased() ?? defaultMethod
        guard HTTPHeader.isValidName(method) else {
            return Self.rejected("NaiveFlow.http: invalid method token", in: context)
        }
        request.httpMethod = method
        if let headersValue = options?.objectForKeyedSubscript("headers"), !headersValue.isUndefined, !headersValue.isNull {
            for header in Self.requestHeadersFromValue(headersValue, in: context) {
                request.addValue(header.value, forHTTPHeaderField: header.name)
            }
        }
        if let bodyValue = options?.objectForKeyedSubscript("body"), !bodyValue.isUndefined, !bodyValue.isNull {
            request.httpBody = Self.bytesFromValue(bodyValue, in: context) ?? Data()
        }
        var timeout = Self.httpDefaultTimeout
        if let timeoutValue = options?.objectForKeyedSubscript("timeout"), timeoutValue.isNumber {
            let timeoutMilliseconds = timeoutValue.toDouble()
            if timeoutMilliseconds.isFinite, timeoutMilliseconds > 0 { timeout = min(timeoutMilliseconds / 1000.0, Self.httpMaxTimeout) }
        }
        request.timeoutInterval = timeout
        let followRedirects = (options?.objectForKeyedSubscript("redirect"))
            .flatMap { $0.isString ? $0.toString() : nil } != "manual"
        let insecure: Bool
        if let insecureValue = options?.objectForKeyedSubscript("insecure"), insecureValue.isBoolean {
            insecure = insecureValue.toBool()
        } else {
            insecure = AWCore.getAllowInsecure()
        }

        let maxBytes = Self.httpMaxResponseBytes

        let promise = JSValue(newPromiseIn: context, fromExecutor: { [weak self, weak run] resolve, reject in
            guard let self, let run else {
                reject?.call(withArguments: [Self.error("NaiveFlow.http: invocation released", in: context)])
                return
            }
            self.assumeIsolated { engine in
                run.inFlightFetches += 1
                run.totalFetches += 1
                Self.reserveGlobalFetchSlot()
                let runID = run.id
                let fetchID = run.claimFetchID()
                let task = Task { [request] in
                    let result: Result<MITMScriptHTTPClient.Response, Error>
                    do {
                        let response = try await MITMScriptHTTPClient.shared.send(
                            request,
                            followRedirects: followRedirects,
                            insecure: insecure,
                            maxBytes: maxBytes,
                            resourceTimeout: Self.invocationIdleTimeout
                        )
                        result = .success(response)
                    } catch {
                        result = .failure(error)
                    }
                    engine.completeFetch(runID: runID, fetchID: fetchID, result: result)
                }
                run.pendingFetches[fetchID] = PendingFetch(resolve: resolve, reject: reject, task: task)
            }
        })
        return promise ?? Self.rejected("NaiveFlow.http: could not create Promise", in: context)
    }

    private func completeFetch(
        runID: UInt64,
        fetchID: Int,
        result: Result<MITMScriptHTTPClient.Response, Error>
    ) {
        Self.releaseGlobalFetchSlot()
        guard let run = liveRuns[runID],
              let pending = run.pendingFetches.removeValue(forKey: fetchID) else { return }
        resumeFetch(run: run, resolve: pending.resolve, reject: pending.reject, result: result)
    }

    private func resumeFetch(
        run: ScriptRun,
        resolve: JSValue?,
        reject: JSValue?,
        result: Result<MITMScriptHTTPClient.Response, Error>
    ) {
        if run.inFlightFetches > 0 { run.inFlightFetches -= 1 }
        guard !run.isDelivered else { return }
        if MonotonicClock.now - run.startedAt > Self.invocationAbsoluteTimeout,
           let original = run.original {
            logger.warning("\(run.logPrefix): HTTP script timed out")
            deliver(.modified(original), for: run)
            return
        }
        armWatchdog(for: run)
        let context = run.context
        _ = runUserScript("async script (NaiveFlow.http resume continuation)") {
            switch result {
            case .success(let response):
                // JS can retain every fetch result until the invocation ends.
                guard run.memoryReservation.add(response.body.count * 3) else {
                    reject?.call(withArguments: [Self.error("NaiveFlow.http: shared memory budget exceeded", in: context)])
                    return
                }
                resolve?.call(withArguments: [Self.makeHTTPResponse(response, in: context)])
            case .failure(let error):
                reject?.call(withArguments: [Self.error("NaiveFlow.http: \(NaiveFlowError.describe(error))", in: context)])
            }
        }
        if context.exception != nil { context.exception = nil }
    }

    // MARK: NaiveFlow.http helpers

    private static func error(_ message: String, in context: JSContext) -> JSValue {
        JSValue(newErrorFromMessage: message, in: context) ?? JSValue(newObjectIn: context)!
    }

    private static func rejected(_ message: String, in context: JSContext) -> JSValue {
        JSValue(newPromiseRejectedWithReason: error(message, in: context) as Any, in: context) ?? JSValue(undefinedIn: context)
    }

    private static func makeHTTPResponse(_ response: MITMScriptHTTPClient.Response, in context: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: context)!
        object.setObject(response.status, forKeyedSubscript: "status" as NSString)
        let pairs: [[String]] = response.headers.map { [$0.name, $0.value] }
        object.setObject(pairs, forKeyedSubscript: "headers" as NSString)
        object.setObject(makeUint8Array(in: context, from: response.body), forKeyedSubscript: "body" as NSString)
        object.setObject(response.finalURL as Any, forKeyedSubscript: "url" as NSString)
        return object
    }

    private static func requestHeadersFromValue(_ value: JSValue, in context: JSContext) -> [(name: String, value: String)] {
        if value.isArray {
            return (headersFromValue(value) ?? []).filter { entry in
                guard !Self.forbiddenRequestHeaders.contains(entry.name.lowercased()) else {
                    logger.warning("[Script] NaiveFlow.http: Forbidden header: \(entry.name)")
                    return false
                }
                return true
            }
        }
        guard value.isObject,
              let keys = context.objectForKeyedSubscript("Object")?.invokeMethod("keys", withArguments: [value]),
              keys.isArray
        else { return [] }
        guard let length = Self.validatedArrayLength(keys, maxLength: 100_000) else { return [] }
        var out: [(name: String, value: String)] = []
        out.reserveCapacity(length)
        for index in 0..<length {
            guard let keyValue = keys.objectAtIndexedSubscript(index), let name = keyValue.toString(),
                  let valueElement = value.objectForKeyedSubscript(name), !valueElement.isUndefined, !valueElement.isNull,
                  let value = valueElement.toString()
            else { continue }
            guard HTTPHeader.isValidName(name) else {
                logger.warning("[Script] NaiveFlow.http: Invalid header name: \(name)")
                continue
            }
            guard HTTPHeader.isValidValue(value) else {
                logger.warning("[Script] NaiveFlow.http: Invalid header value: \(name)")
                continue
            }
            guard !Self.forbiddenRequestHeaders.contains(name.lowercased()) else {
                logger.warning("[Script] NaiveFlow.http: Forbidden header: \(name)")
                continue
            }
            out.append((name: name, value: value))
        }
        return out
    }

    private static let forbiddenRequestHeaders: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding",
        "upgrade", "keep-alive", "te", "trailer", "expect", "proxy-connection",
    ]

    // MARK: Global NaiveFlow.http in-flight counter

    private static func reserveGlobalFetchSlot() {
        mitmScriptGlobalFetchCount.wrappingAdd(1, ordering: .relaxed)
    }
    private static func releaseGlobalFetchSlot() {
        var current = mitmScriptGlobalFetchCount.load(ordering: .relaxed)
        while current > 0 {
            let (exchanged, original) = mitmScriptGlobalFetchCount.weakCompareExchange(
                expected: current, desired: current - 1, ordering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }
    private static func globalFetchCount() -> Int {
        mitmScriptGlobalFetchCount.load(ordering: .relaxed)
    }

    // MARK: - Body bridging

    private static func makeUint8Array(in context: JSContext, from data: Data) -> JSValue {
        let count = data.count
        let contextRef = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(contextRef, kJSTypedArrayTypeUint8Array, count, &exception),
              exception == nil else {
            return JSValue(undefinedIn: context)
        }
        if count > 0 {
            guard let pointer = JSObjectGetTypedArrayBytesPtr(contextRef, object, &exception), exception == nil else {
                return JSValue(undefinedIn: context)
            }
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: count)
        }
        return JSValue(jsValueRef: object, in: context)
    }

    private static func bytesFromValue(_ value: JSValue, in context: JSContext) -> Data? {
        if value.isNull || value.isUndefined { return nil }
        if value.isString {
            return value.toString().map { Data($0.utf8) }
        }
        return typedArrayBytesFromValue(value, in: context)
    }

    private static func typedArrayBytesFromValue(_ value: JSValue, in context: JSContext) -> Data? {
        if value.isNull || value.isUndefined { return nil }
        let contextRef = context.jsGlobalContextRef
        guard let ref = value.jsValueRef else { return nil }
        var exception: JSValueRef?
        let kind = JSValueGetTypedArrayType(contextRef, ref, &exception)
        if exception != nil { return nil }
        if kind == kJSTypedArrayTypeNone { return nil }
        guard let object = JSValueToObject(contextRef, ref, &exception), exception == nil else {
            return nil
        }
        if kind == kJSTypedArrayTypeArrayBuffer {
            let length = JSObjectGetArrayBufferByteLength(contextRef, object, &exception)
            guard exception == nil,
                  let pointer = JSObjectGetArrayBufferBytesPtr(contextRef, object, &exception),
                  exception == nil
            else { return nil }
            return Data(bytes: pointer, count: length)
        }
        let length = JSObjectGetTypedArrayByteLength(contextRef, object, &exception)
        guard exception == nil else { return nil }
        let offset = JSObjectGetTypedArrayByteOffset(contextRef, object, &exception)
        guard exception == nil,
              let pointer = JSObjectGetTypedArrayBytesPtr(contextRef, object, &exception),
              exception == nil
        else { return nil }
        return Data(bytes: pointer + offset, count: length)
    }


}

extension MITMScriptEngine {
    static let shared = MITMScriptEngine()

    static func setRuleSetNames(_ names: [UUID: String]) {
        mitmScriptRuleSetNames.withLock { $0 = names }
    }

    static func purgeRuns(activeIDs: Set<UUID>) {
        JSCConcurrencyBridge.shared.enqueue {
            shared.assumeIsolated { $0.dropRuns(notIn: activeIDs) }
        }
    }
}
