#!/usr/bin/env bash
set -euo pipefail

# --- configuration ---
IMG1="bitnamilegacy/nginx:1.29.1-debian-11-r1"
IMG2="nginx/nginx:1.29.2"
OUTDIR="./nginx-compare-report"
mkdir -p "$OUTDIR"/{img1,img2}

echo "=== Pulling images ==="
docker pull "$IMG1"
docker pull "$IMG2"

# --- export rootfs ---
echo "=== Exporting root filesystems ==="
docker export "$(docker create "$IMG1")" | tar -C "$OUTDIR/img1" -xf -
docker export "$(docker create "$IMG2")" | tar -C "$OUTDIR/img2" -xf -

# --- package list ---
echo "=== Collecting package lists ==="
{
  echo "# Package list for $IMG1"
  docker run --rm "$IMG1" bash -c 'if command -v dpkg >/dev/null; then dpkg -l; elif command -v apk >/dev/null; then apk list -I; else echo "(no package manager found)"; fi'
} > "$OUTDIR/pkg1.txt" || true

{
  echo "# Package list for $IMG2"
  docker run --rm "$IMG2" bash -c 'if command -v dpkg >/dev/null; then dpkg -l; elif command -v apk >/dev/null; then apk list -I; else echo "(no package manager found)"; fi'
} > "$OUTDIR/pkg2.txt" || true

# --- nginx -V output ---
echo "=== Capturing nginx -V output ==="
docker run --rm "$IMG1" nginx -V 2>&1 > "$OUTDIR/nginxV1.txt" || echo "(no nginx binary)" > "$OUTDIR/nginxV1.txt"
docker run --rm "$IMG2" nginx -V 2>&1 > "$OUTDIR/nginxV2.txt" || echo "(no nginx binary)" > "$OUTDIR/nginxV2.txt"

# --- entrypoint + env ---
echo "=== Capturing image metadata ==="
docker inspect "$IMG1" | jq '.[0].Config | {Entrypoint, Cmd, Env}' > "$OUTDIR/inspect1.json"
docker inspect "$IMG2" | jq '.[0].Config | {Entrypoint, Cmd, Env}' > "$OUTDIR/inspect2.json"

# --- file diff ---
echo "=== Generating file diff ==="
diff -rq "$OUTDIR/img1" "$OUTDIR/img2" > "$OUTDIR/files-diff.txt" || true

# --- package diff ---
diff "$OUTDIR/pkg1.txt" "$OUTDIR/pkg2.txt" > "$OUTDIR/pkg-diff.txt" || true

# --- nginx compile diff ---
diff "$OUTDIR/nginxV1.txt" "$OUTDIR/nginxV2.txt" > "$OUTDIR/nginxV-diff.txt" || true

# --- entrypoint diff ---
diff "$OUTDIR/inspect1.json" "$OUTDIR/inspect2.json" > "$OUTDIR/inspect-diff.txt" || true

# --- final markdown summary ---
REPORT="$OUTDIR/NGINX_DIFF_REPORT.md"
cat > "$REPORT" <<EOF
# NGINX Image Comparison Report
Generated: $(date)

**Images compared**
- \$IMG1  
- \$IMG2

---

## 🔍 Entrypoint / Env Diff
\`\`\`diff
$(cat "$OUTDIR/inspect-diff.txt")
\`\`\`

## ⚙️ NGINX Build Options Diff
\`\`\`diff
$(cat "$OUTDIR/nginxV-diff.txt")
\`\`\`

## 📦 Package Diff
\`\`\`diff
$(head -n 200 "$OUTDIR/pkg-diff.txt")
\`\`\`
*(truncated to first 200 lines for brevity)*

## 🧾 File Tree Diff
\`\`\`diff
$(head -n 200 "$OUTDIR/files-diff.txt")
\`\`\`
*(truncated to first 200 lines for brevity)*

---

Full raw outputs are stored under:  
\`$OUTDIR/\`
EOF

echo "✅ Report generated: $REPORT"
