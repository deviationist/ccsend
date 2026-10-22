# ccsend: build the Mac client and embed the server script into it.
#
#   make            build client/build/ccsend.app
#   make test       server tests (local) + client self-checks
#   make install    install the app, link the CLI, create the Quick Actions

APP      := client/build/ccsend.app
BIN      := $(APP)/Contents/MacOS/ccsend
GEN      := client/Sources/ccsend/RemoteScript.swift
DEST     := $(HOME)/Applications/ccsend.app
# macOS ties privacy permissions (Desktop/Downloads access) to this id. Override: make BUNDLE_ID=com.example.ccsend
BUNDLE_ID ?= local.ccsend

.PHONY: all test install clean

all: $(APP)

$(GEN): server/remote.py
	@printf '// Generated from server/remote.py by make. Do not edit.\nenum RemoteScript {\n    static let base64 = "%s"\n}\n' \
		"$$(base64 < server/remote.py | tr -d '\n')" > $@

$(APP): $(GEN) $(shell find client/Sources -name '*.swift') client/Package.swift client/Info.plist
	cd client && swift build -c release --product ccsend
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	sed 's/__BUNDLE_ID__/$(BUNDLE_ID)/' client/Info.plist > $(APP)/Contents/Info.plist
	cp client/.build/release/ccsend $(BIN)
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP)

test: $(APP)
	/usr/bin/python3 server/test_remote.py
	$(BIN) selftest

# rm before cp: overwriting a signed binary in place gets it SIGKILLed.
install: $(APP)
	rm -rf $(DEST)
	cp -R $(APP) $(DEST)
	mkdir -p $(HOME)/.local/bin
	ln -sf $(DEST)/Contents/MacOS/ccsend $(HOME)/.local/bin/ccsend
	$(HOME)/.local/bin/ccsend install

clean:
	rm -rf client/.build client/build $(GEN)
