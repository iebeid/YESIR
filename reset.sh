#!/bin/bash

# ==============================================================================
# SCRIPT: reset.sh
# PURPOSE: Completely resets the project by destroying the old repository and
#          re-cloning. It interactively handles two cases:
#          1. A normal, full clone for users without LFS issues.
#          2. A sparse clone for users with LFS budget errors, prompting for
#             manual data placement.
# WARNING: This script is ALWAYS DESTRUCTIVE and will remove the existing
#          project directory.
# VERSION: 9.2 (Added data cache removal for a true reset)
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Capture the script's own directory to find its own files later ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BOOTSTRAP_REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"

# --- Internet Connectivity Check ---
check_internet() {
    echo "INFO: Checking internet connectivity..."
    # Ping a reliable domain name. This is more robust than an IP ping as it also verifies DNS resolution.
    if ping -c 1 www.google.com &> /dev/null; then
        echo "SUCCESS: Internet connection is active."
    else
        echo "ERROR: No internet connection. Please check your network and try again."
        exit 1
    fi
}

# --- Root User Check: Prevent running the entire script as root ---
if [ "$EUID" -eq 0 ]; then
  echo "ERROR: This script should not be run as root (or with 'sudo')."
  echo "It will ask for your password when it needs to install system packages."
  exit 1
fi

# --- Run initial checks ---
check_internet

# --- Pre-flight Check: Refresh sudo timestamp ---
echo "INFO: This script uses 'sudo' to manage system services and mounts."
echo "You may be prompted for your password once at the beginning."
sudo -v
echo "SUCCESS: Sudo credentials refreshed."
read -r -p "This script needs to install system-level tools (like git, git-lfs, build-essential, cmake). Is it OK to proceed? (y/n): " install_confirm
if [[ "$install_confirm" == "y" || "$install_confirm" == "Y" ]]; then
    echo "INFO: Installing comprehensive system-level tools..."
    if command -v apt-get &> /dev/null; then
        echo "  - Debian/Ubuntu based system detected. Using apt-get."
        sudo apt-get update && sudo apt-get install -y build-essential cmake libssl-dev autoconf automake libtool pkg-config git git-lfs openssh-server
    elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
        echo "  - RedHat/CentOS/Fedora based system detected. Using dnf/yum."
        sudo yum install -y gcc-c++ make cmake openssl-devel autoconf automake libtool pkgconfig git git-lfs
    elif command -v pacman &> /dev/null; then
        echo "  - Arch-based system detected. Using pacman."
        sudo pacman -Syu --noconfirm base-devel cmake openssl pkg-config autoconf automake libtool git git-lfs
    elif command -v brew &> /dev/null; then
        echo "  - macOS detected. Using Homebrew."
        brew install cmake openssl pkg-config autoconf automake libtool git git-lfs
    else
        echo "  - WARNING: Could not detect package manager. Skipping system dependency installation."
        echo "  - Please ensure 'build-essential' (or equivalent), 'cmake', and 'libssl-dev' are installed."
    fi
    echo "SUCCESS: System-level build tools check complete."
else
    echo "Skipping system dependency installation as requested. The build may fail if dependencies are missing."
fi

# --- Function for WSL-specific startup tasks ---
run_wsl_startup_tasks() {
    echo "INFO: Attempting to start the SSH server..."
    # Attempt to start the service but use '|| true' to prevent the script from exiting if it fails.
    sudo service ssh start &> /dev/null || true
    if pgrep -x "sshd" &> /dev/null; then
      echo "SUCCESS: SSH server process is running."
    else
      echo "WARNING: SSH server does not appear to be running."
    fi
    echo ""

    echo "INFO: Proceeding to mount the Windows G: drive..."
    MOUNT_POINT="/mnt/g"
    echo "INFO: Ensuring mount point directory '$MOUNT_POINT' exists."
    sudo mkdir -p "$MOUNT_POINT"
    # Only attempt to unmount if it's already a mount point.
    if mountpoint -q "$MOUNT_POINT"; then
        echo "INFO: Unmounting existing device at '$MOUNT_POINT' to ensure a clean state."
        sudo umount "$MOUNT_POINT" || true
    fi
    echo "INFO: Executing mount command..."
    sudo mount -t drvfs G: "$MOUNT_POINT" -o metadata || true
    if mountpoint -q "$MOUNT_POINT"; then
        echo "SUCCESS: The G: drive has been mounted to $MOUNT_POINT."
    else
        echo "WARNING: Failed to mount G: drive. It may not exist on the Windows host."
    fi
}

