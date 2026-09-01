// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include "private/MediaRemote.h"
#include <limits.h>

#import <Foundation/Foundation.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "adapter/now_playing.h"
#import "utility/helpers.h"

static NSArray<NSNumber *> *acceptedCommands;

__attribute__((constructor)) static void init() {
    acceptedCommands = @[
        @(kMRAPlay),
        @(kMRAPause),
        @(kMRATogglePlayPause),
        @(kMRAStop),
        @(kMRANextTrack),
        @(kMRAPreviousTrack),
        @(kMRAToggleShuffle),
        @(kMRAToggleRepeat),
        @(kMRAStartForwardSeek),
        @(kMRAEndForwardSeek),
        @(kMRAStartBackwardSeek),
        @(kMRAEndBackwardSeek),
        @(kMRAGoBackFifteenSeconds),
        @(kMRASkipFifteenSeconds),
        // ISLETA FORK. The three that carry options.
        //
        // Whitelisting them is only half of what was missing: `adapter_send` called
        // `sendCommand(value, nil)` with the userInfo **hardcoded**, so none of them could have been
        // expressed even with the id allowed. See `sendUserInfo` below.
        //
        // Upstream's own note here — "TODO like/unlike tracks by reading now playing information
        // first, getting the track ID, station ID and station hash" — describes the *ordinary*
        // like, the one Apple Music's radio uses. It is left in place, because that reading is
        // genuinely still to do and this fork does not do it: Isleta passes the ids it is given and
        // has no opinion about where they came from.
        @(kMRALikeTrack),
        @(kMRABanTrack),
        @(kMRAPlayItemInPlaybackQueue),
    ];
    // TODO like/unlike tracks by reading now playing information first,
    // getting the track ID, station ID and station hash
    // and then sending the respective MRCommand.
    // does "ban" mean "remove like" here?
}

static MRCommand findCommand(int command, bool *found) {
    if ([acceptedCommands containsObject:@(command)]) {
        *found = true;
        return (MRCommand)command;
    }
    *found = false;
    return (MRCommand)0;
}

// ISLETA FORK. The options a command may carry, as MediaRemote's own userInfo dictionary.
//
// `nil` rather than an empty dictionary when nothing was given, because that is what the fourteen
// commands upstream already sends are documented to take and it is what they were being sent
// before this existed. An empty dictionary is not obviously the same thing to MediaRemote and
// there is no reason to find out.
//
// **A key is either absent or carries a value; it is never present and null.** MediaRemote reads
// these positionally in places and a `NSNull` where a number is expected is not a missing option,
// it is a wrong one — and a wrong option here does not fail, it succeeds and does nothing, which
// is the failure mode this whole area is built around.
static NSDictionary *sendUserInfo() {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];

    // The queue jump. Both keys or neither is worth stating out loud: the offset alone is exactly
    // the combination that returns success and changes nothing.
    NSNumber *offset = getEnvOptionInt(@"offset");
    if (offset != nil) {
        userInfo[kMRMediaRemoteOptionPlaybackQueueOffset] = offset;
    }
    NSString *contentItemID = getEnvOption(@"content-item-id");
    if (contentItemID != nil && contentItemID.length > 0) {
        userInfo[kMRMediaRemoteOptionContentItemID] = contentItemID;
    }

    // Like and ban. Strings, all three, and passed through untouched — a track id is an opaque
    // token and parsing it here would be inventing a format.
    NSString *trackID = getEnvOption(@"track-id");
    if (trackID != nil && trackID.length > 0) {
        userInfo[kMRMediaRemoteOptionTrackID] = trackID;
    }
    NSString *stationID = getEnvOption(@"station-id");
    if (stationID != nil && stationID.length > 0) {
        userInfo[kMRMediaRemoteOptionStationID] = stationID;
    }
    NSString *stationHash = getEnvOption(@"station-hash");
    if (stationHash != nil && stationHash.length > 0) {
        userInfo[kMRMediaRemoteOptionStationHash] = stationHash;
    }

    return userInfo.count > 0 ? [userInfo copy] : nil;
}

void adapter_send(MRACommand command) {

    bool ok = false;
    MRCommand commandValue = findCommand((int)command, &ok);
    if (!ok) {
        failf(@"Invalid command: %d", command);
    }

    // ISLETA FORK. Was `sendCommand(commandValue, nil)`.
    //
    // Note what the return value is worth: `1` for a command that worked, and `1` for
    // `SetPlaybackQueue` and `kMRPlay` with a queue offset, which do nothing at all. It is checked
    // because a `0` is genuinely a refusal; it is not evidence of the opposite. The caller
    // verifies by reading the queue back.
    bool result = g_mediaRemote.sendCommand(commandValue, sendUserInfo());
    if (!result) {
        failf(@"Failed to send command %d", command);
    }

    waitForCommandCompletion();
}

static inline int send_0_command() {
    return getEnvFuncParamIntSafe(@"adapter_send", 0, @"command");
}

void adapter_send_env() { adapter_send((MRACommand)send_0_command()); }
