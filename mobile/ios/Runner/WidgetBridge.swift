import Flutter
import WidgetKit

/// `checkcheck/widget`: the Dart side copies the connection for the
/// home-screen widget and asks it to reload.
class WidgetBridge: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "checkcheck/widget", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(WidgetBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setConnection":
      guard let arguments = call.arguments as? [String: Any],
        let server = arguments["server"] as? String,
        let token = arguments["token"] as? String
      else {
        result(FlutterError(code: "bad-arguments", message: "server and token are required", details: nil))
        return
      }
      do {
        try WidgetConnection(server: server, token: token).save()
      } catch {
        result(FlutterError(code: "keychain", message: error.localizedDescription, details: nil))
        return
      }
      WidgetCenter.shared.reloadAllTimelines()
      result(nil)
    case "clearConnection":
      WidgetConnection.clear()
      WidgetCenter.shared.reloadAllTimelines()
      result(nil)
    case "reload":
      WidgetCenter.shared.reloadAllTimelines()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
