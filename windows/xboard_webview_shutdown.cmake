# flutter_inappwebview_windows 0.6.0 owns process-wide WinRT resources in
# static smart pointers. CRT destroys them under DLL_PROCESS_DETACH, when
# CoreMessaging/COM may already be unavailable (upstream issue #2733).
# Keep only those four shared owners alive until OS process reclamation.
# Per-view disposal and every caller of exit() retain their existing behavior.
# Never patch the shared Pub cache or Flutter's generated plugin registration.
function(xboard_fix_webview_shutdown target)
  if(NOT TARGET "${target}")
    return()
  endif()
  get_target_property(already_applied "${target}" XB_WEBVIEW_SHUTDOWN_FIXED)
  if(already_applied)
    return()
  endif()
  get_target_property(source_dir "${target}" SOURCE_DIR)
  set(header "in_app_webview/in_app_webview_manager.h")
  set(implementation "in_app_webview/in_app_webview_manager.cpp")
  # Normalize checkout line endings, but reject all other upstream drift.
  # A dependency upgrade requires reviewing the ownership patch explicitly.
  foreach(relative IN ITEMS "${header}" "${implementation}")
    set(path "${source_dir}/${relative}")
    if(NOT EXISTS "${path}")
      message(FATAL_ERROR "WebView shutdown patch: missing pinned source ${relative}")
    endif()
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${path}")
    file(READ "${path}" text)
    string(REPLACE "\r\n" "\n" text "${text}")
    string(SHA256 digest "${text}")
    if(relative STREQUAL header)
      set(expected "931899455a69b5c1f8e3fa380f9bcc3603ea972b7e8c864fccf403cf5a171e0f")
      set(patched_header "${text}")
    else()
      set(expected "bf4f6f8041841af9923d20b08c3782159a3c7f5cc9e8fdb6ac8dbea57ac5b02d")
    endif()
    if(NOT digest STREQUAL expected)
      message(FATAL_ERROR "WebView shutdown patch: pinned 0.6.0 source drift in ${relative}; review before upgrading")
    endif()
  endforeach()

  # References have no static destructor. The heap smart pointers still manage
  # assignment/reset normally while running; their final owners are deliberately
  # process-lifetime. Do not replace this with AddRef on just the compositor:
  # GraphicsContext, the dispatcher controller and RoHelper also perform COM work.
  string(REPLACE
    "inline static std::shared_ptr<rx::RoHelper> rohelper_ = nullptr;"
    "inline static std::shared_ptr<rx::RoHelper>& rohelper_ = *new std::shared_ptr<rx::RoHelper>();"
    patched_header "${patched_header}")
  string(REPLACE
    "inline static winrt::com_ptr<ABI::Windows::System::IDispatcherQueueController>\n      dispatcher_queue_controller_ = nullptr;"
    "inline static winrt::com_ptr<ABI::Windows::System::IDispatcherQueueController>&\n      dispatcher_queue_controller_ = *new winrt::com_ptr<ABI::Windows::System::IDispatcherQueueController>();"
    patched_header "${patched_header}")
  string(REPLACE
    "inline static std::unique_ptr<GraphicsContext> graphics_context_ = nullptr;"
    "inline static std::unique_ptr<GraphicsContext>& graphics_context_ = *new std::unique_ptr<GraphicsContext>();"
    patched_header "${patched_header}")
  string(REPLACE
    "inline static winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor_ = nullptr;"
    "inline static winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor>& compositor_ = *new winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor>();"
    patched_header "${patched_header}")
  string(PREPEND patched_header
    "// XFlclash: four process-lifetime owners; no COM teardown in DLL static destructors.\n")

  set(overlay "${CMAKE_CURRENT_BINARY_DIR}/xboard_webview_shutdown")
  # All translation units must see the same patched class (quoted includes use
  # their source directory). Copy the source/header tree, not just manager.cpp.
  file(GLOB_RECURSE inputs CONFIGURE_DEPENDS RELATIVE "${source_dir}"
    "${source_dir}/*.h" "${source_dir}/*.hpp" "${source_dir}/*.cpp" "${source_dir}/*.cc")
  foreach(relative IN LISTS inputs)
    if(NOT relative STREQUAL header)
      configure_file("${source_dir}/${relative}" "${overlay}/${relative}" COPYONLY)
    endif()
  endforeach()
  # configure_file preserves timestamps on identical output: no rebuild loop.
  set(header_input "${CMAKE_CURRENT_BINARY_DIR}/xboard_webview_manager.h.in")
  file(WRITE "${header_input}" "${patched_header}")
  configure_file("${header_input}" "${overlay}/${header}" COPYONLY)

  get_target_property(sources "${target}" SOURCES)
  set(patched_sources)
  foreach(source IN LISTS sources)
    if(source MATCHES "\\$<")
      message(FATAL_ERROR "WebView shutdown patch: unsupported generated source")
    endif()
    get_filename_component(absolute "${source}" ABSOLUTE BASE_DIR "${source_dir}")
    file(RELATIVE_PATH relative "${source_dir}" "${absolute}")
    if(relative MATCHES "^\\.\\./" OR IS_ABSOLUTE "${relative}" OR
       NOT EXISTS "${overlay}/${relative}")
      message(FATAL_ERROR "WebView shutdown patch: source outside copied tree: ${source}")
    endif()
    list(APPEND patched_sources "${overlay}/${relative}")
  endforeach()
  set_property(TARGET "${target}" PROPERTY SOURCES "${patched_sources}")
  # The pinned plugin exports only its public C API include directory; the
  # original copy remains ABI-identical. Private quoted includes use the overlay.
  set_property(TARGET "${target}" PROPERTY XB_WEBVIEW_SHUTDOWN_FIXED TRUE)
  message(STATUS "Xboard: WebView 0.6.0 process-exit ownership fix applied")
endfunction()

xboard_fix_webview_shutdown(flutter_inappwebview_windows_plugin)
