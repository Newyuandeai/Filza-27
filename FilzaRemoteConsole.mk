# Remote file viewer console for Filza-27.
#
# Adds a browser-based remote file manager on top of the GCDWebServer copy this
# repo already vendors for WebDAV — no second networking stack, no new
# dependency. The console bundle is staged from Resources/FilzaRemoteWeb/src by
# scripts/stage-remote-console-assets.sh and packaged by
# scripts/build_release_ipa.sh as Payload/*.app/FilzaRemoteWeb.bundle.
#
# Contract: docs/API.md (FilzaRemote API v1).

FilzaApplySandboxExt_FILES += FilzaRemoteConsole.m
FilzaApplySandboxExt_FILES += FilzaRemoteConsoleAPI.m
FilzaApplySandboxExt_FILES += FilzaRemoteConsoleFileOps.m
FilzaApplySandboxExt_FILES += FilzaRemoteConsolePreferences.m

before-FilzaApplySandboxExt-all::
	@test -f "FilzaRemoteConsole.h" || (echo "Missing FilzaRemoteConsole.h" >&2; exit 1)
	@test -f "FilzaRemoteConsoleInternal.h" || (echo "Missing FilzaRemoteConsoleInternal.h" >&2; exit 1)
	@test -f "FilzaRemoteConsole.m" || (echo "Missing FilzaRemoteConsole.m listener runtime" >&2; exit 1)
	@test -f "FilzaRemoteConsoleAPI.m" || (echo "Missing FilzaRemoteConsoleAPI.m handler surface" >&2; exit 1)
	@test -f "FilzaRemoteConsoleFileOps.m" || (echo "Missing FilzaRemoteConsoleFileOps.m upload/mutation surface" >&2; exit 1)
	@test -f "FilzaRemoteConsolePreferences.m" || (echo "Missing FilzaRemoteConsolePreferences.m settings section" >&2; exit 1)
	@test -f "scripts/stage-remote-console-assets.sh" || (echo "Missing remote console staging script" >&2; exit 1)
	@bash scripts/stage-remote-console-assets.sh
	@bash scripts/stage-remote-console-assets.sh --check
	@grep -Fq 'GCDWebServerOption_AutomaticallySuspendInBackground' FilzaRemoteConsole.m
	@grep -Fq 'GCDWebServerOption_BindToLocalhost: @NO' FilzaRemoteConsole.m
	@grep -Fq 'SecRandomCopyBytes' FilzaRemoteConsole.m
	@grep -Fq 'FilzaRemoteConsoleTokenEquals' FilzaRemoteConsole.m
	@grep -Fq 'FilzaRemoteConsoleResourceBundle' FilzaRemoteConsole.m
	@grep -Fq '/api/v1/ping' FilzaRemoteConsoleAPI.m
	@grep -Fq '/api/v1/download' FilzaRemoteConsoleAPI.m
	@grep -Fq 'CGImageSourceCreateThumbnailAtIndex' FilzaRemoteConsoleAPI.m
	@grep -Fq 'range_not_satisfiable' FilzaRemoteConsoleAPI.m
	@grep -Fq 'FilzaRemoteConsolePartialSuffix' FilzaRemoteConsoleFileOps.m
	@grep -Fq 'offset_mismatch' FilzaRemoteConsoleFileOps.m
	@grep -Fq 'GCDWebServerFileRequest' FilzaRemoteConsoleFileOps.m
	@grep -Fq 'GCDWebServerMultiPartFormRequest' FilzaRemoteConsoleFileOps.m
	@grep -Fq '0x08074B50' FilzaRemoteConsoleFileOps.m
	@grep -Fq 'TGPreferencesTableViewController' FilzaRemoteConsolePreferences.m
	@grep -Fq 'FilzaRemoteConsoleIsSyntheticSection' FilzaRemoteConsolePreferences.m
	@! grep -Fq 'listenOnPort' FilzaRemoteConsole.m

# The console module must not introduce a competing HTTP server or a second
# WebDAV listener: it plugs into the repo's existing GCDWebServer runtime.
before-FilzaApplySandboxExt-all::
	@! grep -Fq 'GCDWebDAVServer' FilzaRemoteConsole.m
	@! grep -Fq 'CocoaAsyncSocket' FilzaRemoteConsole.m
