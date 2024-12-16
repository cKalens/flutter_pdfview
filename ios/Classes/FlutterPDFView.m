#import "FlutterPDFView.h"

@implementation FLTPDFViewFactory {
    NSObject<FlutterBinaryMessenger>* _messenger;
}

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
    self = [super init];
    if (self) {
        _messenger = messenger;
    }
    return self;
}

- (NSObject<FlutterMessageCodec>*)createArgsCodec {
    return [FlutterStandardMessageCodec sharedInstance];
}

- (NSObject<FlutterPlatformView>*)createWithFrame:(CGRect)frame
                                   viewIdentifier:(int64_t)viewId
                                        arguments:(id _Nullable)args {
    FLTPDFViewController* pdfviewController = [[FLTPDFViewController alloc] initWithFrame:frame
                                                                           viewIdentifier:viewId
                                                                                arguments:args
                                                                          binaryMessenger:_messenger];
    return pdfviewController;
}

@end

@implementation FLTPDFViewController {
    FLTPDFView* _pdfView;
    int64_t _viewId;
    FlutterMethodChannel* _channel;
}

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id _Nullable)args
              binaryMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
    self = [super init];
    _pdfView = [[FLTPDFView new] initWithFrame:frame arguments:args controller:self];
    _viewId = viewId;

    @try  {
        NSString* hexBackgroundColor = args[@"hexBackgroundColor"];
        unsigned rgbValue = 0;
        NSScanner *scanner = [NSScanner scannerWithString:hexBackgroundColor];
        [scanner setScanLocation:1]; // bypass '#' character
        [scanner scanHexInt:&rgbValue];

        UIColor *colour = [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0
                                          green:((rgbValue & 0xFF00) >> 8)/255.0
                                           blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
        _pdfView.view.backgroundColor = colour;
    } @catch (NSException *exception) {
    }

    NSString* channelName = [NSString stringWithFormat:@"plugins.endigo.io/pdfview_%lld", viewId];
    _channel = [FlutterMethodChannel methodChannelWithName:channelName binaryMessenger:messenger];
    __weak __typeof__(self) weakSelf = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [weakSelf onMethodCall:call result:result];
    }];

    return self;
}

- (void)onMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([[call method] isEqualToString:@"pageCount"]) {
        [_pdfView getPageCount:call result:result];
    } else if ([[call method] isEqualToString:@"currentPage"]) {
        [_pdfView getCurrentPage:call result:result];
    } else if ([[call method] isEqualToString:@"setPage"]) {
        [_pdfView setPage:call result:result];
    } else if ([[call method] isEqualToString:@"updateSettings"]) {
        [_pdfView onUpdateSettings:call result:result];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)invokeChannelMethod:(NSString *)name arguments:(id)args {
    [_channel invokeMethod:name arguments:args];
}

- (UIView*)view {
    return _pdfView;
}

@end

@implementation FLTPDFView {
    FLTPDFViewController* _controller;
    UIScrollView *_pdfScrollView;
    PDFView* _pdfView;
    NSNumber* _pageCount;
    NSNumber* _currentPage;
    PDFDestination* _currentDestination;
    BOOL _preventLinkNavigation;
    BOOL _autoSpacing;
    PDFPage* _defaultPage;
    BOOL _defaultPageSet;
}

