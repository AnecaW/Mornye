import 'dart:async';
import 'dart:io';

/// Why audio bytes could not be obtained.
///
/// The category decides recovery: [network], [timeout] and [server] failures
/// are retried; [authentication] asks for new credentials; [unavailable] is
/// permanent for the track; [cancelled] is an obsolete request.
enum StreamFailureKind {
  network,
  timeout,
  authentication,
  unavailable,
  server,
  cancelled,
  invalidData,
}

/// A safe description of a failed stream operation.
///
/// It never carries a request URI, headers or credentials: only a category, an
/// optional HTTP status and a short, credential-free detail such as
/// `range 0-65535`. [userMessage] is what the player may show.
class StreamFailure implements Exception {
  const StreamFailure(
    this.kind, {
    this.statusCode,
    this.retryable = true,
    this.detail,
  });

  final StreamFailureKind kind;
  final int? statusCode;
  final bool retryable;
  final String? detail;

  bool get isPermanent => !retryable;

  /// Classifies an arbitrary error without copying its message: transport
  /// errors can embed the credential-bearing URL.
  static StreamFailure classify(Object error) {
    if (error is StreamFailure) return error;
    if (error is TimeoutException) {
      return const StreamFailure(
        StreamFailureKind.timeout,
        retryable: true,
        detail: 'timed out',
      );
    }
    if (error is HandshakeException) {
      return const StreamFailure(
        StreamFailureKind.network,
        retryable: false,
        detail: 'TLS handshake failed',
      );
    }
    if (error is SocketException) {
      return StreamFailure(
        StreamFailureKind.network,
        retryable: true,
        detail: error.osError?.message ?? 'socket closed',
      );
    }
    if (error is HttpException) {
      final match = RegExp(
        r'Server returned (\d{3})',
      ).firstMatch(error.message);
      if (match != null) {
        return classifyStatus(int.parse(match.group(1)!));
      }
      return const StreamFailure(
        StreamFailureKind.network,
        retryable: true,
        detail: 'HTTP transport failed',
      );
    }
    if (error is StateError) {
      return const StreamFailure(
        StreamFailureKind.cancelled,
        retryable: false,
        detail: 'request cancelled',
      );
    }
    if (error is FormatException) {
      return const StreamFailure(
        StreamFailureKind.invalidData,
        retryable: false,
        detail: 'unexpected response format',
      );
    }
    return const StreamFailure(
      StreamFailureKind.server,
      retryable: true,
      detail: 'unexpected stream error',
    );
  }

  /// Classifies an HTTP status. 401/403 cannot succeed without new
  /// credentials, 404/410/416 are permanent for the track, 408/429 and 5xx are
  /// transient.
  static StreamFailure classifyStatus(int? status) {
    if (status == null) {
      return const StreamFailure(
        StreamFailureKind.network,
        retryable: true,
        detail: 'no HTTP response',
      );
    }
    if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
      return StreamFailure(
        StreamFailureKind.authentication,
        statusCode: status,
        retryable: false,
      );
    }
    if (status == HttpStatus.notFound ||
        status == HttpStatus.gone ||
        status == HttpStatus.requestedRangeNotSatisfiable) {
      return StreamFailure(
        StreamFailureKind.unavailable,
        statusCode: status,
        retryable: false,
      );
    }
    if (status == HttpStatus.requestTimeout ||
        status == HttpStatus.tooManyRequests ||
        status >= 500) {
      return StreamFailure(
        StreamFailureKind.server,
        statusCode: status,
        retryable: true,
      );
    }
    return StreamFailure(
      StreamFailureKind.server,
      statusCode: status,
      retryable: false,
    );
  }

  /// A short explanation suitable for the player's error area.
  String get userMessage => switch (kind) {
    StreamFailureKind.authentication =>
      'Your music server needs you to sign in again.',
    StreamFailureKind.unavailable =>
      'This track is no longer available on your music server.',
    StreamFailureKind.network || StreamFailureKind.timeout =>
      'Your music server is taking too long to answer. Mornye will retry.',
    StreamFailureKind.invalidData =>
      'This file could not be read from your music server.',
    StreamFailureKind.cancelled => '',
    StreamFailureKind.server => 'Your music server could not play this track.',
  };

  StreamFailure asCancelled() => const StreamFailure(
    StreamFailureKind.cancelled,
    retryable: false,
    detail: 'request cancelled',
  );

  StreamFailure withDetail(String value) => StreamFailure(
    kind,
    statusCode: statusCode,
    retryable: retryable,
    detail: value,
  );

  @override
  String toString() =>
      'StreamFailure(${kind.name}${statusCode == null ? '' : ', status=$statusCode'}'
      '${detail == null ? '' : ', $detail'})';
}

