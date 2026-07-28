import Foundation

/// 菜单栏专用工作区，只保留设备、应用与内存查询能力。
public actor MenuBarWorkspace: MenuBarWorkspaceClient {
  private let simulator: any SimulatorControlling
  private let memoryInspector: any MemoryInspecting
  private let applicationCatalog: SimulatorApplicationCatalog

  public init() {
    let runner = FoundationCommandRunner()
    self.simulator = SimctlAdapter(runner: runner)
    self.memoryInspector = LibprocMemoryInspector(runner: runner)
    self.applicationCatalog = SimulatorApplicationCatalog(runner: runner)
  }

  public func menuBarSnapshot() async throws -> MenuBarSnapshot {
    try Task.checkCancellation()
    let inventory = try await simulator.inventory()
    let devices = inventory.devices
      .filter { $0.isAvailable && $0.state == .booted }
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }

    var snapshots: [MenuBarDeviceSnapshot] = []
    snapshots.reserveCapacity(devices.count)
    for device in devices {
      try Task.checkCancellation()
      do {
        let memory = try await memoryInspector.snapshot(for: device.id)
        snapshots.append(MenuBarDeviceSnapshot(device: device, memory: memory))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        snapshots.append(
          MenuBarDeviceSnapshot(
            device: device,
            memory: nil,
            memoryError: error.localizedDescription
          )
        )
      }
    }
    return MenuBarSnapshot(devices: snapshots)
  }

  public func applications(
    for deviceID: SimulatorID
  ) async throws -> SimulatorApplicationListSnapshot {
    try Task.checkCancellation()
    let applications = try await applicationCatalog.applications(for: deviceID)
    try Task.checkCancellation()

    do {
      let memoryByBundleIdentifier = try await memoryInspector.applicationMemorySnapshots(
        for: deviceID,
        applications: applications
      )
      return SimulatorApplicationListSnapshot(
        applications: applications,
        memoryByBundleIdentifier: memoryByBundleIdentifier
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return SimulatorApplicationListSnapshot(
        applications: applications,
        memoryError: error.localizedDescription
      )
    }
  }

  public func dataContainer(
    for deviceID: SimulatorID,
    bundleIdentifier: String
  ) async throws -> URL? {
    try await applicationCatalog.dataContainer(
      for: deviceID,
      bundleIdentifier: bundleIdentifier
    )
  }

  public func showSimulator(_ deviceID: SimulatorID) async throws {
    try Task.checkCancellation()
    let device = try await simulator.validatedDevice(deviceID)
    guard device.state == .booted else {
      throw SimulatorWorkspaceError.deviceNotBooted(deviceID)
    }
    try await simulator.openSimulator(deviceID)
  }
}
