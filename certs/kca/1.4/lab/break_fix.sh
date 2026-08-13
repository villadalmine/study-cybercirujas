#!/usr/bin/env bash
#
# KCA — Domain 1: Kubernetes and Cloud Native Fundamentals
# Topic 1.4: OCI Images  (exam weight 4.5)
# Source: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
# OCI Image Format spec: https://github.com/opencontainers/image-spec
#
# BREAK & FIX LAB — "The content-addressable store, broken on purpose"
#
# WHAT THIS TEACHES
#   An OCI image is not a file: it is a small graph of content-addressed blobs.
#     index.json --(sha256)--> manifest --(sha256)--> config
#                                        --(sha256)--> layer(s)
#   Every edge is the sha256 of the bytes it points at. This lab builds a real,
#   minimal, spec-valid OCI image LAYOUT from scratch (no registry, no network,
#   no daemon), then severs one edge. You repair it using nothing but the bytes
#   on disk — because in a content-addressable store you never guess a digest,
#   you compute it.
#
# SAFETY
#   Runs entirely inside a disposable lab dir (default /tmp/kca-oci-lab).
#   Touches nothing else. Intended for a throwaway lab VM. Re-runnable.
#
# REQUIREMENTS: bash, jq, tar, gzip, sha256sum, coreutils (stat).  skopeo optional.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Guards and preflight
# ---------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-/tmp/kca-oci-lab}"
case "$LAB_DIR" in
  ""|"/"|"/root"|"/home"|"$HOME") echo "Refusing unsafe LAB_DIR=$LAB_DIR"; exit 1;;
esac

for tool in jq tar gzip sha256sum stat awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool"; exit 1; }
done

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold); RED=$(tput setaf 1); GRN=$(tput setaf 2)
  YEL=$(tput setaf 3); CYA=$(tput setaf 6); RST=$(tput sgr0)
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYA=""; RST=""
fi
banner(){ echo; echo "${BOLD}${CYA}=== $* ===${RST}"; }

sha(){ sha256sum "$1" | awk '{print $1}'; }
sz(){ stat -c%s "$1"; }

banner "Building a fresh, spec-valid OCI image layout in $LAB_DIR"
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/blobs/sha256"
cd "$LAB_DIR"

# ---------------------------------------------------------------------------
# 1. The layout marker  (oci-layout)
# ---------------------------------------------------------------------------
printf '{"imageLayoutVersion":"1.0.0"}' > oci-layout

# ---------------------------------------------------------------------------
# 2. One filesystem layer
#    diff_id  = sha256 of the UNCOMPRESSED tar  (identifies the rootfs diff)
#    digest   = sha256 of the COMPRESSED blob   (identifies the stored object)
#    Knowing the two are different is a classic OCI gotcha.
# ---------------------------------------------------------------------------
mkdir -p rootfs/etc
printf 'KCA OCI Images lab — single-layer image\n' > rootfs/etc/motd
tar --numeric-owner --owner=0 --group=0 -C rootfs -cf layer.tar .
DIFF_ID="sha256:$(sha layer.tar)"                 # uncompressed digest
gzip -n -c layer.tar > layer.tar.gz               # -n: deterministic gzip header
LAYER_DIGEST="$(sha layer.tar.gz)"
LAYER_SIZE="$(sz layer.tar.gz)"
mv layer.tar.gz "blobs/sha256/$LAYER_DIGEST"
rm -f layer.tar

# ---------------------------------------------------------------------------
# 3. Image config blob  (references the layer by its diff_id)
# ---------------------------------------------------------------------------
jq -n --arg diff "$DIFF_ID" '{
  architecture:"amd64", os:"linux",
  config:{ Env:["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], Cmd:["/bin/sh"] },
  rootfs:{ type:"layers", diff_ids:[$diff] },
  history:[{ created_by:"KCA lab: single layer" }]
}' > config.json
CONFIG_DIGEST="$(sha config.json)"
CONFIG_SIZE="$(sz config.json)"
mv config.json "blobs/sha256/$CONFIG_DIGEST"

# ---------------------------------------------------------------------------
# 4. Image manifest blob  (references config + layer by digest+size)
# ---------------------------------------------------------------------------
jq -n \
  --arg cd "sha256:$CONFIG_DIGEST" --argjson cs "$CONFIG_SIZE" \
  --arg ld "sha256:$LAYER_DIGEST"  --argjson ls "$LAYER_SIZE" '{
  schemaVersion:2,
  mediaType:"application/vnd.oci.image.manifest.v1+json",
  config:{ mediaType:"application/vnd.oci.image.config.v1+json", digest:$cd, size:$cs },
  layers:[{ mediaType:"application/vnd.oci.image.layer.v1.tar+gzip", digest:$ld, size:$ls }]
}' > manifest.json
MANIFEST_DIGEST="$(sha manifest.json)"
MANIFEST_SIZE="$(sz manifest.json)"
mv manifest.json "blobs/sha256/$MANIFEST_DIGEST"

