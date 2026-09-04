#!/usr/bin/env bash
# =============================================================================
#  AWS Certified Cloud Practitioner — CLF-C02 (exam guide v1.0)
#  Domain 3: Cloud Technology and Services
#  Task Statement 3.6 — "Identify AWS storage services"   (domain weight 4.25)
#
#  BREAK & FIX LABORATORY — DISPOSABLE VM ONLY
#
#  What this lab is
#  ----------------
#  You cannot break a real S3 bucket safely for practice, and CLF-C02 does not
#  require an AWS account. So this lab builds, on a throw-away Linux VM, a
#  faithful *mechanical* model of the four AWS storage families the exam asks
#  you to distinguish, using only Linux primitives plus a self-contained,
#  offline S3 API emulator that reproduces the real error codes:
#
#    AWS service / concept          Modelled in this lab by
#    -----------------------------  ------------------------------------------
#    Amazon EBS (block, 1 AZ,       a loop device + ext4, mounted on exactly
#      attached to one instance)    one "instance" directory tree
#    EBS snapshot                   a point-in-time copy of the volume image
#    Instance store (ephemeral)     a tmpfs mount — wiped on stop/start
#    Amazon EFS (POSIX file,        one ext4 backing mount bind-mounted into
#      shared, multi-AZ)            two "instances" at the same time
#    Amazon S3 (object, regional,   bin/s3lab — an offline emulator speaking
#      storage classes, lifecycle)  aws-s3api-shaped commands, JSON and errors
#    AWS Backup (recovery points)   backup-vault/recovery-point-*/
#
#  Everything the lab creates lives under one root directory plus the loop
#  devices it attaches itself. It never edits the host's /etc/fstab (it mounts
#  from its own fstab file with `mount -a -T`), never touches a real disk, and
#  `destroy` removes exactly what `deploy` created.
#
#  Usage
#  -----
#    sudo ./clf-c02-3.6-storage-breakfix.sh deploy  --yes-disposable-vm
#    sudo ./clf-c02-3.6-storage-breakfix.sh brief
#    sudo ./clf-c02-3.6-storage-breakfix.sh break   --yes-disposable-vm [--fault N]
#    sudo ./clf-c02-3.6-storage-breakfix.sh status
#    sudo ./clf-c02-3.6-storage-breakfix.sh verify
#    sudo ./clf-c02-3.6-storage-breakfix.sh destroy --yes-disposable-vm
#
#  Requirements: root, bash 4+, util-linux (losetup, mount, findmnt, blkid),
#                e2fsprogs (mkfs.ext4), coreutils. No network. No AWS account.
#
#  Official sources (verify every claim in this lab against them)
#  -------------------------------------------------------------
#   CLF-C02 exam guide:
#     https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#   S3 storage classes:
#     https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html
#   S3 lifecycle:
#     https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html
#   S3 restore (archived objects):
#     https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects.html
#   EBS volume types:
#     https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html
#   Making an EBS volume available for use (mount, UUID, fstab):
#     https://docs.aws.amazon.com/ebs/latest/userguide/ebs-using-volumes.html
#   EBS/NVMe device naming on Nitro instances:
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nvme-ebs-volumes.html
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/device_naming.html
#   Instance store (ephemeral):
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html
#   Amazon EFS:
#     https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html
#   Amazon FSx (Windows File Server):
#     https://docs.aws.amazon.com/fsx/latest/WindowsGuide/what-is.html
#   AWS Storage Gateway:
#     https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
#   AWS Snow Family:
#     https://docs.aws.amazon.com/snowball/latest/developer-guide/whatissnowball.html
#   AWS Backup:
#     https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html
# =============================================================================

set -Eeuo pipefail

LAB_ROOT="${LAB_ROOT:-/opt/aws-clf-lab-3.6}"
LAB_MARKER=".aws-clf-3.6-lab"

# ---- Fictional AWS resource identifiers, used consistently everywhere --------
REGION="us-east-1"
AZ_A="us-east-1a"
AZ_B="us-east-1b"
INST_A="i-0a7c3f2e9b1d4c5f0"      # checkout-web-1, AZ_A  (owns the EBS volume)
INST_B="i-0b8d4a1c6e2f7b3a9"      # checkout-web-2, AZ_B  (shares the file system)
VOL_DATA="vol-0f1e2d3c4b5a69788"  # gp3, 256 MiB in this lab
SNAP_DATA="snap-0d4c3b2a1908f7e6d"
EFS_ID="fs-0c9b8a7d6e5f40312"
BUCKET="clf-c02-checkout-artifacts-lab"
CONFIG_KEY="config/checkout.conf"

# ---- Derived paths -----------------------------------------------------------
BIN="$LAB_ROOT/bin"
ETC="$LAB_ROOT/etc"
VAR="$LAB_ROOT/var"
STATE="$LAB_ROOT/state"
BLOCKSTORE="$LAB_ROOT/blockstore"
VAULT="$LAB_ROOT/backup-vault"
DATA_IMG="$BLOCKSTORE/$VOL_DATA.img"
SNAP_IMG="$BLOCKSTORE/$SNAP_DATA.img"
EFS_IMG="$BLOCKSTORE/$EFS_ID.img"
EFS_BACKING="$LAB_ROOT/efs-backing"
A_ROOT="$LAB_ROOT/instances/$INST_A"
B_ROOT="$LAB_ROOT/instances/$INST_B"
A_DATA="$A_ROOT/mnt/data"        # EBS data volume mount point
A_SHARED="$A_ROOT/mnt/shared"    # EFS mount point on instance A
A_SCRATCH="$A_ROOT/mnt/scratch"  # instance store (tmpfs)
B_SHARED="$B_ROOT/mnt/shared"    # same EFS, second instance
FSTAB="$ETC/fstab.lab"
APP_ENV="$ETC/checkout.env"

CONFIRM_FLAG="${AWS_CLF_LAB_CONFIRM:-0}"
FAULT_SELECT="all"

# ---- Output helpers ----------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[..]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
bad()  { printf '%s[XX]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { bad "$*"; exit 1; }
rule() { printf '%s\n' "-----------------------------------------------------------------------------"; }
head1(){ printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; rule; }

trap 'bad "aborted at line $LINENO (command: ${BASH_COMMAND})"' ERR

# ---- Safety gates ------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root: losetup/mount/mkfs require it."
}

require_tools() {
    local missing=() t
    for t in losetup mount umount findmnt blkid mkfs.ext4 truncate md5sum sed awk; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        bad "missing tools: ${missing[*]}"
        say "  Debian/Ubuntu: apt-get install -y util-linux e2fsprogs coreutils"
        say "  RHEL/Fedora:   dnf install -y util-linux e2fsprogs coreutils"
        exit 1
    fi
}

require_confirmation() {
    if [ "$CONFIRM_FLAG" != "1" ]; then
        bad "This command mounts file systems and deliberately breaks things."
        say "  Run it ONLY on a disposable lab VM you can throw away."
        say "  Re-run with --yes-disposable-vm (or AWS_CLF_LAB_CONFIRM=1)."
        exit 1
    fi
    if [ -e "$LAB_ROOT" ] && [ ! -e "$LAB_ROOT/$LAB_MARKER" ]; then
        die "$LAB_ROOT exists but is not a lab root (marker missing). Refusing to touch it."
    fi
}

# ---- Loop device helpers -----------------------------------------------------
loop_of() {   # loop_of <backing-file> -> /dev/loopN or empty
    losetup -j "$1" 2>/dev/null | head -n1 | cut -d: -f1
}

loop_attach() {  # idempotent
    local img="$1" dev
    dev="$(loop_of "$img")"
    [ -n "$dev" ] || dev="$(losetup --find --show "$img")"
    printf '%s\n' "$dev"
}

dev_uuid() {
    local dev="$1" u
    u="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
    [ -n "$u" ] || u="$(blkid -p -s UUID -o value "$dev" 2>/dev/null || true)"
    printf '%s\n' "$u"
}

is_mounted() { findmnt -rn --target "$1" --mountpoint "$1" >/dev/null 2>&1; }

# =============================================================================
#  Generated lab tooling
# =============================================================================

