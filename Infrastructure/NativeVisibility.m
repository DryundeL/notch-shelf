#import "NativeVisibility.h"
#import <objc/message.h>
#import <dlfcn.h>

NSString *NSHLocalizedString(NSString *key) {
    static NSBundle *languageBundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *main = NSBundle.mainBundle;
        NSString *choice = [NSUserDefaults.standardUserDefaults stringForKey:@"shelf.language"];
        if (![@[@"ru", @"en"] containsObject:choice ?: @""]) {
            choice = [main.preferredLocalizations.firstObject hasPrefix:@"ru"] ? @"ru" : @"en";
        }
        NSString *path = [main pathForResource:choice ofType:@"lproj"];
        languageBundle = path ? [NSBundle bundleWithPath:path] : main;
    });
    return [languageBundle localizedStringForKey:key value:key table:nil];
}

static void NSHInvalidate(id assertion) {
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
        }
    } @catch (NSException *exception) { /* Process exit also releases the assertion. */ }
}

@implementation NSHNativeVisibility {
    /// Confirmed, currently applied restriction.
    id _assertion;
    /// Replacement being activated. The confirmed one stays in force until it succeeds,
    /// so changing the allow-list never flashes hidden icons back into the menu bar.
    id _pending;
    NSUInteger _generation;
}

- (void)restore {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    _generation++;
    NSHInvalidate(_pending);
    NSHInvalidate(_assertion);
    _pending = nil;
    _assertion = nil;
}

- (void)hideWithAllowedBundleIDs:(NSArray<NSString *> *)bundleIDs
                    completion:(void (^)(NSString * _Nullable))completion {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    _generation++;
    // A superseded, still unconfirmed request must not linger.
    NSHInvalidate(_pending);
    _pending = nil;
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    if (os.majorVersion != 27 || os.minorVersion != 0 || os.patchVersion != 1) {
        [self restore];
        completion(NSHLocalizedString(@"Эксперимент разрешён только на проверяемой macOS 27.0.1.")); return;
    }
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL);
    Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    SEL initialize = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
    SEL activate = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
    if (!framework || ![configClass instancesRespondToSelector:initialize] ||
        ![assertionClass instancesRespondToSelector:activate] ||
        ![assertionClass instancesRespondToSelector:@selector(invalidate)]) {
        [self restore];
        completion(NSHLocalizedString(@"Системный API скрытия недоступен.")); return;
    }
    @try {
        // Preserve all known/unknown system-item slots instead of selecting only the clock.
        NSMutableArray *systemItems = [NSMutableArray array];
        for (NSInteger index = 0; index < 64; index++) [systemItems addObject:@(index)];
        id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)([configClass alloc], initialize, systemItems, bundleIDs);
        if (!configuration) { [self restore]; completion(NSHLocalizedString(@"Не удалось создать системное ограничение.")); return; }
        [self activateConfiguration:configuration assertionClass:assertionClass selector:activate
                     allowFallback:(_assertion != nil) completion:completion];
    } @catch (NSException *exception) {
        [self restore];
        completion(NSHLocalizedString(@"Системный API несовместим с этой сборкой macOS."));
    }
}

/// Activates `configuration` alongside the current restriction and swaps on success.
/// If the system refuses a second concurrent restriction, falls back once to the old
/// behaviour: drop the current one and activate from scratch (a brief, visible gap).
- (void)activateConfiguration:(id)configuration assertionClass:(Class)assertionClass selector:(SEL)activate
                allowFallback:(BOOL)allowFallback completion:(void (^)(NSString * _Nullable))completion {
    NSUInteger generation = _generation;
    id candidate = [[assertionClass alloc] init];
    if (!candidate) { [self restore]; completion(NSHLocalizedString(@"Не удалось создать системное ограничение.")); return; }
    _pending = candidate;
    __block BOOL finished = NO;
    __weak typeof(self) weakSelf = self;
    void (^callback)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (finished || !self) return;
            finished = YES;
            if (generation != self->_generation || self->_pending != candidate) {
                NSHInvalidate(candidate);
                completion(NSHLocalizedString(@"Операция отменена."));
                return;
            }
            self->_pending = nil;
            if (error) {
                NSHInvalidate(candidate);
                if (allowFallback && self->_assertion) {
                    NSHInvalidate(self->_assertion);
                    self->_assertion = nil;
                    @try {
                        [self activateConfiguration:configuration assertionClass:assertionClass selector:activate
                                     allowFallback:NO completion:completion];
                    } @catch (NSException *exception) {
                        [self restore];
                        completion(NSHLocalizedString(@"Системный API несовместим с этой сборкой macOS."));
                    }
                    return;
                }
                [self restore];
                completion([NSString stringWithFormat:NSHLocalizedString(@"Отказ скрытия (%@, код %ld)."), error.domain, (long)error.code]);
                return;
            }
            NSHInvalidate(self->_assertion);
            self->_assertion = candidate;
            completion(nil);
        });
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(candidate, activate, configuration, callback);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (finished) return;
        finished = YES;
        NSHInvalidate(candidate);
        if (self && generation == self->_generation) [self restore];
        completion(NSHLocalizedString(@"Система не подтвердила скрытие за 3 секунды; ограничение снято."));
    });
}
@end
