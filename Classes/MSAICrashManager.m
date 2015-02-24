#import "AppInsights.h"

#if MSAI_FEATURE_CRASH_REPORTER

#import "AppInsightsPrivate.h"
#import "MSAIHelper.h"
#import "MSAIContextPrivate.h"
#import "MSAICrashManagerPrivate.h"
#import "MSAICrashDataProvider.h"
#import "MSAICrashDetailsPrivate.h"
#import "MSAICrashData.h"
#import "MSAIChannel.h"
#import "MSAIChannelPrivate.h"
#import "MSAIPersistence.h"
#import "MSAIEnvelope.h"
#import "MSAIEnvelopeManager.h"
#import "MSAIEnvelopeManagerPrivate.h"
#import "MSAIData.h"
#import "MSAIKeychainUtils.h"

#import <mach-o/loader.h>
#import <mach-o/dyld.h>

#include <sys/sysctl.h>

// stores the set of crashreports that have been approved but aren't sent yet
#define kMSAICrashApprovedReports @"MSAICrashApprovedReports"

// keys for meta information associated to each crash
#define kMSAICrashMetaUserName @"MSAICrashMetaUserName"
#define kMSAICrashMetaUserEmail @"MSAICrashMetaUserEmail"
#define kMSAICrashMetaUserID @"MSAICrashMetaUserID"
#define kMSAICrashMetaApplicationLog @"MSAICrashMetaApplicationLog"

// internal keys
NSString *const kMSAICrashManagerStatus = @"MSAICrashManagerStatus";

NSString *const kMSAIAppWentIntoBackgroundSafely = @"MSAIAppWentIntoBackgroundSafely";
NSString *const kMSAIAppDidReceiveLowMemoryNotification = @"MSAIAppDidReceiveLowMemoryNotification";

static MSAICrashManagerCallbacks msaiCrashCallbacks = {
    .context = NULL,
    .handleSignal = NULL
};

// proxy implementation for PLCrashReporter to keep our interface stable while this can change
static void plcr_post_crash_callback(siginfo_t *info, ucontext_t *uap, void *context) {
  if(msaiCrashCallbacks.handleSignal != NULL)
    msaiCrashCallbacks.handleSignal(context);
}

static PLCrashReporterCallbacks plCrashCallbacks = {
    .version = 0,
    .context = NULL,
    .handleSignal = plcr_post_crash_callback
};

static NSFileManager *_fileManager;
static NSMutableArray *_crashFiles;
static NSMutableDictionary *_approvedCrashReports;
static NSString *_settingsFile;
static NSString *_crashesDir;
static NSString *_lastCrashFilename;
static MSAICrashManagerStatus _crashManagerStatus;
static BOOL _isSetup;
static BOOL _enableMachExceptionHandler;
static BOOL _enableOnDeviceSymbolication;
static MSAIPLCrashReporter *_plCrashReporter;
static BOOL _didCrashInLastSession;
static BOOL _enableAppNotTerminatingCleanlyDetection;
static BOOL _didReceiveMemoryWarningInLastSession;
static id _delegate;
static PLCrashReporterCallbacks *_crashCallBacks;
static id _appDidBecomeActiveObserver;
static id _appWillTerminateObserver;
static id _appDidEnterBackgroundObserver;
static id _appWillEnterForegroundObserver;
static id _appDidReceiveLowMemoryWarningObserver;
static id _networkDidBecomeReachableObserver;
static BOOL _didLogLowMemoryWarning;
static NSUncaughtExceptionHandler *_exceptionHandler;
static NSString *_analyzerInProgressFile;
static MSAIContext *_appContext;
static BOOL _sendingInProgress;
static NSTimeInterval _timeintervalCrashInLastSessionOccured;
static MSAICrashDetails *_lastSessionCrashDetails;

@interface MSAICrashManager ()

@end


@implementation MSAICrashManager {
}


#pragma mark - Start

+ (void)startManagerWithAppContext:(MSAIContext *)appContext {
  //TODO does it make sense to have everything not initialised if the context is nil?
  if(appContext) {
    if(!_isSetup) {
      _appContext = appContext;
      [self startManager];
    }
  }
}


