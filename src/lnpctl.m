#import "LNPArchive.h"
#import "LNPUI.h"
#import "LNPVersion.h"
#include <sys/acl.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static NSString *const storeRelative = @"Library/Preferences/com.apple.networkextension.plist";
static NSString *const defaultBackups = @"/Users/Shared/lnpctl/backups";
static NSString *const recoveryName = @"lnpctl-recovery";
static NSString *const recoveryAttribute = @"com.dev7a.lnpctl.recovery";
static NSString *const legacyRecoveryAttribute = @"dev.alessandrobologna.lnpctl.recovery";
static const NSUInteger maxFileSize = 64 * 1024 * 1024;
static NSFileManager *fm;
static NSData *executable;
static NSString *executablePath;

static void posixFail(NSString *action) {
    LNPFail([NSString stringWithFormat:@"%@: %s", action, strerror(errno)]);
}

static NSString *absolute(NSString *path) {
    if (![path isAbsolutePath]) path = [fm.currentDirectoryPath stringByAppendingPathComponent:path];
    return path.stringByStandardizingPath;
}

static void noSymlinks(NSString *path) {
    NSString *part = @"/";
    for (NSString *name in absolute(path).pathComponents) {
        if ([name isEqual:@"/"]) continue;
        part = [part stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(part.fileSystemRepresentation, &st)) posixFail([@"Inspect " stringByAppendingString:part]);
        if (S_ISLNK(st.st_mode)) LNPFail([@"Symbolic links are not accepted here: " stringByAppendingString:part]);
    }
}

static NSData *readFile(NSString *path) {
    noSymlinks(path);
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) posixFail([@"Read " stringByAppendingString:path]);
    @try {
        struct stat st;
        if (fstat(fd, &st)) posixFail(@"Inspect open file");
        if (!S_ISREG(st.st_mode) || st.st_size < 0 || (uint64_t)st.st_size > maxFileSize)
            LNPFail(@"Expected a regular file no larger than 64 MiB.");
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
        NSUInteger offset = 0;
        while (offset < data.length) {
            ssize_t count = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) LNPFail(@"File changed or could not be read completely.");
            offset += (NSUInteger)count;
        }
        char extra;
        if (read(fd, &extra, 1) != 0) LNPFail(@"File changed while being read.");
        return data;
    } @finally { close(fd); }
}

static void syncDirectory(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) posixFail(@"Open directory for sync");
    int rc = fsync(fd); int saved = errno; close(fd); errno = saved;
    if (rc) posixFail(@"Sync directory");
}

static void writeFD(int fd, NSData *data) {
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t n = write(fd, (const char *)data.bytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) posixFail(@"Write file");
        offset += (NSUInteger)n;
    }
}

static void writeNew(NSData *data, NSString *path, mode_t mode) {
    noSymlinks(path.stringByDeletingLastPathComponent);
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode);
    if (fd < 0) posixFail([@"Create " stringByAppendingString:path]);
    @try {
        writeFD(fd, data);
        if (fsync(fd)) posixFail(@"Sync new file");
    } @catch (NSException *error) {
        unlink(path.fileSystemRepresentation);
        @throw;
    } @finally { close(fd); }
    syncDirectory(path.stringByDeletingLastPathComponent);
}

// A root-owned leaf is not trustworthy if an ancestor lets another user replace it.
// Walk through pinned directory descriptors, validating each edge before creating it.
static struct stat trustedDirectoryFD(int fd) {
    struct stat st;
    if (fstat(fd, &st)) posixFail(@"Inspect trusted directory");
    if (!S_ISDIR(st.st_mode) || st.st_uid != 0)
        LNPFail(@"Backup paths require root-owned directories throughout their ancestor chain.");
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (!acl) {
        if (errno != ENOENT) posixFail(@"Inspect ancestor ACL");
        return st;
    }
    @try {
        acl_entry_t entry;
        int rc = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
        while (rc == 0) {
            acl_tag_t tag;
            acl_permset_t permissions;
            if (acl_get_tag_type(entry, &tag) || acl_get_permset(entry, &permissions))
                posixFail(@"Inspect ancestor ACL entry");
            if (tag == ACL_EXTENDED_ALLOW) {
                const acl_perm_t mutation[] = {ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
                    ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
                    ACL_WRITE_SECURITY, ACL_CHANGE_OWNER};
                for (NSUInteger i = 0; i < sizeof(mutation) / sizeof(mutation[0]); i++) {
                    int allowed = acl_get_perm_np(permissions, mutation[i]);
                    if (allowed < 0) posixFail(@"Inspect ancestor ACL permission");
                    if (allowed) LNPFail(@"Backup path has an ancestor ACL granting mutation access. Use a protected root-owned location.");
                }
            } else if (tag != ACL_EXTENDED_DENY) LNPFail(@"Unsupported ancestor ACL entry.");
            rc = acl_get_entry(acl, ACL_NEXT_ENTRY, &entry);
        }
        if (rc < 0 && errno != EINVAL) posixFail(@"Read ancestor ACL");
    } @finally { acl_free(acl); }
    return st;
}

static void trustedDirectory(NSString *path, BOOL create) {
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) posixFail(@"Open filesystem root");
    @try {
        struct stat parent = trustedDirectoryFD(fd);
        for (NSString *name in absolute(path).pathComponents) {
            if ([name isEqual:@"/"]) continue;
            BOOL replaceable = (parent.st_mode & 0022) && !(parent.st_mode & S_ISVTX);
            int child = openat(fd, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0 && errno == ENOENT && create) {
                if (replaceable) LNPFail(@"Cannot create backups beneath a directory writable by other users without the sticky bit.");
                if (mkdirat(fd, name.fileSystemRepresentation, 0700)) posixFail(@"Create protected backup parent");
                if (fsync(fd)) posixFail(@"Sync backup parent creation");
                child = openat(fd, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            }
            if (child < 0) posixFail(@"Open backup ancestor without symbolic links");
            @try {
                struct stat next = trustedDirectoryFD(child);
                // macOS protects firmlink directories such as Data/Users with SF_NOUNLINK.
                // This protects that existing edge only, not arbitrary children of Data.
                if (replaceable && !(next.st_flags & SF_NOUNLINK))
                    LNPFail(@"Backup path can be replaced through a writable ancestor. Use a protected root-owned location.");
                close(fd); fd = child; child = -1;
                parent = next;
            } @finally { if (child >= 0) close(child); }
        }
        if (create && fsync(fd)) posixFail(@"Sync backup directory");
    } @finally { close(fd); }
}

