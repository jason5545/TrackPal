import CryptoKit
import Foundation
import Testing
@testable import TrackPalCore

/// 回歸指紋：固定 seed 的隨機情境丟進狀態機，整串輸出（每一筆捲動、點擊、
/// 日誌、旗標變化）的 SHA-256 必須跟記錄的值一樣。
///
/// 這批指紋是 2026-11-13 重構時建立的：當時新狀態機與重構前的程式碼在
/// 6,000 組情境與 3,758 筆實機軌跡上的輸出逐位元相同。之後任何重構只要讓
/// 指紋變了，就代表某個可觀察的行為（或日誌文字）改了。
///
/// 刻意改行為或改日誌格式時，用下面的指令印出新的指紋，貼回 `expected`：
///
///     TRACKPAL_PRINT_GOLDEN=1 swift test --filter EngineGoldenTests
@MainActor
@Suite("狀態機回歸指紋")
struct EngineGoldenTests {
    static let seedsPerGroup: UInt64 = 100

    static let expected: [String] = [
        // GOLDEN-BEGIN
        "2d386de134128fb1daa2d0e7f1f2411824434a949302f605c567b9631f85400c",
        "c6eca742f0d24925b9290c483222a751f63becf2003abbcdab7f0928cafd3337",
        "b8df42f251897fa34d2bf3b8f6f8383d218cdc2a334e1ecf9f12a6482075427d",
        "395b7094ec82bcf72549edc3847b0ecc80ecdb142e09e273ca949d3264cc29c8",
        "808789873d84085ff047140789e8e6ea8944e9d451aa9a46b69afc1392343784",
        "c34949c0e548a71e18b38e3b3f21b78b6ee9bceec47d4407197c38bec56c5bf0",
        "08f452651e9b64b9f65d276903c6b2080ac40b67b159824d22e6d997ae3514a3",
        "0f6aa84a776827bc2eac443a28e75428b17403454c7dda618015fa57067dfbba",
        "ef323338a18ee9c9f21e50b3d0943f6ca8f50ed5df553af74c99556dbbe3d446",
        "efe48b76eb6d97d41bf8975b032118708599cfcdc3ec6e7828e1140347f03086",
        "581650c8359a633db2c3d48b87438ef42b913df591dccb30ab02cab7f536067c",
        "ab41275ce40e452a54f79a2f42d071c0a88611b07cce94413d12163e4367261d",
        "51163194e430784e55febf7162591d321e6e36550adc5540ffc90a3b2331e1cd",
        "5e87701eb009d128ce9f3725c5c39fcebdfabbcd83a36390e8330419476d9b8e",
        "756c017b5da7834ede3b2eb3201a62def394d387eb351a72551bddf2ceb38aad",
        "a265fa615141d897f8f4074e519159c00068df4042f54a04ebb2dbf151f038f4",
        // GOLDEN-END
    ]

    static func digest(group: Int) -> String {
        var hasher = SHA256()
        let first = UInt64(group) * seedsPerGroup + 1
        for seed in first..<(first + seedsPerGroup) {
            let scenario = ScenarioFuzzer.scenario(seed: seed)
            hasher.update(data: Data("### \(scenario.name)\n".utf8))
            for line in EngineScenarioRunner.run(scenario) {
                hasher.update(data: Data(line.utf8))
                hasher.update(data: Data([0x0A]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test("16 組、共 1,600 個情境的輸出指紋不變")
    func transcriptsMatchRecordedDigests() {
        let groupCount = 16
        let actual = (0..<groupCount).map(Self.digest(group:))

        if ProcessInfo.processInfo.environment["TRACKPAL_PRINT_GOLDEN"] != nil {
            print("// GOLDEN-BEGIN")
            for digest in actual { print("        \"\(digest)\",") }
            print("// GOLDEN-END")
        }

        #expect(Self.expected.count == groupCount)
        for (group, digest) in actual.enumerated() where group < Self.expected.count {
            #expect(
                digest == Self.expected[group],
                "seed \(group * 100 + 1)…\(group * 100 + 100) 的輸出變了"
            )
        }
    }

    @Test("同一個 seed 產生的情境完全相同")
    func fuzzerIsDeterministic() {
        #expect(ScenarioFuzzer.scenario(seed: 42) == ScenarioFuzzer.scenario(seed: 42))
        #expect(ScenarioFuzzer.scenario(seed: 42) != ScenarioFuzzer.scenario(seed: 43))
    }

    @Test("SplitMix64 的輸出跟參考實作一致")
    func splitMixMatchesReference() {
        // seed 0 的前三個值，出自 SplitMix64 的參考實作。
        var rng = SplitMix64(seed: 0)
        do { let value = rng.next(); #expect(value == 0xE220_A839_7B1D_CDAF) }
        do { let value = rng.next(); #expect(value == 0x6E78_9E6A_A1B9_65F4) }
        do { let value = rng.next(); #expect(value == 0x06C4_5D18_8009_454F) }
    }

    @Test("同一段輸入重播兩次，輸出相同（狀態機沒有隱藏的全域狀態）")
    func replayIsRepeatable() {
        let scenario = ScenarioFuzzer.scenario(seed: 7)
        #expect(EngineScenarioRunner.run(scenario) == EngineScenarioRunner.run(scenario))
    }

    @Test("情境可以存成 JSON 再讀回來")
    func scenarioRoundTripsThroughJSON() throws {
        let scenario = ScenarioFuzzer.scenario(seed: 11)
        let data = try JSONEncoder().encode(scenario)
        let decoded = try JSONDecoder().decode(EngineScenario.self, from: data)
        // NaN 不等於自己，所以比對重播結果而不是比對值。
        #expect(EngineScenarioRunner.run(decoded) == EngineScenarioRunner.run(scenario))
    }

    @Test("設定裡有不認得的值：不執行，回報錯誤")
    func invalidSettingsAreReported() {
        var scenario = EngineScenario(name: "bad")
        scenario.settings.verticalEdgeMode = "diagonal"
        #expect(EngineScenarioRunner.run(scenario) == ["error invalid settings"])
        #expect(ZoneScrollConfiguration(scenario.settings) == nil)
    }
}
