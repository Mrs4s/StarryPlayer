import Foundation
import MusicSources
import SwiftUI

struct RecommendationStylePicker: View {
    struct Request: Identifiable {
        let id = UUID()
        let categories: [RecommendationStyleCategory]

        init(categories: [RecommendationStyleCategory]) {
            var seen = Set<String>()
            self.categories = categories.filter { seen.insert($0.id).inserted }.map { category in
                var tags = Set<String>()
                let styles = category.styles.filter { tags.insert($0.id).inserted }
                let selected = Set(category.selectedStyleIDs)
                return RecommendationStyleCategory(id: category.id, name: category.name, styles: styles,
                                                   selectedStyleIDs: styles.filter { selected.contains($0.id) }.map(\.id))
            }
        }
    }

    let request: Request
    let daily: DailyRecommendationsModel
    let dismiss: () -> Void
    @Environment(LocalizationStore.self) private var localization
    @Environment(\.theme) private var theme
    @State private var categoryID: String
    @State private var drafts: [String: Set<String>]
    @State private var error: DisplayText?
    @State private var applyTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    static let width: CGFloat = 584

    init(request: Request, daily: DailyRecommendationsModel, dismiss: @escaping () -> Void) {
        self.request = request
        self.daily = daily
        self.dismiss = dismiss
        let selected = request.categories.first { !$0.selectedStyleIDs.isEmpty } ?? request.categories.first
        _categoryID = State(initialValue: selected?.id ?? "")
        _drafts = State(initialValue: Dictionary(uniqueKeysWithValues: request.categories.map { ($0.id, Set($0.selectedStyleIDs)) }))
    }

    private var category: RecommendationStyleCategory? { request.categories.first { $0.id == categoryID } }
    private var selectedIDs: Set<String> { drafts[categoryID] ?? [] }
    private var busy: Bool { daily.savingStyles || applyTask != nil }
    private var canApply: Bool { category != nil && !selectedIDs.isEmpty && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                PageTabs(items: request.categories.map { .init(value: $0.id, title: $0.name) }, selection: $categoryID)
                Spacer(minLength: 0)
                DisplayTextView(text: .localized(LocalizedStringResource("daily.styles.selectedCount", defaultValue: "\(selectedIDs.count) 项已选")))
                    .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant).fixedSize()
            }
            .frame(height: 40)
            .disabled(busy)

            ScrollView {
                if let category {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 16) {
                        ForEach(category.styles) { style in
                            styleButton(style)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .frame(height: 220)
            .disabled(busy)

            if let error {
                DisplayTextView(text: error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#F0625D"))
            }
            buttons
        }
        .padding(20)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.string(LocalizedStringResource("daily.styles.choose", defaultValue: "选择推荐风格")))
        .accessibilityAddTraits(.isModal)
        .onExitCommand { if !busy { dismiss() } }
        .onChange(of: categoryID) { _, _ in error = nil }
        .onAppear { focused = true }
        .onDisappear { applyTask?.cancel() }
    }

    private func styleButton(_ style: RecommendationStyle) -> some View {
        let selected = selectedIDs.contains(style.id)
        return Button {
            var ids = selectedIDs
            if !ids.insert(style.id).inserted { ids.remove(style.id) }
            drafts[categoryID] = ids
            error = nil
        } label: {
            Text(style.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(selected ? theme.primary : theme.onSurfaceVariant)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(selected ? theme.primary.opacity(0.14) : theme.onSurface.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? theme.primary.opacity(0.3) : theme.outlineVariant, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isPill: true))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(style.name)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                DisplayTextView(text: .localized(LocalizedStringResource("common.cancel", defaultValue: "取消")))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
            .focused($focused)
            .keyboardShortcut(.cancelAction)
            .disabled(busy)

            Button {
                guard canApply, let category else { return }
                let ids = selectedIDs
                applyTask = Task { await apply(category, styleIDs: ids) }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small).tint(theme.onPrimary) }
                    DisplayTextView(text: .localized(busy
                        ? LocalizedStringResource("common.applying", defaultValue: "应用中…")
                        : LocalizedStringResource("common.apply", defaultValue: "应用")))
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(theme.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(VariantButtonStyle(variant: .filled, isPill: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
            .opacity(canApply || busy ? 1 : 0.45)
        }
    }

    private func apply(_ category: RecommendationStyleCategory, styleIDs: Set<String>) async {
        defer { applyTask = nil }
        guard !Task.isCancelled else { return }
        error = nil
        do {
            if try await daily.saveStyles(in: category, styleIDs: styleIDs) { dismiss() }
        } catch {
            if !Task.isCancelled { self.error = ErrorText.message(error) }
        }
    }
}