static void makeParents(NSString *path) {
    trustedDirectory(path, YES);
}

static void requireRoot(void) {
    if (geteuid()) LNPFail(@"Run this command with sudo. In Recovery Terminal you are already root.");
}

static void privateBackup(NSString *path) {
    trustedDirectory(path, NO);
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0077))
        LNPFail(@"Backup directory must be owned by root and accessible only to its owner (mode 0700).");
    acl_t acl = acl_get_file(path.fileSystemRepresentation, ACL_TYPE_EXTENDED);
    if (acl) {
        acl_entry_t entry;
        BOOL hasEntries = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) == 0;
        acl_free(acl);
        if (hasEntries) LNPFail(@"Backup directory has additional ACL access. Use a private directory without ACL entries.");
    } else if (errno != ENOENT) posixFail(@"Inspect backup directory access");
}

static NSString *uuidForPath(NSString *path) {
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
    struct __attribute__((packed)) { uint32_t length; uuid_t uuid; } value;
    if (getattrlist(path.fileSystemRepresentation, &attrs, &value, sizeof(value), 0)) posixFail(@"Read volume UUID");
    if (value.length != sizeof(value)) LNPFail(@"Unexpected volume identity result.");
    return [[NSUUID alloc] initWithUUIDBytes:value.uuid].UUIDString;
}

static NSDictionary *volume(NSString *root) {
    root = absolute(root);
    noSymlinks(root);
    NSString *candidate = [root stringByAppendingPathComponent:storeRelative];
    noSymlinks(candidate);
    struct statfs st;
    if (statfs(candidate.fileSystemRepresentation, &st)) posixFail(@"Read target volume");
    if (strcmp(st.f_fstypename, "apfs") || !(st.f_flags & MNT_LOCAL))
        LNPFail(@"The permission store must be on a local APFS volume.");
    if (st.f_flags & MNT_IGNORE_OWNERSHIP)
        LNPFail(@"Ownership is disabled on this volume. Mount it with ownership enabled before using lnpctl.");
    NSString *mount = @(st.f_mntonname);
    if (![root isEqual:@"/"] && ![root isEqual:mount])
        LNPFail(@"--volume must name the mounted Data volume itself, not a directory inside it.");
    NSString *store = [mount stringByAppendingPathComponent:storeRelative];
    noSymlinks(store);
    NSString *name = nil;
    [[NSURL fileURLWithPath:mount] getResourceValue:&name forKey:NSURLVolumeNameKey error:nil];
    return @{@"uuid": uuidForPath(store), @"name": name ?: mount.lastPathComponent,
        @"mount": mount, @"store": store};
}

static NSArray *volumes(void) {
    struct statfs *mounts;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    NSMutableArray *result = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (int i = 0; i < count; i++) {
        if (strcmp(mounts[i].f_fstypename, "apfs")) continue;
        @try {
            NSDictionary *v = volume(@(mounts[i].f_mntonname));
            if (![seen containsObject:v[@"mount"]]) { [result addObject:v]; [seen addObject:v[@"mount"]]; }
        } @catch (NSException *error) { /* Other APFS volumes do not contain this store. */ }
    }
    return result;
}

static void requireOffline(NSDictionary *target) {
    struct statfs active, dest;
    if (statfs("/Library/Preferences", &active) || statfs([target[@"store"] fileSystemRepresentation], &dest))
        posixFail(@"Identify active filesystem");
    if (!memcmp(&active.f_fsid, &dest.f_fsid, sizeof(fsid_t)))
        LNPFail(@"Refusing to write the currently booted Data volume. Shut down and apply from Recovery.");
    if (dest.f_flags & MNT_RDONLY) LNPFail(@"The selected volume is read-only. Mount/unlock its Data volume in Disk Utility.");
}

static NSDictionary *metadata(NSString *path) {
    noSymlinks(path);
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) posixFail(@"Read file metadata");
    @try {
        struct stat st;
        if (fstat(fd, &st)) posixFail(@"Read file metadata");
        if (!S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_flags != 0)
            LNPFail(@"Store must be a regular file with one link and no filesystem flags.");
        ssize_t length = flistxattr(fd, NULL, 0, 0);
        if (length < 0 || (uint64_t)length > maxFileSize) LNPFail(@"Cannot read extended-attribute names.");
        NSMutableData *names = [NSMutableData dataWithLength:(NSUInteger)length];
        if (length && flistxattr(fd, names.mutableBytes, names.length, 0) != length)
            LNPFail(@"Extended attributes changed while reading.");
        NSMutableDictionary *xattrs = [NSMutableDictionary new];
        const char *bytes = names.bytes;
        NSUInteger position = 0;
        while (position < names.length) {
            size_t n = strnlen(bytes + position, names.length - position);
            if (n == names.length - position) LNPFail(@"Malformed extended-attribute name.");
            NSString *key = [[NSString alloc] initWithBytes:bytes + position length:n encoding:NSUTF8StringEncoding];
            if (!key) LNPFail(@"An extended-attribute name is not valid UTF-8.");
            ssize_t size = fgetxattr(fd, bytes + position, NULL, 0, 0, 0);
            if (size < 0 || (uint64_t)size > maxFileSize) LNPFail(@"Cannot read extended attribute.");
            NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
            if (fgetxattr(fd, bytes + position, data.mutableBytes, data.length, 0, 0) != size)
                LNPFail(@"Extended attribute changed while reading.");
            xattrs[key] = data;
            position += n + 1;
        }
        acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
        if (!acl && errno == ENOENT) acl = acl_init(0); // No extended ACL is the ordinary case.
        if (!acl) posixFail(@"Read access-control list");
        ssize_t aclLength = 0;
        char *aclText = acl_to_text(acl, &aclLength);
        if (!aclText) { acl_free(acl); posixFail(@"Encode access-control list"); }
        NSString *aclString = [[NSString alloc] initWithBytes:aclText length:(NSUInteger)aclLength encoding:NSUTF8StringEncoding];
        acl_free(aclText); acl_free(acl);
        if (!aclString) LNPFail(@"Access-control list is not valid UTF-8.");
        return @{@"uid": @(st.st_uid), @"gid": @(st.st_gid), @"mode": @(st.st_mode & 07777),
            @"acl": aclString, @"xattrs": xattrs};
    } @finally { close(fd); }
}

