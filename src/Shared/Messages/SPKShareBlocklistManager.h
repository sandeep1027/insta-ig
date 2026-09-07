#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPKShareBlocklistManager : NSObject

+ (instancetype)shared;

- (BOOL)isUsernameBlocked:(NSString *)username;
- (void)blockUsername:(NSString *)username;
- (void)unblockUsername:(NSString *)username;

@property (nonatomic, readonly) NSArray<NSString *> *blockedUsernames;

@end

NS_ASSUME_NONNULL_END
