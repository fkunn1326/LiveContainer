#import "unarchive.h"

#include "archive.h"
#include "archive_entry.h"
#include <string.h>

static BOOL path_is_unsafe(const char *path) {
  if (path == NULL || path[0] == '\0' || path[0] == '/') return YES;
  const char *component = path;
  while (*component) {
    const char *separator = strchr(component, '/');
    size_t length = separator ? (size_t)(separator - component) : strlen(component);
    if (length == 2 && component[0] == '.' && component[1] == '.') return YES;
    if (separator == NULL) break;
    component = separator + 1;
  }
  return NO;
}

static BOOL symlink_escapes(const char *entryPath, const char *target) {
  if (target == NULL || target[0] == '\0' || target[0] == '/') return YES;
  NSMutableArray<NSString*> *components = [NSMutableArray array];
  NSString *parent = [[NSString stringWithUTF8String:entryPath ?: @""] stringByDeletingLastPathComponent];
  for (NSString *part in [parent pathComponents]) {
    if ([part isEqualToString:@"."] || [part isEqualToString:@"/"] || part.length == 0) continue;
    if ([part isEqualToString:@".."]) {
      if (components.count == 0) return YES;
      [components removeLastObject];
    } else {
      [components addObject:part];
    }
  }
  for (NSString *part in [[NSString stringWithUTF8String:target] pathComponents]) {
    if ([part isEqualToString:@"."] || part.length == 0) continue;
    if ([part isEqualToString:@".."] ) {
      if (components.count == 0) return YES;
      [components removeLastObject];
    } else {
      [components addObject:part];
    }
  }
  return NO;
}

int validateIPAArchive(NSString* fileToValidate, uint64_t maximumExpandedSize, uint64_t maximumFileCount, NSString** errorMessage) {
    if (errorMessage) *errorMessage = nil;
    struct archive *a = archive_read_new();
    archive_read_support_format_zip(a);
    archive_read_support_filter_all(a);
    int r = archive_read_open_filename(a, fileToValidate.fileSystemRepresentation, 10240);
    if (r != ARCHIVE_OK) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Unable to open archive: %s", archive_error_string(a) ?: "unknown error"];
        archive_read_free(a);
        return 1;
    }
    uint64_t expandedSize = 0;
    uint64_t fileCount = 0;
    struct archive_entry *entry;
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK) {
            if (errorMessage) *errorMessage = [NSString stringWithUTF8String:archive_error_string(a) ?: "Unable to read archive"];
            archive_read_free(a);
            return 1;
        }
        const char *path = archive_entry_pathname(entry);
        if (path_is_unsafe(path)) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Unsafe archive path: %s", path ?: "(null)"];
            archive_read_free(a);
            return 2;
        }
        if (archive_entry_filetype(entry) == AE_IFLNK && symlink_escapes(path, archive_entry_symlink(entry))) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Symlink escapes archive root: %s", path ?: "(null)"];
            archive_read_free(a);
            return 3;
        }
        const char *hardlink = archive_entry_hardlink(entry);
        if (hardlink != NULL && path_is_unsafe(hardlink)) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Hard link escapes archive root: %s", hardlink];
            archive_read_free(a);
            return 3;
        }
        fileCount += 1;
        if (fileCount > maximumFileCount) {
            if (errorMessage) *errorMessage = @"Archive contains too many entries";
            archive_read_free(a);
            return 4;
        }
        la_int64_t size = archive_entry_size(entry);
        if (size > 0) {
            uint64_t unsignedSize = (uint64_t)size;
            if (unsignedSize > maximumExpandedSize - expandedSize) {
                if (errorMessage) *errorMessage = @"Archive expands beyond the configured limit";
                archive_read_free(a);
                return 5;
            }
            expandedSize += unsignedSize;
        }
        if (expandedSize > maximumExpandedSize) {
            if (errorMessage) *errorMessage = @"Archive expands beyond the configured limit";
            archive_read_free(a);
            return 5;
        }
        r = archive_read_data_skip(a);
        if (r < ARCHIVE_OK) {
            if (errorMessage) *errorMessage = [NSString stringWithUTF8String:archive_error_string(a) ?: "Unable to read archive data"];
            archive_read_free(a);
            return 1;
        }
    }
    archive_read_close(a);
    archive_read_free(a);
    return 0;
}

static int
copy_data(struct archive *ar, struct archive *aw, NSProgress *progress)
{
  int r;
  const void *buff;
  size_t size;
  la_int64_t offset;

  for (;;) {
    r = archive_read_data_block(ar, &buff, &size, &offset);
    if (r == ARCHIVE_EOF)
      return (ARCHIVE_OK);
    if (r < ARCHIVE_OK)
      return (r);
    r = archive_write_data_block(aw, buff, size, offset);
    if (r < ARCHIVE_OK) {
      fprintf(stderr, "%s\n", archive_error_string(aw));
      return (r);
    }
    progress.completedUnitCount += size;
  }
}

int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress)
{
    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int flags;
    int r;

    /* Select which attributes we want to restore. */
    flags = ARCHIVE_EXTRACT_TIME;
    flags |= ARCHIVE_EXTRACT_PERM;
    flags |= ARCHIVE_EXTRACT_ACL;
    flags |= ARCHIVE_EXTRACT_FFLAGS;
    flags |= ARCHIVE_EXTRACT_SECURE_NODOTDOT;
    flags |= ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS;
    flags |= ARCHIVE_EXTRACT_SECURE_SYMLINKS;

    // Calculate decompressed size
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            archive_read_close(a);
            archive_read_free(a);
            return 1;
        }
        progress.totalUnitCount += archive_entry_size(entry);
    }
    archive_read_close(a);
    archive_read_free(a);

    // Re-open the archive and extract
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r == ARCHIVE_EOF)
            break;
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN)
            break;
        
        NSString* currentFile = [NSString stringWithUTF8String:archive_entry_pathname(entry)];
        NSString* fullOutputPath = [extractionPath stringByAppendingPathComponent:currentFile];
        //printf("extracting %@ to %@\n", currentFile, fullOutputPath);
        archive_entry_set_pathname(entry, fullOutputPath.fileSystemRepresentation);
        
        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, progress);
            if (r < ARCHIVE_OK)
                fprintf(stderr, "%s\n", archive_error_string(ext));
            if (r < ARCHIVE_WARN)
                break;
        }
        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        if (r < ARCHIVE_WARN)
            break;
    }
    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);
    
    return 0;
}