static void validateMetadata(NSDictionary *m) {
    if (![m isKindOfClass:NSDictionary.class]) LNPFail(@"Invalid backup metadata.");
    for (NSString *key in @[@"uid", @"gid", @"mode"])
        if (![m[key] isKindOfClass:NSNumber.class] || [m[key] longLongValue] < 0 || [m[key] unsignedLongLongValue] > UINT32_MAX)
            LNPFail(@"Invalid ownership or mode in backup.");
    if ([m[@"uid"] unsignedIntValue] != 0 || [m[@"mode"] unsignedIntValue] > 0777 ||
        ![m[@"acl"] isKindOfClass:NSString.class] || ![m[@"xattrs"] isKindOfClass:NSDictionary.class])
        LNPFail(@"Unsupported permission-store metadata in backup.");
    for (id key in m[@"xattrs"]) if (![key isKindOfClass:NSString.class] ||
        ![key length] || [key rangeOfString:@"\0"].location != NSNotFound ||
        ![m[@"xattrs"][key] isKindOfClass:NSData.class]) LNPFail(@"Invalid extended attribute in backup.");
    acl_t acl = acl_from_text([m[@"acl"] UTF8String]);
    if (!acl) LNPFail(@"Invalid access-control list in backup.");
    acl_free(acl);
}

static void setMetadata(int fd, NSDictionary *m) {
    validateMetadata(m);
    if (fchown(fd, [m[@"uid"] unsignedIntValue], [m[@"gid"] unsignedIntValue]) ||
        fchmod(fd, [m[@"mode"] unsignedShortValue])) posixFail(@"Preserve owner and mode");
    for (NSString *key in m[@"xattrs"]) {
        NSData *data = m[@"xattrs"][key];
        if (fsetxattr(fd, key.UTF8String, data.bytes, data.length, 0, 0)) posixFail(@"Preserve extended attribute");
    }
    acl_t acl = acl_from_text([m[@"acl"] UTF8String]);
    int rc = acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED); int saved = errno;
    acl_free(acl); errno = saved;
    if (rc) posixFail(@"Preserve access-control list");
}

static void replaceStore(NSData *chosen, NSDictionary *chosenMeta, NSString *path,
                         NSData *expected, NSDictionary *expectedMeta) {
    NSString *temp = [path stringByAppendingFormat:@".lnpctl-%@", NSUUID.UUID.UUIDString];
    noSymlinks(path);
    int fd = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) posixFail(@"Create replacement");
    BOOL installed = NO;
    @try {
        writeFD(fd, chosen);
        setMetadata(fd, chosenMeta);
        if (fsync(fd)) posixFail(@"Sync replacement");
        if (![readFile(temp) isEqual:chosen] || !LNPEqual(metadata(temp), chosenMeta))
            LNPFail(@"Replacement content or metadata did not verify; original is untouched.");
        if (![readFile(path) isEqual:expected] || !LNPEqual(metadata(path), expectedMeta))
            LNPFail(@"Target changed before replacement; original is untouched.");
        if (rename(temp.fileSystemRepresentation, path.fileSystemRepresentation)) posixFail(@"Install replacement");
        installed = YES;
        syncDirectory(path.stringByDeletingLastPathComponent);
        if (![readFile(path) isEqual:chosen] || !LNPEqual(metadata(path), chosenMeta))
            LNPFail(@"Installed content or metadata did not verify.");
    } @catch (NSException *error) {
        if (installed) LNPFail([@"The file was replaced, but final verification failed: " stringByAppendingString:error.reason]);
        @throw;
    } @finally { close(fd); if (!installed) unlink(temp.fileSystemRepresentation); }
}

static NSString *clean(NSString *s) {
    return LNPTerminalText(s);
}

static void json(id value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data) LNPFail(error.localizedDescription);
    fwrite(data.bytes, 1, data.length, stdout); puts("");
}

static NSArray *publicRows(NSArray *rows) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *row in rows) {
        NSMutableDictionary *copy = [row mutableCopy];
        [copy removeObjectForKey:@"_array"]; [copy removeObjectForKey:@"_position"];
        [out addObject:copy];
    }
    return out;
}

static NSString *newName(NSString *prefix) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; f.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    return [NSString stringWithFormat:@"%@-%@-%@", prefix, [f stringFromDate:NSDate.date], NSUUID.UUID.UUIDString];
}

static NSString *defaultBackupDirectory(NSDictionary *v) {
    return [v[@"mount"] stringByAppendingPathComponent:[defaultBackups substringFromIndex:1]];
}

static NSString *recoveryPath(NSDictionary *v, NSString *base) {
    (void)v;
    // Data's mount root may be group-writable. Keep the executable inside the
    // validated private backup parent, where its name cannot be substituted.
    return [base stringByAppendingPathComponent:recoveryName];
}

