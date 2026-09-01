// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

// ISLETA FORK. For the stdin control channel below.
#include <fcntl.h>
#include <unistd.h>

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "adapter/keys.h"
#import "adapter/now_playing.h"
#import "adapter/queue.h"
#import "private/MediaRemote.h"
#import "utility/Debounce.h"
#import "utility/helpers.h"

#ifndef DEBOUNCE_DELAY_MILLIS
#define DEBOUNCE_DELAY_MILLIS 0
#endif

static CFRunLoopRef g_runLoop = NULL;

static NSString *serializeData(NSDictionary *data, BOOL diff, BOOL pretty) {
    return serializeJsonDictionarySafe(
        @{
            @"type" : @"data",
            @"diff" : @(diff),
            @"payload" : data ?: @{},
        },
        pretty);
}

// ISLETA FORK. The queue line.
//
// A distinct `type` beside `{"type":"data"}` rather than a key inside the data payload, for the
// reason the diff protocol exists at all: the payload is a *diff*, and an array that is absent from
// a diff means "unchanged" while an array that is absent from a full state means "there is no
// queue". Those are opposite instructions and one dictionary cannot carry both. A separate line
// also means a consumer written before this existed drops it — `NowPlayingAdapterDecoder` returns
// nil for a `type` it does not know, on purpose.
static NSString *serializeQueue(NSArray<NSDictionary *> *items, BOOL pretty) {
    return serializeJsonDictionarySafe(
        @{
            @"type" : @"queue",
            kMRAQueueItems : items ?: @[],
        },
        pretty);
}

static NSDictionary *createDiff(NSDictionary *a, NSDictionary *b) {
    NSMutableDictionary *diff = [NSMutableDictionary dictionary];
    NSMutableSet *allKeys = [NSMutableSet setWithArray:a.allKeys];
    [allKeys addObjectsFromArray:b.allKeys];
    for (id key in allKeys) {
        id oldValue = a[key];
        id newValue = b[key];
        BOOL valuesDiffer = NO;
        if (oldValue == nil && newValue != nil) {
            valuesDiffer = YES;
        } else if (oldValue != nil && newValue == nil) {
            valuesDiffer = YES;
        } else if (![oldValue isEqual:newValue]) {
            valuesDiffer = YES;
        }
        if (valuesDiffer) {
            diff[key] = newValue ?: [NSNull null];
        }
    }
    return [diff copy];
}

static BOOL isSameItemIdentity(NSDictionary *a, NSDictionary *b) {
    NSArray<NSString *> *keys = identifyingPayloadKeys();
    for (NSString *key in keys) {
        id aValue = a[key];
        id bValue = b[key];
        if (aValue == nil && bValue == nil) {
            continue;
        }
        if (aValue == nil || bValue == nil) {
            return NO;
        }
        if (![aValue isEqual:bValue]) {
            return NO;
        }
    }
    return YES;
}

static NSDictionary *previousData = nil;

static void printData(NSDictionary *data, BOOL diff, BOOL pretty) {
    NSString *serialized = nil;
    if (diff && previousData != nil && isSameItemIdentity(previousData, data)) {
        NSDictionary *result = createDiff(previousData, data);
        if ([result count] == 0) {
            return;
        }
        serialized = serializeData(result, YES, pretty);
    } else {
        serialized = serializeData(data, NO, pretty);
    }
    if (serialized != nil) {
        if (diff) {
            previousData = [data copy];
        }
        // Print the serialized data without duplicates. Note that while this
        // can fail when the key order in the serialized JSON output changes,
        // it practically won't because if it did, there would also be a change
        // in values that needs to be reported.
        printOutUnique(serialized);
    }
    if (!diff) {
        previousData = nil;
    }
}

static void appForNotification(NSNotification *notification,
                               void (^block)(NSRunningApplication *)) {
    NSDictionary *userInfo = notification.userInfo;
    id pidValue = userInfo[kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey];
    if (pidValue != nil) {
        int pid = [pidValue intValue];
        appForPID(pid, block);
    } else {
        block(nil);
    }
};

typedef struct MetadataStats {
    BOOL trackTitleChanged;
    int identifyingTrackKeysIdentical;
    int identifyingTrackKeysChanged;
} MetadataStats;

static MetadataStats createMetadataStats() {
    MetadataStats stats = {
        .trackTitleChanged = NO,
        .identifyingTrackKeysIdentical = 0,
        .identifyingTrackKeysChanged = 0,
    };
    return stats;
}