/**
*	 Main startup sequence initializing PLCrashReporter if it wasn't disabled
*  sets _isSetup to YES
*/
+ (void)startManager {
  if(_crashManagerStatus == MSAICrashManagerStatusDisabled) return;
  static dispatch_once_t plcrPredicate;
  dispatch_once(&plcrPredicate, ^{
    [self initValues];

    [self registerObservers];
    [self loadSettings];


    /* Configure our reporter */

    PLCrashReporterSignalHandlerType signalHandlerType = PLCrashReporterSignalHandlerTypeBSD;
    if([self isMachExceptionHandlerEnabled]) {
      signalHandlerType = PLCrashReporterSignalHandlerTypeMach;
    }

    PLCrashReporterSymbolicationStrategy symbolicationStrategy = PLCrashReporterSymbolicationStrategyNone;
    if([self isOnDeviceSymbolicationEnabled]) {
      symbolicationStrategy = PLCrashReporterSymbolicationStrategyAll;
    }

    MSAIPLCrashReporterConfig *config = [[MSAIPLCrashReporterConfig alloc] initWithSignalHandlerType:signalHandlerType
                                                                               symbolicationStrategy:symbolicationStrategy];
    _plCrashReporter = [[MSAIPLCrashReporter alloc] initWithConfiguration:config];

    // Check if we previously crashed
    if([_plCrashReporter hasPendingCrashReport]) {
      _didCrashInLastSession = YES;
      [self handleCrashReport];
    }

    // The actual signal and mach handlers are only registered when invoking `enableCrashReporterAndReturnError`
    // So it is safe enough to only disable the following part when a debugger is attached no matter which
    // signal handler type is set
    // We only check for this if we are not in the App Store environment

    BOOL debuggerIsAttached = NO;
    if(![_appContext isAppStoreEnvironment]) {
      if([self isDebuggerAttached]) {
        debuggerIsAttached = YES;
        NSLog(@"[AppInsightsSDK] WARNING: Detecting crashes is NOT enabled due to running the app with a debugger attached.");
      }
    }

    if(!debuggerIsAttached) {
      // Multiple exception handlers can be set, but we can only query the top level error handler (uncaught exception handler).
      //
      // To check if PLCrashReporter's error handler is successfully added, we compare the top
      // level one that is set before and the one after PLCrashReporter sets up its own.
      //
      // With delayed processing we can then check if another error handler was set up afterwards
      // and can show a debug warning log message, that the dev has to make sure the "newer" error handler
      // doesn't exit the process itself, because then all subsequent handlers would never be invoked.
      //
      // Note: ANY error handler setup BEFORE AppInsightsSDK initialization will not be processed!

      // get the current top level error handler
      NSUncaughtExceptionHandler *initialHandler = NSGetUncaughtExceptionHandler();

      // PLCrashReporter may only be initialized once. So make sure the developer
      // can't break this
      NSError *error = NULL;

      // set any user defined callbacks, hopefully the users knows what they do
      if(_crashCallBacks) {
        [_plCrashReporter setCrashCallbacks:_crashCallBacks];
      }

      // Enable the Crash Reporter
      if(![_plCrashReporter enableCrashReporterAndReturnError:&error])
        NSLog(@"[AppInsightsSDK] WARNING: Could not enable crash reporter: %@", [error localizedDescription]);

      // get the new current top level error handler, which should now be the one from PLCrashReporter
      NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();

      // do we have a new top level error handler? then we were successful
      if(currentHandler && currentHandler != initialHandler) {
        self.exceptionHandler = currentHandler;

        MSAILog(@"INFO: Exception handler successfully initialized.");
      } else {
        // this should never happen, theoretically only if NSSetUncaugtExceptionHandler() has some internal issues
        NSLog(@"[AppInsightsSDK] ERROR: Exception handler could not be set. Make sure there is no other exception handler set up!");
      }
    }
    _isSetup = YES;
  });

  if([[NSUserDefaults standardUserDefaults] valueForKey:kMSAIAppDidReceiveLowMemoryNotification])
    _didReceiveMemoryWarningInLastSession = [[NSUserDefaults standardUserDefaults] boolForKey:kMSAIAppDidReceiveLowMemoryNotification];

  if(!_didCrashInLastSession && [self isAppNotTerminatingCleanlyDetectionEnabled]) {
    BOOL didAppSwitchToBackgroundSafely = YES;

    if([[NSUserDefaults standardUserDefaults] valueForKey:kMSAIAppWentIntoBackgroundSafely])
      didAppSwitchToBackgroundSafely = [[NSUserDefaults standardUserDefaults] boolForKey:kMSAIAppWentIntoBackgroundSafely];

    if(!didAppSwitchToBackgroundSafely) {
      BOOL considerReport = YES;

      if(_delegate &&
          [_delegate respondsToSelector:@selector(considerAppNotTerminatedCleanlyReportForCrashManager)]) {
        considerReport = [_delegate considerAppNotTerminatedCleanlyReportForCrashManager];
      }

      if(considerReport) {
        [self createCrashReportForAppKill];

        _didCrashInLastSession = YES;
      }
    }
  }
  [self appEnteredForeground];
  [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kMSAIAppDidReceiveLowMemoryNotification];
  [[NSUserDefaults standardUserDefaults] synchronize];

  [self triggerDelayedProcessing];
}


+ (void)initValues {
  _delegate = nil;
  _isSetup = NO;

  _plCrashReporter = nil;
  _exceptionHandler = nil;
  _crashCallBacks = nil;

  _didCrashInLastSession = NO;
  _timeintervalCrashInLastSessionOccured = -1;
  _didLogLowMemoryWarning = NO;

  _approvedCrashReports = [[NSMutableDictionary alloc] init];

  _fileManager = [[NSFileManager alloc] init];
  _crashFiles = [[NSMutableArray alloc] init];

  _crashManagerStatus = MSAICrashManagerStatusAutoSend;

  NSString *testValue = [[NSUserDefaults standardUserDefaults] stringForKey:kMSAICrashManagerStatus];
  if(testValue) {
    _crashManagerStatus = (MSAICrashManagerStatus) [[NSUserDefaults standardUserDefaults] integerForKey:kMSAICrashManagerStatus];
  } else {
    [[NSUserDefaults standardUserDefaults] setInteger:_crashManagerStatus forKey:kMSAICrashManagerStatus];
  }

  _crashesDir = msai_settingsDir();
  _settingsFile = [_crashesDir stringByAppendingPathComponent:MSAI_CRASH_SETTINGS];
  _analyzerInProgressFile = [_crashesDir stringByAppendingPathComponent:MSAI_CRASH_ANALYZER];

  if([_fileManager fileExistsAtPath:_analyzerInProgressFile]) {
    NSError *error = nil;
    [_fileManager removeItemAtPath:_analyzerInProgressFile error:&error];
  }

  _didReceiveMemoryWarningInLastSession = NO;
  _sendingInProgress = NO;

  _lastSessionCrashDetails = nil;

  _enableAppNotTerminatingCleanlyDetection = NO;
  _enableOnDeviceSymbolication = NO;
  _enableMachExceptionHandler = NO;
  _lastCrashFilename = nil;
}

