#import "SPKDirectInboxMenu.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../Utils.h"

@interface SPKDirectInboxMenuEntry : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) NSInteger order;
@property (nonatomic, copy) SPKDirectInboxMenuProvider provider;
@end

@implementation SPKDirectInboxMenuEntry
@end

@interface SPKDirectInboxMenuTransformerEntry : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) NSInteger order;
@property (nonatomic, copy) SPKDirectInboxMenuTransformer transformer;
@end

@implementation SPKDirectInboxMenuTransformerEntry
@end

static NSMutableArray<SPKDirectInboxMenuEntry *> *SPKDirectInboxMenuEntries;
static NSMutableArray<SPKDirectInboxMenuTransformerEntry *> *SPKDirectInboxMenuTransformerEntries;

// Two inbox view controllers implement this delegate callback and which one backs
// the inbox is decided server side, so both are hooked and each keeps its own
// original implementation.
static id (*SPKDirectOrigInboxContextMenu)(id, SEL, id);
static id (*SPKDirectOrigInboxSwiftContextMenu)(id, SEL, id);
static id (*SPKDirectOrigInboxLegacyContextMenu)(id, SEL, id);

static id SPKDirectInboxMenuKVCObject(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// `actionProvider` is not a public property. KVC sometimes finds the block and
/// sometimes does not, depending on which configuration Instagram handed back.
static BOOL SPKDirectInboxMenuObjectIsBlock(id object) {
    static Class blockClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id sample = ^{
        };
        blockClass = [sample class];
        while (blockClass && class_getSuperclass(blockClass) != [NSObject class])
            blockClass = class_getSuperclass(blockClass);
    });
    return blockClass != Nil && [object isKindOfClass:blockClass];
}

static UIContextMenuActionProvider SPKDirectInboxMenuActionProvider(UIContextMenuConfiguration *configuration) {
    id provider = SPKDirectInboxMenuKVCObject(configuration, @"actionProvider");
    if (!SPKDirectInboxMenuObjectIsBlock(provider))
        provider = SPKDirectInboxMenuKVCObject(configuration, @"_actionProvider");
    if (!SPKDirectInboxMenuObjectIsBlock(provider))
        return nil;
    // Copy before the configuration's stack frame goes away. A stack block read
    // through KVC becomes a dangling pointer by the time UIKit asks for the menu.
    return [provider copy];
}

static const void *kSPKDirectInboxMenuProviderKey = &kSPKDirectInboxMenuProviderKey;

// Sparkle never replaces the configuration object. Rebuilding one with
// configurationWithIdentifier:previewProvider:actionProvider: drops the private
// preview/menu state Instagram builds for its context menus, and the long press
// then fails to open on some chats. The original object is kept and only its
// action provider is swapped, through both the public getter and the backing
// ivar (UIKit's private menu machinery does not always go through the getter).
static UIContextMenuActionProvider (*SPKDirectOrigActionProviderGetter)(id, SEL);

static UIContextMenuActionProvider SPKDirectInboxMenuProviderGetter(id self, SEL _cmd) {
    UIContextMenuActionProvider wrapped = objc_getAssociatedObject(self, kSPKDirectInboxMenuProviderKey);
    if (wrapped)
        return wrapped;
    return SPKDirectOrigActionProviderGetter ? SPKDirectOrigActionProviderGetter(self, _cmd) : nil;
}

static void SPKDirectInboxMenuInstallProviderGetterHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL selector = @selector(actionProvider);
        if (!class_getInstanceMethod([UIContextMenuConfiguration class], selector))
            return;
        MSHookMessageEx([UIContextMenuConfiguration class],
                        selector,
                        (IMP)SPKDirectInboxMenuProviderGetter,
                        (IMP *)&SPKDirectOrigActionProviderGetter);
    });
}

