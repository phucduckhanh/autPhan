// AutoTap — tweak tự lặp thao tác chạm (autoclick) để học hỏi/cá nhân hoá.
// Mã viết mới; cấu trúc rút ra từ việc nghiên cứu AutoClicker_v1.1.dylib:
//   Cấu hình (NSUserDefaults) -> Engine (bộ hẹn giờ) -> Touch (IOHID) -> Overlay (dock + chấm).
// Chưa biên dịch/thử trên thiết bị. Cần Theos + iOS SDK, máy đã jailbreak hoặc nạp dylib được.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#pragma mark - 1. Touch: bơm sự kiện chạm qua IOHID (nạp động, không cần header riêng)

typedef void *HIDEvt;
static HIDEvt (*fnParent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                          double, double, double, double, double, Boolean, Boolean, uint32_t);
static HIDEvt (*fnFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                          double, double, double, double, double, Boolean, Boolean, uint32_t);
static void (*fnAppend)(HIDEvt, HIDEvt);
static void (*fnSetInt)(HIDEvt, uint32_t, int64_t);
static void (*fnSender)(HIDEvt, uint64_t);

@interface UIApplication (ATPrivate)
- (void)_enqueueHIDEvent:(HIDEvt)event;
@end

static BOOL ATHIDReady(void) {
    static BOOL ok; static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) return;
        fnParent = dlsym(h, "IOHIDEventCreateDigitizerEvent");
        fnFinger = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        fnAppend = dlsym(h, "IOHIDEventAppendEvent");
        fnSetInt = dlsym(h, "IOHIDEventSetIntegerValue");
        fnSender = dlsym(h, "IOHIDEventSetSenderID");
        ok = fnParent && fnFinger && fnAppend && fnSetInt && fnSender;
    });
    return ok;
}

// n = toạ độ chuẩn hoá (0..1) theo màn hình dọc gốc. down=YES: chạm xuống, NO: nhả ra.
static void ATTouch(CGPoint n, BOOL down) {
    if (!ATHIDReady()) return;
    uint64_t ts = mach_absolute_time();
    const uint32_t mask = 0x3;                       // range | touch
    HIDEvt parent = fnParent(kCFAllocatorDefault, ts, 3 /*hand*/, 0, 0, mask, 0,
                             0, 0, 0, 0, 0, down, down, 0);
    HIDEvt finger = fnFinger(kCFAllocatorDefault, ts, 1, 2, mask,
                             n.x, n.y, 0, down ? 1.0 : 0.0, 0, down, down, 0);
    fnAppend(parent, finger);
    fnSetInt(parent, 0xb0019, 1);                    // IsDisplayIntegrated
    fnSender(parent, 0x8000000817319372ULL);
    [[UIApplication sharedApplication] _enqueueHIDEvent:parent];
    CFRelease(finger); CFRelease(parent);
}

#pragma mark - 2. Config

static NSString *const kCfgKey = @"AutoTap.cfg.v1";

@interface ATConfig : NSObject
@property double intervalMs, holdMs, jitterPx, randomPct, stopAfterSec;
@property (nonatomic) NSMutableArray<NSValue *> *points;    // CGPoint chuẩn hoá theo vùng overlay
+ (instancetype)shared;
- (void)save;
@end

@implementation ATConfig
+ (instancetype)shared { static ATConfig *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [ATConfig new]; [c load]; }); return c; }
- (void)load {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kCfgKey] ?: @{};
    _intervalMs = d[@"iv"] ? [d[@"iv"] doubleValue] : 200;
    _holdMs = d[@"hold"] ? [d[@"hold"] doubleValue] : 30;
    _jitterPx = d[@"jit"] ? [d[@"jit"] doubleValue] : 2;
    _randomPct = d[@"rnd"] ? [d[@"rnd"] doubleValue] : 15;
    _stopAfterSec = [d[@"stop"] doubleValue];                 // 0 = không tự dừng
    _points = [NSMutableArray array];
    for (NSArray *p in d[@"pts"]) [_points addObject:[NSValue valueWithCGPoint:CGPointMake([p[0] doubleValue], [p[1] doubleValue])]];
}
- (void)save {
    NSMutableArray *pts = [NSMutableArray array];
    for (NSValue *v in _points) { CGPoint p = v.CGPointValue; [pts addObject:@[@(p.x), @(p.y)]]; }
    [[NSUserDefaults standardUserDefaults] setObject:@{@"iv":@(_intervalMs), @"hold":@(_holdMs), @"jit":@(_jitterPx),
        @"rnd":@(_randomPct), @"stop":@(_stopAfterSec), @"pts":pts} forKey:kCfgKey];
}
@end