- (instancetype)initWithFrame:(CGRect)frame
                    arguments:(id _Nullable)args
                    controller:(nonnull FLTPDFViewController *)controller {
    self = [super initWithFrame:frame];
    if (self) {
        _controller = controller;

        _pdfView = [[PDFView alloc] initWithFrame: frame];
        _pdfView.delegate = self;

        _autoSpacing = [args[@"autoSpacing"] boolValue];
        BOOL pageFling = [args[@"pageFling"] boolValue];
        BOOL enableSwipe = [args[@"enableSwipe"] boolValue];
        _preventLinkNavigation = [args[@"preventLinkNavigation"] boolValue];

        NSInteger defaultPage = [args[@"defaultPage"] integerValue];

        NSString* filePath = args[@"filePath"];
        FlutterStandardTypedData* pdfData = args[@"pdfData"];

        PDFDocument* document;
        if ([filePath isKindOfClass:[NSString class]]) {
            NSURL* sourcePDFUrl = [NSURL fileURLWithPath:filePath];
            document = [[PDFDocument alloc] initWithURL: sourcePDFUrl];
        } else if ([pdfData isKindOfClass:[FlutterStandardTypedData class]]) {
            NSData* sourcePDFdata = [pdfData data];
            document = [[PDFDocument alloc] initWithData: sourcePDFdata];
        }

        if (document == nil) {
            [_controller invokeChannelMethod:@"onError" arguments:@{@"error" : @"cannot create document: File not in PDF format or corrupted."}];
        } else {
            _pdfView.autoresizesSubviews = true;
            _pdfView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            _pdfView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];

            BOOL swipeHorizontal = [args[@"swipeHorizontal"] boolValue];
            if (swipeHorizontal) {
                _pdfView.displayDirection = kPDFDisplayDirectionHorizontal;
            } else {
                _pdfView.displayDirection = kPDFDisplayDirectionVertical;
            }

            // Sürekli kaydırma, dikey mod
            [_pdfView usePageViewController:pageFling withViewOptions:nil];
            _pdfView.displayMode = enableSwipe ? kPDFDisplaySinglePageContinuous : kPDFDisplaySinglePage;
            _pdfView.document = document;
            _pdfView.autoScales = _autoSpacing;

            _pdfView.maxScaleFactor = 4.0;
            _pdfView.minScaleFactor = _pdfView.scaleFactorForSizeToFit;

            NSString* password = args[@"password"];
            if ([password isKindOfClass:[NSString class]] && [_pdfView.document isEncrypted]) {
                [_pdfView.document unlockWithPassword:password];
            }

            UITapGestureRecognizer *tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap:)];
            tapGestureRecognizer.numberOfTapsRequired = 2;
            tapGestureRecognizer.numberOfTouchesRequired = 1;
            [_pdfView addGestureRecognizer:tapGestureRecognizer];

            NSUInteger pageCount = [document pageCount];

            if (pageCount <= defaultPage) {
                defaultPage = pageCount - 1;
            }

            _defaultPage = [document pageAtIndex: defaultPage];
            __weak __typeof__(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleRenderCompleted:[NSNumber numberWithUnsignedLong: [document pageCount]]];
            });
        }

        if (@available(iOS 11.0, *)) {
            for (id subview in _pdfView.subviews) {
                if ([subview isKindOfClass: [UIScrollView class]]) {
                    _pdfScrollView = subview;
                    _pdfScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
                    if (@available(iOS 13.0, *)) {
                        _pdfScrollView.automaticallyAdjustsScrollIndicatorInsets = NO;
                    }
                    break;
                }
            }
        }

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePageChanged:) name:PDFViewPageChangedNotification object:_pdfView];
        [self addSubview:_pdfView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    _pdfView.frame = self.bounds;
    _pdfView.minScaleFactor = _pdfView.scaleFactorForSizeToFit;
    _pdfView.maxScaleFactor = 4.0;

    if (!_defaultPageSet && _defaultPage != nil) {
        [_pdfView goToPage:_defaultPage];
        _defaultPageSet = YES;
        [self performSelector:@selector(zoomAndCenter) withObject:nil afterDelay:0];
    }
}

- (void)zoomAndCenter {
    PDFPage *currentPage = _pdfView.currentPage;
    if (!currentPage) return;

    printf("selam");
    CGRect pageBounds = [currentPage boundsForBox:kPDFDisplayBoxMediaBox];
    CGFloat pageWidth = pageBounds.size.width;
    CGFloat pageHeight = pageBounds.size.height;
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat viewHeight = self.bounds.size.height;

    _pdfView.autoScales = NO; // Otomatik ölçeklemeyi kapat

    CGFloat desiredScale;
    if (viewWidth > viewHeight) { // Yatay mod
        desiredScale = viewWidth / pageWidth; // Tam genişlik
        desiredScale = desiredScale * 0.8; // Biraz boşluk bırak
    } else { // Dikey mod
        desiredScale = viewWidth / pageWidth;
    }
    desiredScale = MIN(desiredScale, _pdfView.maxScaleFactor);

    _pdfView.scaleFactor = desiredScale;

    CGFloat offsetX = (pageWidth * desiredScale - viewWidth) / 2.0;
    CGFloat offsetY = (pageHeight * desiredScale - viewHeight) / 3.0;

    offsetX = MAX(0, MIN(offsetX, pageWidth * desiredScale - viewWidth));
    offsetY = MAX(0, MIN(offsetY, pageHeight * desiredScale - viewHeight));

    for (UIView *subview in _pdfView.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_PDFDocumentView")]) {
            CGRect subviewFrame = subview.frame;
            subviewFrame.origin.x = -offsetX;
            subviewFrame.origin.y = -offsetY;
            subview.frame = subviewFrame;
            break;
        }
    }
}

