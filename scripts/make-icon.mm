#import <AppKit/AppKit.h>
#include <cmath>
#include <initializer_list>

// One original silhouette in 18-point coordinates for both identities.
// App artwork adds material and lighting; the status item stays a template.
static CGAffineTransform microphoneAngle() {
    CGAffineTransform angle = CGAffineTransformMakeTranslation(5.4, 6.2);
    return CGAffineTransformRotate(angle, -M_PI_4);
}
static CGPathRef microphone() {
    CGMutablePathRef mark = CGPathCreateMutable();
    CGAffineTransform angle = microphoneAngle();
    // Rounded ball grille and a tapered handheld body, separated by a collar gap.
    CGPathAddEllipseInRect(mark, &angle, CGRectMake(-3.2, 6.4, 6.4, 6.4));
    CGMutablePathRef body = CGPathCreateMutable();
    CGPathMoveToPoint(body, nullptr, -1.8, 5.9);
    CGPathAddLineToPoint(body, nullptr, -1.05, 0.6);
    CGPathAddQuadCurveToPoint(body, nullptr, -0.98, 0, -0.4, 0);
    CGPathAddLineToPoint(body, nullptr, 0.4, 0);
    CGPathAddQuadCurveToPoint(body, nullptr, 0.98, 0, 1.05, 0.6);
    CGPathAddLineToPoint(body, nullptr, 1.8, 5.9);
    CGPathAddQuadCurveToPoint(body, nullptr, 0, 5.3, -1.8, 5.9);
    CGPathCloseSubpath(body);
    CGPathAddPath(mark, &angle, body); CGPathRelease(body);
    // A short cable loop makes the silhouette distinct at menu bar sizes.
    CGMutablePathRef cable = CGPathCreateMutable();
    CGPathMoveToPoint(cable, nullptr, 4.9, 5.65);
    CGPathAddLineToPoint(cable, nullptr, 4.2, 4.9);
    CGPathAddCurveToPoint(cable, nullptr, 2.05, 2.65, 4.7, 0.8, 6.6, 2.6);
    CGPathAddLineToPoint(cable, nullptr, 8.7, 4.6);
    CGPathAddCurveToPoint(cable, nullptr, 10.8, 6.6, 13.9, 3.7, 12.0, 1.8);
    CGPathAddLineToPoint(cable, nullptr, 10.95, 0.75);
    CGPathRef stroke = CGPathCreateCopyByStrokingPath(cable, nullptr, 1.35,
        kCGLineCapRound, kCGLineJoinRound, 1);
    CGPathAddPath(mark, nullptr, stroke);
    CGPathRelease(stroke); CGPathRelease(cable);
    return mark;
}
static CGPathRef grilleSeam() {
    // One curved band follows the cage around the spherical mic head.
    CGMutablePathRef curve = CGPathCreateMutable();
    CGPathMoveToPoint(curve, nullptr, -3.2, 9.6);
    CGPathAddCurveToPoint(curve, nullptr, -1.9, 8.0, 1.9, 8.0, 3.2, 9.6);
    CGPathRef band = CGPathCreateCopyByStrokingPath(curve, nullptr, 0.42,
        kCGLineCapRound, kCGLineJoinRound, 1);
    CGAffineTransform angle = microphoneAngle();
    CGPathRef seam = CGPathCreateCopyByTransformingPath(band, &angle);
    CGPathRelease(curve); CGPathRelease(band);
    return seam;
}
static NSColor *rgb(double r, double g, double b, double a = 1) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}
static void gradient(NSBezierPath *path, NSArray<NSColor *> *colors, double angle) {
    [[[NSGradient alloc] initWithColors:colors] drawInBezierPath:path angle:angle];
}
static void drawAppIcon() {
    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(100, 100, 824, 824)
        xRadius:184 yRadius:184];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = rgb(0.09, 0.08, 0.27, 0.30);
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSMakeSize(0, -13);
    [shadow set]; [rgb(0.22, 0.25, 0.68) setFill]; [tile fill];
    [NSGraphicsContext restoreGraphicsState];
    // Discord's Blurple #5865F2 is the central brand color.
    gradient(tile, @[rgb(0.23, 0.26, 0.72), rgb(88.0/255, 101.0/255, 242.0/255), rgb(0.49, 0.53, 1)], 76);
    // Soft upper illumination and a thin bevel retain definition in the Dock.
    [NSGraphicsContext saveGraphicsState]; [tile addClip];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat glowColors[] = {0.88, 0.89, 1, 0.24, 0.88, 0.89, 1, 0};
    CGGradientRef glow = CGGradientCreateWithColorComponents(space, glowColors, nullptr, 2);
    CGContextDrawRadialGradient(NSGraphicsContext.currentContext.CGContext, glow,
        CGPointMake(360, 910), 0, CGPointMake(360, 910), 730, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(glow); CGColorSpaceRelease(space);
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(102, 102, 820, 820)
        xRadius:182 yRadius:182];
    [rgb(0.88, 0.89, 1, 0.35) setStroke]; rim.lineWidth = 2; [rim stroke];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 224, 224); CGContextScaleCTM(context, 32, 32);
    CGPathRef mark = microphone(), seam = grilleSeam();
    CGContextSetShadowWithColor(context, CGSizeMake(0, -8), 12, rgb(0.10, 0.08, 0.35, 0.34).CGColor);
    CGContextAddPath(context, mark); CGContextSetFillColorWithColor(context, rgb(0.94, 0.94, 1).CGColor);
    CGContextFillPath(context);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, nullptr);
    CGContextSaveGState(context); CGContextAddPath(context, mark); CGContextClip(context);
    NSBezierPath *material = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 18, 18)];
    gradient(material, @[rgb(0.79, 0.81, 0.96), rgb(0.96, 0.96, 1), NSColor.whiteColor], 90);
    CGContextRestoreGState(context);
    CGContextAddPath(context, mark); CGContextClip(context);
    CGContextAddPath(context, seam); CGContextSetFillColorWithColor(context, rgb(0.31, 0.35, 0.76).CGColor);
    CGContextFillPath(context);
    CGPathRelease(mark); CGPathRelease(seam); CGContextRestoreGState(context);
}
static void drawMenuIcon() {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    // Clip the transparent cage seam separately so overlapping cable strokes
    // remain solid in the monochrome template.
    CGPathRef mark = microphone(), seam = grilleSeam();
    CGContextSetGrayFillColor(context, 0, 1);
    CGContextSaveGState(context);
    CGContextAddRect(context, CGRectMake(0, 0, 18, 18)); CGContextAddPath(context, seam);
    CGContextEOClip(context); CGContextAddPath(context, mark); CGContextFillPath(context);
    CGContextRestoreGState(context);
    CGPathRelease(mark); CGPathRelease(seam);
}
static NSData *png(int size, void (^draw)(void), double canvasSize) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
        pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext setCurrentContext:graphics];
    CGContextScaleCTM(graphics.CGContext, size / canvasSize, size / canvasSize);
    draw(); [NSGraphicsContext restoreGraphicsState];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "Usage: make-icon <resources-directory>\n"); return 1; }
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSString *iconset = [directory stringByAppendingPathComponent:@"MonoMic.iconset"];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
        }
        for (int size : {16, 32, 64, 128, 256, 512, 1024}) {
            NSData *data = png(size, ^{ drawAppIcon(); }, 1024);
            if (!data) { fprintf(stderr, "macOS could not render the icon. Run with graphics access.\n"); return 1; }
            if (size == 16 || size == 32 || size == 128 || size == 256 || size == 512)
                [data writeToFile:[iconset stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d.png", size, size]] atomically:YES];
            if (size == 32 || size == 64 || size == 256 || size == 512 || size == 1024)
                [data writeToFile:[iconset stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d@2x.png", size/2, size/2]] atomically:YES];
            if (size == 1024)
                [data writeToFile:[directory stringByAppendingPathComponent:@"MonoMic.png"] atomically:YES];
        }
        NSMutableData *pdf = [NSMutableData data];
        CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)pdf);
        CGRect bounds = CGRectMake(0, 0, 18, 18);
        CGContextRef context = CGPDFContextCreate(consumer, &bounds, nullptr);
        CGPDFContextBeginPage(context, nullptr);
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO]];
        drawMenuIcon(); [NSGraphicsContext restoreGraphicsState];
        CGPDFContextEndPage(context); CGPDFContextClose(context);
        CGContextRelease(context); CGDataConsumerRelease(consumer);
        NSString *menuPath = [directory stringByAppendingPathComponent:@"MenuBarIcon.pdf"];
        if (![pdf writeToFile:menuPath atomically:YES]) return 1;
        [png(144, ^{ drawMenuIcon(); }, 18) writeToFile:[directory stringByAppendingPathComponent:@"MenuBarIcon-preview.png"] atomically:YES];
        NSData *preview = png(1280, ^{
            [rgb(0.94, 0.95, 0.96) setFill]; NSRectFill(NSMakeRect(0, 0, 640, 640));
            NSAffineTransform *position = [NSAffineTransform transform];
            [position translateXBy:16 yBy:194]; [position scaleBy:0.28];
            [NSGraphicsContext saveGraphicsState]; [position concat]; drawAppIcon();
            [NSGraphicsContext restoreGraphicsState];
            NSDictionary *title = @{NSFontAttributeName:[NSFont systemFontOfSize:28 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName:rgb(0.13, 0.16, 0.18)};
            [@"Mono Mic" drawAtPoint:NSMakePoint(324, 426) withAttributes:title];
            NSDictionary *caption = @{NSFontAttributeName:[NSFont systemFontOfSize:13],
                NSForegroundColorAttributeName:rgb(0.35, 0.39, 0.42)};
            [@"App icon + menu bar symbol" drawAtPoint:NSMakePoint(324, 402) withAttributes:caption];
            NSImage *menu = [[NSImage alloc] initWithContentsOfFile:menuPath];
            for (int dark = 0; dark < 2; ++dark) {
                double y = dark ? 262 : 324;
                [(dark ? rgb(0.13, 0.15, 0.17) : NSColor.whiteColor) setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(324, y, 278, 44) xRadius:10 yRadius:10] fill];
                NSColor *ink = dark ? NSColor.whiteColor : rgb(0.10, 0.12, 0.14);
                NSImage *tinted = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
                    [menu drawInRect:rect]; [ink setFill]; NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn); return YES;
                }];
                [tinted drawInRect:NSMakeRect(338, y + 13, 18, 18)];
                [@"Mono Mic" drawAtPoint:NSMakePoint(370, y + 14) withAttributes:@{
                    NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSForegroundColorAttributeName:ink}];
            }
            [@"64 px" drawAtPoint:NSMakePoint(64, 150) withAttributes:caption];
            [@"32 px" drawAtPoint:NSMakePoint(176, 150) withAttributes:caption];
            for (int size : {64, 32}) {
                [NSGraphicsContext saveGraphicsState];
                NSAffineTransform *small = [NSAffineTransform transform];
                [small translateXBy:size == 64 ? 50 : 176 yBy:178]; [small scaleBy:size / 1024.0];
                [small concat]; drawAppIcon(); [NSGraphicsContext restoreGraphicsState];
            }
        }, 640);
        if (![preview writeToFile:[directory stringByAppendingPathComponent:@"Icon-preview.png"] atomically:YES]) return 1;
    }
    return 0;
}
