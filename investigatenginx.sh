#!/usr/bin/env bash
set -euo pipefail

# === CONFIGURATION ===
IMG1="bitnamilegacy/nginx:1.29.1-debian-12-r0"
IMG2="library/nginx:1.29.2"
OUTDIR="./nginx-compare-report"
mkdir -p "$OUTDIR"/{img1,img2,img1-post,img2-post}

echo "=== [1/7] Pulling images ==="
docker pull "$IMG1"
docker pull "$IMG2"

# --- export rootfs (pre-entrypoint state) ---
echo "=== Exporting base root filesystems ==="
docker export "$(docker create "$IMG1")" | tar -C "$OUTDIR/img1" -xf -
docker export "$(docker create "$IMG2")" | tar -C "$OUTDIR/img2" -xf -

# --- package lists ---
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

# --- basic metadata diff ---
echo "=== Capturing image metadata ==="
docker inspect "$IMG1" | jq '.[0].Config | {Entrypoint, Cmd, Env}' > "$OUTDIR/inspect1.json"
docker inspect "$IMG2" | jq '.[0].Config | {Entrypoint, Cmd, Env}' > "$OUTDIR/inspect2.json"
diff "$OUTDIR/inspect1.json" "$OUTDIR/inspect2.json" > "$OUTDIR/inspect-diff.txt" || true

# === [2/7] Post-entrypoint snapshot ===
echo "=== Capturing post-entrypoint (runtime) state ==="
CID1=$(docker run -d --rm "$IMG1" sleep 300)
CID2=$(docker run -d --rm "$IMG2" sleep 300)

docker cp "$CID1":/etc/nginx "$OUTDIR/img1-post/etc-nginx" || true
docker cp "$CID2":/etc/nginx "$OUTDIR/img2-post/etc-nginx" || true
docker cp "$CID1":/opt "$OUTDIR/img1-post/opt" || true
docker cp "$CID2":/opt "$OUTDIR/img2-post/opt" || true

# Unified config diff and merged config graphs
diff -ru "$OUTDIR/img1-post/etc-nginx" "$OUTDIR/img2-post/etc-nginx" > "$OUTDIR/nginx-conf-post.diff" || true
docker exec "$CID1" nginx -T > "$OUTDIR/nginxT1.txt" 2>&1 || true
docker exec "$CID2" nginx -T > "$OUTDIR/nginxT2.txt" 2>&1 || true
diff -u "$OUTDIR/nginxT1.txt" "$OUTDIR/nginxT2.txt" > "$OUTDIR/nginxT-diff.txt" || true

docker kill "$CID1" "$CID2" >/dev/null 2>&1 || true

# === [3/7] Extended metadata & build history ===
echo "=== Capturing full image metadata & build history ==="
docker inspect "$IMG1" > "$OUTDIR/inspect1-full.json"
docker inspect "$IMG2" > "$OUTDIR/inspect2-full.json"
docker history --no-trunc "$IMG1" > "$OUTDIR/history1.txt"
docker history --no-trunc "$IMG2" > "$OUTDIR/history2.txt"

# === [4/7] Capabilities and SUID/SGID ===
echo "=== Capturing file capabilities and SUID/SGID ==="
for i in 1 2; do
  IMG_VAR="IMG$i"; IMG="${!IMG_VAR}"
  docker run --rm "$IMG" sh -lc 'command -v getcap >/dev/null || apt-get update && apt-get install -y libcap2-bin; getcap -r / 2>/dev/null' > "$OUTDIR/getcap$i.txt" || true
  docker run --rm "$IMG" sh -lc 'find / -xdev -perm -4000 -o -perm -2000 2>/dev/null' > "$OUTDIR/suid-sgid$i.txt" || true
done
diff -u "$OUTDIR/getcap1.txt" "$OUTDIR/getcap2.txt" > "$OUTDIR/getcap-diff.txt" || true
diff -u "$OUTDIR/suid-sgid1.txt" "$OUTDIR/suid-sgid2.txt" > "$OUTDIR/suid-sgid-diff.txt" || true

# === [5/7] Users, groups, CA certs, APT sources ===
echo "=== Capturing user/group and CA/apt sources data ==="
for i in 1 2; do
  IMG_VAR="IMG$i"; IMG="${!IMG_VAR}"
  docker run --rm "$IMG" sh -lc 'cat /etc/passwd' > "$OUTDIR/passwd$i.txt" || true
  docker run --rm "$IMG" sh -lc 'cat /etc/group'  > "$OUTDIR/group$i.txt"  || true
  docker run --rm "$IMG" sh -lc 'ls -l /etc/ssl | cat; ls -l /etc/ssl/certs | wc -l' > "$OUTDIR/ssl$i.txt" || true
  docker run --rm "$IMG" sh -lc 'grep -RhvE "^\s*#" /etc/apt/sources.list* 2>/dev/null' > "$OUTDIR/apt-sources$i.txt" || true
