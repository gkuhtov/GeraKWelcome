#import "WelcomeViewController.h"
#import "WelcomeConfig.h"
#import "WelcomeAssets.h"
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <math.h>

static UIWindow *s_islandWindow = nil;
static BOOL s_islandMorphingActive = NO;
static NSUInteger s_islandMorphingGeneration = 0;

typedef NS_ENUM(NSUInteger, GeraKIslandScreenFamily) {
    GeraKIslandScreenFamilyDynamicIsland,
    GeraKIslandScreenFamilyClassicNotch,
    GeraKIslandScreenFamilyNoNotch
};

typedef struct {
    GeraKIslandScreenFamily family;
    CGFloat maxExpandedWidth;
    CGFloat topOffset;
} GeraKIslandGeometryProfile;

static NSString *GeraKDeviceModelIdentifier(void) {
    char machine[256] = {0};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        NSString *identifier = [NSString stringWithUTF8String:machine];
        return identifier ?: @"";
    }
    return @"";
}

static GeraKIslandGeometryProfile GeraKProfileForDevice(NSString *model, CGSize screenSize) {
    NSArray<NSString *> *dynamicIslandModels = @[
        @"iPhone15,2", @"iPhone15,3", @"iPhone15,4", @"iPhone15,5",
        @"iPhone16,1", @"iPhone16,2",
        @"iPhone17,1", @"iPhone17,2", @"iPhone17,3", @"iPhone17,4",
        @"iPhone18,1", @"iPhone18,2", @"iPhone18,3", @"iPhone18,4"
    ];
    NSArray<NSString *> *noNotchModels = @[
        @"iPhone6,1", @"iPhone6,2", @"iPhone7,1", @"iPhone7,2",
        @"iPhone8,1", @"iPhone8,2", @"iPhone8,4",
        @"iPhone9,1", @"iPhone9,2", @"iPhone9,3", @"iPhone9,4",
        @"iPhone10,1", @"iPhone10,2", @"iPhone10,4", @"iPhone10,5",
        @"iPhone12,8", @"iPhone14,6"
    ];

    if ([dynamicIslandModels containsObject:model]) {
        return (GeraKIslandGeometryProfile){ GeraKIslandScreenFamilyDynamicIsland, 364.0, 11.0 };
    }
    if ([noNotchModels containsObject:model]) {
        return (GeraKIslandGeometryProfile){ GeraKIslandScreenFamilyNoNotch, 340.0, 11.0 };
    }

    // Для неизвестной модели выбираем ближайший известный профиль по реальным размерам.
    // Размеры не доказывают тип выреза, поэтому модельные идентификаторы выше имеют приоритет.
    CGFloat shortSide = MIN(screenSize.width, screenSize.height);
    CGFloat longSide = MAX(screenSize.width, screenSize.height);
    static const struct {
        CGFloat shortSide;
        CGFloat longSide;
        GeraKIslandScreenFamily family;
        CGFloat maxExpandedWidth;
    } knownProfiles[] = {
        { 320.0, 568.0, GeraKIslandScreenFamilyNoNotch, 340.0 },
        { 375.0, 667.0, GeraKIslandScreenFamilyNoNotch, 340.0 },
        { 414.0, 736.0, GeraKIslandScreenFamilyNoNotch, 340.0 },
        { 360.0, 780.0, GeraKIslandScreenFamilyClassicNotch, 352.0 },
        { 375.0, 812.0, GeraKIslandScreenFamilyClassicNotch, 352.0 },
        { 390.0, 844.0, GeraKIslandScreenFamilyClassicNotch, 352.0 },
        { 414.0, 896.0, GeraKIslandScreenFamilyClassicNotch, 352.0 },
        { 428.0, 926.0, GeraKIslandScreenFamilyClassicNotch, 352.0 },
        { 393.0, 852.0, GeraKIslandScreenFamilyDynamicIsland, 364.0 },
        { 402.0, 874.0, GeraKIslandScreenFamilyDynamicIsland, 364.0 },
        { 430.0, 932.0, GeraKIslandScreenFamilyDynamicIsland, 364.0 },
        { 440.0, 956.0, GeraKIslandScreenFamilyDynamicIsland, 364.0 }
    };

    NSUInteger nearestIndex = 0;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (NSUInteger index = 0; index < sizeof(knownProfiles) / sizeof(knownProfiles[0]); index++) {
        CGFloat widthDistance = fabs(shortSide - knownProfiles[index].shortSide);
        CGFloat heightDistance = fabs(longSide - knownProfiles[index].longSide);
        CGFloat distance = widthDistance + heightDistance;
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearestIndex = index;
        }
    }

    return (GeraKIslandGeometryProfile){
        knownProfiles[nearestIndex].family,
        knownProfiles[nearestIndex].maxExpandedWidth,
        11.0
    };
}

@interface GeraKIslandOverlayController : UIViewController
@property (nonatomic, assign) BOOL shouldHideStatusBar;
@end

@implementation GeraKIslandOverlayController
- (BOOL)prefersStatusBarHidden {
    return self.shouldHideStatusBar;
}
- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    return UIStatusBarAnimationFade;
}
@end

@interface WelcomeViewController ()
@property (nonatomic, strong) UIView *solidBackdropView;
@property (nonatomic, strong) UIView *sceneContainer;
@property (nonatomic, strong) UIImageView *backgroundImageView;
@property (nonatomic, strong) CAGradientLayer *vignetteLayer;
@property (nonatomic, strong) CAEmitterLayer *particleEmitter;
@property (nonatomic, strong) CAEmitterLayer *touchEmitter;

