#!/usr/bin/env bash
#
# lab-701.5-sca.sh — "Break & Fix" laboratory
#
#   Certification : LPI DevOps Tools Engineer — exam 701-100, version 2.0.0
#   Topic         : 701.5 Software Composition, Licensing and Open Source (weight 3.34)
#   Objectives    : https://www.lpi.org/our-certifications/exam-701-objectives/
#
# WHAT THIS SCRIPT DOES
#   It materialises a complete, offline software-composition pipeline for a fictional
#   product ("widgetd 3.2.0", distributed as a closed-source binary), proves the
#   pipeline green, then lands one realistic commit that breaks it in five places at
#   once — the way a dependency bump actually breaks compliance in production.
#   The student is told the symptom and the goal, never the cause.
#
#   Concepts exercised: dependency resolution and lock drift, transitive copyleft
#   contamination, SBOM generation (CycloneDX 1.6), SPDX declared-vs-concluded
#   licensing, license policy as code, allowlist tampering, Apache-2.0 §4(d) NOTICE
#   propagation, and advisory matching against a pinned dependency set.
#
# SAFETY CONTRACT — read before running
#   * Everything is created under a single directory ($LAB_ROOT, default
#     ~/lab-701.5). Nothing outside it is written, moved or deleted.
#   * No network access is required. No system service is touched. No systemd unit,
#     no firewall rule, no package is removed. The only optional system change is
#     installing 'jq', and only after you confirm it.
#   * Do not run as root; the lab does not need it.
#   * Still: run it on a disposable lab VM. That is what it is for.
#   * './lab-701.5-sca.sh cleanup' removes the lab directory and nothing else.
#
# USAGE
#   ./lab-701.5-sca.sh setup      # build the lab, prove it green, then break it
#   ./lab-701.5-sca.sh verify     # run the release pipeline and grade your fix
#   ./lab-701.5-sca.sh brief      # reprint the mission brief
#   ./lab-701.5-sca.sh solution   # print the step-by-step solution (also at EOF)
#   ./lab-701.5-sca.sh cleanup    # delete $LAB_ROOT
#
set -Eeuo pipefail

LAB_ROOT="${LAB_ROOT:-$HOME/lab-701.5}"
MARKER=".lab-701.5-marker"
PRODUCT="widgetd"
PRODUCT_VERSION="3.2.0"

if [ -t 1 ]; then
  C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
  C_B=$'\033[1;34m'; C_D=$'\033[2m';    C_N=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_D=; C_N=
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s::%s %s\n' "$C_B" "$C_N" "$*"; }
good() { printf '%sok:%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_Y" "$C_N" "$*"; }
die()  { printf '%sfatal:%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 2; }
rule() { printf '%s%s%s\n' "$C_D" "--------------------------------------------------------------------------" "$C_N"; }

confirm() {
  # confirm <question> ; honours LAB_YES=1 for unattended runs
  local q="$1" ans
  if [ "${LAB_YES:-0}" = "1" ]; then return 0; fi
  if [ ! -r /dev/tty ]; then
    die "non-interactive run: re-run with LAB_YES=1 if this really is a disposable VM"
  fi
  printf '%s [y/N] ' "$q" > /dev/tty
  read -r ans < /dev/tty || true
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

preflight() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 required (associative arrays)"
  if [ "$(id -u)" -eq 0 ] && [ "${ALLOW_ROOT:-0}" != "1" ]; then
    die "refusing to run as root; this lab needs no privileges (override: ALLOW_ROOT=1)"
  fi
  local missing=()
  for c in awk sed grep sort head tar sha256sum find date; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing core utilities: ${missing[*]}"
  ensure_jq
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  local pm=""
  for c in apt-get dnf zypper apk pacman; do
    command -v "$c" >/dev/null 2>&1 && { pm="$c"; break; }
  done
  warn "'jq' is not installed; the SBOM tooling in this lab is built around it."
  if [ -z "$pm" ]; then
    die "install jq with your package manager and re-run"
  fi
  local cmd
  case "$pm" in
    apt-get) cmd="sudo apt-get update && sudo apt-get install -y jq" ;;
    dnf)     cmd="sudo dnf install -y jq" ;;
    zypper)  cmd="sudo zypper --non-interactive install jq" ;;
    apk)     cmd="sudo apk add --no-cache jq" ;;
    pacman)  cmd="sudo pacman -S --noconfirm jq" ;;
  esac
  say "    proposed command: $cmd"
  confirm "Install jq now?" || die "aborted; install jq manually and re-run"
  bash -c "$cmd" || die "jq installation failed"
  command -v jq >/dev/null 2>&1 || die "jq still not on PATH"
}

# --------------------------------------------------------------------------
# Vendor registry helpers
# --------------------------------------------------------------------------

license_text() {
  # license_text <spdx-id> <holder>
  local id="$1" holder="$2"
  case "$id" in
    MIT)
      cat <<EOF_MIT
MIT License

Copyright (c) 2026 $holder

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
EOF_MIT
      ;;
    BSD-3-Clause)
      cat <<EOF_BSD3
Copyright (c) 2026, $holder
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
EOF_BSD3
      ;;
    Apache-2.0)
      cat <<EOF_APACHE
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

Copyright 2026 $holder

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

[Lab note: the 11-section normative text is abridged here. Section 4(d) is the
 one that has teeth for a redistributor: if the work includes a NOTICE file,
 you must carry its attribution notices into your own distribution.]
EOF_APACHE
      ;;
    GPL-3.0-only)
      cat <<EOF_GPL
                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

Copyright (C) 2026 $holder

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, version 3 of the License.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

Full text: https://www.gnu.org/licenses/gpl-3.0.txt

[Lab note: abridged. The operative clauses for a redistributor are 5 (modified
 source), 6 (corresponding source for object code) and 10 (no further
 restrictions). Conveying a binary that incorporates this work obliges you to
 offer the complete corresponding source of the whole combined work under GPLv3.]
EOF_GPL
      ;;
    MPL-2.0)
      cat <<EOF_MPL
Mozilla Public License Version 2.0

Copyright (c) 2026 $holder

This Source Code Form is subject to the terms of the Mozilla Public License,
v. 2.0. If a copy of the MPL was not distributed with this file, You can
obtain one at https://mozilla.org/MPL/2.0/.

[Lab note: abridged. MPL-2.0 is file-level (weak) copyleft: obligations attach
 to the covered files, not to your whole binary, but section 3.2 still requires
 you to make the source of those files available to recipients.]
EOF_MPL
      ;;
    Zlib)
      cat <<EOF_ZLIB
Copyright (c) 2026 $holder

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use
of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it freely,
subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
EOF_ZLIB
      ;;
    *)
      say "License text for $id, copyright 2026 $holder. (lab placeholder)"
      ;;
  esac
}

mkpkg() {
  # mkpkg <name> <version> <declared-license> <holder> <homepage> [requires...]
  local name="$1" ver="$2" lic="$3" holder="$4" home="$5"; shift 5
  local dir="$LAB_ROOT/vendor/$name/$ver"
  mkdir -p "$dir"
  {
    printf 'name=%s\n'     "$name"
    printf 'version=%s\n'  "$ver"
    printf 'license=%s\n'  "$lic"
    printf 'homepage=%s\n' "$home"
    printf 'purl=pkg:generic/%s@%s\n' "$name" "$ver"
    printf 'requires=%s\n' "$*"
  } > "$dir/package.meta"
  # The LICENSE text is deliberately the authoritative artefact: 'license=' in
  # the metadata is only what upstream *declared*, and upstream is often wrong.
  license_text "${lic}" "$holder" > "$dir/LICENSE"
}

