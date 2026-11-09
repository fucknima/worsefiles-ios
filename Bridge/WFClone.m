//
//  WFClone.m
//  WorseFiles
//

#import "WFClone.h"
#include <sys/clonefile.h>
#include <copyfile.h>
#include <errno.h>

BOOL WFCloneItem(NSString *source, NSString *destination) {
    if (source.length == 0 || destination.length == 0) return NO;

    const char *from = source.fileSystemRepresentation;
    const char *to = destination.fileSystemRepresentation;

    if (clonefile(from, to, 0) == 0) return YES;
    if (errno == EEXIST) return NO;

    return copyfile(from, to, NULL, COPYFILE_ALL | COPYFILE_NOFOLLOW) == 0;
}
