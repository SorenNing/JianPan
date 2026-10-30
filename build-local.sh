#!/bin/sh
# 「键盘」JianPan 本地构建
# tweak: 本地编译（arm64e 对象 + arm64 格式链接——键盘进程为 arm64/arm64e 混合，
#       UIKit 宿主进程的 tweak 用 arm64 slice 即可，KeyboardGlass 0.2/0.2.3 已验证可加载）
# prefs: 本地编译双 slice fat（arm64 + arm64e retag），若 Settings 闪退则改用 Actions 产物
set -e

ROOT=/var/minis/workspace/jianpan
SDK=/root/sdks/iPhoneOS16.5.sdk
CLANG=/usr/bin/clang-19
LLD=/usr/bin/ld64.lld
LDID=/usr/local/bin/ldid
LIPO=/root/theos-rh/toolchain/linux/iphone/bin/lipo
THINC=/root/theos-rh/vendor/include
OUT=/tmp/jp-local
VER=${VER_OVERRIDE:-$(rg '^Version:' $ROOT/control | awk '{print $2}')}

echo "=== JianPan $VER local build ==="
rm -rf "$OUT"
mkdir -p "$OUT/obj" "$OUT/pkg/DEBIAN"

# ---------- 1) 主 tweak dylib ----------
echo "--- compile tweak (arm64e objects) ---"
$CLANG -target arm64e-apple-ios15.0 -isysroot $SDK -fobjc-arc -fmodules \
  -I$ROOT -I$THINC -c $ROOT/JianPan.m -o $OUT/obj/JianPan.o

echo "--- link tweak (arm64 format, works in UIKit host processes) ---"
$LLD -arch arm64 -platform_version ios 15.0 17.0 -dylib -syslibroot $SDK \
  $OUT/obj/JianPan.o -o $OUT/JianPan.dylib \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -framework QuartzCore -framework CoreGraphics -lSystem \
  -undefined dynamic_lookup -install_name @loader_path/JianPan.dylib
$LDID -S -Cadhoc $OUT/JianPan.dylib
file $OUT/JianPan.dylib | cut -c1-80

# ---------- 2) prefs bundle ----------
echo "--- compile prefs (arm64 + arm64e) ---"
for A in arm64 arm64e; do
  $CLANG -target $A-apple-ios15.0 -isysroot $SDK -fobjc-arc -fmodules \
    -I$ROOT/prefs -I$THINC -c $ROOT/prefs/RootListController.m -o $OUT/obj/RootListController.$A.o
done

echo "--- link prefs arm64 slice (chained fixups) ---"
$LLD -arch arm64 -platform_version ios 15.0 17.0 -dylib -fixup_chains -syslibroot $SDK \
  $OUT/obj/RootListController.arm64.o -o $OUT/JianPanPrefs.arm64 \
  -framework UIKit -framework Foundation -framework CoreFoundation -framework CoreGraphics \
  -F$SDK/System/Library/PrivateFrameworks -framework Preferences \
  -lSystem -undefined dynamic_lookup
$LDID -S -Cadhoc $OUT/JianPanPrefs.arm64

echo "--- link prefs arm64e slice (retag subtype) ---"
$LLD -arch arm64 -platform_version ios 15.0 17.0 -dylib -fixup_chains -syslibroot $SDK \
  $OUT/obj/RootListController.arm64e.o -o $OUT/JianPanPrefs.arm64e.raw \
  -framework UIKit -framework Foundation -framework CoreFoundation -framework CoreGraphics \
  -F$SDK/System/Library/PrivateFrameworks -framework Preferences \
  -lSystem -undefined dynamic_lookup
python3 - "$OUT/JianPanPrefs.arm64e.raw" <<'PY'
import struct, sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
if struct.unpack_from('<I', b, 0)[0] != 0xfeedfacf:
    raise SystemExit('not thin 64-bit Mach-O')
struct.pack_into('<I', b, 8, 0x80000002)  # CPU_SUBTYPE_ARM64E
open(p, 'wb').write(b)
PY
$LDID -S -Cadhoc $OUT/JianPanPrefs.arm64e.raw

echo "--- lipo fat prefs ---"
$LIPO -create -output $OUT/JianPanPrefs \
  $OUT/JianPanPrefs.arm64 $OUT/JianPanPrefs.arm64e.raw
$LDID -S -Cadhoc $OUT/JianPanPrefs
file $OUT/JianPanPrefs | cut -c1-120

# ---------- 3) 组装 deb ----------
echo "--- assemble deb ---"
P=$OUT/pkg
D=$P/var/jb/Library/MobileSubstrate/DynamicLibraries
B=$P/var/jb/Library/PreferenceBundles/JianPanPrefs.bundle
L=$P/var/jb/Library/PreferenceLoader/Preferences
T=$P/var/jb/Library/JianPan/Themes
mkdir -p "$D" "$B" "$L" "$T"

cp $OUT/JianPan.dylib "$D/"
cp $ROOT/JianPan.plist "$D/JianPan.plist"
cp $ROOT/prefs/JianPan.plist "$L/JianPan.plist"
cp $OUT/JianPanPrefs "$B/"
cp $ROOT/prefs/Resources/Info.plist "$B/Info.plist"
cp $ROOT/prefs/Resources/Root.plist "$B/Root.plist"
cp $ROOT/prefs/Resources/icon.png $ROOT/prefs/Resources/icon@2x.png $ROOT/prefs/Resources/icon@3x.png "$B/"
cp $ROOT/pkg-deb/postinst "$P/DEBIAN/postinst"

sed "s/^Version: .*/Version: $VER/" $ROOT/control > "$P/DEBIAN/control"
chmod 0755 "$P/DEBIAN/postinst" "$D/JianPan.dylib" "$B/JianPanPrefs"

DEB=$OUT/com.ning.jianpan_${VER}_iphoneos-arm64e.deb
dpkg-deb --root-owner-group -Zgzip --build "$P" "$DEB"

echo "--- verify ---"
dpkg-deb -I "$DEB" | head -6
python3 -c "
import hashlib
h=hashlib.sha256(open('$DEB','rb').read()).hexdigest()
print('SHA256', h)"
echo "=== DONE: $DEB ==="
