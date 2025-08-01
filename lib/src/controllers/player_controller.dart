import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../audio_waveforms.dart';
import '../base/constants.dart';
import '../base/platform_streams.dart';
import '../base/player_identifier.dart';

part '../base/audio_waveforms_interface.dart';
part 'waveform_extraction_controller.dart';

class PlayerController extends ChangeNotifier {
  PlayerState _playerState = PlayerState.stopped;

  /// Provides current state of the player
  PlayerState get playerState => _playerState;

  bool _shouldRefresh = true;

  bool get shouldRefresh => _shouldRefresh;

  bool _isDisposed = false;

  int _maxDuration = -1;

  /// Provides [max] duration of currently provided audio file.
  int get maxDuration => _maxDuration;

  /// An unique key string associated with [this] player only
  final playerKey = shortHash(UniqueKey());

  /// An [WaveformExtractionController] instance which is bound
  /// with [PlayerController]
  /// using [playerKey] and [WaveformExtractionController._extractorKey]
  ///
  /// It can be used to extract waveform data, stop extraction
  /// or listen to waveform data changed and progress.
  late final waveformExtraction = WaveformExtractionController._(playerKey);

  final bool _shouldClearLabels = false;

  bool get shouldClearLabels => _shouldClearLabels;

  /// Rate of updating the reported current duration. Making it high will
  /// cause reporting duration at faster rate which also causes UI to look
  /// smoother.
  ///
  /// **Important** -: As duration is reported from platform, low-end devices
  /// may have higher impact if UpdateFrequency is set to high.
  ///
  /// Defaults to low (updates every 200 milliseconds).
  ///
  /// See also:
  /// * [UpdateFrequency]
  UpdateFrequency updateFrequency = UpdateFrequency.low;

  /// IOS only.
  ///
  /// Overrides AVAudioSession settings with
  /// ```
  /// AVAudioSession.Category: .playback
  /// AVAudioSession.CategoryOptions: [.default]
  /// ```
  /// You may use your implementation to set your preferred configurations.
  /// Changes to this property will only take effect after you call
  /// [preparePlayer].
  ///
  /// Setting this property to true will set the AudioSession in native
  /// otherwise nothing happens.
  ///
  /// Defaults to false.
  bool overrideAudioSession = false;

  /// A stream to get current state of the player. This stream
  /// will emit event whenever there is change in the playerState.
  Stream<PlayerState> get onPlayerStateChanged =>
      PlatformStreams.instance.onPlayerStateChanged.filter(playerKey);

  /// A stream to get current duration. This stream will emit
  /// every 200 milliseconds. Emitted duration is in milliseconds.
  Stream<int> get onCurrentDurationChanged =>
      PlatformStreams.instance.onDurationChanged.filter(playerKey);

  /// A stream to get events when audio is finished playing.
  Stream<void> get onCompletion =>
      PlatformStreams.instance.onCompletion.filter(playerKey);

  PlayerController() {
    if (!PlatformStreams.instance.isInitialised) {
      PlatformStreams.instance.init();
    }
    PlatformStreams.instance.playerControllerFactory.addAll({playerKey: this});
  }

  void _setPlayerState(PlayerState state) {
    _playerState = state;
    PlatformStreams.instance
        .addPlayerStateEvent(PlayerIdentifier(playerKey, state));
  }

  /// Calls platform to prepare player.
  ///
  /// Path  is required parameter for providing location of the
  /// audio file.
  ///
  /// [volume] is optional parameters with minimum value 0.0 is treated
  /// as mute and 1.0 as max volume. Providing value greater 1.0 is also
  /// treated same as 1.0 (max volume).
  ///
  /// Waveforms also will be extracted when with function which can be
  /// accessed using [waveformData]. Passing false to [shouldExtractWaveform]
  /// will prevent extracting of waveforms.
  ///
  /// Waveforms also can be extracted using [extractWaveformData] function
  /// which can be stored locally or over the server. This data can be passed
  /// directly passed to AudioFileWaveforms widget.
  /// This will save the resources when extracting waveforms for same file
  /// everytime.
  ///
  /// [noOfSamples] indicates no of extracted data points. This will determine
  /// number of bars in the waveform.
  ///
  /// Defaults to 100.
  Future<void> preparePlayer({
    required String path,
    double? volume,
    bool shouldExtractWaveform = true,
    int noOfSamples = 100,
  }) async {
    final isPrepared = await AudioWaveformsInterface.instance.preparePlayer(
      path: path,
      key: playerKey,
      frequency: updateFrequency.value,
      volume: volume,
      overrideAudioSession: overrideAudioSession,
    );
    if (isPrepared) {
      _maxDuration = await getDuration();
      _setPlayerState(PlayerState.initialized);
    }

    if (shouldExtractWaveform) {
      waveformExtraction
          .extractWaveformData(
        path: path,
        noOfSamples: noOfSamples,
      )
          .then(
        (value) {
          waveformExtraction.waveformData
            ..clear()
            ..addAll(value);
          notifyListeners();
        },
      );
    }
    notifyListeners();
  }

