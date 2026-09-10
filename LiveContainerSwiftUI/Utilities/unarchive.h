#import <Foundation/Foundation.h>
#include <stdint.h>

extern int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress);

/// Validates an IPA before extraction. Returns zero for a safe archive, otherwise a
/// stable error code; `errorMessage` is optional and owned by the caller after return.
extern int validateIPAArchive(NSString* fileToValidate, uint64_t maximumExpandedSize, uint64_t maximumFileCount, NSString** errorMessage);
