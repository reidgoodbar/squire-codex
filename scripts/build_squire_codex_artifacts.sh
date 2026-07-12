#!/usr/bin/env sh
set -eu

out_dir="${1:-.tmp/release}"
version="${VERSION:-}"
commit="${COMMIT:-}"
date_utc="${DATE_UTC:-}"
cargo_profile="${SQUIRE_CODEX_CARGO_PROFILE:-release}"
runtime_source_dir="${SQUIRE_RUNTIME_SOURCE_DIR:-../squire}"

case "$out_dir" in
  ""|"/"|".")
    echo "refusing unsafe output directory: $out_dir" >&2
    exit 2
    ;;
esac

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    *) echo "unknown" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) echo "unknown" ;;
  esac
}

rust_target_for() {
  case "$1/$2" in
    linux/amd64) echo "x86_64-unknown-linux-gnu" ;;
    linux/arm64) echo "aarch64-unknown-linux-gnu" ;;
    darwin/amd64) echo "x86_64-apple-darwin" ;;
    darwin/arm64) echo "aarch64-apple-darwin" ;;
    *) echo "" ;;
  esac
}

build_runtime() {
  target_os="$1"
  stage_dir="$2"
  runtime_source="$runtime_source_dir/shims/squire_hot_api.c"

  if [ ! -f "$runtime_source" ]; then
    echo "missing Squire runtime source: $runtime_source" >&2
    exit 1
  fi
  if ! command -v cc >/dev/null 2>&1; then
    echo "cc is required to build the Squire runtime" >&2
    exit 1
  fi
  case "$target_os" in
    darwin)
      cc -O3 -DNDEBUG -dynamiclib \
        -o "$stage_dir/libsquire_runtime.dylib" \
        "$runtime_source"
      ;;
    linux)
      cc -O3 -DNDEBUG -shared -fPIC \
        -o "$stage_dir/libsquire_runtime.so" \
        "$runtime_source" \
        -ldl -lcrypto
      ;;
  esac
}

if [ -z "$version" ]; then
  if git describe --tags --exact-match >/dev/null 2>&1; then
    version=$(git describe --tags --exact-match)
  else
    version=$(git describe --tags --always --dirty)
  fi
fi
if [ -z "$commit" ]; then
  commit=$(git rev-parse --short HEAD)
fi
if [ -z "$date_utc" ]; then
  date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

codex_cargo_version="${SQUIRE_CODEX_CARGO_VERSION:-}"
if [ -z "$codex_cargo_version" ]; then
  upstream_tag=$(git tag --merged HEAD --list 'rust-v*' --sort=-version:refname | head -n 1)
  if [ -z "$upstream_tag" ]; then
    echo "cannot derive Codex version; fetch upstream tags or set SQUIRE_CODEX_CARGO_VERSION" >&2
    exit 1
  fi
  upstream_version=${upstream_tag#rust-v}
  product_version=$(printf '%s' "${version#v}" | sed 's/[^0-9A-Za-z.-]/-/g')
  case "$upstream_version" in
    *+*) codex_cargo_version="${upstream_version}.squire.${product_version}" ;;
    *) codex_cargo_version="${upstream_version}+squire.${product_version}" ;;
  esac
fi

manifest="codex-rs/Cargo.toml"
lockfile="codex-rs/Cargo.lock"
manifest_backup=$(mktemp "${TMPDIR:-/tmp}/squire-codex-cargo-toml.XXXXXX")
lockfile_backup=$(mktemp "${TMPDIR:-/tmp}/squire-codex-cargo-lock.XXXXXX")
manifest_rewrite=$(mktemp "${TMPDIR:-/tmp}/squire-codex-cargo-rewrite.XXXXXX")
cp "$manifest" "$manifest_backup"
cp "$lockfile" "$lockfile_backup"
restore_workspace_manifests() {
  cp "$manifest_backup" "$manifest"
  cp "$lockfile_backup" "$lockfile"
  rm -f "$manifest_backup" "$lockfile_backup" "$manifest_rewrite"
}
trap restore_workspace_manifests EXIT
trap 'exit 1' HUP INT TERM

if ! awk -v version="$codex_cargo_version" '
  $0 == "[workspace.package]" { in_workspace_package = 1 }
  in_workspace_package && !rewritten && $1 == "version" && $2 == "=" {
    print "version = \"" version "\""
    rewritten = 1
    next
  }
  { print }
  END { if (!rewritten) exit 1 }
