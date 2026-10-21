# Build, sign and install Calendar Alarm.
#
# Calendar permission is tied to the code signature, so sign with a stable
# identity. By default this picks the first "Apple Development" identity in your
# keychain; override with `make SIGN_IDENTITY="Developer ID Application: ..."`.
# Ad-hoc signing (`SIGN_IDENTITY=-`) works but loses Calendar access on every rebuild.

SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk '/Apple Development/ && !/REVOKED|EXPIRED/ { print $$2; exit }')
CONFIG ?= release
# Universal by default; `make ARCHS=arm64` builds faster for local work.
ARCHS ?= arm64 x86_64
SWIFT_BUILD := swift build -c $(CONFIG) $(foreach a,$(ARCHS),--arch $(a))
APP := build/Calendar Alarm.app
INSTALL_DIR ?= /Applications
INSTALLED := $(INSTALL_DIR)/Calendar Alarm.app

.PHONY: all app test install uninstall clean sound

all: app

test:
	swift test

app:
	@test -n "$(SIGN_IDENTITY)" || { echo "No signing identity found; pass SIGN_IDENTITY=- for ad-hoc"; exit 1; }
	$(SWIFT_BUILD) --product CalendarAlarm
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Library/LaunchAgents"
	cp "$$($(SWIFT_BUILD) --show-bin-path)/CalendarAlarm" "$(APP)/Contents/MacOS/"
	cp Resources/Info.plist "$(APP)/Contents/"
	cp Resources/alarm.wav "$(APP)/Contents/Resources/"
	cp Resources/com.corseapps.calendaralarm.sync.plist "$(APP)/Contents/Library/LaunchAgents/"
	codesign --force --options runtime --timestamp=none \
		--entitlements Resources/CalendarAlarm.entitlements \
		--sign "$(SIGN_IDENTITY)" "$(APP)"
	codesign --verify --strict "$(APP)"
	@echo "Built $(APP)"

# Replaces the installed copy in place. The background agent, if enabled, picks
# up the new binary on its next run.
install: app
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	@echo "Installed $(INSTALLED). Open it once to grant Calendar access and enable background alarms."

uninstall:
	scripts/uninstall.sh "$(INSTALLED)"

sound:
	python3 scripts/make-sound.py Resources/alarm.wav

clean:
	rm -rf build .build