@property (nonatomic, strong) UIView *plaquesLayer;
@property (nonatomic, strong) UIView *headerInfoLayer;
@property (nonatomic, strong) UIView *bottomActionsLayer;

@property (nonatomic, strong) UIImageView *metalLogoView;
@property (nonatomic, strong) CAGradientLayer *shimmerLayer;
@property (nonatomic, strong) UIView *leftPlaqueView;
@property (nonatomic, strong) UIView *rightPlaqueView;

@property (nonatomic, strong) UIControl *continueButtonControl;

@property (nonatomic, assign) BOOL heartbeatActive;
@property (nonatomic, assign) BOOL isDismissing;
@property (nonatomic, copy) void (^standaloneCompletion)(void);
@property (nonatomic, strong) UIImpactFeedbackGenerator *heavyFeedback;
@property (nonatomic, strong) UIImpactFeedbackGenerator *lightFeedback;
@property (nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedback;
@property (nonatomic, strong) UIView *islandMorphingPill;
@property (nonatomic, strong) UILabel *islandMorphingLabel;
@property (nonatomic, assign) BOOL islandMorphingActive;
@property (nonatomic, assign) NSUInteger islandMorphingGeneration;
@end

@implementation WelcomeViewController

#pragma mark - Хелперы декодирования и графики

- (UIImage *)imageFromBase64:(NSString *)base64String {
    if (!base64String || base64String.length == 0) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64String options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) return nil;
    return [UIImage imageWithData:data];
}

- (UIImage *)removeBlackBackground:(UIImage *)image {
    if (!image) return nil;
    CGImageRef rawRef = image.CGImage;
    if (!rawRef) return image;
    
    const CGFloat maskColors[6] = {0, 30, 0, 30, 0, 30};
    CGImageRef maskedRef = CGImageCreateWithMaskingColors(rawRef, maskColors);
    if (!maskedRef) return image;
    
    UIImage *cleanImage = [UIImage imageWithCGImage:maskedRef scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(maskedRef);
    return cleanImage ?: image;
}

- (UIImage *)extractSinglePlaque:(UIImage *)sourceImage {
    if (!sourceImage) return nil;
    CGImageRef cgImg = sourceImage.CGImage;
    if (!cgImg) return sourceImage;
    
    size_t fullW = CGImageGetWidth(cgImg);
    size_t fullH = CGImageGetHeight(cgImg);
    if (fullW == 0 || fullH == 0) return sourceImage;
    
    CGRect cropRect = CGRectMake(0, 0, (CGFloat)fullW * 0.48, (CGFloat)fullH);
    CGImageRef croppedRef = CGImageCreateWithImageInRect(cgImg, cropRect);
    if (!croppedRef) return sourceImage;
    
    UIImage *plaque = [UIImage imageWithCGImage:croppedRef scale:sourceImage.scale orientation:sourceImage.imageOrientation];
    CGImageRelease(croppedRef);
    return plaque ?: sourceImage;
}

- (UIImage *)generateParticleDotImage {
    CGSize size = CGSizeMake(8, 8);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.86 blue:0.60 alpha:0.9].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, size.width, size.height));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UIImage *)generateSparkleTouchImage {
    CGSize size = CGSizeMake(10, 10);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.94 blue:0.75 alpha:1.0].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(1, 1, 8, 8));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

#pragma mark - Жизненный цикл

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.solidBackdropView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.solidBackdropView.backgroundColor = [UIColor blackColor];
    self.solidBackdropView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.solidBackdropView];

    self.heavyFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    self.lightFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    self.selectionFeedback = [[UISelectionFeedbackGenerator alloc] init];
    [self.heavyFeedback prepare];
    [self.lightFeedback prepare];
    [self.selectionFeedback prepare];

    self.sceneContainer = [[UIView alloc] initWithFrame:CGRectInset(self.view.bounds, -45, -45)];
    self.sceneContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.sceneContainer];

    [self setupBackground];
    [self setupVignetteAndParticles];
    [self setupTouchEmitter];
    [self setupHeaderInfo];
    [self setupPlaques];
    [self setupBottomActions];
    [self applyMultiDepthParallax];

    [self prepareInitialEntryStates];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    self.modalPresentationCapturesStatusBarAppearance = YES;
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)beginStandalonePresentationWithCompletion:(void (^)(void))completion {
    self.standaloneCompletion = [completion copy];
    [self startKenBurnsEffect];

    [self executeEntranceChoreographyWithCompletion:^{
        if ([WelcomeConfig sharedConfig].pulseEnabled && !self.isDismissing) {
            [self startHeartbeatCycle];
        }
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopHeartbeatCycle];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.vignetteLayer) {
        self.vignetteLayer.frame = self.sceneContainer.bounds;
    }
}

#pragma mark - Настройка сцены

- (void)setupBackground {
    self.backgroundImageView = [[UIImageView alloc] initWithFrame:self.sceneContainer.bounds];
    self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.clipsToBounds = YES;
    self.backgroundImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImage *bg = [self imageFromBase64:kWelcomeBackgroundBase64] ?: [UIImage imageNamed:@"welcome_bg.jpg"];
    self.backgroundImageView.image = bg;
    [self.sceneContainer addSubview:self.backgroundImageView];
}