static void SPKDirectInboxMenuAttachProvider(UIContextMenuConfiguration *configuration,
                                             UIContextMenuActionProvider provider) {
    if (!configuration || !provider)
        return;
    objc_setAssociatedObject(configuration, kSPKDirectInboxMenuProviderKey, provider,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // object_setIvar retains the new block and releases the replaced one, so the
    // configuration's own ownership stays balanced while the association keeps
    // the getter path alive too.
    Ivar ivar = class_getInstanceVariable(object_getClass(configuration), "_actionProvider");
    if (!ivar)
        ivar = class_getInstanceVariable([UIContextMenuConfiguration class], "_actionProvider");
    if (ivar)
        object_setIvar(configuration, ivar, provider);
}

void SPKDirectInboxMenuRegisterProvider(NSString *identifier, NSInteger order, SPKDirectInboxMenuProvider provider) {
    if (identifier.length == 0 || !provider)
        return;
    if (!SPKDirectInboxMenuEntries)
        SPKDirectInboxMenuEntries = [NSMutableArray array];

    [SPKDirectInboxMenuEntries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPKDirectInboxMenuEntry *entry, NSDictionary *bindings) {
                                    (void)bindings;
                                    return ![entry.identifier isEqualToString:identifier];
                                }]];

    SPKDirectInboxMenuEntry *entry = [SPKDirectInboxMenuEntry new];
    entry.identifier = identifier;
    entry.order = order;
    entry.provider = provider;
    [SPKDirectInboxMenuEntries addObject:entry];
    [SPKDirectInboxMenuEntries sortUsingComparator:^NSComparisonResult(SPKDirectInboxMenuEntry *a, SPKDirectInboxMenuEntry *b) {
        if (a.order == b.order)
            return [a.identifier compare:b.identifier];
        return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
    }];
}

void SPKDirectInboxMenuRegisterTransformer(NSString *identifier, NSInteger order, SPKDirectInboxMenuTransformer transformer) {
    if (identifier.length == 0 || !transformer)
        return;
    if (!SPKDirectInboxMenuTransformerEntries)
        SPKDirectInboxMenuTransformerEntries = [NSMutableArray array];

    [SPKDirectInboxMenuTransformerEntries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPKDirectInboxMenuTransformerEntry *entry, NSDictionary *bindings) {
                                               (void)bindings;
                                               return ![entry.identifier isEqualToString:identifier];
                                           }]];

    SPKDirectInboxMenuTransformerEntry *entry = [SPKDirectInboxMenuTransformerEntry new];
    entry.identifier = identifier;
    entry.order = order;
    entry.transformer = transformer;
    [SPKDirectInboxMenuTransformerEntries addObject:entry];
    [SPKDirectInboxMenuTransformerEntries sortUsingComparator:^NSComparisonResult(SPKDirectInboxMenuTransformerEntry *a, SPKDirectInboxMenuTransformerEntry *b) {
        if (a.order == b.order)
            return [a.identifier compare:b.identifier];
        return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
    }];
}

