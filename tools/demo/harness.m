#import <Foundation/Foundation.h>
#import "LNPUI.h"

int main(void) {
    @autoreleasepool {
        NSArray *names = @[@"Atlas Preview", @"Beacon", @"Canvas", @"Harbor Preview", @"Lumen", @"Orbit", @"Relay", @"Studio Notes"];
        NSMutableArray *rows = [NSMutableArray array];
        for (NSUInteger i = 0; i < names.count; i++) {
            BOOL stale = i == 0 || i == 3;
            NSString *identifier = [[names[i] lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"-"];
            [rows addObject:@{@"token": [NSString stringWithFormat:@"demo-%lu", i],
                @"label": names[i], @"identifier": [@"com.example." stringByAppendingString:identifier],
                @"path": [NSString stringWithFormat:@"/Applications/%@.app/Contents/MacOS/%@", names[i], names[i]],
                @"path_status": stale ? @"missing" : @"exists",
                @"permission": i == 3 ? @"denied" : @"allowed", @"user": @"demo (501)",
                @"configuration": [NSString stringWithFormat:@"demo-configuration-%lu", i]}];
        }
        NSArray *selected = LNPSelectEntries(rows, @"Macintosh HD - synthetic demo");
        printf("DEMO_SELECTION:%s\n", [[selected componentsJoinedByString:@","] UTF8String]);
    }
    return 0;
}