write_s3lab() {
cat > "$BIN/s3lab" <<'S3LAB'
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# s3lab — offline Amazon S3 emulator for the CLF-C02 3.6 lab.
#
# It mirrors the subset of `aws s3api` this lab needs, including AWS's real
# error codes, exit status 254 (aws CLI v2 service error) and JSON output shape.
# Two deliberate simplifications, both called out so nothing is learned wrong:
#
#   1. Lifecycle rules are passed with --rule 'k=v,...' instead of a JSON
#      document. The real command is:
#         aws s3api put-bucket-lifecycle-configuration --bucket B \
#             --lifecycle-configuration file://lifecycle.json
#      get-bucket-lifecycle-configuration here prints the real JSON shape.
#   2. Time is accelerated: 1 hour of AWS retrieval time = 1 second of lab time,
#      so a DEEP_ARCHIVE Bulk restore (up to 48 h) completes in ~48 s.
#
# Real head-object omits StorageClass when the object is STANDARD; this
# emulator always prints it, because the whole point of the lab is to see it.
# -----------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S3="$LAB_ROOT/s3"
HOUR=1                     # lab seconds per AWS hour
DAY_SECONDS=1              # lab seconds per "day" of object age

ARCHIVAL="GLACIER DEEP_ARCHIVE"     # classes that need restore before GET
now()      { date -u +%s; }
iso()      { date -u -d "@${1:-$(now)}" +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null \
             || date -u -r "${1:-$(now)}" +%Y-%m-%dT%H:%M:%S+00:00; }
rfc()      { date -u -d "@${1}" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null \
             || date -u -r "${1}" '+%a, %d %b %Y %H:%M:%S GMT'; }

err() {  # err <Code> <Operation> <Message>
    printf 'An error occurred (%s) when calling the %s operation: %s\n' \
        "$1" "$2" "$3" >&2
    exit 254
}
note() { printf '[lab] %s\n' "$*" >&2; }

obj_path()  { printf '%s/%s/objects/%s\n' "$S3" "$1" "$2"; }
meta_path() { printf '%s/%s/meta/%s.meta\n' "$S3" "$1" "$2"; }
lc_path()   { printf '%s/%s/lifecycle.rules\n' "$S3" "$1"; }

meta_get() { sed -n "s|^$2=||p" "$1" 2>/dev/null | head -n1; }
meta_set() {
    local f="$1" k="$2" v="$3"
    mkdir -p "$(dirname "$f")"; touch "$f"
    if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"
    else printf '%s=%s\n' "$k" "$v" >> "$f"; fi
}
is_archival() { case " $ARCHIVAL " in *" $1 "*) return 0;; *) return 1;; esac; }

tier_hours() {  # tier_hours <class> <tier>
    case "$1:$2" in
        GLACIER:Expedited)      echo 1  ;;   # 1-5 minutes in reality
        GLACIER:Standard)       echo 4  ;;   # 3-5 hours
        GLACIER:Bulk)           echo 8  ;;   # 5-12 hours
        DEEP_ARCHIVE:Standard)  echo 12 ;;   # within 12 hours
        DEEP_ARCHIVE:Bulk)      echo 48 ;;   # within 48 hours
        *) echo 12 ;;
    esac
}

# --------------------------- argument parsing --------------------------------
bucket=""; key=""; prefix=""; sclass=""; body=""; restore_req=""; copy_src=""
declare -a rules=(); declare -a pos=()
op="${1:-}"; [ -n "$op" ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket)               bucket="$2"; shift 2 ;;
        --key)                  key="$2"; shift 2 ;;
        --prefix)               prefix="$2"; shift 2 ;;
        --storage-class)        sclass="$2"; shift 2 ;;
        --body)                 body="$2"; shift 2 ;;
        --restore-request)      restore_req="$2"; shift 2 ;;
        --copy-source)          copy_src="$2"; shift 2 ;;
        --rule)                 rules+=("$2"); shift 2 ;;
        --metadata-directive)   shift 2 ;;
        --*)                    shift ;;
        *)                      pos+=("$1"); shift ;;
    esac
done

case "$op" in
mb)
    b="${pos[0]:-$bucket}"; b="${b#s3://}"
    [ -n "$b" ] || err InvalidBucketName CreateBucket "bucket name required"
    mkdir -p "$S3/$b/objects" "$S3/$b/meta"; : > "$(lc_path "$b")"
    printf 'make_bucket: %s\n' "$b" ;;

put-object)
    [ -d "$S3/$bucket" ] || err NoSuchBucket PutObject "The specified bucket does not exist"
    [ -f "$body" ] || err InvalidRequest PutObject "--body file not found: $body"
    o="$(obj_path "$bucket" "$key")"; m="$(meta_path "$bucket" "$key")"
    mkdir -p "$(dirname "$o")" "$(dirname "$m")"
    cp -- "$body" "$o"
    : > "$m"
    meta_set "$m" storage_class "${sclass:-STANDARD}"
    meta_set "$m" created "$(now)"
    meta_set "$m" restore ""
    meta_set "$m" restore_ready ""
    printf '{\n    "ETag": "\\"%s\\""\n}\n' "$(md5sum "$o" | cut -d' ' -f1)" ;;

head-object)
    o="$(obj_path "$bucket" "$key")"; m="$(meta_path "$bucket" "$key")"
    [ -f "$o" ] || err 404 HeadObject "Not Found"
    sc="$(meta_get "$m" storage_class)"; sc="${sc:-STANDARD}"
    rs="$(meta_get "$m" restore)"; ready="$(meta_get "$m" restore_ready)"
    restore_line=""
    if [ "$rs" = "ongoing" ]; then
        if [ -n "$ready" ] && [ "$(now)" -ge "$ready" ]; then
            meta_set "$m" restore done
            restore_line="ongoing-request=\\\"false\\\", expiry-date=\\\"$(rfc $(( $(now) + 86400 )))\\\""
        else
            restore_line="ongoing-request=\\\"true\\\""
        fi
    elif [ "$rs" = "done" ]; then
        restore_line="ongoing-request=\\\"false\\\", expiry-date=\\\"$(rfc $(( $(now) + 86400 )))\\\""
    fi
    printf '{\n'
    printf '    "AcceptRanges": "bytes",\n'
    printf '    "LastModified": "%s",\n' "$(iso "$(meta_get "$m" created)")"
    printf '    "ContentLength": %s,\n' "$(stat -c %s "$o")"
    printf '    "ETag": "\\"%s\\"",\n' "$(md5sum "$o" | cut -d' ' -f1)"
    printf '    "ContentType": "binary/octet-stream",\n'
    printf '    "ServerSideEncryption": "AES256",\n'
    [ -n "$restore_line" ] && printf '    "Restore": "%s",\n' "$restore_line"
    printf '    "StorageClass": "%s",\n' "$sc"
    printf '    "Metadata": {}\n}\n' ;;

get-object)
    out="${pos[0]:-}"
    o="$(obj_path "$bucket" "$key")"; m="$(meta_path "$bucket" "$key")"
    [ -n "$out" ] || err InvalidRequest GetObject "output file operand required"
    [ -f "$o" ] || err NoSuchKey GetObject "The specified key does not exist."
    sc="$(meta_get "$m" storage_class)"; sc="${sc:-STANDARD}"
    if is_archival "$sc"; then
        rs="$(meta_get "$m" restore)"; ready="$(meta_get "$m" restore_ready)"
        if [ "$rs" = "done" ] || { [ "$rs" = "ongoing" ] && [ -n "$ready" ] && [ "$(now)" -ge "$ready" ]; }; then
            meta_set "$m" restore done
        else
            err InvalidObjectState GetObject \
                "The operation is not valid for the object's storage class"
        fi
    fi
    cp -- "$o" "$out"
    printf '{\n'
    printf '    "AcceptRanges": "bytes",\n'
    printf '    "LastModified": "%s",\n' "$(iso "$(meta_get "$m" created)")"
    printf '    "ContentLength": %s,\n' "$(stat -c %s "$o")"
    printf '    "ETag": "\\"%s\\"",\n' "$(md5sum "$o" | cut -d' ' -f1)"
    printf '    "ContentType": "binary/octet-stream",\n'
    printf '    "StorageClass": "%s",\n' "$sc"
    printf '    "Metadata": {}\n}\n' ;;

