// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.
//
// ISLETA FORK. See queue.h for why this lives in the vendored adapter and not in Isleta.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "adapter/keys.h"
#import "adapter/queue.h"
#import "private/MediaRemote.h"
#import "utility/helpers.h"

#define QUEUE_TIMEOUT_MILLIS 2000
#define JSON_NULL @"null"

/// One `MRContentItem` as a JSON-ready dictionary, or nil for an item with nothing to say.
///
/// Nil rather than an empty dictionary for an item with no title, and that is the same rule
/// `allMandatoryPayloadKeysSet` applies to the now-playing payload: an entry a user could not read
/// is not an entry. It matters more here than there, because the caller discriminates the queue
/// **positionally** — index 0 is the current track — so a placeholder that keeps its slot would
/// make the item after it read as the next song when it is the one after that.
///
/// Every accessor is guarded with `respondsToSelector:`. The classes are declared in our own header
/// rather than reflected, so a missing selector is not a typo we would catch at compile time; it is
/// an OS that has moved on, and the honest answer to that is a shorter dictionary rather than a
/// crash inside a Perl process nobody is watching.
static NSDictionary *itemDictionary(id item) {
    if (![item respondsToSelector:@selector(metadata)]) {
        return nil;
    }
    id metadata = [item metadata];
    if (metadata == nil) {
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    if ([metadata respondsToSelector:@selector(title)]) {
        NSString *title = [metadata title];
        if (![title isKindOfClass:[NSString class]] || title.length == 0) {
            return nil;
        }
        result[kMRATitle] = title;
    } else {
        return nil;
    }

    if ([metadata respondsToSelector:@selector(trackArtistName)]) {
        NSString *artist = [metadata trackArtistName];
        if ([artist isKindOfClass:[NSString class]] && artist.length > 0) {
            result[kMRAArtist] = artist;
        }
    }
    if ([metadata respondsToSelector:@selector(albumName)]) {
        NSString *album = [metadata albumName];
        if ([album isKindOfClass:[NSString class]] && album.length > 0) {
            result[kMRAAlbum] = album;
        }
    }
    // Seconds, and deliberately not converted by `--micros`. That option exists because the
    // *playhead* is anchored to a timestamp and a rounding error there makes a scrub bar step; a
    // queue entry's duration is a track length that nothing is anchored to.
    if ([metadata respondsToSelector:@selector(duration)]) {
        double duration = [metadata duration];
        if (duration > 0) {
            result[kMRADuration] = @(duration);
        }
    }
    // The join key a lyrics or artwork service would need, and the one field of this whole read
    // that turned out better than expected. Zero means the item has none — a local file, a stream.
    // ISLETA FORK. **The audio format, which exists nowhere else.**
    //
    // Measured on macOS 27.0, 2026-08-28, after everything else was tried and failed: MediaRemote's
    // now-playing *dictionary* has no codec, bitrate or quality key; Music's scripting answers
    // `kind: ""` for anything from Apple Music, streamed or downloaded; and
    // `MRNowPlayingAudioFormatController` — which models it with the right vocabulary — never gets
    // its content infos fed outside the system's own UI. The one place the answer is actually
    // published to a client is here, on the *queue item's* metadata:
    //
    //     activeFormat = { bitDepth = 16; bitrate = 0; codec = 1902928227 ('qlac');
    //                      multiChannel = 0; renderingMode = 1; sampleRate = 44100;
    //                      spatialized = 0; tier = 2; }
    //
    // Only the **currently playing** entry carries it — index 1 and beyond answer nil — which is
    // exactly the entry Isleta wants and no loss at all.
    //
    // Emitted as the raw fields rather than as a name. Naming is a product decision and belongs in
    // `AudioFormat`, on the Swift side, where it can be tested; this end's job is to not lose
    // anything on the way through.
    if ([metadata respondsToSelector:@selector(activeFormat)]) {
        id format = [metadata activeFormat];
        if (format != nil && [format respondsToSelector:@selector(dictionaryRepresentation)]) {
            NSDictionary *audio = [format dictionaryRepresentation];
            // Only what serialises. The dictionary is the framework's own and could grow a value
            // JSON has no spelling for, and one of those turns a queue line into a parse failure
            // for every consumer rather than a missing field for one.
            if ([audio isKindOfClass:[NSDictionary class]] &&
                [NSJSONSerialization isValidJSONObject:audio]) {
                result[kMRAAudioFormat] = audio;
            }
        }
    }

    if ([metadata respondsToSelector:@selector(iTunesStoreIdentifier)]) {
        long long storeIdentifier = [metadata iTunesStoreIdentifier];
        if (storeIdentifier != 0) {
            result[kMRAITunesStoreIdentifier] = @(storeIdentifier);
        }
    }
    // The same key the now-playing payload carries, so a consumer can check that index 0 really is
    // the track it thinks is playing. That check is worth having and is **not** a substitute for
    // the positional rule: it can only ever confirm index 0, and the field that claims to identify
    // the playing item — `isCurrentlyPlaying` — answers 0 for all of them.
    if ([item respondsToSelector:@selector(identifier)]) {
        NSString *identifier = [item identifier];
        if ([identifier isKindOfClass:[NSString class]] && identifier.length > 0) {
            result[kMRAContentItemIdentifier] = identifier;
        }
    }

    return result;
}

void requestPlaybackQueueWindow(NSUInteger length,
                                void (^completion)(NSArray<NSDictionary *> *items,
                                                   NSError *error)) {
    MRMediaRemoteRequestNowPlayingPlaybackQueueSync_t request =
        g_mediaRemote.requestNowPlayingPlaybackQueue;
    if (request == NULL) {
        completion(nil, [NSError errorWithDomain:@"MediaRemoteAdapter"
                                            code:1
                                        userInfo:@{
                                            NSLocalizedDescriptionKey :
                                                @"MRMediaRemoteRequestNowPlayingPlaybackQueueSync "
                                                @"is not available on this system"
                                        }]);
        return;
    }

    Class requestClass = NSClassFromString(@"MRPlaybackQueueRequest");
    if (requestClass == nil ||
        ![requestClass respondsToSelector:@selector(defaultPlaybackQueueRequestWithRange:)]) {
        completion(nil, [NSError errorWithDomain:@"MediaRemoteAdapter"
                                            code:2
                                        userInfo:@{
                                            NSLocalizedDescriptionKey :
                                                @"MRPlaybackQueueRequest is not available on this "
                                                @"system"
                                        }]);
        return;
    }

    NSUInteger clamped = length;
    if (clamped < 1) {
        clamped = 1;
    }
    if (clamped > QUEUE_MAX_LENGTH) {
        clamped = QUEUE_MAX_LENGTH;
    }

    // From zero, always. The window is not a page into the queue — it is "the current track and the
    // few after it", and the player has already dropped everything played, so zero is where the
    // answer starts.
    id queueRequest =
        [requestClass defaultPlaybackQueueRequestWithRange:NSMakeRange(0, clamped)];
    if (queueRequest == nil) {
        completion(nil, nil);
        return;
    }
    // Both flags, because they answer different halves and neither is the default. Without
    // `includeMetadata` the items come back as bare identifiers, which is a list of strings no user
    // could read; `includeInfo` is what fills in the rest of each entry.
    if ([queueRequest respondsToSelector:@selector(setIncludeMetadata:)]) {
        [queueRequest setIncludeMetadata:YES];
    }
    if ([queueRequest respondsToSelector:@selector(setIncludeInfo:)]) {
        [queueRequest setIncludeInfo:YES];
    }

    request(queueRequest, g_serialdispatchQueue, ^(id queue, NSError *error) {
      if (error != nil) {
          completion(nil, error);
          return;
      }
      if (queue == nil || ![queue respondsToSelector:@selector(contentItems)]) {
          completion(nil, nil);
          return;
      }
      NSArray *contentItems = [queue contentItems];
      if (![contentItems isKindOfClass:[NSArray class]]) {
          completion(nil, nil);
          return;
      }
      NSMutableArray<NSDictionary *> *items =
          [NSMutableArray arrayWithCapacity:contentItems.count];
      for (id item in contentItems) {
          NSDictionary *converted = itemDictionary(item);
          if (converted != nil) {
              [items addObject:converted];
          }
      }
      completion([items copy], nil);
    });
}

void adapter_queue(unsigned long length) {
    NSString *human_readable_option = getEnvOption(@"human-readable");
    const bool human_readable = human_readable_option != nil;

    __block NSArray<NSDictionary *> *result = nil;
    __block NSError *failure = nil;

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    requestPlaybackQueueWindow((NSUInteger)length,
                               ^(NSArray<NSDictionary *> *items, NSError *error) {
                                 result = items;
                                 failure = error;
                                 dispatch_group_leave(group);
                               });

    dispatch_time_t timeout =
        dispatch_time(DISPATCH_TIME_NOW, QUEUE_TIMEOUT_MILLIS * NSEC_PER_MSEC);
    if (dispatch_group_wait(group, timeout) != 0) {
        printErrf(@"Reading the playback queue timed out after %d milliseconds",
                  QUEUE_TIMEOUT_MILLIS);
        printOut(JSON_NULL);
        return;
    }

    if (failure != nil) {
        // stderr and a `null` on stdout, rather than a non-zero exit. A refusal here says nothing
        // about whether the rest of the adapter works — the caller's stream is very likely healthy
        // — and exiting would retire a route over a feature that is a garnish on it.
        printErr(formatError(failure));
        printOut(JSON_NULL);
        return;
    }

    if (result == nil) {
        printOut(JSON_NULL);
        return;
    }

    NSString *serialized =
        serializeJsonDictionarySafe(@{kMRAQueueItems : result}, human_readable);
    printOut(serialized ?: JSON_NULL);
}

static inline unsigned long queue_0_length() {
    NSNumber *option = getEnvOptionInt(@"length");
    if (option == nil) {
        return QUEUE_DEFAULT_LENGTH;
    }
    long value = [option longValue];
    return value < 1 ? QUEUE_DEFAULT_LENGTH : (unsigned long)value;
}

extern void adapter_queue_env() { adapter_queue(queue_0_length()); }
