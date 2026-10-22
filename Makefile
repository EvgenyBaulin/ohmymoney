# OhMyMoney — build entry points. `make` builds and runs; `make verify` is what CI checks too.
SHELL := /bin/bash

PROJECT      := OhMyMoney.xcodeproj
SCHEME       := OhMyMoney
SCHEME_STORE := OhMyMoney-AppStore
# Build artefacts live outside the repository: it only holds a symbolic link,
# so every path below still reads as if the build were local.
# A machine whose sandbox permissions name another folder says so in `.local-paths.mk`, a file
# that is not under version control: `BUILD_ROOT := <folder>`. Everything below, and every
# script (as OHMYMONEY_BUILD_ROOT), goes through this one variable.
-include .local-paths.mk
BUILD_ROOT   ?= $(HOME)/Library/Developer/OhMyMoney
BUILD_DIR    := Build.nosync
# Through the real path, never through the `Build.nosync` link. They name the same directory,
# but xcodebuild compares the files it wants to delete against the root it was given as text:
# reached through the link, every intermediate of a build from scratch sits "outside of the
# allowed root paths", and 1433 stale files are left behind with a warning each.
DERIVED      := $(BUILD_ROOT)/DerivedData
SPM_PKGS     := $(BUILD_ROOT)/SourcePackages
# Where `swift test` of the two packages keeps its build (`spm-appcore`, `spm-appdatabase` and the
# release twins of `bench` inside it). A second run of the package tests at the same time gives
# a folder of its own, `SPM_SCRATCH=<folder>`: SwiftPM locks its scratch directory, so two runs
# over one wait for each other or fail.
SPM_SCRATCH  ?= $(BUILD_DIR)
DEST         := platform=macOS,arch=arm64
SIGN         := CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""
# The Debug build, its tests and the UI-test runner are signed with the owner's self-signed
# certificate when the keychain has it and trusts it for code signing: then their signature
# stays the same from build to build, and the permissions macOS gave them (Accessibility,
# automation) survive a rebuild. Without it — as on CI and
# before the owner makes it — ad-hoc, as before. Release and AppStore stay ad-hoc.
SIGN_NAME    := OhMyMoney Local Signing
DEV_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(SIGN_NAME)"' && echo '$(SIGN_NAME)' || echo '-')
SIGN_DEV     := CODE_SIGN_IDENTITY="$(DEV_IDENTITY)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""
FORMAT       := xcrun --toolchain default swift-format
# Every tool comes from the toolchain Xcode uses, never from whatever `swift` the shell finds
# first. A `swift` on PATH may resolve its `swift-test` subcommand to another
# toolchain, and both `xcrun` and `xcodebuild` obey the TOOLCHAINS variable; naming the
# toolchain here settles it for the packages and for the app alike.
SWIFT        := xcrun --toolchain default swift
XCB_TOOLCHAIN := -toolchain com.apple.dt.toolchain.XcodeDefault
# No timeout(1) on macOS: perl's alarm is the watchdog. Exit 142 means "timed out".
TMO          := /usr/bin/perl -e 'alarm shift; exec @ARGV'
AWAKE        := caffeinate -i
# One alarm per process: `caffeinate` and `perl` both hand the process over with `exec`, so a
# second $(TMO) around a recipe would merely replace the first. The limit is a variable a
# target can lower instead (`test-one`), which is why these are `=` and not `:=`.
XCB_TIME     ?= 1800
XCB_BASE      = $(AWAKE) $(TMO) $(XCB_TIME) xcodebuild -project $(PROJECT) -destination '$(DEST)' \
	            -derivedDataPath $(DERIVED) -clonedSourcePackagesDirPath $(SPM_PKGS) \
	            $(XCB_TOOLCHAIN)
XCB           = $(XCB_BASE) $(SIGN)
XCB_DEV       = $(XCB_BASE) $(SIGN_DEV)
# A test that hangs should end as a failure, not as half an hour of silence. The allowance is
# per test method and is rounded up to whole minutes by XCTest.
TEST_TIME    := -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
	            -maximum-test-execution-time-allowance 300
# A UI test waits up to two minutes for its first window on a generated set and clicks through
# several windows after that, so it gets more; but one stuck on a system prompt still ends as a
# failure with its name, not as the alarm of the whole run (XCB_TIME) half an hour later.
UI_TEST_TIME := -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
	            -maximum-test-execution-time-allowance 600
APP          := $(DERIVED)/Build/Products/Debug/OhMyMoney.app
RELEASE_APP  := $(DERIVED)/Build/Products/Release/OhMyMoney.app
# The data sets live in the container of the Debug build, which has an id of its own, next to
# its database and never inside it (AppPaths.DataSet). `make bench-app` builds its Release with
# the same id, so both builds open the same sets, and reads its times from there.
DEBUG_ID     := io.github.EvgenyBaulin.ohmymoney.debug
CONTAINER    := $(HOME)/Library/Containers/$(DEBUG_ID)/Data/Library/Application Support/OhMyMoney
BENCH_TIMES  := $(CONTAINER)/Sets/bench/measurements.txt
# The Python of the pandas check: a venv outside the repository. Its path is
# the real one under BUILD_ROOT, not the link in the repository, whose path has spaces. The
# marker is written only once pandas imports, so a half-made venv is never used. The recipes
# look for the marker when they run, not when make reads this file: `make pyenv test-core`
# in one command makes the venv first and then uses it.
# Every build writes its output here as well, so `check-warnings` can read it back.
LOGS         := $(BUILD_DIR)/logs
PYENV        := $(BUILD_ROOT)/pyenv
PYENV_PYTHON := $(PYENV)/bin/python
PYENV_MARKER := $(PYENV)/pandas.ok

.PHONY: all generate build-dir build run test test-core test-db test-ui fmt lint verify test-one eval-model migration-dry-run \
	    check-core-purity check-toolchain check-warnings check-scripts check-chart-double check-privacy check-environment check-geometry check-stale check-attribution check-native check-glass check-fonts check-names check-ci check-log-names check-strings ci-checks hooks clean install \
	    archive-appstore build-appstore check-appstore-clean release-local release-check sample sample-large demo \
	    bench bench-app pyenv build-ios test-ios run-ios run-ios-go

all: run

# One target at a time, whatever `-j` says. The order of `verify` is its meaning: `check-warnings`
# and `check-stale` read the logs `build`, `test`, `test-core`, `test-db` and `check-appstore-clean`
# write, and under `-j` they would read them half-written and say «none». xcodebuild and SwiftPM
# run their own work in parallel already; make has nothing to gain.
.NOTPARALLEL:

