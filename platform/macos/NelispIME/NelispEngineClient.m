#import "NelispEngineClient.h"

@interface NelispEngineClient ()
@property(nonatomic) NSTask *task;
@property(nonatomic) NSFileHandle *input;
@property(nonatomic) NSFileHandle *output;
@property(nonatomic) NSMutableData *readBuffer;
@property(nonatomic) NSInteger nextRequestID;
@property(nonatomic) BOOL learningLoaded;
@end

@implementation NelispEngineClient
+ (instancetype)sharedClient {
  static NelispEngineClient *client;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ client = [[self alloc] init]; });
  return client;
}
- (instancetype)init {
  if ((self = [super init])) {
    _readBuffer = [NSMutableData data];
    _nextRequestID = 1;
  }
  return self;
}
- (NSString *)lispString:(NSString *)value {
  NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
  return [NSString stringWithFormat:@"\"%@\"", escaped];
}
- (BOOL)writeForm:(NSString *)form error:(NSError **)error {
  NSData *data = [[form stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
  @try { [self.input writeData:data]; return YES; }
  @catch (NSException *exception) {
    if (error) *error = [NSError errorWithDomain:@"org.nelisp.ime" code:2
      userInfo:@{NSLocalizedDescriptionKey: exception.reason}];
    return NO;
  }
}
- (nullable NSString *)readLine:(NSError **)error {
  while (YES) {
    const uint8_t *bytes = self.readBuffer.bytes;
    for (NSUInteger i = 0; i < self.readBuffer.length; i++) {
      if (bytes[i] == '\n') {
        NSData *line = [self.readBuffer subdataWithRange:NSMakeRange(0, i)];
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
        return [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
      }
    }
    NSData *chunk = [self.output availableData];
    if (chunk.length == 0) {
      if (error) *error = [NSError errorWithDomain:@"org.nelisp.ime" code:3
        userInfo:@{NSLocalizedDescriptionKey: @"NeLisp IME worker exited"}];
      return nil;
    }
    [self.readBuffer appendData:chunk];
  }
}
- (BOOL)start:(NSError **)error {
  if (self.task.running) return YES;
  NSBundle *bundle = NSBundle.mainBundle;
  NSString *runtime = NSProcessInfo.processInfo.environment[@"NELISP_IME_RUNTIME"];
  if (!runtime.length) runtime = [bundle pathForResource:@"nelisp" ofType:nil];
  NSString *root = NSProcessInfo.processInfo.environment[@"NELISP_IME_ROOT"];
  if (!root.length) root = [bundle.resourcePath stringByAppendingPathComponent:@"nelisp-root"];
  if (![[NSFileManager defaultManager] isExecutableFileAtPath:runtime]) {
    if (error) *error = [NSError errorWithDomain:@"org.nelisp.ime" code:1
      userInfo:@{NSLocalizedDescriptionKey: @"NeLisp runtime was not found"}];
    return NO;
  }
  NSPipe *stdinPipe = [NSPipe pipe], *stdoutPipe = [NSPipe pipe], *stderrPipe = [NSPipe pipe];
  self.task = [[NSTask alloc] init];
  self.task.executableURL = [NSURL fileURLWithPath:runtime];
  self.task.arguments = @[@"--repl", @"--no-prompt", @"--no-print"];
  self.task.standardInput = stdinPipe;
  self.task.standardOutput = stdoutPipe;
  self.task.standardError = stderrPipe;
  if (![self.task launchAndReturnError:error]) return NO;
  self.input = stdinPipe.fileHandleForWriting;
  self.output = stdoutPipe.fileHandleForReading;
  [self.readBuffer setLength:0];
  NSArray<NSString *> *files = @[@"packages/nelisp-json/src/nelisp-json.el",
    @"packages/nelisp-ime/src/nelisp-ime-input.el", @"packages/nelisp-ime/src/nelisp-ime.el",
    @"packages/nelisp-ime/src/nelisp-ime-lattice.el",
    @"packages/nelisp-ime/data/nelisp-ime-dictionary-data.el",
    @"packages/nelisp-ime/src/nelisp-ime-protocol.el"];
  NSMutableString *bootstrap = [NSMutableString stringWithString:@"(progn "];
  for (NSString *file in files)
    [bootstrap appendFormat:@"(load %@) ", [self lispString:[root stringByAppendingPathComponent:file]]];
  [bootstrap appendString:@"(princ \"ready\\n\"))"];
  if (![self writeForm:bootstrap error:error]) return NO;
  return [[self readLine:error] isEqualToString:@"ready"];
}
- (nullable NSDictionary *)requestMethod:(NSString *)method params:(NSDictionary *)params error:(NSError **)error {
  @synchronized(self) {
    if (![self start:error]) return nil;
    NSNumber *requestID = @(self.nextRequestID++);
    NSDictionary *request = @{@"jsonrpc":@"2.0", @"id":requestID, @"method":method, @"params":params};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:request options:0 error:error];
    if (!jsonData) return nil;
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString *form = [NSString stringWithFormat:
      @"(princ (concat (nelisp-ime-protocol-handle-json %@) \"\\n\"))", [self lispString:json]];
    if (![self writeForm:form error:error]) return nil;
    NSString *line = [self readLine:error];
    if (!line) return nil;
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:
      [line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error];
    NSDictionary *remoteError = response[@"error"];
    if (remoteError) {
      if (error) *error = [NSError errorWithDomain:@"org.nelisp.ime" code:4
        userInfo:@{NSLocalizedDescriptionKey: remoteError[@"message"] ?: @"IME error"}];
      return nil;
    }
    return response[@"result"];
  }
}
- (NSURL *)learningURL {
  NSURL *base = [[[NSFileManager defaultManager]
    URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
  return [[base URLByAppendingPathComponent:@"NeLispIME" isDirectory:YES]
    URLByAppendingPathComponent:@"learning.json"];
}
- (void)loadLearning {
  @synchronized(self) {
    if (self.learningLoaded) return;
    self.learningLoaded = YES;
  }
  NSData *data = [NSData dataWithContentsOfURL:self.learningURL];
  if (!data) return;
  NSArray *rows = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![rows isKindOfClass:NSArray.class]) return;
  NSError *error;
  if (![self requestMethod:@"ime/learning.import" params:@{@"rows":rows} error:&error])
    NSLog(@"NeLisp IME learning load: %@", error.localizedDescription);
}
- (void)saveLearning {
  NSError *error;
  NSDictionary *result = [self requestMethod:@"ime/learning.export" params:@{} error:&error];
  NSArray *rows = result[@"rows"];
  if (!rows) { NSLog(@"NeLisp IME learning export: %@", error.localizedDescription); return; }
  NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:&error];
  if (!data) return;
  NSURL *url = self.learningURL;
  [[NSFileManager defaultManager] createDirectoryAtURL:[url URLByDeletingLastPathComponent]
    withIntermediateDirectories:YES attributes:nil error:nil];
  if (![data writeToURL:url options:NSDataWritingAtomic error:&error])
    NSLog(@"NeLisp IME learning save: %@", error.localizedDescription);
}
@end
