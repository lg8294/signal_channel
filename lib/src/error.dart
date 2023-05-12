class SignalRChannelError implements Exception {
  static final String tag = 'SignalRChannel';

  final String? message;

  SignalRChannelError([this.message]);

  String toString() {
    if (message == null) return "$tag Exception";
    return "$tag Exception: $message";
  }
}