build_vendor_registry() {
  mkpkg fastcsv      1.4.2 MIT          "fastcsv contributors"   "https://example.invalid/fastcsv"
  mkpkg fastcsv      2.0.0 MIT          "fastcsv contributors"   "https://example.invalid/fastcsv" "gpl-tabulate==3.1.0"
  mkpkg gpl-tabulate 3.1.0 GPL-3.0-only "The Tabulate Project"   "https://example.invalid/gpl-tabulate"
  mkpkg zlibish      1.0.7 Zlib         "zlibish authors"        "https://example.invalid/zlibish"
  mkpkg mpl-metrics  2.3.0 MPL-2.0      "Metrics Collective"     "https://example.invalid/mpl-metrics"
  mkpkg idna-mini    1.2.0 BSD-3-Clause "The idna-mini Authors"  "https://example.invalid/idna-mini"

  # libyaml-ng 0.4.1 declares a clean SPDX id. 0.5.0 -- a legitimate security
  # release -- regressed its metadata to the ambiguous string "BSD". The LICENSE
  # text did not change. This is the single most common real-world SCA finding.
  mkpkg libyaml-ng   0.4.1 BSD-3-Clause "libyaml-ng developers"  "https://example.invalid/libyaml-ng"
  mkpkg libyaml-ng   0.5.0 BSD          "libyaml-ng developers"  "https://example.invalid/libyaml-ng"
  license_text BSD-3-Clause "libyaml-ng developers" > "$LAB_ROOT/vendor/libyaml-ng/0.5.0/LICENSE"

  local v
  for v in 0.9.0 0.9.3; do
    mkpkg httpx-lite "$v" Apache-2.0 "The httpx-lite Authors" "https://example.invalid/httpx-lite" "idna-mini==1.2.0"
    cat > "$LAB_ROOT/vendor/httpx-lite/$v/NOTICE" <<'EOF_NOTICE'
httpx-lite
Copyright 2023-2026 The httpx-lite Authors

This product includes software developed at the httpx-lite project
(https://example.invalid/httpx-lite).

Portions of the URL parser are derived from idna-mini (BSD-3-Clause),
Copyright 2019 The idna-mini Authors.
EOF_NOTICE
  done
}

# --------------------------------------------------------------------------
# The product, the policy, and the pipeline
# --------------------------------------------------------------------------

build_app() {
  mkdir -p "$LAB_ROOT/app/src"

  cat > "$LAB_ROOT/app/manifest.txt" <<'EOF_MANIFEST'
# widgetd 3.2.0 -- direct runtime dependencies, one "name==version" per line.
# This file is human-owned. app/requirements.lock is generated from it.
fastcsv==1.4.2
libyaml-ng==0.4.1
zlibish==1.0.7
mpl-metrics==2.3.0
EOF_MANIFEST

  license_text Apache-2.0 "Example Widgets, Inc." > "$LAB_ROOT/app/LICENSE"

  cat > "$LAB_ROOT/app/NOTICE" <<'EOF_APPNOTICE'
widgetd
Copyright 2024-2026 Example Widgets, Inc.

This product includes third-party open source software. The complete list, with
versions, SPDX identifiers and full license texts, is generated at build time
into build/THIRD-PARTY-NOTICES.txt and shipped inside the release tarball.

--- Apache License 2.0, section 4(d): upstream NOTICE propagation ---
Every Apache-2.0 dependency that ships its own NOTICE file must have its
attribution text reproduced verbatim below, under a "## name==version" heading.
EOF_APPNOTICE

  cat > "$LAB_ROOT/app/src/widgetd.sh" <<'EOF_SRC'
#!/usr/bin/env bash
# widgetd -- lab stand-in for the product binary. The code is irrelevant here;
# what matters is everything it links against.
echo "widgetd 3.2.0"
EOF_SRC
  chmod +x "$LAB_ROOT/app/src/widgetd.sh"
}

build_policy() {
  mkdir -p "$LAB_ROOT/policy"

  cat > "$LAB_ROOT/policy/spdx-ids.txt" <<'EOF_SPDX'
# Subset of the SPDX License List (https://spdx.org/licenses/) recognised by
# this pipeline. A string that is not on this list is NOT a license identifier,
# it is a guess. CI-owned file: do not edit.
MIT
Apache-2.0
BSD-2-Clause
BSD-3-Clause
ISC
Zlib
BSL-1.0
CC0-1.0
Unlicense
PostgreSQL
Python-2.0
MPL-2.0
EPL-2.0
CDDL-1.0
LGPL-2.1-only
LGPL-3.0-only
GPL-2.0-only
GPL-3.0-only
AGPL-3.0-only
SSPL-1.0
Elastic-2.0
EOF_SPDX

  cat > "$LAB_ROOT/policy/policy.conf" <<'EOF_POLICY'
# widgetd supply-chain license policy.
# Distribution model: proprietary binary shipped to customers + hosted SaaS.
#
#   allow  -> permissive; notice-and-attribution obligations only.
#   review -> weak/file-level copyleft or source-availability duties. Usable,
#             but only with a recorded entry in policy/exceptions.txt.
#   deny   -> strong or network copyleft, or non-OSI source-available terms.
#             NOT waivable by engineering. Changing the distribution model or
#             removing the dependency are the only two answers.
allow MIT
allow Apache-2.0
allow BSD-2-Clause
allow BSD-3-Clause
allow ISC
allow Zlib
allow BSL-1.0
allow CC0-1.0
allow Unlicense
review MPL-2.0
review EPL-2.0
review LGPL-2.1-only
review LGPL-3.0-only
deny GPL-2.0-only
deny GPL-3.0-only
deny AGPL-3.0-only
deny SSPL-1.0
deny Elastic-2.0
EOF_POLICY

  printf '%s\n' \
    '# Concluded licenses (SPDX "concluded" vs "declared").' \
    '# Use this when upstream metadata is absent, ambiguous or wrong, AFTER reading' \
    '# the actual LICENSE text in vendor/<name>/<version>/LICENSE.' \
    '# Format, TAB-separated:  name==version <TAB> SPDX-id <TAB> justification' \
    > "$LAB_ROOT/policy/overrides.conf"

  {
    printf '%s\n' '# Approved exceptions for "review" category licenses.'
    printf '%s\n' '# Format, TAB-separated: name==version <TAB> SPDX-id <TAB> expires(YYYY-MM-DD) <TAB> ticket <TAB> justification'
    printf 'mpl-metrics==2.3.0\tMPL-2.0\t2027-12-31\tWD-3902\tLinked unmodified; MPL-2.0 obligations are file-level and the corresponding source is republished on our mirror.\n'
  } > "$LAB_ROOT/policy/exceptions.txt"

  {
    printf '%s\n' '# Local advisory database, OSV-shaped. CI-owned file: do not edit.'
    printf '%s\n' '# id <TAB> package <TAB> introduced <TAB> fixed <TAB> severity <TAB> summary <TAB> reference'
    printf 'LAB-2026-0001\thttpx-lite\t0.9.0\t0.9.3\tHIGH\tCRLF injection in the request path permits header smuggling\thttps://osv.dev/\n'
    printf 'LAB-2025-0042\tzlibish\t1.0.0\t1.0.6\tMEDIUM\tOut-of-bounds read in inflate() on truncated streams\thttps://osv.dev/\n'
  } > "$LAB_ROOT/policy/advisories.tsv"
}

build_pipeline() {
  mkdir -p "$LAB_ROOT/bin"

  cat > "$LAB_ROOT/bin/lib.sh" <<'EOF_LIB'
#!/usr/bin/env bash
# Shared helpers for the widgetd supply-chain pipeline. CI-owned.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
mkdir -p "$BUILD" "$DIST"

if [ -t 1 ]; then
  G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=; R=; Y=; D=; N=
fi
pass() { printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; }
hint() { printf '        %s%s%s\n' "$D" "$*" "$N"; }
abort(){ printf '  %sERROR%s %s\n' "$R" "$N" "$*" >&2; exit 2; }

meta_get() { # meta_get <package.meta> <key>
  awk -F'=' -v k="$2" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

spdx_valid() { grep -qxF -- "$1" "$ROOT/policy/spdx-ids.txt"; }

override_for() { # override_for <name==version>  -> concluded SPDX id or empty
  awk -F'\t' -v s="$1" '!/^#/ && $1==s { print $2; exit }' "$ROOT/policy/overrides.conf"
}

policy_category() { # policy_category <license-string> -> allow|review|deny|unclassified
  local c
  c="$(awk -v l="$1" '!/^#/ && NF==2 && $2==l { print $1; exit }' "$ROOT/policy/policy.conf")"
  printf '%s' "${c:-unclassified}"
}

exception_expiry() { # exception_expiry <name==version> -> YYYY-MM-DD or empty
  awk -F'\t' -v s="$1" '!/^#/ && $1==s { print $3; exit }' "$ROOT/policy/exceptions.txt"
}

manifest_specs() {
  awk '{ sub(/#.*/, ""); gsub(/[ \t]/, "") } NF' "$ROOT/app/manifest.txt"
}

ver_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
ver_ge() { ! ver_lt "$1" "$2"; }
EOF_LIB

  cat > "$LAB_ROOT/bin/integrity.sh" <<'EOF_INTEGRITY'
#!/usr/bin/env bash
# Step 0 -- the pipeline and the evidence it reads are not the developer's to
# edit locally. Silencing a scanner is not a fix; it is the incident.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"
if sha256sum --quiet -c bin/.sha256sums 2>/dev/null; then
  pass "pipeline, SPDX list, advisory DB and vendor registry unmodified"
else
  fail "pipeline tampering detected -- a CI-owned or vendor file was modified"
  hint "the files above must be restored; compliance findings are fixed in"
  hint "app/manifest.txt, app/NOTICE and policy/{policy,overrides,exceptions}.conf"
  exit 1
fi
EOF_INTEGRITY

  cat > "$LAB_ROOT/bin/resolve.sh" <<'EOF_RESOLVE'
#!/usr/bin/env bash
# Step 1 -- breadth-first dependency resolution over the vendor registry.
# Emits build/resolved.tsv:  name <TAB> version <TAB> introduced-by
#   --write-lock  refresh app/requirements.lock from the resolved graph
#   --check       fail if the lock does not match the resolved graph (drift)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODE="${1:-}"
LOCK="$ROOT/app/requirements.lock"
OUT="$BUILD/resolved.tsv"

declare -A SEEN VER_OF
queue=(); parents=()
while read -r spec; do queue+=("$spec"); parents+=("(direct)"); done < <(manifest_specs)

: > "$OUT"
i=0
while [ "$i" -lt "${#queue[@]}" ]; do
  spec="${queue[$i]}"; parent="${parents[$i]}"; i=$((i + 1))
  case "$spec" in *"=="*) : ;; *) abort "malformed requirement '$spec' (want name==version)";; esac
  name="${spec%%==*}"; ver="${spec#*==}"
  meta="$ROOT/vendor/$name/$ver/package.meta"
  [ -f "$meta" ] || abort "'$spec' is not in the vendor registry (required by $parent)"
  if [ -n "${VER_OF[$name]:-}" ] && [ "${VER_OF[$name]}" != "$ver" ]; then
    abort "version conflict on $name: ${VER_OF[$name]} vs $ver (via $parent)"
  fi
  [ -z "${SEEN[$spec]:-}" ] || continue
  SEEN[$spec]=1; VER_OF[$name]="$ver"
  printf '%s\t%s\t%s\n' "$name" "$ver" "$parent" >> "$OUT"
  for child in $(meta_get "$meta" requires); do
    queue+=("$child"); parents+=("$spec")
  done
done
sort -o "$OUT" "$OUT"

resolved_specs() { awk -F'\t' '{ printf "%s==%s\n", $1, $2 }' "$OUT" | sort; }

case "$MODE" in
  --write-lock)
    { echo "# Generated by bin/resolve.sh from app/manifest.txt -- do not edit by hand."
      resolved_specs; } > "$LOCK"
    pass "lock refreshed: $(resolved_specs | wc -l) components"
    ;;
  --check)
    if [ ! -f "$LOCK" ]; then fail "app/requirements.lock is missing"; exit 1; fi
    if diff -u <(grep -v '^#' "$LOCK" | sed '/^$/d' | sort) <(resolved_specs) > "$BUILD/lock.diff"; then
      pass "lock is in sync with the manifest ($(resolved_specs | wc -l) components)"
    else
      fail "lock drift: app/requirements.lock does not describe app/manifest.txt"
      sed -n '3,$p' "$BUILD/lock.diff" | sed 's/^/        /'
      hint "regenerate with: ./bin/resolve.sh --write-lock"
      exit 1
    fi
    ;;
  *) cat "$OUT" ;;
