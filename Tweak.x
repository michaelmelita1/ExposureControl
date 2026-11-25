// ExposureControl: iPhone 11 camera features for the iPhone XS, XS Max and XR (A12), iOS 15-18.
//
// Same approach as 11Cam, kept separate:
//  - Camera / Settings: CameraUI builds every camera feature in -[CAMCaptureCapabilities
//    initWithHostProcess:] from AVGestalt answers. While that runs, answer YES to the features
//    below; CameraUI turns on the matching UI itself. (Settings also asks AVGestalt directly, so
//    there the answers always apply.)
//  - Camera daemon (mediaserverd on iOS 15-16, cameracaptured on iOS 17+): it reads
//    <model>/AVCaptureSession.plist and CameraSetup.plist through FigCaptureCFCreatePropertyList
//    (ForModel). Patch the returned dictionaries in memory and clear its parsed-config cache.
//
// Features: exposure slider, iPhone 11 zoom dial, automatic Live Photos, View Outside the Frame
// (XS / XS Max, at 2x). Experiment (EXP=NIGHTMODE): Night mode on the XS / XS Max wide camera.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <os/log.h>
#import <substrate.h>

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[ExposureControl] " fmt, ##__VA_ARGS__)

#ifdef DIAG_LOG
static void DiagLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void DiagStart(NSString *file);
#endif

#pragma mark - Device

static NSString *HWModel(void) {
	static NSString *model;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		char buf[32] = {0};
		size_t len = sizeof(buf) - 1;
		if (sysctlbyname("hw.model", buf, &len, NULL, 0) == 0) model = [NSString stringWithUTF8String:buf];
		if (!model) model = @"";
	});
	return model;
}

// iPhone XS (D321AP), XS Max (D331AP, D331pAP): wide + telephoto. XR (N841AP): wide only.
static BOOL IsXS(void) {
	NSString *m = HWModel();
	return [m isEqualToString:@"D321AP"] || [m isEqualToString:@"D331AP"] || [m isEqualToString:@"D331pAP"];
}
static BOOL IsSupportedPhone(void) {
	return IsXS() || [HWModel() isEqualToString:@"N841AP"];
}

#pragma mark - Client: AVGestalt answers while the capabilities are built

static __thread int sCapsInitDepth;
static BOOL sAlwaysOverride; // Settings

static BOOL (*orig_AVGestaltGetBoolAnswer)(CFStringRef question);

static NSDictionary<NSString *, NSNumber *> *BoolOverrides(void) {
	static NSDictionary *overrides;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableDictionary *o = [NSMutableDictionary dictionary];
		// Exposure slider (adjust exposure without locking focus/exposure).
		o[@"AVGQDeviceSupportsExposureBiasWithoutExposureLock"] = @YES;
		// Automatic Live Photos. The daemon side turns on the Live Photo scoring they rely on;
		// the A12 Neural Engine runs it.
		o[@"AVGQDeviceSupportsLivePhotoAuto"] = @YES;
		// View Outside the Frame: on the XS the wide camera supplies the area outside a 2x shot.
		if (IsXS()) o[@"AVGQDeviceSupportsSpatialOverCapture"] = @YES;
#ifdef EXP_NIGHTMODE
		// Night mode (moon button). The daemon side adds the capture modes and tuning.
		if (IsXS()) o[@"AVGQRearFacingLowLightCameraCapability"] = @YES;
#endif
		overrides = [o copy];
		LOG("model %{public}@, AVGestalt overrides: %{public}@", HWModel(), [[overrides allKeys] componentsJoinedByString:@", "]);
	});
	return overrides;
}

static BOOL hook_AVGestaltGetBoolAnswer(CFStringRef question) {
	BOOL answer = orig_AVGestaltGetBoolAnswer(question);
	if ((sCapsInitDepth > 0 || sAlwaysOverride) && question) {
		NSNumber *o = BoolOverrides()[(__bridge NSString *)question];
		if (o) answer = o.boolValue;
	}
	return answer;
}

// iOS 15 CameraUI only shows the exposure slider on phones missing from a built-in list unless
// Apple's developer preference CAMFeatureDevelopmentForceExposureSlider is set (iOS 16+ don't ask).
static Boolean (*orig_CFPreferencesGetAppBooleanValue)(CFStringRef key, CFStringRef app, Boolean *valid);
static Boolean hook_CFPreferencesGetAppBooleanValue(CFStringRef key, CFStringRef app, Boolean *valid) {
	if (sCapsInitDepth > 0 && key && CFEqual(key, CFSTR("CAMFeatureDevelopmentForceExposureSlider"))) {
		if (valid) *valid = true;
		return true;
	}
	return orig_CFPreferencesGetAppBooleanValue(key, app, valid);
}