# ---------------------------------------------------------------------------
# 5. The top-level index.json  (references the manifest by digest+size)
# ---------------------------------------------------------------------------
jq -n --arg md "sha256:$MANIFEST_DIGEST" --argjson ms "$MANIFEST_SIZE" '{
  schemaVersion:2,
  mediaType:"application/vnd.oci.image.index.v1+json",
  manifests:[{
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    digest:$md, size:$ms,
    annotations:{ "org.opencontainers.image.ref.name":"latest" }
  }]
}' > index.json

# ---------------------------------------------------------------------------
# 6. Ship a verifier the student runs to check their repair (check.sh)
#    It walks the whole graph and confirms every digest matches its bytes.
# ---------------------------------------------------------------------------
cat > check.sh <<'CHECKEOF'
#!/usr/bin/env bash
# Validate that the OCI layout in this directory is internally consistent:
# every reference (index -> manifest -> config + layers) must equal the
# sha256 of the bytes it points at, and every referenced blob must exist.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
fail(){ echo "FAIL: $*"; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f oci-layout ] || fail "missing oci-layout marker"
[ -f index.json ] || fail "missing index.json"

mref=$(jq -r '.manifests[0].digest' index.json)
case "$mref" in sha256:*) ;; *) fail "index.json manifest digest malformed: '$mref'";; esac
mhex=${mref#sha256:}; mblob="blobs/sha256/$mhex"
[ -f "$mblob" ] || fail "index.json points at manifest $mref but blobs/sha256/$mhex does NOT exist (dangling content-address)"
got=$(sha256sum "$mblob" | awk '{print $1}')
[ "$got" = "$mhex" ] || fail "manifest blob hashes to sha256:$got but is stored under $mref (digest mismatch)"
want=$(jq -r '.manifests[0].size' index.json); real=$(stat -c%s "$mblob")
[ "$want" = "$real" ] || fail "index.json manifest size=$want but blob is $real bytes"

cfg=$(jq -r '.config.digest' "$mblob"); chex=${cfg#sha256:}
[ -f "blobs/sha256/$chex" ] || fail "config blob $cfg missing"
[ "$(sha256sum "blobs/sha256/$chex"|awk '{print $1}')" = "$chex" ] || fail "config blob digest mismatch"
while read -r ld; do
  lhex=${ld#sha256:}
  [ -f "blobs/sha256/$lhex" ] || fail "layer blob $ld missing"
  [ "$(sha256sum "blobs/sha256/$lhex"|awk '{print $1}')" = "$lhex" ] || fail "layer blob $ld digest mismatch"
done < <(jq -r '.layers[].digest' "$mblob")

echo "PASS: OCI image layout is internally consistent — all digests verify."
if command -v skopeo >/dev/null 2>&1; then
  if skopeo inspect --raw "oci:$(pwd):latest" >/dev/null 2>&1; then
    echo "PASS: skopeo can read oci:$(pwd):latest"
  else
    echo "WARN: skopeo present but could not read the layout"
  fi
fi
CHECKEOF
chmod +x check.sh

# Confirm the freshly built (still healthy) image passes before we break it.
banner "Sanity check on the healthy image"
bash check.sh

# ---------------------------------------------------------------------------
# 7. THE BREAK — sever the index -> manifest edge.
#    We overwrite the manifest pointer in index.json with an all-zero digest.
#    The manifest blob itself is untouched and still on disk; only the
#    pointer that names it is now wrong.
# ---------------------------------------------------------------------------
banner "Breaking the image (controlled, reversible)"
BOGUS="0000000000000000000000000000000000000000000000000000000000000000"
jq --arg b "sha256:$BOGUS" '.manifests[0].digest=$b' index.json > index.json.tmp
mv index.json.tmp index.json
echo "Overwrote index.json .manifests[0].digest with sha256:$BOGUS"

# ---------------------------------------------------------------------------
# 8. Brief the student
# ---------------------------------------------------------------------------
cat <<EOF

${BOLD}${RED}#################### BREAK & FIX — OCI Images ####################${RST}

${BOLD}Lab directory:${RST} $LAB_DIR
${BOLD}Layout:${RST} oci-layout, index.json, blobs/sha256/<digest> ...

${BOLD}${YEL}SYMPTOM you will observe${RST}
  Run:   ${CYA}cd $LAB_DIR && bash check.sh${RST}
  You get a FAIL: index.json references a manifest blob whose digest is
  sha256:0000...0000, and no such blob exists under blobs/sha256/.
  With a real tool the same break looks like:
     ${CYA}skopeo inspect oci:$LAB_DIR:latest${RST}
     -> error resolving the manifest / blob unknown.
  The manifest, config and layer bytes are all still present and valid —
  only the POINTER from index.json to the manifest was corrupted.

${BOLD}${GRN}YOUR GOAL${RST}
  Make ${CYA}bash check.sh${RST} print "PASS" again, WITHOUT rebuilding the image and
  WITHOUT inventing a digest. Repair index.json so its manifest .digest (and
  .size) match the actual manifest blob sitting in blobs/sha256/.

${BOLD}Hints${RST}
  * The manifest blob is the one whose JSON has
    mediaType "application/vnd.oci.image.manifest.v1+json".
  * In an OCI layout the blob's FILENAME under blobs/sha256/ IS its sha256 —
    so once you find it, its digest is literally its file name (verify it).
  * Fix both the digest and the size fields in index.json.manifests[0].

Try it yourself first. The full worked solution is commented at the very
bottom of this script.
${BOLD}${RED}#################################################################${RST}

EOF

exit 0

# ===========================================================================
# ============================  SOLUTION  ===================================
# (Do not read until you have attempted the repair.)
#
# Recap: index.json.manifests[0].digest was overwritten with an all-zero
# sha256. The referenced manifest blob no longer resolves. Nothing else was
# touched, so you can recover the correct pointer purely from the bytes on
# disk — that is the entire promise of a content-addressable store.
#
#   cd /tmp/kca-oci-lab
#
# 1) See the broken pointer:
#      jq '.manifests[0]' index.json
#      # -> "digest": "sha256:0000...0000"
#
# 2) Find the real manifest blob (the one whose mediaType is image.manifest):
#      for b in blobs/sha256/*; do
#        if jq -e '.mediaType=="application/vnd.oci.image.manifest.v1+json"' \
#             "$b" >/dev/null 2>&1; then MAN="$b"; fi
#      done
#      echo "manifest blob = $MAN"
#
# 3) Its digest is its own content hash (and, by construction, its file name):
#      REAL="sha256:$(sha256sum "$MAN" | awk '{print $1}')"
#      SIZE="$(stat -c%s "$MAN")"
#      # Sanity: basename "$MAN" must equal the hex of $REAL.
#      echo "digest=$REAL size=$SIZE"
#
# 4) Rewrite the pointer (fix BOTH digest and size):
#      jq --arg d "$REAL" --argjson s "$SIZE" \
#         '.manifests[0].digest=$d | .manifests[0].size=$s' \
#         index.json > index.json.fixed
#      mv index.json.fixed index.json
#
# 5) Verify the graph is whole again:
#      bash check.sh                              # -> PASS
#      skopeo inspect oci:/tmp/kca-oci-lab:latest # if skopeo is installed
#      # Optional real-world reuse: push it somewhere
#      # skopeo copy oci:/tmp/kca-oci-lab:latest containers-storage:kca/oci-lab:latest
#
# WHY THIS IS THE LESSON
#   An OCI image is a Merkle-like graph: index -> manifest -> {config, layers},
#   each edge being the sha256 of the target bytes. Registries, containerd and
#   the OCI runtimes all deduplicate, cache and verify by these digests. Break
#   one edge and the image is unresolvable even though 100% of the data is
#   present. You repair such damage by RECOMPUTING the digest from the object it
#   names — never by guessing, and never by editing the blob to fit a bad
#   pointer. Same principle underlies image immutability: change any byte in any
#   layer and every digest above it changes too, which is exactly why pinning by
#   digest (image@sha256:...) is stronger than pinning by tag.
#
#   Spec: https://github.com/opencontainers/image-spec/blob/main/image-layout.md
#         https://github.com/opencontainers/image-spec/blob/main/manifest.md
# ===========================================================================