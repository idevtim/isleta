// clang-format off

#ifndef MEDIAREMOTE_PRIVATE_H_
#define MEDIAREMOTE_PRIVATE_H_

#include <Foundation/Foundation.h>

#pragma mark Notifications

extern NSString *kMRMediaRemoteNowPlayingInfoDidChangeNotification;

// ISLETA FORK. Declared upstream and **never posted**: registering for it produced zero callbacks
// against a Music queue that was demonstrably changing, measured on macOS 27.0 on 2026-08-23.
// `NSNotificationCenter` registration returns void, so a name nobody posts is indistinguishable
// from a quiet machine — the same trap as CoreBrightness's `KB*` keys. It is kept because it is
// upstream's, and because deleting it invites the next reader to add it back.
extern NSString *kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification;

// ISLETA FORK. The two that actually fire. Neither carries the `MediaRemote` infix, which is why
// no amount of guessing from the declared name above arrives at them; both were posted in the
// *same millisecond* as the info change `stream` already handles.
extern NSString *kMRNowPlayingPlaybackQueueChangedNotification;
extern NSString *kMRPlayerPlaybackQueueChangedNotification;
extern NSString *kMRMediaRemotePickableRoutesDidChangeNotification;
extern NSString *kMRMediaRemoteNowPlayingApplicationDidChangeNotification;
extern NSString *kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification;
extern NSString *kMRMediaRemoteRouteStatusDidChangeNotification;

#pragma mark Keys

extern NSString *kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey;
extern NSString *kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey;
extern NSString *kMRMediaRemoteNowPlayingInfoAlbum;
extern NSString *kMRMediaRemoteNowPlayingInfoArtist;
extern NSString *kMRMediaRemoteNowPlayingInfoArtworkData;
extern NSString *kMRMediaRemoteNowPlayingInfoArtworkMIMEType;
extern NSString *kMRMediaRemoteNowPlayingInfoChapterNumber;
extern NSString *kMRMediaRemoteNowPlayingInfoComposer;
extern NSString *kMRMediaRemoteNowPlayingInfoDuration;
extern NSString *kMRMediaRemoteNowPlayingInfoElapsedTime;
extern NSString *kMRMediaRemoteNowPlayingInfoGenre;
extern NSString *kMRMediaRemoteNowPlayingInfoIsAdvertisement;
extern NSString *kMRMediaRemoteNowPlayingInfoIsBanned;
extern NSString *kMRMediaRemoteNowPlayingInfoIsInWishList;
extern NSString *kMRMediaRemoteNowPlayingInfoIsLiked;
extern NSString *kMRMediaRemoteNowPlayingInfoIsMusicApp;
extern NSString *kMRMediaRemoteNowPlayingInfoPlaybackRate;
extern NSString *kMRMediaRemoteNowPlayingInfoProhibitsSkip;
extern NSString *kMRMediaRemoteNowPlayingInfoQueueIndex;
extern NSString *kMRMediaRemoteNowPlayingInfoRadioStationIdentifier;
extern NSString *kMRMediaRemoteNowPlayingInfoRepeatMode;
extern NSString *kMRMediaRemoteNowPlayingInfoShuffleMode;
extern NSString *kMRMediaRemoteNowPlayingInfoStartTime;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsFastForward15Seconds;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsIsBanned;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsIsLiked;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsRewind15Seconds;
extern NSString *kMRMediaRemoteNowPlayingInfoTimestamp;
extern NSString *kMRMediaRemoteNowPlayingInfoTitle;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalChapterCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalDiscCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalQueueCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalTrackCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTrackNumber;
extern NSString *kMRMediaRemoteNowPlayingInfoUniqueIdentifier;
extern NSString *kMRMediaRemoteNowPlayingInfoContentItemIdentifier;
extern NSString *kMRMediaRemoteNowPlayingInfoRadioStationHash;
extern NSString *kMRMediaRemoteNowPlayingInfoMediaType;
extern NSString *kMRMediaRemoteNowPlayingInfoServiceIdentifier;
extern NSString *kMRMediaRemoteOptionMediaType;
extern NSString *kMRMediaRemoteOptionSourceID;
extern NSString *kMRMediaRemoteOptionTrackID;
extern NSString *kMRMediaRemoteOptionStationID;
extern NSString *kMRMediaRemoteOptionStationHash;

// ISLETA FORK. The two keys that make `PlayItemInPlaybackQueue` do something.
//
// Both are required and neither is enough. Measured on macOS 27.0 against a live Music queue:
// `kMRPlay (0)` and `SetPlaybackQueue (122)` with the offset alone each returned `1` and changed
// nothing, and `PlayItemInPlaybackQueue (131)` with the offset **and** the content-item id jumped
// to the track. Verified by reading the queue back — never by the return value, which is `1` for
// all three.
//
// **The plural spelling is inert.** `kMRMediaRemoteOptionContentItemIDs` exists in the framework's
// strings and silently does nothing here; it is the batch form. This is the same shape as the
// `AXUIElementPerformAction` trap already in CLAUDE.md: the wrong key is not refused, it is ignored.
extern NSString *kMRMediaRemoteOptionPlaybackQueueOffset;
extern NSString *kMRMediaRemoteOptionContentItemID;
extern NSString *kMRMediaRemoteRouteDescriptionUserInfoKey;
extern NSString *kMRMediaRemoteRouteStatusUserInfoKey;

