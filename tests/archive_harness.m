#import "../src/LNPArchive.h"

int main(int argc, const char **argv) { @autoreleasepool {
    @try {
        if (argc < 3) LNPFail(@"scan FILE or edit FILE OUTPUT TOKEN...");
        NSData *data = [NSData dataWithContentsOfFile:@(argv[2])];
        if (!data) LNPFail(@"Cannot read fixture");
        if (!strcmp(argv[1], "scan")) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:LNPEntries(data, nil) options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
        } else if (!strcmp(argv[1], "edit") && argc >= 5) {
            NSMutableArray *tokens = [NSMutableArray new];
            for (int i = 4; i < argc; i++) [tokens addObject:@(argv[i])];
            NSData *edited = LNPEdit(data, tokens);
            if (![edited writeToFile:@(argv[3]) options:NSDataWritingWithoutOverwriting error:nil]) LNPFail(@"Cannot create result");
        } else LNPFail(@"Invalid harness arguments");
        return 0;
    } @catch (NSException *error) { fprintf(stderr, "%s\n", error.reason.UTF8String); return 1; }
} }
