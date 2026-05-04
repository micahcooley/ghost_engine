#!/usr/bin/env bash
# Compile Vulkan compute shaders (.comp -> .spv)
# Requires glslc (Vulkan SDK or shaderc package)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHADER_DIR="$SCRIPT_DIR/src/shaders"

if ! command -v glslc &>/dev/null; then
    echo "error: glslc not found. Install shaderc or the Vulkan SDK." >&2
    exit 1
fi

compiled=0
for comp in "$SHADER_DIR"/*.comp; do
    [ -f "$comp" ] || continue
    name="$(basename "$comp" .comp)"
    out="$SHADER_DIR/${name}.spv"
    echo "Compiling $name.comp -> ${name}.spv"
    glslc "$comp" -o "$out"
    compiled=$((compiled + 1))
done

echo "Compiled $compiled shaders."