#pragma mark API

typedef enum {
    /*
     * Use nil for userInfo.
     */
    kMRPlay = 0,
    kMRPause = 1,
    kMRTogglePlayPause = 2,
    kMRStop = 3,
    kMRNextTrack = 4,
    kMRPreviousTrack = 5,
    kMRToggleShuffle = 6,
    kMRToggleRepeat = 7,
    kMRStartForwardSeek = 8,
    kMREndForwardSeek = 9,
    kMRStartBackwardSeek = 10,
    kMREndBackwardSeek = 11,
    kMRGoBackFifteenSeconds = 12,
    kMRSkipFifteenSeconds = 13,

    /*
     * Use a NSDictionary for userInfo, which contains three keys:
     * kMRMediaRemoteOptionTrackID
     * kMRMediaRemoteOptionStationID
     * kMRMediaRemoteOptionStationHash
     */
    kMRLikeTrack = 0x6A,
    kMRBanTrack = 0x6B,
    kMRAddTrackToWishList = 0x6C,
    kMRRemoveTrackFromWishList = 0x6D,

    /*
     * ISLETA FORK. Jump to an entry of the playback queue.
     *
     * Use a NSDictionary for userInfo carrying **both**:
     * kMRMediaRemoteOptionPlaybackQueueOffset
     * kMRMediaRemoteOptionContentItemID
     *
     * 131 rather than 122. `SetPlaybackQueue (122)` is the one that reads like the answer, takes
     * the same offset, returns 1 and does nothing.
     */
    kMRPlayItemInPlaybackQueue = 131
} MRCommand;

extern CFStringRef MRMediaRemoteSendCommand;
typedef bool (*MRMediaRemoteSendCommand_t)(MRCommand command, id userInfo);

extern CFStringRef MRMediaRemoteSetPlaybackSpeed;
extern CFStringRef MRMediaRemoteSetElapsedTime;
extern CFStringRef MRMediaRemoteSetShuffleMode;
extern CFStringRef MRMediaRemoteSetRepeatMode;
typedef void (*MRMediaRemoteSetPlaybackSpeed_t)(int speed);
typedef void (*MRMediaRemoteSetElapsedTime_t)(double elapsedTime);
typedef void (*MRMediaRemoteSetShuffleMode_t)(int mode);
typedef void (*MRMediaRemoteSetRepeatMode_t)(int mode);

extern CFStringRef MRMediaRemoteRegisterForNowPlayingNotifications;
extern CFStringRef MRMediaRemoteUnregisterForNowPlayingNotifications;
extern CFStringRef MRMediaRemoteGetNowPlayingApplicationPID;
extern CFStringRef MRMediaRemoteGetNowPlayingClient;
extern CFStringRef MRMediaRemoteGetNowPlayingInfo;
extern CFStringRef MRMediaRemoteGetNowPlayingApplicationIsPlaying;

// ISLETA FORK. The playback queue — the true Up Next.
//
// Behind the *same* code-signing-identifier gate as `MRMediaRemoteGetNowPlayingInfo`: as
// `/usr/bin/perl` it answers a 25-item window in 15-30 ms (5 items in 4-5 ms); from an ad-hoc
// signed CLI it answers `kMRMediaRemoteFrameworkErrorDomain` Code=3, "Operation not permitted".
// So this needs no new mechanism, no new permission and no third private path in Isleta — it is
// one more thing Apple's Perl is allowed to ask on our behalf.
//
// "Sync" names the *request*, not the call: the function returns immediately and answers on the
// queue it is given, exactly like the four getters above.
extern CFStringRef MRMediaRemoteRequestNowPlayingPlaybackQueueSync;

typedef void (*MRMediaRemoteRegisterForNowPlayingNotifications_t)(dispatch_queue_t queue);
typedef void (*MRMediaRemoteUnregisterForNowPlayingNotifications_t)();

typedef void (^MRMediaRemoteGetNowPlayingInfoCompletion_t)(NSDictionary *information);
typedef void (^MRMediaRemoteGetNowPlayingApplicationPIDCompletion_t)(int PID);
typedef void (^MRMediaRemoteGetNowPlayingClientCompletion_t)(id clientObj);
typedef void (^MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion_t)(bool isPlaying);

typedef void (*MRMediaRemoteGetNowPlayingApplicationPID_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingApplicationPIDCompletion_t completion);
typedef void (*MRMediaRemoteGetNowPlayingClient_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingClientCompletion_t completion);
typedef void (*MRMediaRemoteGetNowPlayingInfo_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingInfoCompletion_t completion);
typedef void (*MRMediaRemoteGetNowPlayingApplicationIsPlaying_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion_t completion);