/// A contiguous, half-open byte span: `[start, end)` with `start >= 0`.
class ByteSpan {
  const ByteSpan(this.start, this.length)
    : assert(start >= 0),
      assert(length > 0);

  final int start;
  final int length;

  int get end => start + length;

  bool contains(int offset) => offset >= start && offset < end;

  bool containsRange(int rangeStart, int rangeEnd) =>
      rangeStart >= start && rangeEnd <= end;

  Map<String, dynamic> toJson() => {'start': start, 'length': length};

  static ByteSpan? fromJson(Object? value) {
    if (value is! Map) return null;
    final start = value['start'];
    final length = value['length'];
    if (start is! num || length is! num) return null;
    final s = start.toInt();
    final l = length.toInt();
    if (s < 0 || l <= 0) return null;
    return ByteSpan(s, l);
  }

  @override
  bool operator ==(Object other) =>
      other is ByteSpan && other.start == start && other.length == length;

  @override
  int get hashCode => Object.hash(start, length);

  @override
  String toString() => 'ByteSpan($start, $length)';
}

/// Sorted, merged byte spans describing what a cache entry holds.
class ByteRangeSet {
  ByteRangeSet([Iterable<ByteSpan> spans = const []]) : _spans = _merge(spans);

  factory ByteRangeSet.fromJson(Object? json) {
    if (json is! List) return ByteRangeSet();
    return ByteRangeSet([for (final value in json) ?ByteSpan.fromJson(value)]);
  }

  List<ByteSpan> _spans;

  List<ByteSpan> get spans => List.unmodifiable(_spans);

  int get totalBytes {
    var total = 0;
    for (final span in _spans) {
      total += span.length;
    }
    return total;
  }

  bool get isEmpty => _spans.isEmpty;
  bool get isNotEmpty => _spans.isNotEmpty;

  void add(int start, int length) {
    if (length <= 0 || start < 0) return;
    _spans = _merge([..._spans, ByteSpan(start, length)]);
  }

  void addSpan(ByteSpan span) => add(span.start, span.length);

  /// The span containing [offset], if any.
  ByteSpan? spanAt(int offset) {
    for (final span in _spans) {
      if (span.contains(offset)) return span;
      if (span.start > offset) break;
    }
    return null;
  }

  bool contains(int start, int length) {
    if (length <= 0) return true;
    final span = spanAt(start);
    return span != null && span.containsRange(start, start + length);
  }

  /// The first offset in `[start, end)` that is not cached, or null when the
  /// whole range is present.
  int? firstMissing(int start, int end) {
    if (end <= start) return null;
    var offset = start;
    while (offset < end) {
      final span = spanAt(offset);
      if (span == null) return offset;
      if (span.end >= end) return null;
      offset = span.end;
    }
    return null;
  }

  /// The end of the contiguous cached run that begins at [start], or [start]
  /// when nothing is cached there.
  int contiguousEndFrom(int start) {
    final span = spanAt(start);
    return span == null ? start : span.end;
  }

  bool isComplete(int totalSize) => totalSize > 0 && contains(0, totalSize);

  List<Map<String, dynamic>> toJson() => [
    for (final span in _spans) span.toJson(),
  ];

  static List<ByteSpan> _merge(Iterable<ByteSpan> spans) {
    final sorted = spans.where((span) => span.length > 0).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final merged = <ByteSpan>[];
    for (final span in sorted) {
      if (merged.isEmpty) {
        merged.add(span);
        continue;
      }
      final last = merged.last;
      if (span.start <= last.end) {
        final end = span.end > last.end ? span.end : last.end;
        merged[merged.length - 1] = ByteSpan(last.start, end - last.start);
      } else {
        merged.add(span);
      }
    }
    return merged;
  }