# Xcode keeps the app's pins in the workspace — unless the workspace has no pin file yet and a
# local package has one: then it writes the app's whole graph, Sparkle included, into
# Packages/AppDatabase/Package.resolved, which `swift test` writes back, and `make test-db`
# fails after every build. The workspace gets its own file first, seeded from
# the package's, so the GRDB pin the tests ran against is the one the app starts from.
XCODE_PINS := $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# The project is written again only when the spec or the list of files changed (`--use-cache`,
# the cache outside the repository). XcodeGen itself rewrites OhMyMoney.xcodeproj on every run, even
# when nothing in it differs, and an Xcode open on the project reloads it whenever the file
# changes. It was chosen on 19.09 for a reason that has gone since: the repository lay in iCloud
# Drive, every new copy of the project set the file provider scanning it, and xcodebuild waited
# on that scan for minutes. The repository left iCloud that day.
# CI generates with the XcodeGen scripts/install-xcodegen.sh pins; another release here may
# write another project, so it is said, not refused.
generate: build-dir
	@pin="$$(scripts/install-xcodegen.sh --pinned)"; \
	    have="$$(xcodegen --version 2> /dev/null | sed -n 's/^Version: *//p')"; \
	    [ "$$have" = "$$pin" ] || \
	    echo "generate: xcodegen $${have:-?} here, CI generates with $$pin (scripts/install-xcodegen.sh)"
	xcodegen generate --spec project.yml --quiet --use-cache --cache-path "$(BUILD_ROOT)/xcodegen.cache"
	@if [ ! -f "$(XCODE_PINS)" ]; then mkdir -p "$(dir $(XCODE_PINS))"; \
	    cp Packages/AppDatabase/Package.resolved "$(XCODE_PINS)"; fi

# Recreates the link to the build directory when it is missing, for example after a clone
# or after `make clean`. A real folder of that name, left by an older checkout, is replaced only
# when it is empty: it may hold somebody's release archives, and nothing says so but its files.
build-dir:
	@mkdir -p "$(BUILD_ROOT)"
	@if [ ! -L $(BUILD_DIR) ]; then \
	    if [ -e $(BUILD_DIR) ] && ! rmdir $(BUILD_DIR) 2> /dev/null; then \
	        echo "build-dir: $(BUILD_DIR) is not the link to $(BUILD_ROOT) and is not empty;" \
	            "nothing was removed. Move out what you need, remove it, and run make again." >&2; \
	        exit 1; \
	    fi; \
	    ln -sfn "$(BUILD_ROOT)" $(BUILD_DIR); \
	fi

build: generate
	@echo "signing Debug with: $(DEV_IDENTITY)"
	@mkdir -p $(LOGS)
	set -o pipefail; $(XCB_DEV) -scheme $(SCHEME) -configuration Debug build \
	    2>&1 | tee $(LOGS)/build.log

# The iPhone app. It compiles the Mac app's shared layers in place (project.yml), so the same
# sources are built twice, once per platform. The simulator is named, not numbered: the ids of the
# devices differ from Mac to Mac. Tests of the iPhone target are logic-only and run on it.
IOS_SCHEME   := OhMyMoney-iOS
IOS_SIM      ?= iPhone 17
IOS_XCB       = $(AWAKE) $(TMO) $(XCB_TIME) xcodebuild -project $(PROJECT) -scheme $(IOS_SCHEME) \
	            -derivedDataPath $(DERIVED) -clonedSourcePackagesDirPath $(SPM_PKGS) \
	            $(XCB_TOOLCHAIN) CODE_SIGNING_ALLOWED=NO

build-ios: generate
	@mkdir -p $(LOGS)
	set -o pipefail; $(IOS_XCB) -configuration Debug -destination 'generic/platform=iOS Simulator' build \
	    2>&1 | tee $(LOGS)/build-ios.log

test-ios: generate
	@mkdir -p $(LOGS)
	set -o pipefail; $(IOS_XCB) -configuration Debug -destination 'platform=iOS Simulator,name=$(IOS_SIM)' \
	    -only-testing:OhMyMoneyTests-iOS $(TEST_TIME) test 2>&1 | tee $(LOGS)/test-ios.log
	@! grep -q "Executed 0 tests" $(LOGS)/test-ios.log || \
	    (echo "test-ios: no test ran" && exit 1)

