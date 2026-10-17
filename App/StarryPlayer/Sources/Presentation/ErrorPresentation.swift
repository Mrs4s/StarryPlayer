import Foundation
import MusicSources
import StarryCore

/// Keep the resource and its typed substitutions until a view chooses its language.
enum ErrorText {
    static func describe(_ error: any Error, locale: Locale = .current) -> String {
        message(error).resolved(locale: locale)
    }

    static func message(_ error: any Error) -> DisplayText {
        switch error {
        case let error as PlaybackError:
            switch error {
            case .vipRequired: .localized(LocalizedStringResource("playback.vipRequired", defaultValue: "该歌曲需要 VIP，或未登录", table: "Errors"))
            case .loginExpired: .localized(LocalizedStringResource("playback.loginExpired", defaultValue: "登录已过期，请重新登录", table: "Errors"))
            case .unavailableInRegion: .localized(LocalizedStringResource("playback.unavailableInRegion", defaultValue: "该歌曲在当前地区不可用，可在设置的音乐平台页填写代理", table: "Errors"))
            case .sourceUnreachable: .localized(LocalizedStringResource("playback.sourceUnreachable", defaultValue: "无法连接到音乐来源", table: "Errors"))
            case .assetExpired: .localized(LocalizedStringResource("playback.assetExpired", defaultValue: "播放地址已失效", table: "Errors"))
            case .trialOnly: .localized(LocalizedStringResource("playback.trialOnly", defaultValue: "只有试听片段", table: "Errors"))
            case .decodeFailed(let detail): .localized(LocalizedStringResource("playback.decodeFailed", defaultValue: "解码失败：\(detail)", table: "Errors"))
            case .notImplemented(let detail): .localized(LocalizedStringResource("source.notImplemented", defaultValue: "尚未实现：\(detail)", table: "Errors"))
            case .unknown(let detail): .verbatim(detail)
            }
        case let error as SourceError:
            switch error {
            case .notRegistered: .localized(LocalizedStringResource("source.notRegistered", defaultValue: "来源未注册", table: "Errors"))
            case .capabilityMissing(let detail): .localized(LocalizedStringResource("source.capabilityMissing", defaultValue: "当前来源不支持\(detail)", table: "Errors"))
            case .notImplemented(let detail): .localized(LocalizedStringResource("source.notImplemented", defaultValue: "尚未实现：\(detail)", table: "Errors"))
            case .invalidResponse(let detail): .localized(LocalizedStringResource("source.invalidResponse", defaultValue: "响应异常：\(detail)", table: "Errors"))
            case .network(let detail): .localized(LocalizedStringResource("source.network", defaultValue: "网络错误：\(detail)", table: "Errors"))
            }
        case let error as UserSourceError:
            switch error {
            case .rankingHidden: .localized(LocalizedStringResource("user.rankingHidden", defaultValue: "对方没有公开听歌排行", table: "Errors"))
            case .followsHidden: .localized(LocalizedStringResource("user.followsHidden", defaultValue: "对方没有公开关注和粉丝", table: "Errors"))
            }
        case is CancellationError:
            .localized(LocalizedStringResource("cancelled", defaultValue: "已取消", table: "Errors"))
        default:
            .verbatim(error.localizedDescription)
        }
    }
}
