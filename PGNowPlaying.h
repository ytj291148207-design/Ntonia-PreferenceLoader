#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MediaRemote 的命令码（就这几个，别自己编）。
typedef NS_ENUM(NSInteger, PGMediaCommand) {
    PGMediaCommandPlay = 0,
    PGMediaCommandPause = 1,
    PGMediaCommandTogglePlayPause = 2,
    PGMediaCommandNext = 4,
    PGMediaCommandPrevious = 5,
};

/// 系统"正在播放"的读取与远程控制。
/// 数据源是私有框架 MediaRemote（SpringBoard 进程内可直接用），
/// 任何一步取不到都只是降级成"无内容"，绝不抛异常。
@interface PGNowPlaying : NSObject

+ (instancetype)sharedInstance;

@property (nonatomic, readonly) BOOL monitoring;
/// 有歌名/歌手且确实在播 —— 只有为 YES 才值得占用胶囊的空间。
@property (nonatomic, readonly, getter=isPlaying) BOOL playing;
@property (nonatomic, copy, readonly, nullable) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *artist;
/// 正在播放的 App（可能是音乐 App，也可能是视频 App）。
@property (nonatomic, copy, readonly, nullable) NSString *bundleIdentifier;
/// 当前前台 App。和上一项不同就说明音乐在后台放 —— 也就是"玩游戏在听歌"。
@property (nonatomic, copy, readonly, nullable) NSString *frontmostBundleIdentifier;
/// 播放进度（秒）与总时长（秒）。取不到就是 0，面板会自己把进度条藏起来。
@property (nonatomic, readonly) double elapsed;
@property (nonatomic, readonly) double duration;
/// 封面图原始数据（MPNowPlayingInfo 里的 ArtworkData），可能为 nil。
@property (nonatomic, copy, readonly, nullable) NSData *artworkData;
/// 状态变化回调，主线程调用。
@property (nonatomic, copy, nullable) void (^onChange)(PGNowPlaying *nowPlaying);

- (void)startMonitoring;
- (void)stopMonitoring;
- (void)refresh;
- (void)sendCommand:(PGMediaCommand)command;

@end

NS_ASSUME_NONNULL_END
