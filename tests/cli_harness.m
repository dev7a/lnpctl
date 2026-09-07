// Exercise the production formatting and confirmation code with synthetic data.
// This harness never calls the application entry point or writes a privacy store.
#define main LNPApplicationMain
#import "../src/lnpctl.m"
#undef main

int main(int argc, const char **argv) { @autoreleasepool {
    @try {
        if (argc < 2) LNPFail(@"Expected plan, sanitize, confirm, or menu.");
        NSString *command = @(argv[1]);
        if ([command isEqual:@"confirm"]) {
            puts(confirm(@"Apply this prepared cleanup?") ? "RESULT:yes" : "RESULT:no");
        } else if ([command isEqual:@"menu"]) {
            printf("RESULT:%s\n", promptLine(@"Choice: ").UTF8String);
        } else {
            if (argc != 3) LNPFail(@"Expected a synthetic JSON fixture.");
            NSData *data = [NSData dataWithContentsOfFile:@(argv[2])];
            id fixture = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (!fixture) LNPFail(@"Invalid test fixture.");
            if ([command isEqual:@"plan"]) printPlan(@"/synthetic/backup", fixture);
            else if ([command isEqual:@"sanitize"]) {
                NSMutableArray *safe = [NSMutableArray new];
                for (id value in fixture) [safe addObject:clean(value)];
                json(safe);
            } else LNPFail(@"Unknown harness command.");
        }
        return 0;
    } @catch (NSException *error) {
        fprintf(stderr, "%s\n", error.reason.UTF8String);
        return 1;
    }
} }
