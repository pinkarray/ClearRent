import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/constants/colors.dart';
import '../../services/video_viewing_service.dart';

/// The live call for a video viewing. The host films the property with the
/// rear camera; the tenant watches with their own camera off unless they turn
/// it on. Credentials come from [VideoViewingService], which already did the
/// host's presence check.
class VideoCallScreen extends StatefulWidget {
  final String requestId;
  final String propertyTitle;
  final bool isHost;
  final VideoCallCredentials credentials;

  const VideoCallScreen({
    super.key,
    required this.requestId,
    required this.propertyTitle,
    required this.isHost,
    required this.credentials,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  // How often the host's phone reports where it is during the call.
  static const _presenceEvery = Duration(minutes: 3);

  late final RtcEngine _engine;
  bool _ready = false;
  int? _remoteUid;
  bool _micOn = true;
  late bool _cameraOn = widget.isHost;
  String _status = 'Connecting...';
  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final perms = await [Permission.camera, Permission.microphone].request();
    if (perms.values.any((s) => !s.isGranted)) {
      if (!mounted) return;
      setState(() => _status =
          'ClearRent needs your camera and microphone for the call. '
          'Allow them in Settings.');
      return;
    }

    final c = widget.credentials;
    _engine = createAgoraRtcEngine();
    await _engine.initialize(RtcEngineContext(
      appId: c.appId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));
    _engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (_, _) {
        if (mounted) {
          setState(() => _status = widget.isHost
              ? 'Waiting for the tenant to join...'
              : 'Waiting for your host...');
        }
      },
      onUserJoined: (_, remoteUid, _) {
        if (mounted) setState(() => _remoteUid = remoteUid);
      },
      onUserOffline: (_, remoteUid, _) {
        if (mounted && _remoteUid == remoteUid) {
          setState(() {
            _remoteUid = null;
            _status = widget.isHost
                ? 'The tenant left the call.'
                : 'Your host left the call.';
          });
        }
      },
      onConnectionStateChanged: (_, state, _) {
        if (!mounted) return;
        if (state == ConnectionStateType.connectionStateReconnecting) {
          setState(() => _status = 'Weak network, reconnecting...');
        }
      },
    ));

    await _engine.enableVideo();
    // 360p at 15fps: a walkthrough doesn't need more, and Nigerian mobile data
    // does not forgive more.
    await _engine.setVideoEncoderConfiguration(const VideoEncoderConfiguration(
      dimensions: VideoDimensions(width: 640, height: 360),
      frameRate: 15,
    ));
    if (widget.isHost) {
      await _engine.setCameraCapturerConfiguration(
        const CameraCapturerConfiguration(
          cameraDirection: CameraDirection.cameraRear,
        ),
      );
    }
    await _engine.muteLocalVideoStream(!_cameraOn);
    await _engine.startPreview();
    await _engine.joinChannel(
      token: c.token,
      channelId: c.channel,
      uid: c.uid,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        publishCameraTrack: true,
        publishMicrophoneTrack: true,
        autoSubscribeAudio: true,
        autoSubscribeVideo: true,
      ),
    );
    if (!mounted) return;
    setState(() => _ready = true);

    if (widget.isHost) {
      _presenceTimer = Timer.periodic(_presenceEvery, (_) {
        VideoViewingService().reportPresence(widget.requestId);
      });
    }
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    if (_ready) {
      _engine.leaveChannel();
      _engine.release();
    }
    super.dispose();
  }

  Future<void> _toggleMic() async {
    setState(() => _micOn = !_micOn);
    await _engine.muteLocalAudioStream(!_micOn);
  }

  Future<void> _toggleCamera() async {
    setState(() => _cameraOn = !_cameraOn);
    await _engine.muteLocalVideoStream(!_cameraOn);
  }

  @override
  Widget build(BuildContext context) {
    final remote = _remoteUid;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Main view: the other party. For the tenant that is the property.
            Positioned.fill(
              child: _ready && remote != null
                  ? AgoraVideoView(
                      controller: VideoViewController.remote(
                        rtcEngine: _engine,
                        canvas: VideoCanvas(uid: remote),
                        connection: RtcConnection(
                          channelId: widget.credentials.channel,
                        ),
                      ),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
            ),
            // Own camera, small. The host sees what they are filming.
            if (_ready && _cameraOn)
              Positioned(
                top: 16,
                right: 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AgoraVideoView(
                    controller: VideoViewController(
                      rtcEngine: _engine,
                      canvas: const VideoCanvas(uid: 0),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 16,
              left: 16,
              right: 140,
              child: Text(
                widget.propertyTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _CallButton(
                    icon: _micOn ? Icons.mic : Icons.mic_off,
                    onTap: _ready ? _toggleMic : null,
                  ),
                  _CallButton(
                    icon: _cameraOn ? Icons.videocam : Icons.videocam_off,
                    onTap: _ready ? _toggleCamera : null,
                  ),
                  _CallButton(
                    icon: Icons.flip_camera_android,
                    onTap: _ready && _cameraOn ? _engine.switchCamera : null,
                  ),
                  _CallButton(
                    icon: Icons.call_end,
                    color: AppColors.error,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;

  const _CallButton({required this.icon, this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color ?? Colors.white24,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Icon(
            icon,
            color: onTap == null ? Colors.white38 : Colors.white,
          ),
        ),
      ),
    );
  }
}
