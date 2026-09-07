#import <Foundation/Foundation.h>
#import "../src/LNPUI.h"

int main(void) {
    @autoreleasepool {
        NSMutableArray *rows = [NSMutableArray array];
        for (int i = 0; i < 80; i++) {
            [rows addObject:@{
                @"token": [NSString stringWithFormat:@"token-%02d", i],
                @"label": i == 0 ? @"Alpha \033]52;c;INJECT\a 网络 café" : [NSString stringWithFormat:@"Application %02d", i],
                @"identifier": [NSString stringWithFormat:@"com.example.application.%02d", i],
                @"path": [NSString stringWithFormat:@"/Users/example/Builds/%@/Application-%02d.app/Contents/MacOS/LongExecutable", [@"long-directory/" stringByPaddingToLength:160 withString:@"long-directory/" startingAtIndex:0], i],
                @"path_status": i % 2 ? @"missing" : @"exists",
                @"permission": i % 2 ? @"denied" : @"allowed",
                @"user": @"example (501)",
                @"configuration": [NSString stringWithFormat:@"config-%02d", i]
            }];
        }
        @try {
            NSArray *selected = LNPSelectEntries(rows, @"Macintosh HD — picker test");
            if (!selected) puts("RESULT:cancel");
            else printf("RESULT:%s\n", [[selected componentsJoinedByString:@","] UTF8String]);
            return 0;
        } @catch (NSException *exception) {
            fprintf(stderr, "ERROR:%s\n", exception.reason.UTF8String);
            return 2;
        }
    }
}
