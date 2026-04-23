# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Claude Code

Working with Mac OS X Claude Code credentials within a devcontainer is a little finicky. 

The devcontainer is set up to copy credentials from keychain to `~/.claude.credentials.json` on (re)build, however in case these refreshed between rebuild and now, we also want to have a regular task to do so running on the host. 

Copy `.devcontainer/com.meandu.claude-creds-sync.plist` to `~/Library/LaunchAgents/com.meandu.claude-creds-sync.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.meandu.claude-creds-sync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>umask 077; /usr/bin/security find-generic-password -s "Claude Code-credentials" -w > "$HOME/.claude/.credentials.json" &amp;&amp; /bin/chmod 600 "$HOME/.claude/.credentials.json"</string>
  </array>
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/claude-creds-sync.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/claude-creds-sync.err</string>
</dict>
</plist>
```

### Installation
(once, on the Mac)

```bash
mkdir -p ~/Library/LaunchAgents
cp .devcontainer/com.meandu.claude-creds-sync.plist ~/Library/LaunchAgents/com.meandu.claude-creds-sync.plist
```
paste the plist into the path above

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.meandu.claude-creds-sync.plist
launchctl enable gui/$(id -u)/com.meandu.claude-creds-sync
launchctl kickstart gui/$(id -u)/com.meandu.claude-creds-sync   # run once immediately
tail /tmp/claude-creds-sync.err    # should be empty on success
```

### Uninstallation
To unload later:

```bash
launchctl bootout gui/$(id -u)/com.meandu.claude-creds-sync
```