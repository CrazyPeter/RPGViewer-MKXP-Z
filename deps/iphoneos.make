# 15.0, not 26.0. Xcode's clang only emits ARMv8.1 LSE (ldaddal, casal, swpal)
# and RCPC (ldapr) at -target ios26.0; below that it falls back to the LL/SC
# sequence an iOS 15 CPU has. Anything built for 26.0 and linked into this app
# would die at launch on whatever device lacks the extension -- see
# tools/check-lse.py, which fails the build when one slips in.
#
# Keep -miphoneos-version-min alongside -target. Without it ARCH_FLAG stays
# empty and the assembler sources (coroutine/arm64/Context.S, the setjmp shim)
# get built for macOS, which fails at link with "building for 'iOS', but
# linking in object file built for 'macOS'".
ARCH := arm64
HOST := aarch64-apple-darwin
SDK := iphoneos
MINIMUM_REQUIRED := 15.0
TARGET_FLAG := -miphoneos-version-min=$(MINIMUM_REQUIRED) -target arm64-apple-ios$(MINIMUM_REQUIRED)

include common.make
