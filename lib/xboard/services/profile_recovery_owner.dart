/// Captured subscription ownership, never read from a later login's token.
class ProfileRecoveryOwner {
  const ProfileRecoveryOwner(this.flavor, this.ownerHash);
  final String flavor;
  final String ownerHash;
}