static void SetBoolIvar(id obj, const char *name, BOOL value) {
	Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
	if (!iv) { LOG("ivar %{public}s not found", name); return; }
	*(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv)) = value;
}

#ifdef DIAG_LOG
static BOOL GetBoolIvar(id obj, const char *name, BOOL *found) {
	Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
	if (found) *found = iv != NULL;
	return iv ? *(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv)) : NO;
}
#endif

%group Capabilities
%hook CAMCaptureCapabilities
- (id)initWithHostProcess:(long long)hostProcess {
	sCapsInitDepth++;
	id me = %orig;
	sCapsInitDepth--;
	// iPhone 11 zoom dial. CameraUI only enables it with an ultra-wide camera.
	if (me) SetBoolIvar(me, "_zoomPlatterSupported", YES);
#ifdef DIAG_LOG
	if (me) {
		NSMutableString *s = [NSMutableString stringWithFormat:@"CAMCaptureCapabilities hostProcess=%lld:", hostProcess];
		for (NSString *n in @[@"_exposureSliderSupported", @"_zoomPlatterSupported", @"_livePhotoAutoModeSupported", @"_backSpatialOverCaptureSupported",
		                      @"_backLowLightSupported", @"_ctmSupported", @"_deviceSupportsCTM"]) {
			BOOL found; BOOL v = GetBoolIvar(me, n.UTF8String, &found);
			[s appendFormat:@" %@=%@", [n substringFromIndex:1], found ? (v ? @"1" : @"0") : @"?"];
		}
		DiagLog(@"%@", s);
	}
#endif
	return me;
}
%end
%end

static BOOL sClientHooked, sGestaltHooked;

static void HookGestaltIfReady(void) {
	if (sGestaltHooked) return;
	void *getBool = dlsym(RTLD_DEFAULT, "AVGestaltGetBoolAnswer");
	if (!getBool) return;
	sGestaltHooked = YES;
	MSHookFunction(getBool, (void *)hook_AVGestaltGetBoolAnswer, (void **)&orig_AVGestaltGetBoolAnswer);
	MSHookFunction((void *)CFPreferencesGetAppBooleanValue, (void *)hook_CFPreferencesGetAppBooleanValue, (void **)&orig_CFPreferencesGetAppBooleanValue);
	LOG("AVGestalt hooks installed");
}

static void HookClientIfReady(void) {
	if (sAlwaysOverride) HookGestaltIfReady();
	if (sClientHooked || !objc_getClass("CAMCaptureCapabilities")) return;
	HookGestaltIfReady();
	if (!sGestaltHooked) { LOG("AVGestaltGetBoolAnswer not found; leaving Camera untouched"); return; }
	sClientHooked = YES;
	%init(Capabilities);
#ifdef DIAG_LOG
	DiagStart(sAlwaysOverride ? @"ExposureControl-settings-diag.txt" : @"ExposureControl-diag.txt");
#endif
	LOG("client hooks installed");
}

static void ClientImageAdded(const struct mach_header *mh, intptr_t slide) {
	HookClientIfReady();
}

#pragma mark - Daemon: camera config patches

static NSMutableDictionary *Dict(id obj) {
	return [obj isKindOfClass:[NSMutableDictionary class]] ? obj : nil;
}

