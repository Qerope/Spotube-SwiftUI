import Foundation
import JavaScriptCore
import Observation

/// Plugin = one JS file defining `const plugin = { name, version, author, abilities: ["metadata","audio"], ... }`.
/// metadata: search(q) -> [Track], home() -> [Track] (optional) ; audio: stream(track) -> url string
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
            URLSession.shared.dataTask(with: r) { d, resp, err in
                let s = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let body = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async { cb.call(withArguments: [s, body, err?.localizedDescription ?? NSNull()]) }
            }.resume()
        }
        let pid = file.deletingPathExtension().lastPathComponent
        let get: @convention(block) (String) -> Any = { UserDefaults.standard.string(forKey: "pl.\(pid).\($0)") ?? NSNull() }
        let set: @convention(block) (String, String) -> Void = { UserDefaults.standard.set($1, forKey: "pl.\(pid).\($0)") }
        ctx.setObject(fetch, forKeyedSubscript: "__fetch" as NSString)
        ctx.setObject(get, forKeyedSubscript: "__lsGet" as NSString)
        ctx.setObject(set, forKeyedSubscript: "__lsSet" as NSString)
        ctx.evaluateScript("""
        globalThis.console={log:(...a)=>{}};
        globalThis.fetch=(u,o={})=>new Promise((res,rej)=>__fetch(String(u),JSON.stringify(o),(s,b,e)=>e?rej(new Error(e)):res({status:s,ok:s<400,text:async()=>b,json:async()=>JSON.parse(b)})));
        globalThis.localStorage={getItem:k=>__lsGet(k),setItem:(k,v)=>__lsSet(k,String(v))};
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