/// Walks from the tapped index path to the thread view model behind it. The Swift
/// view controller stores its adapter under an unprefixed ivar name, so all three
/// spellings are tried.
static id SPKDirectInboxMenuViewModelForIndexPath(id controller, id indexPath) {
    id adapter = SPKDirectInboxMenuKVCObject(controller, @"listAdapter");
    if (!adapter)
        adapter = [SPKUtils getIvarForObj:controller name:"_listAdapter"];
    if (!adapter)
        adapter = [SPKUtils getIvarForObj:controller name:"listAdapter"];
    if (!adapter || ![indexPath respondsToSelector:@selector(section)]) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: missing adapter/indexPath controller=%@<%p>",
               NSStringFromClass([controller class]),
               controller);
        return nil;
    }

    SEL sectionControllerSelector = NSSelectorFromString(@"sectionControllerForSection:");
    if (![adapter respondsToSelector:sectionControllerSelector]) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: adapter lacks sectionControllerForSection adapter=%@<%p>",
               NSStringFromClass([adapter class]),
               adapter);
        return nil;
    }

    NSInteger section = [(NSIndexPath *)indexPath section];
    id sectionController = nil;
    @try {
        sectionController = ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, sectionControllerSelector, section);
    } @catch (NSException *exception) {
        // ListKit raises for an index path that no longer matches the adapter
        // (a diff landing under a long press). Letting that escape the delegate
        // callback cancels the interaction, so the popup never appears.
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: sectionControllerForSection: threw section=%ld adapter=%@ exception=%@",
               (long)section,
               NSStringFromClass([adapter class]),
               exception.name);
        return nil;
    }
    id viewModel = SPKDirectInboxMenuKVCObject(sectionController, @"viewModel");
    if (!viewModel)
        viewModel = [SPKUtils getIvarForObj:sectionController name:"_viewModel"];
    if (!viewModel)
        viewModel = SPKDirectInboxMenuKVCObject(sectionController, @"item");
    if (!viewModel)
        viewModel = [SPKUtils getIvarForObj:sectionController name:"_item"];

    if (!viewModel) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: missing viewModel section=%ld sectionController=%@<%p>",
               (long)section,
               NSStringFromClass([sectionController class]),
               sectionController);
    }
    return viewModel;
}

