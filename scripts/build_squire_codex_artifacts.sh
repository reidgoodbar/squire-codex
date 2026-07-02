#!/usr/bin/env sh
set -eu

out_dir="${1:-.tmp/release}"
version="${VERSION:-}"
commit="${COMMIT:-}"
date_utc="${DATE_UTC:-}"
cargo_profile="${SQUIRE_CODEX_CARGO_PROFILE:-release}"

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
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
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
    windows/amd64) echo "x86_64-pc-windows-msvc" ;;
    *) echo "" ;;
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
  if [ "$goos" = "windows" ]; then
    src_binary="codex.exe"
    dest_binary="squire-codex.exe"
  fi

  echo "building $name ($rust_target)"
  (
    cd codex-rs
    case "$cargo_profile" in
      release)
        cargo build --release --target "$rust_target" -p codex-cli --bin codex
        ;;
      dev|debug)
        cargo build --target "$rust_target" -p codex-cli --bin codex
        ;;
      *)
        cargo build --profile "$cargo_profile" --target "$rust_target" -p codex-cli --bin codex
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

  cp "$built" "$stage/$dest_binary"
  chmod 0755 "$stage/$dest_binary"
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
