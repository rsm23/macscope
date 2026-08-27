import Foundation

/// A physical-device projection of mounted volumes. APFS sibling volumes can
/// share one IOBlockStorageDriver counter set, so summing volume snapshots
/// directly would multiply the same device activity.
public struct PhysicalDiskActivity: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let deviceIdentifier: String?
    public let volumeNames: [String]
    public let mountPoints: [String]
    public let io: DiskIOSnapshot

    public init(
        id: String,
        name: String,
        deviceIdentifier: String?,
        volumeNames: [String],
        mountPoints: [String],
        io: DiskIOSnapshot
    ) {
        self.id = id
        self.name = name
        self.deviceIdentifier = deviceIdentifier
        self.volumeNames = volumeNames
        self.mountPoints = mountPoints
        self.io = io
    }
}

public enum PhysicalDiskActivityProjection {
    public static func make(from disks: [DiskSnapshot]) -> [PhysicalDiskActivity] {
        Dictionary(grouping: disks, by: groupingIdentifier)
            .map { identifier, volumes in
                let representative = preferredRepresentative(in: volumes)
                let deviceIdentifier = representative.physicalDeviceIdentifier
                let fallbackName = representative.name.isEmpty ? representative.mountPoint : representative.name
                let name = representative.physicalDeviceName?.nonEmpty
                    ?? deviceIdentifier?.nonEmpty
                    ?? fallbackName
                let volumeNames = Set(volumes.map { $0.name.isEmpty ? $0.mountPoint : $0.name })
                    .sorted(by: localizedAscending)
                let mountPoints = Set(volumes.map(\.mountPoint)).sorted(by: localizedAscending)
                return PhysicalDiskActivity(
                    id: identifier,
                    name: name,
                    deviceIdentifier: deviceIdentifier,
                    volumeNames: volumeNames,
                    mountPoints: mountPoints,
                    io: representative.io ?? DiskIOSnapshot(
                        availability: .unsupported,
                        provenance: "No physical-device counter source",
                        detail: "This mounted volume is not backed by a discoverable IOBlockStorageDriver."
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.io.availability != rhs.io.availability {
                    return availabilityRank(lhs.io.availability) < availabilityRank(rhs.io.availability)
                }
                return localizedAscending(lhs.name, rhs.name)
            }
    }

    private static func groupingIdentifier(for disk: DiskSnapshot) -> String {
        if let identifier = disk.physicalDeviceIdentifier?.nonEmpty {
            return "physical:\(identifier)"
        }
        if let identifier = disk.deviceIdentifier?.nonEmpty {
            return "volume:\(identifier)"
        }
        return "mount:\(disk.mountPoint)"
    }

    private static func preferredRepresentative(in disks: [DiskSnapshot]) -> DiskSnapshot {
        disks.sorted { lhs, rhs in
            let lhsRank = availabilityRank(lhs.io?.availability ?? .unsupported)
            let rhsRank = availabilityRank(rhs.io?.availability ?? .unsupported)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return localizedAscending(lhs.mountPoint, rhs.mountPoint)
        }.first!
    }

    private static func availabilityRank(_ availability: DataAvailability) -> Int {
        switch availability {
        case .available: 0
        case .degraded: 1
        case .stale: 2
        case .restricted: 3
        case .unmapped: 4
        case .unsupported: 5
        }
    }

    private static func localizedAscending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