restore-object)
    o="$(obj_path "$bucket" "$key")"; m="$(meta_path "$bucket" "$key")"
    [ -f "$o" ] || err NoSuchKey RestoreObject "The specified key does not exist."
    sc="$(meta_get "$m" storage_class)"; sc="${sc:-STANDARD}"
    is_archival "$sc" || err InvalidObjectState RestoreObject \
        "Restore is not allowed for the object's current storage class"
    tier="$(printf '%s' "$restore_req" | sed -n 's/.*Tier=\([A-Za-z]*\).*/\1/p')"
    tier="${tier:-Standard}"
    if [ "$sc" = "DEEP_ARCHIVE" ] && [ "$tier" = "Expedited" ]; then
        err InvalidRequest RestoreObject \
            "Expedited retrievals are not available for objects in the DEEP_ARCHIVE storage class"
    fi
    rs="$(meta_get "$m" restore)"
    if [ "$rs" = "ongoing" ]; then
        err RestoreAlreadyInProgress RestoreObject \
            "Object restore is already in progress"
    fi
    h="$(tier_hours "$sc" "$tier")"
    meta_set "$m" restore ongoing
    meta_set "$m" restore_ready "$(( $(now) + h * HOUR ))"
    note "restore accepted: class=$sc tier=$tier — AWS would take up to ${h}h; lab: ${h}s."
    note "poll with: s3lab head-object --bucket $bucket --key $key   (look at .Restore)"
    ;;

copy-object)
    src_bucket="${copy_src%%/*}"; src_key="${copy_src#*/}"
    so="$(obj_path "$src_bucket" "$src_key")"; sm="$(meta_path "$src_bucket" "$src_key")"
    [ -f "$so" ] || err NoSuchKey CopyObject "The specified key does not exist."
    ssc="$(meta_get "$sm" storage_class)"; ssc="${ssc:-STANDARD}"
    if is_archival "$ssc"; then
        rs="$(meta_get "$sm" restore)"; ready="$(meta_get "$sm" restore_ready)"
        if [ "$rs" = "done" ] || { [ "$rs" = "ongoing" ] && [ -n "$ready" ] && [ "$(now)" -ge "$ready" ]; }; then
            :
        else
            err InvalidObjectState CopyObject \
                "The operation is not valid for the object's storage class"
        fi
    fi
    o="$(obj_path "$bucket" "$key")"; m="$(meta_path "$bucket" "$key")"
    mkdir -p "$(dirname "$o")" "$(dirname "$m")"
    cp -- "$so" "$o"; : > "$m"
    meta_set "$m" storage_class "${sclass:-STANDARD}"
    meta_set "$m" created "$(now)"
    meta_set "$m" restore ""; meta_set "$m" restore_ready ""
    printf '{\n    "CopyObjectResult": {\n        "ETag": "\\"%s\\"",\n        "LastModified": "%s"\n    }\n}\n' \
        "$(md5sum "$o" | cut -d' ' -f1)" "$(iso)" ;;

list-objects-v2)
    [ -d "$S3/$bucket" ] || err NoSuchBucket ListObjectsV2 "The specified bucket does not exist"
    printf '{\n    "Contents": [\n'
    first=1
    while IFS= read -r f; do
        k="${f#"$S3/$bucket/objects/"}"
        case "$k" in "$prefix"*) : ;; *) continue ;; esac
        m="$(meta_path "$bucket" "$k")"
        sc="$(meta_get "$m" storage_class)"; sc="${sc:-STANDARD}"
        [ $first -eq 1 ] || printf ',\n'; first=0
        printf '        {\n'
        printf '            "Key": "%s",\n' "$k"
        printf '            "LastModified": "%s",\n' "$(iso "$(meta_get "$m" created)")"
        printf '            "Size": %s,\n' "$(stat -c %s "$f")"
        printf '            "StorageClass": "%s"\n' "$sc"
        printf '        }'
    done < <(find "$S3/$bucket/objects" -type f 2>/dev/null | sort)
    [ $first -eq 1 ] || printf '\n'
    printf '    ]\n}\n' ;;

delete-object)
    rm -f -- "$(obj_path "$bucket" "$key")" "$(meta_path "$bucket" "$key")" ;;

put-bucket-lifecycle-configuration)
    [ -d "$S3/$bucket" ] || err NoSuchBucket PutBucketLifecycleConfiguration "The specified bucket does not exist"
    f="$(lc_path "$bucket")"; : > "$f"
    for r in ${rules[@]+"${rules[@]}"}; do
        id="";  st=""; pf=""; dy=""; cl=""
        IFS=',' read -ra kv <<< "$r"
        for pair in "${kv[@]}"; do
            case "$pair" in
                id=*)     id="${pair#id=}" ;;
                status=*) st="${pair#status=}" ;;
                prefix=*) pf="${pair#prefix=}" ;;
                days=*)   dy="${pair#days=}" ;;
                class=*)  cl="${pair#class=}" ;;
            esac
        done
        printf '%s|%s|%s|%s|%s\n' "${id:-rule}" "${st:-Enabled}" "$pf" "${dy:-0}" "${cl:-GLACIER}" >> "$f"
    done ;;

get-bucket-lifecycle-configuration)
    f="$(lc_path "$bucket")"
    [ -s "$f" ] || err NoSuchLifecycleConfiguration GetBucketLifecycleConfiguration \
        "The lifecycle configuration does not exist"
    printf '{\n    "Rules": [\n'; first=1
    while IFS='|' read -r id st pf dy cl; do
        [ -n "$id" ] || continue
        [ $first -eq 1 ] || printf ',\n'; first=0
        printf '        {\n'
        printf '            "ID": "%s",\n' "$id"
        printf '            "Filter": {\n                "Prefix": "%s"\n            },\n' "$pf"
        printf '            "Status": "%s",\n' "$st"
        printf '            "Transitions": [\n                {\n'
        printf '                    "Days": %s,\n                    "StorageClass": "%s"\n' "$dy" "$cl"
        printf '                }\n            ]\n        }'
    done < "$f"
    [ $first -eq 1 ] || printf '\n'
    printf '    ]\n}\n' ;;

delete-bucket-lifecycle)
    : > "$(lc_path "$bucket")" ;;

lifecycle-run)
    # Lab-only: applies enabled rules now. In AWS this runs asynchronously,
    # at least once a day, and transitions are not instantaneous.
    f="$(lc_path "$bucket")"; [ -s "$f" ] || { note "no lifecycle rules"; exit 0; }
    while IFS='|' read -r id st pf dy cl; do
        [ "$st" = "Enabled" ] || continue
        while IFS= read -r o; do
            k="${o#"$S3/$bucket/objects/"}"
            case "$k" in "$pf"*) : ;; *) continue ;; esac
            m="$(meta_path "$bucket" "$k")"
            cur="$(meta_get "$m" storage_class)"; cur="${cur:-STANDARD}"
            [ "$cur" = "$cl" ] && continue
            age=$(( $(now) - $(meta_get "$m" created) ))
            if [ "$dy" -eq 0 ] || [ "$age" -ge $(( dy * DAY_SECONDS )) ]; then
                meta_set "$m" storage_class "$cl"
                meta_set "$m" restore ""; meta_set "$m" restore_ready ""
                note "lifecycle[$id]: $k  $cur -> $cl"
            fi
        done < <(find "$S3/$bucket/objects" -type f 2>/dev/null | sort)
    done < "$f" ;;

*)
    cat >&2 <<'USAGE'
s3lab — offline S3 emulator (CLF-C02 lab)
  s3lab mb <bucket>
  s3lab put-object   --bucket B --key K --body FILE [--storage-class C]
  s3lab get-object   --bucket B --key K OUTFILE
  s3lab head-object  --bucket B --key K
  s3lab list-objects-v2 --bucket B [--prefix P]
  s3lab restore-object --bucket B --key K --restore-request 'Days=N,GlacierJobParameters={Tier=T}'
  s3lab copy-object  --bucket B --key K --copy-source B/K --storage-class C
  s3lab put-bucket-lifecycle-configuration --bucket B --rule 'id=..,status=..,prefix=..,days=..,class=..'
  s3lab get-bucket-lifecycle-configuration --bucket B
  s3lab delete-bucket-lifecycle --bucket B
  s3lab lifecycle-run --bucket B
USAGE
    exit 255 ;;
esac
S3LAB
chmod 0755 "$BIN/s3lab"
}

