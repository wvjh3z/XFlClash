# Release/Profile retain optimization while producing private, matching PDBs.
# Imported binaries (Flutter/WebView2) are supplied by their own symbol servers.
if(MSVC AND CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
  function(xb_sentry_collect_targets directory output)
    get_property(directory_targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
    get_property(children DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
    foreach(child IN LISTS children)
      xb_sentry_collect_targets("${child}" child_targets)
      list(APPEND directory_targets ${child_targets})
    endforeach()
    set(${output} "${directory_targets}" PARENT_SCOPE)
  endfunction()

  xb_sentry_collect_targets("${CMAKE_SOURCE_DIR}" xb_sentry_targets)
  set(xb_sentry_manifest "")
  foreach(xb_target IN LISTS xb_sentry_targets)
    get_target_property(xb_type "${xb_target}" TYPE)
    get_target_property(xb_imported "${xb_target}" IMPORTED)
    if(NOT xb_imported AND xb_type MATCHES "^(EXECUTABLE|SHARED_LIBRARY|MODULE_LIBRARY|STATIC_LIBRARY|OBJECT_LIBRARY)$")
      target_compile_options("${xb_target}" PRIVATE
        "$<$<OR:$<CONFIG:Release>,$<CONFIG:Profile>>:/Zi>")
      # Separate compiler PDBs prevent parallel targets sharing vc*.pdb.
      set_target_properties("${xb_target}" PROPERTIES
        COMPILE_PDB_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sentry-symbols/obj/${xb_target}/$<CONFIG>")
      if(xb_type MATCHES "^(EXECUTABLE|SHARED_LIBRARY|MODULE_LIBRARY)$")
        target_link_options("${xb_target}" PRIVATE
          "$<$<OR:$<CONFIG:Release>,$<CONFIG:Profile>>:/DEBUG:FULL>"
          "$<$<OR:$<CONFIG:Release>,$<CONFIG:Profile>>:/OPT:REF>"
          "$<$<OR:$<CONFIG:Release>,$<CONFIG:Profile>>:/OPT:ICF>")
        set_target_properties("${xb_target}" PROPERTIES
          PDB_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sentry-symbols/$<CONFIG>"
          PDB_NAME "${xb_target}")
        string(APPEND xb_sentry_manifest
          "${xb_target}\t$<TARGET_FILE:${xb_target}>\t$<TARGET_PDB_FILE:${xb_target}>\n")
      endif()
    endif()
  endforeach()
  # Native Assets Rust outputs are verified and appended by the postbuild
  # preparer; there is no rust_api_cargokit CMake target in v0.9.1.
  file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/sentry-symbols/$<CONFIG>/targets.tsv"
    CONTENT "${xb_sentry_manifest}")
endif()