+ (BOOL)isSetup {
  return _isSetup;
}

//leaving this here to avoid support requests asking for missing dealloc
- (void)dealloc {
  [self unregisterObservers];
}

#pragma mark - Configuration

+ (void)setCrashManagerStatus:(MSAICrashManagerStatus)crashManagerStatus {
  _crashManagerStatus = crashManagerStatus;

  [[NSUserDefaults standardUserDefaults] setInteger:crashManagerStatus forKey:kMSAICrashManagerStatus];
}

+ (MSAICrashManagerStatus)getCrashManagerStatus {
  return _crashManagerStatus;
}

+ (BOOL)isMachExceptionHandlerEnabled {
  return _enableMachExceptionHandler;
}

+ (void)setMachExceptionHandlerEnabled:(BOOL)enabled {
  _enableMachExceptionHandler = enabled;
}

+ (BOOL)isOnDeviceSymbolicationEnabled {
  return _enableOnDeviceSymbolication;
}

+ (void)setOnDeviceSymbolicationEnabled:(BOOL)enabled {
  _enableOnDeviceSymbolication = enabled;
}

+ (BOOL)isAppNotTerminatingCleanlyDetectionEnabled {
  return _enableAppNotTerminatingCleanlyDetection;
}

+ (void)setEnableAppNotTerminatingCleanlyDetection:(BOOL)enableAppNotTerminatingCleanlyDetection {
  _enableAppNotTerminatingCleanlyDetection = enableAppNotTerminatingCleanlyDetection;
}

/**
*  Set the callback for PLCrashReporter
*
*  @param callbacks MSAICrashManagerCallbacks instance
*/
+ (void)setCrashCallbacks:(MSAICrashManagerCallbacks *)callbacks {
  if(!callbacks) return;

  // set our proxy callback struct
  msaiCrashCallbacks.context = callbacks->context;
  msaiCrashCallbacks.handleSignal = callbacks->handleSignal;

  // set the PLCrashReporterCallbacks struct
  plCrashCallbacks.context = callbacks->context;

  _crashCallBacks = &plCrashCallbacks;
}

#pragma mark - Crash Meta Information

+ (BOOL)didCrashInLastSession {
  return _didCrashInLastSession;
}

+ (MSAICrashDetails *)getLastSessionCrashDetails {
  return _lastSessionCrashDetails;
}

+ (NSTimeInterval)getTimeIntervalCrashInLastSessionOccured {
  return _timeintervalCrashInLastSessionOccured;
}

+ (BOOL)didReveiveMemoryWarningInLastSession {
  return _didReceiveMemoryWarningInLastSession;
}

#pragma mark - Debugging Helpers


/**
* Check if the debugger is attached
*
* Taken from https://github.com/plausiblelabs/plcrashreporter/blob/2dd862ce049e6f43feb355308dfc710f3af54c4d/Source/Crash%20Demo/main.m#L96
*
* @return `YES` if the debugger is attached to the current process, `NO` otherwise
*/
+ (BOOL)isDebuggerAttached {
  static BOOL debuggerIsAttached = NO;

  static dispatch_once_t debuggerPredicate;
  dispatch_once(&debuggerPredicate, ^{
    struct kinfo_proc info;
    size_t info_size = sizeof(info);
    int name[4];

    name[0] = CTL_KERN;
    name[1] = KERN_PROC;
    name[2] = KERN_PROC_PID;
    name[3] = getpid();

    if(sysctl(name, 4, &info, &info_size, NULL, 0) == -1) {
      NSLog(@"[AppInsightsSDK] ERROR: Checking for a running debugger via sysctl() failed: %s", strerror(errno));
      debuggerIsAttached = false;
    }

    if(!debuggerIsAttached && (info.kp_proc.p_flag & P_TRACED) != 0)
      debuggerIsAttached = true;
  });

  return debuggerIsAttached;
}

+ (void)generateTestCrash {
  if(![_appContext isAppStoreEnvironment]) {

    if([self isDebuggerAttached]) {
      NSLog(@"[AppInsightsSDK] WARNING: The debugger is attached. The following crash cannot be detected by the SDK!");
    }

    __builtin_trap();
  }
}

#pragma mark - Private Header


+ (void)setDelegate:(id)delegate {
  if(delegate) {
    _delegate = delegate;
  }
}

+ (id)getDelegate {
  return _delegate;
}

+ (NSUncaughtExceptionHandler *)getExceptionHandler {
  return _exceptionHandler;
}

