#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <math.h>

// Loaded only for this launch. The installed game and PlayTools stay unchanged.
static NSMutableDictionary *contacts;
static NSString *secret;
static NSUInteger delivered, maxDelivered;
static NSTimeInterval lastInput;
static void (*originalSendEvent)(id, SEL, UIEvent *);

static void observeEvent(id self, SEL cmd, UIEvent *event) {
    NSUInteger count = 0;
    for (UITouch *t in event.allTouches) {
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) count++;
    }
    if (count && contacts.count) {
        delivered++;
        maxDelivered = MAX(maxDelivered, count);
    }
    originalSendEvent(self, cmd, event);
}

static UIWindow *gameWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow && !w.hidden && w.rootViewController) return w;
        }
    }
    return nil;
}

static NSInteger inject(NSInteger tid, CGPoint p, UITouchPhase phase, UIWindow *w, UIView *v) {
    Class cls = NSClassFromString(@"PTFakeMetaTouch");
    SEL sel = NSSelectorFromString(@"fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:");
    return ((NSInteger (*)(id, SEL, NSInteger, CGPoint, UITouchPhase, UIWindow *, UIView *))objc_msgSend)(cls, sel, tid, p, phase, w, v);
}

static void releaseAll(void) {
    for (NSDictionary *c in contacts.allValues) {
        inject([c[@"tid"] integerValue], CGPointFromString(c[@"point"]), UITouchPhaseCancelled, c[@"window"], c[@"view"]);
    }
    [contacts removeAllObjects];
}

static NSDictionary *handle(NSDictionary *req) {
    if (![req isKindOfClass:NSDictionary.class] || ![req[@"token"] isEqual:secret]) return @{@"error": @"unauthorized"};
    Class cls = NSClassFromString(@"PTFakeMetaTouch");
    SEL sel = NSSelectorFromString(@"fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:");
    if (![cls respondsToSelector:sel]) return @{@"error": @"PlayTools touch API unavailable"};
    UIWindow *w = gameWindow();
    if ([req[@"op"] isEqual:@"keepalive"]) lastInput = NSProcessInfo.processInfo.systemUptime;
    if ([req[@"op"] isEqual:@"reset"]) releaseAll();
    if ([req[@"op"] isEqual:@"touch"]) {
        if (!w) return @{@"error": @"Game window not ready"};
        id events = req[@"events"];
        if (![events isKindOfClass:NSArray.class] || [events count] > 32) return @{@"error": @"Invalid batch"};
        // Validate the complete batch before changing any live contact.
        for (id e in events) {
            if (![e isKindOfClass:NSDictionary.class] || ![e[@"id"] isKindOfClass:NSNumber.class] || ![e[@"x"] isKindOfClass:NSNumber.class] || ![e[@"y"] isKindOfClass:NSNumber.class]) return @{@"error": @"Invalid contact"};
            double x = [e[@"x"] doubleValue], y = [e[@"y"] doubleValue];
            NSInteger cid = [e[@"id"] integerValue];
            if (cid < 0 || cid > 9 || !isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1 || ![@[@"down", @"move", @"up", @"cancel"] containsObject:e[@"phase"]]) return @{@"error": @"Invalid contact range"};
        }
        lastInput = NSProcessInfo.processInfo.systemUptime;
        for (NSDictionary *e in events) {
            NSNumber *cid = e[@"id"];
            NSString *phase = e[@"phase"];
            NSMutableDictionary *c = contacts[cid];
            CGPoint p = CGPointMake([e[@"x"] doubleValue] * w.bounds.size.width, [e[@"y"] doubleValue] * w.bounds.size.height);
            if ([phase isEqual:@"down"]) {
                if (c) continue;
                UIView *view = [w hitTest:p withEvent:nil];
                if (!view) continue;
                NSInteger tid = inject(-1, p, UITouchPhaseBegan, w, view);
                if (tid >= 0) contacts[cid] = [@{@"tid": @(tid), @"point": NSStringFromCGPoint(p), @"window": w, @"view": view} mutableCopy];
            } else if (c) {
                UITouchPhase nativePhase = [phase isEqual:@"move"] ? UITouchPhaseMoved : ([phase isEqual:@"up"] ? UITouchPhaseEnded : UITouchPhaseCancelled);
                inject([c[@"tid"] integerValue], p, nativePhase, c[@"window"], c[@"view"]);
                c[@"point"] = NSStringFromCGPoint(p);
                if (nativePhase != UITouchPhaseMoved) [contacts removeObjectForKey:cid];
            }
        }
    }
    NSMutableArray *points = [NSMutableArray array];
    for (NSNumber *cid in contacts) [points addObject:@{@"id":cid, @"touchId":contacts[cid][@"tid"], @"point":contacts[cid][@"point"]}];
    return @{@"ok":@YES, @"pid":@(getpid()), @"windowReady":@(w != nil), @"width":@(w.bounds.size.width), @"height":@(w.bounds.size.height), @"active":points, @"deliveredEvents":@(delivered), @"maxSimultaneousTouches":@(maxDelivered)};
}

__attribute__((constructor)) static void startBridge(void) {
    const char *value = getenv("PLAYTOUCH_TOKEN");
    if (!value || strlen(value) < 32) return;
    secret = [[NSString alloc] initWithUTF8String:value];
    dispatch_async(dispatch_get_main_queue(), ^{
        contacts = [NSMutableDictionary dictionary];
        Method method = class_getInstanceMethod(UIApplication.class, @selector(sendEvent:));
        originalSendEvent = (void *)method_getImplementation(method);
        method_setImplementation(method, (IMP)observeEvent);
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            if (contacts.count && NSProcessInfo.processInfo.systemUptime - lastInput > 3) releaseAll();
        }];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        int server = socket(AF_INET, SOCK_STREAM, 0), yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in addr = {.sin_len=sizeof(addr), .sin_family=AF_INET, .sin_port=htons(19471)};
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        if (bind(server, (void *)&addr, sizeof(addr)) || listen(server, 4)) { close(server); return; }
        fprintf(stderr, "[PlayTouch] Native touch bridge listening on loopback:19471\n");
        while (1) {
            int client = accept(server, NULL, NULL);
            if (client < 0) break;
            struct timeval timeout = {.tv_sec=2};
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            @autoreleasepool {
                char buf[16385]; size_t used = 0;
                while (used < sizeof(buf)-1) {
                    ssize_t n = recv(client, buf+used, sizeof(buf)-1-used, 0);
                    if (n <= 0) break;
                    used += n;
                    if (memchr(buf, '\n', used)) break;
                }
                NSData *data = [NSData dataWithBytes:buf length:used];
                id req = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                __block NSDictionary *reply;
                dispatch_sync(dispatch_get_main_queue(), ^{ reply = handle(req); });
                NSData *out = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
                const char *bytes = out.bytes; size_t sent = 0;
                while (sent < out.length) { ssize_t n = send(client, bytes+sent, out.length-sent, 0); if (n <= 0) break; sent += n; }
            }
            close(client);
        }
        close(server);
    });
}
