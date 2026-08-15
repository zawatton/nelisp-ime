#import "NelispInputController.h"
#import "NelispEngineClient.h"

@interface NelispInputController ()
@property(nonatomic) NSString *sessionID;
@property(nonatomic) NSInteger candidateIndex;
@property(nonatomic) NSInteger candidateCount;
@property(nonatomic) NSArray<NSString *> *currentCandidates;
@property(nonatomic) IMKCandidates *candidateWindow;
@property(nonatomic) NSInteger activeSegment;
@property(nonatomic) NSInteger segmentCount;
@property(nonatomic) NSString *currentPreedit;
@end

@implementation NelispInputController
- (instancetype)initWithServer:(IMKServer *)server delegate:(id)delegate client:(id)client {
  if ((self = [super initWithServer:server delegate:delegate client:client])) {
    _sessionID = NSUUID.UUID.UUIDString;
    _candidateWindow = [[IMKCandidates alloc] initWithServer:server
      panelType:kIMKSingleColumnScrollingCandidatePanel];
    [[NelispEngineClient sharedClient] requestMethod:@"ime/session.open"
      params:@{@"sessionId":_sessionID, @"inputStyle":@"kana"} error:nil];
    [[NelispEngineClient sharedClient] loadLearning];
  }
  return self;
}
- (void)inputControllerWillClose {
  [[NelispEngineClient sharedClient] requestMethod:@"ime/session.close"
    params:@{@"sessionId":self.sessionID} error:nil];
  [self.candidateWindow hide];
  [super inputControllerWillClose];
}
- (nullable NSString *)portableCodeForKeyCode:(unsigned short)keyCode {
  static NSDictionary<NSNumber *, NSString *> *codes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ codes = @{
    @18:@"Digit1",@19:@"Digit2",@20:@"Digit3",@21:@"Digit4",@23:@"Digit5",
    @22:@"Digit6",@26:@"Digit7",@28:@"Digit8",@25:@"Digit9",@29:@"Digit0",
    @27:@"Minus",@24:@"Equal",@12:@"KeyQ",@13:@"KeyW",@14:@"KeyE",@15:@"KeyR",
    @17:@"KeyT",@16:@"KeyY",@32:@"KeyU",@34:@"KeyI",@31:@"KeyO",@35:@"KeyP",
    @33:@"BracketLeft",@30:@"BracketRight",@0:@"KeyA",@1:@"KeyS",@2:@"KeyD",
    @3:@"KeyF",@5:@"KeyG",@4:@"KeyH",@38:@"KeyJ",@40:@"KeyK",@37:@"KeyL",
    @41:@"Semicolon",@39:@"Quote",@6:@"KeyZ",@7:@"KeyX",@8:@"KeyC",@9:@"KeyV",
    @11:@"KeyB",@45:@"KeyN",@46:@"KeyM",@43:@"Comma",@47:@"Period",
    @44:@"Slash",@42:@"Backslash",@93:@"IntlYen",@94:@"IntlRo"}; });
  return codes[@(keyCode)];
}
- (void)applyResult:(NSDictionary *)result client:(id)sender {
  NSString *commit = result[@"commit"];
  if ((id)commit != NSNull.null && commit.length) {
    self.currentPreedit = @"";
    self.currentCandidates = @[];
    self.candidateCount = 0;
    [self.candidateWindow hide];
    [sender insertText:commit replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
    [[NelispEngineClient sharedClient] saveLearning];
    return;
  }
  NSString *preedit = result[@"preedit"] ?: @"";
  self.currentPreedit = preedit;
  NSArray *candidates = result[@"candidates"];
  self.currentCandidates = (id)candidates == NSNull.null ? @[] : candidates;
  self.candidateCount = self.currentCandidates.count;
  NSNumber *index = result[@"candidate-index"];
  self.candidateIndex = (id)index == NSNull.null ? 0 : index.integerValue;
  NSArray *segments = result[@"segments"];
  self.segmentCount = (id)segments == NSNull.null ? 0 : segments.count;
  NSNumber *active = result[@"active-segment"];
  self.activeSegment = (id)active == NSNull.null ? 0 : active.integerValue;
  [sender setMarkedText:preedit selectionRange:NSMakeRange(preedit.length, 0)
    replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
  if (self.candidateWindow.isVisible) [self.candidateWindow updateCandidates];
}
- (NSArray *)candidates:(id)sender { (void)sender; return self.currentCandidates ?: @[]; }
- (void)candidateSelectionChanged:(NSAttributedString *)candidateString {
  NSInteger index = [self.currentCandidates indexOfObject:candidateString.string];
  if (index != NSNotFound)
    [self sendEvent:@{@"op":@"select-candidate",@"index":@(index)} client:self.client];
}
- (void)candidateSelected:(NSAttributedString *)candidateString {
  NSInteger index = [self.currentCandidates indexOfObject:candidateString.string];
  if (index != NSNotFound)
    [self sendEvent:@{@"op":@"select-candidate",@"index":@(index)} client:self.client];
  [self sendEvent:@{@"op":@"commit"} client:self.client];
}
- (BOOL)sendEvent:(NSDictionary *)event client:(id)sender {
  NSError *error;
  NSDictionary *result = [[NelispEngineClient sharedClient] requestMethod:@"ime/session.feed"
    params:@{@"sessionId":self.sessionID, @"event":event} error:&error];
  if (!result) { NSLog(@"NeLisp IME: %@", error.localizedDescription); return NO; }
  [self applyResult:result client:sender];
  return YES;
}
- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
  if (event.type != NSEventTypeKeyDown) return NO;
  if (event.modifierFlags & (NSEventModifierFlagCommand |
                             NSEventModifierFlagControl |
                             NSEventModifierFlagOption)) return NO;
  switch (event.keyCode) {
  case 36: case 76: return [self sendEvent:@{@"op":@"commit"} client:sender];
  case 51: return [self sendEvent:@{@"op":@"backspace"} client:sender];
  case 53: return [self sendEvent:@{@"op":@"cancel"} client:sender];
  case 49:
    if (self.candidateCount > 1) {
      NSInteger next = (self.candidateIndex + 1) % self.candidateCount;
      BOOL handled = [self sendEvent:@{@"op":@"select-candidate",@"index":@(next)} client:sender];
      [self.candidateWindow updateCandidates];
      [self.candidateWindow selectCandidateWithIdentifier:next];
      [self.candidateWindow show:kIMKLocateCandidatesBelowHint];
      return handled;
    }
    break;
  case 123:
    if (self.activeSegment > 0)
      return [self sendEvent:@{@"op":@"select-segment",
                               @"index":@(self.activeSegment - 1)} client:sender];
    break;
  case 124:
    if (self.activeSegment + 1 < self.segmentCount)
      return [self sendEvent:@{@"op":@"select-segment",
                               @"index":@(self.activeSegment + 1)} client:sender];
    break;
  default: break;
  }
  NSString *code = [self portableCodeForKeyCode:event.keyCode];
  if (!code) {
    if (self.currentPreedit.length && event.characters.length) {
      if (![self sendEvent:@{@"op":@"commit"} client:sender]) return NO;
      [sender insertText:event.characters
        replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
      return YES;
    }
    return NO;
  }
  BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
  return [self sendEvent:@{@"op":@"key",@"code":code,@"shift":@(shift)} client:sender];
}
@end
