// AudioDeviceManagerTests.swift
// NeriPlayer macOS —— M1-T7：音频输出设备枚举与切换测试。
//
// 与 MPVControllerTests / PlayerEngineTests 一样跑真实 libmpv（需要 Vendor/mpv/lib 与 rpath，
// 见 Package.swift）。设备列表来自本机实际回读，因此断言只依赖 mpv 必然提供的 "auto"，
// 不选真实特定硬件（避免测试依赖外接设备）。
//
// 边界：M1-T7 只验证输出设备的列出/读取/切换/通知，不涉及 USB 独占（M8-T6）与音效（M8-T4）。

import XCTest
@testable import NeriPlayer

final class AudioDeviceManagerTests: XCTestCase {

    /// 每个用例独立实例，避免相互污染音频设备状态。
    private func makeManager() throws -> (MPVController, AudioDeviceManager) {
        let controller = try MPVController(clientName: "audio-device-test")
        return (controller, AudioDeviceManager(controller: controller))
    }

    // MARK: - 枚举

    /// 设备列表非空且包含 "auto"（mpv 的自动选择项，任何环境都必然存在）。
    func testDeviceListIsNotEmptyAndContainsAuto() throws {
        let (_, manager) = try makeManager()
        let devices = manager.devices
        XCTAssertFalse(devices.isEmpty, "设备列表不应为空")
        XCTAssertTrue(
            devices.contains { $0.name == AudioDeviceManager.defaultDeviceName },
            "设备列表应包含 auto，实际为 \(devices.map(\.name))"
        )
    }

    /// 每个条目的 name 非空（name 是写回 audio-device 的取值，空名不可用）。
    func testEveryDeviceHasNonEmptyName() throws {
        let (_, manager) = try makeManager()
        for device in manager.devices {
            XCTAssertFalse(device.name.isEmpty, "设备 name 不应为空：\(device)")
        }
    }

    /// 列表读回后 currentDevice 可读，且取值落在列表内。
    func testCurrentDeviceIsReadable() throws {
        let (_, manager) = try makeManager()
        let current = manager.currentDevice
        XCTAssertFalse(current.isEmpty, "currentDevice 应可读")
        XCTAssertTrue(
            manager.devices.contains { $0.name == current },
            "当前设备 \(current) 应存在于设备列表中"
        )
    }

    // MARK: - 切换

    /// 切到 auto 成功，且回读为 auto（不涉及真实特定硬件）。
    func testSelectAutoRoundTrip() throws {
        let (controller, manager) = try makeManager()
        XCTAssertNoThrow(try manager.selectDevice(name: AudioDeviceManager.defaultDeviceName))
        XCTAssertEqual(manager.currentDevice, "auto")
        XCTAssertEqual(try controller.getString("audio-device"), "auto", "写入应直接落到内核属性")
    }

    /// 不在列表中的名字（或名字未在列表中时）被拒绝为 unknownDevice，且不改动当前设备。
    func testSelectUnknownDeviceThrows() throws {
        let (_, manager) = try makeManager()
        try manager.selectDevice(name: AudioDeviceManager.defaultDeviceName)

        let bogus = "neriplayer/definitely-not-a-device"
        XCTAssertThrowsError(try manager.selectDevice(name: bogus)) { error in
            XCTAssertEqual(error as? AudioDeviceError, .unknownDevice(name: bogus))
        }
        XCTAssertEqual(manager.currentDevice, "auto", "被拒绝的切换不应改变当前设备")
    }

    // MARK: - JSON 契约

    /// 解析 libmpv 的实际 JSON 形状，并验证 isEnabled / isDefault 的缺省回退。
    func testDecodeDeviceListAppliesOptionalFieldDefaults() {
        let json = """
        [{"name":"auto","description":"Autoselect device"},
         {"name":"coreaudio/BuiltInSpeakerDevice","description":"内建扬声器","isEnabled":false,"isDefault":true}]
        """
        let decoded = AudioDeviceManager.decodeDeviceList(json)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?.first?.name, "auto")
        XCTAssertEqual(decoded?.first?.description, "Autoselect device")
        XCTAssertEqual(decoded?.first?.isEnabled, true, "缺失 isEnabled 应回退为 true")
        XCTAssertEqual(decoded?.first?.isDefault, false, "缺失 isDefault 应回退为 false")
        XCTAssertEqual(decoded?.last?.isEnabled, false, "显式提供的 isEnabled 应被采用")
        XCTAssertEqual(decoded?.last?.isDefault, true, "显式提供的 isDefault 应被采用")
    }

    /// 非法 JSON 返回 nil（由调用方保留旧快照），不抛不崩。
    func testDecodeInvalidJSONReturnsNil() {
        XCTAssertNil(AudioDeviceManager.decodeDeviceList("not json at all"))
        XCTAssertNil(AudioDeviceManager.decodeDeviceList("{\"name\":\"auto\"}"))
    }

    // MARK: - 通知

    /// observeDevices 订阅后立即收到当前快照。
    func testObserveDevicesEmitsInitialSnapshot() async throws {
        let (_, manager) = try makeManager()
        var iterator = manager.observeDevices().makeAsyncIterator()
        let snapshot = await iterator.next()
        XCTAssertNotNil(snapshot, "订阅后应立刻收到一次当前快照")
        XCTAssertTrue(snapshot?.contains { $0.name == "auto" } ?? false)
    }
}
