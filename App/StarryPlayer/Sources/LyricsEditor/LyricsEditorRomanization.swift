import Foundation
import LyricsCore

extension LyricsEditorSession {
    /// Generates off the main actor; changed lines are skipped and reordered lines matched by ID.
    func generateJapaneseRomanization(for lineID: UUID? = nil, overwrite: Bool = false) async {
        guard !isGeneratingRomanization else { return }
        let candidates = draft.lines.filter {
            (lineID == nil || $0.id == lineID)
                && (overwrite || $0.romanization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && JapaneseRomanization.containsJapaneseScript($0.text)
        }
        guard !candidates.isEmpty else {
            flash("没有需要生成日语音译的歌词行")
            return
        }
        isGeneratingRomanization = true
        defer { isGeneratingRomanization = false }
        let results = await Task.detached(priority: .userInitiated) {
            candidates.compactMap { line -> (LyricsDraft.Line, String)? in
                JapaneseRomanization.romanize(line.text).map { (line, $0) }
            }
        }.value
        guard !Task.isCancelled else { return }
        var updated = 0
        edit { draft in
            for (original, romanization) in results {
                guard let index = draft.lines.firstIndex(where: { $0.id == original.id }),
                      draft.lines[index].text == original.text,
                      draft.lines[index].romanization == original.romanization,
                      draft.lines[index].romanization != romanization else { continue }
                draft.lines[index].romanization = romanization
                updated += 1
            }
        }
        if results.isEmpty {
            flash("未能识别日语读音，请手动填写音译")
        } else if updated == 0 {
            flash("音译无需更新，已修改的歌词行会保留")
        } else if results.count < candidates.count {
            flash("已生成 \(updated) 行音译，\(candidates.count - results.count) 行未识别")
        } else {
            flash("已生成 \(updated) 行日语音译")
        }
    }
}