static NSString *shellQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *recoveryInstructions(NSDictionary *v, NSString *base) {
    NSString *launcher = recoveryPath(v, base);
    NSString *prefix = [v[@"mount"] stringByAppendingString:@"/"];
    NSString *relative = [launcher hasPrefix:prefix] ? [launcher substringFromIndex:prefix.length] : [launcher substringFromIndex:1];
    NSString *example = [@"/Volumes/Data" stringByAppendingPathComponent:relative];
    return [NSString stringWithFormat:
        @"NEXT: APPLY FROM RECOVERY\n\n"
        "1. Save or photograph this checklist before shutting down.\n"
        "   No timestamped backup path is needed; the launcher lists your backups.\n"
        "2. Save your work and choose Apple menu > Shut Down. Wait until the Mac is off.\n"
        "3. Press and hold the power button until startup options appear.\n"
        "   Choose Options > Continue. Select a user and enter the password if asked.\n"
        "4. In Disk Utility, choose View > Show All Devices. Mount/unlock the Data\n"
        "   volume for %@ if needed, then quit Disk Utility.\n"
        "5. Choose Utilities > Terminal. Run: ls /Volumes\n"
        "   If the Data volume is mounted as Data, run:\n\n"
        "   %@\n\n"
        "   If its mount name differs, replace Data with that name; keep the quotes.\n"
        "   If the file is missing, check that the Data volume is mounted/unlocked.\n"
        "   Use this command instead of older instructions for a mount-root launcher.\n"
        "6. Choose the backup by date and removal count. Review its selected entries.\n"
        "   Choose a to apply, then y at the final confirmation.\n"
        "   A stale-plan refusal means return to normal macOS and prepare again.\n"
        "7. After successful verification, run: reboot\n"
        "8. Check System Settings > Privacy & Security > Local Network and test\n"
        "   the applications you kept.\n\n"
        "To undo: repeat steps 2-5, choose the backup, then r to restore. Review\n"
        "the whole-file restore warning and confirm with y. Reboot after success.\n"
        "Leave SIP enabled. This tool never shuts down or reboots the Mac for you.\n",
        clean(v[@"name"]), clean(shellQuote(example))];
}

static void installRecovery(NSDictionary *v, NSString *base) {
    requireRoot();
    base = absolute(base);
    privateBackup(base);
    if (![uuidForPath(base) isEqual:v[@"uuid"]]) LNPFail(@"Recovery launcher and backups must be on the selected Data volume.");
    NSString *path = recoveryPath(v, base);
    NSData *marker = [@"1" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *meta = @{@"uid": @0, @"gid": @0, @"mode": @0700, @"acl": @"!#acl 1\n",
        @"xattrs": @{recoveryAttribute: marker}};
    struct stat st;
    if (!lstat(path.fileSystemRepresentation, &st)) {
        NSDictionary *oldMeta = metadata(path);
        // Upgrade only an exactly matching launcher from the previous namespace.
        // Ownership, mode, ACL and the complete xattr set must still match.
        NSMutableDictionary *legacyMeta = [meta mutableCopy];
        legacyMeta[@"xattrs"] = @{legacyRecoveryAttribute: marker};
        BOOL currentMetadata = LNPEqual(oldMeta, meta);
        if (!currentMetadata && !LNPEqual(oldMeta, legacyMeta))
            LNPFail(@"Recovery launcher path is occupied by an unexpected file; it was not replaced.");
        NSData *old = readFile(path);
        if (![old isEqual:executable] || !currentMetadata) replaceStore(executable, meta, path, old, oldMeta);
        return;
    }
    if (errno != ENOENT) posixFail(@"Inspect Recovery launcher path");
    noSymlinks(path.stringByDeletingLastPathComponent);
    NSString *temp = [path stringByAppendingFormat:@"-%@", NSUUID.UUID.UUIDString];
    int fd = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0700);
    if (fd < 0) posixFail(@"Create Recovery launcher");
    @try {
        writeFD(fd, executable); setMetadata(fd, meta);
        if (fsync(fd)) posixFail(@"Sync Recovery launcher");
        if (![readFile(temp) isEqual:executable] || !LNPEqual(metadata(temp), meta)) LNPFail(@"Recovery launcher did not verify.");
        if (renamex_np(temp.fileSystemRepresentation, path.fileSystemRepresentation, RENAME_EXCL)) posixFail(@"Install Recovery launcher without overwriting an existing file");
        syncDirectory(path.stringByDeletingLastPathComponent);
    } @finally { close(fd); unlink(temp.fileSystemRepresentation); }
}

static void saveBackup(NSString *directory, NSDictionary *v, NSData *original, NSDictionary *meta,
                       NSData *edited, NSArray *selectedRows, NSString *sourceKind) {
    requireRoot(); validateMetadata(meta);
    directory = absolute(directory);
    if ([directory.lastPathComponent isEqual:recoveryName])
        LNPFail(@"The backup name lnpctl-recovery is reserved for the Recovery launcher. Choose another name.");
    NSString *parent = directory.stringByDeletingLastPathComponent;
    makeParents(parent);
    if (![uuidForPath(parent) isEqual:v[@"uuid"]]) LNPFail(@"Keep backups on the selected Data volume so they are available in Recovery.");
    if (mkdir(directory.fileSystemRepresentation, 0700)) posixFail(@"Create new backup directory");
    acl_t emptyACL = acl_init(0);
    if (!emptyACL) posixFail(@"Create private backup access-control list");
    int aclRC = acl_set_file(directory.fileSystemRepresentation, ACL_TYPE_EXTENDED, emptyACL);
    int aclError = errno; acl_free(emptyACL); errno = aclError;
    if (aclRC) posixFail(@"Remove inherited access from new backup directory");
    syncDirectory(parent);
    privateBackup(directory);
    writeNew(original, [directory stringByAppendingPathComponent:@"original.plist"], 0600);
    if (edited) writeNew(edited, [directory stringByAppendingPathComponent:@"edited.plist"], 0600);
    writeNew(executable, [directory stringByAppendingPathComponent:@"lnpctl"], 0700);
    NSMutableDictionary *m = [@{
        @"format": @1, @"tool_version": @LNP_VERSION, @"kind": sourceKind,
        @"created": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
        @"volume_uuid": v[@"uuid"], @"volume_name": v[@"name"],
        @"source_sha256": LNPSHA256(original), @"executable_sha256": LNPSHA256(executable),
        @"metadata": meta, @"removed": publicRows(selectedRows ?: @[])
    } mutableCopy];
    if (edited) m[@"edited_sha256"] = LNPSHA256(edited);
    // The manifest is the completion marker. Partially written directories cannot validate.
    writeNew(LNPEncode(m), [directory stringByAppendingPathComponent:@"manifest.plist"], 0600);
    NSString *instructions = [NSString stringWithFormat:
        @"lnpctl backup\n\nData volume: %@\nVolume UUID: %@\nBackup: %@\n\n%@\n"
        "Direct fallback from this backup directory: ./lnpctl inspect .\n"
        "Then ./lnpctl apply . for cleanup, or ./lnpctl restore . to restore.\n",
        clean(v[@"name"]), v[@"uuid"], clean(directory.lastPathComponent), recoveryInstructions(v, parent)];
    writeNew([instructions dataUsingEncoding:NSUTF8StringEncoding], [directory stringByAppendingPathComponent:@"RECOVERY.txt"], 0600);
    syncDirectory(directory); syncDirectory(parent);
}

