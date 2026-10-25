# Crisp 3.0.0 compatibility source

Source: https://pub.dev/packages/crisp_chat/versions/3.0.0
Archive SHA-256: `e21e3b115151f3bc43515910ebc4d376bcd5d5b9e406fe528d765f87336643c7`.
Original MIT license is retained in LICENSE. Only runtime source/metadata is vendored; examples and upstream development files are omitted.

Android and iOS source is byte-identical to that archive; `upstream-mobile-sha256.json` records it. Changes are restricted to pubspec's desktop dependency (0.4.0) and the Dart desktop adapter: new configuration/result types, await navigation/close, and a visitor-chat URL instead of the operator dashboard. The application continues using its own CrispChatDriver for desktop lifecycle/identity; the upstream desktop adapter must still type-check because Flutter registers it.

Upgrade procedure: compare a new upstream release, rerun mobile integrity and client lifecycle/navigation tests, then remove this compatibility source only when upstream accepts desktop_webview_window 0.4.0 and implements its new interfaces. Do not replace the shared Pub cache or change mobile SDK versions as part of this compatibility adjustment.