write_checkout_app() {
cat > "$BIN/checkout-app" <<'APP'
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# checkout-app — the workload under test.
#   start   : cold start. Pulls its config object from S3. Fails if it cannot.
#   order N : writes an invoice to DATA_DIR (block) and a receipt to UPLOAD_DIR
#             (shared file storage). Falls back to the cached config, exactly
#             like a real service that is already warm.
#   report  : where the data currently lives and how much of it there is.
# -----------------------------------------------------------------------------
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$LAB_ROOT/etc/checkout.env"
CACHE="$LAB_ROOT/var/cache/checkout.conf"
S3LAB="$LAB_ROOT/bin/s3lab"

# shellcheck disable=SC1090
. "$ENV_FILE"

load_config_from_s3() {
    mkdir -p "$(dirname "$CACHE")"
    "$S3LAB" get-object --bucket "$S3_BUCKET" --key "$CONFIG_KEY" "$CACHE.new" >/dev/null
}

case "${1:-}" in
start)
    printf 'checkout-app: cold start on %s\n' "$(hostname)"
    printf 'checkout-app: fetching s3://%s/%s\n' "$S3_BUCKET" "$CONFIG_KEY"
    if ! load_config_from_s3; then
        printf 'checkout-app: FATAL — configuration object unavailable, aborting start\n' >&2
        exit 1
    fi
    mv "$CACHE.new" "$CACHE"
    # shellcheck disable=SC1090
    . "$CACHE"
    printf 'checkout-app: config loaded (TAX_RATE=%s RECEIPT_FORMAT=%s)\n' "$TAX_RATE" "$RECEIPT_FORMAT"
    printf 'checkout-app: DATA_DIR=%s\n' "$DATA_DIR"
    printf 'checkout-app: UPLOAD_DIR=%s\n' "$UPLOAD_DIR"
    printf 'checkout-app: ready\n' ;;

order)
    id="${2:?usage: checkout-app order <invoice-id>}"
    if [ -f "$CACHE" ]; then
        # shellcheck disable=SC1090
        . "$CACHE"
    else
        printf 'checkout-app: WARN — no cached config, using built-in defaults\n' >&2
        TAX_RATE=0.00
    fi
    mkdir -p "$DATA_DIR" "$UPLOAD_DIR"
    printf '{"invoice":"%s","amount":100.00,"tax_rate":%s,"ts":"%s"}\n' \
        "$id" "$TAX_RATE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DATA_DIR/invoice-$id.json"
    printf 'RECEIPT %s / thank you\n' "$id" > "$UPLOAD_DIR/receipt-$id.txt"
    printf 'checkout-app: invoice %s written\n' "$id" ;;

report)
    printf 'invoices (block storage) : %s in %s\n' \
        "$(find "$DATA_DIR" -maxdepth 1 -name 'invoice-*.json' 2>/dev/null | wc -l)" "$DATA_DIR"
    printf 'receipts (file storage)  : %s in %s\n' \
        "$(find "$UPLOAD_DIR" -maxdepth 1 -name 'receipt-*.txt' 2>/dev/null | wc -l)" "$UPLOAD_DIR"
    printf '\nfilesystem backing each path:\n'
    findmnt -no SOURCE,FSTYPE,TARGET --target "$DATA_DIR"   | sed 's/^/  DATA_DIR   -> /'
    findmnt -no SOURCE,FSTYPE,TARGET --target "$UPLOAD_DIR" | sed 's/^/  UPLOAD_DIR -> /' ;;

*)
    printf 'usage: checkout-app {start|order <id>|report}\n' >&2; exit 2 ;;
esac
APP
chmod 0755 "$BIN/checkout-app"
}

write_lab_boot() {
cat > "$BIN/lab-boot" <<'BOOT'
#!/usr/bin/env bash
# lab-boot — the lab's equivalent of an instance boot: attach the "EBS volumes"
# (loop devices) and mount everything declared in etc/fstab.lab.
# This is where a bad fstab entry bites you, exactly as it does on EC2.
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
for img in "$LAB_ROOT"/blockstore/vol-*.img "$LAB_ROOT"/blockstore/fs-*.img; do
    [ -f "$img" ] || continue
    if ! losetup -j "$img" | grep -q .; then
        losetup --find --show "$img" >/dev/null || rc=1
    fi
done
mount -a -T "$LAB_ROOT/etc/fstab.lab" || rc=1
exit $rc
BOOT
chmod 0755 "$BIN/lab-boot"
}

write_fstab() {   # write_fstab <data-device-spec> <efs-device-spec>
    local dataspec="$1" efsspec="$2"
    cat > "$FSTAB" <<EOF
# ---------------------------------------------------------------------------
# fstab.lab — mounted with:  mount -a -T $FSTAB
# The host's real /etc/fstab is never touched by this lab.
#
# Model:
#   $VOL_DATA  gp3 block volume, attached to $INST_A only ($AZ_A)
#   $EFS_ID    shared file system, mounted by $INST_A and $INST_B
#   tmpfs                 instance store: ephemeral, wiped on stop/start
# ---------------------------------------------------------------------------
$dataspec  $A_DATA  ext4  defaults,nofail  0 2
$efsspec  $EFS_BACKING  ext4  defaults,nofail  0 2
$EFS_BACKING  $A_SHARED  none  bind  0 0
$EFS_BACKING  $B_SHARED  none  bind  0 0
tmpfs  $A_SCRATCH  tmpfs  size=16m,mode=0755  0 0
EOF
}

# =============================================================================
#  deploy
# =============================================================================
cmd_deploy() {
    require_root; require_tools; require_confirmation

    head1 "Deploying the CLF-C02 3.6 storage lab under $LAB_ROOT"

    mkdir -p "$BIN" "$ETC" "$VAR/cache" "$STATE" "$BLOCKSTORE" "$VAULT" \
             "$EFS_BACKING" "$A_DATA" "$A_SHARED" "$A_SCRATCH" "$B_SHARED"
    touch "$LAB_ROOT/$LAB_MARKER"

    write_s3lab; write_checkout_app; write_lab_boot

    # --- Block storage: the "gp3 EBS volume" ---------------------------------
    if [ ! -f "$DATA_IMG" ]; then
        info "creating $VOL_DATA (gp3, 256 MiB) in $AZ_A"
        truncate -s 256M "$DATA_IMG"
        local d; d="$(loop_attach "$DATA_IMG")"
        mkfs.ext4 -q -F -L CHECKOUT_DATA "$d"
    fi
    local ddev; ddev="$(loop_attach "$DATA_IMG")"
    local duuid; duuid="$(dev_uuid "$ddev")"

    # --- Shared file storage: the "EFS file system" --------------------------
    if [ ! -f "$EFS_IMG" ]; then
        info "creating $EFS_ID (shared file system, regional)"
        truncate -s 256M "$EFS_IMG"
        local e; e="$(loop_attach "$EFS_IMG")"
        mkfs.ext4 -q -F -L CHECKOUT_SHARED "$e"
    fi
    local edev; edev="$(loop_attach "$EFS_IMG")"
    local euuid; euuid="$(dev_uuid "$edev")"

    write_fstab "UUID=$duuid" "UUID=$euuid"
    info "mounting from $FSTAB"
    "$BIN/lab-boot" || die "lab-boot failed; inspect $FSTAB"

    # --- Application configuration -------------------------------------------
    cat > "$APP_ENV" <<EOF
# checkout-app runtime settings (instance $INST_A, $AZ_A)
DATA_DIR=$A_DATA
UPLOAD_DIR=$A_SHARED/receipts
S3_BUCKET=$BUCKET
CONFIG_KEY=$CONFIG_KEY
EOF
    mkdir -p "$A_SHARED/receipts"

    # --- Object storage: the S3 bucket and its config object ------------------
    if [ ! -d "$LAB_ROOT/s3/$BUCKET" ]; then
        info "creating s3://$BUCKET in $REGION"
        "$BIN/s3lab" mb "$BUCKET" >/dev/null
    fi
    cat > "$VAR/checkout.conf.src" <<'CONF'
# checkout-app configuration — served from Amazon S3
TAX_RATE=0.21
RECEIPT_FORMAT=text
CONF
    "$BIN/s3lab" put-object --bucket "$BUCKET" --key "$CONFIG_KEY" \
        --body "$VAR/checkout.conf.src" --storage-class STANDARD >/dev/null
    "$BIN/s3lab" delete-bucket-lifecycle --bucket "$BUCKET"

    # --- Seed traffic ---------------------------------------------------------
    info "seeding five invoices"
    "$BIN/checkout-app" start >/dev/null || die "app cold start failed on a healthy lab"
    local i
    for i in 1001 1002 1003 1004 1005; do
        "$BIN/checkout-app" order "$i" >/dev/null
        "$BIN/s3lab" put-object --bucket "$BUCKET" --key "invoices/invoice-$i.json" \
            --body "$A_DATA/invoice-$i.json" --storage-class STANDARD >/dev/null
    done
    printf '1001 1002 1003 1004 1005\n' > "$STATE/seed_ids"

    # --- Snapshot + backup recovery point ------------------------------------
    info "taking $SNAP_DATA (EBS snapshot model) and an AWS Backup recovery point"
    sync
    cp -f "$DATA_IMG" "$SNAP_IMG"
    local rp="$VAULT/recovery-point-checkout-shared"
    rm -rf "$rp"; mkdir -p "$rp"
    cp -a "$A_SHARED/receipts/." "$rp/"
    printf 'source=%s\ntaken_at=%s\nresource=%s\n' \
        "$A_SHARED/receipts" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EFS_ID" > "$rp/.recovery-point.meta"

    printf '\n'; ok "lab deployed and healthy"
    cmd_status
    say ""
    say "Next: $0 brief    (read the service map)"
    say "      $0 break --yes-disposable-vm"
}

