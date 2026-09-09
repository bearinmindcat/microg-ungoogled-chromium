#!/usr/bin/env bash
set -euo pipefail

echo "=== microG smali patcher v3 (surgical) ==="
[ "$#" -ge 2 ] || { echo "Usage: $0 <input.apk> <output.apk> [keystore] [keystore_pass]"; exit 1; }
IN="$1"; OUT="$2"
KS="${3:-$HOME/.android/debug.keystore}"; KSPASS="${4:-android}"
NOSIGN=0; [ "${3:-}" = "--no-sign" ] && NOSIGN=1
GMS="com.google.android.gms"; MICROG="app.revanced.android.gms"

_sdk() {
  for _d in "src/third_party/android_sdk/public/build-tools" \
            "third_party/android_sdk/public/build-tools" \
            "${ANDROID_SDK_ROOT:-/nonexistent}/build-tools" \
            "${ANDROID_HOME:-/nonexistent}/build-tools"; do
    [ -d "$_d" ] || continue
    ls -d "$_d"/*/ 2>/dev/null | sort -V | tail -1
    return 0
  done
  return 0
}
_BT="$(_sdk || true)"
ZIPALIGN="${ZIPALIGN:-${_BT}zipalign}";  [ -x "$ZIPALIGN" ]  || ZIPALIGN=zipalign
APKSIGNER="${APKSIGNER:-${_BT}apksigner}"; [ -x "$APKSIGNER" ] || APKSIGNER=apksigner
echo "  build-tools: ${_BT:-<none found, using PATH>}"
command -v "$ZIPALIGN" >/dev/null 2>&1 || [ -x "$ZIPALIGN" ] \
  || { echo "FATAL: zipalign not found (looked in '${_BT:-}' and PATH)"; exit 1; }

SMALI_VER="${SMALI_VER:-3.0.9}"
SMALI_CACHE="${SMALI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/microg-smali}"
_JAVA="$(command -v java 2>/dev/null || true)"   # `command -v` failing must not abort under set -e
[ -x "src/third_party/jdk/current/bin/java" ] && _JAVA="src/third_party/jdk/current/bin/java"
_fetch_jar() {
  _n="$1"; _j="$SMALI_CACHE/$_n-$SMALI_VER-fat.jar"
  [ -s "$_j" ] && { echo "$_j"; return 0; }
  mkdir -p "$SMALI_CACHE"
  curl -fsSL -o "$_j.tmp" \
    "https://github.com/baksmali/smali/releases/download/$SMALI_VER/$_n-$SMALI_VER-fat.jar" \
    && mv -f "$_j.tmp" "$_j" && { echo "$_j"; return 0; }
  rm -f "$_j.tmp"; return 1
}
if command -v baksmali >/dev/null 2>&1 && command -v smali >/dev/null 2>&1; then
  BAKSMALI="baksmali"; SMALI="smali"
else
  [ -n "$_JAVA" ] || { echo "FATAL: no java, cannot run smali"; exit 1; }
  _b=$(_fetch_jar baksmali) && _s=$(_fetch_jar smali) || {
    echo "FATAL: baksmali/smali unavailable and download failed"; exit 1; }
  BAKSMALI="$_JAVA -jar $_b"; SMALI="$_JAVA -jar $_s"
  echo "  using smali $SMALI_VER from $SMALI_CACHE"
fi
for _t in zip unzip; do
  command -v "$_t" >/dev/null 2>&1 || { echo "FATAL: $_t not found"; exit 1; }
done

[ -f "$IN" ] || { echo "no such archive: $IN"; exit 1; }
case "$IN" in *.aab|*.aab.microg) MODE=aab ;; *) MODE=apk ;; esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "  in:  $IN"
echo "  out: $OUT"

echo "[1/5] extracting"
unzip -q "$IN" -d "$TMP/apk"
mapfile -t DEXES < <(cd "$TMP/apk" && find . -name 'classes*.dex' -printf '%P\n' 2>/dev/null | sort -V)
[ "${#DEXES[@]}" -gt 0 ] || { echo "  ERROR: no classes*.dex"; exit 1; }
echo "  mode: $MODE, dex files: ${#DEXES[@]}"

PATCHED_DEX=(); TOTAL=0; ALREADY=0
for dex in "${DEXES[@]}"; do
  d="$TMP/sm_$(echo "${dex%.dex}" | tr / _)"
  $BAKSMALI d "$TMP/apk/$dex" -o "$d" >/dev/null 2>&1 || continue

  while IFS= read -r f; do
    grep -q '"cn\.google"' "$f" 2>/dev/null || continue
    n=$(python3 - "$f" "$GMS" "$MICROG" <<'PY'
import re,sys
path,gms,micro=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(path).read()
m=re.search(r'(\.method static constructor <clinit>\(\)V\n)(.*?)(\.end method)', s, re.S)
if not m: print(0); raise SystemExit
body=m.group(2)
new_body,cnt=re.subn(r'(const-string(?:/jumbo)? [vp][0-9]+, )"%s"'%re.escape(gms),
                     r'\1"%s"'%micro, body)
if cnt:
    s=s[:m.start(2)]+new_body+s[m.end(2):]
    open(path,'w').write(s)
    print(cnt)
else:
    already=len(re.findall(r'const-string(?:/jumbo)? [vp][0-9]+, "%s"'%re.escape(micro), body))
    print(-already if already else 0)
PY
)
    if [ "${n:-0}" -gt 0 ]; then
      echo "  [2/5] $dex: patched $(basename "$f") <clinit> ($n string)"
      TOTAL=$((TOTAL+n))
      case " ${PATCHED_DEX[*]:-} " in *" $dex "*) ;; *) PATCHED_DEX+=("$dex");; esac
    elif [ "${n:-0}" -lt 0 ]; then
      echo "  [2/5] $dex: $(basename "$f") <clinit> already redirected ($(( -n )) string)"
      ALREADY=$((ALREADY - n))
    fi
  done < <(grep -rlE "const-string(/jumbo)? [vp][0-9]+, \"$GMS\"" "$d" 2>/dev/null || true)
done

if [ "$TOTAL" -eq 0 ] && [ "${ALREADY:-0}" -gt 0 ]; then
  echo "  already redirected ($ALREADY string) -- nothing to do, passing input through"
  cp -f "$IN" "$OUT"
  echo "=== done (no-op) ==="
  exit 0
fi
if [ "$TOTAL" -eq 0 ]; then
  echo "!! ERROR: GoogleAuthUtil <clinit> target not found."
  echo "   Locate manually: grep -rl '\"cn.google\"' <smali_out>"
  exit 2
fi
[ "$TOTAL" -le 2 ] || { echo "!! REFUSING: patched $TOTAL strings; expected 1-2."; \
  echo "   Over-patching breaks the Play-Services availability check and kills sign-in."; exit 3; }
echo "  redirected $TOTAL string(s) — availability checks left on real GMS (correct)"

echo "[3/5] reassembling"
for dex in "${PATCHED_DEX[@]}"; do
  _flat="$(echo "${dex%.dex}" | tr / _)"
  if ! $SMALI a "$TMP/sm_$_flat" -o "$TMP/new_$_flat.dex" 2>"$TMP/smali.err"; then
    echo "  ERROR: smali failed on $dex"
    sed 's/^/    /' "$TMP/smali.err" | head -12
    exit 1
  fi
  cp "$TMP/new_$_flat.dex" "$TMP/apk/$dex"; echo "  rebuilt $dex"
done

echo "[4/5] repacking"
if [ "$MODE" = aab ]; then
  ( cd "$TMP/apk" && zip -r -q -9 "$TMP/patched.apk" . -x "META-INF/*" )
  cp -f "$TMP/patched.apk" "$OUT"
  echo "[5/5] bundle written (jarsigner signs it downstream)"
  echo "=== done ==="; echo "  $OUT ($(du -h "$OUT" | cut -f1))"
  exit 0
fi
rm -rf "$TMP/apk/META-INF"
( cd "$TMP/apk" && zip -r -q -0 "$TMP/patched.apk" resources.arsc assets/ lib/ 2>/dev/null || true
  cd "$TMP/apk" && zip -r -q -9 "$TMP/patched.apk" . -x resources.arsc -x "assets/*" -x "lib/*" -x "META-INF/*" )

if [ "$NOSIGN" = 1 ]; then
  echo "[5/5] aligning (no-sign: caller will sign)"
  "$ZIPALIGN" -f -p 4 "$TMP/patched.apk" "$OUT"
else
  echo "[5/5] aligning + signing"
  "$ZIPALIGN" -f -p 4 "$TMP/patched.apk" "$TMP/aligned.apk"
  "$APKSIGNER" sign --ks "$KS" --ks-pass "pass:$KSPASS" --out "$OUT" "$TMP/aligned.apk"
fi

echo "=== done ==="
echo "  $OUT ($(du -h "$OUT" | cut -f1))"
