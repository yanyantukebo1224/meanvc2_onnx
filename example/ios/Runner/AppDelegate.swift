import Flutter
import UIKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    CallAudioIntegration.register(messenger: engineBridge.binaryMessenger)
  }
}


private enum CallAudioIntegration {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "meanvc2/call_audio", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        if #available(iOS 18.2, *) {
          let permission = AVAudioApplication.shared.microphoneInjectionPermission
          result([
            "supported": true,
            "available": AVAudioSession.sharedInstance().isMicrophoneInjectionAvailable,
            "permission": String(describing: permission)
          ])
        } else {
          result(["supported": false, "available": false, "permission": "unsupported"])
        }
      case "requestPermission":
        if #available(iOS 18.2, *) {
          Task { @MainActor in
            let permission = await AVAudioApplication.requestMicrophoneInjectionPermission()
            result([
              "granted": permission == .granted,
              "permission": String(describing: permission)
            ])
          }
        } else {
          result(FlutterError(code: "UNSUPPORTED", message: "Microphone injection requires a newer iOS version.", details: nil))
        }
      case "setEnabled":
        guard let args = call.arguments as? [String: Any],
              let enabled = args["enabled"] as? Bool else {
          result(FlutterError(code: "BAD_ARGUMENT", message: "enabled is required.", details: nil))
          return
        }
        if #available(iOS 18.2, *) {
          do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setPreferredMicrophoneInjectionMode(enabled ? .spokenAudio : .none)
            try session.setActive(true)
            result(["enabled": enabled, "available": session.isMicrophoneInjectionAvailable])
          } catch {
            result(FlutterError(code: "AUDIO_SESSION", message: error.localizedDescription, details: nil))
          }
        } else {
          result(FlutterError(code: "UNSUPPORTED", message: "Microphone injection requires a newer iOS version.", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