  @override
  String toString() => 'ByteRangeSet(${_spans.join(', ')})';
}

/// A single HTTP `Range` header as an inclusive start and exclusive end.
/// Returns null for malformed or unsatisfiable headers.
({int start, int end})? parseSingleByteRange(String header, int? size) {
  if (!header.startsWith('bytes=')) return null;
  final value = header.substring('bytes='.length).trim();
  if (value.contains(',')) return null;
  final match = RegExp(r'^(\d*)-(\d*)$').firstMatch(value);
  if (match == null) return null;
  final rawStart = match.group(1)!;
  final rawEnd = match.group(2)!;
  if (rawStart.isEmpty && rawEnd.isEmpty) return null;
  if (size == null || size <= 0) {
    if (rawStart.isEmpty) return null;
    final start = int.tryParse(rawStart);
    if (start == null || start < 0) return null;
    final end = rawEnd.isEmpty ? start : int.tryParse(rawEnd);
    if (end == null || end < start) return null;
    return (start: start, end: end + 1);
  }
  if (rawStart.isEmpty) {
    final suffix = int.tryParse(rawEnd);
    if (suffix == null || suffix <= 0) return null;
    final length = suffix > size ? size : suffix;
    return (start: size - length, end: size);
  }
  final start = int.tryParse(rawStart);
  if (start == null || start < 0 || start >= size) return null;
  final requestedEnd = rawEnd.isEmpty ? size - 1 : int.tryParse(rawEnd);
  if (requestedEnd == null || requestedEnd < start) return null;
  final end = requestedEnd >= size ? size - 1 : requestedEnd;
  return (start: start, end: end + 1);
}

/// The total representation length announced by `Content-Range` or
/// `Content-Length`, whichever is authoritative for a partial response.
int? totalSizeFromHeaders(Map<String, String> headers) {
  String? value(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  final contentRange = value('content-range');
  if (contentRange != null) {
    final match = RegExp(r'/\s*(\d+)\s*$').firstMatch(contentRange);
    if (match != null) return int.tryParse(match.group(1)!);
  }
  final length = value('content-length');
  if (length != null) {
    final parsed = int.tryParse(length);
    if (parsed != null && parsed >= 0) return parsed;
  }
  return null;
}

/// One response from the authenticated source opener.
class StreamResponse {
  StreamResponse({
    required this.statusCode,
    required this.bytes,
    this.headers = const {},
    int? totalSize,
    Future<void> Function()? close,
  }) : totalSize = totalSize ?? totalSizeFromHeaders(headers),
       close = close ?? (() async {});

  final int statusCode;
  final Stream<List<int>> bytes;
  final Map<String, String> headers;

  /// Total file length when the server announced it.
  final int? totalSize;
  final Future<void> Function() close;

  bool get isPartial => statusCode == HttpStatus.partialContent;
}

/// Opens the authenticated audio source at a byte offset.
///
/// [start] is absolute; [end] is exclusive and null for an open-ended read.
typedef StreamOpen = Future<StreamResponse> Function(int start, int? end);

/// Everything the streaming engine needs to know about one song's bytes.
class StreamTrack {
  const StreamTrack({
    required this.source,
    required this.cacheKey,
    required this.accountId,
    required this.trackId,
    required this.format,
    required this.contentType,
    this.totalSize,
    this.duration,
    this.label = '',
  });

  /// The stable `network://` identity the player queue holds.
  final String source;

  /// Cache identity, unique across accounts and servers.
  final String cacheKey;

  /// Opaque per-account identifier; never a credential.
  final String accountId;
  final String trackId;
  final String format;
  final String contentType;
  final int? totalSize;
  final Duration? duration;

  /// Credential-free short label for diagnostics.
  final String label;

  StreamTrack copyWith({int? totalSize, Duration? duration}) => StreamTrack(
    source: source,
    cacheKey: cacheKey,
    accountId: accountId,
    trackId: trackId,
    format: format,
    contentType: contentType,
    totalSize: totalSize ?? this.totalSize,
    duration: duration ?? this.duration,
    label: label,
  );
}
