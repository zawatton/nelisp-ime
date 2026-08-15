#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface NelispEngineClient : NSObject
+ (instancetype)sharedClient;
- (nullable NSDictionary *)requestMethod:(NSString *)method
                                  params:(NSDictionary *)params
                                   error:(NSError **)error;
- (void)loadLearning;
- (void)saveLearning;
@end
NS_ASSUME_NONNULL_END
