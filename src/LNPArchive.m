#import "LNPArchive.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <membership.h>
#include <pwd.h>
#include <sys/stat.h>

void LNPFail(NSString *message) {
    @throw [NSException exceptionWithName:@"LNPError" reason:message userInfo:nil];
}

NSString *LNPSHA256(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    if (data.length > UINT32_MAX) LNPFail(@"Input exceeds checksum size limit.");
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *result = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [result appendFormat:@"%02x", bytes[i]];
    return result;
}

id LNPDecode(NSData *data) {
    NSError *error = nil;
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
    if (!value) LNPFail([@"Invalid property list: " stringByAppendingString:error.localizedDescription]);
    return value;
}

NSData *LNPEncode(id value) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data) LNPFail(error.localizedDescription);
    return data;
}

static uint32_t (*uidValue)(CFTypeRef);
static CFTypeID (*uidType)(void);

static BOOL isUID(id value) {
    if (!uidValue) {
        uidValue = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetValue");
        uidType = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetTypeID");
        if (!uidValue || !uidType) LNPFail(@"This macOS version does not expose archive UID inspection.");
    }
    return value && CFGetTypeID((__bridge CFTypeRef)value) == uidType();
}

BOOL LNPEqual(id a, id b) {
    if (!a || !b) return a == b;
    if (isUID(a) || isUID(b)) return isUID(a) && isUID(b) &&
        uidValue((__bridge CFTypeRef)a) == uidValue((__bridge CFTypeRef)b);
    if ([a isKindOfClass:NSArray.class]) {
        if (![b isKindOfClass:NSArray.class] || [a count] != [b count]) return NO;
        for (NSUInteger i = 0; i < [a count]; i++) if (!LNPEqual(a[i], b[i])) return NO;
        return YES;
    }
    if ([a isKindOfClass:NSDictionary.class]) {
        if (![b isKindOfClass:NSDictionary.class] || [a count] != [b count]) return NO;
        for (id key in a) if (!LNPEqual(a[key], b[key])) return NO;
        return YES;
    }
    return [a isEqual:b];
}

static NSUInteger indexOf(id uid, NSArray *objects) {
    if (!isUID(uid)) LNPFail(@"Expected an archive reference.");
    NSUInteger n = uidValue((__bridge CFTypeRef)uid);
    if (n >= objects.count) LNPFail(@"Archive reference is outside its object table.");
    return n;
}

static id resolve(id uid, NSArray *objects) {
    if (!uid) return nil;
    NSUInteger n = indexOf(uid, objects);
    return n ? objects[n] : nil;
}

static NSDictionary *dictionary(id value) {
    if (![value isKindOfClass:NSDictionary.class]) LNPFail(@"Unexpected archive dictionary shape.");
    return value;
}

static NSString *className(id value, NSArray *objects) {
    if (![value isKindOfClass:NSDictionary.class] || !value[@"$class"]) return nil;
    id name = dictionary(resolve(value[@"$class"], objects))[@"$classname"];
    if (![name isKindOfClass:NSString.class]) LNPFail(@"Invalid archive class description.");
    return name;
}

static NSString *textField(id uid, NSArray *objects) {
    id value = resolve(uid, objects);
    if (value && ![value isKindOfClass:NSString.class]) LNPFail(@"Unexpected archive string field.");
    return value ?: @"";
}

static BOOL boolField(NSDictionary *rule, NSString *key) {
    id value = rule[key];
    if (![value isKindOfClass:NSNumber.class] ||
        (![value isEqual:@0] && ![value isEqual:@1]))
        LNPFail([@"Missing or unsupported permission field: " stringByAppendingString:key]);
    return [value boolValue];
}

static void validateReferences(id value, NSUInteger count, NSUInteger depth) {
    if (depth > 128) LNPFail(@"Archive nesting exceeds the supported limit.");
    if (isUID(value)) {
        if (uidValue((__bridge CFTypeRef)value) >= count) LNPFail(@"Out-of-range archive reference.");
    } else if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value) validateReferences(value[key], count, depth + 1);
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) validateReferences(item, count, depth + 1);
    }
}