# --- WSL-specific Setup ---
if grep -qE "(Microsoft|WSL)" /proc/version &> /dev/null; then
    read -r -p "This appears to be a WSL environment. Do you want to run WSL-specific tasks (start SSH, mount G: drive)? (y/n): " wsl_confirm
    if [[ "$wsl_confirm" == "y" || "$wsl_confirm" == "Y" ]]; then
        run_wsl_startup_tasks
    fi
fi

# --- DEFINITIVE FIX: Ensure git-lfs is configured after installation ---
echo "INFO: Running 'git lfs install' to configure Git hooks..."
git lfs install

# --- Step 0: Get Target Project Configuration ---
read -r -p "Please enter the Git repository URL for the project to set up: " REPO_URL
if [ -z "$REPO_URL" ]; then
    echo "ERROR: Repository URL cannot be empty."
    exit 1
fi

# Derive project name from the URL
PROJECT_DIR_NAME=$(basename "$REPO_URL" .git)
ENV_NAME="${PROJECT_DIR_NAME,,}-env" # Convert to lowercase for environment name
CACHE_DIR_NAME="${PROJECT_DIR_NAME,,}" # lowercase name for cache
PYTHON_VERSION="3.11"

# --- DEFINITIVE FIX: Automatically detect the default branch ---
# This avoids hardcoding 'main', 'master', or 'v2' and makes the script universal.
GIT_BRANCH=$(git remote show "$REPO_URL" | sed -n '/HEAD branch/s/.*: //p')
if [ -z "$GIT_BRANCH" ]; then
    echo "WARNING: Could not auto-detect default branch. Falling back to 'main'. Clone may fail if 'main' does not exist."
    GIT_BRANCH="main"
fi

# --- Step 0.1: Define Project Structure and Find Conda ---
DOCUMENTS_DIR="$HOME/documents"
PROJECTS_DIR="$DOCUMENTS_DIR/projects"

echo "INFO: Ensuring project directory structure exists: $PROJECTS_DIR"
mkdir -p "$PROJECTS_DIR"
echo "SUCCESS: Project root will be in: $PROJECTS_DIR"

CONDA_BASE=$(conda info --base)
if [ -z "$CONDA_BASE" ]; then
    echo "ERROR: Could not find Conda base directory. Is Conda installed?"
    exit 1
fi
echo "INFO: Conda base found at: $CONDA_BASE"
source "$CONDA_BASE/etc/profile.d/conda.sh"

# --- NEW: Proactively accept Conda Terms of Service ---
# On fresh Anaconda installations, the ToS for default channels must be accepted.
echo "INFO: Proactively accepting Conda Terms of Service to prevent interactive prompts..."
# --- DEFINITIVE FIX: Handle multiple Conda versions and their ToS mechanisms ---
# Newer versions use a single config key. Older versions use the 'tos' subcommand.
# We rely on `conda tos accept` for newer versions.
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
echo "SUCCESS: Conda Terms of Service handled."

# --- Step 0.5: Dependency Checks (Git, Git LFS) ---
if ! command -v git &> /dev/null || ! command -v git-lfs &> /dev/null; then
    echo "ERROR: 'git' and 'git-lfs' are required. Please install them."
    exit 1
fi
echo "INFO: Git and Git LFS are installed."


# --- Step 1: Deactivate and Remove Old Environment ---
echo -e "\n--- STEP 1: Deactivating and Removing Conda Environment '$ENV_NAME' ---"
conda deactivate
if conda env list | grep -q "$ENV_NAME"; then
    echo "INFO: Environment '$ENV_NAME' found. Removing..."
    conda env remove -n "$ENV_NAME" -y
    echo "SUCCESS: Environment '$ENV_NAME' removed."
else
    echo "INFO: Environment '$ENV_NAME' not found. Skipping removal."
fi
conda clean --all -y > /dev/null
echo "SUCCESS: Conda cache cleaned."

