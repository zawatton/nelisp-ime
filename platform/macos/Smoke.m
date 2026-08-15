#import <Foundation/Foundation.h>
#import "NelispIME/NelispEngineClient.h"

int main(void) {
  @autoreleasepool {
    NSError *error;
    NelispEngineClient *client = [NelispEngineClient sharedClient];
    NSDictionary *initialized = [client requestMethod:@"ime/initialize"
      params:@{@"protocolVersion":@1} error:&error];
    if (!initialized || ![initialized[@"engine"] isEqualToString:@"nelisp-ime"]) {
      NSLog(@"initialize failed: %@", error); return 1;
    }
    NSString *sessionID = @"macos-smoke";
    if (![client requestMethod:@"ime/session.open"
      params:@{@"sessionId":sessionID,@"inputStyle":@"kana"} error:&error]) {
      NSLog(@"open failed: %@", error); return 2;
    }
    NSDictionary *result = [client requestMethod:@"ime/session.feed"
      params:@{@"sessionId":sessionID,
               @"event":@{@"op":@"insert",@"text":@"かんじ"}} error:&error];
    if (!result || ![result[@"reading"] isEqualToString:@"かんじ"] ||
        ![result[@"preedit"] isEqualToString:@"漢字"]) {
      NSLog(@"feed failed: %@ result=%@", error, result); return 3;
    }
    [client requestMethod:@"ime/session.close" params:@{@"sessionId":sessionID} error:nil];
  }
  return 0;
}