# Builds the iPhone/iPad app signed with the development team and installs it on every connected,
# ready device (iPhone and iPad alike; a device that is not ready is skipped with the reason).
# `make run-ios` needs no arguments; DEVICE=<name or id fragment> limits it to one device, TEAM
# overrides the team. A free Apple ID's profile lasts 7 days, so this is also the weekly refresh.
# Needs the devices unlocked, trusted and in Developer Mode. Installing over the old copy keeps its
# data. The session may run it on its own: it is in `allow` and `sandbox.excludedCommands`.
TEAM   ?= D68YR62N4B
DEVICE ?=
IOS_DEST ?= generic/platform=iOS
IOS_BUNDLE := $(shell sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER: \(io.github.EvgenyBaulin.ohmymoney\)$$/\1/p' project.yml | sed -n 1p)

run-ios: generate
	@if scripts/install-ios.sh --check "$(DEVICE)"; then \
	    $(MAKE) --no-print-directory run-ios-go DEVICE="$(DEVICE)" IOS_DEST="$(IOS_DEST)" TEAM="$(TEAM)"; \
	else echo "run-ios: no ready device, nothing built (reconnect and unlock it, then run again)"; fi

run-ios-go:
	@mkdir -p $(LOGS)
	set -o pipefail; $(IOS_XCB) -configuration Debug -destination '$(IOS_DEST)' \
	    -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_STYLE=Automatic \
	    CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_ALLOWED=YES build \
	    2>&1 | tee $(LOGS)/run-ios.log
	app="$$(find $(DERIVED)/Build/Products/Debug-iphoneos -maxdepth 1 -name '*.app' | sed -n 1p)"; \
	    test -n "$$app" || (echo "run-ios: no app was built" && exit 1); \
	    scripts/install-ios.sh "$$app" "$(IOS_BUNDLE)" "$(DEVICE)"

# Written to a log like every other build: the code under `#if APPSTORE` compiles in no
# other configuration, so without this its warnings were read by nobody (`check-warnings`).
build-appstore: generate
	@mkdir -p $(LOGS)
	set -o pipefail; $(XCB) -scheme $(SCHEME_STORE) -configuration AppStore build \
	    2>&1 | tee $(LOGS)/build-appstore.log

# «В сборке для App Store Sparkle нет вообще». Not a promise in a document
# — a look inside the bundle that was actually built: no framework of Sparkle's, no XPC
# service of its installer, no feed address to check.
STORE_APP := $(DERIVED)/Build/Products/AppStore/OhMyMoney.app
# The id the owner's copy and the store know the app by. It may never change.
RELEASE_ID := io.github.EvgenyBaulin.ohmymoney
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The product is removed first: this looks for what is **in** the bundle, and a framework
# left there by an earlier build of another target would answer for the one being checked.
check-appstore-clean:
	@rm -rf "$(STORE_APP)"
	@$(MAKE) --no-print-directory build-appstore
	@test -d "$(STORE_APP)" || (echo "appstore: $(STORE_APP) was not built" && exit 1)
	@if find "$(STORE_APP)" -iname '*sparkle*' -print -quit | grep -q .; then \
	    echo "appstore: something of Sparkle is inside the bundle"; \
	    find "$(STORE_APP)" -iname '*sparkle*'; exit 1; fi
	@if [ -d "$(STORE_APP)/Contents/XPCServices" ]; then \
	    echo "appstore: the bundle has XPC services"; \
	    ls "$(STORE_APP)/Contents/XPCServices"; exit 1; fi
	@keys=$$(plutil -p "$(STORE_APP)/Contents/Info.plist" | sed -nE 's/^  "(SU[A-Za-z]+)" => .*/\1/p'); \
	    if [ -n "$$keys" ]; then \
	    echo "appstore: the bundle carries Sparkle's settings:" $$keys; exit 1; fi
	@if otool -L "$(STORE_APP)/Contents/MacOS/OhMyMoney" | grep -qi sparkle; then \
	    echo "appstore: the binary links Sparkle"; exit 1; fi
	@id=$$(plutil -extract CFBundleIdentifier raw "$(STORE_APP)/Contents/Info.plist"); \
	    if [ "$$id" != "$(RELEASE_ID)" ]; then \
	    echo "appstore: the bundle is $$id, not $(RELEASE_ID)"; exit 1; fi
	@test -f "$(STORE_APP)/Contents/Resources/AppIcon.icns" || \
	    (echo "appstore: the bundle has no AppIcon.icns" && exit 1)
	@if grep -q AppIconDebug "$(STORE_APP)/Contents/Resources/Assets.car"; then \
	    echo "appstore: the Debug icon is inside the bundle"; exit 1; fi
	@echo "appstore: no updater inside"
# The bundle was built to be looked at, not opened: Launch Services learnt of it during the
# build and would offer it next to the owner's copy. Both the registration and the bundle go.
	@"$(LSREGISTER)" -u "$(STORE_APP)" 2>/dev/null || true
	@rm -rf "$(STORE_APP)"

# Builds a release of the Direct build, packages it and signs the package with the owner's
# Sparkle key. Stops before anything is built when the key is missing or still the
# placeholder. Never makes a key. `ARGS=--dry-run` checks everything and builds nothing.
release-local: generate
	OHMYMONEY_BUILD_ROOT="$(BUILD_ROOT)" $(AWAKE) bash scripts/make-release.sh $(ARGS)

# A published release looked at from outside, the way an installed copy meets it: the feed at
# the address every copy asks, the archive it points at with its size and EdDSA signature, and
# the app inside — id, version, build, key, feed, the owner's certificate, the Sparkle pinned,
# Sparkle's installer — meeting the designated requirement of the release before it. `V=1.1.1`
# for one version, the newest otherwise. `CANDIDATE=<OhMyMoney.app>` looks at a build made for
# release before it is published, against the newest release. It downloads, so it is not part
# of `make verify`.
release-check:
	@scripts/check-release.sh $(if $(CANDIDATE),--candidate "$(CANDIDATE)",$(V))

# The whole release in one command, the same by day and by night: checks, make verify, the
# commit, the build and its signature, the push, CI, the GitHub release and the feed, in that
# order, never asking and never forcing. A version that is out refuses: its tag exists.
# `ARGS=--dry-run` prints the checks and the plan and changes nothing.
release:
	@$(AWAKE) bash scripts/release.sh $(ARGS)

# A build from the repository is stopped by its path, never by its name: the owner's copy in
# /Applications is called OhMyMoney too, and may be open in the middle of an entry.
run: build
	@pkill -f "$(APP)/Contents/MacOS/OhMyMoney" || true
	open "$(APP)"

# The first line every build prints says which Swift builds the packages, and the check stops
# the run when that is not the compiler Xcode itself uses. A mismatch shows up
# hundreds of errors later, in code that has nothing to do with it, so it is cheaper to say so
# at once. `SWIFT_EXEC` is honoured by SwiftPM and is checked with the rest; a `TOOLCHAINS` that
# no longer has any effect is worth a word, not a failure.
check-toolchain:
	@line=$$($(SWIFT) --version 2>&1 | sed -n 1p | sed -E 's/^swift-driver version: [^ ]+ //'); \
	    echo "toolchain: $$line"; \
	    pkg=$$($(SWIFT) package --version 2>&1 | sed -nE 's/.*- Swift ([0-9]+\.[0-9]+).*/\1/p' | sed -n 1p); \
	    xcc=$$(xcodebuild $(XCB_TOOLCHAIN) -find-executable swiftc 2>/dev/null | sed -n 1p); \
	    xcv=$$("$$xcc" --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | sed -n 1p); \
	    if [ -n "$$SWIFT_EXEC" ]; then \
	        pkg=$$("$$SWIFT_EXEC" --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | sed -n 1p); \
	    fi; \
	    if [ -z "$$pkg" ] || [ -z "$$xcv" ] || [ "$$pkg" != "$$xcv" ]; then \
	        echo "toolchain: the packages would build with Swift $${pkg:-?}, Xcode builds with Swift $${xcv:-?}" >&2; \
	        echo "toolchain: swift on PATH: $$(command -v swift); TOOLCHAINS=$${TOOLCHAINS:-<unset>}; SWIFT_EXEC=$${SWIFT_EXEC:-<unset>}" >&2; \
	        exit 1; \
	    fi; \
	    if [ -n "$$TOOLCHAINS" ]; then echo "toolchain: TOOLCHAINS=$$TOOLCHAINS is set and has no effect here"; fi; \
	    onpath=$$(swift package --version 2>&1 | sed -nE 's/.*- Swift ([0-9]+\.[0-9]+).*/\1/p' | sed -n 1p); \
	    if [ -n "$$onpath" ] && [ "$$onpath" != "$$pkg" ]; then \
	        echo "toolchain: the swift on PATH would use SwiftPM $$onpath — it is not used here"; \
	    fi

# With the venv of `make pyenv` in place, the Reports tables of the golden set are read back
# with pandas as well; without it that one test is skipped and says why.
test-core: build-dir check-toolchain
	@mkdir -p $(LOGS)
	set -o pipefail; if [ -f "$(PYENV_MARKER)" ]; then export OHMYMONEY_PYTHON="$(PYENV_PYTHON)"; fi; \
	    $(AWAKE) $(TMO) 900 $(SWIFT) test --package-path Packages/AppCore \
	    --scratch-path $(SPM_SCRATCH)/spm-appcore --skip PerformanceTests \
	    2>&1 | tee $(LOGS)/test-core.log

# A venv with pandas for the CSV check (scripts/requirements-dev.txt), built from scratch:
# outside the repository, with no pip cache left behind. A failed install leaves no marker,
# so the check stays off rather than failing on a venv without pandas.
pyenv: build-dir
	rm -rf "$(PYENV)"
	python3 -m venv "$(PYENV)"
	"$(PYENV_PYTHON)" -m pip install --no-cache-dir --upgrade pip
	"$(PYENV_PYTHON)" -m pip install --no-cache-dir -r scripts/requirements-dev.txt
	"$(PYENV_PYTHON)" -c "import pandas; print('pandas', pandas.__version__)"
	touch "$(PYENV_MARKER)"

# `swift test` rewrites a Package.resolved that is not its own output — a pin of a package the
# manifest never names, an origin hash of another manifest. The run must leave the committed
# file as it found it, or the pin the tests ran against is not the one in git.
test-db: build-dir check-toolchain
	@mkdir -p $(LOGS)
	@cp Packages/AppDatabase/Package.resolved $(BUILD_DIR)/appdatabase-resolved.before
	set -o pipefail; $(AWAKE) $(TMO) 900 $(SWIFT) test --package-path Packages/AppDatabase \
	    --scratch-path $(SPM_SCRATCH)/spm-appdatabase --skip PerformanceTests \
	    2>&1 | tee $(LOGS)/test-db.log
	@cmp -s $(BUILD_DIR)/appdatabase-resolved.before Packages/AppDatabase/Package.resolved || \
	    (echo "test-db: the run rewrote Packages/AppDatabase/Package.resolved; commit SwiftPM's own file" && exit 1)

# Performance suites, in release and on about 20 000 synthetic operations: the ledger and
# every Analytics section for twelve months, then loading the same history from a WAL file
# and everything after it. `make test-core` and `make test-db` leave them out (`--skip`, a
# stopwatch in a debug build says nothing); `make verify` runs them here, in release, since
# only `OHMYMONEY_BENCH=1` switches them on. Each release build has a
# scratch directory of its own, so it never throws away the debug one.
bench: build-dir check-toolchain
	@mkdir -p $(LOGS)
	set -o pipefail; { OHMYMONEY_BENCH=1 $(AWAKE) $(TMO) 1800 $(SWIFT) test -c release \
	    --package-path Packages/AppCore --scratch-path $(SPM_SCRATCH)/spm-appcore-release \
	    --filter Performance && \
	  OHMYMONEY_BENCH=1 $(AWAKE) $(TMO) 1800 $(SWIFT) test -c release \
	    --package-path Packages/AppDatabase --scratch-path $(SPM_SCRATCH)/spm-appdatabase-release \
	    --filter Performance; } 2>&1 | tee $(LOGS)/bench.log

# The tests of the app run in TEST_WORKERS copies of the test host at once, each with a bundle id
# and so a container, settings and files of its own (scripts/test-parallel.py); the classes of
# scripts/serial-tests.txt, which need the one active app, run after them one by one.
# The build is made once, for testing; the time each class took is kept for the next run's
# spread. On this Mac a skipped test fails the run: every test runs here. `TEST_WORKERS=1` runs
# everything in one copy, as before.
# Every core but two: past that the windows of the tests are laid out more slowly than they wait.
TEST_WORKERS ?= $(shell n=$$(sysctl -n hw.ncpu); [ "$$n" -gt 3 ] && echo $$((n - 2)) || echo 1)
test: generate
	@mkdir -p $(LOGS)
	set -o pipefail; $(XCB_DEV) -scheme $(SCHEME) -configuration Debug \
	    -only-testing:OhMyMoneyTests build-for-testing 2>&1 | tee $(LOGS)/test-build.log
	$(AWAKE) $(TMO) $(XCB_TIME) scripts/test-parallel.py --products $(DERIVED)/Build/Products \
	    --logs $(LOGS) --workers $(TEST_WORKERS) --serial scripts/serial-tests.txt \
	    --times $(BUILD_ROOT)/test-times.tsv --sign "$(DEV_IDENTITY)" \
	    --prepend $(LOGS)/test-build.log -- $(TEST_TIME)

# One test, or one class, on a short leash: `make test-one T=OhMyMoneyTests/SomeTests[/testSomething]`.
# A test that never runs is a failure too — a class that the project does not know about yet
# would otherwise leave xcodebuild happy with nothing done. `DT=1` sends the os_log of the test
# host to stderr, which is how messages that only the log holds end up in the build output.
test-one: XCB_TIME = 600
test-one: generate
	@test -n "$(T)" || (echo "test-one: T=OhMyMoneyTests/Class[/test] is required" && exit 1)
	@mkdir -p $(LOGS)
	@set -o pipefail; $(if $(DT),TEST_RUNNER_OS_ACTIVITY_DT_MODE=YES ,)$(XCB_DEV) \
	    -scheme $(SCHEME) -configuration Debug -only-testing:$(T) \
	    -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
	    -maximum-test-execution-time-allowance 120 test 2>&1 | tee $(LOGS)/test-one.log
	@grep -q "Test Suite '.*' started" $(LOGS)/test-one.log || \
	    (echo "test-one: no test suite ran for $(T)" && exit 1)
	@! grep -q "Executed 0 tests" $(LOGS)/test-one.log || \
	    (echo "test-one: nothing matched $(T)" && exit 1)

# What the category model is worth on a CSV export of the application. `CSV=<folder>` is the
# folder `Export` writes; without it, the synthetic
# export the tests keep, so the target can be run on any tree.
#
# It prints metrics and nothing else — identifiers, never category names — because this output
# is meant to be pasted into a report. It writes nothing anywhere: the build output goes to
# /dev/null and the tool itself opens no database, no model file and no journal.
EVAL_CSV     := Packages/AppCore/Tests/CoreInsightsTests/Fixtures/export
EVAL_SCRATCH := $(BUILD_DIR)/spm-appcore-release

eval-model: build-dir check-toolchain
	@$(SWIFT) build -c release --package-path Packages/AppCore \
	    --scratch-path $(EVAL_SCRATCH) --product ohmymoney-eval-model > /dev/null
	@"$$($(SWIFT) build -c release --package-path Packages/AppCore \
	    --scratch-path $(EVAL_SCRATCH) --show-bin-path)/ohmymoney-eval-model" "$(or $(CSV),$(EVAL_CSV))"

# The update of the schema, tried on a copy of a database file before it reaches the owner's:
# `make migration-dry-run DB=<finance.sqlite>` (`SCHEMA=Schema` unless given). The tool copies
# the file with its -wal and -shm into a temporary folder of its own, migrates the copy with the
# schema of this tree and prints table names, row counts before and after, the counts of the
# data step, «equal» or «differ» for the sums of money and the totals of every month, and what
# the update has to give — no operation without an account, one live main account, the new
# tables empty — never an amount, a name or a note. It deletes the copy, on Ctrl-C too, and a
# copy a killed run left is deleted by the next. It never opens the original. Quit the app that
# uses the file first: a copy taken while it writes may not be whole. Exits non-zero on
# anything that differs.
MIGRATION_SCRATCH := $(BUILD_DIR)/spm-appdatabase-release

migration-dry-run: build-dir check-toolchain
	@test -n "$(DB)" || (echo "migration-dry-run: DB=<path of a finance.sqlite> is required" && exit 1)
	@$(SWIFT) build -c release --package-path Packages/AppDatabase \
	    --scratch-path $(MIGRATION_SCRATCH) --product ohmymoney-migration-dry-run > /dev/null
	@"$$($(SWIFT) build -c release --package-path Packages/AppDatabase \
	    --scratch-path $(MIGRATION_SCRATCH) --show-bin-path)/ohmymoney-migration-dry-run" \
	    "$(DB)" "$(or $(SCHEMA),Schema)"

# UI tests stay on the author's Mac and out of CI. Without the «OhMyMoney Local Signing» certificate
# (scripts/make-signing-identity.sh), Accessibility for the test runner and automation mode
# turned on once, macOS stops them at «Timed out while enabling automation mode».
# `T=OhMyMoneyUITests/Class[/test]` runs one class or one test, with the limits of a UI test
# (UI_TEST_TIME), not the short ones of test-one: a UI test waits minutes for its window.
test-ui: generate
	@echo "signing Debug and the UI-test runner with: $(DEV_IDENTITY)"
	$(XCB_DEV) -scheme $(SCHEME) -configuration Debug -only-testing:$(or $(T),OhMyMoneyUITests) \
	    $(UI_TEST_TIME) test

fmt:
	$(FORMAT) format --in-place --recursive --parallel Packages Apps

# Style is advisory, one rule is not: an implicitly unwrapped
# optional is a crash the compiler was told to let through, and `.swift-format` promises there
# are none. swift-format itself ends 0 on a warning, so the rule is read from what it prints.
lint:
	@out="$$($(FORMAT) lint --recursive --parallel Packages Apps 2>&1)"; status=$$?; \
	    [ -z "$$out" ] || echo "$$out"; \
	    if echo "$$out" | grep -q '\[NeverUseImplicitlyUnwrappedOptionals\]'; then \
	        echo "lint: an implicitly unwrapped optional — use a plain value or an optional"; \
	        exit 1; \
	    fi; \
	    [ "$$status" = "0" ] || echo "lint: advisory only"

# Money never becomes a floating-point number on its way to a chart or a report:
# the views take whole rubles as `Int64` or `Decimal`, both of them
# `Plottable`. So `Double` is banned in these folders outright — no `chart-only` escape, not
# even in a comment, because a trailing comment ends up on another line than the code once
# swift-format wraps it. The words `Float`, `TimeInterval` and `doubleValue` and the
# `opacity(_:)` modifier, which takes a `Double` literal without the word, are banned with
# it: a lighter shade is a system level (`.secondary`, `.tertiary`), not an opacity of ours.
MONEY_VIEW_DIRS := $(wildcard Apps/macOS/Features/Overview Apps/macOS/Features/Analytics \
	Apps/macOS/Features/Reports Apps/macOS/Shared/Charts Apps/macOS/Features/WhatIf)

check-chart-double:
	@! grep -rnwE "Double|Float|TimeInterval|doubleValue" $(MONEY_VIEW_DIRS) || \
	    (echo "Double in chart or report views" && exit 1)
	@! grep -rnE "\.opacity\(" $(MONEY_VIEW_DIRS) || \
	    (echo "opacity(_:) takes a Double: use .secondary / .tertiary" && exit 1)
	@echo "charts: no Double"

# AppCore must stay pure Swift + Foundation so it also builds on Linux and Windows. The
# strict check of the chart views runs with it.
check-core-purity: check-chart-double
	@! grep -rnE "^import (AppKit|SwiftUI|SwiftUICore|GRDB|Charts|CryptoKit|CreateML|Sparkle|TabularData|CoreData)" \
	    Packages/AppCore/Sources || (echo "AppCore purity violated" && exit 1)
	@! grep -rn "\bDouble\b" Packages/AppCore/Sources | grep -vE "chart-only|stats-only" | grep -vE ":[0-9]+: *(///|//|\*)" || \
	    (echo "Double outside chart or statistics code in AppCore" && exit 1)
# `stats-only` is the second escape, and it is narrower than it looks. Money is never a
# floating-point number; what the model and the forecast need it for is the
# arithmetic in between — log-probabilities, a median, a quantile loss. So a `Double` may
# stand inside the statistics, marked, and may not leave them: nothing public in those targets
# may carry one, and that is the line this checks.
	@! grep -rnE "^ *public .*\bDouble\b" Packages/AppCore/Sources || \
	    (echo "a Double in a public declaration of AppCore: statistics keep theirs inside" && exit 1)
# The packages are tested with Swift Testing: it comes with the toolchain, runs
# on Linux and runs a suite's tests in parallel. XCTest is the app's, where XCUITest leaves no
# other choice. Nine files of AppCore imported it until 24.09; this keeps a tenth from coming
# back, and names the file.
	@! grep -rlE "^import XCTest" Packages/AppCore/Tests Packages/AppDatabase/Tests || \
	    (echo "XCTest in a package's tests: they are written with Swift Testing" && exit 1)
	@echo "core purity: ok"

# No view may stop the app on a value missing from its environment: no
# non-optional `@Environment(SomeType.self)`, no `@EnvironmentObject`, no trapping default.
# The script first proves on two small samples that it catches what it should.
check-environment:
	@scripts/check-environment.sh --self-test > /dev/null || scripts/check-environment.sh --self-test
	@scripts/check-environment.sh Apps

# A height taken off the screen never comes back into the layout:
# that is what made the window of Transactions loop until AppKit gave up. The room under a
# floating element belongs to `safeAreaInset`. The check proves itself on two small samples
# first.
check-geometry:
	@scripts/check-geometry.sh --self-test > /dev/null || scripts/check-geometry.sh --self-test
	@scripts/check-geometry.sh Apps

# Our own code builds without a single warning. Only diagnostics whose path starts with this
# repository count: a warning of a package we depend on is not ours to fix, and the tools say
# things of their own («Metadata extraction skipped») that are not warnings about code.
#
# It reads the four logs the build and the tests of this run leave behind, by name: anything
# else in that folder belongs to another run.
#
# A build repeats a warning only for the files it recompiles, so this reads the logs of the
# build that just ran — and the whole picture needs a build from scratch, which `make verify`
# gets after `rm -rf Build.nosync/DerivedData`.
# The logs have to be there. Read from a folder `make clean` emptied, both this check and the
# one below print «none» having looked at nothing at all — which is the eye-check that let the
# 1433 stale files through in the first place.
check-warnings:
	@missing=""; for log in $(LOGS)/build.log $(LOGS)/test.log $(LOGS)/test-core.log \
	                        $(LOGS)/test-db.log $(LOGS)/build-appstore.log; do \
	    [ -f "$$log" ] || missing="$$missing $$log"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "warnings: nothing to read —$$missing; build and test first"; exit 1; \
	fi
	@found=$$(cat $(LOGS)/build.log $(LOGS)/test.log $(LOGS)/test-core.log $(LOGS)/test-db.log \
	    $(LOGS)/build-appstore.log 2>/dev/null | \
	    grep -oE "^$(CURDIR)/(Apps|Packages)/[^:]+:[0-9]+:[0-9]+: warning: .*" | sort -u); \
	    if [ -n "$$found" ]; then echo "$$found"; echo "warnings: our own code has some"; exit 1; fi
	@echo "warnings: none"

# A build from scratch used to leave every intermediate behind: reached through the
# `Build.nosync` link, xcodebuild judged them «outside of the allowed root paths» and refused to
# delete them, one warning each. These carry no line number, and `check-warnings` reads only
# diagnostics that point at a line of our code — hence a check of their own, over the same logs.
# No test is skipped on this Mac: a skipped test is a check that did not happen. The tests of
# the app say so themselves (scripts/test-parallel.py); this reads the logs of the packages and
# of `make bench`. CI skips by design (no screen, no pandas on Linux) and does not run it.
check-skips:
	@found=$$(cat $(LOGS)/test-core.log $(LOGS)/test-db.log $(LOGS)/bench.log 2>/dev/null | \
	    grep -aE "^➜ (Test|Suite) .* skipped" | sort -u); \
	    if [ -n "$$found" ]; then echo "$$found"; echo "skips: some tests did not run"; exit 1; fi
	@test -f $(LOGS)/test.log || (echo "skips: nothing to read — run make test first" && exit 1)
	@found=$$(grep -aE "^Test Case '.*' skipped" $(LOGS)/test.log | sort -u); \
	    if [ -n "$$found" ]; then echo "$$found"; echo "skips: some tests did not run"; exit 1; fi
	@echo "skips: none"

check-stale:
	@missing=""; for log in $(LOGS)/build.log $(LOGS)/test.log; do \
	    [ -f "$$log" ] || missing="$$missing $$log"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "stale files: nothing to read —$$missing; build and test first"; exit 1; \
	fi
	@found=$$(cat $(LOGS)/build.log $(LOGS)/test.log 2>/dev/null | \
	    grep -c "Stale file '.*' is located outside of the allowed root paths"); \
	    if [ "$$found" != "0" ]; then \
	        echo "stale files: $$found left behind — the build root is being reached through a link"; \
	        exit 1; \
	    fi
	@echo "stale files: none"

# The shell scripts stay readable by the bash macOS ships (3.2) and parse before anybody runs
# one. The check proves itself on two small samples first. The steps of a
# release that can run without a key and a build prove themselves here too: they run once a
# version, by hand, and a fault in them is found by the Macs that never get the update; the
# look at a published release (`make release-check`) proves itself offline, on made-up feeds,
# keys and apps. So do the installer of CI's XcodeGen, in the part that needs no network, the
# hook that cleans a commit message, and the merge of the String Catalogs, which keeps what
# Xcode wrote there.
check-scripts:
	@scripts/check-scripts.sh --self-test > /dev/null || scripts/check-scripts.sh --self-test
	@scripts/check-scripts.sh
	@scripts/release-entry.sh --self-test
	@scripts/release-version.sh --self-test
	@scripts/check-release.sh --self-test
	@scripts/install-xcodegen.sh --self-test
	@scripts/git-hooks/commit-msg --self-test
	@python3 scripts/make_xcstrings.py --self-test
	@python3 scripts/make_themes.py --self-test

# No personal data may ever be staged.
check-privacy:
	@! git diff --cached --name-only | grep -E '\.(sqlite|sqlite-wal|sqlite-shm|numbers|pem|key|ohmymoneyarchive)$$' || \
	    (echo "personal data staged" && exit 1)
	@! git diff --cached --name-only | grep -E '\.csv$$' | grep -v '/Fixtures/' || \
	    (echo "CSV outside Fixtures staged" && exit 1)
# A log or a crash report holds what somebody did and what was on the screen, so `.gitignore`
# covers both. Staging is checked above; this asks the other question — would git even offer
# them? The names are the ones this project actually produces: `log_1.txt` from a user,
# `*.ips` from macOS.
	@missing=""; for name in log_1.txt ohmymoney-crash.ips ohmymoney.crash ohmymoney.log \
	                         OhMyMoney-report-0000-00-00.zip sparkle-public-key.txt; do \
	    git check-ignore -q "$$name" || missing="$$missing $$name"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "not ignored:$$missing — a log, a crash report or a key could be committed"; \
	    exit 1; \
	fi
# The folders of personal data are ignored at the root of the repository and nowhere else. A
# rule without the leading slash matches the name at any depth, and on a Mac, where git ignores
# case, `models/` matches `Models/` too: the first `Features/…/Models/` folder of source code
# would have been left out of every commit without a word.
	@missing=""; for name in backups/x exports/x models/x Logs/x; do \
	    git check-ignore -q "$$name" || missing="$$missing $$name"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "not ignored:$$missing — a folder of personal data could be committed"; exit 1; \
	fi
	@hidden=""; for name in Apps/macOS/Features/Planning/Models/Goal.swift \
	                        Apps/macOS/Platform/Logs/Logbook.swift \
	                        Apps/macOS/Platform/Backup/Backups/Copy.swift \
	                        Apps/macOS/Platform/Export/Exports/Export.swift \
	                        Packages/AppCore/Sources/CoreModel/models/Model.swift; do \
	    ! git check-ignore -q "$$name" || hidden="$$hidden $$name"; \
	done; \
	if [ -n "$$hidden" ]; then \
	    echo "ignored:$$hidden — source code in such a folder could never be committed"; exit 1; \
	fi
# The other half of the same rule: a CSV inside a Fixtures folder is the one CSV allowed in,
# so the exception that lets it in has to name a folder that exists.
	@hidden=""; for name in Packages/AppCore/Tests/CoreRatesTests/Fixtures/rates.csv \
	                        Packages/AppCore/Tests/CoreAnalyticsTests/Fixtures/spending.csv; do \
	    ! git check-ignore -q "$$name" || hidden="$$hidden $$name"; \
	done; \
	if [ -n "$$hidden" ]; then \
	    echo "ignored:$$hidden — a CSV fixture could never be committed"; \
	    exit 1; \
	fi
# The documents at the root of the tree are the two the repository publishes; any other
# markdown there is somebody's notes and does not belong in a public tree. Named by what is
# allowed, so a new file of notes needs no line here to be caught.
	@extra="$$(git ls-files -- ':(glob)*.md' | grep -vxE 'README\.md|CHANGELOG\.md' | tr '\n' ' ')"; \
	if [ -n "$$extra" ]; then \
	    echo "tracked at the root: $${extra}— only README.md and CHANGELOG.md are published there"; \
	    exit 1; \
	fi
# And the other side of it: what the repository publishes must never be hidden by a rule.
# `--no-index`: for a file it already tracks, check-ignore answers «not ignored» whatever the
# rules say, and the question is what the rules would do to the file.
	@hidden=""; for name in README.md CHANGELOG.md LICENSE scripts/appcast-envelope.xml; do \
	    ! git check-ignore -q --no-index "$$name" || hidden="$$hidden $$name"; \
	done; \
	if [ -n "$$hidden" ]; then \
	    echo "ignored:$$hidden — a published file could never be committed"; \
	    exit 1; \
	fi
	@echo "privacy: ok"

# «В приложении нет WebView и локального сервера» is the first line of the acceptance table,
# and until now it was a promise rather than a check. Only the
# application's own sources: the packages it fetches are not ours to police. The files on
# disk, not what git tracks: `git grep` let a new file pass until it was added.
check-native:
	@if grep -rnE --include='*.swift' \
	    'import WebKit|WKWebView|WKUserContentController|NWListener|HTTPServer' \
	    Apps Packages/AppCore/Sources Packages/AppDatabase/Sources; then \
	    echo "native: a web view or a local server is in the sources"; \
	    exit 1; \
	fi
	@echo "native: no web view, no server"

# Half of the «Дизайн» criterion: glass belongs to the layer of navigation and control, and
# nowhere else — never on content, never on glass. One file owns the
# material; `GlassEffectContainer` and `glassEffectID` are the container and the identity of
# the morph, not a second layer, so they are allowed anywhere the bar and the panel live.
# Read from the files on disk, like check-native.
GLASS_HOME := Apps/macOS/Shared/DesignSystem/GlassSurfaces.swift

check-glass:
	@found=$$(grep -rlF --include='*.swift' 'glassEffect(' Apps | grep -v '^$(GLASS_HOME)$$' || true); \
	if [ -n "$$found" ]; then \
	    echo "glass: the material is applied outside $(GLASS_HOME):"; \
	    echo "$$found"; \
	    exit 1; \
	fi
	@echo "glass: only in the surfaces of the navigation layer"

# Every font grows with the size of the text the owner chose: a view sets its font with
# `.appFont(_:)` (Shared/DesignSystem/AppFont.swift), never `.font(_:)`; a size held on purpose
# says so in a `// font-fixed:` comment. The check proves itself on two small samples first.
# The old name stays only in identifiers that cannot change yet (scripts/check-names.sh).
check-names:
	@scripts/check-names.sh

check-fonts:
	@scripts/check-fonts.sh --self-test > /dev/null || scripts/check-fonts.sh --self-test
	@scripts/check-fonts.sh

# The history of this repository carries one name — the author's. No commit message may carry
# a co-authorship trailer, a reference to a tool's session or a «Generated with» line (the hook
# of `make hooks` strips them before a commit is made), and every commit but a merge has one
# and the same author. The committer is not counted: GitHub's web interface commits as
# noreply@github.com.
check-attribution:
	@bad="$$(git log --format='%H %s' -i -E \
	        --grep='^[[:space:]]*Co-Authored-By:' \
	        --grep='^[[:space:]]*[A-Za-z][A-Za-z0-9-]*-Session:' \
	        --grep='^[^A-Za-z0-9]*Generated with' HEAD)"; \
	if [ -n "$$bad" ]; then \
	    echo "attribution: a commit message carries a co-authorship trailer or a session reference"; \
	    echo "$$bad"; \
	    echo "run 'make hooks' once, then amend the message"; \
	    exit 1; \
	fi
	@[ "$$(git log --no-merges --format='%ae' HEAD | sort -u | wc -l | tr -d ' ')" = 1 ] || { echo 'attribution: more than one author'; exit 1; }
	@echo "attribution: ok"

# Points git at the hooks of this repository. A local setting of this clone, not something
# a clone gets by itself — git never runs a hook it was not told about.
hooks:
	@git config core.hooksPath scripts/git-hooks
	@echo "hooks: $$(git config core.hooksPath)"

# CI runs what `make verify` runs, less `fmt` (it rewrites instead of judging): CI is what
# vouches for a change on any Mac but the author's. `lint` comes
# along with the checks: advisory in style, it fails on an implicitly unwrapped optional.
# The workflow is compared with the prerequisites of `verify` below, so a check added here and
# not there fails this check instead of passing every pull request unseen.
# A journal event whose name is not a token is written as «<not-a-name>». The
# check proves on two small samples that it catches a long name and an error type written as a
# token before it reads the sources.
check-log-names:
	@scripts/check-log-names.sh --self-test > /dev/null || scripts/check-log-names.sh --self-test
	@scripts/check-log-names.sh

check-ci:
	@scripts/check-ci.sh --self-test > /dev/null || scripts/check-ci.sh --self-test
	@scripts/check-ci.sh

# A key looked up in a table that does not have it comes back as itself and is shown raw — the
# currency caption of the payment methods said «entry.currency» that way. Every literal key a
# lookup of a fixed table is given must be in that table's String Catalog. The check proves on
# two small samples that it catches a wrong table before it reads the sources.
check-strings:
	@scripts/check-strings.sh --self-test > /dev/null || scripts/check-strings.sh --self-test
	@scripts/check-strings.sh

# The checks of `make verify` that read what the builds and tests left behind and change
# nothing. CI runs them after its own builds and tests (.github/workflows/build.yml).
ci-checks: lint check-warnings check-stale check-core-purity check-environment check-geometry \
	    check-scripts check-privacy check-attribution check-native check-glass check-fonts check-names check-ci \
	    check-log-names check-strings

# `check-appstore-clean` comes before `check-warnings` on purpose: it is what builds the store
# configuration, and `check-warnings` reads that build's log with the others.
verify: check-toolchain fmt lint test-core test-db bench build test check-appstore-clean \
	    ci-checks check-skips
	@if [ -f "$(PYENV_MARKER)" ]; then echo "pandas: checked"; \
	    else echo "pandas: NOT checked (run make pyenv)"; fi
	@echo "verify: green"

# Opens the app on synthetic data generated from a fixed seed, in a data set of its own:
# six months, or about 20 000 operations over two years. The set's folder is made anew each
# time; the Debug and Release databases are other folders and are never touched.
# The title of the main window says «DEBUG · SAMPLE». ARGS go to the app last:
# `make sample ARGS=--slow-pipeline` slows every step of the pipeline from the launch on, so
# the placeholders of the start can be seen (Debug → Pipeline slows ⌘R the same way).
ARGS ?=

sample: build
	@pkill -f "$(APP)/Contents/MacOS/OhMyMoney" || true
	open "$(APP)" --args --data-set sample --generate 6 $(ARGS)

sample-large: build
	@pkill -f "$(APP)/Contents/MacOS/OhMyMoney" || true
	open "$(APP)" --args --data-set sample-large --generate large $(ARGS)

# A demo database from a random seed every run; `make demo SEED=<n>` makes the same one again
# on the same day and in the same interface language: the history ends today, and its names are
# in the language of the interface. Only a SEED given on the command line counts, so one left
# exported in the shell does not pin every run; it is a whole number of at most 18 digits, and
# anything else stops here instead of opening the demo of another seed. Twelve months: accounts
# in several currencies and a group outside the summary, transfers with fees in rubles and in
# dollars, currency exchanges, counts, an old card merged into the main one and kept in the
# archive, refunds tied to purchases, money partly given back, a payment due once, a goal in
# dollars, event budgets — in the `demo` set, «DEBUG · DEMO» in the title. The seed is printed
# with the command that makes the same demo again, and the journal of the set says it too.
DEMO_SEED := $(if $(filter command line,$(origin SEED)),$(SEED))

demo: build
	@pkill -f "$(APP)/Contents/MacOS/OhMyMoney" || true
	@seed="$(DEMO_SEED)"; \
	if [ -z "$$seed" ]; then seed="$$(od -An -N6 -tu8 /dev/urandom | tr -d ' ')"; fi; \
	case "$$seed" in *[!0-9]*) seed=invalid;; esac; \
	if [ "$$seed" = invalid ] || [ $${#seed} -gt 18 ]; then \
	  echo "demo: SEED must be a whole number of at most 18 digits, not '$(DEMO_SEED)'"; \
	  exit 1; \
	fi; \
	echo "demo seed: $$seed   (make demo SEED=$$seed reproduces it today, in the same language)"; \
	open "$(APP)" --args --data-set demo --generate 12 --seed "$$seed" $(ARGS)

# The Analytics window of the Release build on about 20 000 operations.
# The Debug build generates the `bench` set and quits; the Release build — ad-hoc signed like
# `make install`, but left where it was built — opens it with the window on Overview and
# twelve months, changes the period by itself eight times, writes the times into the set's
# folder and quits. Each time runs from a change of the period to the first appearance of
# every chart of the section, past the cache of models; the first change is a warm-up.
# A flag without a value (`--measure`, `--generate-only`) goes last: AppKit reads the
# arguments as `-key value` pairs, and a word left without its key would be opened as a
# document — the app would start with no window at all. The app refuses that by itself now
# (`NSTreatUnknownArgumentsAsOpen`, LaunchOptions); the order is kept all the same.
# Neither launch restores saved windows: a second main window would only wait for the first.
# The report opens with the number of operations drawn, and a set with none fails the run —
# an empty history draws fast and would pass for a measurement. The section and the period
# are kept by the set (AnalyticsWindow.storageKey): the owner's Analytics window is untouched.
bench-app: build
	@pkill -f "$(APP)/Contents/MacOS/OhMyMoney" || true
	$(AWAKE) $(TMO) 900 open -W -n "$(APP)" --args --data-set bench --generate large \
	    -ApplePersistenceIgnoreState YES --generate-only
	$(XCB) -scheme $(SCHEME) -configuration Release \
	    PRODUCT_BUNDLE_IDENTIFIER=$(DEBUG_ID) OHMYMONEY_ARCHIVE_HANDLER_RANK=Alternate build
	@rm -f "$(BENCH_TIMES)"
	$(AWAKE) $(TMO) 600 open -W -n "$(RELEASE_APP)" --args --data-set bench --measure-runs 8 \
	    --open analytics --analytics-section overview --analytics-period 12m \
	    -ApplePersistenceIgnoreState YES --measure; \
	    status=$$?; pkill -f "$(RELEASE_APP)/Contents/MacOS/OhMyMoney"; exit $$status
	@test -f "$(BENCH_TIMES)" || (echo "bench-app: no times were written" && exit 1)
	@cat "$(BENCH_TIMES)"
	@grep -Eq ' [1-9][0-9]* operations$$' "$(BENCH_TIMES)" || \
	    (echo "bench-app: the set had no operations, the times say nothing" && exit 1)

# The owner's copy in /Applications is a published release, never a build of the working tree:
# only a release carries the real key of Sparkle, and only such a copy is ever updated. This
# downloads the latest release from GitHub, checks that it is the app it says it is — the id,
# the key in sparkle-public-key.txt, an intact signature — and only then puts it in place. It
# refuses while the owner's copy is running.
INSTALL_TMP := $(BUILD_ROOT)/install

install: build-dir
	@test -f sparkle-public-key.txt || (echo "install: no sparkle-public-key.txt to check the release against" && exit 1)
	@! pgrep -f "/Applications/OhMyMoney.app/Contents/MacOS/OhMyMoney" > /dev/null || \
	    (echo "install: /Applications/OhMyMoney.app is running; quit it first" && exit 1)
	@rm -rf "$(INSTALL_TMP)"; mkdir -p "$(INSTALL_TMP)"
	gh release download --repo EvgenyBaulin/ohmymoney --pattern 'OhMyMoney-*.zip' --dir "$(INSTALL_TMP)"
	@set -e; zip="$$(find "$(INSTALL_TMP)" -maxdepth 1 -name 'OhMyMoney-*.zip' | sed -n 1p)"; \
	    test -n "$$zip" || { echo "install: the latest release has no OhMyMoney-*.zip"; exit 1; }; \
	    ditto -x -k "$$zip" "$(INSTALL_TMP)/unpacked"; \
	    app="$$(find "$(INSTALL_TMP)/unpacked" -maxdepth 1 -name '*.app' | sed -n 1p)"; \
	    test -n "$$app" || { echo "install: the archive holds no app"; exit 1; }; \
	    id="$$(plutil -extract CFBundleIdentifier raw "$$app/Contents/Info.plist")"; \
	    [ "$$id" = "$(RELEASE_ID)" ] || { echo "install: the release is $$id, not $(RELEASE_ID)"; exit 1; }; \
	    key="$$(plutil -extract SUPublicEDKey raw "$$app/Contents/Info.plist")"; \
	    [ "$$key" = "$$(tr -d '[:space:]' < sparkle-public-key.txt)" ] || \
	        { echo "install: the release carries another Sparkle key than sparkle-public-key.txt"; exit 1; }; \
	    codesign --verify --deep --strict "$$app" || { echo "install: the signature does not hold"; exit 1; }; \
	    rm -rf "/Applications/$$(basename "$$app")"; \
	    ditto -x -k "$$zip" /Applications; \
	    "$(LSREGISTER)" -u "$$app" 2>/dev/null || true; \
	    rm -rf "$(INSTALL_TMP)"; \
	    echo "install: $$(basename "$$zip" .zip) is in /Applications, not opened"

archive-appstore: generate
	$(XCB) -scheme $(SCHEME_STORE) -configuration AppStore \
	    -archivePath $(BUILD_DIR)/OhMyMoney-AppStore.xcarchive archive

clean:
	rm -rf "$(BUILD_ROOT)" $(BUILD_DIR) $(PROJECT)
