#!/bin/sh
# patch-mesa-binary-a830.sh -- make a *prebuilt* Mesa recognise the
# Adreno 830v1 (chip id 0x44050001) that mainline DRM reports.
#
# Derived from xiaobai-Lethe/Y700-elden-linux project/rootfs/patch-mesa-a830.sh,
# re-verified against the Mesa 26.0 / 26.1 / 26.2 device tables.
#
# Why this works: Mesa stores each GPU as a 64-bit id
#     (fuse/speedbin << 32) | chip_id
# and freedreno_dev_info.c::dev_id_compare() treats a table entry whose
# bits 47..32 are all ones (0xffff, "WILDCARD_FUSE_ID") as "ignore whatever
# fuse/speedbin the kernel reported".  Rewriting the existing A830 entry into
# 0xffff44050001 therefore makes every SM8750 Adreno 830 match - no rebuild.
#
# Usage:
#   patch-mesa-binary-a830.sh [--dry-run] FILE [FILE ...]
#
# Typical targets (Debian/Ubuntu layout):
#   /usr/lib/aarch64-linux-gnu/libgallium-<ver>.so
#   /usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so
#   /usr/lib/aarch64-linux-gnu/dri/*_dri.so
# Alpine:
#   /usr/lib/libgallium-<ver>.so /usr/lib/libvulkan_freedreno.so
set -eu

dry_run=0
if [ "${1:-}" = "--dry-run" ]; then
	dry_run=1
	shift
fi

[ $# -ge 1 ] || { echo "usage: $0 [--dry-run] FILE [FILE ...]" >&2; exit 2; }

# Edit one file in place. Exit codes: 0 = patched, 3 = already patched,
# 1 = pattern mismatch (nothing written).
edit_file() {
	_target=$1
	if command -v perl >/dev/null 2>&1; then
		perl -e '
			my $f = shift;
			my $o261 = pack("H*", "00000544ffff0000"); # 0x0000ffff44050000 Mesa 26.1/26.2
			my $o260 = pack("H*", "0000054400000000"); # 0x0000000044050000 Mesa 26.0 fake entry
			my $new  = pack("H*", "01000544ffff0000"); # 0x0000ffff44050001 target
			open my $in, "<:raw", $f or die "open $f: $!\n";
			local $/; my $d = <$in>; close $in;
			my $n261 = () = $d =~ /\Q$o261\E/g;
			my $n260 = () = $d =~ /\Q$o260\E/g;
			my $nnew = () = $d =~ /\Q$new\E/g;
			if ($n261 == 1 && $nnew == 0) {
				$d =~ s/\Q$o261\E/$new/;
				print "  mesa 26.1/26.2 entry -> 0xffff44050001\n";
			} elsif ($n260 == 1 && $nnew == 0) {
				$d =~ s/\Q$o260\E/$new/;
				print "  mesa 26.0 entry -> 0xffff44050001 (stopgap only)\n";
			} elsif ($nnew == 1 && $n261 == 0 && $n260 == 0) {
				print "  already patched\n";
				exit 3;
			} else {
				print STDERR sprintf("  unexpected A830 patterns: 26.1=%d 26.0=%d target=%d\n", $n261, $n260, $nnew);
				exit 1;
			}
			open my $out, ">:raw", $f or die "open $f: $!\n";
			print {$out} $d; close $out or die "close $f: $!\n";
		' "$_target"
	else
		python3 -c '
import sys
f = sys.argv[1]
o261 = bytes.fromhex("00000544ffff0000")
o260 = bytes.fromhex("0000054400000000")
new  = bytes.fromhex("01000544ffff0000")
d = open(f, "rb").read()
n261, n260, nnew = d.count(o261), d.count(o260), d.count(new)
if n261 == 1 and nnew == 0:
    d = d.replace(o261, new); print("  mesa 26.1/26.2 entry -> 0xffff44050001")
elif n260 == 1 and nnew == 0:
    d = d.replace(o260, new); print("  mesa 26.0 entry -> 0xffff44050001 (stopgap only)")
elif nnew == 1 and n261 == 0 and n260 == 0:
    print("  already patched"); sys.exit(3)
else:
    sys.exit(f"  unexpected A830 patterns: 26.1={n261} 26.0={n260} target={nnew}")
open(f, "wb").write(d)
' "$_target"
	fi
}

patched=0
for src in "$@"; do
	if [ ! -f "$src" ]; then
		echo "SKIP  $src: not a regular file" >&2
		continue
	fi

	tmp="$src.a830tmp.$$"
	cp -p "$src" "$tmp" || { echo "FAIL  $src: cannot copy" >&2; exit 1; }

	rc=0
	edit_file "$tmp" || rc=$?

	if [ "$rc" -eq 0 ]; then
		if [ "$dry_run" -eq 1 ]; then
			echo "WOULD PATCH $src"
		else
			chmod --reference="$src" "$tmp" 2>/dev/null || true
			mv -f "$tmp" "$src"
			echo "PATCHED $src"
			patched=$((patched + 1))
		fi
		rm -f "$tmp"
	elif [ "$rc" -eq 3 ]; then
		echo "OK      $src (already carries 0xffff44050001)"
		rm -f "$tmp"
	else
		echo "FAIL    $src" >&2
		rm -f "$tmp"
		exit 1
	fi
done

if [ "$dry_run" -eq 1 ]; then
	echo "dry run: nothing written"
else
	echo "done: $patched file(s) patched"
fi