static id MutableDeepCopy(id obj) {
	if ([obj isKindOfClass:[NSDictionary class]]) {
		NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
		[(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { m[k] = MutableDeepCopy(v); }];
		return m;
	}
	if ([obj isKindOfClass:[NSArray class]]) {
		NSMutableArray *m = [NSMutableArray arrayWithCapacity:[obj count]];
		for (id v in (NSArray *)obj) [m addObject:MutableDeepCopy(v)];
		return m;
	}
	return obj;
}

// iOS 15-16 name devices "com.apple.avfoundation.avcapturedevice.built-in_video:N" (uniqueID);
// iOS 18 uses uniqueName ("Back Camera", "Back Dual Camera").
static NSMutableDictionary *Device(NSArray *devices, NSString *idSuffix, NSString *name) {
	for (id d in devices) {
		NSString *uid = Dict(d)[@"uniqueID"], *un = Dict(d)[@"uniqueName"];
		if ([uid isKindOfClass:[NSString class]] && [uid hasSuffix:idSuffix]) return d;
		if ([un isKindOfClass:[NSString class]] && [un isEqualToString:name]) return d;
	}
	return nil;
}

static NSMutableDictionary *FormatsOf(NSMutableDictionary *device) {
	return Dict(Dict(device[@"MultiStream"])[@"AVCaptureDeviceFormats"]);
}

static void PatchCaptureSession(NSMutableDictionary *plist) {
	NSArray *devices = plist[@"AVCaptureDevices"];
	if (![devices isKindOfClass:[NSArray class]]) return;
	NSMutableDictionary *wideFormats = FormatsOf(Device(devices, @"built-in_video:0", @"Back Camera"));
	NSMutableDictionary *dualFormats = FormatsOf(Device(devices, @"built-in_video:3", @"Back Dual Camera"));

	// Automatic Live Photos: the 11 Pro turns on Live Photo scoring here. The daemon also requires a
	// Neural Engine (+[BWInferenceEngine isNeuralEngineSupported]), which the A12 has.
	NSMutableDictionary *common = Dict(plist[@"AVCaptureDeviceCommonSettings"]);
	if (common) common[@"livePhotoVitalityScoringSupported"] = @YES;

	// View Outside the Frame (XS / XS Max): as on the 11 Pro, declared on the multi-camera
	// device's 12MP and 1080p30 formats, plus ConfigureForSpatialOverCaptureSupport on the main
	// camera's 1080p30. The dual camera's formats are overrides on the wide camera's.
	if (wideFormats && dualFormats) {
		Dict(wideFormats[@"1080p30"])[@"ConfigureForSpatialOverCaptureSupport"] = @YES;
		for (NSString *name in @[@"12MP", @"1080p30"]) {
			NSMutableDictionary *f = Dict(dualFormats[name]);
			if (!f) {
				f = [NSMutableDictionary dictionary];
				id depth = Dict(dualFormats[@"720p30"])[@"SupportedDepthDataFormats"];
				if (depth) f[@"SupportedDepthDataFormats"] = depth;
				dualFormats[name] = f;
			}
			f[@"SpatialOverCaptureSupported"] = @YES;
		}
	}

#ifdef EXP_NIGHTMODE
	// Night mode ("digital flash"): the 11 Pro declares it on the wide camera's 12MP photo format
	// and configures its 30 fps preview formats for it. The XS already has the Smart HDR burst
	// pipeline, UB-LowLight processing times and NightModeMinGainThreshold; it lacks these keys.
	if (wideFormats && IsXS()) {
		Dict(wideFormats[@"12MP"])[@"DigitalFlashSupported"] = @YES;
		for (NSString *name in @[@"1080p30", @"720p30"]) Dict(wideFormats[name])[@"ConfigureForDigitalFlashSupport"] = @YES;
	}
#endif
	LOG("patched AVCaptureSession.plist");
}

#ifdef EXP_NIGHTMODE
// iPhone 11 Pro wide camera (sensor 0x0503) Night mode tuning from iOS 16.6.1 (identical in 18.6.2):
// UBCaptureParameters {AdaptiveBracketingParameters, DigitalFlash* thresholds} and
// NoiseReductionAndSharpeningParameters/StillImage/LowLightUBParameters.
static NSString *const kNightTuning = @"YnBsaXN0MDDSAQIDGV8QFExvd0xpZ2h0VUJQYXJhbWV0ZXJzXxATVUJDYXB0dXJlUGFyYW1ldGVyc9QEBQYHCBYXGF8QJElTUE11bHRpQmFuZE5vaXNlUmVkdWN0aW9uUGFyYW1ldGVyc18QIExvY2FsQ29udHJhc3RFbmhhbmNlbWVudFN0cmVuZ3RoXxAWUmF3Tm9pc2VGaWx0ZXJTdHJlbmd0aF8QEVNoYXJwZW5pbmdDb250cm9s1AkKCwwNDhMNXxAXQ2hyb21hUHJvY2Vzc2luZ0VuYWJsZWRfEBhDaHJvbWFQcm9jZXNzaW5nU3RyZW5ndGhfEBZMdW1hUHJvY2Vzc2luZ1N0cmVuZ3RoXxAQTXVsdGlCYW5kRW5hYmxlZAmlDxAREhIQChAeEHgQgqUPFBQVERAyEEYQARAtEFDVGhscHR4ft7i5uV8QHEFkYXB0aXZlQnJhY2tldGluZ1BhcmFtZXRlcnNfEDZEaWdpdGFsRmxhc2hBdmFpbGFibGVFZmZlY3RpdmVJbnRlZ3JhdGlvblRpbWVUaHJlc2hvbGRfEC1EaWdpdGFsRmxhc2hSZWNvbW1lbmRSZWd1bGFyRmxhc2hTTlJUaHJlc2hvbGRfEDhEaWdpdGFsRmxhc2hSZWNvbW1lbmRlZEVmZmVjdGl2ZUludGVncmF0aW9uVGltZVRocmVzaG9sZF8QQlN0YXRpb25hcnlEaWdpdGFsRmxhc2hSZWNvbW1lbmRlZEVmZmVjdGl2ZUludGVncmF0aW9uVGltZVRocmVzaG9sZNQgISIjDySJtl8QIEZpcnN0R3JvdXBNYXhOdW1iZXJPZkZyYW1lc0NvdW50V01heE1vZGVXTWluTW9kZV8QH05leHRHcm91cE1heE51bWJlck9mRnJhbWVzQ291bnTfEA8lJicoKSorLC0uLzAxMjM0NV9iaGlqbW5vD3BucXJfECJEeW5hbWljUmFuZ2VDbGlwcGluZ1JhdGlvVGhyZXNob2xkWEhhbmRoZWxkXxAbTGVuc1NoYWRpbmdDb3JyZWN0aW9uQ2VudHJlXxAhTGVuc1NoYWRpbmdDb3JyZWN0aW9uQ29lZmZpY2llbnRzXxASTWF4SW50ZWdyYXRpb25UaW1lXxAfTWF4Tm9taW5hbEVWWmVyb0ludGVncmF0aW9uVGltZVZNaW5BR0Nf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";
#endif

static void PatchCameraSetup(NSMutableDictionary *plist) {
#ifdef EXP_NIGHTMODE
	if (!IsXS()) return;
	NSData *data = [[NSData alloc] initWithBase64EncodedString:kNightTuning options:0];
	NSDictionary *night = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:NULL] : nil;
	NSMutableDictionary *back = Dict(Dict(plist[@"TuningParameters"])[@"PortTypeBack"]);
	if (!night || !back) return;
	[back enumerateKeysAndObjectsUsingBlock:^(id sensorID, id sensor, BOOL *stop) {
		NSMutableDictionary *ub = Dict(Dict(sensor)[@"UBCaptureParameters"]);
		if (ub) [(NSDictionary *)night[@"UBCaptureParameters"] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *s2) { if (!ub[k]) ub[k] = v; }];
		NSMutableDictionary *still = Dict(Dict(Dict(sensor)[@"NoiseReductionAndSharpeningParameters"])[@"StillImage"]);
		if (still && !still[@"LowLightUBParameters"]) still[@"LowLightUBParameters"] = night[@"LowLightUBParameters"];
		LOG("experiment: Night mode tuning added for back sensor %{public}@", sensorID);
	}];