esac
EOF_RESOLVE

  cat > "$LAB_ROOT/bin/why.sh" <<'EOF_WHY'
#!/usr/bin/env bash
# Diagnostic -- why is this package in my dependency graph?
#   ./bin/why.sh <package-name>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 1 ] || abort "usage: ./bin/why.sh <package-name>"
[ -f "$BUILD/resolved.tsv" ] || "$ROOT/bin/resolve.sh" > /dev/null
target="$1"
line="$(awk -F'\t' -v n="$target" '$1==n { print; exit }' "$BUILD/resolved.tsv")"
[ -n "$line" ] || abort "$target is not in the resolved graph"
chain=()
spec="$(printf '%s' "$line" | awk -F'\t' '{ printf "%s==%s", $1, $2 }')"
parent="$(printf '%s' "$line" | cut -f3)"
chain+=("$spec")
guard=0
while [ "$parent" != "(direct)" ] && [ "$guard" -lt 32 ]; do
  chain+=("$parent")
  pn="${parent%%==*}"
  parent="$(awk -F'\t' -v n="$pn" '$1==n { print $3; exit }' "$BUILD/resolved.tsv")"
  guard=$((guard + 1))
done
printf 'app/manifest.txt'
for (( j=${#chain[@]}-1; j>=0; j-- )); do printf ' -> %s' "${chain[$j]}"; done
printf '\n'
meta="$ROOT/vendor/${target}/$(printf '%s' "$line" | cut -f2)/package.meta"
printf 'declared license: %s\n' "$(meta_get "$meta" license)"
printf 'license text    : %s\n' "${meta%/package.meta}/LICENSE"
EOF_WHY

  cat > "$LAB_ROOT/bin/sbom-gen.sh" <<'EOF_SBOM'
#!/usr/bin/env bash
# Step 2 -- CycloneDX 1.6 SBOM from the resolved graph.
# The "acknowledgement" field records whether a license came from upstream
# metadata (declared) or from our own reading of the LICENSE text (concluded).
# A string that is not a valid SPDX id goes into license.name, never license.id.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -f "$BUILD/resolved.tsv" ] || "$ROOT/bin/resolve.sh" > /dev/null

COMPS="$BUILD/.components.ndjson"; : > "$COMPS"
DEPS="$BUILD/.deps.ndjson";        : > "$DEPS"
ROOT_REF="pkg:generic/widgetd@3.2.0"

refs_of() { # refs_of <requires string> -> JSON array of bom-refs
  local r out=""
  for r in $1; do out+="pkg:generic/${r%%==*}@${r#*==}"$'\n'; done
  printf '%s' "$out" | jq -R 'select(length > 0)' | jq -s '.'
}

jq -n --arg ref "$ROOT_REF" --argjson on "$(refs_of "$(manifest_specs | tr '\n' ' ')")" \
  '{ref: $ref, dependsOn: $on}' >> "$DEPS"

while IFS=$'\t' read -r name ver parent; do
  meta="$ROOT/vendor/$name/$ver/package.meta"
  declared="$(meta_get "$meta" license)"
  concluded="$(override_for "$name==$ver")"
  if [ -n "$concluded" ]; then lic="$concluded"; ack="concluded"; else lic="$declared"; ack="declared"; fi
  if spdx_valid "$lic"; then key="id"; else key="name"; fi
  jq -n \
     --arg n "$name" --arg v "$ver" --arg purl "$(meta_get "$meta" purl)" \
     --arg home "$(meta_get "$meta" homepage)" --arg lic "$lic" \
     --arg ack "$ack" --arg key "$key" --arg decl "$declared" --arg parent "$parent" \
     '{
        type: "library",
        "bom-ref": $purl,
        name: $n,
        version: $v,
        purl: $purl,
        licenses: [ { license: ((if $key == "id" then {id: $lic} else {name: $lic} end)
                                + {acknowledgement: $ack}) } ],
        externalReferences: [ {type: "website", url: $home} ],
        properties: [ {name: "lab:declaredLicense", value: $decl},
                      {name: "lab:introducedBy",    value: $parent} ]
      }' >> "$COMPS"
  jq -n --arg ref "$(meta_get "$meta" purl)" --argjson on "$(refs_of "$(meta_get "$meta" requires)")" \
     '{ref: $ref, dependsOn: $on}' >> "$DEPS"
done < "$BUILD/resolved.tsv"

jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg serial "urn:uuid:$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 00000000-0000-4000-8000-000000000000)" \
  --arg ref "$ROOT_REF" \
  --argjson components "$(jq -s '.' "$COMPS")" \
  --argjson dependencies "$(jq -s '.' "$DEPS")" \
  '{
     bomFormat: "CycloneDX",
     specVersion: "1.6",
     serialNumber: $serial,
     version: 1,
     metadata: {
       timestamp: $ts,
       tools: { components: [ {type: "application", name: "lab-sbom-gen", version: "1.0.0"} ] },
       component: { type: "application", "bom-ref": $ref, name: "widgetd", version: "3.2.0",
                    licenses: [ {license: {id: "Apache-2.0", acknowledgement: "declared"}} ] }
     },
     components: $components,
     dependencies: $dependencies
   }' > "$BUILD/sbom.cdx.json"

jq -e '.components | length > 0' "$BUILD/sbom.cdx.json" > /dev/null \
  || abort "SBOM generated with no components"
pass "build/sbom.cdx.json written ($(jq '.components | length' "$BUILD/sbom.cdx.json") components, CycloneDX 1.6)"
EOF_SBOM

  cat > "$LAB_ROOT/bin/policy-lint.sh" <<'EOF_LINT'
#!/usr/bin/env bash
# Step 3 -- the policy is code, so the policy gets linted too.
# A policy that classifies strings which are not SPDX identifiers does not
# classify anything: it just makes the gate green.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
errors=0
today="$(date -u +%F)"

while read -r cat tok; do
  [ -n "${tok:-}" ] || continue
  case "$cat" in allow|review|deny) : ;; *) fail "policy.conf: unknown category '$cat'"; errors=$((errors+1)); continue ;; esac
  case "$tok" in
    NOASSERTION|NONE|UNKNOWN)
      fail "policy.conf: '$cat $tok' -- placeholders must never be classified"
      hint "NOASSERTION means 'nobody looked yet'. Allowing it allows everything."
      errors=$((errors+1)); continue ;;
  esac
  if ! spdx_valid "$tok"; then
    fail "policy.conf: '$cat $tok' -- '$tok' is not an SPDX identifier"
    hint "e.g. 'BSD' is ambiguous: BSD-2-Clause, BSD-3-Clause and BSD-4-Clause"
    hint "differ, and the 4-clause advertising variant is GPL-incompatible."
    errors=$((errors+1))
  fi
