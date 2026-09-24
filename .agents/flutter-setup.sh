#!/usr/bin/env bash
# Shared, pinned Flutter bootstrap for Amp and OpenHands (Linux x64).
FLUTTER_VERSION=3.44.5
FLUTTER_SHA256=28aa13854feb9de44a317b97c4e886ea3f0af744027418b7e63885cfcd2951f3

flutter_root() {
  if [ "$(id -u)" -eq 0 ] || [ -w /opt ]; then
    printf '%s\n' /opt/flutter
  else
    printf '%s\n' "$HOME/.local/share/flutter"
  fi
}

setup_flutter() {
  local repo_root="$1" root parent archive stage lock_fd path_line
  root="$(flutter_root)"
  parent="$(dirname "$root")"
  mkdir -p "$parent"
  exec {lock_fd}>"$parent/.flutter.lock"
  flock "$lock_fd"

  if [ ! -x "$root/bin/flutter" ] || ! "$root/bin/flutter" --version 2>/dev/null | grep -Fq "Flutter $FLUTTER_VERSION "; then
    (
      set -e
      archive="$(mktemp "${TMPDIR:-/tmp}/flutter-${FLUTTER_VERSION}.XXXXXX.tar.xz")"
      stage="$(mktemp -d "$parent/.flutter-setup.XXXXXX")"
      # Never trust a cached or interrupted download. Keep the current SDK
      # until the archive checksum and extraction both succeed.
      trap 'rm -f "$archive"; rm -rf "$stage"' EXIT
      curl -fsSL --retry 3 -o "$archive" \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
      printf '%s  %s\n' "$FLUTTER_SHA256" "$archive" | sha256sum -c -
      tar -xJf "$archive" -C "$stage"
      if [ -e "$root" ]; then rm -rf "$root"; fi
      mv "$stage/flutter" "$root"
    )
  fi

  "$root/bin/flutter" config --no-analytics >/dev/null
  (cd "$repo_root/app" && "$root/bin/flutter" pub get)

  if [ "$(id -u)" -eq 0 ]; then
    ln -sfn "$root/bin/flutter" /usr/local/bin/flutter
    ln -sfn "$root/bin/dart" /usr/local/bin/dart
  else
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$root/bin/flutter" "$HOME/.local/bin/flutter"
    ln -sfn "$root/bin/dart" "$HOME/.local/bin/dart"
    # Login and interactive shells started after setup need the same commands.
    path_line="export PATH=\"\$HOME/.local/bin:\$PATH\" # omi Flutter"
    for profile in "$HOME/.profile" "$HOME/.bashrc"; do
      touch "$profile"
      if ! grep -Fqx "$path_line" "$profile"; then
        printf '\n%s\n' "$path_line" >> "$profile"
      fi
    done
  fi
  exec {lock_fd}>&-
}
