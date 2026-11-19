import Foundation
import Security

guard CommandLine.arguments.count == 2,
      let password = ProcessInfo.processInfo.environment["PHOTOS_BACKUP_SIGNING_P12_PASSWORD"],
      !password.isEmpty else {
    fputs("Signing identity input is not configured.\n", stderr)
    exit(2)
}

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let options = [kSecImportExportPassphrase as String: password] as CFDictionary
    var rawItems: CFArray?
    let status = SecPKCS12Import(data as CFData, options, &rawItems)
    guard status == errSecSuccess,
          let items = rawItems as? [[String: Any]],
          let item = items.first,
          item[kSecImportItemIdentity as String] != nil,
          item[kSecImportItemLabel as String] as? String == "Photos Backup Release Signing" else {
        fputs("Could not import the expected Photos Backup signing identity.\n", stderr)
        exit(1)
    }
    print("Signing identity imported into the default keychain.")
} catch {
    fputs("Could not read the signing identity file.\n", stderr)
    exit(1)
}