+ (void)setExceptionHandler:(NSUncaughtExceptionHandler *)exceptionHandler {
  if(exceptionHandler) {
    _exceptionHandler = exceptionHandler;
  }
}

+ (NSFileManager *)getFileManager {
  return _fileManager;
}

+ (void)setFileManager:(NSFileManager *)fileManager {
  if(fileManager) {
    _fileManager = fileManager;
  }
}

+ (MSAIPLCrashReporter *)getPLCrashReporter {
  return _plCrashReporter;
}

+ (void)setPLCrashReporter:(MSAIPLCrashReporter *)crashReporter {
  if(crashReporter) {
    _plCrashReporter = crashReporter;
  }
}

+ (NSString *)getLastCrashFilename {
  return _lastCrashFilename;
}

+ (void)setLastCrashFilename:(NSString *)lastCrashFilename {
  if(lastCrashFilename) {
    _lastCrashFilename = lastCrashFilename;
  }
}

+ (NSString *)getCrashesDir {
  return _crashesDir;
}

+ (void)setCrashesDir:(NSString *)crashesDir {
  if(crashesDir) {
    _crashesDir = crashesDir;
  }
}

+ (void)setAppContext:(MSAIContext *)context {
  if(context) {
    _appContext = context;
  }
}

+ (MSAIContext *)getAppContext {
  return _appContext;
}

#pragma mark - (Un)register for Lifecycle Notifications

+ (void)registerObservers {
  __weak typeof(self) weakSelf = self;

  if(nil == _appDidBecomeActiveObserver) {
    _appDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                    object:nil
                                                                                     queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *note) {
                                                                                  [self triggerDelayedProcessing];
                                                                                }];
  }

  if(nil == _networkDidBecomeReachableObserver) {
    _networkDidBecomeReachableObserver = [[NSNotificationCenter defaultCenter] addObserverForName:MSAINetworkDidBecomeReachableNotification
                                                                                           object:nil
                                                                                            queue:NSOperationQueue.mainQueue
                                                                                       usingBlock:^(NSNotification *note) {
                                                                                         [self triggerDelayedProcessing];
                                                                                       }];
  }

  if(nil == _appWillTerminateObserver) {
    _appWillTerminateObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                                                  object:nil
                                                                                   queue:NSOperationQueue.mainQueue
                                                                              usingBlock:^(NSNotification *note) {
                                                                                [self leavingAppSafely];
                                                                              }];
  }

  if(nil == _appDidEnterBackgroundObserver) {
    _appDidEnterBackgroundObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                                                       object:nil
                                                                                        queue:NSOperationQueue.mainQueue
                                                                                   usingBlock:^(NSNotification *note) {
                                                                                     [self leavingAppSafely];
                                                                                   }];
  }

  if(nil == _appWillEnterForegroundObserver) {
    _appWillEnterForegroundObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                                                        object:nil
                                                                                         queue:NSOperationQueue.mainQueue
                                                                                    usingBlock:^(NSNotification *note) {
                                                                                      typeof(self) strongSelf = weakSelf;
                                                                                      [strongSelf appEnteredForeground];
                                                                                    }];
  }

  if(nil == _appDidReceiveLowMemoryWarningObserver) {
    _appDidReceiveLowMemoryWarningObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                                                               object:nil
                                                                                                queue:NSOperationQueue.mainQueue
                                                                                           usingBlock:^(NSNotification *note) {
                                                                                             // we only need to log this once
                                                                                             if(!_didLogLowMemoryWarning) {
                                                                                               [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kMSAIAppDidReceiveLowMemoryNotification];
                                                                                               [[NSUserDefaults standardUserDefaults] synchronize];
                                                                                               _didLogLowMemoryWarning = YES;
                                                                                             }
                                                                                           }];
  }
}

- (void)unregisterObservers {
  [self unregisterObserver:_appDidBecomeActiveObserver];
  [self unregisterObserver:_appWillTerminateObserver];
  [self unregisterObserver:_appDidEnterBackgroundObserver];
  [self unregisterObserver:_appWillEnterForegroundObserver];
  [self unregisterObserver:_appDidReceiveLowMemoryWarningObserver];

  [self unregisterObserver:_networkDidBecomeReachableObserver];
}

- (void)unregisterObserver:(id)observer {
  if(observer) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    observer = nil;
  }
}

#pragma mark - Private - Meta Data for Crash Report


/**
*  Write a meta file for a new crash report
*
*  @param filename the crash reports temp filename
*/
+ (void)storeMetaDataForCrashReportFilename:(NSString *)filename {
  NSError *error = NULL;
  NSMutableDictionary *metaDict = [NSMutableDictionary dictionaryWithCapacity:4];
  NSString *applicationLog = @"";

  [self addStringValueToKeychain:[self userNameForCrashReport] forKey:[NSString stringWithFormat:@"%@.%@", filename, kMSAICrashMetaUserName]];
  [self addStringValueToKeychain:[self userEmailForCrashReport] forKey:[NSString stringWithFormat:@"%@.%@", filename, kMSAICrashMetaUserEmail]];
  [self addStringValueToKeychain:[self userIDForCrashReport] forKey:[NSString stringWithFormat:@"%@.%@", filename, kMSAICrashMetaUserID]];

  if(_delegate != nil && [_delegate respondsToSelector:@selector(applicationLogForCrashManager)]) {
    applicationLog = [_delegate applicationLogForCrashManager] ?: @""; //TODO fix delegate callback
  }
  metaDict[kMSAICrashMetaApplicationLog] = applicationLog;

  NSData *plist = [NSPropertyListSerialization dataWithPropertyList:(id) metaDict
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&error];
  if(plist) {
    [plist writeToFile:[_crashesDir stringByAppendingPathComponent:[filename stringByAppendingPathExtension:@"meta"]] atomically:YES];
  } else {
    MSAILog(@"ERROR: Writing crash meta data failed. %@", error);
  }
}

