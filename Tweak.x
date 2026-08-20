#import <UIKit/UIKit.h>

%hook CAMCaptureCapabilities
-(bool)isZoomPlatterSupported {
                return YES;
}
-(long long)zoomDialStyle {
		return 1;
}
-(bool)isExposureSliderSupported {
                return YES;
}
%end
