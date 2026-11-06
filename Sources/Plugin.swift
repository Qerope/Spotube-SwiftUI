import Foundation
import JavaScriptCore
import Observation
import CryptoKit
import WebKit

/// Plugin = one JS file defining `const plugin = { name, version, author, abilities: [...], ... }`. See README.
@MainActor final class JSPlugin: Identifiable {
    let id: String, name: String, version: String, abilities: [String], file: URL
    private let ctx = JSContext()!

    init(file: URL) throws {
        self.file = file
        let src = try String(contentsOf: file, encoding: .utf8)
        ctx.exceptionHandler = { _, e in print("[plugin]", e?.toString() ?? "") }
        let fetch: @convention(block) (String, String, JSValue) -> Void = { url, opts, cb in
            guard let u = URL(string: url) else { cb.call(withArguments: [0, "", "bad url"]); return }
            var r = URLRequest(url: u)
            let o = (try? JSONSerialization.jsonObject(with: Data(opts.utf8))) as? [String: Any] ?? [:]
            r.httpMethod = o["method"] as? String ?? "GET"
            (o["headers"] as? [String: String])?.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            if let b = o["body"] as? String { r.httpBody = Data(b.utf8) }
            if r.value(forHTTPHeaderField: "Cookie") != nil { r.httpShouldHandleCookies = false }
            URLSession.shared.dataTask(with: r) { d, resp, err in
                let s = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let body = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async { cb.call(withArguments: [s, body, err?.localizedDescription ?? NSNull()]) }
            }.resume()
        }
        let pid = file.deletingPathExtension().lastPathComponent
        let get: @convention(block) (String) -> Any = { UserDefaults.standard.string(forKey: "pl.\(pid).\($0)").flatMap { $0.isEmpty ? nil : $0 } ?? NSNull() }
        let set: @convention(block) (String, String) -> Void = { UserDefaults.standard.set($1, forKey: "pl.\(pid).\($0)") }
        let hmac: @convention(block) (String, String, String) -> String = { algo, k, d in
            let key = SymmetricKey(data: Data(hex: k)), msg = Data(hex: d)
            switch algo {
            case "sha256": return Data(HMAC<SHA256>.authenticationCode(for: msg, using: key)).hex
            case "sha512": return Data(HMAC<SHA512>.authenticationCode(for: msg, using: key)).hex
            default: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key)).hex
            }
        }
        let cookie: @convention(block) (String, String, JSValue) -> Void = { url, name, cb in
            Task { @MainActor in
                do { cb.call(withArguments: [try await WebLogin.shared.cookie(url: url, name: name), NSNull()]) }
                catch { cb.call(withArguments: [NSNull(), error.localizedDescription]) }
            }
        }
        ctx.setObject(hmac, forKeyedSubscript: "__hmac" as NSString)
        ctx.setObject(cookie, forKeyedSubscript: "__cookie" as NSString)
        ctx.setObject(fetch, forKeyedSubscript: "__fetch" as NSString)
        ctx.setObject(get, forKeyedSubscript: "__lsGet" as NSString)
        ctx.setObject(set, forKeyedSubscript: "__lsSet" as NSString)
        ctx.evaluateScript("""
        globalThis.console={log:(...a)=>{}};
        globalThis.fetch=(u,o={})=>new Promise((res,rej)=>__fetch(String(u),JSON.stringify(o),(s,b,e)=>e?rej(new Error(e)):res({status:s,ok:s<400,text:async()=>b,json:async()=>JSON.parse(b)})));
        globalThis.localStorage={getItem:k=>__lsGet(k),setItem:(k,v)=>__lsSet(k,String(v)),removeItem:k=>__lsSet(k,"")};
        globalThis.crypto={hmac:(a,kHex,dHex)=>__hmac(a,kHex,dHex)};
        globalThis.webview={cookie:(u,n)=>new Promise((res,rej)=>__cookie(u,n,(v,e)=>e?rej(new Error(e)):res(v)))};
        """)
        ctx.evaluateScript(src + "\n;globalThis.plugin=plugin;")
        ctx.evaluateScript("globalThis.__call=(n,a,cb)=>Promise.resolve().then(()=>plugin[n](...JSON.parse(a))).then(r=>cb(JSON.stringify(r??null),null),e=>cb(null,String(e)));")
        guard let p = ctx.objectForKeyedSubscript("plugin"), !p.isUndefined else { throw URLError(.cannotParseResponse) }
        id = pid
        name = p.forProperty("name").toString()
        version = p.forProperty("version").isUndefined ? "?" : p.forProperty("version").toString()
        abilities = p.forProperty("abilities").toArray() as? [String] ?? []
    }

    func has(_ fn: String) -> Bool { ctx.evaluateScript("typeof plugin.\(fn)==='function'").toBool() }

    func call<T: Decodable>(_ fn: String, _ args: [Any] = []) async throws -> T {
        let a = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let json: String = try await withCheckedThrowingContinuation { c in
            let cb: @convention(block) (JSValue, JSValue) -> Void = { r, e in
                if !e.isNull { c.resume(throwing: NSError(domain: self.name, code: 1, userInfo: [NSLocalizedDescriptionKey: e.toString()!])) }
                else { c.resume(returning: r.toString()) }
            }
            ctx.objectForKeyedSubscript("__call").call(withArguments: [fn, a, unsafeBitCast(cb, to: AnyObject.self)])
        }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

@MainActor @Observable final class PluginManager {
    var plugins: [JSPlugin] = []
    var metadataID = UserDefaults.standard.string(forKey: "metaPlugin") { didSet { UserDefaults.standard.set(metadataID, forKey: "metaPlugin") } }
    var audioID = UserDefaults.standard.string(forKey: "audioPlugin") { didSet { UserDefaults.standard.set(audioID, forKey: "audioPlugin") } }
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Plugins")

    var metadata: JSPlugin? { plugins.first { $0.id == metadataID } ?? plugins.first { $0.abilities.contains("metadata") } }
    var audio: JSPlugin? { plugins.first { $0.id == audioID } ?? plugins.first { $0.abilities.contains("audio") } }

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: nil) ?? [] {
            let dst = dir.appending(path: f.lastPathComponent)
            try? FileManager.default.removeItem(at: dst); try? FileManager.default.copyItem(at: f, to: dst)
        }
        reload()
    }

    func reload() {
        plugins = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "js" }.sorted { $0.path < $1.path }.compactMap { try? JSPlugin(file: $0) }
    }

    func install(from url: URL) async throws {
        let data: Data
        if url.isFileURL { _ = url.startAccessingSecurityScopedResource(); defer { url.stopAccessingSecurityScopedResource() }; data = try Data(contentsOf: url) }
        else { data = try await URLSession.shared.data(from: url).0 }
        try data.write(to: dir.appending(path: url.deletingPathExtension().lastPathComponent + ".js"))
        reload()
    }

    func remove(_ p: JSPlugin) { try? FileManager.default.removeItem(at: p.file); reload() }
}