static NSDictionary *verifyBackup(NSString *directory, BOOL requireReadableSnapshot) {
    privateBackup(directory);
    id m = LNPDecode(readFile([directory stringByAppendingPathComponent:@"manifest.plist"]));
    if (![m isKindOfClass:NSDictionary.class] || ![m[@"format"] isEqual:@1] ||
        (![m[@"kind"] isEqual:@"cleanup"] && ![m[@"kind"] isEqual:@"snapshot"]) ||
        ![m[@"volume_uuid"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:m[@"volume_uuid"]] ||
        ![m[@"removed"] isKindOfClass:NSArray.class] || ![m[@"created"] isKindOfClass:NSString.class])
        LNPFail(@"Unsupported or incomplete backup manifest.");
    validateMetadata(m[@"metadata"]);
    NSData *original = readFile([directory stringByAppendingPathComponent:@"original.plist"]);
    if (![LNPSHA256(original) isEqual:m[@"source_sha256"]]) LNPFail(@"Original backup checksum mismatch.");
    // A safety copy must preserve even a corrupt or newer-schema current store.
    // Only its post-save verification may skip parsing; restore inputs stay strict.
    if (requireReadableSnapshot || [m[@"kind"] isEqual:@"cleanup"]) LNPEntries(original, nil);
    NSData *binary = readFile([directory stringByAppendingPathComponent:@"lnpctl"]);
    if (![LNPSHA256(binary) isEqual:m[@"executable_sha256"]]) LNPFail(@"Staged executable checksum mismatch.");
    if ([m[@"kind"] isEqual:@"cleanup"]) {
        NSMutableArray *tokens = [NSMutableArray new];
        for (id row in m[@"removed"]) {
            if (![row isKindOfClass:NSDictionary.class] || ![row[@"token"] isKindOfClass:NSString.class]) LNPFail(@"Invalid selected-entry manifest.");
            [tokens addObject:row[@"token"]];
        }
        NSData *edited = readFile([directory stringByAppendingPathComponent:@"edited.plist"]);
        if (![LNPSHA256(edited) isEqual:m[@"edited_sha256"]]) LNPFail(@"Edited backup checksum mismatch.");
        NSData *expected = LNPEdit(original, tokens);
        if (!LNPEqual(LNPDecode(expected), LNPDecode(edited))) LNPFail(@"Edited backup changes more than the selected rule references.");
        NSArray *actual = LNPEntries(original, nil);
        NSMutableDictionary *byToken = [NSMutableDictionary new];
        for (NSDictionary *row in actual) byToken[row[@"token"]] = row;
        for (NSDictionary *row in m[@"removed"]) for (NSString *key in @[@"identifier", @"path", @"permission", @"configuration"])
            if (![row[key] isEqual:byToken[row[@"token"]][key]]) LNPFail(@"Selected-entry description does not match the original.");
    } else if ([m[@"removed"] count]) LNPFail(@"A restore-safety snapshot cannot contain a removal selection.");
    return m;
}

static NSDictionary *loadBackup(NSString *directory) {
    return verifyBackup(directory, YES);
}

static void printPlan(NSString *directory, NSDictionary *m) {
    printf("Backup: %s\nVolume: %s (%s)\nCreated: %s\nType: %s\n",
        clean(directory).UTF8String, clean(m[@"volume_name"] ?: @"Unknown").UTF8String,
        [m[@"volume_uuid"] UTF8String], clean(m[@"created"]).UTF8String, [m[@"kind"] UTF8String]);
    printf("Selected removals: %lu\n", (unsigned long)[m[@"removed"] count]);
    NSUInteger number = 0;
    for (NSDictionary *row in m[@"removed"]) {
        NSString *label = [row[@"label"] isKindOfClass:NSString.class] && [row[@"label"] length] ? row[@"label"] : row[@"identifier"];
        NSString *user = [row[@"user"] isKindOfClass:NSString.class] && [row[@"user"] length] ? row[@"user"] : row[@"configuration"];
        NSString *pathStatus = [row[@"path_status"] isKindOfClass:NSString.class] ? row[@"path_status"] : @"Not recorded";
        printf("\n  %lu. %s\n     User: %s\n     Executable: %s\n     Permission: %s\n"
               "     Path status at preparation: %s\n     Identifier: %s\n     Configuration: %s\n",
            (unsigned long)++number, clean(label).UTF8String, clean(user).UTF8String,
            clean([row[@"path"] length] ? row[@"path"] : @"(no recorded path)").UTF8String,
            clean(row[@"permission"]).UTF8String, clean(pathStatus).UTF8String,
            clean(row[@"identifier"]).UTF8String, clean(row[@"configuration"]).UTF8String);
    }
}

static NSArray *backupItems(NSString *base) {
    noSymlinks(base);
    NSError *error = nil;
    NSArray *names = [fm contentsOfDirectoryAtPath:base error:&error];
    if (!names) LNPFail(error.localizedDescription);
    NSMutableArray *results = [NSMutableArray new];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path = [base stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode)) continue;
        NSMutableDictionary *item = [@{@"directory": path} mutableCopy];
        @try {
            NSDictionary *m = loadBackup(path);
            [item addEntriesFromDictionary:@{@"valid": @YES, @"kind": m[@"kind"], @"created": m[@"created"],
                @"volume_uuid": m[@"volume_uuid"], @"selected": @([m[@"removed"] count])}];
        } @catch (NSException *failure) { item[@"valid"] = @NO; item[@"error"] = failure.reason; }
        [results addObject:item];
    }
    return results;
}