- (void)setupVignetteAndParticles {
    self.vignetteLayer = [CAGradientLayer layer];
    self.vignetteLayer.type = kCAGradientLayerRadial;
    self.vignetteLayer.colors = @[
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.25].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.70].CGColor
    ];
    self.vignetteLayer.locations = @[@0.0, @0.60, @1.0];
    self.vignetteLayer.startPoint = CGPointMake(0.5, 0.5);
    self.vignetteLayer.endPoint = CGPointMake(1.0, 1.0);
    self.vignetteLayer.frame = self.sceneContainer.bounds;
    [self.sceneContainer.layer insertSublayer:self.vignetteLayer above:self.backgroundImageView.layer];

    self.particleEmitter = [CAEmitterLayer layer];
    self.particleEmitter.emitterPosition = CGPointMake(self.view.bounds.size.width / 2.0, -20);
    self.particleEmitter.emitterSize = CGSizeMake(self.view.bounds.size.width * 1.2, 10);
    self.particleEmitter.emitterShape = kCAEmitterLayerLine;

    CAEmitterCell *sparkle = [CAEmitterCell emitterCell];
    sparkle.birthRate = 6.0;
    sparkle.lifetime = 14.0;
    sparkle.velocity = 22.0;
    sparkle.velocityRange = 10.0;
    sparkle.emissionLongitude = (CGFloat)M_PI;
    sparkle.emissionRange = (CGFloat)(M_PI / 4.0);
    sparkle.scale = 0.40;
    sparkle.scaleRange = 0.20;
    sparkle.alphaRange = 0.5;
    sparkle.alphaSpeed = -0.06;
    sparkle.spin = 0.4;
    sparkle.spinRange = 0.8;
    sparkle.contents = (id)[self generateParticleDotImage].CGImage;

    self.particleEmitter.emitterCells = @[sparkle];
    [self.sceneContainer.layer insertSublayer:self.particleEmitter above:self.vignetteLayer];
}

#pragma mark - Touch Trail

- (void)setupTouchEmitter {
    self.touchEmitter = [CAEmitterLayer layer];
    self.touchEmitter.emitterShape = kCAEmitterLayerPoint;
    self.touchEmitter.emitterMode = kCAEmitterLayerOutline;
    self.touchEmitter.renderMode = kCAEmitterLayerAdditive;

    CAEmitterCell *spark = [CAEmitterCell emitterCell];
    spark.name = @"touchSpark";
    spark.birthRate = 0;
    spark.lifetime = 0.65;
    spark.velocity = 45.0;
    spark.velocityRange = 25.0;
    spark.emissionRange = (CGFloat)(2.0 * M_PI);
    spark.yAcceleration = 80.0;
    spark.scale = 0.35;
    spark.scaleRange = 0.15;
    spark.scaleSpeed = -0.3;
    spark.alphaSpeed = -1.2;
    spark.contents = (id)[self generateSparkleTouchImage].CGImage;

    self.touchEmitter.emitterCells = @[spark];
    [self.sceneContainer.layer addSublayer:self.touchEmitter];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    UITouch *touch = [touches anyObject];
    CGPoint loc = [touch locationInView:self.sceneContainer];
    self.touchEmitter.emitterPosition = loc;
    [self.touchEmitter setValue:@(45) forKeyPath:@"emitterCells.touchSpark.birthRate"];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *touch = [touches anyObject];
    CGPoint loc = [touch locationInView:self.sceneContainer];
    
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.touchEmitter.emitterPosition = loc;
    [CATransaction commit];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self.touchEmitter setValue:@(0) forKeyPath:@"emitterCells.touchSpark.birthRate"];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self.touchEmitter setValue:@(0) forKeyPath:@"emitterCells.touchSpark.birthRate"];
}

#pragma mark - Разметка UI