# =============================================================================
#  brief — the teaching card
# =============================================================================
cmd_brief() {
    head1 "CLF-C02 3.6 — the storage services you must be able to tell apart"
    cat <<'BRIEF'
BLOCK — Amazon EBS
  Raw block device attached to one EC2 instance, living in ONE Availability
  Zone. You put a file system on it; it survives instance stop/start and
  termination (when DeleteOnTermination=false). Types: gp3/gp2 (general SSD),
  io2 Block Express/io1 (provisioned IOPS SSD), st1 (throughput HDD),
  sc1 (cold HDD). Snapshots are incremental and stored in Amazon S3, are
  region-scoped, and are how you move a volume to another AZ or Region.
  https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html

BLOCK, EPHEMERAL — EC2 instance store
  Disks physically attached to the host. Fastest, free with the instance, and
  GONE on stop, hibernate, termination or host failure. Buffers, caches,
  scratch — never the only copy of anything.
  https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html

FILE — Amazon EFS / Amazon FSx
  Shared POSIX (EFS, NFS) or Windows/SMB and specialised (FSx for Windows File
  Server, Lustre, NetApp ONTAP, OpenZFS) file systems. Many instances, many
  AZs, at the same time. Elastic: you do not provision capacity for EFS.
  This is the answer whenever a question says "shared across instances".
  https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html
  https://docs.aws.amazon.com/fsx/latest/WindowsGuide/what-is.html

OBJECT — Amazon S3
  Flat key/value object store, regional, 11 nines of durability by design,
  reached over HTTPS APIs, not mounted as a disk. Classes: Standard,
  Intelligent-Tiering, Standard-IA, One Zone-IA, Glacier Instant Retrieval,
  Glacier Flexible Retrieval, Glacier Deep Archive. Only the Glacier Flexible
  and Deep Archive classes require a RESTORE before you can read the object;
  Glacier Instant Retrieval is read like Standard. Lifecycle rules move objects
  between classes automatically — and will happily archive something you still
  need if the rule's prefix is wrong.
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects.html

HYBRID AND BULK TRANSFER
  AWS Storage Gateway — on-premises appliance presenting S3/EBS/Tape backed by
  AWS storage over NFS/SMB/iSCSI (File, Volume, Tape gateways).
  AWS Snow Family — physical devices for offline transfer of TB/PB when the
  network cannot carry it.
  AWS Backup — one policy-driven service for backups and recovery points across
  EBS, EFS, FSx, RDS, DynamoDB and more, with vaults and retention.
  https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
  https://docs.aws.amazon.com/snowball/latest/developer-guide/whatissnowball.html
  https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html

Exam reflex: match the requirement to the family first, the service second.
  "mounted by many instances"      -> EFS / FSx  (never EBS)
  "one instance, needs a file      -> EBS
   system, survives stop/start"
  "HTTP-accessible, unlimited,     -> S3
   static assets, backups, logs"
  "cheapest for records kept for   -> S3 Glacier Deep Archive (retrieval hours)
   7 years, rarely read"
  "temporary scratch, max speed"   -> instance store
  "on-prem app must keep NFS but   -> Storage Gateway
   store in AWS"
  "50 TB to move, slow WAN"        -> Snow Family
BRIEF
}

# =============================================================================
#  status
# =============================================================================
cmd_status() {
    [ -e "$LAB_ROOT/$LAB_MARKER" ] || die "no lab at $LAB_ROOT — run deploy first."
    head1 "Lab topology"
    printf '  region=%s   bucket=s3://%s\n' "$REGION" "$BUCKET"
    printf '  %s (%s) checkout-web-1   volume=%s   file system=%s\n' "$INST_A" "$AZ_A" "$VOL_DATA" "$EFS_ID"
    printf '  %s (%s) checkout-web-2   file system=%s\n' "$INST_B" "$AZ_B" "$EFS_ID"

    head1 "Loop devices (the lab's block volumes)"
    losetup -a 2>/dev/null | grep -F "$BLOCKSTORE" || say "  (none attached)"

    head1 "Mounts"
    local p
    for p in "$A_DATA" "$EFS_BACKING" "$A_SHARED" "$B_SHARED" "$A_SCRATCH"; do
        if is_mounted "$p"; then
            printf '  %-14s %s\n' "MOUNTED" "$(findmnt -no SOURCE,FSTYPE,TARGET "$p" | tr -s ' ')"
        else
            printf '  %-14s %s   %s(directory on the root volume)%s\n' "NOT MOUNTED" "$p" "$C_YEL" "$C_OFF"
        fi
    done

    head1 "fstab.lab"
    grep -v '^\s*#' "$FSTAB" | grep -v '^\s*$' | sed 's/^/  /'

    head1 "S3 inventory (s3://$BUCKET)"
    "$BIN/s3lab" list-objects-v2 --bucket "$BUCKET" \
        | awk '/"Key"/{k=$2} /"StorageClass"/{gsub(/[",]/,"",k); gsub(/[",]/,"",$2); printf "  %-34s %s\n", k, $2}'
    say "  lifecycle:"
    "$BIN/s3lab" get-bucket-lifecycle-configuration --bucket "$BUCKET" 2>/dev/null | sed 's/^/    /' \
        || say "    (no lifecycle configuration)"

    head1 "Application"
    grep -v '^#' "$APP_ENV" | grep . | sed 's/^/  /'
    "$BIN/checkout-app" report 2>/dev/null | sed 's/^/  /' || true
}

# =============================================================================
#  break
# =============================================================================
break_fault_1() {
    head1 "Injecting fault 1 — block storage"
    local ddev; ddev="$(loop_of "$DATA_IMG")"
    [ -n "$ddev" ] || die "data volume not attached; run deploy first"

    sync
    umount "$A_DATA" 2>/dev/null || true
    losetup -d "$ddev"
    # The volume is now "detached", and the mount entry is rewritten to the
    # legacy device alias you request at attach time — which on Nitro instances
    # is NOT what the kernel presents. This is the classic EC2 boot-time trap.
    write_fstab "/dev/sdf" "UUID=$(dev_uuid "$(loop_of "$EFS_IMG")")"

    # Traffic keeps flowing while the volume is missing: the writes land on the
    # instance root volume, underneath the empty mount point.
    local i
    for i in 1006 1007 1008; do
        "$BIN/checkout-app" order "$i" >/dev/null
    done
    printf '1006 1007 1008\n' > "$STATE/fault1_shadow_ids"
    ok "fault 1 injected"
}

break_fault_2() {
    head1 "Injecting fault 2 — object storage"
    # A "cost optimisation" lifecycle rule with an empty prefix: it matches every
    # key in the bucket, including the live application configuration.
    "$BIN/s3lab" put-bucket-lifecycle-configuration --bucket "$BUCKET" \
        --rule 'id=cost-savings-archive-everything,status=Enabled,prefix=,days=0,class=DEEP_ARCHIVE'
    "$BIN/s3lab" lifecycle-run --bucket "$BUCKET" 2>/dev/null
    rm -f "$VAR/cache/checkout.conf"     # the instance is restarting: cache cold
    ok "fault 2 injected"
}