/**
*	 Get the userID from the delegate which should be stored with the crash report
*
*	@return The userID value
*/
+ (NSString *)userIDForCrashReport {
  // first check the global keychain storage
  NSString *userID = [self stringValueFromKeychainForKey:kMSAIMetaUserID] ?: @"";

  if([MSAIAppInsights sharedInstance].delegate &&
      [[MSAIAppInsights sharedInstance].delegate respondsToSelector:@selector(userIDForTelemetryManager:)]) {
    userID = [[MSAIAppInsights sharedInstance].delegate
        userIDForTelemetryManager:[MSAIAppInsights sharedInstance]] ?: @"";
  }

  return userID;
}

/**
*	 Get the userName from the delegate which should be stored with the crash report
*
*	@return The userName value
*/
+ (NSString *)userNameForCrashReport {
  // first check the global keychain storage
  NSString *username = [self stringValueFromKeychainForKey:kMSAIMetaUserName] ?: @"";

  if([MSAIAppInsights sharedInstance].delegate &&
      [[MSAIAppInsights sharedInstance].delegate respondsToSelector:@selector(userNameForTelemetryManager:)]) {
    username = [[MSAIAppInsights sharedInstance].delegate
        userNameForTelemetryManager:[MSAIAppInsights sharedInstance]] ?: @"";
  }

  return username;
}

/**
*	 Get the userEmail from the delegate which should be stored with the crash report
*
*	@return The userEmail value
*/
+ (NSString *)userEmailForCrashReport {
  // first check the global keychain storage
  NSString *useremail = [self stringValueFromKeychainForKey:kMSAIMetaUserEmail] ?: @"";

  if([MSAIAppInsights sharedInstance].delegate &&
      [[MSAIAppInsights sharedInstance].delegate respondsToSelector:@selector(userEmailForTelemetryManager:)]) {
    useremail = [[MSAIAppInsights sharedInstance].delegate
        userEmailForTelemetryManager:[MSAIAppInsights sharedInstance]] ?: @"";
  }

  return useremail;
}

#pragma mark - PLCrashReporter

/**
*	 Process new crash reports provided by PLCrashReporter
*
* Parse the new crash report and gather additional meta data from the app which will be stored along the crash report
*/
+ (void)handleCrashReport {
  NSError *error = NULL;

  if(!_plCrashReporter) return;

  // check if the next call ran successfully the last time
  if(![_fileManager fileExistsAtPath:_analyzerInProgressFile]) {
    // mark the start of the routine
    [_fileManager createFileAtPath:_analyzerInProgressFile contents:nil attributes:nil];

    [self saveSettings];

    // Try loading the crash report
    NSData *crashData = [[NSData alloc] initWithData:[_plCrashReporter loadPendingCrashReportDataAndReturnError:&error]];

    NSString *cacheFilename = [NSString stringWithFormat:@"%.0f", [NSDate timeIntervalSinceReferenceDate]];
    _lastCrashFilename = cacheFilename;

    if(crashData == nil) {
      MSAILog(@"ERROR: Could not load crash report: %@", error);
    } else {
      // get the startup timestamp from the crash report, and the file timestamp to calculate the timeinterval when the crash happened after startup
      MSAIPLCrashReport *report = [[MSAIPLCrashReport alloc] initWithData:crashData error:&error];

      if(report == nil) {
        MSAILog(@"WARNING: Could not parse crash report");
      } else {
        NSDate *appStartTime = nil;
        NSDate *appCrashTime = nil;
        if([report.processInfo respondsToSelector:@selector(processStartTime)]) {
          if(report.systemInfo.timestamp && report.processInfo.processStartTime) {
            appStartTime = report.processInfo.processStartTime;
            appCrashTime = report.systemInfo.timestamp;
            _timeintervalCrashInLastSessionOccured = [report.systemInfo.timestamp timeIntervalSinceDate:report.processInfo.processStartTime];
          }
        }

        [crashData writeToFile:[_crashesDir stringByAppendingPathComponent:cacheFilename] atomically:YES];

        [self storeMetaDataForCrashReportFilename:cacheFilename];

        NSString *incidentIdentifier = @"???";
        if(report.uuidRef != NULL) {
          incidentIdentifier = (NSString *) CFBridgingRelease(CFUUIDCreateString(NULL, report.uuidRef));
        }

        NSString *reporterKey = msai_appAnonID() ?: @"";

        _lastSessionCrashDetails = [[MSAICrashDetails alloc] initWithIncidentIdentifier:incidentIdentifier
                                                                            reporterKey:reporterKey
                                                                                 signal:report.signalInfo.name
                                                                          exceptionName:report.exceptionInfo.exceptionName
                                                                        exceptionReason:report.exceptionInfo.exceptionReason
                                                                           appStartTime:appStartTime
                                                                              crashTime:appCrashTime
                                                                              osVersion:report.systemInfo.operatingSystemVersion
                                                                                osBuild:report.systemInfo.operatingSystemBuild
                                                                               appBuild:report.applicationInfo.applicationVersion
        ];
      }
    }
  }

  // Purge the report
  // mark the end of the routine
  if([_fileManager fileExistsAtPath:_analyzerInProgressFile]) {
    [_fileManager removeItemAtPath:_analyzerInProgressFile error:&error];
  }

  [self saveSettings];

  [_plCrashReporter purgePendingCrashReport];
}