#endif
}

// Takes ownership of `pl` (+1) and returns a +1 object.
static CFPropertyListRef PatchedPlist(CFStringRef name, CFPropertyListRef pl) {
	if (!pl || !name) return pl;
	BOOL session = CFEqual(name, CFSTR("AVCaptureSession.plist"));
	BOOL setup = CFEqual(name, CFSTR("CameraSetup.plist"));
	if (!session && !setup) return pl;
	@try {
		id copy = MutableDeepCopy((__bridge id)pl);
		if (![copy isKindOfClass:[NSMutableDictionary class]]) return pl;
		if (session) PatchCaptureSession(copy); else PatchCameraSetup(copy);
		CFRelease(pl);
		return CFBridgingRetain(copy);
	} @catch (NSException *e) {
		LOG("patching %{public}@ failed: %{public}@", (__bridge NSString *)name, e);
		return pl;
	}
}

static CFPropertyListRef (*orig_FigCaptureCFCreatePropertyList)(CFStringRef name);
static CFPropertyListRef hook_FigCaptureCFCreatePropertyList(CFStringRef name) {
	return PatchedPlist(name, orig_FigCaptureCFCreatePropertyList(name));
}
static CFPropertyListRef (*orig_FigCaptureCFCreatePropertyListForModel)(CFStringRef name, CFStringRef model, int flags);
static CFPropertyListRef hook_FigCaptureCFCreatePropertyListForModel(CFStringRef name, CFStringRef model, int flags) {
	return PatchedPlist(name, orig_FigCaptureCFCreatePropertyListForModel(name, model, flags));
}