# --- Function to check for existing GPU driver and set Conda packages ---
check_gpu_and_set_cuda_packages() {
    echo "INFO: Checking for existing NVIDIA GPU driver..."
    if command -v nvidia-smi &> /dev/null; then
        echo "SUCCESS: Found existing system-level NVIDIA driver. Conda will only install the CUDA toolkit."
        # If a system driver exists, we only need the CUDA toolkit from Conda
        # which will be compatible with the driver.
        CUDA_PACKAGES="cuda"
    else
        echo "WARNING: No system-level NVIDIA driver found (nvidia-smi not in PATH)."
        echo "INFO: Will attempt to install both driver and CUDA toolkit via Conda."
        # If no system driver, install both from Conda.
        CUDA_PACKAGES="nvidia-driver cuda"
    fi
}

# --- Step 2: Re-create Environment and Activate ---
echo -e "\n--- STEP 2: Re-creating a minimal Conda Environment '$ENV_NAME' ---"
echo "INFO: This creates a bare-bones Python environment. The full set of packages"
echo "      will be installed later by the 'setup.py' script."
check_gpu_and_set_cuda_packages
# Conda will automatically resolve and install the latest compatible versions of the CUDA toolkit
# and drivers from the specified channels.
conda create -n "$ENV_NAME" -c conda-forge -c nvidia python="$PYTHON_VERSION" $CUDA_PACKAGES -y

# --- DEFINITIVE FIX: Dynamically find the new environment's path ---
# Instead of assuming the env is in `$CONDA_BASE/envs`, we parse conda's output
# to find the actual location. This handles system vs. user-level installations.
NEW_ENV_PATH=$(conda info --envs | grep -w "$ENV_NAME" | awk '{print $NF}')
if [ -z "$NEW_ENV_PATH" ]; then
    echo "ERROR: Could not find the path for the newly created environment '$ENV_NAME'."
    exit 1
fi
NEW_ENV_PYTHON="$NEW_ENV_PATH/bin/python"
NEW_ENV_PIP="$NEW_ENV_PATH/bin/pip"

echo "SUCCESS: Environment '$ENV_NAME' created."
"$NEW_ENV_PYTHON" --version

# --- NEW STEP 2.5: Configure environment for CUDA libraries ---
# This incorporates the logic from 'export_cuda_env.sh' to ensure
# libraries within the Conda environment (like cuDNN) are found first.
echo -e "\n--- STEP 2.5: Configuring Environment for CUDA Libraries ---"
read -r -p "Do you want to configure this environment to prioritize its own libraries (recommended for CUDA/cuDNN)? (y/n): " cuda_confirm
if [[ "$cuda_confirm" == "y" || "$cuda_confirm" == "Y" ]]; then
    ACTIVATE_DIR="$NEW_ENV_PATH/etc/conda/activate.d"
    DEACTIVATE_DIR="$NEW_ENV_PATH/etc/conda/deactivate.d"
    mkdir -p "$ACTIVATE_DIR"
    mkdir -p "$DEACTIVATE_DIR"

    # Create activation script to PREPEND the env's lib path
    printf 'export OLD_LD_LIBRARY_PATH=${LD_LIBRARY_PATH}\nexport LD_LIBRARY_PATH=${CONDA_PREFIX}/lib/:${LD_LIBRARY_PATH}\n' > "$ACTIVATE_DIR/env_vars.sh"

    # Create deactivation script to restore the old path
    printf 'export LD_LIBRARY_PATH=${OLD_LD_LIBRARY_PATH}\nunset OLD_LD_LIBRARY_PATH\n' > "$DEACTIVATE_DIR/env_vars.sh"

    chmod +x "$ACTIVATE_DIR/env_vars.sh"
    chmod +x "$DEACTIVATE_DIR/env_vars.sh"
    echo "SUCCESS: Environment configured to handle CUDA libraries on activation."
else
    echo "INFO: Skipping CUDA library path configuration."
fi

# --- Step 3: Reset Project Directory and Data Cache ---
echo -e "\n--- STEP 3: Resetting Project Directory and Data Cache ---"
cd "$PROJECTS_DIR"
echo "INFO: Current directory: $(pwd)"

