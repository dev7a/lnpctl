#define NCURSES_WIDECHAR 1
#import "LNPUI.h"
#include <curses.h>
#include <locale.h>
#include <signal.h>
#include <termios.h>
#include <unistd.h>
#include <wchar.h>

static volatile sig_atomic_t interrupted;
static void StopPicker(int signo) { interrupted = signo; }

static void UIError(NSString *message) {
    @throw [NSException exceptionWithName:@"LNPUIError" reason:message userInfo:nil];
}

// Never send entry-provided terminal controls or bidi overrides to the terminal.
// Work in Unicode scalars so wide characters and combining marks retain their width.
NSString *LNPTerminalText(id value) {
    if (!value) return @"";
    if (![value isKindOfClass:NSString.class]) return @"(invalid text)";
    NSData *data = [value dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    if (!data) return @"(invalid Unicode text)";
    const uint32_t *scalars = data.bytes;
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length / sizeof(uint32_t); i++) {
        uint32_t c = scalars[i];
        BOOL control = c < 32 || (c >= 127 && c <= 159) ||
            c == 0x061c || (c >= 0x200b && c <= 0x200f) ||
            (c >= 0x2028 && c <= 0x202e) || (c >= 0x2060 && c <= 0x206f) || c == 0xfeff;
        if (control || [NSCharacterSet.controlCharacterSet longCharacterIsMember:c] ||
            [NSCharacterSet.illegalCharacterSet longCharacterIsMember:c]) {
            [safe appendFormat:@"\\u%04X", c];
        } else {
            [safe appendString:[[NSString alloc] initWithBytes:&c length:sizeof(c)
                                                     encoding:NSUTF32LittleEndianStringEncoding]];
        }
    }
    return safe;
}

static NSString *DisplayString(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return @"(not recorded)";
    return LNPTerminalText(value);
}

static int TextWidth(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const wchar_t *scalars = data.bytes;
    int width = 0;
    for (NSUInteger i = 0; i < data.length / sizeof(wchar_t); i++)
        width += MAX(0, wcwidth(scalars[i]));
    return width;
}

static NSString *FilterTail(NSString *filter, int width) {
    if (TextWidth(filter) <= width) return filter;
    NSUInteger start = 0;
    while (start < filter.length && TextWidth([filter substringFromIndex:start]) > width - 3)
        start = NSMaxRange([filter rangeOfComposedCharacterSequenceAtIndex:start]);
    return [@"..." stringByAppendingString:[filter substringFromIndex:start]];
}

static void Draw(int y, int x, int width, NSString *text, attr_t style) {
    if (y < 0 || y >= LINES || x < 0 || x >= COLS || width <= 0) return;
    // Leave the terminal's lower-right cell alone to avoid implicit scrolling.
    width = MIN(width, COLS - x - (y == LINES - 1 ? 1 : 0));
    NSData *data = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const wchar_t *scalars = data.bytes;
    NSUInteger count = 0;
    int used = 0;
    while (count < data.length / sizeof(wchar_t)) {
        int next = MAX(0, wcwidth(scalars[count]));
        if (used + next > width) break;
        used += next;
        count++;
    }
    attrset(style);
    move(y, x);
    if (count) addnwstr(scalars, (int)count);
    attrset(A_NORMAL);
}

