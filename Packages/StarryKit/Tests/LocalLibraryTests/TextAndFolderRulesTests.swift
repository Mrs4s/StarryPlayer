import Foundation
import Testing
@testable import LocalLibrary

struct TextRepairTests {
    @Test func misreadTextIsReadAgain() {
        #expect(TextRepair.vote(["ÖÜ½ÜÂ×", "Ò¶»ÝÃÀ", "¹ú±ê±àÂë±êÌâ"]) == .gb18030)
        #expect(TextRepair.repaired("ÖÜ½ÜÂ×", as: .gb18030) == "周杰伦")
        #expect(TextRepair.vote(["æ­Œæ‰‹ç”²"]) == .utf8)
    }

    @Test func westernNamesAreLeftAlone() {
        #expect(TextRepair.vote(["Sigur Rós", "Motörhead", "Café del Mar", "Beyoncé"]) == nil)
        #expect(TextRepair.misreadBytes("plain ASCII") == nil)
        #expect(TextRepair.misreadBytes("周杰伦") == nil)
    }

    @Test func otherScripts() {
        let big5 = String(data: "周杰倫 七里香".data(using: LegacyEncoding.big5.foundation)!, encoding: .isoLatin1)!
        #expect(TextRepair.vote([big5, big5]) == .big5)
        let japanese = String(data: "宇多田ヒカル".data(using: LegacyEncoding.shiftJIS.foundation)!, encoding: .isoLatin1)!
        #expect(TextRepair.vote([japanese]) == .shiftJIS)
    }

    @Test func textFiles() {
        let gbk = "[00:01.00]故事的小黄花".data(using: LegacyEncoding.gb18030.foundation)!
        #expect(TextRepair.decodeText(gbk) == "[00:01.00]故事的小黄花")
        #expect(TextRepair.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data("歌".utf8)) == "歌")
    }
}

struct ArtistNamesTests {
    private let names = ArtistNames()

    @Test func separators() {
        #expect(names.split("周杰伦/费玉清") == ["周杰伦", "费玉清"])
        #expect(names.split("A、B、C") == ["A", "B", "C"])
        #expect(names.split("A; B") == ["A", "B"])
        #expect(names.split("Artist feat. Guest") == ["Artist", "Guest"])
        #expect(names.split("Artist (feat. Guest)") == ["Artist", "Guest"])
        #expect(names.split("A / B") == ["A", "B"])
    }

    @Test func namesThatStayWhole() {
        #expect(names.split("AC/DC") == ["AC/DC"])
        #expect(names.split("Simon & Garfunkel") == ["Simon & Garfunkel"])
        #expect(names.split("王力宏&谭维维") == ["王力宏&谭维维"])
        #expect(ArtistNames(splitsAmpersand: true).split("王力宏&谭维维") == ["王力宏", "谭维维"])
        #expect(ArtistNames(splitsAmpersand: true).split("Simon & Garfunkel") == ["Simon & Garfunkel"])
        #expect(ArtistNames(exceptions: ["Me/You"]).split("Me/You") == ["Me/You"])
    }

    @Test func multipleValuesAreKept() {
        #expect(names.split(["A", "B", "a"]) == ["A", "B"])
    }
}

struct FolderRulesTests {
    @Test func fileNames() {
        let parsed = FileName("05 林俊杰 - 江南.mp3")
        #expect(parsed.track == 5)
        #expect(parsed.artist == "林俊杰")
        #expect(parsed.title == "江南")
        #expect(FileName("7 Rings.flac").title == "7 Rings")
        #expect(FileName("1. Intro.mp3").track == 1)
    }

    @Test func discFolders() {
        #expect(FolderRules.discNumber(folderName: "CD1") == 1)
        #expect(FolderRules.discNumber(folderName: "Disc 2") == 2)
        #expect(FolderRules.discNumber(folderName: "disk-3") == 3)
        #expect(FolderRules.discNumber(folderName: "CD") == nil)
        #expect(FolderRules.discNumber(folderName: "叶惠美") == nil)
    }

    @Test func numbersAndGains() {
        #expect(FolderRules.numberPair("3/12") == (3, 12))
        #expect(FolderRules.year("2021-05-20") == 2021)
        #expect(FolderRules.gain("-7.50 dB") == -7.5)
        #expect(FolderRules.r128("-512") == 3)
    }
}
