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

The canonical plist lives at [`.devcontainer/com.meandu.claude-creds-sync.plist`](.devcontainer/com.meandu.claude-creds-sync.plist) — check that file for the current launchd schedule and sync command.

### Installation
(once, on the Mac)

```bash
mkdir -p ~/Library/LaunchAgents
cp .devcontainer/com.meandu.claude-creds-sync.plist ~/Library/LaunchAgents/com.meandu.claude-creds-sync.plist
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