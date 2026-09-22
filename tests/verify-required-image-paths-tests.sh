#!/bin/sh
#
# D-02 regression: 06-verify.sh's release-critical image assertions must
# actually fail.
#
# Before this, check() printed OK/MISS and set nothing; the script had no
# aggregation and no non-zero exit, while carrying a comment claiming its
# seed-manifest-library check made "missing from the image" impossible. It
# made nothing true. A missing library degrades silently to "extensions never
# derive a branch again", which is the trigger class for D-01's amplifier.
#
# These tests exercise check()/check_required() directly against a stub
# debugfs, so no built rootfs is needed and nothing here depends on a vendor
# tree. The canonical checkout is never modified.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERIFY="$REPO_ROOT/scripts/build/06-verify.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

W=$(mktemp -d "${TMPDIR:-/tmp}/verify-required.XXXXXX") || exit 1
[ -n "$W" ] || { echo "FATAL: mktemp gave no path"; exit 1; }
trap 'rm -rf "$W"' EXIT

# --- Source-level contract -------------------------------------------------

if grep -q '^check_required() {' "$VERIFY"; then
	pass "06-verify.sh defines check_required()"
else
	fail "06-verify.sh has no check_required() - critical paths cannot be distinguished from reporting ones"
fi

if grep -q 'MISS_REQUIRED=0' "$VERIFY"; then
	pass "06-verify.sh initialises a required-miss counter"
else
	fail "06-verify.sh has no required-miss counter"
fi

# The script runs under set -e, so check_required must NOT return non-zero -
# that would abort the run at the first MISS and destroy the remaining
# diagnostics, which are the reason to run it at all.
if grep -A12 '^check_required() {' "$VERIFY" | grep -qE '^\s*return 1'; then
	fail "check_required() returns non-zero - under set -e that aborts the whole verifier at the first MISS"
else
	pass "check_required() aggregates instead of returning non-zero (set -e safe)"
fi

if grep -q 'exit 1' "$VERIFY" && grep -q 'MISS_REQUIRED.*-gt 0' "$VERIFY"; then
	pass "06-verify.sh exits non-zero when a required path is missing"
else
	fail "06-verify.sh never exits non-zero on a required miss - it still gates nothing"
fi

# The seed-manifest library is the path D-02 is about.
if grep -q '^check_required /etc/nebulaos-seed-manifest.sh' "$VERIFY"; then
	pass "/etc/nebulaos-seed-manifest.sh is classified REQUIRED"
else
	fail "/etc/nebulaos-seed-manifest.sh is not required - the D-02 trigger path is still fail-open"
fi

# The false claim must be gone.
if grep -q 'which is what this check makes true' "$VERIFY"; then
	fail "06-verify.sh still claims the check makes absence impossible - the false claim survives"
else
	pass "the false 'this check makes it true' claim is gone from tracked source"
fi

# Guard against the opposite failure: a blanket promotion.
_req=$(grep -c '^check_required ' "$VERIFY")
_rep=$(grep -c '^\s*check ' "$VERIFY")
if [ "$_req" -ge 1 ] && [ "$_rep" -gt "$_req" ]; then
	pass "the required set is deliberate ($_req required vs $_rep reporting), not a blanket promotion"
elif [ "$_req" -eq 0 ]; then
	fail "required=0 reporting=$_rep - no path is release-blocking, so the verifier still gates nothing"
else
	fail "required=$_req reporting=$_rep - this looks like a blanket promotion of every check to fatal"
fi

# --- Behavioural: drive the real functions against a stub debugfs ----------
#
# The stub answers "Inode:" for every path EXCEPT the ones named in $ABSENT,
# which is how a missing image path is simulated without building an image.
mkdir -p "$W/bin"
cat > "$W/bin/debugfs" <<'STUB'
#!/bin/sh
# usage mirrors: debugfs -R "stat <path>" <image>
_req=""
while [ $# -gt 0 ]; do
	case "$1" in -R) _req="$2"; shift 2 ;; *) shift ;; esac
done
_path=${_req#stat }
for a in $ABSENT; do
	[ "$a" = "$_path" ] && { echo "stat: File not found by ext2_lookup"; exit 0; }
done
echo "Inode: 12   Type: regular"
STUB
chmod +x "$W/bin/debugfs"

# Extract just the two functions plus the counter, so this exercises the REAL
# definitions without running the whole verifier (which needs a built image).
sed -n '/^MISS_REQUIRED=0/,/^}/p;/^check_required() {/,/^}/p' "$VERIFY" > "$W/fns.sh"
if ! grep -q 'check_required() {' "$W/fns.sh"; then
	# Fall back to a wider slice if the layout differs.
	sed -n '/^MISS_REQUIRED=0/,/^check_required() {/p' "$VERIFY" > "$W/fns.sh"
	sed -n '/^check_required() {/,/^}/p' "$VERIFY" >> "$W/fns.sh"
fi

run_case() {
	_absent="$1"
	PATH="$W/bin:$PATH" ABSENT="$_absent" IMAGES="$W" sh -c '
		. "$0"
		check_required /etc/nebulaos-seed-manifest.sh "test"
		check /opt/some-optional-thing
		[ "$MISS_REQUIRED" -gt 0 ] && exit 1
		exit 0
	' "$W/fns.sh" 2>&1
	echo "rc=$?"
}

out=$(run_case "")
case "$out" in
	*"rc=0"*) pass "required file present -> verifier succeeds" ;;
	*) fail "required file present but the verifier did not succeed: $out" ;;
esac

out=$(run_case "/etc/nebulaos-seed-manifest.sh")
case "$out" in
	*"rc=1"*) pass "required file ABSENT -> MISS -> verifier returns non-zero" ;;
	*) fail "required file absent but the verifier still succeeded - it gates nothing: $out" ;;
esac
case "$out" in
	*"<== REQUIRED"*) pass "an absent required path is marked '<== REQUIRED' in the output" ;;
	*) fail "an absent required path is not visibly marked: $out" ;;
esac

out=$(run_case "/opt/some-optional-thing")
case "$out" in
	*"rc=0"*) pass "an absent REPORTING path does not fail the verifier (documented policy preserved)" ;;
	*) fail "an absent reporting-only path failed the verifier - blanket promotion: $out" ;;
esac

echo ""
echo "verify-required-image-paths-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
