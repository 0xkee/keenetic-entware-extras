#!/opt/bin/sh
# Generate opkg Packages index from .ipk files in a directory.
# Usage: ./scripts/generate-packages-index.sh [dir]
#
# For each .ipk in <dir>:
#   - Extracts control metadata from the package
#   - Appends Filename, Size, MD5sum, SHA256sum fields
# Produces <dir>/Packages and <dir>/Packages.gz
set -eu

DIR="${1:-.}"

if [ ! -d "$DIR" ]; then
    echo "ERROR: Directory not found: $DIR" >&2
    exit 1
fi

PACKAGES_FILE="$DIR/Packages"
: > "$PACKAGES_FILE"

count=0

for ipk in "$DIR"/*.ipk; do
    # Skip if glob didn't expand (no .ipk files)
    [ -e "$ipk" ] || continue

    tmpdir="$(mktemp -d)"

    # .ipk is tar.gz: ./debian-binary, ./control.tar.gz, ./data.tar.gz
    tar -xzf "$ipk" -C "$tmpdir" ./control.tar.gz
    # control.tar.gz contains ./control (plus postinst, postrm, etc.)
    tar -xzf "$tmpdir/control.tar.gz" -C "$tmpdir" ./control

    # Append control fields + package metadata
    # Command substitution strips trailing newlines from control
    control_content="$(cat "$tmpdir/control")"
    filename="$(basename "$ipk")"
    size="$(stat -c%s "$ipk")"
    md5="$(md5sum "$ipk" | cut -d' ' -f1)"
    sha256="$(sha256sum "$ipk" | cut -d' ' -f1)"

    {
        printf "%s\n" "$control_content"
        printf "Filename: %s\n" "$filename"
        printf "Size: %s\n" "$size"
        printf "MD5sum: %s\n" "$md5"
        printf "SHA256sum: %s\n" "$sha256"
        printf "\n"
    } >> "$PACKAGES_FILE"

    rm -rf "$tmpdir"
    count=$((count + 1))
done

# Generate compressed index
gzip -k -f "$PACKAGES_FILE"

echo "Generated Packages index: $count package(s) in $DIR"
