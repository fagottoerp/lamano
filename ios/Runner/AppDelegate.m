#include "AppDelegate.h"
#include "GeneratedPluginRegistrant.h"
#import <FirebaseCore/FirebaseCore.h>
#import <UserNotifications/UserNotifications.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  if ([FIRApp defaultApp] == nil) {
    [FIRApp configure];
  }
  if (@available(iOS 10.0, *)) {
    [UNUserNotificationCenter currentNotificationCenter].delegate = (id<UNUserNotificationCenterDelegate>) self;
  }

  // Ask iOS to register for remote notifications and receive an APNs token.
  [application registerForRemoteNotifications];

  // Override point for customization after application launch.
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
  const unsigned char *dataBuffer = (const unsigned char *)[deviceToken bytes];
  if (!dataBuffer) {
    return;
  }
  NSMutableString *hexToken = [NSMutableString stringWithCapacity:(deviceToken.length * 2)];
  for (NSUInteger i = 0; i < deviceToken.length; ++i) {
    [hexToken appendFormat:@"%02x", dataBuffer[i]];
  }
  NSLog(@"APNs device token: %@", hexToken);
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
  NSLog(@"Failed to register for remote notifications: %@", error);
}

- (void)didInitializeImplicitFlutterEngine:(NSObject<FlutterImplicitEngineBridge>*)engineBridge {
  [GeneratedPluginRegistrant registerWithRegistry:engineBridge.pluginRegistry];
}

@end
