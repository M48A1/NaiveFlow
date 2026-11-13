import Foundation
import JavaScriptCore
import zlib

/// Common data and Web API adapters used by the actual MITM JavaScript context.
nonisolated enum ForeignScriptContext {
    static let timeoutPrefix = "// naiveflow-module-timeout: "
    static let sourceMarker = "\n// downloaded-module-source\n"

    static func bytes(_ value: JSValue, in context: JSContext) -> Data? {
        if value.isUndefined || value.isNull { return nil }
        if value.isString { return value.toString().map { Data($0.utf8) } }
        guard let ref = value.jsValueRef else { return nil }
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        let kind = JSValueGetTypedArrayType(ctx, ref, &exception)
        guard exception == nil, kind != kJSTypedArrayTypeNone,
              let object = JSValueToObject(ctx, ref, &exception), exception == nil else { return nil }
        let length: Int
        let pointer: UnsafeMutableRawPointer?
        if kind == kJSTypedArrayTypeArrayBuffer {
            length = JSObjectGetArrayBufferByteLength(ctx, object, &exception)
            pointer = JSObjectGetArrayBufferBytesPtr(ctx, object, &exception)
        } else {
            length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
            let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
            pointer = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception)?.advanced(by: offset)
        }
        guard exception == nil, length <= 8 * 1024 * 1024 else { return nil }
        if length == 0 { return Data() }
        guard let pointer else { return nil }
        return Data(bytes: pointer, count: length)
    }

    /// Quantumult X can return binary edits solely as bodyBytes (ArrayBuffer).
    static func resultBody(_ value: JSValue, in context: JSContext) -> Data? {
        if let raw = value.objectForKeyedSubscript("body"), let data = bytes(raw, in: context) { return data }
        if let raw = value.objectForKeyedSubscript("bodyBytes") { return bytes(raw, in: context) }
        return nil
    }

    static func uint8Array(_ data: Data, in context: JSContext) -> JSValue {
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, data.count, &exception), exception == nil else {
            return JSValue(undefinedIn: context)
        }
        if !data.isEmpty, let pointer = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, object, &exception), exception == nil {
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        return JSValue(jsValueRef: object, in: context)
    }

    static func headers(_ value: JSValue) -> [(name: String, value: String)]? {
        guard value.isObject, !value.isNull, !value.isUndefined else { return nil }
        if value.isArray, let array = value.toArray() {
            var result: [(name: String, value: String)] = []
            for item in array {
                if let pair = item as? [String], pair.count == 2 { result.append((pair[0], pair[1])) }
                else if let pair = item as? [String: String], let name = pair["field"], let fieldValue = pair["value"] { result.append((name, fieldValue)) }
                else { return nil }
            }
            return result.allSatisfy(validHeader) ? result : nil
        }
        guard let dictionary = value.toDictionary() as? [String: Any], dictionary.count <= 4096 else { return nil }
        var result: [(name: String, value: String)] = []
        for (name, raw) in dictionary {
            let values = (raw as? [String]) ?? [String(describing: raw)]
            for fieldValue in values { result.append((name, fieldValue)) }
        }
        return result.allSatisfy(validHeader) ? result : nil
    }

    private static func validHeader(_ pair: (name: String, value: String)) -> Bool {
        !pair.name.isEmpty && pair.name.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        } && !pair.value.contains("\r") && !pair.value.contains("\n")
    }

    static func status(_ value: JSValue?) -> Int? {
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        let number: Int?
        if value.isNumber { number = Int(exactly: value.toDouble()) }
        else { number = value.toString()?.split(separator: " ").compactMap { Int($0) }.first }
        return number.flatMap { (100...599).contains($0) ? $0 : nil }
    }

    static func install(in context: JSContext, log: @escaping @Sendable (String) -> Void) {
        let logBlock: @convention(block) (String) -> Void = { log($0) }
        context.setObject(logBlock, forKeyedSubscript: "__foreignLog" as NSString)
        let encode: @convention(block) (String) -> JSValue = { value in
            uint8Array(Data(value.utf8), in: JSContext.current()!)
        }
        let decode: @convention(block) (JSValue, Bool) -> JSValue = { value, fatal in
            let ctx = JSContext.current()!
            guard let data = bytes(value, in: ctx) else { return JSValue(object: "", in: ctx) }
            if fatal, String(data: data, encoding: .utf8) == nil {
                ctx.exception = JSValue(newErrorFromMessage: "Invalid UTF-8", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            return JSValue(object: String(decoding: data, as: UTF8.self), in: ctx)
        }
        let atob: @convention(block) (String) -> String = { encoded in
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
        let btoa: @convention(block) (String) -> String = { string in
            Data(string.utf16.compactMap { UInt8(exactly: $0) }).base64EncodedString()
        }
        let parseURL: @convention(block) (String, String) -> [String: String] = { raw, base in
            guard let url = URL(string: raw, relativeTo: URL(string: base))?.absoluteURL,
                  let c = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = c.scheme, let host = c.host else { return [:] }
            let port = c.port.map(String.init) ?? ""
            return ["protocol": scheme + ":", "hostname": host, "port": port,
                    "pathname": c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath,
                    "search": c.percentEncodedQuery.map { "?" + $0 } ?? "", "hash": c.percentEncodedFragment.map { "#" + $0 } ?? "",
                    "username": c.user ?? "", "password": c.password ?? ""]
        }
        let ungzip: @convention(block) (JSValue) -> JSValue = { value in
            let ctx = JSContext.current()!
            guard let data = bytes(value, in: ctx), let inflated = inflateGzip(data) else {
                ctx.exception = JSValue(newErrorFromMessage: "Invalid or oversized gzip data", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            return uint8Array(inflated, in: ctx)
        }
        context.setObject(encode, forKeyedSubscript: "__foreignEncode" as NSString)
        context.setObject(decode, forKeyedSubscript: "__foreignDecode" as NSString)
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
        context.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        context.setObject(parseURL, forKeyedSubscript: "__foreignURL" as NSString)
        let utils = JSValue(newObjectIn: context)!
        utils.setObject(ungzip, forKeyedSubscript: "ungzip" as NSString)
        context.setObject(utils, forKeyedSubscript: "$utils" as NSString)
        context.evaluateScript(webAdapters)
    }

    private static func inflateGzip(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: 8 * 1024 * 1024)
        let result = output.withUnsafeMutableBytes { target in
            input.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(source.count)
                stream.next_out = target.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(target.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    private static let webAdapters = #"""
    globalThis.console = Object.fromEntries(['log','info','warn','error','debug'].map(k=>[k,(...a)=>__foreignLog(a.map(v=>typeof v==='string'?v:JSON.stringify(v)).join(' '))]));
    globalThis.TextEncoder = class TextEncoder { encode(s='') { return __foreignEncode(String(s)); } };
    globalThis.TextDecoder = class TextDecoder { constructor(label='utf-8',options={}) { this.fatal=!!options.fatal; } decode(value=new Uint8Array()) { return __foreignDecode(value,this.fatal); } };
    globalThis.URLSearchParams = class URLSearchParams {
      constructor(value='') { this.pairs=typeof value==='string'?value.replace(/^\?/,'').split('&').filter(Boolean).map(s=>{let i=s.indexOf('=');return [i<0?s:s.slice(0,i),i<0?'':s.slice(i+1)].map(x=>decodeURIComponent(x.replace(/\+/g,' ')));}):Array.isArray(value)?value.map(p=>p.map(String)):Object.entries(value); }
      append(k,v){this.pairs.push([String(k),String(v)]);}
      delete(k){this.pairs=this.pairs.filter(p=>p[0]!==String(k));}
      get(k){return this.pairs.find(p=>p[0]===String(k))?.[1]??null;}
      getAll(k){return this.pairs.filter(p=>p[0]===String(k)).map(p=>p[1]);}
      has(k){return this.pairs.some(p=>p[0]===String(k));}
      set(k,v){this.delete(k);this.append(k,v);}
      *keys(){for(const p of this.pairs)yield p[0];}
      *values(){for(const p of this.pairs)yield p[1];}
      *entries(){yield* this.pairs;}
      [Symbol.iterator](){return this.entries();}
      forEach(fn){for(const [k,v] of this.pairs)fn(v,k,this);}
      toString(){return this.pairs.map(p=>p.map(x=>encodeURIComponent(x).replace(/%20/g,'+')).join('=')).join('&');}
    };
    globalThis.URL = class URL {
      constructor(value,base=''){const c=__foreignURL(String(value),String(base));if(!c.protocol)throw new TypeError('Invalid URL');Object.assign(this,c);this._params=new URLSearchParams(c.search);}
      get searchParams(){return this._params;}
      get search(){const q=this._params?.toString();return q?'?'+q:'';}
      set search(q){this._params=new URLSearchParams(q);}
      get host(){return this.hostname+(this.port?':'+this.port:'');}
      get origin(){return this.protocol+'//'+this.host;}
      get href(){return this.protocol+'//'+(this.username?this.username+(this.password?':'+this.password:'')+'@':'')+this.host+this.pathname+this.search+this.hash;}
      toString(){return this.href;} toJSON(){return this.href;}
    };
    """#
}