- (void)setupHeaderInfo {
    WelcomeConfig *cfg = [WelcomeConfig sharedConfig];
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;

    CGFloat headerW = screenW - 160;
    CGFloat headerH = 240;
    CGFloat startY = screenH * 0.38;

    self.headerInfoLayer = [[UIView alloc] initWithFrame:CGRectMake((screenW - headerW) / 2.0 + 45, startY + 45, headerW, headerH)];
    [self.sceneContainer addSubview:self.headerInfoLayer];

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    glassView.frame = CGRectMake(0, 95, headerW, 120);
    glassView.layer.cornerRadius = 20.0;
    glassView.layer.borderWidth = 0.9;
    glassView.layer.borderColor = [UIColor colorWithRed:0.92 green:0.82 blue:0.65 alpha:0.45].CGColor;
    glassView.layer.allowsEdgeAntialiasing = YES;
    glassView.clipsToBounds = YES;
    glassView.backgroundColor = [UIColor colorWithRed:0.10 green:0.07 blue:0.05 alpha:0.25];
    [self.headerInfoLayer addSubview:glassView];

    UIImage *rawLogo = [self imageFromBase64:kStoreLogoBase64] ?: [UIImage imageNamed:@"store_logo.png"];
    UIImage *cleanLogo = [self removeBlackBackground:rawLogo];

    CGFloat logoW = 230.0;
    CGFloat logoH = 115.0;
    self.metalLogoView = [[UIImageView alloc] initWithFrame:CGRectMake((headerW - logoW) / 2.0, -24, logoW, logoH)];
    self.metalLogoView.contentMode = UIViewContentModeScaleAspectFit;
    self.metalLogoView.image = cleanLogo;
    self.metalLogoView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.metalLogoView.layer.shadowOpacity = 0.70;
    self.metalLogoView.layer.shadowRadius = 18.0;
    self.metalLogoView.layer.shadowOffset = CGSizeMake(0, 10);
    self.metalLogoView.layer.allowsEdgeAntialiasing = YES;
    [self.headerInfoLayer addSubview:self.metalLogoView];

    [self setupLogoShimmerEffect];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(8, 110, headerW - 16, 28)];
    title.text = cfg.headlineText;
    title.textAlignment = NSTextAlignmentCenter;
    UIFont *serifFont = [UIFont fontWithName:@"Georgia-Bold" size:22.0];
    if (!serifFont) serifFont = [UIFont boldSystemFontOfSize:21.5];
    title.font = serifFont;
    title.textColor = [UIColor colorWithRed:0.98 green:0.96 blue:0.93 alpha:1.0];
    title.layer.shadowColor = [UIColor blackColor].CGColor;
    title.layer.shadowOpacity = 0.60;
    title.layer.shadowRadius = 3.0;
    title.layer.shadowOffset = CGSizeMake(0, 1.5);
    [self.headerInfoLayer addSubview:title];

    UILabel *subLine1 = [[UILabel alloc] initWithFrame:CGRectMake(8, 144, headerW - 16, 18)];
    subLine1.text = cfg.sublineText;
    subLine1.textAlignment = NSTextAlignmentCenter;
    subLine1.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    subLine1.textColor = [UIColor colorWithRed:0.88 green:0.83 blue:0.75 alpha:0.90];
    [self.headerInfoLayer addSubview:subLine1];

    UILabel *subLine2 = [[UILabel alloc] initWithFrame:CGRectMake(8, 168, headerW - 16, 22)];
    subLine2.text = cfg.storeSubtitleText;
    subLine2.textAlignment = NSTextAlignmentCenter;
    UIFont *storeFont = [UIFont fontWithName:@"Georgia-Bold" size:15.5];
    if (!storeFont) storeFont = [UIFont boldSystemFontOfSize:15.5];
    subLine2.font = storeFont;
    subLine2.textColor = [UIColor colorWithRed:0.95 green:0.86 blue:0.70 alpha:1.0];
    subLine2.layer.shadowColor = [UIColor blackColor].CGColor;
    subLine2.layer.shadowOpacity = 0.50;
    subLine2.layer.shadowRadius = 2.0;
    subLine2.layer.shadowOffset = CGSizeMake(0, 1.0);
    [self.headerInfoLayer addSubview:subLine2];
}

- (void)setupPlaques {
    WelcomeConfig *cfg = [WelcomeConfig sharedConfig];
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;

    self.plaquesLayer = [[UIView alloc] initWithFrame:self.sceneContainer.bounds];
    [self.sceneContainer addSubview:self.plaquesLayer];

    UIImage *rawPlaques = [self imageFromBase64:kPlaquesBase64] ?: [UIImage imageNamed:@"plaques.png"];
    UIImage *singlePlaque = [self extractSinglePlaque:rawPlaques];

    CGFloat cardCenterY = (screenH * 0.38) + 95 + 60;
    CGFloat plaqueY = cardCenterY - (cfg.plaqueSize.height / 2.0) + 45;

    CGFloat leftX = cfg.leftPlaqueOrigin.x + 45;
    self.leftPlaqueView = [self buildPlaqueViewWithImage:singlePlaque
                                                   text:cfg.leftPlaqueText
                                                  frame:CGRectMake(leftX, plaqueY, cfg.plaqueSize.width, cfg.plaqueSize.height)
                                                isRight:NO];
    [self.plaquesLayer addSubview:self.leftPlaqueView];

    CGFloat rightX = screenW - cfg.rightPlaqueOrigin.x - cfg.plaqueSize.width + 45;
    self.rightPlaqueView = [self buildPlaqueViewWithImage:singlePlaque
                                                    text:cfg.rightPlaqueText
                                                   frame:CGRectMake(rightX, plaqueY, cfg.plaqueSize.width, cfg.plaqueSize.height)
                                                 isRight:YES];
    [self.plaquesLayer addSubview:self.rightPlaqueView];
}

- (UIView *)buildPlaqueViewWithImage:(UIImage *)plaqueImage text:(NSString *)text frame:(CGRect)frame isRight:(BOOL)isRight {
    UIView *container = [[UIView alloc] initWithFrame:frame];
    container.clipsToBounds = NO;
    container.layer.allowsEdgeAntialiasing = YES;

    UIImageView *plaqueBg = [[UIImageView alloc] initWithFrame:container.bounds];
    plaqueBg.contentMode = UIViewContentModeScaleToFill;
    plaqueBg.image = plaqueImage;
    plaqueBg.layer.shadowColor = [UIColor blackColor].CGColor;
    plaqueBg.layer.shadowOpacity = 0.65;
    plaqueBg.layer.shadowRadius = 14.0;
    plaqueBg.layer.shadowOffset = CGSizeMake(isRight ? -5 : 5, 9);
    plaqueBg.layer.allowsEdgeAntialiasing = YES;
    [container addSubview:plaqueBg];

    CGFloat topPadding = 32.0;
    CGFloat bottomPadding = 30.0;
    CGFloat innerW = frame.size.width - 12.0;
    CGFloat innerH = frame.size.height - topPadding - bottomPadding;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(6.0, topPadding, innerW, innerH)];
    lbl.text = text;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 0;
    lbl.font = [UIFont systemFontOfSize:18 weight:UIFontWeightHeavy];
    lbl.textColor = [UIColor colorWithRed:0.20 green:0.11 blue:0.06 alpha:0.98];
    
    lbl.layer.shadowColor = [UIColor colorWithRed:0.98 green:0.93 blue:0.86 alpha:0.85].CGColor;
    lbl.layer.shadowOpacity = 1.0;
    lbl.layer.shadowRadius = 0.6;
    lbl.layer.shadowOffset = CGSizeMake(0, 1.0);
    [container addSubview:lbl];

    return container;
}

