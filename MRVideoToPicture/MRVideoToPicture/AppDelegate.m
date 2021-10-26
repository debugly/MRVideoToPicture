//
//  AppDelegate.m
//  MRVideoToPicture
//
//  Created by Matt Reach on 2020/12/25.
//

#import "AppDelegate.h"
#import "MR0x40ViewController.h"

@interface AppDelegate ()

@property (nonatomic, strong) NSWindowController *rootWinController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:CGRectZero styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
//    window.title = @"视频抽帧器";
    window.titleVisibility = NSWindowTitleVisible;
    window.titlebarAppearsTransparent = YES;
    window.movableByWindowBackground = YES;
//    window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    [window setMinSize:CGSizeMake(300, 300)];
    NSWindowController *rootWinController = [[NSWindowController alloc] initWithWindow:window];
    MR0x40ViewController *vc = [[MR0x40ViewController alloc] init];
    window.contentViewController = vc;
    [window center];
    [window makeKeyWindow];
    [rootWinController showWindow:nil];
    
    self.rootWinController = rootWinController;
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}


@end
