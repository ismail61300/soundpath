import XCTest
@testable import SoundPath

final class AutoEQParserTests: XCTestCase {
    func testParsesPreampAndFilters() throws {
        let text = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
        Filter 2: ON PK Fc 2600 Hz Gain -3.1 dB Q 2.10
        Filter 3: OFF PK Fc 500 Hz Gain 2.0 dB Q 1.00
        """
        let preset = try XCTUnwrap(AutoEQParser.parse(text, name: "Test"))
        XCTAssertEqual(preset.name, "Test")
        XCTAssertEqual(preset.preamp, -6.4, accuracy: 0.001)
        XCTAssertEqual(preset.bands.count, EQSettings.bandCount)
        XCTAssertEqual(preset.bands[0].kind, .lowShelf)
        XCTAssertEqual(preset.bands[0].frequency, 105, accuracy: 0.001)
        XCTAssertEqual(preset.bands[1].kind, .peak)
        XCTAssertEqual(preset.bands[1].gain, -3.1, accuracy: 0.001)
    }

    func testClampsOutOfRangeAndNonFiniteValues() throws {
        let text = """
        Preamp: nan dB
        Filter 1: ON PK Fc 1e9 Hz Gain 99 dB Q 0
        Filter 2: ON PK Fc -50 Hz Gain 1 dB Q 1
        Filter 3: ON PK Fc 1000 Hz Gain inf dB Q 5000
        """
        let preset = try XCTUnwrap(AutoEQParser.parse(text, name: "Bad"))
        XCTAssertEqual(preset.preamp, 0)
        for band in preset.bands {
            XCTAssertTrue(band.frequency.isFinite && band.gain.isFinite && band.q.isFinite)
            XCTAssertTrue((20...20_000).contains(band.frequency))
            XCTAssertTrue((-24...24).contains(band.gain))
            XCTAssertTrue((0.1...20).contains(band.q))
        }
    }

    func testRejectsTextWithoutFilters() {
        XCTAssertNil(AutoEQParser.parse("nothing useful here", name: "x"))
    }
}

final class AppSettingsTests: XCTestCase {
    func testRoundTripKeepsPlugin() throws {
        var s = AppSettings()
        s.volume = 0.4
        s.plugin = AUPluginSettings(type: 1, subType: 2, manufacturer: 3, name: "Test Plug-in", enabled: false,
                                    state: Data([1, 2, 3]))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.hasEffects)
        XCTAssertFalse(back.pluginActive) // disabled
    }

    func testDecodesSettingsSavedBeforePluginsExisted() throws {
        let json = #"{"volume":0.7,"muted":true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.volume, 0.7, accuracy: 0.0001)
        XCTAssertTrue(s.muted)
        XCTAssertNil(s.plugin)
        XCTAssertFalse(s.anyEffectActive)
    }

    func testPersistentTapRules() {
        var s = AppSettings()
        XCTAssertFalse(s.needsPersistentTap)
        s.volume = 0.5
        XCTAssertTrue(s.needsPersistentTap)
    }
}

final class LatencyAndMeterTests: XCTestCase {
    func testDeviceFramesRange() {
        XCTAssertEqual(LatencySetting.deviceFrames(0), 128)
        XCTAssertEqual(LatencySetting.deviceFrames(1), 2048)
        XCTAssertEqual(LatencySetting.ring(0.5).max, LatencySetting.ring(0.5).target * 4)
    }

    @MainActor
    func testMeterScale() {
        XCTAssertEqual(MixerModel.normalized(0), 0)
        XCTAssertEqual(MixerModel.normalized(1), 1, accuracy: 0.001)      // 0 dBFS
        XCTAssertEqual(MixerModel.normalized(0.001), 0)                   // below the floor
        XCTAssertGreaterThan(MixerModel.normalized(0.5), MixerModel.normalized(0.1))
    }
}

final class PluginDescriptionTests: XCTestCase {
    func testSamePluginIgnoresNameAndState() {
        let a = AUPluginSettings(type: 1, subType: 2, manufacturer: 3, name: "A")
        var b = a
        b.name = "B"; b.enabled = false; b.state = Data([9])
        XCTAssertTrue(a.isSamePlugin(as: b))
        b.subType = 99
        XCTAssertFalse(a.isSamePlugin(as: b))
    }
}
