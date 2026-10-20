LABEL       := io.github.weylinmorris.mx4d
APP_NAME    := MX4Driver.app
APP         := build/$(APP_NAME)
BIN         := $(APP)/Contents/MacOS/mx4d
INSTALL_DIR := $(HOME)/Applications
AGENT       := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG         := $(HOME)/Library/Logs/mx4d.log
SOURCES     := $(wildcard Sources/*.swift)

# Sign with a stable identity when one exists so the Accessibility grant survives rebuilds;
# fall back to ad-hoc signing (you'll need to re-grant Accessibility after each rebuild).
SIGN_ID ?= $(shell security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $$2; exit}')

.PHONY: build install uninstall restart logs probe clean

build: $(BIN)

$(BIN): $(SOURCES) Resources/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	swiftc -swift-version 5 -O -o $(BIN) $(SOURCES) -framework IOKit -framework ApplicationServices
	codesign --force --sign "$(if $(SIGN_ID),$(SIGN_ID),-)" $(APP)

install: build
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	@while launchctl print gui/$$(id -u)/$(LABEL) >/dev/null 2>&1; do sleep 0.2; done
	mkdir -p "$(INSTALL_DIR)" "$(HOME)/Library/LaunchAgents"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R $(APP) "$(INSTALL_DIR)/"
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BIN@|$(INSTALL_DIR)/$(APP_NAME)/Contents/MacOS/mx4d|' -e 's|@LOG@|$(LOG)|' \
		Resources/launchagent.plist > "$(AGENT)"
	launchctl bootstrap gui/$$(id -u) "$(AGENT)"
	@echo "Installed. Grant Accessibility to MX4 Driver if prompted. Log: $(LOG)"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	rm -f "$(AGENT)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"

restart:
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)

logs:
	tail -f "$(LOG)"

probe: build
	$(BIN) --probe

clean:
	rm -rf build
