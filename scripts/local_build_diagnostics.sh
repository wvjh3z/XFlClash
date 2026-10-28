# Sourced by the desktop entry after its root and Python prerequisite are known.
# Compatible with Bash 3.2 and Windows Git Bash. No build commands here.
xfl_finish_diagnostics() {
  local result=$?
  trap - EXIT
  trap '' INT TERM
  python3 "${REPO_DIR}/tool/build_diagnostics.py" --root "${REPO_DIR}" \
    --destination "${XFLCLASH_DIAGNOSTICS_DIR}" --exit-code "${result}" || \
    printf '%s\n' 'Diagnostic finalizer failed; original build status retained' >&2
  exit "${result}"
}
XFLCLASH_DIAGNOSTICS_DIR="$(python3 "${REPO_DIR}/tool/build_diagnostics.py" --root "${REPO_DIR}" --create-session)"
export XFLCLASH_DIAGNOSTICS_DIR
trap xfl_finish_diagnostics EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
