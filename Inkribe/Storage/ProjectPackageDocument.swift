import InkribeCore

/// App-owned document validation retains native mapping/recovery policy. The
/// reusable store only needs portable identity, sources and the JSON contract.
extension ProjectDocument: ProjectPackageDocument {
    static var supportedPackageDocumentSchema: Int { ProjectSchema.current }

    var packageIdentity: ProjectPackageIdentity {
        ProjectPackageIdentity(id: id, schemaVersion: schemaVersion, revision: contentRevision)
    }

    var packageSources: [ProjectPackageSource] {
        assets.map { ProjectPackageSource(relativePath: $0.relativeOriginalPath, byteCount: $0.byteCount) }
    }

    func validatePackageDocument() throws { try validate() }
}
