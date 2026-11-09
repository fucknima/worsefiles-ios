//
//  WFClone.h
//  WorseFiles
//
//  Copy one item, preferring an APFS clone. Clones share blocks with the
//  source on the same volume and fall back to a real copy when the kernel or
//  the filesystem refuses.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL WFCloneItem(NSString *source, NSString *destination);

NS_ASSUME_NONNULL_END
