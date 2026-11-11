// Prints the space free for a build on the volume of a path, in whole GB, as Finder counts it:
// NSURLVolumeAvailableCapacityForImportantUsageKey includes space the system frees on demand
// (purgeable caches, local snapshots), which `df` leaves out and so understates by tens of GB.
// Built on first use by scripts/disk-free.sh; prints nothing and fails when the value is missing.
#import <Foundation/Foundation.h>

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString *path = argc > 1 ? @(argv[1]) : NSHomeDirectory();
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    NSDictionary *values = [url resourceValuesForKeys:@[
      NSURLVolumeAvailableCapacityForImportantUsageKey
    ] error:&error];
    NSNumber *bytes = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
    if (bytes == nil || bytes.longLongValue <= 0) { return 1; }
    printf("%lld\n", bytes.longLongValue / 1000000000LL);
  }
  return 0;
}
