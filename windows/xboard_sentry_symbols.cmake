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
  # Rust is produced by Cargo rather than a CMake link target. Cargokit copies
  # its local PDB next to the DLL; record both without installing the PDB.
  if(TARGET rust_api_cargokit)
    set(xb_rust_symbol_outputs 0)
    foreach(xb_rust_binary IN LISTS rust_api_bundled_libraries)
      if(xb_rust_binary MATCHES "[/\\\\]rust_api\\.dll$")
        string(REGEX REPLACE "\\.dll$" ".pdb" xb_rust_pdb "${xb_rust_binary}")
        string(APPEND xb_sentry_manifest
          "rust_api\t${xb_rust_binary}\t${xb_rust_pdb}\n")
        math(EXPR xb_rust_symbol_outputs "${xb_rust_symbol_outputs} + 1")
      endif()
    endforeach()
    if(NOT xb_rust_symbol_outputs EQUAL 1)
      message(FATAL_ERROR "Rust FFI requires one matching DLL/PDB symbol output")
    endif()
  endif()
  file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/sentry-symbols/$<CONFIG>/targets.tsv"
    CONTENT "${xb_sentry_manifest}")
endif()