break_fault_3() {
    head1 "Injecting fault 3 — file storage vs instance store"
    # Someone "improved performance" by moving uploads to the ephemeral disk,
    # migrated the data, deleted the source, and then the instance was stopped
    # and started. The only surviving copy is the AWS Backup recovery point.
    mkdir -p "$A_SCRATCH/receipts"
    cp -a "$A_SHARED/receipts/." "$A_SCRATCH/receipts/" 2>/dev/null || true
    rm -rf "${A_SHARED:?}/receipts"
    sed -i "s|^UPLOAD_DIR=.*|UPLOAD_DIR=$A_SCRATCH/receipts|" "$APP_ENV"
    # stop/start: the instance store is wiped.
    umount "$A_SCRATCH" 2>/dev/null || true
    mount -a -T "$FSTAB" 2>/dev/null || true
    ok "fault 3 injected"
}

cmd_break() {
    require_root; require_tools; require_confirmation
    [ -e "$LAB_ROOT/$LAB_MARKER" ] || die "no lab at $LAB_ROOT — run deploy first."

    case "$FAULT_SELECT" in
        1)   break_fault_1 ;;
        2)   break_fault_2 ;;
        3)   break_fault_3 ;;
        all) break_fault_1; break_fault_2; break_fault_3 ;;
        *)   die "unknown --fault '$FAULT_SELECT' (1, 2, 3 or all)" ;;
    esac

    cat <<EOF

$C_BLD=============================================================================
 INCIDENT REPORT — checkout service, $REGION
=============================================================================$C_OFF

Paging you at 03:10. The checkout service is degraded. Three separate storage
problems are in play. You have the whole lab; nothing outside \$LAB_ROOT is
involved, and every tool you need is already installed.

  Lab root       : $LAB_ROOT
  Tools          : $BIN/checkout-app   $BIN/s3lab   $BIN/lab-boot
  Mount table    : $FSTAB
  App settings   : $APP_ENV
  Backup vault   : $VAULT

