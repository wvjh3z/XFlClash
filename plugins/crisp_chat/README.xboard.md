# Crisp 3.0.0 compatibility source

Source: https://pub.dev/packages/crisp_chat/versions/3.0.0
Archive SHA-256: `e21e3b115151f3bc43515910ebc4d376bcd5d5b9e406fe528d765f87336643c7`.
Original MIT license is retained in LICENSE. Only runtime source/metadata is vendored; examples and upstream development files are omitted.

Android Java and iOS source remain byte-identical to that archive; the sole Android build override upgrades `im.crisp:crisp-sdk` from 2.0.24 to 2.0.25 for the upstream dynamic-resource shrinking fix (#244). `upstream-mobile-sha256.json` records the unchanged original archive hashes. Other changes are restricted to pubspec's desktop dependency (0.4.0) and the Dart desktop adapter: new configuration/result types, await navigation/close, and a visitor-chat URL instead of the operator dashboard. The application continues using its own CrispChatDriver for desktop lifecycle/identity; the upstream desktop adapter must still type-check because Flutter registers it.

Upgrade procedure: compare a new upstream release, rerun mobile integrity and client lifecycle/navigation tests, then remove this compatibility source only when upstream accepts desktop_webview_window 0.4.0 and implements its new interfaces. Do not replace the shared Pub cache or change mobile SDK versions without a separately reviewed compatibility update.

The original mobile hash manifest is retained. The compatibility test reverses only the exact authorized SDK-version substitution before comparing original hashes. Android runtime resources are inventoried from the official 2.0.25 AAR in `tool/crisp_resource_contract.json` as R identifiers mapped to exact original runtime names; both CI and VDS verify those exact names in final APKs, without treating dots and underscores as interchangeable. `tool/crisp_resource_inventory.py` validates the pinned archive and derives the mapping. The tooling-only raw keep XML itself is not required as a runtime resource.
