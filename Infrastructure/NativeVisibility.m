#import "NativeVisibility.h"
#import <objc/message.h>
#import <dlfcn.h>

@implementation NSHNativeVisibility {
    id _assertion;
    NSUInteger _generation;
}
- (void)restore {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    _generation++;
    @try {
        if ([_assertion respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(_assertion, @selector(invalidate));
        }
    } @catch (NSException *exception) { /* Process exit also releases the assertion. */ }
    _assertion = nil;
}
- (void)hideWithAllowedBundleIDs:(NSArray<NSString *> *)bundleIDs
                    completion:(void (^)(NSString * _Nullable))completion {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    [self restore];
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    if (os.majorVersion != 27 || os.minorVersion != 0 || os.patchVersion != 1) {
        completion(@"Эксперимент разрешён только на проверяемой macOS 27.0.1."); return;
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
        completion(@"Системный API скрытия недоступен."); return;
    }
    NSUInteger generation = _generation;
    __block BOOL finished = NO;
    @try {
        // Preserve all known/unknown system-item slots instead of selecting only the clock.
        NSMutableArray *systemItems = [NSMutableArray array];
        for (NSInteger index = 0; index < 64; index++) [systemItems addObject:@(index)];
        id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)([configClass alloc], initialize, systemItems, bundleIDs);
        _assertion = [[assertionClass alloc] init];
        if (!configuration || !_assertion) { [self restore]; completion(@"Не удалось создать системное ограничение."); return; }
        void (^callback)(NSError *) = ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (finished) return;
                finished = YES;
                if (generation != self->_generation) { completion(@"Операция отменена."); return; }
                if (error) {
                    [self restore];
                    completion([NSString stringWithFormat:@"Отказ скрытия (%@, код %ld).", error.domain, (long)error.code]);
                } else { completion(nil); }
            });
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(_assertion, activate, configuration, callback);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            if (generation == self->_generation) [self restore];
            completion(@"Система не подтвердила скрытие за 3 секунды; ограничение снято.");
        });
    } @catch (NSException *exception) {
        finished = YES;
        [self restore];
        completion(@"Системный API несовместим с этой сборкой macOS.");
    }
}
@end