done < <(awk '!/^#/ && NF==2 { print $1, $2 }' "$ROOT/policy/policy.conf")

dupes="$(awk '!/^#/ && NF==2 { print $2 }' "$ROOT/policy/policy.conf" | sort | uniq -d)"
if [ -n "$dupes" ]; then
  fail "policy.conf: identifier classified in more than one category: $(echo $dupes)"
  errors=$((errors+1))
fi

while IFS=$'\t' read -r spec lic why; do
  [ -n "${spec:-}" ] || continue
  [ -f "$ROOT/vendor/${spec%%==*}/${spec#*==}/package.meta" ] \
    || { fail "overrides.conf: '$spec' is not in the vendor registry"; errors=$((errors+1)); }
  spdx_valid "${lic:-}" \
    || { fail "overrides.conf: '${lic:-<empty>}' is not an SPDX identifier"; errors=$((errors+1)); }
  [ "${#why}" -ge 20 ] \
    || { fail "overrides.conf: '$spec' needs a justification (>= 20 chars) naming the evidence"; errors=$((errors+1)); }
done < <(grep -v '^#' "$ROOT/policy/overrides.conf" | sed '/^[[:space:]]*$/d')

while IFS=$'\t' read -r spec lic exp ticket why; do
  [ -n "${spec:-}" ] || continue
  if [ "$(policy_category "${lic:-}")" != "review" ]; then
    fail "exceptions.txt: '$spec' claims $lic, which is not in the 'review' category"
    hint "'deny' is not waivable with an exception -- that is the point of 'deny'."
    errors=$((errors+1))
  fi
  [ -n "${ticket:-}" ] || { fail "exceptions.txt: '$spec' has no approval ticket"; errors=$((errors+1)); }
  [ -n "${why:-}" ]    || { fail "exceptions.txt: '$spec' has no justification"; errors=$((errors+1)); }
  if [ -z "${exp:-}" ] || [ "$exp" \< "$today" ]; then
    fail "exceptions.txt: '$spec' exception expired on ${exp:-<none>}"
    errors=$((errors+1))
  fi
done < <(grep -v '^#' "$ROOT/policy/exceptions.txt" | sed '/^[[:space:]]*$/d')

[ "$errors" -eq 0 ] || exit 1
pass "policy.conf, overrides.conf and exceptions.txt are well-formed"
EOF_LINT

  cat > "$LAB_ROOT/bin/license-gate.sh" <<'EOF_GATE'
#!/usr/bin/env bash
# Step 4 -- classify every SBOM component against the policy.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -f "$BUILD/sbom.cdx.json" ] || abort "no SBOM; run ./bin/sbom-gen.sh first"
violations=0
printf '  %-22s %-12s %-16s %-11s %s\n' COMPONENT VERSION LICENSE SOURCE VERDICT
printf '  %s\n' "$D------------------------------------------------------------------------------$N"

