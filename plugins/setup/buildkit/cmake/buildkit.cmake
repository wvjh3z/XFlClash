# buildkit.cmake — Build Go core as part of the native Linux/Windows build
#
# Include this from a plugin's CMakeLists.txt and call:
#   apply_buildkit()
#
# This adds a custom command that runs build_tool before the native target is linked.

# Resolve at include-time so CMAKE_CURRENT_LIST_DIR is this file's directory
get_filename_component(BUILDKIT_DIR "${CMAKE_CURRENT_LIST_DIR}" DIRECTORY)

function(apply_buildkit)
  if(WIN32)
    set(_launcher "${BUILDKIT_DIR}/run_build_tool.cmd")
  else()
    set(_launcher "${BUILDKIT_DIR}/run_build_tool.sh")
  endif()

  # Project root is one level up from CMAKE_SOURCE_DIR (the top-level CMakeLists.txt
  # lives in linux/ or windows/, so project root is the parent).
  get_filename_component(PROJECT_ROOT "${CMAKE_SOURCE_DIR}" DIRECTORY)

  # The output files the build_tool produces
  if(WIN32)
    set(_output "${PROJECT_ROOT}/libclash/windows/FlClashCore.exe")
    set(_platform_args "windows")
  else()
    set(_output "${PROJECT_ROOT}/libclash/linux/FlClashCore")
    set(_platform_args "linux")
  endif()

  set(BUILDKIT_ENV
    "BUILDKIT_CONFIGURATION=$<CONFIG>"
    "PROJECT_DIR=${PROJECT_ROOT}"
  )

  # An existing core must be rebuilt when its builder/linker policy or Go input
  # changes, including local --skip-clean packaging. CONFIGURE_DEPENDS also
  # notices a newly added optional build_config.yaml or Go source file.
  file(GLOB_RECURSE _buildkit_inputs CONFIGURE_DEPENDS
    "${BUILDKIT_DIR}/build_tool/lib/*.dart"
    "${PROJECT_ROOT}/core/*.go"
    "${PROJECT_ROOT}/core/go.mod"
    "${PROJECT_ROOT}/core/go.sum"
  )
  file(GLOB _buildkit_config CONFIGURE_DEPENDS
    "${PROJECT_ROOT}/build_config.yaml"
    "${BUILDKIT_DIR}/build_tool/pubspec.yaml"
    "${BUILDKIT_DIR}/build_tool/pubspec.lock"
  )

  add_custom_command(
    OUTPUT ${_output}
    COMMAND ${CMAKE_COMMAND} -E env ${BUILDKIT_ENV}
    "${_launcher}" ${_platform_args}
    WORKING_DIRECTORY "${PROJECT_ROOT}"
    DEPENDS ${_buildkit_inputs} ${_buildkit_config}
      "${_launcher}" "${BUILDKIT_DIR}/cmake/buildkit.cmake"
    COMMENT "Building Go core via buildkit..."
    VERBATIM
  )

  add_custom_target(setup_buildkit_build DEPENDS ${_output})
endfunction()