static NSString *promptLine(NSString *prompt) {
    if (!isatty(STDIN_FILENO)) LNPFail(@"The Recovery menu requires an interactive terminal.");
    printf("%s", prompt.UTF8String); fflush(stdout);
    char *line = NULL; size_t size = 0;
    ssize_t n = getline(&line, &size, stdin);
    NSString *answer = n > 0 ? [[NSString alloc] initWithBytes:line length:(NSUInteger)n encoding:NSUTF8StringEncoding] : nil;
    free(line);
    return answer ? [[answer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString] : @"q";
}

static void recoveryMenu(NSString *base) {
    requireRoot(); privateBackup(base);
    NSString *volumeUUID = uuidForPath(base);
    NSMutableArray *checked = [NSMutableArray new];
    for (NSDictionary *item in backupItems(base)) {
        NSMutableDictionary *copy = [item mutableCopy];
        if ([item[@"valid"] boolValue] && ![item[@"volume_uuid"] isEqual:volumeUUID]) {
            copy[@"valid"] = @NO;
            copy[@"error"] = @"Backup belongs to a different volume.";
        }
        [checked addObject:copy];
    }
    NSArray *items = [checked sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"created"] ?: @"" compare:a[@"created"] ?: @""];
    }];
    if (!items.count) LNPFail(@"No backups found here. Prepare a cleanup in normal macOS first.");
    for (;;) {
        puts("\nLOCAL NETWORK RECOVERY\n\nChoose a backup to review. Nothing changes until you confirm apply or restore.");
        for (NSUInteger i = 0; i < items.count; i++) {
            NSDictionary *item = items[i];
            if ([item[@"valid"] boolValue])
                printf("  %lu. %s | %s | %lu removals\n", (unsigned long)i + 1,
                    clean(item[@"created"]).UTF8String, [item[@"kind"] UTF8String], [item[@"selected"] unsignedLongValue]);
            else printf("  %lu. INVALID: %s\n", (unsigned long)i + 1, clean(item[@"error"]).UTF8String);
        }
        NSString *answer = promptLine(@"\nEnter also quits.\nBackup number, or q to quit: ");
        if ([answer isEqual:@"q"] || !answer.length) { puts("Cancelled; nothing changed."); return; }
        NSInteger number = 0;
        NSScanner *scanner = [NSScanner scannerWithString:answer];
        if (![scanner scanInteger:&number] || !scanner.isAtEnd || number < 1 || (NSUInteger)number > items.count ||
            ![items[(NSUInteger)number - 1][@"valid"] boolValue]) { puts("Choose a valid backup number."); continue; }
        NSString *backup = items[(NSUInteger)number - 1][@"directory"];
        NSDictionary *m = loadBackup(backup);
        if (![m[@"volume_uuid"] isEqual:volumeUUID]) LNPFail(@"Backup belongs to a different volume.");
        puts(""); printPlan(backup, m);
        BOOL snapshot = [m[@"kind"] isEqual:@"snapshot"];
        puts("\nEnter also quits.");
        answer = promptLine(snapshot ? @"\nr = restore, b = back, q = quit: " : @"\na = apply cleanup, r = restore, b = back, q = quit: ");
        if ([answer isEqual:@"q"] || !answer.length) { puts("Cancelled; nothing changed."); return; }
        if ([answer isEqual:@"b"]) continue;
        NSString *action = [answer isEqual:@"r"] ? @"restore" : (!snapshot && [answer isEqual:@"a"] ? @"apply" : nil);
        if (!action) { puts("Choose one of the displayed actions."); continue; }
        if (!LNPEqual(loadBackup(backup), m)) LNPFail(@"The backup changed during review. Open the Recovery menu again.");
        // Execute the selected backup's verified binary, preserving its exact-version binding.
        NSString *staged = [backup stringByAppendingPathComponent:@"lnpctl"];
        printf("\nOpening this backup's %s confirmation...\n", action.UTF8String); fflush(stdout);
        const char *args[] = {staged.fileSystemRepresentation, action.UTF8String, backup.fileSystemRepresentation, NULL};
        execv(staged.fileSystemRepresentation, (char *const *)args);
        posixFail(@"Start the verified backup executable");
    }
}

static BOOL confirm(NSString *prompt) {
    if (!isatty(STDIN_FILENO)) LNPFail(@"An interactive confirmation is required; use --yes for an explicitly reviewed operation.");
    NSString *answer = promptLine([prompt stringByAppendingString:@" [y/N] "]);
    return [answer isEqual:@"y"] || [answer isEqual:@"yes"];
}

static void prepare(NSDictionary *v, NSString *backup, NSArray *tokens, NSData *original) {
    NSString *path = v[@"store"];
    NSDictionary *meta = metadata(path);
    if (![readFile(path) isEqual:original]) LNPFail(@"The store changed while selecting. Scan again.");
    NSData *edited = LNPEdit(original, tokens);
    NSMutableArray *selected = [NSMutableArray new];
    for (NSDictionary *row in LNPEntries(original, v[@"mount"])) if ([tokens containsObject:row[@"token"]]) [selected addObject:row];
    saveBackup(backup, v, original, meta, edited, selected, @"cleanup");
    if (![readFile(path) isEqual:original] || !LNPEqual(metadata(path), meta))
        LNPFail(@"The store changed during preparation. The backup is retained, but prepare a fresh cleanup before applying.");
    NSDictionary *m = loadBackup(backup);
    printPlan(backup, m);
    printf("\nPrepared only; the live permissions are unchanged.\nInstructions saved with the backup: %s\n",
        clean([backup stringByAppendingPathComponent:@"RECOVERY.txt"]).UTF8String);
    @try { installRecovery(v, backup.stringByDeletingLastPathComponent); }
    @catch (NSException *error) {
        LNPFail([@"The backup is prepared and retained, but the Recovery launcher could not be installed: " stringByAppendingString:error.reason]);
    }
    printf("\n%s", recoveryInstructions(v, backup.stringByDeletingLastPathComponent).UTF8String);
}

