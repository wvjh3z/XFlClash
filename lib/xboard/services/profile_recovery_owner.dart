/// Captured subscription ownership, never read from a later login's token.
class ProfileRecoveryOwner {
  const ProfileRecoveryOwner(this.flavor, this.ownerHash);
  final String flavor;
  final String ownerHash;
}

/// Fixed diagnostic categories; no path, metadata contents or account identifiers.
enum ProfileRecoveryWarning {
  malformedMetadata,
  unsupportedSchema,
  invalidIdentity,
}

/// Bound warning volume per process. Diagnostic transport never fails cleanup.
class ProfileRecoveryDiagnostics {
  ProfileRecoveryDiagnostics(this._send);
  final void Function(ProfileRecoveryWarning) _send;
  final _reported = <ProfileRecoveryWarning>{};
  void report(ProfileRecoveryWarning warning) {
    if (!_reported.add(warning)) return;
    try {
      _send(warning);
    } catch (_) {
      /* best-effort diagnostic */
    }
  }
}