$C_BLD SYMPTOM 1 — "the invoices we wrote yesterday are gone, and / is filling up"$C_OFF
  \`checkout-app report\` shows only the three newest invoices; 1001-1005 have
  vanished. \`findmnt --target $A_DATA\` shows the path is served by the ROOT
  file system, not by a dedicated device. Rebooting the instance
  (\`$BIN/lab-boot\`) does not help — it fails on one mount entry.

  YOUR OBJECTIVE
    - Bring the $VOL_DATA data volume back under $A_DATA.
    - Make the mount entry survive a reboot *and* a device-name change, the way
      AWS documents it for Nitro instances.
    - Do not lose data: the three invoices written while the volume was missing
      must end up on the volume together with 1001-1005.

$C_BLD SYMPTOM 2 — "new instances will not start"$C_OFF
  \`checkout-app start\` dies with:

      An error occurred (InvalidObjectState) when calling the GetObject
      operation: The operation is not valid for the object's storage class

  A cost-optimisation change was merged to the bucket yesterday.

  YOUR OBJECTIVE
    - Make s3://$BUCKET/$CONFIG_KEY readable again, and permanently so.
    - Make sure the automation cannot archive the live configuration again,
      while keeping the archival savings for the invoice objects.
    - \`checkout-app start\` must exit 0.

$C_BLD SYMPTOM 3 — "receipts disappear, and web-2 never sees them at all"$C_OFF
  Receipts written by checkout-web-1 vanish whenever the instance is stopped and
  started, and checkout-web-2 ($B_SHARED) has never seen a single one. A
  migration last week moved the upload directory "to the fast local disk" and
  deleted the original.

  YOUR OBJECTIVE
    - Put the receipts back on storage that is shared between both instances and
      survives stop/start, and repoint the application at it.
    - Restore the five receipts from the recovery point in the backup vault.
    - Both instances must list the same receipts.

$C_BLD DIAGNOSTIC TOOLKIT$C_OFF
  findmnt --target <path>        which device really serves this path
  findmnt -no SOURCE,FSTYPE <p>  device and file system type
  lsblk / losetup -a             which block devices exist and what backs them
  blkid <device>                 the stable UUID of a file system
  df -h <path> / du -sh <path>   space, and where it is actually being consumed
  mount -a -T $FSTAB             mount everything declared (this is the reboot)
  s3lab head-object ...          storage class and restore state of an object
  s3lab get-bucket-lifecycle-configuration --bucket $BUCKET

$C_BLD GRADING$C_OFF
  $0 verify        — checks every objective, tells you nothing else
  $0 status        — a full read-only picture of the lab

  The worked solution is at the bottom of this script, commented out. Try the
  three objectives first; \`verify\` will tell you honestly where you stand.

EOF
}

# =============================================================================
#  verify
# =============================================================================
PASSED=0; FAILED=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"; PASSED=$((PASSED+1))
    else
        bad "$desc"; FAILED=$((FAILED+1))
    fi
}

f1_volume_mounted() {
    local src ldev
    is_mounted "$A_DATA" || return 1
    src="$(findmnt -no SOURCE "$A_DATA")"
    ldev="$(loop_of "$DATA_IMG")"
    [ -n "$ldev" ] && [ "$src" = "$ldev" ]
}
f1_fstab_by_uuid() {
    local line spec uuid ldev
    line="$(grep -E "[[:space:]]${A_DATA//\//\\/}[[:space:]]" "$FSTAB" | grep -v '^#' | head -n1)"
    spec="$(printf '%s' "$line" | awk '{print $1}')"
    case "$spec" in UUID=*) : ;; *) return 1 ;; esac
    uuid="${spec#UUID=}"
    ldev="$(loop_of "$DATA_IMG")"
    [ -n "$ldev" ] && [ "$uuid" = "$(dev_uuid "$ldev")" ]
}
f1_all_invoices_on_volume() {
    local id ids
    ids="$(cat "$STATE/seed_ids" 2>/dev/null) $(cat "$STATE/fault1_shadow_ids" 2>/dev/null)"
    for id in $ids; do
        [ -f "$A_DATA/invoice-$id.json" ] || return 1
    done
    return 0
}
f2_config_readable() {
    "$BIN/s3lab" get-object --bucket "$BUCKET" --key "$CONFIG_KEY" /tmp/.clf36.$$ >/dev/null 2>&1
    local rc=$?; rm -f /tmp/.clf36.$$; return $rc
}
f2_config_standard() {
    "$BIN/s3lab" head-object --bucket "$BUCKET" --key "$CONFIG_KEY" 2>/dev/null \
        | grep -q '"StorageClass": "STANDARD"'
}
f2_lifecycle_scoped() {
    local f="$LAB_ROOT/s3/$BUCKET/lifecycle.rules"
    [ -s "$f" ] || return 0
    local id st pf dy cl
    while IFS='|' read -r id st pf dy cl; do
        [ "$st" = "Enabled" ] || continue
        case "$cl" in GLACIER|DEEP_ARCHIVE|GLACIER_IR) : ;; *) continue ;; esac
        case "$CONFIG_KEY" in "$pf"*) return 1 ;; esac
    done < "$f"
    return 0
}
f2_app_starts() { "$BIN/checkout-app" start >/dev/null 2>&1; }

_upload_dir() { grep '^UPLOAD_DIR=' "$APP_ENV" | tail -n1 | cut -d= -f2-; }
f3_upload_on_shared() {
    local u src edev
    u="$(_upload_dir)"; [ -n "$u" ] && [ -d "$u" ] || return 1
    src="$(findmnt -no SOURCE --target "$u")"
    edev="$(loop_of "$EFS_IMG")"
    [ -n "$edev" ] && [ "$src" = "$edev" ]
}
f3_receipts_restored() {
    local u id
    u="$(_upload_dir)" || return 1
    for id in $(cat "$STATE/seed_ids"); do
        [ -f "$u/receipt-$id.txt" ] || return 1
    done
    return 0
}
f3_visible_from_b() {
    local id sub u
    u="$(_upload_dir)"; sub="${u##*/}"
    for id in $(cat "$STATE/seed_ids"); do
        [ -f "$B_SHARED/$sub/receipt-$id.txt" ] || return 1
    done
    return 0
}
f3_survives_stop_start() {
    # Non-destructive: cycling the instance store must not affect the receipts.
    umount "$A_SCRATCH" 2>/dev/null || true
    mount -a -T "$FSTAB" >/dev/null 2>&1 || true
    f3_receipts_restored
}

cmd_verify() {
    require_root
    [ -e "$LAB_ROOT/$LAB_MARKER" ] || die "no lab at $LAB_ROOT — run deploy first."

    head1 "Fault 1 — block storage (Amazon EBS model)"
    check "$VOL_DATA is attached and mounted at $A_DATA"          f1_volume_mounted
    check "fstab entry identifies the volume by UUID, not device name" f1_fstab_by_uuid
    check "all eight invoices are on the volume (shadow writes recovered)" f1_all_invoices_on_volume

    head1 "Fault 2 — object storage (Amazon S3 model)"
    check "s3://$BUCKET/$CONFIG_KEY is readable"                   f2_config_readable
    check "the configuration object is back in STANDARD"           f2_config_standard
    check "no enabled lifecycle rule archives the config prefix"   f2_lifecycle_scoped
    check "checkout-app cold start succeeds"                       f2_app_starts

    head1 "Fault 3 — file storage vs instance store (EFS model)"
    check "UPLOAD_DIR is served by the shared file system"         f3_upload_on_shared
    check "the five receipts are restored from the backup vault"   f3_receipts_restored
    check "checkout-web-2 sees the same receipts"                  f3_visible_from_b
    check "receipts survive an instance stop/start"                f3_survives_stop_start

    rule
    printf '  passed: %s%s%s   failed: %s%s%s\n' \
        "$C_GRN" "$PASSED" "$C_OFF" "$C_RED" "$FAILED" "$C_OFF"
    if [ "$FAILED" -eq 0 ]; then
        ok "All objectives met. You can now explain, with your hands, why EBS is"
        say "    not EFS, why an archived object is not a deleted object, and why the"
        say "    instance store is never the only copy."
        return 0
    fi
    warn "Keep going — the worked solution is commented at the bottom of this script."
    return 1
}

# =============================================================================
#  destroy
# =============================================================================
cmd_destroy() {
    require_root; require_confirmation
    [ -e "$LAB_ROOT/$LAB_MARKER" ] || die "no lab at $LAB_ROOT (marker missing) — refusing."

    head1 "Tearing the lab down"
    local t
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        info "umount $t"
        umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null || true
    done < <(findmnt -rno TARGET | grep -F "$LAB_ROOT" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

    local img d
    for img in "$BLOCKSTORE"/*.img; do
        [ -f "$img" ] || continue
        d="$(loop_of "$img")"
        if [ -n "$d" ]; then info "losetup -d $d"; losetup -d "$d" || true; fi
    done

    rm -rf "${LAB_ROOT:?}"
    ok "removed $LAB_ROOT and detached every loop device the lab created"
}

# =============================================================================
#  main
# =============================================================================
usage() {
    cat <<EOF
CLF-C02 3.6 "Identify AWS storage services" — break & fix lab

  $0 deploy  --yes-disposable-vm    build the healthy lab (idempotent)
  $0 brief                          the service map you are being tested on
  $0 break   --yes-disposable-vm    inject the faults [--fault 1|2|3|all]
  $0 status                         read-only picture of the lab
  $0 verify                         grade the objectives
  $0 destroy --yes-disposable-vm    unmount, detach, delete

Environment: LAB_ROOT (default $LAB_ROOT), AWS_CLF_LAB_CONFIRM=1
EOF
}

main() {
    local action="${1:-help}"; shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes-disposable-vm) CONFIRM_FLAG=1; shift ;;
            --fault)             FAULT_SELECT="$2"; shift 2 ;;
            --lab-root)          LAB_ROOT="$2"; shift 2 ;;
            -h|--help)           usage; exit 0 ;;
            *)                   die "unknown option: $1" ;;
        esac
    done
    case "$action" in
        deploy)  cmd_deploy ;;
        brief)   cmd_brief ;;
        break)   cmd_break ;;
        status)  cmd_status ;;
        verify)  cmd_verify ;;
        destroy) cmd_destroy ;;
        help|-h|--help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

# =============================================================================
# =============================================================================
#
#   S O L U T I O N   —   do not read until `verify` has beaten you twice
#
# =============================================================================
# =============================================================================
#
# Throughout: LAB=/opt/aws-clf-lab-3.6 (or your LAB_ROOT).
#
#   export LAB=/opt/aws-clf-lab-3.6
#   export PATH="$LAB/bin:$PATH"
#
# -----------------------------------------------------------------------------
# STEP 0 — Recon before touching anything
# -----------------------------------------------------------------------------
#   sudo ./clf-c02-3.6-storage-breakfix.sh status
#   findmnt --target "$LAB/instances/i-0a7c3f2e9b1d4c5f0/mnt/data"
#   losetup -a | grep blockstore
#   df -h "$LAB"
#
# Read the output as a question about *which storage family* is involved:
# a path served by the root file system when it should have its own device is a
# block-storage problem; an InvalidObjectState is an object-storage problem; a
# path on tmpfs that should be shared is a file-storage problem.
#
# -----------------------------------------------------------------------------
# FAULT 1 — the EBS volume is detached and the mount entry is wrong
# -----------------------------------------------------------------------------
# Diagnosis
#
#   A="$LAB/instances/i-0a7c3f2e9b1d4c5f0"
#   findmnt --target "$A/mnt/data"
#       # -> shows the ROOT device, not a loop device: nothing is mounted there,
#       #    so every write since the outage has gone to the root volume,
#       #    hidden underneath the mount point. That is why / is filling up and
#       #    why invoices 1001-1005 "disappeared" (they are on the volume, which
#       #    is not mounted).
#   sudo "$LAB/bin/lab-boot"
#       # -> mount: special device /dev/sdf does not exist
#   grep -v '^#' "$LAB/etc/fstab.lab"
#       # -> the entry says /dev/sdf. On Nitro instances the kernel presents EBS
#       #    volumes as /dev/nvme1n1, /dev/nvme2n1..., and the order is not
#       #    guaranteed across reboots. AWS documents mounting by UUID for this
#       #    exact reason.
#       #    https://docs.aws.amazon.com/ebs/latest/userguide/ebs-using-volumes.html
#       #    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nvme-ebs-volumes.html
#
# Repair
#
#   # 1. Preserve the shadow writes that landed on the root volume.
#   sudo mkdir -p /root/shadow-rescue
#   sudo cp -a "$A/mnt/data/." /root/shadow-rescue/
#   ls /root/shadow-rescue          # invoice-1006/1007/1008.json
#
#   # 2. Re-attach the volume ("attach-volume" in AWS terms) and find its UUID.
#   IMG="$LAB/blockstore/vol-0f1e2d3c4b5a69788.img"
#   DEV=$(sudo losetup --find --show "$IMG")   # AWS: aws ec2 attach-volume ...
#   echo "$DEV"
#   sudo blkid -s UUID -o value "$DEV"
#   UUID=$(sudo blkid -s UUID -o value "$DEV")
#
#   # 3. Fix the mount entry so it is device-name independent.
#   sudo sed -i "s|^/dev/sdf|UUID=$UUID|" "$LAB/etc/fstab.lab"
#   grep data "$LAB/etc/fstab.lab"
#       # UUID=xxxxxxxx-xxxx-...  /opt/.../mnt/data  ext4  defaults,nofail  0 2
#
#   # 4. Clear the shadow directory FIRST, then mount. If you mount over it, the
#   #    shadowed files stay on the root volume, invisible and still consuming it.
#   sudo rm -f "$A/mnt/data"/invoice-*.json
#   sudo "$LAB/bin/lab-boot"
#   findmnt --target "$A/mnt/data"       # now a loop device, ext4
#
#   # 5. Merge the rescued invoices onto the volume.
#   sudo cp -a /root/shadow-rescue/. "$A/mnt/data/"
#   ls "$A/mnt/data" | wc -l             # 8
#
#   # Real AWS equivalent of the whole sequence:
#   #   aws ec2 attach-volume --volume-id vol-0f1e... --instance-id i-0a7c... --device /dev/sdf
#   #   lsblk -f                                   # find the real NVMe name
#   #   sudo blkid -s UUID -o value /dev/nvme1n1
#   #   echo "UUID=<uuid> /data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
#   #   sudo mount -a && sudo systemctl daemon-reload
#   # And if the volume itself were lost, you would restore it from the snapshot:
#   #   aws ec2 create-volume --snapshot-id snap-0d4c... --availability-zone us-east-1a
#   # (the lab's copy of that snapshot is blockstore/snap-0d4c3b2a1908f7e6d.img).
#
# -----------------------------------------------------------------------------
# FAULT 2 — a lifecycle rule archived the live configuration object
# -----------------------------------------------------------------------------
# Diagnosis
#
#   s3lab head-object --bucket clf-c02-checkout-artifacts-lab --key config/checkout.conf
#       # "StorageClass": "DEEP_ARCHIVE"
#   s3lab get-bucket-lifecycle-configuration --bucket clf-c02-checkout-artifacts-lab
#       # "ID": "cost-savings-archive-everything", "Prefix": "", "Days": 0,
#       # "StorageClass": "DEEP_ARCHIVE"   <- empty prefix = EVERY key in the bucket
#
#   The object was never deleted. Glacier Flexible Retrieval and Glacier Deep
#   Archive objects are not directly readable: you must issue a restore, wait for
#   the retrieval to finish, and then read the temporary copy. Glacier Instant
#   Retrieval and the IA classes are read like Standard — this is the exact
#   distinction CLF-C02 asks about.
#   https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects.html
#
# Repair
#
#   B=clf-c02-checkout-artifacts-lab
#
#   # 1. Stop the bleeding: replace the rule with one scoped to archival data only.
#   s3lab put-bucket-lifecycle-configuration --bucket "$B" \
#        --rule 'id=archive-old-invoices,status=Enabled,prefix=invoices/,days=90,class=GLACIER'
#   s3lab get-bucket-lifecycle-configuration --bucket "$B"
#
#   # 2. Restore the configuration object. DEEP_ARCHIVE supports Standard (<=12 h)
#   #    and Bulk (<=48 h) only — Expedited is rejected. The lab runs at 1 s per
#   #    AWS hour, so Standard completes in ~12 s.
#   s3lab restore-object --bucket "$B" --key config/checkout.conf \
#        --restore-request 'Days=3,GlacierJobParameters={Tier=Standard}'
#   # (Trying Tier=Expedited here returns InvalidRequest — worth doing once.)
#
#   # 3. Poll until the restore completes.
#   until s3lab head-object --bucket "$B" --key config/checkout.conf \
#         | grep -q 'ongoing-request=\"false\"'; do sleep 2; done
#   s3lab head-object --bucket "$B" --key config/checkout.conf
#       # "Restore": "ongoing-request=\"false\", expiry-date=\"...\""
#
#   # 4. A restore is TEMPORARY. To make the object permanently readable, copy it
#   #    onto itself with the target storage class — the standard AWS procedure.
#   s3lab copy-object --bucket "$B" --key config/checkout.conf \
#        --copy-source "$B/config/checkout.conf" --storage-class STANDARD
#   s3lab head-object --bucket "$B" --key config/checkout.conf   # STANDARD
#
#   # 5. Prove the workload recovers.
#   checkout-app start                                          # exits 0
#
#   # Real AWS equivalent:
#   #   aws s3api get-bucket-lifecycle-configuration --bucket $B
#   #   cat > lifecycle.json <<'JSON'
#   #   { "Rules": [ { "ID": "archive-old-invoices",
#   #                  "Filter": { "Prefix": "invoices/" },
#   #                  "Status": "Enabled",
#   #                  "Transitions": [ { "Days": 90, "StorageClass": "GLACIER" } ] } ] }
#   #   JSON
#   #   aws s3api put-bucket-lifecycle-configuration --bucket $B \
#   #       --lifecycle-configuration file://lifecycle.json
#   #   aws s3api restore-object --bucket $B --key config/checkout.conf \
#   #       --restore-request '{"Days":3,"GlacierJobParameters":{"Tier":"Standard"}}'
#   #   aws s3api head-object --bucket $B --key config/checkout.conf
#   #   aws s3 cp s3://$B/config/checkout.conf s3://$B/config/checkout.conf \
#   #       --storage-class STANDARD --metadata-directive COPY
#   # Prevention: keep live configuration out of blanket lifecycle scopes, or use
#   # S3 Intelligent-Tiering, which never puts an object in an asynchronous
#   # archive tier unless you opt in to the Deep Archive Access tier.
#
# -----------------------------------------------------------------------------
# FAULT 3 — the wrong storage service was chosen for shared, durable data
# -----------------------------------------------------------------------------
# Diagnosis
#
#   grep UPLOAD_DIR "$LAB/etc/checkout.env"
#       # -> .../mnt/scratch/receipts
#   findmnt -no SOURCE,FSTYPE --target "$LAB/instances/i-0a7c3f2e9b1d4c5f0/mnt/scratch"
#       # -> tmpfs tmpfs
#
#   tmpfs models the EC2 instance store: local, fast, and erased on stop, start,
#   hibernate, termination or host failure — and never visible to any other
#   instance. Receipts are shared, durable business records; they belong on a
#   shared file system (Amazon EFS, or FSx for a Windows/SMB workload), not on
#   ephemeral local disk and not on an EBS volume that only one instance can
#   attach in one AZ.
#   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html
#   https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html
#
# Repair
#
#   A="$LAB/instances/i-0a7c3f2e9b1d4c5f0"
#   B2="$LAB/instances/i-0b8d4a1c6e2f7b3a9"
#
#   # 1. Recreate the directory on the shared file system.
#   sudo mkdir -p "$A/mnt/shared/receipts"
#   findmnt -no SOURCE,FSTYPE --target "$A/mnt/shared/receipts"   # loop, ext4
#
#   # 2. Restore from the AWS Backup recovery point (the only surviving copy).
#   ls "$LAB/backup-vault/recovery-point-checkout-shared"
#   sudo cp -a "$LAB/backup-vault/recovery-point-checkout-shared/." \
#              "$A/mnt/shared/receipts/"
#   sudo rm -f "$A/mnt/shared/receipts/.recovery-point.meta"
#
#   # 3. Repoint the application at durable shared storage.
#   sudo sed -i "s|^UPLOAD_DIR=.*|UPLOAD_DIR=$A/mnt/shared/receipts|" "$LAB/etc/checkout.env"
#
#   # 4. Prove it is genuinely shared: the second instance sees the same files.
#   ls "$B2/mnt/shared/receipts"
#
#   # 5. Prove it is durable across a stop/start: cycling the instance store
#   #    must change nothing.
#   sudo umount "$A/mnt/scratch"; sudo mount -a -T "$LAB/etc/fstab.lab"
#   ls "$A/mnt/shared/receipts" | wc -l          # still 5
#
#   # Real AWS equivalent:
#   #   aws efs describe-file-systems --file-system-id fs-0c9b...
#   #   sudo mount -t efs -o tls fs-0c9b...:/ /mnt/shared      # amazon-efs-utils
#   #   echo "fs-0c9b...:/ /mnt/shared efs _netdev,tls 0 0" | sudo tee -a /etc/fstab
#   #   aws backup list-recovery-points-by-backup-vault --backup-vault-name checkout-vault
#   #   aws backup start-restore-job --recovery-point-arn arn:aws:... --iam-role-arn arn:aws:iam::...
#
# -----------------------------------------------------------------------------
# STEP 4 — Grade, then tear down
# -----------------------------------------------------------------------------
#   sudo ./clf-c02-3.6-storage-breakfix.sh verify      # 11/11
#   sudo ./clf-c02-3.6-storage-breakfix.sh destroy --yes-disposable-vm
#
# -----------------------------------------------------------------------------
# What each fault was really teaching (say these out loud before the exam)
# -----------------------------------------------------------------------------
#   1. An EBS volume is a device in one AZ attached to one instance. It is not
#      the data until it is mounted, and a mount point without its volume
#      silently swallows writes onto the root volume. Mount by UUID, because
#      device names are not stable — /dev/sdf is a request, /dev/nvme1n1 is what
#      you get. Snapshots (stored in S3, region-scoped) are how the volume
#      crosses an AZ or Region boundary.
#   2. An archived object is not a deleted object. Glacier Flexible Retrieval
#      and Deep Archive require restore-then-read, with retrieval measured in
#      minutes to hours and priced by tier; Glacier Instant Retrieval and the IA
#      classes read like Standard. A lifecycle rule with an empty prefix applies
#      to the entire bucket — cost optimisation is a scoping exercise.
#   3. Choosing storage is choosing durability and sharing semantics, not speed.
#      Instance store is ephemeral and instance-local. EBS is durable but
#      single-attach and single-AZ. EFS/FSx are shared, multi-AZ file systems.
#      S3 is regional object storage reached over an API, not a mounted disk.
#      And AWS Backup is what turns "we deleted the source" into an incident you
#      can end, instead of a data-loss postmortem.
# =============================================================================