static void applyOrRestore(NSString *action, NSString *backup, NSString *root, BOOL yes) {
    requireRoot();
    NSDictionary *m = loadBackup(backup);
    if (![LNPSHA256(executable) isEqual:m[@"executable_sha256"]])
        LNPFail(@"This executable differs from the one staged with the backup. Run that backup's ./lnpctl to apply or restore it.");
    NSDictionary *v = nil;
    if (root) v = volume(root);
    else {
        NSMutableArray *matches = [NSMutableArray new];
        for (NSDictionary *item in volumes()) if ([item[@"uuid"] isEqual:m[@"volume_uuid"]]) [matches addObject:item];
        if (matches.count != 1) LNPFail(@"Cannot identify one mounted target Data volume. Mount/unlock it, then use --volume with its mount path.");
        v = matches[0];
    }
    if (![v[@"uuid"] isEqual:m[@"volume_uuid"]]) LNPFail(@"Wrong volume: its UUID does not match the backup.");
    requireOffline(v);
    BOOL restoring = [action isEqual:@"restore"];
    if (!restoring && ![m[@"kind"] isEqual:@"cleanup"]) LNPFail(@"This is a restore-safety snapshot; use restore, not apply.");
    NSString *path = v[@"store"];
    NSData *current = readFile(path);
    NSDictionary *currentMeta = metadata(path);
    NSData *original = readFile([backup stringByAppendingPathComponent:@"original.plist"]);
    NSData *chosen = restoring ? original : readFile([backup stringByAppendingPathComponent:@"edited.plist"]);
    if ([current isEqual:chosen] && LNPEqual(currentMeta, m[@"metadata"])) { puts("Already installed; nothing changed."); return; }
    if (!restoring && (![current isEqual:original] || !LNPEqual(currentMeta, m[@"metadata"])))
        LNPFail(@"The store changed since preparation. Refusing a stale cleanup; prepare a fresh one in normal macOS.");
    printPlan(backup, m);
    if (restoring) puts("Restore replaces the entire main plist, including permissions changed after this backup.\nThe current state will be saved as a separate restore-safety backup first.");
    if (!yes && !confirm(restoring ? @"Restore this backup?" : @"Apply this prepared cleanup?")) { puts("Cancelled; nothing changed."); return; }
    NSString *safety = nil;
    if (restoring) {
        safety = [backup.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName(@"restore-safety")];
        saveBackup(safety, v, current, currentMeta, nil, nil, @"snapshot");
        verifyBackup(safety, NO);
    }
    NSString *receiptName = newName(action);
    NSMutableDictionary *receipt = [@{@"action": action, @"volume_uuid": v[@"uuid"],
        @"before_sha256": LNPSHA256(current), @"installed_sha256": LNPSHA256(chosen),
        @"created": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date]} mutableCopy];
    if (safety) receipt[@"safety_backup"] = safety;
    writeNew(LNPEncode(receipt), [backup stringByAppendingPathComponent:[receiptName stringByAppendingString:@"-intent.plist"]], 0600);
    replaceStore(chosen, m[@"metadata"], path, current, currentMeta);
    @try {
        writeNew(LNPEncode(receipt), [backup stringByAppendingPathComponent:[receiptName stringByAppendingString:@"-complete.plist"]], 0600);
    } @catch (NSException *error) {
        LNPFail([@"The change was installed and verified, but its completion receipt could not be saved: " stringByAppendingString:error.reason]);
    }
    printf("\n%s completed and verified.\n", restoring ? "Restore" : "Cleanup");
    if (safety) printf("Previous state: %s\n", clean(safety).UTF8String);
    puts("Run reboot, then verify Local Network settings and application connectivity.");
}

static void usage(void) {
    puts("lnpctl " LNP_VERSION " — selective Local Network cleanup\n\n"
         "  sudo lnpctl                         Open the entry picker\n"
         "  sudo lnpctl select [--volume ROOT] [--backups DIRECTORY]\n"
         "  lnpctl list [--volume ROOT] [--json]\n"
         "  sudo lnpctl prepare --entry TOKEN [--entry TOKEN ...] --backup DIRECTORY [--volume ROOT]\n"
         "  sudo lnpctl inspect BACKUP [--json]\n"
         "  sudo lnpctl backups [DIRECTORY] [--json]\n"
         "  sudo lnpctl setup-recovery [--volume ROOT] [--backups DIRECTORY]\n"
         "  lnpctl recovery [DIRECTORY]                    Recovery backup menu\n"
         "  lnpctl volumes [--json]\n"
         "  lnpctl apply BACKUP [--volume ROOT] [--yes]       Recovery\n"
         "  lnpctl restore BACKUP [--volume ROOT] [--yes]     Recovery\n\n"
         "Space selects entries; Enter reviews; p prepares from the review screen.\n"
         "Backups default to /Users/Shared/lnpctl/backups. Apply/restore require an offline volume.\n"
         "Preparation installs a short Recovery launcher and prints a shutdown-to-reboot checklist.\n"
         "setup-recovery adds that handoff to existing backups without changing their selections.\n"
         "Each backup includes this executable and RECOVERY.txt. No SIP changes are needed.");
}

