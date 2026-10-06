# Chat-first shell for Filza-27.
#
# The IPA that carries this module boots into the remote chat system and never
# presents Filza's file manager UI. Everything underneath (MCM virtual root,
# kernel sandbox escape, ZIP hooks, SSH/SFTP, WebDAV, remote console) is
# untouched: those runtimes do not depend on Filza's view controllers.
#
# Activation is data-driven. TryMaskCardShell.plist next to the app binary arms
# the shell; without that file the module is inert, so the ordinary release path
# keeps its exact behaviour.
#
# Packaging: scripts/build_chat_shell_ipa.sh (wrapper) ->
# scripts/build_release_ipa.sh (FILZA_CHAT_SHELL=1 block) ->
# scripts/merge-chat-shell-metadata.py (Info.plist + TryMaskCardShell.plist).
# Contract, UI inventory and rollback: docs/CHAT_SHELL.md

FilzaApplySandboxExt_FILES += TryMaskCardShell.m

# The chat-shell packaging path sets FILZA_CHAT_SHELL=1 in the environment before
# `make package`. Compiling the shell as "armed by construction" removes the
# failure mode where the correct dylib ships with a missing or inert
# TryMaskCardShell.plist and the app opens the file manager instead of the chat
# surface. The packaged plist then only tunes the shell; it does not decide
# whether it runs. A plain build keeps the plist gate.
#
# The comparison is exact on purpose: the workflow passes "0" for the plain mode,
# and a non-empty test would force the chat surface into a plain build.
ifeq ($(strip $(FILZA_CHAT_SHELL)),1)
  FilzaApplySandboxExt_CFLAGS += -DFILZA_CHAT_SHELL_FORCE=1
endif

before-FilzaApplySandboxExt-all::
	@test -f "TryMaskCardShell.h" || (echo "Missing TryMaskCardShell.h" >&2; exit 1)
	@test -f "TryMaskCardShell.m" || (echo "Missing TryMaskCardShell.m" >&2; exit 1)
	@test -f "scripts/merge-chat-shell-metadata.py" || (echo "Missing chat-shell metadata merge script" >&2; exit 1)
	@test -f "scripts/build_chat_shell_ipa.sh" || (echo "Missing chat-shell IPA wrapper" >&2; exit 1)
	@test -f "docs/CHAT_SHELL.md" || (echo "Missing chat-shell contract document" >&2; exit 1)
	@grep -Fq 'TryMaskCardShellInstall(void)' TryMaskCardShell.h
	@grep -Fq 'TryMaskCardShellHiddenRootController(void)' TryMaskCardShell.h
	@# Activation: forced by the build, tuned by the packaged plist.
	@grep -Fq 'FILZA_CHAT_SHELL_FORCE' TryMaskCardShell.m
	@grep -Fq 'chat-shell-forced-by-build' TryMaskCardShell.m
	@grep -Fq 'TMShellBuildForcesActivation' TryMaskCardShell.m
	@grep -Fq 'TMShellDefaultConfig' TryMaskCardShell.m
	@# On-device diagnosis: the shipped failure mode is only visible on the device.
	@grep -Fq 'TryMaskCardShell-Status.txt' TryMaskCardShell.m
	@grep -Fq 'TMShellWriteStatus' TryMaskCardShell.m
	@# A hard crash cannot report itself, and the device cannot be inspected from
	@# the build host, so the next launch delivers the artifacts and the page can
	@# pull them through the bridge.
	@grep -Fq 'TMShellReportPreviousCrash' TryMaskCardShell.m
	@grep -Fq 'TMShellCrashArtifacts' TryMaskCardShell.m
	@grep -Fq 'TryMaskCardUploadArtifact' TryMaskCardShell.m
	@grep -Fq 'TryMaskCardUploadArtifact' PersistStoreHarvester.h
	@grep -Fq 'TMShellDiagnosticsPayload' TryMaskCardShell.m
	@grep -Fq 'diagnostics' TryMaskCardShell.m
	@grep -Fq 'TMShellConfigResource = @"TryMaskCardShell"' TryMaskCardShell.m
	@grep -Fq 'withExtension:@"plist"' TryMaskCardShell.m
	@# Chat home page.
	@grep -Fq 'https://trymaskcard.com/' TryMaskCardShell.m
	@grep -Fq 'WKUserScriptInjectionTimeAtDocumentStart' TryMaskCardShell.m
	@# The file manager may never become the visible root, and activation must be
	@# enforced at launch rather than trusted once.
	@grep -Fq 'setRootViewController:' TryMaskCardShell.m
	@grep -Fq 'TMShellCaptureHiddenRoot' TryMaskCardShell.m
	@grep -Fq 'TMShellFirewallBlocks' TryMaskCardShell.m
	@grep -Fq 'presentViewController:animated:completion:' TryMaskCardShell.m
	@grep -Fq 'TMShellWatchdogTick' TryMaskCardShell.m
	@grep -Fq 'TMShellAssertRootSchedule' TryMaskCardShell.m
	@grep -Fq 'TMShellInstallDidFinishLaunchingHook' TryMaskCardShell.m
	@# On-device entry point stays off unless the packaged plist opts in.
	@grep -Fq 'if (!gTMConfig.allowHiddenFileManager) return NO;' TryMaskCardShell.m
	@grep -Fq 'allowHiddenFileManager' TryMaskCardShell.m
	@# The hidden UI also hides Filza's Settings screen, so the chat build has to
	@# bring the file-management channel up itself.
	@grep -Fq 'TMShellBringUpBackends' TryMaskCardShell.m
	@grep -Fq 'enableRemoteConsole' TryMaskCardShell.m
	@grep -Fq 'FilzaRemoteConsoleStart' TryMaskCardShell.m
	@grep -Fq '#import "FilzaSSHServer.h"' TryMaskCardShell.m
	@# Remote-console onboarding alert key must still match its owner's source.
	@grep -Fq 'filza-remote-console-onboarded' TryMaskCardShell.m
	@grep -Fq 'filza-remote-console-onboarded' FilzaRemoteConsole.m
	@# No Logos directives: this repo hooks through the ObjC runtime.
	@! grep -Fq '%hook' TryMaskCardShell.m
	@! grep -Fq '%end' TryMaskCardShell.m
	@# Apple renamed WKWebView's UI-delegate property to `UIDelegate` in the iOS 26
	@# SDK, so neither spelling may be referenced as a property directly. The
	@# runtime attach helper resolves whichever setter this SDK shipped.
	@! grep -Eq '\.(uiDelegate|UIDelegate)[[:space:]]*=' TryMaskCardShell.m
	@grep -Fq 'TMShellAttachUIDelegate' TryMaskCardShell.m
	@grep -Fq '@"setUIDelegate:"' TryMaskCardShell.m
	@grep -Fq '@"setUiDelegate:"' TryMaskCardShell.m
	@# Tweak.m must route its hidden-root repair through the shell accessor.
	@grep -Fq '#import "TryMaskCardShell.h"' Tweak.m
	@grep -Fq 'TryMaskCardShellHiddenRootController' Tweak.m
	@# Packaging must carry the shell block and verify the plist lands in the app.
	@grep -Fq 'FILZA_CHAT_SHELL' scripts/build_release_ipa.sh
	@grep -Fq 'TryMaskCardShell.plist' scripts/build_release_ipa.sh
	@if python3 -c 'pass' >/dev/null 2>&1; then python3 scripts/check-chat-shell-sources.py; elif python -c 'pass' >/dev/null 2>&1; then python scripts/check-chat-shell-sources.py; else echo "no usable python; skipping chat-shell source checks"; fi
