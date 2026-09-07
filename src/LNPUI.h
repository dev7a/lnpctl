#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Escapes terminal controls, bidi overrides, and invisible format characters.
/// Keeps ordinary Unicode text intact without depending on the process locale.
NSString *LNPTerminalText(id _Nullable value);

/// Shows the entry picker and review. Returns original row tokens after `p`
/// confirms preparation, or nil on cancellation. This function never writes files.
/// Raises an exception when a usable interactive terminal is unavailable.
NSArray<NSString *> * _Nullable LNPSelectEntries(NSArray<NSDictionary *> *rows,
                                               NSString *volumeLabel);

NS_ASSUME_NONNULL_END
