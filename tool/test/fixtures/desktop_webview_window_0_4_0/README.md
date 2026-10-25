# desktop_webview_window 0.4.0 build metadata

Copied unchanged from https://pub.dev/api/archives/desktop_webview_window-0.4.0.tar.gz
Archive SHA-256: faeb95926f046a93a2b8325445a7f889d4b7772ff01b4b63b47c7c891bf9ac5b.
The upstream Apache-2.0 LICENSE is included. These metadata files are test inputs, not a plugin override.

The Windows FetchContent tests execute the real upstream helper with a local synthetic SDK ZIP; they verify integrity, extraction and architecture selection without internet or compilation. They do not claim the synthetic SDK can link. SPM tests exercise our inventory ownership model using the manifest's target/product topology, not Xcode compilation.