// Wrap at word boundaries where possible; paths without spaces wrap by scalar.
static NSArray<NSString *> *Wrap(NSString *text, int width) {
    width = MAX(1, width);
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableString *line = [NSMutableString string];
    int columns = 0;
    for (NSString *word in [text componentsSeparatedByString:@" "]) {
        if (line.length && columns + 1 + TextWidth(word) <= width) {
            [line appendFormat:@" %@", word];
            columns += 1 + TextWidth(word);
            continue;
        }
        if (line.length) {
            [lines addObject:[line copy]];
            [line setString:@""];
            columns = 0;
        }
        NSData *data = [word dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
        const uint32_t *scalars = data.bytes;
        for (NSUInteger i = 0; i < data.length / sizeof(uint32_t); i++) {
            int next = MAX(0, wcwidth((wchar_t)scalars[i]));
            if (columns + next > width && line.length) {
                [lines addObject:[line copy]];
                [line setString:@""];
                columns = 0;
            }
            [line appendString:[[NSString alloc] initWithBytes:&scalars[i] length:sizeof(uint32_t)
                                                     encoding:NSUTF32LittleEndianStringEncoding]];
            columns += next;
        }
    }
    if (line.length || !lines.count) [lines addObject:[line copy]];
    return lines;
}

static NSArray<NSString *> *Details(NSDictionary *row, int width) {
    NSMutableArray *lines = [NSMutableArray array];
    // Put the two duplicate-entry discriminators in the initial viewport.
    NSArray *fields = @[@[@"User", @"user"], @[@"Executable", @"path"],
        @[@"Path status", @"path_status"], @[@"Permission", @"permission"],
        @[@"Identifier", @"identifier"], @[@"Application", @"label"], @[@"Configuration", @"configuration"]];
    for (NSArray *field in fields)
        [lines addObjectsFromArray:Wrap([NSString stringWithFormat:@"%@: %@", field[0], row[field[1]]], width)];
    return lines;
}

static NSInteger Clamp(NSInteger value, NSInteger count) {
    return MAX(0, MIN(value, count - 1));
}

static NSInteger Move(NSInteger value, wint_t key, NSInteger page, NSInteger count) {
    switch (key) {
        case KEY_UP: return Clamp(value - 1, count);
        case KEY_DOWN: return Clamp(value + 1, count);
        case KEY_PPAGE: return Clamp(value - page, count);
        case KEY_NPAGE: return Clamp(value + page, count);
        case KEY_HOME: return 0;
        case KEY_END: return MAX(0, count - 1);
        default: return value;
    }
}

static NSArray<NSDictionary *> *VisibleRows(NSArray<NSDictionary *> *rows, NSString *filter) {
    if (!filter.length) return rows;
    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        for (NSString *key in @[@"label", @"identifier", @"path", @"path_status", @"permission", @"user", @"configuration"]) {
            if ([row[key] rangeOfString:filter options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
                [visible addObject:row];
                break;
            }
        }
    }
    return visible;
}

NSArray<NSString *> *LNPSelectEntries(NSArray<NSDictionary *> *rows, NSString *volumeLabel) {
    const char *term = getenv("TERM");
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) || !term || !*term || !strcmp(term, "dumb"))
        UIError(@"The picker needs an interactive terminal (TERM must support cursor movement).");
    if (!setlocale(LC_CTYPE, "") || MB_CUR_MAX < 4) setlocale(LC_CTYPE, "en_US.UTF-8");
    NSMutableArray *safeRows = [NSMutableArray arrayWithCapacity:rows.count];
    NSMutableSet *tokens = [NSMutableSet set];
    for (NSDictionary *row in rows) {
        NSString *token = row[@"token"];
        if (![token isKindOfClass:NSString.class] || !token.length || [tokens containsObject:token])
            UIError(@"Picker entries require distinct, nonempty selection tokens.");
        [tokens addObject:token];
        NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithObject:token forKey:@"token"];
        for (NSString *key in @[@"label", @"identifier", @"path", @"path_status", @"permission", @"user", @"configuration"])
            safe[key] = DisplayString(row[key]);
        [safeRows addObject:safe];
    }
    NSString *safeVolume = DisplayString(volumeLabel);
    struct termios savedTerminal;
    if (tcgetattr(STDIN_FILENO, &savedTerminal) != 0) UIError(@"Cannot read terminal settings.");
    const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGWINCH, SIGTSTP};
    struct sigaction savedSignals[5];
    for (int i = 0; i < 5; i++) sigaction(signals[i], NULL, &savedSignals[i]);
    SCREEN *screen = newterm(NULL, stdout, stdin);
    if (!screen) {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTerminal);
        for (int i = 0; i < 5; i++) sigaction(signals[i], &savedSignals[i], NULL);
        UIError(@"Cannot initialize this terminal. Check TERM and its terminfo database.");
    }
    interrupted = 0;
    @try {
        struct sigaction handler = {0};
        handler.sa_handler = StopPicker;
        sigemptyset(&handler.sa_mask);
        for (int i = 0; i < 3; i++) sigaction(signals[i], &handler, NULL);
        cbreak(); noecho(); keypad(stdscr, TRUE); curs_set(0); timeout(150);
        attr_t accent = A_BOLD;
        if (!getenv("NO_COLOR") && has_colors()) {
            start_color();
            if (use_default_colors() == OK && init_pair(1, COLOR_CYAN, -1) == OK)
                accent = COLOR_PAIR(1) | A_BOLD;
        }
        NSMutableSet *selected = [NSMutableSet set];
        NSMutableString *filter = [NSMutableString string];
        NSString *priorFilter = @"";
        NSString *hint = @"Space selects; Enter reviews.";
        NSArray *visible = safeRows;
        NSInteger cursor = 0, top = 0, detailOffset = 0, reviewOffset = 0;
        BOOL editing = NO, detailFocus = NO, reviewing = NO;
        while (!interrupted) {
            @autoreleasepool {
                int height = LINES, width = COLS;
                erase();
                if (height < 16 || width < 40) {
                    Draw(0, 0, width, @"Enlarge terminal to at least 40 x 16.", A_BOLD);
                    Draw(2, 0, width, @"Selections stay while you resize.", A_DIM);
                    Draw(3, 0, width, @"q or Ctrl-C cancels the selection.", A_DIM);
                    refresh();
                    wint_t key = 0;
                    int kind = get_wch(&key);
                    if (kind == OK && (key == 'q' || key == 3)) return nil;
                    continue;
                }
                Draw(0, 1, width - 2, reviewing ? @"Review cleanup" : @"Local Network cleanup", A_BOLD);
                Draw(1, 1, width - 2, safeVolume, A_DIM);
                int reviewHeight = height - 8;
                int detailHeight = MAX(4, MIN(9, (height - 10) / 3));
                int tableHeight = height - 10 - detailHeight;
                NSInteger maxDetailOffset = 0, maxReviewOffset = 0;
                if (reviewing) {
                    Draw(2, 1, width - 2, [NSString stringWithFormat:@"%lu selected; %lu entries kept",
                        (unsigned long)selected.count, (unsigned long)(safeRows.count - selected.count)], A_NORMAL);
                    Draw(3, 1, width - 2, @"p saves backup; permissions unchanged.", A_DIM);
                    Draw(4, 1, width - 2, @"Apply later from macOS Recovery.", A_DIM);
                    NSMutableArray *reviewLines = [NSMutableArray array];
                    NSUInteger number = 0;
                    for (NSDictionary *row in safeRows) if ([selected containsObject:row[@"token"]]) {
                        [reviewLines addObject:[NSString stringWithFormat:@"%lu. %@", (unsigned long)++number, row[@"label"]]];
                        [reviewLines addObjectsFromArray:Details(row, width - 4)];
                        [reviewLines addObject:@""];
                    }
                    maxReviewOffset = MAX(0, (NSInteger)reviewLines.count - reviewHeight);
                    reviewOffset = MIN(reviewOffset, maxReviewOffset);
                    for (int line = 0; line < reviewHeight && reviewOffset + line < (NSInteger)reviewLines.count; line++)
                        Draw(5 + line, 2, width - 4, reviewLines[reviewOffset + line], A_NORMAL);
                    Draw(height - 3, 1, width - 2, [NSString stringWithFormat:@"Review lines %ld-%ld of %lu", reviewOffset + 1,
                        MIN(reviewOffset + reviewHeight, (NSInteger)reviewLines.count), (unsigned long)reviewLines.count], A_DIM);
                    Draw(height - 2, 1, width - 2, @"p Prepare  Esc Back  q Cancel", accent);
                    Draw(height - 1, 1, width - 2, @"Arrows/PgUp/PgDn scroll   Home/End", A_DIM);
                } else {
                    NSUInteger visibleSelected = 0;
                    for (NSDictionary *row in visible) if ([selected containsObject:row[@"token"]]) visibleSelected++;
                    NSUInteger hidden = selected.count - visibleSelected;
                    Draw(2, 1, width - 2, [NSString stringWithFormat:@"Selected %lu (%lu hidden)",
                        (unsigned long)selected.count, (unsigned long)hidden], hidden ? accent : A_NORMAL);
                    Draw(4, 1, width - 2, [NSString stringWithFormat:@"Showing %lu of %lu entries",
                        (unsigned long)visible.count, (unsigned long)safeRows.count], A_DIM);
                    Draw(3, 1, width - 2, [NSString stringWithFormat:@"%@ %@%@", editing ? @"Filter:" : @"/ Filter:", FilterTail(filter, width - 14),
                        editing ? @"_" : @""], editing ? accent : A_DIM);
                    BOOL columns = width >= 64;
                    int permissionX = width - 29, statusX = width - 15;
                    int labelWidth = columns ? permissionX - 7 : width - 7;
                    Draw(5, 6, labelWidth, @"Application / identity", A_DIM);
                    if (columns) {
                        Draw(5, permissionX, 13, @"Permission", A_DIM);
                        Draw(5, statusX, 14, @"Executable", A_DIM);
                    }
                    cursor = Clamp(cursor, visible.count);
                    top = MAX(0, MIN(top, (NSInteger)visible.count - tableHeight));
                    if (cursor < top) top = cursor;
                    if (cursor >= top + tableHeight) top = cursor - tableHeight + 1;
                    for (int line = 0; line < tableHeight && top + line < (NSInteger)visible.count; line++) {
                        NSDictionary *row = visible[top + line];
                        BOOL active = top + line == cursor;
                        Draw(6 + line, 0, 1, active ? @">" : @" ", detailFocus ? A_DIM : accent);
                        Draw(6 + line, 2, 3, [selected containsObject:row[@"token"]] ? @"[x]" : @"[ ]", accent);
                        NSString *label = [row[@"label"] isEqualToString:@"(not recorded)"] ? row[@"identifier"] : row[@"label"];
                        if (![label isEqualToString:row[@"identifier"]]) label = [NSString stringWithFormat:@"%@  %@", label, row[@"identifier"]];
                        Draw(6 + line, 6, labelWidth, label, active ? A_BOLD : A_NORMAL);
                        if (columns) {
                            Draw(6 + line, permissionX, 13, row[@"permission"], A_NORMAL);
                            Draw(6 + line, statusX, 14, row[@"path_status"], A_DIM);
                        }
                    }
                    if (!visible.count) Draw(6, 2, width - 4, safeRows.count ? @"No matches. Press / to change filter." : @"No application entries in this snapshot.", A_DIM);
                    int detailY = 6 + tableHeight;
                    NSArray *detailLines = visible.count ? Details(visible[cursor], width - 4) : @[];
                    maxDetailOffset = MAX(0, (NSInteger)detailLines.count - detailHeight);
                    detailOffset = MIN(detailOffset, maxDetailOffset);
                    Draw(detailY, 1, width - 2, [NSString stringWithFormat:@"%@Details %@", detailFocus ? @"> " : @"",
                        detailLines.count ? [NSString stringWithFormat:@"%ld-%ld/%lu  (Tab %@)", detailOffset + 1,
                        MIN(detailOffset + detailHeight, (NSInteger)detailLines.count), (unsigned long)detailLines.count,
                        detailFocus ? @"to table" : @"to scroll"] : @""], detailFocus ? accent : A_DIM);
                    for (int line = 0; line < detailHeight && detailOffset + line < (NSInteger)detailLines.count; line++)
                        Draw(detailY + 1 + line, 2, width - 4, detailLines[detailOffset + line], A_DIM);
                    Draw(height - 3, 1, width - 2, editing ? @"Type to filter; selections stay." : hint, A_DIM);
                    Draw(height - 2, 1, width - 2, editing ? @"Enter Keep  Esc Undo  Ctrl-U Clear" : @"Space select  / filter  Enter review", accent);
                    Draw(height - 1, 1, width - 2, editing ? @"Backspace Delete  Ctrl-C Cancel" : @"Arrows move  Tab details  q cancel", A_DIM);
                }
                refresh();
                wint_t key = 0;
                int kind = get_wch(&key);
                if (kind == ERR || (kind == KEY_CODE_YES && key == KEY_RESIZE)) continue;
                if (kind == OK && key == 3) return nil;
                if (editing) {
                    if ((kind == OK && (key == '\n' || key == '\r')) || (kind == KEY_CODE_YES && key == KEY_ENTER)) editing = NO;
                    else if (kind == OK && key == 27) { [filter setString:priorFilter]; editing = NO; }
                    else if (kind == OK && key == 21) [filter setString:@""];
                    else if ((kind == KEY_CODE_YES && key == KEY_BACKSPACE) || (kind == OK && (key == 127 || key == 8))) {
                        if (filter.length) [filter deleteCharactersInRange:[filter rangeOfComposedCharacterSequenceAtIndex:filter.length - 1]];
                    } else if (kind == OK && key >= 32 && key != 127 && wcwidth((wchar_t)key) >= 0 && filter.length < 512) {
                        uint32_t scalar = (uint32_t)key;
                        NSString *character = [[NSString alloc] initWithBytes:&scalar length:sizeof(scalar) encoding:NSUTF32LittleEndianStringEncoding];
                        [filter appendString:DisplayString(character)];
                    }
                    visible = VisibleRows(safeRows, filter);
                    cursor = top = detailOffset = 0;
                    continue;
                }
                if (kind == OK && key == 'q') return nil;
                if (reviewing) {
                    if (kind == OK && key == 27) { reviewing = NO; continue; }
                    if (kind == OK && key == 'p') {
                        NSMutableArray *result = [NSMutableArray array];
                        for (NSDictionary *row in safeRows) if ([selected containsObject:row[@"token"]]) [result addObject:row[@"token"]];
                        return [result copy];
                    }
                    if (kind == KEY_CODE_YES) reviewOffset = Move(reviewOffset, key, reviewHeight, maxReviewOffset + 1);
                    continue;
                }
                if (kind == OK && key == '/') { priorFilter = [filter copy]; editing = YES; continue; }
                if (kind == OK && key == '\t') { detailFocus = !detailFocus; continue; }
                if (kind == OK && key == 27) { detailFocus = NO; continue; }
                if (kind == OK && key == ' ' && visible.count) {
                    NSString *token = visible[cursor][@"token"];
                    if ([selected containsObject:token]) [selected removeObject:token]; else [selected addObject:token];
                    hint = @"Enter reviews all selected entries.";
                } else if ((kind == OK && (key == '\n' || key == '\r')) || (kind == KEY_CODE_YES && key == KEY_ENTER)) {
                    if (selected.count) { reviewing = YES; reviewOffset = 0; }
                    else hint = @"Select an entry with Space first.";
                } else if (kind == KEY_CODE_YES) {
                    if (detailFocus) detailOffset = Move(detailOffset, key, detailHeight, maxDetailOffset + 1);
                    else {
                        NSInteger next = Move(cursor, key, tableHeight, visible.count);
                        if (next != cursor) detailOffset = 0;
                        cursor = next;
                    }
                }
            }
        }
        return nil;
    } @finally {
        endwin();
        delscreen(screen);
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTerminal);
        for (int i = 0; i < 5; i++) sigaction(signals[i], &savedSignals[i], NULL);
    }
}
