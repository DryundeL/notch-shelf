#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *NSHLocalizedString(NSString *key);
/// Temporary, process-bound experiment. No preferences or system files are modified.
@interface NSHNativeVisibility : NSObject
- (void)hideWithAllowedBundleIDs:(NSArray<NSString *> *)bundleIDs
                    completion:(void (^)(NSString * _Nullable error))completion;
- (void)restore;
@end
NS_ASSUME_NONNULL_END