static MetadataStats compareIdentifyingTrackKeys(NSDictionary *prev,
                                                 NSDictionary *next) {
    MetadataStats stats = createMetadataStats();
    for (NSString *key in @[ kMRATitle, kMRAArtist, kMRAAlbum ]) {
        id a = prev[key], b = next[key];
        if (a == nil || b == nil)
            continue;
        if ([a isEqual:b]) {
            stats.identifyingTrackKeysIdentical++;
        } else {
            stats.identifyingTrackKeysChanged++;
            if ([key isEqualToString:kMRATitle]) {
                stats.trackTitleChanged = YES;
            }
        }
    }
    return stats;
}

extern void adapter_stream() {

    // Get ADAPTER_TEST_MODE as a boolean and set BOOL isTestMode
    BOOL isTestMode = NO;
    char *testModeEnv = getenv("ADAPTER_TEST_MODE");
    if (testModeEnv && strcmp(testModeEnv, "0") != 0 &&
        strlen(testModeEnv) > 0) {
        isTestMode = YES;
    }

    int debounce_delay_millis = 0;
    NSNumber *debounce_option = getEnvOptionInt(@"debounce");
    if (debounce_option != nil) {
        debounce_delay_millis = [debounce_option intValue];
    }

    // ISLETA FORK. Opt-in, so the default output of this fork is byte-identical to upstream's —
    // other consumers of the same script must not start receiving a line type they have never
    // heard of because Isleta wanted one.
    NSString *queue_option = getEnvOption(@"queue");
    NSNumber *queue_length_option = getEnvOptionInt(@"length");

    NSString *no_diff_option = getEnvOption(@"no_diff");
    NSString *no_artwork_option = getEnvOption(@"no-artwork");
    NSString *micros_option = getEnvOption(@"micros");
    NSString *human_readable_option = getEnvOption(@"human-readable");

    // This option is needed for media players which, when changing tracks,
    // update the artist and/or other fields later than e.g. the title, the
    // invalid in-between metadata therefore representing "peculiar" media. The
    // only known player that does this is the TIDAL desktop player with the
    // bundle ID "com.tidal.desktop". This is easy to reproduce when playing
    // media from a playlist with tracks from different artists.
    // FIXME Implement this for any bundle ID, should other players need it.
    // In that case parse any "experimental-peculiar-debounce:*" option.
    NSNumber *peculiar_debounce_option =
        getEnvOptionInt(@"experimental-peculiar-debounce:com.tidal.desktop");
    __block NSString *peculiar_bundle_id = nil;
    __block Debounce *peculiar_debounce = nil;
    __block BOOL did_peculiar_debounce = NO;
    if (peculiar_debounce_option != nil) {
        peculiar_bundle_id = @"com.tidal.desktop";
        int debounce_millis = [peculiar_debounce_option intValue];
        peculiar_debounce =
            [[Debounce alloc] initWithDelay:(debounce_millis / 1000.0)
                                      queue:g_serialdispatchQueue];
    }

    __block NSMutableDictionary *liveData = [NSMutableDictionary dictionary];
    __block MetadataStats liveDataStats = createMetadataStats();
    __block const Debounce *const debounce =
        [[Debounce alloc] initWithDelay:(debounce_delay_millis / 1000.0)
                                  queue:g_serialdispatchQueue];
    __block const BOOL no_diff = (no_diff_option != nil);
    __block const BOOL no_artwork = (no_artwork_option != nil);
    __block const BOOL convert_micros = (micros_option != nil);
    __block const bool human_readable = (human_readable_option != nil);
    __block const BOOL with_queue = (queue_option != nil);
    // ISLETA FORK. Not `const`: the window grows on request. See the control channel below.
    __block NSUInteger queue_length =
        queue_length_option != nil
            ? (NSUInteger)MIN(QUEUE_MAX_LENGTH, MAX(1, [queue_length_option intValue]))
            : QUEUE_DEFAULT_LENGTH;

    void (^localPrintData)(NSDictionary *) = ^(NSDictionary *data) {
      printData(data, !no_diff, human_readable);
    };

    void (^directHandle)() = ^() {
      if (allMandatoryPayloadKeysSet(liveData)) {
          if (human_readable) {
              NSMutableDictionary *shallowClone =
                  [NSMutableDictionary dictionaryWithDictionary:liveData];
              makePayloadHumanReadable(shallowClone);
              localPrintData(shallowClone);
          } else {
              localPrintData(liveData);
          }
      } else {
          localPrintData(nil);
      }
    };

    void (^internalHandle)(bool) = ^(bool updatedStats) {
      if (peculiar_debounce == nil ||
          ![peculiar_bundle_id isEqual:liveData[kMRABundleIdentifier]]) {
          directHandle();
          return;
      }
      if (updatedStats && liveDataStats.trackTitleChanged &&
          liveDataStats.identifyingTrackKeysIdentical > 0) {
          did_peculiar_debounce = true;
          [peculiar_debounce call:^{
            did_peculiar_debounce = false;
            directHandle();
          }];
      } else if (did_peculiar_debounce &&
                 (!updatedStats ||
                  liveDataStats.identifyingTrackKeysChanged == 0)) {
          // Ignore this handle call, since there is an active debounce call.
      } else {
          [peculiar_debounce cancel];
          did_peculiar_debounce = false;
          directHandle();
      }
    };

    void (^handle)() = ^() {
      internalHandle(false);
    };

    void (^handleWithUpdatedStats)() = ^() {
      internalHandle(true);
    };

    // ISLETA FORK. One queue read, printed only when it says something new.
    //
    // `printOut` with a dedupe of its own rather than `printOutUnique`, because that helper holds a
    // single static "previous line" shared by every caller: a queue line landing between two
    // identical data lines would reset it and let the second data line through. Two independent
    // dedupes, one per line type, is the only arrangement where interleaving is harmless.
    __block NSString *previous_queue_line = nil;
    void (^requestQueue)() = ^{
      if (!with_queue) {
          return;
      }
      requestPlaybackQueueWindow(
          queue_length, ^(NSArray<NSDictionary *> *items, NSError *error) {
            if (error != nil) {
                // stderr only. A queue the player will not vend is a garnish going missing, not a
                // stream that has failed, and printing a line for it would retire a healthy route.
                printErrf(@"Failed to read the playback queue: %@", formatError(error));
                return;
            }
            if (items == nil) {
                return;
            }
            NSString *serialized = serializeQueue(items, human_readable);
            if (serialized == nil ||
                [previous_queue_line isEqualToString:serialized]) {
                return;
            }
            previous_queue_line = [serialized copy];
            printOut(serialized);
          });
    };

    void (^requestNowPlayingApplicationPID)() = ^{
      g_mediaRemote.getNowPlayingApplicationPID(
          g_serialdispatchQueue, ^(int pid) {
            if (pid == 0) {
                liveData[kMRAProcessIdentifier] = nil;
                handle();
                return;
            }
            liveData[kMRAProcessIdentifier] = @(pid);
            bool ok = appForPID(pid, ^(NSRunningApplication *process) {
              if (process.bundleIdentifier != nil) {
                  liveData[kMRABundleIdentifier] = process.bundleIdentifier;
              }
              handle();
            });
            if (!ok) {
                handle();
            }
          });
    };

    void (^requestNowPlayingParentApplicationBundleIdentifier)() = ^{
      g_mediaRemote.getNowPlayingClient(g_serialdispatchQueue, ^(id client) {
        NSString *parentAppBundleID = nil;
        if (client && [client respondsToSelector:@selector
                              (parentApplicationBundleIdentifier)]) {
            id result = [client
                performSelector:@selector(parentApplicationBundleIdentifier)];
            if ([result isKindOfClass:[NSString class]]) {
                parentAppBundleID = result;
            }
        }
        if (parentAppBundleID) {
            liveData[kMRAParentApplicationBundleIdentifier] = parentAppBundleID;
        } else {
            [liveData removeObjectForKey:kMRAParentApplicationBundleIdentifier];
        }
        handle();
      });
    };

    void (^requestNowPlayingApplicationIsPlaying)() = ^{
      g_mediaRemote.getNowPlayingApplicationIsPlaying(
          g_serialdispatchQueue, ^(bool isPlaying) {
            liveData[kMRAPlaying] = @(isPlaying);
            handle();
          });
    };

    void (^requestNowPlayingInfo)() = ^{
      g_mediaRemote.getNowPlayingInfo(g_serialdispatchQueue, ^(
                                          NSDictionary *information) {
        NSString *serviceIdentifier =
            information[kMRMediaRemoteNowPlayingInfoServiceIdentifier];
        if (!isTestMode &&
            [serviceIdentifier
                isEqualToString:
                    @"com.vandenbe.MediaRemoteAdapter.TestClient"]) {
            return;
        }
        NSMutableDictionary *converted = convertNowPlayingInformation(
            information, convert_micros, false, no_artwork);
        // Transfer anything over from the existing live data.
        if (liveData[kMRAProcessIdentifier] != nil) {
            converted[kMRAProcessIdentifier] = liveData[kMRAProcessIdentifier];
        }
        if (liveData[kMRABundleIdentifier] != nil) {
            converted[kMRABundleIdentifier] = liveData[kMRABundleIdentifier];
        }
        if (liveData[kMRAParentApplicationBundleIdentifier] != nil) {
            converted[kMRAParentApplicationBundleIdentifier] =
                liveData[kMRAParentApplicationBundleIdentifier];
        }
        if (liveData[kMRAPlaying] != nil) {
            converted[kMRAPlaying] = liveData[kMRAPlaying];
        }
        // Use the old artwork data, since often the MediaRemote framework
        // unloads the artwork and then loads it again shortly after.
        // Only do this when the items have the same identity.
        if (isSameItemIdentity(liveData, converted) &&
            liveData[kMRAArtworkData] != nil &&
            liveData[kMRAArtworkData] != [NSNull null] &&
            converted[kMRAArtworkData] == nil) {
            converted[kMRAArtworkData] = liveData[kMRAArtworkData];
            if (liveData[kMRAArtworkMimeType] != nil &&
                liveData[kMRAArtworkMimeType] != [NSNull null] &&
                converted[kMRAArtworkMimeType] == nil) {
                converted[kMRAArtworkMimeType] = liveData[kMRAArtworkMimeType];
            }
        }

        liveDataStats = compareIdentifyingTrackKeys(liveData, converted);
        [liveData setDictionary:converted];
        handleWithUpdatedStats();
      });
    };

    void (^requestAll)() = ^{
      requestNowPlayingApplicationPID();
      requestNowPlayingParentApplicationBundleIdentifier();
      requestNowPlayingApplicationIsPlaying();
      requestNowPlayingInfo();
    };

    void (^resetAll)() = ^{
      [liveData removeAllObjects];
    };

    void (^refreshAll)() = ^{
      resetAll();
      requestAll();
    };

    // FIXME Is this foolproof? This continues and registers observers
    // which might intervene with the initial requests.
    requestAll();

    // ISLETA FORK. The queue as it stands right now, so a stream that starts mid-track knows what
    // is next without waiting for the user to touch anything. On `g_serialdispatchQueue` because
    // `previous_queue_line` lives there.
    dispatch_async(g_serialdispatchQueue, ^() {
      requestQueue();
    });

    // ISLETA FORK. The control channel: one line of stdin, and the only thing it can say is how big
    // a window to ask for.
    //
    // ## Why there is a channel at all
    //
    // A queue is not a list, it is a *window* onto one — a music library on shuffle is tens of
    // thousands of items, and `+defaultPlaybackQueueRequest` asks for every one of them. So a
    // scrollable Up Next has to ask for what is on screen plus a page, and ask again when the reader
    // reaches the end. The alternative is a one-shot `perl … queue --length=N` per scroll, which
    // costs 60-360 ms of process spawn against a 15-30 ms read: a process per flick of a trackpad.
    //
    // ## Why stdin is safe here and was not before
    //
    // The reader hands this process `/dev/null` for stdin precisely so that a helper sharing a
    // development terminal cannot take SIGTTIN and stop. That reasoning is about a *terminal*, and
    // it is untouched: a pipe is not a controlling terminal and reading from one cannot raise
    // SIGTTIN. With `/dev/null` still attached — which is what every consumer that has never heard
    // of this gets — the first read returns EOF, the source cancels itself, and nothing else
    // changes. The channel is opt-in twice over: no `--queue`, no source at all.
    //
    // Two rules that are not obvious:
    //
    // - **EOF must not end the stream.** stdin closing says nothing about whether MediaRemote still
    //   has something to report, and exiting on it would retire a healthy route the moment a caller
    //   closed a pipe it had finished with.
    // - **A new length clears `previous_queue_line`.** The dedupe compares serialized lines, and a
    //   longer window whose first entries are identical serialises to a *different* string only
    //   because it is longer — but a *shorter* one asked for after a longer one is a prefix, and the
    //   comparison would let it through while the reverse case looked like a repeat. Clearing is one
    //   rule instead of two and cannot be wrong in either direction.
    __block dispatch_source_t control_source = NULL;
    if (with_queue) {
        // Non-blocking, because the read below happens on the serial queue every other piece of
        // this stream also runs on: a blocking read on a pipe nobody is writing to would park the
        // queue that answers MediaRemote's notifications.
        int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
        if (flags != -1) {
            fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
        }
        control_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0,
                                                g_serialdispatchQueue);
        if (control_source != NULL) {
            __block NSMutableData *control_buffer = [NSMutableData data];
            dispatch_source_set_event_handler(control_source, ^{
              char chunk[512];
              ssize_t count = read(STDIN_FILENO, chunk, sizeof(chunk));
              if (count <= 0) {
                  // EOF, or a pipe that has gone away. Cancel and leave the stream running.
                  dispatch_source_cancel(control_source);
                  return;
              }
              [control_buffer appendBytes:chunk length:(NSUInteger)count];

              // Newline framing. A pipe read is not a line, here for the same reason it is not one
              // on the way out.
              while (true) {
                  const char *bytes = (const char *)control_buffer.bytes;
                  NSUInteger length = control_buffer.length;
                  NSUInteger newline = NSNotFound;
                  for (NSUInteger i = 0; i < length; i++) {
                      if (bytes[i] == '\n') {
                          newline = i;
                          break;
                      }
                  }
                  if (newline == NSNotFound) {
                      // A caller that never sends a newline must not be able to grow this forever.
                      if (length > 4096) {
                          [control_buffer setLength:0];
                      }
                      break;
                  }
                  NSString *line = [[NSString alloc] initWithBytes:bytes
                                                            length:newline
                                                          encoding:NSUTF8StringEncoding];
                  [control_buffer replaceBytesInRange:NSMakeRange(0, newline + 1)
                                            withBytes:NULL
                                               length:0];
                  if (line == nil) {
                      continue;
                  }
                  line = [line
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                  if ([line hasPrefix:@"length "]) {
                      NSInteger requested = [[line substringFromIndex:7] integerValue];
                      if (requested < 1) {
                          requested = 1;
                      }
                      if (requested > QUEUE_MAX_LENGTH) {
                          requested = QUEUE_MAX_LENGTH;
                      }
                      queue_length = (NSUInteger)requested;
                      previous_queue_line = nil;
                      requestQueue();
                  } else if ([line isEqualToString:@"queue"]) {
                      previous_queue_line = nil;
                      requestQueue();
                  }
                  // Anything else is silence, for the same reason the decoder treats an unknown
                  // line type as silence: a caller from a later version saying something this one
                  // has not heard of must not be able to stop the stream.
              }
            });
            dispatch_resume(control_source);
        }
    }

    NSNotificationCenter *default_center = [NSNotificationCenter defaultCenter];
    NSNotificationCenter *shared_workscape_notification_center =
        [[NSWorkspace sharedWorkspace] notificationCenter];

    // TODO Refactor the below two callbacks. They share a lot of code.

    id is_playing_change_observer = [default_center
        addObserverForName:
            kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
                  dispatch_async(g_serialdispatchQueue, ^() {
                    appForNotification(notification, ^(
                                           NSRunningApplication *process) {
                      if (process == nil) {
                          // The process for this notification could not be
                          // determined. Assume that there is no now playing
                          // application anymore.
                          resetAll();
                          handle();
                          return;
                      }
                      id isPlayingValue =
                          notification.userInfo
                              [kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey];
                      if (isPlayingValue == nil) {
                          return;
                      }
                      if (liveData[kMRABundleIdentifier] != nil &&
                          process.bundleIdentifier != nil &&
                          ![liveData[kMRABundleIdentifier]
                              isEqual:process.bundleIdentifier]) {
                          // This is a different process, reset all data.
                          resetAll();
                      }
                      if (liveData[kMRAProcessIdentifier] != nil &&
                          ![liveData[kMRAProcessIdentifier]
                              isEqual:@(process.processIdentifier)]) {
                          // This is a different process, reset all data.
                          resetAll();
                      }
                      liveData[kMRABundleIdentifier] = process.bundleIdentifier;
                      requestNowPlayingParentApplicationBundleIdentifier();
                      liveData[kMRAPlaying] = @([isPlayingValue boolValue]);
                      if (liveData[kMRATitle] == nil) {
                          requestNowPlayingInfo();
                      } else {
                          handle();
                      }
                    });
                  });
                }];

    id info_change_observer = [default_center
        addObserverForName:kMRMediaRemoteNowPlayingInfoDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
                  [debounce call:^{
                    appForNotification(notification, ^(
                                           NSRunningApplication *process) {
                      if (process == nil) {
                          // The process for this notification could not be
                          // determined. Assume that there is no now playing
                          // application anymore.
                          resetAll();
                          handle();
                          return;
                      }
                      if (liveData[kMRABundleIdentifier] != nil &&
                          process.bundleIdentifier != nil &&
                          ![liveData[kMRABundleIdentifier]
                              isEqual:process.bundleIdentifier]) {
                          // This is a different process, reset all data.
                          resetAll();
                      }
                      if (liveData[kMRAProcessIdentifier] != nil &&
                          ![liveData[kMRAProcessIdentifier]
                              isEqual:@(process.processIdentifier)]) {
                          // This is a different process, reset all data.
                          resetAll();
                      }
                      if (liveData[kMRAProcessIdentifier] == nil) {
                          requestNowPlayingApplicationPID();
                      }
                      if (liveData[kMRAParentApplicationBundleIdentifier] ==
                          nil) {
                          requestNowPlayingParentApplicationBundleIdentifier();
                      }
                      if (liveData[kMRAPlaying] == nil) {
                          requestNowPlayingApplicationIsPlaying();
                      }
                      requestNowPlayingInfo();
                    });
                  }];
                }];

    // Register notifications for when applications are closed.
    id app_termination_observer = [shared_workscape_notification_center
        addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
                  dispatch_async(g_serialdispatchQueue, ^() {
                    NSDictionary *userInfo = [notification userInfo];
                    id bundleIdentifier =
                        userInfo[@"NSApplicationBundleIdentifier"];
                    if (bundleIdentifier != nil &&
                        [bundleIdentifier
                            isEqual:liveData[kMRABundleIdentifier]]) {
                        // Refresh all data, since the application terminated.
                        refreshAll();
                    }
                  });
                }];

    // ISLETA FORK. Both names, and neither is the one our own header declares.
    //
    // `kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification` — the declared name, and the one
    // anybody would register for — produced zero callbacks against a queue that was demonstrably
    // changing. Registration returns void, so that was silent. These two fire, in the same
    // millisecond as the info change handled above, which is why folding the read in here costs one
    // extra request per track change and no timer anywhere.
    //
    // Both are registered rather than either, because they are posted by different halves of
    // MediaRemote and nothing says one implies the other. The dedupe above absorbs the duplicate.
    NSMutableArray *queue_observers = [NSMutableArray array];
    if (with_queue) {
        for (NSString *name in @[
                 kMRNowPlayingPlaybackQueueChangedNotification,
                 kMRPlayerPlaybackQueueChangedNotification
             ]) {
            id observer = [default_center addObserverForName:name
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *n) {
                                                    dispatch_async(g_serialdispatchQueue, ^() {
                                                      requestQueue();
                                                    });
                                                  }];
            [queue_observers addObject:observer];
        }
    }

    g_mediaRemote.registerForNowPlayingNotifications(g_serialdispatchQueue);

    CFRunLoopRun();

    g_mediaRemote.unregisterForNowPlayingNotifications();

    // ISLETA FORK. Cancelled rather than left to the process exiting, so that the fork behaves the
    // same whether `adapter_stream` returns or the process is signalled.
    if (control_source != NULL) {
        dispatch_source_cancel(control_source);
        control_source = NULL;
    }

    for (id observer in queue_observers) {
        [default_center removeObserver:observer];
    }
    [default_center removeObserver:is_playing_change_observer];
    [default_center removeObserver:info_change_observer];
    [shared_workscape_notification_center
        removeObserver:app_termination_observer];
}

extern void adapter_stream_env() { adapter_stream(); }

extern void _adapter_stream_cancel() {
    if (g_runLoop) {
        CFRunLoopStop(g_runLoop);
    }
}

static void handleSignal(int signal) {
    if (signal == SIGINT || signal == SIGTERM) {
        _adapter_stream_cancel();
    }
}

__attribute__((constructor)) static void init() {
    g_runLoop = CFRunLoopGetCurrent();
    signal(SIGINT, handleSignal);
    signal(SIGTERM, handleSignal);
}
__attribute__((destructor)) static void teardown() { _adapter_stream_cancel(); }

// FIXME Fix "peculiar media" (artist is updated later than title). Example:
/*
35.558 Thirteen by Big Star on Camping Songs
36.091 Good Vibrations (Remastered 2001) by Big Star on Camping Songs
36.204 Good Vibrations (Remastered 2001) by Big Star on Camping Songs (+image)
36.624 Good Vibrations (Remastered 2001) by The Beach Boys on Camping Songs
*/
