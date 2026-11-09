# Client-local SharedPreferences 2.5.6

Source: https://pub.dev/api/archives/shared_preferences-2.5.6.tar.gz

Archive SHA256: `1e85e0dccf5b4a016077fea7dfbb4a7cb39c759ac1596fcf60c06deadb7da91f`.
License: original BSD license in LICENSE; AUTHORS retained.

This client-local source subset contains the original lib, tests and package
metadata. Example applications, development scripts and the optional prebuilt
DevTools extension UI are not bundled. Native implementations remain the
original platform packages from the client lockfile.

Authorized change: legacy SharedPreferences tracks local cache mutations and
reload request generations. A late read cannot replace keys changed by a
setter/remove, resurrect keys after clear, or override a newer reload request.
Untouched keys still refresh when an unrelated write overlaps the read.
Synchronous optimistic setters,
false/error behavior, keys, prefixes, native persistence and async APIs remain
unchanged. A superseded read/key update is discarded; this is not a cross-isolate or
cross-process transaction, and it does not make failed optimistic writes durable.

Only pubspec.yaml (local non-publishable marker) and
lib/src/shared_preferences_legacy.dart differ from the upstream subset. Tests
added by this project are maintained in the client test tree. When upgrading,
compare the guarded methods against the new upstream and rerun original package
tests plus the client reload/failure/Token regression tests. Do not patch a shared
pub cache. Removing this dependency override requires equivalent upstream race
protection; otherwise it restores the known stale-reload bug.

Applies to all users of this package in the client dependency graph, including
the sibling SDK. It does not alter the standalone SDK's hosted dependency.