/**
Get the filename of the first not approved crash report

@return NSString Filename of the first found not approved crash report
*/
+ (NSString *)firstNotApprovedCrashReport {
  if((!_approvedCrashReports || [_approvedCrashReports count] == 0) && [_crashFiles count] > 0) {
    return _crashFiles[0];
  }

  for(NSUInteger i = 0; i < [_crashFiles count]; i++) {
    NSString *filename = _crashFiles[i];

    if(!_approvedCrashReports[filename]) return filename;
  }

  return nil;
}

/**
*	Check if there are any new crash reports that are not yet processed
*
*	@return	`YES` if there is at least one new crash report found, `NO` otherwise
*/
+ (BOOL)hasPendingCrashReport {
  if(_crashManagerStatus == MSAICrashManagerStatusDisabled) return NO;

  if([_fileManager fileExistsAtPath:_crashesDir]) {
    NSError *error = NULL;

    NSArray *dirArray = [_fileManager contentsOfDirectoryAtPath:_crashesDir error:&error];

    for(NSString *file in dirArray) {
      NSString *filePath = [_crashesDir stringByAppendingPathComponent:file];

      NSDictionary *fileAttributes = [_fileManager attributesOfItemAtPath:filePath error:&error];
      if([fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular] &&
          [fileAttributes[NSFileSize] intValue] > 0 &&
          ![file hasSuffix:@".DS_Store"] &&
          ![file hasSuffix:@".analyzer"] &&
          ![file hasSuffix:@".plist"] &&
          ![file hasSuffix:@".data"] &&
          ![file hasSuffix:@".meta"] &&
          ![file hasSuffix:@".desc"]) {
        [_crashFiles addObject:filePath];
      }
    }
  }

  if([_crashFiles count] > 0) {
    MSAILog(@"INFO: %lu pending crash reports found.", (unsigned long) [_crashFiles count]);
    return YES;
  } else {
    if(_didCrashInLastSession) {
      if(_delegate != nil && [_delegate respondsToSelector:@selector(crashManagerWillCancelSendingCrashReport)]) {
        [_delegate crashManagerWillCancelSendingCrashReport];
      }

      _didCrashInLastSession = NO;
    }

    return NO;
  }
}


#pragma mark - Crash Report Processing

+ (void)triggerDelayedProcessing {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(invokeDelayedProcessing) object:nil];
  [self performSelector:@selector(invokeDelayedProcessing) withObject:nil afterDelay:0.5];
}

