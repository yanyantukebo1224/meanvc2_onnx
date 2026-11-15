import Flutter
import UIKit
import AVFAudio
#if canImport(FoundationModels)
import FoundationModels
#endif

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
  #if canImport(FoundationModels)
  @available(iOS 26.0, *)
  @MainActor private static var chatSession: LanguageModelSession?
  #endif

  @MainActor
  private static func synthesizeSpeechToFile(_ text: String) async throws -> String {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("meanvc2_chat_\(UUID().uuidString)")
      .appendingPathExtension("caf")
    return try await withCheckedThrowingContinuation { continuation in
      var audioFile: AVAudioFile?
      var didFinish = false
      synthesizer.write(utterance) { buffer in
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
        if pcmBuffer.frameLength == 0 {
          guard !didFinish else { return }
          didFinish = true
          if audioFile == nil {
            continuation.resume(throwing: NSError(domain: "MeanVC2Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech synthesis returned no audio."]))
          } else {
            continuation.resume(returning: url.path)
          }
          return
        }
        do {
          if audioFile == nil {
            audioFile = try AVAudioFile(forWriting: url, settings: pcmBuffer.format.settings)
          }
          try audioFile?.write(from: pcmBuffer)
        } catch {
          guard !didFinish else { return }
          didFinish = true
          continuation.resume(throwing: error)
        }
      }
    }
  }

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
      case "generateChatReply":
        guard let args = call.arguments as? [String: Any],
              let prompt = args["text"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          result(FlutterError(code: "BAD_ARGUMENT", message: "text is required.", details: nil))
          return
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
          Task { @MainActor in
            do {
              if chatSession == nil {
                chatSession = LanguageModelSession(instructions: "あなたはMeanVC2に搭載された日本語の会話アシスタントです。自然で親しみやすく、簡潔に返答してください。音声で読み上げるため、記号や箇条書きを多用しないでください。")
              }
              let response = try await chatSession!.respond(to: prompt)
              result(response.content)
            } catch {
              result(FlutterError(code: "FOUNDATION_MODEL", message: error.localizedDescription, details: nil))
            }
          }
        } else {
          result(FlutterError(code: "UNSUPPORTED", message: "Apple Foundation Models requires iOS 26 or later.", details: nil))
        }
        #else
        result(FlutterError(code: "UNSUPPORTED", message: "Foundation Models is unavailable in this SDK.", details: nil))
        #endif
      case "synthesizeChatReply":
        guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String, !text.isEmpty else {
          result(FlutterError(code: "BAD_ARGUMENT", message: "text is required.", details: nil))
          return
        }
        Task { @MainActor in
          do {
            let path = try await synthesizeSpeechToFile(text)
            result(path)
          } catch {
            result(FlutterError(code: "SPEECH_SYNTHESIS", message: error.localizedDescription, details: nil))
          }
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
