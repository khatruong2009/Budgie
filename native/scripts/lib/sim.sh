# Sourced by ui_flow.sh and system_flow.sh. One simulator lookup rule, shared
# with the Python scripts through lib/sim.py.
SIM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sim_runtime [device type name]: the highest available iOS runtime that
# offers the device type (default "iPhone 17 Pro"), as a runtime identifier.
sim_runtime() {
  python3 "$SIM_LIB_DIR/sim.py" runtime "$@"
}
