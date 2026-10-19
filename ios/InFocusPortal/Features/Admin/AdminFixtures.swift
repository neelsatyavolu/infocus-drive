import Foundation

/// Fictional Admin data for the sample app (`SampleMode`), screenshots and tests. Fictional people only.
enum AdminFixtures {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    static func access() throws -> PlatformAccess {
        try decode(PlatformAccess.self, accessJSON)
    }

    static func stats() throws -> PlatformStats {
        try decode(PlatformStats.self, statsJSON)
    }

    static func accessRequests() throws -> [AccessRequest] {
        try decode([AccessRequest].self, accessRequestsJSON)
    }

    static func people() throws -> [PlatformPerson] {
        try decode([PlatformPerson].self, peopleJSON)
    }

    static func roles() throws -> [RoleAssignment] {
        try decode([RoleAssignment].self, rolesJSON)
    }

    static func backups() throws -> BackupStatus {
        try decode(BackupStatus.self, backupsJSON)
    }

    static func viewAsPeople() throws -> [ViewAsPerson] {
        try decode([ViewAsPerson].self, #"""
        {"data":[{"id":"u-abby","name":"Abby Example","nickname":null,"email":"abby@example.edu","imageUrl":null},
                 {"id":"u-otto","name":"Otto","nickname":"Otto","email":"otto@example.edu","imageUrl":null}]}
        """#)
    }

    static let accessJSON = #"""
    {"data":{"email":"superadmin@example.edu","role":"SUPER_ADMIN",
      "permissions":{"canManageWorkspaces":true,"canManageAllowedEmails":true,"canManagePlatformRoles":true,"isExecutiveProducer":true}}}
    """#

    static let statsJSON = #"""
    {"data":{"totals":{"users":42,"workspaces":3,"projects":18,"activeMedia":512,"versions":640,"comments":1290,
      "activeShareLinks":4,"roleAssignments":9,"allowedEmails":40},
      "storage":{"estimatedBytes":1250000000000,"isEstimated":true},
      "recentUsers":[{"id":"u-sage","name":"Sage Example","email":"sage@example.edu","createdAt":"2026-10-01T16:00:00.000Z"}]}}
    """#

    static let accessRequestsJSON = #"""
    {"data":[
      {"id":"req-rio","email":"rio@example.edu","name":"Rio Example","status":"PENDING",
       "requestedAt":"2026-10-15T17:20:00.000Z","decidedAt":null,"decidedByEmail":null,"createdAt":"2026-10-15T17:20:00.000Z"},
      {"id":"req-kai","email":"kai@example.edu","name":null,"status":"PENDING",
       "requestedAt":"2026-10-14T09:05:00Z","decidedAt":null,"decidedByEmail":null},
      {"id":"req-juno","email":"juno@example.edu","name":"Juno Example","status":"APPROVED",
       "requestedAt":"2026-09-02T15:00:00.000Z","decidedAt":"2026-09-02T18:00:00.000Z","decidedByEmail":"adviser@example.edu"}]}
    """#

    static let peopleJSON = #"""
    {"data":[
      {"id":"u-abby","email":"abby@example.edu","name":"Abby Example","nickname":null,"createdAt":"2026-08-20T16:00:00.000Z"},
      {"id":"u-otto","email":"otto@example.edu","name":"Otto Example","nickname":"Otto","createdAt":"2026-08-21T16:00:00.000Z"},
      {"id":"u-sage","email":"sage@example.edu","name":"Sage Example","nickname":null,"createdAt":"2026-08-22T16:00:00.000Z"},
      {"id":"pending_7f9c","email":"juno@example.edu","name":"Juno Example","nickname":null,"createdAt":"2026-09-02T18:00:00.000Z"}]}
    """#

    static let rolesJSON = #"""
    {"data":[
      {"id":"r1","email":"otto@example.edu","role":"ASSOCIATE_PRODUCER","category":null,"createdAt":"2026-08-25T16:00:00.000Z","updatedAt":"2026-08-25T16:00:00.000Z"},
      {"id":"r2","email":"sage@example.edu","role":"EXECUTIVE_PRODUCER","category":null,"createdAt":"2026-08-25T16:00:00.000Z"},
      {"id":"r3","email":"adviser@example.edu","role":"ADVISER","category":null,"createdAt":"2026-08-01T16:00:00.000Z"}]}
    """#

    static let backupsJSON = #"""
    {"data":{"configured":true,
      "latest":{"ok":true,"at":"2026-10-18T10:00:00.000Z","key":"portal/2026-10-18.dump","bytes":52428800,"error":null},
      "dumps":[{"key":"portal/2026-10-18.dump","lastModified":"2026-10-18T10:00:00.000Z","bytes":52428800},
               {"key":"portal/2026-10-17.dump","lastModified":"2026-10-17T10:00:00.000Z","bytes":52000000}]}}
    """#
}