/**
* Delayed startup processing for everything that does not to be done in the app startup runloop
*
* - Checks if there is another exception handler installed that may block ours
* - Present UI if the user has to approve new crash reports
* - Send pending approved crash reports
*/
+ (void)invokeDelayedProcessing {
  if(!msai_isRunningInAppExtension() &&
      [[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
    return;
  }

  MSAILog(@"INFO: Start delayed CrashManager processing");

  // was our own exception handler successfully added?
  if(_exceptionHandler) {
    // get the current top level error handler
    NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();

    // If the top level error handler differs from our own, then at least another one was added.
    // This could cause exception crashes not to be reported to AppInsights. See log message for details.
    if(_exceptionHandler != currentHandler) {
      MSAILog(@"[AppInsightsSDK] WARNING: Another exception handler was added. If this invokes any kind exit() after processing the exception, which causes any subsequent error handler not to be invoked, these crashes will NOT be reported to AppInsights!");
    }
  }

  if(!_sendingInProgress && [self hasPendingCrashReport]) {
    _sendingInProgress = YES;

    NSString *notApprovedReportFilename = [self firstNotApprovedCrashReport];

    // this can happen in case there is a non approved crash report but it didn't happen in the previous app session
    if(notApprovedReportFilename && !_lastCrashFilename) {
      _lastCrashFilename = [notApprovedReportFilename lastPathComponent];
    }

    if(msai_isRunningInAppExtension()) {
      [self sendNextCrashReport];
    } else if(_crashManagerStatus != MSAICrashManagerStatusAutoSend && notApprovedReportFilename) {

      if(_delegate != nil && [_delegate respondsToSelector:@selector(crashManagerWillShowSubmitCrashReportAlert)]) {
        [_delegate crashManagerWillShowSubmitCrashReportAlert];
      }
    } else {
      [self sendNextCrashReport];
    }
  }
}


/**
*  Creates a fake crash report because the app was killed while being in foreground
*/
+ (void)createCrashReportForAppKill {
  MSAICrashDataHeaders *crashHeaders = [MSAICrashDataHeaders new];
  crashHeaders.crashDataHeadersId = msai_UUID();
  crashHeaders.exceptionType = kMSAICrashKillSignal;
  crashHeaders.exceptionCode = @"00000020 at 0x8badf00d";
  crashHeaders.exceptionReason = @"The application did not terminate cleanly but no crash occured. The app received at least one Low Memory Warning.";

  MSAICrashData *crashData = [MSAICrashData new];
  crashData.headers = crashHeaders;

  MSAIData *data = [MSAIData new];
  data.baseData = crashData;
  data.baseType = crashData.dataTypeName;

  MSAIEnvelope *fakeCrashEnvelope = [[MSAIEnvelopeManager sharedManager] envelope];
  fakeCrashEnvelope.data = data;
  fakeCrashEnvelope.name = crashData.envelopeTypeName;

  [MSAIPersistence persistFakeReportBundle:@[fakeCrashEnvelope]];
}

/***
* Gathers all collected data and constructs the XML structure and hands everything to the Channel
*/
+ (void)sendNextCrashReport {
  NSError *error = NULL;

  if([_crashFiles count] == 0)
    return;

  NSString *filename = _crashFiles[0];
  NSString *cacheFilename = [filename lastPathComponent];
  NSData *crashData = [NSData dataWithContentsOfFile:filename];

  if([crashData length] > 0) {
    MSAIPLCrashReport *report = nil;
    MSAIEnvelope *crashEnvelope = nil;

    if([[cacheFilename pathExtension] isEqualToString:@"fake"]) {
      NSArray *fakeReportBundle = [MSAIPersistence fakeReportBundle];
      if(fakeReportBundle && fakeReportBundle.count > 0) {
        crashEnvelope = fakeReportBundle[0];
        if([crashEnvelope.appId compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
        }
      }
    } else {
      report = [[MSAIPLCrashReport alloc] initWithData:crashData error:&error];
    }

    if(report == nil && crashEnvelope == nil) {
      MSAILog(@"WARNING: Could not parse crash report");
      // we cannot do anything with this report, so delete it
      [self cleanCrashReportWithFilename:filename];
      // we don't continue with the next report here, even if there are to prevent calling sendCrashReports from itself again
      // the next crash will be automatically send on the next app start/becoming active event
      return;
    }

    if(report) {
      crashEnvelope = [MSAICrashDataProvider crashDataForCrashReport:report];
      if([report.applicationInfo.applicationVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
      }
    }

    if([report.applicationInfo.applicationVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
    }

    // store this crash report as user approved, so if it fails it will retry automatically
    _approvedCrashReports[filename] = @YES;

    [self saveSettings];

    [self processCrashReportWithFilename:filename envelope:crashEnvelope];
  } else {
    // we cannot do anything with this report, so delete it
    [self cleanCrashReportWithFilename:filename];
  }
}

/**
*	 Send the XML data to the server
*
* Wraps the XML structure into a POST body and starts sending the data asynchronously
*
*	@param	xml	The XML data that needs to be send to the server
*/
+ (void)processCrashReportWithFilename:(NSString *)filename envelope:(MSAIEnvelope *)envelope {

  MSAILog(@"INFO: Persisting crash reports started.");

  __weak typeof(self) weakSelf = self;
  [[MSAIChannel sharedChannel] processEnvelope:envelope withCompletionBlock:^(BOOL success) {
    typeof(self) strongSelf = weakSelf;

    _sendingInProgress = NO;
    //TODO: Inform delegate
    if(success) {
      [strongSelf cleanCrashReportWithFilename:filename];
      [strongSelf sendNextCrashReport];
    }
  }];

  if(_delegate != nil && [_delegate respondsToSelector:@selector(crashManagerWillSendCrashReport)]) {
    [_delegate crashManagerWillSendCrashReport]; //FIX delegation
  }
}

#pragma mark - Helpers

/**
* Save all settings
*
* This saves the list of approved crash reports
*/
+ (void)saveSettings {
  NSError *error = nil;

  NSMutableDictionary *rootObj = [NSMutableDictionary dictionaryWithCapacity:2];
  if(_approvedCrashReports && [_approvedCrashReports count] > 0) {
    rootObj[kMSAICrashApprovedReports] = _approvedCrashReports;
  }

  NSData *plist = [NSPropertyListSerialization dataWithPropertyList:(id) rootObj format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];

  if(plist) {
    [plist writeToFile:_settingsFile atomically:YES];
  } else {
    MSAILog(@"ERROR: Writing settings. %@", [error description]);
  }
}


/**
* Load all settings
*
* This contains the list of approved crash reports
*/
+ (void)loadSettings {
  NSError *error = nil;
  NSPropertyListFormat format;

  if(![_fileManager fileExistsAtPath:_settingsFile])
    return;

  NSData *plist = [NSData dataWithContentsOfFile:_settingsFile];
  if(plist) {
    NSDictionary *rootObj = (NSDictionary *) [NSPropertyListSerialization
        propertyListWithData:plist
                     options:NSPropertyListMutableContainersAndLeaves
                      format:&format
                       error:&error];

    if(rootObj[kMSAICrashApprovedReports])
      [_approvedCrashReports setDictionary:rootObj[kMSAICrashApprovedReports]];
  } else {
    MSAILog(@"ERROR: Reading crash manager settings.");
  }
}


/**
* Remove a cached crash report
*
*  @param filename The base filename of the crash report
*/
+ (void)cleanCrashReportWithFilename:(NSString *)filename {
  if(!filename) return;

  NSError *error = NULL;

  [_fileManager removeItemAtPath:filename error:&error];
  [_fileManager removeItemAtPath:[filename stringByAppendingString:@".data"] error:&error];
  [_fileManager removeItemAtPath:[filename stringByAppendingString:@".meta"] error:&error];
  [_fileManager removeItemAtPath:[filename stringByAppendingString:@".desc"] error:&error];

  NSString *cacheFilename = [filename lastPathComponent];
  [self removeKeyFromKeychain:[NSString stringWithFormat:@"%@.%@", cacheFilename, kMSAICrashMetaUserName]];
  [self removeKeyFromKeychain:[NSString stringWithFormat:@"%@.%@", cacheFilename, kMSAICrashMetaUserEmail]];
  [self removeKeyFromKeychain:[NSString stringWithFormat:@"%@.%@", cacheFilename, kMSAICrashMetaUserID]];

  [_crashFiles removeObject:filename];
  [_approvedCrashReports removeObjectForKey:filename];

  [self saveSettings];
}

/**
*	 Remove all crash reports and stored meta data for each from the file system and keychain
*
* This is currently only used as a helper method for tests
*/
+ (void)cleanCrashReports {
  for(NSUInteger i = 0; i < [_crashFiles count]; i++) {
    [self cleanCrashReportWithFilename:_crashFiles[i]];
  }
}

+ (void)persistUserProvidedMetaData:(MSAICrashMetaData *)userProvidedMetaData {
  if(!userProvidedMetaData) return;

  if(userProvidedMetaData.userDescription && [userProvidedMetaData.userDescription length] > 0) {
    NSError *error;
    [userProvidedMetaData.userDescription writeToFile:[NSString stringWithFormat:@"%@.desc", [_crashesDir stringByAppendingPathComponent:_lastCrashFilename]] atomically:YES encoding:NSUTF8StringEncoding error:&error];
  }

  if(userProvidedMetaData.userName && [userProvidedMetaData.userName length] > 0) {
    [self addStringValueToKeychain:userProvidedMetaData.userName forKey:[NSString stringWithFormat:@"%@.%@", _lastCrashFilename, kMSAICrashMetaUserName]];

  }

  if(userProvidedMetaData.userEmail && [userProvidedMetaData.userEmail length] > 0) {
    [self addStringValueToKeychain:userProvidedMetaData.userEmail forKey:[NSString stringWithFormat:@"%@.%@", _lastCrashFilename, kMSAICrashMetaUserEmail]];
  }

  if(userProvidedMetaData.userID && [userProvidedMetaData.userID length] > 0) {
    [self addStringValueToKeychain:userProvidedMetaData.userID forKey:[NSString stringWithFormat:@"%@.%@", _lastCrashFilename, kMSAICrashMetaUserID]];

  }
}

+ (void)leavingAppSafely {
  if([self isAppNotTerminatingCleanlyDetectionEnabled])
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kMSAIAppWentIntoBackgroundSafely];
}

+ (void)appEnteredForeground {
  // we disable kill detection while the debugger is running, since we'd get only false positives if the app is terminated by the user using the debugger
  if(self.isDebuggerAttached) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kMSAIAppWentIntoBackgroundSafely];
  } else if(self.isAppNotTerminatingCleanlyDetectionEnabled) {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kMSAIAppWentIntoBackgroundSafely];
  }
}

+ (void)reportError:(NSError *)error {
  MSAILog(@"ERROR: %@", [error localizedDescription]);
}

#pragma mark - Keychain

+ (BOOL)addStringValueToKeychain:(NSString *)stringValue forKey:(NSString *)key {
  if(!key || !stringValue)
    return NO;

  NSError *error = nil;
  return [MSAIKeychainUtils storeUsername:key
                              andPassword:stringValue
                           forServiceName:msai_keychainMSAIServiceName()
                           updateExisting:YES
                                    error:&error];
}

+ (BOOL)addStringValueToKeychainForThisDeviceOnly:(NSString *)stringValue forKey:(NSString *)key {
  if(!key || !stringValue)
    return NO;

  NSError *error = nil;
  return [MSAIKeychainUtils storeUsername:key
                              andPassword:stringValue
                           forServiceName:msai_keychainMSAIServiceName()
                           updateExisting:YES
                            accessibility:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                                    error:&error];
}

+ (NSString *)stringValueFromKeychainForKey:(NSString *)key {
  if(!key)
    return nil;

  NSError *error = nil;
  return [MSAIKeychainUtils getPasswordForUsername:key
                                    andServiceName:msai_keychainMSAIServiceName()
                                             error:&error];
}

+ (BOOL)removeKeyFromKeychain:(NSString *)key {
  NSError *error = nil;
  return [MSAIKeychainUtils deleteItemForUsername:key
                                   andServiceName:msai_keychainMSAIServiceName()
                                            error:&error];
}

@end

#endif /* MSAI_FEATURE_CRASH_REPORTER */

