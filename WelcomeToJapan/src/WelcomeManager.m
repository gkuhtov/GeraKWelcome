#import "WelcomeManager.h"
#import "WelcomeViewController.h"

@interface WelcomeManager ()
@property (nonatomic, assign) BOOL isPresenting;
@property (nonatomic, strong) WelcomeViewController *activeWelcomeController;
@end

@implementation WelcomeManager

static BOOL sessionColdLaunchHandled = NO;

+ (instancetype)sharedManager {
    static WelcomeManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (BOOL)hasSeenWelcome {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"com.gkuhtov.WelcomeToJapan.hasSeenWelcome"];
}

- (void)startWelcomeIfNeeded {
    // 1. Игнорируем, если уже обрабатывали в этой сессии процесса
    if (sessionColdLaunchHandled || self.isPresenting || [self hasSeenWelcome]) {
        return;
    }

    // 2. Сразу отписываемся от пробуждений приложения (чтобы не срабатывало при выходе из фона)
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];

    [self presentWelcomeWithFastRetry:0];
}

- (void)presentWelcomeWithFastRetry:(NSInteger)retryCount {
    if (sessionColdLaunchHandled || self.isPresenting || [self hasSeenWelcome]) {
        return;
    }

    UIWindow *keyWindow = [self resolveKeyWindow];
    UIViewController *rootVC = keyWindow.rootViewController;

    if (keyWindow && rootVC && !self.activeWelcomeController) {
        // Фиксируем факт показа в памяти текущего процесса.
        sessionColdLaunchHandled = YES;
        self.isPresenting = YES;

        WelcomeViewController *welcomeVC = [[WelcomeViewController alloc] init];
        self.activeWelcomeController = welcomeVC;

        UIView *welcomeView = welcomeVC.view;
        welcomeView.frame = keyWindow.bounds;
        welcomeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [keyWindow addSubview:welcomeView];

        [welcomeVC beginStandalonePresentationWithCompletion:^{
            self.activeWelcomeController = nil;
            self.isPresenting = NO;
        }];
        return;
    }

    // Микро-проверка каждые 30 мс до монтирования контроллера
    if (retryCount < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self presentWelcomeWithFastRetry:retryCount + 1];
        });
    } else {
        sessionColdLaunchHandled = YES;
    }
}

- (UIWindow *)resolveKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) return w;
    }
    return [UIApplication sharedApplication].delegate.window;
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)vc {
    if (!vc) return nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return [self topViewControllerFrom:((UINavigationController *)vc).visibleViewController];
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return [self topViewControllerFrom:((UITabBarController *)vc).selectedViewController];
    }
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        return [self topViewControllerFrom:vc.presentedViewController];
    }
    return vc;
}

@end