echo -e "\n\n\033[1;31m" # Bold Red
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! WARNING: DESTRUCTIVE ACTION !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "This script is about to COMPLETELY REMOVE the following directories:"
echo "  1. Project Directory: $PROJECTS_DIR/$PROJECT_DIR_NAME"
echo "  2. Persistent Cache:  $HOME/.cache/$CACHE_DIR_NAME"
echo ""
echo "This will delete all local code changes, results, and cached data."
echo "This action CANNOT be undone."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo -e "\033[0m" # Reset color

read -r -p "Are you absolutely sure you want to proceed with this destructive reset? (y/n): " reset_confirm
if [[ "$reset_confirm" != "y" && "$reset_confirm" != "Y" ]]; then
    echo "INFO: Reset cancelled by user. Exiting."
    exit 0
fi

# This is a reset script. If the directory exists, it will be destroyed to ensure a clean slate.
if [ -d "$PROJECT_DIR_NAME" ]; then
    rm -rf "$PROJECT_DIR_NAME"
    echo "SUCCESS: Old project directory removed."
fi

# --- DEFINITIVE FIX: Also remove the project-specific data cache to ensure a true reset ---
CACHE_DIR="$HOME/.cache/$CACHE_DIR_NAME"
if [ -d "$CACHE_DIR" ]; then
    rm -rf "$CACHE_DIR"
    echo "SUCCESS: Data cache removed."
fi

# --- Always perform a standard, full clone. Data is not in the repo. ---
echo "INFO: Performing a standard, full clone..."
git clone --branch "$GIT_BRANCH" "$REPO_URL"
cd "$PROJECT_DIR_NAME"
echo "SUCCESS: Project repository is ready."

# --- NEW: Verification Step ---
# This step makes the script's behavior more transparent by showing exactly
# what was cloned from the remote repository. This helps diagnose issues
# where the remote branch might not contain the expected code.
echo -e "\n--- STEP 3.1: Verifying Cloned Repository State ---"
echo "  - Current branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  - Latest commit: $(git log -1 --oneline)"

# --- NEW STEP: Install Python Dependencies ---
# This step installs the minimal bootstrap dependencies (like PyYAML) needed for the main setup scripts to run.
echo -e "\n--- STEP 3.5: Installing Python Dependencies ---"
if [ -f "$BOOTSTRAP_REQUIREMENTS_FILE" ]; then
    echo "INFO: Found bootstrap requirements at '$BOOTSTRAP_REQUIREMENTS_FILE'. Installing packages..."
    # Use the explicit path to pip from the new environment
    "$NEW_ENV_PIP" install --no-cache-dir --upgrade -r "$BOOTSTRAP_REQUIREMENTS_FILE"
    echo "SUCCESS: Python dependencies installed."
else
    echo "ERROR: Bootstrap requirements file not found at '$BOOTSTRAP_REQUIREMENTS_FILE'. This file is required for the setup."
    exit 1
fi

# --- Initialize a flag to track if setup.py was executed ---
SETUP_PY_EXECUTED=false

echo -e "\n--- STEP 4: Running the main setup script ('setup.py') ---"
# --- DEFINITIVE FIX: Check for setup.py in root, then fall back to src/ ---
SETUP_SCRIPT_PATH=$(find . -maxdepth 2 -name "setup.py" | head -n 1)
if [ -f "$SETUP_SCRIPT_PATH" ]; then
    echo "INFO: Executing '$SETUP_SCRIPT_PATH' to build the full Conda environment..."
    "$NEW_ENV_PYTHON" "$SETUP_SCRIPT_PATH"
    SETUP_PY_EXECUTED=true
else
    echo "WARNING: Main setup script ('setup.py') not found in project root or 'src/'."
    echo "INFO: Skipping automatic environment build. The minimal environment with 'requirements.txt' packages is ready."
fi

echo -e "\n\n"
echo "================================================================================"
if [ "$SETUP_PY_EXECUTED" = true ]; then
    echo "--- PROJECT RESET AND SETUP COMPLETE ---"
    echo "--- The project has been fully reset and the Conda environment has been built. ---"
else
    echo "--- PROJECT RESET COMPLETE ---"
    echo "--- A minimal Conda environment with packages from requirements.txt has been created. ---"
fi
echo "--- You can now activate the environment and start working: ---"
echo "    conda activate $ENV_NAME"
exit 0
