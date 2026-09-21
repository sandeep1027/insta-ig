#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../../Shared/Messages/SPKDirectHiddenChats.h"
#import "../../Shared/Messages/SPKShareBlocklistManager.h"
#import "SPKStrings.h"

#import <objc/runtime.h>

static const void *kSPKSupershareBlockedKey = &kSPKSupershareBlockedKey;
static const void *kSPKSupershareUsernameKey = &kSPKSupershareUsernameKey;

/// Returns YES when `username` should be suppressed on share surfaces.
/// Checks the explicit share-recipient blocklist first, then falls through to the
/// hidden-chats list so any user in a hidden 1:1 chat disappears from the share
/// sheet, quick-send strip, and supershard row without a separate blocklist entry.
static BOOL SPKShouldHideShareRecipientWithUsername(NSString *username) {
    if (!username.length)
        return NO;
    if ([[SPKShareBlocklistManager shared] isUsernameBlocked:username])
        return YES;
        
    BOOL hiddenChatsShareSheetEnabled = SPKDirectHiddenChatsEnabled() && [SPKUtils getBoolPref:@"msgs_hidden_chats_hide_in_share_sheet"];
    return hiddenChatsShareSheetEnabled && SPKDirectHiddenChatListContainsUsername(username);
}

static BOOL SPKHideShareRecipientsAnyFeatureEnabled(void) {
    BOOL hiddenChatsShareSheetEnabled = SPKDirectHiddenChatsEnabled() && [SPKUtils getBoolPref:@"msgs_hidden_chats_hide_in_share_sheet"];
    return [SPKUtils getBoolPref:@"general_hide_share_recipients"] || hiddenChatsShareSheetEnabled;
}

static NSString *SPKUsernameFromShareObject(id obj) {
    if (!obj)
        return nil;

    static NSArray *kpaths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kpaths = @[
            @"username",
            @"_username",
            @"user.username",
            @"recipient.username",
            @"recipient.user.username",
            @"thread.username",
            @"viewModel.recipient.users",
            @"recipient.users",
            @"users",
            @"entity.directRecipient_recipient.users",
        ];
    });

    for (NSString *kp in kpaths) {
        @try {
            id val = [obj valueForKeyPath:kp];
            if ([val isKindOfClass:[NSString class]] && ((NSString *)val).length)
                return val;
            if ([val isKindOfClass:[NSArray class]]) {
                NSArray *arr = val;
                if (arr.count > 0) {
                    @try {
                        id uname = [arr.firstObject valueForKey:@"username"];
                        if ([uname isKindOfClass:[NSString class]] && ((NSString *)uname).length)
                            return uname;
                    } @catch (...) {
                    }
                }
            }
        } @catch (...) {
        }
    }
    return nil;
}

static NSString *SPKUsernameFromSupershareCell(id cell) {
    @try {
        id vm = [cell valueForKey:@"recipientCellViewModel"];
        id recipient = [vm valueForKey:@"recipient"];
        NSArray *users = [recipient valueForKey:@"users"];
        if ([users isKindOfClass:[NSArray class]] && users.count == 1) {
            id uname = [users.firstObject valueForKey:@"username"];
            if ([uname isKindOfClass:[NSString class]] && ((NSString *)uname).length)
                return uname;
        }
        NSString *fallback = SPKUsernameFromShareObject(vm);
        return fallback ?: SPKUsernameFromShareObject(recipient);
    } @catch (...) {
    }
    return nil;
}

%group SPKHideShareRecipientsHooks

