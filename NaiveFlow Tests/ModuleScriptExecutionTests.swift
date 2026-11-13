import Foundation
import JavaScriptCore
import Testing
@testable import NaiveFlow

@MainActor
struct ModuleScriptExecutionTests {
    private func execute(_ source: String, dialect: MITMScriptDialect, response: Bool, url: String, body: Data, headers: [String: String] = [:]) throws -> (context: JSContext, result: JSValue) {
        let context = try #require(JSContext())
        ForeignScriptContext.install(in: context, log: { _ in })
        context.setObject(["url": url, "method": "GET", "headers": headers], forKeyedSubscript: "$request" as NSString)
        if response {
            context.setObject(["status": 200, "statusCode": 200, "body": String(decoding: body, as: UTF8.self), "headers": headers] as [String: Any], forKeyedSubscript: "$response" as NSString)
            context.objectForKeyedSubscript("$response")?.setObject(ForeignScriptContext.uint8Array(body, in: context), forKeyedSubscript: "bodyBytes" as NSString)
        } else {
            context.objectForKeyedSubscript("$request")?.setObject(String(decoding: body, as: UTF8.self), forKeyedSubscript: "body" as NSString)
            context.objectForKeyedSubscript("$request")?.setObject(ForeignScriptContext.uint8Array(body, in: context), forKeyedSubscript: "bodyBytes" as NSString)
        }
        context.evaluateScript("""
            globalThis.$script = {startTime:Date.now()/1000};
            globalThis.$done = result => {globalThis.__result=result;globalThis.__completed=true;};
            globalThis.$persistentStore = {read:()=>null,write:()=>true};
            globalThis.$prefs = {valueForKey:()=>null,setValueForKey:()=>true};
            """)
        if dialect == .surge {
            context.setObject(["surge-version": "NaiveFlow"], forKeyedSubscript: "$environment" as NSString)
        } else {
            context.evaluateScript("globalThis.$task = {fetch:()=>Promise.reject(new Error('Unexpected network access'))};")
        }
        context.evaluateScript("(function(){\"use strict\";\n\(source)\n})()")
        context.evaluateScript("void 0")
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        try #require(context.objectForKeyedSubscript("__completed")?.toBool() == true, "The script must call $done")
        return (context, try #require(context.objectForKeyedSubscript("__result")))
    }

    @Test func importedSurgeScriptEditsJSONAndHeadersWithDefaultArguments() async throws {
        let made = try await ModuleOperations.makeModule(from: """
            #!name = JSON example
            #!arguments = RemoveAds:true
            [Script]
            clean = type=http-response, pattern=., requires-body=true, timeout=2.5, script-path=clean.js, argument=RemoveAds={{{RemoveAds}}}
            [MITM]
            hostname = example.com
            """, fallbackName: "Fallback", subscriptionURL: URL(string: "https://example.com/module.sgmodule"), format: .surge,
            fetchResource: { url in
                #expect(url.absoluteString == "https://example.com/clean.js")
                return "const data=JSON.parse($response.body); if($argument==='RemoveAds=true') delete data.ad; $done({body:JSON.stringify(data),headers:{'X-Test':'yes'}});"
            })
        let rule = try #require(made.module.mitmRuleSets.first?.rules.first)
        guard case .script(let encoded, let dialect) = rule.operation else { Issue.record("Missing imported script"); return }
        let source = try #require(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
        #expect(source.hasPrefix(ForeignScriptContext.timeoutPrefix + "2.5\n"))
        let (_, result) = try execute(source, dialect: dialect, response: true, url: "https://example.com/", body: Data(#"{"ad":1,"keep":2}"#.utf8))
        let json = try #require(result.objectForKeyedSubscript("body")?.toString()).data(using: .utf8)!
        #expect(try JSONSerialization.jsonObject(with: json) as? [String: Int] == ["keep": 2])
        #expect(ForeignScriptContext.headers(try #require(result.objectForKeyedSubscript("headers")))?.first?.name == "X-Test")
        #expect(made.module.name == "JSON example")
    }

    @Test(arguments: ModuleFormat.allCases)
    func importedHeaderScriptsCarryHeaderOnlyMetadata(format: ModuleFormat) async throws {
        let config = switch format {
        case .surge:
            "[Script]\nheader = type=http-response, pattern=., script-path=https://example.com/header.js\n[MITM]\nhostname = example.com"
        case .quantumultX:
            ". url script-response-header https://example.com/header.js\nhostname = example.com"
        }
        let made = try await ModuleOperations.makeModule(from: config, fallbackName: "Headers", format: format,
            fetchResource: { _ in "$done({headers:{'X-Test':'yes'}});" })
        let rule = try #require(made.module.mitmRuleSets.first?.rules.first)
        guard case .script(let encoded, _) = rule.operation else {
            Issue.record("Missing imported header script")
            return
        }
        let source = try #require(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
        let marker = try #require(source.range(of: ForeignScriptContext.sourceMarker))
        #expect(source[..<marker.lowerBound].contains(ForeignScriptContext.headerOnlyMarker))
    }

    @Test func binaryBodiesAndQuantumultStringDoneRoundTrip() throws {
        let (ctx, result) = try execute("$done($response.bodyBytes.subarray(1,3));", dialect: .quantumultX, response: true, url: "https://example.com/", body: Data([0, 255, 128, 0]))
        #expect(ForeignScriptContext.bytes(result, in: ctx) == Data([255, 128]))
        let (_, text) = try execute("$done($response.body.replace('ad','ok'));", dialect: .quantumultX, response: true, url: "https://example.com/", body: Data("ad".utf8))
        #expect(text.toString() == "ok")
    }

    @Test func repeatedScriptDownloadsAreCachedAndPersistWithoutDuplication() async throws {
        var calls = 0
        let body = "[Script]\na=type=http-response,pattern=/a,script-path=https://example.com/shared.js,requires-body=true\nb=type=http-response,pattern=/b,script-path=https://example.com/shared.js,requires-body=true\n[MITM]\nhostname=example.com"
        let made = try await ModuleOperations.makeModule(from: body, fallbackName: "Cache", format: .surge, fetchResource: { _ in
            calls += 1
            return String(repeating: "// shared script\n", count: 5000) + "$done({body:'ok'});"
        })
        #expect(calls == 1)
        let data = try JSONEncoder().encode(made.module)
        #expect(data.count < 20_000)
        let restored = try JSONDecoder().decode(Module.self, from: data)
        #expect(restored.id == made.module.id)
        #expect(restored.mitmRuleSets.map { $0.rules.map(\.operation) } == made.module.mitmRuleSets.map { $0.rules.map(\.operation) })
        #expect(restored.mitmRuleSets.map(\.domainSuffixes) == made.module.mitmRuleSets.map(\.domainSuffixes))
    }

    @Test func unsupportedOrBrokenScriptsFailTheWholeImport() async throws {
        await #expect(throws: (any Error).self) {
            try await ModuleOperations.makeModule(from: "[Script]\na=type=cron,script-path=https://example.com/a.js", fallbackName: "Invalid", format: .surge)
        }
        await #expect(throws: (any Error).self) {
            try await ModuleOperations.makeModule(from: "[Script]\na=type=http-response,pattern=.,script-path=https://example.com/a.js\n[MITM]\nhostname=example.com", fallbackName: "Invalid", format: .surge, fetchResource: { _ in "$done({" })
        }
    }

    @Test func mapLocalAndJQDeleteAreImported() async throws {
        let made = try await ModuleOperations.makeModule(from: #"""
            [Map Local]
            ^https://example.com/rpc data-type=base64 data="AAAAAAA=" status-code=200 header="Content-Type:application/grpc|grpc-status:0"
            [Body Rewrite]
            http-response-jq ^https://example.com/json 'del(.data.payment)'
            [MITM]
            hostname = example.com
            """#, fallbackName: "Map", format: .surge)
        let rules = try #require(made.module.mitmRuleSets.first?.rules)
        #expect(rules.count == 2)
        guard case .script(let encoded, _) = rules[0].operation else { Issue.record("Missing response script"); return }
        let source = try #require(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
        let (ctx, result) = try execute(source, dialect: .surge, response: false, url: "https://example.com/rpc", body: Data())
        let response = try #require(result.objectForKeyedSubscript("response"))
        #expect(ForeignScriptContext.bytes(try #require(response.objectForKeyedSubscript("body")), in: ctx) == Data(repeating: 0, count: 5))
        #expect(rules[1].operation == .bodyJSON(.delete(path: "data.payment")))
    }

    @Test func quantumultEchoResponseAndRejectDictionaryPreserveHeadersAndBinary() async throws {
        let made = try await ModuleOperations.makeModule(from: #"""
            ^https://example.com/empty url echo-response application/grpc\r\ngrpc-status: 0 echo-response https://example.com/empty.grpc
            ^https://example.com/ad url reject-dict
            hostname = example.com
            """#, fallbackName: "QX", format: .quantumultX, fetchResource: { _ in String(repeating: "\0", count: 5) })
        let rules = try #require(made.module.mitmRuleSets.first?.rules)
        for (index, rule) in rules.enumerated() {
            guard case .script(let encoded, let dialect) = rule.operation else { Issue.record("Missing response script"); return }
            #expect(dialect == .quantumultX)
            let source = try #require(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
            let (ctx, result) = try execute(source, dialect: dialect, response: false, url: "https://example.com/", body: Data())
            #expect(ForeignScriptContext.status(result.objectForKeyedSubscript("status")) == 200)
            #expect(ForeignScriptContext.resultBody(result, in: ctx) == (index == 0 ? Data(repeating: 0, count: 5) : Data("{}".utf8)))
            let headers = try #require(result.objectForKeyedSubscript("headers"))
            #expect(headers.objectForKeyedSubscript("Content-Type")?.toString() == (index == 0 ? "application/grpc" : "application/json"))
        }
        let ctx = try #require(JSContext())
        let edits = try #require(ctx.evaluateScript("({bodyBytes:new Uint8Array([0,255,128]).buffer})"))
        #expect(ForeignScriptContext.resultBody(edits, in: ctx) == Data([0,255,128]))
        let surgeEdits = try #require(ctx.evaluateScript("({body:new Uint8Array([1,2]),bodyBytes:new Uint8Array([9,9]).buffer})"))
        #expect(ForeignScriptContext.resultBody(surgeEdits, in: ctx) == Data([1,2]))
    }

    /// Download the linked module and its versioned dependencies into /private/tmp
    /// to run this optional real-world fixture alongside deterministic tests.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/private/tmp/BiliBili.ADBlock.sgmodule") && FileManager.default.fileExists(atPath: "/private/tmp/BiliBili.ADBlock.snippet")), arguments: ModuleFormat.allCases)
    func bilibiliReleaseImportsAndExecutesItsActualScripts(format: ModuleFormat) async throws {
        let body = try String(contentsOfFile: "/private/tmp/BiliBili.ADBlock.\(format.fileExtension)", encoding: .utf8)
        var fetched: [String] = []
        let made = try await ModuleOperations.makeModule(from: body, fallbackName: "BiliBili", subscriptionURL: URL(string: "https://github.com/Biliverse/ADBlock/releases/latest/download/BiliBili.ADBlock.\(format.fileExtension)"), format: format, fetchResource: { url in
            fetched.append(url.lastPathComponent)
            let path = ["js", "grpc"].contains(url.pathExtension) ? "/private/tmp/BiliBili-\(url.lastPathComponent)" : "/private/tmp/\(url.lastPathComponent)"
            return try String(contentsOfFile: path, encoding: .utf8)
        })
        let expectedResources: Set<String> = format == .surge
            ? ["request.bundle.js", "response.bundle.js", "BiliBili.ADBlock.boxjs.json"]
            : ["request.bundle.js", "response.bundle.js", "BiliBili.ADBlock.boxjs.json", "empty.grpc"]
        #expect(Set(fetched) == expectedResources)
        #expect(fetched.count == expectedResources.count)
        #expect(made.warnings.isEmpty)
        let data = try JSONEncoder().encode(made.module)
        #expect(data.count < Module.maxEncodedBytes)
        let restored = try JSONDecoder().decode(Module.self, from: data)
        #expect(restored.id == made.module.id)
        #expect(restored.mitmRuleSets.map { $0.rules.map(\.operation) } == made.module.mitmRuleSets.map { $0.rules.map(\.operation) })
        #expect(restored.mitmRuleSets.map(\.domainSuffixes) == made.module.mitmRuleSets.map(\.domainSuffixes))
        let rule = try #require(made.module.mitmRuleSets.first?.rules.first { $0.phase == .httpResponse && $0.urlPattern.contains("splash") })
        guard case .script(let encoded, let dialect) = rule.operation else { Issue.record("Missing actual response script"); return }
        let source = try #require(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
        let input = Data(#"{"code":0,"data":{"show":[{"id":123}],"event_list":[{"id":456}],"keep":"yes"}}"#.utf8)
        let (_, result) = try execute(source, dialect: dialect, response: true, url: "https://app.bilibili.com/x/v2/splash/list", body: input, headers: ["Content-Type": "application/json"])
        let output = try #require(result.objectForKeyedSubscript("body")?.toString())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let outputData = try #require(object["data"] as? [String: Any])
        #expect(outputData["show"] == nil)
        #expect(outputData["event_list"] == nil)
        #expect(outputData["keep"] as? String == "yes")

        let grpcRule = try #require(made.module.mitmRuleSets.first?.rules.first { $0.urlPattern.contains("Teenagers") })
        guard case .script(let grpcEncoded, _) = grpcRule.operation else { Issue.record("Missing binary script"); return }
        let grpcSource = try #require(Data(base64Encoded: grpcEncoded).flatMap { String(data: $0, encoding: .utf8) })
        let name = Array("teenagers".utf8)
        let grpcInput = Data([0,0,0,0,17,10,15,18,9] + name + [42,2,8,1])
        let (grpcContext, grpcResult) = try execute(grpcSource, dialect: dialect, response: true,
            url: "https://grpc.biliapi.net/bilibili.app.interface.v1.Teenagers/ModeStatus", body: grpcInput, headers: ["Content-Type": "application/grpc"])
        #expect(ForeignScriptContext.resultBody(grpcResult, in: grpcContext) == Data([0,0,0,0,15,10,13,18,9] + name + [42,0]))

        if format == .quantumultX {
            #expect(dialect == .quantumultX)
            let echo = try #require(made.module.mitmRuleSets.first?.rules.first { $0.urlPattern.contains("DefaultWords") })
            guard case .script(let echoEncoded, let echoDialect) = echo.operation else { Issue.record("Missing remote echo response"); return }
            #expect(echoDialect == .quantumultX)
            let echoSource = try #require(Data(base64Encoded: echoEncoded).flatMap { String(data: $0, encoding: .utf8) })
            let (echoContext, echoResult) = try execute(echoSource, dialect: .quantumultX, response: false,
                url: "https://grpc.biliapi.net/bilibili.app.interface.v1.Search/DefaultWords", body: Data())
            #expect(ForeignScriptContext.status(echoResult.objectForKeyedSubscript("status")) == 200)
            #expect(ForeignScriptContext.resultBody(echoResult, in: echoContext) == Data(repeating: 0, count: 5))
            let echoHeaders = try #require(echoResult.objectForKeyedSubscript("headers"))
            #expect(echoHeaders.objectForKeyedSubscript("grpc-status")?.toString() == "0")
        }

        let node = ProxyConfiguration(name: "Direct", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
        let bundle = RuntimeConfigurationBundle(id: UUID(), snapshotID: nil, parentID: nil,
            preferences: Dictionary(uniqueKeysWithValues: AWCore.runtimePreferenceKeys.map { ($0, RuntimePreferenceValue.absent) }), nodes: [node], selectedNodeID: node.id, rules: [], finalAction: .direct,
            mitmRuleSets: made.module.mitmRuleSets.map { $0.asMITMRuleSet() }, legacyRouting: nil, legacyMITM: nil)
        try bundle.validate()
    }
}