#ifdef DIAG_LOG
@interface BWGraph : NSObject
@end
%group DaemonDiag
%hook BWGraph
- (BOOL)_resolveFormats:(id *)error {
	BOOL ok = %orig;
	if (!ok) DiagLog(@"capture graph failed to resolve formats (-666)");
	return ok;
}
%end
%hook BWIrisMovieInfo
- (void)setVitalityScore:(float)score { DiagLog(@"Live Photo vitality score = %.3f", score); %orig; }
%end
%hook FigCaptureMovieFileSinkTailPipelineConfiguration
- (void)setVitalityScoringEnabled:(BOOL)e { DiagLog(@"Live Photo vitality scoring enabled = %d", e); %orig; }
%end
%end
#endif

static BOOL sDaemonHooked;

static void HookDaemonIfReady(void) {
	if (sDaemonHooked) return;
	void *create = dlsym(RTLD_DEFAULT, "FigCaptureCFCreatePropertyList");
	void *createForModel = dlsym(RTLD_DEFAULT, "FigCaptureCFCreatePropertyListForModel");
	if (!create && !createForModel) return;
	sDaemonHooked = YES;
	if (create) MSHookFunction(create, (void *)hook_FigCaptureCFCreatePropertyList, (void **)&orig_FigCaptureCFCreatePropertyList);
	if (createForModel) MSHookFunction(createForModel, (void *)hook_FigCaptureCFCreatePropertyListForModel, (void **)&orig_FigCaptureCFCreatePropertyListForModel);
	LOG("daemon hooks installed (%d/%d)", create != NULL, createForModel != NULL);
#ifdef DIAG_LOG
	DiagStart(@"ExposureControl-daemon-diag.txt");
	if (objc_getClass("BWGraph")) %init(DaemonDiag);
#endif
}

static void DaemonImageAdded(const struct mach_header *mh, intptr_t slide) {
	HookDaemonIfReady();
}

static void ClearCaptureSourceCache(void) {
	// The daemon reuses its parsed camera config from here while model and build are unchanged.
	CFPreferencesSetValue(CFSTR("CaptureSourceInfo"), NULL, CFSTR("com.apple.cameracapture.volatile"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize(CFSTR("com.apple.cameracapture.volatile"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

#pragma mark - Diagnostic log (make package DIAG=DIAG_LOG)

#ifdef DIAG_LOG
static NSMutableArray<NSString *> *sDiagPaths;
static dispatch_queue_t sDiagQueue;
static NSMutableString *sDiagBuffer;

static void DiagStart(NSString *file) {
	if (sDiagQueue) return;
	sDiagQueue = dispatch_queue_create("exposurecontrol.diag", DISPATCH_QUEUE_SERIAL);
	sDiagPaths = [NSMutableArray array];
	sDiagBuffer = [NSMutableString stringWithFormat:@"==== ExposureControl diagnostic log, %@, %@ %@, iOS %@\n", [NSDate date],
		[[NSProcessInfo processInfo] processName], HWModel(), [[NSProcessInfo processInfo] operatingSystemVersionString]];
	for (NSString *dir in @[@"/var/mobile/Library/Caches/com.apple.camera", @"/var/mobile/Library/Caches", @"/var/mobile/Media", @"/var/tmp", NSTemporaryDirectory()]) {
		NSString *path = [dir stringByAppendingPathComponent:file];
		if ([sDiagBuffer writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL]) [sDiagPaths addObject:path];
	}
}

static void DiagLog(NSString *fmt, ...) {
	va_list ap; va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	LOG("diag: %{public}@", msg);
	if (!sDiagQueue) return;
	NSString *text = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
	dispatch_async(sDiagQueue, ^{
		[sDiagBuffer appendString:text];
		NSData *line = [text dataUsingEncoding:NSUTF8StringEncoding];
		for (NSString *path in sDiagPaths) {
			NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
			[h seekToEndOfFile]; [h writeData:line]; [h closeFile];
		}
	});
}
#endif

#pragma mark -

%ctor {
	@autoreleasepool {
		if (!IsSupportedPhone()) { LOG("not an iPhone XS / XS Max / XR (%{public}@); doing nothing", HWModel()); return; }
		NSString *process = [[NSProcessInfo processInfo] processName];
		if ([process isEqualToString:@"mediaserverd"] || [process isEqualToString:@"cameracaptured"]) {
			ClearCaptureSourceCache();
			HookDaemonIfReady();
			if (!sDaemonHooked) _dyld_register_func_for_add_image(DaemonImageAdded);
		} else {
			sAlwaysOverride = [process isEqualToString:@"Preferences"];
			HookClientIfReady();
			if (!sClientHooked || !sGestaltHooked) _dyld_register_func_for_add_image(ClientImageAdded);
		}
	}
}
