import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

bool get usesIosSystemViews => !kIsWeb && Platform.isIOS;

Map<String, Object?> iosSystemAppearance(BuildContext context) => {
  'dark': Theme.of(context).brightness == Brightness.dark,
  'rtl': Directionality.of(context) == TextDirection.rtl,
};

/// Hosts UIKit in the existing Flutter layout. Flutter remains the source of
/// truth for values, destinations and actions.
class IosSystemView extends StatefulWidget {
  const IosSystemView({
    super.key,
    required this.kind,
    required this.configuration,
    this.onChanged,
  });

  final String kind;
  final Map<String, Object?> configuration;
  final ValueChanged<Object?>? onChanged;

  @override
  State<IosSystemView> createState() => _IosSystemViewState();
}

class _IosSystemViewState extends State<IosSystemView> {
  MethodChannel? _channel;
  static const _type = 'com.zarz.mornye/ios_system_view';

  Future<void> _configure() async {
    await _channel?.invokeMethod<void>('configure', widget.configuration);
  }

  @override
  void didUpdateWidget(covariant IosSystemView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(oldWidget.configuration) !=
        jsonEncode(widget.configuration)) {
      unawaited(_configure());
    }
  }

  @override
  Widget build(BuildContext context) => UiKitView(
    viewType: _type,
    layoutDirection: Directionality.of(context),
    hitTestBehavior: widget.onChanged == null
        ? PlatformViewHitTestBehavior.transparent
        : PlatformViewHitTestBehavior.opaque,
    creationParams: {'kind': widget.kind, ...widget.configuration},
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: (id) {
      if (!mounted) return;
      final channel = MethodChannel('$_type/$id');
      _channel = channel;
      channel.setMethodCallHandler((call) async {
        if (mounted && call.method == 'changed') {
          widget.onChanged?.call(call.arguments);
        }
      });
      unawaited(_configure());
    },
  );

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
}
