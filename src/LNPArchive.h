#import <Foundation/Foundation.h>

void LNPFail(NSString *message) __attribute__((noreturn));
NSString *LNPSHA256(NSData *data);
id LNPDecode(NSData *data);
NSData *LNPEncode(id value);
BOOL LNPEqual(id left, id right);

// Parses property-list values only. Never instantiates archived Apple classes.
NSArray<NSDictionary *> *LNPEntries(NSData *data, NSString *dataRoot);
NSData *LNPEdit(NSData *original, NSArray<NSString *> *tokens);
