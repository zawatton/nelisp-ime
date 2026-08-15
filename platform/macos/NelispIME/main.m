#import <Cocoa/Cocoa.h>
#import <InputMethodKit/InputMethodKit.h>
int main(int argc, const char *argv[]) {
  (void)argc;
  (void)argv;
  @autoreleasepool {
    NSBundle *bundle = NSBundle.mainBundle;
    IMKServer *server = [[IMKServer alloc]
      initWithName:bundle.infoDictionary[@"InputMethodConnectionName"]
      bundleIdentifier:bundle.bundleIdentifier];
    if (!server) return 1;
    [[NSRunLoop currentRunLoop] run];
  }
  return 0;
}