done
diff -u "$OUTDIR/passwd1.txt" "$OUTDIR/passwd2.txt" > "$OUTDIR/passwd-diff.txt" || true
diff -u "$OUTDIR/group1.txt"  "$OUTDIR/group2.txt"  > "$OUTDIR/group-diff.txt"  || true
diff -u "$OUTDIR/apt-sources1.txt" "$OUTDIR/apt-sources2.txt" > "$OUTDIR/apt-sources-diff.txt" || true

# === [6/7] Dynamic modules & load lists ===
echo "=== Capturing dynamic module listings ==="
docker run --rm "$IMG1" sh -lc 'nginx -V 2>&1 | sed -n "s|.*--modules-path=\([^ ]*\).*|\1|p" | xargs -r ls -l' > "$OUTDIR/modules1.txt" || true
docker run --rm "$IMG2" sh -lc 'nginx -V 2>&1 | sed -n "s|.*--modules-path=\([^ ]*\).*|\1|p" | xargs -r ls -l' > "$OUTDIR/modules2.txt" || true
diff -u "$OUTDIR/modules1.txt" "$OUTDIR/modules2.txt" > "$OUTDIR/modules-diff.txt" || true

# === [7/7] SBOM + vuln snapshot ===
echo "=== Generating SBOM and vulnerability scan ==="
if command -v syft >/dev/null 2>&1; then
  syft "$IMG1" -o json > "$OUTDIR/sbom1.json"
  syft "$IMG2" -o json > "$OUTDIR/sbom2.json"
fi

if command -v grype >/dev/null 2>&1; then
  grype "$IMG1" -o json > "$OUTDIR/vulns1.json"
  grype "$IMG2" -o json > "$OUTDIR/vulns2.json"
fi

# --- file + package diffs ---
echo "=== Creating file and package diffs ==="
diff -rq "$OUTDIR/img1" "$OUTDIR/img2" > "$OUTDIR/files-diff.txt" || true
diff "$OUTDIR/pkg1.txt" "$OUTDIR/pkg2.txt" > "$OUTDIR/pkg-diff.txt" || true
diff "$OUTDIR/nginxV1.txt" "$OUTDIR/nginxV2.txt" > "$OUTDIR/nginxV-diff.txt" || true

# === Generate markdown summary report ===
REPORT="$OUTDIR/NGINX_DIFF_REPORT.md"
echo "=== Building final Markdown summary ==="

cat > "$REPORT" <<EOF
# 🧾 NGINX Image Comparison Report
Generated: $(date)

**Images compared**
- $IMG1  
- $IMG2

---

## 🔍 Entrypoint / Env Diff
\`\`\`diff
$(cat "$OUTDIR/inspect-diff.txt")
\`\`\`

## ⚙️ NGINX Build Options Diff
\`\`\`diff
$(cat "$OUTDIR/nginxV-diff.txt")
\`\`\`

## 🧱 Post-Entrypoint Config (nginx -T) Diff
\`\`\`diff
$(head -n 200 "$OUTDIR/nginxT-diff.txt")
\`\`\`
*(truncated to 200 lines)*

## 🧩 Extended Image Metadata
See \`inspect*-full.json\` and \`history*.txt\` for base lineage and layers.

## 🔐 Capabilities and SUID/SGID Diff
\`\`\`diff
$(head -n 50 "$OUTDIR/getcap-diff.txt")
$(head -n 50 "$OUTDIR/suid-sgid-diff.txt")
\`\`\`
*(truncated)*

## 👥 User/Group and APT Sources Diff
\`\`\`diff
$(cat "$OUTDIR/passwd-diff.txt")
\`\`\`

\`\`\`diff
$(cat "$OUTDIR/apt-sources-diff.txt")
\`\`\`

## 🧩 Dynamic Module Diff
\`\`\`diff
$(cat "$OUTDIR/modules-diff.txt")
\`\`\`

## 📦 Package Diff
\`\`\`diff
$(head -n 200 "$OUTDIR/pkg-diff.txt")
\`\`\`
*(truncated)*

## 📁 File Tree Diff
\`\`\`diff
$(head -n 200 "$OUTDIR/files-diff.txt")
\`\`\`
*(truncated)*

---

Full raw outputs are stored under:  
\`$OUTDIR/\`

If syft/grype are installed, see:
- \`sbom*.json\` for Software Bill of Materials  
- \`vulns*.json\` for vulnerability results
EOF

echo "✅ Report generated at: $REPORT"
