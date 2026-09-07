#import "SPKShareBlocklistManager.h"

#import "../../Utils.h"

static NSString *const kSPKShareRecipientBlocklistKey = @"general_share_recipient_blocklist";

@implementation SPKShareBlocklistManager {
    NSMutableSet<NSString *> *_blocked;
}

+ (instancetype)shared {
    static SPKShareBlocklistManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [SPKShareBlocklistManager new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray *saved = SPKPreferenceObjectForKey(kSPKShareRecipientBlocklistKey);
        _blocked = [saved isKindOfClass:[NSArray class]] ? [NSMutableSet setWithArray:saved] : [NSMutableSet set];
    }
    return self;
}

- (void)_persist {
    SPKPreferenceSetObject(_blocked.allObjects, kSPKShareRecipientBlocklistKey);
}

- (NSString *)_normalize:(NSString *)username {
    NSString *value = username.lowercaseString;
    if ([value hasPrefix:@"@"])
        value = [value substringFromIndex:1];
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (BOOL)isUsernameBlocked:(NSString *)username {
    if (!username.length)
        return NO;
    return [_blocked containsObject:[self _normalize:username]];
}

- (void)blockUsername:(NSString *)username {
    NSString *normalized = [self _normalize:username];
    if (!normalized.length)
        return;
    [_blocked addObject:normalized];
    [self _persist];
}

- (void)unblockUsername:(NSString *)username {
    [_blocked removeObject:[self _normalize:username]];
    [self _persist];
}

- (NSArray<NSString *> *)blockedUsernames {
    return [_blocked.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

@end
