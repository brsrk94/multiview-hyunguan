#!/bin/bash
# Hunyuan3D-2 — Multiview Gradio start script
# Usage:
#   ./start.sh
#   ./start.sh --port 8080 --host 0.0.0.0
#   ./start.sh --disable_tex                       # shape-only, lower setup/runtime load
#   ./start.sh --enable_t23d                       # enable text-to-3D tab
#
# Extra arguments are passed to gradio_app.py.
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
VENV_DIR="$PROJECT_DIR/venv"
PYTHON_BIN="${PYTHON_BIN:-python3}"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║        Hunyuan3D-2  Multiview Setup         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── 1. Virtual environment ──────────────────────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
    echo "[1/6] Creating Python virtual environment..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
else
    echo "[1/6] Virtual environment already exists."
fi
source "$VENV_DIR/bin/activate"
python -m pip install --upgrade pip -q

# ── 2. PyTorch ───────────────────────────────────────────────────────────────
echo "[2/6] Checking PyTorch..."
if python -c "import torch" &>/dev/null; then
    PYT_VER=$(python -c "import torch; print(torch.__version__)")
    CUDA_OK=$(python -c "import torch; print(torch.cuda.is_available())")
    echo "      Already installed: torch $PYT_VER  CUDA=$CUDA_OK"
else
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi &>/dev/null; then
        CUDA_VER=$(nvidia-smi | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -1)
        CUDA_VER="${CUDA_VER:-unknown}"
        echo "      GPU detected (CUDA $CUDA_VER) — installing PyTorch with CUDA..."
        if [[ "$CUDA_VER" == 12* ]]; then
            WHL="https://download.pytorch.org/whl/cu121"
        else
            WHL="https://download.pytorch.org/whl/cu118"
        fi
    else
        echo "      No GPU detected — installing PyTorch CPU (inference will be slow)"
        WHL="https://download.pytorch.org/whl/cpu"
    fi
    python -m pip install torch torchvision torchaudio --index-url "$WHL" -q
fi

# ── 3. Python requirements ───────────────────────────────────────────────────
echo "[3/6] Installing project requirements..."
python -m pip install -r requirements.txt -q
python -m pip install huggingface_hub -q

# pyrender for proper stereo/offscreen rendering
echo "      Installing pyrender + PyOpenGL..."
python -m pip install pyrender PyOpenGL PyOpenGL_accelerate -q 2>/dev/null \
    && echo "      pyrender installed" \
    || echo "      pyrender not available — continuing without optional offscreen renderer"

# System-level Mesa offscreen renderer (needs sudo; skip gracefully if absent)
if ! python -c "import OpenGL.osmesa" &>/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        echo "      Installing Mesa offscreen support (libosmesa6)..."
        sudo apt-get update -q >/dev/null 2>&1 \
            && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libosmesa6-dev libgl1-mesa-dri freeglut3-dev -q >/dev/null 2>&1 \
            && echo "      Mesa offscreen support installed" \
            || echo "      Mesa offscreen support install failed; continuing without it"
    else
        echo "      Mesa offscreen support skipped (sudo/apt not available non-interactively)"
    fi
fi

# ── 4. Install hy3dgen package ───────────────────────────────────────────────
echo "[4/6] Installing hy3dgen package (editable)..."
python -m pip install -e . -q

# ── 5. Compile custom CUDA rasterizer ────────────────────────────────────────
echo "[5/6] Compiling custom rasterizer..."
RAST_DIR="$PROJECT_DIR/hy3dgen/texgen/custom_rasterizer"
if [ -f "$RAST_DIR/setup.py" ]; then
    (cd "$RAST_DIR" && python -m pip install -e . -q) \
        && echo "      Custom rasterizer compiled." \
        || echo "      Compilation failed — CUDA toolkit required for GPU rasterizer."
fi

# ── 6. Verify ────────────────────────────────────────────────────────────────
echo "[6/6] Environment check..."
python - <<'PYCHECK'
import importlib, sys
ok = True
for mod in ["torch", "PIL", "trimesh", "numpy", "diffusers", "transformers"]:
    try:
        importlib.import_module(mod)
        print(f"      ✓ {mod}")
    except ImportError:
        print(f"      ✗ {mod}  <-- MISSING")
        ok = False
if not ok:
    print("\nSome packages are missing. Re-run this script or install manually.")
    sys.exit(1)
PYCHECK

echo ""
echo "✓ Setup complete!"
echo ""
echo "══════════════════════════════════════════════════"
echo "  Running Hunyuan3D-2mv Gradio App"
echo "══════════════════════════════════════════════════"
echo ""

APP_DEVICE=$(python - <<'PYDEVICE'
try:
    import torch
    print("cuda" if torch.cuda.is_available() else "cpu")
except Exception:
    print("cpu")
PYDEVICE
)
echo "Using device: $APP_DEVICE"
echo ""

# Defaults match the repository's multiview turbo Gradio example.
python gradio_app.py \
    --model_path tencent/Hunyuan3D-2mv \
    --subfolder hunyuan3d-dit-v2-mv-turbo \
    --texgen_model_path tencent/Hunyuan3D-2 \
    --device "$APP_DEVICE" \
    --low_vram_mode \
    --enable_flashvdm \
    "$@"
