import MusicSources
import StarryCore
import SwiftUI

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    @MainActor
    static func run(_ operation: @MainActor () async throws -> Value) async -> Loadable<Value> {
        do {
            return .loaded(try await operation())
        } catch {
            return .failed(ErrorText.describe(error))
        }
    }
}

enum ErrorText {
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as PlaybackError:
            switch e {
            case .vipRequired: "该歌曲需要 VIP，或未登录"
            case .loginExpired: "登录已过期，请重新登录"
            case .unavailableInRegion: "该歌曲在当前地区不可用，可在设置的音乐平台页填写代理"
            case .sourceUnreachable: "无法连接到音乐来源"
            case .assetExpired: "播放地址已失效"
            case .trialOnly: "只有试听片段"
            case .decodeFailed(let s): "解码失败：\(s)"
            case .notImplemented(let s): "尚未实现：\(s)"
            case .unknown(let s): s
            }
        case let e as SourceError:
            switch e {
            case .notRegistered: "来源未注册"
            case .capabilityMissing(let s): "当前来源不支持\(s)"
            case .notImplemented(let s): "尚未实现：\(s)"
            case .invalidResponse(let s): "响应异常：\(s)"
            case .network(let s): "网络错误：\(s)"
            }
        case let e as UserSourceError:
            switch e {
            case .rankingHidden: "对方没有公开听歌排行"
            case .followsHidden: "对方没有公开关注和粉丝"
            }
        case is CancellationError:
            "已取消"
        default:
            error.localizedDescription
        }
    }
}

struct AsyncContent<Value, Content: View>: View {
    var state: Loadable<Value>
    var retry: (() -> Void)? = nil
    @ViewBuilder var content: (Value) -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("加载中…").font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .failed(let message):
            VStack(spacing: 14) {
                StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message)
                    .frame(minHeight: 0)
                if let retry {
                    PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary, action: retry)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .loaded(let value):
            content(value)
        }
    }
}
