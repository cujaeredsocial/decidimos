#!/usr/bin/env bash
# Ensures a local, read-only copy of the Decidim source + docs for the EXACT
# version an app uses, and prints its path.
#
# Usage:
#   bash decidim-src.sh                 # version from ./Gemfile.lock (or Gemfile)
#   bash decidim-src.sh /path/to/app    # version from that app
#   bash decidim-src.sh 0.32.2          # explicit version
#   bash decidim-src.sh latest          # newest stable release on RubyGems
#
# Output (stdout, last line): absolute path of the source tree, e.g.
#   ~/.cache/decidim-src/v0.31.5
set -euo pipefail

CACHE="${DECIDIM_SRC_CACHE:-$HOME/.cache/decidim-src}"
arg="${1:-.}"

latest_stable() {
  curl -fsS https://rubygems.org/api/v1/versions/decidim.json |
    python3 -c 'import json,sys; print(next(v["number"] for v in json.load(sys.stdin) if not v["prerelease"]))'
}

if [[ "$arg" == "latest" ]]; then
  version="$(latest_stable)"
elif [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.a-z0-9]*)?$ ]]; then
  version="$arg"
else
  app="$arg"
  version=""
  if [[ -f "$app/Gemfile.lock" ]]; then
    version="$(grep -E '^    decidim \(' "$app/Gemfile.lock" | head -1 | sed -E 's/.*\(([^)]+)\).*/\1/')"
  fi
  if [[ -z "$version" && -f "$app/Gemfile" ]]; then
    version="$(grep -E '^\s*gem "decidim",' "$app/Gemfile" | head -1 | sed -E 's/.*"([0-9][^"]*)".*/\1/')"
  fi
  if [[ -z "$version" ]]; then
    echo "ERROR: no decidim version found in $app/Gemfile.lock or Gemfile. Pass a version explicitly." >&2
    exit 1
  fi
fi

dir="$CACHE/v$version"
if [[ ! -d "$dir/decidim-core" ]]; then
  mkdir -p "$CACHE"
  echo "Cloning decidim v$version into $dir ..." >&2
  git clone -q --depth 1 --branch "v$version" https://github.com/decidim/decidim "$dir"
fi

minor="$(echo "$version" | cut -d. -f1,2)"
latest_patch="$(curl -fsS https://rubygems.org/api/v1/versions/decidim.json 2>/dev/null |
  python3 -c "import json,sys; print(next((v['number'] for v in json.load(sys.stdin) if not v['prerelease'] and v['number'].startswith('$minor.')), '?'))" 2>/dev/null || echo '?')"
echo "decidim version:          $version" >&2
echo "latest patch of $minor:   $latest_patch   (from RubyGems; if newer than the app, it is BEHIND -> check CHANGELOG/GHSA security fixes)" >&2
echo "latest stable overall:    $(latest_stable 2>/dev/null || echo 'unknown (offline)')" >&2
echo "$dir"