static id SPKDirectInboxMenuWrapConfigurationForViewModel(id viewModel, id configuration) {
    if (SPKDirectInboxMenuEntries.count == 0 && SPKDirectInboxMenuTransformerEntries.count == 0)
        return configuration;
    if (![configuration isKindOfClass:[UIContextMenuConfiguration class]])
        return configuration;
    if (!viewModel)
        return configuration;

    SPKDirectThreadContext *context = SPKDirectThreadContextFromInboxViewModel(viewModel);
    if (context.threadId.length == 0) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: no thread context viewModel=%@<%p>",
               NSStringFromClass([viewModel class]),
               viewModel);
        return configuration;
    }

    UIContextMenuConfiguration *original = (UIContextMenuConfiguration *)configuration;
    // The same configuration can be handed back more than once; never wrap a
    // wrapped provider, or each call would nest another layer.
    if (objc_getAssociatedObject(original, kSPKDirectInboxMenuProviderKey))
        return configuration;
    UIContextMenuActionProvider originalProvider = SPKDirectInboxMenuActionProvider(original);
    // A replacement with no Instagram action block has no Delete / Mute / Unread
    // rows. UIKit treats that empty menu as a cancelled long-press. Keep the
    // original configuration so the submenu still opens.
    if (!originalProvider) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Kept Instagram menu: action provider unreadable threadId=%@ configuration=%@<%p>",
               context.threadId ?: @"(unknown)",
               NSStringFromClass([original class]),
               original);
        return configuration;
    }

    NSArray<SPKDirectInboxMenuEntry *> *entries = [SPKDirectInboxMenuEntries copy];
    NSArray<SPKDirectInboxMenuTransformerEntry *> *transformerEntries = [SPKDirectInboxMenuTransformerEntries copy];

    UIContextMenuActionProvider wrappedProvider = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIMenu *baseMenu = nil;
        @try {
            baseMenu = originalProvider(suggestedActions);
        } @catch (NSException *exception) {
            SPKLog(@"Messages", @"[Sparkle InboxMenu] Original provider failed threadId=%@ exception=%@ reason=%@",
                   context.threadId ?: @"(unknown)",
                   exception.name,
                   exception.reason);
            baseMenu = nil;
        }
        if (![baseMenu isKindOfClass:[UIMenu class]]) {
            // An empty menu is not a harmless menu: UIKit reads it as a cancelled
            // long press and the popup never appears. Only substitute the
            // system-suggested rows when there actually are some.
            SPKLog(@"Messages", @"[Sparkle InboxMenu] Original provider returned invalid menu threadId=%@ menu=%@ suggested=%lu",
                   context.threadId ?: @"(unknown)",
                   baseMenu,
                   (unsigned long)suggestedActions.count);
            return suggestedActions.count > 0 ? [UIMenu menuWithChildren:suggestedActions] : nil;
        }

        UIMenu *lastNonEmptyMenu = baseMenu;
        for (SPKDirectInboxMenuTransformerEntry *entry in transformerEntries) {
            UIMenu *transformedMenu = nil;
            @try {
                transformedMenu = entry.transformer(context, viewModel, baseMenu);
            } @catch (NSException *exception) {
                SPKLog(@"Messages", @"[Sparkle InboxMenu] Transformer %@ threw exception=%@ reason=%@",
                       entry.identifier,
                       exception.name,
                       exception.reason);
                continue;
            }
            if (![transformedMenu isKindOfClass:[UIMenu class]])
                continue;
            baseMenu = transformedMenu;
            if (baseMenu.children.count > 0)
                lastNonEmptyMenu = baseMenu;
        }

        NSMutableArray<UIMenuElement *> *sparkleElements = [NSMutableArray array];
        for (SPKDirectInboxMenuEntry *entry in entries) {
            NSArray<UIMenuElement *> *elements = nil;
            @try {
                elements = entry.provider(context, viewModel);
            } @catch (NSException *exception) {
                SPKLog(@"Messages", @"[Sparkle InboxMenu] Provider %@ threw exception=%@ reason=%@",
                       entry.identifier,
                       exception.name,
                       exception.reason);
                continue;
            }
            for (UIMenuElement *element in elements ?: @[]) {
                if ([element isKindOfClass:[UIMenuElement class]])
                    [sparkleElements addObject:element];
            }
        }
        if (sparkleElements.count == 0) {
            if (baseMenu.children.count > 0)
                return baseMenu;
            // A transformer can remove every row — the Message Preview upsell is
            // the whole menu on some threads. Returning that empty menu would
            // cancel the long press, so put back the menu it was handed.
            if (lastNonEmptyMenu && lastNonEmptyMenu != baseMenu) {
                SPKLog(@"Messages", @"[Sparkle InboxMenu] Restored menu emptied by a transformer threadId=%@ children=%lu",
                       context.threadId ?: @"(unknown)",
                       (unsigned long)lastNonEmptyMenu.children.count);
                return lastNonEmptyMenu;
            }
            // Nothing to show and nothing to add: returning this empty menu
            // would cancel the long press. Say so, so a bug report can name
            // the culprit instead of "the menu does not open".
            SPKLog(@"Messages", @"[Sparkle InboxMenu] Suppressed empty menu threadId=%@ transformers=%lu",
                   context.threadId ?: @"(unknown)",
                   (unsigned long)transformerEntries.count);
            return nil;
        }

        // An inline menu renders as its own divided section rather than a nested
        // row, and putting it first in `children` keeps Sparkle's rows above
        // Instagram's own actions.
        UIMenu *sparkleSection = [UIMenu menuWithTitle:@""
                                                 image:nil
                                            identifier:nil
                                               options:UIMenuOptionsDisplayInline
                                              children:sparkleElements];
        NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObject:sparkleSection];
        [children addObjectsFromArray:baseMenu.children ?: @[]];
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Built menu threadId=%@ base=%lu sparkle=%lu",
               context.threadId ?: @"(unknown)",
               (unsigned long)baseMenu.children.count,
               (unsigned long)sparkleElements.count);
        return [baseMenu menuByReplacingChildren:children];
    };

    SPKDirectInboxMenuAttachProvider(original, wrappedProvider);
    // Hand Instagram's own configuration back untouched: only the provider was
    // swapped, so the preview and the private menu state around it stay intact.
    return configuration;
}

