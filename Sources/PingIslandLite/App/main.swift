import AppKit
import Foundation

// MARK: - AgentBeacon 入口
//
// 这是一个 NSApplication 的命令行启动入口。我们刻意不使用 @main 属性
// 而是显式 main()，便于以后接入 LSUIElement.plist 而不影响行为。
//
// 之所以选择 SPM executable 而不是 Xcode 工程：
// - 在没有 Xcode GUI 的环境下也能 swift build / swift run；
// - 老 Mac 用户拿到源码后可以一行命令运行；
// - 后续接 Sparkle 时再补 .app 打包脚本。
//
// 关键决策：
// - LSUIElement = true 等价配置：我们手动设置 NSApp.setActivationPolicy(.accessory)，
//   让 App 在 Dock 不显示图标，只活在菜单栏。

// MARK: - CLI flags（开发期工具）
//
// 所有 hook 相关 CLI 分支必须在 NSApplication.shared 之前处理：
// AppKit 初始化后会 transformProcessType 进入 GUI 上下文，
// 之后写非标准 home 下的文件会被拒（NSCocoaErrorDomain 513）。
let args = CommandLine.arguments

// --home <dir>：把 HookInstaller 的虚拟 HOME 指向某个路径，
// 用 CLI 验证安装逻辑而不动用户真实配置。
if let homeIdx = args.firstIndex(of: "--home"),
   args.indices.contains(homeIdx + 1) {
    let dir = args[homeIdx + 1]
    let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    HookInstaller.homeOverride = url
}

// --smoke-hooks <dir>：串跑 17 家 install→status→uninstall→status 冒烟。
if let smokeIdx = args.firstIndex(of: "--smoke-hooks"),
   args.indices.contains(smokeIdx + 1) {
    let dir = args[smokeIdx + 1]
    let homeURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    HookInstaller.homeOverride = homeURL

    var failures: [String] = []
    for provider in HookInstaller.Provider.allCases {
        let name = provider.displayName
        let path = HookInstaller.settingsURL(for: provider).path
        do {
            let bridge = try HookInstaller.install(provider)
            let afterInstall = HookInstaller.status(provider)
            guard case .installed = afterInstall else {
                failures.append("\(name): install OK but status=\(afterInstall) (bridge=\(bridge), path=\(path))")
                continue
            }
            try HookInstaller.uninstall(provider)
            let afterUninstall = HookInstaller.status(provider)
            switch afterUninstall {
            case .notInstalled:
                print("✅ \(name) install/uninstall OK (\(path))")
            default:
                failures.append("\(name): uninstall left status=\(afterUninstall) at \(path)")
            }
        } catch {
            failures.append("\(name): \(error)")
        }
    }

    if failures.isEmpty {
        print("\n🎉 17 家全通过，home=\(homeURL.path)")
        exit(0)
    } else {
        print("\n❌ \(failures.count) 个失败：")
        for f in failures { print("  - \(f)") }
        exit(1)
    }
}

// --install-hooks <provider>：单家安装。配合 --home 使用更安全。
if let installIdx = args.firstIndex(of: "--install-hooks"),
   args.indices.contains(installIdx + 1) {
    let providerName = args[installIdx + 1]
    guard let provider = HookInstaller.Provider(rawValue: providerName) else {
        let providerList = HookInstaller.Provider.allCases.map(\.rawValue).joined(separator: ", ")
        FileHandle.standardError.write(Data("未知 provider: \(providerName)\n可选：\(providerList)\n".utf8))
        exit(2)
    }
    do {
        let bridgePath = try HookInstaller.install(provider)
        print("✅ 已安装 \(provider.displayName) hooks")
        print("   bridge: \(bridgePath)")
        print("   config: \(HookInstaller.settingsURL(for: provider).path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("❌ 安装失败：\(error)\n".utf8))
        exit(1)
    }
}

// --uninstall-hooks <provider>：单家卸载。
if let uninstallIdx = args.firstIndex(of: "--uninstall-hooks"),
   args.indices.contains(uninstallIdx + 1) {
    let providerName = args[uninstallIdx + 1]
    guard let provider = HookInstaller.Provider(rawValue: providerName) else {
        FileHandle.standardError.write(Data("未知 provider: \(providerName)\n".utf8))
        exit(2)
    }
    do {
        try HookInstaller.uninstall(provider)
        print("✅ 已卸载 \(provider.displayName) hooks")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("❌ 卸载失败：\(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
