import Darwin
import Foundation

actor OperationGate {
  private var activeDeviceIDs: Set<SimulatorID> = []
  private let locksDirectoryURL: URL
  private let fileManager: FileManager

  init(
    locksDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.locksDirectoryURL =
      locksDirectoryURL
      ?? ReceiptStore.defaultApplicationSupportURL(fileManager: fileManager)
      .appendingPathComponent("Locks", isDirectory: true)
  }

  func acquire(for deviceID: SimulatorID) throws -> DeviceOperationLock {
    guard !activeDeviceIDs.contains(deviceID) else {
      throw SimulatorWorkspaceError.operationAlreadyRunning(deviceID)
    }
    guard SimctlAdapter.isValidUDID(deviceID.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }

    try fileManager.createDirectory(
      at: locksDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let url =
      locksDirectoryURL
      .appendingPathComponent(deviceID.rawValue.lowercased())
      .appendingPathExtension("lock")
    let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw SimulatorWorkspaceError.invalidOperation("无法创建设备操作锁")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw SimulatorWorkspaceError.operationAlreadyRunning(deviceID)
    }

    activeDeviceIDs.insert(deviceID)
    return DeviceOperationLock(deviceID: deviceID, descriptor: descriptor, gate: self)
  }

  fileprivate func release(_ deviceID: SimulatorID) {
    activeDeviceIDs.remove(deviceID)
  }
}

final class DeviceOperationLock: @unchecked Sendable {
  let deviceID: SimulatorID
  private var descriptor: Int32
  private let gate: OperationGate
  private let stateLock = NSLock()

  fileprivate init(deviceID: SimulatorID, descriptor: Int32, gate: OperationGate) {
    self.deviceID = deviceID
    self.descriptor = descriptor
    self.gate = gate
  }

  func release() async {
    let descriptorToClose = stateLock.withLock { () -> Int32 in
      let value = descriptor
      descriptor = -1
      return value
    }
    guard descriptorToClose >= 0 else { return }
    flock(descriptorToClose, LOCK_UN)
    Darwin.close(descriptorToClose)
    await gate.release(deviceID)
  }

  deinit {
    let descriptorToClose = stateLock.withLock { () -> Int32 in
      let value = descriptor
      descriptor = -1
      return value
    }
    if descriptorToClose >= 0 {
      flock(descriptorToClose, LOCK_UN)
      Darwin.close(descriptorToClose)
    }
  }
}
