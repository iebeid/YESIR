# ==============================================================================
# MODULE: configuration/setup-windows.py
# VERSION: 33.0 (Hardened Binary Logic & Verification)
# AUTHOR: Islam Ebeid / Gemini
# ==============================================================================

import subprocess
import os

# --- Configuration ---
ENV_NAME = "ppi-env"
PYTHON_VERSION = "3.11"
CUDA_VERSION = "12.1"
PYTORCH_VERSION = "2.1.2"
# Specific link for PyG binaries matching Torch 2.1.2 and CUDA 12.1
PYG_LINK = f"https://data.pyg.org/whl/torch-{PYTORCH_VERSION}+cu121.html"

def run_command(command):
    print(f"\n>>> Executing: {command}\n")
    process = subprocess.Popen(command, shell=True, text=True)
    process.wait()
    if process.returncode != 0:
        print(f"!!! ERROR: Command failed with exit code {process.returncode}")
        return False
    return True

if __name__ == "__main__":
    print(f"--- Starting Self-Contained Setup for '{ENV_NAME}' ---")

    # 1. CREATE ENVIRONMENT
    run_command(f"conda create -n {ENV_NAME} python={PYTHON_VERSION} -y")

    # 2. CONDA INSTALLS (Core C++ Runtimes & Scientific Stack)
    conda_cmd = (
        f"conda install -y -n {ENV_NAME} -c nvidia -c conda-forge "
        f"cuda-toolkit={CUDA_VERSION} cuda-compiler={CUDA_VERSION} cudnn=8.9 "
        f"pycuda dask tqdm biopython matplotlib \"scipy<1.14.0\" scikit-learn "
        f"gensim python-louvain seaborn pandas h5py pyyaml networkx=3.2.1"
    )
    run_command(conda_cmd)

    # 3. PIP INSTALLS (PyTorch Core with CUDA 12.1 Wheels)
    pip_base = f"conda run -n {ENV_NAME} pip install --no-cache-dir "
    run_command(f"{pip_base} torch=={PYTORCH_VERSION} torchvision==0.16.2 torchaudio==2.1.2 --extra-index-url https://download.pytorch.org/whl/cu121")

    # 4. TENSORFLOW & OPTUNA (MLflow Stack)
    run_command(f"{pip_base} \"tensorflow<2.16\" tf-keras")
    run_command(f"{pip_base} optuna mlflow gdown \"transformers==4.41.2\" \"safetensors==0.4.3\" \"optuna-integration[mlflow]\"")

    # 5. PYTORCH GEOMETRIC BINARIES (Sequential Install for Stability)
    print("\n--- Installing PyTorch Geometric Binaries ---")
    pyg_binaries = ["torch-scatter", "torch-sparse", "torch-cluster", "torch-spline-conv"]
    for pkg in pyg_binaries:
        run_command(f"{pip_base} {pkg} -f {PYG_LINK}")
    run_command(f"{pip_base} torch-geometric")

    # 6. CRITICAL PATCH: PROTOBUF COMPATIBILITY
    # Overwrites Protobuf 5.x/6.x to satisfy TensorFlow 2.15 expectations
    print("\n--- Applying Final Protobuf Patch for TensorFlow ---")
    run_command(f"{pip_base} \"protobuf<5.0.0\"")

    # 7. FINAL VERIFICATION
    print("\n" + "="*50)
    print("--- RUNNING FINAL VERIFICATION ---")
    
    # Using a literal string to avoid host-side name errors
    verify_script = (
        "import torch; "
        "import tensorflow as tf; "
        "import torch_geometric; "
        "print('\\n--- Environment Report ---'); "
        "print('PyTorch GPU Available:  ', torch.cuda.is_available()); "
        "print('PyG Version:           ', torch_geometric.__version__); "
        "gpus = tf.config.list_physical_devices('GPU'); "
        "print(f'TensorFlow GPU Found:  {len(gpus)}'); "
        "print('--------------------------\\n')"
    )
    
    run_command(f"conda run -n {ENV_NAME} python -c \"{verify_script}\"")

    # Troubleshooting Advisory
    if os.name == 'nt':
        print("ADVISORY: On Native Windows, TensorFlow 2.11+ requires WSL2 for GPU access.")
        print("PyTorch and PyG will utilize the GPU natively; TensorFlow will default to CPU.")
    
    print("="*50)
    print(f"\nSetup Complete. Use 'conda activate {ENV_NAME}' to begin your research.")