- (void)setupLogoShimmerEffect {
    self.shimmerLayer = [CAGradientLayer layer];
    self.shimmerLayer.frame = self.metalLogoView.bounds;
    self.shimmerLayer.startPoint = CGPointMake(0.0, 0.5);
    self.shimmerLayer.endPoint = CGPointMake(1.0, 0.5);
    self.shimmerLayer.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.92 blue:0.75 alpha:0.50].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
    ];
    self.shimmerLayer.locations = @[@0.0, @0.1, @0.2];
    
    CALayer *maskLayer = [CALayer layer];
    maskLayer.contents = (id)self.metalLogoView.image.CGImage;
    maskLayer.frame = self.metalLogoView.bounds;
    maskLayer.contentsGravity = kCAGravityResizeAspect;
    self.shimmerLayer.mask = maskLayer;
    
    [self.metalLogoView.layer addSublayer:self.shimmerLayer];
    self.shimmerLayer.opacity = 0.0;
}

- (void)triggerShimmerSweep {
    self.shimmerLayer.opacity = 1.0;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"locations"];
    animation.fromValue = @[@0.0, @0.05, @0.15];
    animation.toValue = @[@0.85, @0.95, @1.0];
    animation.duration = 0.65;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.shimmerLayer addAnimation:animation forKey:@"welcome.japan.shimmerSweep"];
}

- (void)setupBottomActions {
    WelcomeConfig *cfg = [WelcomeConfig sharedConfig];
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;

    CGFloat actionsW = screenW - 80;
    CGFloat actionsH = 160;
    CGFloat bottomY = screenH * 0.77;

    self.bottomActionsLayer = [[UIView alloc] initWithFrame:CGRectMake((screenW - actionsW) / 2.0 + 45, bottomY + 45, actionsW, actionsH)];
    [self.sceneContainer addSubview:self.bottomActionsLayer];

    CGFloat btnSpacing = 12.0;
    CGFloat btnW = (actionsW - btnSpacing) / 2.0;
    
    UIControl *tgBtn = [self createCardThemedButton:@"Telegram" frame:CGRectMake(0, 0, btnW, 46) fontSize:16.0];
    [tgBtn addTarget:self action:@selector(openTelegram) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomActionsLayer addSubview:tgBtn];

    UIControl *ghBtn = [self createCardThemedButton:@"GitHub" frame:CGRectMake(btnW + btnSpacing, 0, btnW, 46) fontSize:16.0];
    [ghBtn addTarget:self action:@selector(openGithub) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomActionsLayer addSubview:ghBtn];

    self.continueButtonControl = [self createCardThemedButton:cfg.continueButtonText frame:CGRectMake(0, 56, actionsW, 48) fontSize:16.0];
    [self.continueButtonControl addTarget:self action:@selector(dismissScreen) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomActionsLayer addSubview:self.continueButtonControl];

    UIButton *neverBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    neverBtn.frame = CGRectMake(0, 116, actionsW, 20);
    
    UILabel *neverLabel = [[UILabel alloc] initWithFrame:neverBtn.bounds];
    neverLabel.text = cfg.neverShowText;
    neverLabel.textAlignment = NSTextAlignmentCenter;
    neverLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightLight];
    neverLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    neverLabel.userInteractionEnabled = NO;
    [neverBtn addSubview:neverLabel];
    
    [neverBtn addTarget:self action:@selector(neverShowAgain) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomActionsLayer addSubview:neverBtn];
}

