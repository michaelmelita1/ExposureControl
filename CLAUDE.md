# ExposureControl (iPhone XS / XS Max / XR? — A12): handoff notes
Separate project from 11Cam (do not share code/package). User's repo: michaelmelita1/ExposureControl (0.0.1: hooks isZoomPlatterSupported,
zoomDialStyle=1, isExposureSliderSupported). Target iOS 15–18, rootless arm64e.

Firmware (user's PC Downloads/11Cam15-firmware): iPhoneXS-16.6.1, iPhoneXS-18.7.12, iPhone11Pro-16.6.1, iPhone11Pro-18.6.2 (D321/D331/D331p, D421/D431).
- iOS 18 IPSW system dmgs are AEA (.dmg.aea). Device-VM tool: ~/tools/aeaimg.py + apfsread spec "aea:IPSW:member:BASE64KEY".
  Keys: 11 Pro 18.6.2 043-19053-102.dmg.aea = e68R6N869G5yanbwI8Tja9FskATCUuettAqFfQNBbWw= (ipsw embedded db);
  XS 18.7.12 094-32673-046.dmg.aea = E17QZ4HcKezX1YSacvPrmRbJ/R0hQQaxKrCQ8itCOQo= (fcs PEM fetched by the user from wkms-public).
- iOS 18 AVCaptureSession.plist renamed device keys: uniqueID/localizedName/deviceType/position -> uniqueName ("Back Dual Camera"),
  baseCaptureDeviceUniqueName. Match devices by either.
- XS iOS 16 shared cache: Downloads/11Cam15-firmware/_work/xs16dsc (arm64e, .symbols). Helpers on the device VM: ~/w/dis16.sh ADDR N,
  ~/w/callers16.py SEL..., ~/w/cmcap16_syms.txt.

Findings
- ImagingNetworks: 11 Pro has deep_fusion(.H12), deep_fusion_lowlight, personsemantics, segmentation, smartcam, tracking, text_localization.
  XS (H11) ships everything except deep_fusion / deep_fusion_lowlight (and on 16 smartcam present; on 18 hairnet added).
- XS sensors: wide 0x0403, tele 0x0356 (same tele as 11 Pro), front 0x0414. 11 Pro wide 0x0503.
- XS lacks vs 11 Pro: DeepFusion*/DigitalFlash* format keys, LowLightUBParameters, DeepFusionParameters, SemanticRendering, livePhotoVitalityScoringSupported,
  ConfigureForSpatialOverCaptureSupport (11Cam's X approach applies: dual 12MP/1080p30 SpatialOverCaptureSupported + wide 1080p30 Configure...).
- Deep Fusion gate (CMCapture 16, captureSession_createCameraSourcePipelineConfigurationFromParsedConfiguration+0x430):
  FigCaptureSoftISPEnabled() && format.isDeepFusionSupported && maxQualityPrioritization==3. SoftISPEnabled reads the camera
  source's AttributesDictionary["SoftISP"] (hardware/ISP attribute) -> XS reports no Soft ISP. DF effectively hardware-gated.
- Night mode: digital flash = format DigitalFlashSupported/ConfigureForDigitalFlashSupport (+ UB-LowLight stream, LowLightUBParameters tuning).
  11 Pro has both UB-LowLight and DeepFusion-LowLight -> a UB (non-DF) Night mode path exists; XS has the UB pipeline. No hard A13 check found yet.
- +[BWInferenceEngine isNeuralEngineSupported] true on A12 -> Auto Live Photos (vitality scoring) feasible on XS with livePhotoVitalityScoringSupported.

## 0.1.0 build (Nov 2026)
- Tweak.x rewritten in the 11Cam style: AVGestalt bool overrides during -[CAMCaptureCapabilities initWithHostProcess:] (Settings: always):
  ExposureBiasWithoutExposureLock, LivePhotoAuto, SpatialOverCapture (XS only), EXP_NIGHTMODE: RearFacingLowLightCameraCapability.
  iOS 15 exposure pref CAMFeatureDevelopmentForceExposureSlider (gone in 18). _zoomPlatterSupported ivar = YES.
- Daemon (mediaserverd / cameracaptured; iOS 18 has no mediaserverd, camera daemon is /usr/libexec/cameracaptured):
  livePhotoVitalityScoringSupported in AVCaptureDeviceCommonSettings; VOTF keys (wide 1080p30 Configure..., dual 12MP/1080p30);
  EXP_NIGHTMODE: wide 12MP DigitalFlashSupported, wide 1080p30/720p30 ConfigureForDigitalFlashSupport, and the 11 Pro 0x0503
  UBCaptureParameters {AdaptiveBracketingParameters, DigitalFlash* thresholds} + StillImage/LowLightUBParameters merged into the XS back sensor.
  The XS already has UB-LowLight processing times and NightModeMinGainThreshold.
- iOS 18 string check of the XS 18.7.12 cache: AVGestaltGetBoolAnswer, initWithHostProcess:, _zoomPlatterSupported, _exposureSliderSupported,
  FigCaptureCFCreatePropertyList(ForModel), CaptureSourceInfo / com.apple.cameracapture.volatile all still present.
  XS 18 cache extracted to Downloads/11Cam15-firmware/_work/xs18dsc (no real .symbols: decmpfs-compressed, too slow; ipsw can't parse it).
- Built fat arm64 + arm64e (Linux toolchain makes old-ABI arm64e; the arm64 slice is the fallback). Model check: D321AP, D331AP, D331pAP, N841AP.