// Newer builds hand the delegate an index path and expect the callee to find the
// thread behind it; older ones pass the view model straight in. Both funnel into the
// same wrap, so a feature's rows never depend on which callback is live.
static id SPKDirectInboxMenuWrapConfiguration(id controller, id indexPath, id configuration) {
    if (![configuration isKindOfClass:[UIContextMenuConfiguration class]])
        return configuration;
    return SPKDirectInboxMenuWrapConfigurationForViewModel(SPKDirectInboxMenuViewModelForIndexPath(controller, indexPath),
                                                           configuration);
}

static id SPKDirectInboxContextMenu(id self, SEL _cmd, id indexPath) {
    id configuration = nil;
    @try {
        configuration = SPKDirectOrigInboxContextMenu(self, _cmd, indexPath);
        return SPKDirectInboxMenuWrapConfiguration(self, indexPath, configuration);
    } @catch (NSException *exception) {
        // An exception escaping a context-menu delegate callback cancels the
        // interaction outright, which looks exactly like the menu never opening.
        // Fall back to Instagram's own configuration, untouched.
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Kept Instagram menu after exception=%@ reason=%@",
               exception.name,
               exception.reason);
        return configuration;
    }
}

static id SPKDirectInboxSwiftContextMenu(id self, SEL _cmd, id indexPath) {
    id configuration = nil;
    @try {
        configuration = SPKDirectOrigInboxSwiftContextMenu(self, _cmd, indexPath);
        return SPKDirectInboxMenuWrapConfiguration(self, indexPath, configuration);
    } @catch (NSException *exception) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Kept Instagram menu after exception=%@ reason=%@",
               exception.name,
               exception.reason);
        return configuration;
    }
}

static id SPKDirectInboxLegacyContextMenu(id self, SEL _cmd, id viewModel) {
    id configuration = nil;
    @try {
        configuration = SPKDirectOrigInboxLegacyContextMenu(self, _cmd, viewModel);
        return SPKDirectInboxMenuWrapConfigurationForViewModel(viewModel, configuration);
    } @catch (NSException *exception) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Kept Instagram menu after exception=%@ reason=%@",
               exception.name,
               exception.reason);
        return configuration;
    }
}

static BOOL SPKDirectInboxMenuHookClass(Class inboxClass, SEL selector, IMP replacement, IMP *orig) {
    if (!inboxClass || !class_getInstanceMethod(inboxClass, selector))
        return NO;

    MSHookMessageEx(inboxClass, selector, replacement, orig);
    SPKLog(@"Messages", @"[Sparkle InboxMenu] Installed inbox context menu hook class=%@", NSStringFromClass(inboxClass));
    return YES;
}

void SPKDirectInboxMenuInstallHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKDirectInboxMenuInstallProviderGetterHook();
        SEL selector = NSSelectorFromString(@"networkingCoordinator_contextMenuConfigurationForThreadCellAtIndexPath:");
        BOOL installed = SPKDirectInboxMenuHookClass(SPKDirectObjCInboxClass(),
                                                     selector,
                                                     (IMP)SPKDirectInboxContextMenu,
                                                     (IMP *)&SPKDirectOrigInboxContextMenu);
        installed |= SPKDirectInboxMenuHookClass(SPKDirectSwiftInboxClass(),
                                                 selector,
                                                 (IMP)SPKDirectInboxSwiftContextMenu,
                                                 (IMP *)&SPKDirectOrigInboxSwiftContextMenu);
        if (!installed) {
            // Builds before the networking-coordinator callback existed build the
            // configuration from the view model itself.
            installed = SPKDirectInboxMenuHookClass(SPKDirectObjCInboxClass(),
                                                    NSSelectorFromString(@"_contextMenuConfigurationForThreadCellWithViewModel:"),
                                                    (IMP)SPKDirectInboxLegacyContextMenu,
                                                    (IMP *)&SPKDirectOrigInboxLegacyContextMenu);
        }
        if (!installed)
            SPKLog(@"Messages", @"[Sparkle InboxMenu] No inbox context menu hook installed: no inbox class implements a known menu callback");
    });
}