- (UIControl *)createCardThemedButton:(NSString *)title frame:(CGRect)frame fontSize:(CGFloat)fontSize {
    UIControl *control = [[UIControl alloc] initWithFrame:frame];
    control.layer.cornerRadius = 14.0;
    control.layer.borderWidth = 0.9;
    control.layer.borderColor = [UIColor colorWithRed:0.92 green:0.82 blue:0.65 alpha:0.48].CGColor;
    control.layer.allowsEdgeAntialiasing = YES;
    control.clipsToBounds = YES;

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    glassView.frame = control.bounds;
    glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glassView.userInteractionEnabled = NO;
    glassView.backgroundColor = [UIColor colorWithRed:0.10 green:0.07 blue:0.05 alpha:0.35];
    [control addSubview:glassView];

    UILabel *label = [[UILabel alloc] initWithFrame:control.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = title;
    label.textAlignment = NSTextAlignmentCenter;
    
    UIFont *storeFont = [UIFont fontWithName:@"Georgia-Bold" size:fontSize];
    if (!storeFont) storeFont = [UIFont boldSystemFontOfSize:fontSize];
    label.font = storeFont;
    label.textColor = [UIColor colorWithRed:0.95 green:0.86 blue:0.70 alpha:1.0];
    
    label.layer.shadowColor = [UIColor blackColor].CGColor;
    label.layer.shadowOpacity = 0.65;
    label.layer.shadowRadius = 2.0;
    label.layer.shadowOffset = CGSizeMake(0, 1.0);
    label.userInteractionEnabled = NO;
    [control addSubview:label];

    [control addTarget:self action:@selector(buttonTouchDownAnim:) forControlEvents:UIControlEventTouchDown];
    [control addTarget:self action:@selector(buttonTouchUpAnim:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    return control;
}

- (void)buttonTouchDownAnim:(UIControl *)btn {
    [self.selectionFeedback prepare];
    [self.selectionFeedback selectionChanged];

    [UIView animateWithDuration:0.10 animations:^{
        btn.transform = CGAffineTransformMakeScale(0.96, 0.96);
        btn.alpha = 0.85;
        btn.layer.borderColor = [UIColor colorWithRed:0.92 green:0.82 blue:0.65 alpha:0.25].CGColor;
    }];
}

- (void)buttonTouchUpAnim:(UIControl *)btn {
    [UIView animateWithDuration:0.18 delay:0.0 usingSpringWithDamping:0.65 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
        btn.transform = CGAffineTransformIdentity;
        btn.alpha = 1.0;
        btn.layer.borderColor = [UIColor colorWithRed:0.92 green:0.82 blue:0.65 alpha:0.48].CGColor;
    } completion:nil];
}

#pragma mark - Кинематографический зум & Хореография

- (void)startKenBurnsEffect {
    [UIView animateWithDuration:18.0
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.backgroundImageView.transform = CGAffineTransformMakeScale(1.08, 1.08);
    } completion:nil];
}

- (void)prepareInitialEntryStates {
    self.backgroundImageView.alpha = 0.0;
    self.vignetteLayer.opacity = 0.0;
    
    self.leftPlaqueView.transform = CGAffineTransformMakeTranslation(0, -60);
    self.leftPlaqueView.alpha = 0.0;

    self.rightPlaqueView.transform = CGAffineTransformMakeTranslation(0, -60);
    self.rightPlaqueView.alpha = 0.0;

    self.headerInfoLayer.transform = CGAffineTransformMakeScale(0.90, 0.90);
    self.headerInfoLayer.alpha = 0.0;

    self.bottomActionsLayer.transform = CGAffineTransformMakeTranslation(0, 45);
    self.bottomActionsLayer.alpha = 0.0;
}

- (void)executeEntranceChoreographyWithCompletion:(void(^)(void))completion {
    [UIView animateWithDuration:0.85 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.backgroundImageView.alpha = 1.0;
        self.vignetteLayer.opacity = 1.0;
    } completion:nil];

    [UIView animateWithDuration:1.1 delay:0.15 usingSpringWithDamping:0.80 initialSpringVelocity:0.4 options:0 animations:^{
        self.leftPlaqueView.transform = CGAffineTransformIdentity;
        self.leftPlaqueView.alpha = 1.0;
        self.rightPlaqueView.transform = CGAffineTransformIdentity;
        self.rightPlaqueView.alpha = 1.0;
    } completion:nil];

    [UIView animateWithDuration:1.0 delay:0.28 usingSpringWithDamping:0.75 initialSpringVelocity:0.6 options:0 animations:^{
        self.headerInfoLayer.transform = CGAffineTransformIdentity;
        self.headerInfoLayer.alpha = 1.0;
    } completion:^(BOOL finished) {
        if (completion) completion();
    }];

    [UIView animateWithDuration:0.9 delay:0.40 usingSpringWithDamping:0.85 initialSpringVelocity:0.3 options:0 animations:^{
        self.bottomActionsLayer.transform = CGAffineTransformIdentity;
        self.bottomActionsLayer.alpha = 1.0;
    } completion:nil];
}

#pragma mark - Бесшовный Dynamic Island Morphing (Pixel-Perfect под камерой)

- (void)handleIslandApplicationWillResignActive {
    [self finishSeamlessIslandMorphing];
}

- (void)handleIslandApplicationDidEnterBackground {
    [self finishSeamlessIslandMorphing];
}

- (void)finishSeamlessIslandMorphing {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishSeamlessIslandMorphing];
        });
        return;
    }

    if (!self.islandMorphingActive) {
        return;
    }

    self.islandMorphingActive = NO;
    s_islandMorphingActive = NO;
    s_islandMorphingGeneration += 1;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [center removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];

    [self.islandMorphingPill.layer removeAllAnimations];
    [self.islandMorphingLabel.layer removeAllAnimations];

    GeraKIslandOverlayController *overlayVC = nil;
    if ([s_islandWindow.rootViewController isKindOfClass:[GeraKIslandOverlayController class]]) {
        overlayVC = (GeraKIslandOverlayController *)s_islandWindow.rootViewController;
        overlayVC.shouldHideStatusBar = NO;
        [overlayVC setNeedsStatusBarAppearanceUpdate];
    }

    s_islandWindow.hidden = YES;
    s_islandWindow.rootViewController = nil;
    s_islandWindow = nil;

    self.islandMorphingPill = nil;
    self.islandMorphingLabel = nil;
    [self.view removeFromSuperview];

    void (^completionBlock)(void) = self.standaloneCompletion;
    self.standaloneCompletion = nil;
    if (completionBlock) {
        completionBlock();
    }
}

