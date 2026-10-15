#!/usr/bin/env bash
# Wire up the locally-unpacked verilator and prove it runs.
set -u
VBIN="$HOME/opt/verilator/usr/bin"
VROOT="$HOME/opt/verilator/usr/share/verilator"

echo "=== contents of $VBIN ==="
ls -la "$VBIN" 2>/dev/null

cat > "$HOME/opt/env.sh" <<'EOF'
export VERILATOR_ROOT="$HOME/opt/verilator/usr/share/verilator"
export PATH="$HOME/opt/verilator/usr/bin:$PATH"
EOF
echo
echo "wrote $HOME/opt/env.sh"

. "$HOME/opt/env.sh"
echo
echo "=== smoke test ==="
echo "VERILATOR_ROOT=$VERILATOR_ROOT"
echo "which: $(command -v verilator)"
verilator --version 2>&1 | head -3

echo
echo "=== compile a trivial design end-to-end ==="
T="$HOME/opt/smoke"
rm -rf "$T"; mkdir -p "$T"; cd "$T" || exit 1
cat > top.sv <<'EOF'
module top(input logic clk, output logic [7:0] q);
    logic [7:0] r = 8'h00;
    always_ff @(posedge clk) r <= r + 8'd1;
    assign q = r;
endmodule
EOF
cat > main.cpp <<'EOF'
#include "Vtop.h"
#include "verilated.h"
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtop* t = new Vtop;
    for (int i = 0; i < 5; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    printf("SMOKE_OK q=%d\n", (int)t->q);
    delete t;
    return 0;
}
EOF
verilator -cc --exe --build top.sv main.cpp --top-module top -Wno-lint 2>&1 | tail -6
if [ -x obj_dir/Vtop ]; then ./obj_dir/Vtop; else echo "SMOKE FAILED: no obj_dir/Vtop"; fi