extension Data {
    init(hex: String) {
        var d = Data(), i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < j { d.append(UInt8(hex[i..<j], radix: 16) ?? 0); i = j }
        self = d
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Native webview used by plugins for login: opens `url`, resolves once cookie `name` appears.
@MainActor @Observable final class WebLogin: NSObject, WKNavigationDelegate {
    static let shared = WebLogin()
    var url: URL?
    @ObservationIgnored private var name = ""
    @ObservationIgnored private var cont: CheckedContinuation<String, Error>?
    @ObservationIgnored let web = WKWebView(frame: .zero, configuration: { let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); return c }())

    func cookie(url: String, name: String) async throws -> String {
        cont?.resume(throwing: CancellationError())
        self.name = name; web.navigationDelegate = self
        return try await withCheckedThrowingContinuation { c in
            cont = c; self.url = URL(string: url); web.load(URLRequest(url: self.url!))
        }
    }
    func cancel() { url = nil; cont?.resume(throwing: CancellationError()); cont = nil }
    nonisolated func webView(_ w: WKWebView, didFinish _: WKNavigation!) { Task { @MainActor in check() } }
    nonisolated func webView(_ w: WKWebView, didCommit _: WKNavigation!) { Task { @MainActor in check() } }
    private func check() {
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cs in
            Task { @MainActor in
                guard let v = cs.first(where: { $0.name == self.name })?.value, let c = self.cont else { return }
                self.cont = nil; self.url = nil; c.resume(returning: v)
            }
        }
    }
}