while IFS=$'\t' read -r name ver lic ack parent; do
  spec="$name==$ver"
  cat="$(policy_category "$lic")"
  verdict="ok"
  case "$cat" in
    allow)  verdict="allowed" ;;
    review)
      exp="$(exception_expiry "$spec")"
      if [ -n "$exp" ] && [ "$exp" \> "$(date -u +%F)" ]; then
        verdict="review/excepted until $exp"
      else
        verdict="REVIEW, NO EXCEPTION"; violations=$((violations + 1))
      fi ;;
    deny)        verdict="DENIED";        violations=$((violations + 1)) ;;
    unclassified) verdict="UNCLASSIFIED"; violations=$((violations + 1)) ;;
  esac
  printf '  %-22s %-12s %-16s %-11s %s\n' "$name" "$ver" "$lic" "$ack" "$verdict"
  case "$cat" in
    deny)
      fail "$spec is $lic ($cat) -- introduced by $parent"
      hint "widgetd is conveyed as a closed-source binary; strong copyleft would"
      hint "extend to the whole combined work. 'deny' is not waivable here."
      hint "trace it with: ./bin/why.sh $name" ;;
    unclassified)
      fail "$spec carries '$lic', which the policy does not classify"
      hint "if it is not a valid SPDX id the SBOM stores it under license.name;"
      hint "read vendor/$name/$ver/LICENSE and record a concluded license." ;;
    review)
      [ "$verdict" = "REVIEW, NO EXCEPTION" ] && fail "$spec ($lic) needs an approved entry in policy/exceptions.txt" ;;
  esac