// ISLETA FORK. `queue` is an `MRPlaybackQueue`; `request` is an `MRPlaybackQueueRequest`.
typedef void (^MRMediaRemoteRequestNowPlayingPlaybackQueueCompletion_t)(id queue, NSError *error);
typedef void (*MRMediaRemoteRequestNowPlayingPlaybackQueueSync_t)(id request, dispatch_queue_t queue, MRMediaRemoteRequestNowPlayingPlaybackQueueCompletion_t completion);

#pragma mark Miscellaneous

extern NSString *kMRNowPlayingClientUserInfoKey;

// Accessed with the kMRNowPlayingClientUserInfoKey
// on the userInfo dictionary of an NSNotification.
@interface MRClient : NSObject {}
-(NSString *)parentApplicationBundleIdentifier;
-(NSString *)bundleIdentifier;
-(NSString *)displayName;
@end

// ISLETA FORK. The request object. Declared rather than reflected because these four selectors are
// the whole of what a queue read needs, and `performSelector:` on a method taking an `NSRange` is
// not expressible — the struct argument does not survive the `id`-returning signature.
//
// `+defaultPlaybackQueueRequestWithRange:` is the constructor that works; the parameterless
// `+defaultPlaybackQueueRequest` asks for the whole queue, and a library queue is thousands of
// items. `setIncludeMetadata:` is what puts a title and an artist on each item and
// `setIncludeInfo:` is what fills in the rest; without them the array comes back as identifiers.
@interface MRPlaybackQueueRequest : NSObject
+(instancetype)defaultPlaybackQueueRequestWithRange:(NSRange)range;
-(void)setIncludeMetadata:(BOOL)includeMetadata;
-(void)setIncludeInfo:(BOOL)includeInfo;
@end

// ISLETA FORK. What comes back. `contentItems` is an array of `MRContentItem`.
//
// **`isCurrentlyPlaying` is 0 on every item, the playing one included** — measured with both
// include flags set and with item 0's identifier matching
// `kMRMediaRemoteNowPlayingInfoContentItemIdentifier` exactly. The discriminator is *positional*:
// played items are dropped from the window, so index 0 is the current track and index 1 is the
// next one. That property is declared here anyway, so that the next person to reach for the field
// named after the question finds the sentence saying it does not answer it.
// ISLETA FORK. The audio format of the playing entry, which exists in no other MediaRemote
// surface — see `queue.m` for the four routes that were measured and failed before this one.
// Populated on the *currently playing* item only; every entry after it answers nil.
// **Read through `dictionaryRepresentation` and not through the accessors**, which is not laziness.
// The accessors' return types are not declared anywhere we can see, and guessing them wrong is
// silent: `sampleRate` declared `double` against an integer selector returned 4.24e-314 and a
// `bitDepth` of 0 — numbers that are not obviously wrong until you look for 44100. The framework's
// own dictionary is already boxed with the right types by the code that owns them.
@interface MRContentItemMetadataAudioFormat : NSObject
-(NSDictionary *)dictionaryRepresentation;
@end

@interface MRContentItemMetadata : NSObject
-(NSString *)title;
-(NSString *)trackArtistName;
-(NSString *)albumName;
-(double)duration;
-(long long)iTunesStoreIdentifier;
-(BOOL)isCurrentlyPlaying;
// ISLETA FORK.
-(MRContentItemMetadataAudioFormat *)activeFormat;
@end

@interface MRContentItem : NSObject
-(NSString *)identifier;
-(MRContentItemMetadata *)metadata;
@end

@interface MRPlaybackQueue : NSObject
-(NSArray<MRContentItem *> *)contentItems;
@end

@interface MediaRemote : NSObject
// Commands
@property(readonly) MRMediaRemoteSendCommand_t sendCommand;
// Other controls
@property(readonly) MRMediaRemoteSetPlaybackSpeed_t setPlaybackSpeed;
@property(readonly) MRMediaRemoteSetElapsedTime_t setElapsedTime;
@property(readonly) MRMediaRemoteSetShuffleMode_t setShuffleMode;
@property(readonly) MRMediaRemoteSetRepeatMode_t setRepeatMode;
// Observers
@property(readonly) MRMediaRemoteRegisterForNowPlayingNotifications_t registerForNowPlayingNotifications;
@property(readonly) MRMediaRemoteUnregisterForNowPlayingNotifications_t unregisterForNowPlayingNotifications;
// Metadata
@property(readonly) MRMediaRemoteGetNowPlayingApplicationPID_t getNowPlayingApplicationPID;
@property(readonly) MRMediaRemoteGetNowPlayingClient_t getNowPlayingClient;
@property(readonly) MRMediaRemoteGetNowPlayingInfo_t getNowPlayingInfo;
@property(readonly) MRMediaRemoteGetNowPlayingApplicationIsPlaying_t getNowPlayingApplicationIsPlaying;
// ISLETA FORK. Nil on an OS that has withdrawn the symbol; every caller checks.
@property(readonly) MRMediaRemoteRequestNowPlayingPlaybackQueueSync_t requestNowPlayingPlaybackQueue;
// Constructor
-(id)init;
@end

#endif /* MEDIAREMOTE_PRIVATE_H_ */
