//
//  Buggy.m
//  BuggyDemo
//
//  Created by sgcy on 2018/10/8.
//  Copyright © 2018年 sgcy. All rights reserved.
//

#import "Buggy.h"

#import <FBAllocationTracker/FBAllocationTracker.h>
#import <Sentry/Sentry.h>
#import <Sentry/SentryBreadcrumbTracker.h>
#import <CocoaLumberjack/CocoaLumberjack.h>
#import "LSSafeProtector.h"
#import "CommonEventTracker.h"
#import "MemoryTracker.h"
#import "UIBlockTracker.h"
#import "BSBacktraceLogger.h"

#if DEBUG
static const DDLogLevel ddLogLevel = DDLogLevelVerbose;
#else
static const DDLogLevel ddLogLevel = DDLogLevelWarning;
#endif

@interface Buggy()

@property (nonatomic,strong) DDFileLogger *logger;
@property (nonatomic,strong) CommonEventTracker *eventTracker;
@end

@implementation Buggy

+ (instancetype)sharedInstance
{
    static Buggy *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ 
        sharedInstance = [[Buggy alloc] init];
        [[FBAllocationTrackerManager sharedManager] startTrackingAllocations];
        DDFileLogger *fileLogger = [[DDFileLogger alloc] init]; // File Logger
        [DDLog addLogger:fileLogger];
        sharedInstance.logger = fileLogger;
        sharedInstance.eventTracker = [[CommonEventTracker alloc] init];
        [MemoryTracker sharedInstance];
        [[UIBlockTracker sharedInstance] start];
    });
    return sharedInstance;
}

+ (void)installWithSentryToken:(NSString *)sentryToken
{
    [[self sharedInstance] installCrashHandlerWithSentryToken:sentryToken];
}

- (void)installCrashHandlerWithSentryToken:(NSString *)sentryToken
{
    NSError *error = nil;
    SentryClient *client = [[SentryClient alloc] initWithDsn:sentryToken didFailWithError:&error];
    SentryClient.sharedClient = client;
    SentryClient.sharedClient.extra = [self queryDDLog];
    [SentryClient.sharedClient startCrashHandlerWithError:&error];
    if (nil != error) {
        NSLog(@"%@", error);
    }
    [LSSafeProtector openSafeProtectorWithIsDebug:NO block:^(NSException *exception, LSSafeProtectorCrashType crashType) {
        
    }];
}

- (NSDictionary *)queryDDLog
{
    NSInteger segmentLength = 17;//kb
    NSInteger totalLength = 40;
    NSInteger segmentCount = totalLength / segmentLength;
    NSArray<DDLogFileInfo *> *logInfos = self.logger.logFileManager.sortedLogFileInfos;
    if (logInfos.count < 1) {
        return @{};
    }
    DDLogFileInfo *lastInfo = logInfos.firstObject;
    NSFileHandle *fileHandler = [NSFileHandle fileHandleForReadingAtPath:lastInfo.filePath];
    NSData *lastData = [fileHandler readDataToEndOfFile];
    if (logInfos.count >= 2 && lastInfo.fileSize < 1024 * totalLength) {
        DDLogFileInfo *recentInfo = [logInfos objectAtIndex:1];
        NSFileHandle *fileHandler = [NSFileHandle fileHandleForReadingAtPath:recentInfo.filePath];
        NSMutableData *recentData = [[fileHandler readDataToEndOfFile] mutableCopy];
        [recentData appendData:lastData];
        lastData = [recentData copy];
    }
    NSString *logStr = [[NSString alloc] initWithData:lastData encoding:NSUTF8StringEncoding];
    if (logStr.length > 1024 * totalLength) {
        logStr = [logStr substringFromIndex:logStr.length - 1024 * totalLength];
    }
    NSMutableDictionary *dic = [[NSMutableDictionary alloc] init];
    NSInteger residual = logStr.length % (segmentLength * 1024);
    if (residual > 0) {
        segmentCount = logStr.length / (segmentLength * 1024) + 1;
    }
    for (int i = 0 ; i < segmentCount ; i++) {
        NSString *key = [NSString stringWithFormat:@"log%d",i];
        NSInteger loc = i * segmentLength * 1024;
        NSInteger length = segmentLength * 1024;
        if (logStr.length < loc + length) {
            length = residual;
        }
        NSString *value = [logStr substringWithRange:NSMakeRange(loc, length)];
        [dic setObject:value forKey:key];
    }
    return [dic copy];
}

+ (void)reportError:(NSError *)error
{
    [self reportError:error withStackFrame:NO];
}

+ (void)reportError:(NSError *)error withStackFrame:(BOOL)withStackFrame
{
    SentryEvent *event = [self generateEventWithError:error];
    if (withStackFrame) {
        [[SentryClient sharedClient] snapshotStacktrace:^{
            [[SentryClient sharedClient] appendStacktraceToEvent:event];
            [[SentryClient sharedClient] sendEvent:event withCompletionHandler:^(NSError * _Nullable error) {
            }];
        }];
    }else{
        [[SentryClient sharedClient] sendEvent:event withCompletionHandler:^(NSError * _Nullable error) {
        }];
    }
}

+ (void)reportErrorWithMainStackFrame:(NSError *)error
{
    SentryEvent *event = [self generateEventWithError:error];
    NSArray *mainStackFrames = [BSBacktraceLogger bs_backtraceOfMainThread];
    SentryThread *thread = [[SentryThread alloc] initWithThreadId:@(0)];
    SentryStacktrace *stackTrace = [[SentryStacktrace alloc] initWithFrames:mainStackFrames registers:@{}];
    thread.stacktrace = stackTrace;
    event.threads = @[thread];
    [[SentryClient sharedClient] sendEvent:event withCompletionHandler:^(NSError * _Nullable error) {
    }];
}


+ (SentryEvent *)generateEventWithError:(NSError *)error
{
    SentryEvent *event = [[SentryEvent alloc] initWithLevel:kSentrySeverityError];
    event.message = error.localizedDescription;
    event.extra = [[self sharedInstance] queryDDLog];
    if (error.userInfo[@"extra"]) {
        NSMutableDictionary *mutableDic = [[NSMutableDictionary alloc] initWithDictionary:event.extra];
        mutableDic[@"extra"] = error.userInfo[@"extra"];
        event.extra = [mutableDic copy];
        
        NSMutableDictionary *mutableUserInfo = [[NSMutableDictionary alloc] initWithDictionary:error.userInfo];
        [mutableUserInfo removeObjectForKey:@"extra"];
        event.tags = [mutableUserInfo copy];
    }else{
        event.tags = error.userInfo;
    }
    return event;
}



+ (void)reportLog
{
    SentryEvent *event = [[SentryEvent alloc] initWithLevel:kSentrySeverityDebug];
    event.message = @"UploadLog";
    event.extra = [[self sharedInstance] queryDDLog];
    [[SentryClient sharedClient] sendEvent:event withCompletionHandler:^(NSError * _Nullable error) {
    }];
}


@end
