#!/bin/bash

# Exit immediately if any command exits with non-zero status
set -e
# Exit if any command in a pipeline fails
set -o pipefail
# Print each command before executing (for debugging)
set -x

# Rust
SETUP_RUST_TOOLCHAIN=${SETUP_RUST_TOOLCHAIN:-"nightly"}
SETUP_RUST_PROFILE=${SETUP_RUST_PROFILE:-"minimal"}
RUSTUP_INIT_SH="https://sh.rustup.rs"
CARGO_CONFIG="""
[net]
git-fetch-with-cli = true
"""

# Proxy
ENABLE_PROXY=false
GITHUB_PROXY=""
CARGO_CONFIG_RSPROXY="""
# Mirror for China Mainland
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy]
registry = "https://rsproxy.cn/crates.io-index"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[registries.rsproxy]
index = "https://rsproxy.cn/crates.io-index"
"""

# Cache
CACHE_DIR=${CACHE_DIR:-".cache"}
CLEAR_CACHE_DIR=false

# Other tools
SETUP_MDBOOK=${SETUP_MDBOOK:-""}

# Custom command
CUSTOM_CMD=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --rust-toolchain)
      SETUP_RUST_TOOLCHAIN="$2"
      shift 2
      ;;
    --rust-profile)
      SETUP_RUST_PROFILE="$2"
      shift 2
      ;;
    --enable-proxy)
      ENABLE_PROXY=true
      shift
      ;;
    --install-mdbook)
      SETUP_MDBOOK="$2"
      shift 2
      ;;
    --cache-dir)
      CACHE_DIR="$2"
      shift 2
      ;;
    --clear-cache)
      CLEAR_CACHE_DIR=true
      shift
      ;;
    --execute-command)
      CUSTOM_CMD="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

echo "RUST_LOG=$RUST_LOG"
echo "CURRENT_PATH=$(realpath ./)"

if [[ "$CLEAR_CACHE_DIR" = true && -d "$CACHE_DIR" ]]; then
  echo "Clear cache dir: $(realpath $CACHE_DIR)"
  rm -rf "$CACHE_DIR"
fi

if [ "$ENABLE_PROXY" = true ]; then
  echo "Use rsproxy and Github proxy."
  export RUSTUP_DIST_SERVER="https://rsproxy.cn"
  export RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
  RUSTUP_INIT_SH="https://rsproxy.cn/rustup-init.sh"
  GITHUB_PROXY="https://gh-proxy.com/"
fi

if [ ! -d "$CACHE_DIR" ]; then
  echo "Create cache dir..."
  mkdir -p "$CACHE_DIR" || { echo "Failed to create cache dir"; exit 1; }
fi

if [[ ! -d "$CACHE_DIR/cargo" || ! -d "$CACHE_DIR/rustup" ]]; then
  echo "Rust cache does not exist, installing (toolchain: $SETUP_RUST_TOOLCHAIN, profile: $SETUP_RUST_PROFILE)..."

  # -f ensures curl returns error on server errors
  curl --proto '=https' --tlsv1.2 -sSf "$RUSTUP_INIT_SH" | sh -s -- --default-toolchain "$SETUP_RUST_TOOLCHAIN" --profile "$SETUP_RUST_PROFILE" -y
  
  if [ $? -ne 0 ]; then
    echo "Failed to install Rust"
    exit 1
  fi

  if [[ -d "$HOME/.cargo" && -d "$HOME/.rustup" ]]; then
    echo "$CARGO_CONFIG" > $HOME/.cargo/config.toml

    if [ "$ENABLE_PROXY" = true ]; then
      echo "$CARGO_CONFIG_RSPROXY" >> $HOME/.cargo/config.toml
    fi

    mkdir -p $CACHE_DIR/cargo
    mkdir -p $CACHE_DIR/rustup
    cp -r "$HOME/.cargo"/* "$CACHE_DIR/cargo/" || { echo "Failed to cache cargo dir"; exit 1; }
    cp -r "$HOME/.rustup"/* "$CACHE_DIR/rustup/" || { echo "Failed to cache rustup files"; exit 1; }
  else
    echo "$HOME/.cargo does not exist?"
    exit 1
  fi
else
  mkdir -p $HOME/.cargo
  mkdir -p $HOME/.rustup
  cp -r "$CACHE_DIR/cargo"/* "$HOME/.cargo/" || { echo "Failed to restore cargo cache"; exit 1; }
  cp -r "$CACHE_DIR/rustup"/* "$HOME/.rustup/" || { echo "Failed to restore cargo cache"; exit 1; }
  chown -R $(whoami):$(whoami) "$HOME/.cargo"
  chown -R $(whoami):$(whoami) "$HOME/.rustup"
fi

. "$HOME/.cargo/env"

# Set default Rust toolchain
rustup default $SETUP_RUST_TOOLCHAIN

# Install other tools

if [ ! -d "$CACHE_DIR/bin" ]; then
  mkdir -p $CACHE_DIR/bin || { echo "Failed to create bin dir"; exit 1; }
fi

if [ -n "$SETUP_MDBOOK" ]; then  # Using -n instead of ! -z for better readability
  if [[ ! -f "$CACHE_DIR/bin/mdbook" || $(cat "$CACHE_DIR/bin/mdbook-cache-version") != $SETUP_MDBOOK ]]; then
    echo "Installing mdbook v$SETUP_MDBOOK..."

    temp_dir=$(mktemp -d) || { echo "Failed to create temporary directory"; exit 1; }
    
    echo "Downloading mdbook..."
    curl -L -f "${GITHUB_PROXY}https://github.com/rust-lang/mdBook/releases/download/v$SETUP_MDBOOK/mdbook-v$SETUP_MDBOOK-x86_64-unknown-linux-gnu.tar.gz" -o "$temp_dir/mdbook.tar.gz" || { echo "Failed to download mdbook"; exit 1; }

    echo "Extracting mdbook..."
    tar -xzf "$temp_dir/mdbook.tar.gz" -C "$temp_dir" || { echo "Failed to extract mdbook"; exit 1; }
    
    mv "$temp_dir/mdbook" "$CACHE_DIR/bin/" || { echo "Failed to move mdbook binary"; exit 1; }

    chmod +x "$CACHE_DIR/bin/mdbook" || { echo "Failed to make mdbook executable"; exit 1; }

    rm -rf "$temp_dir"

    echo "$SETUP_MDBOOK" > "$CACHE_DIR/bin/mdbook-cache-version"

    echo "mdbook is installed"
  else
    echo "Using cached mdbook"
  fi
fi

export PATH="$(realpath "$CACHE_DIR/bin"):$PATH"
echo "PATH=$PATH"

echo "======== VERSION ========"
echo -n "Cargo: "
cargo --version || { echo "Failed to get cargo version"; exit 1; }

echo -n "Rustup: "
rustup --version || { echo "Failed to get rustup version"; exit 1; }

if [ -n "$SETUP_MDBOOK" ]; then
  echo -n "mdBook: "
  mdbook --version || { echo "Failed to get mdbook version"; exit 1; }
fi

# Execute custom command if specified
if [ -n "$CUSTOM_CMD" ]; then
  eval "$CUSTOM_CMD"

  # Write back
  cp -r "$HOME/.cargo"/* "$CACHE_DIR/cargo/" || { echo "Failed to cache cargo dir"; exit 1; }
  cp -r "$HOME/.rustup"/* "$CACHE_DIR/rustup/" || { echo "Failed to cache rustup files"; exit 1; }
fi