- (void)triggerSeamlessIslandMorphing {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self triggerSeamlessIslandMorphing];
        });
        return;
    }

    // Повторный вызов во время активной анимации не ставится в очередь и не перезапускает её.
    if (s_islandMorphingActive) {
        return;
    }

    s_islandMorphingActive = YES;
    self.islandMorphingActive = YES;
    NSUInteger generation = ++s_islandMorphingGeneration;
    self.islandMorphingGeneration = generation;

    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *connectedScene in [UIApplication sharedApplication].connectedScenes) {
            if (connectedScene.activationState == UISceneActivationStateForegroundActive &&
                [connectedScene isKindOfClass:[UIWindowScene class]]) {
                scene = (UIWindowScene *)connectedScene;
                break;
            }
        }
        if (!scene) {
            NSLog(@"[WelcomeToJapan] Показ плашки пропущен: нет активной сцены окна.");
            [self finishSeamlessIslandMorphing];
            return;
        }
        s_islandWindow = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        s_islandWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }

    if (!s_islandWindow) {
        NSLog(@"[WelcomeToJapan] Показ плашки пропущен: не удалось создать окно.");
        [self finishSeamlessIslandMorphing];
        return;
    }

    CGSize screenSize = scene ? scene.coordinateSpace.bounds.size : [UIScreen mainScreen].bounds.size;
    if (screenSize.width <= 0.0 || screenSize.height <= 0.0 ||
        screenSize.width < 180.0 || screenSize.height < 120.0) {
        NSLog(@"[WelcomeToJapan] Показ плашки пропущен: некорректная геометрия экрана.");
        [self finishSeamlessIslandMorphing];
        return;
    }

    GeraKIslandGeometryProfile profile = GeraKProfileForDevice(GeraKDeviceModelIdentifier(), screenSize);
    CGFloat screenW = screenSize.width;
    CGFloat initialW = 125.0;
    CGFloat initialH = 37.0;
    CGFloat initialY = profile.topOffset;
    CGFloat expandedW = MIN(screenW - 24.0, profile.maxExpandedWidth);
    CGFloat expandedH = 74.0;

    if (expandedW < 180.0 || expandedW > screenW || expandedH > screenSize.height - initialY) {
        NSLog(@"[WelcomeToJapan] Показ плашки пропущен: геометрия не подходит.");
        [self finishSeamlessIslandMorphing];
        return;
    }

    CGFloat expandedX = (screenW - expandedW) / 2.0;
    CGFloat initialX = (screenW - initialW) / 2.0;
    CGFloat labelWidth = expandedW - 24.0;

    NSString *message = @"🤝 Чисто по-братски, с тебя шаурма";
    NSString *shortMessage = @"🤝 С тебя шаурма";
    UIFont *(^fontForSize)(CGFloat) = ^UIFont *(CGFloat size) {
        return [UIFont fontWithName:@"Georgia-Bold" size:size] ?: [UIFont boldSystemFontOfSize:size];
    };

    UIFont *messageFont = nil;
    for (CGFloat fontSize = 13.5; fontSize >= 11.0; fontSize -= 0.5) {
        UIFont *candidate = fontForSize(fontSize);
        CGFloat measuredWidth = [message sizeWithAttributes:@{ NSFontAttributeName: candidate }].width;
        if (measuredWidth <= labelWidth) {
            messageFont = candidate;
            break;
        }
    }
    if (!messageFont) {
        message = shortMessage;
        for (CGFloat fontSize = 13.5; fontSize >= 11.0; fontSize -= 0.5) {
            UIFont *candidate = fontForSize(fontSize);
            CGFloat measuredWidth = [message sizeWithAttributes:@{ NSFontAttributeName: candidate }].width;
            if (measuredWidth <= labelWidth) {
                messageFont = candidate;
                break;
            }
        }
    }
    if (!messageFont) {
        NSLog(@"[WelcomeToJapan] Показ плашки пропущен: текст не помещается.");
        [self finishSeamlessIslandMorphing];
        return;
    }

    s_islandWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
    s_islandWindow.backgroundColor = [UIColor clearColor];
    s_islandWindow.userInteractionEnabled = NO;

    GeraKIslandOverlayController *overlayVC = [[GeraKIslandOverlayController alloc] init];
    overlayVC.view.backgroundColor = [UIColor clearColor];
    overlayVC.shouldHideStatusBar = YES;
    s_islandWindow.rootViewController = overlayVC;
    [s_islandWindow makeKeyAndVisible];

    UIView *island = [[UIView alloc] initWithFrame:CGRectMake(initialX, initialY, initialW, initialH)];
    island.backgroundColor = [UIColor blackColor];
    island.layer.cornerRadius = initialH / 2.0;
    island.layer.borderWidth = 0.9;
    island.layer.borderColor = [UIColor colorWithRed:0.95 green:0.86 blue:0.70 alpha:0.85].CGColor;
    island.clipsToBounds = YES;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 46.0, labelWidth, 22.0)];
    label.text = message;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByClipping;
    label.font = messageFont;
    label.textColor = [UIColor colorWithRed:0.98 green:0.95 blue:0.88 alpha:1.0];
    label.alpha = 0.0;
    [island addSubview:label];
    [overlayVC.view addSubview:island];

    self.islandMorphingPill = island;
    self.islandMorphingLabel = label;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handleIslandApplicationWillResignActive)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleIslandApplicationDidEnterBackground)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];

    [UIView animateWithDuration:0.42
                          delay:0.02
         usingSpringWithDamping:0.75
          initialSpringVelocity:0.6
                        options:0
                     animations:^{
        island.frame = CGRectMake(expandedX, initialY, expandedW, expandedH);
        island.layer.cornerRadius = expandedH / 2.0;
    } completion:nil];

    [UIView animateWithDuration:0.20
                          delay:0.18
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        label.alpha = 1.0;
    } completion:^(BOOL finished) {
        if (!finished || !self.islandMorphingActive ||
            self.islandMorphingGeneration != generation ||
            s_islandMorphingGeneration != generation) {
            return;
        }

        [self.selectionFeedback prepare];
        [self.selectionFeedback selectionChanged];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.islandMorphingActive ||
                self.islandMorphingGeneration != generation ||
                s_islandMorphingGeneration != generation) {
                return;
            }

            [UIView animateWithDuration:0.15 animations:^{
                label.alpha = 0.0;
            }];

            [UIView animateWithDuration:0.35
                                  delay:0.05
                 usingSpringWithDamping:0.85
                  initialSpringVelocity:0.3
                                options:0
                             animations:^{
                island.frame = CGRectMake(initialX, initialY, initialW, initialH);
                island.layer.cornerRadius = initialH / 2.0;
                island.layer.borderColor = [UIColor clearColor].CGColor;
            } completion:^(BOOL collapseFinished) {
                if (!self.islandMorphingActive ||
                    self.islandMorphingGeneration != generation ||
                    s_islandMorphingGeneration != generation) {
                    return;
                }
                [self finishSeamlessIslandMorphing];
            }];
        });
    }];
}
#pragma mark - Хореография выхода (Exit Choreography)

