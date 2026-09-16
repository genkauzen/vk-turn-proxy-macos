BUILDDIR ?= $(CURDIR)/build
DESTDIR ?= $(BUILDDIR)

# iOS SDK paths
IOS_SDK := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_SIM_SDK := $(shell xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
IOS_MIN_VERSION := 15.0

# macOS SDK paths. The archive is a plain GOOS=darwin c-archive: the bridge has
# no ios-only source (only its tests carry the `ios` tag), and the same GODEBUG
# constructor that keeps the iOS Network Extension alive is harmless on macOS.
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
MACOS_MIN_VERSION := 13.0

# Go settings
export CGO_ENABLED := 1
export GOARCH := arm64

GO_BUILD_FLAGS := -buildmode=c-archive -trimpath -tags ios
export GONOSUMCHECK := *
export GONOSUMDB := *
export GOFLAGS := -mod=mod
GO_LDFLAGS := -s -w

# Patched GOROOT: replaces mach_absolute_time with mach_continuous_time
# so that Go timers keep ticking while the iOS device is asleep.
REAL_GOROOT := $(shell go env GOROOT 2>/dev/null)
PATCHED_GOROOT := $(BUILDDIR)/goroot

.PHONY: all clean ios-device ios-simulator macos macos-arm64 macos-amd64 xcframework xcframework-macos goroot

all: xcframework

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Create a patched copy of GOROOT with boottime monotonic clock
goroot: $(BUILDDIR)
	@if [ ! -f "$(PATCHED_GOROOT)/.patched" ]; then \
		echo "==> Creating patched GOROOT (boottime monotonic clock)..."; \
		rm -rf "$(PATCHED_GOROOT)"; \
		mkdir -p "$(PATCHED_GOROOT)"; \
		rsync -a --delete --exclude=pkg/obj/go-build "$(REAL_GOROOT)/" "$(PATCHED_GOROOT)/"; \
		cd "$(PATCHED_GOROOT)" && patch -p1 -f -N -r- < "$(CURDIR)/goruntime-boottime-over-monotonic.diff"; \
		touch "$(PATCHED_GOROOT)/.patched"; \
		echo "==> GOROOT patched successfully"; \
	else \
		echo "==> Using cached patched GOROOT"; \
	fi

# Build for iOS device (arm64)
# CRITICAL: GOOS=ios (not darwin!) enables iOS-specific signal handling
# in the Go runtime, preventing "non-Go code disabled sigaltstack" crashes
# in Network Extension threads.
ios-device: goroot
	@echo "==> Building for iOS device (arm64) with GOOS=ios..."
	GOROOT="$(PATCHED_GOROOT)" \
	CGO_CFLAGS="-isysroot $(IOS_SDK) -arch arm64 -miphoneos-version-min=$(IOS_MIN_VERSION)" \
	CGO_LDFLAGS="-isysroot $(IOS_SDK) -arch arm64 -miphoneos-version-min=$(IOS_MIN_VERSION)" \
	GOARCH=arm64 \
	GOOS=ios \
	CGO_ENABLED=1 \
	CC="$(shell xcrun --sdk iphoneos -f clang) -isysroot $(IOS_SDK) -arch arm64 -miphoneos-version-min=$(IOS_MIN_VERSION)" \
	go build $(GO_BUILD_FLAGS) -ldflags "$(GO_LDFLAGS)" -o $(BUILDDIR)/libwg-turn-ios-arm64.a .
	@echo "==> Done: $(BUILDDIR)/libwg-turn-ios-arm64.a"

# Build for iOS Simulator (arm64 for Apple Silicon)
ios-simulator: goroot
	@echo "==> Building for iOS Simulator (arm64)..."
	GOROOT="$(PATCHED_GOROOT)" \
	CGO_CFLAGS="-isysroot $(IOS_SIM_SDK) -arch arm64 -miphonesimulator-version-min=$(IOS_MIN_VERSION)" \
	CGO_LDFLAGS="-isysroot $(IOS_SIM_SDK) -arch arm64 -miphonesimulator-version-min=$(IOS_MIN_VERSION)" \
	GOARCH=arm64 \
	GOOS=ios \
	CGO_ENABLED=1 \
	CC="$(shell xcrun --sdk iphonesimulator -f clang) -isysroot $(IOS_SIM_SDK) -arch arm64 -miphonesimulator-version-min=$(IOS_MIN_VERSION)" \
	go build $(GO_BUILD_FLAGS) -ldflags "$(GO_LDFLAGS)" -o $(BUILDDIR)/libwg-turn-sim-arm64.a .
	@echo "==> Done: $(BUILDDIR)/libwg-turn-sim-arm64.a"

# Build for macOS (Apple Silicon). GOOS=darwin, not ios: the macOS Network
# Extension runs as an ordinary process with sigaltstack available, and the
# ios-only runtime signal handling is not needed. The patched GOROOT is still
# used so Go timers keep ticking through sleep (mach_continuous_time); the
# patch touches sys_darwin*, shared by both targets.
macos-arm64: goroot
	@echo "==> Building for macOS (arm64) with GOOS=darwin..."
	GOROOT="$(PATCHED_GOROOT)" \
	CGO_CFLAGS="-isysroot $(MACOS_SDK) -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	CGO_LDFLAGS="-isysroot $(MACOS_SDK) -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	GOARCH=arm64 \
	GOOS=darwin \
	CGO_ENABLED=1 \
	CC="$(shell xcrun --sdk macosx -f clang) -isysroot $(MACOS_SDK) -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	go build -buildmode=c-archive -trimpath -ldflags "$(GO_LDFLAGS)" -o $(BUILDDIR)/libwg-turn-macos-arm64.a .
	@echo "==> Done: $(BUILDDIR)/libwg-turn-macos-arm64.a"

# Build for macOS (Intel). Cross-compiled from any Mac: Go targets amd64 and
# clang gets -arch x86_64 against the same SDK.
macos-amd64: goroot
	@echo "==> Building for macOS (amd64) with GOOS=darwin..."
	GOROOT="$(PATCHED_GOROOT)" \
	CGO_CFLAGS="-isysroot $(MACOS_SDK) -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	CGO_LDFLAGS="-isysroot $(MACOS_SDK) -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	GOARCH=amd64 \
	GOOS=darwin \
	CGO_ENABLED=1 \
	CC="$(shell xcrun --sdk macosx -f clang) -isysroot $(MACOS_SDK) -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	go build -buildmode=c-archive -trimpath -ldflags "$(GO_LDFLAGS)" -o $(BUILDDIR)/libwg-turn-macos-amd64.a .
	@echo "==> Done: $(BUILDDIR)/libwg-turn-macos-amd64.a"

# Universal macOS archive: one xcframework slice may carry both Mac
# architectures only as a fat file, so lipo them together.
macos: macos-arm64 macos-amd64
	@echo "==> Creating universal macOS archive..."
	lipo -create $(BUILDDIR)/libwg-turn-macos-arm64.a $(BUILDDIR)/libwg-turn-macos-amd64.a \
		-output $(BUILDDIR)/libwg-turn-macos.a
	@echo "==> Done: $(BUILDDIR)/libwg-turn-macos.a"

# Create XCFramework from every architecture: iOS device, iOS Simulator and
# macOS. One framework path in project.yml then serves all three platforms.
xcframework: ios-device ios-simulator macos
	@echo "==> Creating XCFramework..."
	rm -rf $(DESTDIR)/WireGuardTURN.xcframework
	xcodebuild -create-xcframework \
		-library $(BUILDDIR)/libwg-turn-ios-arm64.a -headers $(CURDIR)/include \
		-library $(BUILDDIR)/libwg-turn-sim-arm64.a -headers $(CURDIR)/include \
		-library $(BUILDDIR)/libwg-turn-macos.a -headers $(CURDIR)/include \
		-output $(DESTDIR)/WireGuardTURN.xcframework
	@echo "==> Done: $(DESTDIR)/WireGuardTURN.xcframework"

# macOS-only XCFramework, for a Mac that has no iOS SDK installed or a
# macOS-only build. Same output path — the iOS targets simply have no slice.
xcframework-macos: macos
	@echo "==> Creating macOS-only XCFramework..."
	rm -rf $(DESTDIR)/WireGuardTURN.xcframework
	xcodebuild -create-xcframework \
		-library $(BUILDDIR)/libwg-turn-macos.a -headers $(CURDIR)/include \
		-output $(DESTDIR)/WireGuardTURN.xcframework
	@echo "==> Done: $(DESTDIR)/WireGuardTURN.xcframework"

clean:
	rm -rf $(BUILDDIR)
	rm -rf $(DESTDIR)/WireGuardTURN.xcframework