#pragma mark - 3. Engine

@interface ATEngine : NSObject
@property (readonly) BOOL running;
@property (copy) void (^onChange)(void);
@property (copy) CGPoint (^resolve)(NSUInteger idx, double jitterPx);   // trả toạ độ chuẩn hoá màn hình
+ (instancetype)shared;
- (void)toggle;
@end

@implementation ATEngine { NSUInteger _seq, _gen; CFTimeInterval _endAt; }
+ (instancetype)shared { static ATEngine *e; static dispatch_once_t o; dispatch_once(&o, ^{ e = [ATEngine new]; }); return e; }

- (void)toggle {
    if (_running) { _running = NO; _gen++; }
    else if (ATConfig.shared.points.count) {
        _running = YES; _seq = 0; _gen++;
        double s = ATConfig.shared.stopAfterSec;
        _endAt = s > 0 ? CACurrentMediaTime() + s : 0;
        [self scheduleNext];
    }
    if (_onChange) _onChange();
}

- (void)scheduleNext {
    ATConfig *c = ATConfig.shared;
    double f = 1 + (((double)arc4random() / UINT32_MAX) * 2 - 1) * c.randomPct / 100.0;
    double ms = MAX(10.0, c.intervalMs * f);
    NSUInteger g = _gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (g != self->_gen || !self->_running) return;
        if (self->_endAt && CACurrentMediaTime() >= self->_endAt) { [self toggle]; return; }
        [self fireWithMaxHold:ms * 0.8];
        [self scheduleNext];
    });
}

- (void)fireWithMaxHold:(double)maxHold {
    ATConfig *c = ATConfig.shared;
    if (!c.points.count || !_resolve) return;
    CGPoint n = _resolve(_seq++ % c.points.count, c.jitterPx);
    ATTouch(n, YES);
    double hold = MIN(MAX(1.0, c.holdMs), maxHold);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ ATTouch(n, NO); });
}
@end

#pragma mark - 4. Overlay UI

@interface ATWindow : UIWindow @end
@implementation ATWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {          // chỉ nhận chạm trên dock/chấm/alert; còn lại xuyên xuống app
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

@interface ATMarker : UILabel @property NSUInteger idx; @end
@implementation ATMarker @end

@interface ATOverlay : NSObject
+ (void)install;
@end

@implementation ATOverlay
static ATWindow *gWin; static UIView *gDock; static UIButton *gRun;
static NSMutableArray<ATMarker *> *gMarkers;

+ (UIView *)root { return gWin.rootViewController.view; }

+ (void)install {
    if (gWin) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    if (!scene) return;
    gWin = [[ATWindow alloc] initWithWindowScene:scene];
    gWin.windowLevel = UIWindowLevelAlert + 100;
    gWin.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.clearColor;
    gWin.rootViewController = vc; gWin.hidden = NO;
    gMarkers = [NSMutableArray array];
    [self buildDock];
    for (NSUInteger i = 0; i < ATConfig.shared.points.count; i++) [self addMarkerAt:i];
    ATEngine.shared.resolve = ^CGPoint(NSUInteger i, double jit) { return [self screenNormForMarker:gMarkers[i] jitter:jit]; };
    ATEngine.shared.onChange = ^{ [self refreshState]; };
}

+ (CGPoint)screenNormForMarker:(ATMarker *)m jitter:(double)j {
    CGPoint c = m.center;
    c.x += ((double)arc4random() / UINT32_MAX * 2 - 1) * j;
    c.y += ((double)arc4random() / UINT32_MAX * 2 - 1) * j;
    id<UICoordinateSpace> fixed = gWin.screen.fixedCoordinateSpace;
    CGPoint p = [[self root] convertPoint:c toCoordinateSpace:fixed];
    return CGPointMake(p.x / fixed.bounds.size.width, p.y / fixed.bounds.size.height);
}

+ (UIButton *)btn:(NSString *)sym action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sym] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor; b.frame = CGRectMake(0, 0, 40, 40);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside]; return b;
}