- (void)animateDismissalWithCompletion:(void(^)(void))completion {
    if (self.isDismissing) return;
    self.isDismissing = YES;

    [self stopHeartbeatCycle];

    [self.lightFeedback prepare];
    if (@available(iOS 13.0, *)) {
        [self.lightFeedback impactOccurredWithIntensity:0.65];
    } else {
        [self.lightFeedback impactOccurred];
    }

    self.view.userInteractionEnabled = NO;

    [UIView animateWithDuration:0.20 animations:^{
        self.sceneContainer.alpha = 0.0;
        self.solidBackdropView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.view.hidden = YES;
        if (completion) completion();
        [self triggerSeamlessIslandMorphing];
    }];
}

#pragma mark - Усиленный тактовый кардио-движок + Блик

- (void)startHeartbeatCycle {
    if (self.heartbeatActive || self.isDismissing) return;
    self.heartbeatActive = YES;
    [self performSynchronizedPulseStep];
}

- (void)performSynchronizedPulseStep {
    if (!self.heartbeatActive || self.isDismissing) return;

    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pulse.values = @[@1.0, @1.08, @1.02, @1.05, @1.0];
    pulse.keyTimes = @[@0.0, @0.10, @0.18, @0.28, @1.0];
    pulse.duration = 1.25;
    pulse.removedOnCompletion = YES;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.metalLogoView.layer addAnimation:pulse forKey:@"welcome.japan.singleBeat"];

    [self triggerShimmerSweep];

    [self.heavyFeedback prepare];
    if (@available(iOS 13.0, *)) {
        [self.heavyFeedback impactOccurredWithIntensity:1.0];
    } else {
        [self.heavyFeedback impactOccurred];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.heartbeatActive || self.isDismissing) return;
        [self.lightFeedback prepare];
        if (@available(iOS 13.0, *)) {
            [self.lightFeedback impactOccurredWithIntensity:0.85];
        } else {
            [self.lightFeedback impactOccurred];
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.heartbeatActive || self.isDismissing) return;
        [self.heavyFeedback prepare];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.heartbeatActive && !self.isDismissing) {
            [self performSynchronizedPulseStep];
        }
    });
}

- (void)stopHeartbeatCycle {
    self.heartbeatActive = NO;
    [self.metalLogoView.layer removeAnimationForKey:@"welcome.japan.singleBeat"];
    [self.shimmerLayer removeAnimationForKey:@"welcome.japan.shimmerSweep"];
}

- (void)addParallaxEffectToView:(UIView *)target depth:(CGFloat)depth {
    UIInterpolatingMotionEffect *x = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.x" type:UIInterpolatingMotionEffectTypeTiltAlongHorizontalAxis];
    x.minimumRelativeValue = @(-depth);
    x.maximumRelativeValue = @(depth);

    UIInterpolatingMotionEffect *y = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.y" type:UIInterpolatingMotionEffectTypeTiltAlongVerticalAxis];
    y.minimumRelativeValue = @(-depth);
    y.maximumRelativeValue = @(depth);

    UIMotionEffectGroup *group = [UIMotionEffectGroup new];
    group.motionEffects = @[x, y];
    [target addMotionEffect:group];
}

- (void)applyMultiDepthParallax {
    WelcomeConfig *cfg = [WelcomeConfig sharedConfig];
    [self addParallaxEffectToView:self.backgroundImageView depth:6.0];
    [self addParallaxEffectToView:self.plaquesLayer depth:cfg.plaqueParallaxDepth];
    [self addParallaxEffectToView:self.headerInfoLayer depth:26.0];
    [self addParallaxEffectToView:self.metalLogoView depth:48.0];
    [self addParallaxEffectToView:self.bottomActionsLayer depth:20.0];
}

- (void)openTelegram {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[WelcomeConfig sharedConfig].telegramUrl] options:@{} completionHandler:nil];
}

- (void)openGithub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[WelcomeConfig sharedConfig].githubUrl] options:@{} completionHandler:nil];
}

- (void)dismissScreen {
    [self animateDismissalWithCompletion:nil];
}

- (void)neverShowAgain {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"com.gkuhtov.WelcomeToJapan.hasSeenWelcome"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self animateDismissalWithCompletion:nil];
}

@end