static NSMutableDictionary *archive(NSData *data) {
    NSMutableDictionary *a = (NSMutableDictionary *)dictionary(LNPDecode(data));
    if (![a[@"$archiver"] isEqual:@"NSKeyedArchiver"] || ![a[@"$version"] isEqual:@100000] ||
        ![a[@"$objects"] isKindOfClass:NSArray.class] || ![a[@"$objects"] count] ||
        ![a[@"$objects"][0] isEqual:@"$null"] || ![a[@"$top"] isKindOfClass:NSDictionary.class])
        LNPFail(@"Unsupported NetworkExtension archive format.");
    validateReferences(a, [a[@"$objects"] count], 0);
    return a;
}

static NSString *userLabel(NSString *configuration) {
    NSString *uuidString = [configuration substringFromIndex:[@"com.apple.preferences.networkprivacy-" length]];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    if (!uuid) LNPFail(@"Unrecognized Local Network configuration identity.");
    uuid_t bytes; [uuid getUUIDBytes:bytes];
    id_t uid; int kind;
    if (!mbr_uuid_to_id(bytes, &uid, &kind) && kind == ID_TYPE_UID) {
        struct passwd *pw = getpwuid(uid);
        if (pw) return @(pw->pw_name);
    }
    return uuidString;
}

static NSString *pathStatus(NSString *path, NSString *root) {
    if (!path.length) return @"Not recorded";
    if (![path isAbsolutePath]) return @"Unknown";
    if (!root) return @"Not checked";
    // /System content is on the paired System volume, not the mounted Data volume.
    if (![root isEqual:@"/"] && ([path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/"]))
        return @"Not checked";
    NSString *candidate = [root stringByAppendingPathComponent:[path substringFromIndex:1]];
    struct stat st;
    if (!stat(candidate.fileSystemRepresentation, &st)) return @"Exists";
    return (errno == ENOENT || errno == ENOTDIR) ? @"Missing" : @"Unknown";
}

static NSArray<NSDictionary *> *entries(NSMutableDictionary *a, NSString *digest, NSString *root,
                                        NSMutableDictionary *owners) {
    NSArray *objects = a[@"$objects"];
    NSMutableArray *result = [NSMutableArray new];
    NSMutableSet *seenConfigs = [NSMutableSet new];
    NSDictionary *top = a[@"$top"];
    for (NSString *key in [[top allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (!isUID(top[key])) continue;
        id config = resolve(top[key], objects);
        if (![className(config, objects) isEqual:@"NEConfiguration"]) continue;
        NSString *name = textField(config[@"Name"], objects);
        if (![name hasPrefix:@"com.apple.preferences.networkprivacy-"]) continue;
        NSNumber *configIndex = @(indexOf(top[key], objects));
        if ([seenConfigs containsObject:configIndex]) LNPFail(@"A privacy configuration is referenced more than once.");
        [seenConfigs addObject:configIndex];
        NSString *user = userLabel(name);
        NSDictionary *controller = dictionary(resolve(config[@"PathController"], objects));
        if (![className(controller, objects) isEqual:@"NEPathController"])
            LNPFail(@"Unsupported Local Network path controller.");
        NSUInteger arrayIndex = indexOf(controller[@"Rules"], objects);
        if (owners) owners[@(arrayIndex)] = @[configIndex, @(indexOf(config[@"PathController"], objects))];
        NSDictionary *rules = dictionary(objects[arrayIndex]);
        NSString *arrayClass = className(rules, objects);
        if ((! [arrayClass isEqual:@"NSArray"] && ![arrayClass isEqual:@"NSMutableArray"]) ||
            ![rules[@"NS.objects"] isKindOfClass:NSArray.class]) LNPFail(@"Unsupported path-rule array.");
        NSUInteger position = 0;
        for (id ruleRef in rules[@"NS.objects"]) {
            NSDictionary *rule = dictionary(resolve(ruleRef, objects));
            if (![className(rule, objects) isEqual:@"NEPathRule"]) LNPFail(@"Unsupported Local Network rule class.");
            NSString *identifier = textField(rule[@"SigningIdentifier"], objects);
            NSString *path = textField(rule[@"Path"], objects);
            // These are configuration defaults, not application entries. Never offer them for removal.
            if ([identifier hasPrefix:@"PathRuleDefault"]) { position++; continue; }
            NSString *label = identifier.length ? identifier : @"(no signing identifier)";
            for (NSString *component in path.pathComponents)
                if ([component.pathExtension.lowercaseString isEqual:@"app"]) label = component.stringByDeletingPathExtension;
            BOOL decided = boolField(rule, @"MulticastPreferenceSet");
            BOOL denied = boolField(rule, @"DenyMulticast");
            NSString *tokenSource = [NSString stringWithFormat:@"%@:%@:%lu:%lu", digest, configIndex,
                (unsigned long)arrayIndex, (unsigned long)position];
            [result addObject:@{
                @"token": LNPSHA256([tokenSource dataUsingEncoding:NSUTF8StringEncoding]),
                @"label": label, @"identifier": identifier, @"path": path,
                @"path_status": pathStatus(path, root), @"permission": decided ? (denied ? @"Denied" : @"Allowed") : @"Unset",
                @"user": user, @"configuration": name,
                @"_array": @(arrayIndex), @"_position": @(position)
            }];
            position++;
        }
    }
    return result;
}

NSArray<NSDictionary *> *LNPEntries(NSData *data, NSString *root) {
    return entries(archive(data), LNPSHA256(data), root, nil);
}

static NSUInteger referenceCount(id value, NSUInteger target) {
    if (isUID(value)) return uidValue((__bridge CFTypeRef)value) == target;
    NSUInteger count = 0;
    if ([value isKindOfClass:NSArray.class]) for (id v in value) count += referenceCount(v, target);
    if ([value isKindOfClass:NSDictionary.class]) for (id key in value) count += referenceCount(value[key], target);
    return count;
}

NSData *LNPEdit(NSData *original, NSArray<NSString *> *tokens) {
    if (![tokens isKindOfClass:NSArray.class] || !tokens.count) LNPFail(@"Select at least one entry.");
    NSMutableSet *wanted = [NSMutableSet new];
    for (id token in tokens) {
        if (![token isKindOfClass:NSString.class] || [token length] != 64 || [wanted containsObject:token])
            LNPFail(@"Invalid or duplicate entry selection.");
        [wanted addObject:token];
    }
    NSMutableDictionary *a = archive(original);
    NSMutableDictionary *owners = [NSMutableDictionary new];
    NSArray *rows = entries(a, LNPSHA256(original), nil, owners);
    NSMutableDictionary<NSNumber *, NSMutableIndexSet *> *removals = [NSMutableDictionary new];
    for (NSDictionary *row in rows) if ([wanted containsObject:row[@"token"]]) {
        NSNumber *array = row[@"_array"];
        if (!removals[array]) removals[array] = [NSMutableIndexSet new];
        [removals[array] addIndex:[row[@"_position"] unsignedIntegerValue]];
        [wanted removeObject:row[@"token"]];
    }
    if (wanted.count) LNPFail(@"Selection does not match this snapshot. Scan again; nothing was changed.");
    for (NSNumber *array in removals) {
        // Every ancestor must have a unique incoming reference. A private rules array
        // is still shared indirectly when its controller or configuration is aliased.
        // Count opaque and unreachable references too: their semantics are unknown.
        if (referenceCount(a, array.unsignedIntegerValue) != 1)
            LNPFail(@"Selected rules share an archive array. This layout is not supported.");
        for (NSNumber *owner in owners[array])
            if (referenceCount(a, owner.unsignedIntegerValue) != 1)
                LNPFail(@"Selected rules share an archive configuration or path controller. This layout is not supported.");
    }
    // Validate every selected ownership path before changing any archive object.
    for (NSNumber *array in removals) {
        NSMutableDictionary *rules = a[@"$objects"][array.unsignedIntegerValue];
        NSMutableArray *refs = [rules[@"NS.objects"] mutableCopy];
        [refs removeObjectsAtIndexes:removals[array]];
        rules[@"NS.objects"] = refs;
    }
    NSData *edited = LNPEncode(a);
    if (!LNPEqual(a, archive(edited))) LNPFail(@"Archive did not survive a lossless serialization round trip.");
    return edited;
}