+ (void)buildDock {
    gDock = [[UIView alloc] initWithFrame:CGRectMake(20, 120, 4 * 40 + 16, 48)];
    gDock.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85]; gDock.layer.cornerRadius = 24;
    gRun = [self btn:@"play.fill" action:@selector(onRun)];
    NSArray *bs = @[gRun, [self btn:@"plus" action:@selector(onAdd)], [self btn:@"slider.horizontal.3" action:@selector(onSettings)],
                    [self btn:@"trash" action:@selector(onClear)]];
    for (NSUInteger i = 0; i < bs.count; i++) { UIButton *b = bs[i]; b.center = CGPointMake(28 + i * 40, 24); [gDock addSubview:b]; }
    [gDock addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanDock:)]];
    [[self root] addSubview:gDock];
}

+ (void)onPanDock:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:[self root]]; g.view.center = CGPointMake(g.view.center.x + t.x, g.view.center.y + t.y);
    [g setTranslation:CGPointZero inView:[self root]];
}

+ (void)onRun { [ATEngine.shared toggle]; }

+ (void)refreshState {
    BOOL r = ATEngine.shared.running;
    [gRun setImage:[UIImage systemImageNamed:r ? @"stop.fill" : @"play.fill"] forState:UIControlStateNormal];
    for (ATMarker *m in gMarkers) { m.userInteractionEnabled = !r; m.alpha = r ? 0.15 : 1; }   // để chạm xuyên qua chấm khi chạy
}

+ (void)onAdd {
    [ATConfig.shared.points addObject:[NSValue valueWithCGPoint:CGPointMake(0.5, 0.5)]];
    [self addMarkerAt:ATConfig.shared.points.count - 1]; [ATConfig.shared save];
}

+ (void)onClear {
    for (ATMarker *m in gMarkers) [m removeFromSuperview];
    [gMarkers removeAllObjects]; [ATConfig.shared.points removeAllObjects]; [ATConfig.shared save];
}

+ (void)addMarkerAt:(NSUInteger)i {
    CGSize s = [self root].bounds.size; CGPoint n = [ATConfig.shared.points[i] CGPointValue];
    ATMarker *m = [[ATMarker alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    m.idx = i; m.text = [NSString stringWithFormat:@"%lu", (unsigned long)i + 1]; m.textAlignment = NSTextAlignmentCenter;
    m.textColor = UIColor.whiteColor; m.font = [UIFont boldSystemFontOfSize:16];
    m.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:1 alpha:0.55];
    m.layer.cornerRadius = 22; m.layer.masksToBounds = YES; m.layer.borderWidth = 2; m.layer.borderColor = UIColor.whiteColor.CGColor;
    m.center = CGPointMake(n.x * s.width, n.y * s.height); m.userInteractionEnabled = YES;
    [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanMarker:)]];
    [[self root] addSubview:m]; [gMarkers addObject:m];
}

+ (void)onPanMarker:(UIPanGestureRecognizer *)g {
    ATMarker *m = (ATMarker *)g.view; CGPoint t = [g translationInView:[self root]];
    m.center = CGPointMake(m.center.x + t.x, m.center.y + t.y); [g setTranslation:CGPointZero inView:[self root]];
    if (g.state == UIGestureRecognizerStateEnded) {
        CGSize s = [self root].bounds.size;
        ATConfig.shared.points[m.idx] = [NSValue valueWithCGPoint:CGPointMake(m.center.x / s.width, m.center.y / s.height)];
        [ATConfig.shared save];
    }
}

+ (void)onSettings {
    ATConfig *c = ATConfig.shared;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"AutoTap" message:@"Khoảng cách / Giữ (ms) / Jitter (px) / Ngẫu nhiên (%) / Tự dừng (giây, 0=tắt)" preferredStyle:UIAlertControllerStyleAlert];
    NSArray *ph = @[@"Khoảng cách (ms)", @"Giữ (ms)", @"Jitter (px)", @"Ngẫu nhiên (%)", @"Tự dừng (giây)"];
    NSArray *vals = @[@(c.intervalMs), @(c.holdMs), @(c.jitterPx), @(c.randomPct), @(c.stopAfterSec)];
    for (int i = 0; i < 5; i++) [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = ph[i]; t.text = [NSString stringWithFormat:@"%g", [vals[i] doubleValue]]; t.keyboardType = UIKeyboardTypeDecimalPad; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        c.intervalMs = MAX(10, a.textFields[0].text.doubleValue); c.holdMs = MAX(1, a.textFields[1].text.doubleValue);
        c.jitterPx = MAX(0, a.textFields[2].text.doubleValue); c.randomPct = MIN(90, MAX(0, a.textFields[3].text.doubleValue));
        c.stopAfterSec = MAX(0, a.textFields[4].text.doubleValue); [c save]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [gWin.rootViewController presentViewController:a animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void ATInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *n) { [ATOverlay install]; }];
}