done < <(jq -r '.components[]
                | [ .name, .version,
                    (.licenses[0].license.id // .licenses[0].license.name // "NOASSERTION"),
                    (.licenses[0].license.acknowledgement // "declared"),
                    ((.properties[]? | select(.name == "lab:introducedBy") | .value) // "(direct)") ]
                | @tsv' "$BUILD/sbom.cdx.json")

echo
[ "$violations" -eq 0 ] || { fail "$violations license policy violation(s)"; exit 1; }
pass "every component is classified and permitted by policy"
EOF_GATE

  cat > "$LAB_ROOT/bin/attribution-check.sh" <<'EOF_ATTR'
#!/usr/bin/env bash
# Step 5 -- attribution. Two distinct obligations:
#   (a) ship the license texts and copyright notices of everything you convey
#       -> build/THIRD-PARTY-NOTICES.txt, generated, always correct;
#   (b) Apache-2.0 section 4(d): if an Apache-2.0 dependency ships a NOTICE file,
#       its attribution text must be carried into YOUR distribution
#       -> app/NOTICE, human-owned, and therefore the thing that rots.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -f "$BUILD/resolved.tsv" ] || abort "no resolved graph; run ./bin/resolve.sh first"
TPN="$BUILD/THIRD-PARTY-NOTICES.txt"
APPNOTICE="$ROOT/app/NOTICE"
errors=0

{
  echo "THIRD-PARTY SOFTWARE NOTICES FOR widgetd 3.2.0"
  echo "Generated by bin/attribution-check.sh -- do not edit."
  echo
} > "$TPN"

while IFS=$'\t' read -r name ver parent; do
  d="$ROOT/vendor/$name/$ver"
  concluded="$(override_for "$name==$ver")"
  {
    echo "================================================================"
    echo "$name $ver"
    echo "declared license : $(meta_get "$d/package.meta" license)"
    [ -n "$concluded" ] && echo "concluded license: $concluded"
    echo "homepage         : $(meta_get "$d/package.meta" homepage)"
    echo "----------------------------------------------------------------"
    cat "$d/LICENSE"
    echo
  } >> "$TPN"

  [ -f "$d/NOTICE" ] || continue
  if ! grep -qxF "## $name==$ver" "$APPNOTICE"; then
    fail "app/NOTICE has no '## $name==$ver' section, but the package ships a NOTICE"
    hint "Apache-2.0 4(d) obliges you to carry that attribution downstream."
    errors=$((errors + 1)); continue
  fi
  missing=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    grep -qxF "$l" "$APPNOTICE" || missing=$((missing + 1))
  done < "$d/NOTICE"
  if [ "$missing" -gt 0 ]; then
    fail "app/NOTICE reproduces $name==$ver only partially ($missing line(s) missing)"
    hint "the upstream NOTICE must be carried verbatim: cat $d/NOTICE"
    errors=$((errors + 1))
  else
    pass "$name==$ver upstream NOTICE reproduced verbatim"
  fi
done < "$BUILD/resolved.tsv"

pass "build/THIRD-PARTY-NOTICES.txt regenerated ($(grep -c '^====' "$TPN") components)"
[ "$errors" -eq 0 ] || exit 1
EOF_ATTR

  cat > "$LAB_ROOT/bin/vuln-scan.sh" <<'EOF_VULN'
#!/usr/bin/env bash
# Step 6 -- match the pinned dependency set against the advisory database.
# Same input as the license gate: composition is one problem, not two.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -f "$BUILD/resolved.tsv" ] || abort "no resolved graph; run ./bin/resolve.sh first"
hits=0
while IFS=$'\t' read -r id pkg introduced fixed sev summary ref; do
  [ -n "${id:-}" ] || continue
  ver="$(awk -F'\t' -v n="$pkg" '$1==n { print $2; exit }' "$BUILD/resolved.tsv")"
  [ -n "$ver" ] || continue
  if ver_ge "$ver" "$introduced" && ver_lt "$ver" "$fixed"; then
    fail "$id [$sev] $pkg==$ver -- $summary"
    hint "affected: >= $introduced, < $fixed   fixed in: $fixed   ref: $ref"
    hits=$((hits + 1))
  fi
done < <(grep -v '^#' "$ROOT/policy/advisories.tsv" | sed '/^[[:space:]]*$/d')
[ "$hits" -eq 0 ] || { fail "$hits known vulnerable component(s)"; exit 1; }
pass "no component matches a known advisory"
EOF_VULN

  cat > "$LAB_ROOT/bin/build.sh" <<'EOF_BUILD'
#!/usr/bin/env bash
# The release pipeline. Every gate runs even after one fails, so a single run
# shows the whole compliance picture instead of one symptom at a time.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAILED=()
step() {
  local label="$1"; shift
  printf '\n%s==>%s %s\n' "$Y" "$N" "$label"
  if "$@"; then :; else FAILED+=("$label"); fi
}
printf '%s widgetd %s release pipeline %s\n' "$D" "3.2.0" "$N"
step "0/6  pipeline integrity"                    "$ROOT/bin/integrity.sh"
step "1/6  dependency resolution and lock drift"  "$ROOT/bin/resolve.sh" --check
step "2/6  SBOM generation (CycloneDX 1.6)"       "$ROOT/bin/sbom-gen.sh"
step "3/6  license policy lint"                   "$ROOT/bin/policy-lint.sh"
step "4/6  license gate"                          "$ROOT/bin/license-gate.sh"
step "5/6  attribution and NOTICE propagation"    "$ROOT/bin/attribution-check.sh"
step "6/6  vulnerability scan"                    "$ROOT/bin/vuln-scan.sh"

echo; printf '%s----------------------------------------------------------%s\n' "$D" "$N"
if [ "${#FAILED[@]}" -eq 0 ]; then
  tar -czf "$DIST/widgetd-3.2.0.tar.gz" \
      -C "$ROOT" app/src app/LICENSE app/NOTICE app/requirements.lock \
      -C "$BUILD" sbom.cdx.json THIRD-PARTY-NOTICES.txt
  printf '%sRELEASE OK%s  dist/widgetd-3.2.0.tar.gz\n' "$G" "$N"
  printf '            SBOM and third-party notices are inside the tarball.\n'
  exit 0
fi
printf '%sRELEASE BLOCKED%s -- %d gate(s) failed:\n' "$R" "$N" "${#FAILED[@]}"
for f in "${FAILED[@]}"; do printf '  * %s\n' "$f"; done
exit 1
EOF_BUILD

  chmod +x "$LAB_ROOT"/bin/*.sh
}

seal_pipeline() {
  # Record hashes of everything the student is not supposed to edit: the CI
  # scripts, the SPDX list, the advisory DB and the whole vendor registry.
  ( cd "$LAB_ROOT"
    { ls bin/*.sh; echo policy/spdx-ids.txt; echo policy/advisories.tsv; find vendor -type f | sort; } \
      | xargs sha256sum > bin/.sha256sums )
}

# --------------------------------------------------------------------------
# The controlled breakage
# --------------------------------------------------------------------------

apply_breakage() {
  # One commit. Five consequences. Nothing outside $LAB_ROOT is touched.

  # (1) fastcsv 1.4.2 -> 2.0.0: the package itself is still MIT, but 2.0.0
  #     introduced a transitive dependency on gpl-tabulate 3.1.0 (GPL-3.0-only).
  # (2) libyaml-ng 0.4.1 -> 0.5.0: legitimate security bump whose upstream
  #     metadata regressed to the ambiguous string "BSD".
  # (3) httpx-lite 0.9.0 added as a direct dependency: Apache-2.0, ships an
  #     upstream NOTICE, and is the version affected by LAB-2026-0001.
  cat > "$LAB_ROOT/app/manifest.txt" <<'EOF_BROKEN'
# widgetd 3.2.0 -- direct runtime dependencies, one "name==version" per line.
# This file is human-owned. app/requirements.lock is generated from it.
fastcsv==2.0.0
libyaml-ng==0.5.0
zlibish==1.0.7
mpl-metrics==2.3.0
httpx-lite==0.9.0
EOF_BROKEN

  # (4) app/requirements.lock deliberately NOT regenerated -> lock drift.

  # (5) somebody made the gate green the fast way.
  cat >> "$LAB_ROOT/policy/policy.conf" <<'EOF_TAMPER'

# TEMP -- WD-4471: unblock the 3.2.0 release train, revert right after the audit
allow BSD
allow NOASSERTION
EOF_TAMPER

  if command -v git >/dev/null 2>&1; then
    git -C "$LAB_ROOT" add -A >/dev/null 2>&1 || true
    git -C "$LAB_ROOT" -c user.name="Dev McShipit" -c user.email="dev@example.invalid" \
        commit -q -m "feat(csv): fastcsv 2.x, http client, libyaml-ng security bump" >/dev/null 2>&1 || true
  fi
}

print_brief() {
  rule
  printf '%sMISSION BRIEF -- 701.5 Software Composition, Licensing and Open Source%s\n' "$C_B" "$C_N"
  rule
  cat <<EOF_BRIEF

CONTEXT
  You maintain ${PRODUCT} ${PRODUCT_VERSION}. It is conveyed to customers as a
  closed-source binary and also runs as a hosted service. The release pipeline
  under bin/ resolves dependencies, produces a CycloneDX 1.6 SBOM, enforces a
  license policy, propagates attribution and scans for known vulnerabilities.

  The pipeline was green this morning. One commit landed:
      "feat(csv): fastcsv 2.x, http client, libyaml-ng security bump"
  It is now red.

SYMPTOM
  \$ cd $LAB_ROOT && ./bin/build.sh
  ends in RELEASE BLOCKED, dist/ stays empty, and several gates fail at once:
  a lock that no longer describes the manifest, a policy file the linter
  rejects, a component the license gate refuses, an attribution gap, and a
  dependency matching an advisory. Some of those are consequences of the same
  change; one of them is somebody's earlier attempt to make red go away.

WHAT YOU MUST ACHIEVE
  ./bin/build.sh exits 0, prints RELEASE OK, and produces
  dist/widgetd-3.2.0.tar.gz -- under these constraints:

  1. Nothing under bin/, policy/spdx-ids.txt, policy/advisories.tsv or vendor/
     may be modified. Gate 0 hashes them. Silencing a scanner is not a fix.
  2. No GPL/AGPL identifier may be moved out of the 'deny' category, and no
     exception may be written for a denied license.
  3. Every component in the SBOM must end up carrying a valid SPDX identifier,
     and any identifier you assert yourself must be justified by evidence you
     actually read.
  4. libyaml-ng must stay at 0.5.0. It is a security release. Answer its
     license question; do not dodge it by downgrading.
  5. The advisory database is fact. Fix the exposure, not the report.

  Your editable surface is exactly: app/manifest.txt, app/requirements.lock,
  app/NOTICE, policy/policy.conf, policy/overrides.conf, policy/exceptions.txt.

TOOLS YOU HAVE
  ./bin/build.sh              the whole pipeline
  ./bin/resolve.sh            print the resolved graph (--check, --write-lock)
  ./bin/why.sh <package>      why is this thing in my dependency graph?
  ./bin/sbom-gen.sh           regenerate build/sbom.cdx.json
  jq '.components[]' build/sbom.cdx.json
  ls vendor/<name>/           which versions the registry actually offers
  git -C $LAB_ROOT log -p -1  read the commit that did this

QUESTIONS TO ANSWER WHILE YOU WORK
  * fastcsv is MIT. Why did an MIT bump create a copyleft problem?
  * What is the difference between a declared license and a concluded license,
    and which one belongs in an SBOM you hand a customer?
  * Why is "BSD" not a license identifier?
  * Which obligation is discharged by build/THIRD-PARTY-NOTICES.txt, and which
    one is not, and why can only one of them be automated away?
  * Why must 'deny' be non-waivable by the engineer who hit it?

WHEN YOU THINK YOU ARE DONE
  bash $0 verify
  bash $0 solution    # the worked answer, step by step

EOF_BRIEF
  rule
}

# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------

cmd_setup() {
  preflight
  if [ -e "$LAB_ROOT" ]; then
    if [ -f "$LAB_ROOT/$MARKER" ]; then
      warn "an existing lab is present at $LAB_ROOT"
      confirm "Delete it and start clean?" || die "aborted; nothing was changed"
      rm -rf -- "$LAB_ROOT"
    else
      die "$LAB_ROOT exists and is not a lab directory; refusing to touch it (set LAB_ROOT=<path>)"
    fi
  fi

  say ""
  info "This lab writes only under: $LAB_ROOT"
  info "It needs no network, no root, and touches no system service."
  confirm "Is this a disposable lab VM you are happy to write to?" \
    || die "aborted; nothing was changed"

  info "building the vendor registry, the product and the pipeline ..."
  mkdir -p "$LAB_ROOT"
  printf 'LPI 701-100 v2.0.0 / topic 701.5 break-and-fix lab\n' > "$LAB_ROOT/$MARKER"
  printf 'build/\ndist/\n' > "$LAB_ROOT/.gitignore"
  build_vendor_registry
  build_app
  build_policy
  build_pipeline
  seal_pipeline
  "$LAB_ROOT/bin/resolve.sh" --write-lock > /dev/null

  say ""
  info "proving the pipeline green BEFORE anything is broken"
  rule
  if "$LAB_ROOT/bin/build.sh"; then
    good "baseline is clean -- remember this output, it is your target"
  else
    die "baseline is not clean; this is a bug in the lab, not an exercise"
  fi
  rule

  if command -v git >/dev/null 2>&1; then
    git -C "$LAB_ROOT" init -q 2>/dev/null || true
    git -C "$LAB_ROOT" add -A >/dev/null 2>&1 || true
    git -C "$LAB_ROOT" -c user.name="Lab Baseline" -c user.email="lab@example.invalid" \
        commit -q -m "chore: widgetd 3.2.0 baseline, all supply-chain gates green" >/dev/null 2>&1 || true
  fi

  say ""
  info "landing the breaking commit ..."
  apply_breakage
  rm -rf "$LAB_ROOT/dist"; mkdir -p "$LAB_ROOT/dist"
  good "done -- the lab is now broken in a controlled, reversible way"

  say ""
  info "current state of the release pipeline:"
  rule
  "$LAB_ROOT/bin/build.sh" || true
  rule
  print_brief
}

cmd_verify() {
  [ -f "$LAB_ROOT/$MARKER" ] || die "no lab at $LAB_ROOT (run: $0 setup)"
  info "running the release pipeline at $LAB_ROOT"
  rule
  if "$LAB_ROOT/bin/build.sh"; then
    rule
    good "GRADED: PASS -- release artefact produced with a clean, curated SBOM."
    say ""
    say "  Check your own work before moving on:"
    say "    jq -r '.components[] | \"\\(.name)==\\(.version)  \\(.licenses[0].license.id // .licenses[0].license.name)  \\(.licenses[0].license.acknowledgement)\"' \\"
    say "       $LAB_ROOT/build/sbom.cdx.json"
    say "    tar tzf $LAB_ROOT/dist/widgetd-3.2.0.tar.gz"
    say ""
    say "  Every component should show an SPDX id, and exactly one should be"
    say "  'concluded' rather than 'declared'. If more than one is concluded,"
    say "  you asserted something you did not need to assert."
    return 0
  fi
  rule
  warn "GRADED: NOT YET -- read the failing gates above, they name the obligation."
  say  "        stuck? bash $0 solution"
  return 1
}

cmd_solution() {
  sed -n '/^# ==== SOLUTION BEGIN/,/^# ==== SOLUTION END/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
}

cmd_cleanup() {
  [ -e "$LAB_ROOT" ] || { good "nothing to remove at $LAB_ROOT"; return 0; }
  [ -f "$LAB_ROOT/$MARKER" ] || die "$LAB_ROOT is not a lab directory; refusing to delete it"
  confirm "Delete $LAB_ROOT ?" || { warn "kept"; return 0; }
  rm -rf -- "$LAB_ROOT"
  good "removed $LAB_ROOT"
}

main() {
  case "${1:-setup}" in
    setup)    cmd_setup ;;
    verify)   cmd_verify ;;
    brief)    print_brief ;;
    solution) cmd_solution ;;
    cleanup)  cmd_cleanup ;;
    -h|--help|help)
      say "usage: $0 [setup|verify|brief|solution|cleanup]"
      say "       LAB_ROOT=<path>  change the lab directory (default ~/lab-701.5)"
      say "       LAB_YES=1        answer confirmations automatically" ;;
    *) die "unknown subcommand '$1' (try: $0 --help)" ;;
  esac
}

main "$@"
exit $?

# ==== SOLUTION BEGIN ======================================================
#
# WORKED SOLUTION -- 701.5 Software Composition, Licensing and Open Source
# Do not read this until ./bin/build.sh has told you what it dislikes.
#
#   cd ~/lab-701.5      # or $LAB_ROOT
#
# ---------------------------------------------------------------------------
# STEP 0 -- read the commit before touching anything
# ---------------------------------------------------------------------------
#   git log -p -1
#
# Three version changes and one appended policy stanza. The policy stanza is
# not part of "the bump" at all -- it is a previous engineer suppressing a
# finding. Note that and come back to it.
#
# ---------------------------------------------------------------------------
# FAULT 1 -- lock drift (gate 1/6)
# ---------------------------------------------------------------------------
# Symptom: "lock drift: app/requirements.lock does not describe app/manifest.txt"
#
# The manifest is human-owned intent; the lock is the resolved, reproducible
# closure. They diverged because the manifest was edited by hand. Do NOT fix
# this first: the lock must be regenerated from a manifest that is already
# correct, so this is the LAST step. Look at what the new closure contains:
#
#   ./bin/resolve.sh
#
# Two names appear that nobody added by hand: idna-mini (pulled by httpx-lite)
# and gpl-tabulate (pulled by fastcsv 2.0.0). Transitive dependencies are the
# whole reason SCA exists -- your manifest is not your bill of materials.
#
# ---------------------------------------------------------------------------
# FAULT 2 -- transitive copyleft contamination (gate 4/6)
# ---------------------------------------------------------------------------
# Symptom: "gpl-tabulate==3.1.0 is GPL-3.0-only (deny) -- introduced by
#           fastcsv==2.0.0"
#
#   ./bin/why.sh gpl-tabulate
#   # app/manifest.txt -> fastcsv==2.0.0 -> gpl-tabulate==3.1.0
#
# fastcsv itself is still MIT. Its LICENSE did not change. What changed is what
# it *pulls in*, and GPL-3.0-only obligations attach to the combined work you
# convey: shipping widgetd as a closed-source binary that incorporates
# gpl-tabulate would oblige you to offer the complete corresponding source of
# the whole thing under GPLv3 (GPL-3.0, sections 5, 6 and 10).
#
# The policy classifies it 'deny', and 'deny' is not waivable with an
# exception -- an engineer under release pressure is exactly the wrong person
# to relicense the product. The available answers are: change the distribution
# model (a business decision, not yours), replace the dependency, or roll back.
# The registry still carries the 1.x line, which has no dependencies at all:
#
#   ls vendor/fastcsv/            # 1.4.2  2.0.0
#   sed -i 's/^fastcsv==2\.0\.0$/fastcsv==1.4.2/' app/manifest.txt
#
# (In a real repo you would also open a ticket: "fastcsv 2.x is blocked on
# gpl-tabulate; either upstream makes it optional or we migrate off." Pinning
# back is a hold, not a resolution.)
#
# ---------------------------------------------------------------------------
# FAULT 3 -- known vulnerable component (gate 6/6)
# ---------------------------------------------------------------------------
# Symptom: "LAB-2026-0001 [HIGH] httpx-lite==0.9.0 -- CRLF injection ...
#           affected: >= 0.9.0, < 0.9.3   fixed in: 0.9.3"
#
# The advisory database is CI-owned and hashed; editing it is the incident, not
# the fix. Take the fixed version, which the registry has:
#
#   ls vendor/httpx-lite/         # 0.9.0  0.9.3
#   sed -i 's/^httpx-lite==0\.9\.0$/httpx-lite==0.9.3/' app/manifest.txt
#
# Note that composition analysis answered a licensing question and a security
# question from the same resolved graph. That is why SBOM generation sits at
# the front of the pipeline rather than being a compliance afterthought.
#
# ---------------------------------------------------------------------------
# FAULT 4 -- a policy that classifies non-identifiers (gate 3/6)
# ---------------------------------------------------------------------------
# Symptom: "policy.conf: 'allow BSD' -- 'BSD' is not an SPDX identifier"
#          "policy.conf: 'allow NOASSERTION' -- placeholders must never be
#           classified"
#
#   tail -5 policy.conf
#
# Someone appended these to turn gate 4 green under release pressure. Read what
# they actually do: "BSD" allows any of BSD-2-Clause, BSD-3-Clause and the
# GPL-incompatible 4-clause advertising variant without distinguishing them,
# and "NOASSERTION" -- SPDX's word for "nobody has looked yet" -- allows
# literally every unexamined component that will ever enter the graph. The
# suppression is worse than the finding it hid.
#
#   sed -i '/^# TEMP -- WD-4471/,+2d' policy.conf
#   tail -5 policy.conf              # confirm the stanza is gone
#
# ---------------------------------------------------------------------------
# FAULT 5 -- declared vs concluded license (gate 4/6, appears after fault 4)
# ---------------------------------------------------------------------------
# Re-run and the gate now says what the suppression was hiding:
#
#   ./bin/build.sh
#   # libyaml-ng  0.5.0  BSD  declared  UNCLASSIFIED
#
# libyaml-ng 0.5.0 is a security release you were told to keep. Its metadata
# declares "BSD". Because that is not a valid SPDX identifier, bin/sbom-gen.sh
# stored it in CycloneDX's license.name, not license.id:
#
#   jq '.components[] | select(.name=="libyaml-ng") | .licenses' build/sbom.cdx.json
#
# That distinction is the point. An SBOM you hand a customer must not assert an
# identifier nobody verified. So verify it -- read the license, do not guess:
#
#   cat vendor/libyaml-ng/0.5.0/LICENSE
#
# Three numbered conditions: retain the notice in source, reproduce it in
# binary form and documentation, and -- the third one -- do not use the
# holder's name to endorse derived products. Three clauses, with the
# no-endorsement clause and without the 4-clause advertising requirement:
# that is SPDX BSD-3-Clause. Record it as a *concluded* license with the
# evidence you used (a TAB between fields; ^V TAB in vi, Ctrl-V TAB in bash):
#
#   printf 'libyaml-ng==0.5.0\tBSD-3-Clause\tConcluded from vendor/libyaml-ng/0.5.0/LICENSE: three clauses including no-endorsement, no advertising clause.\n' \
#     >> policy/overrides.conf
#
# The SBOM will now emit license.id = BSD-3-Clause with
# acknowledgement = "concluded", which is exactly the honest statement:
# upstream did not tell us, we read the text and this is our conclusion.
#
# Compare the two ways this could have been "fixed": 'allow BSD' asserts
# nothing and permits everything; the override asserts one identifier for one
# version, with a justification and an audit trail.
#
# ---------------------------------------------------------------------------
# FAULT 6 -- Apache-2.0 section 4(d) NOTICE propagation (gate 5/6)
# ---------------------------------------------------------------------------
# Symptom: "app/NOTICE has no '## httpx-lite==0.9.3' section, but the package
#           ships a NOTICE"
#
# build/THIRD-PARTY-NOTICES.txt is regenerated automatically and covers the
# license-text-and-copyright obligation for every component. It cannot cover
# this one: Apache-2.0 section 4(d) says that if the work you received includes
# a NOTICE file, you must carry its attribution notices into your own
# distribution. That is a human act of attribution, so it lives in a
# human-owned file and it is the thing that silently rots on every bump.
#
#   cat vendor/httpx-lite/0.9.3/NOTICE
#   { echo; echo "## httpx-lite==0.9.3"; cat vendor/httpx-lite/0.9.3/NOTICE; } >> app/NOTICE
#
# The checker requires the heading plus every non-empty upstream line verbatim
# -- paraphrasing someone's attribution is not attribution. idna-mini needs no
# section: it is BSD-3-Clause and ships no NOTICE, so the generated
# THIRD-PARTY-NOTICES.txt discharges it. Do not add sections you do not owe.
#
# ---------------------------------------------------------------------------
# STEP FINAL -- regenerate the lock, then verify
# ---------------------------------------------------------------------------
# Only now is the manifest correct, so only now can the lock be right:
#
#   cat app/manifest.txt
#   # fastcsv==1.4.2 / libyaml-ng==0.5.0 / zlibish==1.0.7 /
#   # mpl-metrics==2.3.0 / httpx-lite==0.9.3
#
#   ./bin/resolve.sh --write-lock
#   ./bin/build.sh
#   # RELEASE OK  dist/widgetd-3.2.0.tar.gz
#
#   bash lab-701.5-sca.sh verify
#
# Final closure: six components. Five 'declared', one 'concluded'
# (libyaml-ng). mpl-metrics stays green throughout on its recorded, ticketed,
# dated exception -- that is what the 'review' category is for, and the
# contrast with 'deny' is the whole lesson of the GPL fault.
#
#   jq -r '.components[] | "\(.name)==\(.version)  \(.licenses[0].license.id // .licenses[0].license.name)  \(.licenses[0].license.acknowledgement)"' build/sbom.cdx.json
#
# ---------------------------------------------------------------------------
# WHAT TO TAKE INTO THE EXAM, AND INTO PRODUCTION
# ---------------------------------------------------------------------------
# * Your manifest is not your bill of materials. The transitive closure is, and
#   only a resolver plus a lock file makes it reproducible.
# * A package's own license tells you nothing about the license of what it
#   pulls in. fastcsv stayed MIT the whole time.
# * Copyleft strength is the axis that matters for a distribution decision:
#   permissive (notice only) < file-level/weak (MPL, LGPL) < strong (GPL) <
#   network (AGPL). Policy categories should encode that, not vendor opinion.
# * Declared vs concluded is not bureaucracy. Upstream metadata is frequently
#   absent, stale or ambiguous; the SBOM must record which of the two you are
#   asserting, and CycloneDX 1.6 'acknowledgement' / SPDX
#   LicenseDeclared vs LicenseConcluded exist precisely for that.
# * "BSD", "GPL", "Apache" are not identifiers. SPDX ids are, and they are
#   version- and variant-specific for good reasons.
# * NOASSERTION in an allowlist is not a policy, it is the absence of one.
# * Some obligations automate (shipping license texts); some do not
#   (Apache-2.0 4(d) attribution). Know which is which before you promise a
#   customer your pipeline handles compliance.
# * A gate an engineer can waive alone is not a gate. Suppressed findings are
#   the thing to grep for first when you inherit a red pipeline.
#
# REFERENCES
#   LPI exam 701 objectives     https://www.lpi.org/our-certifications/exam-701-objectives/
#   SPDX License List           https://spdx.org/licenses/
#   SPDX specification          https://spdx.github.io/spdx-spec/
#   CycloneDX specification     https://cyclonedx.org/specification/overview/
#   Apache License 2.0          https://www.apache.org/licenses/LICENSE-2.0
#   GNU GPL v3                  https://www.gnu.org/licenses/gpl-3.0.html
#   GNU license compatibility   https://www.gnu.org/licenses/license-list.html
#   Mozilla Public License 2.0  https://www.mozilla.org/en-US/MPL/2.0/
#   OSI approved licenses       https://opensource.org/licenses
#   OSV vulnerability database  https://osv.dev/
#   OpenSSF / SBOM guidance     https://openssf.org/
#
# ==== SOLUTION END ========================================================