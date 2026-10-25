#!/usr/bin/env bash
#
# Writes PIRInclude.Linux.API.Layout.inc: the layout checks of
# PIRUnit.Linux.API, taken from the installed C header
# /usr/include/linux/io_uring.h (package linux-libc-dev) with gcc.
#
# Run on Linux (WSL too), from any folder:
#   bash Generate-LinuxApiLayout.sh
#
# First it checks that LinuxApiLayout.c names every constant, record and
# field of the header; a name it does not know stops the script. Then it
# builds LinuxApiLayout.c and writes its output (UTF-8 with BOM, CRLF, like
# the other Pascal sources).
#
# A new header pin: install that header, run this script, add what it reports
# to LinuxApiLayout.c and to the Pascal unit, and run the Linux tests.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
header=/usr/include/linux/io_uring.h
source_file="$here/LinuxApiLayout.c"
output="$here/PIRInclude.Linux.API.Layout.inc"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

missing=0

# Constants: the #define names and the enum members of the header
awk '
  /^enum/ { in_enum = 1; next }
  in_enum && /^};/ { in_enum = 0; next }
  in_enum && match($0, /^[ \t]+[A-Z][A-Z0-9_]*/) {
    name = substr($0, RSTART, RLENGTH); gsub(/[ \t]/, "", name); print name; next
  }
  /^#define[ \t]+[A-Za-z_]/ && $2 != "LINUX_IO_URING_H" { print $2 }
' "$header" | sort -u > "$work/constants"

while read -r name; do
  if ! grep -qE "CONST\($name\)" "$source_file"; then
    echo "Not in LinuxApiLayout.c: constant $name"
    missing=1
  fi
done < "$work/constants"

# Records and their fields (fields of nested unions and structs belong to the
# outer record, as in C)
awk '
  /^struct [a-z_0-9]+ \{/ { s = $2; print s; next }
  s != "" && /^\};/ { s = ""; next }
  s != "" {
    line = $0
    gsub(/\/\*.*\*\//, "", line)
    if (line ~ /^[ \t]*(\/\*|\*)/ || line ~ /^[ \t]*\}/ || line ~ /^[ \t]*(union|struct)[ \t]*\{/) next
    if (match(line, /__DECLARE_FLEX_ARRAY\([^,]+,[ \t]*[A-Za-z_0-9]+\)/)) {
      name = substr(line, RSTART, RLENGTH); sub(/^.*,[ \t]*/, "", name); sub(/\)$/, "", name)
    } else if (match(line, /[A-Za-z_0-9]+(\[[^]]*\])?;/)) {
      name = substr(line, RSTART, RLENGTH); sub(/(\[.*)?;$/, "", name)
    } else next
    print s "." name
  }
' "$header" > "$work/records"

while read -r item; do
  if [[ "$item" == *.* ]]; then
    record="${item%%.*}"
    field="${item#*.}"
    if ! grep -qE "(FIELD|FIELD_AS|FLEX)\($record, $field[,)]" "$source_file"; then
      echo "Not in LinuxApiLayout.c: field $record.$field"
      missing=1
    fi
  elif ! grep -qE "SIZE\($item\)" "$source_file"; then
    echo "Not in LinuxApiLayout.c: record $item"
    missing=1
  fi
done < "$work/records"

if [ "$missing" -ne 0 ]; then
  echo "Stopped: add the names above to LinuxApiLayout.c (and to the Pascal unit)."
  exit 1
fi

gcc -std=gnu11 -Wall -Wextra -Werror -o "$work/layout" "$source_file"
{ printf '\xEF\xBB\xBF'; "$work/layout" | sed 's/$/\r/'; } > "$output"

echo "Checked $(wc -l < "$work/constants") constants and $(wc -l < "$work/records") records and fields of $header"
echo "Wrote $output ($(grep -c "ACheck(" "$output") checks)"
