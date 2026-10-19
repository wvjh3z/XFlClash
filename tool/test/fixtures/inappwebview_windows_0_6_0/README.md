These unmodified manager source files and CMakeLists.txt are from the Apache-2.0 licensed
`flutter_inappwebview_windows` 0.6.0 package (pub.dev); only CRLF is normalized
to LF. The upstream license is included as `LICENSE`.

They are offline inputs to the Windows shutdown overlay regression. Production
uses the resolved package, never this fixture. CMake checks the normalized SHA256
of both files before modifying a build-directory copy of the header. Tests
compile that actual header against small COM/Flutter stand-ins, then run real
child processes with late-destructor failure controls. This exercises C++
ownership, not real Windows COM or a complete Flutter application.