%hook IGDirectRecipientListViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    if (!SPKHideShareRecipientsAnyFeatureEnabled())
        return originalObjs;

    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:originalObjs.count];
    for (id obj in originalObjs) {
        BOOL shouldHide = NO;
        if ([obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {
            id recipient = [obj recipient];
            NSString *username = SPKUsernameFromShareObject(obj);
            if (!username.length)
                username = SPKUsernameFromShareObject(recipient);
            if (username.length && SPKShouldHideShareRecipientWithUsername(username)) {
                SPKLog(@"General", @"[Sparkle] Hiding share recipient (blocklist/hidden chat): %@", username);
                shouldHide = YES;
            }
        }
        if (!shouldHide)
            [filteredObjs addObject:obj];
    }
    return [filteredObjs copy];
}
%end

%hook IGDirectSupershareV3RecipientCellSectionController
- (void)didUpdateToObject:(id)object {
    %orig;

    NSString *username = SPKUsernameFromShareObject(object);
    if (!username) {
        @try {
            id recipient = [object valueForKey:@"recipient"];
            username = SPKUsernameFromShareObject(recipient);
        } @catch (...) {
        }
    }
    if (!username)
        username = SPKUsernameFromShareObject(self);
    if (username)
        objc_setAssociatedObject(self, kSPKSupershareUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);

    if (!SPKHideShareRecipientsAnyFeatureEnabled()) {
        objc_setAssociatedObject(self, kSPKSupershareBlockedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    BOOL blocked = username.length && SPKShouldHideShareRecipientWithUsername(username);
    if (blocked)
        SPKLog(@"General", @"[Sparkle] Hiding supershard recipient (blocklist/hidden chat): %@", username);
    objc_setAssociatedObject(self, kSPKSupershareBlockedKey, @(blocked), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSInteger)numberOfItems {
    NSNumber *blocked = objc_getAssociatedObject(self, kSPKSupershareBlockedKey);
    if ([blocked boolValue])
        return 0;
    return %orig;
}

- (CGSize)sizeForItemAtIndex:(NSInteger)index {
    NSNumber *blocked = objc_getAssociatedObject(self, kSPKSupershareBlockedKey);
    if ([blocked boolValue])
        return CGSizeZero;
    return %orig;
}
%end

%hook IGDirectQuickSendListAdapterDataSource
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *orig = %orig;
    if (!SPKHideShareRecipientsAnyFeatureEnabled())
        return orig;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:orig.count];
    for (id obj in orig) {
        NSString *username = SPKUsernameFromShareObject(obj);
        if (username.length && SPKShouldHideShareRecipientWithUsername(username)) {
            SPKLog(@"General", @"[Sparkle] Hiding quick-send recipient (blocklist/hidden chat): %@", username);
            continue;
        }
        [filtered addObject:obj];
    }
    return [filtered copy];
}
%end

%hook IGDirectSupershareV3Cell
- (void)handleLongPress:(id)gestureRecognizer {
    if (![SPKUtils getBoolPref:@"general_hide_share_recipients"]) {
        %orig;
        return;
    }

    NSString *username = SPKUsernameFromSupershareCell(self);
    if (!username.length) {
        UIResponder *r = (UIResponder *)self;
        while (r) {
            if ([r isKindOfClass:[UICollectionView class]]) {
                UICollectionView *cv = (UICollectionView *)r;
                id ds = cv.dataSource;
                @try {
                    NSArray *scs = [ds valueForKey:@"sectionControllers"];
                    for (id sc in scs) {
                        NSString *stored = objc_getAssociatedObject(sc, kSPKSupershareUsernameKey);
                        if (stored.length) {
                            username = stored;
                            break;
                        }
                    }
                } @catch (...) {
                }
                break;
            }
            r = r.nextResponder;
        }
    }

    if (!username.length) {
        %orig;
        return;
    }

    UIViewController *sheetVC = nil;
    UIResponder *walker = (UIResponder *)self;
    while (walker) {
        if ([walker isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)walker;
            if (vc.presentingViewController) {
                sheetVC = vc;
                break;
            }
        }
        walker = walker.nextResponder;
    }

    BOOL alreadyBlocked = [[SPKShareBlocklistManager shared] isUsernameBlocked:username];
    NSString *capturedUsername = username;
    UIViewController *__weak weakSheet = sheetVC;

    NSString *title = alreadyBlocked ? SPKL(@"GENERAL_SHARE_SHEET_UNHIDE_TITLE") : SPKL(@"GENERAL_SHARE_SHEET_HIDE_TITLE");
    NSString *message = alreadyBlocked
        ? [NSString stringWithFormat:SPKL(@"GENERAL_SHARE_SHEET_UNHIDE_MESSAGE"), username]
        : [NSString stringWithFormat:SPKL(@"GENERAL_SHARE_SHEET_HIDE_MESSAGE"), username];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:alreadyBlocked ? SPKL(@"GENERAL_SHARE_SHEET_UNHIDE_ACTION") : SPKL(@"GENERAL_SHARE_SHEET_HIDE_ACTION")
                                              style:alreadyBlocked ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        if (alreadyBlocked) {
            [[SPKShareBlocklistManager shared] unblockUsername:capturedUsername];
        } else {
            [[SPKShareBlocklistManager shared] blockUsername:capturedUsername];
            UIViewController *sheet = weakSheet;
            if (sheet)
                [sheet.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [topMostController() presentViewController:alert animated:YES completion:nil];
}
%end

%end

extern "C" void SPKInstallHideShareRecipientsHooksIfEnabled(void) {
    // Install when the explicit share-recipient blocklist is on, OR when the hidden-chats
    // feature is on — both features now use the same hooks and the same helper function.
    BOOL hiddenChatsShareSheetEnabled = SPKDirectHiddenChatsEnabled() && [SPKUtils getBoolPref:@"msgs_hidden_chats_hide_in_share_sheet"];
    BOOL needsHooks = [SPKUtils getBoolPref:@"general_hide_share_recipients"] || hiddenChatsShareSheetEnabled;
    if (!needsHooks)
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKHideShareRecipientsHooks,
                       IGDirectSupershareV3RecipientCellSectionController = SPKResolveIGClass(@"IGDirectSupershareSwiftV3.IGDirectSupershareV3RecipientCellSectionController", @"IGDirectSupershareV3RecipientCellSectionController"),
                       IGDirectQuickSendListAdapterDataSource = SPKResolveIGClass(@"IGDirectQuickSendViewController.IGDirectQuickSendListAdapterDataSource", @"IGDirectQuickSendListAdapterDataSource"),
                       IGDirectSupershareV3Cell = SPKResolveIGClass(@"IGDirectSupershareSwiftV3.IGDirectSupershareV3Cell", @"IGDirectSupershareV3Cell"));
    });
}