  /// A function to start the player to play/resume the audio.
  ///
  /// When playing audio is finished, this [player] will be [stopped]
  /// and [disposed] by default. To change this behavior use [setFinishMode] method.
  ///
  Future<void> startPlayer({
    bool forceRefresh = true,
  }) async {
    if (_playerState == PlayerState.initialized ||
        _playerState == PlayerState.paused) {
      final isStarted =
          await AudioWaveformsInterface.instance.startPlayer(playerKey);
      if (isStarted) {
        _setPlayerState(PlayerState.playing);
      } else {
        throw "Failed to start player";
      }
    }
    _setRefresh(forceRefresh);
    notifyListeners();
  }

  /// Pauses currently playing audio.
  Future<void> pausePlayer() async {
    final isPaused =
        await AudioWaveformsInterface.instance.pausePlayer(playerKey);
    if (isPaused) {
      _setPlayerState(PlayerState.paused);
    }
    notifyListeners();
  }

  /// A function to stop player.
  Future<void> stopPlayer() async {
    final isStopped =
        await AudioWaveformsInterface.instance.stopPlayer(playerKey);
    if (isStopped) {
      _setPlayerState(PlayerState.stopped);
    }
    notifyListeners();
  }

  /// Releases the resources associated with this player.
  Future<void> release() async {
    await AudioWaveformsInterface.instance.release(playerKey);
  }

  /// Sets volume for this player. Doesn't throw Exception.
  /// Returns false if it couldn't set the volume.
  ///
  /// Minimum value [0.0] is treated as mute and 1.0 as max volume.
  /// Providing value greater 1.0 is also treated same as 1.0 (max volume).
  ///
  /// Default to 1.0
  Future<bool> setVolume(double volume) async {
    final result =
        await AudioWaveformsInterface.instance.setVolume(volume, playerKey);
    return result;
  }

  /// Sets playback rate for this player. Doesn't throw Exception.
  /// Returns false if it couldn't set the rate.
  ///
  /// Default to 1.0
  Future<bool> setRate(double rate) async {
    final result =
        await AudioWaveformsInterface.instance.setRate(rate, playerKey);
    return result;
  }

  /// Returns maximum duration for [DurationType.max] and
  /// current duration for [DurationType.current] for playing media.
  /// The duration is in milliseconds, if no duration is available
  /// -1 is returned.
  ///
  /// Default to Duration.max.
  Future<int> getDuration([DurationType? durationType]) async {
    final duration = await AudioWaveformsInterface.instance
        .getDuration(playerKey, durationType?.index ?? 1);
    return duration ?? -1;
  }

  /// Moves the media to specified time(milliseconds) position.
  ///
  /// Minimum Android [O] is required to use this function
  /// otherwise nothing happens.
  Future<void> seekTo(int progress) async {
    if (progress < 0 || _playerState.isStopped) return;

    await AudioWaveformsInterface.instance.seekTo(playerKey, progress);
  }

  /// This method will be used to change behaviour of player when audio
  /// is finished playing.
  ///
  /// Check[FinishMode]'s doc to understand the difference between the modes.
  Future<void> setFinishMode({
    FinishMode finishMode = FinishMode.stop,
  }) async {
    return AudioWaveformsInterface.instance.setReleaseMode(
      playerKey,
      finishMode,
    );
  }

  /// Release any resources taken by this controller. Disposing this
  /// will stop the player and release resources from native.
  ///
  /// If this is last remaining controller then it will also dispose
  /// the platform stream. They can be re-initialised by initialising a
  /// new controller.
  @override
  void dispose() async {
    if (playerState != PlayerState.stopped) await stopPlayer();
    await release();
    PlatformStreams.instance.playerControllerFactory.remove(playerKey);
    if (PlatformStreams.instance.playerControllerFactory.isEmpty) {
      PlatformStreams.instance.dispose();
    }
    _isDisposed = true;
    super.dispose();
  }

  /// Frees [resources] used by all players simultaneously.
  ///
  /// This method closes the stream and releases resources allocated by all
  /// players. Note that it does not dispose of the controller.
  ///
  /// Returns `true` if all players stop successfully, otherwise returns `false`.
  Future<bool> stopAllPlayers() async {
    PlatformStreams.instance.dispose();
    var isAllPlayersStopped =
        await AudioWaveformsInterface.instance.stopAllPlayers();
    if (isAllPlayersStopped) {
      PlatformStreams.instance.playerControllerFactory
          .forEach((playKey, controller) {
        controller._setPlayerState(PlayerState.stopped);
      });
    }
    return isAllPlayersStopped;
  }

  /// Pauses all the players. Works similar to stopAllPlayer.
  Future<bool> pauseAllPlayers() async {
    var isAllPlayersPaused =
        await AudioWaveformsInterface.instance.pauseAllPlayers();
    if (isAllPlayersPaused) {
      PlatformStreams.instance.playerControllerFactory
          .forEach((playKey, controller) {
        controller._setPlayerState(PlayerState.paused);
      });
    }
    return isAllPlayersPaused;
  }

  /// Sets [_shouldRefresh] flag with provided boolean parameter.
  void _setRefresh(bool refresh) {
    _shouldRefresh = refresh;
  }

  /// Sets [_shouldRefresh] flag with provided boolean parameter.
  void setRefresh(bool refresh) {
    _shouldRefresh = refresh;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  @override
  bool operator ==(Object other) {
    return other is PlayerController && other.playerKey == playerKey;
  }

  @override
  int get hashCode => super.hashCode; //ignore: unnecessary_overrides
}
