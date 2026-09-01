// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.
//
// ISLETA FORK. This whole file is Isleta's, added to the vendored copy of
// `ungive/mediaremote-adapter` rather than to Isleta itself. That placement is the point: the
// queue is behind the same code-signing-identifier gate as the now-playing info, so it can only be
// asked by Apple's Perl, which means it belongs to the framework Perl loads. Nothing here is a new
// private path in Isleta — CLAUDE.md's two-paths rule is untouched.

#ifndef MEDIAREMOTEADAPTER_ADAPTER_QUEUE_H
#define MEDIAREMOTEADAPTER_ADAPTER_QUEUE_H

#import <Foundation/Foundation.h>

// The default number of queue entries asked for.
//
// Five, which is the current track and four behind it. A 5-item window costs 4-5 ms against 15-30
// for 25, and the Up Next sneak peek reads exactly one of them — the rest are asked for so that a
// later milestone showing the next few has nothing to change on this side.
#define QUEUE_DEFAULT_LENGTH 5

// The most that may be asked for.
//
// Not a performance guard so much as a guard against the parameterless constructor's behaviour
// arriving by another road: `+defaultPlaybackQueueRequest` asks for the entire queue, and a music
// library on shuffle is tens of thousands of items. A caller that wants a scrollable queue wants
// paging, not a bigger number here.
#define QUEUE_MAX_LENGTH 100

// Asks for a window of the playback queue and answers on `g_serialdispatchQueue`.
//
// `items` is an array of JSON-ready dictionaries in queue order, or nil with `error` set. Both may
// be nil: a player with no queue is not an error, and neither is a machine with nothing playing.
//
// Never blocks. The one-shot `adapter_queue` does its own waiting; `stream` must not, because it
// is called from a notification callback on the same serial queue the answer arrives on.
void requestPlaybackQueueWindow(NSUInteger length,
                                void (^completion)(NSArray<NSDictionary *> *items,
                                                   NSError *error));

#endif // MEDIAREMOTEADAPTER_ADAPTER_QUEUE_H
