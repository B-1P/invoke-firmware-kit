#!/bin/sh
# Run user boot hooks from the writable /data partition, so changes can be
# deployed over SSH without reflashing. Each executable /data/boot.d/*.sh is
# started in the background; output goes to /data/boot.d/<name>.log.
D=/data/boot.d
[ -d "$D" ] || exit 0
for f in "$D"/*.sh; do
  [ -x "$f" ] || continue
  "$f" > "$f.log" 2>&1 < /dev/null &
done
