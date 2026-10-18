import AtemProxyKit
import Foundation

// Headless runner, for a Mac mini in a rack or for debugging.
//
//   atem-proxy <atem-ip> [--listen <local-ip>] [--port <port>] [--name <name>]
//   atem-proxy --config proxies.json      (a JSON array of ProxyConfiguration)

let usage = """
usage: atem-proxy <atem-ip> [--listen <local-ip>] [--port <port>] [--name <name>] [--no-bonjour]
       atem-proxy --config <proxies.json>
"""

func parseArguments() -> [ProxyConfiguration] {
    var args = Array(CommandLine.arguments.dropFirst())
    func value(after flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    if let path = value(after: "--config") {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode([ProxyConfiguration].self, from: data)
        } catch {
            FileHandle.standardError.write(Data("Can't read \(path): \(error)\n".utf8))
            exit(1)
        }
    }

    let listen = value(after: "--listen")
    let port = value(after: "--port").flatMap(UInt16.init) ?? IPv4Endpoint.atemPort
    let name = value(after: "--name")
    let advertise = !args.contains("--no-bonjour")
    args.removeAll { $0 == "--no-bonjour" }
    guard let host = args.first, !host.hasPrefix("-") else {
        print(usage)
        exit(args.contains("--help") ? 0 : 1)
    }
    return [ProxyConfiguration(name: name ?? "ATEM \(host)", atemHost: host, listenIP: listen,
                               listenPort: port, advertise: advertise)]
}

let configurations = parseArguments()
for config in configurations {
    let errors = config.validationErrors(among: configurations)
    if !errors.isEmpty {
        FileHandle.standardError.write(Data("\(config.name): \(errors.joined(separator: " "))\n".utf8))
        exit(1)
    }
}

let proxies = configurations.map(ProxyInstance.init)
for proxy in proxies {
    let name = proxy.configuration.name
    proxy.onLog = { entry in
        guard entry.level != .debug else { return }
        print("\(entry.date.formatted(date: .omitted, time: .standard)) [\(name)] \(entry.level.rawValue.uppercased()) \(entry.message)")
    }
    proxy.start()
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    proxies.forEach { $0.stopAndWait() }
    exit(0)
}
sigint.resume()
RunLoop.main.run()