- (UIView*)view {
    return _pdfView;
}

- (void)getPageCount:(FlutterMethodCall*)call result:(FlutterResult)result {
    _pageCount = [NSNumber numberWithUnsignedLong: [[_pdfView document] pageCount]];
    result(_pageCount);
}

- (void)getCurrentPage:(FlutterMethodCall*)call result:(FlutterResult)result {
    _currentPage = [NSNumber numberWithUnsignedLong: [_pdfView.document indexForPage: _pdfView.currentPage]];
    result(_currentPage);
}

- (void)setPage:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary<NSString*, NSNumber*>* arguments = [call arguments];
    NSNumber* page = arguments[@"page"];

    [_pdfView goToPage: [_pdfView.document pageAtIndex: page.unsignedLongValue ]];
    result([NSNumber numberWithBool: YES]);
}

- (void)onUpdateSettings:(FlutterMethodCall*)call result:(FlutterResult)result {
    result(nil);
}

-(void)handlePageChanged:(NSNotification*)notification {
    // Cihaz yönünü öğren
        UIInterfaceOrientation orientation = [UIApplication sharedApplication].windows.firstObject.windowScene.interfaceOrientation;

        // Eğer yatay moddaysa yakınlaştır
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            //Scroll To top yapılması gerekiyor
        } else {
            // Dikey modda otomatik ölçeklemeye geri dön
            _pdfView.autoScales = YES;
        }
    [_controller invokeChannelMethod:@"onPageChanged" arguments:@{@"page" : [NSNumber numberWithUnsignedLong: [_pdfView.document indexForPage: _pdfView.currentPage]], @"total" : [NSNumber numberWithUnsignedLong: [_pdfView.document pageCount]]}];
}

-(void)handleRenderCompleted: (NSNumber*)pages {
    [_controller invokeChannelMethod:@"onRender" arguments:@{@"pages" : pages}];
}

- (void)PDFViewWillClickOnLink:(PDFView *)sender
                       withURL:(NSURL *)url{
    if (!_preventLinkNavigation){
        NSDictionary *options = @{};
        [[UIApplication sharedApplication] openURL:url options:options completionHandler:^(BOOL success) {
            if (success) {
                NSLog(@"URL opened successfully");
            } else {
                NSLog(@"Failed to open URL");
            }
        } ];
    }
    [_controller invokeChannelMethod:@"onLinkHandler" arguments:url.absoluteString];
}

- (void) onDoubleTap: (UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        if ([_pdfView scaleFactor] == _pdfView.scaleFactorForSizeToFit) {
            CGPoint point = [recognizer locationInView:_pdfView];
            PDFPage* page = [_pdfView pageForPoint:point nearest:YES];
            PDFPoint pdfPoint = [_pdfView convertPoint:point toPage:page];
            PDFRect rect = [page boundsForBox:kPDFDisplayBoxMediaBox];
            PDFDestination* destination = [[PDFDestination alloc] initWithPage:page atPoint:CGPointMake(pdfPoint.x - (rect.size.width / 4),pdfPoint.y + (rect.size.height / 4))];
            [UIView animateWithDuration:0.2 animations:^{
                self->_pdfView.scaleFactor = self->_pdfView.scaleFactorForSizeToFit *2;
                [self->_pdfView goToDestination:destination];
            }];
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                self->_pdfView.scaleFactor = self->_pdfView.scaleFactorForSizeToFit;
            }];
        }
    }
}

@end