' "$manifest" > "$manifest_rewrite"; then
  echo "could not rewrite Codex workspace version" >&2
  exit 1
fi
mv "$manifest_rewrite" "$manifest"

rm -rf "$out_dir"
mkdir -p "$out_dir"

targets="${SQUIRE_CODEX_RELEASE_TARGETS:-"$(detect_os) $(detect_arch)"}"
checksum_files=""
set -- $targets
while [ "$#" -gt 0 ]; do
  goos="$1"
  goarch="$2"
  shift 2

  rust_target="$(rust_target_for "$goos" "$goarch")"
  if [ -z "$rust_target" ]; then
    echo "unsupported target: $goos/$goarch" >&2
    exit 2
  fi

  name="squire-codex_${version}_${goos}_${goarch}"
  stage="$out_dir/$name"
  mkdir -p "$stage"

  src_binary="codex"
  dest_binary="squire-codex"
  helper_binary="codex-code-mode-host"
  echo "building $name ($rust_target)"
  (
    cd codex-rs
    case "$cargo_profile" in
      release)
        cargo build --release --target "$rust_target" -p codex-cli --bin codex
        cargo build --release --target "$rust_target" -p codex-code-mode-host --bin codex-code-mode-host
        ;;
      dev|debug)
        cargo build --target "$rust_target" -p codex-cli --bin codex
        cargo build --target "$rust_target" -p codex-code-mode-host --bin codex-code-mode-host
        ;;
      *)
        cargo build --profile "$cargo_profile" --target "$rust_target" -p codex-cli --bin codex
        cargo build --profile "$cargo_profile" --target "$rust_target" -p codex-code-mode-host --bin codex-code-mode-host
        ;;
    esac
  )

  target_root="${CARGO_TARGET_DIR:-codex-rs/target}"
  profile_dir="$cargo_profile"
  case "$cargo_profile" in
    dev) profile_dir="debug" ;;
  esac
  built="$target_root/$rust_target/$profile_dir/$src_binary"
  if [ ! -f "$built" ]; then
    echo "missing built binary: $built" >&2
    exit 1
  fi
  built_helper="$target_root/$rust_target/$profile_dir/$helper_binary"
  if [ ! -f "$built_helper" ]; then
    echo "missing built runtime helper: $built_helper" >&2
    exit 1
  fi

  cp "$built" "$stage/$dest_binary"
  cp "$built_helper" "$stage/$helper_binary"
  build_runtime "$goos" "$stage"
  if [ -f "$stage/libsquire_runtime.dylib" ] || [ -f "$stage/libsquire_runtime.so" ]; then
    printf '1\n' > "$stage/SQUIRE_RUNTIME_ABI"
  fi
  chmod 0755 "$stage/$dest_binary"
  chmod 0755 "$stage/$helper_binary"
  if [ -f "$stage/libsquire_runtime.dylib" ]; then
    chmod 0755 "$stage/libsquire_runtime.dylib"
  fi
  if [ -f "$stage/libsquire_runtime.so" ]; then
    chmod 0755 "$stage/libsquire_runtime.so"
  fi
  cp SQUIRE_CODEX.md README.md LICENSE NOTICE "$stage/"

  cat > "$stage/BUILD_INFO.txt" <<EOF
Squire Codex release artifact
version: $version
commit: $commit
date: $date_utc
target: $goos/$goarch
rust_target: $rust_target
profile: $cargo_profile
binary: $dest_binary
runtime_helper: $helper_binary
runtime_abi: 1
codex_cargo_version: $codex_cargo_version
EOF

  archive="$out_dir/$name.tar.gz"
  (cd "$out_dir" && tar -czf "$name.tar.gz" "$name")
  rm -rf "$stage"
  checksum_files="$checksum_files $(basename "$archive")"
done

(
  cd "$out_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sha256sum $checksum_files > SHA256SUMS
  else
    # shellcheck disable=SC2086
    shasum -a 256 $checksum_files > SHA256SUMS
  fi
)

cat > "$out_dir/RELEASE_MANIFEST.txt" <<EOF
Squire Codex release artifacts
version: $version
commit: $commit
date: $date_utc

Artifacts:
$checksum_files

Verify:
  shasum -a 256 -c SHA256SUMS
  # or, on Linux:
  sha256sum -c SHA256SUMS
EOF

echo "squire_codex_release_artifacts: $out_dir"
