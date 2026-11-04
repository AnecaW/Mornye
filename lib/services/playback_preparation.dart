import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum PlaybackPhase {
  idle,
  loading,
  buffering,
  playing,
  paused,
  recovering,
  failed,
}

bool recoverableNetworkPreparation(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  if (error is HttpException) {
    return RegExp(r'\b(408|425|429|500|502|503|504)\b').hasMatch(error.message);
  }
  if (error is PlatformException) {
    final text = '${error.code} ${error.message} ${error.details}';
    if (RegExp(
      r'\b(401|403|404|415)\b|unsupported|not supported|NSURLErrorDomain (-1011|-1012|-1013)',
      caseSensitive: false,
    ).hasMatch(text)) {
      return false;
    }
    return text.contains('Failed to set playerItem') ||
        text.contains('Failed to set playeritem') ||
        text.contains('AVPlayerItem.Status.failed') ||
        text.contains('MEDIA_ERROR_IO') ||
        text.contains('NSURLErrorDomain');
  }
  return false;
}

Future<T?> prepareNetworkPlayback<T>({
  required Future<T> Function(int attempt) prepare,
  required bool Function() current,
  required Future<void> Function(int attempt) recovering,
  Future<void> Function(Duration)? wait,
  int attempts = 3,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (!current()) return null;
    try {
      return await prepare(attempt);
    } catch (error) {
      if (!current()) return null;
      if (attempt == attempts - 1 || !recoverableNetworkPreparation(error)) {
        rethrow;
      }
      await recovering(attempt + 1);
      if (!current()) return null;
      await (wait ?? Future<void>.delayed)(
        Duration(milliseconds: 250 * (attempt + 1)),
      );
    }
  }
  return null;
}
