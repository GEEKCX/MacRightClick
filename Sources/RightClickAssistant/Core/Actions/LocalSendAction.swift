import Foundation
import AppKit

/// 通过 LocalSend 直传选中文件。
///
/// 执行路径：
/// 1. 优先使用 `localsend-cli`（Homebrew 安装）在后台直接发起传输：
///    `localsend-cli send [--to <默认设备>] <files...>`。配置了默认设备（IP 或别名）
///    时一键直传，无需任何交互；未配置时不传 `--to`，由 CLI 在交互终端里选设备会失败，
///    因此退回到路径 2。
/// 2. 未安装 CLI 或未配置默认设备时，退化为用 LocalSend.app 打开选中文件，
///    由用户在 App 内选择接收方。
///
/// 默认设备存储在宿主 App 的 UserDefaults（key: `guyue.localSend.target`），
/// 可在「设置 → 通用 → LocalSend 直传」中修改。
public final class LocalSendAction: MenuAction, @unchecked Sendable {
    public static let targetDefaultsKey = "guyue.localSend.target"
    public static let localSendBundleIdentifier = "org.localsend.localsendApp"

    /// LocalSend CLI 的常见安装位置（Homebrew Apple Silicon / Intel）。
    private static let candidateCLIPaths = [
        "/opt/homebrew/bin/localsend-cli",
        "/usr/local/bin/localsend-cli"
    ]

    private static let runner = BackgroundActionRunner(
        actionLabel: "utility.localsend",
        ioQueueLabel: "guyue.RightClickAssistant.localsend-io"
    )

    public let actionId: String
    public let localizedTitle: String
    public let iconName: String?
    public let category: ActionCategory = .utility

    public var associatedBundleIdentifier: String? {
        return Self.localSendBundleIdentifier
    }

    public var tier: ActionTier { .professional }

    public var isEnabledByDefault: Bool { false }

    public init() {
        self.actionId = "guyue.action.utility.localsend"
        self.localizedTitle = "通过 LocalSend 传输"
        self.iconName = "paperplane.fill"
    }

    public func isAvailable(for targetURLs: [URL]) -> Bool {
        guard !targetURLs.isEmpty else { return false }
        // 只要装了 LocalSend 本体就显示；CLI 缺失时退化为打开 App。
        return InstalledAppRegistry.shared.isInstalled(Self.localSendBundleIdentifier)
    }

    public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool {
        // 空白背景右键没有要传的文件，隐藏。
        guard !isContainer else { return false }
        return isAvailable(for: targetURLs)
    }

    public func execute(targetURLs: [URL]) -> Bool {
        return submit(targetURLs: targetURLs, completion: { _ in }) == .accepted
    }

    public func submit(
        targetURLs: [URL],
        completion: @escaping @Sendable (ActionCompletionStatus) -> Void
    ) -> ActionSubmission {
        guard !targetURLs.isEmpty else {
            completion(.failed)
            return .rejected
        }

        let paths = targetURLs.map { $0.path }
        Self.runner.submit({
            self.performSend(paths: paths)
        }, completion: { status in
            DispatchQueue.main.async {
                switch status {
                case .succeeded:
                    SharedHUDManager.show(
                        title: "LocalSend",
                        content: "已通过 LocalSend 发送 \(paths.count) 个项目",
                        isSuccess: true
                    )
                case .failed:
                    SharedHUDManager.show(
                        title: "LocalSend 发送失败",
                        content: "请确认接收设备在线，或检查默认设备配置",
                        isSuccess: false
                    )
                case .cancelled:
                    break
                }
                completion(status)
            }
        })
        return .accepted
    }

    private func performSend(paths: [String]) -> ActionCompletionStatus {
        if let cliPath = Self.resolveCLIPath() {
            return runCLI(cliPath: cliPath, paths: paths)
        }
        return openLocalSendApp(paths: paths)
    }

    /// 依次探测 Homebrew 常见路径与 PATH。
    nonisolated static func resolveCLIPath() -> String? {
        for path in candidateCLIPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["localsend-cli"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard which.terminationStatus == 0 else { return nil }
            let resolved = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved, !resolved.isEmpty,
                  FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
            return resolved
        } catch {
            return nil
        }
    }

    /// `localsend-cli send [--to target] <paths...>`
    private func runCLI(cliPath: String, paths: [String]) -> ActionCompletionStatus {
        let target = UserDefaults.standard.string(forKey: Self.targetDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var args = ["send"]
        if !target.isEmpty {
            args += ["--to", target]
        }
        args += paths

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? .succeeded : .failed
        } catch {
            AppLog.error("LocalSend CLI 启动失败: \(error.localizedDescription)", category: .action)
            return .failed
        }
    }

    /// 兜底：直接以文件路径为启动参数拉起 LocalSend 二进制。
    /// LocalSend 会把传入的路径自动加入「发送」页选中列表（见上游
    /// selected_sending_files_provider.dart 的 LoadSelectionFromArgsAction），
    /// 第二实例还会把参数交接给已运行实例后自行退出，无需用户重启 App。
    private func openLocalSendApp(paths: [String]) -> ActionCompletionStatus {
        let appURL = InstalledAppRegistry.shared.url(for: Self.localSendBundleIdentifier)
            ?? URL(fileURLWithPath: "/Applications/LocalSend.app")
        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/LocalSend")
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            // 极端情况：拿不到二进制，退化为 NSWorkspace 打开文档。
            let urls = paths.map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return .succeeded
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = paths
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // 第二实例交接完即退出；即便 App 冷启动，这里也不阻塞等待传输完成。
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
            }
            return .succeeded
        } catch {
            AppLog.error("拉起 LocalSend.app 失败: \(error.localizedDescription)", category: .action)
            return .failed
        }
    }
}