int main(int argc, const char **argv) { @autoreleasepool {
    fm = NSFileManager.defaultManager;
    umask(0077);
    @try {
        BOOL launchedForRecovery = [@(argv[0]).lastPathComponent isEqual:recoveryName];
        NSString *command = argc > 1 ? @(argv[1]) : (launchedForRecovery ? @"recovery" : @"select");
        if ([command isEqual:@"--help"] || [command isEqual:@"help"] || [command isEqual:@"-h"]) { usage(); return 0; }
        if ([command isEqual:@"--version"]) { puts("lnpctl " LNP_VERSION); return 0; }
        NSDictionary *allowed = @{
            @"select": @[@"--volume", @"--backups"], @"list": @[@"--volume", @"--json"],
            @"prepare": @[@"--volume", @"--entry", @"--backup"],
            @"inspect": @[@"--json"], @"backups": @[@"--json"], @"volumes": @[@"--json"],
            @"setup-recovery": @[@"--volume", @"--backups"], @"recovery": @[],
            @"apply": @[@"--volume", @"--yes"], @"restore": @[@"--volume", @"--yes"]
        };
        if (!allowed[command]) LNPFail(@"Unknown command. Run lnpctl --help.");
        NSMutableDictionary *options = [NSMutableDictionary new];
        NSMutableArray *tokens = [NSMutableArray new], *positional = [NSMutableArray new];
        for (int i = 2; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if (![arg hasPrefix:@"--"]) { [positional addObject:arg]; continue; }
            if (![allowed[command] containsObject:arg]) LNPFail([@"Unknown option for this command: " stringByAppendingString:arg]);
            if (options[arg] && ![arg isEqual:@"--entry"]) LNPFail(@"An option was specified more than once.");
            if ([arg isEqual:@"--json"] || [arg isEqual:@"--yes"]) { options[arg] = @YES; continue; }
            if (++i >= argc || [@(argv[i]) hasPrefix:@"--"]) LNPFail([@"Missing value for " stringByAppendingString:arg]);
            if ([arg isEqual:@"--entry"]) [tokens addObject:@(argv[i])];
            else options[arg] = @(argv[i]);
        }
        BOOL needsBackup = [@[@"inspect", @"apply", @"restore"] containsObject:command];
        if ((needsBackup && positional.count != 1) ||
            (!needsBackup && ![@[@"backups", @"recovery"] containsObject:command] && positional.count) || positional.count > 1)
            LNPFail(@"Unexpected arguments. Run lnpctl --help.");
        char buffer[PATH_MAX]; uint32_t size = sizeof(buffer);
        if (_NSGetExecutablePath(buffer, &size)) LNPFail(@"Executable path exceeds the supported length.");
        char resolved[PATH_MAX]; if (!realpath(buffer, resolved)) posixFail(@"Locate executable");
        executablePath = @(resolved);
        executable = readFile(executablePath);
        if ([command isEqual:@"setup-recovery"]) {
            requireRoot();
            NSDictionary *v = volume(options[@"--volume"] ?: @"/");
            NSString *base = absolute(options[@"--backups"] ?: defaultBackupDirectory(v));
            privateBackup(base);
            BOOL valid = NO;
            for (NSDictionary *item in backupItems(base))
                if ([item[@"valid"] boolValue] && [item[@"volume_uuid"] isEqual:v[@"uuid"]]) valid = YES;
            if (!valid) LNPFail(@"No valid backups for this volume found. Prepare a cleanup first.");
            installRecovery(v, base);
            puts("Recovery launcher installed. Existing backups and live permissions are unchanged.\n");
            printf("%s", recoveryInstructions(v, base).UTF8String);
            return 0;
        }
        if ([command isEqual:@"recovery"]) {
            NSString *base = defaultBackups;
            if (launchedForRecovery) {
                struct statfs fs;
                if (statfs(executablePath.fileSystemRepresentation, &fs)) posixFail(@"Locate the Recovery launcher's volume");
                NSString *parent = executablePath.stringByDeletingLastPathComponent;
                base = [parent isEqual:@(fs.f_mntonname)] ?
                    [parent stringByAppendingPathComponent:[defaultBackups substringFromIndex:1]] : parent;
            }
            recoveryMenu(absolute(positional.count ? positional[0] : base));
            return 0;
        }
        if ([command isEqual:@"volumes"]) {
            NSArray *items = volumes();
            if (options[@"--json"]) json(items);
            else for (NSDictionary *v in items) printf("%s  %s\n", [v[@"uuid"] UTF8String], clean(v[@"mount"]).UTF8String);
            return 0;
        }
        if ([command isEqual:@"list"] || [command isEqual:@"select"] || [command isEqual:@"prepare"]) {
            if (![command isEqual:@"list"]) requireRoot();
            NSDictionary *v = volume(options[@"--volume"] ?: @"/");
            NSData *original = readFile(v[@"store"]);
            NSArray *rows = LNPEntries(original, options[@"--volume"] ?: @"/");
            if ([command isEqual:@"list"]) {
                if (options[@"--json"]) json(@{@"volume": v, @"source_sha256": LNPSHA256(original), @"entries": publicRows(rows)});
                else { printf("%lu entries on %s\n", (unsigned long)rows.count, clean(v[@"name"]).UTF8String);
                    for (NSDictionary *r in rows) printf("%s\n  %s | %s | %s | %s\n  %s\n", [r[@"token"] UTF8String],
                        clean(r[@"identifier"]).UTF8String, clean(r[@"permission"]).UTF8String, clean(r[@"path_status"]).UTF8String,
                        clean(r[@"user"]).UTF8String, clean([r[@"path"] length] ? r[@"path"] : @"(no recorded path)").UTF8String); }
                return 0;
            }
            NSString *backup = nil;
            if ([command isEqual:@"select"]) {
                NSArray *selection = LNPSelectEntries(publicRows(rows), v[@"name"]);
                if (!selection) { puts("Cancelled; nothing changed."); return 0; }
                tokens = [selection mutableCopy];
                NSString *base = options[@"--backups"] ?: defaultBackupDirectory(v);
                backup = [absolute(base) stringByAppendingPathComponent:newName(@"cleanup")];
            } else {
                if (!options[@"--backup"] || !tokens.count) LNPFail(@"prepare requires --backup and at least one --entry token from a current scan.");
                backup = absolute(options[@"--backup"]);
            }
            prepare(v, backup, tokens, original);
            return 0;
        }
        if ([command isEqual:@"inspect"]) {
            NSString *directory = absolute(positional[0]);
            NSDictionary *m = loadBackup(directory);
            if (options[@"--json"]) json(@{@"directory": directory, @"valid": @YES,
                @"volume_uuid": m[@"volume_uuid"], @"kind": m[@"kind"], @"created": m[@"created"], @"removed": m[@"removed"]});
            else printPlan(directory, m);
            return 0;
        }
        if ([command isEqual:@"backups"]) {
            NSString *base = absolute(positional.count ? positional[0] : defaultBackups);
            NSArray *results = backupItems(base);
            if (options[@"--json"]) json(results);
            else for (NSDictionary *item in results) printf("%s  %s\n  %s\n", [item[@"valid"] boolValue] ? "valid" : "INVALID",
                clean(item[@"directory"]).UTF8String, clean(item[@"error"] ?: [NSString stringWithFormat:@"%@ | %@ | %@", item[@"created"], item[@"kind"], item[@"volume_uuid"]]).UTF8String);
            return 0;
        }
        applyOrRestore(command, absolute(positional[0]), options[@"--volume"], [options[@"--yes"] boolValue]);
        return 0;
    } @catch (NSException *error) {
        fprintf(stderr, "lnpctl: %s\n", clean(error.reason ?: @"Unknown error").UTF8String);
        return 1;
    }
} }
